# Flyology Postgres

`Flyology.Postgres` is a native Ada implementation of the Postgres frontend/backend
protocol over Flyology I/O. It provides both:

- client primitives that can be called from Flyology native or lightweight tasks; and
- a generic protocol server that hands frontend commands to application-defined Ada
  handlers.

The current development baseline implements protocol 3.2 framing and startup,
verified TLS for clients and servers,
typed streaming simple- and extended-query results, prepared statements and
portals, streaming `COPY IN`, `COPY OUT`, and `COPY BOTH`, trust,
cleartext-password, and SCRAM-SHA-256 authentication, and raw dispatch of every
normal frontend command. It interoperates over verified TLS in both directions with
Postgres 18.4: the test client connects to a real Postgres TLS/SCRAM server, and
`psql` connects with `sslmode=verify-full` to the Flyology TLS/SCRAM test server.
Cancellation uses the official encrypted separate-connection flow in both
directions. Replication interoperability is tested against PostgreSQL 14 through
18 as a Flyology client of a real primary, as a real recovery-mode PostgreSQL
standby of a Flyology primary, and as real `pg_recvlogical` consuming
Flyology's `pgoutput` producer.

## Development setup

Configure the Flyology organization index, then build against its published
Flyology release:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr build
```

The checked-in manifest declares `flyology ~0.1.1-dev` as a regular dependency;
Alire resolves it from that index. See the
[Flyology guide](https://flyology.org/guide/) for runtime setup details.

SCRAM uses two small dependencies with no transitive production crates:

- `hmac_ada ^0.2.0` supplies SPARK-proved SHA-256 and HMAC-SHA-256, explicit
  intermediate-key wiping, and constant-time digest equality; and
- `system_random ^1.0.0` obtains nonce bytes directly from `getentropy` on Unix-like
  systems and `BCryptGenRandom` on Windows.

TLS uses Flyology's provider-neutral, ownership-preserving upgrade API. The
shipped Flyology OpenSSL 3 provider is loaded at run time, so this crate adds no
link-time OpenSSL dependency and applications may supply another provider.

## Examples

- [`psqlish`](examples/psqlish/README.md) is a compact, polished
  `psql`-like client with a multiline REPL, catalog commands, bounded table
  rendering, verified TLS, and real Postgres authentication.
- [`pgish`](examples/pgish/README.md) is a small read-only Postgres-like server
  with a bounded SQL subset and virtual Flyology, session, repository, runtime,
  settings, and catalog tables. Certificate/key configuration enables required
  TLS.

Both are independent nested Alire crates. Their integration suite uses an
ephemeral CA so `psqlish` and real `psql` exercise verified TLS against `pgish`.

## Versioned SQL parser and catalog types

The nested SQL crates contain isolated native PostgreSQL 14–18 raw parsers and
fully generated Ada 2022 syntax-tree APIs. Normal applications depend on a
single `flyology_postgres_sql_vNN` crate, such as
`flyology_postgres_sql_v18`; applications may combine several version crates,
which link their shared core once. The `flyology_postgres_sql` crate remains the
all-version compatibility umbrella. These build choices do not change the Ada
package names. The default `SQL.AST.V14`–`V18` packages return fully owned,
naturally navigable Ada records. Allocation-sensitive consumers can explicitly
select the flat-arena `SQL.Views.V14`–`V18` API. Both retain discriminated
optionals, exact-width scalars, generated enums, and owned text. Generated
catalog layers also expose built-in PostgreSQL type metadata and OID constants
for every supported major. See the [SQL guide](sql/README.md) for dependency
and GPR examples.

`pgish` validates input with the PostgreSQL 18 grammar before applying its
deliberately bounded read-only evaluator subset.

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

`Flyology.Postgres.Client.Session` borrows a transport. `Startup` performs plaintext
startup and authentication. `Startup_TLS` first sends the exact Postgres
`SSLRequest`, requires an `S` response without downgrade fallback, upgrades the same
transport, verifies the server chain and DNS name through the selected Flyology TLS
provider, and only then sends credentials. Any negotiation or encrypted-startup
failure permanently closes the session state. `Send_Query` followed by repeated
`Receive_Query_Event` calls is the
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
`Receive_Extended_Event` calls. Commands can be written back to back before Sync,
and Flush forces pending output without ending the cycle. `Enter_Pipeline_Mode`
extends that to whole batches, described under Pipelined batches below. `State`
exposes ready, active simple,
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

### Pipelined batches

By default the session finishes one Sync-terminated batch before it writes the
next command, so every batch costs a round trip. `Enter_Pipeline_Mode` lifts
that restriction. After `Synchronize`, the next `Prepare_Statement`,
`Bind_Portal`, `Describe_Statement`, `Describe_Portal`, `Execute_Portal`, or
`Close_Statement`/`Close_Portal` call opens the following batch at once, so
several batches stay in flight. `Pending_Synchronizations` counts the batches
whose `ReadyForQuery` has not arrived, `In_Pipeline_Mode` reports the mode, and
`Exit_Pipeline_Mode` returns the session to one batch at a time once every
batch has been consumed.

Responses arrive in the order the batches were written, and each
`ReadyForQuery` ends exactly one batch. Each batch's own Sync contains its
failure: the server discards the rest of that batch, sends its `ReadyForQuery`,
and then processes the batch behind it normally, so the session does not enter
`Recovery_Required`. A batch that fails before its Sync is written still needs
`Synchronize`, exactly as it does outside pipeline mode. Local ordering checks
such as Execute before Bind apply per batch and reset at each Sync.

PostgreSQL sends `RowDescription` only in reply to `Describe_Portal` or
`Describe_Statement`, so a portal executed without one returns bare rows.
`Receive_Extended_Event` accepts them, and checks the column count only against
a description the server actually sent. Describe a batch when you want that
check, or skip it to save a message per batch.

Simple queries are rejected while the mode is active, because a simple query
carries no Sync boundary of its own. A COPY response is rejected too, and that
rejection is terminal: the response is already consumed and the server is
already streaming, so the session closes and its transport must be discarded.
Leave pipeline mode before starting COPY.

A pipeline that writes far more than it reads can block. The server stops
reading once its own output buffer fills, and the client then blocks writing
into a full socket buffer. Interleave `Receive_Extended_Event` calls with the
writes, or keep the outstanding bytes below the socket buffers.

```ada
Client.Enter_Pipeline_Mode (Session);
Client.Prepare_Statement
  (Session, "insert_row", "insert into items (value) values ($1)",
   (1 => 25));

