Title: Logical.Producer emits a data message without the streamed xid prefix inside an open stream segment
Labels: bug
Refs: LOGICAL-2, LOGICAL-3

## Summary

`Producer.Emit` requires a streamed message to sit inside a stream segment, but never requires a message inside a segment to be streamed. A caller who leaves the defaulted `Xid` parameter of `Make_Insert` or `Make_Logical_Decoding_Message` alone while a segment is open gets bytes with no four-byte xid prefix, and the producer keeps reporting `Stream_Segment`. A consumer inside that same segment consumes four bytes of xid unconditionally, so it either rejects the message or silently reads a different one. `Managed_Primary` forwards the producer's output verbatim to `Send_XLog_Data`, so the shifted bytes reach a live subscriber.

## Problem

Commit `6f496f5`.

The data-message arm of `Producer.Emit` checks one direction only (`src/flyology-postgres-replication-logical-producer.adb:128-140`):

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

`Is_Streamed` returns the private `Streamed` field (`src/flyology-postgres-replication-logical.adb:1283`), and every xid-bearing constructor derives that field from a defaulted parameter (`src/flyology-postgres-replication-logical.adb:357-368`):

```ada
function Make_Insert
  (Relation_Id : UInt32;
   New_Tuple   : Tuple_Data;
   Xid         : Transaction_Id := 0) return Message is
   Result : Message := (others => <>);
begin
   Result.Message_Type := Insert_Message;
   Result.Relation := Relation_Id;
   Result.After := New_Tuple;
   Result.Xid := Xid;
   Result.Streamed := Xid /= 0;
```

`Make_Logical_Decoding_Message` derives it the same way (`src/flyology-postgres-replication-logical.adb:312-313`), and `Encode` writes the prefix only when the flag is set (`src/flyology-postgres-replication-logical.adb:638-643`):

```ada
procedure Append_Stream_Xid is
begin
   if Item.Streamed then
      Protocol.Append_U32 (Result, Item.Xid);
   end if;
end Append_Stream_Xid;
```

That procedure is called for exactly the seven xid-bearing tags, `Logical_Decoding_Message`, `Relation_Message`, `Type_Message`, `Insert_Message`, `Update_Message`, `Delete_Message` and `Truncate_Message` (`src/flyology-postgres-replication-logical.adb:696`, `:711`, `:733`, `:740`, `:747`, `:760`, `:772`). `Origin_Message` correctly carries no xid (`src/flyology-postgres-replication-logical.adb:689-692`).

pgoutput has no such choice. It takes the xid from the transaction whenever streaming is active (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/pgoutput/pgoutput.c:1462-1469`):

```c
	/*
	 * Remember the xid for the change in streaming mode. We need to send xid
	 * with each change in the streaming mode so that subscriber can make
	 * their association and on aborts, it can discard the corresponding
	 * changes.
	 */
	if (data->in_streaming)
		xid = change->txn->xid;
```

`pgoutput_truncate` repeats it (`pgoutput.c:1626-1628`) and so does `pgoutput_message` (`pgoutput.c:1692-1697`). `logicalrep_write_message` then writes the prefix for any valid xid (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/proto.c:655-657`):

```c
	/* transaction ID (if not valid, we're not streaming) */
	if (TransactionIdIsValid(xid))
		pq_sendint32(out, xid);
```

PostgreSQL's apply worker reads those four bytes back unconditionally for every data message while a streamed transaction is open (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/worker.c:584-593`):

```c
	/*
	 * We should have received XID of the subxact as the first part of the
	 * message, so extract it.
	 */
	current_xid = pq_getmsgint(s, 4);

	if (!TransactionIdIsValid(current_xid))
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg_internal("invalid transaction ID in streamed replication transaction")));
```

This library's own stateful `Decoder` behaves identically through its `In_Stream` flag (`src/flyology-postgres-replication-logical.adb:1235-1247`).

The bytes go on the wire unchanged. `Managed_Primary` hands every message from the application logical source to `Producer.Emit` and sends the result as it stands (`src/flyology-postgres-replication-managed_primary.adb:264-271`):

