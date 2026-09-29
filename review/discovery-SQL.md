# Discovery report: SQL native parser runtime and generators

Scope: read-only correctness review of the handwritten native scanner, DFA, LALR engine,
engine error reporting, builders, converters, and semantics runtime under `sql/src`, plus the
generator logic in `sql/tools` (`generate_native_parser.py`, `generate_native_actions.py`,
`generate_owned_ast.py`, `generate_owned_parser.py`), compared rule by rule against the
vendored PostgreSQL 14-18 `scan.l`, `scansup.c`, `parser.c`, and `gram.y`. Nothing was built,
run, or modified.

Severity rubric: P0 = memory unsafety (arena out-of-bounds, use-after-free in the owned AST,
crash on any input) or a silent wrong parse of common valid SQL; P1 = wrong result or
unexpected exception on valid input via a reachable path (parse failing instead of returning
the tree, wrong AST shape, wrong error location), or a documented contract violated;
P2 = edge-case incorrectness on unusual input, wrong diagnostic text, or contract drift.

Note on exception behaviour: the engine (`native-engine.adb:108-130`) catches every exception,
so scanner `Constraint_Error`s do not escape `Parse`; they surface as a failed parse whose
message is the GNAT check text. Findings below describe that observable result.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| SQL-1 | `E'\v'` unescapes to `v` instead of vertical tab on PostgreSQL 17/18 | P1 | high |
| SQL-2 | Octal escapes `\400`..`\777` fail the parse (range check) instead of storing the low byte | P1 | high |
| SQL-3 | `\U` escapes >= 0x80000000 overflow `Natural`; wrong diagnostic instead of "invalid Unicode escape value" | P2 | high |
| SQL-4 | `E''` octal/hex escapes forming invalid UTF-8 are accepted; PostgreSQL rejects via `pg_verifymbstr` | P2 | high |
| SQL-5 | `UESCAPE` character check misses form feed (all) and vertical tab (v17/18) | P2 | high |
| SQL-6 | v14 `doNegate` folds `-` into String/BitString/Boolean constants instead of building `A_Expr` | P1 | high |
| SQL-7 | Grammar-level `ereport` errors lose `parser_errposition(@n)` and `%s`/`%d` arguments | P2 | high |
| SQL-8 | Non-EOF scanner diagnostics quote the rest of the input; zero-length identifier cursor off by one | P2 | high |
| SQL-9 | Diagnostic cursor positions are byte offsets; PostgreSQL and the oracle report character offsets | P1 | high |

Verification notes for all findings: the shallow arena path (`Views.Parse` versus
`C_Oracle.Parse` through `Internals.First_Difference`) compares diagnostic text and position
exactly, so every diagnostic finding can be checked by adding the quoted SQL to
`sql/tests/src/flyology-postgres-sql-differential_testing.adb`; AST-shape findings can be
checked the same way or through `AST.V14/V17/V18.Parse`.

## Findings

### SQL-1: `E'\v'` unescapes to the letter `v` instead of vertical tab on PostgreSQL 17 and 18

Location: `sql/src/flyology-postgres-sql-native-scanner.adb:197-204` (`Unescaped_Character`),
used by the `Escape_Character` action at lines 381-385. Reference:
`sql/backends/v17/vendor/native_source/backend/parser/scan.l` and
`sql/backends/v18/.../scan.l`, `unescape_single_char` (`case 'v': return '\v';`); v14-v16 have
no `case 'v'`.

Severity: P1 (silent wrong string value for valid SQL; affects two supported majors).
Confidence: high.

Evidence:
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
v17/v18 `scan.l`:
```c
		case 't':
			return '\t';
		case 'v':
			return '\v';
```
The Ada scanner body is shared by all majors and has no per-version switch for this escape.

Failure scenario: any escape string containing `\v` on v17/v18 (e.g. tab-separated data with
vertical tabs) is parsed with the wrong byte, silently.

Reproduction: `SELECT E'a\vb'` through `AST.V17.Parse` or `AST.V18.Parse`. PostgreSQL 17/18 (and
the C oracle) yield `A_Const` sval = `"a" & Character'Val (11) & "b"` (3 bytes, 0x61 0x0B 0x62).
The Ada scanner yields `"avb"`. On v14-v16 both yield `"avb"` (no bug).

