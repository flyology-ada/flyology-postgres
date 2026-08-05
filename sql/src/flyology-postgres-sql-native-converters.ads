with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.Schema;

private package Flyology.Postgres.SQL.Native.Converters is

   Converter_Error : exception;
   Maximum_Conversion_Depth : constant := 256;

   procedure Load
     (Tree           : in out Syntax_Tree;
      Build          : Builders.Builder;
      Root           : Builders.Dynamic_Value;
      Version_Number : Interfaces.Integer_64;
      Node_Message   : Positive;
      List_Message   : Positive;
      Raw_Stmt_Message : Positive;
      Messages       : Schema.Message_Array;
      Fields         : Schema.Field_Array;
      Enums          : Schema.Enum_Array;
      Enum_Values    : Schema.Enum_Value_Array;
      Result         : out Value_Id);

end Flyology.Postgres.SQL.Native.Converters;
