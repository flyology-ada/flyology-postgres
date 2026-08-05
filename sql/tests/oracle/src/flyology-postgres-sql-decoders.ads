with Interfaces;
with System;
with Flyology.Postgres.SQL.Arena_Storage;

private package Flyology.Postgres.SQL.Decoders is

   Decoder_Error : exception;
   Maximum_Message_Depth : constant := 256;

   type Wire_Type is (Varint, Fixed_64, Length_Delimited,
                      Start_Group, End_Group, Fixed_32);
   type Reader is private;

   procedure Initialize
     (Stream : out Reader; Data : System.Address; Length : Natural);
   function At_End (Stream : Reader) return Boolean;
   procedure Read_Key
     (Stream       : in out Reader;
      Field_Number : out Positive;
      Encoding     : out Wire_Type);
   function Read_Varint
     (Stream : in out Reader) return Interfaces.Unsigned_64;
   function Read_Int_32
     (Stream : in out Reader) return Interfaces.Integer_32;
   function Read_Int_64
     (Stream : in out Reader) return Interfaces.Integer_64;
   function Read_SInt_32
     (Stream : in out Reader) return Interfaces.Integer_32;
   function Read_SInt_64
     (Stream : in out Reader) return Interfaces.Integer_64;
   function Read_Fixed_32
     (Stream : in out Reader) return Interfaces.Unsigned_32;
   function Read_Fixed_64
     (Stream : in out Reader) return Interfaces.Unsigned_64;
   function Read_SFixed_32
     (Stream : in out Reader) return Interfaces.Integer_32;
   function Read_SFixed_64
     (Stream : in out Reader) return Interfaces.Integer_64;
   function Read_Float
     (Stream : in out Reader) return Interfaces.IEEE_Float_32;
   function Read_Double
     (Stream : in out Reader) return Interfaces.IEEE_Float_64;
   function Read_Text (Stream : in out Reader) return String;
   procedure Read_Embedded (Stream : in out Reader; Child : out Reader);
   procedure Skip_Field
     (Stream       : in out Reader;
      Field_Number : Positive;
      Encoding     : Wire_Type);

   function Begin_Object (Tree : in out Syntax_Tree) return Value_Id
     renames Arena_Storage.Begin_Object;
   procedure Finish_Object
     (Tree : in out Syntax_Tree;
      Id   : Value_Id;
      Items : Member_Vectors.Vector)
     renames Arena_Storage.Finish_Object;
   procedure Set_Member
     (Items : in out Member_Vectors.Vector; Name : String; Value : Value_Id)
     renames Arena_Storage.Set_Member;
   procedure Clear_Member
     (Items : in out Member_Vectors.Vector; Name : String)
     renames Arena_Storage.Clear_Member;
   function Make_Array
     (Tree : in out Syntax_Tree;
      Items : Element_Vectors.Vector) return Value_Id
     renames Arena_Storage.Make_Array;
   function Store_Boolean
     (Tree : in out Syntax_Tree; Value : Boolean) return Value_Id
     renames Arena_Storage.Store_Boolean;
   function Store_Signed
     (Tree : in out Syntax_Tree; Value : Interfaces.Integer_64) return Value_Id
     renames Arena_Storage.Store_Signed;
   function Store_Unsigned
     (Tree : in out Syntax_Tree; Value : Interfaces.Unsigned_64) return Value_Id
     renames Arena_Storage.Store_Unsigned;
   function Store_Float
     (Tree : in out Syntax_Tree; Value : Interfaces.IEEE_Float_64) return Value_Id
     renames Arena_Storage.Store_Float;
   function Store_Text
     (Tree : in out Syntax_Tree; Value : String) return Value_Id
     renames Arena_Storage.Store_Text;

private

   type Reader is record
      Base     : System.Address := System.Null_Address;
      Position : Natural := 0;
      Limit    : Natural := 0;
      Depth    : Natural := 0;
   end record;

end Flyology.Postgres.SQL.Decoders;
