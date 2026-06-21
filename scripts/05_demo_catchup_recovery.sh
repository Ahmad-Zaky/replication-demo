#!/usr/bin/env bash
# DDIA — "Handling Node Outages → Follower failure: Catch-up recovery"
#
# "If a follower crashes and is restarted, or if the network between the leader
#  and the follower is temporarily interrupted, the follower can recover quite
#  easily: from its log, it knows the last transaction that was processed before
#  the fault occurred. Thus, the follower can connect to the leader and request
#  all the data changes that occurred during the time when the follower was
#  disconnected. When it has applied these changes, it has caught up to the
#  leader and can continue receiving a stream of data changes as before."
#
# This script reproduces the "network temporarily interrupted" case: it cuts the
# async follower off the Docker network, writes a backlog to the primary while it
# is isolated, then reconnects it and watches it resume streaming FROM WHERE IT
# LEFT OFF — pure catch-up from its log, no re-clone.
#
# Why a network cut and not `docker stop`?  In this demo, restarting a replica
# container re-runs setup.sh, which does a full pg_basebackup re-clone — that is
# NOT catch-up recovery.  A network partition leaves the follower's data + log
# intact, so it recovers exactly as the book describes.
#
# We use the ASYNC follower: cutting off the SYNC follower would block the
# primary's writes (synchronous_standby_names='replica_sync').

set -euo pipefail

BACKLOG="${1:-5000}"   # rows to write while the follower is partitioned away
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

# Capture the follower's network now (it's gone once we disconnect).
NET="$(docker inspect pg_replica_async \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"

count_primary() {
  docker exec pg_primary psql -U postgres -d demo -t -A -c "SELECT count(*) FROM events;"
}
count_async() {
  docker exec pg_replica_async psql -U postgres -d demo -t -A -c "SELECT count(*) FROM events;"
}
reconnect() { docker network connect "$NET" pg_replica_async 2>/dev/null || true; }
trap reconnect EXIT   # never leave the follower partitioned

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Follower failure: Catch-up recovery                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Rows on PRIMARY before we start: $(count_primary)"
echo "Rows on ASYNC follower:          $(count_async)"

hr
echo "Step 1 — Interrupt the network between leader and follower"
echo "         (docker network disconnect). The follower's data and log stay on"
echo "         disk; it just can't reach the leader."
docker network disconnect "$NET" pg_replica_async
echo "  pg_replica_async is PARTITIONED (still running, just unreachable)."

hr
echo "Step 2 — Write a backlog of $BACKLOG rows to the primary while the"
echo "         follower is cut off. The primary keeps accepting writes because"
echo "         this follower is asynchronous — it never waited for it."
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label)
   SELECT 'catchup-backlog #' || g FROM generate_series(1, $BACKLOG) AS g;"
echo ""
echo "  Rows on PRIMARY now:               $(count_primary)"
echo "  Rows the follower can still see:   $(count_async)   <-- frozen, it's behind"

hr
echo "Step 3 — From the leader's view, the partitioned follower's replay position"
echo "         is frozen and falling behind the primary's current WAL. (It may"
echo "         still show as 'streaming' until the leader's TCP timeout fires.)"
echo "         The primary retains WAL (wal_keep_size) so it can still catch up:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state,
          pg_size_pretty(pg_current_wal_lsn() - replay_lsn) AS behind_primary
   FROM pg_stat_replication ORDER BY application_name;"

hr
echo "Step 4 — Heal the network. The follower reconnects, tells the leader the"
echo "         last LSN it had, and requests every change it missed."
reconnect
trap - EXIT
echo "  Network restored. Replaying the backlog from the log..."
echo ""

target="$(count_primary)"
echo "  Waiting for the follower to catch up to $target rows:"
for _ in $(seq 1 30); do
  sleep 2
  got="$(count_async 2>/dev/null || echo '?')"
  printf "    follower has %s / %s rows\n" "$got" "$target"
  [ "$got" = "$target" ] && break
done

hr
echo "Step 5 — Caught up. The follower is back in pg_stat_replication with zero"
echo "         lag, streaming live again — and it never re-cloned:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state,
          (sent_lsn - replay_lsn) AS lag_bytes
   FROM pg_stat_replication ORDER BY application_name;"

hr
echo "Done. The follower recovered purely from the leader's retained WAL — no"
echo "backup or re-clone was needed. (If it had been cut off long enough for the"
echo "leader to recycle that WAL, recovery from the log would be impossible and a"
echo "full re-basebackup would be required — see script 07.)"
