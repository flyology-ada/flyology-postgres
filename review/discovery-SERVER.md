# SERVER review: protocol server, server sessions, transports

Scope: `src/flyology-postgres-server.{ads,adb}`, `src/flyology-postgres-server_sessions{,-control}.{ads,adb}`,
`src/flyology-postgres-transports{,-connections,-sockets,-tls_sockets}.{ads,adb}`, with
`framing`, `protocol`, `wire`, and `scram` read for the consumed contracts. Read-only review; nothing was
built or run. The Flyology runtime contracts the server depends on (`Flyology.IO.Structured_Servers`,
`Flyology.IO.Connections`, `Flyology.IO.Connections.TLS`, `Flyology.IO.Sockets`, `Flyology.IO.TLS`) were read
from the sibling `flyology` checkout's sources by absolute path (no `cd`, no modification). Real-backend
behaviour was confirmed against the PostgreSQL `REL_18_STABLE` sources (`backend_startup.c`,
`copyfromparse.c`, `fe-protocol3.c`, `fe-cancel.c`, `fe_utils/cancel.c`) where a claim depends on it.

Severity rubric (from the task): P0 = memory/aliasing unsafety, security-relevant, hang/deadlock in normal
operation, or protocol violation breaking interop with psql/libpq; P1 = wrong result/state/exception on a
reachable path, or a documented contract violated; P2 = edge-case incorrectness, wrong diagnostics, contract
drift needing unusual input.

---

### SERVER-1: First `Read_Initial` runs in `Run_Session`'s declarative part, so any client-caused failure on the first packet escapes the session handlers and stops the whole server's admission loop
- Location: `src/flyology-postgres-server.adb:371-372` (declaration), `:524-548` (handlers that do not cover it), `:551-563` (`Process_Connection` has no handler)
- Severity: P0
- Confidence: high
- Evidence:
  ```
  366	   procedure Run_Session
  ...
  371	      Initial : Protocol.Initial_Request :=
  372	        Server_Sessions.Read_Initial (Client, Startup_Timeout);
  373	      TLS_Active : Boolean := False;
  374	   begin
  ...
  524	   exception
  525	      when Error : Protocol.Protocol_Error =>
  ...
  537	      when Error : others =>
  ```
  In Ada the handlers of a `handled_sequence_of_statements` do not cover exceptions raised while elaborating
  the declarative part; they propagate to the caller. `Process_Connection` (551-563) has no handler, so the
  exception reaches the Structured_Servers worker. The runtime's worker (flyology
  `flyology-io-structured_servers.adb:453-458`) does:
  ```
  Handle (Context, Connection, Peer, Item.Handler_Stop'Access);
  exception
     when Connections.Operation_Cancelled => Cancelled := True;
     when Event : others => Report (Handler_Callback, Event); Failed := True;
  ```
  and `Report` (`:406-410`) is `Record_Failure (...)` followed by `Stop_Accepting`, which is
  `Item.Accept_Stop.Request` (`:225-228`). Every worker's next `Accept_Connection` then raises
  `Operation_Cancelled` and sets `Stop_Worker := True` (`:444-446`), so all `Capacity + 1` workers exit their
  accept loops. The Serve task itself keeps waiting in `Await_Stop` (`entry Await_Stop when Phase =
  Stop_Requested`, `:71`) until someone calls `Request_Shutdown`, after which `Serve` raises `Server_Failed`
  (`:534-536`). The identical `Read_Initial` inside the loop (`server.adb:403`) IS covered by the handlers,
  so the design intent (convert client errors into a FATAL response and return normally) is clear and the
  first read is the odd one out.

  Exceptions that reach the declarative part from ordinary clients, per the runtime contract
  (`flyology-io-connections.ads`, `Receive_Exactly`): `Device_Error` "peer closes early" (connect then close,
  e.g. a TCP health probe, `nc -z`, a port scanner), `Flyology.IO.Timeout_Error` (client connects and stays
  silent for `Startup_Timeout` = 30 s), and `Protocol.Protocol_Error` from `Framing.Read_Initial`/
  `Decode_Initial` (length < 8 or > 16 MiB such as the bytes `GET ` of an HTTP probe, missing terminator,
  empty user, ...). None of these is a server fault; PostgreSQL logs and drops such connections.
