package body Flyology.Postgres.SQL.Views is

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options) is
   begin
      Flyology.Postgres.SQL.Parse (SQL, Version, Result, Options);
   end Parse;

   function Is_Valid (Tree : Syntax_Tree) return Boolean is
     (Flyology.Postgres.SQL.Is_Valid (Tree));

   function Version (Tree : Syntax_Tree) return Major_Version is
     (Flyology.Postgres.SQL.Version (Tree));

   function Source (Tree : Syntax_Tree) return String is
     (Flyology.Postgres.SQL.Source (Tree));

   function Error (Tree : Syntax_Tree) return Diagnostic is
     (Flyology.Postgres.SQL.Error (Tree));

   function Message (Item : Diagnostic) return String is
     (Flyology.Postgres.SQL.Message (Item));

   function Cursor_Position (Item : Diagnostic) return Natural is
     (Flyology.Postgres.SQL.Cursor_Position (Item));

end Flyology.Postgres.SQL.Views;
