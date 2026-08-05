package body Flyology.Postgres.SQL.Internals is

   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_64;

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

   function First_Difference (Left, Right : Syntax_Tree) return String is
      Difference : Unbounded_String;

      function Compare
        (Left_Id, Right_Id : Value_Id; Path : String; Depth : Natural)
         return Boolean
      is
         Left_Value  : constant Stored_Value := Stored (Left, Left_Id);
         Right_Value : constant Stored_Value := Stored (Right, Right_Id);

         procedure Fail (Message : String) is
         begin
            if Length (Difference) = 0 then
               Difference := To_Unbounded_String (Path & ": " & Message);
            end if;
         end Fail;

         function Member_Names
           (Tree : Syntax_Tree; Item : Stored_Value) return String
         is
            Names : Unbounded_String;
         begin
            if Item.Length > 0 then
               for Offset in 0 .. Item.Length - 1 loop
                  if Length (Names) > 0 then
                     Append (Names, ",");
                  end if;
                  Append
                    (Names,
                     Tree.Members.Element
                       (Positive (Item.First + Offset)).Name);
               end loop;
            end if;
            return To_String (Names);
         end Member_Names;
      begin
         if Depth > 256 then
            Fail ("excessive arena recursion");
            return False;
         elsif Left_Value.Kind /= Right_Value.Kind then
            Fail ("stored kinds differ");
            return False;
         end if;
         case Left_Value.Kind is
            when Null_Value =>
               return True;
            when Boolean_Value =>
               if Left_Value.Boolean_Data /= Right_Value.Boolean_Data then
                  Fail ("boolean values differ");
                  return False;
               end if;
            when Signed_Integer_Value =>
               if Left_Value.Signed_Data /= Right_Value.Signed_Data then
                  Fail ("signed values differ");
                  return False;
               end if;
            when Unsigned_Integer_Value =>
               if Left_Value.Unsigned_Data /= Right_Value.Unsigned_Data then
                  Fail ("unsigned values differ");
                  return False;
               end if;
            when Float_Value =>
               if Left_Value.Float_Data /= Right_Value.Float_Data then
                  Fail ("floating-point values differ");
                  return False;
               end if;
            when String_Value =>
               if Left_Value.Text /= Right_Value.Text then
                  Fail
                    ("text differs (native='" & To_String (Left_Value.Text) &
                     "', C='" & To_String (Right_Value.Text) & "')");
                  return False;
               end if;
            when Array_Value =>
               if Left_Value.Length /= Right_Value.Length then
                  Fail ("array lengths differ");
                  return False;
               end if;
               if Left_Value.Length > 0 then
                  for Offset in 0 .. Left_Value.Length - 1 loop
                     if not Compare
                       (Left.Elements.Element
                          (Positive (Left_Value.First + Offset)),
                        Right.Elements.Element
                          (Positive (Right_Value.First + Offset)),
                        Path & "[" & Natural'Image (Offset + 1) & "]",
                        Depth + 1)
                     then
                        return False;
                     end if;
                  end loop;
               end if;
            when Object_Value =>
               if Left_Value.Length /= Right_Value.Length then
                  Fail
                    ("object member counts differ (native" &
                     Left_Value.Length'Image & " [" &
                     Member_Names (Left, Left_Value) & "], C" &
                     Right_Value.Length'Image & " [" &
                     Member_Names (Right, Right_Value) & "])");
                  return False;
               end if;
               if Left_Value.Length > 0 then
                  for Offset in 0 .. Left_Value.Length - 1 loop
                     declare
                        Member : constant Object_Member :=
                          Left.Members.Element
                            (Positive (Left_Value.First + Offset));
                        Name : constant String := To_String (Member.Name);
                        Match : Value_Id := No_Value;
                     begin
                        for Other in 0 .. Right_Value.Length - 1 loop
                           declare
                              Candidate : constant Object_Member :=
                                Right.Members.Element
                                  (Positive (Right_Value.First + Other));
                           begin
                              if Candidate.Name = Member.Name then
                                 Match := Candidate.Value;
                                 exit;
                              end if;
                           end;
                        end loop;
                        if Match = No_Value then
                           Fail
                             ("C object omits member " & Name & " (members: " &
                              Member_Names (Right, Right_Value) & ")");
                           return False;
                        elsif not Compare
                          (Member.Value, Match, Path & "." & Name, Depth + 1)
                        then
                           return False;
                        end if;
                     end;
                  end loop;
               end if;
         end case;
         return True;
      end Compare;
   begin
      if Left.Valid /= Right.Valid then
         return "validity differs";
      elsif not Left.Valid then
         if Left.Parse_Error.Position /= Right.Parse_Error.Position then
            return
              "diagnostic positions differ (native" &
              Left.Parse_Error.Position'Image & ", C" &
              Right.Parse_Error.Position'Image & ")";
         elsif Left.Parse_Error.Text /= Right.Parse_Error.Text then
            return
              "diagnostic messages differ (native='" &
              To_String (Left.Parse_Error.Text) & "', C='" &
              To_String (Right.Parse_Error.Text) & "')";
         end if;
         return "";
      elsif not Compare (Left.Root, Right.Root, "root", 0) then
         return To_String (Difference);
      end if;
      return "";
   end First_Difference;

   function Equivalent (Left, Right : Syntax_Tree) return Boolean is
     (First_Difference (Left, Right)'Length = 0);

end Flyology.Postgres.SQL.Internals;
