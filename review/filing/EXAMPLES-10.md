Title: pgish answers a semicolon, comment or whitespace-only query with 42601 instead of EmptyQueryResponse
Labels: bug
Refs: none

## Summary

`Pgish_Handler.Handle` sends EmptyQueryResponse only when `Ada.Strings.Fixed.Trim (Query_Text, Both)` is empty. RM A.4.3 defines that `Trim` to remove `Space` characters only, so a query made of tabs or newlines is not recognised as empty either, and a bare `;` or a comment is not empty as a string at all. Everything that misses the guard reaches `Pgish_SQL.Parse`, which raises `Syntax_Error` for a tree with no statements, and the handler maps that to SQLSTATE 42601. PostgreSQL answers EmptyQueryResponse for a query string containing no statement. The extended-protocol `Parse` branch has no emptiness guard at all, so preparing an empty statement is rejected the same way.

## Problem

Commit `6f496f5`.

The simple-query guard (`examples/pgish/src/pgish_handler.adb:305-316`):

```ada
         when Protocol.Query =>
            declare
               Text : constant String := Ada.Strings.Fixed.Trim
                 (Sessions.Query_Text (Command), Ada.Strings.Both);
            begin
               if Text'Length = 0 then
                  Sessions.Send_Empty_Query_Response (Client, Timeout);
                  Sessions.Send_Ready (Client, Timeout => Timeout);
               else
                  Run_SQL (Context, Client, Text, Simple => True);
               end if;
            end;
```

RM A.4.3 defines `Trim (Source, Side)` as removing leading and trailing `Space` characters, so a tab, a line feed or a carriage return survives it and `Text'Length` is not zero. A bare `;`, a line comment and a block comment are not whitespace at all and were never candidates for the guard.

Everything that reaches `Pgish_SQL.Parse` with no statement raises (`examples/pgish/src/pgish_sql.adb:704-709`):

```ada
      Visitors.Traverse (Lowerer, Tree);
      if Lowerer.Statement_Count = 0 then
         raise Syntax_Error with "expected SELECT or SHOW statement";
      elsif not Lowerer.Lowered then
         raise Syntax_Error with "unsupported SQL statement";
      end if;
```

and `SQL_State_For` maps that name to 42601 (`examples/pgish/src/pgish_handler.adb:115`):

```ada
      if Ada.Strings.Fixed.Index (Name, "SYNTAX_ERROR") /= 0 then return "42601";
```

The extended-protocol branch calls the same `Parse` with no guard of its own (`examples/pgish/src/pgish_handler.adb:318-331`):

```ada
         when Protocol.Parse =>
            declare
               Name : SQL.Name_Text;
               Text : State.Query_Text;
               Ignored : SQL.Query;
            begin
               Decode_Parse (Command, Name, Text);
               Ignored := SQL.Parse (SQL.Image (Text));
```

so an empty prepared statement, which PostgreSQL accepts, is answered with 42601 instead of ParseComplete.

PostgreSQL's `exec_simple_query` (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/postgres.c:1012`) answers an empty parse tree list with EmptyQueryResponse (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/postgres.c:1351-1355`):

```c
	/*
	 * If there were no parsetrees, return EmptyQueryResponse message.
	 */
	if (!parsetree_list)
		NullCommand(dest);
```

so `;`, a comment-only submission and a whitespace-only submission all produce EmptyQueryResponse there, and `psql` prints nothing.

No test submits an empty or comment-only query. The pgish suite's rejection list covers unsupported statements, not empty ones (`examples/pgish/src/pgish_tests.adb:106-128`), and the real `psql` integration script's recovery fixture uses `SELECT FROM flyology_tables`, a statement with no projection rather than no statement (`examples/pgish/scripts/run-integration.sh:125-131`).

## What happens now

Spike: the program first checks the handler's own emptiness test against a newline and a tab, then submits a bare semicolon, a line comment, a block comment, a newline and the empty string to `Pgish_SQL.Parse` and asserts that none is reported as a syntax error.

```ada
   --  The handler's own emptiness test must recognise a whitespace-only query.
   Check (Ada.Strings.Fixed.Trim (Newline, Ada.Strings.Both)'Length = 0,
          "Pgish_Handler treats a newline-only Query as empty");
...
   Expect_Not_Syntax_Error (";", "a bare semicolon is an empty query");
   Expect_Not_Syntax_Error ("-- note", "a line comment is an empty query");
   Expect_Not_Syntax_Error ("/* c */", "a block comment is an empty query");
   Expect_Not_Syntax_Error (Newline, "a newline-only Query is an empty query");
   Expect_Not_Syntax_Error ("", "an empty string is an empty query");
```

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

The first two lines are the `Trim` behaviour on its own, independent of the parser: neither a newline nor a tab is removed, so neither reaches the EmptyQueryResponse branch.

Observed against the running `examples/pgish/bin/flyology_pgish` on an ephemeral port:

```
== bare semicolon on the wire ==
    ErrorResponse severity=ERROR code=42601 msg=expected SELECT or SHOW statement
    ReadyForQuery I
== comment only on the wire ==
    ErrorResponse severity=ERROR code=42601 msg=expected SELECT or SHOW statement
    ReadyForQuery I
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A simple Query message whose text contains no statement, whether because it is empty, whitespace of any kind, a bare `;`, or only comments, should be answered with EmptyQueryResponse followed by ReadyForQuery, as `exec_simple_query` does (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/postgres.c:1351-1355`). An extended-protocol `Parse` of the same text should answer ParseComplete rather than 42601.

## Suggested treatment

The emptiness test belongs after parsing, not before it. `Pgish_SQL.Parse` already knows that the tree holds zero statements (`examples/pgish/src/pgish_sql.adb:705-706`); reporting that case distinctly, rather than as `Syntax_Error`, lets both handler branches answer correctly: the simple-query branch sends EmptyQueryResponse and the `Parse` branch sends ParseComplete. That covers the semicolon, comment and every whitespace form in one place, and the `Trim` guard can stay as a fast path.

Introducing that distinct case is a maintainer decision, because it adds an exception or a result value to the public interface of `examples/pgish/src/pgish_sql.ads`. The options are: a new `Empty_Query_Error` exception raised where `Statement_Count = 0` today; a boolean or count on the returned `Query` that the handler tests; or leaving `Parse` alone and widening the handler's guard to strip all whitespace, `;` and comments before the length test, which fixes the simple-query branch only and leaves the extended `Parse` branch wrong.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the rejection list (`examples/pgish/src/pgish_tests.adb:106-128`), asserting that `;`, a comment and a tab are not syntax errors. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

A client that submits a statement-free query gets an error where the reference server sends EmptyQueryResponse, and an extended-protocol client that prepares an empty statement gets 42601 where PostgreSQL accepts it. Real `psql` strips a bare `;` before sending and libpq tolerates the error, so the practical impact falls on scripted and programmatic clients that forward text unchanged, and on any client that ends a submission with a newline the guard does not strip. The session stays usable and ReadyForQuery still arrives. Deterministic.
