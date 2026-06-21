#!/usr/bin/env bash
# Runs inside each replica container.
# 1. Waits for the primary to be ready.
# 2. Clones the primary with pg_basebackup.
# 3. Configures standby settings.
# 4. Starts PostgreSQL in hot-standby (read-only) mode.

set -euo pipefail

PGDATA="${PGDATA:-/var/lib/postgresql/data}"
PRIMARY_HOST="${PRIMARY_HOST:-primary}"
PRIMARY_PORT="${PRIMARY_PORT:-5432}"
REPL_USER="${REPL_USER:-replicator}"
REPL_PASS="${REPL_PASS:-replicator_pass}"
REPLICA_NAME="${REPLICA_NAME:-replica}"

# ── Step 1: wait for primary ──────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Replica setup: $REPLICA_NAME"
echo "╚══════════════════════════════════════════════╝"
echo ""
# ── Idempotency check ─────────────────────────────────────────────────────────
# If this data directory has already been cloned (PG_VERSION present), this is a
# RESTART, not a first boot. We must NOT re-clone: the whole point of follower
# crash-recovery (DDIA "Follower failure: Catch-up recovery") is that the standby
# starts from the log it already has on disk and then streams the gap from the
# leader. Re-cloning would throw that log away. So we skip straight to startup.
if [ -s "$PGDATA/PG_VERSION" ]; then
  echo "[restart] Existing standby data found — skipping clone."
  echo "          PostgreSQL will recover from its on-disk log and then catch up"
  echo "          on any changes it missed while it was down."
  echo ""
  exec gosu postgres postgres -D "$PGDATA"
fi

echo "[1/4] Waiting for primary at $PRIMARY_HOST:$PRIMARY_PORT ..."
until pg_isready -h "$PRIMARY_HOST" -p "$PRIMARY_PORT" -U postgres -q; do
  printf "  ."; sleep 2
done
echo "  Primary is up!"

# Give the primary a few extra seconds to finish running init.sql
echo "      (waiting for init.sql to complete...)"
sleep 8

# ── Step 2: clone ─────────────────────────────────────────────────────────────
echo "[2/4] Cloning primary with pg_basebackup..."
# Clear the contents of the data dir without removing the mount point itself
# (Docker volumes can't be deleted — only their contents can be cleared).
find "$PGDATA" -mindepth 1 -delete 2>/dev/null || true

PGPASSWORD="$REPL_PASS" pg_basebackup \
  -h "$PRIMARY_HOST" \
  -p "$PRIMARY_PORT" \
  -U "$REPL_USER" \
  -D "$PGDATA" \
  --wal-method=stream \
  -P            # show progress

# ── Step 3: configure standby ────────────────────────────────────────────────
echo "[3/4] Configuring standby ($REPLICA_NAME)..."

# PostgreSQL 12+: presence of this file is what makes postgres start as standby
touch "$PGDATA/standby.signal"

# primary_conninfo tells the standby where to stream WAL from.
# application_name must match synchronous_standby_names on the primary
# so the primary can tell replica_sync apart from replica_async.
cat >> "$PGDATA/postgresql.auto.conf" << EOF

# Written by setup.sh
primary_conninfo = 'host=$PRIMARY_HOST port=$PRIMARY_PORT user=$REPL_USER password=$REPL_PASS application_name=$REPLICA_NAME'
EOF

# Fix ownership so postgres process can read/write the data dir
chown -R postgres:postgres "$PGDATA"
chmod 700 "$PGDATA"

# ── Step 4: start standby ─────────────────────────────────────────────────────
echo "[4/4] Starting PostgreSQL in hot-standby mode..."
echo ""
exec gosu postgres postgres -D "$PGDATA"
