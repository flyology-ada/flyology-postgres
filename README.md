# Flyology Postgres

`Flyology.Postgres` is a native Ada implementation of the Postgres frontend/backend
protocol over Flyology I/O. It provides both:

- client primitives that can be called from Flyology native or lightweight tasks; and
- a generic protocol server that hands frontend commands to application-defined Ada
  handlers.

The current development baseline implements protocol 3.2 framing and startup,
typed streaming simple- and extended-query results, prepared statements and
portals, streaming `COPY IN`, `COPY OUT`, and `COPY BOTH`, trust,
cleartext-password, and SCRAM-SHA-256 authentication, and raw dispatch of every
normal frontend command. It interoperates in both directions with Postgres 18.4:
the test client connects to a real Postgres SCRAM server, and `psql` connects to
the Flyology SCRAM test server. Cancellation uses the official
separate-connection flow in both directions.

## Development setup

For fast iteration, the manifest pins Flyology to the sibling checkout:

```sh
alr -n with flyology --use=../flyology
alr build
```

The checked-in manifest already contains that dependency and pin. Published
development builds will replace the path pin with the Flyology Alire index described
in the [Flyology guide](https://flyology.org/guide/).

SCRAM uses two small dependencies with no transitive production crates:

- `hmac_ada ^0.2.0` supplies SPARK-proved SHA-256 and HMAC-SHA-256, explicit
  intermediate-key wiping, and constant-time digest equality; and
- `system_random ^1.0.0` obtains nonce bytes directly from `getentropy` on Unix-like
  systems and `BCryptGenRandom` on Windows.

No OpenSSL, TLS, or general-purpose cryptography framework is added.

## Examples

- [`psqlish`](examples/psqlish/README.md) is a compact, polished
  `psql`-like client with a multiline REPL, catalog commands, bounded table
  rendering, and real Postgres authentication.
- [`pgish`](examples/pgish/README.md) is a small read-only Postgres-like server
  with a bounded SQL subset and virtual Flyology, session, repository, runtime,
  settings, and catalog tables.

Both are independent nested Alire crates. They share a loopback default so
`psqlish` and real `psql` can be used directly against `pgish`.

## API outline

`Flyology.Postgres.Protocol` owns and frames wire messages. A frontend message retains
its one-byte tag and complete payload; `Kind` classifies all protocol 3 frontend tags:
`Bind`, `Close`, `CopyData`, `CopyDone`, `CopyFail`, `Describe`, `Execute`, `Flush`,
`FunctionCall`, password/SASL responses, `Parse`, `Query`, `Sync`, and `Terminate`.
Unknown future tags are preserved as `Unknown` messages rather than discarded.
`Decode_Backend` adds an owned typed view of `RowDescription`, `DataRow`,
`CommandComplete`, `EmptyQueryResponse`, `ErrorResponse`, `NoticeResponse`,
`ParameterStatus`, `ParseComplete`, `BindComplete`, `CloseComplete`,
`ParameterDescription`, `NoData`, `PortalSuspended`, all three COPY responses,
`CopyData`, `CopyDone`, and `ReadyForQuery`.
`Original_Message` retains the raw lower-level message. Row descriptions expose every
per-field protocol value, and parameter descriptions retain every parameter OID. Data
rows expose
every column as binary-safe bytes and distinguish NULL from a present zero-length
value. Diagnostic fields are addressable by their protocol code, so future fields are
retained as well as the standard severity, SQLSTATE, and message fields.

Typed frontend constructors encode `Parse`, `Bind`, `Describe`, `Execute`, `Close`,
`Flush`, `Sync`, `CopyData`, `CopyDone`, and `CopyFail`. Empty names select unnamed
statements or portals. Parse accepts
parameter OIDs, including zero for an unspecified type. Each Bind value is built with
`Text_Parameter`, `Binary_Parameter`, or `Null_Parameter`, so its format stays attached
to its bytes. Bind uses Postgres's zero-, one-, or per-parameter format-code forms,
supports independent result format codes, and preserves the distinction between NULL
and an empty value. Execute accepts Postgres's nonnegative signed 32-bit maximum-row
count; zero means unlimited.

`Flyology.Postgres.Client.Session` borrows a transport. `Startup` performs startup and
authentication. `Send_Query` followed by repeated `Receive_Query_Event` calls is the
high-level simple-query path. It returns one owned event at a time rather than
accumulating an unbounded result: each result set is a row description, zero or more
data rows, and a command completion; command-only statements produce a command
completion; an empty query produces an empty-query event; and errors and notices are
returned as typed diagnostics. A final ready event carries the idle, in-transaction,
or failed-transaction state. Multiple statements naturally produce multiple event
sequences before that final ready event. `Send_Command` plus `Receive_Message` remain
the raw lower-level API for direct protocol control and custom state machines.

The task-friendly extended path consists of `Prepare_Statement`, `Bind_Portal`,
`Describe_Statement`, `Describe_Portal`, `Execute_Portal`, `Resume_Portal`,
`Close_Statement`, `Close_Portal`, `Flush`, `Synchronize`, and repeated
`Receive_Extended_Event` calls. Commands can be pipelined before Sync, and Flush
forces pending output without ending the cycle. `State` exposes ready, active simple,
extended, and COPY operations, COPY completion, recovery-required, and awaiting-ready
states. Invalid local
ordering, such as Execute before Bind or Resume before `PortalSuspended`, is rejected
before writing. After an extended `ErrorResponse`, only Sync (or termination) is
accepted; the session becomes reusable only after the corresponding `ReadyForQuery`.
A Sync already pipelined before the error satisfies the same rule.

A bounded streaming extended flow is:

```ada
Client.Prepare_Statement
  (Session, "items", "select id, value from items where id > $1", (1 => 23));
Client.Bind_Portal
  (Session,
   Portal_Name    => "items_page",
   Statement_Name => "items",
   Parameters     => (1 => Protocol.Text_Parameter ("100")));
Client.Describe_Portal (Session, "items_page");
Client.Execute_Portal (Session, "items_page", Maximum_Rows => 50);
Client.Flush (Session);

loop
   declare
      Event : constant Client.Extended_Query_Event :=
        Client.Receive_Extended_Event (Session);
   begin
      --  Consume RowDescription/DataRow events as they arrive.
      exit when Protocol.Response_Kind (Event) in
        Protocol.Command_Complete_Response |
        Protocol.Portal_Suspended_Response |
        Protocol.Error_Response;
   end;
end loop;

--  Resume after PortalSuspended, or synchronize when finished.
Client.Synchronize (Session);
loop
   exit when Protocol.Response_Kind
     (Client.Receive_Extended_Event (Session)) =
       Protocol.Ready_For_Query_Response;
end loop;
```

A typical streaming loop is:

```ada
Client.Send_Query (Session, "select id, value from items");
loop
   declare
      Event : constant Client.Simple_Query_Event :=
        Client.Receive_Query_Event (Session);
   begin
      case Protocol.Response_Kind (Event) is
         when Protocol.Row_Description_Response =>
            --  Inspect Protocol.Description (Event).
            null;
         when Protocol.Data_Row_Response =>
            --  Consume Protocol.Row_Data (Event).
            null;
         when Protocol.Error_Response | Protocol.Notice_Response =>
            --  Inspect Protocol.Diagnostic_Data (Event).
            null;
         when others =>
            null;
      end case;
      exit when Protocol.Response_Kind (Event) =
        Protocol.Ready_For_Query_Response;
   end;
end loop;
```

### Streaming COPY

A `CopyInResponse`, `CopyOutResponse`, or `CopyBothResponse` is returned by the
same simple- or extended-query receive call that started the operation. Its
`Copy_Format_Description` retains the overall text/binary code and every
per-column code. `State` then reports `Copy_In_Active`, `Copy_Out_Active`, or
`Copy_Both_Active`.

For a writable direction, call `Send_Copy_Data` once per bounded chunk and then
`Finish_Copy`; `Abort_Copy` sends `CopyFail` with a server-visible reason. For a
readable direction, each `Receive_Copy_Event` returns one `CopyData` frame.
`CopyDone`, `CommandComplete`, errors, notices, parameter status, and
`ReadyForQuery` are also returned individually. No API in this path collects a
COPY stream.

```ada
Client.Send_Query (Session, "copy measurements from stdin (format text)");
declare
   Started : constant Client.Simple_Query_Event :=
     Client.Receive_Query_Event (Session);
begin
   --  Inspect Protocol.Copy_Formats (Started), then stream bounded chunks.
   Client.Send_Copy_Data (Session, First_Chunk);
   Client.Send_Copy_Data (Session, Second_Chunk);
   Client.Finish_Copy (Session);
end;

--  Receive CommandComplete as a Copy_Event, then the simple-query
--  ReadyForQuery as a Simple_Query_Event.
```

For simple-query COPY, graceful `CommandComplete` returns to
`Simple_Query_Active` until the final query event; an error or client abort keeps
the COPY receiver active through `ReadyForQuery` so recovery cannot be skipped.
For extended COPY, `Sync` is mandatory. COPY OUT may pipeline `Sync` after
`Execute`; COPY IN and the writable half of COPY BOTH send it after local
`CopyDone`/`CopyFail`. A server error without an already pending `Sync` enters
`Recovery_Required`, matching other extended-query operations. Cancellation is
reported as the server's normal error and recovery sequence.

Startup retains variable-length `BackendKeyData`. To cancel,
`Client.Send_Cancel_Request` writes those credentials to a caller-opened distinct
transport, while `Flyology.Postgres.Client_Sockets.Cancel` opens, sends on, and closes
a separate socket. Neither API reads a reply, and the transport-level API rejects the
active session transport by identity.

`Flyology.Postgres.Server` is generic over an application context, the existing
trust/cleartext authentication callback, a SCRAM verifier lookup callback, and a
command handler. It uses Flyology's structured server and gives each accepted
connection its own Flyology handler task. The handler receives every frontend command
as a `Protocol.Message` and writes responses through
`Flyology.Postgres.Server_Sessions`. Its `Send_Row_Description` and `Send_Data_Row`
array overloads accept arbitrary field and column counts. `Make_Field_Description`,
`Text_Column`, `Binary_Column`, and `Null_Column` build their values; the original
one-column string and NULL helpers remain available for concise handlers.

COPY handlers use `Send_Copy_In_Response`, `Send_Copy_Out_Response`, or
`Send_Copy_Both_Response`, followed by bounded `Send_Copy_Data` calls and
`Send_Copy_Done`. `Read_Copy_Command` strictly dispatches one client
`CopyData`, `CopyDone`, or `CopyFail` frame at a time; accessors expose the chunk
or failure reason while `Original_Message` preserves the raw command. This lets
custom handlers apply backpressure and stream directly to application storage.

A handler can poll
`Server_Sessions.Cancellation_Requested`; it becomes true for a matching cancellation
of that handler operation and for forced structured-server shutdown. The token is
fresh for each command, so cancellation does not leak into the next operation.

The server advertises protocol 3.2 and emits 32-byte cancellation secrets for 3.2
peers. Protocol 3.0 peers retain the required legacy 4-byte `BackendKeyData` shape.
Backend process IDs and secrets come directly from the operating system's
cryptographic random source. Registrations are removed when a session ends, and valid,
invalid, stale, and duplicate requests all receive the same externally observable
behavior: the cancellation connection closes silently with no response.

For `SCRAM_SHA_256`, `Lookup_SCRAM_Verifier` returns the exact Postgres credential
form `SCRAM-SHA-256$<iterations>:<salt>$<StoredKey>:<ServerKey>`, or an empty string
for an unknown/uncredentialed user. The server never requests, receives, or retains
that user's plaintext password. Unknown users are challenged with a static precomputed
dummy verifier: real and dummy verifier text follows the same per-attempt parsing and
constant-time proof-verification path, with no PBKDF2 derivation on the server's
username-controlled authentication path. Unknown users are rejected after proof
verification regardless of the supplied password.

This adds one required generic formal to every `Flyology.Postgres.Server`
instantiation, including trust and cleartext instances. Existing instances should add
a `Lookup_SCRAM_Verifier` function; returning `""` is sufficient when the selected
mode is not SCRAM. The behavior of `Trust` and `Cleartext_Password` is unchanged.

Two transport adapters are included:

- `Flyology.Postgres.Transports.Connections` for accepted Flyology connections; and
- `Flyology.Postgres.Transports.Sockets` for a directly connected Flyology socket.

Symbolic traceback capture with GNAT's `-Es` binder switch is supported for
Flyology lightweight tasks by the pinned Flyology revision. Flyology commit
`4a9cc29735a18f762ea241693504263e6b30fc1f` gives each fresh fiber stack an
explicit unwind root: traceback capture includes the active fiber and stops
before the unrelated scheduler stack. The library and tests retain `-Es`, and
the fast suite raises and catches an exception on a lightweight task to validate
that capability at this dependency boundary.

## Current boundaries

- Authentication supports `trust`, cleartext passwords, and SCRAM-SHA-256. MD5,
  GSSAPI, SSPI, certificate authentication, and SCRAM-SHA-256-PLUS are not
  implemented.
- TLS is intentionally deferred until Flyology can upgrade an accepted connection
  without losing connection ownership or buffered-byte safety. The server answers an
  `SSLRequest` with `N`; the client currently starts in plaintext without requesting
  TLS.
- Cleartext-password authentication must only be used on a trusted test or private
  network until TLS is available.
- Cancellation connections are currently plaintext because TLS itself is deferred.
  Applications that require encrypted cancellation should wait for the transport
  upgrade support noted above; the current libpq cancellation API reuses the original
  connection's encryption and host-verification requirements.
- Flyology lightweight tasks are cooperatively scheduled. A COPY OUT socket that is
  continuously readable may not suspend the receiving lightweight task, so a delayed
  canceller on the same execution group can be starved. Issue cancellation from an
  independently scheduled task, or add an explicit Flyology fairness/yield point in
  a long-running receive loop. The one-frame-per-call API naturally returns control
  to the application after every `CopyData`, where it can yield, inspect its own
  cancellation state, or send a cancellation request. The integration test
  deterministically consumes one COPY frame, synchronously sends the separate-
  connection cancellation, and verifies SQLSTATE `57014` plus `ReadyForQuery`
  recovery.
- SCRAM nonces contain 18 bytes from the operating system cryptographic random source.
  Iteration counts are accepted from 4,096 through 1,000,000, SCRAM messages are
  bounded to 4 KiB, proofs and signatures use constant-time comparison, and sensitive
  derived intermediates are wiped where the compiler-supported mechanism permits.
- The library supplies framing, authentication flow, COPY/query state machines,
  command dispatch, and common response constructors. SQL execution,
  prepared-statement/portal state, transaction state, interpretation of COPY
  contents, and result type metadata belong to the application handler.
- Frames are bounded to 16 MiB to prevent unbounded allocation from an untrusted length
  field; a COPY chunk is one frame with at most 16 MiB minus the four-byte length
  field. Typed decoding also rejects impossible counts, invalid or truncated lengths,
  missing terminators, invalid format or transaction-state values, and trailing bytes.
  Large COPY values must be split across frames by the sender.

The implementation follows the current official
[message-flow](https://www.postgresql.org/docs/current/protocol-flow.html) and
[message-format](https://www.postgresql.org/docs/current/protocol-message-formats.html)
documentation, Postgres's
[SASL authentication flow](https://www.postgresql.org/docs/current/sasl-authentication.html),
[RFC 5802](https://www.rfc-editor.org/rfc/rfc5802), and
[RFC 7677](https://www.rfc-editor.org/rfc/rfc7677).

### Password normalization boundary

`Client.Startup.Password` and `SCRAM.Make_Verifier_Raw` treat an Ada `String` as an
exact octet sequence. Flyology Postgres does **not** implement SASLprep, Unicode
normalization, or Postgres's valid-UTF-8-then-SASLprep fallback. ASCII passwords are
fully interoperable. Non-ASCII passwords interoperate only when the verifier was
derived from the same exact octets and no normalization is required; callers needing
Postgres's normalization semantics must normalize before calling, or provision the
server with a verifier created by Postgres. This boundary is explicit rather than
silently claiming full SASLprep support.

## Randomness dependency

Cancellation routing uses the small `system_random` crate, which maps to
`getentropy` on Unix-like systems and `BCryptGenRandom` on Windows. This dependency is
also used for SCRAM nonces, so both security-sensitive paths share one operating-system
RNG dependency.

## SPARK proof boundary

`Flyology.Postgres.Wire` is an allocation-free SPARK core used by the production
protocol facade. `Flyology.Postgres.SCRAM_Core` adds bounded PBKDF2-HMAC-SHA-256,
digest hashing/XOR, and wipe glue over the proved `hmac_ada` primitives. GNATprove
verifies arbitrary-bound array indexing, endian encoding and decoding, total
status-returning cursor reads, bounded byte views, frame-length conversions,
extended-protocol format-count validity, exact COPY-response lengths and format-code
validity, earliest-NUL search, initial/startup packet structure, protocol 3.2
variable cancellation keys, exact source correspondence for recognized startup
parameters and special requests, SCRAM core bounds, loop termination, and the
packages' functional
contracts.
The Flyology transports, heap-backed owned messages, tasking, and socket adapters
remain conventional Ada outside this boundary.

The cancellation registry, cryptographic credential generation, and token routing are
intentionally conventional Ada. `Encode_Cancel_Request` composes the already-proved
endian primitives without expanding the SPARK proof boundary.

GNATprove is intentionally not a library dependency. It lives in the nested proof
environment and can be run with:

```sh
cd proof
alr gnatprove \
  -P ../flyology_postgres.gpr \
  -u flyology-postgres-wire.adb \
  -j0 --level=1 --output=oneline --output-header -f
alr gnatprove \
  -P ../flyology_postgres.gpr \
  -u flyology-postgres-scram_core.adb \
  -j0 --level=1 --output=oneline --output-header -f
```

The current GNATprove FSF 16.1.0 result on the combined source is 291 of 291
checks proved: 257 wire-core checks and 34 SCRAM-core checks. The wire core adds
no warnings or assumptions. The SCRAM core reports five termination assumptions
at calls into `hmac_ada`'s SHA-256 and HMAC operations because those dependency
entry points do not expose `Always_Terminates`; no run-time or functional check
is left unproved.

## Tests

The nested `tests` crate keeps AUnit out of the library's production dependency graph:

```sh
cd tests
alr build
alr action test
```

The first integration run downloads the official source archive, verifies its SHA-256
checksum, and builds Postgres into `tests/.cache`. Later runs reuse that installation.
The unit suite combines typed backend decoding and malformed-message coverage with the
RFC 7677 SCRAM-SHA-256 transcript, verifier round trips, wrong-password proof
rejection, and malformed verifier/final-message rejection. COPY fixtures cover all
frontend constructors, all backend response kinds, mixed text/binary formats,
malformed counts and codes, simple and extended transitions, abort/recovery, and
bidirectional streaming. `COPY BOTH` uses an exact protocol fixture because a real
server exercise would require replication setup.
The fast suite also raises and catches a marked exception on a lightweight fiber,
regressing normal Ada exception reporting and symbolic traceback capture with
the `-Es` binder switch.

The integration suite starts an isolated real SCRAM server for the Ada client, verifies
typed query streaming and cancellation of `pg_sleep`, then starts the Flyology SCRAM
protocol server and queries it with the freshly built `psql`.
The real-server direction covers multiple columns and rows, NULL and empty values,
multiple statements and result sets, command-only and empty queries, notices,
parameter status, errors, and recovery. The extended real-server flow covers named
and unnamed statements and portals, multiple parameter OIDs, text/binary/NULL values,
statement and portal Describe, mixed result formats, streamed rows, max-row
`PortalSuspended` and resume, Close, Flush, Sync, and mandatory error recovery. It
also covers simple and extended `COPY TO STDOUT`/`COPY FROM STDIN`, text and binary
output, multiple chunks, NULL versus empty text, `CopyFail`, malformed input, and
post-error reuse, plus synchronous separate-connection cancellation during an active
COPY OUT stream. The
`psql` direction verifies that the Flyology server emits a multi-column, multi-row
result with both NULL and empty text, performs `\copy` in both directions through
the streaming server helpers, then uses Postgres 18's named prepared-
statement commands and asserts raw dispatch of Parse, Bind, Describe, Execute, Close,
and Sync. It also rejects both a wrong password and an unknown user through real
SCRAM exchanges. Server-side tests cover correct, incorrect, stale, duplicate, and
concurrent cancellation credentials, verify silent cancellation-connection close,
and confirm a valid request stops a polling Flyology handler with SQLSTATE `57014`.

Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `POSTGRES_VERSION` | `18.4` | Stable numeric Postgres source version to build |
| `POSTGRES_CACHE_DIR` | `tests/.cache/postgres` | Reusable source/build/install cache |
| `POSTGRES_BUILD_JOBS` | `4` | Parallel build jobs |
| `POSTGRES_CONFIGURE_ARGS` | empty | Additional arguments passed to `configure` |
| `POSTGRES_INTEGRATION` | `1` | Set to `0` to run only the fast unit tests |
| `POSTGRES_TEST_PORT` | `55433` | Port for the real Postgres server |
| `POSTGRES_PSQL_TEST_PORT` | `55432` | Port for the Flyology test server |

## License

Licensed under either the MIT License or the Apache License, Version 2.0, at your
option (`MIT OR Apache-2.0`).
