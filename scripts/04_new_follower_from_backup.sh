#!/usr/bin/env bash
# DDIA — "Setting Up New Followers"
#
# "Take a consistent snapshot of the leader's database at some point in time...
#  Copy the snapshot to the new follower node. The follower connects to the
#  leader and requests all the data changes that have happened since the snapshot
#  was taken... When the follower has processed the backlog of data changes since
#  the snapshot, we say it has caught up."
#
# This brings up a BRAND-NEW, EMPTY follower (pg_replica_new, port 5435) and seeds
# it FROM A BACKUP rather than from a live clone:
#   1. Write "historical" rows to the primary (data that exists before backup).
#   2. Take a base backup of the primary (the snapshot) into a shared volume.
#   3. Write MORE rows AFTER the backup (changes the snapshot does NOT contain).
#   4. Start the new node; it restores the snapshot, then streams the post-backup
#      changes from the leader.
#   5. Verify the new follower has BOTH the backup data and the streamed changes.
#
# The node is profile-gated, so a normal `docker compose up -d` never starts it.

set -euo pipefail

HIST="${1:-2000}"   # rows that exist BEFORE the backup (land in the snapshot)
POST="${2:-2000}"   # rows written AFTER the backup (must be streamed)
hr() { echo ""; echo "────────────────────────────────────────────────"; echo ""; }

COMPOSE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
dc() { docker compose -f "$COMPOSE_DIR/docker-compose.yml" "$@"; }

q_primary() { docker exec pg_primary     psql -U postgres -d demo -t -A -c "$1"; }
q_new()     { docker exec pg_replica_new psql -U postgres -d demo -t -A -c "$1"; }

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   Setting up a NEW follower from a backup            ║"
echo "╚══════════════════════════════════════════════════════╝"

# Start clean: no leftover node or stale backup from a previous run.
docker rm -f pg_replica_new >/dev/null 2>&1 || true
docker volume rm "$(basename "$COMPOSE_DIR")_replica_new_data" >/dev/null 2>&1 || true
docker exec pg_primary bash -c 'find /backup -mindepth 1 -delete 2>/dev/null || true'

hr
echo "Step 1 — Write $HIST HISTORICAL rows to the primary (these will be inside"
echo "         the backup snapshot)."
q_primary "INSERT INTO events (label)
           SELECT 'historical (in backup) #' || g FROM generate_series(1, $HIST) AS g;" >/dev/null
echo "  Primary row count now: $(q_primary 'SELECT count(*) FROM events;')"

hr
echo "Step 2 — Take a base backup of the primary (the consistent snapshot)."
echo "         pg_basebackup runs against the leader and writes into the shared"
echo "         /backup volume; -X stream makes the snapshot self-consistent."
backup_lsn="$(q_primary 'SELECT pg_current_wal_lsn();')"
echo "  WAL position at backup time: $backup_lsn"
docker exec -e PGPASSWORD=replicator_pass pg_primary \
  pg_basebackup -h primary -p 5432 -U replicator -D /backup --wal-method=stream -P
echo "  Backup written to /backup ($(docker exec pg_primary bash -c 'du -sh /backup 2>/dev/null | cut -f1'))."

hr
echo "Step 3 — Write $POST MORE rows AFTER the backup. These are NOT in the"
echo "         snapshot — the new follower can only get them by streaming."
q_primary "INSERT INTO events (label)
           SELECT 'post-backup (streamed) #' || g FROM generate_series(1, $POST) AS g;" >/dev/null
echo "  Primary row count now: $(q_primary 'SELECT count(*) FROM events;')"

hr
echo "Step 4 — Start the brand-new, empty follower (pg_replica_new, port 5435)."
echo "         It restores the snapshot from /backup, then streams the gap."
dc --profile newfollower up -d replica_new >/dev/null 2>&1
echo "  Container starting. Watching it restore and begin streaming:"
echo ""
for _ in $(seq 1 40); do
  sleep 1
  if docker logs pg_replica_new 2>&1 | grep -q "started streaming WAL from primary"; then
    break
  fi
done
docker logs pg_replica_new 2>&1 \
  | grep -E "Restoring the snapshot|consistent recovery state|started streaming WAL from primary|ready to accept" \
  | tail -6 | sed 's/^/    /'

hr
echo "Step 5 — Wait for catch-up, then prove the new follower has BOTH the"
echo "         backup data and the streamed-since-backup data:"
target="$(q_primary 'SELECT count(*) FROM events;')"
for _ in $(seq 1 40); do
  sleep 2
  got="$(q_new 'SELECT count(*) FROM events;' 2>/dev/null || echo '?')"
  printf "    follower has %s / %s rows\n" "$got" "$target"
  [ "$got" = "$target" ] && break
done
echo ""
docker exec pg_replica_new psql -U postgres -d demo -c \
  "SELECT
     count(*) FILTER (WHERE label LIKE 'historical (in backup)%')    AS from_backup,
     count(*) FILTER (WHERE label LIKE 'post-backup (streamed)%')     AS streamed_after_backup,
     count(*)                                                         AS total
   FROM events;"

hr
echo "The leader now sees three followers, including the new one:"
docker exec pg_primary psql -U postgres -d demo -c \
  "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY application_name;"

hr
echo "Done. A new node was seeded from a backup and then caught up by streaming —"
echo "exactly DDIA's 'Setting Up New Followers' procedure."
echo ""
echo "The new follower is an EXTRA, profile-gated node (port 5435). To remove just it:"
echo "  docker rm -f pg_replica_new && docker volume rm $(basename "$COMPOSE_DIR")_replica_new_data"
echo "Or do a full reset (the --profile flag is required to remove this node):"
echo "  docker compose --profile newfollower down -v && docker compose up -d"
