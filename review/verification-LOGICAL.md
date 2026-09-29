# Adversarial verification: LOGICAL (pgoutput codec and Producer)

Every candidate was re-derived from the sources (`src/flyology-postgres-replication-logical.ads/.adb`,
`src/flyology-postgres-replication-logical-producer.ads/.adb`,
`src/flyology-postgres-replication-managed_primary.adb`) rather than from the
discovery text, and each survivor has a runnable program under
`tests/repros/src/`. All five survived refutation; one severity is corrected
upward and one finding is reclassified (behavior true, but it is a validation
gap that requires a design decision, not a contract violation).

## Documentation check (asked for explicitly)

- `README.md:366-372` says only: "`Logical.Producer` validates transaction
  ordering while encoding the existing typed messages as `pgoutput`." No
  narrowing.
- `src/flyology-postgres-replication-logical-producer.ads:1-60` documents the
  `Transaction_State` enum, `Emit`'s monotonic WAL envelope, and
  `Transaction`'s "active or paused streamed transaction identifier". It
  never states that only one transaction may be in flight, that interleaving
  is unsupported, or that a Stream Abort always terminates the top-level
  transaction. `tests/REPLICATION_VALIDATION.md` says nothing about producer
  ordering scope either.
- Therefore **none of LOGICAL-1..3 is a documented limitation.** The single
  `Current`/`XID` pair in the private record is an implementation choice, not
  a published contract. (LOGICAL-2 (b) is the closest to "implicit scope", and
  is discussed there.)

## Reachability

`Managed_Primary.Stream_Logical` (`src/flyology-postgres-replication-managed_primary.adb:255-272`)
takes whatever the application `Logical_Source` yields, calls
`Producer.Emit`, and hands the result straight to
`Replication_Sessions.Send_XLog_Data`. Anything the Producer accepts goes on
the wire to a real subscriber unmodified; anything it rejects aborts the
stream with `Protocol_Error`. There is no second validation layer.

---

### LOGICAL-1: Producer accepts a non-streamed data message inside an open stream segment and emits it without the xid prefix

**Verdict:** CONFIRMED (and the consequence is worse than the report claimed:
a *silent* misread, not only a rejection).

**Severity:** **P0** (report said P1).

**Repro:** `tests/repros/src/repro_logical_1.adb`

**Output** (`cd tests/repros && ./run.sh repro_logical_1`, exit status **1**):

```
  -- StreamStart bytes: 53 00 00 00 14 01
  -- producer state = STREAM_SEGMENT, consumer inside stream = TRUE
  -- Insert accepted inside the segment: 49 00 00 00 2a 4e 00 01 74 00 00 00 02 34 32
  --   producer state stays STREAM_SEGMENT
  --   in-stream consumer rejected those bytes: Insert must contain a new tuple
  -- Message accepted inside the segment: 4d 01 01 02 03 00 01 02 03 04 61 62 63 64 65 66 67 68 00 00 00 00 04 01 02 03 04
  --   in-stream consumer read xid = 16843267, transactional = FALSE
  --   in-stream consumer read LSN = 16#0102030461626364# (sent 16#0102030001020304#)
  --   in-stream consumer read prefix "efgh" (sent "abcdefgh")
  FAILED: Producer rejects an Insert without a streamed xid while a stream segment is open
  FAILED: bytes the Producer emits inside a segment are read back unchanged by an in-stream consumer (Insert)
  FAILED: Producer rejects a logical decoding message without a streamed xid while a stream segment is open
  FAILED: bytes the Producer emits inside a segment are read back unchanged by an in-stream consumer (Message)
BUG REPRODUCED: 4 failed expectation(s)
```

