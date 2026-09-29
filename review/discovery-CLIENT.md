# Correctness discovery: CLIENT (session state machine)

Scope: `src/flyology-postgres-client.ads` / `.adb`, `src/flyology-postgres-client_sockets.ads` / `.adb`,
read against `Protocol`, `Framing`, `Transports`, `Transports.TLS_Sockets`, README sections
"API outline", "Pipelined batches", "Streaming COPY", and the existing tests
(`tests/src/tests.adb`, `postgres_test_client.adb`, `postgres_test_pipeline.adb`).
Read-only review; nothing was built or run. Known items PROTO-1..7 are excluded.

Severity rubric: P0 = memory/aliasing unsafety, security-relevant, hang/deadlock in normal
operation, or interop-breaking protocol violation; P1 = wrong result or unexpected exception on
valid input via a reachable path, or a documented contract violated; P2 = edge-case
incorrectness, wrong diagnostics, or contract drift needing unusual input.

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| CLIENT-1 | Scoped `Receive_Extended_Event` derives `Sync_Pending` from the state instead of `Pending_Syncs`; in pipeline mode a failed earlier batch wrongly puts the open batch into `Recovery_Required` | P1 | High |
| CLIENT-2 | Extended COPY IN with a Sync pipelined before `CopyInResponse` is modelled as if the server honoured that Sync; the server discards it, so the session waits for a `ReadyForQuery` that never comes or ends stuck in `Awaiting_Ready` with `Pending_Synchronizations = 1` | P1 | High (server behaviour), needs real PostgreSQL to observe the hang |
| CLIENT-3 | Scoped `Send_Query` bypasses the pipeline-mode rejection that the synchronous path and the `Enter_Pipeline_Mode` contract promise | P2 | High |
| CLIENT-4 | Extended DataRow column check uses whichever `RowDescription` arrived last, not the one for the executed portal; Describe A then Execute B in one batch raises `Protocol_Error` on a valid sequence | P2 | High |
| CLIENT-5 | One session-wide `Portal_Is_Suspended` flag: with two portals bound in a batch, `Execute_Portal` of the second is refused after the first suspends, and `Resume_Portal` of the first is refused after the second is bound | P2 | High |
| CLIENT-6 | Startup failure leaves `Not_Started`/`TLS_Negotiated` for the plaintext path but `Closed` for the TLS path; a retried `Startup` writes to a connection the server already closed | P2 | Medium |

---

### CLIENT-1: Scoped `Receive_Extended_Event` derives `Sync_Pending` from the state instead of `Pending_Syncs`

Location:
- `src/flyology-postgres-client.adb:1523` (`Start_Receive`)
- versus `src/flyology-postgres-client.adb:2226` (synchronous `Receive_Extended_Event`)
- consumer: `Apply_Extended_Event`, `src/flyology-postgres-client.adb:956-1031` (lines 984-988, 993-995, 998-1006)

Severity: P1. Confidence: High.

Evidence:

Synchronous path (2226):
```ada
      Sync_Pending : constant Boolean := Item.Pending_Syncs > 0;
```
Scoped path (1523):
```ada
      Operation.Sync_Pending := Item.Current_State = Awaiting_Ready;
```
`Apply_Extended_Event` (998-1006) uses that flag to decide whether an `ErrorResponse` needs local
recovery:
```ada
         when Protocol.Error_Response =>
            ...
            if not Sync_Pending then
               Item.Current_State := Recovery_Required;
               Item.Bound_In_Cycle := False;
               Item.Portal_Is_Suspended := False;
            end if;
```
and the same flag gates `Portal_Is_Suspended` for `Command_Complete`/`Portal_Suspended` (984-995).

In pipeline mode the two expressions differ exactly when a later batch is open while an earlier
batch is still outstanding: `Send_Command` (517-519) moves `Awaiting_Ready` to
`Extended_Query_Active` when the next batch's Parse/Bind/... is written, while `Pending_Syncs`
stays > 0. The synchronous path then treats a response as belonging to the outstanding batch
(correct: responses arrive in batch order and every earlier `ReadyForQuery` has already been
consumed); the scoped path treats it as belonging to the open batch.

