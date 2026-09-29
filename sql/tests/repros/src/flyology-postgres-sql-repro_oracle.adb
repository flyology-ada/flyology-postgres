with Flyology.Postgres.SQL.All_Versions;
pragma Elaborate_All (Flyology.Postgres.SQL.All_Versions);
with Flyology.Postgres.SQL.C_Oracle;
with Flyology.Postgres.SQL.Internals;

package body Flyology.Postgres.SQL.Repro_Oracle is

   procedure Parse_Native
     (Text    : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options) is
   begin
      Parse (Text, Version, Result, Options);
   end Parse_Native;

   procedure Parse_Oracle
     (Text    : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options) is
   begin
      C_Oracle.Parse (Text, Version, Result, Options);
   end Parse_Oracle;

   function First_Difference (Left, Right : Syntax_Tree) return String is
   begin
      return Internals.First_Difference (Left, Right);
   end First_Difference;

end Flyology.Postgres.SQL.Repro_Oracle;
