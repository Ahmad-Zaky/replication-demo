# Cleaning Up Transient State After a Backup Restore

**File:** `replica/restore_from_backup.sh`, lines 51–53

```bash
# A backup may carry over transient state; clear anything that shouldn't ride
# along into a fresh standby start.
rm -f "$PGDATA/postmaster.pid" "$PGDATA/recovery.signal" "$PGDATA/standby.signal" 2>/dev/null || true
```

## Why This Step Exists

A backup snapshot is taken from a running server. That means the data directory can contain files that only make sense in the context of the *source* server. Carrying them into a fresh standby causes startup failures or incorrect behavior. This step removes three such files.

---

## Files Removed and Why

### `postmaster.pid`

PostgreSQL writes this file when it starts, recording its own process ID (and other metadata). On the next startup, if this file exists, Postgres assumes another instance is already running and refuses to start with an error like:

```
FATAL: lock file "postmaster.pid" already exists
```

A backup from a live primary always contains this file with the primary's PID, so it must be deleted before starting the replica.

---

### `recovery.signal`

An empty sentinel file (introduced in PostgreSQL 12) that tells Postgres to enter **one-shot recovery mode**: replay WAL until caught up, then promote itself to a normal read-write primary.

That is the wrong mode for a standby. A standby should keep following the primary indefinitely — promoting would split the cluster into two independent primaries.

---

### `standby.signal`

An empty sentinel file that tells Postgres to start as a **streaming replication standby** (continuous WAL replay, never self-promotes).

This file is deleted here even though it's the *desired* final state, because the version in the backup may embed stale connection info (e.g., it was taken from a server that was itself a standby pointing at a different primary). The setup script removes it here and re-creates it fresh — with the correct `primary_conninfo` pointing at this cluster's primary — in a later step.

---

## The `2>/dev/null || true` Idiom

- `2>/dev/null` — suppresses "No such file or directory" errors if any of the files are already absent.
- `|| true` — ensures the overall command exits with success regardless, so the script does not abort.

---

## Net Effect

After this step the data directory looks like a cold, never-started Postgres instance with no leftover process state, no recovery mode signal, and no stale standby configuration — ready to be wired up as a clean standby with fresh configuration.
