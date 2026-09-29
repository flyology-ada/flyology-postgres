Title: Logical.Producer ends the top-level transaction on a subtransaction Stream Abort and bars interleaving
Labels: bug
Refs: LOGICAL-1

## Summary

`Producer.Emit` treats `Stream_Abort` exactly like `Stream_Commit`: it returns to `Idle` and clears the XID without ever reading `Logical.Subtransaction`. pgoutput emits a Stream Abort for a `ROLLBACK TO SAVEPOINT` inside a streamed transaction, naming the top-level xid and the aborting subxid, and the top-level transaction then continues with further segments. After such a message the producer reports `Idle` and transaction zero while the top-level transaction is still open, which is the exact condition `Managed_Primary` uses to declare the stream complete, and it refuses the continuation segment. The producer also models a single in-flight transaction, so it rejects the interleaving that streaming exists to allow.

## Problem

Commit `6f496f5`.

Stream Commit and Stream Abort share one arm (`src/flyology-postgres-replication-logical-producer.adb:92-98`):

```ada
when Stream_Commit_Message | Stream_Abort_Message =>
   Require
     (Item.Current = Stream_Paused
      and then Item.XID = Logical.Transaction (Message),
      "stream completion requires the paused transaction");
   Item.Current := Idle;
   Item.XID := 0;
```

`Logical.Subtransaction` (`src/flyology-postgres-replication-logical.ads:519-523`) exists and is never called from the producer body.

pgoutput distinguishes the two cases. `pgoutput_stream_abort` resolves the top-level transaction and writes both identifiers (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/pgoutput/pgoutput.c:1859-1866`):

```c
	/* determine the toplevel transaction */
	toptxn = rbtxn_get_toptxn(txn);

	Assert(rbtxn_is_streamed(toptxn));

	OutputPluginPrepareWrite(ctx, true);
	logicalrep_write_stream_abort(ctx->out, toptxn->xid, txn->xid, abort_lsn,
								  txn->xact_time.abort_time, write_abort_info);
```

When a subtransaction aborts, `toptxn->xid` and `txn->xid` differ and the top-level transaction stays streamed, so pgoutput goes on to write further `S(xid, first_segment = false)` segments and a final `c(xid)`. PostgreSQL's apply worker mirrors that split (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/worker.c:1835-1837`):

```c
	xid = abort_data.xid;
	subxid = abort_data.subxid;
	toplevel_xact = (xid == subxid);
```

Only the equal case finishes the transaction (`worker.c:1733-1745`):

```c
	/*
	 * If the two XIDs are the same, it's in fact abort of toplevel xact, so
	 * just delete the files with serialized info.
	 */
	if (xid == subxid)
		stream_cleanup_files(MyLogicalRepWorker->subid, xid);
	else
	{
```

The unequal case truncates the spool file back to the subtransaction's start offset (`worker.c:1794-1796`) and stays inside the transaction.

Two consequences follow.

### The public queries lie about an open transaction

After a subtransaction abort, `Producer.State` returns `Idle` and `Producer.Transaction` returns zero while the top-level xid is still open. `Managed_Primary` uses precisely that value as its end-of-stream guard (`src/flyology-postgres-replication-managed_primary.adb:275-277`):

```ada
Require
  (Producer.State (Encoder) = Producer.Idle,
   "logical source ended inside a transaction");
```

A logical source that stops after a subtransaction abort, halfway through a streamed transaction, is therefore accepted as a complete stream, and `Managed_Primary` goes on to send a keepalive and advance the slot (`src/flyology-postgres-replication-managed_primary.adb:278-287`). The continuation segment is refused instead, because `Item.XID` was cleared, and the `Stream_Start` arm compares against it (`src/flyology-postgres-replication-logical-producer.adb:78-83`). Resending `S(xid, first_segment = true)` is not a workaround: PostgreSQL's `stream_open_file` creates the changes file afresh for a first segment and appends only otherwise (`worker.c:4261-4277`), so the changes already streamed for that xid would be discarded.

### Interleaving between segments is rejected

Streaming exists so that other work continues while a large transaction is in progress. `Stream_Paused` admits only `S`, `c`, `A` and `p` for the same XID (`src/flyology-postgres-replication-logical-producer.adb:68-84`, `:92-98`, `:115-121`, `:128-134`), and `Begin_Message` and a first `Stream_Start` both require `Idle` (`:54-57`, `:73-77`). A small transaction that commits between two segments of a paused one, and a second streamed transaction that opens its own segment, are both rejected. The library's own stateful `Decoder` accepts every one of those sequences, because it tracks only `In_Stream` (`src/flyology-postgres-replication-logical.adb:1224-1247`).

