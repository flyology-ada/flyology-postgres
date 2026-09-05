with Ada.Characters.Handling;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Unchecked_Conversion;
package body Flyology.Postgres.SQL.Native.Semantics is

   use type Interfaces.Integer_64;
   use type Interfaces.Unsigned_64;
   use type Builders.Dynamic_Value;
   use type Builders.Value_Kind;

   function To_Unsigned is new Ada.Unchecked_Conversion
     (Source => Interfaces.Integer_64, Target => Interfaces.Unsigned_64);
   function To_Integer is new Ada.Unchecked_Conversion
     (Source => Interfaces.Unsigned_64, Target => Interfaces.Integer_64);

   function Truth (Value : Builders.Dynamic_Value) return Boolean is
     (case Value.Kind is
         when Builders.Null_Value => False,
         when Builders.Boolean_Value => Value.Boolean_Data,
         when Builders.Integer_Value => Value.Integer_Data /= 0,
         when others => True);

   function Integer_Of (Value : Builders.Dynamic_Value) return Interfaces.Integer_64 is
     (case Value.Kind is
         when Builders.Integer_Value => Value.Integer_Data,
         when Builders.Boolean_Value => Boolean'Pos (Value.Boolean_Data),
         when Builders.Null_Value => 0,
         when others => raise Constraint_Error with "integer value required");

   function Text_Of (Value : Builders.Dynamic_Value) return String is
     (case Value.Kind is
         when Builders.Text_Value => To_String (Value.Text_Data),
         when Builders.Null_Value => "",
         when others => raise Constraint_Error with "text value required");

   function Binary
     (Operator : String; Left, Right : Builders.Dynamic_Value)
      return Builders.Dynamic_Value
   is
      L : Interfaces.Integer_64;
      R : Interfaces.Integer_64;
   begin
      if Operator = "==" or else Operator = "!=" then
         declare
            Equal : constant Boolean :=
              (if Left.Kind /= Right.Kind then
                  Left.Kind = Builders.Null_Value
                    and then not Truth (Right)
               else
                 (case Left.Kind is
                     when Builders.Null_Value => True,
                     when Builders.Integer_Value =>
                       Left.Integer_Data = Right.Integer_Data,
                     when Builders.Boolean_Value =>
                       Left.Boolean_Data = Right.Boolean_Data,
                     when Builders.Text_Value => Left.Text_Data = Right.Text_Data,
                     when Builders.Object_Value =>
                       Left.Object_Data = Right.Object_Data,
                     when Builders.List_Value => Left.List_Data = Right.List_Data,
                     when Builders.Cell_Value =>
                       Left.Cell_List = Right.Cell_List
                         and then Left.Cell_Index = Right.Cell_Index,
                     when Builders.Field_Reference_Value => False));
         begin
            return Builders.Flag (if Operator = "==" then Equal else not Equal);
         end;
      elsif Operator = "&&" then
         return Builders.Flag (Truth (Left) and then Truth (Right));
      elsif Operator = "||" then
         return Builders.Flag (Truth (Left) or else Truth (Right));
      elsif Operator = "," then
         return Right;
      end if;

      L := Integer_Of (Left);
      R := Integer_Of (Right);
      if Operator = "+" then
         return Builders.Number (L + R);
      elsif Operator = "-" then
         return Builders.Number (L - R);
      elsif Operator = "*" then
         return Builders.Number (L * R);
      elsif Operator = "/" then
         return Builders.Number (L / R);
      elsif Operator = "%" then
         return Builders.Number (L rem R);
      elsif Operator = "<" then
         return Builders.Flag (L < R);
      elsif Operator = ">" then
         return Builders.Flag (L > R);
      elsif Operator = "<=" then
         return Builders.Flag (L <= R);
      elsif Operator = ">=" then
         return Builders.Flag (L >= R);
      elsif Operator = "&" then
         return Builders.Number
           (To_Integer (To_Unsigned (L) and To_Unsigned (R)));
      elsif Operator = "|" then
         return Builders.Number
           (To_Integer (To_Unsigned (L) or To_Unsigned (R)));
      elsif Operator = "<<" then
         return Builders.Number
           (To_Integer
              (Interfaces.Shift_Left (To_Unsigned (L), Natural (R))));
      elsif Operator = ">>" then
         return Builders.Number
           (To_Integer
              (Interfaces.Shift_Right (To_Unsigned (L), Natural (R))));
      else
         raise Program_Error with "unsupported generated binary operator " & Operator;
      end if;
   end Binary;

   function Unary
     (Operator : String; Value : Builders.Dynamic_Value)
      return Builders.Dynamic_Value is
   begin
      if Operator = "!" then
         return Builders.Flag (not Truth (Value));
      elsif Operator = "-" then
         return Builders.Number (-Integer_Of (Value));
      elsif Operator = "+" then
         return Builders.Number (Integer_Of (Value));
      elsif Operator = "--" then
         return Builders.Number (Integer_Of (Value) - 1);
      elsif Operator = "++" then
         return Builders.Number (Integer_Of (Value) + 1);
      elsif Operator = "~" then
         --  Avoid a range check when a modular all-ones result is converted
         --  back to Integer_64.  This is the two's-complement identity used
         --  by PostgreSQL's signed flag values.
         return Builders.Number (-Integer_Of (Value) - 1);
      else
         raise Program_Error with "unsupported generated unary operator " & Operator;
      end if;
   end Unary;

   function Node_Is
     (Build : not null access Builders.Builder; Value : Builders.Dynamic_Value;
      Type_Name : String) return Builders.Dynamic_Value is
   begin
      return Builders.Flag
        ((Value.Kind = Builders.Object_Value
          and then Build.Object_Type (Value) = Type_Name)
         or else
           (Value.Kind = Builders.Object_Value
            and then Build.Object_Type (Value) = "A_Const"
            and then Type_Name = "String"
            and then
              (Build.Field (Value, "val.sval.sval") /= Builders.No_Value
               or else Build.Field (Value, "val.val.str") /= Builders.No_Value))
         or else
           (Value.Kind = Builders.List_Value and then Type_Name = "List"));
   end Node_Is;

   function Set_Field
     (Build : not null access Builders.Builder; Item : Builders.Dynamic_Value;
      Name : String; Value : Builders.Dynamic_Value)
      return Builders.Dynamic_Value is
   begin
      Build.Set_Field (Item, Name, Value);
      return Value;
   end Set_Field;

   function Invoke
     (Build : not null access Builders.Builder; Name : String;
      Arguments : Builders.Semantic_Array) return Builders.Dynamic_Value
   is
      function Argument (Index : Positive) return Builders.Dynamic_Value is
        (Arguments (Arguments'First + Index - 1));

      function Negated (Value : Builders.Dynamic_Value)
         return Builders.Dynamic_Value
      is
         Text : constant String := Text_Of (Value);
      begin
         if Text'Length > 0 and then Text (Text'First) = '+' then
            return Builders.Text ("-" & Text (Text'First + 1 .. Text'Last));
         elsif Text'Length > 0 and then Text (Text'First) = '-' then
            return Builders.Text (Text (Text'First + 1 .. Text'Last));
         else
            return Builders.Text ("-" & Text);
         end if;
      end Negated;

      Result : Builders.Dynamic_Value;
   begin
      if Name in "pstrdup" | "castNode" then
         return Argument (1);
      elsif Name = "lappend" then
         return Build.Append (Argument (1), Argument (2));
      elsif Name = "lcons" then
         return Build.Prepend (Argument (1), Argument (2));
      elsif Name = "list_concat" then
         return Build.Concatenate (Argument (1), Argument (2));
      elsif Name = "list_length" then
         return Builders.Number (Interfaces.Integer_64 (Build.Length (Argument (1))));
      elsif Name = "list_make1_impl" then
         return Build.List_Of (Argument (Arguments'Length));
      elsif Name = "list_make2_impl" then
         Result := Build.List_Of (Argument (Arguments'Length - 1));
         return Build.Append (Result, Argument (Arguments'Length));
      elsif Name = "list_make3_impl" then
         Result := Build.List_Of (Argument (Arguments'Length - 2));
         Result := Build.Append (Result, Argument (Arguments'Length - 1));
         return Build.Append (Result, Argument (Arguments'Length));
      elsif Name = "list_make4_impl" then
         Result := Build.List_Of (Argument (Arguments'Length - 3));
         Result := Build.Append (Result, Argument (Arguments'Length - 2));
         Result := Build.Append (Result, Argument (Arguments'Length - 1));
         return Build.Append (Result, Argument (Arguments'Length));
      elsif Name = "list_delete_cell" then
         return Build.Delete (Argument (1), Positive (Argument (2).Cell_Index));
      elsif Name = "list_delete_nth_cell" then
         return Build.Delete
           (Argument (1), Positive (Integer_Of (Argument (2)) + 1));
      elsif Name = "list_truncate" then
         return Build.Truncate (Argument (1), Natural (Integer_Of (Argument (2))));
      elsif Name = "list_copy_tail" then
         declare
            Source : constant Builders.Dynamic_Value := Argument (1);
            Skip   : constant Natural := Natural (Integer_Of (Argument (2)));
            Copy   : Builders.Dynamic_Value := Build.New_List;
         begin
            if Skip < Build.Length (Source) then
               for Index in Skip + 1 .. Build.Length (Source) loop
                  Copy := Build.Append (Copy, Build.Element (Source, Index));
               end loop;
            end if;
            return Copy;
         end;
      elsif Name = "lnext" then
         return Build.Next_Cell (Argument (1), Argument (2));
      elsif Name = "list_nth_cell" then
         return Build.Cell
           (Argument (1), Positive (Integer_Of (Argument (2)) + 1));
      elsif Name = "list_last_cell" then
         return Build.Cell (Argument (1), Build.Length (Argument (1)));
      elsif Name = "strcmp" then
         return Builders.Number
           (if Text_Of (Argument (1)) > Text_Of (Argument (2)) then 1
            elsif Text_Of (Argument (1)) < Text_Of (Argument (2)) then -1
            else 0);
      elsif Name = "pg_strcasecmp" then
         return Builders.Number
           (if Ada.Characters.Handling.To_Lower (Text_Of (Argument (1))) >
               Ada.Characters.Handling.To_Lower (Text_Of (Argument (2)))
            then 1
            elsif Ada.Characters.Handling.To_Lower (Text_Of (Argument (1))) <
                  Ada.Characters.Handling.To_Lower (Text_Of (Argument (2)))
            then -1
            else 0);
      elsif Name = "copyObjectImpl" then
         return Build.Copy (Argument (1));
      elsif Name = "equal" then
         return Builders.Flag (Build.Equivalent (Argument (1), Argument (2)));
      elsif Name = "defGetInt32" then
         declare
            Item : constant Builders.Dynamic_Value :=
              Build.Field (Argument (1), "arg");
         begin
            if Item.Kind = Builders.Object_Value
              and then Build.Object_Type (Item) = "Integer"
            then
               return Build.Field (Item, "ival");
            end if;
            raise Parser_Error with "definition requires an integer value";
         end;
      elsif Name = "psprintf" then
         declare
            Format        : constant String := Text_Of (Argument (1));
            Rendered      : Unbounded_String;
            Index         : Natural := Format'First;
            Next_Argument : Positive := 2;

            function Integer_Text (Value : Builders.Dynamic_Value) return String
            is
               Image : constant String :=
                 Interfaces.Integer_64'Image (Integer_Of (Value));
            begin
               return Image
                 ((if Image (Image'First) = ' ' then Image'First + 1
                   else Image'First) .. Image'Last);
            end Integer_Text;

            procedure Append_Argument (Specifier : Character) is
            begin
               if Next_Argument > Arguments'Length then
                  raise Program_Error with
                    "missing generated psprintf argument for " & Format;
               end if;
               case Specifier is
                  when 's' =>
                     Append (Rendered, Text_Of (Argument (Next_Argument)));
                  when 'd' =>
                     Append
                       (Rendered, Integer_Text (Argument (Next_Argument)));
                  when others =>
                     raise Program_Error with
                       "unsupported generated psprintf format " & Format;
               end case;
               Next_Argument := Next_Argument + 1;
            end Append_Argument;
         begin
            while Index <= Format'Last loop
               if Format (Index) /= '%' then
                  Append (Rendered, Format (Index));
               else
                  Index := Index + 1;
                  if Index > Format'Last then
                     raise Program_Error with
                       "unsupported generated psprintf format " & Format;
                  elsif Format (Index) = '%' then
                     Append (Rendered, '%');
                  else
                     Append_Argument (Format (Index));
                  end if;
               end if;
               Index := Index + 1;
            end loop;
            if Next_Argument <= Arguments'Length then
               raise Program_Error with
                 "extra generated psprintf arguments for " & Format;
            end if;
            return Builders.Text (To_String (Rendered));
         end;
      elsif Name in "makeString" | "makeFloat" | "makeInteger" | "makeBoolean" then
         declare
            Type_Name : constant String :=
              (if Name = "makeString" then "String"
               elsif Name = "makeFloat" then "Float"
               elsif Name = "makeInteger" then "Integer"
               else "Boolean");
            Field_Name : constant String :=
              (if Name = "makeString" then "sval"
               elsif Name = "makeFloat" then "fval"
               elsif Name = "makeInteger" then "ival"
               else "boolval");
            Object : constant Builders.Dynamic_Value := Build.New_Object (Type_Name);
         begin
            Build.Set_Field (Object, Field_Name, Argument (1));
            return Object;
         end;
      elsif Name = "makeDefElem" then
         Result := Build.New_Object ("DefElem");
         Build.Set_Field (Result, "defname", Argument (1));
         Build.Set_Field (Result, "arg", Argument (2));
         Build.Set_Field (Result, "location", Argument (3));
         return Result;
      elsif Name = "makeRawStmt" then
         Result := Build.New_Object ("RawStmt");
         Build.Set_Field (Result, "stmt", Argument (1));
         Build.Set_Field (Result, "stmt_location", Argument (2));
         Build.Set_Field (Result, "stmt_len", Builders.Number (0));
         return Result;
      elsif Name = "doNegate" then
         declare
            Item     : constant Builders.Dynamic_Value := Argument (1);
            Integer_14 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.val.ival");
            Integer_15 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.ival.ival");
            Float_14 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.val.str");
            Float_14_Tag : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.type");
            Float_15 : constant Builders.Dynamic_Value :=
              Build.Field (Item, "val.fval.fval");
         begin
            if Item.Kind = Builders.Object_Value
              and then Build.Object_Type (Item) = "A_Const"
            then
               Build.Set_Field (Item, "location", Argument (2));
               if Integer_14.Kind = Builders.Integer_Value then
                  Build.Set_Field
                    (Item, "val.val.ival", Unary ("-", Integer_14));
                  return Item;
               elsif Integer_15.Kind = Builders.Integer_Value then
                  Build.Set_Field
                    (Item, "val.ival.ival", Unary ("-", Integer_15));
                  return Item;
               --  PostgreSQL 14 nodes.h assigns 227 to T_Float; gram.y folds
               --  only that tag in doNegate.
               elsif Float_14.Kind = Builders.Text_Value
                 and then Float_14_Tag.Kind = Builders.Integer_Value
                 and then Float_14_Tag.Integer_Data = 227
               then
                  Build.Set_Field (Item, "val.val.str", Negated (Float_14));
                  return Item;
               elsif Float_15.Kind = Builders.Text_Value then
                  Build.Set_Field (Item, "val.fval.fval", Negated (Float_15));
                  return Item;
               end if;
            end if;

            Result := Build.New_Object ("A_Expr");
            Build.Set_Field (Result, "kind", Builders.Number (0));
            declare
               Operator : constant Builders.Dynamic_Value :=
                 Build.New_Object ("String");
            begin
               Build.Set_Field (Operator, "sval", Builders.Text ("-"));
               Build.Set_Field (Result, "name", Build.List_Of (Operator));
            end;
            Build.Set_Field (Result, "lexpr", Builders.No_Value);
            Build.Set_Field (Result, "rexpr", Item);
            Build.Set_Field (Result, "location", Argument (2));
            return Result;
         end;
      elsif Name = "doNegateFloat" then
         declare
            Item : constant Builders.Dynamic_Value := Argument (1);
            Fval : constant Builders.Dynamic_Value := Build.Field (Item, "fval");
            Str  : constant Builders.Dynamic_Value := Build.Field (Item, "str");
         begin
            if Fval.Kind = Builders.Text_Value then
               Build.Set_Field (Item, "fval", Negated (Fval));
            elsif Str.Kind = Builders.Text_Value then
               Build.Set_Field (Item, "str", Negated (Str));
            else
               raise Constraint_Error with "floating value required for negation";
            end if;
            return Builders.No_Value;
         end;
      elsif Name in "SystemFuncName" | "SystemTypeName" then
         declare
            String_Node : constant Builders.Dynamic_Value :=
              Invoke (Build, "makeString", (1 => Argument (1)));
            Names : constant Builders.Dynamic_Value := Build.List_Of (String_Node);
         begin
            if Name = "SystemFuncName" then
               return Names;
            end if;
            Result := Build.New_Object ("TypeName");
            Build.Set_Field (Result, "names", Names);
            Build.Set_Field (Result, "typemod", Builders.Number (-1));
            Build.Set_Field (Result, "location", Builders.Number (-1));
            return Result;
         end;
      elsif Name = "scanner_yyerror" then
         raise Scanner_Parser_Error with Text_Of (Argument (1));
      elsif Name = "errmsg" then
         raise Parser_Error with Text_Of (Argument (1));
      else
         raise Program_Error with "unsupported generated semantic helper " & Name;
      end if;
   end Invoke;

end Flyology.Postgres.SQL.Native.Semantics;
