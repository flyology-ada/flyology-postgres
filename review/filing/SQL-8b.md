Title: PostgreSQL 18's parameter-number range check is applied to PostgreSQL 14 through 17
Labels: bug
Refs: SQL-8

## Summary

The native scanner rejects a `$n` parameter whose number exceeds the 32-bit signed range on every supported major. PostgreSQL added that check in version 18; on 14 through 17 the `{param}` rule is a bare `atol` with no range test, so those servers accept the statement. `SELECT $12345678901, 1` therefore fails to parse on four of the five supported majors, with a diagnostic PostgreSQL never produces there, while the pinned oracle parses it into a valid tree.

## Problem

Commit `6f496f5`.

The Ada parameter rule applies the range check unconditionally (`sql/src/flyology-postgres-sql-native-scanner.adb:510-524`):

```ada
               when Tables.Parameter_Token =>
                  declare
                     Number : Interfaces.Integer_64 := 0;
                  begin
                     for Index in Text'First + 1 .. Text'Last loop
                        Number := Number * 10 + Interfaces.Integer_64
                          (Character'Pos (Text (Index)) - Character'Pos ('0'));
                        if Number > Interfaces.Integer_64 (Interfaces.Integer_32'Last) then
                           Fail (Self, First, "parameter number too large");
                        end if;
                     end loop;
                     Token := Token_Param;
                     Value := Builders.Number (Number);
                     return;
                  end;
```

The scanner body is shared by all five generated backends, so the check runs on every major.

The range check was added in PostgreSQL 18's `scan.l` (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:994-1004`):

```c
{param}			{
					ErrorSaveContext escontext = {T_ErrorSaveContext};
					int32		val;

					SET_YYLLOC();
					val = pg_strtoint32_safe(yytext + 1, (Node *) &escontext);
					if (escontext.error_occurred)
						yyerror("parameter number too large");
					yylval->ival = val;
					return PARAM;
				}
```

PostgreSQL 17 has no such test (`sql/backends/v17/vendor/native_source/backend/parser/scan.l:1008-1012`):

```c
{param}			{
					SET_YYLLOC();
					yylval->ival = atol(yytext + 1);
					return PARAM;
				}
```

The same bare `atol` action stands at `sql/backends/v14/vendor/native_source/backend/parser/scan.l:969-973`, `sql/backends/v15/vendor/native_source/backend/parser/scan.l:976-980` and `sql/backends/v16/vendor/native_source/backend/parser/scan.l:993-997`.

The native-versus-oracle corpus uses one parameter, `$1`, inside a larger statement (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:50`), and the PostgreSQL regression corpus contains no parameter number long enough to exceed the 32-bit range on any major. The regression corpus check would catch this shape, since it compares every statement the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), but no corpus file contains such a parameter. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same native scanner, so both sides reject identically.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic text.

```ada
   Param_Large  : constant String := "SELECT $12345678901, 1";
...
   --  {param} gained a range check only in v18; on v14..v17 scan.l uses a
   --  plain atol and the oracle accepts this statement outright.
   for Version in SQL.Major_Version loop
      Expect_Message (Param_Large, Version);
   end loop;
```

```
  -- POSTGRESQL_14 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_14 oracle: [] @ 0
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT $12345678901, 1>>
  -- POSTGRESQL_15 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_15 oracle: [] @ 0
  FAILED: POSTGRESQL_15: message matches the C oracle for <<SELECT $12345678901, 1>>
  -- POSTGRESQL_16 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_16 oracle: [] @ 0
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT $12345678901, 1>>
  -- POSTGRESQL_17 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_17 oracle: [] @ 0
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT $12345678901, 1>>
  -- POSTGRESQL_18 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_18 oracle: [parameter number too large at or near "$12345678901"] @ 8
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT $12345678901, 1>>
```

An empty oracle diagnostic means the oracle parsed the statement. On PostgreSQL 14 through 17 the native parser rejects a statement those servers accept. On PostgreSQL 18 both sides reject it and only the quoted context differs, which is {{ISSUE:SQL-8}}.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

On PostgreSQL 14 through 17, `SELECT $12345678901, 1` must parse, with the parameter number carrying whatever `atol` yields for those digits, matching the `{param}` action at `sql/backends/v17/vendor/native_source/backend/parser/scan.l:1008-1012`. Only on PostgreSQL 18 must it fail with `parameter number too large`.

## Suggested treatment

The range check at `sql/src/flyology-postgres-sql-native-scanner.adb:517-519` must apply on PostgreSQL 18 only. The scanner is one handwritten generic package instantiated once per major from generated code (`sql/src/flyology-postgres-sql-native-version_v18.adb:16-19`, generated by `sql/tools/generate_native_parser.py`; generated packages are not hand-edited in this repository), so the version-dependent behaviour has to arrive through that instantiation. This needs a maintainer decision, and it is the same mechanism question the reports on the `\v` escape and the `UESCAPE` character set raise. The options are:

- add a generic formal Boolean, or a version discriminator, to `Flyology.Postgres.SQL.Native.Scanner`, and have `generate_native_parser.py` emit the actual in each `version_v*.adb` instantiation;
- carry the range bound in the generated scanner tables, so the check is data rather than code;
- pass the major version into `Lexer.Initialize` alongside `Backslash_Quote` and `Standard_Conforming_Strings`, and branch inside the scanner.

The pre-18 behaviour of `atol` on a value that does not fit `int` is also a decision to record. `yylval->ival` is `int`, so a value past the 32-bit range is truncated by the conversion rather than diagnosed, and the fix must reproduce whatever the pinned oracle stores rather than inventing a bound.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the statement that uses `$1` at line 50, as `Check ("SELECT $12345678901, 1")` on all majors, which asserts acceptance on the four earlier majors and the diagnostic on PostgreSQL 18. The spike is that test. No existing test asserts the current behaviour.

## Severity

Valid SQL for the targeted server is rejected through the ordinary `Parse` path on four of the five supported majors, and the caller is handed a diagnostic PostgreSQL does not produce there, so an application that uses the parser to validate statements before sending them rejects statements the server would run. It needs a parameter number above 2147483647, which is unusual input; a query that reaches it is more likely to be generated than hand-written. PostgreSQL 14 through 17.
