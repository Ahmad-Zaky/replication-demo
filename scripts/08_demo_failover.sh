#!/usr/bin/env bash
# Demonstrate manual failover: promote the sync replica to become the new primary.
#
# Steps:
#   1. Stop the primary (simulates a crash).
#   2. Promote pg_replica_sync → it becomes a new read/write primary.
#   3. Write to the promoted replica to confirm it now accepts writes.
#
# To restore the original cluster afterwards:
#   docker compose down -v && docker compose up -d

set -euo pipefail

hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║         Failover Demo                        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "Current state — all three nodes running:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication;"

hr

echo "Step 1 — Stopping the primary (simulating a crash)..."
docker stop pg_primary
echo "  pg_primary is down."

hr

echo "Step 2 — Promoting pg_replica_sync to new primary..."
# pg_ctl promote tells the standby to stop streaming and accept writes.
docker exec pg_replica_sync \
  gosu postgres pg_ctl promote -D /var/lib/postgresql/data
echo "  Promotion signal sent.  Waiting for it to complete..."
sleep 4

hr

echo "Step 3 — Confirm the promoted replica is no longer in recovery:"
docker exec pg_replica_sync psql -U postgres -d demo -c \
  "SELECT pg_is_in_recovery() AS still_standby, NOW() AS promoted_at;"

echo ""
echo "Step 4 — Clear the synchronous-standby requirement on the new primary."
echo "  The promoted node inherited synchronous_standby_names='replica_sync'."
echo "  As a standby that was dormant, but now that it accepts writes every"
echo "  COMMIT would block waiting for a sync standby that no longer exists,"
echo "  so we clear it (a real failover would reconfigure replication here)."
docker exec pg_replica_sync psql -U postgres -d demo -c \
  "ALTER SYSTEM SET synchronous_standby_names = ''; SELECT pg_reload_conf();"

echo ""
echo "Step 5 — Write to the new primary (should succeed now):"
docker exec pg_replica_sync psql -U postgres -d demo -c \
  "INSERT INTO events (label) VALUES ('Written to promoted primary') RETURNING id, label, written_at;"

hr

echo "Failover complete!"
echo ""
echo "Notes:"
echo "  • pg_replica_async still points to the OLD primary — it would need"
echo "    its primary_conninfo updated to follow pg_replica_sync."
echo "  • The original pg_primary, if restarted, would need to be turned into"
echo "    a standby of the new primary (or reinitialized)."
echo ""
echo "To reset everything:"
echo "  docker compose down -v && docker compose up -d"
