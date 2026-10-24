#!/usr/bin/env python3
"""DDIA — "Consistent Prefix Reads" + "Detecting Concurrent Writes" (version vectors)

"There are also algorithms that explicitly keep track of causal dependencies."
"Two operations are concurrent if neither happens before the other (i.e., neither
 knows about the other)."

Mr. Poons asks a question in a chat. Four readers — Alice, Bob, Carol and Dave —
answer it AT THE SAME INSTANT, then two of them reply to what they saw.

Each participant writes to their OWN partition (one log per writer, as in a
multi-leader or per-user-sharded system), so no single log orders the messages.

Two kinds of vector appear:
  * a message's vv — stored in its row, written once by the INSERT, never
    updated: what the author had seen when they wrote it;
  * a person's "knows" vector — kept by their app (here: computed from what their
    screen shows): the highest message number shown from every log. When they
    write, it becomes the new message's vv (plus one in their own slot).

Vectors are compared in two places, both inside each person's app:
  1. the DELIVERY CHECK — an incoming row's vv against the app's "knows" vector
     → show the row now, or hold it back until what it depends on arrives;
  2. the ORDERING COMPARISON — two messages' vv against each other
     → one must stay above the other (→), or either order is fine (‖).

The partitions are REAL: partitions/docker-compose.yml runs five independent
replication clusters, one per writer, each with its own leader, sync replica and
async read replica (15 containers). They share no leader and no WAL, so nothing
but the version vectors relates their messages. Apps read each partition from its
async replica; the script makes Bob's lag (recovery_min_apply_delay). Carol's app
reads every partition from its leader. Your own messages always show on your own
screen (read from your own partition's leader).

Start that cluster first — this script does not start any containers:
  docker compose -f partitions/docker-compose.yml up -d
  until bash partitions/check_partitions.sh >/dev/null 2>&1; do sleep 2; done

The script polls with psql; it has no WebSockets or backend. The animation in
docs/version_vectors_animation.html shows how a real chat app would move the same
data, and docs/concurrent_answers_version_vectors.md explains every step.

Python 3 standard library only; talks to the cluster through `docker exec psql`.
Usage: python3 scripts/13_demo_concurrent_answers_version_vectors.py [lag_seconds]
"""

import json
import subprocess
import sys
import threading
import time

DELAY = int(sys.argv[1]) if len(sys.argv) > 1 else 6   # Bob's follower lag (s)
RUN = f"run-{int(time.time())}"

PARTS = ["poons", "alice", "bob", "carol", "dave"]      # one partition per writer
AUTHOR = {"poons": "Mr. Poons", "alice": "Alice", "bob": "Bob",
          "carol": "Carol", "dave": "Dave"}

LAGGING = "bob"                                          # its read replica lags


def leader(part):
    return f"part_{part}_leader"


def sync_replica(part):
    return f"part_{part}_sync"


def read_replica(part):
    return f"part_{part}_async"


# Where each partition is read from: its async replica, or its leader.
READ_FROM = {p: read_replica(p) for p in PARTS}
FROM_LEADER = {p: leader(p) for p in PARTS}

next_seq = {p: 1 for p in PARTS}   # each writer's own counter in its own partition
delay_applied = False              # so cleanup only resets a delay we actually set


def hr():
    print("\n────────────────────────────────────────────────\n")


def banner(title):
    print("╔══════════════════════════════════════════════════════╗")
    print(f"║  {title:<52}║")
    print("╚══════════════════════════════════════════════════════╝")


def psql(container, sql):
    out = subprocess.run(
        ["docker", "exec", container, "psql", "-U", "postgres", "-d", "demo",
         "-t", "-A", "-q", "-v", "ON_ERROR_STOP=1", "-c", sql],
        check=True, capture_output=True, text=True)
    return out.stdout.strip()


def lit(s):
    return "'" + s.replace("'", "''") + "'"


# ── Version vector helpers ───────────────────────────────────────────────────

def fmt(vv):
    """[P1 A0 B0 C0 D0] — one counter per partition, in a fixed order."""
    return "[" + " ".join(f"{p[0].upper()}{vv.get(p, 0)}" for p in PARTS) + "]"


def label(msg):
    return f"{msg['part'][0].upper()}{msg['seq']}"


def labels(msgs):
    return " ".join(label(m) for m in msgs) or "(nothing)"


