# Discovery report: EXAMPLES (pgish, psqlish, psqlbench)

Scope: read-only correctness review of `examples/pgish`, `examples/psqlish`, and
`examples/psqlbench` in the worktree
`/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd`.
Each README promise and each relevant PostgreSQL protocol rule was checked
against the code; the library contract was read from
`src/flyology-postgres-server.ads`, `src/flyology-postgres-server.adb` (command
loop, lines 486-521), `src/flyology-postgres-server_sessions.ads`, and
`src/flyology-postgres-protocol.ads`. Nothing was built or run.

Severity rubric (as given): P0 = crash/hang on ordinary input, or a protocol
violation that makes real psql/libpq fail; P1 = wrong result or unexpected
exception on valid input via a reachable path, or documented behavior violated;
P2 = edge-case incorrectness, wrong diagnostics, or README drift needing
unusual input.

## Summary

| ID | Title | Severity | Confidence |
| --- | --- | --- | --- |
| EXAMPLES-1 | pgish `LIKE '%'` / `'%%'` raises `Ada.Strings.Pattern_Error` instead of matching all non-NULL rows | P1 | high |
| EXAMPLES-2 | pgish silently evaluates `NOT LIKE` as `LIKE` (operator name `!~~` ignored) | P1 | high |
| EXAMPLES-3 | pgish `ORDER BY` sorts integer/bigint columns as text (`1,10,11,...,2`) while WHERE compares numerically | P1 | high |
| EXAMPLES-4 | psqlish raises `Constraint_Error` and tears down the connection on any zero-column result (`SELECT;` on Postgres, `SELECT *;` on pgish) | P1 | high |
| EXAMPLES-5 | pgish `information_schema.columns` fails with 54000 unless filtered by `table_name =`, even with `LIMIT` | P2 | high |
| EXAMPLES-6 | pgish folds double-quoted identifiers and ignores column qualifiers, contradicting README "case-insensitive unless double quoted" | P2 | high |
| EXAMPLES-7 | pgish `flyology_sessions` keeps phantom "idle" sessions after a client drops without Terminate | P2 | high |
| EXAMPLES-8 | `flyology_pgish` option/env errors escape the main handler (raised in the declarative part) and print a raw runtime traceback | P2 | high |
| EXAMPLES-9 | psqlish expanded (`\x on`) output pads each field name to its own column's data width, misaligning the `|` separators | P2 | high |
| EXAMPLES-10 | pgish answers `;`, comment-only, or newline-only simple queries with ERROR 42601 instead of EmptyQueryResponse | P2 | medium |
| EXAMPLES-11 | pgish `SELECT *` without FROM returns a zero-column row instead of an error (PostgreSQL rejects it) | P2 | high |

## Findings

### EXAMPLES-1: `LIKE '%'` (and `'%%'`) raises `Ada.Strings.Pattern_Error` instead of matching every non-NULL value
- Location: `examples/pgish/src/pgish_catalog.adb:444-466` (`Like`), used from `Matches` at `:468-503`
- Severity: P1
- Confidence: high
- Evidence:
  ```
  Leading  : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'First) = '%';
  Trailing : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'Last) = '%';
  First    : constant Integer := Pattern'First + Boolean'Pos (Leading);
  Last     : constant Integer := Pattern'Last - Boolean'Pos (Trailing);
  Needle   : constant String := (if First > Last then "" else Pattern (First .. Last));
  ...
  elsif Leading and Trailing then
     return Ada.Strings.Fixed.Index (Value, Needle) /= 0;
  ```
  For the pattern `'%'` the single character is both Leading and Trailing, so
  `Needle = ""` and `Ada.Strings.Fixed.Index (Value, "")` is evaluated. RM
  A.4.3 (Index): "Pattern_Error is propagated if Pattern is the null string".
  `'%%'` takes the same path (First = 2 > Last = 1).
