Title: pgish ORDER BY compares integer columns as text while WHERE compares them numerically
Labels: bug
Refs: none

## Summary

`Pgish_Catalog.Sort.Before` compares every value as an Ada `String`, ignoring the column's type OID, while `Pgish_Catalog.Matches` detects two numeric operands and compares them as `Long_Long_Integer`. The two halves of one query therefore disagree: `WHERE ordinal_position > 9` is numeric and correct, but `ORDER BY ordinal_position` yields `1,10,11,...,16,2,...,9`. Every integer column in the virtual catalog is affected, so three of the README's own example queries return rows in the wrong order as soon as a value reaches two digits.

## Problem

Commit `6f496f5`.

Sorting is unconditionally lexicographic (`examples/pgish/src/pgish_catalog.adb:623-632`):

```ada
   procedure Sort (Result : in out Result_Set; Column : String; Descending : Boolean) is
      Index : constant Natural := Find_Column (Result, Column);
      function Before (Left, Right : Cell) return Boolean is
      begin
         if Left.Is_Null then return Descending and then not Right.Is_Null;
         elsif Right.Is_Null then return not Descending;
         elsif Descending then return SQL.Image (Left.Value) > SQL.Image (Right.Value);
         else return SQL.Image (Left.Value) < SQL.Image (Right.Value);
         end if;
      end Before;
```

`Cell` carries no type, and `Sort` never consults `Result.Columns (Index).Type_Oid`, which the catalog does populate: `information_schema.columns.ordinal_position` is declared int4 (`examples/pgish/src/pgish_catalog.adb:382`), and so are `session_id` (`:216`), `group_id` (`:145`) and `listen_port` (`:122`), with int8 for `members`, `dispatches`, `query_count` and `uptime_seconds` (`:149`, `:158`, `:220`, `:119`).

Filtering does consult the values numerically (`examples/pgish/src/pgish_catalog.adb:488-497`):

```ada
      Both_Numeric := Numeric (SQL.Image (Cell_Value.Value), Left_Number)
        and then Numeric (SQL.Image (Predicate.Value), Right_Number);
      if Both_Numeric then
         Comparison := (if Left_Number < Right_Number then -1
                        elsif Left_Number > Right_Number then 1 else 0);
      else
         Comparison :=
           (if SQL.Image (Cell_Value.Value) < SQL.Image (Predicate.Value) then -1
            elsif SQL.Image (Cell_Value.Value) > SQL.Image (Predicate.Value) then 1 else 0);
      end if;
```

PostgreSQL orders an integer column numerically, using the ordering of its type. `information_schema.columns.ordinal_position` is `cardinal_number` (`tests/.cache/postgres/18.4-openssl/source/src/backend/catalog/information_schema.sql:672`), and that domain is `integer` (`tests/.cache/postgres/18.4-openssl/source/src/backend/catalog/information_schema.sql:187-188`):

```sql
CREATE DOMAIN cardinal_number AS integer
    CONSTRAINT cardinal_number_domain_check CHECK (value >= 0);
```

The README's example queries order by integer columns (`examples/pgish/README.md:124-137`):

```sql
SELECT group_id, members, ready, waiting, dispatches
FROM flyology_runtime_groups
WHERE members > 0
ORDER BY group_id;
...
SELECT session_id, user_name, database_name, query_count, state
FROM flyology_sessions
ORDER BY session_id;
```

and `ORDER BY committed_at DESC` (`examples/pgish/README.md:132`) sorts a timestamp rendered as text.

The tests only ever order text. The pgish suite's ordering assertion sorts `table_name` and compares the two results as strings (`examples/pgish/src/pgish_tests.adb:174-185`), which is correct for text and hides the type-blind comparison. The real `psql` integration script runs `ORDER BY group_id LIMIT 4` and `ORDER BY committed_at DESC LIMIT 2` but discards both outputs with `>/dev/null` (`examples/pgish/scripts/run-integration.sh:118-123`), so neither order is checked.

## What happens now

Spike: the program asks `information_schema.columns` for the 16 `ordinal_position` values of `flyology_runtime_groups`, once ascending and once descending, and asserts that position 2 sorts second and position 16 sorts last. It then runs `WHERE ordinal_position > 9` on the same column to show that the filter is numeric.

```ada
   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT ordinal_position FROM information_schema.columns " &
         "WHERE table_name = 'flyology_runtime_groups' " &
         "ORDER BY ordinal_position"),
      Result);
   ...
   Check (Result.Row_Count = 16 and then Cell_Text (2) = "2",
          "ascending ORDER BY places 2 second, not 10");
```

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

The last line is the control: the same column, the same values, and a numerically correct answer from the filter, which is what makes the disagreement inside one query visible.

Observed against the running `examples/pgish/bin/flyology_pgish` while probing session state, `SELECT session_id, application_name, state FROM flyology_sessions ORDER BY session_id` returned session identifiers in the order `1, 10, 11, 12, 13, 14, 15, 17, 2, 3, ...`, so the README's own `ORDER BY session_id` example is already wrong once a server has served ten connections.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

`ORDER BY` on an int4 or int8 column should order numerically, matching both PostgreSQL and the numeric comparison `Pgish_Catalog.Matches` already performs on the same column. The two clauses of one query should not use different orderings for the same values.

## Suggested treatment

Give `Sort` the column's type. `Find_Column` already returns the index into `Result.Columns`, so `Before` can read `Result.Columns (Index).Type_Oid` and, for the integer OIDs the catalog emits (23 and 20), compare with the `Numeric` helper that `Matches` uses (`examples/pgish/src/pgish_catalog.adb:436-442`), falling back to the string comparison for everything else. That keeps one definition of numeric comparison and leaves text columns unchanged.

Comparing on `Numeric` succeeding for both cells, rather than on the type OID, would also fix the reproduced cases and would additionally reorder text columns whose values happen to look numeric. Which of the two rules applies is a maintainer decision: the type-directed rule matches PostgreSQL, the value-directed rule matches what `Matches` does today.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the existing descending-order assertion (`examples/pgish/src/pgish_tests.adb:174-185`), ordering an integer column across the nine-to-ten boundary. The spike is that test. No existing test asserts the current behaviour, so none has to change. The integration script's two discarded ordering queries (`examples/pgish/scripts/run-integration.sh:118-123`) should compare their output instead of sending it to `/dev/null`.

## Severity

Any `ORDER BY` on an integer column returns rows in the wrong order once a value reaches two digits, with no error, so `ORDER BY dispatches DESC` ranks 9 above 1000 and a client reading the top row gets the wrong one. Three of the README's own example queries are affected, and the columns involved (`session_id`, `group_id`, `members`, `dispatches`, `query_count`, `listen_port`, `uptime_seconds`, `ordinal_position`) are the ones a discovery client sorts by. Single-digit data hides it, so the failure appears only once a counter passes 9. Deterministic.
