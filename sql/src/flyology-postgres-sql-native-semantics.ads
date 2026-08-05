with Flyology.Postgres.SQL.Native.Builders;
with Interfaces;

package Flyology.Postgres.SQL.Native.Semantics is

   Parser_Error : exception;
   Scanner_Parser_Error : exception;

   No_Arguments : constant Builders.Semantic_Array (1 .. 0) := (others => <>);

   function Truth (Value : Builders.Dynamic_Value) return Boolean;
   function Integer_Of (Value : Builders.Dynamic_Value) return Interfaces.Integer_64;
   function Text_Of (Value : Builders.Dynamic_Value) return String;
   function Binary
     (Operator : String; Left, Right : Builders.Dynamic_Value)
      return Builders.Dynamic_Value;
   function Unary
     (Operator : String; Value : Builders.Dynamic_Value)
      return Builders.Dynamic_Value;
   function Node_Is
     (Build : not null access Builders.Builder; Value : Builders.Dynamic_Value;
      Type_Name : String) return Builders.Dynamic_Value;
   function Set_Field
     (Build : not null access Builders.Builder; Item : Builders.Dynamic_Value;
      Name : String; Value : Builders.Dynamic_Value)
      return Builders.Dynamic_Value;

   function Invoke
     (Build : not null access Builders.Builder; Name : String;
      Arguments : Builders.Semantic_Array) return Builders.Dynamic_Value;

end Flyology.Postgres.SQL.Native.Semantics;
