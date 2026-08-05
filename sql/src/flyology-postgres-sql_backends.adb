package body Flyology.Postgres.SQL_Backends is

   type Backend_Array is array (SQL.Major_Version) of Parse_Access;
   Backends : Backend_Array := (others => null);

   function Register
     (Version : SQL.Major_Version;
      Parse   : not null Parse_Access) return Boolean is
   begin
      if Backends (Version) /= null
        and then Backends (Version) /= Parse
      then
         raise Program_Error with
           "a different SQL parser backend is already registered for " &
           SQL.Major_Version'Image (Version);
      end if;
      Backends (Version) := Parse;
      return True;
   end Register;

   procedure Parse
     (Text    : String;
      Version : SQL.Major_Version;
      Result  : in out SQL.Syntax_Tree;
      Options : SQL.Parse_Options)
   is
      Backend : constant Parse_Access := Backends (Version);
   begin
      if Backend = null then
         raise SQL.Parser_Backend_Error with
           "the " & SQL.Major_Version'Image (Version) &
           " SQL parser backend is not linked; depend on the matching " &
           "flyology_postgres_sql_vNN crate, with its versioned AST or " &
           "Views package, or with Flyology.Postgres.SQL.All_Versions " &
           "through the compatibility umbrella";
      end if;
      Backend.all (Text, Options, Result);
   end Parse;

end Flyology.Postgres.SQL_Backends;
