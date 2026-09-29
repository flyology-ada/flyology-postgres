package Flyology.Postgres.SQL.Repro_Oracle is
   --  Thin child-package bridge so reproduction programs outside the
   --  Flyology.Postgres.SQL hierarchy can reach the private C oracle and
   --  arena comparison helpers.

   procedure Parse_Native
     (Text    : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options);

   procedure Parse_Oracle
     (Text    : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options);

   function First_Difference (Left, Right : Syntax_Tree) return String;

end Flyology.Postgres.SQL.Repro_Oracle;