Neither restriction is documented. `README.md:366-367` says only that "`Logical.Producer` validates transaction ordering while encoding the existing typed messages as `pgoutput`", and `src/flyology-postgres-replication-logical-producer.ads:1-60` documents the `Transaction_State` enum, the monotonic WAL envelope and "the active or paused streamed transaction identifier" without ever stating that one transaction at a time is the limit or that a Stream Abort is terminal.

The producer test covers a single linear streamed transaction that ends in `Make_Stream_Commit` (`tests/src/replication_tests.adb:1403-1411`). The only Stream Abort built anywhere in the suite is the top-level `Make_Stream_Abort (20, 20)` at `tests/src/replication_tests.adb:1137`, which goes through `Logical.Encode` and not through the producer. No test emits two transactions to one encoder.

The producer's monotonic envelope rule, `WAL_Start >= Item.Last_End` (`src/flyology-postgres-replication-logical-producer.adb:49-51`, documented at `src/flyology-postgres-replication-logical-producer.ads:35-37`), has the same root and should be revisited with the interleaving part: under interleaving pgoutput's per-message write location is not monotonic across transactions, because `logicalrep_write_begin` sends `txn->final_lsn` (`proto.c:60-67`) for a transaction that began earlier.

The one-directional ordering model behind this finding is the same one that lets an unstreamed data message through an open segment ({{ISSUE:LOGICAL-1}}).

## What happens now

Spike: the program streams one segment for xid 20, stops it, emits a Stream Abort naming subtransaction 21, and asserts that the top-level transaction stays paused and can continue. It then pauses xid 30 and tries to produce a complete small transaction, and separately pauses xid 40 and tries to open a segment for xid 41.

```ada
Emit (Logical.Make_Stream_Start (Top_Xid, True), 200, 201);
Emit (Logical.Make_Insert (42, Row, Xid => Top_Xid), 201, 202);
Emit (Logical.Make_Stream_Stop, 202, 203);
Emit (Logical.Make_Stream_Abort (Xid => Top_Xid, Subxid => Sub_Xid), 203, 204);
Emit (Logical.Make_Stream_Start (Top_Xid, False), 204, 205);
...
Emit (Logical.Make_Begin (400, 0, 31), 303, 304);
...
Emit (Logical.Make_Stream_Start (41, True), 502, 503);
```

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

The abort of subtransaction 21 drops the producer to `Idle` with transaction zero while xid 20 is still open, and every interleaved sequence is refused.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 17.10 server sources used for reference.

## What should happen

A Stream Abort whose subtransaction identifier differs from its transaction identifier should leave the producer in `Stream_Paused` with the top-level XID intact, so `State` and `Transaction` keep reporting the open transaction and the next segment for that xid is accepted. Only `Xid = Subxid` should complete the transaction, matching `pgoutput_stream_abort` and `apply_handle_stream_abort`. A paused streamed transaction should not block unrelated transactions, since pgoutput produces them between segments by design.

## Suggested treatment

Split the shared arm at `src/flyology-postgres-replication-logical-producer.adb:92-98`. Keep the current handling for `Stream_Commit_Message`, and for `Stream_Abort_Message` return to `Idle` only when `Logical.Subtransaction (Message) = Logical.Transaction (Message)`, otherwise leave `Item.Current` and `Item.XID` unchanged. That closes the subtransaction part on its own and repairs the `Managed_Primary` end-of-stream guard, and the spike is the regression test for it; it belongs in `Test_Logical_Producer` (`tests/src/replication_tests.adb:1372-1455`).

The interleaving part is larger. This needs a maintainer decision: either the producer keeps a set of in-flight transactions, which means replacing the single `Current`/`XID` pair in the private record (`src/flyology-postgres-replication-logical-producer.ads:63-70`) and choosing a bound on how many transactions may be tracked, or the single-transaction model becomes a documented limitation stated in `src/flyology-postgres-replication-logical-producer.ads` and `README.md:366-367`. Whichever is chosen, the monotonic `WAL_Start >= Last_WAL_End` envelope rule at `src/flyology-postgres-replication-logical-producer.adb:49-51` has to be settled in the same decision, because interleaved pgoutput output does not satisfy it. No existing test asserts the current behaviour of either part.

## Severity

An application logical source that produces a subtransaction abort loses the rest of its streamed transaction: the continuation segment is rejected with `Protocol_Error`, which aborts the whole replication stream through `Managed_Primary`, and a source that stops there instead is accepted as complete and the slot is advanced past an unfinished transaction. Interleaving fails the same way, with `Protocol_Error` on valid pgoutput output. Both need streaming to be negotiated and a source that produces the sequences pgoutput produces, so a source that only ever emits one transaction at a time and never uses savepoints is unaffected. Deterministic.
