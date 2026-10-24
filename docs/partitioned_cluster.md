# The Five-Partition Cluster

**Files:** `partitions/docker-compose.yml`, `partitions/init.sql`,
`partitions/check_partitions.sh`

**Used by:** `scripts/13_demo_concurrent_answers_version_vectors.py` (see
[concurrent_answers_version_vectors.md](concurrent_answers_version_vectors.md))

---

## 1. Why a second cluster

The main cluster (`docker-compose.yml`) has **one leader and one WAL**. That's
what scripts 01–12 need: catch-up recovery, failover and the rest are all about
one leader and its followers. But one leader also puts **every write in one
total order**, which is exactly what script 13 is about *not* having.

Script 13 needs writes that **no single log sees together**: five writers, each
writing to their own partition. So each partition gets its **own replication
cluster**:

```
                 poons    alice    bob      carol    dave
  leader           ●        ●        ●        ●        ●     writes · Carol's app reads here
  sync replica     ●        ●        ●        ●        ●     durability only, not read
  async replica    ●        ●        ● ⏳     ●        ●     everyone else reads here; Bob's lags
                 └──────── five separate clusters: no shared leader, no shared WAL ────────┘
```

Each partition has the same shape as the main cluster: a leader, a
**synchronous** replica (the leader waits for it on every commit) and an
**asynchronous** replica that apps read from. Nothing connects the five
clusters, so the only thing that relates a message in Bob's partition to one in
Carol's is the version vector stored on each row.

The main cluster is left exactly as it was. The two clusters are separate
Compose projects with different container names, ports and volumes, so they can
run at the same time.

---

## 2. Containers and ports

| Partition | Leader (writes) | Sync replica | Async read replica |
|---|---|---|---|
| poons | `part_poons_leader` · 5441 | `part_poons_sync` · 5442 | `part_poons_async` · 5443 |
| alice | `part_alice_leader` · 5451 | `part_alice_sync` · 5452 | `part_alice_async` · 5453 |
| bob | `part_bob_leader` · 5461 | `part_bob_sync` · 5462 | `part_bob_async` · 5463 ⏳ |
| carol | `part_carol_leader` · 5471 | `part_carol_sync` · 5472 | `part_carol_async` · 5473 |
| dave | `part_dave_leader` · 5481 | `part_dave_sync` · 5482 | `part_dave_async` · 5483 |

⏳ Script 13 sets `recovery_min_apply_delay` on `part_bob_async` while it runs,
and clears it when it exits.

All nodes use user `postgres`, password `postgres`, database `demo`, for example:

```bash
psql -h localhost -p 5461 -U postgres -d demo    # Bob's partition leader
```

Together the 15 containers use about 350 MiB of memory when idle.

---

## 3. How it's built

| Piece | What it does |
|---|---|
| `partitions/docker-compose.yml` | 15 services in a Compose project named `replication_partitions`. YAML anchors (`x-leader`, `x-replica`) keep the five partitions identical. |
| `partitions/init.sql` | Runs once on each **leader**: creates the `replicator` role and the `chat_log` table, then sets `synchronous_standby_names = 'replica_sync'`. |
| `../primary/pg_hba.conf` | Reused unchanged from the main cluster. It allows replication connections on the Docker network. |
| `../replica/setup.sh` | Reused unchanged: each replica waits for its leader, clones it with `pg_basebackup`, and starts as a hot standby. It skips the clone on restart. |
| `partitions/check_partitions.sh` | Shows `pg_stat_replication` for each leader. Exits 0 only when all five partitions have both replicas streaming. |

Replica names (`replica_sync`, `replica_async`) repeat across partitions. That's
fine: each name is only matched against **its own leader's**
`synchronous_standby_names`.

The `chat_log` table is the same on every leader, but each leader only ever
holds rows written by its own writer. The rows reach that partition's two
replicas through its WAL.

---

## 4. Start, check, stop, reset

```bash
# Start (about 30 s the first time: each replica clones its leader)
docker compose -f partitions/docker-compose.yml up -d

# Wait until every partition has both replicas streaming
until bash partitions/check_partitions.sh >/dev/null 2>&1; do sleep 2; done
bash partitions/check_partitions.sh
```

A healthy cluster prints two rows per partition and a summary:

```
── partition bob ─────────────────────────────────────────
  replica_async streaming async
  replica_sync streaming sync
...
5 of 5 partitions have both replicas streaming.
```

```bash
# Stop, keeping the data
docker compose -f partitions/docker-compose.yml down

# Full reset: delete all 15 volumes, then start fresh
docker compose -f partitions/docker-compose.yml down -v
docker compose -f partitions/docker-compose.yml up -d
```

Script 13 doesn't start or stop anything. Before it does anything, it checks
that all five leaders are up with both replicas streaming. If not, it lists the
problems, prints the commands above and exits with status 1.

---

## 5. Things to know

- **The sync replica can block writes.** As in the main cluster, a leader waits
  for its `replica_sync` on every commit. If you stop or pause a partition's
  sync replica, writes to that partition hang until it's back. Script 13 only
  delays the **async** replica, so its writes are never blocked.
- **Clocks.** The NAIVE view in script 13 sorts by `written_at` from five
  different leaders. They share the host's clock here. In a real system they
  wouldn't, which is one more reason not to order by timestamps.
- **Partition count is fixed by the file.** The script's `PARTS` list and the
  compose services must match. To add a partition, copy one partition's three
  services and volumes, give them new names and ports, and add the name to
  `PARTS` in script 13 and `PARTS` in `check_partitions.sh`.
