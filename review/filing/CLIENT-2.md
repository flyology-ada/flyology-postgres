Title: Extended COPY IN counts the Sync the backend discards, leaving the session one ReadyForQuery short
Labels: bug
Refs: SERVER-4

## Summary

PostgreSQL discards a `Sync` that arrives while the backend is reading COPY IN data, so that Sync never produces a `ReadyForQuery`. The session counts it anyway and carries it into the COPY state as `Copy_Sync_Pending`. With the message order libpq puts on the wire, the client believes two batches are outstanding and the server answers one, so the session is stranded in `Awaiting_Ready` with `Pending_Synchronizations = 1`, where every command and `Synchronize` raise `Program_Error` and the next receive blocks until `Timeout_Error`. A caller who instead trusts `Pending_Synchronizations` and omits the second Sync leaves the backend waiting for a message no API call can write.

## Problem

Commit `6f496f5`.

Every `Sync` is counted, and a Sync written during an extended COPY also arms `Copy_Sync_Pending` (`src/flyology-postgres-client.adb:525-533`):

```ada
when Protocol.Sync =>
   Item.Pending_Syncs := Item.Pending_Syncs + 1;
   Item.Current_State := Awaiting_Ready;
   Item.Batch_Open := False;
   Item.Bound_In_Cycle := False;
   Item.Portal_Is_Suspended := False;
   if Item.Current_Copy_Origin = Extended_Copy then
      Item.Copy_Sync_Pending := True;
   end if;
```

When the `CopyInResponse` arrives, the same count reaches `Enter_Copy`. The typed path passes the flag its caller computed from `Item.Pending_Syncs > 0` (`src/flyology-postgres-client.adb:1009-1017`):

```ada
when Protocol.Copy_In_Response |
     Protocol.Copy_Out_Response |
     Protocol.Copy_Both_Response =>
   Require_No_Pipelined_Copy (Item);
   Enter_Copy
     (Item,
      Protocol.Response_Kind (Response),
      Origin       => Extended_Copy,
      Sync_Pending => Sync_Pending);
```

and the raw `Receive_Message` path reads the counter directly (`src/flyology-postgres-client.adb:625-629`):

```ada
Enter_Copy
  (Item,
   Protocol.Response_Kind (Decoded),
   Origin       => Extended_Copy,
   Sync_Pending => Item.Pending_Syncs > 0);
```

Neither site distinguishes the readable COPY directions from the writable ones.

`Enter_Copy` records it verbatim (`src/flyology-postgres-client.adb:43-50`):

```ada
procedure Enter_Copy
  (Item         : in out Session;
   Response     : Protocol.Backend_Message_Kind;
   Origin       : Copy_Origin;
   Sync_Pending : Boolean := False) is
begin
   Item.Current_Copy_Origin := Origin;
   Item.Copy_Sync_Pending := Sync_Pending;
```

The backend does not honour that Sync. `CopyGetData` consumes and discards `Flush` and `Sync` while the backend is in copy-in mode (`tests/.cache/postgres/18.4-openssl/source/src/backend/commands/copyfromparse.c:320-329`):

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

The COPY runs inside `exec_execute_message`, so a Sync written straight after Execute never reaches the main loop and never produces a `ReadyForQuery`. Only the Sync that follows `CopyDone` does.

That ordering is what libpq writes. `PQsendQueryGuts`, which serves `PQsendQueryParams`, appends Parse, Bind, Describe, Execute and then Sync (`tests/.cache/postgres/18.4-openssl/source/src/interfaces/libpq/fe-exec.c:1896-1909`):

```c
/* construct the Execute message */
if (pqPutMsgStart(PqMsg_Execute, conn) < 0 ||
...
/* construct the Sync message if not in pipeline mode */
if (conn->pipelineStatus == PQ_PIPELINE_OFF)
{
    if (pqPutMsgStart(PqMsg_Sync, conn) < 0 ||
```

`PQputCopyEnd` then writes `CopyDone` and a second Sync (`tests/.cache/postgres/18.4-openssl/source/src/interfaces/libpq/fe-exec.c:2797-2807`):

```c
/*
 * If we sent the COPY command in extended-query mode, we must issue a
 * Sync as well.
 */
if (conn->cmd_queue_head &&
    conn->cmd_queue_head->queryclass != PGQUERY_SIMPLE)
{
    if (pqPutMsgStart(PqMsg_Sync, conn) < 0 ||
```

So libpq puts `P B D E S d c S` on the wire and expects exactly one `ReadyForQuery`. The frontend tags this library produces for the same sequence are `PBESdcS`, the same order without the optional Describe.

The API accepts that order. `Synchronize` is legal from `Extended_Query_Active`, and `Receive_Extended_Event` accepts `Awaiting_Ready` (`src/flyology-postgres-client.adb:2232-2234`). README "Streaming COPY" says where to send the Sync, not that an earlier one is rejected (`README.md:319-321`):

```
For extended COPY, `Sync` is mandatory. COPY OUT may pipeline `Sync` after
`Execute`; COPY IN and the writable half of COPY BOTH send it after local
`CopyDone`/`CopyFail`.
```

A generic extended-query driver following the README's own Prepare, Bind, Execute, Synchronize example cannot know in advance that the statement is a COPY, which is the case the backend's leniency exists for.

COPY OUT is unaffected: it never reads from the frontend, so a pipelined Sync reaches the main loop and is answered. Only the writable directions, COPY IN and the writable half of COPY BOTH, are wrong.

