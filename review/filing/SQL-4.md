Title: Escape strings whose octal or hex escapes form invalid UTF-8 are accepted instead of rejected
Labels: bug
Refs: SQL-2

## Summary

PostgreSQL tracks whether an escape produced a NUL or a high-bit byte and runs `pg_verifymbstr` over the assembled literal before returning `SCONST`, so `SELECT E'\377'` and `SELECT E'\xC3'` fail with an encoding error. The native scanner appends the byte unconditionally and `Finish_Quoted` returns the literal without validating it, so both statements parse successfully and the consumer receives an `A_Const.sval` that is not valid UTF-8. The zero-byte case fails on both sides, but with a different message and a different cursor.

## Problem

Commit `6f496f5`.

The two escape actions append the decoded byte with no encoding bookkeeping (`sql/src/flyology-postgres-sql-native-scanner.adb:386-403`):

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
               when Tables.Hex_Escape =>
                  declare
                     Code : constant Natural := Based_Value (Text (Text'First + 2 .. Text'Last), 16);
                  begin
                     if Code = 0 then
                        Fail (Self, First, "invalid zero byte in string literal");
                     end if;
                     Append (Self.Literal, Character'Val (Code));
                  end;
```

`Finish_Quoted` then returns the assembled literal with no post-check (`sql/src/flyology-postgres-sql-native-scanner.adb:206-218`):

```ada
   procedure Finish_Quoted
     (Self : in out Lexer; Token : out Integer; Value : out Builders.Dynamic_Value) is
   begin
      case Self.Previous_String_Condition is
         when XB_Condition => Token := Token_Bconst;
         when XH_Condition => Token := Token_Xconst;
         when XQ_Condition | XE_Condition => Token := Token_Sconst;
         when XUS_Condition => Token := Token_Usconst;
         when others =>
            Fail (Self, Self.Token_Location, "unhandled quoted string state");
      end case;
      Value := Builders.Text (To_String (Self.Literal));
   end Finish_Quoted;
```

PostgreSQL sets a flag in both escape actions (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:722-737`):

```c
<xe>{xeoctesc}  {
					unsigned char c = strtoul(yytext + 1, NULL, 8);

					check_escape_warning(yyscanner);
					addlitchar(c, yyscanner);
					if (c == '\0' || IS_HIGHBIT_SET(c))
						yyextra->saw_non_ascii = true;
				}
<xe>{xehexesc}  {
					unsigned char c = strtoul(yytext + 2, NULL, 16);

					check_escape_warning(yyscanner);
					addlitchar(c, yyscanner);
					if (c == '\0' || IS_HIGHBIT_SET(c))
						yyextra->saw_non_ascii = true;
				}
```

and the rule that closes an escape string validates before returning the token (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:619-624`):

```c
							if (yyextra->saw_non_ascii)
								pg_verifymbstr(yyextra->literalbuf,
											   yyextra->literallen,
											   false);
							yylval->str = litbufdup(yyscanner);
							return SCONST;
```

The rules are the same on all five majors. `report_invalid_encoding` carries no `errposition`, which is why the oracle's cursor for these errors is 0.

The native-versus-oracle corpus has one escape-string statement, `SELECT E'line\n', U&'d\0061t\+000061'` (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:48`), with no octal or hexadecimal escape. The `\377` and `\xNN` sequences in the PostgreSQL regression corpus are inside plain `'...'` literals, which never take the escape path. The regression corpus check compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), so a statement the oracle rejects and the native parser accepts is counted as rejected and skipped rather than compared. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same native scanner, so an over-permissive scanner is over-permissive on both sides of that comparison.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic text and the cursor, with `E'\303\251'`, two escapes that assemble one valid UTF-8 character, as a control.

```ada
   Expect_Same ("SELECT E'\377'");
   Expect_Same ("SELECT E'\xC3'");
   Expect_Same ("SELECT E'\000'");
...
      Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
             Version'Image & ": " & Text & " reports the C oracle message");
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": " & Text & " reports the C oracle cursor");
```

Per-major repetitions are trimmed to PostgreSQL 14 and 18; the intervening majors print the same lines.

```
  -- POSTGRESQL_14 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_14: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_18: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_18: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_14 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_14: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_18: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_18: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_14 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_14: SELECT E'\000' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_18: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_18: SELECT E'\000' reports the C oracle cursor
  ok: POSTGRESQL_14: control E'\303\251' matches the C oracle
  ok: POSTGRESQL_15: control E'\303\251' matches the C oracle
  ok: POSTGRESQL_16: control E'\303\251' matches the C oracle
  ok: POSTGRESQL_17: control E'\303\251' matches the C oracle
  ok: POSTGRESQL_18: control E'\303\251' matches the C oracle
BUG REPRODUCED: 20 failed expectation(s)
```

An empty native diagnostic means the native parser accepted the statement. The control shows that escapes assembling valid UTF-8 agree on every major.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

An escape string in which an octal or hexadecimal escape produced a NUL or a high-bit byte must be validated as a whole before the token is returned, and must fail with `invalid byte sequence for encoding "UTF8": 0x<byte>` at cursor 0, matching `pg_verifymbstr` at `sql/backends/v18/vendor/native_source/backend/parser/scan.l:619-622`. That covers the zero-byte case as well, which PostgreSQL reports through the same path rather than as a scanner error at the escape.

## Suggested treatment

Track the equivalent of `saw_non_ascii` on the lexer while the escape actions run at `sql/src/flyology-postgres-sql-native-scanner.adb:386-403`, and validate the assembled literal in `Finish_Quoted` (lines 206-218) for the `XE_Condition` case when the flag is set, reporting the first offending byte with the PostgreSQL message and cursor 0. Removing the two `if Code = 0` early failures is part of the same change, since PostgreSQL reaches the zero byte through the same validation rather than through a scanner error at the escape. The octal action must be corrected for values above 255 first, or the validation is never reached for those inputs; that is {{ISSUE:SQL-2}}.

The validation needs a UTF-8 verifier over the assembled literal, which the crate does not currently have. Whether to add one in `sql/src`, and whether the parser should validate encoding at all rather than leaving it to the consumer, is a public-behaviour choice. This needs a maintainer decision: validate in the scanner and match PostgreSQL exactly, or document that the native parser does not perform the encoding check and that `A_Const.sval` may hold bytes PostgreSQL would reject.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the escape-string entry at line 48, as `Check ("SELECT E'\377'")` and `Check ("SELECT E'\xC3'")` on all majors. The spike is that test. No existing test asserts the current behaviour.

## Severity

Malformed input is accepted and the parsed `A_Const.sval` holds bytes that are not valid UTF-8, so a consumer that assumes the parser produces text a PostgreSQL server would accept can be handed a string that server rejects. No valid statement is misparsed, and it needs an octal or hexadecimal escape producing a NUL or a high-bit byte inside an `E'...'` literal, which is unusual input. All five supported majors.
