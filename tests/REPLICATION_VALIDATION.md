# Replication validation boundaries

The live matrix is deliberately split between behavior the current public API
can prove and behavior that needs new primary-server functionality. It runs as
five independent CI jobs for PostgreSQL 14.23, 15.18, 16.14, 17.10, and 18.4.
Each PostgreSQL installation is cached by exact release, platform, architecture,
and build-script content. Failed jobs retain only focused PostgreSQL, client,
server, standby, and transport-injection logs; data directories and generated
TLS private keys are excluded.

## Evidence in the current matrix

- Every committed `pgoutput` scenario applies decoded row changes to a common
  deterministic state oracle. State becomes visible only at `Commit`,
  `StreamCommit`, or `CommitPrepared`; aborted streams and rolled-back prepared
  transactions leave it unchanged. Exact row IDs, payloads, markers, enum
  values, and transaction counts are checked for regular and streamed changes,
  two-phase commit and rollback, binary tuples, and origin-tagged transactions.
  The v1 flow additionally covers update, delete, truncate flags, NULL,
  replica-identity-full old tuples, a large TOAST value represented as unchanged
  by an update, and a transactional message.
- The reconnect flow acknowledges a checkpoint commit by its logical end LSN,
  verifies the slot persisted that acknowledgement, and interrupts a 1,000-row
  transaction three ways: a deliberate disconnect after row 50, a seeded TCP
  reset after 20,000 encrypted server bytes, and a one-second transport stall
  against a 200-millisecond receive timeout. Each creates a fresh process,
  session, and decoder and requires rows 800001 through 801000 in exact order
  before advancing the acknowledgement. The acknowledged checkpoint may be
  replayed once; a second replay or any duplicate or gap in the interrupted
  transaction fails the oracle.
- Real PostgreSQL standbys consume WAL from Flyology across a WAL segment
  boundary, name a physical slot using PostgreSQL's quoted identifier syntax,
  replay the target row, and report received, flushed, and applied LSNs exactly
  equal to the advertised primary end. Flyology initiates `CopyDone`, drains
  crossed feedback until the standby's `CopyDone`, sends `CommandComplete` and
  `ReadyForQuery`, and serves the restarted standby data directory again. The
  standby connects with SCRAM-SHA-256 over TLS using `sslmode=verify-full`, a
  test CA, and a hostname-verified server certificate. With periodic standby
  feedback configured to ten seconds, a second reply-requesting keepalive with
  no intervening WAL requires another exact-LSN response within two seconds.
- Supported releases exercise streamed transactions, two-phase prepare, commit
  and rollback, parallel abort, binary tuples, and origins against real
  PostgreSQL through that same committed-state model while also validating the
  decoded protocol metadata.
- Both replication directions run through a seeded TCP proxy with 4 KiB socket
  buffers, bounded reads, deterministic short writes, and per-write delay. The
  proxy records byte and write counts and the injection seed, and the matrix
  requires bidirectional traffic. This adversity remains below TLS, so the real
  TLS record and replication framing paths absorb the fragmentation and
  backpressure.
- Every supported `pg_recvlogical` consumes a transaction from Flyology's
  stateful `pgoutput` producer through the managed-primary API. The real client
  sends libpq's quoted logical option names, writes the exact marker row through
  end position `0/140`, returns feedback, and the application-owned memory slot
  persists `confirmed_lsn = 0/140` before COPY BOTH finishes.
- The memory-store conformance suite covers slot creation, exclusive generation
  leases, stale-writer rejection, monotonic acknowledgement, exact WAL reads and
  retention, timeline promotion/history, prepared-state recovery through a new
  consumer instance, idempotent target-applied marking, and removal only after
  source acknowledgement.

## Exact server boundaries

Flyology now owns the replication state machines but deliberately does not own a
durability technology. Applications supply slot, WAL, timeline, and prepared
stores through explicit interfaces. The included bounded memory store proves
the contracts and replacement-instance behavior, but cannot establish survival
across an operating-system process crash. Production durability, atomic writes,
cross-process locking, and repair remain obligations of the supplied backend.

The managed logical primary produces `pgoutput` from an application change
source and interoperates with `pg_recvlogical`. A PostgreSQL subscription worker
still needs the normal SQL publication/subscription catalog surface and initial
table synchronization, which the replication-mode managed primary does not
attempt to emulate.

## Prioritized follow-up

1. Supply at least one crash-durable backend outside this crate and run the
   conformance suite across real process termination, truncated writes, locking,
   repair, and target-commit/source-ack races.
2. Run a promoted real standby through the managed timeline interface,
   `TIMELINE_HISTORY`, and WAL on the newly persisted timeline.
3. Compose the managed logical primary with a normal SQL catalog and snapshot
   provider, then use a real PostgreSQL subscription worker as the end-to-end
   initial-copy and continuing-change oracle.
