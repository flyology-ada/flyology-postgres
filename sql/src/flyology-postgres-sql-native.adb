with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.Converters;
with Flyology.Postgres.SQL.Native.Schema_V14;
with Flyology.Postgres.SQL.Native.Schema_V15;
with Flyology.Postgres.SQL.Native.Schema_V16;
with Flyology.Postgres.SQL.Native.Schema_V17;
with Flyology.Postgres.SQL.Native.Schema_V18;
with Flyology.Postgres.SQL.Native.Version_V14;
with Flyology.Postgres.SQL.Native.Version_V15;
with Flyology.Postgres.SQL.Native.Version_V16;
with Flyology.Postgres.SQL.Native.Version_V17;
with Flyology.Postgres.SQL.Native.Version_V18;

package body Flyology.Postgres.SQL.Native is

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options)
   is
      Build        : aliased Builders.Builder;
      Native_Root  : Builders.Dynamic_Value;
      Error_Offset : Natural := 0;
      Success      : Boolean := False;
      Failure      : Unbounded_String;
   begin
      case Version is
         when PostgreSQL_14 =>
            Version_V14.Parse
              (SQL, Options, Build, Native_Root, Error_Offset,
               Failure, Success);
         when PostgreSQL_15 =>
            Version_V15.Parse
              (SQL, Options, Build, Native_Root, Error_Offset,
               Failure, Success);
         when PostgreSQL_16 =>
            Version_V16.Parse
              (SQL, Options, Build, Native_Root, Error_Offset,
               Failure, Success);
         when PostgreSQL_17 =>
            Version_V17.Parse
              (SQL, Options, Build, Native_Root, Error_Offset,
               Failure, Success);
         when PostgreSQL_18 =>
            Version_V18.Parse
              (SQL, Options, Build, Native_Root, Error_Offset,
               Failure, Success);
      end case;

      if not Success then
         Result.Parse_Error :=
           (Text     => Failure,
            Position => (if SQL'Length = 0 then 0 else Error_Offset + 1));
         return;
      end if;

      case Version is
         when PostgreSQL_14 =>
            Converters.Load
              (Result, Build, Native_Root, Schema_V14.Version_Number,
               Schema_V14.Node_Message, Schema_V14.List_Message,
               Schema_V14.Raw_Stmt_Message, Schema_V14.Messages,
               Schema_V14.Fields, Schema_V14.Enums, Schema_V14.Enum_Values,
               Result.Root);
         when PostgreSQL_15 =>
            Converters.Load
              (Result, Build, Native_Root, Schema_V15.Version_Number,
               Schema_V15.Node_Message, Schema_V15.List_Message,
               Schema_V15.Raw_Stmt_Message, Schema_V15.Messages,
               Schema_V15.Fields, Schema_V15.Enums, Schema_V15.Enum_Values,
               Result.Root);
         when PostgreSQL_16 =>
            Converters.Load
              (Result, Build, Native_Root, Schema_V16.Version_Number,
               Schema_V16.Node_Message, Schema_V16.List_Message,
               Schema_V16.Raw_Stmt_Message, Schema_V16.Messages,
               Schema_V16.Fields, Schema_V16.Enums, Schema_V16.Enum_Values,
               Result.Root);
         when PostgreSQL_17 =>
            Converters.Load
              (Result, Build, Native_Root, Schema_V17.Version_Number,
               Schema_V17.Node_Message, Schema_V17.List_Message,
               Schema_V17.Raw_Stmt_Message, Schema_V17.Messages,
               Schema_V17.Fields, Schema_V17.Enums, Schema_V17.Enum_Values,
               Result.Root);
         when PostgreSQL_18 =>
            Converters.Load
              (Result, Build, Native_Root, Schema_V18.Version_Number,
               Schema_V18.Node_Message, Schema_V18.List_Message,
               Schema_V18.Raw_Stmt_Message, Schema_V18.Messages,
               Schema_V18.Fields, Schema_V18.Enums, Schema_V18.Enum_Values,
               Result.Root);
      end case;
      Result.Valid := True;
   exception
      when Error : Converters.Converter_Error =>
         raise Parser_Backend_Error with
           "native PostgreSQL AST conversion failed: " &
           Ada.Exceptions.Exception_Message (Error);
   end Parse;

end Flyology.Postgres.SQL.Native;
