Title: One session-wide suspended-portal flag rejects executing and resuming portals in the same batch
Labels: bug
Refs: none

## Summary

Portal suspension is tracked by a single Boolean that carries no portal name. `Execute_Portal` refuses any execute while it is set, and `Bind_Portal` clears it unconditionally. Inside one Flush-driven batch, a bound but never executed portal therefore cannot be executed while another portal is suspended, and a portal that is still suspended on the server cannot be resumed once an unrelated portal has been bound. Both sequences are legal extended-query traffic, and the caller is left with no route but the raw `Send_Command` path.

## Problem

Commit `6f496f5`.

`Execute_Portal` refuses on the session-wide flag (`src/flyology-postgres-client.adb:860-879`):

```ada
procedure Execute_Portal
   (Item         : in out Session;
   Portal_Name  : String;
   Maximum_Rows : Protocol.Row_Limit := 0;
   Timeout      : Duration := 30.0) is
begin
   Require_Extended_Send (Item, "execute a portal");
   if not Item.Bound_In_Cycle then
      raise Program_Error with
        "cannot execute a portal before binding it in this query cycle";
   end if;
   if Item.Portal_Is_Suspended then
      raise Program_Error with
        "use Resume_Portal for a suspended portal";
   end if;
```

The scoped overload repeats the same check (`src/flyology-postgres-client.adb:1301-1304`), so both public paths behave alike here.

`Bind_Portal` clears the flag for any portal name (`src/flyology-postgres-client.adb:825-832`):

```ada
   Send_Command
     (Item,
      Protocol.Make_Bind_Message
        (Portal_Name, Statement_Name, Parameters, Result_Formats),
      Timeout);
   Item.Bound_In_Cycle := True;
   Item.Portal_Is_Suspended := False;
end Bind_Portal;
```

`Resume_Portal`, which has no scoped overload, then refuses because the flag it needs was cleared by that unrelated bind (`src/flyology-postgres-client.adb:881-893`):

```ada
procedure Resume_Portal
   (Item         : in out Session;
   Portal_Name  : String;
   Maximum_Rows : Protocol.Row_Limit := 0;
   Timeout      : Duration := 30.0) is
begin
   if Item.Current_State /= Extended_Query_Active
     or else not Item.Portal_Is_Suspended
   then
      raise Program_Error with
        "no suspended Postgres portal can be resumed";
   end if;
```

The flag is set from the response with no name either (`src/flyology-postgres-client.adb:992-995`):

```ada
when Protocol.Portal_Suspended_Response =>
   if not Sync_Pending then
      Item.Portal_Is_Suspended := True;
   end if;
```

The specification restricts resumption to a batch whose responses arrive through Flush, and both sequences below stay inside one such batch (`src/flyology-postgres-client.ads:334-336`):

```ada
--  Continue a portal after PortalSuspended. Sync ends the batch that owns
--  the portal, so only a batch whose responses arrive through Flush can be
--  resumed.
```

The protocol does not forbid two live portals in one batch. Portals live until the transaction, or the implicit transaction that Sync closes, ends.

`Test_Extended_Client_State` (`tests/src/tests.adb:1552-1578`) binds one portal, executes it to `PortalSuspended` and resumes the same portal. No test binds a second portal while one is suspended, so neither half of the defect is reachable from the suite.

## What happens now

Spike: two authenticated sessions over an in-memory transport, each parsing one statement and driving one Flush-terminated batch. Variant (a) binds `p1` and `p2`, executes `p1` with `Maximum_Rows => 1`, consumes the row and the `PortalSuspended`, and then executes `p2`, which was bound and never executed. Variant (b) suspends `p1`, then binds and runs `p2` to completion, and then resumes `p1`, which is still suspended on the server.

```ada
--  (a)
Client.Bind_Portal (Session, "p1", "s", Timeout => 1.0);
Client.Bind_Portal (Session, "p2", "s", Timeout => 1.0);
Client.Execute_Portal (Session, "p1", Maximum_Rows => 1, Timeout => 1.0);
Client.Flush (Session, Timeout => 1.0);
Queue (Channel, Single_Column_Row);
Queue (Channel, Protocol.Make_Empty_Message ('s'));  --  PortalSuspended
...
Client.Execute_Portal (Session, "p2", Timeout => 1.0);

--  (b)
Client.Bind_Portal (Session, "p1", "s", Timeout => 1.0);
Client.Execute_Portal (Session, "p1", Maximum_Rows => 1, Timeout => 1.0);
Client.Flush (Session, Timeout => 1.0);
Queue (Channel, Single_Column_Row);
Queue (Channel, Protocol.Make_Empty_Message ('s'));  --  PortalSuspended
...
Client.Bind_Portal (Session, "p2", "s", Timeout => 1.0);
Client.Execute_Portal (Session, "p2", Timeout => 1.0);
Client.Flush (Session, Timeout => 1.0);
...
Client.Resume_Portal (Session, "p1", Timeout => 1.0);
```

```
  -- (a) Bind p1, Bind p2, Execute p1 (Maximum_Rows => 1), Flush
  -- PortalSuspended received
  -- Execute_Portal ("p2") raised Program_Error: use Resume_Portal for a suspended portal
  FAILED: a bound, never executed portal can be executed while another portal of the same batch is suspended
  -- (b) Execute p1 to suspension, then bind and run p2, then resume p1
  -- PortalSuspended received
  -- Resume_Portal ("p1") raised Program_Error: no suspended Postgres portal can be resumed
  FAILED: a portal suspended earlier in the same Flush-driven batch can still be resumed after another portal ran
BUG REPRODUCED: 2 failed expectation(s)
```

Both variants use the synchronous send path. The scoped `Execute_Portal` carries the identical check at `src/flyology-postgres-client.adb:1301-1304` and fails variant (a) the same way; `Resume_Portal` exists only in the synchronous form.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

Suspension is a property of a portal, not of the session. Executing a different, bound, never executed portal must be accepted while another portal is suspended, and a portal suspended earlier in the same Flush-driven batch must remain resumable after an unrelated portal has run, which is the case `Resume_Portal`'s specification describes as resumable.

## Suggested treatment

Record the suspended portals by name for the life of the batch instead of one Boolean: set the name on `PortalSuspended`, clear that name on the portal's own `CommandComplete`, `ErrorResponse` or `Close`, clear the whole set at Sync where `Send_Command` already clears the flag (`src/flyology-postgres-client.adb:530`), and have `Bind_Portal` clear only the name it rebinds. `Execute_Portal` then refuses only when the named portal is itself suspended, and `Resume_Portal` accepts a named portal that is.

Holding several names needs a bound on how many suspended portals one batch may track, which is a new externally visible capacity. This needs a maintainer decision: track a bounded set with a documented capacity, track only the most recently suspended portal name and refuse the rest, or store the name in an unbounded container. The one-Boolean model cannot express any of these, and `PortalSuspended` itself carries no name, so the name has to come from the `Execute` the session sent.

The regression test belongs in `Test_Extended_Client_State` (`tests/src/tests.adb:1552-1578`), which already drives a portal to `PortalSuspended` and resumes it. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

Valid sequences are refused locally, before anything is written, so the transport is never desynchronised and no wrong data reaches the caller. The cost is that a caller who keeps two portals live in one batch, which the protocol allows, has to abandon the typed API and hand-build Execute messages through `Send_Command`. It needs the unusual shape of a second portal in a batch that already has a suspended one. Deterministic.
