Title: A RowDescription for another statement makes the executed portal's DataRows unreadable
Labels: bug
Refs: none

## Summary

The extended-query path keeps one session-wide row description and checks every `DataRow` against whichever `RowDescription` arrived last, with no link to the statement or portal it describes. Describing one object and executing another in a single batch is legal extended-query traffic, and the server's description arrives before the executed portal's rows. `Receive_Extended_Event` then raises `Protocol_Error` on a message sequence PostgreSQL legitimately produced, and because the stale description is never cleared, every remaining row of that portal fails the same way and the batch's result set stays unreadable.

## Problem

Commit `6f496f5`.

Every `RowDescription` overwrites the session's description, and every `DataRow` is validated against it (`src/flyology-postgres-client.adb:962-978`):

```ada
when Protocol.Row_Description_Response =>
   Item.Described_Columns := Protocol.Field_Count
     (Protocol.Description (Response));
   Item.Has_Row_Description := True;
when Protocol.Data_Row_Response =>
   --  The backend sends RowDescription only in reply to Describe,
   --  so a portal that was executed without one legitimately
   --  returns bare rows. Check the column count against a
   --  description that actually arrived, and take the rest on
   --  trust, because nothing else describes their shape.
   if Item.Has_Row_Description
     and then Protocol.Column_Count (Protocol.Row_Data (Response)) /=
       Item.Described_Columns
   then
      raise Protocol.Protocol_Error with
        "DataRow column count does not match RowDescription";
   end if;
```

Nothing binds the retained description to the object that was described. `Has_Row_Description` is cleared only by `CommandComplete`, `EmptyQueryResponse` (`src/flyology-postgres-client.adb:979-982`), `NoData` (`:989-991`), `ErrorResponse` (`:996-998`) and `ReadyForQuery`, none of which occurs between a Describe reply and the reply to a later Execute in the same batch.

The `.ads` sentence that sanctions the tolerant check is about a missing description, not about matching descriptions to objects (`src/flyology-postgres-client.ads:405-410`):

```ada
--  Receive and validate one extended-query response event. In pipeline
--  mode each ReadyForQuery ends one batch, in the order the batches were
--  written. A portal executed without Describe_Portal or
--  Describe_Statement returns rows with no RowDescription, which is
--  accepted; the column count is checked only against a description the
--  server actually sent.
```

The server did send this description, for a different prepared statement. `Describe_Statement ("two")` legitimately produces `ParameterDescription` and `RowDescription`, and an `Execute` of an unrelated portal in the same batch legitimately produces bare `DataRow`s.

The simple-query path carries the same one-description model at `src/flyology-postgres-client.adb:716-729`, but there it is sound: a simple query always describes each result before its rows, and `CommandComplete` clears the description between statements.

`Test_Extended_Client_State` (`tests/src/tests.adb:1513-1596`) uses a single statement and a single portal and never describes one object while executing another, so the mismatch cannot arise there. No test describes one object and executes a different one in one batch.

## What happens now

Spike: an authenticated session over an in-memory transport writes one batch of `Parse "one"` (one column), `Parse "two"` (two columns), `Bind "p1"` to `"one"`, `Describe_Statement "two"`, `Execute "p1"`, `Flush`. The backend's replies are queued in exact message order, ending with the two-field `RowDescription` for `"two"` and then the one-column `DataRow` and `CommandComplete` for portal `"p1"`. The program reads events until the queue drains and asserts that the row is delivered.

```ada
Client.Prepare_Statement (Session, "one", "select 1", Timeout => 1.0);
Client.Prepare_Statement (Session, "two", "select 1, 2", Timeout => 1.0);
Client.Bind_Portal (Session, "p1", "one", Timeout => 1.0);
Client.Describe_Statement (Session, "two", Timeout => 1.0);
Client.Execute_Portal (Session, "p1", Timeout => 1.0);
Client.Flush (Session, Timeout => 1.0);

--  Exactly what the backend replies, in message order.
Queue (Channel, Protocol.Make_Empty_Message ('1'));   --  Parse one
Queue (Channel, Protocol.Make_Empty_Message ('1'));   --  Parse two
Queue (Channel, Protocol.Make_Empty_Message ('2'));   --  Bind p1
Queue (Channel, Parameter_Description);               --  Describe "two"
Queue (Channel, Row_Description (2));                 --  Describe "two"
Queue (Channel, Single_Column_Row);                   --  Execute p1
Queue (Channel, Command_Complete);                    --  Execute p1
```

```
  -- Receive_Extended_Event raised Protocol_Error: DataRow column count does not match RowDescription
  FAILED: a RowDescription for another statement does not invalidate the executed portal's rows
  FAILED: the executed portal's single-column DataRow is delivered
BUG REPRODUCED: 2 failed expectation(s)
```

The spike drives the synchronous receive path. `Apply_Extended_Event` is shared, so the scoped `Receive_Extended_Event` fails the same way. `Describe_Portal (P2)` followed by `Execute_Portal (P1)` produces the same result.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A `RowDescription` that describes a statement or portal other than the one whose `Execute` is being answered must not invalidate that portal's rows. The rows of portal `"p1"` should be delivered, and the batch should complete normally, as `Receive_Extended_Event` promises for a portal executed without its own Describe.

## Suggested treatment

Bind the retained description to the object it describes rather than to the session. `Describe_Statement` and `Describe_Portal` already know the name they sent, so the session can record which object the pending description belongs to, and `Apply_Extended_Event` can apply the column check only when the executed portal is the described one, taking the rows on trust otherwise. Clearing the description on the `Execute` reply of any other portal is the smaller alternative. Whichever is chosen, the `Protocol_Error` path must also clear `Has_Row_Description` and `Described_Columns` so a single mismatch cannot poison the rest of the batch.

Tracking the described object adds session state, and the description of a portal remains valid across several Executes in a batch, so the retention rule is a maintainer decision: keep one description per described name for the life of the batch, or discard the description as soon as an unrelated portal is executed.

The regression test belongs in `Test_Extended_Client_State` (`tests/src/tests.adb:1513`), which already builds a single-portal extended batch. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

An unexpected `Protocol_Error` on a legal message stream, and once it fires the batch cannot be read: the stale description survives the exception, so every subsequent `DataRow` of that portal fails identically and the caller can only abandon the batch. It needs the unusual shape of describing one object while executing another inside a single batch, which a caller who describes each portal it executes never writes. Deterministic.
