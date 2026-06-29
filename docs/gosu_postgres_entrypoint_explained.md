# Container Entrypoint Command — `exec gosu postgres postgres -D "$PGDATA"`

## The Command

```bash
exec gosu postgres postgres -D "$PGDATA"
```

Found in [replica/setup.sh](../replica/setup.sh).

---

## Part-by-Part Breakdown

| Part | What it does |
|---|---|
| `exec` | Replaces the current shell process with the following command |
| `gosu postgres` | Drops privileges from root to the `postgres` OS user |
| `postgres` | The PostgreSQL server binary |
| `-D "$PGDATA"` | Points PostgreSQL to its data directory (e.g. `/var/lib/postgresql/data`) |

---

## Why `exec` Instead of Just Running the Command?

Without `exec`, the shell spawns PostgreSQL as a child process:

```
PID 1: shell (entrypoint.sh)
  └── PID 2: postgres
```

With `exec`, the shell *becomes* PostgreSQL:

```
PID 1: postgres   ← no shell wrapper left behind
```

This matters in containers for two reasons:

1. **Signal forwarding** — Docker sends `SIGTERM` to PID 1 when stopping a container. If PID 1 is a shell, the signal may not reach PostgreSQL, causing a forceful kill instead of a clean shutdown.
2. **Process hygiene** — No zombie or orphan shell process; PostgreSQL owns PID 1 directly.

---

## Why `gosu` Instead of `su` or `sudo`?

`su` and `sudo` both leave a wrapper process running. `gosu` is designed for containers: it does an internal `exec` so it disappears after switching users, leaving only the target process with no parent overhead.

```
# sudo -u postgres postgres  →  sudo (still running) → postgres
# gosu postgres postgres      →  postgres (gosu is gone)
```

---

## What `$PGDATA` Contains

PostgreSQL reads everything it needs from this directory:

| File / Dir | Purpose |
|---|---|
| `postgresql.conf` | Server configuration (memory, connections, replication, etc.) |
| `pg_hba.conf` | Client authentication rules |
| `pg_wal/` | Write-ahead log segments |
| `base/` | Actual table and index data |
| `PG_VERSION` | Records the major version |

---

## Summary

This single line safely hands off a container from a root-owned shell to the PostgreSQL server process running as the unprivileged `postgres` user, with clean signal handling and no leftover wrapper processes — the standard pattern used in the official PostgreSQL Docker image.
