# Adversarial verification: CLIENT findings

Method: every claim was re-derived from `src/flyology-postgres-client.ads` / `.adb`,
`src/flyology-postgres-protocol.adb`, `README.md` ("API outline", "Pipelined batches",
"Streaming COPY") and `tests/src/tests.adb`, then a runnable reproduction was written
under `tests/repros/src/` and executed with `cd tests/repros && ./run.sh repro_client_<n>`.
Each program asserts the CORRECT behaviour, so exit 1 with `BUG REPRODUCED` means the
finding stands on the current sources.

Both client receive paths are reachable from the public spec: the synchronous
`Receive_*` functions and the scoped `Flyology.Operations` overloads
(`Receive_Extended_Event (Set, Item, Timeout) return Receive_Operation`,
`Send_Query (Set, Item, SQL, Timeout) return Send_Operation`,
`Startup (Set, Item, ...) return Startup_Operation`). No existing file was modified;
only new `tests/repros/src/repro_client_*.adb` programs were added.

Severity rubric as given: P0 = memory/aliasing unsafety, security-relevant,
hang/deadlock in normal operation, or interop-breaking protocol violation; P1 = wrong
result or unexpected exception on valid input via a reachable path, or a documented
contract violated; P2 = edge-case incorrectness, wrong diagnostics, or contract drift
needing unusual input.

| ID | Verdict | Severity (discovery -> corrected) | Repro |
|----|---------|-----------------------------------|-------|
| CLIENT-1 | CONFIRMED | P1 -> P1 | `repro_client_1` |
| CLIENT-2 | CONFIRMED | P1 -> P1 (P0 defensible) | `repro_client_2` |
| CLIENT-3 | CONFIRMED | P2 -> P2 | `repro_client_3` |
| CLIENT-4 | CONFIRMED | P2 -> P2 | `repro_client_4` |
| CLIENT-5 | CONFIRMED | P2 -> P2 | `repro_client_5` |
| CLIENT-6 | CONFIRMED (behaviour); the "correct" target state is a design choice | P2 -> P2 | `repro_client_6` |

---

### CLIENT-1: Scoped `Receive_Extended_Event` derives `Sync_Pending` from the state instead of `Pending_Syncs`

**Verdict:** CONFIRMED.

Refutation attempts that failed:
- *Maybe the two expressions can never differ.* They differ whenever a later batch is
  open while an earlier one is outstanding. `Send_Command` (Parse/Bind/Describe/
  Execute/Close branch) moves `Awaiting_Ready` to `Extended_Query_Active` while
  `Pending_Syncs` stays > 0, so the scoped flag is `False` and the synchronous flag is
  `True` for exactly the same wire bytes.
