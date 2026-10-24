# Consistent Prefix Reads — How to Test

**Scripts:** `scripts/11_demo_consistent_prefix_violation.sh` (the problem) and
`scripts/12_demo_consistent_prefix_guarantee.sh` (two fixes)

**Book section:** *DDIA*, Replication → Problems with Replication Lag →
**Consistent Prefix Reads**

> *"This guarantee says that if a sequence of writes happens in a certain order,
> then anyone reading those writes will see them appear in the same order."*

---

## 1. The anomaly in one picture

Mr. Poons asks a question. Mrs. Cake answers it. The answer is **causally after**
the question: it couldn't exist without it. If the question and the answer sit
in **different partitions** and those partitions replicate with different lag,
an observer can see the answer first:

```
  LEADER history          Q ───────── A                  (Q committed before A)

  partition "questions"   follower lags 5s ···········Q
  partition "answers"     follower is fresh      A

  observer reads both     ─────────── [ A only ] ────── [ Q + A ]
                                        ▲
                     "About ten seconds usually, Mr. Poons."
                      ...answer to WHAT? Nobody has asked yet.
```

Each follower is consistent **on its own**. The problem comes from **combining**
two followers that replicate independently. Their combined state never existed
on the leader.

---

## 2. Why one PostgreSQL follower can't show this

A PostgreSQL standby replays **one WAL, strictly in commit order**. Any snapshot
of a single follower is therefore a **prefix** of the leader's history. It may be
an old prefix (lag), but it is never a reordered one. A single-partition,
single-leader database gets consistent prefix reads for free.

This cluster has one leader and one WAL, so script 11 **simulates two partitions**.
Each partition's reads go to a different follower:

| Partition | Read from | Lag |
|---|---|---|
| `questions` | `pg_replica_async` (5434) | made to lag with `recovery_min_apply_delay` |
| `answers` | `pg_replica_sync` (5433) | up to date |

In a really sharded system, each partition has its own leader and log. The effect
is the same: two independent streams with different lag.

---

## 3. Prerequisites

Start from a healthy three-node cluster:

```bash
docker compose up -d
until bash scripts/01_check_replication.sh 2>/dev/null | grep -q async; do sleep 2; done
bash scripts/01_check_replication.sh   # two rows: sync + async
```

If a previous demo promoted a replica or stopped the primary (scripts 08 and 10),
reset first:

```bash
docker compose --profile newfollower down -v && docker compose up -d
```

Both scripts create their own table, `conversation`, with `CREATE TABLE IF NOT
EXISTS`, so you don't need to change `init.sql`. Each run tags its rows with a
unique `run_id`, so you can re-run the scripts as many times as you like.

---

## 4. Test 1 — see the violation (script 11)

```bash
bash scripts/11_demo_consistent_prefix_violation.sh        # defaults: 5s lag, 2s gap
bash scripts/11_demo_consistent_prefix_violation.sh 8 2    # <lag seconds> <gap seconds>
```

**What the script does**

1. Creates `conversation` on the leader and waits until **both** followers have it.
   This happens before any lag is added, so the table is present everywhere.
2. Sets `recovery_min_apply_delay` on `pg_replica_async`. The follower still
   **receives** WAL but holds back **replaying** it, which mimics a lagging partition.
3. Writes the question (`part = 'questions'`), waits `GAP` seconds, then writes the
   answer (`part = 'answers'`). Both writes go to the leader, in causal order.
4. Polls as a partitioned app would: questions from the async follower, answers
   from the sync follower.

**Expected output**

```
  t+ 0.2s  Q: (nothing yet)      A: "About ten seconds usually, Mr. Poons."   ⚠ ANSWER WITHOUT QUESTION
  t+ 0.9s  Q: (nothing yet)      A: "About ten seconds usually, Mr. Poons."   ⚠ ANSWER WITHOUT QUESTION
  t+ 1.7s  Q: (nothing yet)      A: "About ten seconds usually, Mr. Poons."   ⚠ ANSWER WITHOUT QUESTION
  t+ 2.4s  Q: (nothing yet)      A: "About ten seconds usually, Mr. Poons."   ⚠ ANSWER WITHOUT QUESTION
  t+ 3.1s  Q: "How far into the future can you see, Mrs. Cake?"  A: "About ten seconds usually, Mr. Poons."
  ...
Result — the observer saw the answer WITHOUT its question in
         4 of 12 samples.
```

**How to read it.** The answer appears **before** its question for about
`LAG − GAP` seconds (5 − 2 = 3 s by default). After that the lagging follower
replays the question and the view looks correct again. The anomaly is
**temporary**, like all replication-lag effects, but a user who reloads during
that window sees an impossible conversation.

✅ **Pass criterion:** at least one `⚠ ANSWER WITHOUT QUESTION` line. If you get
none, increase the lag (e.g. `8 2`). The window must be longer than the polling
interval.

---

## 5. Test 2 — see the guarantee (script 12)

