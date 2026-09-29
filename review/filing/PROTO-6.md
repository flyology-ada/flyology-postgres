Title: Read_C_String reports a size-limit violation for an empty buffer instead of a missing terminator
Labels: bug
Refs: none

## Summary

`Read_C_String` bundles an oversized buffer, a cursor before the buffer and a cursor past the end of the buffer into one check whose message is "Postgres string exceeds the configured limit". The documented condition for an exhausted buffer is the opposite, and the accurate "unterminated Postgres string" message is reachable only once at least one byte remains. The empty case is reachable from the wire: a frontend Query message with a length field of 4 produces a zero-byte payload, and `Server_Sessions.Query_Text` reads it. The wrong text then reaches the peer, because the server forwards the exception message verbatim into the FATAL ErrorResponse.

## Problem

Commit `6f496f5`.

The conjoined check and the accurate message it shadows (`src/flyology-postgres-protocol.adb:156-164`):

```ada
   begin
      Require
        (Source'Length <= Maximum_Message_Size
         and then Cursor >= Source'First
         and then Cursor <= Source'Last,
         "Postgres string exceeds the configured limit");
      Position := Wire.Wire_Length (Cursor - Source'First);
      Wire.Try_Read_C_String (Source, Position, View, Success);
      Require (Success, "unterminated Postgres string");
```

For a `1 .. 0` buffer with `Cursor = 1` the third conjunct fails, so the size-limit message is raised and `:164` is never reached.

The documented condition (`src/flyology-postgres-protocol.ads:684-690`):

```ada
   function Read_C_String
     (Source : Byte_Array; Cursor : in out Byte_Offset) return String;
   --  Read bytes through the next zero terminator and advance Cursor.
   --  @param Source Buffer being decoded.
   --  @param Cursor First text byte; advanced past the terminator.
   --  @return String containing bytes before the terminator.
   --  @exception Protocol_Error No terminator remains in Source.
```

The wire-reachable path runs through the server's Query handling. A frontend `Q` message whose length field is 4 satisfies `Wire.Valid_Typed_Length` (`src/flyology-postgres-wire.ads:319-320`), yields `Content_Length` of 0, and `Framing.Read_Message` builds a message with an empty payload (`src/flyology-postgres-framing.adb:76-80`). `Query_Text` then calls `Read_C_String` with the cursor at `Contents'First` on that empty array (`src/flyology-postgres-server_sessions.adb:471-479`):

```ada
   function Query_Text (Command : Protocol.Message) return String is
      Contents : constant Protocol.Byte_Array := Protocol.Payload (Command);
      Cursor   : Protocol.Byte_Offset := Contents'First;
   begin
      if Protocol.Kind (Command) /= Protocol.Query then
         raise Protocol.Protocol_Error with "message is not a Query command";
      end if;
      declare
         Result : constant String := Protocol.Read_C_String (Contents, Cursor);
```

`Password_Text` (`src/flyology-postgres-server_sessions.adb:489`), `SASL_Initial_Response` (`:514`), and the client's SASL mechanism loop (`src/flyology-postgres-client.adb:262-264`) reach it the same way.

The wrong text reaches the peer, because `Run_Session` forwards the exception message verbatim (`src/flyology-postgres-server.adb:525-532`):

```ada
      when Error : Protocol.Protocol_Error =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "08P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
```

`Test_Malformed_String` does not catch this. It uses a one-byte buffer, which reaches the accurate message, and it only asserts that some `Protocol_Error` was raised without inspecting the text (`tests/src/tests.adb:404-422`):

```ada
      Contents : constant Protocol.Byte_Array (1 .. 1) :=
        (1 => Protocol.Byte (Character'Pos ('x')));
...
      Assert (Rejected, "unterminated strings are rejected");
```

## What happens now

Spike: `Read_C_String` is called on an empty buffer and on a one-byte unterminated buffer, and the two exception messages are compared. The program then drives the wire-reachable path by calling `Server_Sessions.Query_Text` on a `Q` message with an empty payload. It asserts that each case reports a missing terminator, which is the documented condition.

```ada
   Empty     : constant Protocol.Byte_Array (1 .. 0) := (others => 0);
   One_Byte  : constant Protocol.Byte_Array := B ("a");
...
   function Mentions_Termination (Text : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, "unterminated") > 0
      or else Ada.Strings.Fixed.Index (Text, "terminator") > 0);
...
   Check
     (Mentions_Termination (Empty_Message),
      "an empty buffer reports a missing terminator, not a size-limit "
      & "violation");
...
         Text : constant String :=
           Sessions.Query_Text (Protocol.Make_Message ('Q', Empty));
```

```
  -- protocol.ads:690 -- "@exception Protocol_Error No terminator remains in Source."
  -- empty (1 .. 0) buffer, cursor 1 -> "Postgres string exceeds the configured limit"
  -- one-byte unterminated buffer      -> "unterminated Postgres string"
  ok: an unterminated non-empty buffer reports a missing terminator
  FAILED: an empty buffer reports a missing terminator, not a size-limit violation
  -- Server_Sessions.Query_Text on an empty 'Q' payload -> "Postgres string exceeds the configured limit"
  FAILED: an empty Query payload is diagnosed as an unterminated string, not as exceeding the configured message-size limit
BUG REPRODUCED: 2 failed expectation(s)
```

The one-byte control passes with the accurate message, isolating the failure to the exhausted-buffer case. The second failure is the wire-reachable one: a zero-byte payload is reported as exceeding a 16 MiB limit.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A buffer with no bytes left to read should be diagnosed as having no terminator, which is what `src/flyology-postgres-protocol.ads:690` documents. The size-limit message should be raised only when `Source'Length` actually exceeds `Maximum_Message_Size`. Which inputs are rejected does not change; only the text does.

## Suggested treatment

Split the `Require` at `src/flyology-postgres-protocol.adb:157-161` into two. Keep `Source'Length <= Maximum_Message_Size` under the existing size-limit message, and move `Cursor >= Source'First and then Cursor <= Source'Last` under the "unterminated Postgres string" message that already exists at `:164`. A cursor before `Source'First` is caller misuse rather than an exhausted buffer, so a maintainer may prefer a third message for it; that is a wording choice, not a behavioural one.

The regression test belongs in `tests/src/tests.adb` at `Test_Malformed_String` (`tests/src/tests.adb:404-422`), which must be extended to cover the empty buffer and to assert the message rather than only that an exception was raised; the spike is the test. No existing test asserts the current text, so none has to change.

## Severity

A client that sends a zero-payload `Q`, `p`, or SASL message receives a FATAL ErrorResponse claiming its string exceeded a size limit when the payload was zero bytes long, which points a maintainer at the wrong cause. The rejection itself is correct, the exception type is the documented one, and no result is wrong; only the diagnostic text is. Reaching it takes a malformed or truncated message from the peer, not a valid one. Deterministic.