- Failure scenario: With `Postgres_Test_Server` (or any instantiation) serving: a client opens a TCP
  connection and closes it without sending anything -> `Device_Error` escapes -> admission stops for the
  entire server; every subsequent `psql` connection queues in the listen backlog and never gets a response
  (Serve neither returns nor raises until `Request_Shutdown` is called, after which it raises
  `Server_Failed`). Same outcome for `printf 'GET / HTTP/1.1\r\n' | nc host port` or for a client that idles
  30 s before its startup packet. Additionally, for the malformed-length case no FATAL `ErrorResponse` is
  sent (the 08P01 path at 525-536 is bypassed), unlike every later malformed packet.
- Reproduction test sketch: cannot use `Memory_Transport` (needs a real `Connection`); scripted raw-socket
  client against `postgres_test_server`: (1) connect and immediately close; (2) then run
  `psql "$psql_connection" -Atc 'select 1'` with a 5 s `connect_timeout`. Expected: (2) succeeds. Actual:
  (2) times out; `Test_Server.Serve_TLS` later raises `Server_Failed` whose text contains the
  `Device_Error` occurrence. Variant: send `00 00 00 04` as the first four bytes; expected a FATAL 08P01
  "invalid initial Postgres packet length" followed by close and continued service; actual: silent close and
  the same admission stop.
- Existing coverage: none. `run-integration.sh` only drives well-formed psql startups; the plaintext
  `sslmode=disable` case sends a valid startup packet and is handled inside the covered loop body.

### SERVER-2: `TLS_Required` rejects plaintext `CancelRequest`, so psql's Ctrl-C (legacy `PQcancel`, still used by `psql` 18) never cancels anything
- Location: `src/flyology-postgres-server.adb:406-419`
- Severity: P1 (borders P0: breaks a psql feature outright under the policy the test server ships with)
- Confidence: high (behaviour); high (client facts, verified in PG 18 sources)
- Evidence:
  ```
  406	      if Context.TLS_Mode = TLS_Required and then not TLS_Active then
  407	         Server_Sessions.Send_Error
  408	           (Client,
  409	            Message   => "TLS is required",
  410	            SQL_State => "08004",
  411	            Severity  => "FATAL",
  412	            Timeout   => Write_Timeout);
  413	         return;
  414	      end if;
  415
  416	      if Protocol.Kind (Initial) = Protocol.Cancel_Request then
  417	         Context.Router.Route
  418	           (Protocol.Process_Id (Initial), Protocol.Secret_Key (Initial));
  419	         return;
  ```
  The TLS gate runs before the cancel check, so a CancelRequest that arrives without a preceding accepted
  SSLRequest is answered with an ErrorResponse and never routed. The documented policy is narrower:
  `server.ads:85` "@param Policy Whether plaintext startup is allowed or rejected." and `:77-78`
  "TLS_Required rejects plaintext" in the context of startup. The real backend
  (`backend_startup.c`, `ProcessStartupPacket`) handles `CANCEL_REQUEST_CODE` before any SSL handling and
  regardless of `hostssl` rules, because cancel packets carry no credentials beyond the secret key. libpq's
  legacy `PQcancel` (`fe-cancel.c`) does `connect()` then `send()` of the cancel packet with no SSLRequest
  ("old, non-encrypted, but signal-safe way"), and `src/fe_utils/cancel.c` on both `REL_17_STABLE` and
  `REL_18_STABLE` still calls `PQcancel(cancelConn, ...)` from its SIGINT handler. Only clients using
  `PQcancelCreate`/`PQcancelBlocking` negotiate TLS for the cancel connection.
