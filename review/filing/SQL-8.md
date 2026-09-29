Title: Scanner diagnostics quote the rest of the statement instead of the offending token
Labels: bug
Refs: SQL-8b

## Summary

The engine builds the "at or near" context for every scanner error as the whole remainder of the statement text. In flex only the end-of-input rules quote through end of input; every other rule quotes the current match, because `YY_DO_BEFORE_ACTION` has written a NUL at the end of it. So `SELECT E'wrong: \U002FFFFF'` reports `at or near "\U002FFFFF'"` where PostgreSQL reports `at or near "\U002FFFFF"`, and `SELECT 1x, 2` reports `at or near "1x, 2"` where PostgreSQL reports `at or near "1x"`. Three related divergences ride on the same code path, one of which also puts the cursor one byte late.

## Problem

Commit `6f496f5`.

The scanner-error branch quotes to the end of the statement (`sql/src/flyology-postgres-sql-native-engine.adb:112-119`):

```ada
            declare
               Offset : constant Natural := Lexer.Error_Position - 1;
            begin
               Report_Error
                 (Error, Offset, True,
                  (if Offset >= SQL'Length then ""
                   else SQL (SQL'First + Offset .. SQL'Last)));
            end;
```

and `Report_Error` wraps that text in `at or near "..."` (`sql/src/flyology-postgres-sql-native-engine.adb:40-43`).

In flex, `scanner_yyerror` takes `loc = scanbuf + *yylloc` and prints it as a C string, and `YY_DO_BEFORE_ACTION` has written `'\0'` at `yytext + yyleng`, so the quoted context ends at the end of the current match. Only the `<<EOF>>` rules, for an unterminated literal, dollar quote or comment, genuinely run to end of input, which is why those cases already agree.

Three further divergences share the path.

`str_udeescape` reports its error with no "at or near" suffix at all (`sql/backends/v18/vendor/native_source/backend/parser/parser.c:492-495`):

```c
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("invalid Unicode escape"),
						 errhint("Unicode escapes must be \\XXXX or \\+XXXXXX.")));
```

`base_yylex` restores the current token before scanning the `UESCAPE` string, so a syntax error quotes the whole three-token sequence (`sql/backends/v18/vendor/native_source/backend/parser/parser.c:264-266`):

```c
				/* Un-truncate current token so errors point to third token */
				*(yyextra->lookahead_end) = yyextra->lookahead_hold_char;
```

And a zero-length delimited identifier is reported at the opening quote in C, because `SET_YYLLOC()` runs in the `{xdstart}` rule (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:789-793`) and the `yyerror` at `sql/backends/v18/vendor/native_source/backend/parser/scan.l:804` uses that `*yylloc`:

```c
{xdstart}		{
					SET_YYLLOC();
					BEGIN(xd);
					startlit();
				}
```

The Ada rule passes the location of the closing-quote match instead (`sql/src/flyology-postgres-sql-native-scanner.adb:431-435`):

```ada
               when Tables.Identifier_Stop | Tables.Unicode_Identifier_Stop =>
                  Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                  if Length (Self.Literal) = 0 then
                     Fail (Self, First, "zero-length delimited identifier");
                  end if;
```

`sql/README.md:320-322` states that the native-versus-oracle comparison preserves "parse validity, diagnostics, and cursor positions". That comparison never runs on this input: the regression corpus check compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), and the four invalid statements in the native-versus-oracle corpus (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:69-75`) are three end-of-input scanner errors and one grammar error, so every scanner diagnostic it exercises is one of the cases that legitimately quotes to end of input. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same engine.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic text, and for the zero-length identifier the cursor as well. `SELECT 'unterminated` is a control that must keep matching.

```ada
   Unicode_Ctx  : constant String := "SELECT E'wrong: \U002FFFFF'";
   Param_Large  : constant String := "SELECT $12345678901, 1";
   Numeric_Junk : constant String := "SELECT 1x, 2";
   Udeescape    : constant String := "SELECT U&'\061'";
   Zero_Ident   : constant String := "SELECT """"";
   Uescape_Stmt : constant String := "SELECT * FROM U&'t' UESCAPE '!'";
...
      Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
             Version'Image & ": message matches the C oracle for <<" & Text & ">>");
...
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": cursor matches the C oracle for <<" & Text & ">>");
```

Per-major repetitions are trimmed to PostgreSQL 14 and 18; every major omitted here prints the PostgreSQL 14 lines. The numeric-junk statement starts at PostgreSQL 16, whose rules introduce it, and the parameter statement is shown for PostgreSQL 18 only, for the reason given below the block.

