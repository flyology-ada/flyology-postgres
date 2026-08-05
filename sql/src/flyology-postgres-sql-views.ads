package Flyology.Postgres.SQL.Views is

   subtype Diagnostic is Flyology.Postgres.SQL.Diagnostic;
   subtype Syntax_Tree is Flyology.Postgres.SQL.Syntax_Tree;

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options);

   function Is_Valid (Tree : Syntax_Tree) return Boolean;
   function Version (Tree : Syntax_Tree) return Major_Version
     with Pre => Is_Valid (Tree);
   function Source (Tree : Syntax_Tree) return String;
   function Error (Tree : Syntax_Tree) return Diagnostic
     with Pre => not Is_Valid (Tree);
   function Message (Item : Diagnostic) return String;
   function Cursor_Position (Item : Diagnostic) return Natural;

end Flyology.Postgres.SQL.Views;
