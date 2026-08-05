with Ada.Containers;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.AST.V14;
with Flyology.Postgres.SQL.AST.V16;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.Views;
with Flyology.Postgres.SQL.Views.V14;
with Flyology.Postgres.SQL.Views.V16;
with Flyology.Postgres.SQL.Views.V18;
pragma Elaborate_All (Flyology.Postgres.SQL.Views.V14);
pragma Elaborate_All (Flyology.Postgres.SQL.Views.V16);
pragma Elaborate_All (Flyology.Postgres.SQL.Views.V18);

procedure Multi_Version_Example is
   package SQL renames Flyology.Postgres.SQL;
   package AST_14 renames Flyology.Postgres.SQL.AST.V14;
   package AST_16 renames Flyology.Postgres.SQL.AST.V16;
   package AST_18 renames Flyology.Postgres.SQL.AST.V18;
   package Views renames Flyology.Postgres.SQL.Views;
   Views_14_Size : constant Natural :=
     Flyology.Postgres.SQL.Views.V14.Node_Reference'Size;
   Views_16_Size : constant Natural :=
     Flyology.Postgres.SQL.Views.V16.Node_Reference'Size;
   Views_18_Size : constant Natural :=
     Flyology.Postgres.SQL.Views.V18.Node_Reference'Size;
   pragma Unreferenced (Views_14_Size, Views_16_Size, Views_18_Size);

   use type Ada.Containers.Count_Type;
   use type SQL.Major_Version;

   Owned_14 : AST_14.Owned_Syntax_Tree;
   Owned_16 : AST_16.Owned_Syntax_Tree;
   Owned_18 : AST_18.Owned_Syntax_Tree;
begin
   AST_14.Parse ("SELECT 14", Owned_14);
   AST_16.Parse ("SELECT 16", Owned_16);
   AST_18.Parse ("SELECT 18", Owned_18);

   if not Owned_14.Valid or else Owned_14.Root.Statements.Length /= 1
     or else not Owned_16.Valid or else Owned_16.Root.Statements.Length /= 1
     or else not Owned_18.Valid or else Owned_18.Root.Statements.Length /= 1
   then
      raise Program_Error with "coexisting owned parsers failed";
   end if;

   for Version in
     SQL.Major_Version range SQL.PostgreSQL_14 .. SQL.PostgreSQL_18
   loop
      if Version /= SQL.PostgreSQL_15 and then Version /= SQL.PostgreSQL_17 then
         declare
            Arena : Views.Syntax_Tree;
         begin
            Views.Parse ("SELECT 1", Version, Arena);
            if not Views.Is_Valid (Arena) then
               raise Program_Error with
                 "coexisting shallow parser failed for " & Version'Image;
            end if;
         end;
      end if;
   end loop;
end Multi_Version_Example;
