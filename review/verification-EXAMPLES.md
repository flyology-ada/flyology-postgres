# Adversarial verification: EXAMPLES (pgish, psqlish, psqlbench)

Worktree: `/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd`

Every candidate finding was checked against the actual sources (`examples/pgish/src/*`,
`examples/psqlish/src/*`, `src/flyology-postgres-protocol.ads`,
`src/flyology-postgres-server.adb`), against the two READMEs, and against a runnable
reproduction under `examples/repros/src/`. Ten reproduction programs were written and
run; all ten fail on current sources. EXAMPLES-8 was verified by running
`examples/pgish/bin/flyology_pgish` directly, as permitted.

Additional wire-level evidence was collected by starting `examples/pgish/bin/flyology_pgish`
on ephemeral ports under `timeout` and driving it with a minimal PostgreSQL v3 client
(startup / Query / Terminate, plus abrupt `SO_LINGER 0` closes). Every server process was
stopped afterwards; `pgrep flyology_pgish` is clean.

Severity rubric used (as given): **P0** = crash/hang on ordinary input, or a protocol
violation that makes real psql/libpq fail; **P1** = wrong result or unexpected exception on
valid input via a reachable path, or documented behavior violated; **P2** = edge-case
incorrectness, wrong diagnostics, or README drift needing unusual input.

## Verdict summary

| ID | Verdict | Reported | Corrected | Repro |
| --- | --- | --- | --- | --- |
| EXAMPLES-1 | CONFIRMED | P1 | P1 | `repro_examples_1.adb` |
| EXAMPLES-2 | CONFIRMED | P1 | P1 | `repro_examples_2.adb` |
| EXAMPLES-3 | CONFIRMED | P1 | P1 | `repro_examples_3.adb` |
| EXAMPLES-4 | CONFIRMED | P1 | P1 | `repro_examples_4.adb` |
| EXAMPLES-5 | CONFIRMED | P2 | **P1** (raised) | `repro_examples_5.adb` |
| EXAMPLES-6 | CONFIRMED | P2 | P2 | `repro_examples_6.adb` |
| EXAMPLES-7 | CONFIRMED, one sub-claim REFUTED | P2 | **P1** (raised) | `repro_examples_7.adb` |
| EXAMPLES-8 | CONFIRMED | P2 | P2 | binary run (no program needed) |
| EXAMPLES-9 | CONFIRMED | P2 | P2 | `repro_examples_9.adb` |
| EXAMPLES-10 | CONFIRMED (and broader than reported) | P2 | P2 | `repro_examples_10.adb` |
| EXAMPLES-11 | CONFIRMED | P2 | P2 | `repro_examples_11.adb` |

