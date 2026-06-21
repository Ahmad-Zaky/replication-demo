#!/usr/bin/env bash
# DDIA — "Handling Node Outages → Follower failure: Catch-up recovery"
#         (the leader's WAL-retention dilemma)
#
# "The leader can delete its log of writes after all followers have confirmed
#  that they have processed it, but if a follower is unavailable for a long time,
#  the leader faces a choice: retain the log until the follower recovers and
#  catches up (at the risk of running out of disk space on the leader), or delete
#  the log that the unavailable follower has not yet acknowledged (in which case
#  the follower won't be able to recover from the log and will have to be restored
#  from a backup when it comes back up)."
#
# This script shows BOTH horns of that dilemma, using the two retention
# mechanisms PostgreSQL gives you:
#
#   • wal_keep_size  — a BOUNDED amount of WAL is kept. Disk is safe, but a
#     follower absent too long "falls off the end" and must be re-cloned.
#   • replication slot — UNBOUNDED retention pinned to a follower's position.
#     Catch-up is always possible, but WAL piles up and can fill the disk.
#
# Read-only / observational. It creates and then DROPS a demo slot, so it leaves
# no WAL pinned behind.

set -euo pipefail

hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }
SLOT="demo_dilemma_slot"

cleanup() {
  docker exec pg_primary psql -U postgres -d demo -c \
    "SELECT pg_drop_replication_slot('$SLOT')
     WHERE EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='$SLOT');" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   The leader's WAL-retention dilemma                 ║"
echo "╚══════════════════════════════════════════════════════╝"

hr
echo "Mechanism 1 — BOUNDED retention (wal_keep_size)."
echo "  This demo's primary keeps a fixed amount of WAL. Safe for disk, but a"
echo "  follower offline longer than this window cannot catch up from the log:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SHOW wal_keep_size;"
echo "  Current size of the primary's WAL directory:"
docker exec pg_primary bash -c "du -sh \$PGDATA/pg_wal 2>/dev/null | cut -f1" \
  | sed 's/^/    /'

hr
echo "Mechanism 2 — UNBOUNDED retention (a replication slot)."
echo "  A slot pins WAL at a follower's position so catch-up is ALWAYS possible —"
echo "  at the cost of WAL growing without bound if that follower never returns."
echo ""
echo "  Creating slot '$SLOT' (pins WAL at the current position):"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT slot_name, lsn AS pinned_at
   FROM pg_create_physical_replication_slot('$SLOT', immediately_reserve := true);"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT slot_name, slot_type, active, restart_lsn
   FROM pg_replication_slots WHERE slot_name='$SLOT';"

hr
echo "Generating WAL while the slot sits INACTIVE (as if its follower is gone)..."
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label)
   SELECT 'wal-churn #' || g FROM generate_series(1, 3000) AS g;" >/dev/null
# Force a few WAL segment switches so retention is observable.
for _ in 1 2 3; do
  docker exec pg_primary psql -U postgres -d demo -c "SELECT pg_switch_wal();" >/dev/null
done
echo "  Done."

hr
echo "The slot is still holding WAL at its old position — the primary may NOT"
echo "recycle anything past restart_lsn, even though the follower is absent:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT slot_name, active, restart_lsn,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_retained_for_slot
   FROM pg_replication_slots WHERE slot_name='$SLOT';"
echo ""
echo "  → That 'wal_retained_for_slot' figure would grow forever while the"
echo "    follower stays away. That is the disk-fill risk the book warns about."

hr
echo "The trade-off, side by side:"
echo "  • Keep the log (slot)        → follower always recoverable,  disk may fill."
echo "  • Drop the log (wal_keep_size hit) → disk safe,  follower needs a fresh backup."
echo ""
echo "Cleaning up the demo slot so it stops pinning WAL on this primary..."
cleanup
trap - EXIT
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT count(*) AS demo_slots_remaining FROM pg_replication_slots WHERE slot_name='$SLOT';"
echo ""
echo "Done. (Re-run script 05 to see a follower that DID catch up from retained WAL.)"
