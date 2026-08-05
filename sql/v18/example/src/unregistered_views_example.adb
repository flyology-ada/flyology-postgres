with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.Views;

procedure Unregistered_Views_Example is
   package SQL renames Flyology.Postgres.SQL;
   package Views renames Flyology.Postgres.SQL.Views;

   Tree : Views.Syntax_Tree;
begin
   begin
      Views.Parse ("SELECT 1", SQL.PostgreSQL_18, Tree);
      raise Program_Error with "an unregistered parser was accepted";
   exception
      when SQL.Parser_Backend_Error =>
         null;
   end;
end Unregistered_Views_Example;
