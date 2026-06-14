-- Runs once when the primary is first initialized.

-- Replication user used by both standbys
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pass';

-- Demo table we'll use to observe replication
CREATE TABLE events (
  id        SERIAL PRIMARY KEY,
  label     TEXT        NOT NULL,
  written_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed rows so replicas have data from the moment they connect
INSERT INTO events (label) VALUES
  ('Primary initialized'),
  ('Replication user created');

-- Enable synchronous replication AFTER all init work is done.
-- Setting this here (via ALTER SYSTEM → postgresql.auto.conf) rather than as a
-- -c flag avoids a deadlock: the postgres entrypoint uses our full command for
-- its temporary init server, so a -c flag would cause CREATE DATABASE to block
-- waiting for replica_sync before the replica even exists.
ALTER SYSTEM SET synchronous_standby_names = 'replica_sync';
