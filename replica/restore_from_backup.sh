#!/usr/bin/env bash
# Runs inside the pg_replica_new container.
#
# DDIA — "Setting Up New Followers":
#   1. Take a consistent snapshot of the leader (the base backup — done by
#      scripts/04_*.sh, which drops it in $BACKUP_DIR before starting this node).
#   2. Copy the snapshot to the new follower node  ← THIS SCRIPT.
#   3. The follower connects to the leader and requests all the data changes that
#      have happened since the snapshot was taken (it knows the snapshot's LSN).
#   4. When it has caught up, it carries on as a normal follower.
#
# Unlike replica/setup.sh, this node does NOT do its own live pg_basebackup — it
# restores from a backup that already exists on disk, exactly as you would when
# seeding a follower from last night's backup.

set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PRIMARY_HOST="${PRIMARY_HOST:-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASS="${REPL_PASS:-replicator_pass}"
REPLICA_NAME="${REPLICA_NAME:-replica_new}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  New follower from backup: $REPLICA_NAME"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Idempotency: on a restart, just start; don't re-restore ──────────────────
if [ -s "$PGDATA/PG_VERSION" ]; then
  echo "[restart] Existing data found — skipping restore, starting standby."
  echo ""
  exec gosu postgres postgres -D "$PGDATA"
fi

# ── Step 1: wait for the backup to be present ────────────────────────────────
echo "[1/3] Waiting for a base backup to appear in $BACKUP_DIR ..."
until [ -s "$BACKUP_DIR/backup_label" ] || [ -s "$BACKUP_DIR/PG_VERSION" ]; do
  printf "  ."; sleep 2
done
echo "  Backup found."

# ── Step 2: restore the snapshot into the (empty) data directory ─────────────
echo "[2/3] Restoring the snapshot into $PGDATA (a plain copy — no live clone)..."
find "$PGDATA" -mindepth 1 -delete 2>/dev/null || true
cp -a "$BACKUP_DIR/." "$PGDATA/"

# A backup may carry over transient state; clear anything that shouldn't ride
# along into a fresh standby start.
rm -f "$PGDATA/postmaster.pid" "$PGDATA/recovery.signal" "$PGDATA/standby.signal" 2>/dev/null || true

# ── Step 3: configure + start as a standby that streams the gap ──────────────
echo "[3/3] Configuring standby and starting — it will now stream every change"
echo "      made since the backup was taken."

touch "$PGDATA/standby.signal"
cat >> "$PGDATA/postgresql.auto.conf" << EOF

# Written by restore_from_backup.sh
primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASS application_name=$REPLICA_NAME'
EOF

chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

echo ""
exec gosu postgres postgres -D "$PGDATA"
