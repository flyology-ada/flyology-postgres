# SERVER verification report (adversarial)

Method: every candidate was re-derived from the sources with `rg`/`sed`/`cat`
before any repro was written. Runtime claims were checked against the exact
Flyology release the lockfile pins (`alire/alire.lock` commit
`bd95746d…`, materialised at
`~/.local/share/alire/releases/flyology_bd95746d/src/`). Every claim that
depends on real-backend or libpq behaviour was checked against a PostgreSQL
checkout at `REL_18_BETA1-2983-g9fd46ee9347` (`PG_VERSION "19devel"`) found on
this machine, reading only — the exact file and line are cited in each section.

Nine reproduction programs were added under `tests/repros/src/repro_server_*.adb`
and run with `cd tests/repros && ./run.sh repro_server_<n>`. Two candidates are
duplicates of already-verified PROTO findings and got no new program. Nothing
under `src/`, `sql/`, `examples/`, or `tests/src/` was touched, nothing was
committed, and no full suite was run.

Seven of the nine non-duplicate candidates survived refutation intact. One
(SERVER-7) is **partially confirmed**: its second half is refuted in its stated
form and replaced by what actually happens on the wire. One severity is raised
(SERVER-11, P2 → P1) and one supporting mechanism in the discovery report is
corrected (SERVER-1: the failure is not a hang, it is a prompt whole-server
termination — which is worse, not better).

Rubric used, as given: P0 = memory/aliasing unsafety, security-relevant,
hang/deadlock in normal operation, or interop-breaking protocol violation;
P1 = wrong result or unexpected exception on valid input via a reachable path,
or a documented contract violated; P2 = edge-case incorrectness, wrong
diagnostics, or contract drift needing unusual input.

Every repro that could carry one includes a **control case** that passes on
today's sources, so a failure cannot be blamed on the harness.

---

### SERVER-1: the first `Read_Initial` runs in `Run_Session`'s declarative part, so any client-caused failure on the first packet escapes the session handlers and kills the whole server

**Verdict:** CONFIRMED — with the mechanism corrected. The consequence the
discovery predicted (admission stops for the entire server) is real and
reproduced; its explanation of *how* Serve behaves afterwards is wrong in the
victim's favour, and the corrected behaviour is more severe, not less.

Refutation attempts and what they found:

- *Is the Ada claim right — do a subprogram's handlers really not cover its own
  declarative part?* Yes. `Initial` is the object declared at
  `src/flyology-postgres-server.adb:371-372` and initialised by
  `Server_Sessions.Read_Initial (Client, Startup_Timeout)`; the handlers at
  `:524-548` belong to the handled sequence of statements and cannot catch it.
  `Process_Connection` (`:551-563`) has no handler at all. The second
  `Read_Initial` inside the loop (`:403`) *is* covered, so this is an
  inconsistency inside one subprogram, not a design choice.
- *Does an escaped handler exception really stop the whole server, or does the
  runtime isolate it per connection?* It stops the server. In
  `flyology-io-structured_servers.adb:453-460` the worker does
  `Handle (...) exception … when Event : others => Report (Handler_Callback,
  Event)`, and `Report` (`:406-410`) is `Item.State.Record_Failure (…)` followed
  by `Stop_Accepting`, i.e. `Item.Accept_Stop.Request` (`:225-228`). Every
  worker's next `Accept_Connection` then raises `Operation_Cancelled` and sets
  `Stop_Worker := True` (`:444-445`).
- *Does `Serve` then block until someone calls `Request_Shutdown`, as the
  discovery claims?* **No — this part of the discovery is wrong.**
  `Record_Failure` ends with `Phase := Policy.Phase_After_Stop (Phase);`
  (`flyology-io-structured_servers.adb:126`), which moves the lifecycle to
  `Stop_Requested`, so the `Await_Stop` at `:508` is released immediately.
  `Serve` drains, closes the owned listener, and raises `Server_Failed`
  (`:535-537`) on its own. The repro confirms this empirically: the follow-up
  client gets `ECONNREFUSED` (errno 61) — the listener is already closed —
  *before* the program calls `Request_Shutdown`.
- *Are the triggering exceptions reachable from ordinary, non-malicious
  clients?* Yes, three ways, all through
  `Flyology.IO.Connections.Receive_Exactly`'s documented contract
  (`flyology-io-connections.ads:286-295`): `Device_Error` "the peer closes
  early" (a TCP health probe, `nc -z`, a port scanner); `Timeout_Error` (a
  client silent for `Startup_Timeout`); and `Protocol.Protocol_Error` from
  `Wire.Valid_Initial_Length` — an HTTP probe's first four bytes `GET ` are
  0x47455420 = 1 195 725 856, far above `Maximum_Frame_Size`. The repro uses
  the first, which is the cheapest.

**Severity:** **P0** (unchanged). Any peer that can complete a TCP handshake
can terminate the entire server with zero bytes sent — a remote,
pre-authentication denial of service.

**Repro:** `tests/repros/src/repro_server_1.adb`

**Output** (`./run.sh repro_server_1`, exit status 1):

```
  -- listening on 127.0.0.1: 49263
  -- control client received a backend message tagged 'R'
  -- probe 1 connected and closed without sending a byte
  -- client after the probe failed: FLYOLOGY.IO.SOCKETS.SOCKET_ERROR: connect failed [errno=61]
  -- Serve terminated with REPRO_SERVER_1.TEST_SERVER.STRUCTURED.SERVER_FAILED: raised FLYOLOGY.IO.DEVICE_ERROR : connection closed while receiving
  ok: control: an ordinary client is served before any misbehaving one connects (harness sanity check)
  FAILED: after a client connects and disconnects without sending anything, the listener still serves the next connection
  FAILED: a client that connects and closes early does not make Serve raise a server failure
BUG REPRODUCED: 2 failed expectation(s)
```

The control client is served (`R` = AuthenticationRequest), the probe connects
and closes without sending a byte, and the identical client that follows can no
longer even connect. Reproduced identically on four consecutive runs.