def compare(a, b):
    """'before' if a happened before b, 'after' if b before a, else 'concurrent'."""
    a_le_b = all(a.get(p, 0) <= b.get(p, 0) for p in PARTS)
    b_le_a = all(b.get(p, 0) <= a.get(p, 0) for p in PARTS)
    if a_le_b and b_le_a:
        return "equal"
    if a_le_b:
        return "before"
    if b_le_a:
        return "after"
    return "concurrent"


def knows_of(msgs):
    """A "knows" vector: the highest seq shown from each partition."""
    knows = {p: 0 for p in PARTS}
    for m in msgs:
        knows[m["part"]] = max(knows[m["part"]], m["seq"])
    return knows


# ── Reading ──────────────────────────────────────────────────────────────────

def read(read_from):
    """Read every partition from its node (one query per partition cluster)."""
    by_node = {}
    for part, node in read_from.items():
        by_node.setdefault(node, []).append(part)
    rows = []
    for node, parts in by_node.items():
        rows += json.loads(psql(node, f"""
          SELECT coalesce(json_agg(t), '[]') FROM (
            SELECT part, seq, author, body, vv,
                   extract(epoch FROM written_at)::float8 AS ts
            FROM chat_log
            WHERE run_id = {lit(RUN)}
              AND part = ANY (ARRAY[{", ".join(lit(p) for p in parts)}])) t;"""))
    return rows


def deliverable(m, knows):
    """The delivery check: may message m be shown, given this "knows" vector?

      * it is the next one in its own partition  (m.seq == knows[own] + 1), and
      * for every OTHER partition k: knows[k] >= m.vv[k]
    """
    p = m["part"]
    return m["seq"] == knows[p] + 1 and all(
        knows[k] >= m["vv"].get(k, 0) for k in PARTS if k != p)


def causal_deliver(rows):
    """Run the delivery check until nothing more can be shown.

    Returns (shown, held_back, knows).
    """
    shown, held = [], sorted(rows, key=lambda r: (r["part"], r["seq"]))
    knows = {p: 0 for p in PARTS}
    progress = True
    while progress:
        progress = False
        for m in list(held):
            if deliverable(m, knows):
                shown.append(m)
                held.remove(m)
                knows[m["part"]] = m["seq"]
                progress = True
    return shown, held, knows


def canonical(msgs):
    """A total order every reader agrees on that respects happens-before.

    If a → b then b's vector is >= a's everywhere and > somewhere, so
    sum(b) > sum(a). Ties can only be concurrent messages; break them by
    partition name so every reader picks the same order.
    """
    return sorted(msgs, key=lambda m: (sum(m["vv"].values()), PARTS.index(m["part"])))


def missing_deps(m, present):
    have = knows_of(present)
    return [f"{k[0].upper()}{m['vv'][k]}" for k in PARTS
            if k != m["part"] and have[k] < m["vv"].get(k, 0)]


def screen_reads(person):
    """Where a person's app reads each partition from.

    Carol's app reads every partition from its leader. Everyone else's reads
    every partition from its async read replica, except their OWN partition,
    which comes from its leader: an app always shows what you sent.
    """
    if person == "carol":
        return FROM_LEADER
    return {**READ_FROM, person: leader(person)}


def screen(person):
    """What a person's screen shows right now: (shown, held_back, knows)."""
    shown, held, knows = causal_deliver(read(screen_reads(person)))
    return canonical(shown), held, knows


def explain_check(msg, knows, who):
    """Print the delivery check for one row in one person's app, slot by slot."""
    own = msg["part"]
    print(f"  Delivery check in {who}'s app: can {label(msg)} {fmt(msg['vv'])} be shown?")
    print(f"    {'log':<4} {label(msg) + ' needs':<9} {who.replace('Mr. ', '') + ' knows':<12} test")
    ok_all = True
    for k in PARTS:
        need, have = msg["vv"].get(k, 0), knows[k]
        if k == own:
            ok = have == need - 1
            test = f"next in {AUTHOR[own]}'s log? shown {have}, so the next is {have + 1}"
        else:
            ok = have >= need
            test = "needs nothing from this log" if need == 0 else f"{need} ≤ {have}?"
        ok_all = ok_all and ok
        print(f"    {k[0].upper():<4} {need:<9} {have:<12} {test:<48} {'✓' if ok else '✗'}")
    if ok_all:
        after = dict(knows)
        after[own] = msg["seq"]
        print(f"    → ✓ SHOW {label(msg)}. {who}'s \"knows\" becomes {fmt(after)}.")
    else:
        need = [f"{k[0].upper()}{msg['vv'][k]}" for k in PARTS
                if k != own and knows[k] < msg["vv"].get(k, 0)]
        print(f"    → ✗ HOLD {label(msg)} back: it needs {', '.join(need)}, which isn't on")
        print(f"      {who}'s screen yet. The app re-checks it whenever new rows arrive.")


