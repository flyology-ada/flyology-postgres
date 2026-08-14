# psqlbench

`psqlbench` is a local PostgreSQL replication workbench. It is an independent
Alire executable crate built with Flyology supervision, flyology-http, and
flyology-postgres.

The current vertical slice keeps PostgreSQL inside Docker containers and runs
the control plane as a native Ada process. Docker access uses Flyology HTTP/1.1
over the daemon's Unix-domain socket; psqlbench does not invoke the Docker CLI.

## Current slice

- verifies the Docker daemon and creates a private `psqlbench` bridge network;
- reconciles containers carrying the `org.flyology.psqlbench.instance` label;
- creates PostgreSQL 14.23, 15.18, 16.14, 17.10, and 18.4 containers;
- starts, stops, and removes owned containers;
- opens a syntax-highlighted SQL editor and supervised Flyology Postgres query
  session for a selected instance;
- streams columns, rows, command tags, notices, errors, duration, and
  cancellation state into a bounded tabular result, resolving every result
  type OID through that server's own `pg_type` catalog;
- streams query results in demand-driven 250-row pages, pausing PostgreSQL
  intake between pages until the result viewport requests more, while retaining
  the compact 1,024-event ring and batched event draining; the workbench can
  also drain pages automatically to an explicit 5,000-row display cap;
- continuously collects timestamped output for every owned container into a
  bounded 1,024-line ring, and replays the selected server's retained output
  before following it live, with an independent node selector in the logs
  window;
- serves an adjacency-aware, windowed topology workbench whose visible dock
  columns and rows compact as panels are hidden, with live WebSocket activity;
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
- exposes a per-link failure lab that can hold relay delivery, add up to five
  seconds of latency, cap relay throughput from 16 KiB/s upward, or deliberately
  disconnect one supervised generation while the backlog and recovery remain
  visible;
- creates idempotent logical-stream, physical-standby, and mixed-version sample
  topologies from UI presets, reusing matching managed containers after an app
  restart;
- exposes a confirmed Reset lab action that stops every supervised link,
  removes labeled psqlbench containers and their data volumes, and clears the
  durable topology while preserving Postgres images and the private network;
- runs Docker operations through a bounded Flyology HTTP Unix-socket client
  pool; and
- supervises Docker readiness, log collection, the dynamic link family, and the
  HTTP service as a dependency-ordered topology; the UI renders live bounded
  `Flyology.Supervision.Current` snapshots for every static child and admitted
  family generation, including lifecycle, readiness, liveness, recovery
  attempts, and execution model.

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
diagnostic before more changes are applied. Each logical link also exposes the
resolved runtime column map, replica-identity keys, and missing or generated
target columns in its expandable projection view.
Physical bootstrap WAL is streamed with PostgreSQL's replication protocol by
the Flyology client;
Docker installs the received archive without invoking `pg_basebackup`. After
recovery starts, all live WAL passes through the observable Flyology proxy.

Failure-lab controls execute inside that proxy for both logical and physical
links. Pausing stops relay delivery without stopping the source client, so the
bounded relay queue and PostgreSQL slot provide backpressure. Latency and
bandwidth shaping delay only relay-to-consumer `XLogData`; protocol keepalives
and feedback remain visible. “Disconnect now” requests a generation-qualified
supervised replacement through Flyology. These controls and their counters are
deliberately runtime-only: restarting psqlbench returns every restored link to
an unshaped network.

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

The desktop UI keeps the lab in one fixed workbench instead of a scrolling
document. Six independent windows expose instances, replication links, the SQL
session, Postgres output, replication-wire events, and the live supervision
tree:

```text
+ flyology / psqlbench      Postgres replication workbench   Docker ready
+ [New instance] [New link] [Preset                         ] [Panels...]
+----------------+---------------------------+------------------------+
| 01 instances   | 03 sql.session            | 04 postgres.stderr     |
| containers     | editor | bounded results  | retained + live output |
+----------------+---------------------------+------------------------+
| 02 links       | 05 replication.wire       | 06 supervision.tree    |
| lag + failures | pgoutput / WAL / feedback | generations + families |
+----------------+---------------------------+------------------------+
| transport HTTP + WebSocket | docker Unix socket | COPY BOTH / WAL    |
```

Every title bar has a dock-slot selector. Dragging a title bar converts that
window to a movable, resizable floating window; docking into an occupied slot
swaps the two windows. The Panels controls hide and restore tools, Reset layout
returns to the six-slot arrangement, and the browser retains the layout locally.
Logical relays bind loopback. A physical relay binds all host IPv4 interfaces
so its Docker standby can reach it through `host.docker.internal`; it uses the
demo password in cleartext and is suitable only for this local workbench. Live
recovery never connects directly to the source.

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
name. Reset lab removes every labeled psqlbench instance and attached data
volume after stopping replication links. It does not remove pulled images, the
`psqlbench` network, or unrelated Docker resources.

## Docker transport boundary

`Psqlbench_Docker` exposes typed operations, not arbitrary command execution.
Its private implementation configures an origin-bound Flyology HTTP client with
`Unix_Socket`, retains a bounded connection pool, and maps each operation to a
Docker Engine endpoint. Request deadlines and cancellation flow through the
same client for container, image, network, volume, log, and exec operations.
Physical bootstrap streams the native `BASE_BACKUP` tar directly into the
standby's mounted volume through Docker's archive endpoint.

The default socket is `/var/run/docker.sock`. Set
`PSQLBENCH_DOCKER_SOCKET` for Docker installations exposing a different local
pathname. The HTTP authority remains `http://localhost`; it is not used for a
TCP connection.

JSON request parsing and response/event serialization use the Apache-2.0
`utilada` crate from the Alire community index. The psqlbench code supplies a
small domain wrapper but does not implement JSON escaping, tokenization, or
number encoding itself.

The handlers and browser API remain independent of this transport boundary.