**Description:** `Flyology.Postgres.Server.Run_Session` initialises its
`Initial : Protocol.Initial_Request` object from
`Server_Sessions.Read_Initial (Client, Startup_Timeout)` in its declarative part
(`src/flyology-postgres-server.adb:371-372`). In Ada an exception raised while
elaborating a declarative part is not covered by that subprogram's own
handlers, so the `Protocol_Error` and catch-all handlers at `:524-548` — which
exist precisely to convert a client-caused failure into a FATAL `ErrorResponse`
and return normally, and which do cover the identical `Read_Initial` at `:403` —
never run. `Process_Connection` (`:551-563`) adds no handler, so the exception
reaches the Flyology structured worker, whose
`when Event : others => Report (Handler_Callback, Event)`
(`flyology-io-structured_servers.adb:457-459`) records a server failure, moves
the lifecycle phase to `Stop_Requested` and requests `Accept_Stop`. Every worker
leaves its accept loop, `Serve` closes the listener and raises `Server_Failed`.
The reachable triggers are all ordinary client behaviour that PostgreSQL merely
logs and drops: a connect-then-close probe (`Device_Error`), a client that stays
silent past `Startup_Timeout` (`Timeout_Error`), and a non-PostgreSQL first
packet such as an HTTP request line (`Protocol_Error`). For the malformed-length
case the client is additionally closed on with no FATAL `ErrorResponse`, unlike
every later protocol error. Moving the first read into the statement part, or
wrapping `Process_Connection`'s body, closes it.

---

### SERVER-2: `TLS_Required` rejects a plaintext `CancelRequest`, so psql's Ctrl-C never cancels anything

**Verdict:** CONFIRMED, including both client-side facts, verified in the
PostgreSQL tree rather than from memory.

Refutation attempts:

- *Is the ordering really wrong, or does the cancel check run first somewhere
  else?* It is wrong. `src/flyology-postgres-server.adb:406-414` sends
  `FATAL 08004 "TLS is required"` and `return`s; the
  `Protocol.Kind (Initial) = Protocol.Cancel_Request` test that calls
  `Context.Router.Route` is at `:416-419`, after it. There is no earlier cancel
  path.
- *Does the real backend also gate cancel on encryption?* No.
  `ProcessStartupPacket` (`src/backend/tcop/backend_startup.c:575-580`) does
  `if (proto == CANCEL_REQUEST_CODE) { ProcessCancelRequestPacket(...);
  goto fail; }` **before** the `NEGOTIATE_SSL_CODE` branch at `:582`, with no
  `hostssl`-style condition anywhere in that path.
- *Does psql 17/18/19 still send the cancel in plaintext, or has it moved to the
  new encrypted API?* Still plaintext. `src/fe_utils/cancel.c:153-175`
  `handle_sigint` calls `PQcancel(cancelConn, errbuf, sizeof(errbuf))` (and again
  at `:211` in the Windows handler), and `PQcancel` is introduced in
  `src/interfaces/libpq/fe-cancel.c:528` as
  `"PQcancel: old, non-encrypted, but signal-safe way of requesting query
  cancel"` — it opens a raw `socket()` and writes the cancel packet with no
  SSLRequest, because the handler must stay async-signal-safe. Only
  `PQcancelCreate`/`PQcancelBlocking` negotiate TLS, and psql's SIGINT path does
  not use them.
- *Is the discovery's characterisation of the policy contract fair?*
  `src/flyology-postgres-server.ads:85` says "@param Policy Whether plaintext
  **startup** is allowed or rejected", and `:77-78` frames `TLS_Required` in
  terms of startup. A CancelRequest is not a startup; the implementation is
  broader than its own specification.

**Severity:** **P1** (unchanged), and the P0 case is worth stating: under the
rubric's "interop-breaking protocol violation" this is arguable P0, because a
standard, universally used psql feature silently stops working against the
policy the repository's own test server ships with
(`tests/src/postgres_test_server.adb:287` uses `TLS_Required`). It is kept at P1
because nothing is corrupted and no connection is broken — the query simply runs
to completion instead of being cancelled.

**Repro:** `tests/repros/src/repro_server_2.adb`

**Output** (`./run.sh repro_server_2`, exit status 1):

```
  -- Policy => TLS_Allowed,  plaintext CancelRequest -> <silent close>
  -- Policy => TLS_Required, plaintext CancelRequest -> 45 00 00 00 2b 53 46 41 54 41 4c 00 56 46 41 54 41 4c 00 43 30 38 30 30 34 00 4d 54 4c 53 20 69 73 20 72 65 71 75 69 72 65 64 00 00   (E   +SFATAL VFATAL C08004 MTLS is required  )
  ok: control: under TLS_Allowed a plaintext CancelRequest is routed and the connection closes silently
  FAILED: under TLS_Required a plaintext CancelRequest is still routed and closed silently, as PostgreSQL handles CANCEL_REQUEST_CODE before any SSL negotiation
  -- psql's Ctrl-C (fe_utils/cancel.c -> PQcancel, the 'old, non-encrypted, signal-safe' path) therefore never cancels anything against a TLS_Required server
BUG REPRODUCED: 1 failed expectation(s)
```

The program runs two servers on loopback ports differing only in `Policy`, so
the control (`TLS_Allowed`, silent close as PostgreSQL does) isolates the gate as
the sole cause. It uses a stub `Flyology.IO.TLS.Provider` that raises if
touched — proving the TLS machinery is never reached on this path.