def where_is(part, seq):
    """Is row (part, seq) on its partition's leader and on each replica right now?"""
    sql = (f"SELECT count(*) FROM chat_log WHERE run_id = {lit(RUN)} "
           f"AND part = {lit(part)} AND seq = {seq};")
    return {node: psql(node, sql) == "1"
            for node in (leader(part), sync_replica(part), read_replica(part))}


# ── Writing ──────────────────────────────────────────────────────────────────

def write(part, body, knows):
    """Write to the author's own partition LEADER. vv = what they know + own tick.

    The vv is written once, by this INSERT, and never updated afterwards.
    """
    seq = next_seq[part]
    next_seq[part] += 1
    vv = dict(knows)
    vv[part] = seq
    vv = {p: n for p, n in vv.items() if n > 0}
    at = psql(leader(part), f"""
      INSERT INTO chat_log (run_id, part, seq, author, body, vv)
      VALUES ({lit(RUN)}, {lit(part)}, {seq}, {lit(AUTHOR[part])}, {lit(body)},
              {lit(json.dumps(vv))}::jsonb)
      RETURNING to_char(written_at, 'HH24:MI:SS.MS');""")
    return {"part": part, "seq": seq, "author": AUTHOR[part], "body": body,
            "vv": vv, "at": at}


def wait_visible(wanted):
    """Wait until the given messages (e.g. {'poons': 1}) are on their read replicas."""
    while True:
        have = knows_of(read({p: READ_FROM[p] for p in wanted}))
        if all(have[p] >= n for p, n in wanted.items()):
            return
        time.sleep(0.2)


def preflight():
    """Stop with a clear message unless all 15 partition containers are ready."""
    problems = []
    for p in PARTS:
        try:
            rows = psql(leader(p), "SELECT application_name || ':' || state "
                                   "FROM pg_stat_replication ORDER BY 1;").split()
        except subprocess.CalledProcessError:
            problems.append(f"{leader(p)} is not running")
            continue
        for want in ("replica_async:streaming", "replica_sync:streaming"):
            if want not in rows:
                problems.append(f"{p}: {want.split(':')[0]} is not streaming from {leader(p)}")
    if problems:
        print("  The five-partition cluster isn't ready:")
        for msg in problems:
            print(f"    ✗ {msg}")
        print()
        print("  This script does not start containers. Start them and wait, then re-run:")
        print("    docker compose -f partitions/docker-compose.yml up -d")
        print("    until bash partitions/check_partitions.sh >/dev/null 2>&1; do sleep 2; done")
        sys.exit(1)
    print("  ✓ 5 partitions, each with a leader and 2 streaming replicas")


def set_delay(value):
    global delay_applied
    subprocess.run(["docker", "exec", read_replica(LAGGING), "psql", "-U", "postgres",
                    "-d", "demo", "-q",
                    "-c", f"ALTER SYSTEM SET recovery_min_apply_delay = '{value}'",
                    "-c", "SELECT pg_reload_conf();"],
                   check=True, capture_output=True)
    delay_applied = value != "0"


# ── The demo ─────────────────────────────────────────────────────────────────

