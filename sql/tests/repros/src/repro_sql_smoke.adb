with Flyology.Postgres.SQL.AST.V18;
with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_Smoke is
   package V18 renames Flyology.Postgres.SQL.AST.V18;
   Tree : V18.Owned_Syntax_Tree;
begin
   V18.Parse ("SELECT 1", Tree);
   Check (Tree.Valid, "owned AST parses SELECT 1");
   Check (Native_Error ("SELECT 1", SQL.PostgreSQL_18) = "",
          "native arena parses SELECT 1");
   Check (Oracle_Difference ("SELECT 1", SQL.PostgreSQL_18) = "",
          "native arena and C oracle agree on SELECT 1");
   Check (Native_Error ("SELEC 1", SQL.PostgreSQL_18) /= "",
          "native arena reports a syntax error");
   Note ("native: " & Native_Error ("SELEC 1", SQL.PostgreSQL_18)
         & " @" & Native_Error_Position ("SELEC 1", SQL.PostgreSQL_18)'Image);
   Note ("oracle: " & Oracle_Error ("SELEC 1", SQL.PostgreSQL_18)
         & " @" & Oracle_Error_Position ("SELEC 1", SQL.PostgreSQL_18)'Image);
   Finish;
end Repro_SQL_Smoke;
