with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.Scanner;
with Flyology.Postgres.SQL.Native.Tables;
with Ada.Strings.Unbounded;

generic
   with package Lexical_Scanner is new Flyology.Postgres.SQL.Native.Scanner (<>);
   Final_State       : Integer;
   Last_Table_Index  : Integer;
   Terminal_Count    : Integer;
   Maximum_Token     : Integer;
   Pact_Default      : Integer;
   Table_Error       : Integer;
   Translate         : Tables.Integer_Array;
   Rule_Left         : Tables.Integer_Array;
   Rule_Length       : Tables.Integer_Array;
   Default_Action    : Tables.Integer_Array;
   Default_Goto      : Tables.Integer_Array;
   Action_Offset     : Tables.Integer_Array;
   Goto_Offset       : Tables.Integer_Array;
   Action_Table      : Tables.Integer_Array;
   Action_Check      : Tables.Integer_Array;
   with procedure Semantic_Reduce
     (Build        : aliased in out Builders.Builder;
      Rule         : Positive;
      Values       : Builders.Semantic_Array;
      Locations    : Builders.Location_Array;
      Result       : in out Builders.Dynamic_Value;
      Location     : in out Integer;
      Error_Location : not null access Integer;
      Parse_Result : in out Builders.Dynamic_Value);
package Flyology.Postgres.SQL.Native.Engine is

   procedure Parse
     (SQL           : String;
      Options       : Parse_Options;
      Initial_Token : Natural;
      Build         : aliased in out Builders.Builder;
      Result        : out Builders.Dynamic_Value;
      Error_Offset  : out Natural;
      Error_Message : out Ada.Strings.Unbounded.Unbounded_String;
      Success       : out Boolean);

end Flyology.Postgres.SQL.Native.Engine;
