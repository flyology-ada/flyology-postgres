package body Flyology.Postgres.SQL.Internals is

   function Stored (Tree : Syntax_Tree; Value : Value_Id) return Stored_Value is
     (Tree.Values.Element (Positive (Value)));

   function Root (Tree : Syntax_Tree) return Value_Id is (Tree.Root);

   function Has_Field
     (Tree : Syntax_Tree; Object : Value_Id; Name : String) return Boolean
   is
      Item : constant Stored_Value := Stored (Tree, Object);
   begin
      if Item.Kind /= Object_Value then
         return False;
      end if;
      if Item.Length = 0 then
         return False;
      end if;
      for Offset in 0 .. Item.Length - 1 loop
         if To_String
           (Tree.Members.Element (Positive (Item.First + Offset)).Name) = Name
         then
            return True;
         end if;
      end loop;
      return False;
   end Has_Field;

   function Field
     (Tree : Syntax_Tree; Object : Value_Id; Name : String) return Value_Id
   is
      Item : constant Stored_Value := Stored (Tree, Object);
   begin
      if Item.Kind /= Object_Value or else Item.Length = 0 then
         raise Constraint_Error with "expected a nonempty JSON object";
      end if;
      for Offset in 0 .. Item.Length - 1 loop
         declare
            Member : constant Object_Member :=
              Tree.Members.Element (Positive (Item.First + Offset));
         begin
            if To_String (Member.Name) = Name then
               return Member.Value;
            end if;
         end;
      end loop;
      raise Constraint_Error with "JSON object field is absent: " & Name;
   end Field;

   function Kind (Tree : Syntax_Tree; Value : Value_Id) return Stored_Kind is
     (Stored (Tree, Value).Kind);

   function String_Data (Tree : Syntax_Tree; Value : Value_Id) return String is
     (To_String (Stored (Tree, Value).Text));

   function Signed_Data
     (Tree : Syntax_Tree; Value : Value_Id) return Interfaces.Integer_64 is
     (Stored (Tree, Value).Signed_Data);

   function Unsigned_Data
     (Tree : Syntax_Tree; Value : Value_Id) return Interfaces.Unsigned_64 is
     (Stored (Tree, Value).Unsigned_Data);

   function Float_Data (Tree : Syntax_Tree; Value : Value_Id) return Long_Float is
     (Stored (Tree, Value).Float_Data);

   function Boolean_Data (Tree : Syntax_Tree; Value : Value_Id) return Boolean is
     (Stored (Tree, Value).Boolean_Data);

   function To_Sequence
     (Tree : Syntax_Tree; Value : Value_Id) return Sequence_Id
   is
      pragma Unreferenced (Tree);
   begin
      return Sequence_Id (Value);
   end To_Sequence;

   function Empty_Sequence return Sequence_Id is (Sequence_Id (No_Value));

   function Length (Tree : Syntax_Tree; Sequence : Sequence_Id) return Natural is
     (if Sequence = Sequence_Id (No_Value)
      then 0
      else Stored (Tree, Value_Id (Sequence)).Length);

   function Element
     (Tree : Syntax_Tree;
      Sequence : Sequence_Id;
      Index : Positive) return Value_Id
   is
      Item : constant Stored_Value := Stored (Tree, Value_Id (Sequence));
   begin
      return Tree.Elements.Element (Positive (Item.First + Index - 1));
   end Element;

   function Only_Field_Name (Tree : Syntax_Tree; Object : Value_Id) return String is
      Item : constant Stored_Value := Stored (Tree, Object);
   begin
      if Item.Kind /= Object_Value or else Item.Length /= 1 then
         raise Constraint_Error with "expected a one-field PostgreSQL node object";
      end if;
      return To_String (Tree.Members.Element (Positive (Item.First)).Name);
   end Only_Field_Name;

   function Only_Field_Value (Tree : Syntax_Tree; Object : Value_Id) return Value_Id is
      Item : constant Stored_Value := Stored (Tree, Object);
   begin
      if Item.Kind /= Object_Value or else Item.Length /= 1 then
         raise Constraint_Error with "expected a one-field PostgreSQL node object";
      end if;
      return Tree.Members.Element (Positive (Item.First)).Value;
   end Only_Field_Value;

end Flyology.Postgres.SQL.Internals;
