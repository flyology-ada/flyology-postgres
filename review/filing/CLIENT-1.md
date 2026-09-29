Title: Scoped Receive_Extended_Event puts an open pipelined batch into Recovery_Required on an earlier batch's error
Labels: bug
Refs: CLIENT-3

## Summary

The scoped `Receive_Extended_Event` decides whether a response belongs to an earlier, already Sync-terminated batch by testing the session state, while the synchronous function tests the outstanding Sync count. In pipeline mode the two disagree as soon as the next batch is opened. An earlier batch's `ErrorResponse` read through the scoped path is then charged to the open batch: the session moves to `Recovery_Required`, the open batch's bound portal can no longer be executed, and the earlier batch's `ReadyForQuery`, which is the next message on the wire, can no longer be received. Only an extra `Synchronize` escapes, and that prematurely closes the open batch.

## Problem

Commit `6f496f5`.

The scoped path derives the flag from the state (`src/flyology-postgres-client.adb:1523`):

```ada
Operation.Sync_Pending := Item.Current_State = Awaiting_Ready;
```

The synchronous path derives it from the counter (`src/flyology-postgres-client.adb:2226`):

```ada
Sync_Pending : constant Boolean := Item.Pending_Syncs > 0;
```

Both feed the same `Apply_Extended_Event`, whose `ErrorResponse` arm uses the flag to leave an earlier batch's failure alone (`src/flyology-postgres-client.adb:996-1006`):

```ada
when Protocol.Error_Response =>
   Item.Has_Row_Description := False;
   Item.Described_Columns := 0;
   --  An outstanding Sync already ends the failed batch, and the
   --  server skips to it. Only an unsynchronized failure leaves the
   --  open batch in need of recovery.
   if not Sync_Pending then
      Item.Current_State := Recovery_Required;
      Item.Bound_In_Cycle := False;
      Item.Portal_Is_Suspended := False;
   end if;
```

The two expressions differ exactly when a later batch is open while an earlier one is outstanding. `Send_Command`'s Sync branch sets `Awaiting_Ready` and increments the counter (`src/flyology-postgres-client.adb:525-533`), and the next batch's Parse or Bind then moves the state back to `Extended_Query_Active` while `Pending_Syncs` stays above zero (`src/flyology-postgres-client.adb:517-519`):

```ada
if Item.Current_State in Ready | Awaiting_Ready then
   Item.Current_State := Extended_Query_Active;
end if;
```

The scoped flag is then `False` and the synchronous flag is `True` for the same wire bytes.

The counter behaviour is the documented one. README "Pipelined batches" (`README.md:218-222`):

```
Responses arrive in the order the batches were written, and each
`ReadyForQuery` ends exactly one batch. Each batch's own Sync contains its
failure: the server discards the rest of that batch, sends its `ReadyForQuery`,
and then processes the batch behind it normally, so the session does not enter
`Recovery_Required`.
```

The suite codifies the same rule, but only through the synchronous path (`tests/src/tests.adb:1793-1797`):

```ada
Assert
  (Next = Protocol.Error_Response
   and then Client.State (Session) = Client.Awaiting_Ready
   and then Client.Pending_Synchronizations (Session) = 2,
   "a failed pipelined batch needs no separate recovery Sync");
```

The only scoped extended-query test, `Test_Extended_Operations` (`tests/src/tests.adb:2293-2331`), never enters pipeline mode and receives a single `ParseComplete`, so the state test and the counter test never disagree there. No test drives the scoped receive with a Sync outstanding.

## What happens now

Spike: two sessions over an in-memory transport, each authenticated, put into pipeline mode, given a complete batch 1 (Parse, Bind, Execute, Sync) and an opened batch 2 (Parse, Bind). The backend's reply to batch 1, an `ErrorResponse` followed by its `ReadyForQuery`, is queued for both. The first session reads it through the synchronous `Receive_Extended_Event` as a control on the other path; the second reads the identical bytes through the scoped overload, then tries to execute the open batch's bound portal and to consume batch 1's `ReadyForQuery`.

```ada
Client.Enter_Pipeline_Mode (Item);
Client.Prepare_Statement (Item, "first", "select 1", Timeout => 1.0);
Client.Bind_Portal (Item, "first", "first", Timeout => 1.0);
Client.Execute_Portal (Item, "first", Timeout => 1.0);
Client.Synchronize (Item, Timeout => 1.0);
Client.Prepare_Statement (Item, "second", "select 1", Timeout => 1.0);
Client.Bind_Portal (Item, "second", "second", Timeout => 1.0);

Queue (Channel, Protocol.Make_Message ('E', Failure));
Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));

Receive : Client.Receive_Operation :=
  Client.Receive_Extended_Event
    (Set'Access, Session'Access, Timeout => 1.0);
...
Client.Execute_Portal (Session, "second", Timeout => 1.0);
```

```
  -- synchronous receive: kind = ERROR_RESPONSE, state = EXTENDED_QUERY_ACTIVE, pending = 1
  ok: control: the synchronous receive leaves the open batch active
  -- scoped receive:      kind = ERROR_RESPONSE, state = RECOVERY_REQUIRED, pending = 1
  ok: the scoped receive returns batch 1's ErrorResponse
  ok: batch 1's ReadyForQuery is still outstanding
  FAILED: an earlier pipelined batch's ErrorResponse does not put the open batch into Recovery_Required (README: 'the session does not enter Recovery_Required')
  -- Execute_Portal ("second") raised Program_Error: cannot execute a portal while Postgres session state is RECOVERY_REQUIRED
  FAILED: the open batch's bound portal can still be executed
  -- the follow-up receive raised Program_Error: Postgres extended-query recovery requires Sync before receiving
  FAILED: batch 1's ReadyForQuery can still be consumed
BUG REPRODUCED: 3 failed expectation(s)
```

The control section passes on the same byte stream, so the divergence is entirely in the scoped path.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

The scoped receive should attribute a response to an earlier batch on the same evidence the synchronous receive uses, the outstanding Sync count. An earlier pipelined batch's `ErrorResponse` must leave the open batch in `Extended_Query_Active` with its `Bound_In_Cycle` intact, as README "Pipelined batches" requires.

## Suggested treatment

Set the flag from the counter in `Start_Receive` (`src/flyology-postgres-client.adb:1523`):

```ada
Operation.Sync_Pending := Item.Pending_Syncs > 0;
```

The same flag also gates `Portal_Is_Suspended` for `CommandComplete` (`src/flyology-postgres-client.adb:986`) and `PortalSuspended` (`:993`), so the one-line change also stops an earlier batch's `PortalSuspended` from corrupting the open batch's portal state. The scoped entry points reimplement the synchronous guards rather than sharing them, and the scoped `Send_Query` drops a different one ({{ISSUE:CLIENT-3}}); `Start_Send`, `Start_Receive` and `Start_Startup_Operation` are worth auditing against their synchronous counterparts in the same pass.

The regression test belongs in `Test_Pipelined_Client_State` (`tests/src/tests.adb:1667`), which already builds the two-batch state and reads it only through the synchronous path. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

A pipelined session that uses the scoped receive path loses the open batch on the first error in any earlier batch, and the error is what pipelining exists to tolerate. The caller gets `Program_Error` from `Execute_Portal` and from the next receive, and the only way forward, an extra `Synchronize`, closes a batch the caller has not finished writing and desynchronises its batch accounting. Both pipeline mode and the scoped overloads are ordinary public API, and no unusual input is needed beyond two batches in flight. Deterministic.
