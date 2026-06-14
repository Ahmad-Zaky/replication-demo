#!/usr/bin/env bash
# Demonstrate the key difference between synchronous and asynchronous replication.
#
# Part A — Sync replica paused:
#   A write to the primary BLOCKS because the sync replica cannot acknowledge it.
#
# Part B — Async replica paused:
#   A write to the primary SUCCEEDS IMMEDIATELY; the async replica catches up
#   once it is unpaused.

set -euo pipefail

pause()   { docker pause   "$1" >/dev/null; echo "  ⏸  $1 paused"; }
unpause() { docker unpause "$1" >/dev/null; echo "  ▶  $1 unpaused"; }
hr()      { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Part A: Write blocks when SYNC replica is paused  ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Pausing pg_replica_sync — the primary can no longer get a write"
echo "acknowledgment from it, so writes will stall."
echo ""

pause pg_replica_sync

echo ""
echo "Attempting INSERT with a 4-second statement timeout..."
echo "(this will time out because the sync replica cannot respond)"
echo ""

docker exec pg_primary psql -U postgres -d demo \
  -c "SET statement_timeout = '4000ms';
      INSERT INTO events (label) VALUES ('BLOCKED by missing sync ack') RETURNING id;" \
  2>&1 || echo ""

echo ""
echo "→ Write timed out exactly as expected."
echo "  In production this protects you from silent data loss:"
echo "  if the sync replica is down, you know immediately."

hr

unpause pg_replica_sync
echo "  Sync replica is back — let's verify it's still healthy."
sleep 3

docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"

# ─────────────────────────────────────────────────────────────────────────────
hr
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Part B: Write succeeds when ASYNC replica is paused ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Pausing pg_replica_async — the primary does NOT wait for it."
echo ""

pause pg_replica_async

echo ""
echo "Inserting a row (no timeout — should return immediately)..."
echo ""

docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label) VALUES ('Succeeds with async replica paused') RETURNING id, label;"

echo ""
echo "→ Write returned immediately even though async replica is offline."
echo "  Trade-off: if the primary crashes NOW, this row could be lost"
echo "  (it hasn't reached the async replica yet)."

hr

echo "Unpausing async replica — it will now replay the missing WAL..."
unpause pg_replica_async
sleep 4

echo ""
echo "Async replica has caught up:"
docker exec pg_replica_async psql -U postgres -d demo -c \
  "SELECT id, label FROM events ORDER BY id DESC LIMIT 5;"

hr
echo "Done.  Run ./01_check_replication.sh to see final replication state."
