with Flyology.Postgres.SQL.Repro_Oracle;
with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_1 is
   --  SQL-1: E'\v' must unescape to vertical tab (0x0B) on PostgreSQL 17 and
   --  18 (scan.l unescape_single_char gained "case 'v': return '\v';" in v17).
   --  The shared Ada scanner has no 'v' case, so it falls through to
   --  "when others => Value" and stores the letter 'v'.

   package Oracle renames Flyology.Postgres.SQL.Repro_Oracle;

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
      Note (Version'Image & " native-vs-C: ["
            & Oracle_Difference (Escaped, Version) & "]");
      Check (Oracle_Difference (Escaped, Version) = "",
             Version'Image & ": E'a\vb' matches the C oracle");
      Check (not Folds_To_Letter_V (Version),
             Version'Image & ": E'a\vb' is not the same tree as 'avb'");
   end loop;

   --  Control: v14..v16 scan.l has no 'v' case, so the letter is correct.
   for Version in SQL.Major_Version range SQL.PostgreSQL_14 .. SQL.PostgreSQL_16 loop
      Check (Oracle_Difference (Escaped, Version) = "",
             Version'Image & ": E'a\vb' matches the C oracle (control)");
      Check (Folds_To_Letter_V (Version),
             Version'Image & ": E'a\vb' equals 'avb' before v17 (control)");
   end loop;

   Finish;
end Repro_SQL_1;
