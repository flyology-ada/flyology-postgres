# Adversarial verification: SQL native parser findings

Method. Every candidate was re-read against `sql/src`, against the vendored
PostgreSQL sources under `sql/backends/v<major>/vendor`, and then executed
against the version-pinned C oracle through the reproduction harness in
`sql/tests/repros`. Each program asserts the behaviour of PostgreSQL / the C
oracle, so on current sources it prints `BUG REPRODUCED` and exits 1; a fixed
parser would print `PASS` and exit 0. Nothing outside
`sql/tests/repros/src/` was modified and no suite was regenerated or rerun.

Decisive evidence is the C oracle: `Oracle_Difference` parses the same SQL
through the native Ada arena and through the pinned `libpg_query` build for a
major and returns the first differing logical arena path, and
`Native_Error` / `Oracle_Error` (with their `_Position` variants) expose each
side's diagnostic text and cursor.

Severity rubric used (as supplied): P0 = memory unsafety or crash on any
input, or a silent wrong parse of common valid SQL; P1 = wrong result or
unexpected exception on valid input via a reachable path, or a documented
contract violated; P2 = edge-case incorrectness on unusual input, wrong
diagnostic text, or contract drift.

Result: 8 of 9 findings CONFIRMED as stated, 1 PARTIALLY CONFIRMED (SQL-6,
one of its three sub-claims is refuted). Verifying SQL-8 also surfaced one
divergence the discovery report explicitly cleared, recorded below as SQL-8b.
No candidate was refuted outright.

| ID | Verdict | Severity (reviewer -> corrected) | Repro |
|----|---------|----------------------------------|-------|
| SQL-1 | CONFIRMED | P1 -> P1 | `repro_sql_1.adb` |
| SQL-2 | CONFIRMED | P1 -> P1 | `repro_sql_2.adb` |
| SQL-3 | CONFIRMED | P2 -> P2 | `repro_sql_3.adb` |
| SQL-4 | CONFIRMED | P2 -> P2 | `repro_sql_4.adb` |
| SQL-5 | CONFIRMED | P2 -> P2 | `repro_sql_5.adb` |
| SQL-6 | PARTIALLY CONFIRMED | P1 -> P1 | `repro_sql_6.adb` |
| SQL-7 | CONFIRMED | P2 -> P2 | `repro_sql_7.adb` |
| SQL-8 | CONFIRMED | P2 -> P2 | `repro_sql_8.adb` |
| SQL-8b | NEW (found while verifying SQL-8) | - -> P1 | `repro_sql_8.adb` |
| SQL-9 | CONFIRMED | P1 -> P1 | `repro_sql_9.adb` |

### SQL-1: `E'\v'` unescapes to `v` instead of vertical tab on PostgreSQL 17/18

**Verdict:** CONFIRMED. Attempted refutation: the shared Ada scanner body could
have carried a per-version switch elsewhere, or v14-v16 could also have the
rule. Neither holds. `sql/backends/v17/vendor/native_source/backend/parser/scan.l:1406-1421`
and `sql/backends/v18/.../scan.l:1398-1413` define
`unescape_single_char` with `case 'v': return '\v';` immediately after
`case 't'`; the same function at `v14/.../scan.l:1342-1357`,
`v15:1351-1365` and `v16:1403-1417` stops at `case 't'` and falls through to
the default. The Ada `Unescaped_Character`
(`sql/src/flyology-postgres-sql-native-scanner.adb:197-204`, used by the
`Escape_Character` action at lines 381-385) has no `'v'` case and no version
parameter. The C oracle confirms the divergence on v17/v18 and confirms
agreement on v14-v16.

**Severity:** P1 (as filed). Silent wrong string value for valid SQL on two
supported majors. Not P0: `\v` in an escape string is not common SQL.

**Repro:** `sql/tests/repros/src/repro_sql_1.adb`

**Output** (`./run.sh repro_sql_1`, exit status 1):

```
  -- POSTGRESQL_17 native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val.A_Const.sval.sval: text differs (native='avb', C='ab')]
  FAILED: POSTGRESQL_17: E'a\vb' matches the C oracle
  FAILED: POSTGRESQL_17: E'a\vb' is not the same tree as 'avb'
  -- POSTGRESQL_18 native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val.A_Const.sval.sval: text differs (native='avb', C='ab')]
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

(the C value prints as `ab` because the middle byte is the non-printing
vertical tab 0x0B; native produced the three bytes `a`, `v`, `b`.)

**Description:** `Unescaped_Character` in
`sql/src/flyology-postgres-sql-native-scanner.adb:197-204` maps only
`b f n r t` and returns the escaped character unchanged for everything else.
PostgreSQL 17 added `case 'v': return '\v';` to `unescape_single_char` in
`scan.l`, so from v17 on `E'a\vb'` is the three bytes `0x61 0x0B 0x62`, while
the Ada scanner stores `0x61 0x76 0x62` ("avb"). The statement is valid SQL
and parses successfully on both sides, so the wrong byte reaches the consumer
silently in the `A_Const.sval` of every affected literal. Affects
PostgreSQL 17 and 18 only; v14-v16 have no `case 'v'` and both parsers agree.

### SQL-2: Octal escapes `\400`..`\777` fail the parse with an Ada range-check message

**Verdict:** CONFIRMED. Attempted refutation: a `pragma Suppress`, `-gnatp`,
or an earlier validity test could have prevented the range check, and the
oracle could have rejected `E'\401'` too. Neither holds. `scan.l:264` defines
`xeoctesc [\\][0-7]{1,3}` and the action at `v18/.../scan.l:722-729` is
`unsigned char c = strtoul(yytext + 1, NULL, 8); ... addlitchar(c, ...)`, so
C truncates to one byte and `\401` becomes the single byte `0x01` with no high
bit and therefore no `pg_verifymbstr` rejection. The oracle accepts the
statement on all five majors. The Ada action
(`sql/src/flyology-postgres-sql-native-scanner.adb:386-394`) computes
`Based_Value` (up to 511) and calls `Character'Val (Code)`.

