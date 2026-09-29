Title: A rejected plaintext startup leaves the session in Not_Started and accepts a second startup packet
Labels: bug
Refs: none

## Summary

When the server rejects authentication with an `ErrorResponse`, `Complete_Startup` raises `Database_Error` without touching the session state, so the session stays in `Not_Started`. `Startup_TLS` and the scoped TLS negotiation stage set `Closed` for the same class of failure, so an identical rejection produces two different states depending on how the session was started. A caller that dispatches on `State` cannot tell "never started" from "rejected", and the session accepts a second `Startup`, writing another startup packet to a connection the server closed after the error.

## Problem

Commit `6f496f5`.

The plaintext startup loop raises on the server's `ErrorResponse` and changes nothing else (`src/flyology-postgres-client.adb:344-348`):

```ada
when 'E' =>
   Flyology.Postgres.SCRAM_Core.Wipe
     (Expected_Server_Signature);
   raise Database_Error with
     SQL_State (Response) & ": " & Error_Message (Response);
```

No handler between that raise and the caller sets `Current_State`, and the entry guard admits `Not_Started` (`src/flyology-postgres-client.adb:209-211`):

```ada
if Item.Current_State not in Not_Started | TLS_Negotiated then
   raise Program_Error with "Postgres session is already started";
end if;
```

`Startup_TLS` wraps the same `Complete_Startup` call and closes the session on any failure (`src/flyology-postgres-client.adb:453-457`):

```ada
exception
   when others =>
      Item.Current_State := Closed;
      raise;
end;
```

The scoped path does not compensate. `Fail_Startup` closes only the TLS negotiation stage (`src/flyology-postgres-client.adb:1647-1649`):

```ada
if Item.Kind = TLS_Negotiation_Stage then
   Item.Item.Current_State := Closed;
end if;
```

so the scoped plaintext failure at `src/flyology-postgres-client.adb:1843-1845` leaves `Not_Started` as well.

README "API outline" states the closing rule for the TLS path (`README.md:116-117`):

```
provider, and only then sends credentials. Any negotiation or encrypted-startup
failure permanently closes the session state.
```

An authentication `ErrorResponse` is an encrypted-startup failure when it arrives over TLS. No sentence in the README or in `src/flyology-postgres-client.ads` promises `Closed` for a rejected plaintext startup. The expectation asserted below is inferred from the `Startup_TLS` precedent and from the state's own documented meaning (`src/flyology-postgres-client.ads:72`):

```ada
--  @enum Closed The server or client has terminated the session.
```

That is the observable inconsistency: the same `28P01` error yields `Closed` on a TLS session and `Not_Started` on a plaintext one, on both the synchronous and the scoped paths.

`Test_TLS_Refusal_Is_Terminal` asserts exactly the terminal behaviour for the TLS path, including the refused retry (`tests/src/tests.adb:330-346`):

```ada
Assert
  (Client.State (Session) = Client.Closed,
   "TLS refusal permanently closes the session state");
...
Assert
  (Retry_Rejected,
   "TLS-refused sessions cannot retry startup in plaintext");
```

There is no counterpart for a rejected plaintext startup. `Test_Startup` (`tests/src/tests.adb:265-292`) only round-trips the encoded startup packet and never runs a session against a rejecting server.

## What happens now

Spike: a session over an in-memory transport whose only queued backend message is a `FATAL 28P01` `ErrorResponse`. It calls `Startup`, records the resulting state, clears the recorded frontend bytes, and calls `Startup` again to see whether a second startup packet is written. A second session repeats the first rejection through the scoped `Startup` and `Finish`.

```ada
Queue (Channel, Authentication_Failure);
Client.Startup (Session, User => "tester", Timeout => 1.0);
...
Clear_Sent (Channel);
Client.Startup (Session, User => "tester", Timeout => 1.0);
...
Start : Client.Startup_Operation :=
  Client.Startup
    (Set'Access, Session'Access, User => "tester", Timeout => 1.0);
```

```
  -- Startup raised Database_Error: 28P01: password authentication failed for user "tester"
  ok: the server's ErrorResponse fails the startup
  -- after the rejected startup: state = NOT_STARTED, Is_Ready = FALSE
  FAILED: a rejected startup closes the session state, as Startup_TLS does for the same failure
  -- the retried Startup raised PROGRAM_ERROR: memory transport input is exhausted
  -- bytes written by the retried Startup = 56
  FAILED: a rejected session refuses another Startup instead of writing a second startup packet to a connection the server has closed
  -- scoped Finish raised Database_Error: 28P01: password authentication failed for user "tester"
  ok: the scoped startup reports the same failure
  -- after the rejected scoped startup: state = NOT_STARTED
  FAILED: the scoped startup closes the session state too
BUG REPRODUCED: 3 failed expectation(s)
```

The `PROGRAM_ERROR: memory transport input is exhausted` line comes from the drained transport after the retried startup packet was written. The 56 written bytes are the evidence that the retry was accepted; on a real connection those bytes go to a socket the server closed after the `ErrorResponse`, and the failure surfaces as a transport error rather than as a precondition violation.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A session whose startup the server rejected must stop accepting `Startup` and must stop writing to the connection, and both the synchronous and the scoped plaintext paths must reach the same state as `Startup_TLS` reaches for the same rejection. `State` must distinguish a session that has never started from one the server refused.

## Suggested treatment

This needs a maintainer decision, because the target state is not fixed by any documented sentence:

- Set `Current_State := Closed` on the `ErrorResponse` branch of `Complete_Startup` (`src/flyology-postgres-client.adb:344-348`) and drop the `Kind = TLS_Negotiation_Stage` condition in `Fail_Startup` (`:1647-1649`) so every failed startup stage closes. This matches `Startup_TLS`, matches the documented meaning of `Closed`, and makes the retry fail with the existing `Program_Error` precondition at `:209-211` instead of writing to a dead socket.
- Or document `Not_Started` as a retryable state after a rejection and make the retry safe, which means the transport has to be known to be reusable. Since PostgreSQL closes the connection after a `FATAL` authentication error, this option only makes sense if the session is also given a way to rebind a fresh transport.

Either way the two plaintext paths and the TLS path must agree. The regression test belongs next to `Test_TLS_Refusal_Is_Terminal` (`tests/src/tests.adb:307-347`), which already asserts the terminal behaviour for the TLS path. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

The wrong-looking state is only observable to a caller that dispatches on `State` after catching `Database_Error`, and the exception itself is correct and carries the SQL state. The concrete harm is the accepted retry: a rejected session writes a second 56-byte startup packet to a connection the server has already closed, and the caller sees a transport error rather than a clean precondition failure. A caller that discards the session on `Database_Error`, which is the usual reaction, never notices. Deterministic; not reproduced against a live server.
