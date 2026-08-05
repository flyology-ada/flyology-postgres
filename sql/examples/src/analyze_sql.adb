with Ada.Command_Line;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Visitors;

procedure Analyze_SQL is
   package AST renames Flyology.Postgres.SQL.AST.V18;
   package Visitors renames Flyology.Postgres.SQL.AST.V18.Visitors;

   use Ada.Strings.Unbounded;
   Default_SQL : constant String :=
     "WITH recent AS (" &
     "SELECT account_id FROM audit.events WHERE action = 'login') " &
     "SELECT a.email, count(r.account_id) " &
     "FROM app.accounts AS a " &
     "JOIN recent AS r ON r.account_id = a.id " &
     "GROUP BY a.email";

   SQL_Text : constant String :=
     (if Ada.Command_Line.Argument_Count = 0
      then Default_SQL
      else Ada.Command_Line.Argument (1));

   type Analysis_Visitor is new Visitors.Visitor with record
      Selects        : Natural := 0;
      Targets        : Natural := 0;
      Relations      : Natural := 0;
      Joins          : Natural := 0;
      Column_Refs    : Natural := 0;
      Function_Calls : Natural := 0;
      Relation_Names : Unbounded_String;
   end record;

   overriding procedure Enter_Select_Stmt
     (Self    : in out Analysis_Visitor;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Range_Var
     (Self    : in out Analysis_Visitor;
      Item    : AST.Range_Var;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Join_Expr
     (Self    : in out Analysis_Visitor;
      Item    : AST.Join_Expr;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Column_Ref
     (Self    : in out Analysis_Visitor;
      Item    : AST.Column_Ref;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Func_Call
     (Self    : in out Analysis_Visitor;
      Item    : AST.Func_Call;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Select_Stmt
     (Self    : in out Analysis_Visitor;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      Self.Selects := Self.Selects + 1;
      Self.Targets := Self.Targets + Natural (Item.Target_List.Length);
   end Enter_Select_Stmt;

   overriding procedure Enter_Range_Var
     (Self    : in out Analysis_Visitor;
      Item    : AST.Range_Var;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      Self.Relations := Self.Relations + 1;
      if Item.Relname.Present then
         if Length (Self.Relation_Names) > 0 then
            Append (Self.Relation_Names, ", ");
         end if;
         if Item.Schemaname.Present then
            Append (Self.Relation_Names, Item.Schemaname.Value);
            Append (Self.Relation_Names, ".");
         end if;
         Append (Self.Relation_Names, Item.Relname.Value);
      end if;
   end Enter_Range_Var;

   overriding procedure Enter_Join_Expr
     (Self    : in out Analysis_Visitor;
      Item    : AST.Join_Expr;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Joins := Self.Joins + 1;
   end Enter_Join_Expr;

   overriding procedure Enter_Column_Ref
     (Self    : in out Analysis_Visitor;
      Item    : AST.Column_Ref;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Column_Refs := Self.Column_Refs + 1;
   end Enter_Column_Ref;

   overriding procedure Enter_Func_Call
     (Self    : in out Analysis_Visitor;
      Item    : AST.Func_Call;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Function_Calls := Self.Function_Calls + 1;
   end Enter_Func_Call;

   Tree   : AST.Owned_Syntax_Tree;
   Report : Analysis_Visitor;
begin
   AST.Parse (SQL_Text, Tree);
   if not Tree.Valid then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "parse error:" & Natural'Image (Tree.Diagnostic_Position) & " " &
         To_String (Tree.Diagnostic_Message));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
      return;
   end if;

   Visitors.Traverse (Report, Tree);

   Ada.Text_IO.Put_Line ("select statements:" & Report.Selects'Image);
   Ada.Text_IO.Put_Line ("target expressions:" & Report.Targets'Image);
   Ada.Text_IO.Put_Line ("relations:" & Report.Relations'Image);
   Ada.Text_IO.Put_Line ("relation names: " & To_String (Report.Relation_Names));
   Ada.Text_IO.Put_Line ("joins:" & Report.Joins'Image);
   Ada.Text_IO.Put_Line ("column references:" & Report.Column_Refs'Image);
   Ada.Text_IO.Put_Line ("function calls:" & Report.Function_Calls'Image);

   if SQL_Text = Default_SQL
     and then
       (Report.Selects /= 2
        or else Report.Targets /= 3
        or else Report.Relations /= 3
        or else Report.Joins /= 1
        or else Report.Function_Calls /= 1)
   then
      raise Program_Error with "unexpected analysis of the example query";
   end if;
end Analyze_SQL;
