Title: pgish evaluates NOT LIKE as LIKE and returns the inverse row set with no diagnostic
Labels: bug
Refs: none

## Summary

`Pgish_SQL.Add_Predicate` computes the operator name of an `A_Expr` node and then ignores it on the `AEXPR_LIKE` branch, storing `Like_Match` unconditionally. The PostgreSQL grammar lowers `a NOT LIKE b` to that same node kind with the operator name `!~~`, so pgish drops the negation. `WHERE name NOT LIKE 'maximum%'` returns exactly the rows PostgreSQL excludes and omits the rows PostgreSQL returns. No error is sent, so a client cannot tell the answer is inverted.

## Problem

Commit `6f496f5`.

The lowering computes `Name` and then never consults it for the LIKE kind (`examples/pgish/src/pgish_sql.adb:414-437`):

```ada
         when AST.Node_A_Expr =>
            declare
               Value : constant AST.A_Expr := Expression.A_Expr_Payload;
               Name  : constant String :=
                 Name_From (Value.Name, "predicate operator");
            begin
               ...
               if Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Like then
                  Item.Operator := Like_Match;
                  Item.Value :=
                    Make_Text
                      (String_Literal (Value.Rexpr.Value),
                       Maximum_Value_Length);
               elsif Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Op then
```

`Name` is used only by the `AEXPR_OP` branch that follows it, so `~~` and `!~~` are indistinguishable to the executor.

The PostgreSQL grammar puts both spellings under the same node kind and separates them by name alone. Plain LIKE (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15023-15026`):

```
			| a_expr LIKE a_expr
				{
					$$ = (Node *) makeSimpleA_Expr(AEXPR_LIKE, "~~",
												   $1, $3, @2);
				}
```

NOT LIKE (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15037-15041`):

```
			| a_expr NOT_LA LIKE a_expr							%prec NOT_LA
				{
					$$ = (Node *) makeSimpleA_Expr(AEXPR_LIKE, "!~~",
												   $1, $4, @2);
				}
```

The ESCAPE form does the same (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15048`), so `!~~` is the only marker of negation on this node kind.

`Pgish_Catalog.Matches` then evaluates the stored operator directly (`examples/pgish/src/pgish_catalog.adb:485-487`):

```ada
      elsif Predicate.Operator = SQL.Like_Match then
         return Like (SQL.Image (Cell_Value.Value), SQL.Image (Predicate.Value));
```

The pgish README lists the supported predicates without `NOT LIKE` (`examples/pgish/README.md:83-85`), and states what an unsupported construct must produce (`examples/pgish/README.md:88-91`):

> Transactions, joins, subqueries, arbitrary functions, DDL/DML, COPY, parameters, binary formats, and general Postgres SQL are unsupported and return an ErrorResponse with a specific SQLSTATE followed by ReadyForQuery. The session remains usable.

`NOT LIKE` is neither negated correctly nor rejected, so it satisfies neither half of the documented contract.

The pgish suite parses one LIKE predicate and inspects the parse result (`examples/pgish/src/pgish_tests.adb:50-59`), and asserts the operator mapping only for the `AEXPR_OP` comparison operators (`examples/pgish/src/pgish_tests.adb:70-88`). No test parses or executes `NOT LIKE`, and the real `psql` integration script runs no LIKE query (`examples/pgish/scripts/run-integration.sh:95-123`).

## What happens now

Spike: the program runs `WHERE name LIKE 'maximum%'` as a control, then parses `WHERE name NOT LIKE 'maximum%'`, reports the operator the lowering stored, executes it, and asserts the two rows PostgreSQL returns. The program accepts either correct negation or a parse-time rejection, since rejection would satisfy the documented subset contract.

```ada
      begin
         Query := SQL.Parse
           ("SELECT name FROM flyology_settings WHERE name NOT LIKE " &
            "'maximum%' ORDER BY name");
      exception
         when Error : SQL.Syntax_Error =>
            Accepted := False;
      ...
         Note ("NOT LIKE parsed; stored operator is "
               & Query.Predicates (1).Operator'Image);
         Catalog.Execute (Context, Session, Query, Result);
         Check (Result.Row_Count = 2,
                "NOT LIKE 'maximum%' selects authentication and tls (got"
                & Result.Row_Count'Image & ")");
```

```
  ok: LIKE 'maximum%' selects the four maximum_* settings (got 4)
  -- NOT LIKE parsed; stored operator is LIKE_MATCH
  -- NOT LIKE 'maximum%' returned 4 row(s); first = maximum_query_length
  FAILED: NOT LIKE 'maximum%' selects authentication and tls (got 4)
  FAILED: first NOT LIKE row is 'authentication'
BUG REPRODUCED: 2 failed expectation(s)
```

The control shows the positive form selecting exactly the four `maximum_*` settings, and the negated form returns the same four.

Observed against the running `examples/pgish/bin/flyology_pgish` on an ephemeral port:

```
== NOT LIKE 'maximum%' on the wire ==
    RowDescription fields=1 ['name']
    DataRow ['maximum_query_length']
    DataRow ['maximum_tokens']
    DataRow ['maximum_result_rows']
    DataRow ['maximum_sessions']
    CommandComplete 'SELECT 4'
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18 grammar used for reference.

## What should happen

`a NOT LIKE b` is the negation of `a LIKE b`, and the grammar marks it with the operator name `!~~` on the `AEXPR_LIKE` node (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15039`). pgish should either evaluate it as that negation or reject the statement with an ErrorResponse, as the README requires for constructs outside the subset. It must not silently return the complement of the correct row set.

## Suggested treatment

The narrow fix is to consult `Name` on the LIKE branch of `Pgish_SQL.Add_Predicate` (`examples/pgish/src/pgish_sql.adb:431-436`) and raise `Syntax_Error` for `!~~`, which turns the query into the documented ErrorResponse and closes the wrong-result defect without extending the subset.

Adding real support instead needs a maintainer decision, because it adds a value to the public predicate operator enumeration in `examples/pgish/src/pgish_sql.ads` and a case in `Pgish_Catalog.Matches`. The options are to reject `!~~` as outside the subset, to add a `Not_Like_Match` operator alongside `Like_Match`, or to add a negation flag to `SQL.Predicate` that applies to every operator. The README's supported-predicate sentence (`examples/pgish/README.md:83-85`) has to change if the subset grows.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the operator-lowering assertions (`examples/pgish/src/pgish_tests.adb:79-87`), asserting the chosen behaviour for `NOT LIKE`. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

A query in the shape of a documented predicate returns the exact complement of the correct rows, with no error and no indication that anything went wrong, so a client that filters with `NOT LIKE` acts on inverted data. Any client can write it, and the subset does not document `NOT LIKE` as supported, so it should have been rejected instead. Deterministic.