- Failure scenario: `psql "$psql_connection"` (sslmode=verify-full, server `Policy => TLS_Required`) runs
  `select pg_sleep(30)`; user presses Ctrl-C; psql prints "Cancel request sent"; the server handler keeps
  looping for the full 30 s because the plaintext CancelRequest received `FATAL 08004 TLS is required`
  and was discarded. Same for any driver built on `PQcancel` (psycopg2, psycopg3 `cancel()`, DBD::Pg, ...).
- Reproduction test sketch: extend `tests/src/postgres_test_cancellation.adb`'s `Send_Raw_Cancel` with a
  plaintext variant (skip `Encode_SSL_Request`/`Upgrade_TLS`, write `Encode_Cancel_Request` directly on the
  socket). Expected (PostgreSQL semantics): silent close and `Drain_Cancellation` observes 57014. Actual:
  an `E` message with SQLSTATE 08004 is readable on the cancel socket and `Expect_Still_Running` semantics
  hold (the query is not cancelled).
- Existing coverage: `postgres_test_cancellation.adb:59-68` always upgrades to TLS before sending the
  CancelRequest, so the plaintext path is untested; `run-integration.sh` does not exercise psql Ctrl-C.

### SERVER-3: NegotiateProtocolVersion carries the bare minor number instead of the full protocol version; libpq 18 rejects it as a "downgrade to pre-3.0"
- Location: `src/flyology-postgres-server.adb:444-447`, `src/flyology-postgres-server_sessions.adb:150-159`, contract `src/flyology-postgres-server_sessions.ads:85-92`
- Severity: P1
- Confidence: high
- Evidence:
  ```
  444	         if Startup.Protocol_Minor > 2 then
  445	            Server_Sessions.Send_Negotiate_Protocol
  446	              (Client, Latest_Minor => 2, Timeout => Write_Timeout);
  ```
  ```
  156	      Protocol.Append_U32 (Contents, Latest_Minor);
  157	      Protocol.Append_U32 (Contents, 0);
  158	      Send_Built (Item, 'v', Contents, Timeout);
  ```
  The wire value is `00 00 00 02`. The real backend (`backend_startup.c`, `SendNegotiateProtocolVersion`)
  sends `pq_sendint32(&buf, FrontendProtocol)`, i.e. the full `major<<16 | minor` value (`00 03 00 02` for
  3.2). libpq 18 (`fe-protocol3.c`, `pqGetNegotiateProtocolVersion3`) reads it as a `ProtocolVersion` and
  fails with `if (their_version < PG_PROTOCOL(3, 0))` -> "received invalid protocol negotiation message:
  server requested downgrade to pre-3.0 protocol version"; libpq 17 and earlier likewise split it with
  `PG_PROTOCOL_MAJOR/MINOR`. The protocol document's phrase "Newest minor protocol version supported"
  describes the same full-word value as implemented by both sides since PG 11; the `.ads` parameter name
  `Latest_Minor` bakes the misreading into the API.
- Failure scenario: a client sends StartupMessage with version 3.3 (or any minor > 2). Expected: `v`
  message `00 03 00 02 00 00 00 00`, client continues at 3.2. Actual: `v` `00 00 00 02 00 00 00 00`;
  libpq aborts the connection with the pre-3.0 error. Not reachable with shipping libpq (which caps
  `max_protocol_version` at 3.2) but reachable with any future or third-party client that requests a newer
  minor, which is the only situation in which this message is ever sent.
- Reproduction test sketch: `Memory_Transport` + `Server_Sessions.Session`; call
  `Send_Negotiate_Protocol (Session, 2, 1.0)`; assert `Channel.Output = ('v', 00 00 00 0C, 00 03 00 02,
  00 00 00 00)`. Currently yields `00 00 00 02` in bytes 6-9.
- Existing coverage: none; no test encodes or decodes a `v` message.