README "Pipelined batches" promises: "Each batch's own Sync contains its failure ... so the
session does not enter `Recovery_Required`." `tests/src/tests.adb:1795-1800` asserts exactly that
for the synchronous path ("a failed pipelined batch needs no separate recovery Sync").

Failure scenario (all valid traffic):
1. `Enter_Pipeline_Mode`; batch 1: Parse/Bind/Execute/Sync (`Pending_Syncs = 1`, `Awaiting_Ready`).
2. Batch 2 opened: Parse "second", Bind "second" (`Extended_Query_Active`, `Bound_In_Cycle = True`, `Pending_Syncs = 1`).
3. Server answers batch 1 with `ErrorResponse`, `ReadyForQuery`.
4. Client receives the `ErrorResponse` through a scoped `Receive_Operation`: `Sync_Pending = False`
   because the state is `Extended_Query_Active`, so the session becomes `Recovery_Required`,
   `Bound_In_Cycle` is cleared.
5. Consequences: `Execute_Portal (Session, "second")` raises `Program_Error`
   ("cannot execute a portal ... state is RECOVERY_REQUIRED"), and any further
   `Receive_Extended_Event` (scoped or synchronous) raises `Program_Error`
   ("recovery requires Sync before receiving") although batch 1's `ReadyForQuery` is the next
   byte on the wire. The only way out is an extra `Synchronize`, which prematurely ends batch 2 and
   desynchronises the local `Pending_Syncs` count from what the caller intended.

Variant: batch 1 executes with `Maximum_Rows => 1` and ends with `PortalSuspended`; received through
the scoped path while batch 2 is open, `Portal_Is_Suspended := True` is set on the open batch, so
`Execute_Portal` for batch 2's freshly bound portal raises "use Resume_Portal for a suspended
portal".

Reproduction sketch (Memory_Transport, no real PostgreSQL):
```
Channel : aliased Memory_Transport; Session : Client.Session (Channel'Access);
Set : aliased Operations.Completion_Set (Capacity => 1);
Queue R(method 0), Queue Z('I'); Client.Startup (Session, User => "t");
Client.Enter_Pipeline_Mode (Session);
Prepare_Statement (Session, "first", "select 1"); Bind_Portal (Session, "first", "first");
Execute_Portal (Session, "first"); Synchronize (Session);
   -- Pending_Synchronizations = 1, State = Awaiting_Ready
Prepare_Statement (Session, "second", "select 1"); Bind_Portal (Session, "second", "second");
   -- State = Extended_Query_Active, Pending = 1
Queue E ('M' "x" NUL NUL); Queue Z('I');
Receive : Client.Receive_Operation := Client.Receive_Extended_Event (Set'Access, Session'Access, 1.0);
Operations.Wait_All (Set); Client.Finish (Receive, Event);
Check (Response_Kind (Event) = Error_Response);
Check (Client.State (Session) = Client.Extended_Query_Active, "scoped receive matches sync path");   -- actual: Recovery_Required
Check (Client.Pending_Synchronizations (Session) = 1);
-- Correct behaviour continues: Client.Execute_Portal (Session, "second") is accepted,
-- and the next receive (either path) returns Ready_For_Query_Response with Pending = 0
-- and State = Extended_Query_Active (batch 2 still open).
-- Actual: Execute_Portal raises Program_Error; Receive_Extended_Event raises Program_Error.
```
Control: running the identical byte sequence through synchronous `Receive_Extended_Event` gives
`Awaiting_Ready`/`Extended_Query_Active` as the existing test at `tests.adb:1795` shows.

Existing coverage: `Test_Pipelined_Client_State` (tests.adb:1667-1990) covers only the synchronous
receive. `Test_Composable_Client_Operations` (tests.adb:2068-2459) exercises scoped receives only
outside pipeline mode (single open batch, `Pending_Syncs = 0`, and `Awaiting_Ready`), where the two
expressions coincide. `postgres_test_pipeline.adb` uses synchronous receives.