```
  -- POSTGRESQL_14 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_14 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_18 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_18 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_18 native: [parameter number too large at or near "$12345678901, 1"] @ 8
  -- POSTGRESQL_18 oracle: [parameter number too large at or near "$12345678901"] @ 8
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT $12345678901, 1>>
  -- POSTGRESQL_16 native: [trailing junk after numeric literal at or near "1x, 2"] @ 8
  -- POSTGRESQL_16 oracle: [trailing junk after numeric literal at or near "1x"] @ 8
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT 1x, 2>>
  -- POSTGRESQL_18 native: [trailing junk after numeric literal at or near "1x, 2"] @ 8
  -- POSTGRESQL_18 oracle: [trailing junk after numeric literal at or near "1x"] @ 8
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT 1x, 2>>
  -- POSTGRESQL_14 native: [invalid Unicode escape at or near "\061'"] @ 11
  -- POSTGRESQL_14 oracle: [invalid Unicode escape] @ 11
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT U&'\061'>>
  -- POSTGRESQL_14 native: [zero-length delimited identifier at or near """] @ 9
  -- POSTGRESQL_14 oracle: [zero-length delimited identifier at or near """"] @ 8
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT "">>
  FAILED: POSTGRESQL_14: cursor matches the C oracle for <<SELECT "">>
  -- POSTGRESQL_14 native: [syntax error at or near "U&'t'"] @ 15
  -- POSTGRESQL_14 oracle: [syntax error at or near "U&'t' UESCAPE '!'"] @ 15
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT * FROM U&'t' UESCAPE '!'>>
  -- POSTGRESQL_18 native: [invalid Unicode escape at or near "\061'"] @ 11
  -- POSTGRESQL_18 oracle: [invalid Unicode escape] @ 11
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT U&'\061'>>
  -- POSTGRESQL_18 native: [zero-length delimited identifier at or near """] @ 9
  -- POSTGRESQL_18 oracle: [zero-length delimited identifier at or near """"] @ 8
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT "">>
  FAILED: POSTGRESQL_18: cursor matches the C oracle for <<SELECT "">>
  -- POSTGRESQL_18 native: [syntax error at or near "U&'t'"] @ 15
  -- POSTGRESQL_18 oracle: [syntax error at or near "U&'t' UESCAPE '!'"] @ 15
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT * FROM U&'t' UESCAPE '!'>>
  ok: POSTGRESQL_14: control unterminated literal matches
  ok: POSTGRESQL_15: control unterminated literal matches
  ok: POSTGRESQL_16: control unterminated literal matches
  ok: POSTGRESQL_17: control unterminated literal matches
  ok: POSTGRESQL_18: control unterminated literal matches
BUG REPRODUCED: 33 failed expectation(s)
```

The `SELECT $12345678901, 1` line is shown for PostgreSQL 18 only, where both sides reject the statement and only the quoted context differs. On PostgreSQL 14 through 17 the oracle accepts that statement outright, which is a separate defect ({{ISSUE:SQL-8b}}).

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

A scanner diagnostic must quote the current token, not the rest of the statement: `at or near "\U002FFFFF"` and `at or near "1x"`, matching what `scanner_yyerror` prints once flex has terminated `yytext`. `invalid Unicode escape` from `str_udeescape` must carry no "at or near" suffix. A syntax error on a `U&'...' UESCAPE '...'` sequence must quote the whole sequence. A zero-length delimited identifier must be reported at the opening quote, cursor 8 for `SELECT ""`, with `""` as the quoted context.

## Suggested treatment

Carry the length of the offending match alongside the error offset in the lexer, and use it to bound the context at `sql/src/flyology-postgres-sql-native-engine.adb:112-119` instead of running to `SQL'Last`. `Lexer.Error_Position` already exists for the offset; a companion `Error_Length` covering the current match, with the end-of-input rules reporting the remaining length, reproduces both behaviours from one mechanism.

The three related sites each need their own change: `Fail` for the `invalid Unicode escape` case must be able to suppress the "at or near" suffix, which `Report_Error` already supports through its `Add_Context` parameter; the zero-length delimited identifier at `sql/src/flyology-postgres-sql-native-scanner.adb:431-435` must pass the location recorded at the opening quote, which the `Identifier_Start` clause immediately above already stores in `Self.Token_Location`; and the `UESCAPE` lookahead needs to report the span from the start of the `U&'...'` token rather than only that token.

Adding a public `Error_Length` to `Flyology.Postgres.SQL.Native.Scanner` widens a package interface. This needs a maintainer decision: expose the length, or return the bounded context text itself from the lexer so the engine does no slicing.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the existing invalid statements at lines 69-75, as `Check ("SELECT E'wrong: \U002FFFFF'")` and `Check ("SELECT """"")` on all majors and `Check ("SELECT 1x, 2")` from `PostgreSQL_16`. The spike is that test. No existing test asserts the current behaviour.

## Severity

Wrong diagnostic text on every non-end-of-input scanner error, and for a zero-length delimited identifier a cursor one byte late. Any application that shows the parser's diagnostic shows the rest of the statement quoted back where PostgreSQL shows the offending token, which for a long statement is the whole tail of the query. The input is invalid on both sides, so no valid statement is misparsed. All five supported majors; the numeric-junk rules exist from PostgreSQL 16.