for Value of Values loop
   Client.Bind_Portal
     (Session,
      Portal_Name    => "",
      Statement_Name => "insert_row",
      Parameters     => (1 => Protocol.Text_Parameter (Value)));
   Client.Execute_Portal (Session, "");
   Client.Synchronize (Session);
end loop;

--  Every batch is already written before the first response is read.
while Client.Pending_Synchronizations (Session) > 0 loop
   declare
      Event : constant Client.Extended_Query_Event :=
        Client.Receive_Extended_Event (Session);
   begin
      if Protocol.Response_Kind (Event) = Protocol.Error_Response then
         --  Inspect Protocol.Diagnostic_Data (Event). The batches behind
         --  this one still run.
         null;
      end if;
   end;
end loop;

Client.Exit_Pipeline_Mode (Session);
```

The example prepares `insert_row` inside the first batch, so every later batch
depends on it. If that statement fails to parse, the server abandons the rest
of the first batch and each following `Bind_Portal` then fails with
`prepared statement "insert_row" does not exist`. Prepare in a batch that the
loop drains first when the SQL is not already known to be valid.

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
COPY BOTH also accepts bounded data already crossed in flight after the two
directions close and before `CommandComplete`, matching real PostgreSQL
replication shutdown ordering.
For extended COPY, `Sync` is mandatory. COPY OUT may pipeline `Sync` after
`Execute`; COPY IN and the writable half of COPY BOTH send it after local
`CopyDone`/`CopyFail`. A server error without an already pending `Sync` enters
`Recovery_Required`, matching other extended-query operations. Cancellation is
reported as the server's normal error and recovery sequence.

### Streaming replication

`Flyology.Postgres.Replication` adds replication startup modes, typed
`IDENTIFY_SYSTEM`, `SHOW`, `TIMELINE_HISTORY`, physical and logical
`START_REPLICATION` commands, LSN conversion, and all four messages carried by
replication `CopyData`: `XLogData`, `PrimaryKeepalive`,
`StandbyStatusUpdate`, and `HotStandbyFeedback`. Constructors and strict
decoding are symmetric, retain arbitrary WAL bytes, and accept timestamps
before the PostgreSQL epoch.

`Flyology.Postgres.Replication.Base_Backups` provides native `BASE_BACKUP`
without invoking `pg_basebackup`. Typed, major-gated options cover PostgreSQL
14 through 18; a `Receiver` emits start/end LSNs and timelines, nullable
tablespace metadata, archive boundaries, one bounded archive or manifest chunk,
progress, diagnostics, and completion. PostgreSQL 14's separate COPY streams
and PostgreSQL 15+'s multiplexed `n`/`m`/`d`/`p` frames share the same event
surface. PostgreSQL 17+ manifest upload uses the existing bounded COPY IN path
before an incremental backup. See [Native BASE_BACKUP](docs/BASE_BACKUP.md) for
the API, compatibility matrix, cancellation/security rules, and psqlbench
migration sequence.

`Flyology.Postgres.Replication.Logical` builds, encodes, and decodes every
`pgoutput` message at its natural level: transaction control, transaction
metadata, or row change. It supports protocol v1 committed transactions, v2
streamed in-progress
transactions (PostgreSQL 14), v3 two-phase transactions (15), and v4 parallel
streaming abort metadata (16 and later). Relation columns, tuple values,
replica identity, old/key/new tuple roles, truncate flags, logical messages,
origins, stream segments, and prepared-transaction GIDs remain typed and
owned. The stateful decoder inserts the streamed XID only between
`StreamStart` and `StreamStop`; stream commit, abort, and prepare messages are
decoded after that segment has stopped.

`Flyology.Postgres.Replication.Persistence` defines application-supplied
interfaces for physical and logical slots, WAL retention, timeline history and
promotion, and prepared-consumer state. Slot mutations use generation leases,
advance monotonically only after the backend reports durability, and expose the
oldest restart LSN as the WAL retention floor. The generic
`Persistence.Memory` child is a bounded volatile reference implementation for
tests and ephemeral single-owner servers, not a crash-durable store.

`Logical.Producer` validates transaction ordering while encoding the existing
typed messages as `pgoutput`. The generic `Managed_Primary` composes slot, WAL,
timeline, and application logical-source implementations with replication
server sessions. `Prepared_Consumer` separates durable prepare, idempotent
target application, durable applied marking, source acknowledgement, and final
removal so a replacement consumer can resume the same store safely.

The existing bounded COPY BOTH path carries replication without a second
framing stack:

```ada
Client.Startup
  (Session,
   User             => "replicator",
   Database         => "app",
   Password         => Password,
   Replication_Mode => Protocol.Logical_Replication_Connection);