**Description:** `Run_Session` applies the `TLS_Required` gate at
`src/flyology-postgres-server.adb:406-414` before it inspects the initial
request's kind at `:416`, so a `CancelRequest` that arrives on a plaintext
connection is answered with `FATAL` SQLSTATE `08004` "TLS is required" and never
reaches `Context.Router.Route`. PostgreSQL handles `CANCEL_REQUEST_CODE` first
and unconditionally (`src/backend/tcop/backend_startup.c:575-580`), because a
cancel packet carries no credential beyond the secret key it must already know.
The practical consequence is that Ctrl-C in psql — and every driver built on
`PQcancel`, which `src/fe_utils/cancel.c:165` still uses from its signal handler
and which `src/interfaces/libpq/fe-cancel.c:528` documents as the
"old, non-encrypted, but signal-safe" path — is answered with an error and
discarded against any server configured `TLS_Required`, the policy this
repository's own test server ships. The library's own specification is narrower
than its behaviour: `server.ads:85` scopes `Policy` to plaintext *startup*. The
fix is to move the `Cancel_Request` branch above the TLS gate.

---

### SERVER-3: NegotiateProtocolVersion carries the bare minor number instead of the full protocol version word

**Verdict:** CONFIRMED, with a stronger reachability argument than the discovery
gave.

Refutation attempts:

- *Could the protocol documentation justify sending the bare minor?* Its wording
  invites that reading and is the likely origin of the bug:
  `doc/src/sgml/protocol.sgml:5449-5455` describes the field as
  "Newest minor protocol version supported by the server for the major protocol
  version requested by the client." But **both reference implementations treat
  it as a full `ProtocolVersion`**, and interop is decided by them:
  * server: `SendNegotiateProtocolVersion` does
    `pq_sendint32(&buf, FrontendProtocol)`
    (`src/backend/tcop/backend_startup.c:965`), where `FrontendProtocol` is a
    `ProtocolVersion` set to `Min(proto, PG_PROTOCOL_LATEST)` at `:734` and
    `PG_PROTOCOL(m,n)` is `((m) << 16) | (n)`
    (`src/include/libpq/pqcomm.h:89`, `PG_PROTOCOL_LATEST = PG_PROTOCOL(3,2)`
    at `:95`).
  * client: `pqGetNegotiateProtocolVersion3` reads it into `their_version` and
    rejects it with
    `"received invalid protocol negotiation message: server requested downgrade
    to pre-3.0 protocol version"` when `their_version < PG_PROTOCOL(3, 0)`
    (`src/interfaces/libpq/fe-protocol3.c:1482-1486`). A bare `2` is `0x00000002`,
    far below `0x00030000`, so **every** `v` message this library emits aborts a
    modern libpq connection.
- *Is the path really unreachable with shipping clients, as the discovery
  concedes?* Less so than it says. In the PostgreSQL 19 beta tree examined here,
  libpq **defaults** `conn->max_pversion` to `PG_PROTOCOL_GREASE` =
  `PG_PROTOCOL(3,9999)` "to test negotiation. The server should automatically
  downgrade to a supported version."
  (`src/interfaces/libpq/fe-connect.c:2149-2156`;
  `src/include/libpq/pqcomm.h:115`). Such a client sends minor 9999, this server
  answers `00 00 00 02`, and libpq aborts. That default is annotated
  "for 19beta only. It will be reverted before RC1", so it is not a permanent
  fact — but it shows the path is live, not theoretical.
- *Does the `.ads` mislead a future maintainer?* Yes: the parameter is named
  `Latest_Minor : Protocol.UInt32`
  (`src/flyology-postgres-server_sessions.ads:85-92`), baking the misreading
  into the public API, and `Run_Session` passes the literal `2`
  (`src/flyology-postgres-server.adb:444-446`).

**Severity:** **P1** (unchanged). Not P0 today only because stable libpq caps
itself at 3.2 and so never provokes the message; the moment anything does, the
connection is aborted, which is the P0 shape.

**Repro:** `tests/repros/src/repro_server_3.adb`

**Output** (`./run.sh repro_server_3`, exit status 1):

```
  -- Send_Negotiate_Protocol (Latest_Minor => 2) emitted: 76 00 00 00 0c 00 00 00 02 00 00 00 00 
  -- PostgreSQL would emit:                             76 00 00 00 0c 00 03 00 02 00 00 00 00 
  ok: a NegotiateProtocolVersion frame of the documented size is sent
  -- version word on the wire: 00 00 00 02 
  FAILED: the version word is the full ProtocolVersion 00 03 00 02, as PostgreSQL's SendNegotiateProtocolVersion emits and libpq's pqGetNegotiateProtocolVersion3 requires (>= PG_PROTOCOL(3,0))
  ok: the unrecognized-option count is zero
BUG REPRODUCED: 1 failed expectation(s)
```

libpq cannot be run here, so the repro asserts the exact wire bytes the two
reference implementations cited above require; the frame tag, length and
option-count checks pass, isolating the failure to the version word.

**Description:** `Server_Sessions.Send_Negotiate_Protocol`
(`src/flyology-postgres-server_sessions.adb:150-159`) encodes its
`Latest_Minor` parameter directly as the first Int32 of the `v` frame, and
`Run_Session` passes `2` (`src/flyology-postgres-server.adb:444-446`), so the
wire value is `00 00 00 02`. PostgreSQL's `SendNegotiateProtocolVersion` sends a
full `ProtocolVersion` — `pq_sendint32(&buf, FrontendProtocol)`,
`src/backend/tcop/backend_startup.c:965`, with `PG_PROTOCOL(3,2) = 0x00030002` —
and libpq reads the field back as a `ProtocolVersion`, failing with
"server requested downgrade to pre-3.0 protocol version" for anything below
`PG_PROTOCOL(3,0)` (`src/interfaces/libpq/fe-protocol3.c:1482-1486`). Since this
library sends the message only when a client requests minor > 2
(`server.adb:444`), every `v` message it ever emits is malformed and aborts the
connection it was meant to rescue. The `Latest_Minor` parameter name in
`server_sessions.ads:85-92` records the misreading in the public API, so the fix
is a renamed parameter carrying `major << 16 | minor` as well as a corrected
value.

---

### SERVER-4: `Read_Copy_Command` rejects Sync/Flush during COPY IN, which is what libpq's extended-query COPY leaves in the stream, and documents results its type cannot represent

**Verdict:** CONFIRMED, both halves.

Refutation attempts:

- *Can `Frontend_Copy_Kind` represent the documented Flush/Sync/Terminate
  results at all?* No. It is
  `(Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail)`
  (`src/flyology-postgres-protocol.ads:217-218`), and
  `Decode_Frontend_Copy` ends `when others => raise Protocol_Error with
  "message is not a frontend COPY command"`
  (`src/flyology-postgres-protocol.adb:869-870`). The `.ads` sentence
  "@return CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate event"
  (`src/flyology-postgres-server_sessions.ads:32`) is unimplementable as written.
- *Does the real backend really tolerate it, or is the discovery paraphrasing?*
  It tolerates it, in two places. `src/backend/commands/copyfromparse.c:291-296`
  admits `PqMsg_Flush` and `PqMsg_Sync` to the message-type whitelist during
  COPY from stdin, and `:326-335` handles them with
  `/* Ignore Flush/Sync for the convenience of client libraries (such as libpq)
  that may send those without noticing that the command they just sent was
  COPY. */ goto readmessage;`.
- *Is the path reachable, or only via hand-written frontends?* Reachable.
  libpq's `PQexecParams`/`PQsendQueryParams` pipeline Parse/Bind/Describe/
  Execute/Sync in one flush, so when the statement turns out to be
  `COPY … FROM STDIN` the trailing `Sync` is already queued ahead of the first
  `CopyData` — exactly the situation the PostgreSQL comment names. Drivers that
  always use the extended protocol (psycopg3 among them) hit it as their normal
  COPY path.
- *Is the damage confined to the test server?* No. Three in-repo consumers call
  the same helper: `src/flyology-postgres-replication-managed_primary.adb:55`,
  `src/flyology-postgres-replication-base_backups-server_sessions.adb:204`, and
  `tests/src/postgres_test_replication_server.adb:215`.

**Severity:** **P1** (unchanged). It is a wrong exception on valid input through
a reachable client path, plus a documented contract that cannot be honoured.
Not raised to P0 because the affected COPY flavour is the extended-protocol one;
psql's `\copy` uses a simple `Query` and is unaffected.

**Repro:** `tests/repros/src/repro_server_4.adb`

**Output** (`./run.sh repro_server_4`, exit status 1):

```
  -- queued frontend bytes: 53 00 00 00 04 | 64 00 00 00 06 61 0a 
  -- Read_Copy_Command raised FLYOLOGY.POSTGRES.PROTOCOL.PROTOCOL_ERROR: message is not a frontend COPY command
  FAILED: a Sync arriving during COPY IN does not make Read_Copy_Command raise; PostgreSQL ignores Flush/Sync there (copyfromparse.c)
  FAILED: the CopyData that follows the ignored Sync is delivered to the COPY handler
  -- Server.Run_Session turns this into FATAL 08P01 'message is not a frontend COPY command' and drops the connection (src/flyology-postgres-server.adb:524-535)
  -- Protocol.Frontend_Copy_Kind is (Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail) only, so the Flush, Sync and Terminate results promised by server_sessions.ads:32 are unrepresentable
BUG REPRODUCED: 2 failed expectation(s)
```

The queued bytes are exactly what libpq leaves in the stream: `S` (Sync) then
`d` (CopyData).

**Description:** `Server_Sessions.Read_Copy_Command`
(`src/flyology-postgres-server_sessions.adb:70-75`) forwards the next frontend
message to `Protocol.Decode_Frontend_Copy`, whose `when others` arm raises
`Protocol_Error "message is not a frontend COPY command"`
(`src/flyology-postgres-protocol.adb:869-870`). A `Sync` — which libpq's
`PQexecParams` has already queued behind the Execute that started the COPY — is
therefore rejected, `Run_Session`'s handler turns it into
`FATAL 08P01` (`src/flyology-postgres-server.adb:524-535`) and the connection is
dropped, where PostgreSQL explicitly ignores `Flush` and `Sync` in the same
position and reads the following `CopyData`
(`src/backend/commands/copyfromparse.c:326-335`). Separately, the operation's
own specification promises "CopyData, CopyDone, CopyFail, Flush, Sync, or
Terminate event" (`src/flyology-postgres-server_sessions.ads:32`) while
`Protocol.Frontend_Copy_Kind` has only the first three values, so half the
documented result set is unrepresentable. Both the replication managed-primary
and base-backup server sessions inherit the gap.

---

### SERVER-5: `Read_Command`/`Read_Initial` promise one deadline for the complete message but re-arm `Timeout` for every transport read

**Verdict:** **DUPLICATE of PROTO-1**, already CONFIRMED there
(`tests/repros/src/repro_proto_1.adb`, measured 0.75 s against a 0.30 s
deadline). No new repro written.

The one thing the server framing adds is a second pair of contract sites that
PROTO-1 did not cite: `src/flyology-postgres-server_sessions.ads:18`
("@param Timeout Maximum time allowed for the complete packet") for
`Read_Initial` and `:24` ("… the complete message") for `Read_Command` repeat
the same unimplemented promise one layer up, so a fix must correct three
specifications, not one. The server-specific consequence — a pre-authentication
client that fragments its startup packet holds a worker for roughly
2 × `Startup_Timeout` (2 reads for the untagged packet), and any later typed
message for 3 × — is a liveness-bound weakening, not a separate defect, and it
is what makes SERVER-8's allocation window longer than it looks.

**Severity:** P1, as recorded for PROTO-1.

---

### SERVER-6: `Serve_TLS`/`Serve` lifecycle contracts drift from the body

**Verdict:** CONFIRMED, both halves.

Refutation attempts:

- *Is `Program_Error` perhaps re-raised as `Constraint_Error` somewhere on the
  way out?* No. `src/flyology-postgres-server.adb:622-625` raises
  `Program_Error with "Serve_TLS requires TLS_Allowed or TLS_Required"` directly
  in `Serve_TLS`'s own body, before `Serve_Internal` is called; nothing between
  it and the caller has a handler. The `.ads` says
  "@exception Constraint_Error Policy is TLS_Disabled"
  (`src/flyology-postgres-server.ads:87`). Confirmed empirically.
