Title: pgish keeps a session slot after an abrupt disconnect, then refuses live clients with FATAL 28P01
Labels: bug
Refs: none

## Summary

`Pgish_Handler.Handle` releases a session slot only from the `Terminate_Command` branch. When a peer disappears without Terminate, the library's per-connection loop removes its own cancellation entry and re-raises, so the pgish registry slot stays occupied with `State = "idle"`. `flyology_sessions` then reports dead sessions, and because 16 slots are shared by 17 handler workers the accumulated phantoms also refuse admission: a legitimate connection gets `Accepted = False` from `Authenticate` and the library answers `FATAL 28P01 password authentication failed` on a server that uses trust authentication. Measured against the running server: 16 of 16 clients admitted on a clean server, 8 of 16 after 16 abrupt disconnects.

## Problem

Commit `6f496f5`.

The slot is released in exactly one place (`examples/pgish/src/pgish_handler.adb:419`):

```ada
         when Protocol.Terminate_Command => State.Remove_Session (Context);
```

The library offers no disconnect callback to reach on any other path. Its generic formals are `Authenticate`, `Lookup_SCRAM_Verifier` and `Handle` (`src/flyology-postgres-server.ads:11-30`):

```ada
generic
   type Handler_Context (<>) is limited private;

   with function Authenticate
     (Context  : in out Handler_Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean;

   with function Lookup_SCRAM_Verifier
     (Context : in out Handler_Context;
      Startup : Protocol.Startup_Information) return String;
...
   with procedure Handle
     (Context : in out Handler_Context;
      Client  : in out Server_Sessions.Session;
      Command : Protocol.Message);
```

When `Read_Command` raises on peer EOF or reset, on a TLS failure, or on the 300 second `Command_Timeout` that pgish configures (`examples/pgish/src/flyology_pgish.adb:148`), the connection loop removes only the library's router entry and re-raises (`src/flyology-postgres-server.adb:483-521`):

```ada
               loop
                  declare
                     Command : constant Protocol.Message :=
                       Server_Sessions.Read_Command
                         (Client, Command_Timeout);
...
               end loop;
            exception
               when others =>
                  Context.Router.Remove (Key);
                  raise;
            end;
```

`Handle` is never called with `Terminate_Command` on that path, so `Remove_Session` is never reached and the slot keeps its `Occupied` flag and its `"idle"` state.

The registry reuses an occupied slot only for the same handler task (`examples/pgish/src/pgish_state.adb:36-44`):

```ada
         for Index in Slots'Range loop
            if Slots (Index).Occupied and then Slots (Index).Owner = Owner then
               Free := Index;
               exit;
            elsif not Slots (Index).Occupied and then Free = 0 then
               Free := Index;
            end if;
         end loop;
         Accepted := Free /= 0;
```

so a phantom slot is consumed until the one task that owns it happens to serve another connection.

The slot count and the worker count differ by one. pgish sizes the server at `Pgish_State.Maximum_Sessions` (`examples/pgish/src/flyology_pgish.adb:153-154`), which is 16 (`examples/pgish/src/pgish_state.ads:7`), and the library runs one more worker than that (`src/flyology-postgres-server.adb:209-216`):

```ada
   function Worker_Capacity (Session_Count : Positive) return Positive is
   begin
      if Session_Count = Positive'Last then
         raise Program_Error with
           "Postgres server capacity leaves no cancellation worker";
      end if;
      return Session_Count + 1;
   end Worker_Capacity;
```

used at `src/flyology-postgres-server.adb:579`. A connection served by a worker that owns no slot therefore finds all 16 slots occupied by other tasks' phantoms, `Pgish_Handler.Authenticate` returns the registry's `Accepted` unchanged (`examples/pgish/src/pgish_handler.adb:24-43`), and the library turns that into a fatal credential error (`src/flyology-postgres-server.adb:449-456`):

```ada
         if not Admit (Context.Application.all, Client, Startup) then
            Server_Sessions.Send_Error
              (Client,
               Message   => "password authentication failed",
               SQL_State => "28P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
            return;
         end if;
```

The README states the admission bound as a property of the server (`examples/pgish/README.md:147`):

> The server admits at most 16 sessions.

and lists `flyology_sessions` as holding "bounded live sessions" (`examples/pgish/README.md:110`).

Nothing tests an abrupt disconnect. The pgish suite registers and removes a session in the same procedure (`examples/pgish/src/pgish_tests.adb:169-171`, `:214`), and the real `psql` integration script connects and disconnects through `psql`, which always sends Terminate (`examples/pgish/scripts/run-integration.sh:95-134`).

## What happens now

