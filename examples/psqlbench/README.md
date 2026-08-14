# psqlbench

`psqlbench` is a local PostgreSQL replication workbench. It is an independent
Alire executable crate built with Flyology supervision, flyology-http, and
flyology-postgres.

The current vertical slice keeps PostgreSQL inside Docker containers and runs the
control plane as a native Ada process. Docker access intentionally goes through
a small, typed CLI transport for now. The transport boundary is isolated so it
can switch to flyology-http over the Docker daemon's Unix socket when that
client support is available and verified.

## Current slice

- verifies the Docker daemon and creates a private `psqlbench` bridge network;
- reconciles containers carrying the `org.flyology.psqlbench.instance` label;
- creates PostgreSQL 14.23, 15.18, 16.14, 17.10, and 18.4 containers;
- starts, stops, and removes owned containers;
- opens a supervised Flyology Postgres query session for a selected instance;
- streams columns, rows, command tags, notices, errors, duration, and
  cancellation state into a bounded tabular result, resolving every result
  type OID through that server's own `pg_type` catalog;
- retains the complete 1,000-row display bound in a compact 1,024-event ring
  and drains available event batches without per-row polling latency;
- continuously collects timestamped output for every owned container into a
  bounded 1,024-line ring, and replays the selected server's retained output
  before following it live;
- serves a Flyology-themed topology workbench and live WebSocket activity;
- creates supervised, cross-version logical links for a managed three-column
  demo table and applies future inserts, updates, deletes, and truncates;
- configures committed pgoutput v1 or large-transaction streaming pgoutput v2
  links, with UI query patterns for stream segments and transactional versus
  non-transactional logical messages;
- configures pgoutput v3 prepared-transaction and v4 streamed/prepared links;
  applies `PREPARE TRANSACTION`, `COMMIT PREPARED`, and `ROLLBACK PREPARED`
  through the downstream Flyology client, with link-scoped target GIDs;
- maps a source `schema.table` to a differently named compatible target
  relation while retaining snapshot initialization and live change activity;
- projects selected logical columns onto renamed target columns, with optional
  target-side casts, and revalidates the plan when pgoutput announces a changed
  source relation;
- routes every logical message through a Flyology Postgres replication client,
  stateful pgoutput decoder/encoder, Flyology Postgres replication server, and
  a second Flyology Postgres replication client before applying it to the
  target; source slot acknowledgement advances only after target commit;
- provisions a new same-version physical standby with the native Flyology
  `BASE_BACKUP` receiver, then routes its live recovery stream through a
  Flyology physical replication client and Flyology replication server before
  PostgreSQL's walreceiver applies it; standby feedback is proxied back to the
  source slot;
- exposes a selectable per-link activity stream for logical pgoutput messages
  and physical `XLogData`, primary keepalives, standby write/flush/apply
  feedback, hot-standby feedback, and upstream acknowledgements, both inline
  on each topology link and in the filterable global ledger;
- previews decoded old/new tuple values when an insert, update, or delete
  activity row is hovered or keyboard-focused;
- renders each replica's current and applied LSN, exact byte lag, and replayed
  share of the WAL span observed since that link started;
- creates idempotent logical-stream, physical-standby, and mixed-version sample
  topologies from UI presets, reusing matching managed containers after an app
  restart;
- runs Docker operations through one bounded native executor; and
- supervises Docker readiness, log collection, the dynamic link family, and the
  HTTP service as a dependency-ordered topology.

The logical bridge exports a slot snapshot, copies existing rows through
Flyology clients at the returned consistent LSN, records initialization on the
target atomically, and then starts pgoutput at that same boundary. A completed
marker makes restarts idempotent; an incomplete slot is recreated instead of
resuming a partial copy. Relation mapping discovers up to 64 source columns
from the snapshot and pgoutput relation metadata, applies replica-identity keys
for updates and deletes, and addresses target columns by name. An optional
column projection uses one rule per line:

```text
sku -> product_code
quantity_text -> units :: integer
price_cents -> price :: numeric(12,2)
```

A projection selects only those source columns, permits renames and safe
target-side SQL casts, and leaves unmapped target columns to their defaults.
Replica-identity columns must remain mapped so updates and deletes are
unambiguous. Before snapshot or apply, psqlbench verifies source columns,
target columns, cast types, generated/identity restrictions, and required
target values. New unmapped source columns are ignored; removing a mapped
column or changing the target incompatibly stops the link with a visible
diagnostic before more changes are applied.
Physical bootstrap WAL is streamed with PostgreSQL's replication protocol by
the Flyology client;
Docker installs the received archive without invoking `pg_basebackup`. After
recovery starts, all live WAL passes through the observable Flyology proxy.