The suite's extended COPY IN case sends the Sync only after `CopyDone` (`tests/src/tests.adb:1280-1308`), the order the README prescribes, so the discarded Sync never occurs there. Nothing tests the libpq order.

The mirror of this defect on the server side, where `Read_Copy_Command` rejects the same in-COPY Sync instead of ignoring it, is reported separately ({{ISSUE:SERVER-4}}).

## What happens now

Spike: an authenticated session over an in-memory transport runs an extended COPY IN twice. Variant (a) writes Parse, Bind, Execute, Sync, then `CopyData`, `CopyDone`, Sync, which is libpq's order, and is fed exactly what a real backend replies: `CopyInResponse`, then `CommandComplete` and one `ReadyForQuery`. Variant (b) omits the second Sync, as a caller who trusts `Pending_Synchronizations` would, and is fed `CopyInResponse` and `CommandComplete`. Both variants print the frontend tags actually written, and then ask whether the session can carry on.

```ada
Client.Prepare_Statement (Item, "c", "copy t from stdin", Timeout => 1.0);
Client.Bind_Portal (Item, "", "c", Timeout => 1.0);
Client.Execute_Portal (Item, "", Timeout => 1.0);
Client.Synchronize (Item, Timeout => 1.0);
Queue (Channel, Copy_In_Response);
...
Client.Send_Copy_Data (Session, Chunk, Timeout => 1.0);
Client.Finish_Copy (Session, Timeout => 1.0);
Client.Synchronize (Session, Timeout => 1.0);
--  What a real backend now sends: CommandComplete, then exactly one
--  ReadyForQuery (for the Sync that followed CopyDone).
Queue (Channel, Command_Complete);
Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
```

```
  -- (a) Execute, Sync, CopyData, CopyDone, Sync -- the libpq order
  ok: the extended COPY IN starts from CopyInResponse
  -- frontend tags written: PBESdcS
  -- Pending_Synchronizations after both Syncs = 2 (the server discarded the first Sync, so one ReadyForQuery is owed)
  ok: CommandComplete ends the COPY
  ok: the single ReadyForQuery is delivered
  -- after the exchange: state = AWAITING_READY, pending = 1, unconsumed backend bytes = 0
  ok: the whole server response was consumed
  FAILED: no ReadyForQuery remains outstanding: the server discarded the Sync it received while in copy-in mode
  FAILED: the COPY IN batch leaves the session ready for the next command
  -- Prepare_Statement raised Program_Error: cannot prepare a statement while Postgres session state is AWAITING_READY
  FAILED: a following command is accepted after the COPY IN batch
  -- on a real socket the phantom outstanding batch also makes the next Receive_Extended_Event block until Timeout_Error
  -- (b) Execute, Sync, CopyData, CopyDone -- no second Sync
  ok: the extended COPY IN starts from CopyInResponse
  -- frontend tags written: PBESdc
  ok: CommandComplete ends the COPY
  -- after CommandComplete: state = AWAITING_READY, pending = 1
  FAILED: the discarded Sync is not counted as outstanding
  -- Synchronize raised Program_Error: cannot synchronize while Postgres session state is AWAITING_READY
  FAILED: the Sync the backend is waiting for can still be written; otherwise the session can only be discarded
BUG REPRODUCED: 5 failed expectation(s)
```

Both variants use the synchronous receive path; the miscounted Sync lives in the session state, so the scoped path inherits it unchanged. Variant (b) is the worse one: the backend is waiting for a Sync, and no public call can write it, because `Synchronize` and `Send_Command` refuse every tag except `Terminate` from `Awaiting_Ready` outside pipeline mode.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server and libpq sources used for reference.

## What should happen

A Sync that was outstanding when a writable COPY started has already been discarded by the backend, so it must not be counted as a batch awaiting `ReadyForQuery`. After `CommandComplete` and the one real `ReadyForQuery`, the session must be `Ready` with `Pending_Synchronizations = 0` and must accept the next command. When no second Sync has been written, `Synchronize` must still be able to write the Sync the backend is waiting for.

## Suggested treatment

Fix it inside `Enter_Copy` (`src/flyology-postgres-client.adb:43-50`), which already receives both the response kind and the session, so both call sites are covered at once. When the origin is `Extended_Copy`, the response opens a writable direction (`Copy_In_Response`, or `Copy_Both_Response` whose writable half opens), and `Sync_Pending` is set, decrement `Item.Pending_Syncs` and store `Item.Copy_Sync_Pending := False`. `Copy_Out_Response` keeps the current behaviour, because the backend does answer a Sync pipelined before a COPY OUT. The Sync branch of `Send_Command` (`:531-533`) is then correct as written: it arms `Copy_Sync_Pending` only for a Sync written after the COPY is under way, which is the one the backend answers. `Exit_Pipeline_Mode`'s outstanding-batch check at `:2435-2440` is off by one for the same reason and is fixed by the same change.

The regression test belongs beside the existing extended COPY IN case in `Test_Copy_Client_State` (`tests/src/tests.adb:1280-1309`), which exercises only the README order. The program above is the test. No existing test asserts the wrong behaviour.

## Severity

Any caller that sends its Sync in libpq's position, which a generic extended-query driver does because it cannot know the statement is a COPY, ends the COPY with a session that refuses every further command. On a real socket variant (a) degrades further: the next `Receive_Extended_Event` waits for a `ReadyForQuery` that will never arrive and fails with `Timeout_Error`, and variant (b) blocks the backend on a Sync the client can no longer write, with no recovery short of discarding the connection. It needs no unusual input, only the extended protocol and a COPY IN. Deterministic; not reproduced against a live server.
