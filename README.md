# PostgreSQL Replication Demo

A hands-on companion to **Chapter 5 – Replication** in *Designing Data-Intensive Applications* (Kleppmann).

Spins up three PostgreSQL 15 containers with Docker Compose:

```
                        writes
  you ──────────────► PRIMARY        port 5432
                      (leader)
                          │
          ┌───────────────┴───────────────┐
          │ WAL  (synchronous)            │ WAL  (asynchronous)
          ▼                               ▼
  SYNC REPLICA                    ASYNC REPLICA
  port 5433                       port 5434

  Primary waits for this          Primary does NOT wait.
  replica to confirm each         Write returns immediately;
  write before returning          replica catches up in the
  success to the client.          background.
```

| Concept from the book | Where you see it here |
|---|---|
| Leader-based replication | `pg_primary` is the only node that accepts writes |
| Synchronous follower | `pg_replica_sync` — primary blocks until it confirms |
| Asynchronous follower | `pg_replica_async` — primary never waits |
| Replication lag | `pg_stat_replication.lag_bytes` on the primary |
| Read-only replicas | Any `INSERT` on a replica fails immediately |
| Failover / promotion | Script 04 stops the primary and promotes the sync replica |

---

## Prerequisites

| Tool | Minimum version |
|---|---|
| Docker | 24.x |
| Docker Compose | v2 (bundled with Docker Desktop or `docker compose` plugin) |

---

## Quick Start

```bash
# 1. Clone / enter the project
cd replication_demo

# 2. Make the scripts executable
chmod +x replica/setup.sh scripts/*.sh

# 3. Bring everything up (always start fresh — see note below)
docker compose up -d

# 4. Watch the replicas clone themselves from the primary
#    (takes ~20–30 seconds the first time)
docker compose logs -f replica_sync replica_async
#    Wait until you see: "Starting PostgreSQL in hot-standby mode..."

# 5. Verify all three nodes are healthy
bash scripts/01_check_replication.sh
```

> **Important:** if you ever see "database demo does not exist" or the primary
> stuck in an unhealthy state, you likely have a stale Docker volume.
> Run `docker compose down -v && docker compose up -d` to wipe volumes and
> start completely fresh.

Expected output from step 5 — you should see two rows in `pg_stat_replication`,
one with `sync_state = sync` and one with `sync_state = async`.

---

## Demo Walkthrough

Run the scripts in order for a full tour.

### Script 01 — Check replication status

```bash
bash scripts/01_check_replication.sh
```

Shows:
- Which replicas are connected to the primary
- Their `sync_state` (`sync` vs `async`)
- Replication lag in bytes
- Whether each replica is in recovery (standby) mode

### Script 02 — Write data and read from replicas

```bash
bash scripts/02_write_and_read.sh "My first replicated write"
```

Shows:
- A row written to the primary appearing on both replicas immediately
- How to confirm replicas are **read-only** (try running the hint at the bottom)

```bash
# Try to write to a replica — this must fail
docker exec pg_replica_sync psql -U postgres -d demo \
  -c "INSERT INTO events (label) VALUES ('oops') RETURNING *;"
# ERROR:  cannot execute INSERT in a read-only transaction
```

### Script 03 — Synchronous vs asynchronous: the real difference

```bash
bash scripts/03_demo_sync_vs_async.sh
```

**Part A** — pauses `pg_replica_sync` and attempts a write with a 4-second timeout.
The write **blocks and times out** because the primary is waiting for an acknowledgment
that will never come.

**Part B** — pauses `pg_replica_async` and writes again.
The write **returns immediately** — the primary does not wait.
After the replica is unpaused it replays the missing WAL and catches up.

This directly demonstrates the durability vs. latency trade-off discussed in
*DDIA* § "Synchronous Versus Asynchronous Replication".

### Script 04 — Manual failover (promote a replica)

```bash
bash scripts/04_demo_failover.sh
```

1. Stops `pg_primary` (simulates a crash).
2. Runs `pg_ctl promote` on `pg_replica_sync`.
3. Writes a row to the newly promoted primary to confirm it accepts writes.

This maps to *DDIA* § "Handling Node Outages → Follower failure: Catch-up recovery"
and § "Leader Failure: Failover".

---

## Connecting Manually

You can connect to any node with `psql` or any PostgreSQL client:

```bash
# Primary (read + write)
psql -h localhost -p 5432 -U postgres -d demo

# Sync replica (read-only)
psql -h localhost -p 5433 -U postgres -d demo

# Async replica (read-only)
psql -h localhost -p 5434 -U postgres -d demo

# Password for all: postgres
```

Useful queries to run interactively:

```sql
-- On primary: see connected replicas
SELECT application_name, state, sync_state, sent_lsn, replay_lsn,
       (sent_lsn - replay_lsn) AS lag_bytes
FROM   pg_stat_replication;

-- On a replica: confirm it is a standby
SELECT pg_is_in_recovery();

-- On a replica: how far behind is it?
SELECT now() - pg_last_xact_replay_timestamp() AS replay_delay;
```

---

## How It Works Internally

### Primary configuration (`docker-compose.yml` `-c` flags)

| Setting | Value | Purpose |
|---|---|---|
| `wal_level` | `replica` | Enables WAL streaming to standbys |
| `max_wal_senders` | `10` | Max concurrent replication connections |
| `wal_keep_size` | `256 MB` | Keep WAL segments so slow replicas can catch up |
| `synchronous_standby_names` | `replica_sync` | The named standby must confirm before write returns |

### Replica bootstrap (`replica/setup.sh`)

1. Waits for the primary with `pg_isready`
2. Clones the entire primary data directory with `pg_basebackup --wal-method=stream`
3. Creates `standby.signal` — PostgreSQL 12+ uses this file to enter hot-standby mode
4. Writes `primary_conninfo` to `postgresql.auto.conf` with the correct `application_name`
5. Starts `postgres` via `gosu postgres postgres -D $PGDATA`

The `application_name` in `primary_conninfo` is how the primary knows which standby
is the designated synchronous one (it matches `synchronous_standby_names`).

---

## Cleanup

```bash
# Stop containers but keep volumes (fast restart)
docker compose down

# Full reset — deletes all data so you start from scratch
docker compose down -v
```

After `down -v`, `docker compose up -d` re-runs the full bootstrap from scratch.

---

## File Structure

```
replication_demo/
├── docker-compose.yml          Three-node cluster definition
├── primary/
│   ├── init.sql                Creates replication user + demo table
│   └── pg_hba.conf             Allows replication connections from Docker network
├── replica/
│   └── setup.sh                Clones primary and starts each standby
└── scripts/
    ├── 01_check_replication.sh Replication topology and lag
    ├── 02_write_and_read.sh    Write on primary, read from replicas
    ├── 03_demo_sync_vs_async.sh  Pause replicas to show blocking vs non-blocking writes
    └── 04_demo_failover.sh     Promote sync replica after primary failure
```
