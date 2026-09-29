Title: Diagnostic cursor positions are byte offsets where PostgreSQL reports character offsets
Labels: bug
Refs: none

## Summary

The engine stores the error position as a byte offset into the statement and the backend publishes that offset plus one as the diagnostic cursor. PostgreSQL converts the byte offset to a character number in `scanner_errposition` before handing it to `errposition`, and the pinned oracle passes that value through unchanged. The two agree only for ASCII input. With one two-byte character before the error, the published cursor is one too high, and the drift grows with every non-ASCII character that precedes the error. Any consumer that indexes the query text by `Cursor_Position` points at the wrong character.

## Problem

Commit `6f496f5`.

The engine keeps a byte offset (`sql/src/flyology-postgres-sql-native-engine.adb:33`):

```ada
         Error_Offset := Natural'Min (Offset, SQL'Length);
```

and the backend publishes it as the cursor (`sql/src/flyology-postgres-sql-native-backend.adb:22-24`):

```ada
         Result.Parse_Error :=
           (Text     => Failure,
            Position => (if Text'Length = 0 then 0 else Error_Offset + 1));
```

PostgreSQL converts the offset to a character number (`sql/backends/v18/vendor/src/postgres/src_backend_parser_scan.c:10538-10549`):

```c
scanner_errposition(int location, core_yyscan_t yyscanner)
{
	int			pos;

	if (location < 0)
		return 0;				/* no-op if location is unknown */

	/* Convert byte offset to character number */
	pos = pg_mbstrlen_with_len(yyextra->scanbuf, location) + 1;
	/* And pass it to the ereport mechanism */
	return errposition(pos);
}
```

and `pg_mbstrlen_with_len` counts characters, not bytes (`sql/backends/v18/vendor/src/postgres/src_backend_utils_mb_mbutils.c:530-547`):

```c
pg_mbstrlen_with_len(const char *mbstr, int limit)
{
	int			len = 0;

	/* optimization for single byte encoding */
	if (pg_database_encoding_max_length() == 1)
		return limit;

	while (limit > 0 && *mbstr)
	{
		int			l = pg_mblen_with_len(mbstr, limit);

		limit -= l;
		mbstr += l;
		len++;
	}
	return len;
}
```

Grammar-level positions go through the same function: the vendored grammar defines `parser_errposition` in terms of it (`sql/backends/v18/vendor/native_source/backend/parser/gram.y:151`):

```c
#define parser_errposition(pos)  scanner_errposition(pos, yyscanner)
```

So both the scanner and the grammar error paths are affected, on all five majors.

`sql/README.md:320-322` states what the native-versus-oracle comparison preserves:

```text
The comparison is member-order independent for objects and order sensitive for
sequences. It preserves scalar kinds, enum values, omitted fields, array
contents, parse validity, diagnostics, and cursor positions.
```

That comparison never sees this case. The four invalid statements in the native-versus-oracle corpus are ASCII only (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:69-75`); the one statement containing non-ASCII text, `SELECT 'é雪' AS unicode_text` at line 45, is valid and therefore produces no diagnostic. The regression corpus check compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), so it never compares a diagnostic at all. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same engine and backend.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic cursor, once for a grammar error and once for a scanner error, each preceded by one two-byte character, with the ASCII-only forms of both statements as controls.

```ada
   --  U+00E9 as its two UTF-8 bytes, written explicitly so the reproduction
   --  does not depend on the compiler's source-encoding setting.
   E_Acute : constant String :=
     Character'Val (16#C3#) & Character'Val (16#A9#);

   Syntax_Case : constant String := "SELECT '" & E_Acute & "', 1 1";
   Scanner_Case : constant String := "SELECT '" & E_Acute & "', 'x";
   Ascii_Syntax : constant String := "SELECT 'e', 1 1";
   Ascii_Scan   : constant String := "SELECT 'e', 'x";
...
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": " & Label & " cursor matches the C oracle");
```

Per-major repetitions are trimmed to PostgreSQL 14 and 18; the intervening majors print the same lines.

```
  -- POSTGRESQL_14 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_14 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_14: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_14 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_14 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_14: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_14: control ASCII grammar cursor matches
  ok: POSTGRESQL_14: control ASCII scanner cursor matches
  -- POSTGRESQL_18 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_18 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_18: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_18 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_18 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_18: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_18: control ASCII grammar cursor matches
  ok: POSTGRESQL_18: control ASCII scanner cursor matches
BUG REPRODUCED: 10 failed expectation(s)
```

The two messages are byte-for-byte identical on both sides in each case; only the cursor differs. The ASCII controls agree exactly, which is why the existing error cases pass.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

`Cursor_Position` must be the 1-based character number of the error, as `scanner_errposition` computes it with `pg_mbstrlen_with_len`, so `SELECT 'é', 1 1` reports 15 and `SELECT 'é', 'x` reports 13. A byte offset and a character number coincide for ASCII, which is why the difference only shows once non-ASCII text precedes the error.

## Suggested treatment

Convert the byte offset to a character count before publishing it. The narrowest place is `sql/src/flyology-postgres-sql-native-backend.adb:22-24`, where `Error_Offset + 1` becomes the count of UTF-8 characters in `Text (Text'First .. Text'First + Error_Offset - 1)` plus one; `Error_Offset` itself stays a byte offset, which is what the engine needs internally for slicing the quoted context. The generated per-major backends publish the cursor the same way and are regenerated rather than hand-edited, so the conversion belongs in the shared helper they call.

`pg_mbstrlen_with_len` counts characters in the server encoding, and the pinned oracle runs with UTF-8. Whether the native parser should assume UTF-8 for this conversion, take the encoding from `Parse_Options`, or fall back to a byte count for single-byte encodings, is an externally visible choice. This needs a maintainer decision: assume UTF-8 and document it, or make the encoding a parse option.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the invalid statements at lines 69-75, as a `Check` on a statement with a two-byte character before the error, together with its ASCII form so a fix cannot regress the common case. The spike is that test. No existing test asserts the current behaviour.

## Severity

A systematic unit mismatch across the whole public `Cursor_Position` surface, not per-case drift: every diagnostic cursor is a byte offset, and every non-ASCII character before the error adds one to the error. A consumer that underlines the offending token in the query text underlines the wrong character whenever the statement contains non-ASCII text, which ordinary string literals and quoted identifiers routinely do. It affects diagnostics only, so no valid statement is misparsed, and it contradicts `sql/README.md:320-322`, which lists cursor positions among what the native-versus-oracle comparison preserves. All five supported majors and both the scanner and grammar error paths. Deterministic.
