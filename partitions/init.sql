-- Runs once when each partition LEADER is first initialized.
-- Every partition (poons, alice, bob, carol, dave) gets the same schema; each
-- one only ever stores the messages written by its own writer.

-- Replication user used by this partition's two replicas
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator_pass';

-- One row per chat message. vv is the message's version vector: written once by
-- the INSERT, never updated.
CREATE TABLE chat_log (
  run_id     TEXT        NOT NULL,
  part       TEXT        NOT NULL,   -- partition = the writer's own log
  seq        INT         NOT NULL,   -- position in that partition
  author     TEXT        NOT NULL,
  body       TEXT        NOT NULL,
  vv         JSONB       NOT NULL,   -- version vector {partition: seq}
  written_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (run_id, part, seq)
);

-- Same reason as primary/init.sql: enable synchronous replication only after
-- init is done, via ALTER SYSTEM, so the entrypoint's temporary init server
-- doesn't block waiting for a replica that doesn't exist yet.
ALTER SYSTEM SET synchronous_standby_names = 'replica_sync';
