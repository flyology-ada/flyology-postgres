private package Flyology.Postgres.SQL.Native is

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options);

end Flyology.Postgres.SQL.Native;
