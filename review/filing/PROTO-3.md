Title: Decode_Initial is documented as taking the complete packet but decodes the bytes after the length field
Labels: bug, documentation
Refs: none

## Summary

`Decode_Initial` is documented as decoding an untagged initial packet "including its length field", with `Contents` described as "Complete packet bytes". The implementation decodes the bytes after the length word instead. Passing the complete packet, as documented, makes the length word be read as the request code, and because a length is neither a recognised special code nor major version 3, every such packet is classified `Unknown_Initial` with no exception raised. Round tripping the library's own encoder output through the documented entry point therefore fails silently.

## Problem

Commit `6f496f5`.

The documented contract (`src/flyology-postgres-protocol.ads:588-592`):

```ada
   function Decode_Initial (Contents : Byte_Array) return Initial_Request;
   --  Strictly decode an untagged initial packet including its length field.
   --  @param Contents Complete packet bytes.
   --  @return Classified owned initial request.
   --  @exception Protocol_Error Length or recognized contents are malformed.
```

The wire layer reads byte 0 of `Contents` as the request code (`src/flyology-postgres-wire.adb:233-249`):

```ada
      Try_Read_U32 (Data, Cursor, Code, Success);
      ...
      if Code = SSL_Request_Code then
         Value.Kind := SSL_Request;
      ...
      elsif Code = Cancel_Request_Code then
```

and an unrecognised code that is not major version 3 is classified without any error (`src/flyology-postgres-wire.adb:264-267`):

```ada
      elsif Shift_Right (Code, 16) /= 3 then
         Value.Kind := Unknown_Request;
         Status := Initial_Ok;
         return;
```

The protocol layer restarts the parameter walk immediately after the version word, not after a length plus a version word (`src/flyology-postgres-protocol.adb:1180-1183`):

```ada
            declare
               Cursor : Byte_Offset := Contents'First + 4;
            begin
               while Contents (Cursor) /= 0 loop
```

Both in-repo callers agree with the code and contradict the specification. `Framing.Read_Initial` reads and validates the length itself, then passes only the bytes after it (`src/flyology-postgres-framing.adb:51-59`):

```ada
      Length : constant Protocol.UInt32 := Read_Length (Channel, Timeout);
   begin
      if not Wire.Valid_Initial_Length (Length) then
         raise Protocol.Protocol_Error with
           "invalid initial Postgres packet length";
      end if;
      return Protocol.Decode_Initial
        (Read_Contents
           (Channel, Natural (Wire.Content_Length (Length)), Timeout));
```

The unit test does the same, slicing the packet after a `Read_U32` (`tests/src/tests.adb:271-275`):

```ada
      Cursor : Protocol.Byte_Offset := Packet'First;
      Length : constant Protocol.UInt32 :=
        Protocol.Read_U32 (Packet, Cursor);
      Initial : constant Protocol.Initial_Request :=
        Protocol.Decode_Initial (Packet (Cursor .. Packet'Last));
```

That is why no test catches this. Every call site in the repository already strips the length, so nothing here ever exercises the documented usage, and the misclassification is silent when it does happen.

## What happens now

Spike: the library's own `Encode_SSL_Request`, `Encode_Cancel_Request` and `Encode_Startup` output is fed to `Decode_Initial` unmodified, which is the most natural reading of "Complete packet bytes". The program asserts that each complete packet is classified as its own kind.

```ada
      begin
         Result := Protocol.Kind (Protocol.Decode_Initial (Packet));
      ...
      Check
        (not Failed and then Result = Expected,
         Label & " decodes as " & Expected'Image
         & " when the complete packet is passed, as documented");
...
   Classify
     ("complete 8-byte SSLRequest packet",
      Protocol.Encode_SSL_Request,
      Protocol.SSL_Request);
   Classify
     ("complete CancelRequest packet",
      Protocol.Encode_Cancel_Request (12345, (1 .. 4 => 16#AB#)),
      Protocol.Cancel_Request);
   Classify
     ("complete startup packet",
      Protocol.Encode_Startup (User => "alice"),
      Protocol.Startup);
```

```
  -- protocol.ads:589 -- "Strictly decode an untagged initial packet including its length field."
  -- protocol.ads:590 -- "@param Contents Complete packet bytes."
  -- complete 8-byte SSLRequest packet: Decode_Initial -> UNKNOWN_INITIAL (expected SSL_REQUEST)
  FAILED: complete 8-byte SSLRequest packet decodes as SSL_REQUEST when the complete packet is passed, as documented
  -- complete CancelRequest packet: Decode_Initial -> UNKNOWN_INITIAL (expected CANCEL_REQUEST)
  FAILED: complete CancelRequest packet decodes as CANCEL_REQUEST when the complete packet is passed, as documented
  -- complete startup packet: Decode_Initial -> UNKNOWN_INITIAL (expected STARTUP)
  FAILED: complete startup packet decodes as STARTUP when the complete packet is passed, as documented
BUG REPRODUCED: 3 failed expectation(s)
```

No `Protocol_Error` is raised for any of the three packet kinds. All three are misclassified silently.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

The code and the specification should agree about what `Contents` holds. Either `Decode_Initial` accepts and validates the leading length word as `src/flyology-postgres-protocol.ads:589-590` states, or the specification says that `Contents` is the packet body after the length, which is what both in-repo callers pass and what the implementation reads.

## Suggested treatment

This is a maintainer decision, though the evidence points one way.

The documentation fix corrects the two sentences at `src/flyology-postgres-protocol.ads:589-590` to say that `Contents` is the packet body after the four-byte length, and renames the parameter accordingly, for instance to `Body_Bytes`, so the signature carries the meaning rather than only the comment. Nothing in the repository changes behaviour, and `Framing.Read_Initial` remains the operation that owns length validation. This is the fix the call sites and the tests already assume.

The code fix makes `Decode_Initial` read and validate the length word itself, then decode the remainder. That matches the published sentence but duplicates the length validation `Framing.Read_Initial` performs at `src/flyology-postgres-framing.adb:53-56`, and it breaks every existing caller, both in-repo ones included.

Whichever is chosen, a regression test belongs in `tests/src/tests.adb` beside `Test_Startup` (`tests/src/tests.adb:265-277`), round tripping each of the three encoders through the documented entry point; the spike is the test for the code fix. `Test_Startup` itself is written against the current behaviour and would have to change if the code fix is taken.

## Severity

Nothing in this repository misbehaves, because no in-repo path passes a complete packet. The impact falls on an external consumer of a public entry point: following the documented usage produces a wrong classification for all three initial packet kinds, with no exception and no diagnostic, so the caller sees `Unknown_Initial` and has nothing to go on. A server built that way would refuse every SSLRequest, CancelRequest and startup packet it received. Deterministic.
