# Concurrent Answers & Version Vectors — How It Works

**Script:** `scripts/13_demo_concurrent_answers_version_vectors.py`

**Book sections:** *DDIA*, Replication → Problems with Replication Lag →
**Consistent Prefix Reads** (*"algorithms that explicitly keep track of causal
dependencies"*) and → Leaderless Replication → **Detecting Concurrent Writes**
(*"The 'happens-before' relationship and concurrency"*, *"Version vectors"*).

> 🎬 **Prefer to watch it first?** Open
> [version_vectors_animation.html](version_vectors_animation.html) in a browser.
> It replays this demo step by step, with the vectors, the hold-back and the final
> ordering animated.

This builds on [consistent_prefix_reads.md](consistent_prefix_reads.md). Script
12 Part B tracked **one** dependency with **one** LSN. This demo has many writers
answering at the same moment, so it tracks dependencies with a **vector**.

---

## 1. The scenario

```
                         Mr. Poons: "How far into the future can you see?"   P1
                                          │
               ┌──────────────┬───────────┴──┬──────────────┐
               ▼              ▼              ▼              ▼        same instant
            Alice A1        Bob B1        Carol C1       Dave D1      (concurrent)
                                │   ╲            │
                                │    ╲ Carol sees ALL four answers
                                │     ╲          ▼
                                │      ╲──────► Carol C2  "Bob's right…"   (after B1)
                                │
                         Bob's partition lags → Dave can't see B1 yet
                                                 Dave D2  "Agree with Alice" (concurrent with B1, C2)
```

Three things need answering:

1. **How do participants see each other's messages?** Each one reads the chat,
   and what they saw becomes part of their next message's metadata.
2. **How does a reader tell "replied to" from "concurrent"?** By comparing
   version vectors.
3. **How does every reader end up with the same order?** By delivering messages
   causally, then sorting them deterministically.

---

## 2. When you need this at all

If the whole chat lives in **one partition with one leader** (script 12 Part A),
you don't need vectors. The leader's log already puts every write in a total
order. Four "simultaneous" answers are simply committed one after another, and
every follower replays them in that order. Concurrency is settled by whoever
commits first.

Vectors are needed when **no single log sees every write**:

- each user writes to their own partition or shard (as in this demo);
- multi-leader replication, e.g. each user writes to the nearest datacenter;
- leaderless replication (Dynamo-style), or offline-first clients that sync later.

To build that here, **each participant gets their own partition**, and every
partition is a **separate replication cluster**: `poons`, `alice`, `bob`, `carol`,
`dave`, each with its own leader, sync replica and async read replica. That's 15
PostgreSQL containers, defined in `partitions/docker-compose.yml`, which is
separate from the main three-node cluster used by scripts 01–12. The five
clusters share no leader and no WAL, so nothing orders messages across
partitions except their vectors. Apps read each partition from its async read
replica, and the script makes **Bob's** read replica lag.

See [partitioned_cluster.md](partitioned_cluster.md) for the topology, ports, and
how to start, check and reset it.

```
                 poons    alice    bob      carol    dave
  leader           ●        ●        ●        ●        ●     writes · Carol's app reads here
  sync replica     ●        ●        ●        ●        ●     durability only, not read
  async replica    ●        ●        ● ⏳     ●        ●     everyone else reads here; Bob's lags
                 └──────── five separate clusters: no shared leader, no shared WAL ────────┘
```

---

## 3. The data model

```sql
CREATE TABLE chat_log (
  run_id     TEXT,          -- isolates each run
  part       TEXT,          -- partition = the writer's own log
  seq        INT,           -- position in that partition: 1, 2, 3, ...
  author     TEXT,
  body       TEXT,
  vv         JSONB,         -- version vector {partition: seq}
  written_at TIMESTAMPTZ DEFAULT clock_timestamp(),
  PRIMARY KEY (run_id, part, seq)
);
```

Every partition leader has this table (created by `partitions/init.sql`), and
each one only ever holds rows written by its own writer. The vector is stored
**on the message row**. Like `depends_on_lsn` in script 12,
it has to travel with the data, so every reader on any device can check it. The
script prints vectors in a fixed order, `[P A B C D]`:

```
  C2 [P1 A1 B1 C2 D1]   = "this is Carol's 2nd message, written after she had seen
                           Poons' 1st, Alice's 1st, Bob's 1st and Dave's 1st"
```

### Where the "knows" vector lives: script 13 vs a real chat app

There are two kinds of vector, and they live in different places:

- **A message's `vv`** is stored in the database, in its `chat_log` row. It's
  written once by the `INSERT` and never updated.
- **A person's "knows" vector** is the highest message number their screen shows
  from each partition. It belongs to that person's **device**, not to the
  database.

In a real chat app, each user's browser or phone keeps its own "knows" vector in
memory and updates it as messages arrive. Script 13 has no real devices. **One
Python process plays all five users' devices**, and there is **no backend**: the
script talks straight to the databases with `docker exec psql`.

So the script doesn't keep a "knows" vector per user. It **rebuilds it from
scratch** every time it needs one:

1. `screen(person)` reads every row of this run from that person's read path
   (`screen_reads()`): Carol from the five leaders, everyone else from the read
   replicas, and everyone's own partition from its leader.
2. `causal_deliver()` starts with an empty vector, `knows = {p: 0 for p in PARTS}`,
   runs the delivery check over those rows, and raises `knows` for each row it
   shows.
3. The caller keeps the result only as a local variable, for example
   `shown, held, knows = screen("dave")`, and drops it after that step.
4. When that person writes, `write(part, body, knows)` copies it into the new row
   (`vv = dict(knows)`, plus one in their own slot). That `vv` is the only place
   a "knows" vector is ever saved.

The only per-user state the script keeps across steps is `next_seq`, each
writer's message counter.

| | Script 13 | Real chat app |
|---|---|---|
| Who plays the user's device | the Python script, for all five users | each user's browser or phone |
| Where "knows" lives | a local variable, rebuilt by `screen(person)` each time it's needed | the app's memory (optionally saved on the device, e.g. `localStorage`), updated as each row arrives |
| Held-back rows | worked out again on every rebuild | kept in a list on the device and re-checked when new rows arrive |
| How rows reach the device | the script polls the databases directly | a backend pushes them, e.g. over a WebSocket (see "Between Step 2 and Step 3" below) |
| Backend | none | receives messages, runs the `INSERT` on the right partition leader, pushes new rows to open chats |
| How "knows" reaches the database | `write()` copies it into the new row's `vv` | the app sends it with the message, and the backend stores it as the row's `vv` |

**Why rebuilding gives the same answer.** The delivery check is deterministic: the
same rows always give the same screen and the same "knows" vector. Each person
always reads from the same nodes, and replicas only move forward, so a rebuild
can never "un-see" a message. That makes rebuilding from the database equivalent
to the step-by-step updates a real device does. The script takes the shortcut
because it keeps the code short. The animation
([version_vectors_animation.html](version_vectors_animation.html)) shows the
real-app version.

---

## 4. Step by step: how a vector is built

Each write follows three rules:

| Rule | What happens | Code |
|---|---|---|
| **Read** | The participant's app reads the chat. Their **"knows" vector** is, for each partition, the highest `seq` their screen shows. | `screen(person)` → `knows` |
| **Tick** | They write to their own partition and add one to their own counter. | `seq = next_seq[part]` |
| **Attach** | The new message's vector is the "knows" vector with their own entry set to the new `seq`. | `vv = dict(knows); vv[part] = seq` |

Each person's screen reads from a fixed place, as in the animation
(`screen_reads()` in the script):

| Person | Reads from |
|---|---|
| Carol | every partition's **leader** (`FROM_LEADER`) |
| Mr. Poons, Alice, Bob, Dave | every partition's **async read replica** (`READ_FROM`); Bob's lags |
| Everyone, for their **own** partition | their own partition's **leader**. An app always shows what you sent. |

Here is the walkthrough, using real output from the script. Commit times and
sample counts differ on every run.

### Step 1 — the question

Mr. Poons has seen nothing (`[P0 A0 B0 C0 D0]`). He ticks his own counter:

```
  P1 [P1 A0 B0 C0 D0]  Mr. Poons: How far into the future can you see, Mrs. Cake?
```

### Step 2 — four answers at the same instant

Four threads each **read** the chat (all four see only `P1`), then wait at a
`threading.Barrier`. Once all four have arrived, the barrier releases them
together and they write within a few milliseconds of each other:

```
  Alice screen shows P1   → knows [P1 A0 B0 C0 D0]
  ...
  A1 [P1 A1 B0 C0 D0]  committed 08:34:39.582  Alice: About ten seconds, I think.
  B1 [P1 A0 B1 C0 D0]  committed 08:34:39.577  Bob: Ten seconds usually, it's in the book.
  C1 [P1 A0 B0 C1 D0]  committed 08:34:39.577  Carol: Isn't it a whole minute?
  D1 [P1 A0 B0 C0 D1]  committed 08:34:39.589  Dave: No idea, I'd like to know too.
```

Bob and Carol even share the same millisecond. Commit timestamps say nothing
about who replied to whom. The vectors do: each answer has a `1` only in its own
slot and in `P`, so **none of them knew about the others**.

The script then queries each node for Bob's answer, which shows where the lag
actually is:

```
  Where is Bob's answer B1 right now? (queried on each node of Bob's partition)
    leader         part_bob_leader    ✓ has B1   ← committed: the write is finished
    sync replica   part_bob_sync      ✓ has B1   ← the leader waited for it before committing
    read replica   part_bob_async     ✗ no B1    ← received, applied 6s later; apps read Bob's log here
```

### Between Step 2 and Step 3 — how the answers reach everyone's screen

First, the stored vectors **never change**. A message's `vv` is written once, by
its `INSERT`, and stays the permanent record of what its author had seen. What
changes as messages arrive is each person's **"knows" vector**, which lives in
their **app's memory**, not in the database.

Script 13 moves data by polling with `psql`. A real chat app would move the same
data like this (the animation shows each hop):

```
  Alice's app          Chat backend            Leader (chat_log)        Replicas
  ───────────          ────────────            ─────────────────        ────────
  1. vv = knows + 1
     {"part":"alice","seq":1,"body":…,"vv":{"P":1,"A":1}}
       ── WebSocket ──►
                       2. INSERT INTO chat_log (part, seq, body, vv) …
                          ── SQL ─────────────►  row A1, vv [1 1 0 0 0]
       ◄── ack: sent ──     (commit)              (written once, never updated)
                                                 3. WAL ───────────────►  fast: applied in ms
                                                                         slow: received, applied 6 s later
                       4. NOTIFY new_message
                          for each open chat:
                          SELECT … WHERE part = :log AND seq > :highest_seen
                          on THAT person's read copy (leader for Carol,
                          replicas for everyone else; Bob's log → slow replica)
       ◄── push rows ──
  5. for each row: show it if its vv's
     dependencies are on screen, else hold it;
     knows = highest seq shown per log
     (Alice: [1 1 0 0 0] → [1 1 0 1 1])
```

| Hop | Where it runs | What is stored where |
|---|---|---|
| 1. Build and send | the browser | the new message's `vv` is computed from the app's in-memory "knows" vector |
| 2. Insert and acknowledge | backend → leader | one new row per message, `vv` in its JSONB column, immutable |
| 3. Replicate | leader → replicas | an identical copy of each row, `vv` included |
| 4. Notify and push | backend ← each person's read copy → WebSocket | nothing new is stored; rows are read and pushed |
| 5. Deliver | the browser | only the app's in-memory "knows" vector changes |

So after step 5, Alice's app holds `knows = [1 1 0 1 1]`, while the row for her
answer still says `[1 1 0 0 0]`. Both are correct. The row records what she had
seen **when she wrote A1**. The "knows" vector records what she has seen **now**,
and it becomes the `vv` of her **next** message.

Different screens get different rows at the same moment because step 4 reads
from **each person's read copy**. Carol's copy is the leader, so she gets B1
immediately. Mr. Poons, Alice and Dave read Bob's log from the slow replica, so
B1 isn't returned yet. The backend just pushes it on a later check, once the
replica has applied it.

### Step 3 — Carol replies after seeing everyone

Carol's app reads from the leader, so it shows all four answers. Her "knows"
vector becomes the **element-wise max** (merge) of everything her screen shows:

```
  Carol's screen shows P1 A1 B1 C1 D1 → knows [P1 A1 B1 C1 D1]
  C2 [P1 A1 B1 C2 D1]  Carol: Bob's right, it's ten seconds. I was wrong.
  Ordering comparison B1 vs C2: before → C2 must sit below B1 on every screen,
  and no screen may show C2 until it shows B1.
```

`B1` in her vector is the recorded fact that **C2 happened after B1**.

> **How can Carol see B1 if Bob's replica is slow?** Bob's `INSERT` finished in
> Step 2, on the **leader**, at `08:34:39.577`, at the same moment as the other three
> answers. A write is done once the leader commits it. The lag lives only in the
> **copy** that readers use for Bob's partition:
>
> ```
>   08:34:39.577  Bob's INSERT commits on the leader          → B1 exists
>   +few ms       WAL streamed to part_bob_async              → B1 received, not applied
>   +~0.1 s       Carol's app reads from the LEADER           → sees B1 ✓
>   +~0.2 s       Dave's app reads through the replicas       → B1 missing ✗
>   ≈ 08:34:45.6  replica applies B1 (recovery_min_apply_delay = 6s) → readers see B1
> ```
>
> In the script, `screen("carol")` reads with `FROM_LEADER`, which sends each
> partition's read to that partition's leader. Dave's screen and the observer read
> with `READ_FROM`, which sends each partition's read to its async read replica,
> and Bob's (`part_bob_async`) is the lagging one. So two people can see different
> things at the same moment. The vectors record exactly what each of them saw.

### Step 4 — Dave replies with a partial view

Dave's app reads through the followers. Bob's partition lags, so `B1` is not
visible. `C2` **is** on the fresh follower, but it fails the **delivery check**
(section 5): its vector needs `B1`. So it is **held back**, and Dave's screen
shows only what is causally complete. The script prints the check slot by slot:

```
  Dave's screen shows P1 A1 C1 D1   held back: C2

  Delivery check in Dave's app: can C2 [P1 A1 B1 C2 D1] be shown?
    log  C2 needs  Dave knows   test
    P    1         1            1 ≤ 1?                                           ✓
    A    1         1            1 ≤ 1?                                           ✓
    B    1         0            1 ≤ 0?                                           ✗
    C    2         1            next in Carol's log? shown 1, so the next is 2   ✓
    D    1         1            1 ≤ 1?                                           ✓
    → ✗ HOLD C2 back: it needs B1, which isn't on
      Dave's screen yet. The app re-checks it whenever new rows arrive.

  Dave writes D2 [P1 A1 B0 C1 D2]  Dave: Agree with Alice.
  B0 in D2's vector: Dave never saw Bob's answer. Ordering comparison:
    B1 vs D2: concurrent   C2 vs D2: concurrent
  So D2 doesn't have to wait for B1, and every screen can show it now.
```

> **Why holding back matters for writers too.** If Dave had been shown `C2`, his
> vector would include `C2`, and through it Bob's answer, which he never saw. A
> participant's vector must describe what they were **actually shown**, so the
> same delivery rule protects readers and writers.

### Step 5 — every person's screen while B1 is still lagging

The script reads each person's screen from their own read places:

```
  Mr. Poons (followers)  P1 A1 C1 D1 D2       held: C2    knows [P1 A1 B0 C1 D2]
  Alice     (followers)  P1 A1 C1 D1 D2       held: C2    knows [P1 A1 B0 C1 D2]
  Bob       (followers)  P1 A1 B1 C1 D1 D2 C2 held: -     knows [P1 A1 B1 C2 D2]
  Carol     (leader   )  P1 A1 B1 C1 D1 D2 C2 held: -     knows [P1 A1 B1 C2 D2]
  Dave      (followers)  P1 A1 C1 D1 D2       held: C2    knows [P1 A1 B0 C1 D2]
```

The same row gets the same rule but a different result. Bob reads through the
followers too, but `B1` is his own message, so his app has it and `C2` passes
the delivery check there (the script prints Bob's check as well). Carol reads
from the leader. The other three hold `C2`.

### Step 6 — the observer, and the re-check

An observer polls through the followers, like Mr. Poons, Alice and Dave do. It
prints a NAIVE view (commit-time order, no checks) next to the CAUSAL one; see
section 6 for that timeline. Once `B1` reaches the slow follower, the script
re-runs the delivery check on the `C2` that Alice's app was holding. This time
the B slot passes (`1 ≤ 1 ✓`), so `C2` is shown.

### Step 7 and Result — ordering, and five identical screens

Step 7 prints the ordering comparison for every pair (section 5b). The result
sorts by Σ and checks that **all five screens** show the same list:

```
  Mr. Poons screen: P1 A1 B1 C1 D1 D2 C2
  ...
  Dave      screen: P1 A1 B1 C1 D1 D2 C2
  ✅ all five screens identical
```

| Script step | Animation steps |
|---|---|
| 1 | 2 |
| 2 (incl. "where is B1") | 3–8, 12 |
| 3 | 13 |
| 4 | 14–15 |
| 5 | 15 (the five screens) |
| 6 | 16–17 |
| 7 + Result | 11, 18 |

---

## 5. Where vectors get compared, and what each comparison decides

Vectors are compared in two places. Both run **inside each person's app**. In this
design the backend and the database never compare vectors; they only store and
move them.

| | 1. Delivery check | 2. Ordering comparison |
|---|---|---|
| Question | Can I show this row yet? | Which of these two messages goes first? |
| Compares | an incoming row's `vv` with the app's own "knows" vector | two messages' `vv` with each other |
| When | every time a row arrives, and again for held rows when new rows arrive | when the app places messages on screen |
| Outcome | **show** it now, or **hold** it back until what it depends on arrives | **X → Y**: X must stay above Y. **X ‖ Y**: either order is fine, so every app uses the same tie-break (Σ, then name) |
| In the code | `causal_deliver()` (section 6) | `compare()` (section 5b) and `canonical()` (section 7) |

A worked delivery check: C2 (`vv = [P1 A1 B1 C2 D1]`) arriving at two apps.

```
  log   C2 needs   Alice knows   Bob knows
  P        1           1 ✓          1 ✓
  A        1           1 ✓          1 ✓
  B        1           0 ✗          1 ✓      ← Alice's screen has no Bob message yet
  C        2           1 ✓ (next)   1 ✓ (next)
  D        1           1 ✓          1 ✓
           →  Alice: HOLD C2          Bob: SHOW C2
```

When B1 later reaches Alice's app, her app re-runs the check on C2. Now B
passes, and C2 appears.

The animation shows both comparisons in action (steps 9–11, 14 and 17).

## 5b. Comparing two vectors: happens-before vs concurrent

For two vectors `a` and `b` (a missing entry counts as 0):

| Condition | Meaning |
|---|---|
| `a[k] ≤ b[k]` for every `k`, and they're not equal | **a happened before b** (b's author knew about a) |
| `b[k] ≤ a[k]` for every `k`, and they're not equal | **b happened before a** |
| some entries bigger on each side | **concurrent**: neither author knew about the other |

```python
def compare(a, b):
    a_le_b = all(a.get(p, 0) <= b.get(p, 0) for p in PARTS)
    b_le_a = all(b.get(p, 0) <= a.get(p, 0) for p in PARTS)
    if a_le_b and b_le_a: return "equal"
    if a_le_b:            return "before"
    if b_le_a:            return "after"
    return "concurrent"
```

Worked examples from the run:

```
  B1 [P1 A0 B1 C0 D0]   vs   C2 [P1 A1 B1 C2 D1]
     every entry of B1 ≤ C2's                         → B1 happened before C2

  B1 [P1 A0 B1 C0 D0]   vs   D2 [P1 A1 B0 C1 D2]
     B: 1 > 0   but   A: 0 < 1                         → concurrent

  C2 [P1 A1 B1 C2 D1]   vs   D2 [P1 A1 B0 C1 D2]
     B,C bigger in C2   but   D bigger in D2           → concurrent
```

Step 6 of the script prints the full relation, computed only from the vectors:

```
         P1  A1  B1  C1  D1  D2  C2
     P1   ·   →   →   →   →   →   →
     A1   ←   ·   ‖   ‖   ‖   →   →
     B1   ←   ‖   ·   ‖   ‖   ‖   →
     C1   ←   ‖   ‖   ·   ‖   →   →
     D1   ←   ‖   ‖   ‖   ·   →   →
     D2   ←   ←   ‖   ←   ←   ·   ‖
     C2   ←   ←   ←   ←   ←   ‖   ·
```

Read row `B1`: it happened before `C2` (→) and is concurrent (‖) with `D2`,
because Dave never saw it.

---

## 6. Causal delivery: when a reader may show a message

A reader collects whatever its followers return, then shows message `m` from
partition `p` only when:

1. **It is next in its own partition:** `m.seq == shown[p] + 1`, so there are no
   gaps within a writer's own messages; and
2. **Its dependencies are already shown:** `shown[k] ≥ m.vv[k]` for every other
   partition `k`.

It repeats until nothing more can be delivered. Messages that are left over are
**held back** until a later read brings in what they depend on.

```python
if m["seq"] == seen[p] + 1 and all(
        seen[k] >= m["vv"].get(k, 0) for k in PARTS if k != p):
    deliver(m)
```

The delivered set is always **causally closed**: if a message is shown, everything
it depends on is shown too. That is consistent prefix reads extended to many
writers. Step 5 of the script compares this with a naive reader:

```
  t+ 0.2s
    NAIVE   P1 C1 A1 D1 C2⚠ D2   ⚠ = shown before what it replies to
    CAUSAL  P1 A1 C1 D1 D2   held back: C2 needs B1
  t+ 5.9s
    NAIVE   P1 B1 C1 A1 D1 C2 D2
    CAUSAL  P1 A1 B1 C1 D1 D2 C2
```

For about 6 seconds, the naive reader shows *"Bob's right"* with no Bob message
anywhere. The causal reader holds it back until `B1` arrives.

---

## 7. Ordering: the same order for every reader

Causality gives only a **partial** order. It says `B1` comes before `C2`, but
nothing about `A1` vs `B1`. A chat window needs a **total** order, and every
reader must pick the **same** one. The script sorts by:

```python
sorted(msgs, key=lambda m: (sum(m["vv"].values()), m["part"]))
```

**Why the sum respects causality.** If `a → b`, then `b`'s vector is ≥ `a`'s in
every entry and strictly greater in at least one (the author's own tick). So
`sum(b) > sum(a)`, and a message can never sort above something it depends on.
Equal sums can only belong to concurrent messages, and the partition name breaks
those ties the same way for everyone.

```
   P1 [P1 A0 B0 C0 D0] Σ=1  Mr. Poons
   A1 [P1 A1 B0 C0 D0] Σ=2  Alice      ┐
   B1 [P1 A0 B1 C0 D0] Σ=2  Bob        │ concurrent → tie broken by name
   C1 [P1 A0 B0 C1 D0] Σ=2  Carol      │
   D1 [P1 A0 B0 C0 D1] Σ=2  Dave       ┘
   D2 [P1 A1 B0 C1 D2] Σ=5  Dave: Agree with Alice.        ┐ concurrent; any order
   C2 [P1 A1 B1 C2 D1] Σ=6  Carol: Bob's right, ...        ┘ is valid, Σ picks one
```

The script finishes by checking that a reader going through the lagging followers
and a reader going to the leader compute **identical** orders.

> **The cost.** In the CAUSAL timeline above, `B1` lands **between** messages
> already on screen (`A1 … C1`) when it finally arrives. A deterministic order
> over concurrent messages means a late message can be inserted above ones you
> have already read. Real chat apps either accept that, append in delivery order
> (each reader then sees concurrent messages in a different order, which is still
> causally correct), or route the conversation through **one** leader or sequencer
> to get a single total order (script 12 Part A).

---

## 8. Version vectors in the book vs here

In *DDIA*, **version vectors** appear in leaderless replication. Each replica
keeps one counter per replica for a **key**, so that concurrent writes to the
same key can be detected and kept as siblings. This demo uses the same structure,
one counter per writer compared element-wise, to track **causal dependencies
between messages**. That use is often called a *vector clock*. The comparison
rules, the merge (element-wise max) and the "concurrent = neither dominates" test
are identical.

---

## 9. How to run and test

**Prerequisites:** **Python 3** on the host, and the **five-partition cluster
already running**. That's `partitions/docker-compose.yml`, not the main
`docker-compose.yml`.

> **The script does not start the database.** It doesn't run `docker compose` and
> doesn't create any containers. It connects to the running `part_*` containers
> through `docker exec psql`. Before doing anything, it checks that all five
> leaders are up with both replicas streaming. If not, it lists what's wrong,
> prints the start commands below, and exits with status 1.

Start the cluster and wait until every partition has both replicas streaming
(about 30 seconds the first time):

```bash
docker compose -f partitions/docker-compose.yml up -d
until bash partitions/check_partitions.sh >/dev/null 2>&1; do sleep 2; done
bash partitions/check_partitions.sh   # expect "5 of 5 partitions have both replicas streaming."
```

It runs independently of the main cluster, so you don't need to stop or reset
that one. The script uses only the Python standard library. Inside the running
cluster, it only inserts `chat_log` rows (the table comes from
`partitions/init.sql`), and it sets and then clears the replay delay on
`part_bob_async`.

```bash
python3 scripts/13_demo_concurrent_answers_version_vectors.py      # Bob's partition lags 6s
python3 scripts/13_demo_concurrent_answers_version_vectors.py 10   # lag in seconds
```

What it prints, step by step:

| Step | Shows |
|---|---|
| Setup | the cluster check, each partition's leader and read replica, and where each person's app reads |
| 1 | the question and its vector |
| 2 | each answerer's screen and "knows" vector, the four answers' vectors and commit times, the pairwise checks (all `concurrent`), and where B1 is on each node |
| 3 | Carol's screen, her merged "knows" vector, her reply `C2`, and the ordering comparison B1 → C2 |
| 4 | Dave's screen, the slot-by-slot delivery check that holds `C2`, his reply `D2`, and that `D2` is concurrent with `B1` and `C2` |
| 5 | all five screens while B1 lags, and Bob's delivery check that passes `C2` |
| 6 | NAIVE vs CAUSAL timeline while Bob's partition catches up, then Alice's re-check that releases `C2` |
| 7 + Result | the ordering matrix, the canonical order, and a check that all five screens are identical |

✅ **Pass criteria**

- Step 2: all six pairs are `concurrent`, and B1 is `✓` on `part_bob_leader` and
  `part_bob_sync` but `✗` on `part_bob_async`.
- Step 4: `held back: C2`, its check ends with `✗ HOLD C2`, and `D2` is
  `concurrent` with `B1` and `C2`.
- Step 5: Mr. Poons, Alice and Dave hold `C2`; Bob and Carol show it.
- Step 6: NAIVE shows `C2⚠` in at least one sample; CAUSAL never shows `C2`
  before `B1`; Alice's re-check ends with `✓ SHOW C2`.
- Result: `✅ all five screens identical`.

If Step 4 or Step 5 does not show `C2` held back, Bob's read replica caught up
too fast. Re-run with a larger lag, e.g. `10`.

### Inspecting it by hand

Each partition's rows live on its own leader, so you read them partition by
partition:

```bash
# The latest run's id (every run uses one id across all five partitions)
RUN=$(docker exec part_poons_leader psql -U postgres -d demo -t -A -c "SELECT max(run_id) FROM chat_log;")

# The vectors as stored, partition by partition
for p in poons alice bob carol dave; do
  docker exec part_${p}_leader psql -U postgres -d demo -t -A -c \
    "SELECT part, seq, author, vv FROM chat_log WHERE run_id = '$RUN' ORDER BY seq;"
done

# Did B1 happen before C2? They live in different clusters, so fetch both
# vectors and compare them (every key of B1 <= the same key in C2)
B1=$(docker exec part_bob_leader   psql -U postgres -d demo -t -A -c "SELECT vv FROM chat_log WHERE run_id = '$RUN' AND seq = 1;")
C2=$(docker exec part_carol_leader psql -U postgres -d demo -t -A -c "SELECT vv FROM chat_log WHERE run_id = '$RUN' AND seq = 2;")
docker exec part_poons_leader psql -U postgres -d demo -t -A -c \
  "SELECT bool_and(coalesce(('$C2'::jsonb ->> k)::int, 0) >= ('$B1'::jsonb ->> k)::int)
   FROM jsonb_object_keys('$B1'::jsonb) k;"                            # → t
```

### Cleanup and reset

The script removes the replay delay in a `finally` block, which also runs on
Ctrl-C. Bob's read replica then catches up by itself.

> **Reset:** ✅ not needed. Only `chat_log` rows remain. If an interrupted run left
> Bob's read replica lagging, clear the delay:
> `docker exec part_bob_async psql -U postgres -d demo -c "ALTER SYSTEM SET recovery_min_apply_delay = '0'" -c "SELECT pg_reload_conf();"`
>
> To stop the five partitions: `docker compose -f partitions/docker-compose.yml down`
> (add `-v` to delete their data too).
