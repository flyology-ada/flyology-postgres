Title: pgish answers LIKE '%' with an internal XX000 error carrying a GNAT runtime source location
Labels: bug
Refs: none

## Summary

`Pgish_Catalog.Like` removes a leading and a trailing `%` before matching, so the patterns `'%'` and `'%%'` leave a null needle, and the substring branch then calls `Ada.Strings.Fixed.Index` with a null pattern. RM A.4.3 requires that to propagate `Ada.Strings.Pattern_Error`. The exception escapes `Pgish_Catalog.Execute`, `Pgish_Handler.SQL_State_For` does not recognise it, and the client receives SQLSTATE `XX000` whose message is the GNAT runtime source location `a-strsea.adb:300`. A documented query that PostgreSQL answers with every non-NULL row returns an internal error and puts a runtime file name on the network.

## Problem

Commit `6f496f5`.

`Like` strips the wildcards and keeps the remainder as the needle (`examples/pgish/src/pgish_catalog.adb:444-456`):

```ada
   function Like (Value, Pattern : String) return Boolean is
      Leading  : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'First) = '%';
      Trailing : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'Last) = '%';
      First    : constant Integer := Pattern'First + Boolean'Pos (Leading);
      Last     : constant Integer := Pattern'Last - Boolean'Pos (Trailing);
      Needle   : constant String := (if First > Last then "" else Pattern (First .. Last));
   begin
      if Ada.Strings.Fixed.Index (Needle, "%") /= 0
        or else Ada.Strings.Fixed.Index (Needle, "_") /= 0
      then
         raise Unsupported_Error with "LIKE supports only leading/trailing percent wildcards";
      elsif Leading and Trailing then
         return Ada.Strings.Fixed.Index (Value, Needle) /= 0;
```

For the pattern `'%'` the single character satisfies both `Leading` and `Trailing`, `First` exceeds `Last`, and `Needle` is `""`. For `'%%'` the same holds. RM A.4.3 defines `Ada.Strings.Fixed.Index` to propagate `Pattern_Error` when `Pattern` is the null string, so the `Leading and Trailing` branch raises rather than matching.

Nothing between `Like` and the wire recognises the exception. `SQL_State_For` tests pgish's own exception names only (`examples/pgish/src/pgish_handler.adb:111-124`):

```ada
      if Ada.Strings.Fixed.Index (Name, "SYNTAX_ERROR") /= 0 then return "42601";
      elsif Ada.Strings.Fixed.Index (Name, "UNDEFINED_TABLE_ERROR") /= 0 then return "42P01";
      elsif Ada.Strings.Fixed.Index (Name, "UNDEFINED_COLUMN_ERROR") /= 0 then return "42703";
      elsif Ada.Strings.Fixed.Index (Name, "UNSUPPORTED_ERROR") /= 0 then return "0A000";
      elsif Ada.Strings.Fixed.Index (Name, "RESOURCE_LIMIT_ERROR") /= 0 then return "54000";
      elsif Ada.Strings.Fixed.Index (Name, "PROTOCOL_ERROR") /= 0 then return "08P01";
      elsif Name = "CONSTRAINT_ERROR" then return "26000";
      else return "XX000";
      end if;
```

`Report_Error` sends the occurrence's message verbatim (`examples/pgish/src/pgish_handler.adb:131-137`):

```ada
      Message : constant String := Ada.Exceptions.Exception_Message (Occurrence);
   begin
      Sessions.Send_Error
        (Client,
         Message   => (if Message'Length = 0 then "query failed" else Message),
         SQL_State => SQL_State_For (Occurrence),
         Timeout   => Timeout);
```

`Ada.Strings.Pattern_Error` is raised by the GNAT runtime, so its message is a runtime source location and that is what reaches the client.

The pgish README documents the accepted pattern shapes (`examples/pgish/README.md:83-85`):

