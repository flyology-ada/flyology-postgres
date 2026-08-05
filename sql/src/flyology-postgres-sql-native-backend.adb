with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Flyology.Postgres.SQL.Native.Converters;
package body Flyology.Postgres.SQL.Native.Backend is

   procedure Parse
     (Text    : String;
      Options : Parse_Options;
      Result  : in out Syntax_Tree)
   is
      Build        : aliased Builders.Builder;
      Native_Root  : Builders.Dynamic_Value;
      Error_Offset : Natural := 0;
      Success      : Boolean := False;
      Failure      : Unbounded_String;
   begin
      Parse_Native
        (Text, Options, Build, Native_Root, Error_Offset, Failure, Success);

      if not Success then
         Result.Parse_Error :=
           (Text     => Failure,
            Position => (if Text'Length = 0 then 0 else Error_Offset + 1));
         return;
      end if;

      Load (Result, Build, Native_Root, Result.Root);
      Result.Valid := True;
   exception
      when Error : Converters.Converter_Error =>
         raise Parser_Backend_Error with
           "native PostgreSQL AST conversion failed: " &
           Ada.Exceptions.Exception_Message (Error);
   end Parse;

end Flyology.Postgres.SQL.Native.Backend;
