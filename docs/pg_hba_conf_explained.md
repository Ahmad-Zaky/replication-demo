# pg_hba.conf — Host-Based Authentication Explained

## What is `pg_hba.conf`?

`pg_hba.conf` (Host-Based Authentication) is PostgreSQL's access control file. It controls **who can connect, from where, and how they must authenticate**. PostgreSQL reads it top-to-bottom and uses the **first matching rule** — order matters.

---

## Column Structure

```
TYPE    DATABASE    USER        ADDRESS         METHOD
```

| Column | Meaning |
|---|---|
| **TYPE** | How the connection arrives (`local` = Unix socket, `host` = TCP/IP) |
| **DATABASE** | Which database(s) the rule applies to |
| **USER** | Which PostgreSQL user(s) the rule applies to |
| **ADDRESS** | Client IP/CIDR range (only for `host` entries) |
| **METHOD** | How to authenticate the connection |

---

## This Project's Config ([primary/pg_hba.conf](../primary/pg_hba.conf))

```
# TYPE  DATABASE    USER          ADDRESS         METHOD

# Local Unix-socket connections (used by init scripts)
local   all         all                           trust

# Loopback connections
host    all         all           127.0.0.1/32    trust
host    all         all           ::1/128         trust

# All hosts in the Docker network → password required
host    all         all           0.0.0.0/0       md5

# Replication connections from replicas (also in Docker network)
host    replication replicator    0.0.0.0/0       md5
```

---

## Entry-by-Entry Breakdown

### 1. Local Unix socket — trust
```
local   all   all   trust
```
Connections via the Unix domain socket (same machine, no network) are let in without a password. Used by `pg_ctl`, init scripts, and the `postgres` OS user running inside the container.

---

### 2. Loopback TCP (IPv4 and IPv6) — trust
```
host   all   all   127.0.0.1/32   trust
host   all   all   ::1/128        trust
```
TCP connections from `localhost` (both IPv4 and IPv6) are trusted without a password. Useful for local tooling and health checks running inside the same container.

---

### 3. Any host on the Docker network — md5
```
host   all   all   0.0.0.0/0   md5
```
Any TCP connection from any IP must authenticate with an MD5-hashed password. This is the catch-all rule for external clients connecting to the primary over the Docker network.

---

### 4. Replication connections — md5
```
host   replication   replicator   0.0.0.0/0   md5
```
The special `replication` pseudo-database enables streaming replication connections. Only the `replicator` user may connect for this purpose, from any IP, and must supply a password. This is the rule that allows the replica to pull the WAL stream from the primary.

---

## Why Order Matters

The loopback `trust` rules appear **before** the `0.0.0.0/0 md5` rule. So localhost connections skip the password check because they match first. If the rules were reversed, localhost connections would also require md5 authentication.

---

## Authentication Methods Reference

| Method | Description |
|---|---|
| `trust` | Allow without any password |
| `md5` | Require MD5-hashed password |
| `scram-sha-256` | Require SCRAM-SHA-256 password (stronger than md5) |
| `reject` | Always deny |
| `peer` | Match OS username to PostgreSQL username (Unix socket only) |
