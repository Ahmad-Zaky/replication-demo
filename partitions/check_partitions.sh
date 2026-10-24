#!/usr/bin/env bash
# Health check for the five-partition cluster (partitions/docker-compose.yml).
#
# For each partition leader, shows which replicas are streaming from it and
# their sync_state. A healthy cluster has two rows per partition:
#   replica_sync  → sync
#   replica_async → async
#
# Exit status is 0 only when all five partitions have both replicas streaming,
# so it can be used in a wait loop:
#   until bash partitions/check_partitions.sh >/dev/null 2>&1; do sleep 2; done

set -uo pipefail

PARTS=(poons alice bob carol dave)
healthy=0

for p in "${PARTS[@]}"; do
  echo "── partition $p ─────────────────────────────────────────"
  rows=$(docker exec "part_${p}_leader" psql -U postgres -d demo -t -A -F' ' -c \
    "SELECT application_name, state, sync_state FROM pg_stat_replication ORDER BY application_name;" 2>/dev/null)
  if [ -z "$rows" ]; then
    echo "  leader part_${p}_leader not reachable, or no replicas connected yet"
    continue
  fi
  echo "$rows" | sed 's/^/  /'
  if echo "$rows" | grep -q '^replica_async streaming async$' &&
     echo "$rows" | grep -q '^replica_sync streaming sync$'; then
    healthy=$((healthy + 1))
  fi
done

echo ""
echo "$healthy of ${#PARTS[@]} partitions have both replicas streaming."
[ "$healthy" -eq "${#PARTS[@]}" ]
