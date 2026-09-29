Title: Logical.Producer rejects a non-transactional logical decoding message outside a transaction
Labels: bug
Refs: LOGICAL-1

## Summary

`Producer.Emit` applies one blanket "must be inside a transaction" rule to the whole data-message group, `Logical_Decoding_Message` included, without consulting `Logical.Is_Transactional`. pgoutput emits a non-transactional logical decoding message outside any `B`/`C` pair and outside any `S`/`E` pair, which is the only place it ever puts one. The producer therefore raises `Protocol_Error` on valid pgoutput output, and it does so for the constructor's default setting, since `Make_Logical_Decoding_Message` declares `Transactional : Boolean := False`. Through `Managed_Primary` that aborts the whole replication stream.

## Problem

Commit `6f496f5`.

The rule is applied to every kind in the arm (`src/flyology-postgres-replication-logical-producer.adb:128-134`):

```ada
when Origin_Message | Logical_Decoding_Message |
     Relation_Message | Type_Message | Insert_Message |
     Update_Message | Delete_Message | Truncate_Message =>
   Require
     (Item.Current in Regular_Transaction | Stream_Segment |
        Preparing_Transaction,
      "pgoutput data message is outside a transaction");
```

`Logical.Is_Transactional` (`src/flyology-postgres-replication-logical.ads:583-587`) exists and is never called from the producer body.

The message type is modelled with the flag, and it defaults to False (`src/flyology-postgres-replication-logical.ads:242-247`):

```ada
function Make_Logical_Decoding_Message
  (Message_LSN   : LSN;
   Prefix        : String;
   Content       : Byte_Array;
   Transactional : Boolean := False;
   Xid           : Transaction_Id := 0) return Message;
```

pgoutput sends a BEGIN first only for the transactional case (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/pgoutput/pgoutput.c:1699-1719`):

```c
	/*
	 * Output BEGIN if we haven't yet. Avoid for non-transactional messages.
	 */
	if (transactional)
	{
		PGOutputTxnData *txndata = (PGOutputTxnData *) txn->output_plugin_private;

		/* Send BEGIN if we haven't yet */
		if (txndata && !txndata->sent_begin_txn)
			pgoutput_send_begin(ctx, txn);
	}

	OutputPluginPrepareWrite(ctx, true);
	logicalrep_write_message(ctx->out,
							 xid,
							 message_lsn,
							 transactional,
							 prefix,
							 sz,
							 message);
	OutputPluginWrite(ctx, true);
```

A message written by `pg_logical_emit_message(false, ...)` never reaches the reorder buffer's change queue at all. `ReorderBufferQueueMessage` calls the output plugin straight away for the non-transactional case (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/reorderbuffer.c:901-916`):

```c
	else
	{
		ReorderBufferTXN *txn = NULL;
		volatile Snapshot snapshot_now = snap;

		/* Non-transactional changes require a valid snapshot. */
		Assert(snapshot_now);

		if (xid != InvalidTransactionId)
			txn = ReorderBufferTXNByXid(rb, xid, true, NULL, lsn, true);

		/* setup snapshot to allow catalog access */
		SetupHistoricSnapshot(snapshot_now, NULL);
		PG_TRY();
		{
			rb->message(rb, txn, lsn, false, prefix, message_size, message);
```

So the message is written out at decode time, outside any transaction boundary, including between two segments of a paused streamed transaction. That is the one position the producer refuses.

The restriction is not documented. `README.md:366-367` says only that "`Logical.Producer` validates transaction ordering while encoding the existing typed messages as `pgoutput`", and `src/flyology-postgres-replication-logical-producer.ads:43-44` documents the exception as "The transaction sequence, envelope, or negotiated protocol configuration is invalid".

The only logical decoding message anywhere in the suite is built with `Transactional => True` and goes through `Logical.Encode`, not through the producer (`tests/src/replication_tests.adb:1101-1104`). The producer test (`tests/src/replication_tests.adb:1372-1455`) never emits one at all. Its one out-of-transaction rejection check uses an `Insert` (`tests/src/replication_tests.adb:1413-1427`), which is correct for that kind and does not cover this one.

The blanket treatment of the data-message group is the same one that lets an unstreamed data message through an open segment ({{ISSUE:LOGICAL-1}}).

## What happens now

Spike: the program emits a non-transactional logical decoding message on an idle version-1 producer and again between two segments of a paused streamed transaction, asserting both are emitted and that the first decodes back to what was built. It then emits a transactional one outside a transaction and asserts that it is still rejected.

```ada
Producer.Configure (E, Version => 1);

Data : constant Logical.Byte_Array :=
  Producer.Emit
    (E,
     Logical.Make_Logical_Decoding_Message
       (Message_LSN   => 16#100#,
        Prefix        => "app",
        Content       => (1 => 1),
        Transactional => False),
     16#100#, 16#101#);
Read_Back : constant Logical.Message := Logical.Decode (Data, Version => 1);
```

```
  -- non-transactional message outside a transaction rejected: pgoutput data message is outside a transaction
  -- non-transactional message between segments rejected: pgoutput data message is outside a transaction
  FAILED: Producer emits a non-transactional logical decoding message outside any transaction
  FAILED: the emitted non-transactional message decodes back to what was built
  FAILED: Producer emits a non-transactional logical decoding message between two segments of a paused streamed transaction
  ok: a transactional logical decoding message outside a transaction is still rejected
BUG REPRODUCED: 3 failed expectation(s)
```

Both positions pgoutput uses are refused with `Protocol_Error`. The last line confirms that a transactional message outside a transaction is still correctly rejected, so the fix has to be narrowed by the flag rather than removed.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 17.10 server sources used for reference.

## What should happen

A `Logical_Decoding_Message` with `Is_Transactional` False should be accepted in any producer state, matching `pgoutput_message`, which emits it without a preceding BEGIN. A transactional one should keep the current requirement of an open transaction.

## Suggested treatment

Split `Logical_Decoding_Message` out of the shared `Require` at `src/flyology-postgres-replication-logical-producer.adb:131-134` and gate it on `Logical.Is_Transactional (Message)`: require `Item.Current in Regular_Transaction | Stream_Segment | Preparing_Transaction` only when the flag is set. The existing check stays as it is for the other kinds in the arm. The regression test belongs in `Test_Logical_Producer` (`tests/src/replication_tests.adb:1372-1455`); the spike is the test, including its transactional counter-case. No existing test asserts the current behaviour.

## Severity

An application logical source that produces a non-transactional logical decoding message gets `Protocol_Error` on valid input, and through `Managed_Primary` that aborts the replication stream rather than skipping one message. It needs a source that emits such a message, which is what `pg_logical_emit_message(false, ...)` produces and what the constructor's default setting builds. Deterministic.