The desired topology is stored as bounded JSON Lines in
`psqlbench-state.jsonl` (override with `PSQLBENCH_STATE_FILE`). On startup a
supervised reconciliation generation adopts or recreates managed instances,
validates their version and port, restores each link with its desired running
state, and only then admits the HTTP service. Logical links resume their slot
and snapshot marker; physical links reconnect an existing standby or bootstrap
one when its container is absent. State replacement uses temporary and previous
files so an interrupted write remains recoverable.

## Functional outline

The workbench grows in four layers while keeping the browser API stable:

1. **Runtime control (implemented):** discover labeled containers; provision,
   start, stop, and remove versioned nodes; report readiness and lifecycle
   events.
2. **Query sessions (implemented):** attach an authenticated frontend connection
   to any node, cancel work in progress, and render bounded tabular or diagnostic
   results alongside retained, real-time Postgres logs.
3. **Replication links (logical and physical baselines implemented):** own a
   typed link, slots, internal relay, logical target apply session, or
   automatically provisioned same-major physical standby.
4. **Protocol observation (implemented):** route replication through Flyology Postgres and
   stream WAL positions, lag, keepalives, relation metadata, tuple changes, and
   link failures to the activity ledger.

The intended desktop layout is deliberately topology-first:

```text
+ flyology / psqlbench                         [Docker ready]
+-------------------------------------------------------------------+
| BUILD THE TOPOLOGY. WATCH THE WIRE.                [+ New instance]|
+-------------------------------------------------------------------+
|  primary-17            physical / WAL             standby-17      |
|  PG 17.10  [healthy]  =========================>  PG 17.10 [live] |
|  :55432                 0/3A7D2C10 · 18 ms         :55433          |
|  [Inspect] [Stop]                         [Inspect] [Stop]         |
|                                                                   |
|  publisher-18          logical / orders            subscriber-18  |
|  PG 18.4   [healthy]  --------------------------> PG 18.4 [live]  |
+-------------------------------------------------------------------+
| SELECTED INSTANCE: primary-17                    [Query] [Logs]   |
| select version(), 42;           | server_version        | ?column?|
| [Cancel] [Run query]             | PostgreSQL 17.10 ...  | 42      |
+----------------------------------+--------------------------------+
| LIVE EVENTS                          | LINK INSPECTOR              |
| 12:10 relation public.orders         | slot    orders_demo         |
| 12:10 insert  id=42                  | sent    0/3A7D2C10          |
| 12:10 standby status update          | flush   0/3A7D2C10          |
+--------------------------------------+----------------------------+
```

The current UI implements instance nodes, managed logical and physical-link
creation and status, the selected-instance Query and Logs workspace, and a live
protocol activity ledger. Logical relays bind loopback. A physical relay binds
all host IPv4 interfaces so its Docker standby can reach it through
`host.docker.internal`; it uses the demo password in cleartext and is suitable
only for this local workbench. Live recovery never connects directly to the
source.

## Build and run

Docker must be installed and the current user must be allowed to reach the
daemon.

```sh
cd examples/psqlbench
alr -n build
./bin/psqlbench
```

Open <http://127.0.0.1:8080/>. Set `PSQLBENCH_PORT` to choose another loopback
port. Set `PSQLBENCH_ASSET_ROOT` when starting the binary outside this crate
directory.

The demo creates only containers, physical-standby volumes, and networks with
the `psqlbench` prefix and Flyology ownership labels. Removing an instance
removes its container and any psqlbench physical-standby volume with the same
name.

## Docker transport boundary

`Psqlbench_Docker` exposes typed operations, not arbitrary command execution.
Its private implementation currently spawns `docker` with an argument vector,
captures bounded output, enforces a deadline, and never evaluates a shell
string. HTTP handlers run those operations through a single-worker native
executor so cooperative event-loop threads are not blocked.

JSON request parsing and response/event serialization use the Apache-2.0
`utilada` crate from the Alire community index. The psqlbench code supplies a
small domain wrapper but does not implement JSON escaping, tokenization, or
number encoding itself.

Once flyology-http can configure HTTP/1.1 and HTTP/2 clients over Unix-domain
sockets, this package can replace its private transport without changing the
handlers or browser API.
