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

## Exact server boundaries

The primary-side API is a protocol/session toolkit, not a WAL-retention or
logical-decoding server. In particular, it has no persistent replication-slot
catalog, WAL retention policy keyed by restart LSN, timeline state machine,
history-file store, promotion operation, publication catalog, or logical output
producer. The live primary test can therefore validate a physical slot name in
`START_REPLICATION`, but it cannot truthfully claim slot persistence or retention.
For the same reason, a subscription worker or `pg_recvlogical` cannot consume
from Flyology yet, and promotion/timeline-history behavior has no production
implementation to test.

## Prioritized follow-up

1. Add an application-owned primary state interface for persistent physical and
   logical slots, including confirmed/restart LSN durability and WAL retention;
   then test restart and duplicate bounds against that state rather than only a
   real PostgreSQL source slot.
2. Persist prepared consumer state and prove it survives a consumer process
   restart between `Prepare`/`StreamPrepare` and `CommitPrepared` or
   `RollbackPrepared`.
3. Add timeline and history callbacks plus promotion state, then run a promoted
   real standby through `TIMELINE_HISTORY` and a new timeline's WAL.
4. Once a logical output producer exists, use `pg_recvlogical` first, followed
   by a real subscription worker, as the primary-side logical oracle.