```ada
declare
   Data : constant Logical.Byte_Array :=
     Producer.Emit (Encoder, Message, Start_LSN, End_LSN);
begin
   Replication_Sessions.Send_XLog_Data
     (Client, Start_LSN, End_LSN, Sent_At => 0, Data => Data,
      Timeout => Item.Operation_Timeout);
end;
```

There is no second validation layer between the producer and the subscriber.

The tests never build a data message without an xid inside a segment. The producer test streams one Insert and passes `Xid => 20` explicitly (`tests/src/replication_tests.adb:1405-1408`), and the encoder round-trip test passes it too (`tests/src/replication_tests.adb:1140-1144`). The default is not covered anywhere.

The same one-directional ordering model produces wrong results for a subtransaction abort and for interleaved transactions ({{ISSUE:LOGICAL-2}}), and for a non-transactional logical decoding message ({{ISSUE:LOGICAL-3}}).

## What happens now

Spike: the program opens one stream segment for xid 20 on a `Producer.Encoder` and on a `Logical.Decoder` configured the same way, then emits an Insert and a logical decoding message built with the default `Xid`, and asserts that the producer rejects them and that whatever bytes it does return are read back unchanged by the consumer sitting inside that segment. The message payload is chosen so that dropping four bytes still parses.

```ada
Producer.Configure (E, Version => 2, Streaming => Logical.In_Progress);
Logical.Configure  (D, Version => 2, Streaming => Logical.In_Progress);

Start_Bytes : constant Logical.Byte_Array :=
  Producer.Emit (E, Logical.Make_Stream_Start (Segment_Xid, True), 200, 201);

Data : constant Logical.Byte_Array :=
  Producer.Emit (E, Logical.Make_Insert (Relation, Row), 201, 202);

Data : constant Logical.Byte_Array :=
  Producer.Emit
    (E,
     Logical.Make_Logical_Decoding_Message
       (Message_LSN   => 16#0102_0300_0102_0304#,
        Prefix        => "abcdefgh",
        Content       => (1, 2, 3, 4),
        Transactional => True),
     202, 203);

M : constant Logical.Message := Logical.Decode (D, Data);
```

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

The Insert is emitted with no xid prefix, and the consumer reads `00 00 00 2a` as the xid and then fails on the shifted body. The logical decoding message is worse: it is accepted on both sides, and the consumer reads an xid of 16843267 that was never sent, `Transactional` flipped from True to False, LSN `0102030461626364` instead of `0102030001020304`, and prefix `"efgh"` instead of `"abcdefgh"`.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 17.10 server sources used for reference.

## What should happen

Inside `Stream_Segment` the producer should require every xid-bearing data message to carry the segment's xid, so its output always matches what pgoutput writes between `S` and `E` and what an apply worker reads back.

## Suggested treatment

Make the check at `src/flyology-postgres-replication-logical-producer.adb:131-140` symmetric: while `Item.Current = Stream_Segment`, require `Logical.Is_Streamed (Message)` for `Logical_Decoding_Message | Relation_Message | Type_Message | Insert_Message | Update_Message | Delete_Message | Truncate_Message`, keeping the existing xid-identity comparison. `Origin_Message` must stay exempt, since `Encode` writes no xid for it. The regression test belongs in `Test_Logical_Producer` (`tests/src/replication_tests.adb:1372-1455`); the spike is the test. No existing test asserts the current behaviour, so nothing has to change to accommodate the fix.

## Severity

A streamed transaction produced through `Managed_Primary` can carry data messages that a subscriber cannot parse, and in the logical decoding message case cannot detect: the subscriber accepts a message with an invented xid, an inverted transactional flag, a wrong LSN and a truncated prefix. It takes a caller who omits `Xid` on a message emitted inside a segment, and `Xid` is defaulted to zero on every one of those constructors, so it is what a caller who does not think about streaming writes. The producer holds the segment xid and could reject it. Deterministic.
