with Flyology.Postgres.SQL;

private package Flyology.Postgres.SQL_Backends is

   type Parse_Access is access procedure
     (Text    : String;
      Options : SQL.Parse_Options;
      Result  : in out SQL.Syntax_Tree);

   function Register
     (Version : SQL.Major_Version;
      Parse   : not null Parse_Access) return Boolean;

   procedure Parse
     (Text    : String;
      Version : SQL.Major_Version;
      Result  : in out SQL.Syntax_Tree;
      Options : SQL.Parse_Options);

end Flyology.Postgres.SQL_Backends;