Client.Send_Command
  (Session,
   Replication.Start_Logical
     ("subscriber_1",
      Position,
      (Replication.Option ("proto_version", "4"),
       Replication.Option ("publication_names", "app_publication"),
       Replication.Option ("streaming", "parallel"))));

--  Receive CopyBothResponse with Receive_Query_Event, then configure once.
Logical.Configure (Decoder, Version => 4, Streaming => Logical.Parallel);

loop
   declare
      Event : constant Client.Copy_Event := Client.Receive_Copy_Event (Session);
   begin
      if Protocol.Response_Kind (Event) = Protocol.Copy_Data_Response then
         declare
            Frame : constant Replication.Stream_Message :=
              Replication.Decode (Protocol.Original_Message (Event));
         begin
            if Replication.Kind (Frame) = Replication.XLog_Data then
               declare
                  Change : constant Logical.Message :=
                    Logical.Decode (Decoder, Replication.Data (Frame));
               begin
                  --  Dispatch Logical.Kind (Change) without buffering the WAL.
                  null;
               end;
            end if;
         end;
      end if;
   end;
end loop;
```

Use `Physical_Replication_Connection` with `Start_Physical` for raw WAL. The
frontend status and hot-standby feedback constructors return ordinary
`Protocol.Message` values for the writable COPY direction.

For the primary direction, `Decode_Command` classifies and validates
`IDENTIFY_SYSTEM`, `SHOW`, `TIMELINE_HISTORY`, and physical or logical
`START_REPLICATION`, with typed access to its slot, LSN, timeline, parameter,
and logical options. `Flyology.Postgres.Replication.Server_Sessions` completes
the corresponding simple-query responses and provides bounded COPY BOTH
operations for WAL, keepalives, and standby feedback:

```ada
declare
   Command : constant Replication.Command :=
     Replication.Decode_Command (Message);