```bash
bash scripts/12_demo_consistent_prefix_guarantee.sh        # defaults: 5s lag, 2s gap
bash scripts/12_demo_consistent_prefix_guarantee.sh 8 3    # <lag seconds> <gap seconds>
```

The lag is the same as in Test 1, but the script tries the two fixes the book
suggests.

### Part A — Put causally related writes in the same partition

> *"One solution is to make sure that any writes that are causally related to each
> other are written to the same partition."*

Both messages go to the same partition (`chat-42`). The observer reads the whole
conversation in **one query against one follower**, and it deliberately uses the
**lagging** one.

**Expected output**

```
  t+ 0.1s  (nothing yet)
  ...
  t+ 3.2s  Q ✓   A (not yet)
  t+ 3.8s  Q ✓   A (not yet)
  t+ 5.1s  Q ✓   A ✓
  ...
→ Answer-without-question seen in 0 of 12 samples.
```

**How to read it.** The follower lags the whole time, yet the observer moves
through the prefixes of the real history: *nothing → question → question +
answer*. Lag makes the view **stale**, but never **out of order**.

### Part B — Track the causal dependency explicitly

> *"There are also algorithms that explicitly keep track of causal dependencies."*

The partitions stay split exactly as in script 11. Two things change:

1. **Writer.** After the question commits, the script reads the leader's WAL
   position (`pg_current_wal_lsn()`). It stores that LSN in the answer's
   `depends_on_lsn` column, so the answer says *"I depend on everything up to LSN X"*.
2. **Reader.** Before showing an answer, the reader asks the **questions**
   follower how far it has replayed (`pg_last_wal_replay_lsn()`). If the follower
   is behind `depends_on_lsn`, the answer is **held back**.

**Expected output**

```
  t+ 0.3s  Q (not yet)   A held back — questions follower at 0/405E288 < 0/405E2B0
  t+ 1.3s  Q (not yet)   A held back — questions follower at 0/405E288 < 0/405E2B0
  t+ 2.2s  Q (not yet)   A held back — questions follower at 0/405E288 < 0/405E2B0
  t+ 3.1s  Q ✓   A ✓
  ...
→ Answer-without-question seen in 0 of 8 samples;
  the answer was held back in 3 samples while its cause was missing.
```

**How to read it.** The answer is already sitting on the fresh follower, which is
exactly the data that caused the violation in script 11. This time the reader
holds it back until the question's partition catches up, and then both appear
together.

> **Why the reader checks the replay LSN *before* reading the question.** Every
> statement on a standby takes its own snapshot. If the reader checked the LSN
> first and then read the question, the question read starts after replay passed
> the dependency, so it is guaranteed to include the question. The opposite order
> leaves a gap: the question query could miss the question, and the LSN check
> could then still pass.

✅ **Pass criterion:** the final summary shows `0 violations` for **both** parts,
and the script prints `✅ Consistent prefix reads held.`

---

## 6. Side by side

| | Script 11 | Script 12 Part A | Script 12 Part B |
|---|---|---|---|
| Where Q and A live | different partitions | **same** partition | different partitions |
| Followers read | two, independent lag | **one** | two, independent lag |
| Causal metadata | none | not needed (one ordered log) | answer carries `depends_on_lsn` |
| Can show A without Q? | **yes** ⚠ | no | no (answer held back) |
| Cost | — | limits how you partition data | extra check per read; answer shows up later |

---

## 7. Inspecting it by hand

While either script is running, or after you set the delay yourself, you can
watch both followers:

```bash
# Make the async follower lag manually
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET recovery_min_apply_delay = '10s'" -c "SELECT pg_reload_conf();"

# Latest messages on each follower
docker exec pg_replica_async psql -U postgres -d demo \
  -c "SELECT id, run_id, part, author, depends_on_lsn FROM conversation ORDER BY id DESC LIMIT 4;"
docker exec pg_replica_sync psql -U postgres -d demo \
  -c "SELECT id, run_id, part, author, depends_on_lsn FROM conversation ORDER BY id DESC LIMIT 4;"

# How far each follower has replayed
docker exec pg_replica_async psql -U postgres -d demo -c "SELECT pg_last_wal_replay_lsn();"
docker exec pg_replica_sync  psql -U postgres -d demo -c "SELECT pg_last_wal_replay_lsn();"

# Remove the lag again
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET recovery_min_apply_delay = '0'" -c "SELECT pg_reload_conf();"
```

---

## 8. Cleanup and reset

Both scripts register an `EXIT` trap that sets `recovery_min_apply_delay` back to
`0`. The trap runs even if you press Ctrl-C, and the async follower then catches
up by itself. Nothing is promoted or stopped.

> **Reset:** ✅ not needed. The only thing left behind is a few rows in the
> `conversation` table. Do a full reset
> (`docker compose --profile newfollower down -v && docker compose up -d`) only if
> you want clean data.

If an interrupted run somehow left the follower lagging, clear the delay with the
last command in section 7.
