with Ada.Exceptions;
with System;

with Flyology.Postgres.SQL.Backends;
with Flyology.Postgres.SQL.Decoders;
with Flyology.Postgres.SQL.Decoder_V14;
with Flyology.Postgres.SQL.Decoder_V15;
with Flyology.Postgres.SQL.Decoder_V16;
with Flyology.Postgres.SQL.Decoder_V17;
with Flyology.Postgres.SQL.Decoder_V18;

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

   procedure Decode
     (Tree    : in out Syntax_Tree;
      Version : Major_Version;
      Data    : System.Address;
      Length  : Natural) is
   begin
      case Version is
         when PostgreSQL_14 => Decoder_V14.Load (Tree, Data, Length);
         when PostgreSQL_15 => Decoder_V15.Load (Tree, Data, Length);
         when PostgreSQL_16 => Decoder_V16.Load (Tree, Data, Length);
         when PostgreSQL_17 => Decoder_V17.Load (Tree, Data, Length);
         when PostgreSQL_18 => Decoder_V18.Load (Tree, Data, Length);
      end case;
   end Decode;

   procedure Parse
     (SQL     : String;
      Version : Major_Version;
      Result  : in out Syntax_Tree;
      Options : Parse_Options := Default_Options)
   is
      Backend : Backends.Backend_Handle;
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

      Backends.Start (Backend, SQL, Version, Options);
      declare
         Error_Text : constant Unbounded_String := Backends.Error_Message (Backend);
      begin
         if Length (Error_Text) /= 0 then
            Result.Parse_Error :=
              (Text => Error_Text, Position => Backends.Error_Position (Backend));
            Backends.Release (Backend);
            return;
         end if;
      end;

      if Backends.Byte_Length (Backend) = 0 then
         raise Parser_Backend_Error with
           "PostgreSQL backend returned neither protobuf data nor a diagnostic";
      end if;
      Decode
        (Result, Version, Backends.Data (Backend), Backends.Byte_Length (Backend));
      Backends.Release (Backend);
      Result.Valid := True;
   exception
      when Error : Decoders.Decoder_Error =>
         Backends.Release (Backend);
         Reset (Result);
         Result.Input := To_Unbounded_String (SQL);
         Result.Parsed_Version := Version;
         raise Parser_Backend_Error with
           "malformed PostgreSQL protobuf result: " &
           Ada.Exceptions.Exception_Message (Error);
      when others =>
         Backends.Release (Backend);
         raise;
   end Parse;

end Flyology.Postgres.SQL;