### SERVER-4: `Read_Copy_Command` documents Flush/Sync/Terminate results that the type cannot represent; a Sync during COPY IN (what libpq sends for extended-protocol COPY) is answered with FATAL instead of being ignored
- Location: `src/flyology-postgres-server_sessions.ads:26-32`, `src/flyology-postgres-server_sessions.adb:70-75`, `src/flyology-postgres-protocol.adb:850-871`
- Severity: P1
- Confidence: high
- Evidence:
  ```
  26	   function Read_Copy_Command
  27	     (Item : in out Session; Timeout : Duration)
  28	      return Protocol.Frontend_Copy_Message;
  29	   --  Read and classify one frontend message during COPY.
  ...
  32	   --  @return CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate event.
  ```
  `Protocol.Frontend_Copy_Kind` is `(Frontend_Copy_Data, Frontend_Copy_Done, Frontend_Copy_Fail)`
  (`protocol.ads`), and `Decode_Frontend_Copy` ends with
  ```
  869	         when others =>
  870	            raise Protocol_Error with "message is not a frontend COPY command";
  ```
  so the documented Flush/Sync/Terminate outcomes are unreachable. PostgreSQL's `CopyGetData`
  (`copyfromparse.c`) has `case PqMsg_Flush: case PqMsg_Sync: /* Ignore Flush/Sync for the convenience of
  client libraries (such as libpq) that may send those without noticing that the command they just sent was
  COPY. */ goto readmessage;`. libpq's `PQexecParams("COPY ... FROM STDIN")` sends
  Parse/Bind/Describe/Execute/Sync before the backend answers, so the Sync is already queued when the
  handler enters COPY IN.
- Failure scenario: client sends `Parse("COPY flyology_sink FROM STDIN")`, `Bind`, `Execute`, `Sync`; the
  handler (e.g. `postgres_test_server.adb:148-164` loop) sends CopyInResponse and calls
  `Read_Copy_Command`; the next message is `S` -> `Protocol_Error` propagates out of `Handle` ->
  `Run_Session` sends `FATAL 08P01 message is not a frontend COPY command` and drops the connection. Real
  PostgreSQL accepts the following CopyData/CopyDone.
- Reproduction test sketch: `Memory_Transport`; `Queue (Channel, Protocol.Make_Sync_Message)`;
  `Queue (Channel, Protocol.Make_Copy_Data_Message (Chunk))`; `Read_Copy_Command (Session, 1.0)`.
  Expected per the `.ads`: a Sync classification (or, per PostgreSQL, the Sync skipped and the CopyData
  returned). Actual: `Protocol_Error`. Integration: a small libpq program using `PQexecParams` for the
  COPY against `postgres_test_server`.
- Existing coverage: `Test_Copy_Protocol` (`tests.adb:1081-1092`) queues only CopyData;
  `run-integration.sh` uses `psql \copy`, which issues a simple `Query` with no Sync. Other callers of the
  same helper (`replication-managed_primary.adb:55`, `base_backups-server_sessions.adb:204`) inherit the gap.

