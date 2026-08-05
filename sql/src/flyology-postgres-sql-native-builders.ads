with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

package Flyology.Postgres.SQL.Native.Builders is

   type Value_Kind is (Null_Value, Integer_Value, Boolean_Value, Text_Value,
                       Object_Value, List_Value, Cell_Value,
                       Field_Reference_Value);

   type Dynamic_Value is record
      Kind             : Value_Kind := Null_Value;
      Integer_Data     : Interfaces.Integer_64 := 0;
      Boolean_Data     : Boolean := False;
      Text_Data        : Ada.Strings.Unbounded.Unbounded_String;
      Object_Data      : Natural := 0;
      List_Data        : Natural := 0;
      Cell_List        : Natural := 0;
      Cell_Index       : Natural := 0;
      Reference_Object : Natural := 0;
      Reference_Field  : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   No_Value : constant Dynamic_Value := (others => <>);

   type Semantic_Array is array (Integer range <>) of Dynamic_Value;
   type Location_Array is array (Integer range <>) of Integer;

   function Number (Value : Interfaces.Integer_64) return Dynamic_Value;
   function Flag (Value : Boolean) return Dynamic_Value;
   function Text (Value : String) return Dynamic_Value;

   type Builder is tagged limited private;

   function New_Object
     (Self : in out Builder; Type_Name : String) return Dynamic_Value;
   function Object_Type
     (Self : Builder; Item : Dynamic_Value) return String
     with Pre => Item.Kind in Object_Value | Cell_Value;
   procedure Set_Field
     (Self : in out Builder; Item : Dynamic_Value; Name : String;
      Value : Dynamic_Value)
     with Pre => Item.Kind in Object_Value | Cell_Value;
   function Field
     (Self : Builder; Item : Dynamic_Value; Name : String) return Dynamic_Value
     with Pre => Item.Kind = Object_Value;

   function New_List (Self : in out Builder) return Dynamic_Value;
   function List_Of
     (Self : in out Builder; Item : Dynamic_Value) return Dynamic_Value;
   function Append
     (Self : in out Builder; List : Dynamic_Value;
      Item : Dynamic_Value) return Dynamic_Value;
   function Prepend
     (Self : in out Builder; Item : Dynamic_Value;
      List : Dynamic_Value) return Dynamic_Value;
   function Concatenate
     (Self : in out Builder; Left, Right : Dynamic_Value) return Dynamic_Value;
   function Delete
     (Self : in out Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value;
   function Truncate
     (Self : in out Builder; List : Dynamic_Value; Length : Natural)
      return Dynamic_Value;
   function Length (Self : Builder; List : Dynamic_Value) return Natural;
   function Element
     (Self : Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value;
   function Cell
     (Self : Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value;
   function Cell_Element
     (Self : Builder; Item : Dynamic_Value) return Dynamic_Value
     with Pre => Item.Kind = Cell_Value;
   function Next_Cell
     (Self : Builder; List, Item : Dynamic_Value) return Dynamic_Value;
   function Copy
     (Self : in out Builder; Item : Dynamic_Value) return Dynamic_Value;
   function Equivalent
     (Self : Builder; Left, Right : Dynamic_Value) return Boolean;
   function Field_Reference
     (Item : Dynamic_Value; Name : String) return Dynamic_Value
     with Pre => Item.Kind = Object_Value;
   function Dereference
     (Self : Builder; Item : Dynamic_Value) return Dynamic_Value;
   procedure Assign
     (Self : in out Builder; Target : Dynamic_Value; Value : Dynamic_Value)
     with Pre => Target.Kind = Field_Reference_Value;

private

   package US renames Ada.Strings.Unbounded;

   type Object_Entry is record
      Type_Name    : US.Unbounded_String;
      First_Member : Natural := 0;
      Last_Member  : Natural := 0;
   end record;

   type Member_Entry is record
      Name  : US.Unbounded_String;
      Value : Dynamic_Value;
      Next  : Natural := 0;
   end record;

   type List_Entry is record
      First_Element : Natural := 0;
      Last_Element  : Natural := 0;
      Length        : Natural := 0;
   end record;

   type Element_Entry is record
      Value : Dynamic_Value;
      Next  : Natural := 0;
   end record;

   package Object_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Object_Entry);
   package Member_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Member_Entry);
   package List_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => List_Entry);
   package Element_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Element_Entry);

   type Builder is tagged limited record
      Objects  : Object_Vectors.Vector;
      Members  : Member_Vectors.Vector;
      Lists    : List_Vectors.Vector;
      Elements : Element_Vectors.Vector;
   end record;

end Flyology.Postgres.SQL.Native.Builders;