The exception does **not** escape `Parse`: the engine's catch-all at
`sql/src/flyology-postgres-sql-native-engine.adb:104-130` converts it into a
failed parse. The repro records this explicitly - `owned V18.Parse does not
propagate an exception` passes, and the resulting `Diagnostic_Message` is the
GNAT check text `flyology-postgres-sql-native-scanner.adb:393 range check
failed` at cursor 1 (the `SELECT` token). That is the contract violation:
`sql/tests/src/owned_ast_tests.adb:494-498` documents that a failed
`Parse` retains a diagnostic and a cursor position, and here the "diagnostic"
is an internal Ada source location rather than a PostgreSQL message, on input
PostgreSQL accepts.

**Severity:** P1 (as filed). Valid SQL rejected through a reachable path, with
an internal-implementation string in the public `Diagnostic`. Not P0: nothing
crashes or escapes `Parse`, and 3-digit octal escapes at or above `\400` are
unusual input.

**Repro:** `sql/tests/repros/src/repro_sql_2.adb`

**Output** (`./run.sh repro_sql_2`, exit status 1):

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

**Description:** The `Octal_Escape` action in
`sql/src/flyology-postgres-sql-native-scanner.adb:386-394` decodes up to three
octal digits into a `Natural` (maximum 511) and then calls
`Character'Val (Code)`, which raises `Constraint_Error` for any value above
255. PostgreSQL's `<xe>{xeoctesc}` rule in `scan.l` stores the value in an
`unsigned char`, so `\400`..`\777` are truncated to their low byte; `E'\401'`
is valid SQL whose value is the one byte `0x01`. On all five majors the native
parser instead returns an invalid tree whose `Diagnostic_Message` is the GNAT
range-check text and whose `Diagnostic_Position` points at the first token,
while the C oracle returns a `SelectStmt` with an `A_Const`. The same range
check also masks the real PostgreSQL diagnostics for `\400` and `\777`
(`invalid byte sequence for encoding "UTF8": 0x00` / `0xff`).

### SQL-3: `\U` escapes >= 0x80000000 overflow `Natural`

**Verdict:** CONFIRMED. Attempted refutation: `Natural` could have been 64-bit
on this toolchain, or the escape could have been rejected before the value was
assembled. Neither holds - the repro shows the GNAT message
`flyology-postgres-sql-native-scanner.adb:74 overflow check failed`, i.e. the
accumulation in `Based_Value`
(`sql/src/flyology-postgres-sql-native-scanner.adb:70-77`) overflows, and the
control `\U7FFFFFFF` (one bit lower) reaches the intended
`invalid Unicode escape value` path at the oracle's cursor. `scan.l` reads the
8 hex digits with `strtoul` into a `pg_wchar` and lets `addunicode` reject the
value, so the message is `invalid Unicode escape value` at the backslash
(cursor 10).

**Severity:** P2 (as filed). The input is invalid on both sides; only the
diagnostic text and cursor are wrong. Confirmed as P2.

**Repro:** `sql/tests/repros/src/repro_sql_3.adb`

**Output** (`./run.sh repro_sql_3`, exit status 1):

```
  -- POSTGRESQL_14 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_14 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_14: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_14: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_15 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_15 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_15: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_15: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_16 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_16 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_16: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_16: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_17 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_17 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_17: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_17: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_18 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_18 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_18: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_18: \UFFFFFFFF cursor matches the C oracle
  -- control \U7FFFFFFF native: [invalid Unicode escape value at or near "\U7FFFFFFF'"] @ 10
  ok: control: \U7FFFFFFF reports invalid Unicode escape value
  ok: control: \U7FFFFFFF cursor matches the C oracle
BUG REPRODUCED: 10 failed expectation(s)
```

**Description:** `Based_Value` in
`sql/src/flyology-postgres-sql-native-scanner.adb:70-77` accumulates into
`Natural`, whose upper bound is 2**31-1 on this toolchain, so the eight hex
digits of `{xeunicode}`'s `\UXXXXXXXX` form overflow on the final multiply for
any value at or above 0x80000000. The `Constraint_Error` is caught by the
engine's generic handler and reported as
`flyology-postgres-sql-native-scanner.adb:74 overflow check failed` at cursor 1,
where `scan.l`'s `addunicode` / `is_valid_unicode_codepoint` path yields
`invalid Unicode escape value at or near "\UFFFFFFFF"` at cursor 10. Both
parsers reject the statement, so only the diagnostic diverges. Affects all
five majors; the escape is inside `E'...'` strings only.

### SQL-4: `E''` octal/hex escapes forming invalid UTF-8 are accepted

**Verdict:** CONFIRMED. Attempted refutation: the pinned oracle might not link
the encoding check, or the check might be a warning. Neither holds. In
`v18/.../scan.l:722-737` both `<xe>{xeoctesc}` and `<xe>{xehexesc}` set
`yyextra->saw_non_ascii = true` when `c == '\0' || IS_HIGHBIT_SET(c)`, and the
rule that closes an escape string runs
`if (yyextra->saw_non_ascii) pg_verifymbstr(yyextra->literalbuf,
yyextra->literallen, false);` before `return SCONST` (lines 616-624). The
oracle rejects `E'\377'` and `E'\xC3'` on every major; native accepts both.
`Finish_Quoted` (`native-scanner.adb:206-218`) performs no post-check.

