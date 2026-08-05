private package Flyology.Postgres.SQL.C_Oracle is

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options);

end Flyology.Postgres.SQL.C_Oracle;
