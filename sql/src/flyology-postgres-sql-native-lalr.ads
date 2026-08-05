with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.Tables;

generic
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
   with procedure Next_Token
     (External_Token : out Integer;
      Value          : out Builders.Dynamic_Value;
      Location       : out Integer);
   with procedure Reduce
     (Rule      : Positive;
      Values    : Builders.Semantic_Array;
      Locations : Builders.Location_Array;
      Result    : in out Builders.Dynamic_Value;
      Location  : in out Integer);
   with procedure Syntax_Error (Location : Integer; External_Token : Integer);
package Flyology.Postgres.SQL.Native.LALR is

   procedure Parse;

end Flyology.Postgres.SQL.Native.LALR;