Existing coverage: none. `rg -c -e "E'[^']*\\\\v"` over the v14, v17, and v18 regression corpora
returns 0 matches; `native_testing.adb` only scans `E'line\n'`; the differential list has
`E'line\n'` only.

### SQL-2: Octal escapes `\400`..`\777` in `E''` strings fail the parse with an Ada range-check message instead of producing the low byte

Location: `sql/src/flyology-postgres-sql-native-scanner.adb:386-394` (`Octal_Escape` action:
`Append (Self.Literal, Character'Val (Code))`), caught by
`sql/src/flyology-postgres-sql-native-engine.adb:108-130` (`when Error : others` ->
`Report_Error (Error, Last_Location, False)`). Reference: v14-v18 `scan.l`
`xeoctesc [\\][0-7]{1,3}` and its action `unsigned char c = strtoul(yytext + 1, NULL, 8);
... addlitchar(c, ...)` (the value is truncated to one byte in C).

Severity: P1 (valid SQL rejected; also masks the real PostgreSQL diagnostic for `\400` and
`\600`..`\777`). Confidence: high (no `pragma Suppress` in `sql/src`, no `-gnatp` in
`sql/config/flyology_postgres_sql_config.gpr`, so `Character'Val (511)` raises
`Constraint_Error`).

Evidence:
```ada
               when Tables.Octal_Escape =>
                  declare
                     Code : constant Natural := Based_Value (Text (Text'First + 1 .. Text'Last), 8);
                  begin
                     if Code = 0 then
                        Fail (Self, First, "invalid zero byte in string literal");
                     end if;
                     Append (Self.Literal, Character'Val (Code));
```
`Based_Value` of three octal digits ranges to 511; `Character'Val` accepts 0..255. The engine's
generic handler turns the `Constraint_Error` into `Success := False` with the Ada exception
message and `Error_Offset := Last_Location` (the token *before* the string).

Failure scenario: `SELECT E'\401'` is valid PostgreSQL (`strtoul` -> 257, stored as byte 0x01,
no high bit, so no encoding check). The Ada scanner raises inside `Next_Token`, and the
engine reports a failed parse whose message is the GNAT range-check text and whose position
is that of `SELECT`.

Reproduction: `AST.V18.Parse ("SELECT E'\401'")` (all majors). Expected (PostgreSQL / C
oracle): valid, one `SelectStmt` whose target is `A_Const` sval = 1 byte `Character'Val (1)`,
location 7. Ada: invalid tree; message is a GNAT check message (not a PostgreSQL diagnostic),
position 1. Related: `SELECT E'\777'` -> PostgreSQL error `invalid byte sequence for encoding
"UTF8": 0xff` (cursor 0, see SQL-4) versus the Ada range-check failure; `SELECT E'\400'` ->
PostgreSQL `invalid byte sequence for encoding "UTF8": 0x00` versus the range-check failure.

Existing coverage: none. `rg -n '\\[4-7][0-7][0-7]' sql/tests/.cache/postgres-regress/corpus/v18/*.sql`
finds no 3-digit octal escape >= `\400`; `native_testing.adb` only exercises `E'line\n'`.

### SQL-3: `\U` escapes with a value >= 0x80000000 overflow `Natural` and yield an Ada overflow message instead of "invalid Unicode escape value"

Location: `sql/src/flyology-postgres-sql-native-scanner.adb:70-77` (`Based_Value` returns
`Natural`), called from `Unicode_Escape` (line 351) and `Unicode_Surrogate` (line 364) with
the 8 hex digits of `xeunicode [\\](u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})`. Reference: `scan.l`
`pg_wchar c = strtoul(yytext + 2, NULL, 16); ... addunicode(c, ...)` ->
`if (!is_valid_unicode_codepoint(c)) yyerror("invalid Unicode escape value");`.

Severity: P2 (input is invalid in both; diagnostic text and position are wrong).
Confidence: high.

Evidence:
```ada
   function Based_Value (Value : String; Base : Positive) return Natural is
      Result : Natural := 0;
   begin
      for Item of Value loop
         Result := Result * Base + Hex_Value (Item);
```
`Natural'Last` is 2**31-1 on this toolchain; `\U80000000` and above overflow on the last
multiply and raise `Constraint_Error`, which the engine reports as a generic failure at
`Last_Location`.

