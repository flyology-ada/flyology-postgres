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
- runs Docker operations through one bounded native executor; and
- supervises Docker readiness, log collection, and the HTTP service as a
  dependency-ordered static topology.

This is not yet the replication bridge. The instance model and event stream are
the control-plane foundation for physical and logical links.

## Functional outline

The workbench grows in four layers while keeping the browser API stable:

1. **Runtime control (implemented):** discover labeled containers; provision,
   start, stop, and remove versioned nodes; report readiness and lifecycle
   events.
2. **Query sessions (implemented):** attach an authenticated frontend connection
   to any node, cancel work in progress, and render bounded tabular or diagnostic
   results alongside retained, real-time Postgres logs.
3. **Replication links:** bootstrap physical standbys and logical
   publication/subscription pairs, with slots and credentials owned by a typed
   link model.
4. **Protocol observation:** route replication through Flyology Postgres and
   stream WAL positions, lag, keepalives, relation metadata, tuple changes, and
   link failures to the activity ledger.

The intended desktop layout is deliberately topology-first:

```text
+ flyology / psqlbench                         [Docker ready]
+-------------------------------------------------------------------+
| BUILD THE TOPOLOGY. WATCH THE WIRE.                [+ New instance]|
+-------------------------------------------------------------------+
|  primary-17            physical / WAL             standby-16      |
|  PG 17.10  [healthy]  =========================>  PG 16.14 [live] |
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

The current UI implements instance nodes, the selected-instance Query and Logs
workspace, and the live ledger. Replication links and their inspector remain
the next topology layer.

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

The demo creates only containers and networks with the `psqlbench` prefix and
Flyology ownership labels. Removing an instance removes its container. Named
volume management will be added with replication bootstrapping, so this slice
does not claim that deleted instance data is recoverable.

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
