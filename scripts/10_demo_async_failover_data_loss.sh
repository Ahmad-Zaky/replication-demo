#!/usr/bin/env bash
# DDIA — "Handling Node Outages → Leader failure: Failover" (the danger of async)
#
# "If asynchronous replication is used, the new leader may not have received all
#  the writes from the old leader before it failed. ... The most common solution
#  is for the old leader's unreplicated writes to simply be discarded, which means
#  that writes you believed to be committed weren't durable after all."
#
# This script reproduces that data loss:
#   1. Partition the ASYNC follower off the network so it stops receiving WAL.
#   2. Commit "critical" rows on the primary (they succeed — the sync replica
#      acks them, so the client is told they are durable).
#   3. Crash the primary.
#   4. Promote the STALE async follower (the wrong choice — see script 09).
#   5. Observe that the critical rows are GONE on the new leader.
#
# We cut the network rather than `docker pause`: a paused container's kernel
# still buffers the incoming WAL in its socket and applies it on unpause, so the
# writes would NOT actually be lost. A real partition severs the stream.
#
# ⚠ DESTRUCTIVE: this stops the primary and promotes a replica. You MUST reset
#   afterwards:  docker compose down -v && docker compose up -d

set -euo pipefail

N="${1:-5}"   # number of "critical" rows to write during the danger window
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

# Capture the follower's network now (it's gone once we disconnect).
NET="$(docker inspect pg_replica_async \
        --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}')"

count() {  # $1 = container
  docker exec "$1" psql -U postgres -d demo -t -A \
    -c "SELECT count(*) FROM events WHERE label LIKE 'CRITICAL-payment%';"
}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Async failover data loss (discarded writes)        ║"
echo "╚══════════════════════════════════════════════════════╝"

hr
echo "Step 1 — Partition the ASYNC follower off the network. It stops receiving"
echo "         WAL from the leader, so it is about to fall behind."
docker network disconnect "$NET" pg_replica_async
echo "  pg_replica_async is PARTITIONED (running, but receiving nothing)."

hr
echo "Step 2 — Commit $N CRITICAL rows on the primary. These SUCCEED and return"
echo "         to the client as committed — the sync replica acknowledged them,"
echo "         so you believe they are safely durable:"
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label)
   SELECT 'CRITICAL-payment #' || g FROM generate_series(1, $N) AS g
   RETURNING id, label;"
echo ""
echo "  CRITICAL rows visible on PRIMARY:           $(count pg_primary)"
echo "  CRITICAL rows that reached the ASYNC node:  $(count pg_replica_async)   <-- partitioned, never got them"

hr
echo "Step 3 — The primary crashes."
docker stop pg_primary >/dev/null
echo "  pg_primary is DOWN. The sync replica that HAD the critical rows is"
echo "  unreachable for routing in this scenario — operations grabs the only"
echo "  other follower they can see and promotes it. That is the stale async one."

hr
echo "Step 4 — Promote the STALE async follower to be the new leader."
docker network connect "$NET" pg_replica_async 2>/dev/null || true
echo "  Reconnected to the network, but the primary is dead — it cannot fetch"
echo "  the missing writes."
docker exec pg_replica_async \
  gosu postgres pg_ctl promote -D /var/lib/postgresql/data
echo "  Promotion signalled. Waiting for it to complete..."
sleep 4
# Clear the inherited sync requirement so the new leader can accept writes.
docker exec pg_replica_async psql -U postgres -d demo \
  -c "ALTER SYSTEM SET synchronous_standby_names = ''" \
  -c "SELECT pg_reload_conf();" >/dev/null

hr
echo "Step 5 — Inspect the new leader. The 'committed' critical writes are GONE:"
echo ""
echo "  CRITICAL rows on the NEW leader (promoted async): $(count pg_replica_async)"
echo ""
docker exec pg_replica_async psql -U postgres -d demo -c \
  "SELECT count(*) AS total_rows,
          count(*) FILTER (WHERE label LIKE 'CRITICAL-payment%') AS critical_rows_kept
   FROM events;"

hr
echo "💥 Data loss: writes the client was told had committed were silently"
echo "   discarded, because the promoted follower never received them. This is"
echo "   the async-failover trap, and the reason the book stresses picking the"
echo "   MOST up-to-date follower (script 09) — or using synchronous replication."
echo ""
echo "Reset the cluster before any other demo:"
echo "  docker compose down -v && docker compose up -d"