> Predicates support `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `IS NULL`, `IS NOT NULL`, and `LIKE`; LIKE accepts exact, prefix, suffix, and substring patterns using percent only.

`'%'` is the substring pattern with an empty substring. PostgreSQL matches every non-NULL value with it: in `MatchText` a `%` consumes any following wildcards and, with the pattern then exhausted, returns `LIKE_TRUE` (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/adt/like_match.c:128-151`):

```c
			/*
			 * If we're at end of pattern, match: we have a trailing % which
			 * matches any remaining text string.
			 */
			if (plen <= 0)
				return LIKE_TRUE;
```

No test evaluates a LIKE predicate. The only LIKE in the pgish suite is parsed and its parse result inspected, never executed (`examples/pgish/src/pgish_tests.adb:50-59`), and the real `psql` integration script runs no LIKE query at all (`examples/pgish/scripts/run-integration.sh:95-123`).

## What happens now

Spike: the program initialises a pgish server state, runs `SELECT name FROM flyology_settings` as a control, then runs the same query with `WHERE name LIKE '%'` and with `WHERE name LIKE '%%'`, asserting that neither raises and that each returns the six rows PostgreSQL returns.

```ada
   --  Baseline: the six flyology_settings rows all have a non-NULL name.
   Try ("SELECT name FROM flyology_settings", 6);
   --  PostgreSQL: LIKE '%' matches every non-NULL value.
   Try ("SELECT name FROM flyology_settings WHERE name LIKE '%'", 6);
   --  PostgreSQL: '%%' is also 'match anything'.
   Try ("SELECT name FROM flyology_settings WHERE name LIKE '%%'", 6);
```

```
  ok: SELECT name FROM flyology_settings returns 6 rows (got 6)
  -- unexpected ADA.STRINGS.PATTERN_ERROR : a-strsea.adb:300
  FAILED: SELECT name FROM flyology_settings WHERE name LIKE '%' must not raise
  -- unexpected ADA.STRINGS.PATTERN_ERROR : a-strsea.adb:300
  FAILED: SELECT name FROM flyology_settings WHERE name LIKE '%%' must not raise
BUG REPRODUCED: 2 failed expectation(s)
```

The control query passing first isolates the failure to the pattern, not to the catalog or the state setup.

Observed against the running `examples/pgish/bin/flyology_pgish` on an ephemeral port, the same query produces:

```
== LIKE '%' on the wire ==
    ErrorResponse severity=ERROR code=XX000 msg=a-strsea.adb:300
    ReadyForQuery I
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

`name LIKE '%'` and `name LIKE '%%'` should return every row whose `name` is not NULL, as `MatchText` does (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/adt/like_match.c:146-151`) and as the README's "substring patterns using percent only" states. No query in the documented subset should reach the client as SQLSTATE `XX000`, and no GNAT runtime source location should appear in an ErrorResponse.

## Suggested treatment

Give `Like` an explicit all-wildcard case before the substring branch: when `Needle` is empty and either `Leading` or `Trailing` is set, the pattern matches any value, so return `True`. The empty needle is also correct for the `Leading`-only and `Trailing`-only branches, which already return `True` for it by the length comparison, so only the `Leading and Trailing` branch needs the guard.

Independently, `Pgish_Handler.SQL_State_For` should not let an unexpected exception's message become the client-visible error text. Reporting a fixed string such as "internal error" for the `XX000` case, with the occurrence left to the server log, keeps runtime source locations off the wire. That change is a maintainer decision, because it alters the text every unrecognised failure currently sends: the options are to keep the message and accept runtime text on the wire, to replace it with a fixed string, or to keep the message only for pgish's own exceptions and substitute a fixed string for every other one.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` next to the existing NULL-predicate execution test (`examples/pgish/src/pgish_tests.adb:187-194`), executing `WHERE name LIKE '%'` and asserting the full row count. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

A documented and ordinary query fails with an internal-error SQLSTATE, and the error text handed to the client is a GNAT runtime file and line rather than a diagnostic. The session survives, `ReadyForQuery` still arrives, and `psql` recovers, so it is not a crash. It needs the pattern `'%'` or `'%%'`, which is the usual way to write "every non-NULL value" and is reachable from any client. Deterministic.
