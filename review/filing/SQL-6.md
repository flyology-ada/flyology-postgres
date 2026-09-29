Title: On PostgreSQL 14, SELECT -'abc' folds the sign into the constant instead of building an A_Expr
Labels: bug
Refs: none

## Summary

The Ada `doNegate` decides how to negate an `A_Const` by probing member paths, and treats any constant whose `val.val.str` member holds text as a float. On PostgreSQL 14 the `Value` union stores float, string and bit-string payloads in that same member, so string and bit-string constants take the float branch and the sign is folded into the literal in place. PostgreSQL 14's `gram.y` folds the sign only for `T_Integer` and `T_Float` and builds an `A_Expr` for everything else. `SELECT -'abc'` therefore yields an `A_Const` with `sval` `"-abc"` where PostgreSQL yields `A_Expr("-", A_Const{sval "abc"})`, and the result is indistinguishable from the plain literal `SELECT '-abc'`.

## Problem

Commit `6f496f5`.

The Ada implementation probes members rather than the constant's type tag (`sql/src/flyology-postgres-sql-native-semantics.adb:330-360`):

```ada
      elsif Name = "doNegate" then
         declare
            Item     : constant Builders.Dynamic_Value := Argument (1);
            Integer_14 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.val.ival");
            Integer_15 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.ival.ival");
            Float_14 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.val.str");
            Float_15 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.fval.fval");
         begin
            ...
               elsif Float_14.Kind = Builders.Text_Value then
                  Build.Set_Field (Item, "val.val.str", Negated (Float_14));
                  return Item;
```

`val.val.str` is the PostgreSQL 14 `Value` union member shared by `T_Float`, `T_String` and `T_BitString`, so the `Float_14` branch fires for all three. From PostgreSQL 15 the payloads live in distinct `sval`, `fval` and `bsval` members, and the `Float_15` probe selects correctly.

PostgreSQL 14 gates the in-place negation on the type tag (`sql/backends/v14/vendor/native_source/backend/parser/gram.y:16877-16900`):

```c
static Node *
doNegate(Node *n, int location)
{
	if (IsA(n, A_Const))
	{
		A_Const *con = (A_Const *)n;

		/* report the constant's location as that of the '-' sign */
		con->location = location;

		if (con->val.type == T_Integer)
		{
			con->val.val.ival = -con->val.val.ival;
			return n;
		}
		if (con->val.type == T_Float)
		{
			doNegateFloat(&con->val);
			return n;
		}
	}

	return (Node *) makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location);
}
```

`SELECT -TRUE` is not affected: PostgreSQL 14's `makeBoolAConst` returns a `TypeCast` wrapping the constant, so `doNegate` never receives an `A_Const` there and both parsers build the `A_Expr`.

The native-versus-oracle corpus has no unary minus applied to a literal at all (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:40-75`), and the PostgreSQL 14 regression corpus has binary subtraction against a string literal only, never a unary minus directly before one. The owned corpus compares the owned result against `Parse_Baseline`, which runs the same native semantic actions, so both sides of that comparison fold the sign identically.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 and compares the two arenas, then parses `SELECT '-abc'` natively and checks whether the negated form produced the same tree as that plain literal. Integer, float and boolean negation on PostgreSQL 14 and the same statements on PostgreSQL 15 through 18 are controls.

```ada
   Expect_Match ("SELECT -'abc'");
   Expect_Match ("SELECT -B'101'");

   Check (not Folded ("SELECT -'abc'", "SELECT '-abc'"),
          "v14: -'abc' is not the same tree as the literal '-abc'");
```

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

The third failure is the consequence for a consumer: on PostgreSQL 14 the tree for `SELECT -'abc'` is byte-for-byte the tree for `SELECT '-abc'`, so the unary operator has disappeared from the parse result.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

On PostgreSQL 14, `SELECT -'abc'` must produce `A_Expr{kind AEXPR_OP, name "-", rexpr A_Const{sval "abc"}}` and `SELECT -B'101'` must produce the same shape over the bit-string constant, matching `makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location)` at `sql/backends/v14/vendor/native_source/backend/parser/gram.y:16899`. Only integer and float constants may be negated in place.

## Suggested treatment

Make the `doNegate` branch at `sql/src/flyology-postgres-sql-native-semantics.adb:330-360` test the constant's type tag rather than which member holds text. On PostgreSQL 14 the tag is `con->val.type`, which the builder carries alongside the union members, so the float branch can be gated on it being `T_Float`; the `Float_15` probe on the later majors is already unambiguous because `fval` is distinct from `sval` and `bsval`. Probing `val.val.str` cannot distinguish the three PostgreSQL 14 payloads and should not be the discriminator.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb`, which has no unary-minus entry, as `Check ("SELECT -'abc'")` and `Check ("SELECT -B'101'")` on all majors, together with `Check ("SELECT -1")` and `Check ("SELECT -1.5")` so a fix cannot regress the folding that is correct. The spike is that test. No existing test asserts the current behaviour.

## Severity

A silently wrong AST for valid SQL: the unary operator is absent from the parse result and the tree is identical to the one for a literal with a leading minus sign, so a consumer that rewrites or analyses the statement cannot recover the difference and no diagnostic is produced. It needs a unary minus applied directly to a string or bit-string literal, which is not common SQL. PostgreSQL 14 only.