Reproduction: `SELECT E'\UFFFFFFFF'` (all majors). Expected (PostgreSQL / oracle): message
`invalid Unicode escape value at or near "\UFFFFFFFF"`, cursor position 10 (1-based, the
backslash). Ada: message is the GNAT overflow text, position 1. Compare with
`SELECT E'\U7FFFFFFF'`, which stays inside `Natural` and correctly reports
`invalid Unicode escape value` (but see SQL-8 for the context text).

Existing coverage: none (`rg -n '\\U[89A-Fa-f][0-9A-Fa-f]{7}'` over the corpus finds nothing;
the corpus only has `\U002FFFFF`-style values below 2**31).

### SQL-4: `E''` octal/hex escapes that form invalid UTF-8 are accepted; PostgreSQL rejects them after `pg_verifymbstr`

Location: `sql/src/flyology-postgres-sql-native-scanner.adb:386-403` (`Octal_Escape`,
`Hex_Escape`) and 206-218 (`Finish_Quoted`, no post-check). Reference: v14-v18 `scan.l`
`<xe>{xeoctesc}` / `<xe>{xehexesc}` set `yyextra->saw_non_ascii = true` for `c == '\0' ||
IS_HIGHBIT_SET(c)`, and `<xqs>{quotecontinuefail}|{other}|<<EOF>>` runs
`if (yyextra->saw_non_ascii) pg_verifymbstr(literalbuf, literallen, false);` before returning
`SCONST` (v18 `scan.l:619-622`; the oracle links `src_backend_utils_mb_mbutils.c` and calls it
at `src_backend_parser_scan.c:8922`).

Severity: P2 (malformed input accepted; the returned string is not valid UTF-8, so downstream
consumers that assume UTF-8 text may misbehave). Confidence: high.

Evidence: the Ada actions append `Character'Val (Code)` unconditionally for 1..255 and never
validate the assembled literal.

Reproduction (all majors):
- `SELECT E'\377'` -> PostgreSQL/oracle: error `invalid byte sequence for encoding "UTF8": 0xff`
  with cursor position 0 (`report_invalid_encoding` carries no `errposition`). Ada: valid tree,
  `A_Const` sval = one byte 0xFF.
- `SELECT E'\xC3'` -> same PostgreSQL error (`0xc3`); Ada accepts a lone lead byte.
- `SELECT E'\000'` / `SELECT E'\x00'` -> PostgreSQL: `invalid byte sequence for encoding
  "UTF8": 0x00`, cursor 0. Ada: `invalid zero byte in string literal at or near "\000'"`,
  cursor 10. (Both fail, but message and position differ.)
- Valid multi-byte sequences assembled from escapes (`SELECT E'\303\251'`) are accepted by
  both; no difference.

Existing coverage: the corpus `\377` / `\xNN` hits (`char.sql`, `conversion.sql`,
`encoding.sql`) are inside plain `'...'` literals, which never take the escape path.

### SQL-5: `UESCAPE` escape-character validation misses form feed (all majors) and vertical tab (v17, v18)

Location: `sql/src/flyology-postgres-sql-native-scanner.adb:717-722`. Reference: `parser.c`
`check_uescapechar` -> `scanner_isspace`, `scansup.c` (`' '`, `\t`, `\n`, `\r`, `\f`; v17/v18
add `\v`).

Severity: P2. Confidence: high.

Evidence:
```ada
               if Escape in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | '+' | ''' | '"' |
                 ' ' | Character'Val (9) | Character'Val (10) | Character'Val (13)
               then
                  Fail (Self, Natural (Next_Loc), "invalid Unicode escape character");
```
`Character'Val (12)` is absent on every major and `Character'Val (11)` is absent for v17/v18.

Reproduction: `SELECT U&'a' UESCAPE E'\f'` (all majors) and `SELECT U&'a' UESCAPE E'\v'`
(v17, v18 — on v14-v16 `E'\v'` is the letter `v`, which is a legal escape). Expected
(PostgreSQL / oracle): `invalid Unicode escape character at or near "E'\f'"`, cursor 21. Ada:
valid parse with `A_Const` sval `"a"`.

Existing coverage: none; corpus `UESCAPE` cases use `'!'`, `'*'`, `'+'`, `'\\'` and bare `+`.

### SQL-6: PostgreSQL 14 `doNegate` folds the sign into String, BitString, and Boolean constants instead of building `A_Expr`

