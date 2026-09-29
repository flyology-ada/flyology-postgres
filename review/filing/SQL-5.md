Title: UESCAPE accepts form feed on every major and vertical tab on PostgreSQL 17 and 18
Labels: bug
Refs: SQL-1

## Summary

The scanner validates the `UESCAPE` character against a hand-written set that omits form feed on every supported major and vertical tab on PostgreSQL 17 and 18. PostgreSQL rejects both through `check_uescapechar`, which delegates to `scanner_isspace`. As a result `SELECT U&'a' UESCAPE E'\f'` parses successfully into an `A_Const` with `sval` `"a"` where PostgreSQL reports `invalid Unicode escape character at or near "E'\f'"` at cursor 22, and `SELECT U&'a' UESCAPE E'\v'` does the same on PostgreSQL 17 and 18.

## Problem

Commit `6f496f5`.

The escape-character test is a literal set (`sql/src/flyology-postgres-sql-native-scanner.adb:717-722`):

```ada
               Escape := Element (Next_Value.Text_Data, 1);
               if Escape in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | '+' | ''' | '"' |
                 ' ' | Character'Val (9) | Character'Val (10) | Character'Val (13)
               then
                  Fail (Self, Natural (Next_Loc), "invalid Unicode escape character");
               end if;
```

`Character'Val (12)`, the form feed, is absent on every major, and `Character'Val (11)`, the vertical tab, is absent for PostgreSQL 17 and 18.

PostgreSQL delegates the whitespace half of the test (`sql/backends/v18/vendor/native_source/backend/parser/parser.c:352-362`, and the same function at `sql/backends/v14/vendor/native_source/backend/parser/parser.c:326-336`):

```c
check_uescapechar(unsigned char escape)
{
	if (isxdigit(escape)
		|| escape == '+'
		|| escape == '\''
		|| escape == '"'
		|| scanner_isspace(escape))
		return false;
	else
		return true;
}
```

`scanner_isspace` lists the form feed on every major (`sql/backends/v14/vendor/src/postgres/src_backend_parser_scansup.c:126-136`):

```c
scanner_isspace(char ch)
{
	/* This must match scan.l's list of {space} characters */
	if (ch == ' ' ||
		ch == '\t' ||
		ch == '\n' ||
		ch == '\r' ||
		ch == '\f')
		return true;
	return false;
}
```

The PostgreSQL 15 and 16 copies are identical at `src_backend_parser_scansup.c:126-136`. The PostgreSQL 17 and 18 copies add the vertical tab at `sql/backends/v17/vendor/src/postgres/src_backend_parser_scansup.c:126-137` and `sql/backends/v18/vendor/src/postgres/src_backend_parser_scansup.c:126-137`:

```c
	if (ch == ' ' ||
		ch == '\t' ||
		ch == '\n' ||
		ch == '\r' ||
		ch == '\v' ||
		ch == '\f')
```

Before PostgreSQL 17 the vertical-tab case is legitimately accepted, because `E'\v'` there denotes the letter `v`, which is an acceptable escape character. That is the version split described in {{ISSUE:SQL-1}}.

