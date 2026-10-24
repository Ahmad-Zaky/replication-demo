#!/usr/bin/env bash
# DDIA — "Problems with Replication Lag → Consistent Prefix Reads" (the fix)
#
# "One solution is to make sure that any writes that are causally related to each
#  other are written to the same partition... There are also algorithms that
#  explicitly keep track of causal dependencies."
#
# Same setup as script 11 (the follower that serves the questions lags), but now
# the observer can never see the answer without its question:
#
#   Part A — SAME PARTITION. The question and the answer live in one partition,
#            so the observer reads the whole conversation from ONE follower. That
#            follower replays a single WAL strictly in commit order, so whatever
#            it shows is a prefix of the leader's history: nothing → question →
#            question + answer. Never answer-only — even though it lags.
#
#   Part B — TRACK THE CAUSAL DEPENDENCY. The partitions stay separate (questions
#            on the lagging follower, answers on the fresh one, exactly like
#            script 11), but the answer records the LSN of the question it depends
#            on. The reader holds the answer back until the questions follower has
#            replayed at least that LSN.

set -euo pipefail

DELAY="${1:-5}"   # seconds the lagging follower holds back replay
GAP="${2:-2}"     # seconds between the question and the answer
RUN="run-$(date +%s)"
QUESTION='How far into the future can you see, Mrs. Cake?'
ANSWER='About ten seconds usually, Mr. Poons.'
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }
q()  { docker exec "$1" psql -U postgres -d demo -t -A -c "$2"; }
elapsed() { awk -v s="$1" -v n="$(date +%s%N)" 'BEGIN{printf "%4.1f", (n-s)/1e9}'; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Consistent prefix reads: the GUARANTEE             ║"
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
echo "Setup — Create the conversation table and wait until both followers have"
echo "        it, then make pg_replica_async lag (recovery_min_apply_delay = ${DELAY}s)."
q pg_primary "SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS conversation (
  id             SERIAL PRIMARY KEY,
  run_id         TEXT        NOT NULL,
  part           TEXT        NOT NULL,   -- which partition the row lives in
  author         TEXT        NOT NULL,
  body           TEXT        NOT NULL,
  depends_on_lsn PG_LSN,                 -- causal dependency (Part B)
  written_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);" >/dev/null
for node in pg_replica_sync pg_replica_async; do
  until [ "$(q "$node" "SELECT to_regclass('conversation') IS NOT NULL;")" = "t" ]; do
    sleep 0.5
  done
done
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET recovery_min_apply_delay = '${DELAY}s'" \
  -c "SELECT pg_reload_conf();" >/dev/null
echo "  Done. pg_replica_async now replays ${DELAY}s behind the leader."

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Part A: causally related writes in ONE partition    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Both messages go to partition 'chat-42', served by the LAGGING follower"
echo "pg_replica_async. The observer reads the whole conversation from it."
echo ""
q pg_primary "INSERT INTO conversation (run_id, part, author, body)
  VALUES ('$RUN-A', 'chat-42', 'Mr. Poons', '$QUESTION');" >/dev/null
echo "  ✎ Mr. Poons: $QUESTION"
sleep "$GAP"
q pg_primary "INSERT INTO conversation (run_id, part, author, body)
  VALUES ('$RUN-A', 'chat-42', 'Mrs. Cake', '$ANSWER');" >/dev/null
echo "  ✎ Mrs. Cake: $ANSWER   (${GAP}s later)"
echo ""
echo "Observer polling pg_replica_async:"
echo ""

start=$(date +%s%N)
end=$(( start + (DELAY + 2) * 1000000000 ))
samples_a=0; violations_a=0
while [ "$(date +%s%N)" -lt "$end" ]; do
  # One query = one snapshot of one follower = one prefix of the leader's log.
  seen=$(q pg_replica_async "SELECT coalesce(string_agg(author, ',' ORDER BY id), '')
                             FROM conversation WHERE run_id='$RUN-A';")
  t=$(elapsed "$start")
  samples_a=$((samples_a + 1))
  case "$seen" in
    "")                    echo "  t+${t}s  (nothing yet)" ;;
    "Mr. Poons")           echo "  t+${t}s  Q ✓   A (not yet)" ;;
    "Mr. Poons,Mrs. Cake") echo "  t+${t}s  Q ✓   A ✓" ;;
    *)                     violations_a=$((violations_a + 1))
                           echo "  t+${t}s  saw: $seen   ⚠ NOT A PREFIX" ;;
  esac
  sleep 0.5