def main():
    print()
    banner("Concurrent answers ordered by version vectors")

    hr()
    print("Setup — Check the five partition clusters, then make Bob's read replica")
    print(f"        lag ({DELAY}s on {read_replica(LAGGING)}).")
    preflight()
    set_delay(f"{DELAY}s")
    print()
    print(f"  {'partition':<10} {'leader (writes)':<20} {'read replica':<18}")
    for p in PARTS:
        print(f"  {p:<10} {leader(p):<20} {read_replica(p):<18}"
              + (f"lags {DELAY}s" if p == LAGGING else ""))
    print()
    print("  Five separate clusters: no shared leader, no shared WAL.")
    print("  Carol's app reads every partition from its leader. Everyone else's app")
    print("  reads from the read replicas. Everyone's own messages always show on")
    print("  their own screen.")

    # Step 1 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 1 — Mr. Poons asks. He knows nothing yet, so his vector is just")
    print("         one tick in his own slot:")
    q = write("poons", "How far into the future can you see, Mrs. Cake?", knows_of([]))
    print(f"  P1 {fmt(q['vv'])}  Mr. Poons: {q['body']}")
    wait_visible({"poons": 1})

    # Step 2 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 2 — Alice, Bob, Carol and Dave each READ the chat, then all four")
    print("         ANSWER at the same instant (threads released by one barrier).")
    print("         Each answer's vv = that person's \"knows\" vector + 1 in their slot.")
    print()
    answers_text = {
        "alice": "About ten seconds, I think.",
        "bob":   "Ten seconds usually, it's in the book.",
        "carol": "Isn't it a whole minute?",
        "dave":  "No idea, I'd like to know too.",
    }
    barrier = threading.Barrier(len(answers_text))
    round1, views = {}, {}

    def answer(part):
        shown, _, knows = screen(part)
        views[part] = (shown, knows)
        barrier.wait()                       # everybody writes at once
        round1[part] = write(part, answers_text[part], knows)

    threads = [threading.Thread(target=answer, args=(p,)) for p in answers_text]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    for p in answers_text:
        shown, knows = views[p]
        print(f"  {AUTHOR[p]:<5} screen shows {labels(shown):<4} → knows {fmt(knows)}")
    print()
    for p in answers_text:
        m = round1[p]
        print(f"  {label(m)} {fmt(m['vv'])}  committed {m['at']}  {m['author']}: {m['body']}")
    print()
    print("  The vv is now stored in each row and is never updated again.")
    print("  Nobody saw anybody else's answer, so no vector is ≥ another:")
    a = [round1[p] for p in answers_text]
    for i in range(len(a)):
        for j in range(i + 1, len(a)):
            print(f"    {label(a[i])} vs {label(a[j])}: {compare(a[i]['vv'], a[j]['vv'])}")
    print()
    print("  Where is Bob's answer B1 right now? (queried on each node of Bob's partition)")
    spots = where_is("bob", 1)
    mark = lambda node: "✓ has B1" if spots[node] else "✗ no B1 "
    print(f"    leader         {leader('bob'):<18} {mark(leader('bob'))}"
          "   ← committed: the write is finished")
    print(f"    sync replica   {sync_replica('bob'):<18} {mark(sync_replica('bob'))}"
          "   ← the leader waited for it before committing")
    print(f"    read replica   {read_replica('bob'):<18} {mark(read_replica('bob'))}"
          f"   ← received, applied {DELAY}s later; apps read Bob's log here")

    # Step 3 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 3 — Carol's app reads from the LEADERS, so it already shows B1.")
    print("         She replies to Bob. Her \"knows\" vector becomes C2's vv:")
    shown, _, knows = screen("carol")
    print(f"  Carol's screen shows {labels(shown)} → knows {fmt(knows)}")
    c2 = write("carol", "Bob's right, it's ten seconds. I was wrong.", knows)
    print(f"  {label(c2)} {fmt(c2['vv'])}  Carol: {c2['body']}")
    print(f"  Ordering comparison B1 vs C2: {compare(round1['bob']['vv'], c2['vv'])}"
          " → C2 must sit below B1 on every screen,")
    print("  and no screen may show C2 until it shows B1.")

    # Step 4 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 4 — Dave's app reads from the read replicas. B1 isn't there yet, and")
    print("         C2 has arrived but fails the delivery check:")
    wait_visible({"alice": 1, "carol": 2, "dave": 1})
    shown, held, knows = screen("dave")
    print(f"  Dave's screen shows {labels(shown)}   held back: {labels(held)}")
    print()
    for m in held:
        explain_check(m, knows, "Dave")
    print()
    d2 = write("dave", "Agree with Alice.", knows)
    print(f"  Dave writes {label(d2)} {fmt(d2['vv'])}  Dave: {d2['body']}")
    print(f"  B0 in D2's vector: Dave never saw Bob's answer. Ordering comparison:")
    print(f"    B1 vs D2: {compare(round1['bob']['vv'], d2['vv'])}"
          f"   C2 vs D2: {compare(c2['vv'], d2['vv'])}")
    print("  So D2 doesn't have to wait for B1, and every screen can show it now.")

    # Step 5 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 5 — Every person's screen right now (B1 still lagging):")
    print()
    wait_visible({"dave": 2})
    screens = {p: screen(p) for p in PARTS}
    for p in PARTS:
        shown, held, knows = screens[p]
        where = "leaders" if p == "carol" else "replicas"
        print(f"  {AUTHOR[p]:<9} ({where:<8})  {labels(shown):<20}"
              f" held: {labels(held) if held else '-':<4}  knows {fmt(knows)}")
    print()
    print("  Same row, same rule, different result. Bob's app has B1 (his own),")
    print("  so C2 passes there:")
    bob_shown = [m for m in screens["bob"][0] if label(m) != "C2"]
    c2_on_bob = next((m for m in screens["bob"][0] if label(m) == "C2"), None)
    if c2_on_bob:
        explain_check(c2_on_bob, knows_of(bob_shown), "Bob")

    # Step 6 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 6 — An observer polls the chat from the read replicas, like Mr. Poons,")
    print("         Alice and Dave do.")
    print("         NAIVE  = everything visible, sorted by wall-clock commit time")
    print("         CAUSAL = delivery check + canonical order")
    print()
    start = time.time()
    last, naive_bad, samples = None, 0, 0
    while time.time() - start < DELAY + 2:
        rows = read(READ_FROM)
        naive = sorted(rows, key=lambda r: r["ts"])
        broken = [m for m in naive if missing_deps(m, rows)]
        shown, held, _ = causal_deliver(rows)
        samples += 1
        naive_bad += bool(broken)
        state = (
            " ".join(label(m) + ("⚠" if m in broken else "") for m in naive),
            " ".join(label(m) for m in canonical(shown)),
            ", ".join(f"{label(m)} needs {', '.join(missing_deps(m, shown))}" for m in held),
        )
        if state != last:
            print(f"  t+{time.time() - start:4.1f}s")
            print(f"    NAIVE   {state[0]}" + ("   ⚠ = shown before what it replies to" if broken else ""))
            print(f"    CAUSAL  {state[1]}" + (f"   held back: {state[2]}" if state[2] else ""))
            last = state
        time.sleep(0.5)
    print()
    print(f"  → NAIVE showed a reply before its cause in {naive_bad} of {samples} samples;")
    print("    CAUSAL never did (it only shows causally complete prefixes).")
    print()
    print("  B1 has now reached Bob's read replica. Alice's app re-runs the delivery")
    print("  check on the C2 it was holding:")
    alice_shown = [m for m in screen("alice")[0] if label(m) != "C2"]
    explain_check(c2, knows_of(alice_shown), "Alice")

    # Step 7 ─────────────────────────────────────────────────────────────────
    hr()
    print("Step 7 — The ordering comparison for every pair, computed only from the")
    print("         vectors. Each app does this when it places messages on screen.")
    print("         → row happened before column (must stay above it)")
    print("         ‖ concurrent (either order is fine; the tie-break decides)")
    print()
    every = canonical(read(FROM_LEADER))
    print("        " + " ".join(f"{label(m):>3}" for m in every))
    for r in every:
        cells = []
        for c in every:
            rel = compare(r["vv"], c["vv"])
            cells.append({"equal": "·", "before": "→", "after": "←", "concurrent": "‖"}[rel])
        print(f"    {label(r):>3} " + " ".join(f"{x:>3}" for x in cells))

    hr()
    print("Result — every app sorts by the sum of the vector (Σ), ties by partition")
    print("         name. A reply always has a bigger Σ than what it replies to, so")
    print("         every → is kept; Σ and the name only decide between ‖ messages.")
    print()
    for m in every:
        print(f"  {label(m):>3} {fmt(m['vv'])} Σ={sum(m['vv'].values()):<2}"
              f" {m['author']}: {m['body']}")
    print()
    final = {p: " ".join(label(m) for m in screen(p)[0]) for p in PARTS}
    for p in PARTS:
        print(f"  {AUTHOR[p]:<9} screen: {final[p]}")
    print("  ✅ all five screens identical" if len(set(final.values())) == 1
          else "  ✗ screens differ (Bob's read replica still lagging?)")


if __name__ == "__main__":
    try:
        main()
    finally:
        if delay_applied:
            print()
            print(f"Cleanup — removing the artificial replay delay on {read_replica(LAGGING)}...")
            try:
                set_delay("0")
                print("  It will now replay normally and catch up.")
            except Exception:
                print("  (could not reset — run the reset command from the docs)")
