Title: Startup _pq_. protocol options are discarded, so a server cannot answer with NegotiateProtocolVersion
Labels: bug
Refs: SERVER-3

## Summary

`Decode_Initial` inspects only the `replication` startup parameter and drops every other name and value pair, and `Startup_Information` has no field that could carry them. A startup packet requesting `_pq_.some_option` therefore decodes to a value identical to one requesting nothing, so no application built on this library can even detect that a client asked for a protocol option. The protocol requires the server to answer NegotiateProtocolVersion listing each unrecognised option, and this library's encoder hard-codes a count of zero and is reached only when the requested minor version exceeds 2. A conforming server cannot be built on the current API.

## Problem

Commit `6f496f5`.

The parameter walk examines one name and discards the rest (`src/flyology-postgres-protocol.adb:1183-1205`):

```ada
               while Contents (Cursor) /= 0 loop
                  declare
                     Name : constant String :=
                       Read_C_String (Contents, Cursor);
                     Value : constant String :=
                       Read_C_String (Contents, Cursor);
                  begin
                     if Name = "replication" then
                        ...
                     end if;
                  end;
               end loop;
```

`Startup_Information` has six fields and no parameter collection, so there is nowhere for an option to go (`src/flyology-postgres-protocol.ads:569-576`):

```ada
   type Startup_Information is record
      Protocol_Major  : UInt16 := 3;
      Protocol_Minor  : UInt16 := 0;
      User            : Ada.Strings.Unbounded.Unbounded_String;
      Database        : Ada.Strings.Unbounded.Unbounded_String;
      Application_Name : Ada.Strings.Unbounded.Unbounded_String;
      Replication_Mode : Replication_Connection_Mode := Normal_Connection;
   end record;
```

`Initial_Request` keeps only the kind, that record, a pid and a secret (`src/flyology-postgres-protocol.ads:819-824`), so the information is gone by the time any caller sees the request.

The server layer cannot compensate, for two independent reasons. `Send_Negotiate_Protocol` has no parameter for unrecognised options and unconditionally encodes a count of zero (`src/flyology-postgres-server_sessions.adb:150-159`):

```ada
   procedure Send_Negotiate_Protocol
     (Item         : in out Session;
      Latest_Minor : Protocol.UInt32;
      Timeout      : Duration) is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U32 (Contents, Latest_Minor);
      Protocol.Append_U32 (Contents, 0);
      Send_Built (Item, 'v', Contents, Timeout);
   end Send_Negotiate_Protocol;
```

and `Run_Session` calls it only when the client asked for a minor version above 2 (`src/flyology-postgres-server.adb:444-447`):

```ada
         if Startup.Protocol_Minor > 2 then
            Server_Sessions.Send_Negotiate_Protocol
              (Client, Latest_Minor => 2, Timeout => Write_Timeout);
         end if;
```

The backend rule that gate contradicts collects each `_pq_.` name and sends the message when *either* condition holds (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:793-801` and `:840-842`):

```c
			else if (strncmp(nameptr, "_pq_.", 5) == 0)
			{
				...
				unrecognized_protocol_options =
					lappend(unrecognized_protocol_options, pstrdup(nameptr));
			}
...
		if (PG_PROTOCOL_MINOR(proto) > PG_PROTOCOL_MINOR(PG_PROTOCOL_LATEST) ||
			unrecognized_protocol_options != NIL)
			SendNegotiateProtocolVersion(unrecognized_protocol_options);
```

`SendNegotiateProtocolVersion` then writes the option count and the names (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:941-945`):

```c
	pq_beginmessage(&buf, PqMsg_NegotiateProtocolVersion);
	pq_sendint32(&buf, FrontendProtocol);
	pq_sendint32(&buf, list_length(unrecognized_protocol_options));
	foreach(lc, unrecognized_protocol_options)
		pq_sendstring(&buf, lfirst(lc));
```

So a plain 3.0 client that requests `_pq_.foo` is entitled to a `v` message, and this library sends none. The `Protocol_Minor > 2` gate at `src/flyology-postgres-server.adb:444` is a second, independent reason the message is missing, on top of the discarded names.

No test covers it, because there is nothing to assert against: `_pq_` does not occur anywhere under `src/` or `tests/`, and no API surfaces an option for a test to read back.