Location: `sql/src/flyology-postgres-sql-native-semantics.adb:330-360` (`doNegate` in
`Semantics.Invoke`; no per-version override exists — `rg '"doNegate"'
sql/src/*support*.adb` finds none). Reference: v14 `gram.y` `doNegate`:
`if (con->val.type == T_Integer) ... if (con->val.type == T_Float) doNegateFloat(&con->val);
... return makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location);`.

Severity: P1 (silent wrong AST for valid SQL on a supported major). Confidence: high.

Evidence:
```ada
            Float_14 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.val.str");
            ...
               elsif Float_14.Kind = Builders.Text_Value then
                  Build.Set_Field (Item, "val.val.str", Negated (Float_14));
                  return Item;
```
The v14 `Value` union stores `T_Float`, `T_String`, and `T_BitString` payloads in the same
`val.val.str` member; the generated v14 helpers write it for all three
(`action_helper_catalog_chunk_01.adb:35-36` sets `val.type` 228 = `T_String` +
`val.val.str`; `chunk_02.adb:254-255` sets 229 = `T_BitString`; `chunk_02.adb:554-555`
sets 228 + `"t"`/`"f"` for `makeBoolAConst`). The Ada test never consults `val.type`, so any
of those constants under unary minus is mutated in place. v15+ use distinct `val.sval` /
`val.fval` / `val.bsval` members, so only v14 is affected.

Reproduction (`AST.V14.Parse`; also visible through the shallow arena versus the C oracle):
- `SELECT -'abc'` -> expected `ResTarget.val = A_Expr{kind AEXPR_OP, name [String "-"],
  rexpr A_Const{sval "abc", location 8}, location 7}`. Ada: `A_Const{sval "-abc",
  location 7}` (no `A_Expr`).
- `SELECT -B'101'` -> expected `A_Expr("-", A_Const{bsval "b101"})`; Ada: `A_Const{bsval
  "-b101"}`.
- `SELECT -TRUE` -> expected `A_Expr("-", A_Const{str "t"})` (v14 booleans are `T_String`);
  Ada: `A_Const{str "-t"}`.
- Control: `SELECT -1`, `SELECT -1.5`, `SELECT -'1'::int` are unaffected.

Existing coverage: the v14 corpus has binary `x - '...'` only (`float4.sql`, `money.sql`);
no unary minus directly before a string/bit/boolean literal.

### SQL-7: Grammar-level `ereport` errors lose `parser_errposition(@n)` and any `%s` arguments

Location: `sql/tools/generate_native_actions.py:600-609` (a `DoStmt` containing `errmsg` becomes
`raise Semantics.Parser_Error with Semantics.Text_Of (<format literal>)`); engine handling at
`sql/src/flyology-postgres-sql-native-engine.adb:128-129` (`Report_Error (Error,
Last_Location, False)`). Reference: `gram.y` `ereport(ERROR, (errcode(...), errmsg(...),
parser_errposition(@n)))`.

Severity: P2 (wrong cursor position on invalid input; one message keeps a literal `%s`).
Confidence: high.

Evidence: generated `action_catalog_chunk_08.adb:735-736`
```ada
               raise Semantics.Parser_Error with Semantics.Text_Of (Builders.Text
                  ("LIMIT #,# syntax is not supported"));
```
for `gram.y:13313-13317`, which carries `parser_errposition(@1)`. The only surviving
format literal is `action_helper_catalog_chunk_01.adb:515`
`"unrecognized JSON encoding: %s"`.

Reproduction:
- `SELECT 1 LIMIT 1, 2` (all majors): expected message `LIMIT #,# syntax is not supported`,
  cursor 10 (the `LIMIT` token). Ada: same message, cursor 20 (position of the end-of-input
  token that was read to finish `select_offset_value`).
- `SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)` (v16+): expected
  `unrecognized JSON encoding: foo`; Ada: `unrecognized JSON encoding: %s`.

Existing coverage: the corpus test only compares statements the oracle accepts, and the
differential list has no grammar-level `ereport` case.

### SQL-8: Non-EOF scanner diagnostics quote the rest of the input instead of the offending token

