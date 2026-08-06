# Replication validation boundaries

The live matrix is deliberately split between behavior the current public API
can prove and behavior that needs new primary-server functionality. It runs as
five independent CI jobs for PostgreSQL 14.23, 15.18, 16.14, 17.10, and 18.4.

## Evidence in the current matrix

- The committed `pgoutput` v1 flow applies all decoded row changes to pending
  state and publishes that state only at `Commit`. It covers inserts, updates,
  deletes, truncate flags, NULL, replica-identity-full old tuples, a large TOAST
  value represented as unchanged by an update, a transactional message, and an
  exact final-state comparison.
- The reconnect flow acknowledges a checkpoint commit by its logical end LSN,
  verifies the slot persisted that acknowledgement, disconnects after row 50
  of a 1,000-row transaction, creates a fresh session and decoder, and requires
  rows 800001 through 801000 in exact order before advancing the acknowledgement.
  The acknowledged checkpoint may be replayed once; a second replay or any
  duplicate or gap in the interrupted transaction fails the oracle.
- Real PostgreSQL standbys consume WAL from Flyology across a WAL segment
  boundary, name a physical slot using PostgreSQL's quoted identifier syntax,
  replay the target row, and report received, flushed, and applied LSNs exactly
  equal to the advertised primary end. Flyology initiates `CopyDone`, drains
  crossed feedback until the standby's `CopyDone`, sends `CommandComplete` and
  `ReadyForQuery`, and serves the restarted standby data directory again. The
  standby connects with SCRAM-SHA-256 over TLS using `sslmode=verify-full`, a
  test CA, and a hostname-verified server certificate.
- Supported releases still exercise streamed transactions, two-phase prepare,
  commit and rollback, parallel abort metadata, binary tuples, and origins
  against real PostgreSQL. These scenarios validate the complete decoded
  message metadata but do not yet feed the same committed-state model.

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
2. Generalize the committed-state apply oracle by transaction ID so streamed
   and two-phase transactions use the same exact-state comparison, including
   prepared state that survives a consumer restart.
3. Add timeline and history callbacks plus promotion state, then run a promoted
   real standby through `TIMELINE_HISTORY` and a new timeline's WAL.
4. Add deterministic adverse transports around both replication directions:
   fragmented frames, bounded slow-consumer backpressure, timeout and reset
   injection, and exact keepalive reply-request timing.
5. Once a logical output producer exists, use `pg_recvlogical` first, followed
   by a real subscription worker, as the primary-side logical oracle.
