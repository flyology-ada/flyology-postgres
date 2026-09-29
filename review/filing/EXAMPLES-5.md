Title: pgish information_schema.columns exceeds the 32-row bound unless a table_name equality filter is supplied
Labels: bug
Refs: none

## Summary

`Pgish_Catalog.Add_Information_Columns` materialises one row per column of every virtual table, 55 rows, before any projection, filter or `LIMIT` is applied, and `Add_Row` raises `Resource_Limit_Error` at the 32-row bound. `Pgish_Catalog.Execute` pushes a filter into the generator only for the first predicate whose base column is `table_name` and whose operator is `Equal_To`. `SELECT column_name FROM information_schema.columns LIMIT 5`, built entirely from documented subset features, therefore fails with SQLSTATE 54000 even though the requested result is five rows.

## Problem

Commit `6f496f5`.

The generator materialises every table's columns first (`examples/pgish/src/pgish_catalog.adb:386-409`):

```ada
      for Table of Tables loop
         if Only_Table'Length = 0
           or else Base_Name (Only_Table) = Base_Name (SQL.Image (Table.Name))
         then
            Load (SQL.Image (Table.Name));
            for Column in 1 .. Source.Column_Count loop
               Values := (others => Null_Cell);
               ...
               Add_Row (Result, Values);
            end loop;
         end if;
      end loop;
```

With no `Only_Table` the eight virtual tables contribute 9 + 16 + 8 + 8 + 5 + 3 + 4 + 2 = 55 rows, counted from `Add_Server_Info` (`examples/pgish/src/pgish_catalog.adb:117-125`), `Add_Runtime_Groups` (`:145-160`), `Add_Stack_Pool` (`:190-198`), `Add_Sessions` (`:216-223`), `Add_Commits` (`:248-252`), `Add_Tables` (`:268-270`), `Add_Settings` (`:293-296`) and `Add_Environment` (`:323-324`).

`Add_Row` refuses the thirty-third (`examples/pgish/src/pgish_catalog.adb:83-90`):

```ada
   procedure Add_Row (Result : in out Result_Set; Values : Cell_Array) is
   begin
      if Result.Row_Count = Maximum_Rows then
         raise Resource_Limit_Error with "result row limit exceeded";
      end if;
```

`Maximum_Rows` is `Pgish_SQL.Maximum_Result_Rows` (`examples/pgish/src/pgish_catalog.ads:12`), which is 32 (`examples/pgish/src/pgish_sql.ads:11`).

Only one predicate shape reaches the generator (`examples/pgish/src/pgish_catalog.adb:682-697`):

```ada
            declare
               Table_Filter : SQL.Value_Text;
            begin
               for Index in 1 .. Query.Predicate_Count loop
                  if Base_Name (SQL.Image (Query.Predicates (Index).Column)) =
                    "table_name"
                    and then Query.Predicates (Index).Operator = SQL.Equal_To
                  then
                     Table_Filter := Query.Predicates (Index).Value;
                     exit;
                  end if;
               end loop;
               Source := (others => <>);
               Add_Information_Columns
                 (State, Source, SQL.Image (Table_Filter));
            end;
```

Everything else is applied after the fact: `Project` filters the materialised rows (`examples/pgish/src/pgish_catalog.adb:608-619`) and `Limit` truncates the projected result (`examples/pgish/src/pgish_catalog.adb:706-707`), both of which run only if `Add_Information_Columns` returned at all.

Every part of the failing query is documented. `information_schema.columns` is a listed virtual table (`examples/pgish/README.md:116`), `LIMIT 0..32` is part of the stated grammar (`examples/pgish/README.md:73`), and `table_schema` is one of the view's own columns (`examples/pgish/src/pgish_catalog.adb:379`). The README's bounds paragraph presents 32 as a result bound, not as a bound on intermediate rows (`examples/pgish/README.md:145-146`):

> Queries are limited to 8,192 bytes, 128 tokens, 16 projections, eight predicates, 16 result columns, 32 result rows, and 256 bytes per result value.

The suite covers only the shape that works. Its `information_schema.columns` test always supplies `table_name = 'flyology_server_info'` (`examples/pgish/src/pgish_tests.adb:156-168`), which is the same shape `psqlish`'s `\d TABLE` sends (`examples/psqlish/README.md:94-96`), and the real `psql` integration script queries `information_schema.tables`, not `columns` (`examples/pgish/scripts/run-integration.sh:95-96`).

## What happens now

Spike: the program runs the covered `table_name =` shape as a control, then a bare `LIMIT 5`, then a `table_schema =` filter with `LIMIT 1`, then a `table_name LIKE` filter with `LIMIT 5`, asserting that each returns its small documented result without raising.

```ada
   --  Baseline: the pushdown shape already covered by pgish_tests works.
   Try ("SELECT column_name FROM information_schema.columns " &
        "WHERE table_name = 'flyology_server_info'", 9);

   --  A bare LIMIT, documented by the README as part of the subset.
   Try ("SELECT column_name FROM information_schema.columns LIMIT 5", 5);
```

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

The control shows that the table itself is readable, so the failure is in the row budget spent before projection rather than in the catalog data.

Observed against the running `examples/pgish/bin/flyology_pgish` on an ephemeral port:

```
== information_schema.columns LIMIT 5 on the wire ==
    ErrorResponse severity=ERROR code=54000 msg=result row limit exceeded
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A query whose result fits inside the documented 32-row bound should return that result. `SELECT column_name FROM information_schema.columns LIMIT 5` asks for five rows and every part of it is inside the documented subset, so it should succeed rather than reporting a resource limit.

## Suggested treatment

Stop spending the result budget on rows the query cannot return. The smallest fix is to pass the effective row ceiling into `Add_Information_Columns` and stop the outer loop once enough rows exist for the query, so generation ends at the `LIMIT` rather than at `Maximum_Rows`. That alone fixes the bare-`LIMIT` and `table_schema` cases.

Applying the predicates during generation instead of after it also fixes the `table_name LIKE` case and removes the special status of the `table_name` equality pushdown, but it moves predicate evaluation into the generator and is a larger change.

This needs a maintainer decision on where the 32-row bound applies: to the rows a query returns, or to the rows the catalog materialises. The options are to keep the current meaning and document it, to bound only the returned rows and let generation stream, or to give `information_schema.columns` a larger generation bound than the result bound. The README's bounds paragraph (`examples/pgish/README.md:145-147`) must state the chosen meaning.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the existing filtered-columns test (`examples/pgish/src/pgish_tests.adb:156-168`), asserting that an unfiltered `information_schema.columns` query with a small `LIMIT` succeeds. The spike is that test. That existing test passes today and keeps passing; no test asserts the current failure.

## Severity

An ordinary discovery query built only from documented features returns an error instead of its result, so a client browsing the catalog cannot list columns without already knowing a table name. The failure is a clean ErrorResponse with a plausible SQLSTATE and the session stays usable, so nothing is lost beyond the answer. It applies to every `information_schema.columns` query that lacks a `table_name` equality predicate. Deterministic.
