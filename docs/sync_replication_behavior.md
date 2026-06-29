# PostgreSQL Synchronous Replication — Behavior & Edge Cases

## 1. What happens when the primary doesn't get the ACK from the sync replica?

The commit **blocks indefinitely** on the primary.

The client's `COMMIT` call hangs — the primary has written the WAL to its own disk but will not return success to the client until it receives confirmation that the sync replica has written (and optionally flushed) the WAL. The session is stuck waiting.

**No timeout by default.** PostgreSQL does not give up and fall back to async mode on its own.

### When the sync replica comes back

1. The replica reconnects and resumes streaming WAL from the primary.
2. The primary sends it the WAL segments that were waiting.
3. The replica writes them and sends back the ACK.
4. The blocked `COMMIT` on the primary immediately unblocks and returns success to the client.

The commit was never lost — the WAL was already written on the primary's disk. The replica just needed to catch up and confirm.

### The escape hatch

If the replica is down for too long and you need the primary to accept writes again:

```sql
-- Drop sync requirement, all pending and future commits proceed async
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```

---

## 2. Can the backend signal a timeout on the blocked commit?

Yes, but the mechanism matters.

### Option 1: `statement_timeout` (dangerous)

```sql
SET statement_timeout = '5000'; -- 5 seconds
COMMIT;
```

If the sync replica doesn't ACK within 5s, PostgreSQL raises:
```
ERROR: canceling statement due to statement timeout
```

**The danger (phantom commit):** By the time the timeout fires, the commit WAL record is already written to the primary's disk — the transaction **is committed on the primary**. The client sees an error but the data is there. If the backend retries, you get a duplicate.

### Option 2: `SET LOCAL synchronous_commit` — the clean escape hatch

```sql
BEGIN;
SET LOCAL synchronous_commit = local;  -- or 'off'
-- ... your writes ...
COMMIT; -- returns immediately after writing to primary's WAL, no standby wait
```

| Value | Primary waits for... |
|---|---|
| `remote_apply` | Replica to **replay** the WAL (strongest) |
| `on` *(default)* | Replica to **flush** WAL to its disk |
| `remote_write` | Replica to **receive** WAL into OS buffer (not flushed) |
| `local` | Primary's **own** disk flush only — replica is ignored |
| `off` | Nothing (not even primary's disk flush) |

No phantom commit risk because you're consciously choosing not to wait.

### Option 3: Connection/socket timeout (application level)

If the backend sets a socket read timeout and the connection is cut, the same phantom commit problem applies — the commit may have landed on the primary even though the connection dropped.

### Recommended approach

Use `statement_timeout` as a safety net, but design writes that need guaranteed low latency to use `SET LOCAL synchronous_commit = local` explicitly.

---

## 3. Does `SET LOCAL synchronous_commit = local` make the replica no longer synchronous?

**Yes, for that transaction only.**

`synchronous_standby_names` defines **who** the sync replica is. `synchronous_commit` defines **how much** you wait for them, on a per-transaction basis.

- `SET LOCAL synchronous_commit = local` tells the primary: *flush to my own WAL, then return to the client — don't wait for `replica_sync` at all.*
- The replica is **not reconfigured** — it is still listed in `synchronous_standby_names` and still streams WAL as usual.
- Other concurrent transactions on the primary that don't set this still block and wait for the replica's ACK normally.

---

## 4. What if the sync replica crashes permanently and never comes back?

### What PostgreSQL does automatically: nothing

When `replica_sync` crashes, the WAL sender process on the primary detects the disconnection. PostgreSQL checks: *"do I still have a standby satisfying `synchronous_standby_names`?"* — the answer is no, so the blocked commit **stays blocked**. PostgreSQL does not automatically fall back to async. The primary is frozen for writes.

### What must happen: operator intervention

```sql
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
```

The moment `pg_reload_conf()` runs, PostgreSQL re-evaluates the sync requirement, finds no standbys are required, and the blocked commit **immediately unblocks** and returns success to the client.

### The durability tradeoff at that moment

After clearing `synchronous_standby_names`:
- The committed data exists **only on the primary**.
- If the primary crashes before a new replica is provisioned and synced, that data is lost.
- Since the replica is already permanently gone, this is unavoidable — you are choosing availability over the now-impossible durability guarantee.

### Recovery steps

1. Provision a new replica (`scripts/04_new_follower_from_backup.sh`).
2. Let it catch up to the primary.
3. Re-enable `synchronous_standby_names` once it is in sync.

### Avoiding this single point of failure

Use a quorum configuration so one replica's permanent loss doesn't freeze the primary:

```sql
synchronous_standby_names = 'ANY 1 (replica1, replica2)'
```

If one replica permanently dies, the other satisfies the sync requirement and the primary never blocks.
