private package Flyology.Postgres.SQL.Internals is

   type Sequence_Id is private;

   function Root (Tree : Syntax_Tree) return Value_Id
     with Pre => Is_Valid (Tree);

   function Has_Field
     (Tree : Syntax_Tree; Object : Value_Id; Name : String) return Boolean;
   function Field
     (Tree : Syntax_Tree; Object : Value_Id; Name : String) return Value_Id
     with Pre => Has_Field (Tree, Object, Name);

   function Kind (Tree : Syntax_Tree; Value : Value_Id) return Stored_Kind;
   function String_Data (Tree : Syntax_Tree; Value : Value_Id) return String;
   function Signed_Data
     (Tree : Syntax_Tree; Value : Value_Id) return Interfaces.Integer_64;
   function Unsigned_Data
     (Tree : Syntax_Tree; Value : Value_Id) return Interfaces.Unsigned_64;
   function Float_Data (Tree : Syntax_Tree; Value : Value_Id) return Long_Float;
   function Boolean_Data (Tree : Syntax_Tree; Value : Value_Id) return Boolean;

   function To_Sequence
     (Tree : Syntax_Tree; Value : Value_Id) return Sequence_Id;
   function Empty_Sequence return Sequence_Id;
   function Length (Tree : Syntax_Tree; Sequence : Sequence_Id) return Natural;
   function Element
     (Tree : Syntax_Tree;
      Sequence : Sequence_Id;
      Index : Positive) return Value_Id
     with Pre => Index <= Length (Tree, Sequence);

   function Only_Field_Name (Tree : Syntax_Tree; Object : Value_Id) return String;
   function Only_Field_Value (Tree : Syntax_Tree; Object : Value_Id) return Value_Id;

private

   type Sequence_Id is new Value_Id;

end Flyology.Postgres.SQL.Internals;