## What happens now

Spike: two startup packets are built, one plain and one carrying `_pq_.some_option=1`, and both are decoded. Because no field exists to compare against, the program asserts the weakest property any spec-compliant decoder must have, namely that the two decoded values are distinguishable. That assertion compiles against today's API, fails today, and passes under any fix that surfaces the option.

```ada
      Protocol.Append_U32 (Contents, Version_3_0);
      Protocol.Append_C_String (Contents, "user");
      Protocol.Append_C_String (Contents, "alice");
      Protocol.Append_C_String (Contents, "_pq_.some_option");
      Protocol.Append_C_String (Contents, "1");
      Protocol.Append_Byte (Contents, 0);
...
   Check
     (With_Option /= Without,
      "a startup packet requesting _pq_.some_option decodes differently "
      & "from one that requests nothing, so a server can list the "
      & "unrecognized option in NegotiateProtocolVersion");
```

```
  -- startup without options:   00 03 00 00 75 73 65 72 00 61 6c 69 63 65 00 00 
  -- startup with _pq_.some_option=1: 00 03 00 00 75 73 65 72 00 61 6c 69 63 65 00 5f 70 71 5f 2e 73 6f 6d 65 5f 6f 70 74 69 6f 6e 00 31 00 00 
  -- Decode_Initial accepted both packets without error.
  FAILED: a startup packet requesting _pq_.some_option decodes differently from one that requests nothing, so a server can list the unrecognized option in NegotiateProtocolVersion
  -- the two decoded Startup_Information values are identical, so the requested protocol option is unrecoverable and
  -- Send_Negotiate_Protocol can only ever encode 0 unrecognized options (server_sessions.adb:156-157).
BUG REPRODUCED: 1 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A startup packet requesting `_pq_.` options should decode to something that carries those names, and a server built on this library should be able to answer NegotiateProtocolVersion listing them, whatever minor version the client requested. That is the backend rule at `tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:840-842`: the message is sent when the minor version is newer than supported *or* any unrecognised option was requested. A client that asked for an option and received no `v` message is entitled to conclude the option was accepted.

## Suggested treatment

This needs a maintainer decision, because closing this adds public API surface rather than correcting a local expression. The options are:

- Add a field to `Startup_Information` (`src/flyology-postgres-protocol.ads:569-576`) carrying the requested `_pq_.` names, and a matching parameter on `Send_Negotiate_Protocol` (`src/flyology-postgres-server_sessions.ads:85-88`) replacing the hard-coded zero at `src/flyology-postgres-server_sessions.adb:157`. This changes a public record type, so every consumer that aggregates it is affected.
- Leave `Startup_Information` alone and add an accessor on `Initial_Request` returning the requested option names, with the same `Send_Negotiate_Protocol` parameter. This is additive for existing consumers but splits startup data across two accessors.
- Carry every unrecognised startup parameter, not only `_pq_.` prefixed ones, since the backend treats the rest as GUC options (`backend_startup.c:803-805`). This is the largest surface and the only one that lets an application see `options` or a custom GUC.

Whichever is chosen, `Run_Session`'s `Protocol_Minor > 2` gate at `src/flyology-postgres-server.adb:444` must widen to send the message when either condition holds, matching `backend_startup.c:840-842`.

A fix here must not land before {{ISSUE:SERVER-3}}. That issue reports that the version word in the `v` frame carries the bare minor number instead of the full protocol version. Today the malformed frame is only ever sent to clients requesting minor above 2; widening the gate first would start sending it to ordinary 3.0 clients, which would abort connections that work now.

The regression test belongs in `tests/src/tests.adb` beside `Test_Startup` (`tests/src/tests.adb:265-277`), asserting both the decoded option names and the emitted `v` frame; the spike is the decoder half of that test. No existing test asserts the current behaviour, so none has to change.

## Severity

A server built on this library cannot answer a client that requests protocol options, and no application-visible API can even detect the request, so the deviation cannot be worked around by a consumer. Mainstream interop is unaffected, because libpq sends no `_pq_.` options unless an application asks for them, so a normal connection never reaches this. The effect is a missing capability on the server role rather than a wrong result on any path that runs today. Deterministic.
