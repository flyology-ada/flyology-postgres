with Flyology.Postgres.SQL.Native;

package body Flyology.Postgres.SQL is

   function Message (Item : Diagnostic) return String is
     (To_String (Item.Text));

   function Cursor_Position (Item : Diagnostic) return Natural is
     (Item.Position);

   function Is_Valid (Tree : Syntax_Tree) return Boolean is (Tree.Valid);

   function Version (Tree : Syntax_Tree) return Major_Version is
     (Tree.Parsed_Version);

   function Source (Tree : Syntax_Tree) return String is
     (To_String (Tree.Input));

   function Supports_Parse_Options (Version : Major_Version) return Boolean is
     (Version /= PostgreSQL_14);

   function Error (Tree : Syntax_Tree) return Diagnostic is
     (Tree.Parse_Error);

   procedure Reset (Tree : in out Syntax_Tree) is
   begin
      Tree.Valid := False;
      Tree.Root := No_Value;
      Tree.Parse_Error := (others => <>);
      Tree.Values.Clear;
      Tree.Members.Clear;
      Tree.Elements.Clear;
   end Reset;

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options)
   is
   begin
      Reset (Result);
      Result.Input := To_Unbounded_String (SQL);
      Result.Parsed_Version := Version;

      for Index in SQL'Range loop
         if SQL (Index) = Character'Val (0) then
            Result.Parse_Error :=
              (Text => To_Unbounded_String ("SQL input contains an embedded NUL byte"),
               Position => Index - SQL'First + 1);
            return;
         end if;
      end loop;
      if not Supports_Parse_Options (Version)
        and then Options /= Default_Options
      then
         raise Unsupported_Parse_Options with
           "PostgreSQL 14's native parser supports only Default_Options";
      end if;
      Native.Parse (SQL, Version, Result, Options);
   end Parse;

end Flyology.Postgres.SQL;