Spike: the program starts one task per registry slot, each of which registers a session and runs a query and then ends without ever reaching the Terminate branch, exactly as a peer that disappears does. After every task has terminated it asks `flyology_sessions` how many sessions remain and then tries to register one more client.

```ada
   task body Dropped_Connection is
   ...
      --  Pgish_Handler.Authenticate registers the session.
      State.Register_Session
        (Context, "flyology", "flyology",
         "dropped" & Number'Image, Accepted);
      --  One ordinary Query, then the peer disappears.
      State.Begin_Query (Context, "SELECT 1", Snapshot);
      State.End_Query (Context);
   end Dropped_Connection;
...
   Check (Result.Row_Count = 0,
          "flyology_sessions lists no session once every peer is gone");
   State.Register_Session
     (Context, "flyology", "flyology", "fresh_client", Admitted);
   Check (Admitted,
          "a fresh client is admitted while no live session exists");
```

```
  -- flyology_sessions still reports 16 session(s) after all peers disconnected
  FAILED: flyology_sessions lists no session once every peer is gone
  FAILED: a fresh client is admitted while no live session exists
BUG REPRODUCED: 2 failed expectation(s)
```

Observed end to end against the running `examples/pgish/bin/flyology_pgish`, with trust authentication, no TLS, ephemeral ports, and every server stopped afterwards:

1. Two live connections, one closed with `SO_LINGER 0` so the peer sends a reset and no Terminate. After 1.5 seconds the surviving connection still sees both:

```
== A dropped without Terminate, asked from B ==
    ['1', 'conn_a', 'idle']
    ['2', 'conn_b', 'running']
RESULT: live sessions after drop = 2 (expected 1: conn_b only)
```

2. Control, on a clean server: 16 connections opened, all 16 admitted (`ctl 0..15 -> ['Auth', 'ReadyForQuery']`).

3. 16 connections opened and all closed with a reset, a 2 second pause, then 16 fresh connections:

```
new 0 -> ['Auth', 'ReadyForQuery']
new 1 -> ['ERROR FATAL 28P01 password authentication failed']
new 2 -> ['Auth', 'ReadyForQuery']
new 3 -> ['ERROR FATAL 28P01 password authentication failed']
...
admitted 8, refused 8
```

A separate run confirmed `flyology_sessions` listing all 16 dead sessions as `idle` at that point. The control in step 2 is what makes step 3 a regression rather than a capacity limit: the same 16 clients on the same server are admitted before the abrupt disconnects and half refused after.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A session slot belongs to a live connection. When the connection ends for any reason, including peer reset, EOF, TLS failure and command timeout, the slot should be released, `flyology_sessions` should stop listing it, and the server should keep admitting up to the 16 sessions the README promises. A connection refused for lack of a slot should not be reported as a credential failure on a trust-authentication server.

## Suggested treatment

The pgish-only fix is to make `Pgish_State.Register` reclaim a slot whose owning task has terminated, using `Ada.Task_Identification.Is_Terminated` on the recorded `Owner` when no free slot is found, before answering `Accepted := False`. That releases phantoms without any library change and restores admission, though `flyology_sessions` still lists a dead session until the next admission sweep.

Releasing the slot promptly needs the library to tell the application that a connection ended, and the `Server` generic has no such formal today (`src/flyology-postgres-server.ads:11-30`). Adding one is a maintainer decision, because it changes the generic's public contract and every existing instantiation. The options are: reclaim terminated owners inside `Pgish_State.Register` only; add an optional `Disconnect` formal with a null default so existing instantiations keep compiling and pgish releases the slot from it; or have pgish call `Remove_Session` from a handler in its own connection path, which it cannot do while the loop lives inside the library.

Separately, the refusal message needs a maintainer decision of its own: the library sends `28P01 password authentication failed` for every `Admit` rejection (`src/flyology-postgres-server.adb:449-456`), which is wrong for a capacity refusal on a trust server. The options are to keep one message, to let `Authenticate` distinguish rejection reasons, or to add a separate admission callback with its own SQLSTATE, such as 53300 for too many connections.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the existing session registration test (`examples/pgish/src/pgish_tests.adb:169-171`), registering from tasks that terminate without removing and then asserting that a fresh registration is accepted. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

After ordinary client churn the server refuses legitimate connections, and it reports the refusal as a password failure on a server that authenticates nobody, so an operator sees a credential error where the real cause is a leaked slot. Measured at 8 refusals in 16 attempts after 16 abrupt disconnects, against 0 in 16 on a clean server. `flyology_sessions`, the table the README offers for exactly this kind of inspection, reports the dead sessions as idle with their old identifiers and query counts. It takes an accumulation of disconnects that skip Terminate rather than one ordinary input, and the refusal is a well-formed FATAL ErrorResponse rather than a protocol violation. Deterministic.
