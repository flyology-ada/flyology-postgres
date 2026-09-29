Title: pgish returns a zero-column row for SELECT * with no FROM clause instead of rejecting it
Labels: bug
Refs: EXAMPLES-4

## Summary

In `Pgish_Catalog.Project` the star expansion loops over `Source.Column_Count`, and with no FROM clause `Source` is the default empty `Result_Set`, so no column and no value is added. The no-table branch still appends one row, so the result is a single row of zero columns, and the handler puts a RowDescription with zero fields, a DataRow with zero columns and `CommandComplete 'SELECT 1'` on the wire. PostgreSQL rejects `SELECT *` with no tables specified with SQLSTATE 42601. The messages pgish sends are exactly the input that crashes the companion client.

## Problem

Commit `6f496f5`.

The star expansion adds a column per source column (`examples/pgish/src/pgish_catalog.adb:519-527`):

```ada
         if Projection.Kind = SQL.Star_Projection then
            for Index in 1 .. Source.Column_Count loop
               Add_Column
                 (Result, SQL.Image (Source.Columns (Index).Name),
                  Source.Columns (Index).Type_Oid,
                  Source.Columns (Index).Type_Size);
            end loop;
            return;
         end if;
```

and the row expansion adds a value per source column (`examples/pgish/src/pgish_catalog.adb:569-573`):

```ada
               if Projection.Kind = SQL.Star_Projection then
                  for Index in 1 .. Source.Column_Count loop
                     Output := Output + 1;
                     Values (Output) := Source_Row.Values (Index);
                  end loop;
```

With no FROM clause `Execute` never calls `Load_Source`, so `Source` keeps the default value it was given at `examples/pgish/src/pgish_catalog.adb:658` and `Source.Column_Count` is zero. Both loops run zero times. The no-table branch nevertheless emits a row (`examples/pgish/src/pgish_catalog.adb:600-606`):

```ada
      Empty_Row : constant Result_Row := (Values => (others => Null_Cell));
   begin
      for Index in 1 .. Query.Projection_Count loop
         Add_Projected_Column (Query.Projections (Index));
      end loop;
      if SQL.Is_Empty (Query.Table_Name) then
         Add_Projected_Row (Empty_Row);
```

which is correct for `SELECT current_user` and the other table-free projections, and wrong for a star.

PostgreSQL rejects the statement in `ExpandAllTables` (`tests/.cache/postgres/18.4-openssl/source/src/backend/parser/parse_target.c:1322-1331`):

```c
	/*
	 * Check for "SELECT *;".  We do it this way, rather than checking for
	 * target == NIL, because we want to allow SELECT * FROM a zero_column
	 * table.
	 */
	if (!found_table)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("SELECT * with no tables specified is not valid"),
				 parser_errposition(pstate, location)));
```

`ERRCODE_SYNTAX_ERROR` is 42601 (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/errcodes.txt:340`), and the comment shows the rejection is deliberate rather than a side effect of an empty target list.

The pgish README's grammar makes `FROM virtual_table` optional and lists `*` among the supported projections (`examples/pgish/README.md:68-81`), so nothing in the documented subset excludes the combination, and the README says unsupported constructs return an ErrorResponse with a specific SQLSTATE (`examples/pgish/README.md:88-91`).

The suite uses `SELECT *` only with a FROM clause, either to reject an unsupported construct (`examples/pgish/src/pgish_tests.adb:107-128`) or to reject an unknown table (`examples/pgish/src/pgish_tests.adb:206-212`), and its table-free execution test projects named functions rather than a star (`examples/pgish/src/pgish_tests.adb:196-204`). The real `psql` integration script's recovery fixture uses `SELECT FROM flyology_tables`, which has a FROM clause and no projection (`examples/pgish/scripts/run-integration.sh:125-130`).

## What happens now

Spike: the program submits `SELECT *` and `SELECT *;` with no FROM clause and asserts that each is rejected, accepting any of the catalog's rejection exceptions.

```ada
   Expect_Rejected ("SELECT *", "SELECT * with no FROM clause is rejected");
   Expect_Rejected ("SELECT *;", "SELECT *; with no FROM clause is rejected");
```

```
  -- SELECT * with no FROM clause is rejected: accepted, Column_Count = 0, Row_Count = 1
  FAILED: SELECT * with no FROM clause is rejected
  -- SELECT *; with no FROM clause is rejected: accepted, Column_Count = 0, Row_Count = 1
  FAILED: SELECT *; with no FROM clause is rejected
BUG REPRODUCED: 2 failed expectation(s)
```

Observed against the running `examples/pgish/bin/flyology_pgish` on an ephemeral port:

```
== SELECT * with no FROM on the wire ==
    RowDescription fields=0 []
    DataRow []
    CommandComplete 'SELECT 1'
    ReadyForQuery I
```

The messages are well formed and the server stays healthy. Real `psql` prints `--` and `(1 row)` for them, but the companion client narrows the field count to `Positive` and dies on the same three messages, which is reported separately in {{ISSUE:EXAMPLES-4}}.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

`SELECT *` with no FROM clause should be rejected with SQLSTATE 42601, as `ExpandAllTables` does (`tests/.cache/postgres/18.4-openssl/source/src/backend/parser/parse_target.c:1327-1331`), rather than answered with a zero-column row.

## Suggested treatment

Reject the combination where it is detectable. `Pgish_SQL.Parse` already knows both the table name and the projection kinds, so raising `Syntax_Error` there when a star projection appears with an empty `Table_Name` reproduces PostgreSQL's 42601 through the mapping `Pgish_Handler.SQL_State_For` already applies (`examples/pgish/src/pgish_handler.adb:115`). Rejecting in `Pgish_Catalog.Project` instead, at the no-table branch (`examples/pgish/src/pgish_catalog.adb:605-606`), gives the same result one layer later.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` in the rejection list (`examples/pgish/src/pgish_tests.adb:106-128`), asserting that `SELECT *` with no FROM clause is rejected. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

pgish accepts a statement PostgreSQL rejects and answers it with a row that carries no data, so a client is told one row was selected and receives nothing in it. The server itself stays healthy and every message it sends is well formed, so the direct harm is limited to the wrong answer. The practical harm is larger for the companion client, which crashes on precisely these messages ({{ISSUE:EXAMPLES-4}}). It needs `SELECT *` written without a FROM clause. Deterministic.
