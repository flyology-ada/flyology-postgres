with Ada.Containers;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.Views;
with Flyology.Postgres.SQL.Views.V18;
pragma Elaborate_All (Flyology.Postgres.SQL.Views.V18);

procedure V18_Owned_Example is
   package AST renames Flyology.Postgres.SQL.AST.V18;
   package SQL renames Flyology.Postgres.SQL;
   package Views renames Flyology.Postgres.SQL.Views;
   V18_View_Size : constant Natural :=
     Flyology.Postgres.SQL.Views.V18.Node_Reference'Size;
   pragma Unreferenced (V18_View_Size);
   use type Ada.Containers.Count_Type;

   Tree  : AST.Owned_Syntax_Tree;
   Arena : Views.Syntax_Tree;
begin
   AST.Parse ("SELECT 1", Tree);
   if not Tree.Valid or else Tree.Root.Statements.Length /= 1 then
      raise Program_Error with "PostgreSQL 18 selective parser failed";
   end if;

   Views.Parse ("SELECT 1", SQL.PostgreSQL_18, Arena);
   if not Views.Is_Valid (Arena) then
      raise Program_Error with "PostgreSQL 18 shallow dispatcher failed";
   end if;
end V18_Owned_Example;