Location: `sql/src/flyology-postgres-sql-native-engine.adb:112-119`
(`Context := SQL (SQL'First + Offset .. SQL'Last)` for every `Scanner_Error`). Reference:
`scan.l` `scanner_yyerror`: `loc = scanbuf + *yylloc` where flex's `YY_DO_BEFORE_ACTION`
has written `'\0'` at `yytext + yyleng`, so the quoted context ends at the end of the
current match; only the `<<EOF>>` rules (unterminated literals/comments) quote through
the end of input, which is the case the differential tests cover.

Severity: P2 (diagnostic text). Confidence: high (mechanism verified in the vendored
`scan.c` `YY_DO_BEFORE_ACTION`; expected output matches upstream `strings.out`).

Reproduction (all majors unless noted; positions 1-based):
- `SELECT E'wrong: \U002FFFFF'` -> expected `invalid Unicode escape value at or near
  "\U002FFFFF"`; Ada: `invalid Unicode escape value at or near "\U002FFFFF'"` (trailing
  quote included; longer inputs quote everything after the escape).
- `SELECT $12345678901` -> expected `parameter number too large at or near "$12345678901"`;
  Ada quotes through end of input (same here, differs once anything follows, e.g.
  `SELECT $12345678901, 1`).
- `SELECT 1x, 2` (v15+) -> expected `trailing junk after numeric literal at or near "1x"`;
  Ada: `... at or near "1x, 2"`.
- `SELECT U&'\061'` -> PostgreSQL `str_udeescape` reports plain `invalid Unicode escape`
  (an `ereport` with `scanner_errposition`, no "at or near" suffix); Ada appends
  ` at or near "..."`.
- `SELECT ""` -> expected `zero-length delimited identifier at or near """"`, cursor 8
  (`SET_YYLLOC` at the opening quote); Ada: `Fail (Self, First, ...)` at
  `scanner.adb:433-434` uses the *closing* quote: cursor 9 and context `"`.
- `SELECT * FROM U&'t' UESCAPE '!'` -> expected `syntax error at or near "U&'t' UESCAPE
  '!'"` (`base_yylex` un-truncates the current token before scanning the escape string);
  Ada: `syntax error at or near "U&'t'"`.

Existing coverage: `differential_testing.adb` covers only the EOF-shaped scanner errors
(`'unterminated`, `$$unterminated`, `/* unterminated`), where both sides quote to end of
input.

### SQL-9: Diagnostic cursor positions are byte offsets; PostgreSQL reports character offsets

Location: `sql/src/flyology-postgres-sql-native-engine.adb:33` (`Error_Offset :=
Natural'Min (Offset, SQL'Length)` in bytes), `sql/src/flyology-postgres-sql-native-backend.adb:24`
and generated `ast_parser_v*.adb` (`Diagnostic_Position := Error_Offset + 1`). Reference:
`scan.l` `scanner_errposition`: `pos = pg_mbstrlen_with_len(yyextra->scanbuf, location) + 1;`
— every PostgreSQL cursor (`lexer_errposition`, `parser_errposition`) goes through this
byte-to-character conversion, and the oracle wrapper passes `cursorpos` through unchanged
(`flyology_pg18_wrapper.c:54`, `c_oracle.adb:66`).

Severity: P1 (documented comparison contract: README says arenas are compared "including ...
cursor positions"; any consumer that maps `Cursor_Position` onto the query text points at the
wrong character whenever non-ASCII text precedes the error). Confidence: high.

Reproduction (all majors): `SELECT 'é', 1 1` -> expected cursor 15 (characters: the second `1`
is the 15th character); Ada: 16 (byte offset 15 + 1, because `é` is two bytes). Similarly
`SELECT 'é', 'x` -> expected `unterminated quoted string at or near "'x"` cursor 13; Ada: 14.
ASCII-only inputs agree, which is why the existing error cases pass.

Existing coverage: none of the differential error cases contain non-ASCII text before the
error; the corpus test never compares diagnostics.

#### SQL-7 addendum: dropped format arguments are systematic, and the cleanest all-majors repro is `processCASbits`

A multi-line-tolerant search over the generated catalogs finds these literals raised verbatim:
`%s and %s options cannot be used together`, `%s constraints cannot be marked DEFERRABLE`,
`%s constraints cannot be marked NO INHERIT`, `%s constraints cannot be marked NOT VALID`,
`%s constraints cannot be marked ENFORCED` / `NOT ENFORCED` (v18),
`a column list with %s is only supported for ON DELETE actions`,
`column number must be in range from 1 to %d`, `unrecognized JSON encoding: %s` (v17, v18),
and `unrecognized role option "%s"` (all majors).