- *Maybe the scoped expression is the correct one.* No: `tests/src/tests.adb`
  (`Test_Pipelined_Client_State`, "a failed pipelined batch needs no separate recovery
  Sync") and README "Pipelined batches" ("Each batch's own Sync contains its failure ...
  so the session does not enter `Recovery_Required`") both codify the `Pending_Syncs`
  behaviour. The scoped path is the deviation.
- *Maybe the scoped path is unreachable in pipeline mode.* `Start_Receive` accepts
  `Extended_Query_Active` and `Awaiting_Ready`, and nothing gates it on `Pipelined`.
  The reproduction reaches it through the public spec only.

**Severity:** P1 (unchanged). Unexpected `Program_Error` on valid pipelined traffic via a
reachable public path, and a documented contract ("the session does not enter
`Recovery_Required`") violated.

**Repro:** `tests/repros/src/repro_client_1.adb`

**Output** (`./run.sh repro_client_1`, exit status 1):

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

The control section runs the identical byte stream through the synchronous
`Receive_Extended_Event` and passes, so the divergence is entirely in the scoped path.

**Description:** `Start_Receive` in `src/flyology-postgres-client.adb` sets
`Operation.Sync_Pending := Item.Current_State = Awaiting_Ready`, whereas the synchronous
`Receive_Extended_Event` uses `Item.Pending_Syncs > 0`. `Apply_Extended_Event` uses that
flag to decide whether a response belongs to an earlier, already Sync-terminated batch.
In pipeline mode, once the next batch's Parse/Bind has been written the state is
`Extended_Query_Active` while the earlier batch's Sync is still outstanding, so a scoped
receive misattributes the earlier batch's `ErrorResponse` to the open batch: the session
is driven to `Recovery_Required` and `Bound_In_Cycle` is cleared. The open batch's
already-bound portal can then no longer be executed (`Program_Error`), and the earlier
batch's `ReadyForQuery` — the very next byte on the wire — can no longer be received
(`Program_Error`, "recovery requires Sync before receiving"). The only escape is an extra
`Synchronize`, which prematurely closes the open batch and desynchronises the caller's
batch accounting. The same flag also gates `Portal_Is_Suspended` for `CommandComplete`
and `PortalSuspended`, so an earlier batch's `PortalSuspended` received through the
scoped path likewise corrupts the open batch's portal state.

---

### CLIENT-2: Extended COPY IN with a Sync pipelined before `CopyInResponse`

**Verdict:** CONFIRMED, and the state damage is observable without a real server.

Server behaviour used (from PostgreSQL sources, stated here so reachability can be
judged):
- `src/backend/commands/copyfromparse.c`, `CopyGetData`: while the backend is in copy-in
  mode it consumes and **discards** `Flush` and `Sync` — "Ignore Flush/Sync for the
  convenience of client libraries (such as libpq) that may send those without noticing
  that the command they just sent was COPY." The COPY runs inside
  `exec_execute_message`, so a Sync written straight after Execute never reaches the main
  loop and never produces a `ReadyForQuery`.
- `src/interfaces/libpq/fe-exec.c`, `PQputCopyEnd`: after writing `CopyDone` libpq writes
  a **second** `Sync` when the COPY was issued in extended-query mode. `PQsendQueryParams`
  already appended a Sync after Execute. So the sequence libpq actually puts on the wire
  is `P B [D] E S d… c S` and it expects exactly **one** `ReadyForQuery`.

The reproduction queues exactly the bytes a real backend sends for that sequence
(`CopyInResponse`, then `CommandComplete` + one `ReadyForQuery`) and shows the library
ends one `ReadyForQuery` short. No hang or timeout is needed to demonstrate it; the
program prints the frontend tag sequence it produced (`PBESdcS`) so it can be compared
against libpq's.

Refutation attempts that failed:
- *Maybe the README forbids this order.* README "Streaming COPY" says "COPY IN and the
  writable half of COPY BOTH send it after local `CopyDone`/`CopyFail`" — it says where to
  send *the* Sync, not that an earlier one is illegal, and the API accepts the earlier one
  (`Synchronize` from `Extended_Query_Active`, and `Receive_Extended_Event` accepts
  `Awaiting_Ready`). A generic extended-query driver following the README's own
  Prepare/Bind/Execute/Synchronize example cannot know in advance that the statement is a
  COPY — which is precisely the case the backend's leniency exists for.
- *Maybe COPY OUT is affected the same way and the model is therefore right.* It is not.
  A COPY OUT never reads from the frontend, so the pipelined Sync is honoured; the model
  is only wrong for the writable direction (COPY IN, and COPY BOTH's writable half).
- *Maybe there is an API-level escape.* There is none. After `CommandComplete` the state
  is `Awaiting_Ready`, and `Synchronize` and `Send_Command` both refuse every tag except
  `Terminate` from `Awaiting_Ready` outside pipeline mode.

**Severity:** P1 (unchanged), with P0 defensible. It is a wrong result on valid input via
a reachable path (the phantom outstanding batch), and on a real socket it degrades to a
permanent block: in variant (b) the backend waits for a Sync that no API call can send,
and the client's next receive blocks until `Timeout_Error` with no recovery short of
discarding the connection. A maintainer who classes "the libpq COPY IN sequence" as
normal operation should treat this as P0.

**Repro:** `tests/repros/src/repro_client_2.adb`

**Output** (`./run.sh repro_client_2`, exit status 1):

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

**Description:** `Send_Command` counts every `Sync` in `Pending_Syncs`, and
`Apply_Extended_Event` passes that count into `Enter_Copy` as `Copy_Sync_Pending` when a
`CopyInResponse` arrives, so the session models the Sync that the backend has already
discarded as one that will still be answered. With the libpq ordering (Sync after
Execute, Sync after `CopyDone`) the client counts two outstanding batches and the server
sends one `ReadyForQuery`: `Receive_Copy_Event` retires one Sync and leaves the session
permanently in `Awaiting_Ready` with `Pending_Synchronizations = 1`, where
`Send_Command`, `Prepare_Statement`, `Send_Query` and `Synchronize` all refuse and
`Receive_Extended_Event` blocks until `Timeout_Error`; `Exit_Pipeline_Mode` bookkeeping is
off by one for the same reason. If the caller instead trusts
`Pending_Synchronizations` and omits the second Sync, the backend completes the COPY,
sends `CommandComplete`, and then waits for a message the client can no longer write —
an unrecoverable block. The fix belongs where the writable COPY direction starts: a Sync
outstanding when `CopyInResponse` (or the writable half of `CopyBothResponse`) arrives
must be dropped from `Pending_Syncs` and must not set `Copy_Sync_Pending`. COPY OUT is
correct as it stands.

---

### CLIENT-3: Scoped `Send_Query` bypasses the pipeline-mode rejection

**Verdict:** CONFIRMED.

Refutation attempts that failed:
- *Maybe `Start_Send` re-checks.* It does not; `Start_Send` writes the encoded message
  directly and never passes through `Send_Command`, which is where the raw path's
  "simple queries are not allowed in Postgres pipeline mode" check lives.
- *Maybe the state check makes it unreachable.* The scoped overload only requires
  `Current_State = Ready`, which is exactly the state pipeline mode starts from and
  returns to between batches.

**Severity:** P2 (unchanged). A documented rejection is missing
(`Enter_Pipeline_Mode`: "Simple queries are rejected while the mode is active"; README
"Pipelined batches" repeats it), but nothing invalid reaches the wire and no counter is
corrupted: the window is only reachable with zero outstanding batches, and
`Apply_Query_Event`'s `ReadyForQuery` branch sets `Ready` directly without touching
`Pending_Syncs`. That is contract drift plus an inconsistency between the two entry
points, not a wrong result — hence P2 rather than P1.

**Repro:** `tests/repros/src/repro_client_3.adb`

**Output** (`./run.sh repro_client_3`, exit status 1):

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

**Description:** The scoped `Send_Query` overload in
`src/flyology-postgres-client.adb` checks only `Item.Current_State /= Ready` and omits the
`Item.Pipelined` guard that both the synchronous `Send_Query` and `Send_Command` apply.
On the same session and in the same state, the synchronous call raises `Program_Error`
while the scoped call writes the `Query` frame and leaves the session in
`Simple_Query_Active` with `In_Pipeline_Mode` still `True`. The documented promise that
simple queries are rejected while pipeline mode is active is therefore only honoured by
one of the two public entry points.

---

### CLIENT-4: Extended DataRow column check uses whichever `RowDescription` arrived last

**Verdict:** CONFIRMED.

Refutation attempts that failed:
- *Maybe the spec sanctions it.* `client.ads` says "the column count is checked only
  against a description the server actually sent". The server did send this description —
  for a different prepared statement. The sentence is about tolerating a missing
  description, not about matching descriptions to objects, and the resulting exception on
  a legal message stream is not a defensible reading.
- *Maybe the stream is not legal.* It is: `Describe_Statement ("two")` legitimately
  produces `ParameterDescription` + `RowDescription`, and an `Execute` of an unrelated
  portal in the same batch legitimately produces bare `DataRow`s. The reproduction queues
  the backend's replies in exact message order.
- *Maybe `Has_Row_Description` is cleared in between.* It is cleared only by
  `CommandComplete`, `EmptyQueryResponse`, `NoData`, `ErrorResponse` and `ReadyForQuery`,
  none of which occurs between the Describe reply and the Execute reply.

**Severity:** P2 (unchanged), close to the P1 boundary. It is an unexpected exception on a
valid stream via a reachable path, but it needs the unusual shape of describing one
object while executing another inside a single batch, which is what the P2 clause
("needing unusual input") covers. Note the blast radius once triggered: `Protocol_Error`
propagates out of `Receive_Extended_Event` without clearing the stale description, so
every subsequent `DataRow` of that portal fails the same way and the batch's result set
becomes unreadable.

**Repro:** `tests/repros/src/repro_client_4.adb`

**Output** (`./run.sh repro_client_4`, exit status 1):

```
  -- Receive_Extended_Event raised Protocol_Error: DataRow column count does not match RowDescription
  FAILED: a RowDescription for another statement does not invalidate the executed portal's rows
  FAILED: the executed portal's single-column DataRow is delivered
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:** `Apply_Extended_Event` stores `Described_Columns` /
`Has_Row_Description` for every `RowDescription` regardless of which statement or portal
it describes, and validates every subsequent `DataRow` against it. In a batch that does
`Parse "one"`, `Parse "two"`, `Bind "p1" -> "one"`, `Describe_Statement "two"`,
`Execute "p1"`, `Flush`, the server's `RowDescription` for the two-column statement "two"
arrives before the one-column rows of portal "p1", and `Receive_Extended_Event` raises
`Protocol.Protocol_Error` ("DataRow column count does not match RowDescription") on a
message sequence PostgreSQL legitimately produced. The same happens with
`Describe_Portal (P2)` followed by `Execute_Portal (P1)`. The check needs to be bound to
the portal whose Execute is being answered, or dropped for descriptions that do not
belong to the executed portal.

---

### CLIENT-5: One session-wide `Portal_Is_Suspended` flag rejects valid multi-portal sequences

**Verdict:** CONFIRMED, both variants.

Refutation attempts that failed:
- *Maybe the spec documents the restriction.* `client.ads` `Resume_Portal` says only
  "Sync ends the batch that owns the portal, so only a batch whose responses arrive
  through Flush can be resumed" — the reproduction stays inside one Flush-driven batch,
  i.e. inside the case the spec describes as resumable.
- *Maybe `Bind_Portal` correctly resets the flag.* It sets `Portal_Is_Suspended := False`
  unconditionally, which is exactly the second half of the defect: binding an unrelated
  portal makes the session forget that another portal is still suspended server-side.
- *Maybe the protocol forbids two live portals in one batch.* It does not; portals live
  until the transaction (or the implicit transaction closed by Sync) ends.

**Severity:** P2 (unchanged). Valid sequences are refused before anything is written, so
the transport is never desynchronised; the caller has to fall back to `Send_Command` with
a raw Execute message. That is edge-case incorrectness in local ordering checks.

**Repro:** `tests/repros/src/repro_client_5.adb`

**Output** (`./run.sh repro_client_5`, exit status 1):

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

**Description:** The session tracks suspension with a single Boolean
`Portal_Is_Suspended` that carries no portal name. `Execute_Portal` refuses any execute
while it is set, and `Bind_Portal` clears it unconditionally. Consequently, after
`Bind p1`, `Bind p2`, `Execute p1 (Maximum_Rows => 1)` and a `PortalSuspended`,
`Execute_Portal (Session, "p2")` raises `Program_Error` ("use Resume_Portal for a
suspended portal") although p2 is a bound, never-executed portal; and after a suspended
p1 is followed by `Bind p2` / `Execute p2`, `Resume_Portal (Session, "p1")` raises
`Program_Error` ("no suspended Postgres portal can be resumed") although p1 is still
suspended on the server. Both sequences are legal extended-query traffic inside one
Flush-driven batch — the case `client.ads` describes as the resumable one.

---

### CLIENT-6: Startup failure state is inconsistent between the plaintext and TLS paths

**Verdict:** CONFIRMED as described. The observable behaviour is exactly as reported; the
only soft part of the finding is which state is the *correct* one, which is a design
choice rather than a documented promise (see Severity).

Refutation attempts that failed:
- *Maybe only the TLS-negotiation failure is meant to be terminal.* README "API outline"
  says of `Startup_TLS`: "Any negotiation **or encrypted-startup** failure permanently
  closes the session state". The identical authentication `ErrorResponse` therefore
  produces `Closed` on a TLS session and `Not_Started` on a plaintext one.
- *Maybe the scoped path already handles it.* It does not: `Fail_Startup` sets `Closed`
  only when `Item.Kind = TLS_Negotiation_Stage`, so the scoped authentication failure
  leaves `Not_Started` as well (confirmed in the second half of the reproduction).
- *Maybe the retry is harmless.* `Complete_Startup` accepts `Not_Started |
  TLS_Negotiated`, so the retry writes a full 56-byte startup packet before failing; on a
  real connection that is a write to a socket the server closed after the ErrorResponse,
  and the failure surfaces as a transport error rather than a `Program_Error`
  precondition.

**Severity:** P2 (unchanged). No documented sentence promises `Closed` for a rejected
*plaintext* startup, so this is contract drift and an inter-path inconsistency rather
than a violated promise. The reproduction asserts `Closed` on the precedent set by
`Startup_TLS` and by the scoped TLS stage; if the maintainers prefer a different terminal
state name, the actionable part of the finding is still that a rejected session must stop
accepting `Startup` and must stop writing to the connection.

**Repro:** `tests/repros/src/repro_client_6.adb`

**Output** (`./run.sh repro_client_6`, exit status 1):

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

(The `PROGRAM_ERROR: memory transport input is exhausted` line comes from the exhausted
in-memory transport *after* the retried startup packet was written; the 56 written bytes
are the evidence that the retry was accepted.)

**Description:** `Complete_Startup`'s `'E'` branch raises `Database_Error` without
touching `Current_State`, so a session whose authentication the server rejected stays in
`Not_Started` on both the synchronous and the scoped plaintext paths, while `Startup_TLS`
and the scoped `TLS_Negotiation_Stage` set `Closed` for the same class of failure. A
caller that dispatches on `State` cannot distinguish "never started" from "rejected", and
`Complete_Startup` accepts a second `Startup` on that session (`Current_State not in
Not_Started | TLS_Negotiated`), writing another startup packet to a connection the server
closed after the ErrorResponse; the retry then fails with a transport error instead of a
clean `Program_Error` precondition.

---

## Notes for the findings document

- CLIENT-1 and CLIENT-3 are the same class of defect: the scoped
  (`Flyology.Operations`) overloads reimplement the synchronous entry points' guards and
  drop one each. A sweep of `Start_Send` / `Start_Receive` / `Start_Startup_Operation`
  against their synchronous counterparts is worth doing beyond these two instances.
- CLIENT-2 is the only finding whose consequence reaches a blocking read on a real
  socket; it is also the one whose triggering sequence is what libpq puts on the wire.
- No finding in this batch involves memory or aliasing unsafety, so none is P0 on those
  grounds.
