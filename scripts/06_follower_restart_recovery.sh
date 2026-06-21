#!/usr/bin/env bash
# DDIA — "Handling Node Outages → Follower failure: Catch-up recovery"
#
# "If a follower crashes and is restarted... from its log, it knows the last
#  transaction that was processed before the fault occurred. Thus, the follower
#  can connect to the leader and request all the data changes that occurred during
#  the time when the follower was disconnected."
#
# Script 05 showed the "network interrupted" half of that sentence. THIS script
# shows the "crashes and is restarted" half: the follower CONTAINER is stopped
# and started again. On restart it:
#   1. Reads its on-disk WAL log to find the last transaction it had processed,
#      and replays anything not yet applied (standby crash recovery).
#   2. Connects to the leader and streams every change it missed while down.
#
# This relies on replica/setup.sh being idempotent: on a restart it detects the
# existing data directory and SKIPS the re-clone, so the follower truly recovers
# from its own log instead of being rebuilt from scratch.
#
# We use the ASYNC follower so the primary keeps accepting writes while it is down.

set -euo pipefail

BACKLOG="${1:-5000}"   # rows to write while the follower is down
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

count_primary() { docker exec pg_primary       psql -U postgres -d demo -t -A -c "SELECT count(*) FROM events;"; }
count_async()   { docker exec pg_replica_async psql -U postgres -d demo -t -A -c "SELECT count(*) FROM events;"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Follower restart: recover from its own log         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Rows on PRIMARY before we start: $(count_primary)"
echo "Rows on ASYNC follower:          $(count_async)"

# Note the last LSN the follower has on disk BEFORE it goes down — this is the
# point it will resume from.
last_lsn="$(docker exec pg_replica_async psql -U postgres -d demo -t -A \
  -c "SELECT pg_last_wal_replay_lsn();")"
echo "Follower's last replayed LSN:    $last_lsn   (its on-disk log ends here)"

hr
echo "Step 1 — Crash the follower (docker stop). A clean SIGTERM shutdown; its"
echo "         data directory and WAL log stay on the volume."
docker stop pg_replica_async >/dev/null
echo "  pg_replica_async is DOWN."

hr
echo "Step 2 — Write a backlog of $BACKLOG rows to the primary while it is down."
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label)
   SELECT 'restart-backlog #' || g FROM generate_series(1, $BACKLOG) AS g;"
echo ""
echo "  Rows on PRIMARY now: $(count_primary)"
echo "  The leader retains this WAL (wal_keep_size) so the follower can catch up."

hr
echo "Step 3 — Start the follower again (docker start)."
docker start pg_replica_async >/dev/null
echo "  Booting. setup.sh detects existing data and SKIPS the clone, so this is"
echo "  genuine log-based recovery — watch the startup log:"
echo ""
# Wait for the container to log that it has reached recovery / started streaming.
for _ in $(seq 1 30); do
  sleep 1
  if docker logs pg_replica_async 2>&1 | grep -q "started streaming WAL from primary"; then
    break
  fi
done
docker logs pg_replica_async 2>&1 \
  | grep -E "skipping clone|redo starts at|consistent recovery state|started streaming WAL from primary|database system is ready" \
  | tail -8 | sed 's/^/    /'

hr
echo "Step 4 — It resumes from the LSN it had on disk ($last_lsn) and streams the"
echo "         gap. Waiting for it to catch up to $(count_primary) rows:"
target="$(count_primary)"
for _ in $(seq 1 30); do
  sleep 2
  got="$(count_async 2>/dev/null || echo '?')"
  printf "    follower has %s / %s rows\n" "$got" "$target"
  [ "$got" = "$target" ] && break
done

hr
echo "Step 5 — Back in sync, streaming live, with zero lag — recovered purely"
echo "         from its log plus the leader's retained WAL (no re-clone):"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state,
          (sent_lsn - replay_lsn) AS lag_bytes
   FROM pg_stat_replication ORDER BY application_name;"

hr
echo "Done. Compare with script 05 (same recovery, but triggered by a network"
echo "partition instead of a process restart)."