- *Is "only once at a time" merely loose English for "one-shot"?* It reads as a
  mutual-exclusion statement, and the implementation supports the sequential
  reading everywhere except the guard: each `Serve_Internal` allocates a fresh
  `Structured.Server` (`:577-579`), installs it, clears it and frees it on both
  the normal and the exceptional path (`:585-601`). Only
  `Inner_Holder.Install`'s `Serve_Started` flag (`:184-187`) makes it one-shot,
  and that flag is never reset by `Clear`.
- *Does either drift bite a plausible caller?* Yes for (a): a caller who writes
  `exception when Constraint_Error =>` around a configuration-driven
  `Serve_TLS` gets an unhandled `Program_Error`. (b) needs a caller who restarts
  a server after a clean shutdown, which is unusual but is what the sentence
  invites.

**Severity:** **P2** (unchanged) — contract drift, both halves needing unusual
input (a `TLS_Disabled` policy passed to `Serve_TLS` is a programming error;
sequential reuse is an uncommon pattern). Note the deliberate contrast with
SERVER-11, which is also a documented-contract violation but sits on the default
configuration of the ordinary shutdown path and is therefore P1.

**Repro:** `tests/repros/src/repro_server_6.adb`

**Output** (`./run.sh repro_server_6`, exit status 1):

```
  -- Serve_TLS (Policy => TLS_Disabled) raised PROGRAM_ERROR: Serve_TLS requires TLS_Allowed or TLS_Required
  FAILED: Serve_TLS with Policy => TLS_Disabled raises the Constraint_Error its specification documents (server.ads:87)
  ok: control: the first Serve returns cleanly after Request_Shutdown
  -- the second sequential Serve raised PROGRAM_ERROR: Postgres server is one-shot
  FAILED: a Server whose Serve has returned can be served again, as 'Serve may be called only once at a time' (server.ads:65) says
BUG REPRODUCED: 2 failed expectation(s)
```

The control shows the first `Serve` returning cleanly, so the second call's
failure is the one-shot guard and not a broken first run.

**Description (contract drift):** Two lifecycle promises on
`Flyology.Postgres.Server` do not match the body.
`src/flyology-postgres-server.ads:87` documents
`@exception Constraint_Error Policy is TLS_Disabled`, while
`src/flyology-postgres-server.adb:622-625` raises `Program_Error`, so a caller
that handles the documented exception does not catch the one raised.
`src/flyology-postgres-server.ads:65` and `:80-81` say Serve/Serve_TLS "may be
called only once at a time", which permits sequential reuse, while
`Inner_Holder.Install` (`src/flyology-postgres-server.adb:184-186`) enforces
one-shot with `Program_Error "Postgres server is one-shot"` even though every
`Serve_Internal` allocates, installs, clears and frees a fresh
`Structured.Server`. Either the specifications or the guards should move; the
value of the finding is that today neither text is safe to program against.

---

### SERVER-7: session-terminating diagnostics — raw Ada exception text is sent to clients, and shutdown cancellation is not reported as 57P01

**Verdict:** **PARTIALLY CONFIRMED.**

- **(b) exception-text disclosure: CONFIRMED**, and reproduced verbatim.
- **(a) "shutdown cancellation is reported the same way (XX000)": REFUTED as
  stated, but the underlying gap is real and is worse.** The catch-all does try
  to answer `XX000`, but its `Send_Error` writes through the *same*
  `Handler_Stop` token that was just cancelled
  (`Connection_Transport.Send_All` passes `Item.Token`,
  `src/flyology-postgres-transports-connections.adb:48-55`, and
  `Process_Connection` binds that token to the handler's cancellation at
  `src/flyology-postgres-server.adb:557-558`), so the write is cancelled too and
  the nested `exception when others => null` at `:545-547` discards it. The peer
  receives **no diagnostic at all** — a bare connection drop, not `XX000`.

Refutation attempts:

- *Is the `XX000` catch-all really reached by client-visible failures, or only
  by internal ones?* Reached by both. `src/flyology-postgres-server.adb:537-544`
  forwards `Ada.Exceptions.Exception_Message (Error)` of *any* non-`Protocol_Error`
  exception, including a `Constraint_Error` raised inside the application's own
  `Handle` callback, which `Run_Session` re-raises through `:504-508`.
- *Does GNAT's `Exception_Message` for a check failure actually carry source
  coordinates?* Yes — the repro's client received
  `repro_server_7.adb:102 index check failed` over the wire.
- *Does PostgreSQL really use 57P01 here?* Yes; `ERRCODE_ADMIN_SHUTDOWN` /
  "terminating connection due to administrator command" is what a backend sends
  on `pg_terminate_backend` and smart shutdown, and reconnect logic in client
  libraries keys on it. This library sends nothing.

**Severity:** **P2** (unchanged, for both halves). (b) is information disclosure
of low impact — a source file name and line number, no secrets, no memory
contents — so it stays below the rubric's "security-relevant" P0 bar; (a) is a
missing diagnostic on an administrative path.

**Repro:** `tests/repros/src/repro_server_7.adb`

**Output** (`./run.sh repro_server_7`, exit status 1):

```
  -- handler Constraint_Error -> SQLSTATE XX000 message "repro_server_7.adb:102 index check failed"
  -- administrator client is idle; calling Request_Shutdown
  -- no ErrorResponse arrived: FLYOLOGY.IO.DEVICE_ERROR
  -- forced shutdown -> no ErrorResponse reached the peer at all: the XX000 Send_Error at server.adb:539-544 uses the same cancelled Handler_Stop token and its failure is discarded by the nested handler at :545-547
  FAILED: an internal Ada check failure in the handler does not put a server source file and line number into the ErrorResponse sent to the peer
  FAILED: a session terminated by Request_Shutdown is told SQLSTATE 57P01 (ERRCODE_ADMIN_SHUTDOWN), as PostgreSQL does, instead of receiving no diagnostic at all
BUG REPRODUCED: 2 failed expectation(s)
```

