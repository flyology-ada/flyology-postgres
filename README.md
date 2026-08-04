# Flyology Postgres

`Flyology.Postgres` is a native Ada implementation of the Postgres frontend/backend
protocol over Flyology I/O. It provides both:

- client primitives that can be called from Flyology native or lightweight tasks; and
- a generic protocol server that hands frontend commands to application-defined Ada
  handlers.

The current development baseline implements protocol 3.2 framing and startup,
typed streaming simple-query results, trust and cleartext-password authentication,
and raw dispatch of every normal frontend command. It interoperates in both
directions with Postgres 18.4: the test client connects to a real Postgres server,
and `psql` connects to the test server. Cancellation uses the official
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

## API outline

`Flyology.Postgres.Protocol` owns and frames wire messages. A frontend message retains
its one-byte tag and complete payload; `Kind` classifies all protocol 3 frontend tags:
`Bind`, `Close`, `CopyData`, `CopyDone`, `CopyFail`, `Describe`, `Execute`, `Flush`,
`FunctionCall`, password/SASL responses, `Parse`, `Query`, `Sync`, and `Terminate`.
Unknown future tags are preserved as `Unknown` messages rather than discarded.
`Decode_Backend` adds an owned typed view of `RowDescription`, `DataRow`,
`CommandComplete`, `EmptyQueryResponse`, `ErrorResponse`, `NoticeResponse`,
`ParameterStatus`, and `ReadyForQuery`. `Original_Message` retains the raw lower-level
message. Row descriptions expose every per-field protocol value. Data rows expose
every column as binary-safe bytes and distinguish NULL from a present zero-length
value. Diagnostic fields are addressable by their protocol code, so future fields are
retained as well as the standard severity, SQLSTATE, and message fields.

`Flyology.Postgres.Client.Session` borrows a transport. `Startup` performs startup and
authentication. `Send_Query` followed by repeated `Receive_Query_Event` calls is the
high-level simple-query path. It returns one owned event at a time rather than
accumulating an unbounded result: each result set is a row description, zero or more
data rows, and a command completion; command-only statements produce a command
completion; an empty query produces an empty-query event; and errors and notices are
returned as typed diagnostics. A final ready event carries the idle, in-transaction,
or failed-transaction state. Multiple statements naturally produce multiple event
sequences before that final ready event. `Send_Command` plus `Receive_Message` remain
the raw lower-level API for extended-query, COPY, and custom state machines.

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

Startup retains variable-length `BackendKeyData`. To cancel,
`Client.Send_Cancel_Request` writes those credentials to a caller-opened distinct
transport, while `Flyology.Postgres.Client_Sockets.Cancel` opens, sends on, and closes
a separate socket. Neither API reads a reply, and the transport-level API rejects the
active session transport by identity.

`Flyology.Postgres.Server` is generic over an application context, an authentication
callback, and a command handler. It uses Flyology's structured server and gives each
accepted connection its own Flyology handler task. The handler receives every frontend
command as a `Protocol.Message` and writes responses through
`Flyology.Postgres.Server_Sessions`. Its `Send_Row_Description` and `Send_Data_Row`
array overloads accept arbitrary field and column counts. `Make_Field_Description`,
`Text_Column`, `Binary_Column`, and `Null_Column` build their values; the original
one-column string and NULL helpers remain available for concise handlers.

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

Two transport adapters are included:

- `Flyology.Postgres.Transports.Connections` for accepted Flyology connections; and
- `Flyology.Postgres.Transports.Sockets` for a directly connected Flyology socket.

## Current boundaries

- Authentication supports `trust` and cleartext passwords. SCRAM/SASL, MD5, GSSAPI,
  SSPI, and certificate authentication are not implemented yet.
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
- The library supplies framing, authentication flow, command dispatch, and common
  response constructors. SQL execution, prepared-statement/portal state, transaction
  state, COPY semantics, and result type metadata belong to the application handler.
- Frames are bounded to 16 MiB to prevent unbounded allocation from an untrusted length
  field. Typed decoding also rejects impossible counts, invalid or truncated lengths,
  missing terminators, invalid format or transaction-state values, and trailing bytes.

The implementation follows the current official
[message-flow](https://www.postgresql.org/docs/current/protocol-flow.html) and
[message-format](https://www.postgresql.org/docs/current/protocol-message-formats.html)
documentation.

## Randomness dependency

Cancellation routing uses the small `system_random` crate, which maps to
`getentropy` on Unix-like systems and `BCryptGenRandom` on Windows. This dependency is
also the appropriate entropy source for SCRAM nonces. A SCRAM branch should reuse the
same crate rather than introduce a second operating-system RNG wrapper; when merging
the two slices, keep one `system_random = "^1.0.0"` manifest entry.

## SPARK proof boundary

`Flyology.Postgres.Wire` is an allocation-free SPARK core used by the production
protocol facade. GNATprove verifies arbitrary-bound array indexing, endian encoding
and decoding, total status-returning cursor reads, bounded byte views, frame-length
conversions, earliest-NUL search, initial/startup packet structure, protocol 3.2
variable cancellation keys, exact source correspondence for recognized startup
parameters and special requests, loop termination, and the package's functional
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
```

The current result is 251 of 251 checks proved with GNATprove FSF 16.1.0.

## Tests

The nested `tests` crate keeps AUnit out of the library's production dependency graph:

```sh
cd tests
alr build
alr action test
```

The first integration run downloads the official source archive, verifies its SHA-256
checksum, and builds Postgres into `tests/.cache`. Later runs reuse that installation.
The suite starts an isolated real server for the Ada-client test, verifies typed query
streaming and cancellation of `pg_sleep`, then starts the Ada protocol server and
queries it with the freshly built `psql`.
The real-server direction covers multiple columns and rows, NULL and empty values,
multiple statements and result sets, command-only and empty queries, notices,
parameter status, errors, and recovery. The `psql` direction verifies that the
Flyology server emits a multi-column, multi-row result with both NULL and empty text.
Server-side tests cover correct, incorrect, stale, duplicate, and
concurrent credentials, verify silent cancellation-connection close, and confirm a
valid request stops a polling Flyology handler with SQLSTATE `57014`.

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