**Severity:** P2 (as filed). Malformed, unusual input accepted. Confirmed P2 -
this admits an `A_Const.sval` that is not valid UTF-8, but it does not corrupt
any valid statement.

**Repro:** `sql/tests/repros/src/repro_sql_4.adb`

**Output** (`./run.sh repro_sql_4`, exit status 1):

```
  -- POSTGRESQL_14 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_14: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_15 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_15: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_15: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_16 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_16: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_16: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_17 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_17: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_17: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT E'\377' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xff] @ 0
  FAILED: POSTGRESQL_18: SELECT E'\377' reports the C oracle message
  ok: POSTGRESQL_18: SELECT E'\377' reports the C oracle cursor
  -- POSTGRESQL_14 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_14: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_15 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_15: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_15: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_16 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_16: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_16: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_17 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_17: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_17: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_18 SELECT E'\xC3' native: [] @ 0  oracle: [invalid byte sequence for encoding "UTF8": 0xc3] @ 0
  FAILED: POSTGRESQL_18: SELECT E'\xC3' reports the C oracle message
  ok: POSTGRESQL_18: SELECT E'\xC3' reports the C oracle cursor
  -- POSTGRESQL_14 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_14: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_14: SELECT E'\000' reports the C oracle cursor
  -- POSTGRESQL_15 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_15: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_15: SELECT E'\000' reports the C oracle cursor
  -- POSTGRESQL_16 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_16: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_16: SELECT E'\000' reports the C oracle cursor
  -- POSTGRESQL_17 SELECT E'\000' native: [invalid zero byte in string literal at or near "\000'"] @ 10  oracle: [invalid byte sequence for encoding "UTF8": 0x00] @ 0
  FAILED: POSTGRESQL_17: SELECT E'\000' reports the C oracle message
  FAILED: POSTGRESQL_17: SELECT E'\000' reports the C oracle cursor
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

**Description:** The `Octal_Escape` and `Hex_Escape` actions in
`sql/src/flyology-postgres-sql-native-scanner.adb:386-403` append
`Character'Val (Code)` unconditionally, and `Finish_Quoted` (lines 206-218)
returns the assembled literal without validating its encoding. PostgreSQL's
`scan.l` tracks `saw_non_ascii` for a NUL or high-bit byte produced by an
escape and calls `pg_verifymbstr` before returning `SCONST`, so `SELECT
E'\377'` and `SELECT E'\xC3'` fail with `invalid byte sequence for encoding
"UTF8": 0xff` / `0xc3` (cursor 0, since `report_invalid_encoding` carries no
errposition). The native parser accepts both and hands the consumer a string
that is not valid UTF-8. The zero-byte case fails on both sides but with a
different message and cursor (native `invalid zero byte in string literal at or
near "\000'"` @10 versus `invalid byte sequence for encoding "UTF8": 0x00` @0).
Escapes that assemble valid UTF-8 (`E'\303\251'`) agree. Affects all five
majors.

### SQL-5: `UESCAPE` character check misses form feed (all) and vertical tab (v17/18)

**Verdict:** CONFIRMED, with one correction to the reviewer's expected cursor.
`parser.c:352-362` defines `check_uescapechar` as
`isxdigit(escape) || escape == '+' || escape == '\'' || escape == '"' ||
scanner_isspace(escape)`, and `scanner_isspace`
(`sql/backends/v14/vendor/src/postgres/src_backend_parser_scansup.c:126-136`)
lists `' '`, `'\t'`, `'\n'`, `'\r'`, `'\f'`; the v17 and v18 copies
(`src_backend_parser_scansup.c:126-137`) add `'\v'`. The Ada test at
`sql/src/flyology-postgres-sql-native-scanner.adb:717-722` lists
`'0'..'9' | 'a'..'f' | 'A'..'F' | '+' | ''' | '"' | ' ' | Character'Val (9) |
Character'Val (10) | Character'Val (13)` - form feed (12) is missing on every
major and vertical tab (11) is missing for v17/v18. Correction: the oracle's
cursor is 22, not the 21 stated in the discovery report (`E'\f'` begins at
1-based column 22 of `SELECT U&'a' UESCAPE E'\f'`).

**Severity:** P2 (as filed). Invalid input accepted; no valid statement is
misparsed.

**Repro:** `sql/tests/repros/src/repro_sql_5.adb`

**Output** (`./run.sh repro_sql_5`, exit status 1):

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

