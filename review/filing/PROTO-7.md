Title: Maximum_Message_Size is documented as a frame bound but typed messages may be one byte larger
Labels: bug
Refs: none

## Summary

`Maximum_Message_Size` is documented as the largest complete wire message including its type byte and encoded length, which makes it a bound on the frame. On the typed-message path both ends are one byte loose relative to that: `Make_Message` admits a payload of `Maximum_Message_Size - 4`, which encodes to `Maximum_Message_Size + 1` bytes, and `Valid_Typed_Length` accepts a length field of `Maximum_Message_Size`, after which `Read_Message` reads `Maximum_Message_Size + 1` bytes. The untagged initial-packet path honours the bound exactly, so the two message families disagree about what the constant means.

## Problem

Commit `6f496f5`.

The documented meaning (`src/flyology-postgres.ads:6-8`):

```ada
   Maximum_Message_Size : constant := 16 * 1_024 * 1_024;
   --  Largest complete PostgreSQL wire message accepted by the library,
   --  including its type byte and encoded length.
```

echoed at `src/flyology-postgres-protocol.ads:33-34`:

```ada
   Maximum_Message_Size : constant := Flyology.Postgres.Maximum_Message_Size;
   --  Largest accepted complete wire message, including header bytes.
```

The write side admits a payload four bytes below the bound (`src/flyology-postgres-protocol.adb:176-181`):

```ada
   function Make_Message
     (Code : Character; Payload : Byte_Array) return Message is
   begin
      Require
        (Payload'Length <= Maximum_Message_Size - 4,
         "Postgres message exceeds the configured limit");
```

and `Encode` then emits one tag byte, four length bytes and the payload, which is `Maximum_Message_Size + 1` bytes in total (`src/flyology-postgres-protocol.adb:222-229`):

```ada
   function Encode (Item : Message) return Byte_Array is
      Result : Flyology.Bytes.Unbounded_Bytes;
   begin
      Append_Byte (Result, Byte (Character'Pos (Item.Tag)));
      Append_U32 (Result, UInt32 (Payload_Length (Item) + 4));
      Append_Bytes (Result, Payload (Item));
      return Flyology.Bytes.To_Array (Result);
   end Encode;
```

The read side is symmetric (`src/flyology-postgres-wire.ads:319-320`):

```ada
   function Valid_Typed_Length (Length : UInt32) return Boolean is
     (Length >= 4 and then Length <= UInt32 (Maximum_Frame_Size));
```

`Maximum_Frame_Size` is `Maximum_Message_Size` (`src/flyology-postgres-wire.ads:47`), and `Framing.Read_Message` reads one tag byte plus `Length` bytes for an accepted length (`src/flyology-postgres-framing.adb:70-80`), so the accepted frame is again `Maximum_Message_Size + 1`.

The untagged path honours the bound exactly, which is what makes this a slip specific to typed messages rather than a consistent reading of the constant. `Valid_Initial_Length` requires `Length <= Maximum_Frame_Size` for a packet whose frame *is* `Length` bytes (`src/flyology-postgres-wire.ads:316-317`), and `Encode_Startup` checks the encoded total (`src/flyology-postgres-protocol.adb:1261-1263`):

```ada
      Require
        (Flyology.Bytes.Length (Contents) + 4 <= Maximum_Message_Size,
         "startup packet exceeds the configured limit");
```

No test catches it because no test constructs a message at the boundary. The message tests use short payloads, and nothing asserts the encoded length of a maximal frame.

## What happens now

Spike: `Valid_Typed_Length` is queried at `Maximum_Message_Size` and at `Maximum_Message_Size - 1`, and `Make_Message` is given a real payload of `Maximum_Message_Size - 4` bytes. The program asserts that the last admissible value on each side produces a frame no larger than the documented maximum.

