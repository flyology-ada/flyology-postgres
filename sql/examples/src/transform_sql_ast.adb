with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Visitors;

procedure Transform_SQL_AST is
   package AST renames Flyology.Postgres.SQL.AST.V18;
   package Visitors renames Flyology.Postgres.SQL.AST.V18.Visitors;

   use Ada.Strings.Unbounded;
   use type AST.Node_Access;
   use type AST.Node_Kind;
   use type AST.String_Value_Access;

   package Relation_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => AST.Node_Access);

   package Literal_Vectors is new Ada.Containers.Vectors
     (Index_Type   => Positive,
      Element_Type => AST.String_Value_Access);

   type Rewrite_Planner is new Visitors.Visitor with record
      Relations       : Relation_Vectors.Vector;
      String_Literals : Literal_Vectors.Vector;
   end record;

   procedure Remember_Relation
     (Relations : in out Relation_Vectors.Vector;
      Item      : AST.Node_Access);

   overriding procedure Enter_Select_Stmt
     (Self    : in out Rewrite_Planner;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_Join_Expr
     (Self    : in out Rewrite_Planner;
      Item    : AST.Join_Expr;
      Control : in out Visitors.Traversal_Control);

   overriding procedure Enter_A_Const
     (Self    : in out Rewrite_Planner;
      Item    : AST.A_Const;
      Control : in out Visitors.Traversal_Control);

   procedure Remember_Relation
     (Relations : in out Relation_Vectors.Vector;
      Item      : AST.Node_Access) is
   begin
      if Item /= null and then Item.Kind = AST.Node_Range_Var then
         Relations.Append (Item);
      end if;
   end Remember_Relation;

   overriding procedure Enter_Select_Stmt
     (Self    : in out Rewrite_Planner;
      Item    : AST.Select_Stmt;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      for Source of Item.From_Clause loop
         Remember_Relation (Self.Relations, Source);
      end loop;
   end Enter_Select_Stmt;

   overriding procedure Enter_Join_Expr
     (Self    : in out Rewrite_Planner;
      Item    : AST.Join_Expr;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      if Item.Larg.Present then
         Remember_Relation (Self.Relations, Item.Larg.Value);
      end if;
      if Item.Rarg.Present then
         Remember_Relation (Self.Relations, Item.Rarg.Value);
      end if;
   end Enter_Join_Expr;

   overriding procedure Enter_A_Const
     (Self    : in out Rewrite_Planner;
      Item    : AST.A_Const;
      Control : in out Visitors.Traversal_Control)
   is
      pragma Unreferenced (Control);
   begin
      if Item.Sval.Present and then Item.Sval.Value /= null then
         Self.String_Literals.Append (Item.Sval.Value);
      end if;
   end Enter_A_Const;

   Tree : AST.Owned_Syntax_Tree;
   Plan : Rewrite_Planner;

   Renamed  : Natural := 0;
   Redacted : Natural := 0;
begin
   AST.Parse
     ("SELECT email FROM public.accounts " &
      "WHERE tenant = 'acme' AND status = 'active'",
      Tree);
   if not Tree.Valid then
      raise Program_Error with To_String (Tree.Diagnostic_Message);
   end if;

   --  Pass one only observes the graph and retains references owned by Tree.
   Visitors.Traverse (Plan, Tree);

   --  Pass two changes scalar payloads without changing graph topology.
   for Reference of Plan.Relations loop
      if Reference.Range_Var_Payload.Relname.Present
        and then
          To_String (Reference.Range_Var_Payload.Relname.Value) = "accounts"
      then
         Reference.Range_Var_Payload.Relname.Value :=
           To_Unbounded_String ("accounts_archive");
         Renamed := Renamed + 1;
      end if;
   end loop;

   for Reference of Plan.String_Literals loop
      if Reference.Sval.Present then
         Reference.Sval.Value := To_Unbounded_String ("[redacted]");
         Redacted := Redacted + 1;
      end if;
   end loop;

   Ada.Text_IO.Put_Line ("renamed relations:" & Renamed'Image);
   Ada.Text_IO.Put_Line ("redacted string literals:" & Redacted'Image);

   if Renamed /= 1 or else Redacted /= 2 then
      raise Program_Error with "unexpected transformation result";
   end if;
end Transform_SQL_AST;