begin
   case Replication.Kind (Command) is
      when Replication.Identify_System_Command =>
         Replication_Sessions.Send_Identify_System
           (Client, System_Id, Timeline, Current_WAL, Timeout => 10.0);
      when Replication.Start_Physical_Command =>
         Replication_Sessions.Begin_Streaming (Client, Timeout => 10.0);
         Replication_Sessions.Send_XLog_Data
           (Client,
            WAL_Start => Replication.Position (Command),
            WAL_End   => Current_WAL,
            Sent_At   => Now,
            Data      => WAL_Chunk,
            Timeout   => 10.0);
         declare
            Feedback : constant Replication.Stream_Message :=
              Replication_Sessions.Read_Standby_Message
                (Client, Timeout => 10.0);
         begin
            --  Apply StandbyStatusUpdate or HotStandbyFeedback.
            null;
         end;
      when others =>
         null;
   end case;
end;
```

Startup retains variable-length `BackendKeyData`. To cancel,
`Client.Send_Cancel_Request` writes those credentials to a caller-opened distinct
transport, while `Flyology.Postgres.Client_Sockets.Cancel` opens, sends on, and closes
a separate socket. Neither API reads a reply, and the transport-level API rejects the
active session transport by identity. `Client_Sockets.Cancel_TLS` performs the same
flow after a required, verified TLS upgrade using the original server name and TLS
policy.

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

Three transport adapters are included:

- `Flyology.Postgres.Transports.Connections` for accepted Flyology connections;
- `Flyology.Postgres.Transports.Sockets` for a directly connected plaintext Flyology
  socket; and
- `Flyology.Postgres.Transports.TLS_Sockets` for a socket that is upgraded in place
  after PostgreSQL accepts TLS and thereafter owns the encrypted connection.

The generic server's `Serve_TLS` accepts a configured provider and either
`TLS_Allowed` or `TLS_Required`; required mode rejects direct plaintext startup.
The original `Serve` remains an explicit plaintext API. `Client_Sockets.Cancel_TLS`
uses a new verified TLS connection for the official separate-connection cancellation
flow.

Symbolic traceback capture with GNAT's `-Es` binder switch is supported for
Flyology lightweight tasks by the indexed Flyology release. Flyology commit
`4a9cc29735a18f762ea241693504263e6b30fc1f` gives each fresh fiber stack an
explicit unwind root: traceback capture includes the active fiber and stops
before the unrelated scheduler stack. The library and tests retain `-Es`, and
the fast suite raises and catches an exception on a lightweight task to validate
that capability at this dependency boundary.

## Current boundaries

- Authentication supports `trust`, cleartext passwords, and SCRAM-SHA-256. MD5,
  GSSAPI, SSPI, certificate authentication, and SCRAM-SHA-256-PLUS are not
  implemented.
- TLS clients always verify the peer chain and DNS name because Flyology's shipped
  provider intentionally has no insecure client mode. The server does not yet request
  client certificates.
- TLS uses PostgreSQL's traditional `SSLRequest` negotiation. PostgreSQL 17's
  `sslnegotiation=direct` mode, which starts TLS immediately on the TCP connection,
  is not implemented.
- `Startup` and `Cancel` remain explicit plaintext APIs for trusted test or private
  networks. Use `Startup_TLS`, `Serve_TLS`, and `Cancel_TLS` when encryption is
  required. Cleartext-password authentication is safe only on an authenticated TLS
  connection or a comparably trusted transport.
- SCRAM-SHA-256 accepts the standard `n,,` and `y,,` GS2 headers. Actual channel
  binding (`SCRAM-SHA-256-PLUS` and `p=tls-server-end-point`) remains unsupported.
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
status-returning cursor reads, two's-complement signed-field conversion, bounded
byte views, frame-length conversions,
extended-protocol format-count validity, exact COPY-response lengths and format-code
validity, earliest-NUL search, initial/startup packet structure, protocol 3.2
variable cancellation keys, SSLRequest classification, exact source correspondence
for recognized startup
parameters and special requests, SCRAM core bounds, loop termination, and the
packages' functional
contracts.
The Flyology transports, heap-backed owned messages, tasking, and socket adapters
remain conventional Ada outside this boundary.

The cancellation registry, cryptographic credential generation, and token routing are
intentionally conventional Ada. `Encode_Cancel_Request` and the physical/logical
replication codecs compose the already-proved 16-, 32-, and 64-bit endian and
signed-bit-pattern primitives without expanding the SPARK proof boundary.

GNATprove is intentionally not a library dependency. It lives in the nested proof
environment and can be run with:

```sh
cd proof
alr gnatprove \
  -u flyology-postgres-wire.adb \
  -j0 --level=1 --output=oneline --output-header -f \
  2>&1 | tee gnatprove-run.txt
