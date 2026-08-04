# psqlish

`psqlish` is a polished, intentionally incomplete `psql`-like example
for the production `Flyology.Postgres.Client` API. It connects to ordinary
Postgres and to `examples/pgish`; it is small enough to read as
an example and is not intended to replace `psql`.

It demonstrates startup authentication, simple-query event processing,
multiple result sets, bounded display buffering, recovery after SQL errors,
and a multiline REPL. Interactive terminals use `linenoise_ada` for line
editing and command history. Trust, cleartext-password, and SCRAM-SHA-256
startup are provided by the library. Verified TLS is available through
`sslmode=verify-full`; there is no insecure encrypted mode or downgrade
fallback. COPY streaming, variables, files, pager support, and the
extended-query protocol are deliberately out of scope.

## Build

The example is a nested Alire crate. Its committed `flyology_postgres` pin
points to the repository root (`../..`) so it exercises the current checkout.
Flyology itself is resolved normally from the Flyology organization index.

From this directory:

```sh
alr -n build
./bin/psqlish --help
```

Configure the Flyology organization index before building if it is not already
present in your Alire settings:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
```

## Connection and CLI

Defaults are `127.0.0.1:55432`, user `flyology`, database `flyology`.
`PGHOST`, `PGHOSTADDR`, `PGPORT`, `PGUSER`, `PGDATABASE`, `PGPASSWORD`,
`PGSSLMODE`, and `PGSSLROOTCERT` override those defaults; the corresponding
long options then override the environment. Supported SSL modes are `disable`
(the compatibility default) and `verify-full`. In verified mode, `PGHOST` is
the certificate DNS name while optional `PGHOSTADDR` selects the connection
address. Host names and numeric IPv4/IPv6 addresses are resolved through
Flyology's DNS API. The password is passed only after any required TLS handshake
and is never
printed. This example deliberately has no password-valued CLI option, which
keeps it out of process listings and shell history.

```sh
PGHOST=db.example.com PGHOSTADDR=192.0.2.10 \
PGSSLMODE=verify-full PGSSLROOTCERT=root-ca.pem \
PGPASSWORD=flyology-secret \
  ./bin/psqlish --command "select 1"
```

Use `--command` (or `-c`) for scripts:

```sh
PGPASSWORD=flyology-secret ./bin/psqlish \
  --command "select 1 as n, null::text as missing, ''::text as empty"
```

The process exits nonzero after a server SQL error, option error, startup
failure, protocol error, or transport failure. A SQL error is still drained
through `ReadyForQuery`, so an interactive connection remains reusable.

## REPL

SQL is accumulated across lines until the last non-whitespace byte is a
semicolon. Multiple statements in one submission produce multiple independent
tables and command tags. Interactive input supports cursor editing and
up/down history. History is saved to `~/.psqlish_history`; set
`PSQLISH_HISTORY` to override that path or to an empty value to disable
persistence. Redirected input remains non-interactive and is never recorded.
EOF submits a pending buffer and exits; `\q` exits when entered at a fresh
prompt.

Available meta commands:

```text
\?                 help
\q                 quit
\dt                list non-system tables
\d [TABLE]         describe TABLE, or list tables without an argument
\x on|off          expanded output
\timing on|off     elapsed time
\pset null VALUE   change the NULL marker (VALUE may be empty)
```

`\dt` uses `pg_catalog.pg_tables`; `\d TABLE` uses
`information_schema.columns`. Those queries work on real Postgres and form the
catalog-query contract for the companion `pgish` server.

Example session:

```text
psqlish 0.1.0-dev (TLS verify-full; COPY is not implemented; \? for help)
flyology=> select 7 as n, null::text as missing, ''::text as empty;
+---+---------+-------+
| n | missing | empty |
+===+=========+=======+
| 7 | NULL    |       |
+---+---------+-------+
(1 row)
SELECT 1
flyology=> \timing on
Timing is on
flyology=> select 1 / 0;
ERROR [22012]: division by zero
Time: 0.431000000 ms
flyology=> select 'still ready' as state;
```

Actual timings vary.

## Display and memory behavior

The formatter has configurable limits rather than universal hard caps. This
client configures explicit limits of 1,000 buffered rows, 1 MiB of retained
cell/header bytes per display batch, and 80 output bytes per cell. These values are
kept next to the client wiring in `psqlish_main.adb`, so another consumer can
choose its own policy.

The client can display more than 1,000 rows. When a row or byte boundary is
reached, it renders that batch, releases it, repeats the headers, and continues
receiving the same result. Alignment is therefore consistent within a batch,
not across an unlimited result. Total output is not capped; the backend command
tag (for example `SELECT 1001`) retains the server's total. Thus the connection
reaches `ReadyForQuery` without accumulating an unbounded result. Long cells
end in `...` and a truncation summary is printed. A single backend frame is
still bounded by the parent library's protocol frame limit.

Text-format fields retain their UTF-8 bytes. ASCII line-breaking and control
bytes are escaped so borders remain intact; display width is byte-oriented,
not Unicode-column-aware. Binary-format fields are visibly encoded as `\x`
followed by hexadecimal bytes. NULL uses a configurable marker and remains
distinct from an empty string. A column is right-aligned only when every
displayed non-NULL value looks numeric.

Notices and errors include severity and SQLSTATE. Parameter-status events that
occur during a query are printed as `PARAMETER name = value`. Empty queries,
command-only responses, multiple statements, and errors followed by
`ReadyForQuery` all have explicit handling.

## Tests and integration

The nested test crate covers alignment, NULL versus empty, binary encoding,
cell and row truncation, multiple-result state reset, expanded output, and
option parsing. Its executable output is checked exactly by a shell fixture:

```sh
./scripts/test.sh
```

The default test is deterministic and does not require a server. To add the
repository's cached configurable real Postgres integration, including an
ephemeral CA, verified TLS, and wrong-host rejection:

```sh
POSTGRES_INTEGRATION=1 ./scripts/test.sh
```

After building and starting `examples/pgish` at the shared
default endpoint, the coordinating integration command is:

```sh
./scripts/run-pgish-integration.sh
```

All `PG*` variables remain available if the server uses an overridden
endpoint or credentials.
