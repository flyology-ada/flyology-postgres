with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Interfaces;

with Flyology.Postgres.SQL.Arena_Storage; use Flyology.Postgres.SQL.Arena_Storage;

package body Flyology.Postgres.SQL.Native.Converters is

   use type Builders.Value_Kind;
   use type Schema.Value_Kind;
   use type Interfaces.Integer_64;

   procedure Load
     (Tree           : in out Syntax_Tree;
      Build          : Builders.Builder;
      Root           : Builders.Dynamic_Value;
      Version_Number : Interfaces.Integer_64;
      Node_Message   : Positive;
      List_Message   : Positive;
      Raw_Stmt_Message : Positive;
      Messages       : Schema.Message_Array;
      Fields         : Schema.Field_Array;
      Enums          : Schema.Enum_Array;
      Enum_Values    : Schema.Enum_Value_Array;
      Result         : out Value_Id)
   is
      function Convert_Message
        (Message : Positive; Item : Builders.Dynamic_Value; Depth : Natural)
         return Value_Id;

      function Convert_Scalar
        (Field : Schema.Field_Descriptor; Item : Builders.Dynamic_Value)
         return Value_Id;

      function Is_Default
        (Field : Schema.Field_Descriptor; Item : Builders.Dynamic_Value)
         return Boolean;

      function Source_Field
        (Message : Schema.Message_Descriptor; Item : Builders.Dynamic_Value;
         Field : Schema.Field_Descriptor) return Builders.Dynamic_Value
      is
         Result : Builders.Dynamic_Value :=
           Build.Field (Item, To_String (Field.Source_Name));
         Name : constant String := To_String (Message.Name);
      begin
         if Result.Kind = Builders.Null_Value
           and then To_String (Field.Source_Name) = "str"
         then
            if Name = "String" then
               Result := Build.Field (Item, "sval");
            elsif Name = "Float" then
               Result := Build.Field (Item, "fval");
            elsif Name = "BitString" then
               Result := Build.Field (Item, "bsval");
            end if;
         end if;
         return Result;
      end Source_Field;

      function Convert_Enum
        (Enum : Positive; Item : Builders.Dynamic_Value) return Value_Id is
      begin
         if Item.Kind /= Builders.Integer_Value then
            raise Converter_Error with "integer enum value required";
         end if;
         declare
            Descriptor : constant Schema.Enum_Descriptor := Enums (Enum);
         begin
            for Index in Descriptor.First_Value ..
              Descriptor.First_Value + Descriptor.Value_Count - 1
            loop
               if Enum_Values (Index).Source_Number = Item.Integer_Data then
                  return Store_Text (Tree, To_String (Enum_Values (Index).Name));
               end if;
            end loop;
         end;
         raise Converter_Error with "unknown generated enum numeric value";
      end Convert_Enum;

      function Convert_Node
        (Item : Builders.Dynamic_Value; Depth : Natural) return Value_Id
      is
         Members : Member_Vectors.Vector;
         Value   : Value_Id;
      begin
         if Depth > Maximum_Conversion_Depth then
            raise Converter_Error with "excessive native AST recursion";
         end if;
         Value := Begin_Object (Tree);
         if Item.Kind = Builders.Null_Value then
            Finish_Object (Tree, Value, Members);
            return Value;
         end if;
         declare
            Node_Descriptor : constant Schema.Message_Descriptor :=
              Messages (Node_Message);
            Type_Name : constant String :=
              (if Item.Kind = Builders.List_Value then "List"
               elsif Item.Kind = Builders.Object_Value then
                 Build.Object_Type (Item)
               else "");
            Found : Boolean := False;
         begin
            for Index in Node_Descriptor.First_Field ..
              Node_Descriptor.First_Field + Node_Descriptor.Field_Count - 1
            loop
               declare
                  Field : constant Schema.Field_Descriptor := Fields (Index);
               begin
                  if Field.Kind = Schema.Message_Value
                    and then To_String (Messages (Field.Target).Name) = Type_Name
                  then
                     Set_Member
                       (Members, To_String (Field.Output_Name),
                        Convert_Message (Field.Target, Item, Depth + 1));
                     Found := True;
                     exit;
                  end if;
               end;
            end loop;
            if not Found then
               raise Converter_Error with
                 "protobuf Node has no variant for native " &
                 Item.Kind'Image & " value " & Type_Name;
            end if;
         end;
         Finish_Object (Tree, Value, Members);
         return Value;
      end Convert_Node;

      function Convert_Scalar
        (Field : Schema.Field_Descriptor; Item : Builders.Dynamic_Value)
         return Value_Id is
      begin
         case Field.Kind is
            when Schema.Boolean_Value =>
               return Store_Boolean
                 (Tree,
                  (case Item.Kind is
                      when Builders.Boolean_Value => Item.Boolean_Data,
                      when Builders.Integer_Value => Item.Integer_Data /= 0,
                      when others =>
                        raise Converter_Error with
                          "boolean value required for " &
                          To_String (Field.Source_Name)));
            when Schema.Signed_Value =>
               if Item.Kind /= Builders.Integer_Value then
                  raise Converter_Error with
                    "signed integer value required for " &
                    To_String (Field.Source_Name);
               end if;
               return Store_Signed (Tree, Item.Integer_Data);
            when Schema.Unsigned_Value =>
               if Item.Kind /= Builders.Integer_Value or else Item.Integer_Data < 0 then
                  raise Converter_Error with
                    "unsigned integer value required for " &
                    To_String (Field.Source_Name);
               end if;
               return Store_Unsigned
                 (Tree, Interfaces.Unsigned_64 (Item.Integer_Data));
            when Schema.Float_Value =>
               raise Converter_Error with
                 "native raw grammar produced an unexpected protobuf float scalar";
            when Schema.Text_Value =>
               if Item.Kind = Builders.Integer_Value
                 and then Item.Integer_Data in 0 .. 255
               then
                  return Store_Text
                    (Tree, (1 => Character'Val (Item.Integer_Data)));
               elsif Item.Kind /= Builders.Text_Value then
                  raise Converter_Error with
                    "text value required for " & To_String (Field.Source_Name);
               end if;
               return Store_Text (Tree, To_String (Item.Text_Data));
            when Schema.Message_Value =>
               if Field.Target = Node_Message then
                  return Convert_Node (Item, 1);
               end if;
               return Convert_Message (Field.Target, Item, 1);
            when Schema.Enum_Value =>
               return Convert_Enum (Field.Target, Item);
         end case;
      end Convert_Scalar;

      function Convert_Inline_Message
        (Message : Positive; Scalar : Builders.Dynamic_Value; Depth : Natural)
         return Value_Id
      is
         Descriptor : constant Schema.Message_Descriptor := Messages (Message);
         Members    : Member_Vectors.Vector;
         Value      : constant Value_Id := Begin_Object (Tree);
      begin
         if Depth > Maximum_Conversion_Depth then
            raise Converter_Error with "excessive inline-node recursion";
         end if;
         if Descriptor.Field_Count > 0 then
            declare
               Field : constant Schema.Field_Descriptor :=
                 Fields (Descriptor.First_Field);
            begin
               if Scalar.Kind /= Builders.Null_Value
                 and then not Is_Default (Field, Scalar)
               then
                  Set_Member
                    (Members, To_String (Field.Output_Name),
                     Convert_Scalar (Field, Scalar));
               end if;
            end;
         end if;
         Finish_Object (Tree, Value, Members);
         return Value;
      end Convert_Inline_Message;

      function Convert_Inline_Node
        (Tag : Interfaces.Integer_64; Scalar : Builders.Dynamic_Value;
         Depth : Natural) return Value_Id
      is
         Node_Descriptor : constant Schema.Message_Descriptor :=
           Messages (Node_Message);
         Members : Member_Vectors.Vector;
         Value   : constant Value_Id := Begin_Object (Tree);
      begin
         for Index in Node_Descriptor.First_Field ..
           Node_Descriptor.First_Field + Node_Descriptor.Field_Count - 1
         loop
            declare
               Field : constant Schema.Field_Descriptor := Fields (Index);
            begin
               if Field.Kind = Schema.Message_Value
                 and then Messages (Field.Target).Node_Tag = Tag
               then
                  Set_Member
                    (Members, To_String (Field.Output_Name),
                     Convert_Inline_Message (Field.Target, Scalar, Depth + 1));
                  Finish_Object (Tree, Value, Members);
                  return Value;
               end if;
            end;
         end loop;
         raise Converter_Error with "unknown inline PostgreSQL NodeTag";
      end Convert_Inline_Node;

      function Is_Default
        (Field : Schema.Field_Descriptor; Item : Builders.Dynamic_Value)
         return Boolean is
      begin
         case Field.Kind is
            when Schema.Boolean_Value =>
               return
                 (Item.Kind = Builders.Boolean_Value and then not Item.Boolean_Data)
                 or else
                 (Item.Kind = Builders.Integer_Value and then Item.Integer_Data = 0);
            when Schema.Signed_Value | Schema.Unsigned_Value =>
               return Item.Kind = Builders.Integer_Value and then Item.Integer_Data = 0;
            when Schema.Enum_Value =>
               if Item.Kind /= Builders.Integer_Value then
                  return False;
               end if;
               declare
                  Descriptor : constant Schema.Enum_Descriptor :=
                    Enums (Field.Target);
               begin
                  for Index in Descriptor.First_Value ..
                    Descriptor.First_Value + Descriptor.Value_Count - 1
                  loop
                     if Enum_Values (Index).Source_Number = Item.Integer_Data then
                        return Enum_Values (Index).Wire_Number = 0;
                     end if;
                  end loop;
                  return False;
               end;
            when Schema.Float_Value =>
               return False;
            when Schema.Text_Value =>
               return
                 (Item.Kind = Builders.Text_Value and then Length (Item.Text_Data) = 0)
                 or else
                 (Item.Kind = Builders.Integer_Value and then Item.Integer_Data = 0);
            when Schema.Message_Value =>
               return False;
         end case;
      end Is_Default;

      function Convert_Message
        (Message : Positive; Item : Builders.Dynamic_Value; Depth : Natural)
         return Value_Id
      is
         Descriptor : constant Schema.Message_Descriptor := Messages (Message);
         Members    : Member_Vectors.Vector;
         Value      : constant Value_Id := Begin_Object (Tree);
      begin
         if Depth > Maximum_Conversion_Depth then
            raise Converter_Error with "excessive native AST recursion";
         end if;
         if Message /= List_Message
           and then
             (Item.Kind /= Builders.Object_Value
              or else Build.Object_Type (Item) /= To_String (Descriptor.Name))
         then
            raise Converter_Error with
              "expected native " & To_String (Descriptor.Name) & " object";
         end if;

         if Descriptor.Field_Count > 0 then
            for Index in Descriptor.First_Field ..
              Descriptor.First_Field + Descriptor.Field_Count - 1
            loop
               declare
                  Field : constant Schema.Field_Descriptor := Fields (Index);
                  Stored_Source : constant Builders.Dynamic_Value :=
                    (if Message = List_Message
                       and then Item.Kind = Builders.List_Value
                     then Item
                     else Source_Field (Descriptor, Item, Field));
                  Source : constant Builders.Dynamic_Value :=
                    (if not Field.Repeated
                       and then Field.Kind = Schema.Enum_Value
                       and then Stored_Source.Kind = Builders.Null_Value
                     then Builders.Number (0)
                     else Stored_Source);
               begin
                  if To_String (Descriptor.Name) = "A_Const"
                    and then not Field.Repeated
                    and then Field.Kind = Schema.Message_Value
                    and then Stored_Source.Kind = Builders.Null_Value
                  then
                     if Field.Target = Node_Message then
                        declare
                           Tag : constant Builders.Dynamic_Value :=
                             Build.Field (Item, "val.type");
                           Scalar : Builders.Dynamic_Value := Builders.No_Value;
                        begin
                           if Tag.Kind = Builders.Integer_Value then
                              for Node_Field_Index in
                                Messages (Node_Message).First_Field ..
                                Messages (Node_Message).First_Field +
                                  Messages (Node_Message).Field_Count - 1
                              loop
                                 declare
                                    Node_Field : constant
                                      Schema.Field_Descriptor :=
                                        Fields (Node_Field_Index);
                                 begin
                                    if Node_Field.Kind = Schema.Message_Value
                                      and then
                                        Messages (Node_Field.Target).Node_Tag =
                                          Tag.Integer_Data
                                      and then
                                        Messages (Node_Field.Target).Field_Count > 0
                                    then
                                       declare
                                          Inner : constant
                                            Schema.Field_Descriptor :=
                                              Fields
                                                (Messages
                                                   (Node_Field.Target).First_Field);
                                       begin
                                          Scalar := Build.Field
                                            (Item, "val.val." &
                                             To_String (Inner.Source_Name));
                                       end;
                                    end if;
                                 end;
                              end loop;
                              Set_Member
                                (Members, To_String (Field.Output_Name),
                                 Convert_Inline_Node
                                   (Tag.Integer_Data, Scalar, Depth + 1));
                           end if;
                        end;
                     elsif Messages (Field.Target).Field_Count > 0 then
                        declare
                           Inner : constant Schema.Field_Descriptor :=
                             Fields (Messages (Field.Target).First_Field);
                           Prefix : constant String :=
                             "val." & To_String (Field.Source_Name) & ".";
                           Marker : constant Builders.Dynamic_Value :=
                             Build.Field (Item, Prefix & "type");
                           Scalar : constant Builders.Dynamic_Value :=
                             Build.Field
                               (Item, Prefix & To_String (Inner.Source_Name));
                        begin
                           if Marker.Kind /= Builders.Null_Value then
                              Set_Member
                                (Members, To_String (Field.Output_Name),
                                 Convert_Inline_Message
                                   (Field.Target, Scalar, Depth + 1));
                           end if;
                        end;
                     end if;
                  elsif Field.Repeated then
                     if Source.Kind = Builders.Null_Value then
                        null;
                     elsif Source.Kind /= Builders.List_Value then
                        raise Converter_Error with
                          "list value required for " &
                          To_String (Field.Source_Name);
                     elsif Build.Length (Source) > 0 then
                        declare
                           Elements : Element_Vectors.Vector;
                        begin
                           for Position in 1 .. Build.Length (Source) loop
                              declare
                                 Element : constant Builders.Dynamic_Value :=
                                   Build.Element (Source, Position);
                              begin
                                 if Field.Kind = Schema.Message_Value
                                   and then Field.Target = Node_Message
                                 then
                                    Elements.Append
                                      (Convert_Node (Element, Depth + 1));
                                 elsif Field.Kind = Schema.Message_Value then
                                    Elements.Append
                                      (Convert_Message
                                         (Field.Target, Element, Depth + 1));
                                 elsif Field.Kind = Schema.Enum_Value then
                                    Elements.Append
                                      (Convert_Enum (Field.Target, Element));
                                 else
                                    Elements.Append
                                      (Convert_Scalar (Field, Element));
                                 end if;
                              end;
                           end loop;
                           Set_Member
                             (Members, To_String (Field.Output_Name),
                              Make_Array (Tree, Elements));
                        end;
                     end if;
                  elsif Source.Kind /= Builders.Null_Value
                    and then not Is_Default (Field, Source)
                  then
                     if Field.Kind = Schema.Message_Value
                       and then Field.Target = Node_Message
                     then
                        Set_Member
                          (Members, To_String (Field.Output_Name),
                           Convert_Node (Source, Depth + 1));
                     elsif Field.Kind = Schema.Message_Value then
                        Set_Member
                          (Members, To_String (Field.Output_Name),
                           Convert_Message (Field.Target, Source, Depth + 1));
                     elsif Field.Kind = Schema.Enum_Value then
                        Set_Member
                          (Members, To_String (Field.Output_Name),
                           Convert_Enum (Field.Target, Source));
                     else
                        Set_Member
                          (Members, To_String (Field.Output_Name),
                           Convert_Scalar (Field, Source));
                     end if;
                  end if;
               exception
                  when Error : Converter_Error =>
                     raise Converter_Error with
                       To_String (Descriptor.Name) & "." &
                       To_String (Field.Source_Name) & ": " &
                       Ada.Exceptions.Exception_Message (Error);
               end;
            end loop;
         end if;
         Finish_Object (Tree, Value, Members);
         return Value;
      end Convert_Message;

      Members : Member_Vectors.Vector;
      Stmts   : Element_Vectors.Vector;
   begin
      if Root.Kind not in Builders.Null_Value | Builders.List_Value then
         raise Converter_Error with "native parser root is not a statement list";
      end if;
      Result := Begin_Object (Tree);
      Set_Member (Members, "version", Store_Signed (Tree, Version_Number));
      for Index in 1 .. Build.Length (Root) loop
         declare
            Item : constant Builders.Dynamic_Value := Build.Element (Root, Index);
         begin
            if Item.Kind = Builders.Object_Value
              and then Build.Object_Type (Item) = "RawStmt"
            then
               Stmts.Append (Convert_Message (Raw_Stmt_Message, Item, 1));
            else
               --  PostgreSQL's alternate raw-parse modes return their node
               --  directly in the parser list.  Normalize that result into
               --  the ParseResult/RawStmt envelope used by the public API.
               declare
                  Raw_Members : Member_Vectors.Vector;
                  Raw         : constant Value_Id := Begin_Object (Tree);
               begin
                  Set_Member
                    (Raw_Members, "stmt", Convert_Node (Item, 1));
                  Finish_Object (Tree, Raw, Raw_Members);
                  Stmts.Append (Raw);
               end;
            end if;
         end;
      end loop;
      if not Stmts.Is_Empty then
         Set_Member (Members, "stmts", Make_Array (Tree, Stmts));
      end if;
      Finish_Object (Tree, Result, Members);
   end Load;

end Flyology.Postgres.SQL.Native.Converters;
