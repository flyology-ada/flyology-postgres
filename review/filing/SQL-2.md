Title: Octal escapes E'\400' through E'\777' fail the parse with a GNAT range-check message
Labels: bug
Refs: SQL-4

## Summary

The octal escape action decodes up to three octal digits into a `Natural`, which reaches 511, and then calls `Character'Val`, which raises `Constraint_Error` above 255. PostgreSQL stores the same value in an `unsigned char`, so `E'\401'` is valid SQL whose string value is the single byte `0x01`. No exception escapes `Parse`: the engine's catch-all turns it into a failed parse whose published diagnostic is the GNAT range-check text `flyology-postgres-sql-native-scanner.adb:393 range check failed` at the `SELECT` token. Valid SQL is rejected on all five majors, and an internal Ada source location is handed to the caller as the diagnostic.

## Problem

Commit `6f496f5`.

The octal escape action (`sql/src/flyology-postgres-sql-native-scanner.adb:386-394`):

```ada
               when Tables.Octal_Escape =>
                  declare
                     Code : constant Natural := Based_Value (Text (Text'First + 1 .. Text'Last), 8);
                  begin
                     if Code = 0 then
                        Fail (Self, First, "invalid zero byte in string literal");
                     end if;
                     Append (Self.Literal, Character'Val (Code));
                  end;
```

`Based_Value` accumulates without an upper bound (`sql/src/flyology-postgres-sql-native-scanner.adb:70-77`), so three octal digits reach 511, and `Character'Val` at line 393 accepts 0 through 255 only. There is no `pragma Suppress` in `sql/src` and no `-gnatp` in the crate configuration, so the check runs.

PostgreSQL's pattern accepts one to three octal digits (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:264`):

```c
xeoctesc		[\\][0-7]{1,3}
```

and its action truncates the value to one byte (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:722-729`):

```c
<xe>{xeoctesc}  {
					unsigned char c = strtoul(yytext + 1, NULL, 8);

					check_escape_warning(yyscanner);
					addlitchar(c, yyscanner);
					if (c == '\0' || IS_HIGHBIT_SET(c))
						yyextra->saw_non_ascii = true;
				}
```

So `\401` is the byte `0x01`, which has no high bit and therefore does not trigger the encoding check either. The rule is identical on the earlier majors.

The `Constraint_Error` is caught by the engine's generic handler and reported as a failed parse with the exception message and no PostgreSQL context (`sql/src/flyology-postgres-sql-native-engine.adb:128-129`):

```ada
         else
            Report_Error (Error, Last_Location, False);
```

That violates the documented shape of a failed parse. `sql/tests/src/owned_ast_tests.adb:494-498` asserts that an invalid parse retains a diagnostic and a cursor position:

```ada
      Assert (not Tree.Valid, "invalid SQL leaves no owned AST root");
      Assert (Length (Tree.Diagnostic_Message) > 0,
              "owned parse result retains the diagnostic");
      Assert (Tree.Diagnostic_Position > 0,
              "owned parse result retains the cursor position");
```

Both hold here, but the diagnostic is an Ada source location rather than a PostgreSQL message, on input PostgreSQL accepts.

The native-versus-oracle corpus has one escape-string statement, `SELECT E'line\n', U&'d\0061t\+000061'` (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:48`), with no octal escape at all. The PostgreSQL regression corpus contains no three-digit octal escape at or above `\400` on any major. The regression corpus check also compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), and the owned corpus compares the owned result against `Parse_Baseline`, which runs the same native scanner, so both sides of that comparison fail identically.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares diagnostics, cursors and arenas, then calls the public owned `Parse` to record whether an exception escapes and what the published diagnostic says.

```ada
   Valid_Octal : constant String := "SELECT E'\401'";
...
      Check (Native_Error (Valid_Octal, Version) = "",
             Version'Image & ": E'\401' parses (C oracle accepts it)");
      Check (Oracle_Difference (Valid_Octal, Version) = "",
             Version'Image & ": E'\401' arena matches the C oracle");
...
   Check (not Raised, "owned V18.Parse does not propagate an exception");
   Check (Tree.Valid, "owned V18.Parse accepts SELECT E'\401'");
```

