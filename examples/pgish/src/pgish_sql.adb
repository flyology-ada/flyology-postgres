with Ada.Characters.Handling;
with Ada.Containers;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Visitors;

package body Pgish_SQL is

   use Ada.Characters.Handling;
   use Ada.Strings.Unbounded;

   package AST renames Flyology.Postgres.SQL.AST.V18;
   package Visitors renames Flyology.Postgres.SQL.AST.V18.Visitors;

   use type AST.A_Expr_Kind;
   use type AST.Bool_Expr_Type;
   use type AST.Limit_Option;
   use type AST.Node_Access;
   use type AST.Node_Kind;
   use type AST.Float_Value_Access;
   use type AST.Integer_Value_Access;
   use type AST.Null_Test_Type;
   use type AST.Set_Operation;
   use type AST.Sort_By_Dir;
   use type AST.Sort_By_Nulls;
   use type AST.Sql_Value_Function_Op;
   use type AST.String_Value_Access;
   use type Ada.Containers.Count_Type;

   function Make_Text (Value : String; Capacity : Positive) return Text is
      Result : Text (Capacity);
   begin
      if Value'Length > Capacity then
         raise Syntax_Error with "SQL token exceeds its bounded length";
      end if;
      Result.Length := Value'Length;
      if Value'Length > 0 then
         Result.Data (1 .. Value'Length) := Value;
      end if;
      return Result;
   end Make_Text;

   function Image (Value : Text) return String is
     (if Value.Length = 0 then "" else Value.Data (1 .. Value.Length));

   function Is_Empty (Value : Text) return Boolean is (Value.Length = 0);

   function Trimmed (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));

   function Node_Text
     (Item : AST.Node_Access;
      What : String) return String
   is
   begin
      if Item = null or else Item.Kind /= AST.Node_String_Value then
         raise Syntax_Error with "unsupported " & What;
      end if;
      declare
         Value : constant AST.String_Value := Item.String_Value_Payload;
      begin
         if not Value.Sval.Present then
            raise Syntax_Error with "unsupported " & What;
         end if;
         return To_String (Value.Sval.Value);
      end;
   end Node_Text;

   function Name_From
     (Items : AST.Sequence_Of_Node;
      What : String) return String
   is
      Result : Unbounded_String;
   begin
      if Items.Is_Empty then
         raise Syntax_Error with "unsupported " & What;
      end if;
      for Item of Items loop
         if Length (Result) > 0 then
            Append (Result, ".");
         end if;
         Append (Result, Node_Text (Item, What));
      end loop;
      return To_String (Result);
   end Name_From;

   function Is_Bare_Star (Item : AST.Column_Ref) return Boolean is
   begin
      return
        Item.Fields.Length = 1
        and then Item.Fields.First_Element /= null
        and then Item.Fields.First_Element.Kind = AST.Node_A_Star;
   end Is_Bare_Star;

   function Column_Name (Item : AST.Node_Access) return String is
   begin
      if Item = null or else Item.Kind /= AST.Node_Column_Ref then
         raise Syntax_Error with "expected column reference";
      end if;
      declare
         Value : constant AST.Column_Ref := Item.Column_Ref_Payload;
      begin
         if Is_Bare_Star (Value) then
            raise Syntax_Error with "expected column reference";
         end if;
         return Name_From (Value.Fields, "column reference");
      end;
   end Column_Name;

   function Is_Integer_Lexeme (Value : String) return Boolean is
      Cursor : Integer := Value'First;
   begin
      if Value'Length = 0 then
         return False;
      end if;
      if Value (Cursor) = '-' then
         Cursor := Cursor + 1;
         if Cursor > Value'Last then
            return False;
         end if;
      end if;
      while Cursor <= Value'Last loop
         if Value (Cursor) not in '0' .. '9' then
            return False;
         end if;
         Cursor := Cursor + 1;
      end loop;
      return True;
   end Is_Integer_Lexeme;

   function Literal_Value (Item : AST.Node_Access) return String is
   begin
      if Item = null then
         raise Syntax_Error with "comparison requires a literal value";
      end if;
      case Item.Kind is
         when AST.Node_A_Const =>
            declare
               Value : constant AST.A_Const := Item.A_Const_Payload;
            begin
               if Value.Sval.Present and then Value.Sval.Value /= null then
                  return
                    (if Value.Sval.Value.Sval.Present
                     then To_String (Value.Sval.Value.Sval.Value)
                     else "");
               elsif Value.Ival.Present and then Value.Ival.Value /= null then
                  return
                    (if Value.Ival.Value.Ival.Present
                     then Trimmed (Value.Ival.Value.Ival.Value'Image)
                     else "0");
               elsif Value.Fval.Present
                 and then Value.Fval.Value /= null
                 and then Value.Fval.Value.Fval.Present
                 and then Is_Integer_Lexeme
                   (To_String (Value.Fval.Value.Fval.Value))
               then
                  return To_String (Value.Fval.Value.Fval.Value);
               else
                  raise Syntax_Error with
                    "comparison requires a literal value";
               end if;
            end;

         when AST.Node_A_Expr =>
            declare
               Value : constant AST.A_Expr := Item.A_Expr_Payload;
            begin
               if Value.Kind.Present
                 and then Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Op
                 and then not Value.Lexpr.Present
                 and then Value.Rexpr.Present
                 and then Value.Rexpr.Value /= null
                 and then Name_From (Value.Name, "unary operator") = "-"
               then
                  declare
                     Magnitude : constant String :=
                       Literal_Value (Value.Rexpr.Value);
                  begin
                     if Magnitude'Length > 0
                       and then Magnitude (Magnitude'First) /= '-'
                       and then Is_Integer_Lexeme (Magnitude)
                     then
                        return "-" & Magnitude;
                     end if;
                  end;
               end if;
               raise Syntax_Error with
                 "comparison requires a literal value";
            end;

         when others =>
            raise Syntax_Error with "comparison requires a literal value";
      end case;
   end Literal_Value;

   function String_Literal (Item : AST.Node_Access) return String is
   begin
      if Item = null or else Item.Kind /= AST.Node_A_Const then
         raise Syntax_Error with "LIKE requires a quoted pattern";
      end if;
      declare
         Value : constant AST.A_Const := Item.A_Const_Payload;
      begin
         if Value.Sval.Present and then Value.Sval.Value /= null then
            return
              (if Value.Sval.Value.Sval.Present
               then To_String (Value.Sval.Value.Sval.Value)
               else "");
         end if;
         raise Syntax_Error with "LIKE requires a quoted pattern";
      end;
   end String_Literal;

   function Range_Name (Item : AST.Range_Var) return String is
      Result : Unbounded_String;

      procedure Add (Value : AST.Optional_Text) is
      begin
         if Value.Present then
            if Length (Result) > 0 then
               Append (Result, ".");
            end if;
            Append (Result, To_String (Value.Value));
         end if;
      end Add;
   begin
      if Item.Alias.Present then
         raise Syntax_Error with "table aliases are unsupported";
      end if;
      Add (Item.Catalogname);
      Add (Item.Schemaname);
      Add (Item.Relname);
      if Length (Result) = 0 then
         raise Syntax_Error with "expected table name";
      end if;
      return To_String (Result);
   end Range_Name;

   procedure Add_Projection
     (Target : AST.Node_Access;
      Result : in out Query)
   is
      Item : Projection;
   begin
      if Result.Projection_Count = Maximum_Projections then
         raise Syntax_Error with "projection limit exceeded";
      end if;
      if Target = null or else Target.Kind /= AST.Node_Res_Target then
         raise Syntax_Error with "expected projection expression";
      end if;
      declare
         Res : constant AST.Res_Target := Target.Res_Target_Payload;
      begin
         if not Res.Indirection.Is_Empty or else not Res.Val.Present
           or else Res.Val.Value = null
         then
            raise Syntax_Error with "unsupported projection expression";
         end if;
         declare
            Value : constant AST.Node_Access := Res.Val.Value;
         begin
            case Value.Kind is
               when AST.Node_Column_Ref =>
                  if Is_Bare_Star (Value.Column_Ref_Payload) then
                     Item.Kind := Star_Projection;
                  else
                     Item.Kind := Column_Projection;
                     Item.Name :=
                       Make_Text (Column_Name (Value), Maximum_Name_Length);
                  end if;

               when AST.Node_A_Const | AST.Node_A_Expr =>
                  Item.Kind := Literal_Projection;
                  Item.Literal :=
                    Make_Text (Literal_Value (Value), Maximum_Value_Length);

               when AST.Node_Func_Call =>
                  declare
                     Call : constant AST.Func_Call := Value.Func_Call_Payload;
                     Name : constant String :=
                       To_Lower (Name_From (Call.Funcname, "function name"));
                  begin
                     if not Call.Args.Is_Empty
                       or else not Call.Agg_Order.Is_Empty
                       or else Call.Agg_Filter.Present
                       or else Call.Over.Present
                       or else
                         (Call.Agg_Within_Group.Present
                          and then Call.Agg_Within_Group.Value)
                       or else
                         (Call.Agg_Star.Present and then Call.Agg_Star.Value)
                       or else
                         (Call.Agg_Distinct.Present
                          and then Call.Agg_Distinct.Value)
                       or else
                         (Call.Func_Variadic.Present
                          and then Call.Func_Variadic.Value)
                     then
                        raise Syntax_Error with
                          "only zero-argument functions are supported";
                     end if;
                     Item.Kind := Function_Projection;
                     Item.Name := Make_Text (Name, Maximum_Name_Length);
                     if Name = "current_database" then
                        Item.Function_Id := Current_Database_Function;
                     elsif Name = "version" then
                        Item.Function_Id := Version_Function;
                     elsif Name = "now" then
                        Item.Function_Id := Now_Function;
                     else
                        raise Syntax_Error with
                          "unsupported SQL function: " & Name;
                     end if;
                  end;

               when AST.Node_Sql_Value_Function =>
                  declare
                     Value_Function : constant AST.Sql_Value_Function :=
                       Value.Sql_Value_Function_Payload;
                  begin
                     if not Value_Function.Op.Present
                       or else Value_Function.Op.Value /=
                         AST.Sql_Value_Function_Op_Svfop_Current_User
                     then
                        raise Syntax_Error with
                          "unsupported SQL value function";
                     end if;
                     Item.Kind := Function_Projection;
                     Item.Function_Id := Current_User_Function;
                     Item.Name :=
                       Make_Text ("current_user", Maximum_Name_Length);
                  end;

               when others =>
                  raise Syntax_Error with "unsupported projection expression";
            end case;
         end;
         if Res.Name.Present then
            Item.Alias :=
              Make_Text (To_String (Res.Name.Value), Maximum_Name_Length);
         end if;
      end;
      Result.Projection_Count := Result.Projection_Count + 1;
      Result.Projections (Result.Projection_Count) := Item;
   end Add_Projection;

   procedure Add_Predicate
     (Expression : AST.Node_Access;
      Result     : in out Query);

   procedure Store_Predicate
     (Item   : Predicate;
      Result : in out Query)
   is
   begin
      if Result.Predicate_Count = Maximum_Predicates then
         raise Syntax_Error with "predicate limit exceeded";
      end if;
      Result.Predicate_Count := Result.Predicate_Count + 1;
      Result.Predicates (Result.Predicate_Count) := Item;
   end Store_Predicate;

   procedure Add_Predicate
     (Expression : AST.Node_Access;
      Result     : in out Query)
   is
      Item : Predicate;
   begin
      if Expression = null then
         raise Syntax_Error with "expected predicate expression";
      end if;
      case Expression.Kind is
         when AST.Node_Bool_Expr =>
            declare
               Value : constant AST.Bool_Expr :=
                 Expression.Bool_Expr_Payload;
            begin
               if not Value.Boolop.Present
                 or else Value.Boolop.Value /= AST.Bool_Expr_Type_And_Expr
               then
                  raise Syntax_Error with "only AND predicates are supported";
               end if;
               for Child of Value.Args loop
                  Add_Predicate (Child, Result);
               end loop;
            end;

         when AST.Node_Null_Test =>
            declare
               Value : constant AST.Null_Test :=
                 Expression.Null_Test_Payload;
            begin
               if not Value.Arg.Present or else Value.Arg.Value = null
                 or else not Value.Nulltesttype.Present
               then
                  raise Syntax_Error with "unsupported NULL predicate";
               end if;
               Item.Column :=
                 Make_Text
                   (Column_Name (Value.Arg.Value), Maximum_Name_Length);
               case Value.Nulltesttype.Value is
                  when AST.Null_Test_Type_Is_Null =>
                     Item.Operator := Is_Null;
                  when AST.Null_Test_Type_Is_Not_Null =>
                     Item.Operator := Is_Not_Null;
                  when others =>
                     raise Syntax_Error with "unsupported NULL predicate";
               end case;
               Store_Predicate (Item, Result);
            end;

         when AST.Node_A_Expr =>
            declare
               Value : constant AST.A_Expr := Expression.A_Expr_Payload;
               Name  : constant String :=
                 Name_From (Value.Name, "predicate operator");
            begin
               if not Value.Kind.Present
                 or else not Value.Lexpr.Present
                 or else Value.Lexpr.Value = null
                 or else not Value.Rexpr.Present
                 or else Value.Rexpr.Value = null
               then
                  raise Syntax_Error with "unsupported predicate expression";
               end if;
               Item.Column :=
                 Make_Text
                   (Column_Name (Value.Lexpr.Value), Maximum_Name_Length);
               if Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Like then
                  Item.Operator := Like_Match;
                  Item.Value :=
                    Make_Text
                      (String_Literal (Value.Rexpr.Value),
                       Maximum_Value_Length);
               elsif Value.Kind.Value = AST.A_Expr_Kind_Aexpr_Op then
                  if Name = "=" then
                     Item.Operator := Equal_To;
                  elsif Name in "!=" | "<>" then
                     Item.Operator := Not_Equal_To;
                  elsif Name = "<" then
                     Item.Operator := Less_Than;
                  elsif Name = "<=" then
                     Item.Operator := Less_Or_Equal;
                  elsif Name = ">" then
                     Item.Operator := Greater_Than;
                  elsif Name = ">=" then
                     Item.Operator := Greater_Or_Equal;
                  else
                     raise Syntax_Error with
                       "unsupported comparison operator";
                  end if;
                  Item.Value :=
                    Make_Text
                      (Literal_Value (Value.Rexpr.Value),
                       Maximum_Value_Length);
               else
                  raise Syntax_Error with "unsupported predicate operator";
               end if;
               Store_Predicate (Item, Result);
            end;

         when others =>
            raise Syntax_Error with "unsupported predicate expression";
      end case;
   end Add_Predicate;

   procedure Lower_Select
     (Item   : AST.Select_Stmt;
      Result : in out Query)
   is
   begin
      if not Item.Distinct_Clause.Is_Empty
        or else Item.Into_Clause.Present
        or else not Item.Group_Clause.Is_Empty
        or else
          (Item.Group_Distinct.Present and then Item.Group_Distinct.Value)
        or else Item.Having_Clause.Present
        or else not Item.Window_Clause.Is_Empty
        or else not Item.Values_Lists.Is_Empty
        or else not Item.Locking_Clause.Is_Empty
        or else Item.With_Clause.Present
        or else Item.Larg.Present
        or else Item.Rarg.Present
        or else
          (Item.Op.Present
           and then Item.Op.Value not in
             AST.Set_Operation_Undefined | AST.Set_Operation_Setop_None)
      then
         raise Syntax_Error with "unsupported SELECT feature";
      end if;
      if Item.Target_List.Is_Empty then
         raise Syntax_Error with "expected projection expression";
      end if;
      if Item.From_Clause.Length > 1 then
         raise Syntax_Error with "only one table is supported";
      end if;

      Result.Kind := Select_Statement;
      for Target of Item.Target_List loop
         Add_Projection (Target, Result);
      end loop;

      if not Item.From_Clause.Is_Empty then
         declare
            Source : constant AST.Node_Access :=
              Item.From_Clause.First_Element;
         begin
            if Source = null or else Source.Kind /= AST.Node_Range_Var then
               raise Syntax_Error with "unsupported FROM item";
            end if;
            Result.Table_Name :=
              Make_Text
                (Range_Name (Source.Range_Var_Payload), Maximum_Name_Length);
         end;
      end if;

      if Item.Where_Clause.Present then
         if Is_Empty (Result.Table_Name) then
            raise Syntax_Error with "WHERE requires a virtual table";
         end if;
         Add_Predicate (Item.Where_Clause.Value, Result);
      end if;

      if Item.Sort_Clause.Length > 1 then
         raise Syntax_Error with "only one ORDER BY expression is supported";
      elsif not Item.Sort_Clause.Is_Empty then
         declare
            Sort_Node : constant AST.Node_Access :=
              Item.Sort_Clause.First_Element;
         begin
            if Sort_Node = null or else Sort_Node.Kind /= AST.Node_Sort_By then
               raise Syntax_Error with "unsupported ORDER BY expression";
            end if;
            declare
               Sort : constant AST.Sort_By := Sort_Node.Sort_By_Payload;
            begin
               if not Sort.Node.Present or else Sort.Node.Value = null
                 or else not Sort.Use_Op.Is_Empty
                 or else
                   (Sort.Sortby_Nulls.Present
                    and then Sort.Sortby_Nulls.Value not in
                      AST.Sort_By_Nulls_Undefined |
                      AST.Sort_By_Nulls_Sortby_Nulls_Default)
               then
                  raise Syntax_Error with "unsupported ORDER BY expression";
               end if;
               Result.Order_Column :=
                 Make_Text
                   (Column_Name (Sort.Node.Value), Maximum_Name_Length);
               if Sort.Sortby_Dir.Present then
                  case Sort.Sortby_Dir.Value is
                     when AST.Sort_By_Dir_Undefined |
                       AST.Sort_By_Dir_Sortby_Default |
                       AST.Sort_By_Dir_Sortby_Asc =>
                        null;
                     when AST.Sort_By_Dir_Sortby_Desc =>
                        Result.Order_Descending := True;
                     when others =>
                        raise Syntax_Error with
                          "unsupported ORDER BY direction";
                  end case;
               end if;
            end;
         end;
      end if;

      if Item.Limit_Offset.Present then
         raise Syntax_Error with "OFFSET is unsupported";
      end if;
      if Item.Limit_Option.Present
        and then Item.Limit_Option.Value = AST.Limit_Option_With_Ties
      then
         raise Syntax_Error with "FETCH WITH TIES is unsupported";
      end if;
      if Item.Limit_Count.Present then
         declare
            Value : constant String := Literal_Value (Item.Limit_Count.Value);
         begin
            if not Is_Integer_Lexeme (Value)
              or else (Value'Length > 0 and then Value (Value'First) = '-')
            then
               raise Syntax_Error with
                 "LIMIT requires a non-negative integer";
            end if;
            begin
               Result.Limit := Natural'Value (Value);
            exception
               when Constraint_Error =>
                  raise Syntax_Error with
                    "LIMIT exceeds the server row limit of" &
                    Maximum_Result_Rows'Image;
            end;
            Result.Has_Limit := True;
         end;
      end if;
   end Lower_Select;

   function Parse (SQL : String) return Query is
      Tree : AST.Owned_Syntax_Tree;

      type Lowering_Visitor is new Visitors.Visitor with record
         Value                  : Query;
         Statement_Count        : Natural := 0;
         Node_Count             : Natural := 0;
         Expect_Statement_Root  : Boolean := False;
         Lowered                : Boolean := False;
      end record;

      overriding procedure Enter_Raw_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Raw_Stmt;
         Control : in out Visitors.Traversal_Control);
      overriding procedure Enter_Node
        (Self    : in out Lowering_Visitor;
         Item    : AST.Node;
         Control : in out Visitors.Traversal_Control);
      overriding procedure Enter_Select_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Select_Stmt;
         Control : in out Visitors.Traversal_Control);
      overriding procedure Enter_Variable_Show_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Variable_Show_Stmt;
         Control : in out Visitors.Traversal_Control);

      overriding procedure Enter_Raw_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Raw_Stmt;
         Control : in out Visitors.Traversal_Control)
      is
         pragma Unreferenced (Item, Control);
      begin
         Self.Statement_Count := Self.Statement_Count + 1;
         if Self.Statement_Count > 1 then
            raise Syntax_Error with "only one SQL statement is supported";
         end if;
         Self.Expect_Statement_Root := True;
      end Enter_Raw_Stmt;

      overriding procedure Enter_Node
        (Self    : in out Lowering_Visitor;
         Item    : AST.Node;
         Control : in out Visitors.Traversal_Control)
      is
         pragma Unreferenced (Control);
      begin
         Self.Node_Count := Self.Node_Count + 1;
         if Self.Node_Count > Maximum_AST_Nodes then
            raise Syntax_Error with "SQL AST node limit exceeded";
         end if;
         if Self.Expect_Statement_Root then
            Self.Expect_Statement_Root := False;
            if Item.Kind not in
              AST.Node_Select_Stmt | AST.Node_Variable_Show_Stmt
            then
               raise Syntax_Error with "unsupported SQL statement";
            end if;
         end if;
      end Enter_Node;

      overriding procedure Enter_Select_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Select_Stmt;
         Control : in out Visitors.Traversal_Control)
      is
         pragma Unreferenced (Control);
      begin
         if Self.Lowered then
            raise Syntax_Error with "subqueries are unsupported";
         end if;
         Lower_Select (Item, Self.Value);
         Self.Lowered := True;
      end Enter_Select_Stmt;

      overriding procedure Enter_Variable_Show_Stmt
        (Self    : in out Lowering_Visitor;
         Item    : AST.Variable_Show_Stmt;
         Control : in out Visitors.Traversal_Control)
      is
         pragma Unreferenced (Control);
      begin
         if Self.Lowered or else not Item.Name.Present then
            raise Syntax_Error with "unsupported SHOW statement";
         end if;
         Self.Value.Kind := Show_Statement;
         Self.Value.Show_Name :=
           Make_Text (To_String (Item.Name.Value), Maximum_Name_Length);
         Self.Lowered := True;
      end Enter_Variable_Show_Stmt;

      Lowerer : Lowering_Visitor;
   begin
      if SQL'Length > Maximum_Query_Length then
         raise Syntax_Error with "SQL query limit exceeded";
      end if;
      AST.Parse (SQL, Tree);
      if not Tree.Valid then
         raise Syntax_Error with
           To_String (Tree.Diagnostic_Message)
           & " at character" & Tree.Diagnostic_Position'Image;
      end if;
      Visitors.Traverse (Lowerer, Tree);
      if Lowerer.Statement_Count = 0 then
         raise Syntax_Error with "expected SELECT or SHOW statement";
      elsif not Lowerer.Lowered then
         raise Syntax_Error with "unsupported SQL statement";
      end if;
      return Lowerer.Value;
   end Parse;

end Pgish_SQL;
