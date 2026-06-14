#!/usr/bin/env bash
# Show the replication topology from the primary's perspective.

set -euo pipefail

echo "════════════════════════════════════════════════"
echo " Replication status (from PRIMARY)"
echo "════════════════════════════════════════════════"
docker exec pg_primary psql -U postgres -d demo -x -c "
SELECT
  application_name  AS replica,
  state,
  sync_state,
  sent_lsn,
  write_lsn,
  flush_lsn,
  replay_lsn,
  (sent_lsn - replay_lsn) AS lag_bytes
FROM pg_stat_replication
ORDER BY application_name;
"

echo ""
echo "════════════════════════════════════════════════"
echo " Standby status — SYNC REPLICA (port 5433)"
echo "════════════════════════════════════════════════"
docker exec pg_replica_sync psql -U postgres -d demo -c "
SELECT
  pg_is_in_recovery()        AS is_standby,
  pg_last_wal_receive_lsn()  AS received_lsn,
  pg_last_wal_replay_lsn()   AS replayed_lsn,
  now() - pg_last_xact_replay_timestamp() AS replay_delay;
"

echo ""
echo "════════════════════════════════════════════════"
echo " Standby status — ASYNC REPLICA (port 5434)"
echo "════════════════════════════════════════════════"
docker exec pg_replica_async psql -U postgres -d demo -c "
SELECT
  pg_is_in_recovery()        AS is_standby,
  pg_last_wal_receive_lsn()  AS received_lsn,
  pg_last_wal_replay_lsn()   AS replayed_lsn,
  now() - pg_last_xact_replay_timestamp() AS replay_delay;
"
