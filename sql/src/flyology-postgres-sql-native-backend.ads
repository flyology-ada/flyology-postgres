with Ada.Strings.Unbounded;

with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL_Backends;

generic
   Version : Major_Version;
   with procedure Parse_Native
     (SQL           : String;
      Options       : Parse_Options;
      Build         : aliased in out Builders.Builder;
      Result        : out Builders.Dynamic_Value;
      Error_Offset  : out Natural;
      Error_Message : out Ada.Strings.Unbounded.Unbounded_String;
      Success       : out Boolean);
   with procedure Load
     (Tree   : in out Syntax_Tree;
      Build  : Builders.Builder;
      Root   : Builders.Dynamic_Value;
      Result : out Value_Id);
package Flyology.Postgres.SQL.Native.Backend is
private
   procedure Parse
     (Text    : String;
      Options : Parse_Options;
      Result  : in out Syntax_Tree);

   Registered : constant Boolean :=
     SQL_Backends.Register (Version, Parse'Access);
   pragma Unreferenced (Registered);
end Flyology.Postgres.SQL.Native.Backend;