done
echo ""
echo "→ Answer-without-question seen in $violations_a of $samples_a samples."
echo "  The follower lagged the whole time, yet every read was a prefix of the"
echo "  real history: nothing → question → question + answer."

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Part B: separate partitions + causal dependency     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Same layout as script 11:"
echo "  partition 'questions' → pg_replica_async (lags by ${DELAY}s)"
echo "  partition 'answers'   → pg_replica_sync  (up to date)"
echo "but now the answer carries the LSN of the question it responds to."
echo ""
# The LSN right after the question committed: any follower that has replayed up
# to here is guaranteed to contain the question.
q_lsn=$(docker exec pg_primary psql -U postgres -d demo -t -A \
  -c "INSERT INTO conversation (run_id, part, author, body)
      VALUES ('$RUN-B', 'questions', 'Mr. Poons', '$QUESTION');" \
  -c "SELECT pg_current_wal_lsn();" | tail -n 1)
echo "  ✎ Mr. Poons: $QUESTION"
echo "      committed; leader WAL position after the commit = $q_lsn"
sleep "$GAP"
q pg_primary "INSERT INTO conversation (run_id, part, author, body, depends_on_lsn)
  VALUES ('$RUN-B', 'answers', 'Mrs. Cake', '$ANSWER', '$q_lsn');" >/dev/null
echo "  ✎ Mrs. Cake: $ANSWER   (${GAP}s later, depends_on_lsn = $q_lsn)"
echo ""
echo "Observer polling — answers from pg_replica_sync, questions from"
echo "pg_replica_async, and holding back any answer whose cause isn't visible:"
echo ""

start=$(date +%s%N)
end=$(( start + (DELAY + 2) * 1000000000 ))
samples_b=0; violations_b=0; held_b=0
while [ "$(date +%s%N)" -lt "$end" ]; do
  dep=$(q pg_replica_sync "SELECT depends_on_lsn FROM conversation
                           WHERE run_id='$RUN-B' AND part='answers';")
  # Order matters: check how far the questions follower has replayed FIRST, then
  # read the question. A read that starts after replay passed the dependency is
  # guaranteed to see it.
  replayed=$(q pg_replica_async "SELECT pg_last_wal_replay_lsn();")
  question=$(q pg_replica_async "SELECT body FROM conversation
                                 WHERE run_id='$RUN-B' AND part='questions';")
  t=$(elapsed "$start")
  samples_b=$((samples_b + 1))
  if [ -n "$question" ]; then qmark="✓"; else qmark="(not yet)"; fi
  if [ -z "$dep" ]; then
    show_answer=""
  elif [ "$(q pg_replica_async "SELECT '$replayed'::pg_lsn >= '$dep'::pg_lsn;")" = "t" ]; then
    show_answer=yes
  else
    show_answer=held
  fi

  if [ "$show_answer" = yes ] && [ -z "$question" ]; then
    violations_b=$((violations_b + 1))
    echo "  t+${t}s  Q (not yet)   A ✓   ⚠ ANSWER WITHOUT QUESTION"
  elif [ "$show_answer" = yes ]; then
    echo "  t+${t}s  Q ✓   A ✓"
  elif [ "$show_answer" = held ]; then
    held_b=$((held_b + 1))
    echo "  t+${t}s  Q $qmark   A held back — questions follower at $replayed < $dep"
  else
    echo "  t+${t}s  Q $qmark   A (not yet)"
  fi
  sleep 0.5
done
echo ""
echo "→ Answer-without-question seen in $violations_b of $samples_b samples;"
echo "  the answer was held back in $held_b samples while its cause was missing."

hr
echo "Result:"
echo "  Part A (same partition):          $violations_a violations in $samples_a samples"
echo "  Part B (causal dependency check):  $violations_b violations in $samples_b samples"
echo ""
if [ "$violations_a" -eq 0 ] && [ "$violations_b" -eq 0 ]; then
  echo "✅ Consistent prefix reads held. Compare with script 11, where the same lag"
  echo "   showed the answer before the question. The lag didn't go away — the"
  echo "   reads just never expose a state that didn't happen."
else
  echo "💥 Unexpected: a non-prefix state was observed. Re-run with a longer delay."
fi
