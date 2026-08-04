with Flyology.Postgres.Types.V14;
with Flyology.Postgres.Types.V15;
with Flyology.Postgres.Types.V16;
with Flyology.Postgres.Types.V17;
with Flyology.Postgres.Types.V18;

package body Flyology.Postgres.Types is

   use type OID;

   function Is_Known (Item : Type_Descriptor) return Boolean is
     (Item.OID_Value /= No_OID);

   function Type_OID (Item : Type_Descriptor) return OID is
     (Item.OID_Value);

   function SQL_Name (Item : Type_Descriptor) return String is
     (To_String (Item.Name_Value));

   function Kind (Item : Type_Descriptor) return Type_Kind is
     (Item.Kind_Value);

   function Category (Item : Type_Descriptor) return Type_Category is
     (Item.Category_Value);

   function Storage (Item : Type_Descriptor) return Storage_Kind is
     (Item.Storage_Value);

   function Alignment (Item : Type_Descriptor) return Alignment_Kind is
     (Item.Alignment_Value);

   function Passing (Item : Type_Descriptor) return Passing_Kind is
     (Item.Passing_Value);

   function Length_Form (Item : Type_Descriptor) return Length_Kind is
     (Item.Length_Value);

   function Fixed_Size (Item : Type_Descriptor) return Natural is
     (Item.Size_Value);

   function Is_Preferred (Item : Type_Descriptor) return Boolean is
     (Item.Preferred_Value);

   function Element_Type_OID (Item : Type_Descriptor) return OID is
     (Item.Element_Value);

   function Array_Type_OID (Item : Type_Descriptor) return OID is
     (Item.Array_Value);

   function Lookup
     (Version : SQL.Major_Version; Value : OID) return Type_Descriptor is
     (case Version is
         when SQL.PostgreSQL_14 => V14.Lookup (Value),
         when SQL.PostgreSQL_15 => V15.Lookup (Value),
         when SQL.PostgreSQL_16 => V16.Lookup (Value),
         when SQL.PostgreSQL_17 => V17.Lookup (Value),
         when SQL.PostgreSQL_18 => V18.Lookup (Value));

   function Lookup
     (Version : SQL.Major_Version; Name : String) return Type_Descriptor is
     (case Version is
         when SQL.PostgreSQL_14 => V14.Lookup (Name),
         when SQL.PostgreSQL_15 => V15.Lookup (Name),
         when SQL.PostgreSQL_16 => V16.Lookup (Name),
         when SQL.PostgreSQL_17 => V17.Lookup (Name),
         when SQL.PostgreSQL_18 => V18.Lookup (Name));

end Flyology.Postgres.Types;
