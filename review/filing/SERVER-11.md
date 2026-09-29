Title: Request_Shutdown cancels no connection work with the default Drain_Timeout, so Serve never returns
Labels: bug
Refs: none

## Summary

`Request_Shutdown` is documented as requesting listener shutdown and cancellation of active connection work. It requests only the accept token: the handler token is requested exclusively by the drain path, which runs only when `Drain_Timeout` is finite, and both `Serve` and `Serve_TLS` default it to `Flyology.IO.Infinite`. With the shipped defaults an operator who calls `Request_Shutdown` with one idle client attached sees the listener close and `Serve` never return.

## Problem

Commit `6f496f5`.

The contract promises two things (`src/flyology-postgres-server.ads:89-90`):

```ada
   procedure Request_Shutdown (Item : in out Server);
   --  Request listener shutdown and cancellation of active connection work.
```

The implementation delegates without adding anything (`src/flyology-postgres-server.adb:635-638`, through `Inner_Holder.Request_Stop` at `:192-198`), and the runtime's `Request_Shutdown` requests the accept token only (`flyology-io-structured_servers.adb:184-191` in the pinned runtime):

```ada
   procedure Request_Shutdown (Item : in out Server) is
      New_Request : Boolean;
   begin
      Item.State.Request_Stop (New_Request);
      if New_Request then
         Item.Accept_Stop.Request;
      end if;
   end Request_Shutdown;
```

`Handler_Stop` is requested in exactly one place, `Force_Handlers` (`flyology-io-structured_servers.adb:230-235`), which runs from the `delay Drain_Timeout` arm of `Serve`'s timed select and from its `when others` cleanup. With an infinite drain the select is skipped entirely (`flyology-io-structured_servers.adb:512-522`):

```ada
               if Drain_Timeout = Infinite then
                  Item.State.Await_All_Workers;
               else
                  select
                     Item.State.Await_All_Workers;
                  or
                     delay Drain_Timeout;
                     Force_Handlers;
                     Item.State.Await_All_Workers;
                  end select;
               end if;
```

Infinite is the default on both entry points (`src/flyology-postgres-server.ads:63` and `:76`):

```ada
      Drain_Timeout : Duration := Flyology.IO.Infinite);
```

and the generic formal `Command_Timeout` is infinite too (`src/flyology-postgres-server.ads:37`), so a session parked in `Read_Command` has nothing to wake it either.

No test covers the default. Every in-repo server passes a finite drain: `tests/src/postgres_test_server.adb:288`, `tests/src/postgres_test_logical_primary.adb:383`, `tests/src/postgres_test_replication_server.adb:365` and `tests/src/postgres_test_managed_physical_primary.adb:330` all use `Drain_Timeout => 1.0`.

## What happens now

Spike: two servers differing only in `Drain_Timeout`, one explicit at 1.0 as the control and one left at the default. Each has a client that has reached `ReadyForQuery` and is idle. `Request_Shutdown` is called on both, and each `Serve` is given a bounded 5 second wait.

```ada
      --  Explicit finite drain: the documented cancellation does happen.
      Test_Server.Serve
        (Control_Server, Control_Listener, Control_State,
         Drain_Timeout => 1.0);
```

```ada
      --  Drain_Timeout left at its documented default of Infinite.
      Test_Server.Serve (Default_Server, Default_Listener, Default_State);
```

```
  -- control client reached ReadyForQuery and is now idle
  -- default client reached ReadyForQuery and is now idle
  -- calling Request_Shutdown on both servers while both clients idle
  -- Drain_Timeout => 1.0        : Serve returned within 5.000000000s -> TRUE
  -- Drain_Timeout => default    : Serve returned within 5.000000000s -> FALSE
  ok: control: with an explicit finite Drain_Timeout, Request_Shutdown cancels the idle session and Serve returns
  FAILED: with the documented default Drain_Timeout, Request_Shutdown also cancels active connection work and Serve returns (server.ads:89-90)
  -- Serve is still blocked in Await_All_Workers; only closing the client releases it
BUG REPRODUCED: 1 failed expectation(s)
```

The control differs from the failing case only in `Drain_Timeout`, which isolates the default as the cause. The wait is bounded rather than left to expire, and the program then closes the client socket to release the blocked `Serve` and exits.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Request_Shutdown` either cancels active connection work, as `src/flyology-postgres-server.ads:89-90` says it does, or the specification states that cancellation happens only once `Drain_Timeout` expires and therefore never with the default. Today the shipped default does not deliver what the operation documents.

## Suggested treatment

This needs a maintainer decision, because each end of the fix changes externally visible behaviour:

- Make the operation match its words: have `Flyology.Postgres.Server.Request_Shutdown` request handler cancellation as well as the accept token. This changes what a caller's connected clients experience at shutdown, from a graceful drain to an immediate cancellation, on every existing application.
- Change the default `Drain_Timeout` on `Serve` and `Serve_TLS` (`src/flyology-postgres-server.ads:63`, `:76`) from `Flyology.IO.Infinite` to a finite value. That is a new policy value and needs the value itself approved.
- Correct the specification at `src/flyology-postgres-server.ads:89-90` to say that active connection work is cancelled only after `Drain_Timeout` elapses, and that the default drain is unbounded. This keeps every current behaviour and makes the unbounded wait a documented choice.

The spike is the regression test, and it belongs with the other server lifecycle coverage in `tests/src/tests.adb`. No existing test asserts the wrong behaviour; the in-repo servers avoid the default entirely.

## Severity

An application that writes nothing and shuts down with a client connected gets a `Serve` that does not return, which is what the documented default produces. It is a documented contract not honoured on the ordinary shutdown path, reached without any unusual call, and only closing the client releases the server. A graceful drain that waits for clients is a legitimate design, so the defect is that the specification promises cancellation the default does not deliver rather than the wait itself. Deterministic.