---

### CLIENT-2: Extended COPY IN with a Sync pipelined before `CopyInResponse` is modelled as if the server honoured that Sync

Location:
- `src/flyology-postgres-client.adb:43-70` (`Enter_Copy` records `Copy_Sync_Pending`)
- `src/flyology-postgres-client.adb:1013-1017` (`Apply_Extended_Event` passes `Sync_Pending` for `Copy_In_Response`), and `629` for the raw path
- `src/flyology-postgres-client.adb:528-533` (`Send_Command` Sync counts every Sync, sets `Copy_Sync_Pending`)
- `src/flyology-postgres-client.adb:2318-2328`, `2344-2361` (`Receive_Copy_Event` CommandComplete / ReadyForQuery)
- `src/flyology-postgres-client.adb:932-953` (`Synchronize` accepts `Copy_Completion_Active` with `Extended_Copy`)

Severity: P1. Confidence: High on the server behaviour and the library model; the hang itself
needs a real PostgreSQL to observe (Memory_Transport cannot show which bytes the server would
not send).

Evidence:

`Receive_Extended_Event` accepts `Awaiting_Ready`, so `Execute_Portal; Synchronize;
Receive_Extended_Event` is a permitted way to obtain the `CopyInResponse`. `Apply_Extended_Event`
(1013-1017) then records the pending Sync as belonging to the COPY:
```ada
            Enter_Copy
              (Item,
               Protocol.Response_Kind (Response),
               Origin       => Extended_Copy,
               Sync_Pending => Sync_Pending);
```
`Receive_Copy_Event` (2318-2328) later relies on that flag to predict a `ReadyForQuery`:
```ada
         when Protocol.Command_Complete_Response =>
            ...
            elsif Item.Copy_Sync_Pending then
               Item.Current_State := Awaiting_Ready;
```
PostgreSQL's copy-in reader (`src/backend/commands/copyfromparse.c`, `CopyGetData`; the same code
has been in `copy.c` since 7.4) explicitly discards `Sync` and `Flush` received while in copy-in
mode ("Ignore Flush/Sync for the convenience of client libraries (such as libpq) that may send
those without noticing that the command they just sent was COPY"). The backend runs the COPY inside
`exec_execute_message`, so a Sync sent right after Execute is consumed by that loop and never
produces a `ReadyForQuery`. That is why libpq's `PQputCopyEnd` sends a second Sync after CopyDone
for extended-query COPY. The README acknowledges half of this ("COPY IN ... send it after local
CopyDone/CopyFail") but the state machine still counts the earlier Sync.

Failure scenario (valid traffic, real server):
1. `Prepare_Statement`/`Bind_Portal`/`Execute_Portal` for `COPY t FROM STDIN`; `Synchronize`
   (`Pending_Syncs = 1`, `Awaiting_Ready`).
2. `Receive_Extended_Event` returns `Copy_In_Response`; `Copy_Sync_Pending = True`, `Copy_In_Active`.
3. `Send_Copy_Data ...`; `Finish_Copy` (`Copy_Completion_Active`).
4. Either:
   a. Caller follows the README and calls `Synchronize` again (accepted): `Pending_Syncs = 2`.
      Server sends `CommandComplete`, then exactly one `ReadyForQuery` (the first Sync was
      discarded). `Receive_Copy_Event` -> C -> `Awaiting_Ready`; -> Z -> `Pending_Syncs = 1`,
      state `Awaiting_Ready`. The session is now permanently `Awaiting_Ready` with one phantom
      outstanding batch: `Send_Command` refuses everything but Terminate, `Receive_Extended_Event`
      blocks until `Timeout_Error`, `Exit_Pipeline_Mode`-style bookkeeping is off by one.
   b. Caller trusts the state machine (a Sync is already pending) and does not send a second Sync:
      after `CommandComplete` the session is `Awaiting_Ready`, the server is idle waiting for a
      message, and the next `Receive_Copy_Event`/`Receive_Extended_Event` blocks until
      `Timeout_Error`. No API call is accepted that would send the missing Sync except `Synchronize`
      from `Awaiting_Ready`, which is rejected outside pipeline mode.

Reproduction sketch (Memory_Transport, scenario 4a; the queued bytes are what a real server sends):
```
Queue R(0), Z('I'); Startup.
Prepare_Statement (Session, "c", "copy t from stdin"); Bind_Portal (Session, "", "c");
Execute_Portal (Session, ""); Synchronize (Session);        -- Pending = 1
Queue G (CopyInResponse: format byte 0, U16 1, U16 0);
Ev := Receive_Extended_Event (Session);  Check (Kind = Copy_In_Response and State = Copy_In_Active);
Send_Copy_Data (Session, "a\n"); Finish_Copy (Session); Synchronize (Session);   -- Pending = 2
Queue C ("COPY 1"); Queue Z('I');        -- a real server sends exactly one Z here
Ev := Receive_Copy_Event (Session);  Check (Kind = Command_Complete_Response);
Ev := Receive_Copy_Event (Session);  Check (Kind = Ready_For_Query_Response);
Check (Client.Is_Ready (Session), "COPY IN batch ends Ready");             -- actual: Awaiting_Ready
Check (Client.Pending_Synchronizations (Session) = 0);                     -- actual: 1
Check (Bytes_Remaining (Channel) = 0);
```
Real-server confirmation for the verifier: with `psql`-less raw traffic (or the integration harness),
send Execute, Sync, then CopyData, CopyDone, Sync, and count `ReadyForQuery` messages: one.

Existing coverage: none for the Sync-before-`CopyInResponse` order. The unit test
(tests.adb:1280-1308, "extended COPY observes Sync before ReadyForQuery") and the integration test
(`postgres_test_client.adb:975-1010`) both obtain `CopyInResponse` without a preceding Sync (Flush or
nothing) and send the single Sync after `Finish_Copy`, which is the case that works.

---

### CLIENT-3: Scoped `Send_Query` bypasses the pipeline-mode rejection

Location: `src/flyology-postgres-client.adb:1255-1274` (scoped `Send_Query`) versus `558-566`
(synchronous `Send_Query`) and `469-472` (`Send_Command`).

Severity: P2. Confidence: High.

Evidence (1262-1263):
```ada
      if Item.Current_State /= Ready then
         raise Program_Error with "Postgres session is not ready for a query";
```
No `Item.Pipelined` check. The synchronous path (560-565) and `Send_Command` (469-472) both raise
`Program_Error` "simple queries are not allowed in Postgres pipeline mode". `Enter_Pipeline_Mode`'s
contract (client.ads:373-386) and README "Pipelined batches" state "Simple queries are rejected
while the mode is active". `Complete_Send` (1097-1110) then moves the session to
`Simple_Query_Active` with `Pipelined = True`.

Failure scenario: `Enter_Pipeline_Mode`; drain everything so the state is `Ready` (or before the
first batch); start `Client.Send_Query (Set'Access, Session'Access, "select 1")`. The Query is
written and the session is `Simple_Query_Active` in pipeline mode. On the wire this is harmless
(no batch is outstanding), so the impact is contract drift plus inconsistent behaviour between the
two entry points; a subsequent `Receive_Query_Event` completes normally.

Reproduction sketch:
```
Startup; Enter_Pipeline_Mode (Session);
Send : Client.Send_Operation := Client.Send_Query (Set'Access, Session'Access, "select 1", 1.0);
-- Correct: Program_Error raised at the call (as with the synchronous overload).
-- Actual: operation starts; Wait_All; Finish succeeds; Sent (Channel) contains a 'Q' frame;
--         State = Simple_Query_Active while In_Pipeline_Mode = True.
```
Existing coverage: tests.adb:1750-1758 checks only the synchronous rejection.

---

### CLIENT-4: Extended DataRow column check uses whichever `RowDescription` arrived last

Location: `src/flyology-postgres-client.adb:961-978` (`Apply_Extended_Event` RowDescription /
DataRow), spec promise at `client.ads:407-413`.

Severity: P2. Confidence: High.

Evidence:
```ada
         when Protocol.Row_Description_Response =>
            Item.Described_Columns := Protocol.Field_Count
              (Protocol.Description (Response));
            Item.Has_Row_Description := True;
         when Protocol.Data_Row_Response =>
            ...
            if Item.Has_Row_Description
              and then Protocol.Column_Count (Protocol.Row_Data (Response)) /=
                Item.Described_Columns
            then
               raise Protocol.Protocol_Error with
                 "DataRow column count does not match RowDescription";
```
`Has_Row_Description` is only cleared by CommandComplete, EmptyQueryResponse, NoData, ErrorResponse
or ReadyForQuery, and a RowDescription is not tied to the statement or portal it describes. The
spec says "the column count is checked only against a description the server actually sent", but
the description used may be for a different object.

Failure scenario (valid protocol): in one batch, `Describe_Statement ("two")` (2 columns) followed
by `Bind_Portal`/`Execute_Portal` of a portal for statement "one" (1 column), with no
CommandComplete in between. Responses: `t`, `T(2)`, `2`, `D(1 col)` -> `Protocol_Error` from
`Receive_Extended_Event`, on a message stream the server legitimately produced. Same with
`Describe_Portal (P2)` then `Execute_Portal (P1)`.

Reproduction sketch:
```
Startup; Prepare_Statement (Session, "one", "select 1"); Prepare_Statement (Session, "two", "select 1, 2");
Bind_Portal (Session, "p1", "one"); Describe_Statement (Session, "two"); Execute_Portal (Session, "p1"); Flush;
Queue 1, 1, 2, t (U16 0), T (2 fields), D (1 column), C ("SELECT 1");
loop receiving; Check (no Protocol_Error is raised and the D event is returned with 1 column).
-- Actual: Receive_Extended_Event raises Protocol_Error at the DataRow.
```
Existing coverage: tests.adb:1934-1950 covers only "bare rows without a RowDescription".

---

### CLIENT-5: One session-wide `Portal_Is_Suspended` flag rejects valid multi-portal sequences

Location: `src/flyology-postgres-client.adb:860-898` (`Execute_Portal`, `Resume_Portal`), `815-832`
(`Bind_Portal` clears the flag), `984-995` (`Apply_Extended_Event` sets/clears it).

Severity: P2. Confidence: High.

Evidence (870-874, 886-892):
```ada
      if Item.Portal_Is_Suspended then
         raise Program_Error with
           "use Resume_Portal for a suspended portal";
      ...
      if Item.Current_State /= Extended_Query_Active
        or else not Item.Portal_Is_Suspended
      then
         raise Program_Error with
           "no suspended Postgres portal can be resumed";
```
The flag carries no portal name. Two consequences on valid protocol:

a. `Bind_Portal (P1)`, `Bind_Portal (P2)`, `Execute_Portal (P1, Maximum_Rows => 1)`, `Flush`,
   receive `2`, `2`, `D`, `s`. Now `Execute_Portal (P2)` raises `Program_Error` although P2 is a
   bound, never-executed portal.
b. `Bind_Portal (P1)`, `Execute_Portal (P1, 1)`, `Flush`, receive `2`, `D`, `s`; then
   `Bind_Portal (P2)` (clears the flag, 831), `Execute_Portal (P2)`, receive `2`, `D`, `C`. Now
   `Resume_Portal (P1)` raises `Program_Error` although P1 is still suspended server-side.

The spec (client.ads:334-340) says only "Sync ends the batch that owns the portal", i.e. within a
Flush-driven batch resuming is promised. `Send_Command` with a raw Execute is the only workaround.

Reproduction sketch (case a):
```
Startup; Prepare_Statement (Session, "s", "select 1");
Bind_Portal (Session, "p1", "s"); Bind_Portal (Session, "p2", "s");
Execute_Portal (Session, "p1", Maximum_Rows => 1); Flush (Session);
Queue 1, 2, 2, D(1 col), s; receive five events;
Check (Execute_Portal (Session, "p2") does not raise);   -- actual: Program_Error
```
Existing coverage: tests.adb:1560-1580 covers a single suspended portal only.

---

### CLIENT-6: Startup failure state is inconsistent between the plaintext and TLS paths

Location: `src/flyology-postgres-client.adb:347-349` (sync `Complete_Startup` 'E'), `386-404`
(`Startup` has no state change on failure), `452-457` (`Startup_TLS` sets `Closed` on any failure),
`1647-1649` (`Fail_Startup` sets `Closed` only for the TLS stage). Contract: `client.ads:71`
("Closed The server or client has terminated the session").

Severity: P2. Confidence: Medium.

Evidence (1647-1649):
```ada
      if Item.Kind = TLS_Negotiation_Stage then
         Item.Item.Current_State := Closed;
      end if;
```
and `Startup` (386-404) simply propagates `Database_Error` leaving `Current_State = Not_Started`.
After an authentication `ErrorResponse` the server closes the connection, so the session's
documented `Closed` state is the accurate one, and `Complete_Startup` accepts a retried `Startup`
(`Current_State in Not_Started | TLS_Negotiated`, line 209), which then writes a new startup packet
to a dead transport and fails with a transport error instead of `Program_Error`.

Failure scenario: `Startup` gets `E` (28P01 wrong password). `State (Session) = Not_Started`,
`Is_Ready = False`. A caller that dispatches on `State` cannot distinguish "never started" from
"rejected"; `Send_Cancel_Request` correctly refuses, but `Startup` is accepted again.

Reproduction sketch:
```
Queue E (SQLSTATE 28P01, message); begin Startup (Session, User => "t"); exception when Database_Error => null; end;
Check (Client.State (Session) = Client.Closed, "rejected startup closes the session like Startup_TLS does");   -- actual: Not_Started
```
Existing coverage: tests.adb `Test_TLS_Refusal_Is_Terminal` (307-348) and the composable test
(2160-2190) check the TLS refusal path only.

---

## Areas reviewed with no findings

- Simple-query state machine (`Apply_Query_Event`, 702-768): RowDescription/DataRow pairing and
  column-count check, multi-statement result sets, EmptyQueryResponse, ErrorResponse then
  ReadyForQuery, Notice/ParameterStatus/NotificationResponse ('A' decodes to `Unknown_Response`)
  pass-through, COPY responses entering `Simple_Copy`.
- Simple-query COPY IN / OUT / BOTH transitions (`Enter_Copy`, `Send_Command` CopyDone/CopyFail,
  `Receive_Copy_Event`): server error during COPY IN with or without the client still sending,
  CopyFail, CopyDone/CommandComplete/ReadyForQuery ordering, BASE_BACKUP second `CopyOutResponse`
  and trailing `RowDescription`, walsender timeline-switch result set (server CopyDone first, then
  client CopyDone, then T/D/C/Z), crossed in-flight CopyData after both directions close, `On_Wait`
  observer sending StandbyStatusUpdate mid-read (same task, state read only after the observer).
- Extended COPY OUT with Sync pipelined after Execute (the README-documented case), extended COPY
  OUT/IN via Flush, error before COPY starts with Sync pending, error mid-COPY OUT with Sync
  pending, `Synchronize` refusing `Copy_In_Active`/`Copy_Both_Active` (correct: the server would
  discard it), `Synchronize` refusing simple-query COPY.
- Pipeline mode through the synchronous receive: `Pending_Syncs` counting, `Batch_Open` handling
  in `Complete_Synchronization`, error-in-earlier-batch versus error-in-open-batch (ordering of
  `ReadyForQuery` consumption makes `Pending_Syncs > 0` the right discriminator), Flush after Sync,
  `Exit_Pipeline_Mode` preconditions, `Enter_Pipeline_Mode` idempotence, Terminate clearing pipeline
  bookkeeping, `Require_No_Pipelined_Copy` closing the session on both typed and raw paths.
- `Require_Extended_Send`, `Execute_Portal`/`Bind_Portal` ordering, `Resume_Portal` after Sync
  (documented as unsupported), Recovery_Required gating of sends and receives, `Synchronize` from
  `Recovery_Required`.
- Startup message loop, both synchronous and scoped: AuthenticationOk before/after SCRAM phases,
  cleartext, SASL mechanism-list parsing (empty list, missing terminator, trailing bytes),
  SASLContinue/SASLFinal phase checks, server-signature verification and wiping on every exit,
  unknown methods -> `Unsupported_Authentication`, BackendKeyData length (8..260 covers 3.0 and 3.2
  keys), ErrorResponse -> `Database_Error`, Notice/ParameterStatus/NegotiateProtocolVersion
  tolerated, ReadyForQuery before AuthenticationOk rejected, SCRAM gs2 header "n,," (no
  channel-binding downgrade issue with SCRAM-SHA-256-PLUS servers), password/nonce wiping in
  `Wipe_Startup` on success, failure, cancel, and `Finish`.
- `Startup_TLS`: SSLRequest, single-byte response, refusal terminal, `Closed` on failure,
  Program_Error preconditions before any write.
- `Send_Cancel_Request` / `Encode_Cancel_Request`: secret 4..256 bytes consistent with the
  BackendKeyData check, distinct-transport check, no read of a response. `Client_Sockets.Cancel`
  closes the socket; `Cancel_TLS` transfers the socket into the TLS connection (`Take`), whose
  finalization closes it, and the handler's `Is_Open` guard prevents a double close.
- Scoped send/receive/startup operations: transport acquisition and release on success, failure,
  cancellation and `Rollback_Start`; retained exception re-raised by `Finish`; zero-length body
  completion; `Complete_Send` mirroring the synchronous simple-query transition; scoped
  `Execute_Portal` needing no state change because `Bind_Portal` already opened the batch.
- `Send_Command` state gating for Not_Started/Closed/Recovery_Required/Awaiting_Ready and COPY
  writes; Terminate resets.

## Observations not counted

- Policy, documented: `Resume_Portal` after Sync is refused even inside an explicit transaction
  where the portal survives; `Execute_Portal` requires a Bind in the same batch (a portal bound
  in an earlier batch of an open transaction is refused); a `CopyOutResponse` in pipeline mode
  closes the session; TLS refusal never falls back to plaintext.
- Deliberate leniency: `Receive_Message` (raw) accepts `ReadyForQuery` without a Sync; unknown
  backend tags during startup are skipped; NegotiateProtocolVersion is ignored (the client asks for
  3.2 and the 3.0 fallback has no client-visible difference beyond key length, which is handled);
  `Send_Command` accepts a `Query` or `Sync` in extended or COPY states (raw escape hatch, the
  typed API refuses them).
- `Receive_Query_Event` spec says "Session in Simple_Query_Active or Awaiting_Ready state"
  (client.ads:213) but the body accepts only `Simple_Query_Active` (775); `Awaiting_Ready` is not
  reachable on the simple-query path, so this is documentation drift only.
- After a transport failure or a cancelled scoped transfer that already moved bytes, the session
  keeps its pre-transfer state (for example `Ready` after half a Query frame was written). Nothing
  in the contract says the session becomes `Closed`, and callers are expected to discard a session
  whose transport failed; noted because a later `Send_*` would produce an unparseable stream, but
  not counted as a defect.
- `Unknown_Response` (including NotificationResponse 'A') is rejected inside `Receive_Copy_Event`.
  PostgreSQL only delivers notifications while reading a new command, never inside COPY, so no
  valid stream triggers it.
- Timeout semantics: synchronous entry points document a per-message timeout and the scoped
  startup documents a single deadline; the per-read re-arming inside `Framing.Read_Message` is
  PROTO-1 (excluded).
