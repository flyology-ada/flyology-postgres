Title: Startup_Data, Process_Id and Secret_Key return record defaults instead of the documented Protocol_Error
Labels: bug, documentation
Refs: none

## Summary

The three `Initial_Request` accessors document `Protocol_Error` when the request is of the wrong variant, but they are unchecked component reads of a record that is not discriminated. Called on an SSLRequest or a CancelRequest, they return the record defaults: a `Startup_Information` with an empty user, a process identifier of zero, and a zero-length secret key. A consumer that follows the written contract and uses the exception as its variant test gets a plausible looking empty result instead, most dangerously a zero-length cancellation secret to compare against a real one.

## Problem

Commit `6f496f5`.

The documented contract (`src/flyology-postgres-protocol.ads:597-612`):

```ada
   function Startup_Data
     (Item : Initial_Request) return Startup_Information;
   --  Return fields carried by a startup packet.
   --  @param Item Startup request.
   --  @return Decoded supported startup fields.
   --  @exception Protocol_Error Item is not Startup.
   function Process_Id (Item : Initial_Request) return UInt32;
   --  Return the process identifier carried by CancelRequest.
   --  @param Item Cancel_Request.
   --  @return Target backend process identifier.
   --  @exception Protocol_Error Item is not Cancel_Request.
   function Secret_Key (Item : Initial_Request) return Byte_Array;
   --  Copy the secret carried by CancelRequest.
   --  @param Item Cancel_Request.
   --  @return Copy of target backend cancellation secret bytes.
   --  @exception Protocol_Error Item is not Cancel_Request.
```

The bodies are expression functions with no check (`src/flyology-postgres-protocol.adb:1217-1225`):

```ada
   function Startup_Data
     (Item : Initial_Request) return Startup_Information is
     (Item.Startup);

   function Process_Id (Item : Initial_Request) return UInt32 is
     (Item.Backend_Pid);

   function Secret_Key (Item : Initial_Request) return Byte_Array is
     (Flyology.Bytes.To_Array (Item.Secret));
```

`Initial_Request` is a plain record with defaults, not a discriminated one, so no `Constraint_Error` arises either (`src/flyology-postgres-protocol.ads:819-824`):

```ada
   type Initial_Request is record
      Request_Kind : Initial_Kind := Unknown_Initial;
      Startup      : Startup_Information;
      Backend_Pid  : UInt32 := 0;
      Secret       : Flyology.Bytes.Unbounded_Bytes;
   end record;
```

`Startup_Information`'s own defaults supply the plausible looking values, including `Protocol_Major : UInt16 := 3` and an empty `User` (`src/flyology-postgres-protocol.ads:569-576`).

The sibling `Backend_Message` accessors show the intended style, so this is drift rather than a deliberate omission (`src/flyology-postgres-protocol.adb:1051-1057`):

```ada
   function Description (Item : Backend_Message) return Row_Description is
   begin
      Require
        (Item.Response = Row_Description_Response,
         "backend response is not RowDescription");
      return Item.Row_Description_Value;
   end Description;
```

No in-repo caller is wrong today, which is why nothing fails. `Run_Session` guards on `Protocol.Kind` before every use (`src/flyology-postgres-server.adb:416-420`, `:431-432`), so the missing checks are never reached from inside the repository, and no test calls an accessor on the wrong variant.

## What happens now

Spike: the library's own `Encode_SSL_Request` output, with its length word stripped exactly as `Framing.Read_Initial` strips it, is decoded into an `Initial_Request`. The program first confirms the packet decoded as `SSL_Request`, then calls each of the three accessors and asserts that `Protocol_Error` is raised, as `protocol.ads` documents.

```ada
   Packet : constant Protocol.Byte_Array := Protocol.Encode_SSL_Request;
   Contents : constant Protocol.Byte_Array :=
     Packet (Packet'First + 4 .. Packet'Last);

   Item : constant Protocol.Initial_Request :=
     Protocol.Decode_Initial (Contents);
...
      declare
         Info : constant Protocol.Startup_Information :=
           Protocol.Startup_Data (Item);
      ...
   exception
      when Protocol.Protocol_Error =>
         Raised := True;
   end;
   Check
     (Raised,
      "Startup_Data raises Protocol_Error when Item is not Startup "
      & "(protocol.ads:602)");
```

```
  -- SSLRequest contents: 04 d2 16 2f 
  -- Protocol.Kind = SSL_REQUEST
  ok: the packet decodes as SSL_Request (so it is neither Startup nor Cancel_Request)
  -- Startup_Data returned a record instead of raising: major = 3, user = ""
  FAILED: Startup_Data raises Protocol_Error when Item is not Startup (protocol.ads:602)
  -- Process_Id returned 0 instead of raising
  FAILED: Process_Id raises Protocol_Error when Item is not Cancel_Request (protocol.ads:607)
  -- Secret_Key returned a 0-byte array instead of raising
  FAILED: Secret_Key raises Protocol_Error when Item is not Cancel_Request (protocol.ads:612)
BUG REPRODUCED: 3 failed expectation(s)
```

The `Kind` check passing first isolates the failure to the accessors rather than to the packet the spike built.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

The code and the specification should agree. Either the three accessors raise `Protocol_Error` on the wrong variant, as `src/flyology-postgres-protocol.ads:602`, `:607` and `:612` state and as the `Backend_Message` accessors already do, or the specification stops promising an exception the implementation does not raise.

## Suggested treatment

This is a maintainer decision, because the two fixes differ in what an existing external caller sees.

The code fix adds three `Require` guards in the style of `Description` (`src/flyology-postgres-protocol.adb:1051-1057`), turning the expression functions into ordinary function bodies that check `Item.Request_Kind` against `Startup` and `Cancel_Request` before returning. A caller that today reads a default value out of the wrong variant starts seeing `Protocol_Error`, which is the documented behaviour but is new behaviour for that caller.

The documentation fix removes the three `@exception` lines and states what the accessors actually return for an unmatched variant, namely the record defaults. That keeps every existing caller working and puts the burden of checking `Kind` on the consumer, which is what `Run_Session` already does.

Either way the regression test belongs in `tests/src/tests.adb` beside `Test_Startup` (`tests/src/tests.adb:265-277`), asserting the chosen behaviour for a non-Startup packet; the spike is the test for the code fix. No existing test asserts the current behaviour, so none has to change.

## Severity

No in-repo path is wrong, because every in-repo caller checks `Kind` first. The harm falls on an external consumer that takes the published `.ads` at its word and uses the exception as its variant discriminator: instead of a raised exception it gets a `Startup_Information` with an empty user name, a `Process_Id` of zero, or a zero-length `Secret_Key`. The last of those is the worst case, since a zero-length secret compared against a real one is a silent mismatch rather than a detected error. Reaching any of it requires calling an accessor on the wrong variant, which is not what a caller who checks `Kind` does. Deterministic.