Reproduction (all majors): `CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)`.
`gram.y` (v18:4203-4211) calls `processCASbits($5, @5, "CHECK", ...)`, which reports
`CHECK constraints cannot be marked DEFERRABLE` with `parser_errposition(location)` =
`@5` = the `DEFERRABLE` token: expected message `CHECK constraints cannot be marked
DEFERRABLE`, cursor 38. Ada: message `%s constraints cannot be marked DEFERRABLE`, cursor 49
(the `)` lookahead that closed `ConstraintAttributeSpec`).
Also `CREATE ROLE r WITH foo` -> expected `unrecognized role option "foo"`, cursor 20; Ada:
`unrecognized role option "%s"`, cursor at the end-of-input token (21).

## Areas reviewed with no findings

- Keyword recognition and case folding: ASCII-only downcasing (`Lowercase`) matches
  `ScanKeywordLookup`/`downcase_identifier` for the UTF-8 server encoding; keyword lookup
  happens on the untruncated text as in `scan.l`.
- Identifier truncation to 63 bytes (`Truncated_Identifier`) matches `pg_mbcliplen` for valid
  UTF-8, including 2-, 3-, and 4-byte characters straddling the limit; quoted and U& identifiers
  are truncated after de-escaping as in `parser.c`.
- Quoted identifiers with doubled quotes, `U&"..."` and `U&'...'` de-escaping (4- and 6-digit
  forms, doubled escape, surrogate pairs, dangling first surrogate, second-without-first,
  non-hex digits, short escapes): `Unicode_Decode` mirrors `str_udeescape` branch for branch,
  including the `in - str + position + 3` positions. UESCAPE lookahead consumption and
  "UESCAPE must be followed by a simple string literal" match `base_yylex`.
- String continuation across newline-containing whitespace only (`xqs` state machine, `Less
  (First, 0)` push-back), `''` doubling, `E''` simple escapes `\b \f \n \r \t`, `\uXXXX` /
  `\UXXXXXXXX` below 2**31, surrogate pairing and its error cases, `standard_conforming_strings
  = off` routing of `'...'` into the escape state, and `backslash_quote` enforcement of `\'`.
- Dollar quoting: tag matching, `$tag$...$junk$tag$` partial-delimiter push-back, `$1` versus
  `$a$`, `$` alone, nested delimiters; `Dollar_Failed` returns `$` like `dolqfailed`.
- Bit and hex string literals (`B''`, `X''`): the scanner accepts any non-quote content and
  prefixes `b`/`x` exactly as `scan.l`; digit validity is not a scanner concern in PostgreSQL.
- Numeric literals: `1.`, `.1`, exponents, `1..2` push-back, v14 `realfail1/2` and v15+
  `realfail` push-back counts, `integer_junk`/`numeric_junk`/`real_junk`/`param_junk` errors
  via per-version action classification, PG16+ underscores and `0x/0o/0b` (Ada mirrors
  `pg_strtoint32_safe`: value computed with underscores skipped, `ICONST` iff it fits int32,
  else `FCONST` with the original text), overflow-safe accumulation in `Integer_64`,
  `2147483647` -> ICONST, `2147483648` -> FCONST, `-2147483648` through `doNegateFloat`.
