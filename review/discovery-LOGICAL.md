# Discovery report: LOGICAL (pgoutput codec and producer)

## Scope

Read-only correctness review of the pgoutput logical-replication message codec
and its stateful producer:

- src/flyology-postgres-replication-logical.ads (contract, 748 lines)
- src/flyology-postgres-replication-logical.adb (1598 lines)
- src/flyology-postgres-replication-logical-producer.ads/.adb (72 + 169 lines)
- Context: src/flyology-postgres-replication.ads (LSN = UInt64,
  Replication_Timestamp = Int64, Transaction_Id = UInt32),
  src/flyology-postgres-wire.ads/.adb (Try_Read_*, Count_Fits, Element_At,
  bit casts), src/flyology-postgres-protocol.adb (Append_C_String rejects
  embedded NUL), README "Streaming replication" paragraphs,
  tests/REPLICATION_VALIDATION.md, tests/src/replication_tests.adb
  (Test_Logical_* at 600-1420), tests/src/postgres_test_replication.adb,
  tests/src/postgres_test_logical_primary.adb,
  src/flyology-postgres-replication-managed_primary.adb:232-280 (the only
  in-tree Producer consumer).

Every encoder and decoder layout was compared field-by-field against
PostgreSQL's proto.c (logicalrep_write_*/logicalrep_read_*) and pgoutput.c for
protocol versions 1-4. Findings are concentrated in the Producer's ordering
model; the byte-level codec itself checked out.

## Severity rubric

- P0: memory/aliasing unsafety, security-relevant, hang, or interop-breaking
  protocol violation (a real PostgreSQL or subscriber would reject or misread
  the bytes).
- P1: wrong result or unexpected exception on valid input via a reachable
  path, or a documented contract violated.
- P2: edge-case incorrectness, wrong diagnostics, or contract drift needing
  unusual input.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| LOGICAL-1 | Producer accepts a non-streamed data message inside an open stream segment and emits it without the xid prefix, which an in-stream consumer misreads | P1 | high |
| LOGICAL-2 | Producer models a single in-flight streamed XID and treats every Stream Abort as terminal, rejecting valid pgoutput sequences (subtransaction abort continuation, interleaved transactions) | P1 | high |
| LOGICAL-3 | Producer rejects a non-transactional Logical Decoding Message outside a transaction, which is exactly where pgoutput emits it | P1 | high |
| LOGICAL-4 | Producer does not enforce Commit.commit_lsn = Begin.final_lsn (and Prepare.prepare_lsn = BeginPrepare.prepare_lsn), which a PostgreSQL apply worker rejects as a protocol violation | P2 | medium-high |
| LOGICAL-5 | Abort_LSN / Event_Timestamp raise on a Make_Stream_Abort message even when the caller supplied the v4 abort metadata | P2 | medium |

## Findings

### LOGICAL-1: Producer accepts a non-streamed data message inside an open stream segment and emits it without the xid prefix