alr gnatprove \
  -u flyology-postgres-scram_core.adb \
  -j0 --level=1 --output=oneline --output-header -f \
  2>&1 | tee gnatprove-run.txt
```

The current GNATprove FSF 16.1.0 result on the combined source is 326 of 326
checks proved: 292 wire-core checks and 34 SCRAM-core checks. The wire core adds
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
bidirectional streaming.
Replication fixtures cover connection startup, command decoding and quoting,
crossed COPY BOTH shutdown traffic, every physical
stream envelope, every logical v1 message, v2 in-progress transaction context,
v3 two-phase messages, v4 parallel abort metadata, every tuple value form, and
malformed or version-incompatible payload rejection.
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

The replication integration matrix starts isolated PostgreSQL 14.23, 15.18,
16.14, 17.10, and 18.4 primaries. Every major exercises physical WAL,
`pgoutput` v1, and streamed v2 traffic; supported majors additionally exercise
v3 two-phase and streamed-prepare traffic and v4 parallel aborts. PostgreSQL 18
also covers binary tuples and replication origins. The v1 oracle applies every
decoded insert, update, delete, and truncate transaction to deterministic
pending and committed state, checks replica-identity old tuples against that
state, preserves unchanged TOAST, and compares the exact final rows. A separate
slot-resume oracle persists one commit acknowledgement, resets the connection
and decoder after 50 of the next transaction's 1,000 rows, and requires the
whole interrupted transaction without a gap on reconnect.

PostgreSQL 14, 17, and 18 also take a complete native client-side `BASE_BACKUP`
through the public event receiver, including WAL, tablespace metadata, tar
bytes, a SHA-256 backup manifest, and consistent start/end LSNs. PostgreSQL 18
also uploads that manifest and takes an incremental successor, then cancels a
second active backup through a separate TLS CancelRequest connection and must
return SQLSTATE `57014` followed by `ReadyForQuery`.

For the reverse direction, every major takes a real base backup, starts it with
`standby.signal` and a quoted physical slot name against the Flyology primary
test server, replays a transaction that exists only in streamed WAL, and proves
received, flushed, and applied feedback positions. The server then completes
both COPY BOTH directions in protocol order, and the same standby data
directory is restarted for a second exact feedback cycle. CI runs the five
PostgreSQL releases as independent shards with version-specific installation
caches. Every major also runs its unmodified `pg_recvlogical` against a
memory-backed managed Flyology primary, consumes an exact `pgoutput` row through
LSN `0/140`, and proves that feedback advances the application-owned logical
slot. PostgreSQL 18 additionally promotes the real standby and follows
persisted timeline history into exact WAL on timeline 2, then runs an
unmodified subscription worker through publication discovery, repeatable-read
sync-slot creation, and initial `COPY TO STDOUT`. A crash-durable external test
backend runs the reusable store conformance fixture across `SIGKILL`, torn-tail
repair, and process locking. [Replication validation boundaries and evidence](tests/REPLICATION_VALIDATION.md)
separate these semantics from the durability technology and SQL catalog that
applications still supply.

Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `POSTGRES_VERSION` | `18.4` | Stable numeric Postgres source version to build |
| `POSTGRES_CACHE_DIR` | `tests/.cache/postgres` | Reusable source/build/install cache |
| `POSTGRES_BUILD_JOBS` | `4` | Parallel build jobs |
| `POSTGRES_CONFIGURE_ARGS` | empty | Additional arguments passed to `configure` |
| `POSTGRES_INTEGRATION` | `1` | Set to `0` to run only the fast unit tests |
| `POSTGRES_REPLICATION_INTEGRATION` | `1` | Set to `0` to skip the live replication matrix |
| `POSTGRES_REPLICATION_VERSIONS` | `14.23 15.18 16.14 17.10 18.4` | Stable releases in the replication matrix |
| `POSTGRES_REPLICATION_PORT` | `55434` | Base port for primary, Flyology server, and standby tests |
| `POSTGRES_TEST_PORT` | `55433` | Port for the real Postgres server |
| `POSTGRES_PSQL_TEST_PORT` | `55432` | Port for the Flyology test server |

## License

Licensed under either the MIT License or the Apache License, Version 2.0, at your
option (`MIT OR Apache-2.0`).
