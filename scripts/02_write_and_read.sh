#!/usr/bin/env bash
# Write a row to the primary and immediately read it from both replicas.
# Usage: ./02_write_and_read.sh "optional label"

set -euo pipefail

LABEL="${1:-Hello from demo $(date '+%H:%M:%S')}"

echo "════════════════════════════════════════════════"
echo " Writing to PRIMARY"
echo "════════════════════════════════════════════════"
docker exec pg_primary psql -U postgres -d demo -c \
  "INSERT INTO events (label) VALUES ('$LABEL') RETURNING id, label, written_at;"

echo ""
echo "════════════════════════════════════════════════"
echo " Reading from SYNC REPLICA (port 5433)"
echo " (always up-to-date — primary waited for it)"
echo "════════════════════════════════════════════════"
docker exec pg_replica_sync psql -U postgres -d demo -c \
  "SELECT id, label, written_at FROM events ORDER BY id DESC LIMIT 5;"

echo ""
echo "════════════════════════════════════════════════"
echo " Reading from ASYNC REPLICA (port 5434)"
echo " (usually up-to-date, but not guaranteed)"
echo "════════════════════════════════════════════════"
docker exec pg_replica_async psql -U postgres -d demo -c \
  "SELECT id, label, written_at FROM events ORDER BY id DESC LIMIT 5;"

echo ""
echo ">>> Try writing to a replica (it must be read-only):"
echo "    docker exec pg_replica_sync psql -U postgres -d demo \\"
echo "      -c \"INSERT INTO events (label) VALUES ('oops') RETURNING *;\""
