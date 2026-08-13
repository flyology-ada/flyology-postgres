package Psqlbench_JSON is

   function Quote (Value : String) return String;

   function String_Field
     (Document : String;
      Name     : String) return String;

   function Natural_Field
     (Document : String;
      Name     : String;
      Default  : Natural) return Natural;

   function Valid_Name (Value : String) return Boolean;
   function Valid_Version (Value : String) return Boolean;

end Psqlbench_JSON;
