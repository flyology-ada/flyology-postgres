Title: Abort_LSN and Event_Timestamp raise on a Stream Abort built with version-4 metadata by Make_Stream_Abort
Labels: bug
Refs: none

## Summary

`Make_Stream_Abort` accepts a version-4 abort LSN and abort timestamp and stores both, and `Encode (Item, 4, Parallel)` writes both out. `Abort_LSN` and `Event_Timestamp` are gated on the private `Parallel_Stream` flag, which only `Decode` ever sets, so both accessors raise `Protocol_Error` on the message the caller just built. The documented exception condition is that the message lacks version-4 abort metadata, which is false here. An application that constructs a parallel-stream abort cannot read back the values it supplied, while the identical logical value obtained from the wire behaves correctly.

## Problem

Commit `6f496f5`.

The constructor stores both values and leaves the flag alone (`src/flyology-postgres-replication-logical.adb:460-473`):

```ada
function Make_Stream_Abort
  (Xid        : Transaction_Id;
   Subxid     : Transaction_Id;
   Abort_LSN  : LSN := 0;
   Aborted_At : Replication_Timestamp := 0) return Message is
   Result : Message := (others => <>);
begin
   Result.Message_Type := Stream_Abort_Message;
   Result.Xid := Xid;
   Result.Subxid := Subxid;
   Result.First_Position := Abort_LSN;
   Result.First_Time := Aborted_At;
   return Result;
end Make_Stream_Abort;
```

`Encode` writes them for the parallel streaming mode (`src/flyology-postgres-replication-logical.adb:799-806`):

```ada
when Stream_Abort_Message =>
   Append_Tag (Result, 'A');
   Protocol.Append_U32 (Result, Item.Xid);
   Protocol.Append_U32 (Result, Item.Subxid);
   if Streaming = Parallel then
      Append_LSN (Result, Item.First_Position);
      Append_Time (Result, Item.First_Time);
   end if;
```

The accessors do not consult the streaming mode or the wire version. They require `Parallel_Stream` (`src/flyology-postgres-replication-logical.adb:1348-1355` and `:1367-1371`):

```ada
function Abort_LSN (Item : Message) return LSN is
begin
   Require
     (Item.Message_Type = Stream_Abort_Message
      and then Item.Parallel_Stream,
      "logical message has no parallel-stream abort LSN");
   return Item.First_Position;
end Abort_LSN;
```

```ada
Require
  (Item.Message_Type /= Stream_Abort_Message
   or else Item.Parallel_Stream,
   "non-parallel StreamAbort has no event timestamp");
```

`Parallel_Stream` is declared in the private record with the default False (`src/flyology-postgres-replication-logical.ads:720`) and is assigned in exactly one place, inside `Decode` (`src/flyology-postgres-replication-logical.adb:874`):

```ada
Result.Parallel_Stream := Streaming = Parallel;
```

Those are the only three occurrences in the package: the one assignment at `:874` and the two reads at `:1352` and `:1369`. No constructor sets it, so no constructed message can ever satisfy the gate.

The contract the accessors publish is about the metadata, not about the message's provenance (`src/flyology-postgres-replication-logical.ads:555-559`):

```ada
function Abort_LSN (Item : Message) return LSN;
--  Return the version-4 stream abort record's LSN.
--  @param Item Version-4 Stream_Abort_Message.
--  @return Abort record LSN.
--  @exception Protocol.Protocol_Error Item lacks version-4 abort metadata.
```

`Event_Timestamp` carries the same promise at `src/flyology-postgres-replication-logical.ads:560-565`. `Make_Stream_Abort` documents its two parameters as "Version-4 abort record LSN, otherwise zero" and "Version-4 abort timestamp, otherwise zero" (`src/flyology-postgres-replication-logical.ads:354-355`), so a message built with non-zero values does carry the metadata.

The tests exercise the two accessors only on decoded messages. `tests/src/replication_tests.adb:1022-1027` decodes a version-4 parallel `'A'` message and asserts `Abort_LSN` and `Event_Timestamp`. The constructed counterpart, `Make_Stream_Abort (51, 52, 53, 54)` at `tests/src/replication_tests.adb:1165-1168`, is passed to a helper that only compares `Kind` and re-encodes the decoded copy (`tests/src/replication_tests.adb:1079-1096`):