- Location: src/flyology-postgres-replication-logical-producer.adb:128-140;
  src/flyology-postgres-replication-logical.adb:636-642 (Append_Stream_Xid),
  :356-367 (Make_Insert sets `Result.Streamed := Xid /= 0`), :653-656
  (Encode's only streamed check).
- Severity: P1 (output is interop-breaking, but reaching it requires the
  caller to omit Xid; the Producer's stated purpose is to catch exactly that
  class of ordering error).
- Confidence: high.
- Evidence (producer.adb:128-140):

  ```ada
  when Origin_Message | Logical_Decoding_Message |
       Relation_Message | Type_Message | Insert_Message |
       Update_Message | Delete_Message | Truncate_Message =>
     Require
       (Item.Current in Regular_Transaction | Stream_Segment |
          Preparing_Transaction,
        "pgoutput data message is outside a transaction");
     if Logical.Is_Streamed (Message) then
        Require
          (Item.Current = Stream_Segment
           and then Logical.Transaction (Message) = Item.XID,
           "streamed pgoutput message changed transaction identity");
     end if;
  ```

  The check is one-directional: a streamed message must be in a segment, but
  a message in a segment is not required to be streamed. Encode
  (logical.adb:636-642) writes the xid prefix only when `Item.Streamed`, and
  Make_Insert/Update/Delete/Relation/Type/Truncate/Logical_Decoding_Message
  set `Streamed := Xid /= 0`, so a message built with the default `Xid => 0`
  is encoded without the prefix.
- Failure scenario: pgoutput always writes the xid on every Relation, Type,
  Insert, Update, Delete, Truncate and Message emitted between Stream Start
  and Stream Stop (pgoutput.c passes `xid = txn->xid` whenever
  `in_streaming`). A subscriber inside a segment (the library's own stateful
  Decoder, or PostgreSQL's apply worker via `logicalrep_read_insert` with
  `in_streamed_transaction`) therefore consumes 4 bytes of xid first. The
  Producer-validated bytes are shifted: the relation OID is taken as the xid,
  the `'N'` tag plus tuple header become the relation OID, and decoding fails
  or yields garbage.
- Reproduction test sketch:

  ```ada
  E : Producer.Encoder;
  T : constant Logical.Tuple_Data := Logical.Make_Tuple ((1 => Logical.Null_Column));
  Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
  Ignore (Producer.Emit (E, Logical.Make_Stream_Start (20, True), 200, 201));
  --  Xid defaults to 0 -> Is_Streamed = False
  Data : constant Logical.Byte_Array :=
    Producer.Emit (E, Logical.Make_Insert (42, T), 201, 202);
  --  Expected: Protocol_Error (row change inside a segment must carry xid 20).
  --  Actual:  returns 49 00 00 00 2A 4E 00 01 6E  ('I', relid 42, 'N', ncols 1, 'n')
  --           and State (E) = Stream_Segment.
  --  Feed it to a consumer that is inside the stream:
  D : Logical.Decoder;
  Logical.Configure (D, 2, Logical.In_Progress);
  Ignore (Logical.Decode (D, Logical.Encode (Logical.Make_Stream_Start (20, True), 2, Logical.In_Progress)));
  M := Logical.Decode (D, Data);
  --  Actual: xid := 16#0000002A#, relid := 16#4E00016E#, then
  --  Protocol_Error "truncated Insert tuple tag".  With a longer tuple the
  --  bytes decode as a different relation with different column values.
  ```

  Expected fix direction: in Stream_Segment require `Is_Streamed (Message)`
  for the seven xid-bearing kinds (Origin legitimately has no xid).
- Existing coverage: tests/src/replication_tests.adb:1405-1408 emits
  `Make_Insert (42, Tuple, Xid => 20)` inside a segment (correct case) and
  :1413-1427 rejects a row change while Idle; no test emits a non-streamed
  data message inside a segment.

### LOGICAL-2: Producer models a single in-flight streamed XID and treats every Stream Abort as terminal

- Location: src/flyology-postgres-replication-logical-producer.adb:54-60
  (Begin requires Idle), :68-84 (first StreamStart requires Idle; continued
  StreamStart requires Stream_Paused with same XID), :92-98 (Stream Abort ->
  Idle, XID := 0 regardless of Subxid), :123-126 (Commit/Rollback Prepared
  require Idle); src/flyology-postgres-replication-logical-producer.ads:6-14,
  :53-56 (single `XID` field; "active or paused streamed transaction").
- Severity: P1 (unexpected Protocol_Error on ordering sequences pgoutput
  produces; the subtransaction-abort case is a modelling error independent of
  any "one transaction at a time" simplification).
- Confidence: high on the rejection behaviour and on pgoutput's ordering.
- Evidence (producer.adb:92-98):

  ```ada
  when Stream_Commit_Message | Stream_Abort_Message =>
     Require
       (Item.Current = Stream_Paused
        and then Item.XID = Logical.Transaction (Message),
        "stream completion requires the paused transaction");
     Item.Current := Idle;
     Item.XID := 0;
  ```

  `Subtransaction (Message)` is never consulted. In pgoutput
  (`pgoutput_stream_abort`, called from `ReorderBufferAbort` on a
  subtransaction that was marked streamed) a Stream Abort with
  `subxid /= xid` aborts only that subtransaction; the top-level transaction
  remains streamed and continues with further `S(xid, first_segment=0)`
  segments and finally `c(xid)` (or directly `c(xid)` when nothing remains).
  The apply worker (`apply_handle_stream_abort`) likewise only truncates the
  subxact's changes and stays in the transaction.

  Independently, pgoutput interleaves work between segments of a paused
  transaction: after `E`, the walsender continues decoding WAL, so a small
  transaction can commit (`B ... C`), another large transaction can stream
  (`S(B, first) ... E`), or a `K`/`r` for an earlier prepared transaction can
  be sent before `S(A, cont)` resumes. The Producer's `Stream_Paused` state
  admits only `S` with the same XID, `c`, `A`, or `p`.
- Failure scenario (subtransaction abort):

  ```ada
  Producer.Configure (E, 2, Logical.In_Progress);
  Emit (Make_Stream_Start (20, True), 200, 201);
  Emit (Make_Insert (42, T, Xid => 20), 201, 202);
  Emit (Make_Stream_Stop, 202, 203);
  Emit (Make_Stream_Abort (Xid => 20, Subxid => 21), 203, 204);
  --  State (E) = Idle, Transaction (E) = 0 although xid 20 is still open.
  Emit (Make_Stream_Start (20, False), 204, 205);
  --  Expected: accepted (pgoutput continues xid 20 with first_segment = 0).
  --  Actual: Protocol_Error "continued StreamStart changed transaction identity".
  --  Variant: Emit (Make_Stream_Commit (20, 205, 206, 0), 205, 206) right after
  --  the abort -> Protocol_Error "stream completion requires the paused transaction".
  ```

  Failure scenario (interleaving), after `Emit (Make_Stream_Stop ...)` with
  xid 20 paused:

  ```ada
  Emit (Make_Begin (301, 0, 21), 300, 301);
  --  Expected: accepted; actual: "Begin requires an idle pgoutput producer".
  Emit (Make_Stream_Start (22, True), 300, 301);
  --  Expected: accepted; actual: "first StreamStart requires an idle producer".
  Emit (Make_Commit_Prepared (301, 302, 0, 5, "gid-5"), 300, 301);   -- v3
  --  Expected: accepted; actual: "prepared completion requires an idle producer".
  ```

  Contrast: the stateful Decoder (logical.adb:1220-1245) only tracks
  `In_Stream` and accepts all of these sequences, and the real-PostgreSQL
  interop model in tests/src/postgres_test_replication.adb:1336-1362 decodes
  them.
- Reproduction test sketch: the Ada above, asserting no exception and
  `Producer.Transaction (E) = 20` after the subtransaction abort.
- Existing coverage: replication_tests.adb:1403-1411 covers a single
  S/I/E/c sequence only; no test emits a Stream Abort with `Subxid /= Xid`,
  nor any message between segments other than the same-XID completion. The
  Managed_Primary (managed_primary.adb:257-270) forwards whatever the
  application Logical_Source yields, so an application source that mirrors
  PostgreSQL's ordering hits these rejections.
- Note: the documented `WAL_Start >= Last_WAL_End` envelope policy
  (producer.ads:35-37) also conflicts with pgoutput's per-message
  `write_location` under interleaving (Begin uses `txn->first_lsn`, which is
  below the last streamed change LSN of another transaction). That is a
  documented policy and is not counted separately, but it must be revisited
  together with this finding.

### LOGICAL-3: Producer rejects a non-transactional Logical Decoding Message outside a transaction

- Location: src/flyology-postgres-replication-logical-producer.adb:128-134.
- Severity: P1 (unexpected Protocol_Error for a valid message in the only
  position pgoutput ever places it).
- Confidence: high.
- Evidence: the same `Require (Item.Current in Regular_Transaction |
  Stream_Segment | Preparing_Transaction, "pgoutput data message is outside a
  transaction")` applies to `Logical_Decoding_Message` regardless of
  `Is_Transactional (Message)`.

  In pgoutput.c `pgoutput_message` only emits `BEGIN` "if we haven't yet.
  Avoid for non-transactional messages"; non-transactional messages
  (`pg_logical_emit_message(false, ...)`) are written immediately by
  `ReorderBufferQueueMessage`, outside any `B`/`C` or `S`/`E` pair (and
  possibly between segments of a paused streamed transaction). The
  Logical message constructor (logical.ads:242-255) explicitly models
  `Transactional => False`.
- Failure scenario / reproduction:

  ```ada
  Producer.Configure (E, Version => 1);
  Data := Producer.Emit
    (E, Logical.Make_Logical_Decoding_Message
          (Message_LSN => 16#100#, Prefix => "app", Content => (1 => 1),
           Transactional => False),
     16#100#, 16#101#);
  --  Expected: 4D 00 0000000000000100 61 70 70 00 00000001 01
  --  Actual:   Protocol_Error "pgoutput data message is outside a transaction".
  ```

  (Conversely, a `Transactional => True` message outside a transaction should
  stay rejected.)
- Existing coverage: replication_tests.adb:1101-1105 round-trips a
  transactional message through Encode/Decode only; the Producer test never
  emits a Logical_Decoding_Message.

### LOGICAL-4: Producer does not enforce Begin/Commit and BeginPrepare/Prepare LSN agreement that a PostgreSQL apply worker requires

- Location: src/flyology-postgres-replication-logical-producer.adb:54-66
  (Begin stores only XID), :100-113 (BeginPrepare/Prepare compare only XID).
- Severity: P2 (Producer accepts a sequence pgoutput never produces and that
  a real subscriber rejects; requires the caller to supply inconsistent
  LSNs, and the spec does not promise LSN consistency).
- Confidence: medium-high. PostgreSQL's worker.c `apply_handle_begin` stores
  `begin_data.final_lsn` in `remote_final_lsn`; `apply_handle_commit` raises
  `ERRCODE_PROTOCOL_VIOLATION` "incorrect commit LSN ... in commit message
  (expected ...)" when `commit_data.commit_lsn != remote_final_lsn`
  (an Assert in PostgreSQL 10-13, an ereport since 14). `apply_handle_prepare`
  performs the same check against `prepare_data.prepare_lsn`. pgoutput
  writes `txn->final_lsn` into both Begin.final_lsn and Commit.commit_lsn.
- Failure scenario: an application logical source emits
  `Make_Begin (Final_LSN => 101, ...)` and `Make_Commit (Commit_LSN => 103,
  ...)`. The Producer accepts and the managed primary sends it; a
  `CREATE SUBSCRIPTION` worker on the other end errors out and the
  subscription retries forever. pg_recvlogical (the consumer used by the
  interop matrix for change delivery) does not check, so the matrix cannot
  detect this.
- Reproduction test sketch:

  ```ada
  Producer.Configure (E, Version => 1);
  Ignore (Producer.Emit (E, Logical.Make_Begin (101, 0, 10), 100, 101));
  Ignore (Producer.Emit (E, Logical.Make_Commit (103, 104, 0), 103, 104));
  --  Accepted today (this is verbatim replication_tests.adb:1387-1397).
  --  Expected (if the Producer is to guarantee subscriber-acceptable
  --  ordering): Protocol_Error because Commit_LSN /= the pending Begin's
  --  Final_LSN.  Same for Make_Begin_Prepare (Prepare_LSN => 301, ...) followed
  --  by Make_Prepare (Prepare_LSN => 302, ...).
  ```

  Independent evidence in-tree: the real-subscription primary test uses
  matching values `Make_Begin (16#130#, 0, 10)` / `Make_Commit (16#130#,
  16#140#, 0)` (tests/src/postgres_test_logical_primary.adb:362-370).
- Existing coverage: none; the unit test itself uses mismatched LSNs.
  REPLICATION_VALIDATION.md:106-121 states the PG18 subscription worker only
  proves initial COPY interoperability.
- Related (not counted separately): the Producer also does not compare the
  GID between BeginPrepare and Prepare; the apply worker keys on prepare_lsn,
  not GID, so that omission is harmless on the wire.

### LOGICAL-5: Abort_LSN and Event_Timestamp raise on a constructed Stream Abort that carries v4 metadata

- Location: src/flyology-postgres-replication-logical.adb:1348-1355
  (Abort_LSN requires `Item.Parallel_Stream`), :1357-1371 (Event_Timestamp
  same), :460-471 (Make_Stream_Abort never sets `Parallel_Stream`), :874
  (Decode sets `Parallel_Stream := Streaming = Parallel`); contract at
  logical.ads:346-356 and :555-569.
- Severity: P2 (contract drift on constructed messages; decoded messages are
  fine).
- Confidence: medium (the spec's `Version` note that constructed messages
  report version 1 gives the implementation a reading, but the accessor's own
  documented exception condition -- "Item lacks version-4 abort metadata" --
  is false for the message in question).
- Evidence (logical.adb:1348-1355):

  ```ada
  function Abort_LSN (Item : Message) return LSN is
  begin
     Require
       (Item.Message_Type = Stream_Abort_Message
        and then Item.Parallel_Stream,
        "logical message has no parallel-stream abort LSN");
  ```

  `Parallel_Stream` is only ever set by Decode; `Make_Stream_Abort
  (Abort_LSN => ..., Aborted_At => ...)` stores the values but leaves the
  flag False, so the metadata the caller just supplied is unreadable, while
  `Encode (Item, 4, Parallel)` happily serialises it.
- Reproduction test sketch:

  ```ada
  M : constant Logical.Message :=
    Logical.Make_Stream_Abort (Xid => 51, Subxid => 52, Abort_LSN => 53, Aborted_At => 54);
  Logical.Abort_LSN (M);        -- expected 53; actual Protocol_Error
  Logical.Event_Timestamp (M);  -- expected 54; actual Protocol_Error
  Logical.Abort_LSN (Logical.Decode (Logical.Encode (M, 4, Logical.Parallel), 4, Streaming => Logical.Parallel));
  --  = 53 (works only after a round trip)
  ```
- Existing coverage: replication_tests.adb:1165-1168 round-trips
  `Make_Stream_Abort (51, 52, 53, 54)` at the byte level only; :1019-1028
  reads Abort_LSN from a decoded message only.

## Areas reviewed with no findings

- Byte layout of all 19 encoders and decoders versus proto.c: B (final_lsn,
  commit_time, xid), C (flags=0, commit_lsn, end_lsn, commit_time), O, M
  ([xid], flags, lsn, prefix, int32 length, content), R ([xid], relid, ns,
  name, replident, int16 ncols, per-column flags/name/typid/typmod), Y, I
  ([xid], relid, 'N', tuple), U ([xid], relid, optional K/O tuple, 'N'
  tuple), D ([xid], relid, K/O tuple), T ([xid], int32 nrelids, int8 flags,
  relids), S (xid, first_segment), E, c (xid, flags=0, commit_lsn, end_lsn,
  time), A (xid, subxid, [abort_lsn, abort_time]), b, P, K, r
  (flags, prepare_end_lsn, rollback_end_lsn, prepare_time, rollback_time,
  xid, gid), p. All match, including big-endian widths and field order.
- Signedness: typmod through To_Int32_Bits/To_UInt32_Bits; timestamps
  (possibly negative) through To_Int64_Bits/To_UInt64_Bits; LSN as UInt64.
- Replica identity characters d/n/f/i; column flag bit 1; Truncate flag bits
  1 (CASCADE) and 2 (RESTART IDENTITY) with `and 16#FC# = 0` rejection of
  others; Commit/StreamCommit/prepared flags required to be 0; Message flags
  restricted to 0/1; StreamStart first flag 0/1.
- TupleData: 'n', 'u', 't', 'b' distinguished; NULL vs unchanged TOAST vs
  empty text are distinct variants; unknown kind byte raises Protocol_Error;
  count and per-value lengths are bounded against the remaining payload
  before Reserve_Capacity; a length >= 2^31 cannot pass the payload check.
- Strings: Read_String requires a NUL terminator ("unterminated"),
  Append_C_String rejects embedded NUL, so encode/decode of prefix, names,
  GIDs and origin names cannot desynchronise.
- Decoder strictness: every read is via Try_Read_* + Require ("truncated
  ..."), Require_End rejects trailing bytes, empty input rejected, unknown
  tag rejected.
- Version/mode gating: S/E/c/A require v>=2 and streaming; b/P/K/r/p
  require v>=3 (p also streaming); Stream Abort abort_lsn/abort_time are
  gated on `Streaming = Parallel` (which Configuration_Is_Valid limits to
  v4), matching pgoutput's `write_abort_info = (streaming == PARALLEL)` and
  the apply worker's `read_abort_info`, rather than on version alone.
- Stateful Decoder XID insertion: xid is read only for M/R/Y/I/U/D/T and only
  while In_Stream; S nested, E outside, and c/A/p inside a segment are
  rejected; In_Stream is updated only after a successful decode so a failed
  message leaves state unchanged (as documented).
- Encode/decode round-trip symmetry for all kinds in both streamed and
  non-streamed forms; canonical re-encoding of decoded messages.
- Ownership: all decoded text/tuples live in Unbounded_String /
  Unbounded_Bytes / Vectors (controlled); no access types; an exception
  mid-decode simply finalises the partial Result -- no leak or dangling
  reference paths.
- Producer atomic rollback on failure (Previous_State/XID/End restored in a
  `when others` handler before re-raising).

## Observations not counted

- `Relation_Id` (logical.adb:1433-1440) accepts Type_Message and returns the
  type OID, although the contract (logical.ads:604-608) names only Relation
  or row-change messages. Lenient, not wrong.
- Feeding the stateless Decode a Data array longer than
  Maximum_Message_Size (16 MiB) fails inside Wire.Can_Read's Fits_Wire_Limit
  and surfaces as a misleading "truncated <field>" Protocol_Error rather than a
  size diagnostic. Assertions (-gnata) are not enabled in the config, so the
  Element_At precondition does not fire. Unreachable through the library's
  own XLogData frames.
- The stateful Decoder does not reject B/C/b/P/K/r inside a stream segment;
  pgoutput never emits them there. Origin ('O') legitimately follows the
  first Stream Start of an origin-tagged transaction, and the decoder
  correctly reads no xid for it.
- Make_* constructors infer `Streamed` from `Xid /= 0`; harmless because 0 is
  InvalidTransactionId.
- Decode accepts 'b' binary tuple values without knowing whether the
  `binary` option was negotiated; permissive.
- The Encode ceiling `Maximum_Message_Size - 29` and the Producer's
  monotonic WAL-envelope rule are documented policy values.
- `Version (Item)` returning 1 for constructed messages is documented, but it
  is the root of LOGICAL-5.