The first line is a real GNAT range-check failure inside the application handler
— not a synthetic `raise … with` — read back off the socket by the client.

**Description:** `Run_Session`'s catch-all
(`src/flyology-postgres-server.adb:537-548`) builds the client's `ErrorResponse`
from `Ada.Exceptions.Exception_Message (Error)` under SQLSTATE `XX000`. Two
things follow. First, any `Constraint_Error` or `Storage_Error` raised inside
the application's `Handle` callback is reported to the peer — authenticated or
not — with GNAT's message, which names the server source file and line of the
failing check; the repro's client received
`repro_server_7.adb:102 index check failed`. Second, when `Request_Shutdown`
plus a finite `Drain_Timeout` forces handler cancellation, `Read_Command` raises
`Operation_Cancelled`, the catch-all attempts its `XX000` answer through the
very `Handler_Stop` token that was just cancelled, that write fails, and the
nested `exception when others => null` at `:545-547` swallows it: the client sees
an unexplained connection drop where PostgreSQL sends
`FATAL 57P01 terminating connection due to administrator command`, the SQLSTATE
client libraries key their reconnect logic on. Sending a fixed, non-revealing
message for internal errors and recognising `Operation_Cancelled` as `57P01`
(written before the handler token is consumed, or through an uncancelled path)
addresses both.

---

### SERVER-8: pre-authentication startup packet length is accepted up to 16 MiB and the buffer is committed before any payload byte arrives

**Verdict:** CONFIRMED. One detail in the discovery is imprecise and corrected
below.

Refutation attempts:

- *Is the buffer really allocated before the payload arrives, or lazily as bytes
  come in?* Before. `Framing.Read_Contents` allocates
  `new Protocol.Byte_Array (1 .. Byte_Offset (Count))` at
  `src/flyology-postgres-framing.adb:30-31` and only then calls
  `Channel.Receive_Exactly (Buffer.all, …)` at `:34`. The repro's transport
  supplies the four length bytes and nothing else, and observes the library
  asking for 16 777 212 bytes it had already committed.
- *Is `Count` really attacker-controlled up to 16 MiB?*
  `Wire.Valid_Initial_Length` is `Length >= 8 and then Length <=
  UInt32 (Maximum_Frame_Size)` (`src/flyology-postgres-wire.ads:316-317`) with
  `Maximum_Frame_Size = Flyology.Postgres.Maximum_Message_Size = 16 MiB`
  (`src/flyology-postgres-wire.ads:47`), applied at
  `src/flyology-postgres-framing.adb:53-56` before any payload read.
- *Is "materialised three times" accurate?* Not exactly, and it is worth stating
  precisely: the heap `Buffer` and the local `Result :=  Buffer.all`
  (`framing.adb:36-37`) are live simultaneously, so the concurrent peak is 2×
  the declared length; `Free (Buffer)` then runs before the function result is
  copied out, so a third copy is transient at most. The essential point — a
  four-byte, unauthenticated write commits ~32 MiB — stands.
- *Does PostgreSQL really cap this?* Yes:
  `#define MAX_STARTUP_PACKET_LENGTH 10000` (`src/include/libpq/pqcomm.h:148`),
  enforced at `src/backend/tcop/backend_startup.c:543-550` with
  `FATAL "invalid length of startup packet"` *before* the `palloc` at `:558`.
- *Is the exposure unbounded?* No, and this caps the severity: concurrency is
  bounded by `Worker_Capacity (Item.Capacity) = Capacity + 1`
  (`src/flyology-postgres-server.adb:209-216`), so the worst case is
  `(Capacity + 1) × ~32 MiB`. SERVER-5 lengthens the hold — each of the two
  reads gets the full `Startup_Timeout` — but does not widen it.

**Severity:** **P2** (unchanged). Amplification is large (4 bytes → ~32 MiB) but
the total is bounded by the configured session capacity, so it is a resource
and parity gap rather than an unbounded denial of service.

**Repro:** `tests/repros/src/repro_server_8.adb`

**Output** (`./run.sh repro_server_8`, exit status 1):

```
  -- client-declared initial packet length: 16777216 (Wire.Valid_Initial_Length accepts up to Maximum_Message_Size)
  -- PostgreSQL's cap on the same unauthenticated packet: 10004
  -- Read_Initial raised FLYOLOGY.IO.TIMEOUT_ERROR: peer sends no payload
  -- transport reads issued: 2
  -- payload bytes the library asked for (= heap buffer it had already allocated): 16777212
  FAILED: an unauthenticated startup packet does not cause an allocation larger than PostgreSQL's MAX_STARTUP_PACKET_LENGTH before any payload byte has been received
  -- four attacker-supplied bytes committed 16777212 bytes of heap per connection, held for the whole startup timeout, on every worker the listener admits
BUG REPRODUCED: 1 failed expectation(s)
```

Note on the assertion: the exact bound is a **policy value this repository has
not chosen**, and per `.claude/rules/decision-authority.md` picking one is a user
decision (candidates: PostgreSQL's 10000, or a value derived from the existing
limit). The repro asserts parity with PostgreSQL's published cap because that is
the only externally established reference point; the finding is the absence of
*any* startup-specific bound, not the specific number.

**Description:** `Framing.Read_Initial` validates the client's length word only
against `Wire.Valid_Initial_Length`, which admits anything up to
`Maximum_Message_Size` = 16 MiB (`src/flyology-postgres-wire.ads:316-317`), and
then calls `Read_Contents`, which allocates a heap buffer of that size
(`src/flyology-postgres-framing.adb:30-31`) *before* asking the peer for a
single payload byte. A pre-authentication peer that writes four bytes and then
stalls therefore commits ~16 MiB — doubled while the buffer is copied to the
local `Result` at `:36-37` — for the whole startup window, on every worker the
listener admits, i.e. `Capacity + 1` times. PostgreSQL bounds exactly this
allocation at `MAX_STARTUP_PACKET_LENGTH = 10000`
(`src/include/libpq/pqcomm.h:148`) and rejects anything larger with
`FATAL "invalid length of startup packet"` before allocating
(`src/backend/tcop/backend_startup.c:543-556`). The library has no
startup-specific bound at all; adding one is a policy decision that needs the
maintainer's approval, so this finding reports the gap rather than a value.