```ada
Assert
  (Logical.Kind (Decoded) = Logical.Kind (Item),
   "logical constructor preserves its message kind");
Assert
  (Logical.Encode (Decoded, Version, Streaming) = Encoded,
   "logical messages have a canonical encode/decode round trip");
```

Neither accessor is ever called on `Item`, only on the decoded result, so the asymmetry is invisible to the suite.

## What happens now

Spike: the program builds one Stream Abort with `Make_Stream_Abort (51, 52, 53, 54)`, encodes it at version 4 in the parallel streaming mode, reads the two accessors on the constructed message, and then decodes the same bytes and reads them again.

```ada
Built : constant Logical.Message :=
  Logical.Make_Stream_Abort (Top_Xid, Sub_Xid, Abort_At, Aborted_At);

Wire : constant Logical.Byte_Array :=
  Logical.Encode (Built, 4, Logical.Parallel);
...
LSN_Readable  := Logical.Abort_LSN (Built) = Abort_At;
Time_Readable := Logical.Event_Timestamp (Built) = Aborted_At;
...
Decoded : constant Logical.Message :=
  Logical.Decode (Wire, Version => 4, Streaming => Logical.Parallel);
```

```
  -- Make_Stream_Abort (51, 52, 53, 54) encodes at v4/parallel as: 41 00 00 00 33 00 00 00 34 00 00 00 00 00 00 00 35 00 00 00 00 00 00 00 36
  -- Abort_LSN (built) raised Protocol_Error: logical message has no parallel-stream abort LSN
  -- Event_Timestamp (built) raised Protocol_Error: non-parallel StreamAbort has no event timestamp
  -- after a v4/parallel round trip: Abort_LSN = 53, Event_Timestamp = 54
  FAILED: Abort_LSN returns the abort LSN supplied to Make_Stream_Abort
  FAILED: Event_Timestamp returns the abort time supplied to Make_Stream_Abort
BUG REPRODUCED: 2 failed expectation(s)
```

The encoded bytes end in `35` and `36`, the abort LSN 53 and the timestamp 54 the constructor was given, and both accessors refuse to return them from the object that produced those bytes. The same two values are readable after a wire round trip.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Abort_LSN` and `Event_Timestamp` should return the values a `Stream_Abort_Message` carries whether it was decoded or constructed, so that a message built by `Make_Stream_Abort` and the message obtained by decoding its own encoding behave identically. The exception should be raised when the metadata is genuinely absent, as the accessors document.

## Suggested treatment

Set the flag in the constructor: in `Make_Stream_Abort` (`src/flyology-postgres-replication-logical.adb:460-473`) assign `Result.Parallel_Stream` when the caller supplied version-4 metadata. Deriving it from the arguments keeps the two defaulted parameters meaningful and leaves `Encode` and `Decode` untouched, since no wire bytes depend on the flag. The regression test belongs in `Test_Logical_Encoding` beside the existing `Make_Stream_Abort (51, 52, 53, 54)` case (`tests/src/replication_tests.adb:1165-1168`); the spike is the test. No existing test asserts the current behaviour.

This needs a maintainer decision on one point: what counts as "supplied". Deriving the flag from `Abort_LSN /= 0 or else Aborted_At /= 0` makes a genuine abort at LSN zero with timestamp zero indistinguishable from an omitted one, while adding an explicit parameter to `Make_Stream_Abort` changes a public profile. The alternative is to leave the behaviour and correct the two `@exception` lines at `src/flyology-postgres-replication-logical.ads:559` and `:565` to say that the accessors apply only to decoded messages.

## Severity

Two accessors raise `Protocol_Error` on a message that carries the values they return, so an application that builds a parallel-stream abort cannot inspect what it built, and code that works on decoded messages breaks when handed a constructed one. No wire bytes are affected and decoded messages behave correctly, so nothing wrong goes to a subscriber. It needs version-4 parallel streaming and a caller that reads the abort metadata back off a constructed message. Deterministic.
