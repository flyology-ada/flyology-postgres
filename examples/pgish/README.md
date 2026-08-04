# pgish

`pgish` is an independent nested Alire crate that builds a small, read-only
Postgres server on Flyology's production `Server` and `Server_Sessions` APIs.
It is an educational server, not a database or a general SQL implementation.

The binary is `flyology_pgish`. It listens on
`127.0.0.1:55432` by default, negotiates Postgres protocol 3.2, refuses TLS and
GSS upgrades, and uses trust authentication. The loopback default is
intentional: do not expose this example on an untrusted network.

## Build and run

The crate pins `flyology_postgres` through the portable `../..` path so it uses
the current checkout. Flyology itself resolves from the configured Flyology
organization index.

```sh
cd examples/pgish
alr -n build
alr -n run flyology_pgish
```

Connect with a real `psql`:

```sh
psql -h 127.0.0.1 -p 55432 -U flyology -d flyology
```

The server prints `ready host=... port=...` after the listener is accepting
connections. SIGTERM requests graceful shutdown and gives active sessions two
seconds to drain. Postgres CancelRequest routing remains active during query
execution; bounded row emission checks cancellation between rows.

Configuration can come from environment variables or CLI options. CLI values
win:

| Environment | CLI | Default |
| --- | --- | --- |
| `FLYOLOGY_PGISH_HOST` | `--host NUMERIC_IP` | `127.0.0.1` |
| `FLYOLOGY_PGISH_PORT` | `--port PORT` | `55432` |
| `FLYOLOGY_PGISH_REPO` | `--repo PATH` | current directory |
| `FLYOLOGY_PGISH_TASK_MODE` | `--task-mode lightweight\|native` | `lightweight` |

Task mode selects the production server's per-connection handler tasks. The
signal/shutdown watcher is always native so control-plane progress is
independent of event-loop progress.

## Supported SQL

The hand-written lexer/parser intentionally accepts only:

```text
SELECT projection [, ...]
  [FROM virtual_table]
  [WHERE predicate [AND ...]]
  [ORDER BY projected_column [ASC|DESC]]
  [LIMIT 0..32]
  [;]

SHOW server_version|server_encoding|client_encoding|timezone|
     standard_conforming_strings [;]
```

Projections support `*`, columns, quoted string/integer literals, aliases with
or without `AS`, and `current_database()`, `current_user`, `version()`, and
`now()`. Identifiers are case-insensitive unless double quoted. String literals
use doubled single quotes. Predicates support `=`, `!=`, `<>`, `<`, `<=`, `>`,
`>=`, `IS NULL`, `IS NOT NULL`, and `LIKE`; LIKE accepts exact, prefix,
suffix, and substring patterns using percent only. ORDER BY is limited to one
projected column. NULL and empty text remain distinct on the wire.

The parser accepts one statement per Query message. Transactions, joins,
subqueries, arbitrary functions, DDL/DML, COPY, parameters, binary formats,
and general Postgres SQL are unsupported and return an ErrorResponse with a
specific SQLSTATE followed by ReadyForQuery. The session remains usable.

Simple Query is fully supported. Extended Parse/Bind/Describe/Execute/Close,
Flush, and Sync support a bounded, no-parameter text-format subset with one
prepared statement and portal per session. Extended errors enter the normal
discard-until-Sync recovery state. A small, isolated compatibility adapter
answers the catalog query shapes used by Postgres 18 `\dt` and `\d`; it is not
a general `pg_catalog` implementation.

## Virtual catalog

All data is read-only. Tables may be named directly or under the synthetic
`flyology` schema.

| Table | Contents |
| --- | --- |
| `flyology_server_info` | version/protocol, uptime, handler task mode, listener, repository path/HEAD, start time |
| `flyology_runtime_groups` | public inert execution-group snapshots and counters |
| `flyology_runtime_stack_pool` | process-wide public stack-pool snapshot |
| `flyology_sessions` | bounded live sessions, startup identity, query count, time, and state |
| `flyology_repo_commits` | up to 32 commits cached at startup: hashes, author, date, subject |
| `flyology_tables` | virtual table descriptions |
| `flyology_settings` | effective query/token/row/session/security limits |
| `flyology_environment` | only `FLYOLOGY_DEFAULT`, `FLYOLOGY_LOOP_POOL_SIZE`, `FLYOLOGY_LOOP_PLACEMENT`, `LANG`, and `TZ` when set |
| `information_schema.tables` | synthetic catalog rows used for discovery |
| `information_schema.columns` | synthetic column metadata |

Example queries:

```sql
SELECT protocol_version, task_mode, repository_head
FROM flyology_server_info;

SELECT group_id, members, ready, waiting, dispatches
FROM flyology_runtime_groups
WHERE members > 0
ORDER BY group_id;

SELECT short_hash, author, subject, committed_at
FROM flyology_repo_commits
WHERE subject LIKE '%Postgres%'
ORDER BY committed_at DESC
LIMIT 10;

SELECT session_id, user_name, database_name, query_count, state
FROM flyology_sessions
ORDER BY session_id;

\dt flyology.*
\d flyology.flyology_server_info
```

## Bounds and security boundary

Queries are limited to 8,192 bytes, 128 tokens, 16 projections, eight
predicates, 16 result columns, 32 result rows, and 256 bytes per result value.
The server admits at most 16 sessions. These fixed bounds also keep execution
safe on lightweight task stacks; catalog evaluation never grows with attacker
input.

Repository data is treated as untrusted text and clipped to field bounds. At
startup, the server locates `git` and invokes it directly with an argument
array (`git -C PATH log ...`), never through a shell. SQL cannot select a file,
program, command, or arbitrary environment variable. Commit queries read only
the bounded startup cache, so sessions never spawn processes.

Trust authentication is the only mode in this example. An optional SCRAM mode
is deliberately omitted because the current generic authentication callback
does not provide a post-authentication session hook needed to register state
without leaving failed attempts behind. No TLS is offered until Flyology
connection upgrades and channel binding are available.

## Tests

```sh
alr -n build
alr -n test
```

`pgish_tests` covers case and quoting, projections, predicates,
NULL behavior, ordering, limits, malformed/unsupported input, and catalog
bounds. `scripts/run-integration.sh` starts the server, waits for its ready
line, exercises Parse/Bind/Describe/Execute/Close/Sync with Flyology's typed
client, and then uses real Postgres 18 `psql` for NULL/empty values, catalog
meta commands, and error recovery. It sends SIGTERM and waits for deterministic
exit. Set `FLYOLOGY_PGISH_SKIP_INTEGRATION=1` to run only focused
tests.
