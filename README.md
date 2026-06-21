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

The ten demo scripts are numbered to follow the **flow of the book's Replication
chapter**, from basic leader/follower mechanics through to the failure modes:

| # | Book section | Script demonstrates |
|---|---|---|
| 01 | Leaders and Followers | Replication topology, `sync_state`, and lag from the leader's view |
| 02 | Leaders and Followers | Writes go to the leader; reads from followers; followers are read-only |
| 03 | Synchronous vs Asynchronous Replication | A sync follower blocks the write; an async one doesn't |
| 04 | Setting Up New Followers | Seed a brand-new empty node from a base backup, then stream the gap |
| 05 | Handling Node Outages → Follower failure | Catch-up recovery after a **network** interruption |
| 06 | Handling Node Outages → Follower failure | Catch-up recovery after a follower **crash/restart** (recover from its own log) |
| 07 | Handling Node Outages → Follower failure | The leader's WAL-retention dilemma: `wal_keep_size` vs a replication slot |
| 08 | Handling Node Outages → Leader failure | Manual failover: promote a follower to new leader |
| 09 | Handling Node Outages → Leader failure | Pick the most up-to-date follower (highest replay LSN) before promoting |
| 10 | Handling Node Outages → Leader failure | Async failover discards "committed" writes (promoting a stale follower) |

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

## Resetting to a Clean State

Some demos deliberately change the cluster — they pause containers (script 03),
start an extra node (script 04), or stop and promote a node (scripts 08 and 10).
**Always reset to a clean three-node cluster before re-running a demo**, otherwise
scripts may hang or behave unexpectedly.

### The one command that always works

```bash
docker compose --profile newfollower down -v && docker compose up -d
```

This wipes all data volumes and rebuilds the full cluster from scratch (re-running
the replica bootstrap). Then wait ~20–30 s for the replicas to clone and verify:

```bash
bash scripts/01_check_replication.sh
# Expect two rows: one sync_state = sync, one sync_state = async
```

> **Why `--profile newfollower`?** Script 04 starts an extra, profile-gated node
> (`pg_replica_new`). A plain `docker compose down -v` ignores profiled services,
> so that node and its volumes would survive the reset. Including the profile
> guarantees a clean slate; the flag is harmless if you never ran script 04. If
> you never start the new-follower node, a plain `docker compose down -v` is equivalent.

A copy-paste "reset and verify" block:

```bash
docker compose --profile newfollower down -v && docker compose up -d
# wait until both replicas finish cloning
until bash scripts/01_check_replication.sh 2>/dev/null | grep -q async; do sleep 2; done
bash scripts/01_check_replication.sh
```

### When do I need to reset?

| After running | State left behind | Reset needed before re-running? |
|---|---|---|
| Script 01 / 02 | None (read-only / single write) | No |
| Script 03 | Containers unpaused again, but extra demo rows remain | Only if you want clean data |
| Script 04 | **Extra node `pg_replica_new` (5435) left running**; extra demo rows remain | To remove the extra node — use the profile-aware reset |
| Script 05 | Network reconnected, follower caught up, extra demo rows remain | Only if you want clean data |
| Script 06 | Follower restarted and caught up, extra demo rows remain | Only if you want clean data |
| Script 07 | Demo replication slot created then dropped; extra demo rows remain | Only if you want clean data |
| Script 08 | **Primary stopped, sync replica promoted, sync requirement cleared** | **Yes — always** |
| Script 09 | Replay delay cleared, follower caught up, extra demo rows remain | Only if you want clean data |
| Script 10 | **Primary stopped, async replica promoted, writes lost** | **Yes — always** |

> **Scripts 08 and 10 are destructive to the topology.** Once you promote a
> replica, the only supported way back to the original three-node cluster is the
> full reset command above.

### Lighter resets (when volumes are still good)

```bash
# Just unpause any paused containers (e.g. if a demo was interrupted)
docker unpause pg_replica_sync pg_replica_async 2>/dev/null || true

# Restart containers but KEEP data (fast; does NOT undo a promotion)
docker compose restart
```

