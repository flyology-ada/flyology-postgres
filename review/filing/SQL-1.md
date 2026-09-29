Title: E'\v' unescapes to the letter v instead of vertical tab on PostgreSQL 17 and 18
Labels: bug
Refs: SQL-5

## Summary

The native scanner's single-character escape table maps `b`, `f`, `n`, `r` and `t` and returns every other escaped character unchanged. PostgreSQL 17 added `case 'v': return '\v';` to `unescape_single_char`, so from that release `E'a\vb'` is the three bytes `0x61 0x0B 0x62`. The scanner stores `0x61 0x76 0x62` instead. The statement is valid SQL and parses successfully on both sides, so the wrong byte reaches the consumer silently in the `A_Const.sval` of every affected literal.

## Problem

Commit `6f496f5`.

`Unescaped_Character` has no `'v'` case and no version parameter (`sql/src/flyology-postgres-sql-native-scanner.adb:197-204`):

```ada
   function Unescaped_Character (Value : Character) return Character is
     (case Value is
         when 'b' => Character'Val (8),
         when 'f' => Character'Val (12),
         when 'n' => Character'Val (10),
         when 'r' => Character'Val (13),
         when 't' => Character'Val (9),
         when others => Value);
```

The escape action calls it directly, so an unmapped escape appends the escaped character itself (`sql/src/flyology-postgres-sql-native-scanner.adb:381-385`):

```ada
               when Tables.Escape_Character =>
                  if Text (Text'First + 1) = ''' and then not Self.Backslash_Quote then
                     Fail (Self, First, "unsafe use of backslash quote in a string literal");
                  end if;
                  Append (Self.Literal, Unescaped_Character (Text (Text'First + 1)));
```

PostgreSQL 17 maps `v` to the vertical tab (`sql/backends/v17/vendor/native_source/backend/parser/scan.l:1406-1421`):

```c
unescape_single_char(unsigned char c, core_yyscan_t yyscanner)
{
	switch (c)
	{
		case 'b':
			return '\b';
		case 'f':
			return '\f';
		case 'n':
			return '\n';
		case 'r':
			return '\r';
		case 't':
			return '\t';
		case 'v':
			return '\v';
```

PostgreSQL 18 carries the same rule at `sql/backends/v18/vendor/native_source/backend/parser/scan.l:1398-1413`. The same function stops at `case 't'` and falls through to `default:` on the three earlier majors: `sql/backends/v14/vendor/native_source/backend/parser/scan.l:1342-1357`, `sql/backends/v15/vendor/native_source/backend/parser/scan.l:1351-1365` and `sql/backends/v16/vendor/native_source/backend/parser/scan.l:1403-1417`.

The only escape-string statement in the native-versus-oracle corpus is `SELECT E'line\n', U&'d\0061t\+000061'` (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:48`), which exercises `\n` and the two Unicode forms and no other escape. The owned corpus repeats that statement (`sql/tests/src/owned_ast_tests.adb:619`) and compares the owned result against `Parse_Baseline`, which runs the same native scanner, so a scanner defect appears identically on both sides of that comparison and cannot be detected there. The PostgreSQL regression corpus contains no `\v` inside an escape string on any major, and its statement check runs only for statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257).

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the two arenas, then parses `SELECT 'avb'` natively and checks whether the escaped form produced the same tree as the plain letter `v`.

```ada
   Escaped : constant String := "SELECT E'a\vb'";
   Plain_V : constant String := "SELECT 'avb'";

   function Folds_To_Letter_V (Version : SQL.Major_Version) return Boolean is
      A, B : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Native (Escaped, Version, A);
      Oracle.Parse_Native (Plain_V, Version, B);
      return Oracle.First_Difference (A, B) = "";
   end Folds_To_Letter_V;
begin
   for Version in SQL.Major_Version range SQL.PostgreSQL_17 .. SQL.PostgreSQL_18 loop
      Check (Oracle_Difference (Escaped, Version) = "",
             Version'Image & ": E'a\vb' matches the C oracle");
      Check (not Folds_To_Letter_V (Version),
             Version'Image & ": E'a\vb' is not the same tree as 'avb'");
   end loop;
```

```
  -- POSTGRESQL_17 native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val.A_Const.sval.sval: text differs (native='avb', C='ab')]
  FAILED: POSTGRESQL_17: E'a\vb' matches the C oracle
  FAILED: POSTGRESQL_17: E'a\vb' is not the same tree as 'avb'
  -- POSTGRESQL_18 native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val.A_Const.sval.sval: text differs (native='avb', C='ab')]
  FAILED: POSTGRESQL_18: E'a\vb' matches the C oracle
  FAILED: POSTGRESQL_18: E'a\vb' is not the same tree as 'avb'
  ok: POSTGRESQL_14: E'a\vb' matches the C oracle (control)
  ok: POSTGRESQL_14: E'a\vb' equals 'avb' before v17 (control)
  ok: POSTGRESQL_15: E'a\vb' matches the C oracle (control)
  ok: POSTGRESQL_15: E'a\vb' equals 'avb' before v17 (control)
  ok: POSTGRESQL_16: E'a\vb' matches the C oracle (control)
  ok: POSTGRESQL_16: E'a\vb' equals 'avb' before v17 (control)
BUG REPRODUCED: 4 failed expectation(s)
```

The C value prints as `ab` because its middle byte is the non-printing vertical tab `0x0B`. The native scanner produced the three printable bytes `a`, `v`, `b`.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

On PostgreSQL 17 and 18, `E'a\vb'` must produce the three bytes `0x61 0x0B 0x62`, as `unescape_single_char` does at `sql/backends/v17/vendor/native_source/backend/parser/scan.l:1420-1421`. On PostgreSQL 14 through 16 the current behaviour, the letter `v`, is correct.

## Suggested treatment

`Unescaped_Character` needs the escape set for the major being parsed. The scanner is one handwritten generic package instantiated once per major from generated code (`sql/src/flyology-postgres-sql-native-version_v18.adb:16-19`, generated by `sql/tools/generate_native_parser.py`; generated packages are not hand-edited in this repository). This needs a maintainer decision, and it is the same decision the report on the `UESCAPE` character set ({{ISSUE:SQL-5}}) needs, since that set also gained the vertical tab in PostgreSQL 17. The options are:

- add a generic formal to `Flyology.Postgres.SQL.Native.Scanner` describing the escape and space sets, and have `generate_native_parser.py` emit the actual in each `version_v*.adb` instantiation;
- add the mapping to the generated scanner tables, so `Unescaped_Character` becomes table driven and carries no version knowledge of its own;
- pass the major version into `Lexer.Initialize` alongside `Backslash_Quote` and `Standard_Conforming_Strings`, and branch inside the scanner.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the existing escape-string entry at line 48, as a `Check ("SELECT E'a\vb'")` restricted to `PostgreSQL_17` and above plus a pre-17 control. The spike is that test. No existing test asserts the current behaviour, so nothing has to change.

## Severity

A valid escape string silently yields a wrong string value: one byte in the parsed literal differs from what PostgreSQL 17 and 18 produce, with no diagnostic and no difference in tree shape, so a consumer that reads `A_Const.sval` cannot tell. It needs `\v` inside an `E'...'` literal, which is not common SQL. PostgreSQL 17 and 18 only.
