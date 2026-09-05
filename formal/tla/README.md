# pgoutput Producer ordering assurance

`PgoutputProducer.tla` models one atomic `Producer.Emit` call as one action.
It selects the ordering behavior for issues #56, #57, and #58 while preserving
the Producer's existing monotonic XLogData-envelope contract.

## Assurance boundary

- TLC explores two transaction identities and at most two stream segments per
  identity. These are qualification bounds, not implementation capacities.
- No fairness or liveness assumption is used. `Emit` is a synchronous caller-
  driven validator; this campaign checks safety and representative
  reachability.
- The model abstracts bytes to whether an accepted streamed message carries
  the active segment XID prefix. Exact pgoutput bytes remain covered by Ada
  codec tests.
- Allocation failure, transport behavior, cancellation, crash/retry, prepared
  transactions, and WAL persistence are outside this model.
- `PgoutputProducerProof.tla` quantifies over an arbitrary nonempty transaction
  set and has no transaction-count or segment-count bound. It proves only the
  ordering safety kernel; it is not a refinement proof of the Ada body.

## Required outcomes

- An XID-bearing data or transactional logical message inside a stream segment
  is accepted only with the segment XID, and its wire form carries that XID.
- Aborting a subtransaction does not complete the top-level streamed
  transaction. More than one streamed transaction can remain paused, and a
  regular transaction or another stream can run between segments.
- A nontransactional logical decoding message is accepted only while fully
  idle or between paused stream segments.
- A rejected action leaves the complete Producer state unchanged.

## Model-to-Ada map

| Model action | Ada operation/message |
| --- | --- |
| `BeginRegular` | `Producer.Emit (Make_Begin (...))` |
| `CommitRegular` | `Producer.Emit (Make_Commit (...))` |
| `StartStream` | `Producer.Emit (Make_Stream_Start (...))` |
| `StopStream` | `Producer.Emit (Make_Stream_Stop)` |
| `CommitStream` | `Producer.Emit (Make_Stream_Commit (...))` |
| `AbortStream` | `Producer.Emit (Make_Stream_Abort (...))` |
| `Data` | `Producer.Emit (Make_Insert (...))` |
| `LogicalMessage` | `Producer.Emit (Make_Logical_Decoding_Message (...))` |

The replay state maps `context`, `currentXid`, paused membership, and paused
recency to the private Encoder representation. Segment counters and the last-
action observation fields are adapter-owned history used to compare every
modeled transition. The adapter receives only materialized inputs; expected
outcomes and states remain trace-oracle data.

## Campaign artifacts

- `PgoutputProducer.cfg` exhausts the approved bounded state graph.
- `_56_broken`, `_57_broken`, and `_58_broken` each enable one filed behavior
  and must fail its intended invariant with the maintained counterexample.
- `_Replay.cfg` follows one deterministic path through rejection, XID-prefix,
  subabort continuation, transaction interleaving, multiple paused streams,
  and nontransactional-message cases. `WitnessPending` intentionally fails at
  the end so TLC emits the replay trace.
- The maintained formal check runs TLC, checks action coverage and expected
  negative failures, normalizes and byte-compares the replay trace, generates
  the typed Ada boundary twice, replays it, and requires all TLAPS obligations.