Use the full `down -v` reset whenever in doubt — it is the only guaranteed clean slate.

---

## Demo Walkthrough

Run the scripts in order for a full tour — the numbering follows the **flow of the
book's Replication chapter**, from basic leader/follower mechanics to the failure
modes. Each script names the *DDIA* section it illustrates.

## Leaders and Followers

> *"Each node that stores a copy of the database is called a replica... one of the
> replicas is designated the leader. When clients want to write to the database,
> they must send their requests to the leader... The other replicas are known as
> followers. Whenever the leader writes new data..., it also sends the data change
> to all of its followers."* — DDIA, **Leaders and Followers**

The two scripts here establish the baseline: one writable leader, two read-only
followers receiving its change stream.

### Script 01 — Check replication status

```bash
bash scripts/01_check_replication.sh
```

Shows:
- Which replicas are connected to the primary
- Their `sync_state` (`sync` vs `async`)
- Replication lag in bytes
- Whether each replica is in recovery (standby) mode

> **Reset:** ✅ not needed — read-only, changes nothing.

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

> **Reset:** ✅ not needed — just adds one row; the topology is unchanged.

## Synchronous vs Asynchronous Replication

> *"The advantage of synchronous replication is that the follower is guaranteed to
> have an up-to-date copy of the data... The disadvantage is that if the
> synchronous follower doesn't respond..., the write cannot be processed."* — DDIA,
> **Synchronous Versus Asynchronous Replication**

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

