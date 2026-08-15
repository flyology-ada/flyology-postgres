with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Flyology.Postgres.SQL.Native.Builders is

   use type Interfaces.Integer_64;

   function Number (Value : Interfaces.Integer_64) return Dynamic_Value is
     ((Kind => Integer_Value, Integer_Data => Value, others => <>));

   function Flag (Value : Boolean) return Dynamic_Value is
     ((Kind => Boolean_Value, Boolean_Data => Value, others => <>));

   function Text (Value : String) return Dynamic_Value is
     ((Kind => Text_Value, Text_Data => To_Unbounded_String (Value), others => <>));

   function New_Object
     (Self : in out Builder; Type_Name : String) return Dynamic_Value is
   begin
      Self.Objects.Append
        (Object_Entry'(Type_Name => To_Unbounded_String (Type_Name), others => <>));
      return
        (Kind => Object_Value, Object_Data => Self.Objects.Last_Index,
         others => <>);
   end New_Object;

   function Object_Type
     (Self : Builder; Item : Dynamic_Value) return String is
     (To_String (Self.Objects.Element (Item.Object_Data).Type_Name));

   procedure Set_Field
     (Self : in out Builder; Item : Dynamic_Value; Name : String;
      Value : Dynamic_Value)
   is
      Object_Item : Object_Entry;
      Cursor      : Natural;
   begin
      if Item.Kind = Cell_Value and then Name = "l" then
         return;
      elsif Item.Kind = Cell_Value
        and then Name in "ptr_value" | "int_value" | "oid_value"
      then
         declare
            Cursor : Natural :=
              Self.Lists.Element (Item.Cell_List).First_Element;
         begin
            for Index in 2 .. Item.Cell_Index loop
               Cursor := Self.Elements.Element (Cursor).Next;
            end loop;
            declare
               Element : Element_Entry := Self.Elements.Element (Cursor);
            begin
               Element.Value := Value;
               Self.Elements.Replace_Element (Cursor, Element);
            end;
         end;
         return;
      end if;
      if Item.Kind /= Object_Value or else Item.Object_Data = 0 then
         raise Constraint_Error with
           "attempt to set field " & Name & " on a non-object value";
      end if;
      Object_Item := Self.Objects.Element (Item.Object_Data);
      Cursor := Object_Item.First_Member;
      while Cursor /= 0 loop
         declare
            Member : Member_Entry := Self.Members.Element (Cursor);
         begin
            if To_String (Member.Name) = Name then
               Member.Value := Value;
               Self.Members.Replace_Element (Cursor, Member);
               return;
            end if;
            Cursor := Member.Next;
         end;
      end loop;

      Self.Members.Append
        (Member_Entry'(Name => To_Unbounded_String (Name),
                       Value => Value, Next => 0));
      declare
         New_Index : constant Positive := Self.Members.Last_Index;
      begin
         if Object_Item.Last_Member = 0 then
            Object_Item.First_Member := New_Index;
         else
            declare
               Previous : Member_Entry :=
                 Self.Members.Element (Object_Item.Last_Member);
            begin
               Previous.Next := New_Index;
               Self.Members.Replace_Element (Object_Item.Last_Member, Previous);
            end;
         end if;
         Object_Item.Last_Member := New_Index;
         Self.Objects.Replace_Element (Item.Object_Data, Object_Item);
      end;
   end Set_Field;

   function Field
     (Self : Builder; Item : Dynamic_Value; Name : String) return Dynamic_Value
   is
      Cursor : Natural;
   begin
      if Item.Kind = Cell_Value then
         if Name = "i" then
            return Number (Interfaces.Integer_64 (Item.Cell_Index));
         elsif Name = "l" then
            return
              (Kind => List_Value, List_Data => Item.Cell_List, others => <>);
         end if;
         return No_Value;
      end if;
      if Item.Kind /= Object_Value or else Item.Object_Data = 0 then
         return No_Value;
      end if;
      Cursor := Self.Objects.Element (Item.Object_Data).First_Member;
      while Cursor /= 0 loop
         declare
            Member : constant Member_Entry := Self.Members.Element (Cursor);
         begin
            if To_String (Member.Name) = Name then
               return Member.Value;
            end if;
            Cursor := Member.Next;
         end;
      end loop;
      --  PostgreSQL 14's Value node stores Integer in the anonymous
      --  `val.ival` union member, while the versioned protobuf shape exposes
      --  the same scalar directly as `ival`.  Handwritten constructors use
      --  the protobuf-facing name; generated grammar actions still use the C
      --  member path (notably intVal(linitial(...))).
      if Self.Object_Type (Item) = "Integer" and then Name = "val.ival" then
         return Self.Field (Item, "ival");
      elsif Self.Object_Type (Item) = "String" and then Name = "val.str" then
         return Self.Field (Item, "sval");
      elsif Self.Object_Type (Item) = "A_Const" and then Name = "val.node" then
         --  In PostgreSQL this anonymous union member aliases the NodeTag of
         --  the active scalar node.  Preserve the containing value so
         --  Semantics.Node_Is can inspect the normalized protobuf field.
         return Item;
      end if;
      return No_Value;
   end Field;

   function New_List (Self : in out Builder) return Dynamic_Value is
   begin
      Self.Lists.Append (List_Entry'(others => <>));
      return
        (Kind => List_Value, List_Data => Self.Lists.Last_Index,
         others => <>);
   end New_List;

   function List_Of
     (Self : in out Builder; Item : Dynamic_Value) return Dynamic_Value
   is
      Result : constant Dynamic_Value := New_List (Self);
   begin
      return Self.Append (Result, Item);
   end List_Of;

   function Append
     (Self : in out Builder; List : Dynamic_Value;
      Item : Dynamic_Value) return Dynamic_Value
   is
      Result : Dynamic_Value := List;
   begin
      if Result.Kind = Null_Value then
         Result := New_List (Self);
      end if;
      if Result.Kind /= List_Value then
         raise Constraint_Error with "attempt to append to a non-list value";
      end if;

      declare
         Header : List_Entry := Self.Lists.Element (Result.List_Data);
      begin
         Self.Elements.Append (Element_Entry'(Value => Item, Next => 0));
         declare
            New_Index : constant Positive := Self.Elements.Last_Index;
         begin
            if Header.Last_Element = 0 then
               Header.First_Element := New_Index;
            else
               declare
                  Previous : Element_Entry :=
                    Self.Elements.Element (Header.Last_Element);
               begin
                  Previous.Next := New_Index;
                  Self.Elements.Replace_Element (Header.Last_Element, Previous);
               end;
            end if;
            Header.Last_Element := New_Index;
            Header.Length := Header.Length + 1;
            Self.Lists.Replace_Element (Result.List_Data, Header);
         end;
      end;
      return Result;
   end Append;

   function Prepend
     (Self : in out Builder; Item : Dynamic_Value;
      List : Dynamic_Value) return Dynamic_Value
   is
      Result : Dynamic_Value := List;
   begin
      if Result.Kind = Null_Value then
         return List_Of (Self, Item);
      end if;
      if Result.Kind /= List_Value then
         raise Constraint_Error with "attempt to prepend to a non-list value";
      end if;
      declare
         Header : List_Entry := Self.Lists.Element (Result.List_Data);
      begin
         Self.Elements.Append
           (Element_Entry'(Value => Item, Next => Header.First_Element));
         Header.First_Element := Self.Elements.Last_Index;
         if Header.Last_Element = 0 then
            Header.Last_Element := Header.First_Element;
         end if;
         Header.Length := Header.Length + 1;
         Self.Lists.Replace_Element (Result.List_Data, Header);
      end;
      return Result;
   end Prepend;

   function Concatenate
     (Self : in out Builder; Left, Right : Dynamic_Value) return Dynamic_Value
   is
      Result : Dynamic_Value := Left;
   begin
      if Result.Kind = Null_Value then
         Result := New_List (Self);
      end if;
      if Right.Kind = Null_Value then
         return Result;
      end if;
      for Index in 1 .. Self.Length (Right) loop
         Result := Self.Append (Result, Self.Element (Right, Index));
      end loop;
      return Result;
   end Concatenate;

   function Delete
     (Self : in out Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value
   is
      Result : Dynamic_Value := New_List (Self);
   begin
      if List.Kind = Null_Value then
         return Result;
      end if;
      for Position in 1 .. Self.Length (List) loop
         if Position /= Index then
            Result := Self.Append (Result, Self.Element (List, Position));
         end if;
      end loop;
      return Result;
   end Delete;

   function Truncate
     (Self : in out Builder; List : Dynamic_Value; Length : Natural)
      return Dynamic_Value
   is
      Result : Dynamic_Value := New_List (Self);
   begin
      for Position in 1 .. Natural'Min (Length, Self.Length (List)) loop
         Result := Self.Append (Result, Self.Element (List, Position));
      end loop;
      return Result;
   end Truncate;

   function Length (Self : Builder; List : Dynamic_Value) return Natural is
     (if List.Kind = Null_Value then 0
      elsif List.Kind = List_Value then Self.Lists.Element (List.List_Data).Length
      else raise Constraint_Error with "length requested for a non-list value");

   function Element
     (Self : Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value
   is
      Cursor : Natural;
   begin
      if List.Kind /= List_Value or else Index > Self.Length (List) then
         raise Constraint_Error with "list index is out of range";
      end if;
      Cursor := Self.Lists.Element (List.List_Data).First_Element;
      for Position in 1 .. Index - 1 loop
         pragma Unreferenced (Position);
         Cursor := Self.Elements.Element (Cursor).Next;
      end loop;
      return Self.Elements.Element (Cursor).Value;
   end Element;

   function Cell
     (Self : Builder; List : Dynamic_Value; Index : Positive)
      return Dynamic_Value
   is
      pragma Unreferenced (Self);
   begin
      if List.Kind /= List_Value then
         raise Constraint_Error with "cell requested for a non-list value";
      end if;
      return
        (Kind => Cell_Value, Cell_List => List.List_Data,
         Cell_Index => Index, others => <>);
   end Cell;

   function Cell_Element
     (Self : Builder; Item : Dynamic_Value) return Dynamic_Value is
     (Self.Element
        ((Kind => List_Value, List_Data => Item.Cell_List, others => <>),
         Positive (Item.Cell_Index)));

   function Next_Cell
     (Self : Builder; List, Item : Dynamic_Value) return Dynamic_Value is
     (if Item.Kind = Cell_Value and then Item.Cell_Index < Self.Length (List)
      then
        (Kind => Cell_Value, Cell_List => List.List_Data,
         Cell_Index => Item.Cell_Index + 1, others => <>)
      else No_Value);

   function Copy
     (Self : in out Builder; Item : Dynamic_Value) return Dynamic_Value
   is
   begin
      case Item.Kind is
         when Object_Value =>
            declare
               Result : constant Dynamic_Value :=
                 Self.New_Object (Self.Object_Type (Item));
               Cursor : Natural :=
                 Self.Objects.Element (Item.Object_Data).First_Member;
            begin
               while Cursor /= 0 loop
                  declare
                     Member : constant Member_Entry := Self.Members.Element (Cursor);
                  begin
                     Self.Set_Field
                       (Result, To_String (Member.Name), Self.Copy (Member.Value));
                     Cursor := Member.Next;
                  end;
               end loop;
               return Result;
            end;
         when List_Value =>
            declare
               Result : Dynamic_Value := Self.New_List;
            begin
               for Index in 1 .. Self.Length (Item) loop
                  Result := Self.Append (Result, Self.Copy (Self.Element (Item, Index)));
               end loop;
               return Result;
            end;
         when Cell_Value =>
            return Self.Copy (Self.Cell_Element (Item));
         when Field_Reference_Value =>
            return Self.Copy (Self.Dereference (Item));
         when others =>
            return Item;
      end case;
   end Copy;

   function Equivalent
     (Self : Builder; Left, Right : Dynamic_Value) return Boolean
   is
   begin
      if Left.Kind /= Right.Kind then
         return False;
      end if;
      case Left.Kind is
         when Null_Value => return True;
         when Integer_Value => return Left.Integer_Data = Right.Integer_Data;
         when Boolean_Value => return Left.Boolean_Data = Right.Boolean_Data;
         when Text_Value => return Left.Text_Data = Right.Text_Data;
         when List_Value =>
            if Self.Length (Left) /= Self.Length (Right) then
               return False;
            end if;
            for Index in 1 .. Self.Length (Left) loop
               if not Self.Equivalent
                 (Self.Element (Left, Index), Self.Element (Right, Index))
               then
                  return False;
               end if;
            end loop;
            return True;
         when Object_Value =>
            if Self.Object_Type (Left) /= Self.Object_Type (Right) then
               return False;
            end if;
            declare
               Left_Cursor  : Natural :=
                 Self.Objects.Element (Left.Object_Data).First_Member;
               Right_Cursor : Natural :=
                 Self.Objects.Element (Right.Object_Data).First_Member;
            begin
               loop
                  while Left_Cursor /= 0
                    and then To_String
                      (Self.Members.Element (Left_Cursor).Name) = "location"
                  loop
                     Left_Cursor := Self.Members.Element (Left_Cursor).Next;
                  end loop;
                  while Right_Cursor /= 0
                    and then To_String
                      (Self.Members.Element (Right_Cursor).Name) = "location"
                  loop
                     Right_Cursor := Self.Members.Element (Right_Cursor).Next;
                  end loop;
                  exit when Left_Cursor = 0 or else Right_Cursor = 0;
                  declare
                     L : constant Member_Entry := Self.Members.Element (Left_Cursor);
                     R : constant Member_Entry := Self.Members.Element (Right_Cursor);
                  begin
                     if L.Name /= R.Name or else not Self.Equivalent (L.Value, R.Value) then
                        return False;
                     end if;
                     Left_Cursor := L.Next;
                     Right_Cursor := R.Next;
                  end;
               end loop;
               return Left_Cursor = 0 and then Right_Cursor = 0;
            end;
         when Cell_Value =>
            return Self.Equivalent
              (Self.Cell_Element (Left), Self.Cell_Element (Right));
         when Field_Reference_Value =>
            return Self.Equivalent
              (Self.Dereference (Left), Self.Dereference (Right));
      end case;
   end Equivalent;

   function Field_Reference
     (Item : Dynamic_Value; Name : String) return Dynamic_Value is
     ((Kind             => Field_Reference_Value,
       Reference_Object => Item.Object_Data,
       Reference_Field  => To_Unbounded_String (Name),
       others           => <>));

   function Dereference
     (Self : Builder; Item : Dynamic_Value) return Dynamic_Value is
     (case Item.Kind is
         when Field_Reference_Value =>
           Self.Field
             ((Kind => Object_Value, Object_Data => Item.Reference_Object,
               others => <>),
              To_String (Item.Reference_Field)),
         when Cell_Value => Self.Cell_Element (Item),
         when others => Item);

   procedure Assign
     (Self : in out Builder; Target : Dynamic_Value; Value : Dynamic_Value) is
   begin
      Self.Set_Field
        ((Kind => Object_Value, Object_Data => Target.Reference_Object,
          others => <>),
         To_String (Target.Reference_Field), Value);
   end Assign;

end Flyology.Postgres.SQL.Native.Builders;
