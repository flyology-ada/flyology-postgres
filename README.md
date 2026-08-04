# Flyology Postgres

`Flyology.Postgres` is a native Ada implementation of the Postgres frontend/backend
protocol over Flyology I/O. It provides both:

- client primitives that can be called from Flyology native or lightweight tasks; and
- a generic protocol server that hands frontend commands to application-defined Ada
  handlers.

The current development baseline implements protocol 3.0 framing and startup,
simple-query client operation, trust and cleartext-password authentication, and raw
dispatch of every normal frontend command. It interoperates in both directions with
Postgres 18.4: the test client connects to a real Postgres server, and `psql` connects
to the test server.

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

`Flyology.Postgres.Client.Session` borrows a transport. `Startup` performs startup and
authentication, `Send_Query` covers the simple-query path, and `Send_Command` plus
`Receive_Message` expose the lower-level protocol needed to build extended-query and
COPY state machines.

`Flyology.Postgres.Server` is generic over an application context, an authentication
callback, and a command handler. It uses Flyology's structured server and gives each
accepted connection its own Flyology handler task. The handler receives every frontend
command as a `Protocol.Message` and writes responses through
`Flyology.Postgres.Server_Sessions`.

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
- Startup, SSL, GSS encryption, and cancellation requests are decoded. Cancellation
  requests are currently accepted and closed but are not routed to a running handler.
- The library supplies framing, authentication flow, command dispatch, and common
  response constructors. SQL execution, prepared-statement/portal state, transaction
  state, COPY semantics, and result type metadata belong to the application handler.
- Frames are bounded to 16 MiB to prevent unbounded allocation from an untrusted length
  field.

The implementation follows the current official
[message-flow](https://www.postgresql.org/docs/current/protocol-flow.html) and
[message-format](https://www.postgresql.org/docs/current/protocol-message-formats.html)
documentation.

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

GNATprove is intentionally not a library dependency. It lives in the nested proof
environment and can be run with:

```sh
cd proof
alr gnatprove \
  -P ../flyology_postgres.gpr \
  -u flyology-postgres-wire.adb \
  -j0 --level=1 --output=oneline --output-header -f
```

The current result is 245 of 245 checks proved with GNATprove FSF 16.1.0.

## Tests

The nested `tests` crate keeps AUnit out of the library's production dependency graph:

```sh
cd tests
alr build
alr action test
```

The first integration run downloads the official source archive, verifies its SHA-256
checksum, and builds Postgres into `tests/.cache`. Later runs reuse that installation.
The suite starts an isolated real server for the Ada-client test, then starts the Ada
protocol server and queries it with the freshly built `psql`.

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
