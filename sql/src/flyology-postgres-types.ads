with Ada.Strings.Unbounded;
with Interfaces;

with Flyology.Postgres.SQL;

package Flyology.Postgres.Types is

   subtype OID is Interfaces.Unsigned_32;
   No_OID : constant OID := 0;

   type Type_Kind is
     (Base_Type,
      Composite_Type,
      Domain_Type,
      Enum_Type,
      Multirange_Type,
      Pseudo_Type,
      Range_Type);

   type Type_Category is
     (Array_Category,
      Boolean_Category,
      Composite_Category,
      Date_Time_Category,
      Enum_Category,
      Geometric_Category,
      Network_Category,
      Numeric_Category,
      Pseudo_Category,
      Range_Category,
      String_Category,
      Time_Span_Category,
      User_Category,
      Bit_String_Category,
      Unknown_Category,
      Internal_Category);

   type Storage_Kind is
     (Plain_Storage, External_Storage, Extended_Storage, Main_Storage);

   type Alignment_Kind is
     (Character_Alignment,
      Short_Alignment,
      Integer_Alignment,
      Double_Alignment,
      Platform_Alignment);

   type Passing_Kind is
     (By_Reference, By_Value, Platform_Dependent_Passing);

   type Length_Kind is
     (Fixed_Length, Variable_Length, Null_Terminated, Platform_Length);

   type Type_Descriptor is private;
   Unknown_Type : constant Type_Descriptor;

   function Is_Known (Item : Type_Descriptor) return Boolean;
   function Type_OID (Item : Type_Descriptor) return OID
     with Pre => Is_Known (Item);
   function SQL_Name (Item : Type_Descriptor) return String
     with Pre => Is_Known (Item);
   function Kind (Item : Type_Descriptor) return Type_Kind
     with Pre => Is_Known (Item);
   function Category (Item : Type_Descriptor) return Type_Category
     with Pre => Is_Known (Item);
   function Storage (Item : Type_Descriptor) return Storage_Kind
     with Pre => Is_Known (Item);
   function Alignment (Item : Type_Descriptor) return Alignment_Kind
     with Pre => Is_Known (Item);
   function Passing (Item : Type_Descriptor) return Passing_Kind
     with Pre => Is_Known (Item);
   function Length_Form (Item : Type_Descriptor) return Length_Kind
     with Pre => Is_Known (Item);
   function Fixed_Size (Item : Type_Descriptor) return Natural
     with Pre => Is_Known (Item) and then Length_Form (Item) = Fixed_Length;
   function Is_Preferred (Item : Type_Descriptor) return Boolean
     with Pre => Is_Known (Item);
   function Element_Type_OID (Item : Type_Descriptor) return OID
     with Pre => Is_Known (Item);
   function Array_Type_OID (Item : Type_Descriptor) return OID
     with Pre => Is_Known (Item);

   function Lookup
     (Version : SQL.Major_Version; Value : OID) return Type_Descriptor;
   function Lookup
     (Version : SQL.Major_Version; Name : String) return Type_Descriptor;

private

   use Ada.Strings.Unbounded;

   type Type_Descriptor is record
      OID_Value       : OID := No_OID;
      Name_Value      : Unbounded_String;
      Kind_Value      : Type_Kind := Base_Type;
      Category_Value  : Type_Category := User_Category;
      Storage_Value   : Storage_Kind := Plain_Storage;
      Alignment_Value : Alignment_Kind := Character_Alignment;
      Passing_Value   : Passing_Kind := By_Reference;
      Length_Value    : Length_Kind := Variable_Length;
      Size_Value      : Natural := 0;
      Preferred_Value : Boolean := False;
      Element_Value   : OID := No_OID;
      Array_Value     : OID := No_OID;
   end record;

   Unknown_Type : constant Type_Descriptor := (others => <>);

end Flyology.Postgres.Types;