---

### SERVER-9: `TLS_Socket_Transport.Receive_Exactly` reports the same event differently with and without an observer, and a zero timeout fails before attempting any read

**Verdict:** CONFIRMED, both halves, on a real loopback socket pair.

Refutation attempts:

- *Is the exception difference real, or an artefact of the discovery reading
  the wrong `Receive`?* Real, and the repro shows both in one run on identical
  sockets: without an observer the transport delegates to
  `Flyology.IO.Sockets.Receive_Exactly`
  (`src/flyology-postgres-transports-tls_sockets.adb:46-47`) whose documented
  early-close report is `Device_Error`
  (`flyology-io-sockets.ads:545`) — observed as
  `FLYOLOGY.IO.DEVICE_ERROR: socket closed while receiving`. With an observer it
  goes through `Receive_Chunk` → `Flyology.IO.Sockets.Receive`, whose orderly
  close is `Last = Item'First - 1` (`flyology-io-sockets.ads:474`), and
  `:69-71` turns that into
  `Flyology.IO.TLS.TLS_Error "TLS peer closed before receive completed"` — on a
  transport that has never been upgraded. Observed exactly.
- *Is the zero-timeout claim arithmetic or real?* Real. `Bounded` is
  `Timeout >= 0.0` so `0.0` is bounded, `Deadline := Clock + 0`, and the first
  loop iteration finds `Left <= 0.0` and raises before `Receive_Chunk` is called
  (`:52-59`). The repro pre-loads all eight bytes into the receive buffer,
  waits 50 ms, and still gets `Timeout_Error`.
- *Does any real caller pass an observer to this transport?* Yes.
  `TLS_Socket_Transport` is the standard socket client transport
  (`src/flyology-postgres-client_sockets.adb:42`, plus `examples/pgish`,
  `examples/psqlish`), and `Client.Receive_Copy_Event` threads `On_Wait` into
  `Framing.Read_Message` (`src/flyology-postgres-client.adb:2288-2292`) for
  `Replication.Feedback.Standby_Reporter`
  (`src/flyology-postgres-replication-feedback.adb:27-53`), a public API whose
  entire purpose is to be passed there.
- *Is the contract itself clear about which exception to expect?* No — and that
  is part of the finding. `src/flyology-postgres-transports.ads:28-40` documents
  only `Timeout_Error`, so neither `Device_Error` nor `TLS_Error` is specified;
  what is indefensible is that the choice depends on whether `On_Wait` was
  passed rather than on what happened.

**Severity:** **P2** (unchanged) — inconsistent diagnostics plus an edge-case
(zero-timeout) incorrectness, both on the replication-feedback path rather than
the mainstream query path.

**Repro:** `tests/repros/src/repro_server_9.adb`

**Output** (`./run.sh repro_server_9`, exit status 1):

```
  -- plaintext peer closes after 3 of 8 bytes
  --   without an observer -> FLYOLOGY.IO.DEVICE_ERROR: socket closed while receiving
  --   with an observer    -> FLYOLOGY.IO.TLS.TLS_ERROR: TLS peer closed before receive completed
  FAILED: an early peer close on an un-upgraded transport reports the same exception with and without an observer
  -- Receive_Exactly (Timeout => 0.0, observer) raised FLYOLOGY.IO.TIMEOUT_ERROR: Postgres transport deadline expired before the buffer filled
  FAILED: a zero timeout with an observer still attempts one read and returns bytes that are already available
BUG REPRODUCED: 2 failed expectation(s)
```

(The repro builds real loopback TCP pairs; `Sockets.Create_Socket_Pair` was
tried first and rejected by the runtime's socket preparation with
`configure socket failed [errno=22]`, so it is unusable for this transport.)

**Description:**
`Flyology.Postgres.Transports.TLS_Sockets.TLS_Socket_Transport.Receive_Exactly`
takes two different routes depending on whether the caller supplied an observer
(`src/flyology-postgres-transports-tls_sockets.adb:41-50` versus `:52-83`).
Without one, a plaintext peer that closes mid-message surfaces as
`Flyology.IO.Device_Error`, the socket layer's documented early-close report;
with one, the chunked loop sees `Last < Cursor` and raises
`Flyology.IO.TLS.TLS_Error "TLS peer closed before receive completed"` (`:69-71`)
even on a transport that was never upgraded, so a caller's exception handler has
to depend on its own choice of `On_Wait` rather than on the event. Separately,
`Timeout => 0.0` is treated as bounded, `Deadline` equals the current `Clock`,
and the loop raises `Timeout_Error` at `:55-58` before `Receive_Chunk` is ever
called, so bytes already sitting in the receive buffer are never read — whereas
the observer-less path passes `0.0` down to the socket and TLS layers, where it
means "one immediate attempt". Both reach the replication-feedback path, where
`Standby_Reporter` is the intended `On_Wait` for `Client.Receive_Copy_Event`.

---

### SERVER-10: `_pq_.` protocol-extension parameters are silently dropped instead of being reported in NegotiateProtocolVersion

**Verdict:** **DUPLICATE of PROTO-5**, already CONFIRMED there
(`tests/repros/src/repro_proto_5.adb`). No new repro written: PROTO-5's
verification already covered both the decoder side (`Startup_Information` has no
field for the options, `src/flyology-postgres-protocol.ads:569-583`; the
parameter walk at `src/flyology-postgres-protocol.adb:1183-1205` inspects only
`replication`) and the server side (`Send_Negotiate_Protocol` hard-codes
`Append_U32 (Contents, 0)` at
`src/flyology-postgres-server_sessions.adb:157`, and `Run_Session` calls it only
when `Protocol_Minor > 2`, `src/flyology-postgres-server.adb:443-447`).