**Description:** In `Producer.Emit`
(`src/flyology-postgres-replication-logical-producer.adb:117-140`) the
stream check is one-directional: a message for which `Logical.Is_Streamed` is
True must be inside `Stream_Segment` with a matching XID, but a message
*inside* `Stream_Segment` is never required to be streamed. Every `Make_*`
constructor for the xid-bearing kinds derives `Streamed := Xid /= 0`
(`logical.adb:352`, `:366`, and siblings), and `Encode`'s `Append_Stream_Xid`
(`logical.adb:636-642`) writes the four-byte prefix only when `Item.Streamed`.
A caller who omits the defaulted `Xid` parameter — the default is `0` — while
the Producer itself is tracking an open segment therefore gets bytes with no
xid prefix, and `Producer.State` still reports `Stream_Segment`. This
conflicts with pgoutput, which sets `xid = txn->xid` whenever `in_streaming`
is set and prefixes every Relation/Type/Insert/Update/Delete/Truncate/Message
written between `S` and `E`; PostgreSQL's apply worker consumes those four
bytes unconditionally while `in_streamed_transaction` is set. The repro shows
both outcomes against this library's own stateful `Decoder` (the same state
machine a subscriber runs): the Insert is *rejected* ("Insert must contain a
new tuple"), and the logical decoding message is **silently misread** as a
different message — xid `16843267` invented out of the flags and LSN bytes,
`Transactional` flipped from True to False, LSN `0102030461626364` instead of
`0102030001020304`, prefix `"efgh"` instead of `"abcdefgh"`. Because
`Managed_Primary` sends the Producer's output verbatim, this is corrupted
data delivered to a live subscriber through the component whose only job is to
catch exactly this class of error, which is why the severity is raised to P0
under the "a real PostgreSQL subscriber would reject or misread the bytes"
clause. The one mitigating factor (and the reason the discovery report chose
P1) is that it takes a caller who omits `Xid`; but `Xid` is defaulted, the
Producer holds all the information needed to reject it, and the failure is
silent. Fix direction: inside `Stream_Segment`, require `Is_Streamed (Message)`
for `Logical_Decoding_Message | Relation_Message | Type_Message |
Insert_Message | Update_Message | Delete_Message | Truncate_Message`
(`Origin_Message` correctly carries no xid).

---

### LOGICAL-2: Producer models a single in-flight streamed XID and treats every Stream Abort as terminal

**Verdict:** CONFIRMED. Not a documented limitation (see the documentation
check above). Two distinct defects, both reproduced.

**Severity:** **P1** (agrees with the report). Part (a) is a plain modelling
error; part (b) is a scope gap that is still a wrong rejection of valid
pgoutput output.

**Repro:** `tests/repros/src/repro_logical_2.adb`

**Output** (`cd tests/repros && ./run.sh repro_logical_2`, exit status **1**):

```
  -- after StreamStop: state = STREAM_PAUSED, Transaction = 20
  -- after StreamAbort (xid 20, subxid 21): state = IDLE, Transaction = 0
  -- continuation segment for xid 20 rejected: continued StreamStart changed transaction identity
  -- xid 30 paused: state = STREAM_PAUSED, Transaction = 30
  -- small transaction 31 rejected while xid 30 is paused: Begin requires an idle pgoutput producer
  -- second streamed transaction 41 rejected: first StreamStart requires an idle producer
  FAILED: a StreamAbort naming a subtransaction leaves the top-level streamed transaction paused
  FAILED: a StreamAbort naming a subtransaction keeps the top-level xid
  FAILED: the top-level transaction may continue with a further segment after one of its subtransactions aborts
  FAILED: an unrelated transaction may be produced between two segments of a paused streamed transaction
  FAILED: a second streamed transaction may start while another is paused
BUG REPRODUCED: 5 failed expectation(s)
```

**Description:** `Producer.Emit`
(`src/flyology-postgres-replication-logical-producer.adb:92-98`) handles
`Stream_Commit_Message` and `Stream_Abort_Message` identically — it drops to
`Idle` and clears `XID` — and never reads `Logical.Subtransaction (Message)`.
That contradicts pgoutput: `pgoutput_stream_abort` writes the *top-level*
`toptxn->xid` together with the aborting `txn->xid`, so a `ROLLBACK TO
SAVEPOINT` inside a streamed transaction produces an `'A'` message whose
subxid differs from the xid while the top-level transaction stays streamed and
continues with further `S(xid, first_segment = false)` segments and a final
`c(xid)`. PostgreSQL's `apply_handle_stream_abort` mirrors that: only when
`xid == subxid` does it finish the transaction; otherwise it truncates the
spool file back to the subxact's start offset and stays inside the
transaction. Two consequences follow. First, the public queries lie with no
further call: after a subtransaction abort `Producer.State` reports `Idle` and
`Producer.Transaction` reports `0` while xid 20 is still open — and
`Managed_Primary` (`managed_primary.adb:275-277`) uses exactly
`Producer.State (Encoder) = Producer.Idle` as its "logical source ended inside
a transaction" guard, so a stream truncated mid-transaction would be accepted
as complete. Second, the continuation is refused with "continued StreamStart
changed transaction identity"; the natural workaround — resending
`S(20, first_segment = true)` — would make PostgreSQL's `stream_open_file`
create the spool file afresh instead of appending, discarding the changes
already streamed for that xid. Separately, part (b): pgoutput interleaves by
design — after `E` the walsender keeps decoding, so other transactions commit
(`B..C`) or start their own segments before the paused one resumes — and the
Producer's `Stream_Paused` state admits only `S`/`c`/`A`/`p` for the same XID,
rejecting all of it (`producer.adb:54-60`, `:68-84`, `:123-126`, `:128-134`).
Contrast the library's own stateful `Decoder` (`logical.adb:1220-1249`), which
tracks only `In_Stream` and accepts every one of these sequences. The
`producer.ads:35-37` monotonic `WAL_Start >= Last_WAL_End` envelope rule has
the same root: under interleaving pgoutput's per-message `write_location` is
not monotonic across transactions (Begin uses `txn->first_lsn`), so it must be
revisited together with this finding.

---

### LOGICAL-3: Producer rejects a non-transactional Logical Decoding Message outside a transaction

**Verdict:** CONFIRMED.

**Severity:** **P1** (agrees with the report).

**Repro:** `tests/repros/src/repro_logical_3.adb`

**Output** (`cd tests/repros && ./run.sh repro_logical_3`, exit status **1**):

```
  -- non-transactional message outside a transaction rejected: pgoutput data message is outside a transaction
  -- non-transactional message between segments rejected: pgoutput data message is outside a transaction
  FAILED: Producer emits a non-transactional logical decoding message outside any transaction
  FAILED: the emitted non-transactional message decodes back to what was built
  FAILED: Producer emits a non-transactional logical decoding message between two segments of a paused streamed transaction
  ok: a transactional logical decoding message outside a transaction is still rejected
```

**Description:** `Producer.Emit`
(`src/flyology-postgres-replication-logical-producer.adb:128-134`) applies one
blanket rule — `Item.Current in Regular_Transaction | Stream_Segment |
Preparing_Transaction`, else "pgoutput data message is outside a transaction" —
to the whole data-message group, `Logical_Decoding_Message` included, without
consulting `Logical.Is_Transactional (Message)`. In pgoutput,
`pgoutput_message` emits a `BEGIN` first only for transactional messages
("Output BEGIN if we haven't yet. Avoid for non-transactional messages"); a
message written by `pg_logical_emit_message(false, ...)` is queued by
`ReorderBufferQueueMessage` and written out immediately at decode time,
outside any `B`/`C` pair and outside any `S`/`E` pair — including between two
segments of a paused streamed transaction. So the Producer refuses to emit the
message in the only position pgoutput ever puts it, and it does so for the
constructor's *default* setting: `Make_Logical_Decoding_Message`
(`logical.ads:242-254`) declares `Transactional : Boolean := False`. The
result is an unexpected `Protocol_Error` on valid input through a reachable
path — via `Managed_Primary` it aborts the whole replication stream. The
repro also confirms that a `Transactional => True` message outside a
transaction is still correctly rejected, so the fix must be narrowed by
`Is_Transactional`, not removed.

---

### LOGICAL-4: Producer does not enforce Begin/Commit and BeginPrepare/Prepare LSN agreement

**Verdict:** CONFIRMED as a behavioral fact, but reclassified: this is a
**validation gap that requires a design decision**, not a violated contract.
The Producer's published promise is to validate "transaction ordering"
(`producer.ads:2-3`) and "the transaction sequence, envelope, or negotiated
protocol configuration" (`producer.ads:41-43`); LSN *values* are caller data
elsewhere in the API. Decisive evidence that the current behavior is
intentional: `tests/src/replication_tests.adb:1387-1397` deliberately emits
`Make_Begin (101, 0, 10)` followed by `Make_Commit (103, 104, 0)` and asserts
success, so adding the check would fail an existing maintained test. Under
this repository's `decision-authority` rule that makes it a user decision, not
a unilateral fix.

**Severity:** **P2** (agrees with the report).

**Repro:** `tests/repros/src/repro_logical_4.adb`

**Output** (`cd tests/repros && ./run.sh repro_logical_4`, exit status **1**):

```
  -- Begin final_lsn = 16#101#
  --   emitted 42 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 00 00 00 00 0a
  -- Commit commit_lsn = 16#103# (does not match the Begin)
  --   emitted 43 00 00 00 00 00 00 00 01 03 00 00 00 00 00 00 01 04 00 00 00 00 00 00 00 00
  --   accepted; a PostgreSQL apply worker would raise ERRCODE_PROTOCOL_VIOLATION on these bytes
  -- BeginPrepare prepare_lsn = 16#301#
  --   emitted 62 00 00 00 00 00 00 03 01 00 00 00 00 00 00 03 02 00 00 00 00 00 00 00 00 00 00 00 0b 67 69 64 2d 31 31 00
  -- Prepare prepare_lsn = 16#302# (does not match BeginPrepare)
  --   emitted 50 00 00 00 00 00 00 00 03 02 00 00 00 00 00 00 03 03 00 00 00 00 00 00 00 00 00 00 00 0b 67 69 64 2d 31 31 00
  --   accepted; a PostgreSQL apply worker would raise ERRCODE_PROTOCOL_VIOLATION on these bytes
  -- Begin/Commit both at final_lsn 16#130#
  --   emitted 42 00 00 00 00 00 00 01 30 00 00 00 00 00 00 00 00 00 00 00 0c
  --   emitted 43 00 00 00 00 00 00 00 01 30 00 00 00 00 00 00 01 40 00 00 00 00 00 00 00 00
  FAILED: Producer rejects a Commit whose commit LSN differs from the pending Begin's final LSN
  FAILED: Producer rejects a Prepare whose prepare LSN differs from the pending BeginPrepare's prepare LSN
  ok: Producer still accepts the agreeing Begin/Commit pair pgoutput emits
```

**Description:** `Producer.Emit` stores only the XID at `Begin_Message`
(`producer.adb:54-60`) and `Begin_Prepare_Message` (`:100-106`), and compares
only the XID at `Commit_Message` (`:62-66`) and `Prepare_Message` (`:108-113`).
The Begin `final_lsn` is never retained, so a `Commit` whose `commit_lsn`
disagrees is accepted and encoded. PostgreSQL's apply worker records
`begin_data.final_lsn` into `remote_final_lsn` in `apply_handle_begin` and,
in `apply_handle_commit`, raises `ERRCODE_PROTOCOL_VIOLATION` — "incorrect
commit LSN %X/%X in commit message (expected %X/%X)" — when
`commit_data.commit_lsn != remote_final_lsn` (an `Assert` in PostgreSQL 10-13,
an `ereport` since 14); `apply_handle_prepare` performs the identical
comparison against `prepare_data.prepare_lsn`. pgoutput itself writes
`txn->final_lsn` into both fields, so the pair always agrees on the wire.
Consequence: an application logical source that gets the two LSNs out of step
produces a stream that a `CREATE SUBSCRIPTION` worker errors on and then
retries forever; `pg_recvlogical`, which the interop matrix uses for change
delivery, does not perform the check, so the existing test matrix cannot
detect it. The related omission of a GID comparison between BeginPrepare and
Prepare is harmless on the wire, since the apply worker keys on `prepare_lsn`,
not on the GID. Whether to close this gap is a contract decision for the
maintainer, because the current unit test asserts the opposite.

---

### LOGICAL-5: Abort_LSN and Event_Timestamp raise on a constructed Stream Abort that carries v4 metadata

**Verdict:** CONFIRMED. The alternative reading offered in the discovery
report — that a constructed message reports version 1 and so "lacks version-4
metadata" by definition — does not survive: the gate is `Item.Parallel_Stream`
(not `Wire_Version`), that field is assigned in exactly one place, `Decode`
(`logical.adb:874`, verified by grep: assignments at `:874` only, reads at
`:1352` and `:1369`), and `Encode (Built, 4, Parallel)` demonstrably
serialises the very values the accessors refuse to return.

**Severity:** **P2** (agrees with the report).

**Repro:** `tests/repros/src/repro_logical_5.adb`

**Output** (`cd tests/repros && ./run.sh repro_logical_5`, exit status **1**):

```
  -- Make_Stream_Abort (51, 52, 53, 54) encodes at v4/parallel as: 41 00 00 00 33 00 00 00 34 00 00 00 00 00 00 00 35 00 00 00 00 00 00 00 36
  -- Abort_LSN (built) raised Protocol_Error: logical message has no parallel-stream abort LSN
  -- Event_Timestamp (built) raised Protocol_Error: non-parallel StreamAbort has no event timestamp
  -- after a v4/parallel round trip: Abort_LSN = 53, Event_Timestamp = 54
  FAILED: Abort_LSN returns the abort LSN supplied to Make_Stream_Abort
  FAILED: Event_Timestamp returns the abort time supplied to Make_Stream_Abort
```

**Description:** `Make_Stream_Abort`
(`src/flyology-postgres-replication-logical.adb:460-471`) accepts and stores
`Abort_LSN` and `Aborted_At` in `First_Position`/`First_Time` but never sets
the private `Parallel_Stream` flag, which only `Decode` sets
(`logical.adb:874`). `Abort_LSN` (`:1348-1355`) and `Event_Timestamp`
(`:1357-1371`) both require that flag, so the two values the caller just
supplied are unreadable from the message object, while `Encode (Item, 4,
Parallel)` (`:798-806`) writes them out correctly — the repro shows `35` and
`36` in the encoded bytes and reads `53`/`54` back only after a wire round
trip. This contradicts the accessors' own documented exception condition,
`logical.ads:555-559` and `:560-565`: "Protocol_Error Item lacks version-4
abort metadata", which is false for this message. No wire bytes are affected
and decoded messages behave correctly, so this is contract drift on
constructed messages: an application that builds a parallel-stream abort
cannot inspect it, and a caller that round-trips through `Encode`/`Decode`
gets different behavior from the identical logical value.

---

## Refuted / no finding

Nothing in the candidate list was refuted. Spot checks I performed against the
report's "areas reviewed with no findings" that also held up: `Append_Stream_Xid`
placement for every xid-bearing tag; the `'A'` abort-metadata gate on
`Streaming = Parallel` (matching pgoutput's `write_abort_info` and the apply
worker's `read_abort_info`) rather than on version alone; and the stateful
`Decoder`'s ordering rules at `logical.adb:1220-1249` (`S` not nested, `E`
only inside, `c`/`A`/`p` only outside a segment, `In_Stream` advanced only
after a successful decode).
