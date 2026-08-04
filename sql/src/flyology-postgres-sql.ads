with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Flyology.Postgres.SQL is

   type Major_Version is (PostgreSQL_14, PostgreSQL_15, PostgreSQL_16,
                          PostgreSQL_17, PostgreSQL_18);

   type Parse_Mode is
     (SQL_Statements,
      Type_Name,
      PLpgSQL_Expression,
      PLpgSQL_Assignment_1,
      PLpgSQL_Assignment_2,
      PLpgSQL_Assignment_3);

   type Parse_Options is record
      Mode                       : Parse_Mode := SQL_Statements;
      Backslash_Quote            : Boolean := True;
      Standard_Conforming_Strings : Boolean := True;
      Escape_String_Warning      : Boolean := True;
   end record;

   Default_Options : constant Parse_Options := (others => <>);

   function Supports_Parse_Options (Version : Major_Version) return Boolean;

   type Diagnostic is private;

   function Message (Item : Diagnostic) return String;
   function Cursor_Position (Item : Diagnostic) return Natural;

   type Syntax_Tree is tagged limited private;

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

   Parser_Backend_Error : exception;
   Unsupported_Parse_Options : exception;

private

   use Ada.Strings.Unbounded;

   type Diagnostic is record
      Text     : Unbounded_String;
      Position : Natural := 0;
   end record;

   type Value_Id is new Natural;
   No_Value : constant Value_Id := 0;

   type Stored_Kind is
     (Null_Value,
      Boolean_Value,
      Signed_Integer_Value,
      Unsigned_Integer_Value,
      Float_Value,
      String_Value,
      Array_Value,
      Object_Value);

   type Stored_Value is record
      Kind          : Stored_Kind := Null_Value;
      Text          : Unbounded_String;
      Signed_Data   : Interfaces.Integer_64 := 0;
      Unsigned_Data : Interfaces.Unsigned_64 := 0;
      Float_Data    : Long_Float := 0.0;
      Boolean_Data  : Boolean := False;
      First         : Natural := 0;
      Length        : Natural := 0;
   end record;

   type Object_Member is record
      Name  : Unbounded_String;
      Value : Value_Id := No_Value;
   end record;

   package Value_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Stored_Value);
   package Member_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Object_Member);
   package Element_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Value_Id);

   type Syntax_Tree is tagged limited record
      Parsed_Version : Major_Version := PostgreSQL_18;
      Input          : Unbounded_String;
      Parse_Error    : Diagnostic;
      Valid          : Boolean := False;
      Root           : Value_Id := No_Value;
      Values         : Value_Vectors.Vector;
      Members        : Member_Vectors.Vector;
      Elements       : Element_Vectors.Vector;
   end record;

end Flyology.Postgres.SQL;