### SERVER-5: `Read_Command`/`Read_Initial` promise one deadline for the complete message, but each header/payload read is given the full `Timeout` again (3x for typed messages, 2x for the initial packet)
- Location: `src/flyology-postgres-framing.adb:48-60, 62-81` (behaviour); contracts at `src/flyology-postgres-server_sessions.ads:18, 24` and `src/flyology-postgres-framing.ads:15-17`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  70	      Channel.Receive_Exactly (Tag, Timeout, On_Wait);
  71	      Length := Read_Length (Channel, Timeout, On_Wait);
  ...
  76	      return Protocol.Make_Message
  77	        (Character'Val (Tag (Tag'First)),
  78	         Read_Contents
  79	           (Channel, Natural (Wire.Content_Length (Length)), Timeout,
  ```
  versus `server_sessions.ads:24` "@param Timeout Maximum time allowed for the complete message." and
  `framing.ads:15` "Read one typed message under a single deadline."
- Failure scenario: a pre-authentication client sends the tag byte, waits 29 s, sends the 4 length bytes,
  waits 29 s, then sends the payload: the handler worker is held for ~87 s although `Startup_Timeout` is
  30 s. With `Command_Timeout = Infinite` (default) the extra factor is moot post-auth, but any finite
  configured timeout is honoured only per fragment.
- Reproduction test sketch: raw-socket client against the test server that sends `p` (or the startup
  length) and delays between fragments; measure when the FATAL/close arrives. Expected: about
  `Startup_Timeout`. Actual: about `3 x Startup_Timeout`. A `Memory_Transport` cannot observe this because
  it never waits.
- Existing coverage: none asserts elapsed time; `tests/scripts/fragmenting-proxy.py` fragments bytes but
  the pipeline scripts do not check deadlines.

### SERVER-6: `Serve_TLS`/`Serve` lifecycle contracts drift from the body (documented `Constraint_Error` is raised as `Program_Error`; "only once at a time" is implemented as one-shot)
- Location: `src/flyology-postgres-server.ads:87` vs `src/flyology-postgres-server.adb:622-625`; `src/flyology-postgres-server.ads:65, 80-81` vs `src/flyology-postgres-server.adb:184-186`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  87	   --  @exception Constraint_Error Policy is TLS_Disabled.
  ```
  ```
  622	      if Policy = TLS_Disabled then
  623	         raise Program_Error with
  624	           "Serve_TLS requires TLS_Allowed or TLS_Required";
  ```
  ```
  65	   --  @param Item Server instance; Serve may be called only once at a time.
  ```
  ```
  184	         if Serve_Started then
  185	            raise Program_Error with "Postgres server is one-shot";
  ```
  A caller handling the documented `Constraint_Error` does not catch the actual exception; a caller that
  reads "only once at a time" as permitting sequential reuse gets `Program_Error` on the second `Serve`
  even though each `Serve_Internal` allocates a fresh `Structured.Server`.
- Failure scenario: `Serve_TLS (..., Policy => TLS_Disabled)` inside `exception when Constraint_Error =>`
  -> unhandled `Program_Error`. Second sequential `Serve` after a clean shutdown -> `Program_Error`.
- Reproduction test sketch: instantiate the generic in `tests.adb`, call `Serve_TLS` with `TLS_Disabled`
  and a dummy listener, assert the exception identity; call `Serve` twice sequentially.
- Existing coverage: none.

### SERVER-7: Session-terminating diagnostics: raw Ada exception text is sent to clients as `FATAL XX000`, and shutdown cancellation is reported the same way instead of `57P01`
- Location: `src/flyology-postgres-server.adb:537-548`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  537	      when Error : others =>
  538	         begin
  539	            Server_Sessions.Send_Error
  540	              (Client,
  541	               Message   => Ada.Exceptions.Exception_Message (Error),
  542	               SQL_State => "XX000",
  543	               Severity  => "FATAL",
  ```
  `Read_Command` raises `Operation_Cancelled` when the Structured server forces handler cancellation (drain
  timeout / `Request_Shutdown`), and the catch-all turns it into `XX000` with the runtime's internal
  message; PostgreSQL sends `FATAL 57P01 terminating connection due to administrator command`. The same
  catch-all forwards `Exception_Message` of any handler-raised `Constraint_Error`/`Storage_Error`, which
  with GNAT contains source file names and line numbers, to unauthenticated and authenticated peers alike.
- Failure scenario: psql connected and idle; server `Request_Shutdown` with a finite `Drain_Timeout`;
  psql shows `FATAL: XX000: <runtime text>` instead of the administrator-command message; client
  libraries keyed on 57P01 (admin shutdown reconnect logic) do not recognise it.
- Reproduction test sketch: `postgres_test_server` with `Drain_Timeout => 1.0`; keep a psql session idle;
  send the server SIGTERM/`Request_Shutdown`; inspect psql's error. Expected 57P01; actual XX000.
- Existing coverage: none.

### SERVER-8: Pre-authentication startup packet length is accepted up to 16 MiB and materialised three times before decoding (PostgreSQL caps at 10000 bytes)
- Location: `src/flyology-postgres-wire.ads:316-317`; `src/flyology-postgres-framing.adb:30-31, 37, 51-59`; `src/flyology-postgres-protocol.adb:176-185`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  316	   function Valid_Initial_Length (Length : UInt32) return Boolean is
  317	     (Length >= 8 and then Length <= UInt32 (Maximum_Frame_Size));
  ```
  ```
  30	      Buffer : Byte_Array_Access :=
  31	        new Protocol.Byte_Array (1 .. Protocol.Byte_Offset (Count));
  ...
  37	         Result : constant Protocol.Byte_Array := Buffer.all;
  ```
  The heap buffer is sized from the client-supplied length before any byte of payload arrives, copied to
  `Result`, and then copied again by `Make_Message`/`Decode_Initial` consumers. PostgreSQL rejects startup
  packets larger than `MAX_STARTUP_PACKET_LENGTH` (10000) with `FATAL invalid length of startup packet`
  precisely to bound unauthenticated memory use.
- Failure scenario: `Capacity + 1` unauthenticated connections each send `01 00 00 00` and then trickle
  bytes (each read individually enjoys the full `Startup_Timeout`, see SERVER-5): 16 MiB is allocated per
  connection up front, ~48 MiB transient once complete, for the duration of the trickle.
- Reproduction test sketch: raw-socket client sending length `16#0100_0000#` followed by one byte every
  few seconds; observe RSS of the server process.
- Existing coverage: none. Note per `.claude/rules/decision-authority.md`: a startup-specific bound is a
  new policy value and needs a user decision (candidates: PostgreSQL's 10000, or derive from the existing
  limit); this finding only reports the gap.

### SERVER-9: `TLS_Socket_Transport.Receive_Exactly` with an observer raises a different exception class than without one for the same event, and a zero timeout fails before attempting any read
- Location: `src/flyology-postgres-transports-tls_sockets.adb:41-50, 52-59, 64-72`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  69	            if Last < Cursor then
  70	               raise Flyology.IO.TLS.TLS_Error with
  71	                 "TLS peer closed before receive completed";
  ```
  `Receive_Chunk` (12-24) reads through `Flyology.IO.Sockets.Receive` when not encrypted, which reports an
  orderly close as `Last = Item'First - 1` (`flyology-io-sockets.ads`), so a plaintext EOF becomes a
  `TLS_Error` with a TLS message. The observer-less path (41-50) instead delegates to
  `Sockets.Receive_Exactly`, whose EOF is `Device_Error` ("peer closes before completion"). Callers
  therefore see a different exception class depending on whether they passed `On_Wait`, not on what
  happened; the `Transport` contract (`transports.ads:28-40`) documents only `Timeout_Error`.
  ```
  52	      while Cursor <= Data'Last loop
  53	         if Bounded then
  54	            Left := Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
  55	            if Left <= 0.0 then
  56	               raise Flyology.IO.Timeout_Error with
  ```
  With `Timeout = 0.0`, `Deadline = Clock + 0` and the next `Clock` is >= `Deadline`, so the loop raises
  before calling `Receive_Chunk` even when bytes are already available; the observer-less path passes 0.0
  through to the socket/TLS layers, where zero means "immediate attempt" (`flyology-io-tls.ads:189`).
- Failure scenario: the replication client (`Standby_Reporter.On_Wait`, `replication-feedback.adb:27`,
  reached via `client.adb:2288` -> `Framing.Read_Message (..., On_Wait)`) over a plaintext
  `TLS_Socket_Transport` whose peer closes mid-message: caller handlers written for `Device_Error` (the
  documented socket EOF) receive `TLS_Error` instead. A caller polling with `Timeout => 0.0` and an observer
  never reads even available bytes.
- Reproduction test sketch: loopback socket pair; server writes 3 of 8 expected bytes and closes; client
  calls `Receive_Exactly (Data (1 .. 8), 1.0, Observer'Access)` on an un-upgraded transport. Expected
  `Device_Error` (same as without an observer); actual `TLS_Error`. Second case: server writes 8 bytes;
  client calls with `Timeout => 0.0` and an observer; expected the 8 bytes; actual `Timeout_Error`.
- Existing coverage: none for the observer path of this transport (`Memory_Transport` ignores `On_Wait`).

### SERVER-10: `_pq_.` protocol-extension parameters are silently dropped instead of being reported in NegotiateProtocolVersion
- Location: `src/flyology-postgres-wire.adb:270-360` (only `user`, `database`, `application_name` are recognised; nothing collects `_pq_.` names); `src/flyology-postgres-server.adb:444-447`; `src/flyology-postgres-server_sessions.adb:157` (count is always 0)
- Severity: P2
- Confidence: high
- Evidence: `server_sessions.adb:157` `Protocol.Append_U32 (Contents, 0);` and `server.adb:444` sends the
  message only when `Protocol_Minor > 2`. PostgreSQL (`backend_startup.c`) collects every startup parameter
  whose name starts with `_pq_.` into `unrecognized_protocol_options` and sends NegotiateProtocolVersion
  whenever `PG_PROTOCOL_MINOR(proto) > PG_PROTOCOL_MINOR(PG_PROTOCOL_LATEST) ||
  unrecognized_protocol_options != NIL`, including for a 3.0 client. The protocol requires this so a client
  can learn that an optional extension was not honoured.
- Failure scenario: a 3.0 client sends `_pq_.some_extension=1`; expected `v` with version 3.0 and one
  option name; actual: no `v` message, so the client proceeds believing the extension is active.
- Reproduction test sketch: raw-socket client (or `Protocol.Encode_Startup` cannot express it; build the
  packet by hand) with the extra parameter against the test server; check for a `v` message before
  `R`.
- Existing coverage: none; `Test_Startup`/`Test_Malformed_Startup` only cover the three recognised names.

### SERVER-11: `Request_Shutdown` promises cancellation of active connection work, but with the default `Drain_Timeout = Infinite` no handler is ever cancelled, so one idle client blocks `Serve` forever
- Location: `src/flyology-postgres-server.ads:89-92` (contract), `:59-63, 70-76` (default `Drain_Timeout => Flyology.IO.Infinite`), `:37` (`Command_Timeout := Infinite`); runtime `flyology-io-structured_servers.adb:184-191, 512-513, 230-235`
- Severity: P2
- Confidence: high
- Evidence:
  ```
  89	   procedure Request_Shutdown (Item : in out Server);
  90	   --  Request listener shutdown and cancellation of active connection work.
  ```
  Runtime `Request_Shutdown` only requests `Accept_Stop` (`:187-190`); `Handler_Stop` is requested by
  `Force_Handlers` (`:230-235`), which runs only from the `delay Drain_Timeout` branch (`:512-521`); with
  `Drain_Timeout = Infinite` the Serve task waits in `Await_All_Workers` unconditionally. A session
  blocked in `Read_Command (Client, Command_Timeout)` with the default infinite timeout never observes
  cancellation.
- Failure scenario: application calls `Serve` with defaults, one psql sits idle at the prompt, operator
  calls `Request_Shutdown`: the listener closes but `Serve` does not return until psql exits, contrary to
  the `Request_Shutdown` documentation.
- Reproduction test sketch: start the test server with `Drain_Timeout` left at the default, connect psql,
  call `Request_Shutdown` from another task, wait 5 s; `Serve` is still blocked.
- Existing coverage: `postgres_test_server.adb:288` passes `Drain_Timeout => 1.0`, so the default path is
  untested.

---

## Areas reviewed with no findings

- SSLRequest handling: `Serve` (TLS_Disabled) answers `N` and continues in plaintext; `TLS_Allowed` accepts
  either; a second SSLRequest after an accepted one is rejected ("duplicate Postgres SSLRequest"); GSSENC is
  refused with `N`. Two negotiation packets are permitted before the startup packet, matching the backend's
  `ssl_done`/`gss_done` pair. (Noted, not raised: with `TLS_Disabled` a second SSLRequest gets a second `N`
  rather than a FATAL; harmless leniency.)
- TLS upgrade ordering and buffering: `S` is written synchronously before `Connections.TLS.Upgrade`;
  `Read_Initial` reads exactly 4 + 4 bytes through `Connection.Receive_Exactly`, so no plaintext bytes
  following the SSLRequest can be consumed as post-handshake data (the CVE-2021-23214 pattern); the
  runtime cancels queued plaintext operations at the transition. Ownership stays with the `Connection`;
  `Run_Session` never closes, the Structured worker closes exactly once.
- Startup packet parsing (`Wire.Decode_Initial`): length lower bound 8, terminator required, trailing data
  rejected, unterminated strings rejected, missing/empty `user` rejected, `database` defaults to `user`,
  duplicate parameters last-wins, unknown parameters ignored. Major != 3 becomes `Unknown_Initial` and a
  FATAL 08P01. Minor versions 0-2 accepted, > 2 negotiated down to 2.
- Cancel keys: `Generate` yields a non-zero 31-bit PID and 4 (3.0/3.1) or 32 (>= 3.2) random secret bytes;
  `Send_Backend_Key_Data` encodes exactly `Key.Length` bytes; `Matches` XORs all 32 stored bytes with no
  data-dependent early exit on the secret (only PID/length short-circuit, which are not secret); `Route`
  scans every slot and reveals nothing to the requester; the CancelRequest length window 12..264 matches
  the 3.2 spec. Operation token lifetime: `Begin_Operation`/`End_Operation`/`Remove` run on every normal
  and exceptional path and `Route`'s `Target.Request` executes under the Registry lock, so the stack token
  cannot be freed while a cancel is being delivered.
- Authentication: Trust/Cleartext/SCRAM message-kind checks; SCRAM unknown-user path uses the dummy
  verifier and checks `Has_Credential` only after full verification; server signature wiped; failure is
  `FATAL 28P01`; `SASLInitialResponse` mechanism and length validation; `SASLResponse`/`PasswordMessage`
  trailing-data checks.
- Startup completion ordering: AuthenticationOk, ParameterStatus set, BackendKeyData, ReadyForQuery `I`.
- Command loop: handler exceptions clear the operation token, unregister the key, and become a FATAL;
  `Terminate` invokes the handler then exits; Registry full -> `FATAL 53300`.
- Framing: partial frames straddling reads are handled by `Receive_Exactly`; zero-length payloads skip the
  read; typed length lower bound 4 and upper bound `Maximum_Message_Size` with a FATAL 08P01 diagnostic.
- Transports: `Connection_Transport`/`Socket_Transport` map timeouts to `Flyology.IO.Timeout_Error` as the
  `Transport` contract requires; `Send_All` delegates partial-write handling to the runtime; `Wait_Observer`
  omission is allowed by the contract. `TLS_Socket_Transport.Upgrade_TLS` closes the taken socket on
  handshake failure (no leak); after that the transport is unusable but only raises, never aliases.
- `Serve_Internal` lifecycle: `Install`/`Clear`/`Free` on normal and exceptional paths; `Request_Shutdown`
  before `Serve` is honoured; capacity = sessions + 1 leaves one worker for cancel connections.
- `Server_Sessions` encoders: RowDescription/DataRow/COPY-response size and count checks, ReadyForQuery
  status validation, ErrorResponse field layout with 5-character SQLSTATE check, SASL message codes 10/11/12.