Nothing was REFUTED outright and nothing is a DOCUMENTED SUBSET escape. One sub-claim
inside EXAMPLES-7 ("No slot exhaustion is possible ... this is a state/observability error,
not a denial of service") is refuted by measurement.

### PostgreSQL semantics relied on (stated from my own knowledge, not from the report)

- `x LIKE '%'` matches every non-NULL value; `'%%'` is equivalent. `NULL LIKE '%'` is NULL,
  so NULL rows are not returned.
- `x NOT LIKE p` is the negation of `x LIKE p` (NULL-preserving). The grammar lowers it to
  the same `AEXPR_LIKE` node kind with operator name `!~~`; this is visible in the
  checked-in grammar at `sql/backends/v18/vendor/native_source/backend/parser/gram.y:15025-15048`
  (`~~` for LIKE, `!~~` for NOT LIKE).
- `ORDER BY` on an `integer`/`bigint` column orders numerically, not lexicographically.
- `SELECT;` is valid since PostgreSQL 9.4 and yields a zero-column result; psql prints
  `--` then `(1 row)`. The RowDescription legitimately carries a field count of 0.
- `SELECT *` with no FROM clause is rejected: `ERROR: SELECT * with no tables specified is
  not valid` (SQLSTATE 42601).
- A simple Query string that contains no statement (`;`, a comment, whitespace) is answered
  with EmptyQueryResponse by `exec_simple_query`, not with an error; psql prints nothing.
- Unquoted identifiers fold to lower case; double-quoted identifiers keep their case, so
  `"PROTOCOL_VERSION"` and `protocol_version` are different identifiers.
- In psql expanded mode (`\x on`), every field name on the left is padded to the width of
  the widest *field name*, so all `|` separators line up in one column.

### README claims cited by the findings — all verified present

- `examples/pgish/README.md`, "Supported SQL": "Identifiers are case-insensitive unless
  double quoted." (EXAMPLES-6)
- Same section: "LIKE accepts exact, prefix, suffix, and substring patterns using percent
  only." (EXAMPLES-1)
- Same section: `[LIMIT 0..32]` is part of the documented grammar. (EXAMPLES-5)
- "Virtual catalog" table lists `information_schema.columns`, and states "Tables may be
  named directly or under the synthetic `flyology` schema." (EXAMPLES-5, EXAMPLES-6)
- "Example queries" include `ORDER BY group_id`, `ORDER BY session_id`, and
  `ORDER BY committed_at DESC`. (EXAMPLES-3)
- "Bounds and security boundary": "The server admits at most 16 sessions." (EXAMPLES-7)
- `examples/psqlish/README.md`: `\x on|off  expanded output` (EXAMPLES-9); "Empty queries,
  command-only responses, multiple statements, and errors followed by `ReadyForQuery` all
  have explicit handling." (context for EXAMPLES-4).

---

### EXAMPLES-1: `LIKE '%'` / `'%%'` raises `Ada.Strings.Pattern_Error` instead of matching every non-NULL value

**Verdict:** CONFIRMED.

**Severity:** P1 (unchanged). Not P0: the session survives, `ReadyForQuery` still arrives,
and psql recovers.

**Repro:** `examples/repros/src/repro_examples_1.adb`

**Output** (`cd examples/repros && ./run.sh repro_examples_1`):

```
  ok: SELECT name FROM flyology_settings returns 6 rows (got 6)
  -- unexpected ADA.STRINGS.PATTERN_ERROR : a-strsea.adb:300
  FAILED: SELECT name FROM flyology_settings WHERE name LIKE '%' must not raise
  -- unexpected ADA.STRINGS.PATTERN_ERROR : a-strsea.adb:300
  FAILED: SELECT name FROM flyology_settings WHERE name LIKE '%%' must not raise
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

Wire-level confirmation against `bin/flyology_pgish` (port 55599):

```
== EXAMPLES-1 on the wire: LIKE '%' ==
    ErrorResponse severity=ERROR code=XX000 msg=a-strsea.adb:300
    ReadyForQuery I
```

**Description:** `Pgish_Catalog.Like` (`examples/pgish/src/pgish_catalog.adb:444-466`)
strips a leading and a trailing `%` and, for the patterns `'%'` and `'%%'`, is left with a
null `Needle`; the `Leading and Trailing` branch then calls
`Ada.Strings.Fixed.Index (Value, "")`, which RM A.4.3 requires to propagate
`Ada.Strings.Pattern_Error`. The exception escapes `Pgish_Catalog.Execute`, and because
`Pgish_Handler.SQL_State_For` (`pgish_handler.adb:111-124`) matches only pgish's own
exception names it reports SQLSTATE `XX000` with the GNAT runtime's message as the
client-visible error text — the observed ErrorResponse literally reads
`a-strsea.adb:300`, leaking an internal runtime source location to the network. The README
documents substring `%` patterns, and `LIKE '%'` is a normal "everything non-NULL" idiom,
so a documented, valid query returns an internal-error diagnostic instead of the six
`flyology_settings` rows.

---

### EXAMPLES-2: `NOT LIKE` is silently evaluated as `LIKE`

**Verdict:** CONFIRMED.

**Severity:** P1 (unchanged). Silently wrong results are worse than an error; this is the
inverse of the correct row set with no diagnostic at all.

**Repro:** `examples/repros/src/repro_examples_2.adb`

**Output:**

```
  ok: LIKE 'maximum%' selects the four maximum_* settings (got 4)
  -- NOT LIKE parsed; stored operator is LIKE_MATCH
  -- NOT LIKE 'maximum%' returned 4 row(s); first = maximum_query_length
  FAILED: NOT LIKE 'maximum%' selects authentication and tls (got 4)
  FAILED: first NOT LIKE row is 'authentication'
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

Wire-level confirmation:

```
== EXAMPLES-2 on the wire: NOT LIKE 'maximum%' ==
    RowDescription fields=1 ['name']
    DataRow ['maximum_query_length']
    DataRow ['maximum_tokens']
    DataRow ['maximum_result_rows']
    DataRow ['maximum_sessions']
    CommandComplete 'SELECT 4'
```

**Description:** `Pgish_SQL.Add_Predicate` (`examples/pgish/src/pgish_sql.adb:413-436`)
computes the operator `Name` but, on the `A_Expr_Kind_Aexpr_Like` branch, never consults
it: it unconditionally stores `Like_Match`. The PostgreSQL grammar lowers `a NOT LIKE b` to
the same `AEXPR_LIKE` kind with name `!~~` (`gram.y:15039`, `:15048`), so pgish stores an
un-negated LIKE predicate. `SELECT name FROM flyology_settings WHERE name NOT LIKE
'maximum%'` therefore returns exactly the four `maximum_*` rows that PostgreSQL excludes,
and omits `authentication` and `tls`. No error is emitted, so the client cannot tell the
answer is inverted. The pgish README lists `LIKE` but not `NOT LIKE` among supported
predicates and states that unsupported constructs "return an ErrorResponse with a specific
SQLSTATE"; either negating correctly or rejecting the statement would satisfy the
documented contract, and the repro accepts either.

---

### EXAMPLES-3: `ORDER BY` compares integer columns as text while `WHERE` compares them numerically

**Verdict:** CONFIRMED.

**Severity:** P1 (unchanged). This is a wrong result for three of the README's own example
queries.

**Repro:** `examples/repros/src/repro_examples_3.adb`

**Output:**

```
  -- ascending order: 1,10,11,12,13,14,15,16,2,3,4,5,6,7,8,9
  ok: flyology_runtime_groups reports 16 columns (got 16)
  FAILED: ascending ORDER BY places 2 second, not 10
  FAILED: ascending ORDER BY places 16 last, not 9
  -- descending order: 9,8,7,6,5,4,3,2,16,15,14,13,12,11,10,1
  FAILED: descending ORDER BY places 16 first, not 9
  ok: WHERE ordinal_position > 9 is numeric and yields 7 rows (got 7)
BUG REPRODUCED: 3 failed expectation(s)
```
exit status 1.

Independently observed on the wire while probing session state:
`SELECT session_id, application_name, state FROM flyology_sessions ORDER BY session_id`
returned `1, 10, 11, 12, 13, 14, 15, 17, 2, 3, ...` — i.e. the README's own
`ORDER BY session_id` example is already wrong once a server has served ten connections.

**Description:** `Pgish_Catalog.Sort.Before` (`examples/pgish/src/pgish_catalog.adb:623-651`)
always compares `SQL.Image (…)` values as Ada `String`s, ignoring the column's type OID,
while `Pgish_Catalog.Matches` (`:486-503`) detects two numeric operands and compares them
as `Long_Long_Integer`. The two halves of the same query therefore disagree: for
`information_schema.columns.ordinal_position` (int4, OID 23) `WHERE ordinal_position > 9`
correctly yields seven rows, but `ORDER BY ordinal_position` yields
`1,10,11,…,16,2,3,…,9`. The same applies to every integer column in the catalog
(`session_id`, `group_id`, `members`, `dispatches`, `query_count`, `listen_port`,
`uptime_seconds`), so `ORDER BY dispatches DESC` ranks `9` above `1000`. Three README
example queries (`ORDER BY group_id`, `ORDER BY session_id`, `ORDER BY committed_at DESC`)
are affected as soon as any value reaches two digits.

---

### EXAMPLES-4: psqlish raises `Constraint_Error` on any zero-column result and abandons the connection

**Verdict:** CONFIRMED.

**Severity:** P1 (unchanged). It is a hard client crash (unhandled exception, socket closed
without Terminate, nonzero exit, REPL gone), but it needs the unusual-though-valid
`SELECT;` / `SELECT *;`, so it does not meet the "ordinary input" bar for P0.

**Repro:** `examples/repros/src/repro_examples_4.adb`

**Output:**

```
  ok: a zero-field RowDescription decodes as RowDescription
  ok: the library reports Field_Count = 0 (Natural, not Positive)
  ok: the library reports Column_Count = 0 (Natural, not Positive)
  -- psqlish_main.adb:234 raised CONSTRAINT_ERROR : repro_examples_4.adb:57 range check failed
  FAILED: psqlish accepts a zero-field RowDescription
  -- psqlish_main.adb:262 raised CONSTRAINT_ERROR : repro_examples_4.adb:76 range check failed
  FAILED: psqlish accepts a zero-column DataRow
  -- Display renders a zero-column result as: "SELECT 1
"
  ok: Psqlish.Display already accepts an empty Column_Array
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

The repro builds real `T` and `D` messages with a zero count, decodes them through
`Flyology.Postgres.Protocol.Decode_Backend`, and then evaluates the two narrowing
declarations copied from `psqlish_main.adb`. `psqlish` itself is not built in this worktree
(`examples/psqlish/bin` does not exist) and building it would have written into a
forbidden directory, so the client binary was not exercised; the reachability of a
zero-field RowDescription was instead confirmed on the wire against pgish (see
EXAMPLES-11: `RowDescription fields=0 []`, `DataRow []`, `CommandComplete 'SELECT 1'`).

**Description:** `examples/psqlish/src/psqlish_main.adb:234` and `:262` narrow the library's
`Natural`-valued accessors to `Positive`:

```ada
Count : constant Positive := Protocol.Field_Count (Description);   -- :234
Count : constant Positive := Protocol.Column_Count (Row);          -- :262
```

`Flyology.Postgres.Protocol` declares both as returning `Natural`
(`src/flyology-postgres-protocol.ads:370` and `:414`), and a zero-field RowDescription is
legal on the wire — real PostgreSQL produces one for `SELECT;`, and pgish produces one for
`SELECT *;`. The range check fails, the `Constraint_Error` leaves `Execute_Query`, `Run`'s
handler (`psqlish_main.adb:516-522`) closes the socket without sending Terminate and
re-raises, and the top-level handler prints `Exception_Information` and exits nonzero — so
an interactive session is destroyed rather than showing an empty result.
`Psqlish.Display.Begin_Result` already accepts an empty `Column_Array` (verified: it
renders just the command tag), so the defect is confined to the two narrowings in the
client main.

---

### EXAMPLES-5: `information_schema.columns` is unusable without a `table_name =` predicate, even with `LIMIT`

**Verdict:** CONFIRMED.

**Severity:** **P1, raised from the reported P2.** The rubric's P2 clause requires "unusual
input"; `SELECT column_name FROM information_schema.columns LIMIT 5` is an ordinary
discovery query built entirely from documented subset features (documented table,
documented `LIMIT 0..32`), and it fails. It is "documented behavior violated" and
"unexpected exception on valid input", which is P1. Mitigating (and why the discovery's P2
is defensible): the failure is a clean ErrorResponse with a plausible SQLSTATE and the
session stays usable.

**Repro:** `examples/repros/src/repro_examples_5.adb`

**Output:**

```
  ok: SELECT column_name FROM information_schema.columns WHERE table_name = 'flyology_server_info' returns 9 rows (got 9)
  -- unexpected PGISH_CATALOG.RESOURCE_LIMIT_ERROR : result row limit exceeded
  FAILED: SELECT column_name FROM information_schema.columns LIMIT 5 must not raise
  -- unexpected PGISH_CATALOG.RESOURCE_LIMIT_ERROR : result row limit exceeded
  FAILED: SELECT column_name FROM information_schema.columns WHERE table_schema = 'flyology' LIMIT 1 must not raise
  -- unexpected PGISH_CATALOG.RESOURCE_LIMIT_ERROR : result row limit exceeded
  FAILED: SELECT column_name FROM information_schema.columns WHERE table_name LIKE 'flyology_server%' LIMIT 5 must not raise
BUG REPRODUCED: 3 failed expectation(s)
```
exit status 1.

Wire-level confirmation:

```
== EXAMPLES-5 on the wire: information_schema.columns LIMIT 5 ==
    ErrorResponse severity=ERROR code=54000 msg=result row limit exceeded
```

**Description:** `Pgish_Catalog.Add_Information_Columns`
(`examples/pgish/src/pgish_catalog.adb:356-410`) materializes one row per column of every
virtual table before any projection, filtering or `LIMIT` is applied: 9 + 16 + 8 + 8 + 5 +
3 + 4 + 2 = 55 rows (counts verified against `Add_Server_Info`, `Add_Runtime_Groups`,
`Add_Stack_Pool`, `Add_Sessions`, `Add_Commits`, `Add_Tables`, `Add_Settings`,
`Add_Environment`). `Add_Row` (`:83-90`) raises `Resource_Limit_Error` at
`Maximum_Rows = 32`, and `Pgish_Catalog.Execute` (`:653-706`) pushes a filter into the
generator only for the first predicate whose base column name is `table_name` **and** whose
operator is `Equal_To`. A bare `LIMIT`, a `table_schema =` filter, or a `table_name LIKE`
filter therefore all abort with SQLSTATE 54000 "result row limit exceeded" even though the
requested result is 1-5 rows, far inside the documented 32-row bound. Only psqlish's
`\d TABLE` shape (which always supplies `table_name = ...`) works, which is exactly the
shape `pgish_tests.adb:156-168` covers.

---

### EXAMPLES-6: double-quoted identifiers are case-folded and column/schema qualifiers are ignored

**Verdict:** CONFIRMED.

**Severity:** P2 (unchanged). The README statement "Identifiers are case-insensitive unless
double quoted" is violated, but only for the unusual input the P2 clause describes
(upper-case quoted identifiers, bogus qualifiers). No valid query returns a wrong value;
pgish accepts queries PostgreSQL would reject.

**Repro:** `examples/repros/src/repro_examples_6.adb`

**Output:**

```
  ok: unquoted identifiers are case-insensitive
  -- a double-quoted upper-case column name is case sensitive: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: a double-quoted upper-case column name is case sensitive
  -- a double-quoted upper-case table name is case sensitive: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: a double-quoted upper-case table name is case sensitive
  -- an unknown column qualifier is rejected: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: an unknown column qualifier is rejected
  -- an unknown schema qualifier is rejected: accepted,  3 column(s) named "table_schema", 8 row(s)
  FAILED: an unknown schema qualifier is rejected
BUG REPRODUCED: 4 failed expectation(s)
```
exit status 1.

**Description:** `Pgish_Catalog.Base_Name` (`examples/pgish/src/pgish_catalog.adb:92-96`)
drops everything before the last `.` and lower-cases the remainder. It is the only name
normalizer used by `Find_Column` (`:98-108`), by `Load_Source` (`:412-434`), and by
`Add_Projected_Column` when naming the output column (`:515-558`). The PostgreSQL parser
preserves the case of a double-quoted identifier and folds only unquoted ones, so
`SELECT "PROTOCOL_VERSION" FROM flyology_server_info` reaches pgish with its case intact
and is then folded away: the query succeeds and the result column is labelled
`protocol_version`, where PostgreSQL raises 42703. The same folding makes
`FROM "FLYOLOGY_SERVER_INFO"` resolve. Because the qualifier is discarded rather than
checked, `SELECT nowhere.protocol_version FROM flyology_server_info` (PostgreSQL: missing
FROM-clause entry) and `SELECT * FROM bogus_schema.flyology_tables` (README: tables live
directly or under the synthetic `flyology` schema) both succeed. A client that relies on
quoting to disambiguate, or that mistypes a schema, gets silent success instead of an
error.

---

### EXAMPLES-7: `flyology_sessions` retains phantom sessions after a client disconnects without Terminate — and those phantoms refuse admission to live clients

**Verdict:** CONFIRMED for the mechanism and the observability effect. The finding's
concluding sub-claim — *"No slot exhaustion is possible (one slot per handler task), so
this is a state/observability error, not a denial of service"* — is **REFUTED by
measurement**: phantom slots do block admission for legitimate clients, and the refusal is
reported as `FATAL 28P01 password authentication failed` on a trust-authentication server.

**Severity:** **P1, raised from the reported P2.** A valid connection is refused with a
false authentication error, and the README's "The server admits at most 16 sessions"
becomes untrue after ordinary client churn. It stops short of P0 because it takes an
accumulation of abrupt disconnects rather than a single ordinary input, and the refusal is
a well-formed FATAL ErrorResponse rather than a protocol violation.

**Repro:** `examples/repros/src/repro_examples_7.adb`

**Output:**

```
  -- flyology_sessions still reports 16 session(s) after all peers disconnected
  FAILED: flyology_sessions lists no session once every peer is gone
  FAILED: a fresh client is admitted while no live session exists
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

End-to-end evidence against `examples/pgish/bin/flyology_pgish` (trust auth, no TLS,
ephemeral ports, each server stopped afterwards):

1. Two live connections, one closed with `SO_LINGER 0` (RST, no Terminate); after 1.5 s the
   surviving connection still sees both:
   ```
   == A dropped without Terminate, asked from B ==
       ['1', 'conn_a', 'idle']
       ['2', 'conn_b', 'running']
   RESULT: live sessions after drop = 2 (expected 1: conn_b only)
   ```
2. Control run — 16 fresh connections opened on a clean server: all 16 admitted
   (`ctl 0..15 -> ['Auth', 'ReadyForQuery']`).
3. Exhaustion run — 16 connections opened, all closed with RST, 2 s pause, then 16 fresh
   connections:
   ```
   new 0 -> ['Auth', 'ReadyForQuery']
   new 1 -> ['ERROR FATAL 28P01 password authentication failed']
   new 2 -> ['Auth', 'ReadyForQuery']
   new 3 -> ['ERROR FATAL 28P01 password authentication failed']
   ...
   admitted 8, refused 8
   ```
   A separate run confirmed `flyology_sessions` listing all 16 dead sessions as `idle`
   at that point.

**Description:** `Pgish_Handler.Handle` calls `Pgish_State.Remove_Session` only from the
`Protocol.Terminate_Command` branch (`examples/pgish/src/pgish_handler.adb:419`), and
`Flyology.Postgres.Server`'s generic formals are `Authenticate`,
`Lookup_SCRAM_Verifier` and `Handle` only — there is no disconnect callback. When
`Read_Command` raises on peer EOF/reset, a TLS failure, or the 300 s `Command_Timeout`, the
per-connection loop (`src/flyology-postgres-server.adb:486-521`) removes only the library's
own cancellation-router entry and re-raises, leaving the pgish registry slot `Occupied`
with `State = "idle"`. `Pgish_State.Register` (`pgish_state.adb:28-65`) reuses an occupied
slot only when its `Owner` is the same handler task, so the slot is consumed until that one
task happens to serve another connection. Two consequences follow. First, the README's
`SELECT ... FROM flyology_sessions` example reports dead sessions with their old
`session_id`, `query_count` and `connected_at`. Second — and this is the part the
discovery report dismissed — `Pgish_State.Maximum_Sessions = 16` slots are shared by 17
handler workers (`Flyology.Postgres.Server.Worker_Capacity` returns `Capacity + 1`), so
once phantoms fill the registry a new connection served by a worker without a slot gets
`Accepted = False` from `Authenticate` and the library answers
`FATAL 28P01 "password authentication failed"` — a false credential error on a server that
uses trust authentication. Measured: 16/16 admitted on a clean server, 8/16 admitted after
16 abrupt disconnects.

---

### EXAMPLES-8: `flyology_pgish` option and environment errors bypass the main exception handler

**Verdict:** CONFIRMED.

**Severity:** P2 (unchanged). Wrong diagnostics on invalid input; the process still exits
nonzero and no server is left running.

**Repro:** none written — per the task rules, running the prebuilt binary with an invalid
option is sufficient, and the defect lives in the declarative part of a main procedure that
cannot be called from a test program.

**Output** (`timeout 15 ./examples/pgish/bin/flyology_pgish …`, run from the worktree root):

```
### --port abc
Execution of ./examples/pgish/bin/flyology_pgish terminated by unhandled exception
raised CONSTRAINT_ERROR : bad input for 'Value: "abc"
Load address: 0x100724000
Call stack traceback locations:
0x101007c68 0x101007cc8 0x1010373b0 0x1010365a0 0x1010365d4 0x10072cc2c 0x10072dd2c 0x101053134
exit=1

### --port 70000
raised CONSTRAINT_ERROR : port must be in 1 .. 65535        (+ traceback)   exit=1

### --bogus
raised CONSTRAINT_ERROR : unknown option: --bogus           (+ traceback)   exit=1

### --task-mode weird
raised CONSTRAINT_ERROR : task mode must be lightweight or native (+ traceback) exit=1

### --tls-cert /tmp/nope.pem
raised CONSTRAINT_ERROR : --tls-cert and --tls-key must be provided together (+ traceback) exit=1

### FLYOLOGY_PGISH_PORT=x (environment)
raised CONSTRAINT_ERROR : bad input for 'Value: "x"         (+ traceback)   exit=1
```

**Description:** `examples/pgish/src/flyology_pgish.adb:136` elaborates
`Options : constant Parsed_Configuration := Read_Configuration;` in the main procedure's
declarative part. `Read_Configuration` raises `Constraint_Error` for an unknown option, a
missing option value, a non-numeric or out-of-range `--port`, a bad `--task-mode`, a lone
`--tls-cert`/`--tls-key`, and for a non-numeric `FLYOLOGY_PGISH_PORT`. Per RM 11.2, an
exception raised while elaborating a body's declarative part is not handled by that body's
own handler, so the carefully written handler at `:242-249` — which prints
`flyology_pgish: <message>` and calls `Set_Exit_Status (Failure)` — never runs. Users get
GNAT's unhandled-exception report with a load address and raw traceback addresses instead
of the intended one-line diagnostic. No hang occurs: `Shutdown_Watcher` is never activated
when the declarative part fails, and the process exits 1. Moving the elaboration into the
statement part (or wrapping it in a block with its own handler) restores the intended
behaviour.

---

### EXAMPLES-9: psqlish expanded (`\x on`) output misaligns field names

**Verdict:** CONFIRMED.

**Severity:** P2 (unchanged). Cosmetic misrendering; no data is lost or altered.

**Repro:** `examples/repros/src/repro_examples_9.adb`

**Output:**

```
  -- line 2: "n | 7"
  -- line 3: "value | alpha"
  ok: both expanded field lines carry a separator
  FAILED: the expanded separators align (n at 3, value at 7)
  FAILED: psql renders the short name padded to the widest name
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

**Description:** `Psqlish.Display.Finish_Result` computes `Widths (Index)` as the per-column
maximum of the header text and every value in that column
(`examples/psqlish/src/psqlish-display.adb:304-322`) — the right quantity for the tabular
layout. The expanded renderer (`:327-345`) then reuses the same array to pad the field
name: `Line (Name & Spaces (Widths (Index) - Name'Length) & " | " & Value);`. In expanded
mode each field occupies its own line, so the name column must be padded to the widest
*name*, not to each column's data width. For `select 7 as n, 'alpha' as value` psqlish
renders `n | 7` and `value | alpha` (separators in columns 3 and 7) where psql renders
`n     | 7` and `value | alpha` with both separators in column 7. Conversely, a short name
with a wide value pushes that one separator far to the right, so the `|` column wanders
from line to line within a single record.

---

### EXAMPLES-10: `;`, comment-only, and other whitespace-only simple queries get ERROR 42601 instead of EmptyQueryResponse

**Verdict:** CONFIRMED, and broader than reported. Besides the `;` and comment cases, the
handler's emptiness test uses `Ada.Strings.Fixed.Trim`, which RM A.4.3 defines as removing
`Space` characters only — so a query consisting of a tab, a newline, or a carriage return
also skips the EmptyQueryResponse path. The extended-query `Parse` branch has no emptiness
guard at all, so preparing an empty statement (legal in PostgreSQL) is rejected too.

**Severity:** P2 (unchanged). Real psql strips a bare `;` client-side and libpq tolerates
the error, so impact is limited to scripted or programmatic clients.

**Repro:** `examples/repros/src/repro_examples_10.adb`

**Output:**

```
  FAILED: Pgish_Handler treats a newline-only Query as empty
  FAILED: Pgish_Handler treats a tab-only Query as empty
  -- a bare semicolon is an empty query: Pgish_SQL.Syntax_Error "expected SELECT or SHOW statement" -> SQLSTATE 42601
  FAILED: a bare semicolon is an empty query
  -- a line comment is an empty query: Pgish_SQL.Syntax_Error "expected SELECT or SHOW statement" -> SQLSTATE 42601
  FAILED: a line comment is an empty query
  -- a block comment is an empty query: Pgish_SQL.Syntax_Error "expected SELECT or SHOW statement" -> SQLSTATE 42601
  FAILED: a block comment is an empty query
  -- a newline-only Query is an empty query: Pgish_SQL.Syntax_Error "expected SELECT or SHOW statement" -> SQLSTATE 42601
  FAILED: a newline-only Query is an empty query
  -- an empty string is an empty query: Pgish_SQL.Syntax_Error "expected SELECT or SHOW statement" -> SQLSTATE 42601
  FAILED: an empty string is an empty query
BUG REPRODUCED: 7 failed expectation(s)
```
exit status 1.

Wire-level confirmation:

```
== EXAMPLES-10 on the wire: bare semicolon ==
    ErrorResponse severity=ERROR code=42601 msg=expected SELECT or SHOW statement
    ReadyForQuery I
== EXAMPLES-10 on the wire: comment only ==
    ErrorResponse severity=ERROR code=42601 msg=expected SELECT or SHOW statement
    ReadyForQuery I
```

**Description:** `Pgish_Handler.Handle`'s `Protocol.Query` branch
(`examples/pgish/src/pgish_handler.adb:305-316`) sends EmptyQueryResponse only when
`Ada.Strings.Fixed.Trim (Query_Text, Both)` is empty; everything else reaches
`Pgish_SQL.Parse`, which raises `Syntax_Error with "expected SELECT or SHOW statement"`
whenever the parsed tree contains zero statements (`pgish_sql.adb:705-709`).
`Pgish_Handler.SQL_State_For` maps that to SQLSTATE 42601. PostgreSQL's
`exec_simple_query` answers EmptyQueryResponse for a query string containing no statement,
so a bare `;`, a comment-only submission, or a whitespace-only submission is reported by
pgish as a syntax error where the reference server reports an empty query. Because `Trim`
removes only `Space` characters, tab- and newline-only Query messages bypass the intended
guard as well; the same `Parse` is called with no guard from the extended-protocol `Parse`
branch (`pgish_handler.adb:318-329`), so preparing an empty statement also yields 42601.

---

### EXAMPLES-11: `SELECT *` with no FROM clause produces a zero-column row instead of an error

**Verdict:** CONFIRMED.

**Severity:** P2 (unchanged). pgish itself stays healthy and the wire messages are
well-formed; the practical harm is that it hands psqlish exactly the input that trips
EXAMPLES-4.

**Repro:** `examples/repros/src/repro_examples_11.adb`

**Output:**

```
  -- SELECT * with no FROM clause is rejected: accepted, Column_Count = 0, Row_Count = 1
  FAILED: SELECT * with no FROM clause is rejected
  -- SELECT *; with no FROM clause is rejected: accepted, Column_Count = 0, Row_Count = 1
  FAILED: SELECT *; with no FROM clause is rejected
BUG REPRODUCED: 2 failed expectation(s)
```
exit status 1.

Wire-level confirmation:

```
== EXAMPLES-11 on the wire: SELECT * with no FROM ==
    RowDescription fields=0 []
    DataRow []
    CommandComplete 'SELECT 1'
    ReadyForQuery I
```

**Description:** In `Pgish_Catalog.Project` (`examples/pgish/src/pgish_catalog.adb:519-527`
and `:569-573`), star expansion loops over `Source.Column_Count`; with no FROM clause
`Source` is the default empty `Result_Set`, so neither a column nor a value is added.
`:600-607` then still calls `Add_Projected_Row (Empty_Row)` for the no-table case, so the
result is one row of zero columns. `Pgish_Handler.Send_Result` faithfully puts a
RowDescription with 0 fields, a DataRow with 0 columns, and `CommandComplete 'SELECT 1'` on
the wire. PostgreSQL rejects `SELECT *` without tables with SQLSTATE 42601
("SELECT * with no tables specified is not valid"). Since psqlish narrows the field count
to `Positive`, `SELECT *;` typed into psqlish against pgish crashes the client
(EXAMPLES-4); real psql prints `--` / `(1 row)` and survives.

---

## Notes on method and cleanup

- Files created: `examples/repros/src/repro_examples_{1,2,3,4,5,6,7,9,10,11}.adb` only.
  Nothing under `src/`, `sql/`, `examples/pgish/`, `examples/psqlish/`,
  `examples/psqlbench/` or `tests/` was modified; nothing was committed. The harness's own
  `repro_examples_smoke` still prints `PASS` (exit 0), so the project file and switches are
  unchanged.
- Helper scripts used to drive the pgish binary live outside the repository, in the session
  scratchpad (`pgwire.py`, `probe.py`, `exhaust*.py`).
- Every `flyology_pgish` instance was started under `timeout` on an ephemeral port
  (55599/55601/55603/55605/55607/55609) and killed afterwards; `pgrep -fl flyology_pgish`
  returns nothing.
- No full test suite was run.