```
  -- POSTGRESQL_14 native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  -- POSTGRESQL_14 oracle: [] @ 0
  FAILED: POSTGRESQL_14: E'\401' parses (C oracle accepts it)
  FAILED: POSTGRESQL_14: E'\401' arena matches the C oracle
  -- POSTGRESQL_15 native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  -- POSTGRESQL_15 oracle: [] @ 0
  FAILED: POSTGRESQL_15: E'\401' parses (C oracle accepts it)
  FAILED: POSTGRESQL_15: E'\401' arena matches the C oracle
  -- POSTGRESQL_16 native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  -- POSTGRESQL_16 oracle: [] @ 0
  FAILED: POSTGRESQL_16: E'\401' parses (C oracle accepts it)
  FAILED: POSTGRESQL_16: E'\401' arena matches the C oracle
  -- POSTGRESQL_17 native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  -- POSTGRESQL_17 oracle: [] @ 0
  FAILED: POSTGRESQL_17: E'\401' parses (C oracle accepts it)
  FAILED: POSTGRESQL_17: E'\401' arena matches the C oracle
  -- POSTGRESQL_18 native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  -- POSTGRESQL_18 oracle: [] @ 0
  FAILED: POSTGRESQL_18: E'\401' parses (C oracle accepts it)
  FAILED: POSTGRESQL_18: E'\401' arena matches the C oracle
  -- owned Parse diagnostic: [flyology-postgres-sql-native-scanner.adb:393 range check failed] @ 1
  ok: owned V18.Parse does not propagate an exception
  FAILED: owned V18.Parse accepts SELECT E'\401'
  -- SELECT E'\400' native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] oracle: [invalid byte sequence for encoding "UTF8": 0x00]
  -- SELECT E'\777' native: [flyology-postgres-sql-native-scanner.adb:393 range check failed] oracle: [invalid byte sequence for encoding "UTF8": 0xff]
BUG REPRODUCED: 11 failed expectation(s)
```

An empty oracle diagnostic means the oracle parsed the statement. The last two lines show that the range check also masks the real PostgreSQL diagnostics for `\400` and `\777`, which are the encoding errors described in {{ISSUE:SQL-4}}.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

`E'\401'` must parse into a `SelectStmt` whose target is an `A_Const` with a one-byte `sval` of `0x01`, matching `scan.l`'s `unsigned char c = strtoul(yytext + 1, NULL, 8)`. For values whose low byte is `0x00` or has the high bit set, the parse must fail with the PostgreSQL encoding diagnostic, not with an Ada check message. No public diagnostic should ever be an Ada source location.

## Suggested treatment

Truncate the decoded value the way `scan.l` does before appending it, in the octal action at `sql/src/flyology-postgres-sql-native-scanner.adb:386-394`: keep `Code mod 256`, and drive the existing zero-byte and encoding paths from the truncated byte. The hexadecimal action two clauses below already cannot exceed 255, so only the octal path needs the change. Whether the assembled literal is then rejected for encoding is the separate question in {{ISSUE:SQL-4}}.

Independently, the engine's generic handler at `sql/src/flyology-postgres-sql-native-engine.adb:128-129` publishes any unexpected exception message as the diagnostic. Any check message that reaches it is an internal fault, and it would be worth mapping that branch onto a fixed diagnostic rather than the raw exception text, so a future scanner fault cannot leak an Ada source location into the public `Diagnostic_Message`. That is a public-diagnostic policy choice and needs a maintainer decision.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the escape-string entry at line 48, as `Check ("SELECT E'\401'")` on all majors. The spike is that test. No existing test asserts the current behaviour.

## Severity

Valid SQL is rejected on all five supported majors through the ordinary `Parse` path, and the caller is handed an internal Ada source location where a PostgreSQL diagnostic is expected. Nothing crashes and no exception escapes `Parse`. It needs a three-digit octal escape at or above `\400` inside an `E'...'` literal, which is unusual input. Deterministic.
