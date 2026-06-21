#!/usr/bin/env bash
# DDIA — "Handling Node Outages → Leader failure: Failover" (choosing a new leader)
#
# "The best candidate for leadership is usually the replica with the most
#  up-to-date data changes from the old leader (to minimize any data loss)."
# "With asynchronous replication, you can pick the follower with the highest log
#  sequence number. This minimizes the amount of data that is lost during
#  failover."
#
# This script makes one follower deliberately lag, then compares the replay LSN
# of every follower to decide which one should be promoted. It does NOT actually
# fail over — it shows the *decision* you must make first. (Script 04 / 07 do the
# promotion.)
#
# We force lag with recovery_min_apply_delay on the async replica: it still
# RECEIVES the WAL but deliberately delays REPLAYING it, so its replay LSN falls
# behind the sync replica's. That mirrors a real follower that is behind.

set -euo pipefail

DELAY="${1:-30s}"     # how long the async follower will hold back replay
BURST="${2:-2000}"    # rows to write so the lag is visible
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Failover: pick the most up-to-date follower        ║"
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
echo "Step 1 — Make the ASYNC follower lag on purpose (recovery_min_apply_delay=$DELAY)."
echo "         It keeps receiving WAL but delays replaying it, just like a"
echo "         follower that is behind."
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET recovery_min_apply_delay = '$DELAY'" \
  -c "SELECT pg_reload_conf();"

hr
echo "Step 2 — Write a burst of $BURST rows to the primary so the lag shows up."
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label)
   SELECT 'leader-choice #' || g FROM generate_series(1, $BURST) AS g;" >/dev/null
echo "  Burst written. Giving the sync follower a moment to apply it..."
sleep 3

hr
echo "Step 3 — From the leader's pg_stat_replication, compare how far each"
echo "         follower has REPLAYED (a single consistent snapshot):"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state,
          replay_lsn,
          (sent_lsn - replay_lsn) AS bytes_behind_leader
   FROM pg_stat_replication ORDER BY application_name;"

# Pull both followers' replay positions from ONE snapshot so the verdict can't
# be skewed by reading the two nodes at slightly different instants.
read -r sync_pos async_pos < <(docker exec pg_primary psql -U postgres -d demo -t -A -F' ' -c "
  SELECT
    coalesce(max(pg_wal_lsn_diff(replay_lsn,'0/0')) FILTER (WHERE application_name='replica_sync'),  0)::bigint,
    coalesce(max(pg_wal_lsn_diff(replay_lsn,'0/0')) FILTER (WHERE application_name='replica_async'), 0)::bigint
  FROM pg_stat_replication;")

hr
echo "Step 4 — Verdict: promote the follower with the HIGHEST replay LSN."
echo "         (sync replayed $sync_pos bytes, async replayed $async_pos bytes since 0/0)"
if [ "$sync_pos" -ge "$async_pos" ]; then
  behind=$(( sync_pos - async_pos ))
  echo "  ➜ Promote the SYNC replica (5433)."
  echo "    The async replica is $behind bytes behind; promoting it would silently"
  echo "    discard those committed writes."
else
  behind=$(( async_pos - sync_pos ))
  echo "  ➜ Promote the ASYNC replica (5434)."
  echo "    It is $behind bytes ahead of the sync replica right now."
fi
echo ""
echo "  This is exactly the book's rule: choosing the most up-to-date follower"
echo "  minimizes the data lost during failover. Promoting a stale follower is"
echo "  how 'committed' writes vanish (see script 10)."
