#!/usr/bin/env bash
# DDIA — "Problems with Replication Lag → Consistent Prefix Reads" (the anomaly)
#
# "If some partitions are replicated slower than others, an observer may see the
#  answer before they see the question."
# "This guarantee says that if a sequence of writes happens in a certain order,
#  then anyone reading those writes will see them appear in the same order."
#
# A single PostgreSQL follower can NOT show this anomaly: it replays one WAL
# strictly in commit order, so it always holds a prefix of the leader's history.
# The anomaly needs several INDEPENDENT replication streams — partitions (shards),
# each with its own followers and its own lag.
#
# We simulate two partitions on top of this cluster by routing each partition's
# reads to a different follower:
#
#   partition "questions"  →  read from pg_replica_async  (made to lag)
#   partition "answers"    →  read from pg_replica_sync   (up to date)
#
# Mr. Poons asks a question, Mrs. Cake answers it (causally AFTER it). An observer
# reads the conversation the way a partitioned app would — each partition from its
# own follower — and sees the answer with no question in front of it.

set -euo pipefail

DELAY="${1:-5}"    # seconds the "questions" partition's follower lags behind
GAP="${2:-2}"      # seconds between the question and the answer
RUN="run-$(date +%s)"
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }
q()  { docker exec "$1" psql -U postgres -d demo -t -A -c "$2"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Consistent prefix reads: the VIOLATION             ║"
echo "╚══════════════════════════════════════════════════════╝"

cleanup() {
  echo ""
  echo "Cleanup — removing the artificial replay delay on the async follower..."
  docker exec pg_replica_async psql -U postgres -d demo \
    -c "ALTER SYSTEM SET recovery_min_apply_delay = '0'" \
    -c "SELECT pg_reload_conf();" >/dev/null 2>&1 || true
  echo "  Async follower will now replay normally and catch up."
}
trap cleanup EXIT

hr
echo "Step 1 — Create the conversation table on the leader and wait until both"
echo "         followers have it (before we make one of them lag)."
q pg_primary "SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS conversation (
  id             SERIAL PRIMARY KEY,
  run_id         TEXT        NOT NULL,
  part           TEXT        NOT NULL,   -- which partition the row lives in
  author         TEXT        NOT NULL,
  body           TEXT        NOT NULL,
  depends_on_lsn PG_LSN,                 -- causal dependency (used by script 12)
  written_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);" >/dev/null
for node in pg_replica_sync pg_replica_async; do
  until [ "$(q "$node" "SELECT to_regclass('conversation') IS NOT NULL;")" = "t" ]; do
    sleep 0.5
  done
done
echo "  conversation table is on the leader and both followers."

hr
echo "Step 2 — Make the 'questions' partition's follower lag"
echo "         (recovery_min_apply_delay = ${DELAY}s on pg_replica_async)."
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET recovery_min_apply_delay = '${DELAY}s'" \
  -c "SELECT pg_reload_conf();" >/dev/null
echo "  partition 'questions' → pg_replica_async (lags by ${DELAY}s)"
echo "  partition 'answers'   → pg_replica_sync  (up to date)"

hr
echo "Step 3 — The conversation, written to the leader in causal order:"
q pg_primary "INSERT INTO conversation (run_id, part, author, body) VALUES
  ('$RUN', 'questions', 'Mr. Poons', 'How far into the future can you see, Mrs. Cake?');" >/dev/null
echo "  ✎ Mr. Poons: How far into the future can you see, Mrs. Cake?"
sleep "$GAP"
q pg_primary "INSERT INTO conversation (run_id, part, author, body) VALUES
  ('$RUN', 'answers', 'Mrs. Cake', 'About ten seconds usually, Mr. Poons.');" >/dev/null
echo "  ✎ Mrs. Cake: About ten seconds usually, Mr. Poons.   (${GAP}s later)"

hr
echo "Step 4 — An observer polls the conversation, reading each partition from"
echo "         its own follower:"
echo ""
start=$(date +%s%N)
end=$(( start + (DELAY + 3) * 1000000000 ))
samples=0; violations=0
while [ "$(date +%s%N)" -lt "$end" ]; do
  question=$(q pg_replica_async "SELECT body FROM conversation WHERE run_id='$RUN' AND part='questions';")
  answer=$(q pg_replica_sync   "SELECT body FROM conversation WHERE run_id='$RUN' AND part='answers';")
  t=$(awk -v s="$start" -v n="$(date +%s%N)" 'BEGIN{printf "%4.1f", (n-s)/1e9}')
  samples=$((samples + 1))
  if [ -n "$answer" ] && [ -z "$question" ]; then
    violations=$((violations + 1))
    echo "  t+${t}s  Q: (nothing yet)      A: \"$answer\"   ⚠ ANSWER WITHOUT QUESTION"
  elif [ -n "$answer" ]; then
    echo "  t+${t}s  Q: \"$question\"  A: \"$answer\""
  elif [ -n "$question" ]; then
    echo "  t+${t}s  Q: \"$question\"  A: (nothing yet)"
  else
    echo "  t+${t}s  (nothing yet)"
  fi
  sleep 0.5
done

hr
echo "Result — the observer saw the answer WITHOUT its question in"
echo "         $violations of $samples samples."
echo ""
if [ "$violations" -gt 0 ]; then
  echo "💥 Consistent prefix violated: each follower is internally consistent,"
  echo "   but the two partitions replicate independently, so the observer's"
  echo "   combined view is not a prefix of what actually happened. To them it"
  echo "   looks like Mrs. Cake answered before anyone asked."
else
  echo "  (No violation caught this time — try a longer delay, e.g. 8.)"
fi
echo ""
echo "  See script 12 for two ways to guarantee consistent prefix reads."