The native-versus-oracle corpus has no `UESCAPE` statement at all (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:40-75`), and the `UESCAPE` cases in the PostgreSQL regression corpus use `'!'`, `'*'`, `'+'` and a bare `+`. The regression corpus check compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), so a statement the oracle rejects and the native parser accepts is counted as rejected and skipped rather than compared. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same native scanner.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic text and the cursor, with the vertical-tab statement on PostgreSQL 14 through 16 as a control that must keep parsing.

```ada
   Form_Feed : constant String := "SELECT U&'a' UESCAPE E'\f'";
   Vert_Tab  : constant String := "SELECT U&'a' UESCAPE E'\v'";
...
      Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
             Version'Image & ": " & Text & " reports the C oracle message");
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": " & Text & " reports the C oracle cursor");
```

```
  -- POSTGRESQL_14 SELECT U&'a' UESCAPE E'\f' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\f'"] @ 22
  FAILED: POSTGRESQL_14: SELECT U&'a' UESCAPE E'\f' reports the C oracle message
  FAILED: POSTGRESQL_14: SELECT U&'a' UESCAPE E'\f' reports the C oracle cursor
  -- POSTGRESQL_15 SELECT U&'a' UESCAPE E'\f' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\f'"] @ 22
  FAILED: POSTGRESQL_15: SELECT U&'a' UESCAPE E'\f' reports the C oracle message
  FAILED: POSTGRESQL_15: SELECT U&'a' UESCAPE E'\f' reports the C oracle cursor
  -- POSTGRESQL_16 SELECT U&'a' UESCAPE E'\f' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\f'"] @ 22
  FAILED: POSTGRESQL_16: SELECT U&'a' UESCAPE E'\f' reports the C oracle message
  FAILED: POSTGRESQL_16: SELECT U&'a' UESCAPE E'\f' reports the C oracle cursor
  -- POSTGRESQL_17 SELECT U&'a' UESCAPE E'\f' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\f'"] @ 22
  FAILED: POSTGRESQL_17: SELECT U&'a' UESCAPE E'\f' reports the C oracle message
  FAILED: POSTGRESQL_17: SELECT U&'a' UESCAPE E'\f' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT U&'a' UESCAPE E'\f' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\f'"] @ 22
  FAILED: POSTGRESQL_18: SELECT U&'a' UESCAPE E'\f' reports the C oracle message
  FAILED: POSTGRESQL_18: SELECT U&'a' UESCAPE E'\f' reports the C oracle cursor
  -- POSTGRESQL_17 SELECT U&'a' UESCAPE E'\v' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\v'"] @ 22
  FAILED: POSTGRESQL_17: SELECT U&'a' UESCAPE E'\v' reports the C oracle message
  FAILED: POSTGRESQL_17: SELECT U&'a' UESCAPE E'\v' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT U&'a' UESCAPE E'\v' native: [] @ 0  oracle: [invalid Unicode escape character at or near "E'\v'"] @ 22
  FAILED: POSTGRESQL_18: SELECT U&'a' UESCAPE E'\v' reports the C oracle message
  FAILED: POSTGRESQL_18: SELECT U&'a' UESCAPE E'\v' reports the C oracle cursor
  ok: POSTGRESQL_14: control UESCAPE E'\v' matches the C oracle
  ok: POSTGRESQL_15: control UESCAPE E'\v' matches the C oracle
  ok: POSTGRESQL_16: control UESCAPE E'\v' matches the C oracle
BUG REPRODUCED: 14 failed expectation(s)
```

An empty native diagnostic means the native parser accepted the statement. The last three lines are the controls: on PostgreSQL 14 through 16 the vertical-tab statement parses on both sides.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

`SELECT U&'a' UESCAPE E'\f'` must fail with `invalid Unicode escape character at or near "E'\f'"` at cursor 22 on all five majors, and `SELECT U&'a' UESCAPE E'\v'` must fail the same way on PostgreSQL 17 and 18, matching `check_uescapechar` and `scanner_isspace`. On PostgreSQL 14 through 16 the vertical-tab statement must keep parsing, because `E'\v'` is the letter `v` there.

## Suggested treatment

Add `Character'Val (12)` to the rejected set at `sql/src/flyology-postgres-sql-native-scanner.adb:717-722` unconditionally. `Character'Val (11)` must be rejected for PostgreSQL 17 and 18 only, and the scanner is one handwritten generic package instantiated once per major from generated code (`sql/src/flyology-postgres-sql-native-version_v18.adb:16-19`, generated by `sql/tools/generate_native_parser.py`; generated packages are not hand-edited in this repository). This needs a maintainer decision, and it is the same decision the report on the `\v` escape ({{ISSUE:SQL-1}}) needs. The options are:

- add a generic formal to `Flyology.Postgres.SQL.Native.Scanner` describing the escape and space sets, and have `generate_native_parser.py` emit the actual in each `version_v*.adb` instantiation;
- carry the sets in the generated scanner tables, so the test becomes table driven and the scanner holds no version knowledge of its own;
- pass the major version into `Lexer.Initialize` alongside `Backslash_Quote` and `Standard_Conforming_Strings`, and branch inside the scanner.

Once the vertical tab is a real vertical tab in the escape string, both characters fall out of one space set, so a fix that mirrors `scanner_isspace` covers the whole rule rather than the two observed characters.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb`, which currently has no `UESCAPE` entry, as `Check ("SELECT U&'a' UESCAPE E'\f'")` on all majors and the vertical-tab statement restricted to `PostgreSQL_17` and above. The spike is that test. No existing test asserts the current behaviour.

## Severity

Invalid input is accepted: a statement PostgreSQL refuses to parse yields a valid tree with no diagnostic, so a caller using the parser to validate SQL before sending it to a server accepts a statement the server will reject. No valid statement is misparsed. It needs a `UESCAPE` clause whose escape character is a form feed or, on the newer majors, a vertical tab, which is unusual input. All five supported majors for the form feed, PostgreSQL 17 and 18 for the vertical tab.