```ada
   Max : constant := Protocol.Maximum_Message_Size;
   Largest_Payload : constant Protocol.Byte_Offset :=
     Protocol.Byte_Offset (Max) - 4;
...
   Check
     (not Wire.Valid_Typed_Length (Protocol.UInt32 (Max)),
      "a typed length field of Maximum_Message_Size is rejected, because "
      & "the resulting frame is Maximum_Message_Size + 1 bytes");
   Check
     (Wire.Valid_Typed_Length (Protocol.UInt32 (Max - 1)),
      "a typed length field of Maximum_Message_Size - 1 is still accepted");
...
   Buffer := new Protocol.Byte_Array'(1 .. Largest_Payload => 0);
   ...
         Item : constant Protocol.Message :=
           Protocol.Make_Message ('d', Buffer.all);
      begin
         Frame :=
           Protocol.Byte_Offset (Protocol.Payload_Length (Item)) + 5;
```

```
  -- Maximum_Message_Size = 16777216; documented as the largest complete message INCLUDING the type byte and the encoded length
  -- Wire.Valid_Typed_Length ( 16777216 ) -> TRUE; that length describes a 16777217-byte frame
  FAILED: a typed length field of Maximum_Message_Size is rejected, because the resulting frame is Maximum_Message_Size + 1 bytes
  ok: a typed length field of Maximum_Message_Size - 1 is still accepted
  -- Make_Message ('d', payload of 16777212 bytes) succeeded; Encode would emit 16777217 bytes
  FAILED: Make_Message rejects a payload whose complete frame would exceed Maximum_Message_Size
  -- the encoded frame would be 1 byte(s) larger than the documented maximum
BUG REPRODUCED: 2 failed expectation(s)
```

The `Max - 1` control still passes, isolating the failure to the last admissible value. The payload is a real allocation, so the reported 16777217-byte frame is the size `Encode` would emit, not an arithmetic estimate.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Maximum_Message_Size` should mean one thing on both message families. Either a typed frame of `1 + 4 + payload` bytes must fit within it, matching the sentence at `src/flyology-postgres.ads:6-8` and the exactness of `Valid_Initial_Length` and `Encode_Startup`, or the constant is documented as bounding the length field rather than the frame.

## Suggested treatment

This needs a maintainer decision, because it is a choice about the meaning of a published limit rather than an isolated expression.

Tightening the code changes `Make_Message` at `src/flyology-postgres-protocol.adb:180` to `Payload'Length <= Maximum_Message_Size - 5` and `Valid_Typed_Length` at `src/flyology-postgres-wire.ads:320` to `Length <= UInt32 (Maximum_Frame_Size) - 1`, so the frame bound holds on both families. That narrows the published limit by one byte, which is visible to any consumer sitting exactly at it, and `Valid_Typed_Length` carries a `Post` contract on `Content_Length` (`src/flyology-postgres-wire.ads:322-325`), so the proved wire core has to be rechecked.

Re-documenting instead changes the two sentences at `src/flyology-postgres.ads:7-8` and `src/flyology-postgres-protocol.ads:34` to say that the constant bounds the encoded length field, and notes that a typed frame is one byte larger. That leaves every accepted input accepted, but the untagged path then honours a stricter bound than the typed one for no stated reason, so `Valid_Initial_Length` and `Encode_Startup` would want a matching note.

Either way the regression test belongs in `tests/src/tests.adb` beside the message-encoding tests, asserting the accepted and rejected values on both sides of the boundary; the spike is the test for the tightening. No existing test asserts the current boundary, so none has to change.

## Severity

Nothing misbehaves at runtime. The encoder and the decoder agree with each other, since `Make_Message` admits `Maximum_Message_Size - 4` of payload and `Valid_Typed_Length` admits a length field of `Maximum_Message_Size`, and both describe the same `Maximum_Message_Size + 1` byte frame. Buffers are sized from the actual length, so there is no memory effect, and 16 MiB is far below PostgreSQL's own limit, so no peer rejects the extra byte and there is no interop effect. What is wrong is the documented bound, by one byte, and only on typed messages. Which side to correct is a policy call about a published limit rather than a defect with a single right answer. Deterministic.
