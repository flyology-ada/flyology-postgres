Title: NegotiateProtocolVersion carries the bare minor number instead of the full protocol version word
Labels: bug
Refs: PROTO-5

## Summary

`Send_Negotiate_Protocol` writes its `Latest_Minor` argument as the first Int32 of the `v` frame, and `Run_Session` passes the literal `2`, so the wire value is `00 00 00 02`. Both PostgreSQL reference implementations treat that field as a full `ProtocolVersion`, and libpq rejects anything below `PG_PROTOCOL(3, 0)` as a downgrade to a pre-3.0 protocol. Every NegotiateProtocolVersion message this library emits is malformed, and it aborts the connection it was sent to rescue.

## Problem

Commit `6f496f5`.

The encoder writes the argument unchanged (`src/flyology-postgres-server_sessions.adb:150-159`):

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

and `Run_Session` supplies `2` (`src/flyology-postgres-server.adb:444-447`):

```ada
         if Startup.Protocol_Minor > 2 then
            Server_Sessions.Send_Negotiate_Protocol
              (Client, Latest_Minor => 2, Timeout => Write_Timeout);
         end if;
```

PostgreSQL sends a full `ProtocolVersion` in the same field (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:936-942`):

```c
SendNegotiateProtocolVersion(List *unrecognized_protocol_options)
{
	StringInfoData buf;
	ListCell   *lc;

	pq_beginmessage(&buf, PqMsg_NegotiateProtocolVersion);
	pq_sendint32(&buf, FrontendProtocol);
```

`FrontendProtocol` is set to `Min(proto, PG_PROTOCOL_LATEST)` at `backend_startup.c:721`, `PG_PROTOCOL(m,n)` is `(((m) << 16) | (n))` (`tests/.cache/postgres/18.4-openssl/source/src/include/libpq/pqcomm.h:90`) and `PG_PROTOCOL_LATEST` is `PG_PROTOCOL(3,2)` (`:97`), so a 3.2 backend puts `00 03 00 02` on the wire.

libpq reads the field back as a `ProtocolVersion` and refuses anything below 3.0 (`tests/.cache/postgres/18.4-openssl/source/src/interfaces/libpq/fe-protocol3.c:1461-1465`):

```c
	if (their_version < PG_PROTOCOL(3, 0))
	{
		libpq_append_conn_error(conn, "received invalid protocol negotiation message: server requested downgrade to pre-3.0 protocol version");
		goto failure;
	}
```

A bare `2` is `0x00000002`, far below `0x00030000`, so every `v` message this library emits fails that test.

The message is sent only when a client asks for a minor above 2 (`server.adb:444`), which stable libpq never does because it caps itself at 3.2. The path is live all the same: in a PostgreSQL 19 beta checkout on this host (`PG_VERSION "19devel"`), libpq defaults `conn->max_pversion` to `PG_PROTOCOL_GREASE`, which is `PG_PROTOCOL(3,9999)` (`src/include/libpq/pqcomm.h:115` in that tree), at `src/interfaces/libpq/fe-connect.c:2149-2156`, with the comment "to test negotiation. The server should automatically downgrade to a supported version." and the note that the default is "for 19beta only. It will be reverted before RC1". Such a client sends minor 9999, this server answers `00 00 00 02`, and libpq aborts the connection. That default is not a permanent fact, and it is not present in the 14.23 through 18.4 trees, but it shows the path is reachable rather than theoretical.

The public API records the misreading: the parameter is `Latest_Minor : Protocol.UInt32` (`src/flyology-postgres-server_sessions.ads:85-92`), documented as "Highest supported minor version", so a future maintainer is steered into the same mistake.

No test encodes or decodes a `v` message, so nothing catches it.

## What happens now

Spike: `Send_Negotiate_Protocol` is called on a memory transport with the value `Run_Session` passes, and the emitted frame is compared byte for byte with what `SendNegotiateProtocolVersion` would produce for 3.2.

```ada
   Expected_Frame : constant Protocol.Byte_Array (1 .. 13) :=
     (1  => Protocol.Byte (Character'Pos ('v')),
      2  => 0, 3 => 0, 4 => 0, 5 => 12,   --  length: 4 + 4 + 4
      6  => 0, 7 => 3, 8 => 0, 9 => 2,    --  PG_PROTOCOL(3, 2)
      10 => 0, 11 => 0, 12 => 0, 13 => 0); --  0 unrecognized options

begin
   Sessions.Send_Negotiate_Protocol (Session, Latest_Minor, 1.0);
```

```
  -- Send_Negotiate_Protocol (Latest_Minor => 2) emitted: 76 00 00 00 0c 00 00 00 02 00 00 00 00 
  -- PostgreSQL would emit:                             76 00 00 00 0c 00 03 00 02 00 00 00 00 
  ok: a NegotiateProtocolVersion frame of the documented size is sent
  -- version word on the wire: 00 00 00 02 
  FAILED: the version word is the full ProtocolVersion 00 03 00 02, as PostgreSQL's SendNegotiateProtocolVersion emits and libpq's pqGetNegotiateProtocolVersion3 requires (>= PG_PROTOCOL(3,0))
  ok: the unrecognized-option count is zero
BUG REPRODUCED: 1 failed expectation(s)
```

The tag, length and option-count checks pass, which isolates the failure to the version word.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server and libpq sources used for reference.

## What should happen

The first Int32 of the `v` frame is a `ProtocolVersion`, `major << 16 | minor`, so a server negotiating down to 3.2 must send `00 03 00 02`. That is what `SendNegotiateProtocolVersion` emits and what `pqGetNegotiateProtocolVersion3` requires.

## Suggested treatment

The smallest correct change is to compose the full word inside `Send_Negotiate_Protocol`: `Protocol.Append_U32 (Contents, 16#0003_0000# or Latest_Minor)`. Major 3 is not a new policy choice here, because `Run_Session` already rejects any other major with `FATAL 0A000` (`src/flyology-postgres-server.adb:434-442`), so the value is derived from an existing contract.

Whether the public parameter should keep its present shape is a maintainer decision: either keep `Latest_Minor : Protocol.UInt32` and compose the major in the body, or replace it with a full-version parameter (renamed, and documented as `major << 16 | minor`) so the caller states what goes on the wire. The second removes the misreading from the API but changes a published signature.

The spike is the regression test, and it belongs with the other `Server_Sessions` encoder checks in `tests/src/tests.adb`. No existing test asserts the wrong behaviour.

The `_pq_.` protocol-option gap reported in {{ISSUE:PROTO-5}} is the second reason a `v` message goes missing, and its fix must not land before this one: sending `v` to ordinary 3.0 clients while the version word is still `00 00 00 02` would abort connections that work today.

## Severity

Every NegotiateProtocolVersion message the server sends is malformed, and a libpq client that receives one aborts the connection with "server requested downgrade to pre-3.0 protocol version". It is not reached by stable libpq, which never requests a minor above 2, so today it needs a client that asks for a newer minor version, which is the only situation in which the message is sent at all. Deterministic when the message is sent.
