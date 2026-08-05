with Interfaces;

private package Flyology.Postgres.SQL.Arena_Storage is

   function Begin_Object (Tree : in out Syntax_Tree) return Value_Id;
   procedure Finish_Object
     (Tree  : in out Syntax_Tree;
      Id    : Value_Id;
      Items : Member_Vectors.Vector);
   procedure Set_Member
     (Items : in out Member_Vectors.Vector; Name : String; Value : Value_Id);
   procedure Clear_Member
     (Items : in out Member_Vectors.Vector; Name : String);
   function Make_Array
     (Tree : in out Syntax_Tree;
      Items : Element_Vectors.Vector) return Value_Id;
   function Store_Boolean
     (Tree : in out Syntax_Tree; Value : Boolean) return Value_Id;
   function Store_Signed
     (Tree : in out Syntax_Tree; Value : Interfaces.Integer_64) return Value_Id;
   function Store_Unsigned
     (Tree : in out Syntax_Tree; Value : Interfaces.Unsigned_64) return Value_Id;
   function Store_Float
     (Tree : in out Syntax_Tree; Value : Interfaces.IEEE_Float_64) return Value_Id;
   function Store_Text
     (Tree : in out Syntax_Tree; Value : String) return Value_Id;

end Flyology.Postgres.SQL.Arena_Storage;
