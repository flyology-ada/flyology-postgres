Title: Scoped Send_Query writes a simple query while pipeline mode is active
Labels: bug
Refs: CLIENT-1

## Summary

The scoped `Send_Query` overload checks only that the session is `Ready` and omits the pipeline-mode guard that the synchronous overload and `Send_Command` both apply. On the same session in the same state, the synchronous call raises `Program_Error` and writes nothing, while the scoped call puts a `Query` frame on the wire and leaves the session in `Simple_Query_Active` with pipeline mode still active. The documented rejection is honoured by one of the two public entry points.

## Problem

Commit `6f496f5`.

The synchronous overload rejects the call first (`src/flyology-postgres-client.adb:558-568`):

```ada
procedure Send_Query
  (Item : in out Session; SQL : String; Timeout : Duration := 30.0) is
   Contents : Flyology.Bytes.Unbounded_Bytes;
begin
   if Item.Pipelined then
      raise Program_Error with
        "simple queries are not allowed in Postgres pipeline mode";
   end if;
   if Item.Current_State /= Ready then
      raise Program_Error with "Postgres session is not ready for a query";
   end if;
```

The scoped overload has no such guard (`src/flyology-postgres-client.adb:1255-1274`):

```ada
procedure Send_Query
  (Item      : not null access Session;
   SQL       : String;
   Timeout   : Duration := 30.0;
   Operation : in out Send_Operation) is
   Contents : Flyology.Bytes.Unbounded_Bytes;
begin
   if Item.Current_State /= Ready then
      raise Program_Error with "Postgres session is not ready for a query";
   elsif SQL'Length > Protocol.Maximum_Message_Size - 5 then
      ...
   Start_Send
     (Item,
      Protocol.Make_Message ('Q', Flyology.Bytes.To_Array (Contents)),
      Simple_Query_Send,
```

`Start_Send` does not re-check: it writes the encoded message and never passes through `Send_Command`, where the raw path's identical rejection lives (`src/flyology-postgres-client.adb:469-472`):

```ada
if Item.Pipelined and then Tag = Protocol.Query then
   raise Program_Error with
     "simple queries are not allowed in Postgres pipeline mode";
end if;
```

`Ready` is exactly the state pipeline mode starts from and returns to between batches, so the state test does not make the window unreachable.

`Enter_Pipeline_Mode` documents the rejection (`src/flyology-postgres-client.ads:375-376`):

```ada
--  ends exactly one batch in the order the batches were written. Simple
--  queries are rejected while the mode is active. A COPY response is
```

README "Pipelined batches" repeats it (`README.md:232-236`):

```
Simple queries are rejected while the mode is active, because a simple query
carries no Sync boundary of its own. A COPY response is rejected too, and that
rejection is terminal: the response is already consumed and the server is
already streaming, so the session closes and its transport must be discarded.
Leave pipeline mode before starting COPY.
```

`Test_Pipelined_Client_State` asserts the rejection only for the synchronous overload (`tests/src/tests.adb:1750-1759`), and the scoped `Send_Query` test, `Test_Partial_And_Gates` (`tests/src/tests.adb:2171-2195`), never enters pipeline mode. No test combines the two.

## What happens now

Spike: one authenticated session over an in-memory transport, put into pipeline mode with no batch outstanding, is asked to send the same simple query twice. The synchronous overload runs first as a control on the other path; then the scoped overload is called on the same session and the same state, and the frontend bytes are inspected.

```ada
Client.Startup (Session, User => "tester", Timeout => 1.0);
Client.Enter_Pipeline_Mode (Session);
Clear_Sent (Channel);
--  Control: the synchronous overload rejects the call.
Client.Send_Query (Session, "select 1", Timeout => 1.0);
--  The scoped overload, same session, same state.
Send : Client.Send_Operation :=
  Client.Send_Query
    (Set'Access, Session'Access, "select 1", Timeout => 1.0);
```

```
  -- synchronous Send_Query raised Program_Error: simple queries are not allowed in Postgres pipeline mode
  ok: control: the synchronous Send_Query rejects a simple query in pipeline mode
  ok: control: the rejected synchronous call wrote nothing
  -- after the scoped call: state = SIMPLE_QUERY_ACTIVE, In_Pipeline_Mode = TRUE, frontend bytes written = 14
  FAILED: the scoped Send_Query rejects a simple query in pipeline mode (Enter_Pipeline_Mode: 'Simple queries are rejected while the mode is active')
  FAILED: no Query message reaches the wire while pipeline mode is active
  FAILED: the refused simple query leaves the session state untouched
BUG REPRODUCED: 3 failed expectation(s)
```

The 14 written bytes are the `Query` frame the guard exists to prevent.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

Both entry points should apply the same rejection. A simple query attempted while pipeline mode is active should raise `Program_Error`, write nothing, and leave the session in `Ready`, as `Enter_Pipeline_Mode` and README "Pipelined batches" state.

## Suggested treatment

Add the missing guard at the head of the scoped `Send_Query` (`src/flyology-postgres-client.adb:1262`), before the state test, so the two overloads reject on the same condition and in the same order:

```ada
if Item.Pipelined then
   raise Program_Error with
     "simple queries are not allowed in Postgres pipeline mode";
end if;
```

This is one instance of a pattern: the scoped overloads reimplement the synchronous guards instead of sharing them, and the scoped receive drops a different one ({{ISSUE:CLIENT-1}}). `Start_Send`, `Start_Receive` and `Start_Startup_Operation` should be audited against their synchronous counterparts in the same pass.

The regression test belongs in `Test_Pipelined_Client_State` (`tests/src/tests.adb:1750-1759`), next to the synchronous assertion, which already has the session in the required state. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

Contract drift and an inconsistency between two public entry points rather than a wrong result. A `Query` frame does reach the wire while pipeline mode is active, but the window is only open with zero outstanding batches, so no interleaving with a pipelined batch's responses occurs, and no counter is corrupted: `Apply_Query_Event`'s `ReadyForQuery` branch sets `Ready` directly and does not touch `Pending_Syncs`. A caller who reads the documentation and uses the scoped API gets no diagnostic where the synchronous API gives one. Deterministic.
