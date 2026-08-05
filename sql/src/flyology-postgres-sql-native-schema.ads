with Ada.Strings.Unbounded;
with Interfaces;

private package Flyology.Postgres.SQL.Native.Schema is

   use type Interfaces.Integer_64;

   package US renames Ada.Strings.Unbounded;

   type Value_Kind is
     (Boolean_Value, Signed_Value, Unsigned_Value, Float_Value, Text_Value,
      Message_Value, Enum_Value);

   type Field_Descriptor is record
      Source_Name : US.Unbounded_String;
      Output_Name : US.Unbounded_String;
      Kind        : Value_Kind;
      Target      : Natural := 0;
      Repeated    : Boolean := False;
   end record;
   type Field_Array is array (Positive range <>) of Field_Descriptor;

   type Message_Descriptor is record
      Name        : US.Unbounded_String;
      Node_Tag    : Interfaces.Integer_64 := -1;
      First_Field : Natural := 0;
      Field_Count : Natural := 0;
   end record;
   type Message_Array is array (Positive range <>) of Message_Descriptor;

   type Enum_Descriptor is record
      First_Value : Natural := 0;
      Value_Count : Natural := 0;
   end record;
   type Enum_Array is array (Positive range <>) of Enum_Descriptor;

   type Enum_Value_Descriptor is record
      Source_Number : Interfaces.Integer_64;
      Wire_Number   : Interfaces.Integer_64;
      Name          : US.Unbounded_String;
   end record;
   type Enum_Value_Array is array (Positive range <>) of Enum_Value_Descriptor;

end Flyology.Postgres.SQL.Native.Schema;