> **Reset:** ✅ not needed — the script re-unpauses both containers and they catch
> up. It only leaves a few extra rows; do a [full reset](#resetting-to-a-clean-state)
> if you want clean data.

## Setting Up New Followers

> *"Take a consistent snapshot of the leader's database at some point in time...
> Copy the snapshot to the new follower node. The follower connects to the leader
> and requests all the data changes that have happened since the snapshot was
> taken... When the follower has processed the backlog of data changes since the
> snapshot, we say it has caught up."* — DDIA, **Setting Up New Followers**

### Script 04 — New follower bootstrapped from a backup

```bash
bash scripts/04_new_follower_from_backup.sh 2000 2000   # historical, post-backup
```

```
  ── on the PRIMARY ───────────────────────────────────────────────────────────►
  write HISTORICAL rows ──►  ● take base backup (snapshot @ LSN)  ──► write POST rows
                            (saved to the shared /backup volume)

  ── the NEW empty node (pg_replica_new, port 5435) ───────────────────────────►
        restore snapshot from backup        then stream changes since the snapshot
        ┌───────────────────────────┐       ┌──────────────────────────────────┐
        │ HISTORICAL rows (in backup)│  ──►  │ + POST rows (streamed from leader)│
        └───────────────────────────┘       └──────────────────────────────────┘
                          result: from_backup = 2000, streamed = 2000  ✓
```

**What it does:** writes "historical" rows, takes a `pg_basebackup` snapshot into a
shared volume, writes *more* rows after the snapshot, then starts a **brand-new,
empty** node that **restores from the backup** (a plain copy, not a live clone) and
streams everything committed since. It finishes by proving the new follower holds
**both** the backup data and the streamed-since-backup data, and now appears in the
leader's `pg_stat_replication`. This is the exact snapshot → copy → catch-up
sequence the book describes for adding a follower without locking the leader.

> **The new node is profile-gated** (`profiles: ["newfollower"]` in
> `docker-compose.yml`), so a normal `docker compose up -d` never starts it — only
> script 04 does. Its bootstrap lives in `replica/restore_from_backup.sh`, which
> restores from `$BACKUP_DIR` instead of cloning.

> **Reset:** ⚠️ needed afterwards — this leaves the extra `pg_replica_new` node
> (port 5435) running. Use the [profile-aware reset](#the-one-command-that-always-works)
> (`docker compose --profile newfollower down -v && docker compose up -d`) so the
> extra node and its volumes are removed.

---

## Handling Node Outages

> *"Any node in the system can go down... our goal is to keep the system as a
> whole running despite individual node failures."* — DDIA, **Handling Node Outages**

Scripts 05–10 cover the two failure cases the book lays out: a **follower** going
down (scripts 05–07) and the **leader** going down (scripts 08–10).

### Follower failure: Catch-up recovery

> *"If a follower crashes and is restarted, or if the network between the leader
> and the follower is temporarily interrupted... from its log, it knows the last
> transaction that was processed before the fault occurred. Thus, the follower can
> connect to the leader and request all the data changes that occurred during the
> time when the follower was disconnected."* — DDIA, **Follower failure: Catch-up
> recovery**

#### Script 05 — Catch-up recovery after a network interruption

```bash
bash scripts/05_demo_catchup_recovery.sh 5000   # backlog size is optional
```

This is the **"network temporarily interrupted"** half of the quote above.

```
  time ──────────────────────────────────────────────────────────────────►

  PRIMARY    │■■■■│■■■■│■■■■│■■■■│■■■■│■■■■│■■■■│  keeps accepting writes
                  ╳ network cut          ╳ healed
  ASYNC      │■■■■│                       │····replay backlog····│■■■■│
  REPLICA      caught up   FROZEN / behind      catches up from leader's
                            (data + log intact)  retained WAL — no re-clone
```

**What it does:** cuts the async follower off the Docker network (the book's
"network temporarily interrupted" case), writes a backlog to the primary while it
is isolated, then reconnects it and watches it **resume streaming from its last
LSN** — pure catch-up from the log.

> **Network cut vs. container restart.** This script demonstrates the
> *network-interruption* case, so the follower process stays up the whole time.
> Script 06 demonstrates the *crash/restart* case (`docker stop` / `docker start`).
> Both use the **async** follower: cutting off the **sync** follower would block
> the primary's writes.

> **Reset:** ✅ not needed — the follower reconnects and catches up on its own;
> the topology is unchanged.

#### Script 06 — Catch-up recovery after a crash/restart

```bash
bash scripts/06_follower_restart_recovery.sh 5000   # backlog size is optional
```

This is the **"crashes and is restarted"** half of the same quote.

```
  ASYNC follower data dir (on disk volume)        leader retains the WAL
  ┌──────────────────────────────┐               ┌────────────────────────┐
  │ WAL log up to LSN 0/403F188   │  docker stop  │ keeps streaming, buffers│
  │ "last txn I processed"        │ ───────────►  │ 5000-row backlog        │
  └──────────────────────────────┘   docker start └────────────────────────┘
            │  1. read on-disk log → redo from last checkpoint (no re-clone)
            │  2. connect to leader, stream everything after 0/403F188
            ▼
        caught up, streaming live again
```

**What it does:** stops the follower **container**, writes a backlog to the
primary, then starts the container again. On boot it reads its on-disk WAL,
replays from its last checkpoint, then connects to the leader and streams the gap
— and the startup log proves it (`skipping clone`, `redo starts at…`,
`started streaming WAL from primary…`).

> **This needs an idempotent bootstrap.** `replica/setup.sh` detects an
> already-initialised data directory on restart and **skips the `pg_basebackup`
> re-clone**, so the follower genuinely recovers from its own log rather than being
> rebuilt from scratch.

> **Reset:** ✅ not needed — the follower restarts and catches up on its own;
> the topology is unchanged.

#### Script 07 — The leader's WAL-retention dilemma

```bash
bash scripts/07_demo_wal_retention.sh
```

The flip side of catch-up recovery: how long should the leader keep its log for a
follower that is still absent?

> *"...the leader faces a choice: retain the log until the follower recovers and
> catches up (at the risk of running out of disk space on the leader), or delete
> the log that the unavailable follower has not yet acknowledged (in which case the
> follower won't be able to recover from the log and will have to be restored from
> a backup when it comes back up)."* — DDIA, **Follower failure: Catch-up recovery**

```
                     follower is gone for a long time...
            ┌──────────────────────────┴──────────────────────────┐
   KEEP the log (replication slot)              DROP the log (wal_keep_size hit)
   restart_lsn pins WAL ████████████████►       only a bounded window is kept ██──┐
   ✅ follower always recoverable               ✅ disk stays safe                 │
   ❌ WAL grows → disk may FILL UP              ❌ follower must re-clone from backup
```

**What it does:** read-only/observational. Shows the bounded `wal_keep_size` this
demo uses, then creates a physical **replication slot** (with WAL reserved), churns
some WAL, and shows the slot pinning ~48 MB that the primary may not recycle while
its follower is absent. It **drops the slot at the end** so no WAL stays pinned.

> **Reset:** ✅ not needed — it drops the demo slot it created and leaves only a few
> extra rows.

### Leader failure: Failover

> *"Handling a failure of the leader is trickier. One of the followers needs to be
> promoted to be the new leader, clients need to be reconfigured to send their
> writes to the new leader, and the other followers need to start consuming data
> changes from the new leader. This process is called failover."* — DDIA, **Leader
> failure: Failover**

#### Script 08 — Manual failover (promote a replica)

```bash
bash scripts/08_demo_failover.sh
```

The happy path: promote the **sync** follower, which by definition held every
acknowledged write, so nothing is lost.

```
  before                              after `pg_ctl promote`
  PRIMARY (pg_primary) ✗ crash        SYNC replica ──► NEW PRIMARY (read + write)
     │                                ASYNC replica still points at the OLD leader
  SYNC ◄── streams ── ASYNC           (a real failover would re-point it here)
```

**What it does:**

1. Stops `pg_primary` (simulates a crash).
2. Runs `pg_ctl promote` on `pg_replica_sync` — it stops being a standby and
   becomes a read/write leader.
3. Clears `synchronous_standby_names` on the new primary so its writes don't block
   waiting for a synchronous standby that no longer exists.
4. Writes a row to the newly promoted primary to confirm it accepts writes.

Scripts 09 and 10 then show what the book warns about when you *don't* promote such
an up-to-date follower.

> **Reset:** ⚠️ required afterwards — **destructive**: the primary is stopped and
> the sync replica promoted, so the cluster topology is permanently changed. You
> **must** [reset to a clean state](#resetting-to-a-clean-state)
> (`docker compose --profile newfollower down -v && docker compose up -d`) before
> running any other demo.

#### Script 09 — Pick the most up-to-date follower

```bash
bash scripts/09_demo_choose_new_leader.sh 30s 2000   # delay & burst optional
```

Maps to *DDIA* § **"Leader failure: Failover"** (choosing a new leader):

> *"The best candidate for leadership is usually the replica with the most
> up-to-date data changes from the old leader... With asynchronous replication,
> you can pick the follower with the highest log sequence number. This minimizes
> the amount of data that is lost during failover."*

```
                       ┌─────────── which follower do we promote? ───────────┐
   PRIMARY  current WAL ●───────────────────────────────────────────────────►
                                                          replay_lsn
   SYNC  replica   ●──────────────────────────────────────────────● 0 behind ✓ promote
   ASYNC replica   ●────────────────────────────● 295 KB behind   ✗ would lose data
                                                  └── lag = data you'd discard ──┘
```

**What it does:** deliberately makes the async follower lag
(`recovery_min_apply_delay`), writes a burst to the primary, then reads **one
consistent snapshot** of each follower's `replay_lsn` from `pg_stat_replication`
and prints a verdict: promote the follower with the highest LSN. It does **not**
fail over — it shows the *decision* you must make first (scripts 08 and 10 do the
promotion). The artificial delay is cleared on exit so the follower catches up.

> **Reset:** ✅ not needed — it clears the artificial replay delay on exit and the
> follower catches up; nothing is promoted.

#### Script 10 — Async failover discards "committed" writes

```bash
bash scripts/10_demo_async_failover_data_loss.sh 5   # number of critical rows
```

Maps to *DDIA* § **"Leader failure: Failover"** (the danger of async) — what
happens when you ignore the rule from script 09:

> *"If asynchronous replication is used, the new leader may not have received all
> the writes from the old leader before it failed... The most common solution is
> for the old leader's unreplicated writes to simply be discarded, which means that
> writes you believed to be committed weren't durable after all."*

```
  1. partition ASYNC ╳        2. commit 5 CRITICAL rows (sync acks → "durable")
                                  PRIMARY ✅  SYNC ✅  ASYNC ✗ (never received)
  3. PRIMARY crashes 💥        4. promote the STALE async follower
                                  ┌────────────────────────────────────┐
                                  │  NEW LEADER is missing those 5 rows │  💥 data loss
                                  └────────────────────────────────────┘
```

**What it does:** partitions the async follower, commits "critical" rows that
succeed (the sync replica acks them, so the client is told they're durable),
crashes the primary, then promotes the **stale** async follower. The critical
rows are gone on the new leader — the exact failure the book warns about.

> **A note on realism:** the script uses a network partition, **not**
> `docker pause`. A paused container's kernel still buffers the incoming WAL in
> its socket and applies it on unpause, so the writes would *not* actually be lost.
> A real partition severs the stream — which is the whole point of the demo.

> **Reset:** ⚠️ required afterwards — **destructive**: the primary is stopped and
> the (stale) async replica promoted, so the cluster topology is permanently
> changed. You **must** [reset to a clean state](#resetting-to-a-clean-state)
> (`docker compose --profile newfollower down -v && docker compose up -d`) before
> running any other demo.

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

# New follower from backup (read-only) — only running after script 04
psql -h localhost -p 5435 -U postgres -d demo

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

1. **Idempotency check** — if the data directory is already initialised (`PG_VERSION`
   present), this is a **restart**: skip the clone and start straight away, so the
   follower recovers from its own log (see script 06). The steps below run only on a
   first, empty boot.
2. Waits for the primary with `pg_isready`
3. Clones the entire primary data directory with `pg_basebackup --wal-method=stream`
4. Creates `standby.signal` — PostgreSQL 12+ uses this file to enter hot-standby mode
5. Writes `primary_conninfo` to `postgresql.auto.conf` with the correct `application_name`
6. Starts `postgres` via `gosu postgres postgres -D $PGDATA`

The `application_name` in `primary_conninfo` is how the primary knows which standby
is the designated synchronous one (it matches `synchronous_standby_names`).

A second bootstrap, `replica/restore_from_backup.sh`, is used only by the on-demand
`pg_replica_new` node: instead of a live clone it **restores from a base backup**
already sitting in `$BACKUP_DIR`, then streams the changes since (see script 04).

---

## Cleanup

```bash
# Stop containers but keep volumes (fast restart)
docker compose down

# Full reset — deletes all data so you start from scratch
# (include --profile newfollower so script 04's extra node is removed too)
docker compose --profile newfollower down -v
```

After `down -v`, `docker compose up -d` re-runs the full bootstrap from scratch.

---

## File Structure

```
replication_demo/
├── docker-compose.yml          Three-node cluster + on-demand new-follower node
├── primary/
│   ├── init.sql                Creates replication user + demo table
│   └── pg_hba.conf             Allows replication connections from Docker network
├── replica/
│   ├── setup.sh                Clones primary and starts each standby (idempotent on restart)
│   └── restore_from_backup.sh  Bootstraps pg_replica_new from a base backup (script 04)
└── scripts/                                  # numbered to follow the book's flow
    ├── 01_check_replication.sh             Leaders & Followers — topology and lag
    ├── 02_write_and_read.sh                Leaders & Followers — write on leader, read on followers
    ├── 03_demo_sync_vs_async.sh            Sync vs Async — blocking vs non-blocking writes
    ├── 04_new_follower_from_backup.sh      Setting Up New Followers — seed from a backup, then stream
    ├── 05_demo_catchup_recovery.sh         Follower failure — catch-up after a network interruption
    ├── 06_follower_restart_recovery.sh     Follower failure — catch-up after a crash/restart
    ├── 07_demo_wal_retention.sh            Follower failure — wal_keep_size vs replication slot
    ├── 08_demo_failover.sh                 Leader failure — manual failover (promote sync replica)
    ├── 09_demo_choose_new_leader.sh        Leader failure — pick the most up-to-date follower
    └── 10_demo_async_failover_data_loss.sh Leader failure — async failover discards committed writes
```
