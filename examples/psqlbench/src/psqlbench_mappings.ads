package Psqlbench_Mappings is

   Max_Columns : constant := 64;
   Max_Type_Bytes : constant := 96;

   type Mapping_Rule is record
      Source_Length : Natural range 0 .. 63 := 0;
      Source : String (1 .. 63) := (others => ' ');
      Target_Length : Natural range 0 .. 63 := 0;
      Target : String (1 .. 63) := (others => ' ');
      Type_Length : Natural range 0 .. Max_Type_Bytes := 0;
      Target_Type : String (1 .. Max_Type_Bytes) := (others => ' ');
   end record;

   type Mapping_Array is
     array (Positive range 1 .. Max_Columns) of Mapping_Rule;

   procedure Parse
     (Value : String; Rules : out Mapping_Array; Count : out Natural);

   function Source_Name (Rule : Mapping_Rule) return String;
   function Target_Name (Rule : Mapping_Rule) return String;
   function Target_Type (Rule : Mapping_Rule) return String;

end Psqlbench_Mappings;
