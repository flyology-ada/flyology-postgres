Title: Read_Copy_Command rejects a Sync during COPY IN and documents results its type cannot represent
Labels: bug
Refs: CLIENT-2

## Summary

`Read_Copy_Command` forwards every frontend message to `Decode_Frontend_Copy`, whose catch-all arm raises `Protocol_Error "message is not a frontend COPY command"`. A `Sync` is exactly what libpq leaves in the stream when an extended-query cycle turns out to have started a `COPY ... FROM STDIN`, and PostgreSQL ignores it there by design. The server instead answers `FATAL 08P01` and drops the connection. Separately, the operation's own specification promises Flush, Sync and Terminate results that `Protocol.Frontend_Copy_Kind` has no values for.

## Problem

Commit `6f496f5`.

The helper does no filtering (`src/flyology-postgres-server_sessions.adb:70-75`):

```ada
   function Read_Copy_Command
     (Item : in out Session; Timeout : Duration)
      return Protocol.Frontend_Copy_Message is
   begin
      return Protocol.Decode_Frontend_Copy (Read_Command (Item, Timeout));
   end Read_Copy_Command;
```

and the decoder rejects everything outside three message kinds (`src/flyology-postgres-protocol.adb:868-870`):

```ada
         when others =>
            raise Protocol_Error with "message is not a frontend COPY command";
      end case;
```

`Run_Session`'s `Protocol_Error` handler turns that into a FATAL `ErrorResponse` with SQLSTATE `08P01` and the session ends (`src/flyology-postgres-server.adb:524-535`).

PostgreSQL admits `Flush` and `Sync` to the COPY-from-stdin message whitelist (`tests/.cache/postgres/18.4-openssl/source/src/backend/commands/copyfromparse.c:287-288`) and then skips them (`:320-329`):

```c
						case PqMsg_Flush:
						case PqMsg_Sync:

							/*
							 * Ignore Flush/Sync for the convenience of client
							 * libraries (such as libpq) that may send those
							 * without noticing that the command they just
							 * sent was COPY.
							 */
							goto readmessage;
```

The named situation is the reachable one. `PQexecParams` and `PQsendQueryParams` pipeline Parse, Bind, Describe, Execute and Sync in a single flush, so when the statement turns out to be `COPY ... FROM STDIN` the trailing `Sync` is already queued ahead of the first `CopyData`. Drivers that always use the extended protocol, psycopg3 among them, take that path for every COPY.

The second half is a contract that cannot be honoured. `src/flyology-postgres-server_sessions.ads:26-32` says:

```ada
   function Read_Copy_Command
     (Item : in out Session; Timeout : Duration)
      return Protocol.Frontend_Copy_Message;
   --  Read and classify one frontend message during COPY.
   --  @param Item Server session in COPY mode.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate event.
```

while the result type has three values (`src/flyology-postgres-protocol.ads:217-218`):

```ada
   type Frontend_Copy_Kind is
     (Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail);
```

so half the documented result set is unrepresentable.

Three consumers in this repository call the same helper and inherit both halves: `src/flyology-postgres-replication-managed_primary.adb:55`, `src/flyology-postgres-replication-base_backups-server_sessions.adb:204`, and `tests/src/postgres_test_replication_server.adb:215`.

The existing COPY test queues only a `CopyData` before calling the helper (`tests/src/tests.adb:1081-1093`), and `tests/scripts/run-integration.sh` drives psql's `\copy`, which issues a simple `Query` and never pipelines a `Sync`.

## What happens now

Spike: a memory transport is loaded with the two messages libpq leaves in the stream, a `Sync` followed by a `CopyData`, and `Read_Copy_Command` is called once.

```ada
   --  What libpq leaves in the stream when PQexecParams issued the COPY:
   --  the trailing Sync of the extended-query cycle, then the COPY payload.
   Queue (Channel, Protocol.Make_Sync_Message);
   Queue (Channel, Protocol.Make_Copy_Data_Message (Chunk));
   ...
         Command : constant Protocol.Frontend_Copy_Message :=
           Sessions.Read_Copy_Command (Session, 1.0);
```

```
  -- queued frontend bytes: 53 00 00 00 04 | 64 00 00 00 06 61 0a 
  -- Read_Copy_Command raised FLYOLOGY.POSTGRES.PROTOCOL.PROTOCOL_ERROR: message is not a frontend COPY command
  FAILED: a Sync arriving during COPY IN does not make Read_Copy_Command raise; PostgreSQL ignores Flush/Sync there (copyfromparse.c)
  FAILED: the CopyData that follows the ignored Sync is delivered to the COPY handler
  -- Server.Run_Session turns this into FATAL 08P01 'message is not a frontend COPY command' and drops the connection (src/flyology-postgres-server.adb:524-535)
  -- Protocol.Frontend_Copy_Kind is (Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail) only, so the Flush, Sync and Terminate results promised by server_sessions.ads:32 are unrepresentable
BUG REPRODUCED: 2 failed expectation(s)
```

The queued bytes are `53 00 00 00 04` (`S`, Sync) then `64 00 00 00 06 61 0a` (`d`, CopyData carrying `a` and a newline).

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A `Flush` or `Sync` arriving while COPY IN is active is skipped and the following message is read, as `CopyGetData` does at `copyfromparse.c:320-329`. The documented result set of `Read_Copy_Command` and the values `Frontend_Copy_Kind` can carry have to agree, whichever way they are made to agree.

## Suggested treatment

For the rejection, make `Read_Copy_Command` loop: read a message, and when its kind is `Flush` or `Sync`, read the next one instead of decoding it. That reproduces PostgreSQL's behaviour without changing any type, and it fixes all three in-repo consumers at once.

The documented result set needs a maintainer decision, because honouring it as written adds public API. The options are:

- Narrow the specification: correct `src/flyology-postgres-server_sessions.ads:32` to the three kinds `Frontend_Copy_Kind` actually has, and let the body skip Flush and Sync silently as PostgreSQL does. `Terminate` then still reaches the caller as a `Protocol_Error`.
- Widen the result: add new `Frontend_Copy_Kind` values for the Flush, Sync and Terminate events and return them, so callers can act on a client that abandons the COPY. This is a new public enumeration value on a published type and needs approval of the value set and its meaning.

The spike is the regression test for the first half; it belongs beside the existing COPY coverage at `tests/src/tests.adb:1081-1093`, which queues only a `CopyData` and would keep passing either way. No existing test asserts the wrong behaviour.

The client side has the mirror image of the same COPY-with-Sync problem, reported in {{ISSUE:CLIENT-2}}.

## Severity

An extended-protocol `COPY ... FROM STDIN` fails with `FATAL 08P01` and a dropped connection against any server built on this library, on the normal path of drivers that always use the extended protocol. It is a wrong exception on valid input from a standard client. psql's `\copy` uses a simple `Query` and is unaffected, which is why the in-repo integration run does not see it. The unrepresentable documented results are a contract defect with no runtime effect on their own. Deterministic.
