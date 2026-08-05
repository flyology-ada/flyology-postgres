with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces; use Interfaces;

package body Flyology.Postgres.SQL.Arena_Storage is

   function Begin_Object (Tree : in out Syntax_Tree) return Value_Id is
   begin
      Tree.Values.Append (Stored_Value'(others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Begin_Object;

   procedure Finish_Object
     (Tree  : in out Syntax_Tree;
      Id    : Value_Id;
      Items : Member_Vectors.Vector)
   is
      First : constant Natural := Natural (Tree.Members.Length) + 1;
   begin
      for Item of Items loop
         Tree.Members.Append (Item);
      end loop;
      Tree.Values.Replace_Element
        (Positive (Id), (Kind => Object_Value, First => First,
                         Length => Natural (Items.Length), others => <>));
   end Finish_Object;

   procedure Set_Member
     (Items : in out Member_Vectors.Vector; Name : String; Value : Value_Id) is
   begin
      if not Items.Is_Empty then
         for Index in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (Index).Name) = Name then
               Items.Replace_Element
                 (Index, (Name => To_Unbounded_String (Name), Value => Value));
               return;
            end if;
         end loop;
      end if;
      Items.Append
        (Object_Member'(Name => To_Unbounded_String (Name), Value => Value));
   end Set_Member;

   procedure Clear_Member
     (Items : in out Member_Vectors.Vector; Name : String) is
   begin
      if not Items.Is_Empty then
         for Index in Items.First_Index .. Items.Last_Index loop
            if To_String (Items.Element (Index).Name) = Name then
               Items.Delete (Index);
               return;
            end if;
         end loop;
      end if;
   end Clear_Member;

   function Make_Array
     (Tree : in out Syntax_Tree;
      Items : Element_Vectors.Vector) return Value_Id
   is
      First : constant Natural := Natural (Tree.Elements.Length) + 1;
   begin
      Tree.Values.Append (Stored_Value'(others => <>));
      for Item of Items loop
         Tree.Elements.Append (Item);
      end loop;
      Tree.Values.Replace_Element
        (Tree.Values.Last_Index,
         (Kind => Array_Value, First => First,
          Length => Natural (Items.Length), others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Make_Array;

   function Store_Boolean
     (Tree : in out Syntax_Tree; Value : Boolean) return Value_Id is
   begin
      Tree.Values.Append
        (Stored_Value'(Kind => Boolean_Value, Boolean_Data => Value, others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Store_Boolean;

   function Store_Signed
     (Tree : in out Syntax_Tree; Value : Integer_64) return Value_Id is
   begin
      Tree.Values.Append
        (Stored_Value'(Kind => Signed_Integer_Value, Signed_Data => Value, others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Store_Signed;

   function Store_Unsigned
     (Tree : in out Syntax_Tree; Value : Unsigned_64) return Value_Id is
   begin
      Tree.Values.Append
        (Stored_Value'(Kind => Unsigned_Integer_Value, Unsigned_Data => Value, others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Store_Unsigned;

   function Store_Float
     (Tree : in out Syntax_Tree; Value : IEEE_Float_64) return Value_Id is
   begin
      Tree.Values.Append
        (Stored_Value'(Kind => Float_Value, Float_Data => Long_Float (Value), others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Store_Float;

   function Store_Text
     (Tree : in out Syntax_Tree; Value : String) return Value_Id is
   begin
      Tree.Values.Append
        (Stored_Value'(Kind => String_Value, Text => To_Unbounded_String (Value), others => <>));
      return Value_Id (Tree.Values.Last_Index);
   end Store_Text;

end Flyology.Postgres.SQL.Arena_Storage;