- Operators: comment-start truncation (`/*`, `--`), the trailing `+`/`-` rule with the
  `~!@#^&|`?%` exemption, the single-character self fallback, the two-character
  `=> >= <= <> !=` fallback (the hard-coded `Actions (49..52)` indices resolve to
  EQUALS_GREATER/LESS_EQUALS/GREATER_EQUALS/NOT_EQUALS = 271/272/273/274 in all five
  generated tables), and "operator too long" at 64.
- Parameters `$n`: overflow check matches `strtoint` ERANGE; `$0` accepted by both.
- Comments: nested `/* */` depth tracking, error location at the outermost start,
  `--` to end of line, comment-start inside operators; comment tokens are filtered in
  `Next_Token`.
- `N'...'` (`Nchar_Start`) and `U&` fallback (`Unicode_Failed`) push-back and token values.
- NUL bytes: rejected up front (`sql.adb:46-53`, generated owned `Parse`); the vendored
  flex tables map NUL to index 256, so byte 0x01 is an ordinary transition in both.
- DFA walk (`native-dfa.adb`): longest-match with last-accepting backtrack mirrors flex's
  `-CF` `yy_transition` scheme; start-condition constants 1..23 match `yy_start_state_list`
  pairs.
- LALR engine: `yypact_value_is_default` skip of lookahead, `yycheck` fallback to
  `yydefact`, `YYTABLE_NINF` error, `YYFINAL` accept on shifting EOF, out-of-range tokens
  mapped to `YYUNDEF` (2), default `$$ = $1`, absence of error recovery (PostgreSQL has no
  `error` productions).
- Lookahead token rewriting (`NOT_LA`, `NULLS_LA`, `WITH_LA`, `WITHOUT_LA`, `FORMAT_LA`) and
  the restore of the current token's location and text for syntax-error reporting.
- Syntax-error text (`syntax error at or near "<token>"` / `at end of input`) for
  ASCII inputs: token-text extraction matches flex's hold-character NUL and the
  `lookahead_end` truncation in `base_yylex`.
- Builders: `lappend`, `lcons`, `list_concat` (in place, copy when the left list is NIL),
  `list_make*`, `list_copy_tail`, `lnext`/`list_nth_cell`; `list_truncate`/`list_delete_*`
  return fresh lists where PostgreSQL mutates in place, but the only grammar uses
  (`makeColumnRef`, `SplitColQualList`) never observe the original list afterwards.
- Semantics helpers: `doNegateFloat` sign handling, `strcmp` (unsigned byte order),
  `psprintf` formats, `makeRawStmt`/`updateRawStmtEnd`, `FETCH ALL` -> `Integer_64` 
  9223372036854775807.
- Converters (shallow arena) and the generated owned parser: default-value elision
  (empty text, zero, enum wire 0) matches protobuf presence semantics used by the oracle;
  the v14 `Value`-union aliasing (`val.val.str` -> `sval`/`fval`/`bsval`) is handled in
  `Source_Field`.
- Owned AST ownership: `Owned_Syntax_Tree` is `Limited_Controlled`; `Parse` clears any
  previous graph first, every `Convert_*` releases partially built children on exception,
  and `Finalize` -> `Clear` -> recursive `Release`; no Adjust exists because the tree type is
  limited. No double-free or leak-on-error path found.
- Version wiring: PG14 rejects non-default `Parse_Options` (`Unsupported_Parse_Options`);
  parse-mode initial tokens map to `MODE_*` tokens.

## Observations not counted

- `YYLLOC_DEFAULT` differs by major (v14-v17: `@$ = @1`, possibly -1; v18: first non-negative
  RHS location). The Ada LALR applies the v18 rule to every major. I could not find a
  v14-v17 action that consumes `@n` of a nonterminal whose leading symbol can reduce to empty
  (all `location` assignments and `parser_errposition` uses I traced bottom out at a terminal),
  so the difference appears unobservable today, but a future grammar could expose it.
- The generator hard-codes flex rule numbers 1..56 to action kinds for every major
  (`generate_native_parser.py:139-169`). The five generated tables agree at 46..56 and the
  multi-major corpus exercises every rule kind, so this holds for the vendored sources; it is
  a maintenance hazard, not a current defect.
- `Parse_Options.Escape_String_Warning` is never passed to the scanner. PostgreSQL only emits
  a WARNING for it, so no parse result differs.
- Invalid UTF-8 in the *input* (not produced by escapes): PostgreSQL's identifier clipping
  (`pg_mbcliplen`) and `str_udeescape`'s final `pg_verifymbstr` treat stray continuation bytes
  differently from the Ada scanner, but pg_query itself does not validate input encoding
  either, so there is no single reference behaviour to compare against.
- `Actions (49..52)` are indexed by absolute rule number inside the shared scanner body;
  correct today, fragile by construction (same hazard as the generator mapping).
- `Semantics.Invoke "pg_strcasecmp"` uses Latin-1-aware `To_Lower`; the grammar only tests its
  result for equality with ASCII literals, so the sign difference is unobservable.
- `Builders.Field` returns `No_Value` for unknown members, so mis-spelled member paths in
  generated helpers would silently read as absent rather than failing loudly; no instance found.