One backend citation is worth adding because SERVER-10 states the server-side
rule the PROTO write-up paraphrased, and it checks out exactly:
`src/backend/tcop/backend_startup.c:853-855` sends the message when
`PG_PROTOCOL_MINOR(proto) > PG_PROTOCOL_MINOR(PG_PROTOCOL_LATEST) ||
unrecognized_protocol_options != NIL`, with the options collected at `:813-814`.
So a 3.0 client that requests `_pq_.foo` is entitled to a `v` message and this
library sends none — the `Protocol_Minor > 2` gate is a second, independent
reason the message is missing, on top of the discarded names. Note that fixing
SERVER-10 without fixing SERVER-3 would make things worse, since the `v` message
would then be sent to ordinary 3.0 clients carrying a malformed version word.

**Severity:** P2, as recorded for PROTO-5.

---

### SERVER-11: `Request_Shutdown` promises cancellation of active connection work, but with the default `Drain_Timeout` no handler is ever cancelled

**Verdict:** CONFIRMED. Severity raised.

Refutation attempts:

- *Does the runtime's `Request_Shutdown` cancel handlers?* No. It is
  `Item.State.Request_Stop (New_Request); if New_Request then
  Item.Accept_Stop.Request; end if;`
  (`flyology-io-structured_servers.adb:184-191`) — only the accept token.
  `Item.Handler_Stop.Request` appears solely in `Force_Handlers` (`:230-235`).
- *Does anything else call `Force_Handlers`?* Only the `delay Drain_Timeout`
  arm of the timed select at `:512-521`, and the `when others` cleanup at
  `:525-529`. With `Drain_Timeout = Infinite`, `Serve` takes the unguarded
  `Item.State.Await_All_Workers` at `:513` and no handler is ever forced.
- *Is `Postgres.Server` perhaps compensating?*
  `Flyology.Postgres.Server.Request_Shutdown` is a one-line delegation to
  `Inner_Holder.Request_Stop` (`src/flyology-postgres-server.adb:635-638`),
  which calls the runtime's `Request_Shutdown` and nothing else
  (`:192-198`).
- *Is the blocked handler configuration the default or a pathological one?* It is
  the default twice over: `Drain_Timeout : Duration := Flyology.IO.Infinite` on
  both `Serve` and `Serve_TLS` (`src/flyology-postgres-server.ads:63`, `:76`),
  and the generic formal `Command_Timeout : Duration := Flyology.IO.Infinite`
  (`:37`), so a session parked in `Read_Command` waits forever by default.
- *Is the discovery's severity of P2 right?* No — this is why the repro carries a
  control. The documented contract at `src/flyology-postgres-server.ads:89-90`
  is "Request listener shutdown **and cancellation of active connection work**",
  and with the shipped defaults the second clause does not happen; the effect is
  that `Serve` does not return. That is squarely "a documented contract
  violated" on a default, ordinary path.

**Severity:** **P1** (raised from the discovery's P2). Contrast with SERVER-6,
kept at P2: both are documented-contract violations, but SERVER-6 needs an
unusual call (a `TLS_Disabled` policy handed to `Serve_TLS`, or a sequential
restart) while SERVER-11 is what an application gets by writing nothing at all
and shutting down with a client connected. The rubric's P0 clause
"hang/deadlock in normal operation" is arguable — `Serve` never returns while an
idle client is attached — but it is not held here because a graceful drain that
waits for clients is a legitimate design and the caller can set a finite
`Drain_Timeout`; what is wrong is the specification, which promises cancellation
the default does not deliver.

**Repro:** `tests/repros/src/repro_server_11.adb`

**Output** (`./run.sh repro_server_11`, exit status 1):

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

The predicted hang is demonstrated with a **bounded** 5 s wait against a control
server that differs only in `Drain_Timeout`, not by letting the program time out;
the program then closes the client socket to release `Serve` and exits cleanly
with status 1.

**Description:** `Flyology.Postgres.Server.Request_Shutdown` is documented as
"Request listener shutdown **and cancellation of active connection work**"
(`src/flyology-postgres-server.ads:89-90`). It delegates to the Flyology
runtime's `Request_Shutdown` (`src/flyology-postgres-server.adb:635-638`), which
requests only the accept token
(`flyology-io-structured_servers.adb:184-191`); the handler token is requested
exclusively by `Force_Handlers` (`:230-235`), which runs only from the
`delay Drain_Timeout` arm of `Serve`'s timed select (`:512-521`). Both `Serve`
and `Serve_TLS` default `Drain_Timeout` to `Flyology.IO.Infinite`
(`server.ads:63`, `:76`), so with the shipped defaults `Serve` takes the
unguarded `Await_All_Workers` branch and no handler is ever cancelled — and
since the generic formal `Command_Timeout` also defaults to `Infinite`
(`server.ads:37`), a session parked in `Read_Command` waits indefinitely. An
operator who calls `Request_Shutdown` with one idle client attached sees the
listener close and `Serve` never return. Either the default should be finite or
the specification should say that cancellation is contingent on a finite
`Drain_Timeout`; the repository's own test server sidesteps it by passing
`Drain_Timeout => 1.0` (`tests/src/postgres_test_server.adb:288`), which is why
no existing test covers the default.

---

## Notes on the working tree

The only files this verification created are
`tests/repros/src/repro_server_1.adb`, `_2`, `_3`, `_4`, `_6`, `_7`, `_8`, `_9`
and `_11` (no `_5` or `_10`; those are duplicates). No file under `src/`,
`sql/`, `examples/`, or `tests/src/` was modified, no existing repro or script
was touched, and nothing was committed. The PostgreSQL checkout at
`/Users/yrashk/Projects/omnigres/postgres` was read only, never entered with
`cd` and never modified.

`git status` also shows three modified files under `sql/tests/config/`
(`flyology_postgres_sql_tests_config.{ads,gpr,h}`) and an untracked
`sql/tests/repros/`; neither was produced here — the only builds run were
`tests/repros/repros.gpr`.
