Title: Serve_TLS raises Program_Error where its specification documents Constraint_Error, and Serve is one-shot
Labels: bug, documentation
Refs: none

## Summary

Two lifecycle promises on `Flyology.Postgres.Server` do not match the body. `Serve_TLS` documents `Constraint_Error` for a `TLS_Disabled` policy and raises `Program_Error`, so a caller that handles the documented exception does not catch the one raised. `Serve` and `Serve_TLS` are documented as callable "only once at a time", which permits sequential reuse, while the holder enforces one-shot with `Program_Error "Postgres server is one-shot"`. Neither text is safe to program against today.

## Problem

Commit `6f496f5`.

### Documented exception identity

`src/flyology-postgres-server.ads:87` states:

```ada
   --  @exception Constraint_Error Policy is TLS_Disabled.
```

The body raises a different exception, in `Serve_TLS` itself and before `Serve_Internal` is reached, so nothing on the way out can translate it (`src/flyology-postgres-server.adb:622-625`):

```ada
      if Policy = TLS_Disabled then
         raise Program_Error with
           "Serve_TLS requires TLS_Allowed or TLS_Required";
      end if;
```

### Sequential reuse

`src/flyology-postgres-server.ads:65` and `:80-81` read as mutual exclusion, which permits a later call after the first has returned:

```ada
   --  @param Item Server instance; Serve may be called only once at a time.
```

The implementation supports that reading everywhere except the guard. Each `Serve_Internal` allocates a fresh `Structured.Server` (`src/flyology-postgres-server.adb:577-579`), installs it, and clears and frees it on both the normal and the exceptional path (`:585-601`). Only the holder's flag makes the object one-shot (`src/flyology-postgres-server.adb:184-187`):

```ada
         if Serve_Started then
            raise Program_Error with "Postgres server is one-shot";
         end if;
         Serve_Started := True;
```

`Clear` never resets that flag (`src/flyology-postgres-server.adb:200-206`), so a `Server` whose `Serve` returned cleanly cannot be served again.

No test covers either site. Every in-repo server calls `Serve` or `Serve_TLS` exactly once with a policy the guard accepts (`tests/src/postgres_test_server.adb:282-288`, `tests/src/postgres_test_logical_primary.adb:383`, `tests/src/postgres_test_replication_server.adb:359-365`, `tests/src/postgres_test_managed_physical_primary.adb:328-330`).

## What happens now

Spike: `Serve_TLS` is called with `Policy => TLS_Disabled` inside a handler that catches only the documented `Constraint_Error`; then one `Server` is served, shut down, and served again on a second listener, with the first cycle acting as the control.

```ada
      begin
         Test_Server.Serve_TLS
           (Server, Listener, State, Provider,
            Policy => Flyology.Postgres.TLS_Disabled);
      exception
         when Constraint_Error =>
            Caught := True;
```

```ada
      --  Ask for shutdown first so the initial Serve returns promptly.
      Test_Server.Request_Shutdown (Server);
      begin
         Test_Server.Serve (Server, First_Listener, State);
         First_Returned := True;
      ...
      begin
         Test_Server.Request_Shutdown (Server);
         Test_Server.Serve (Server, Second_Listener, State);
         Reused := True;
```

```
  -- Serve_TLS (Policy => TLS_Disabled) raised PROGRAM_ERROR: Serve_TLS requires TLS_Allowed or TLS_Required
  FAILED: Serve_TLS with Policy => TLS_Disabled raises the Constraint_Error its specification documents (server.ads:87)
  ok: control: the first Serve returns cleanly after Request_Shutdown
  -- the second sequential Serve raised PROGRAM_ERROR: Postgres server is one-shot
  FAILED: a Server whose Serve has returned can be served again, as 'Serve may be called only once at a time' (server.ads:65) says
BUG REPRODUCED: 2 failed expectation(s)
```

The control shows the first `Serve` returning cleanly, so the second call's failure is the one-shot guard and not a broken first run.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

The exception a caller is told to handle is the exception raised, and the lifetime a caller is told they have is the lifetime enforced. Both are stated in `src/flyology-postgres-server.ads:65`, `:80-81` and `:87`.

## Suggested treatment

Either the specifications or the guards must move, and each half has two defensible ends.

For the exception identity: raise `Constraint_Error` in `src/flyology-postgres-server.adb:622-625` to match `server.ads:87`, or change `server.ads:87` to document `Program_Error`, which is the more accurate name for a policy value the caller should not have passed. The second is a documented-exception change on a published operation and needs approval, since a caller may already handle `Constraint_Error`.

For sequential reuse: allow it, by resetting `Serve_Started` in `Inner_Holder.Clear` alongside `Current := null`, which the existing per-call allocation and free in `Serve_Internal` already support; or keep the one-shot guard and change `server.ads:65` and `:80-81` to say that a `Server` may be served exactly once. The first widens what the type promises and needs approval as an API decision.

The spike is the regression test for both halves; it belongs with the other `Flyology.Postgres.Server` coverage in `tests/src/tests.adb`. No existing test asserts the wrong behaviour.

## Severity

Contract drift on two lifecycle promises, with no wrong data and no protocol effect. A caller who wraps a configuration-driven `Serve_TLS` in `exception when Constraint_Error =>` gets an unhandled `Program_Error` at run time, which needs a `TLS_Disabled` policy reaching `Serve_TLS`, a programming error the guard exists to catch. Sequential reuse after a clean shutdown is an uncommon pattern, but it is what the present wording invites. Both are deterministic.
