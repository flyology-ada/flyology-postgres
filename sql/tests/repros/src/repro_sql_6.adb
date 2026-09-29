with Flyology.Postgres.SQL.Repro_Oracle;
with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_6 is
   --  SQL-6: v14 gram.y doNegate() folds the sign into the constant only
   --  when con->val.type is T_Integer or T_Float; every other constant gets
   --  makeSimpleA_Expr(AEXPR_OP, "-", NULL, n, location).  The v14 Value
   --  union keeps T_Float, T_String and T_BitString payloads in the same
   --  val.val.str member, and the Ada doNegate tests only that the member
   --  holds text, so string and bit-string constants are negated in place
   --  and no A_Expr node is built.  v15+ use distinct sval/fval/bsval
   --  members and are unaffected.

   package Oracle renames Flyology.Postgres.SQL.Repro_Oracle;

   V14 : constant SQL.Major_Version := SQL.PostgreSQL_14;

   function Folded (Negated_Text, Literal_Text : String) return Boolean is
      A, B : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Native (Negated_Text, V14, A);
      Oracle.Parse_Native (Literal_Text, V14, B);
      return Oracle.First_Difference (A, B) = "";
   end Folded;

   procedure Expect_Match (Text : String) is
   begin
      Note ("v14 " & Text & " native-vs-C: [" & Oracle_Difference (Text, V14) & "]");
      Check (Oracle_Difference (Text, V14) = "",
             "v14: " & Text & " matches the C oracle");
   end Expect_Match;
begin
   Expect_Match ("SELECT -'abc'");
   Expect_Match ("SELECT -B'101'");

   Check (not Folded ("SELECT -'abc'", "SELECT '-abc'"),
          "v14: -'abc' is not the same tree as the literal '-abc'");

   --  Controls that must keep working.
   Expect_Match ("SELECT -1");
   Expect_Match ("SELECT -1.5");
   --  v14 makeBoolAConst wraps the A_Const in a TypeCast, so doNegate never
   --  sees an A_Const here and both sides build an A_Expr.
   Expect_Match ("SELECT -TRUE");

   for Version in SQL.Major_Version range SQL.PostgreSQL_15 .. SQL.PostgreSQL_18 loop
      Check (Oracle_Difference ("SELECT -'abc'", Version) = "",
             Version'Image & ": control -'abc' matches the C oracle");
      Check (Oracle_Difference ("SELECT -B'101'", Version) = "",
             Version'Image & ": control -B'101' matches the C oracle");
   end loop;

   Finish;
end Repro_SQL_6;