- Failure scenario: `SELECT name FROM flyology_settings WHERE name LIKE '%'`.
  PostgreSQL (and the README's "substring patterns using percent only") returns
  every non-NULL row. pgish raises `ADA.STRINGS.PATTERN_ERROR`, which
  `Pgish_Handler.SQL_State_For` (`pgish_handler.adb:111-124`) maps to `XX000`
  with the GNAT runtime's exception message as the ErrorResponse text.
- Reproduction sketch (Ada, same harness as `pgish_tests.adb`):
  `Catalog.Execute (Context, Session, SQL.Parse ("SELECT name FROM flyology_settings WHERE name LIKE '%'"), Result)`.
  Expected: `Result.Row_Count = 6` (all settings rows; none is NULL).
  Actual: `Ada.Strings.Pattern_Error` propagates out of `Pgish_Catalog.Execute`.
  Same for pattern `'%%'`.
- Existing coverage: `pgish_tests.adb:53` only parses a LIKE predicate
  (`LIKE 'flyology_%'`) and never executes one; the integration script
  (`scripts/run-integration.sh`) runs no LIKE query. None covers a bare `%`.

### EXAMPLES-2: `NOT LIKE` is evaluated as `LIKE`
- Location: `examples/pgish/src/pgish_sql.adb:417-436` (`Add_Predicate`, A_Expr branch)
- Severity: P1
- Confidence: high
- Evidence:
  ```
  Name  : constant String := Name_From (Value.Name, "predicate operator");
  ...
  if Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Like then
     Item.Operator := Like_Match;
     Item.Value := Make_Text (String_Literal (Value.Rexpr.Value), Maximum_Value_Length);
  ```
  The operator `Name` is computed but never consulted for the LIKE kind. The
  checked-in PostgreSQL grammar (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15037-15040`,
  same in v17 at :14872-14875) lowers `a_expr NOT_LA LIKE a_expr` to
  `makeSimpleA_Expr(AEXPR_LIKE, "!~~", ...)`, i.e. the same `Aexpr_Like` kind
  with name `!~~`. pgish therefore stores `Like_Match` with no negation and
  `Matches` (`pgish_catalog.adb:468-503`) returns the positive match.
- Failure scenario: `SELECT name FROM flyology_settings WHERE name NOT LIKE 'maximum%'`
  returns the four `maximum_*` rows and omits `authentication` and `tls`,
  the exact inverse of PostgreSQL. No error is reported, so the caller gets
  a plausible-looking wrong result.
- Reproduction sketch: `Q := SQL.Parse ("SELECT name FROM flyology_settings WHERE name NOT LIKE 'maximum%'")`
  then `Catalog.Execute (Context, Session, Q, Result)`. Expected (PostgreSQL):
  2 rows (`authentication`, `tls`) or, if the subset excludes NOT LIKE, a
  `Syntax_Error` from `Parse`. Actual: `Parse` succeeds with
  `Q.Predicates (1).Operator = Like_Match`, and `Execute` returns 4 rows
  (`maximum_query_length`, `maximum_tokens`, `maximum_result_rows`,
  `maximum_sessions`). Also `... WHERE name NOT LIKE '%'` combines with
  EXAMPLES-1.
- Existing coverage: none for NOT LIKE (tests parse only positive LIKE).

### EXAMPLES-3: `ORDER BY` compares numeric columns as text although WHERE compares them numerically
- Location: `examples/pgish/src/pgish_catalog.adb:623-651` (`Sort`/`Before`); contrast `Matches` at `:486-503`
- Severity: P1
- Confidence: high
- Evidence:
  ```
  elsif Descending then return SQL.Image (Left.Value) > SQL.Image (Right.Value);
  else return SQL.Image (Left.Value) < SQL.Image (Right.Value);
  ```
  `Before` always uses Ada `String` comparison, even for columns declared with
  int4/int8 OIDs (`group_id` 23, `session_id` 23, `members`/`dispatches`/`query_count`
  20, `ordinal_position` 23, ...). `Matches` does detect both-numeric operands
  and compares `Long_Long_Integer`, so `WHERE members > 9` and
  `ORDER BY members` disagree.
- Failure scenario: every README example with `ORDER BY group_id` /
  `ORDER BY session_id` / `ORDER BY committed_at DESC` once values reach two
  digits: `SELECT session_id FROM flyology_sessions ORDER BY session_id`
  with live sessions 9 and 10 returns `10, 9`. Any `ORDER BY dispatches DESC`
  ranks `9` above `1000`.
- Reproduction sketch (deterministic, no sessions needed):
  `Catalog.Execute (Context, Session, SQL.Parse ("SELECT ordinal_position FROM information_schema.columns WHERE table_name = 'flyology_runtime_groups' ORDER BY ordinal_position"), Result)`
  (16 columns). Expected first three values `1, 2, 3` and last `16`.
  Actual order `1, 10, 11, 12, 13, 14, 15, 16, 2, 3, ..., 9`.
  Also `... ORDER BY ordinal_position DESC` yields `9, 8, ..., 2, 16, 15, ...`.
- Existing coverage: `pgish_tests.adb:173-185` orders a text column only
  (`table_name`); the integration script orders `group_id` and `committed_at`
  but discards the output (`>/dev/null`).

### EXAMPLES-4: psqlish raises `Constraint_Error` on any zero-column result and abandons the session
- Location: `examples/psqlish/src/psqlish_main.adb:234-235` and `:262-263`
- Severity: P1
- Confidence: high
- Evidence:
  ```
  Count : constant Positive := Protocol.Field_Count (Description);
  ...
  Count : constant Positive := Protocol.Column_Count (Row);
  ```
  while the library declares `function Field_Count (Item : Row_Description) return Natural`
  (`src/flyology-postgres-protocol.ads:370`) and
  `function Column_Count (Item : Data_Row) return Natural` (`:414`). A
  RowDescription with 0 fields (legal; `SELECT;` is valid SQL since PostgreSQL
  9.4 and `psql` prints `--` / `(1 row)`) fails the `Positive` subtype check.
  The exception leaves `Execute_Query`, `Run`'s handler
  (`psqlish_main.adb:516-522`) closes the socket without Terminate and
  re-raises, and the top-level handler prints `Exception_Information` and exits
  with failure. `Display.Begin_Result` itself accepts an empty `Column_Array`,
  so the defect is only the narrowing in main.
- Failure scenario: `psqlish --command 'select;'` against real PostgreSQL, or
  interactively `select;` (connection lost, REPL exits). Against pgish the
  same happens for `SELECT *;` because of EXAMPLES-11.
- Reproduction sketch: a verifier can (a) run
  `psqlish --command 'select;'` against the cached Postgres used by
  `scripts/run-integration.sh` (expected output `SELECT 1`, exit 0; actual
  `raised CONSTRAINT_ERROR : psqlish_main.adb:234 range check failed`, exit 1),
  or (b) feed `SELECT *;` to psqlish connected to pgish via
  `scripts/run-pgish-integration.sh` style stdin.
- Existing coverage: `fixture_tests.adb` never exercises a zero-column
  result; `scripts/run-integration.sh` runs `select 2 ...`, `generate_series`,
  `\d`, and `select 1 / 0` only.

### EXAMPLES-5: `information_schema.columns` is unusable without a `table_name =` predicate, even with `LIMIT`
- Location: `examples/pgish/src/pgish_catalog.adb:356-410` (`Add_Information_Columns`), `:653-706` (pushdown in `Execute`), `:83-90` (`Add_Row` raising at 32 rows)
- Severity: P2
- Confidence: high
- Evidence: `Add_Information_Columns` appends one row per column of every
  virtual table: 9 + 16 + 8 + 8 + 5 + 3 + 4 + 2 = 55 rows > `Maximum_Rows = 32`,
  so `Add_Row` raises `Resource_Limit_Error` ("result row limit exceeded")
  before `Project`/`LIMIT` run. `Execute` only pushes down the first predicate
  whose column is `table_name` with operator `Equal_To`; any other predicate
  (`table_schema = 'flyology'`, `table_name LIKE ...`, `column_name = ...`) or
  a bare `LIMIT` still materializes all 55 rows.
- Failure scenario: `SELECT column_name FROM information_schema.columns LIMIT 5`
  returns ERROR 54000 although the README lists the table and documents LIMIT.
  psqlish's `\d TABLE` (which always adds `table_name = ...`) is unaffected.
- Reproduction sketch: `Catalog.Execute (Context, Session, SQL.Parse ("SELECT column_name FROM information_schema.columns LIMIT 5"), Result)`.
  Expected: 5 rows. Actual: `Pgish_Catalog.Resource_Limit_Error`. Same for
  `... WHERE table_schema = 'flyology' LIMIT 1`.
- Existing coverage: `pgish_tests.adb:156-168` tests only the filtered
  (`table_name = 'flyology_server_info'`) shape, with the comment "stay within
  result bounds", so the unfiltered case is knowingly untested.

### EXAMPLES-6: double-quoted identifiers are case-folded and column qualifiers are ignored
- Location: `examples/pgish/src/pgish_catalog.adb:92-108` (`Base_Name`, `Find_Column`), `:515-558` (`Add_Projected_Column` names the output column via `Base_Name`), `:412-434` (`Load_Source` via `Base_Name`)
- Severity: P2
- Confidence: high
- Evidence:
  ```
  function Base_Name (Name : String) return String is
     Dot : constant Natural := Ada.Strings.Fixed.Index (Name, ".", Going => Ada.Strings.Backward);
  begin
     return To_Lower ((if Dot = 0 then Name else Name (Dot + 1 .. Name'Last)));
  ```
  The PostgreSQL parser preserves the case of `"Quoted"` identifiers (it folds
  only unquoted ones), but every catalog lookup lowercases the name and strips
  any qualifier, so quoting has no effect. README (`examples/pgish/README.md`,
  "Supported SQL"): "Identifiers are case-insensitive unless double quoted."
- Failure scenario: `SELECT "PROTOCOL_VERSION" FROM flyology_server_info`
  succeeds and labels the column `protocol_version`; PostgreSQL raises 42703.
  `SELECT nowhere.protocol_version FROM flyology_server_info` and
  `SELECT * FROM "FLYOLOGY_TABLES"` / `FROM bogus_schema.flyology_tables`
  succeed where PostgreSQL errors (missing FROM-clause entry / undefined table).
- Reproduction sketch: `Catalog.Execute (Context, Session, SQL.Parse ("SELECT ""PROTOCOL_VERSION"" FROM flyology_server_info"), Result)`.
  Expected per README: `Undefined_Column_Error`. Actual: 1 row,
  `SQL.Image (Result.Columns (1).Name) = "protocol_version"`. Likewise
  `SQL.Parse ("SELECT x.protocol_version FROM flyology_server_info")` executes.
- Existing coverage: `pgish_tests.adb:63-69` checks only that quoted
  lower-case identifiers parse; nothing checks case preservation or qualifier
  validation.

### EXAMPLES-7: `flyology_sessions` retains phantom sessions after a client disconnects without Terminate
- Location: `examples/pgish/src/pgish_handler.adb:419` (only `Terminate_Command` calls `Remove_Session`); `examples/pgish/src/pgish_state.adb:28-65` (`Register` reuses a slot only for the same `Task_Id`); library loop `src/flyology-postgres-server.adb:486-521`
- Severity: P2
- Confidence: high
- Evidence: the library's per-connection loop calls `Handle` only for messages
  actually read; when `Read_Command` raises (peer EOF/reset, TLS failure,
  `Command_Timeout` of 300 s), it runs `Context.Router.Remove (Key)` and
  re-raises. `Flyology.Postgres.Server` has no disconnect callback (generic
  formals are `Authenticate`, `Lookup_SCRAM_Verifier`, `Handle` only), so
  pgish's `Session_Registry` slot stays `Occupied` with `State = "idle"`. The
  handler tasks are a fixed pool ("number of handler tasks created eagerly by
  Serve", `flyology-io-structured_servers.ads:85`), so the slot is overwritten
  only when that same task serves its next connection; until then
  `SELECT ... FROM flyology_sessions` (README example) lists a dead session
  with its old `session_id`, `query_count`, and `connected_at`. The same
  happens when `Authenticate` registers the slot but the router is full
  (`server.adb:461-473`) or startup writes fail.
- Failure scenario: connect with psql, `kill -9` it (or close a raw TCP socket
  after startup), then from another connection run
  `SELECT session_id, state FROM flyology_sessions`: the dead session is still
  reported as `idle`.
- Reproduction sketch: server-level only (needs two connections). Expected:
  only live sessions listed. Actual: phantom row until slot reuse. No
  slot exhaustion is possible (one slot per handler task), so this is a
  state/observability error, not a denial of service.
- Existing coverage: none (integration script always terminates cleanly).

### EXAMPLES-8: `flyology_pgish` option and environment errors bypass the main exception handler
- Location: `examples/pgish/src/flyology_pgish.adb:136` (`Options : constant Parsed_Configuration := Read_Configuration;` in the declarative part) vs. handler at `:242-249`
- Severity: P2
- Confidence: high
- Evidence: `Read_Configuration` raises `Constraint_Error` for `--port abc`
  (`Natural'Value`), out-of-range ports, unknown options, a missing option
  value, bad `--task-mode`, or a lone `--tls-cert`/`--tls-key`
  (`:66-67, 81, 97, 102-114`), and `Natural'Value` on `FLYOLOGY_PGISH_PORT`
  (`:41-43`). Because `Options` is elaborated in the declarative part, RM 11.2
  means the procedure's own `exception` handler does not apply; the exception
  propagates out of the main program, so the intended
  `flyology_pgish: unknown option: --bogus` line and `Set_Exit_Status` path
  never run and GNAT prints `raised CONSTRAINT_ERROR : ... unknown option: --bogus`
  with a traceback-style message instead. (No hang: `Shutdown_Watcher` is
  never activated when the declarative part fails.)
- Failure scenario: `./bin/flyology_pgish --port abc`, `--port 70000`,
  `--bogus`, or `FLYOLOGY_PGISH_PORT=x ./bin/flyology_pgish`.
- Reproduction sketch: run the binary with `--port abc`; expected stderr
  `flyology_pgish: ...` and exit status 1; actual: unhandled-exception report
  from the runtime.
- Existing coverage: none.

### EXAMPLES-9: psqlish expanded output misaligns field names
- Location: `examples/psqlish/src/psqlish-display.adb:304-322` (Widths include data widths), `:327-345` (expanded renderer pads `Name` with `Widths (Index)`)
- Severity: P2
- Confidence: high
- Evidence:
  ```
  Line (Name & Spaces (Widths (Index) - Name'Length) & " | " & Value);
  ```
  `Widths (Index)` is the per-column maximum of the header and all values of
  that column (computed for the tabular layout). In expanded mode each column
  is its own line, so the name column should be padded to the widest *name*;
  padding each name to its own column's data width makes the `|` separators
  wander.
- Failure scenario: `\x on` then `select 7 as n, 'alpha' as value;` renders
  `n | 7` and `value | alpha` (psql: `n     | 7` / `value | alpha`).
  Conversely a wide value in a short-named column pushes that one separator
  far right.
- Reproduction sketch (Display only): `Set_Expanded (View, True); Begin_Result (View, (Make_Column ("n"), Make_Column ("value"))); Add_Row (View, (Text_Cell ("7"), Text_Cell ("alpha"))); Out := Finish_Result (View, "SELECT 1")`.
  Expected lines `n     | 7` and `value | alpha`. Actual `n | 7` and
  `value | alpha`.
- Existing coverage: `fixture_tests.adb:84-104` checks only that `RECORD 1`
  appears.

### EXAMPLES-10: `;`, comment-only, or newline-only simple queries get ERROR 42601 instead of EmptyQueryResponse
- Location: `examples/pgish/src/pgish_handler.adb:305-316` (trims spaces only), `examples/pgish/src/pgish_sql.adb:705-709` (`Statement_Count = 0` raises `Syntax_Error`)
- Severity: P2
- Confidence: medium (behavior certain; psql impact modest)
- Evidence:
  ```
  Text : constant String := Ada.Strings.Fixed.Trim (Sessions.Query_Text (Command), Ada.Strings.Both);
  if Text'Length = 0 then Send_Empty_Query_Response ...
  ```
  then `Parse` on `";"`, `"-- note"`, `"/* c */"`, or `"\n"` yields zero raw
  statements and raises `Syntax_Error with "expected SELECT or SHOW statement"`,
  reported as SQLSTATE 42601. PostgreSQL's `exec_simple_query` sends
  EmptyQueryResponse for a query string with no statements (psql prints
  nothing for a bare `;`). The extended path has the same gap: Parse of an
  empty string is legal in PostgreSQL but rejected here.
- Failure scenario: `psql -c ';'` or typing `;` alone; scripts with a trailing
  comment-only submission.
- Reproduction sketch: `SQL.Parse (";")` and `SQL.Parse ("-- hi")` currently
  raise `Syntax_Error`; the handler should have treated them as empty. Expected
  wire sequence `EmptyQueryResponse, ReadyForQuery`; actual
  `ErrorResponse(42601), ReadyForQuery`.
- Existing coverage: none.

### EXAMPLES-11: `SELECT *` with no FROM produces a zero-column row instead of an error
- Location: `examples/pgish/src/pgish_catalog.adb:519-527` and `:569-573` (star expansion over an empty `Source`), `:605-607` (`Add_Projected_Row (Empty_Row)` when no table)
- Severity: P2
- Confidence: high
- Evidence: with `Table_Name` empty, `Source.Column_Count = 0`, so the
  `Star_Projection` loops add no columns and no values, then
  `Add_Projected_Row (Empty_Row)` appends one row. The handler then sends a
  RowDescription with 0 fields, a DataRow with 0 columns, and `SELECT 1`.
  PostgreSQL rejects `SELECT *` without tables with 42601 ("SELECT * with no
  tables specified is not valid").
- Failure scenario: `SELECT *;` from psql prints `--` / `(1 row)`; from psqlish
  it triggers EXAMPLES-4 (client crash).
- Reproduction sketch: `Catalog.Execute (Context, Session, SQL.Parse ("SELECT *"), Result)`.
  Expected: a `Syntax_Error`/`Undefined_Column_Error`. Actual:
  `Result.Column_Count = 0 and Result.Row_Count = 1`.
- Existing coverage: none.

## Areas reviewed with no findings
- pgish extended-protocol state machine (`pgish_handler.adb:293-425`): Parse
  validates before storing; Bind checks the statement name (26000 on mismatch);
  Describe 'S' sends ParameterDescription(0) then RowDescription, Describe 'P'
  sends RowDescription; Execute re-runs the portal and sends `SELECT n`;
  Close of unknown names succeeds silently (`pgish_state.adb:185-204`);
  errors set the discard-until-Sync state and only Sync/Terminate are honored
  while failed, matching PostgreSQL's `ignore_till_sync` (which also skips
  simple Query). Simple Query always ends in ReadyForQuery('I').
- pgish command tag format (`"SELECT" & Rows'Image` gives `SELECT 3`), NULL vs
  empty text on the wire (`Null_Column` vs `Text_Column ("")`), cancellation
  check between rows with 57014, NULL semantics of comparison predicates
  (`NULL <> x` is false), NULL ordering (ASC nulls last, DESC nulls first),
  LIMIT applied after ORDER BY, `LIMIT 33+` rejected before execution,
  negative/`-12` literal folding, doubled-quote string literals, alias naming,
  `?column?` naming, `SHOW` answers, `current_user`/`current_database()`
  from startup identity, timestamp text `YYYY-MM-DD HH:MM:SS+00`.
- pgish psql compatibility adapter against psql 18's `\dt` and `\d` query
  shapes (oid/nspname/relname lookup, `c.relchecks` row with relkind `v`, the
  `pg_attribute a` column query keyed by `'1000N'`, `pg_get_userbyid` listing).
  Plain `\d` does not fetch `pg_get_viewdef` (that is `\d+` only), so the
  documented commands work.
- pgish session identity keyed by `Ada.Task_Identification.Current_Task`:
  the flyology README states lightweight handlers "remain Ada tasks", so each
  pooled handler task has a distinct `Task_Id`; no cross-session slot sharing.
- pgish signal/shutdown path: `Pgish_Signals.Complete` is called on help, on
  `Serve` exceptions, and on normal return, so `Shutdown_Watcher` always
  terminates; SIGTERM maps to `Request_Shutdown` within 50 ms.
- pgish `Load_Commits`: argument array (no shell), 0x1F/0x1E separators,
  CR/LF stripping, bounded fields, temp-file cleanup on every path.
- psqlish input handling per README rule ("last non-whitespace byte is a
  semicolon"), meta-command dispatch only at a fresh prompt, EOF submits a
  pending buffer, `\pset null` with empty marker, `\d schema.table` split at
  the last dot with `'` doubling.
- psqlish display: byte-oriented width (documented), control-byte escaping
  keeps borders intact, `...` truncation stays within `Cell_Width`, numeric
  right-alignment only when every non-NULL value is numeric, `(1 row)` vs
  `(n rows)`, batch flush at 1,000 rows/1 MiB with repeated headers
  (documented), binary cells as `\x..`, error/notice formatting with SQLSTATE,
  `Time: ... ms` format.
- psqlish options: env defaults then CLI overrides, `--opt=value` and
  `--opt value`, `--host`/`--hostaddr` prefix disambiguation, port range,
  sslmode restricted to disable/verify-full, no password option (documented).
- psqlbench: `Psqlbench_JSON` delegates all string escaping and number
  encoding to `utilada` (`Util.Serialize.IO.JSON`), as the README states;
  persistence, links, logs, server, and query modules build JSON only through
  that writer, and every `'Image` used for output is trimmed. No manual
  escaping or untrimmed number formatting was found, and `utilada` itself is
  outside this review.

## Observations not counted
- pgish `LIKE` rejects any `_` in the pattern with 0A000 (`pgish_catalog.adb:451-455`);
  since every virtual table name contains `_`, `LIKE 'flyology_%'` (the very
  pattern parsed in `pgish_tests.adb:53`) fails at execution. README says
  "percent only", so treated as documented scope.
- `Psql_Compatibility` matches raw query text before parsing
  (`pgish_catalog.adb:715-729`): a user query whose text merely contains
  `from pg_catalog.pg_tables` (for example inside a string literal) is answered
  with the table listing. Needs contrived input.
- `LIMIT ALL` (a NULL constant in the grammar) is rejected with the misleading
  message "comparison requires a literal value"; `SELECT NULL`, `SELECT true`,
  and `SELECT 1.5` are likewise rejected. Bounded subset, but the messages
  reuse the comparison wording.
- Unsupported-but-valid statements (`BEGIN`, `SET`, DDL) are reported as
  42601 (syntax_error) rather than 0A000; unknown portal on Execute/Describe
  is 26000 rather than 34000; an internal `Constraint_Error` would also be
  reported as 26000 because of the name-based mapping (`pgish_handler.adb:121`).
- Boolean columns (OID 16) are sent as `true`/`false` text; PostgreSQL's
  canonical text is `t`/`f`. Common drivers accept both.
- Cancellation during an extended `Execute` sends ErrorResponse but does not
  enter the failed state, so later Bind/Execute in the same batch are still
  processed before Sync (libpq tolerates this).
- Execute with a non-zero row limit is rejected with 0A000 (portal suspension
  unsupported); libpq/psql always send 0, and the README calls the extended
  subset bounded.
- A `FunctionCall` ('F') message gets an ErrorResponse plus the failed state,
  so a client that does not follow with Sync never sees ReadyForQuery.
- psqlish cell truncation operates on bytes and removes 3 bytes before
  `...`, so a multibyte UTF-8 sequence can be split at the cut. README
  documents byte-oriented width, so not counted.
- psqlish `\pset null  X` (two spaces) keeps the leading space in the marker;
  the row-omission footer prints a double space (`Natural'Image`).
- psqlish `\x` without an argument prints a usage error instead of toggling
  (documented as `on|off`).
- pgish `\d+` would fail (`pg_get_viewdef` is not answered); README only
  promises `\dt` and `\d`.