**Description:** `Next_Token` in
`sql/src/flyology-postgres-sql-native-scanner.adb:717-722` validates the
`UESCAPE` character against a hand-written set that omits form feed
(`Character'Val (12)`) on all supported majors and vertical tab
(`Character'Val (11)`) on v17 and v18, where `scansup.c`'s `scanner_isspace`
(the function `parser.c`'s `check_uescapechar` delegates to) rejects both. As
a result `SELECT U&'a' UESCAPE E'\f'` parses successfully into an `A_Const`
with `sval` `"a"` on every major, and `SELECT U&'a' UESCAPE E'\v'` does the
same on v17/v18, where PostgreSQL and the C oracle report
`invalid Unicode escape character at or near "E'\f'"` (respectively `E'\v'`)
at cursor 22. On v14-v16 the vertical-tab case legitimately succeeds, because
`E'\v'` there denotes the letter `v` (see SQL-1) and `v` is an acceptable
escape character; the repro asserts that as a control.

### SQL-6: v14 `doNegate` folds `-` into String and BitString constants

**Verdict:** PARTIALLY CONFIRMED. Two of the three reproduction cases are
real; the third is refuted.

* `SELECT -'abc'` on v14: CONFIRMED. The oracle builds an `A_Expr`; native
  keeps an `A_Const`. First difference:
  `root.stmts[1].stmt.SelectStmt.targetList[1].ResTarget.val: C object omits
  member A_Const (members: A_Expr)`.
* `SELECT -B'101'` on v14: CONFIRMED, identical path.
* `SELECT -TRUE` on v14: **REFUTED.** The oracle and native agree. v14
  `gram.y`'s `makeBoolAConst` returns
  `makeTypeCast((Node *) n, SystemTypeName("bool"), -1)`, so `doNegate`
  receives a `TypeCast`, never an `A_Const`, and both sides build the
  `A_Expr`. The reviewer's claim that v14 booleans are folded is wrong.

Attempted refutation of the surviving cases: a per-version override could have
existed (`rg '"doNegate"' sql/src` finds only the one implementation), or v15+
could be affected too (they are not - the repro asserts agreement on v15-v18
as controls). `v14/.../gram.y:16877-16898` gates the in-place negation on
`con->val.type == T_Integer` and `con->val.type == T_Float` and otherwise
returns `makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location)`.

**Severity:** P1 (as filed), for the string and bit-string cases. A silent
wrong AST for valid SQL on a supported major. Not P0: unary minus applied
directly to a string or bit-string literal is not common SQL.

**Repro:** `sql/tests/repros/src/repro_sql_6.adb`

**Output** (`./run.sh repro_sql_6`, exit status 1):

```
  -- v14 SELECT -'abc' native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val: C object omits member A_Const (members: A_Expr)]
  FAILED: v14: SELECT -'abc' matches the C oracle
  -- v14 SELECT -B'101' native-vs-C: [root.stmts[ 1].stmt.SelectStmt.targetList[ 1].ResTarget.val: C object omits member A_Const (members: A_Expr)]
  FAILED: v14: SELECT -B'101' matches the C oracle
  FAILED: v14: -'abc' is not the same tree as the literal '-abc'
  -- v14 SELECT -1 native-vs-C: []
  ok: v14: SELECT -1 matches the C oracle
  -- v14 SELECT -1.5 native-vs-C: []
  ok: v14: SELECT -1.5 matches the C oracle
  -- v14 SELECT -TRUE native-vs-C: []
  ok: v14: SELECT -TRUE matches the C oracle
  ok: POSTGRESQL_15: control -'abc' matches the C oracle
  ok: POSTGRESQL_15: control -B'101' matches the C oracle
  ok: POSTGRESQL_16: control -'abc' matches the C oracle
  ok: POSTGRESQL_16: control -B'101' matches the C oracle
  ok: POSTGRESQL_17: control -'abc' matches the C oracle
  ok: POSTGRESQL_17: control -B'101' matches the C oracle
  ok: POSTGRESQL_18: control -'abc' matches the C oracle
  ok: POSTGRESQL_18: control -B'101' matches the C oracle
BUG REPRODUCED: 3 failed expectation(s)
```

**Description:** `Semantics.Invoke`'s `doNegate`
(`sql/src/flyology-postgres-sql-native-semantics.adb:330-360`) decides how to
negate an `A_Const` by probing member paths: if `val.val.str` holds text it
rewrites that member in place and returns the constant. The v14 `Value` union
stores `T_Float`, `T_String` and `T_BitString` payloads in the same
`val.val.str` member, so string and bit-string constants take the float
branch. v14 `gram.y:16877-16898` folds the sign only for `T_Integer` and
`T_Float` and builds `makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location)` for
everything else. Consequently `SELECT -'abc'` yields
`A_Const{sval "-abc", location 7}` in the native arena where PostgreSQL yields
`A_Expr{AEXPR_OP, "-", rexpr A_Const{sval "abc"}}`, and the two trees are
indistinguishable from the plain literal `SELECT '-abc'` (the repro asserts
this). `SELECT -B'101'` diverges the same way. PostgreSQL 14 only: v15+ moved
to distinct `sval` / `fval` / `bsval` members, so the probe selects correctly.
`SELECT -TRUE`, `SELECT -1` and `SELECT -1.5` are unaffected.

### SQL-7: Grammar-level `ereport` errors lose `parser_errposition(@n)` and `%s`/`%d` arguments

**Verdict:** CONFIRMED, with two corrections to the reviewer's scope.

* `SELECT 1 LIMIT 1, 2`: the message survives; the cursor does not. Native
  reports cursor 20 (the end-of-input token that closed
  `select_offset_value`), the oracle reports 10 (`@1`, the `LIMIT` token, per
  `v18/.../gram.y:13310-13318`). All five majors.
* `CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)`: both halves diverge.
  Native says `%s constraints cannot be marked DEFERRABLE` @48 (the `)`
  lookahead); the oracle says `CHECK constraints cannot be marked DEFERRABLE`,
  @38 on v18 (the `DEFERRABLE` token, from `processCASbits($5, @5, "CHECK",
  ...)` at `v18/.../gram.y:4203-4211`) and @0 on v14-v17. All five majors.
* `CREATE ROLE r WITH foo`: `unrecognized role option "%s"` versus
  `unrecognized role option "foo"`, both at cursor 20. All five majors.
* **Correction:** the JSON-encoding case reaches this path from v16 on, not
  only v17/v18 as the addendum states; on v14/v15 the statement is a plain
  syntax error on both sides.
* **Correction:** for the `processCASbits` and JSON cases the pinned oracle
  reports cursor 0 on v14-v17 and a real cursor on v18, so the size of the
  position divergence differs by major even though native diverges everywhere.

Attempted refutation: the `%s` could have been substituted downstream (it is
not - it reaches `SQL.Message` verbatim), and the position could have been
corrected by the engine (it is not - `native-engine.adb:128-129` reports the
generic `Parser_Error` at `Last_Location`).

**Severity:** P2 (as filed). Wrong diagnostic text and wrong cursor on input
that is invalid on both sides. This sits at the top of P2: the raw printf
format reaching a user-visible message is a functional defect over roughly ten
message templates, and if the project treats PostgreSQL-identical diagnostics
as part of its public contract it should be raised to P1.

**Repro:** `sql/tests/repros/src/repro_sql_7.adb`

**Output** (`./run.sh repro_sql_7`, exit status 1):

```
  -- POSTGRESQL_14 SELECT 1 LIMIT 1, 2
  --     native: [LIMIT #,# syntax is not supported] @ 20
  --     oracle: [LIMIT #,# syntax is not supported] @ 10
  ok: POSTGRESQL_14: SELECT 1 LIMIT 1, 2 message matches the C oracle
  FAILED: POSTGRESQL_14: SELECT 1 LIMIT 1, 2 cursor matches the C oracle
  -- POSTGRESQL_15 SELECT 1 LIMIT 1, 2
  --     native: [LIMIT #,# syntax is not supported] @ 20
  --     oracle: [LIMIT #,# syntax is not supported] @ 10
  ok: POSTGRESQL_15: SELECT 1 LIMIT 1, 2 message matches the C oracle
  FAILED: POSTGRESQL_15: SELECT 1 LIMIT 1, 2 cursor matches the C oracle
  -- POSTGRESQL_16 SELECT 1 LIMIT 1, 2
  --     native: [LIMIT #,# syntax is not supported] @ 20
  --     oracle: [LIMIT #,# syntax is not supported] @ 10
  ok: POSTGRESQL_16: SELECT 1 LIMIT 1, 2 message matches the C oracle
  FAILED: POSTGRESQL_16: SELECT 1 LIMIT 1, 2 cursor matches the C oracle
  -- POSTGRESQL_17 SELECT 1 LIMIT 1, 2
  --     native: [LIMIT #,# syntax is not supported] @ 20
  --     oracle: [LIMIT #,# syntax is not supported] @ 10
  ok: POSTGRESQL_17: SELECT 1 LIMIT 1, 2 message matches the C oracle
  FAILED: POSTGRESQL_17: SELECT 1 LIMIT 1, 2 cursor matches the C oracle
  -- POSTGRESQL_18 SELECT 1 LIMIT 1, 2
  --     native: [LIMIT #,# syntax is not supported] @ 20
  --     oracle: [LIMIT #,# syntax is not supported] @ 10
  ok: POSTGRESQL_18: SELECT 1 LIMIT 1, 2 message matches the C oracle
  FAILED: POSTGRESQL_18: SELECT 1 LIMIT 1, 2 cursor matches the C oracle
  -- POSTGRESQL_14 CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)
  --     native: [%s constraints cannot be marked DEFERRABLE] @ 48
  --     oracle: [CHECK constraints cannot be marked DEFERRABLE] @ 0
  FAILED: POSTGRESQL_14: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) message matches the C oracle
  FAILED: POSTGRESQL_14: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) cursor matches the C oracle
  -- POSTGRESQL_15 CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)
  --     native: [%s constraints cannot be marked DEFERRABLE] @ 48
  --     oracle: [CHECK constraints cannot be marked DEFERRABLE] @ 0
  FAILED: POSTGRESQL_15: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) message matches the C oracle
  FAILED: POSTGRESQL_15: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) cursor matches the C oracle
  -- POSTGRESQL_16 CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)
  --     native: [%s constraints cannot be marked DEFERRABLE] @ 48
  --     oracle: [CHECK constraints cannot be marked DEFERRABLE] @ 0
  FAILED: POSTGRESQL_16: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) message matches the C oracle
  FAILED: POSTGRESQL_16: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) cursor matches the C oracle
  -- POSTGRESQL_17 CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)
  --     native: [%s constraints cannot be marked DEFERRABLE] @ 48
  --     oracle: [CHECK constraints cannot be marked DEFERRABLE] @ 0
  FAILED: POSTGRESQL_17: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) message matches the C oracle
  FAILED: POSTGRESQL_17: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) cursor matches the C oracle
  -- POSTGRESQL_18 CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)
  --     native: [%s constraints cannot be marked DEFERRABLE] @ 48
  --     oracle: [CHECK constraints cannot be marked DEFERRABLE] @ 38
  FAILED: POSTGRESQL_18: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) message matches the C oracle
  FAILED: POSTGRESQL_18: CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE) cursor matches the C oracle
  -- POSTGRESQL_14 CREATE ROLE r WITH foo
  --     native: [unrecognized role option "%s"] @ 20
  --     oracle: [unrecognized role option "foo"] @ 20
  FAILED: POSTGRESQL_14: CREATE ROLE r WITH foo message matches the C oracle
  -- POSTGRESQL_15 CREATE ROLE r WITH foo
  --     native: [unrecognized role option "%s"] @ 20
  --     oracle: [unrecognized role option "foo"] @ 20
  FAILED: POSTGRESQL_15: CREATE ROLE r WITH foo message matches the C oracle
  -- POSTGRESQL_16 CREATE ROLE r WITH foo
  --     native: [unrecognized role option "%s"] @ 20
  --     oracle: [unrecognized role option "foo"] @ 20
  FAILED: POSTGRESQL_16: CREATE ROLE r WITH foo message matches the C oracle
  -- POSTGRESQL_17 CREATE ROLE r WITH foo
  --     native: [unrecognized role option "%s"] @ 20
  --     oracle: [unrecognized role option "foo"] @ 20
  FAILED: POSTGRESQL_17: CREATE ROLE r WITH foo message matches the C oracle
  -- POSTGRESQL_18 CREATE ROLE r WITH foo
  --     native: [unrecognized role option "%s"] @ 20
  --     oracle: [unrecognized role option "foo"] @ 20
  FAILED: POSTGRESQL_18: CREATE ROLE r WITH foo message matches the C oracle
  -- POSTGRESQL_16 SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)
  --     native: [unrecognized JSON encoding: %s] @ 63
  --     oracle: [unrecognized JSON encoding: foo] @ 0
  FAILED: POSTGRESQL_16: SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo) message matches the C oracle
  -- POSTGRESQL_17 SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)
  --     native: [unrecognized JSON encoding: %s] @ 63
  --     oracle: [unrecognized JSON encoding: foo] @ 0
  FAILED: POSTGRESQL_17: SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo) message matches the C oracle
  -- POSTGRESQL_18 SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)
  --     native: [unrecognized JSON encoding: %s] @ 63
  --     oracle: [unrecognized JSON encoding: foo] @ 63
  FAILED: POSTGRESQL_18: SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo) message matches the C oracle
BUG REPRODUCED: 23 failed expectation(s)
```

**Description:** `sql/tools/generate_native_actions.py:600-609` translates a
`gram.y` `ereport(ERROR, (errcode(...), errmsg(FMT, args...),
parser_errposition(@n)))` into
`raise Semantics.Parser_Error with Semantics.Text_Of (Builders.Text (FMT))`,
discarding both the `parser_errposition` argument and every `%s`/`%d`
substitution. `sql/src/flyology-postgres-sql-native-engine.adb:128-129` then
reports the exception message at `Last_Location`, the location of whatever
lookahead token finished the production, rather than at the grammar location
the `ereport` named. As a result native emits the raw format string for the
templates that take arguments (`%s constraints cannot be marked DEFERRABLE`,
`unrecognized role option "%s"`, `unrecognized JSON encoding: %s`,
`column number must be in range from 1 to %d`, and the other `processCASbits`
variants) and an incorrect cursor for every grammar-level `ereport`, including
argument-free ones such as `LIMIT #,# syntax is not supported`. Affects all
five majors; the JSON-encoding template exists from v16.

### SQL-8: Non-EOF scanner diagnostics quote the rest of the input; zero-length identifier cursor off by one

**Verdict:** CONFIRMED, every listed case. Attempted refutation: the C side
might quote to end of input too (it does not - only the `<<EOF>>` rules do,
which is why the existing differential cases `SELECT 'unterminated`,
`SELECT $$unterminated`, `SELECT /* unterminated` pass and are asserted as
controls in the repro).

Measured divergences, all five majors unless noted:

| input | native | oracle |
|---|---|---|
| `SELECT E'wrong: \U002FFFFF'` | `... at or near "\U002FFFFF'"` | `... at or near "\U002FFFFF"` |
| `SELECT 1x, 2` (v16+) | `... at or near "1x, 2"` | `... at or near "1x"` |
| `SELECT U&'\061'` | `invalid Unicode escape at or near "\061'"` | `invalid Unicode escape` |
| `SELECT ""` | `... at or near """` @9 | `... at or near """"` @8 |
| `SELECT * FROM U&'t' UESCAPE '!'` | `syntax error at or near "U&'t'"` | `syntax error at or near "U&'t' UESCAPE '!'"` |

**Corrections to the reviewer's scope:** the numeric-junk rules exist from v16,
not v15 (`v15/.../scan.l:1008` is a different junk rule; `SELECT 1x, 2` parses
as `SELECT 1 AS x, 2` on v14 and v15 on both sides). The `$12345678901` case is
not merely context drift - see SQL-8b.

**Severity:** P2 (as filed). Wrong diagnostic text and, for `SELECT ""`, a
cursor one byte late, all on input that is invalid on both sides.

**Repro:** `sql/tests/repros/src/repro_sql_8.adb`

**Output** (`./run.sh repro_sql_8`, exit status 1):

```
  -- POSTGRESQL_14 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_14 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_14: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_15 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_15 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_15: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_16 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_16 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_17 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_17 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
  -- POSTGRESQL_18 native: [invalid Unicode escape value at or near "\U002FFFFF'"] @ 17
  -- POSTGRESQL_18 oracle: [invalid Unicode escape value at or near "\U002FFFFF"] @ 17
  FAILED: POSTGRESQL_18: message matches the C oracle for <<SELECT E'wrong: \U002FFFFF'>>
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
  -- POSTGRESQL_16 native: [trailing junk after numeric literal at or near "1x, 2"] @ 8
  -- POSTGRESQL_16 oracle: [trailing junk after numeric literal at or near "1x"] @ 8
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT 1x, 2>>
  -- POSTGRESQL_17 native: [trailing junk after numeric literal at or near "1x, 2"] @ 8
  -- POSTGRESQL_17 oracle: [trailing junk after numeric literal at or near "1x"] @ 8
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT 1x, 2>>
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
  -- POSTGRESQL_15 native: [invalid Unicode escape at or near "\061'"] @ 11
  -- POSTGRESQL_15 oracle: [invalid Unicode escape] @ 11
  FAILED: POSTGRESQL_15: message matches the C oracle for <<SELECT U&'\061'>>
  -- POSTGRESQL_15 native: [zero-length delimited identifier at or near """] @ 9
  -- POSTGRESQL_15 oracle: [zero-length delimited identifier at or near """"] @ 8
  FAILED: POSTGRESQL_15: message matches the C oracle for <<SELECT "">>
  FAILED: POSTGRESQL_15: cursor matches the C oracle for <<SELECT "">>
  -- POSTGRESQL_15 native: [syntax error at or near "U&'t'"] @ 15
  -- POSTGRESQL_15 oracle: [syntax error at or near "U&'t' UESCAPE '!'"] @ 15
  FAILED: POSTGRESQL_15: message matches the C oracle for <<SELECT * FROM U&'t' UESCAPE '!'>>
  -- POSTGRESQL_16 native: [invalid Unicode escape at or near "\061'"] @ 11
  -- POSTGRESQL_16 oracle: [invalid Unicode escape] @ 11
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT U&'\061'>>
  -- POSTGRESQL_16 native: [zero-length delimited identifier at or near """] @ 9
  -- POSTGRESQL_16 oracle: [zero-length delimited identifier at or near """"] @ 8
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT "">>
  FAILED: POSTGRESQL_16: cursor matches the C oracle for <<SELECT "">>
  -- POSTGRESQL_16 native: [syntax error at or near "U&'t'"] @ 15
  -- POSTGRESQL_16 oracle: [syntax error at or near "U&'t' UESCAPE '!'"] @ 15
  FAILED: POSTGRESQL_16: message matches the C oracle for <<SELECT * FROM U&'t' UESCAPE '!'>>
  -- POSTGRESQL_17 native: [invalid Unicode escape at or near "\061'"] @ 11
  -- POSTGRESQL_17 oracle: [invalid Unicode escape] @ 11
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT U&'\061'>>
  -- POSTGRESQL_17 native: [zero-length delimited identifier at or near """] @ 9
  -- POSTGRESQL_17 oracle: [zero-length delimited identifier at or near """"] @ 8
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT "">>
  FAILED: POSTGRESQL_17: cursor matches the C oracle for <<SELECT "">>
  -- POSTGRESQL_17 native: [syntax error at or near "U&'t'"] @ 15
  -- POSTGRESQL_17 oracle: [syntax error at or near "U&'t' UESCAPE '!'"] @ 15
  FAILED: POSTGRESQL_17: message matches the C oracle for <<SELECT * FROM U&'t' UESCAPE '!'>>
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

**Description:** `sql/src/flyology-postgres-sql-native-engine.adb:112-119`
builds the "at or near" context for every `Scanner_Error` as
`SQL (SQL'First + Offset .. SQL'Last)`, i.e. everything from the error offset
to the end of the statement. In flex, `YY_DO_BEFORE_ACTION` writes `'\0'` at
`yytext + yyleng`, so `scanner_yyerror`'s `loc = scanbuf + *yylloc` stops at
the end of the current match; only the `<<EOF>>` rules (unterminated literal,
dollar quote or comment) genuinely quote through end of input. Three related
divergences ride along: `str_udeescape` reports plain `invalid Unicode escape`
through an `ereport` with `scanner_errposition`
(`v18/.../parser.c:492-495`) and no "at or near" suffix at all, whereas
native appends one; `base_yylex` un-truncates the current token before
scanning the `UESCAPE` string (`v18/.../parser.c:264-266`, "Un-truncate
current token so errors point to third token") so a syntax error quotes the
whole `U&'t' UESCAPE '!'` sequence where native quotes only `U&'t'`; and the
zero-length delimited identifier is reported at the opening quote in C
(`SET_YYLLOC()` runs in the `{xdstart}` rule, `v18/.../scan.l:789-793`, and
`yyerror` at line 804 uses that `*yylloc`) but at the closing quote in Ada
(`native-scanner.adb:431-435` passes `First` of the `Identifier_Stop` match),
giving cursor 9 instead of 8. Affects all five majors.

### SQL-8b (NEW): the v18-only `parameter number too large` check is applied to v14-v17

**Verdict:** CONFIRMED. Found while reproducing SQL-8; not in the discovery
report, which explicitly cleared this area ("Parameters `$n`: overflow check
matches `strtoint` ERANGE" under *Areas reviewed with no findings*). That
clearance is wrong for v14-v17.

`{param}` in `v14/.../scan.l:969`, `v15:976`, `v16:993` and `v17:1008` is
`yylval->ival = atol(yytext + 1); return PARAM;` with no range test. Only
`v18/.../scan.l:994-1004` introduces
`pg_strtoint32_safe(...)` / `yyerror("parameter number too large")`. The Ada
scanner applies the range check on every major, so `SELECT $12345678901, 1`
is rejected by native on v14-v17 while the C oracle parses it successfully
(`validity differs`).

**Severity:** P1. Valid-for-that-major SQL is rejected through the ordinary
`Parse` path on four of the five supported majors, with a diagnostic
PostgreSQL never produces there.

**Repro:** `sql/tests/repros/src/repro_sql_8.adb` (the `SELECT $12345678901, 1`
block; on v14-v17 the oracle column is empty, meaning the oracle accepted the
statement).

**Output excerpt:**

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

**Description:** The Ada scanner's parameter rule enforces the int32 range
check that PostgreSQL added in version 18, but the rule is shared across all
five generated backends. On PostgreSQL 14 through 17, `scan.l`'s `{param}`
action is a bare `atol` with no range test, so `SELECT $12345678901, 1` is a
statement those servers accept and the pinned oracle parses into a valid tree.
Native instead returns an invalid tree with `parameter number too large at or
near "$12345678901, 1"` at cursor 8. On v18 both reject the statement and only
the quoted context differs (SQL-8). Consumers targeting v14-v17 therefore see
a rejection for input the real server accepts.

### SQL-9: Diagnostic cursor positions are byte offsets; PostgreSQL reports character offsets

**Verdict:** CONFIRMED. Attempted refutation: the oracle wrapper could have
converted the cursor back to bytes, or the difference could have come from the
message rather than the position. Neither holds - the two messages are
byte-for-byte identical in both cases and only the cursor differs, and the
ASCII controls agree exactly. `scanner_errposition`
(`v18/vendor/src/postgres/src_backend_parser_scan.c:10538-10549`) is
`pos = pg_mbstrlen_with_len(yyextra->scanbuf, location) + 1;`, and
`pg_mbstrlen_with_len` (`src_backend_utils_mb_mbutils.c:530-547`) counts
characters, not bytes. Grammar-level positions go through the same function:
the vendored `gram.y` defines `parser_errposition` as
`scanner_errposition(pos, yyscanner)`.

**Severity:** P1 (as filed). This is a systematic unit mismatch across the
whole public `Cursor_Position` surface rather than per-case drift, and it
contradicts `sql/README.md:319-322`, which states that the native/oracle
comparison "preserves scalar kinds, enum values, omitted fields, array
contents, parse validity, diagnostics, and cursor positions". Weakest of the
P1s in the set, since it only affects diagnostics for input that is invalid on
both sides; a reviewer who scopes P1 strictly to valid input would file it P2.

**Repro:** `sql/tests/repros/src/repro_sql_9.adb`

**Output** (`./run.sh repro_sql_9`, exit status 1):

```
  -- POSTGRESQL_14 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_14 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_14: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_14 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_14 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_14: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_14: control ASCII grammar cursor matches
  ok: POSTGRESQL_14: control ASCII scanner cursor matches
  -- POSTGRESQL_15 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_15 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_15: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_15 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_15 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_15: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_15: control ASCII grammar cursor matches
  ok: POSTGRESQL_15: control ASCII scanner cursor matches
  -- POSTGRESQL_16 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_16 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_16: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_16 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_16 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_16: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_16: control ASCII grammar cursor matches
  ok: POSTGRESQL_16: control ASCII scanner cursor matches
  -- POSTGRESQL_17 grammar error after 2-byte character native @ 16 [syntax error at or near "1"]
  -- POSTGRESQL_17 grammar error after 2-byte character oracle @ 15 [syntax error at or near "1"]
  FAILED: POSTGRESQL_17: grammar error after 2-byte character cursor matches the C oracle
  -- POSTGRESQL_17 scanner error after 2-byte character native @ 14 [unterminated quoted string at or near "'x"]
  -- POSTGRESQL_17 scanner error after 2-byte character oracle @ 13 [unterminated quoted string at or near "'x"]
  FAILED: POSTGRESQL_17: scanner error after 2-byte character cursor matches the C oracle
  ok: POSTGRESQL_17: control ASCII grammar cursor matches
  ok: POSTGRESQL_17: control ASCII scanner cursor matches
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

**Description:** `sql/src/flyology-postgres-sql-native-engine.adb:33` stores
`Error_Offset := Natural'Min (Offset, SQL'Length)` as a byte offset into the
statement, and `sql/src/flyology-postgres-sql-native-backend.adb:22-24` (and
the generated `ast_parser_v*.adb`) publishes `Error_Offset + 1` as the
diagnostic cursor. PostgreSQL converts the byte offset to a character number
in `scanner_errposition` before handing it to `errposition`, and the pinned
oracle wrapper passes that `cursorpos` through unchanged, so the two agree
only for ASCII input. With a single two-byte character before the error,
`SELECT 'e-acute', 1 1` reports cursor 16 natively against the oracle's 15,
and the scanner-level `SELECT 'e-acute', 'x` reports 14 against 13; the drift
grows with every non-ASCII character preceding the error. Any consumer that
indexes the query text by `Cursor_Position` - to underline the offending token,
for instance - points at the wrong character. Affects all five majors and both
the scanner and grammar error paths.

## Corrections to the discovery report

1. **SQL-5:** the oracle's cursor for `SELECT U&'a' UESCAPE E'\f'` is 22, not
   21.
2. **SQL-6:** `SELECT -TRUE` is *not* affected. v14 `makeBoolAConst` returns a
   `TypeCast` wrapping the `A_Const`, so `doNegate` never sees an `A_Const`
   and both parsers build the `A_Expr`. Only the String and BitString cases
   are real.
3. **SQL-7 addendum:** the `unrecognized JSON encoding: %s` path is reachable
   from v16, not only v17/v18. For the `processCASbits` and JSON cases the
   pinned oracle carries cursor 0 on v14-v17 and a real cursor on v18, so
   the *size* of the position divergence differs by major.
4. **SQL-8:** `SELECT 1x, 2` is a numeric-junk error from v16, not v15; on v14
   and v15 both parsers accept it as `SELECT 1 AS x, 2`.
5. **SQL-8b (new):** the *Areas reviewed with no findings* entry
   "Parameters `$n`: overflow check matches `strtoint` ERANGE" is incorrect.
   The range check exists only in v18's `scan.l`; applying it to v14-v17
   rejects statements the oracle accepts. Filed above as P1.

## Verification artifacts

Nine programs under `sql/tests/repros/src/`, one per finding:
`repro_sql_1.adb` .. `repro_sql_9.adb`. Each is built and run with
`cd sql/tests/repros && ./run.sh repro_sql_<n>`; all nine currently exit 1
with `BUG REPRODUCED`, and each contains at least one control expectation that
passes today, so a program that starts printing `PASS` indicates a real fix
rather than a broken assertion. No production or test source outside that
directory was touched, and neither the full SQL suite nor any generator was
run.
