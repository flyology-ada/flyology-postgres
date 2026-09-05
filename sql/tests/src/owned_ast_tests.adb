with Ada.Containers;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.Views;
with Flyology.Postgres.SQL.AST.V14;
with Flyology.Postgres.SQL.AST.V14.Testing;
with Flyology.Postgres.SQL.AST.V14.Visitors;
with Flyology.Postgres.SQL.AST.V15;
with Flyology.Postgres.SQL.AST.V15.Testing;
with Flyology.Postgres.SQL.AST.V15.Visitors;
with Flyology.Postgres.SQL.AST.V16;
with Flyology.Postgres.SQL.AST.V16.Testing;
with Flyology.Postgres.SQL.AST.V16.Visitors;
with Flyology.Postgres.SQL.AST.V17;
with Flyology.Postgres.SQL.AST.V17.Testing;
with Flyology.Postgres.SQL.AST.V17.Visitors;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Testing;
with Flyology.Postgres.SQL.AST.V18.Visitors;
with Interfaces;

package body Owned_AST_Tests is

   package SQL renames Flyology.Postgres.SQL;
   package Views renames Flyology.Postgres.SQL.Views;
   package AST_14 renames Flyology.Postgres.SQL.AST.V14;
   package AST_15 renames Flyology.Postgres.SQL.AST.V15;
   package AST_16 renames Flyology.Postgres.SQL.AST.V16;
   package AST_17 renames Flyology.Postgres.SQL.AST.V17;
   package AST_18 renames Flyology.Postgres.SQL.AST.V18;
   package Test_14 renames Flyology.Postgres.SQL.AST.V14.Testing;
   package Test_15 renames Flyology.Postgres.SQL.AST.V15.Testing;
   package Test_16 renames Flyology.Postgres.SQL.AST.V16.Testing;
   package Test_17 renames Flyology.Postgres.SQL.AST.V17.Testing;
   package Test_18 renames Flyology.Postgres.SQL.AST.V18.Testing;
   package Visitors_14 renames Flyology.Postgres.SQL.AST.V14.Visitors;
   package Visitors_15 renames Flyology.Postgres.SQL.AST.V15.Visitors;
   package Visitors_16 renames Flyology.Postgres.SQL.AST.V16.Visitors;
   package Visitors_17 renames Flyology.Postgres.SQL.AST.V17.Visitors;
   package Visitors_18 renames Flyology.Postgres.SQL.AST.V18.Visitors;

   use type AST_14.Node_Kind;
   use type AST_15.Node_Kind;
   use type AST_16.Node_Kind;
   use type AST_17.Node_Kind;
   use type AST_18.A_Expr_Kind;
   use type AST_18.Node_Kind;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Integer_32;

   type Counting_Visitor_14 is new Visitors_14.Visitor with record
      Nodes : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_14;
      Item    : AST_14.Node;
      Control : in out Visitors_14.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   type Counting_Visitor_15 is new Visitors_15.Visitor with record
      Nodes : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_15;
      Item    : AST_15.Node;
      Control : in out Visitors_15.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   type Counting_Visitor_16 is new Visitors_16.Visitor with record
      Nodes : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_16;
      Item    : AST_16.Node;
      Control : in out Visitors_16.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   type Counting_Visitor_17 is new Visitors_17.Visitor with record
      Nodes : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_17;
      Item    : AST_17.Node;
      Control : in out Visitors_17.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   type Counting_Visitor_18 is new Visitors_18.Visitor with record
      Nodes       : Natural := 0;
      Node_Leaves : Natural := 0;
      Selects     : Natural := 0;
      Ctes        : Natural := 0;
      Joins       : Natural := 0;
      Expressions : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Node;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Leave_Node
     (Self : in out Counting_Visitor_18;
      Item : AST_18.Node);
   overriding procedure Enter_Select_Stmt
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Select_Stmt;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Enter_Common_Table_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Common_Table_Expr;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Enter_Join_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Join_Expr;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Enter_A_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.A_Expr;
      Control : in out Visitors_18.Traversal_Control);

   overriding procedure Enter_Node
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Node;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   overriding procedure Leave_Node
     (Self : in out Counting_Visitor_18;
      Item : AST_18.Node)
   is
      pragma Unreferenced (Item);
   begin
      Self.Node_Leaves := Self.Node_Leaves + 1;
   end Leave_Node;

   overriding procedure Enter_Select_Stmt
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Select_Stmt;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Selects := Self.Selects + 1;
   end Enter_Select_Stmt;

   overriding procedure Enter_Common_Table_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Common_Table_Expr;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Ctes := Self.Ctes + 1;
   end Enter_Common_Table_Expr;

   overriding procedure Enter_Join_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.Join_Expr;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Joins := Self.Joins + 1;
   end Enter_Join_Expr;

   overriding procedure Enter_A_Expr
     (Self    : in out Counting_Visitor_18;
      Item    : AST_18.A_Expr;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Expressions := Self.Expressions + 1;
   end Enter_A_Expr;

   type Pruning_Visitor is new Visitors_18.Visitor with record
      Nodes         : Natural := 0;
      Selects       : Natural := 0;
      Select_Leaves : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Pruning_Visitor;
      Item    : AST_18.Node;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Enter_Select_Stmt
     (Self    : in out Pruning_Visitor;
      Item    : AST_18.Select_Stmt;
      Control : in out Visitors_18.Traversal_Control);
   overriding procedure Leave_Select_Stmt
     (Self : in out Pruning_Visitor;
      Item : AST_18.Select_Stmt);

   overriding procedure Enter_Node
     (Self    : in out Pruning_Visitor;
      Item    : AST_18.Node;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item, Control);
   begin
      Self.Nodes := Self.Nodes + 1;
   end Enter_Node;

   overriding procedure Enter_Select_Stmt
     (Self    : in out Pruning_Visitor;
      Item    : AST_18.Select_Stmt;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item);
   begin
      Self.Selects := Self.Selects + 1;
      Control := Visitors_18.Skip_Children;
   end Enter_Select_Stmt;

   overriding procedure Leave_Select_Stmt
     (Self : in out Pruning_Visitor;
      Item : AST_18.Select_Stmt)
   is
      pragma Unreferenced (Item);
   begin
      Self.Select_Leaves := Self.Select_Leaves + 1;
   end Leave_Select_Stmt;

   type Stopping_Visitor is new Visitors_18.Visitor with record
      Nodes : Natural := 0;
   end record;

   overriding procedure Enter_Node
     (Self    : in out Stopping_Visitor;
      Item    : AST_18.Node;
      Control : in out Visitors_18.Traversal_Control)
   is
      pragma Unreferenced (Item);
   begin
      Self.Nodes := Self.Nodes + 1;
      if Self.Nodes = 3 then
         Control := Visitors_18.Stop_Traversal;
      end if;
   end Enter_Node;

   function First_Node
     (Tree : AST_18.Owned_Syntax_Tree) return AST_18.Node_Access
   is
      Raw : constant AST_18.Raw_Stmt_Access :=
        Tree.Root.Statements.Element (1);
   begin
      Assert (Raw.Statement.Present, "owned RawStmt contains its statement");
      return Raw.Statement.Value;
   end First_Node;

   procedure Test_Every_Version is
      T14 : AST_14.Owned_Syntax_Tree;
      T15 : AST_15.Owned_Syntax_Tree;
      T16 : AST_16.Owned_Syntax_Tree;
      T17 : AST_17.Owned_Syntax_Tree;
      T18 : AST_18.Owned_Syntax_Tree;
      D14 : AST_14.Owned_Syntax_Tree;
      D15 : AST_15.Owned_Syntax_Tree;
      D16 : AST_16.Owned_Syntax_Tree;
      D17 : AST_17.Owned_Syntax_Tree;
      D18 : AST_18.Owned_Syntax_Tree;
   begin
      Test_14.Parse_Baseline ("SELECT 14", T14);
      Test_15.Parse_Baseline ("SELECT 15", T15);
      Test_16.Parse_Baseline ("SELECT 16", T16);
      Test_17.Parse_Baseline ("SELECT 17", T17);
      Test_18.Parse_Baseline ("SELECT 18", T18);
      AST_14.Parse ("SELECT 14", D14);
      AST_15.Parse ("SELECT 15", D15);
      AST_16.Parse ("SELECT 16", D16);
      AST_17.Parse ("SELECT 17", D17);
      AST_18.Parse ("SELECT 18", D18);

      Assert (Test_14.Equivalent (T14, D14),
              "PostgreSQL 14 owned output equals the arena baseline");
      Assert (Test_15.Equivalent (T15, D15),
              "PostgreSQL 15 owned output equals the arena baseline");
      Assert (Test_16.Equivalent (T16, D16),
              "PostgreSQL 16 owned output equals the arena baseline");
      Assert (Test_17.Equivalent (T17, D17),
              "PostgreSQL 17 owned output equals the arena baseline");
      Assert (Test_18.Equivalent (T18, D18),
              "PostgreSQL 18 owned output equals the arena baseline");

      Assert (T14.Valid and T14.Root.Statements.Length = 1,
              "PostgreSQL 14 produces an owned root");
      Assert (T15.Valid and T15.Root.Statements.Length = 1,
              "PostgreSQL 15 produces an owned root");
      Assert (T16.Valid and T16.Root.Statements.Length = 1,
              "PostgreSQL 16 produces an owned root");
      Assert (T17.Valid and T17.Root.Statements.Length = 1,
              "PostgreSQL 17 produces an owned root");
      Assert (T18.Valid and T18.Root.Statements.Length = 1,
              "PostgreSQL 18 produces an owned root");

      Assert
        (T14.Root.Statements.Element (1).Statement.Value.Kind =
           AST_14.Node_Select_Stmt,
         "PostgreSQL 14 owned node has its generated variant");
      Assert
        (T15.Root.Statements.Element (1).Statement.Value.Kind =
           AST_15.Node_Select_Stmt,
         "PostgreSQL 15 owned node has its generated variant");
      Assert
        (T16.Root.Statements.Element (1).Statement.Value.Kind =
           AST_16.Node_Select_Stmt,
         "PostgreSQL 16 owned node has its generated variant");
      Assert
        (T17.Root.Statements.Element (1).Statement.Value.Kind =
           AST_17.Node_Select_Stmt,
         "PostgreSQL 17 owned node has its generated variant");
      Assert
        (T18.Root.Statements.Element (1).Statement.Value.Kind =
           AST_18.Node_Select_Stmt,
         "PostgreSQL 18 owned node has its generated variant");
   end Test_Every_Version;

   procedure Test_Complex_Traversal is
      Tree : AST_18.Owned_Syntax_Tree;
   begin
      AST_18.Parse
        ("WITH active AS (SELECT id FROM accounts WHERE enabled) "
         & "SELECT a.id FROM active AS a JOIN audit AS b ON a.id = b.id "
         & "WHERE a.id > 10",
         Tree);
      Assert (Tree.Valid, "complex SELECT produces an owned tree");
      declare
         Statement : constant AST_18.Node_Access := First_Node (Tree);
         Selection : constant AST_18.Select_Stmt :=
           Statement.Select_Stmt_Payload;
         With_Item : constant AST_18.With_Clause_Access :=
           Selection.With_Clause.Value;
         CTE_Node  : constant AST_18.Node_Access :=
           With_Item.Ctes.Element (1);
         CTE       : constant AST_18.Common_Table_Expr :=
           CTE_Node.Common_Table_Expr_Payload;
         Join_Node : constant AST_18.Node_Access :=
           Selection.From_Clause.Element (1);
         Join      : constant AST_18.Join_Expr :=
           Join_Node.Join_Expr_Payload;
         Predicate_Node : constant AST_18.Node_Access :=
           Selection.Where_Clause.Value;
         Predicate : constant AST_18.A_Expr :=
           Predicate_Node.A_Expr_Payload;
      begin
         Assert (Statement.Kind = AST_18.Node_Select_Stmt,
                 "field notation reaches SelectStmt");
         Assert (Selection.With_Clause.Present,
                 "SelectStmt retains the optional WITH clause");
         Assert (With_Item.Ctes.Length = 1,
                 "owned CTE list is a typed Ada vector");
         Assert (CTE_Node.Kind = AST_18.Node_Common_Table_Expr,
                 "CTE list contains the concrete node variant");
         Assert (CTE.Ctequery.Present,
                 "nested CTE query is an owned node access");
         Assert (Join_Node.Kind = AST_18.Node_Join_Expr,
                 "FROM list contains a join variant");
         Assert (Join.Larg.Present and Join.Rarg.Present and Join.Quals.Present,
                 "join children are naturally navigable optional accesses");
         Assert (Predicate_Node.Kind = AST_18.Node_A_Expr,
                 "WHERE expression is a concrete variant");
         Assert
           (Predicate.Kind.Present
            and then Predicate.Kind.Value = AST_18.A_Expr_Kind_Aexpr_Op,
            "generated enum values survive materialization");
      end;
   end Test_Complex_Traversal;

   procedure Test_Presence is
      Tree : AST_18.Owned_Syntax_Tree;
   begin
      AST_18.Parse ("SELECT 0, FALSE, NULL", Tree);
      declare
         Selection : constant AST_18.Select_Stmt :=
           First_Node (Tree).Select_Stmt_Payload;
         Zero_Target : constant AST_18.Res_Target :=
           Selection.Target_List.Element (1).Res_Target_Payload;
         False_Target : constant AST_18.Res_Target :=
           Selection.Target_List.Element (2).Res_Target_Payload;
         Null_Target : constant AST_18.Res_Target :=
           Selection.Target_List.Element (3).Res_Target_Payload;
         Zero_Value : constant AST_18.A_Const :=
           Zero_Target.Val.Value.A_Const_Payload;
         False_Value : constant AST_18.A_Const :=
           False_Target.Val.Value.A_Const_Payload;
         Null_Value : constant AST_18.A_Const :=
           Null_Target.Val.Value.A_Const_Payload;
      begin
         Assert (Zero_Value.Ival.Present,
                 "the zero integer alternative itself is present");
         Assert (not Zero_Value.Ival.Value.Ival.Present,
                 "an omitted default-valued protobuf scalar stays absent");
         Assert (False_Value.Boolval.Present,
                 "the false boolean alternative itself is present");
         Assert (not False_Value.Boolval.Value.Boolval.Present,
                 "an omitted false protobuf scalar stays absent");
         Assert
           (Null_Value.Isnull.Present and then Null_Value.Isnull.Value,
            "an explicitly true scalar remains present with its value");
      end;
   end Test_Presence;

   procedure Test_Ownership_And_Replacement is
      Arena : Views.Syntax_Tree;
      Tree  : AST_18.Owned_Syntax_Tree;
   begin
      Views.Parse ("SELECT 1 AS retained", SQL.PostgreSQL_18, Arena);
      Test_18.Materialize_Baseline (Arena, Tree);
      Views.Parse ("SELECT 2", SQL.PostgreSQL_18, Arena);
      declare
         Selection : constant AST_18.Select_Stmt :=
           First_Node (Tree).Select_Stmt_Payload;
         Target : constant AST_18.Res_Target :=
           Selection.Target_List.Element (1).Res_Target_Payload;
      begin
         Assert (To_String (Tree.Source_Text) = "SELECT 1 AS retained",
                 "owned tree keeps its source independently of the arena");
         Assert
           (Target.Name.Present
            and then To_String (Target.Name.Value) = "retained",
            "owned strings and nodes outlive replacement of the source arena");
      end;

      AST_18.Parse
        ("MERGE INTO inventory AS i USING changes AS c ON i.id = c.id "
         & "WHEN MATCHED THEN UPDATE SET quantity = c.quantity",
         Tree);
      declare
         Statement : constant AST_18.Node_Access := First_Node (Tree);
         Merge     : constant AST_18.Merge_Stmt :=
           Statement.Merge_Stmt_Payload;
      begin
         Assert (Statement.Kind = AST_18.Node_Merge_Stmt,
                 "replacing an owned tree releases and changes its root");
         Assert (Merge.Relation.Present and Merge.Merge_When_Clauses.Length = 1,
                 "MERGE records and typed sequences are materialized");
      end;

      AST_18.Parse
        ("CREATE TABLE typed_example "
         & "(id bigint PRIMARY KEY, payload jsonb NOT NULL)",
         Tree);
      declare
         Statement : constant AST_18.Node_Access := First_Node (Tree);
         Creation  : constant AST_18.Create_Stmt :=
           Statement.Create_Stmt_Payload;
      begin
         Assert (Statement.Kind = AST_18.Node_Create_Stmt,
                 "DDL has a concrete generated record variant");
         Assert (Creation.Relation.Present and Creation.Table_Elts.Length = 2,
                 "DDL child messages and vectors are owned");
      end;

      AST_18.Parse ("SHOW search_path", Tree);
      declare
         Statement : constant AST_18.Node_Access := First_Node (Tree);
         Show      : constant AST_18.Variable_Show_Stmt :=
           Statement.Variable_Show_Stmt_Payload;
      begin
         Assert (Statement.Kind = AST_18.Node_Variable_Show_Stmt,
                 "utility statement has a concrete generated variant");
         Assert
           (Show.Name.Present
            and then To_String (Show.Name.Value) = "search_path",
            "utility statement text is owned");
      end;

      AST_18.Parse ("SELECT FROM WHERE", Tree);
      Assert (not Tree.Valid, "invalid SQL leaves no owned AST root");
      Assert (Length (Tree.Diagnostic_Message) > 0,
              "owned parse result retains the diagnostic");
      Assert (Tree.Diagnostic_Position > 0,
              "owned parse result retains the cursor position");
      Assert (Tree.Root.Statements.Is_Empty,
              "failed replacement releases the previous object graph");

      AST_18.Clear (Tree);
      Assert (not Tree.Valid and Tree.Root.Statements.Is_Empty,
              "explicit Clear is idempotent and leaves an empty owner");
   end Test_Ownership_And_Replacement;

   procedure Test_Direct_Path is
      Baseline : AST_18.Owned_Syntax_Tree;
      Direct   : AST_18.Owned_Syntax_Tree;
      Text     : constant String :=
        "WITH active AS (SELECT id FROM accounts WHERE enabled) "
        & "SELECT a.id FROM active AS a JOIN audit AS b ON a.id = b.id "
        & "WHERE a.id > 10";
   begin
      Test_18.Parse_Baseline (Text, Baseline);
      AST_18.Parse (Text, Direct);
      Assert (Direct.Valid, "direct semantic construction succeeds");
      Assert
        (Test_18.Equivalent (Baseline, Direct),
         "every owned field matches the arena baseline");
      Assert
        (Direct.Root.Version.Present
         and then Baseline.Root.Version.Present
         and then Direct.Root.Version.Value = Baseline.Root.Version.Value,
         "direct root retains the exact PostgreSQL version");
      declare
         Expected : constant AST_18.Select_Stmt :=
           First_Node (Baseline).Select_Stmt_Payload;
         Actual : constant AST_18.Select_Stmt :=
           First_Node (Direct).Select_Stmt_Payload;
      begin
         Assert
           (Actual.Target_List.Length = Expected.Target_List.Length,
            "owned target sequence matches the arena baseline");
         Assert
           (Actual.From_Clause.Length = Expected.From_Clause.Length,
            "owned FROM sequence matches the arena baseline");
         Assert
           (Actual.With_Clause.Present = Expected.With_Clause.Present,
            "owned optional presence matches the arena baseline");
         Assert
           (Actual.Where_Clause.Present = Expected.Where_Clause.Present,
            "owned expression presence matches the arena baseline");
      end;
   end Test_Direct_Path;

   procedure Test_Direct_Corpus is
      procedure Compare_14 (Text : String) is
         Baseline, Direct : AST_14.Owned_Syntax_Tree;
      begin
         Test_14.Parse_Baseline (Text, Baseline);
         AST_14.Parse (Text, Direct);
         Assert (Test_14.Equivalent (Baseline, Direct),
                 "V14 direct AST differs for: " & Text);
      end Compare_14;

      procedure Compare_15 (Text : String) is
         Baseline, Direct : AST_15.Owned_Syntax_Tree;
      begin
         Test_15.Parse_Baseline (Text, Baseline);
         AST_15.Parse (Text, Direct);
         Assert (Test_15.Equivalent (Baseline, Direct),
                 "V15 direct AST differs for: " & Text);
      end Compare_15;

      procedure Compare_16 (Text : String) is
         Baseline, Direct : AST_16.Owned_Syntax_Tree;
      begin
         Test_16.Parse_Baseline (Text, Baseline);
         AST_16.Parse (Text, Direct);
         Assert (Test_16.Equivalent (Baseline, Direct),
                 "V16 direct AST differs for: " & Text);
      end Compare_16;

      procedure Compare_17 (Text : String) is
         Baseline, Direct : AST_17.Owned_Syntax_Tree;
      begin
         Test_17.Parse_Baseline (Text, Baseline);
         AST_17.Parse (Text, Direct);
         Assert (Test_17.Equivalent (Baseline, Direct),
                 "V17 direct AST differs for: " & Text);
      end Compare_17;

      procedure Compare_18 (Text : String) is
         Baseline, Direct : AST_18.Owned_Syntax_Tree;
      begin
         Test_18.Parse_Baseline (Text, Baseline);
         AST_18.Parse (Text, Direct);
         Assert (Test_18.Equivalent (Baseline, Direct),
                 "V18 direct AST differs for: " & Text);
      end Compare_18;

      procedure Compare_Common (Text : String) is
      begin
         Compare_14 (Text);
         Compare_15 (Text);
         Compare_16 (Text);
         Compare_17 (Text);
         Compare_18 (Text);
      end Compare_Common;

      Merge_SQL : constant String :=
        "MERGE INTO inventory AS i USING changes AS c ON i.id = c.id "
        & "WHEN MATCHED THEN UPDATE SET quantity = c.quantity "
        & "WHEN NOT MATCHED THEN INSERT (id, quantity) "
        & "VALUES (c.id, c.quantity)";
   begin
      Compare_Common ("");
      Compare_Common ("SELECT 0, FALSE, NULL, 'é雪' AS text");
      Compare_Common ("SELECT DISTINCT name FROM events");
      Compare_Common ("SELECT 1; SELECT 2;");
      Compare_Common ("SELECT ""Mixed Case"" FROM ""Quoted Table""");
      Compare_Common
        ("-- leading" & ASCII.LF
         & "SELECT /* nested /* block */ ok */ 42");
      Compare_Common
        ("WITH q AS (SELECT id FROM events) "
         & "SELECT q.id FROM q JOIN audit a ON q.id = a.id WHERE q.id > 1");
      Compare_Common ("SELECT E'line\n', U&'d\0061t\+000061'");
      Compare_Common ("SELECT E'\401'");
      Compare_Common ("SELECT $12345678901, 1");
      Compare_Common ("SELECT E'a\vb'");
      Compare_Common ("SELECT -'abc'");
      Compare_Common ("SELECT -B'101'");
      Compare_Common ("SELECT -1");
      Compare_Common ("SELECT -1.5");
      Compare_Common ("INSERT INTO t (a, b) VALUES (1, 'x') RETURNING a");
      Compare_Common ("UPDATE t SET a = a + 1 WHERE b IS NOT NULL RETURNING *");
      Compare_Common ("DELETE FROM t USING u WHERE t.id = u.id RETURNING t.id");
      Compare_Common
        ("CREATE TABLE direct_test "
         & "(id bigint PRIMARY KEY, payload jsonb NOT NULL)");
      Compare_Common
        ("ALTER TABLE direct_test ADD COLUMN created_at timestamptz "
         & "DEFAULT now()");
      Compare_Common
        ("CREATE INDEX ON direct_test ((payload->>'kind')) WHERE id > 0");
      Compare_Common
        ("EXPLAIN (ANALYZE false, VERBOSE true) SELECT * FROM direct_test");
      Compare_Common ("COPY direct_test FROM STDIN WITH (FORMAT csv, HEADER true)");
      Compare_Common ("SHOW search_path");
      Compare_Common ("SET LOCAL work_mem = '16MB'");
      Compare_Common ("BEGIN ISOLATION LEVEL SERIALIZABLE; COMMIT");
      Compare_Common ("-- comment" & ASCII.LF & "SELECT $$dollar text$$");
      Compare_Common ("SELECT 'unterminated");
      Compare_Common ("SELECT $$unterminated");
      Compare_Common ("SELECT /* unterminated");
      Compare_Common ("SELECT FROM WHERE");
      Compare_Common ("CREATE TABLE (");
      Compare_Common ("SELECT foo.*.bar FROM foo");
      Compare_Common ("SELECT 1" & Character'Val (0) & "SELECT 2");
      Compare_15 (Merge_SQL);
      Compare_16 (Merge_SQL);
      Compare_17 (Merge_SQL);
      Compare_18 (Merge_SQL);

      declare
         Tree : AST_18.Owned_Syntax_Tree;
      begin
         AST_18.Parse ("SELECT E'\401'", Tree);
         Assert (Tree.Valid, "V18 direct AST accepts a truncated octal escape");
      end;

      declare
         Tree : AST_18.Owned_Syntax_Tree;
      begin
         AST_18.Parse ("SELECT $12345678901, 1", Tree);
         Assert (not Tree.Valid, "V18 direct AST retains its parameter-number bound");
      end;

      declare
         Baseline, Direct : AST_15.Owned_Syntax_Tree;
         Options : constant SQL.Parse_Options :=
           (Mode => SQL.Type_Name, others => <>);
      begin
         Test_15.Parse_Baseline ("integer", Baseline, Options);
         AST_15.Parse ("integer", Direct, Options);
         Assert
           (Test_15.Equivalent (Baseline, Direct),
            "V15 direct AST differs in type-name parse mode");
      end;

      declare
         Direct : AST_14.Owned_Syntax_Tree;
         Raised : Boolean := False;
      begin
         begin
            AST_14.Parse
              ("integer", Direct, (Mode => SQL.Type_Name, others => <>));
         exception
            when SQL.Unsupported_Parse_Options =>
               Raised := True;
         end;
         Assert (Raised, "V14 direct path rejects unsupported parse options");
      end;
   end Test_Direct_Corpus;

   procedure Test_Generated_Visitors is
      T14 : AST_14.Owned_Syntax_Tree;
      T15 : AST_15.Owned_Syntax_Tree;
      T16 : AST_16.Owned_Syntax_Tree;
      T17 : AST_17.Owned_Syntax_Tree;
      T18 : AST_18.Owned_Syntax_Tree;
      V14 : Counting_Visitor_14;
      V15 : Counting_Visitor_15;
      V16 : Counting_Visitor_16;
      V17 : Counting_Visitor_17;
      V18 : Counting_Visitor_18;
      Pruner  : Pruning_Visitor;
      Stopper : Stopping_Visitor;
      Text : constant String :=
        "WITH active AS (SELECT id FROM accounts WHERE enabled) "
        & "SELECT a.id FROM active AS a JOIN audit AS b ON a.id = b.id "
        & "WHERE a.id > 10";
   begin
      AST_14.Parse ("SELECT 14", T14);
      AST_15.Parse ("SELECT 15", T15);
      AST_16.Parse ("SELECT 16", T16);
      AST_17.Parse ("SELECT 17", T17);
      AST_18.Parse (Text, T18);

      Visitors_14.Traverse (V14, T14);
      Visitors_15.Traverse (V15, T15);
      Visitors_16.Traverse (V16, T16);
      Visitors_17.Traverse (V17, T17);
      Visitors_18.Traverse (V18, T18);

      Assert
        (V14.Nodes > 0 and V15.Nodes > 0 and V16.Nodes > 0 and V17.Nodes > 0,
         "generated visitors traverse all four earlier version roots");
      Assert
        (V18.Nodes > 0 and then V18.Nodes = V18.Node_Leaves,
         "full visitor traversal balances generic node enter/leave callbacks");
      Assert
        (V18.Selects = 2 and V18.Ctes = 1 and V18.Joins = 1
         and V18.Expressions > 0,
         "typed callbacks cover SELECTs, CTEs, joins, and expressions");

      Visitors_18.Traverse (Pruner, T18);
      Assert
        (Pruner.Selects = 1 and Pruner.Select_Leaves = 1
         and Pruner.Nodes = 1,
         "Skip_Children prunes descendants and retains the leave callback");

      Visitors_18.Traverse (Stopper, T18.Root);
      Assert
        (Stopper.Nodes = 3,
         "Stop_Traversal ends traversal immediately from a node callback");
   end Test_Generated_Visitors;

   procedure Run is
   begin
      Ada.Text_IO.Put_Line ("  owned roots and arena equivalence");
      Test_Every_Version;
      Ada.Text_IO.Put_Line ("  owned complex traversal");
      Test_Complex_Traversal;
      Ada.Text_IO.Put_Line ("  owned presence");
      Test_Presence;
      Ada.Text_IO.Put_Line ("  owned lifetime");
      Test_Ownership_And_Replacement;
      Ada.Text_IO.Put_Line ("  owned complex baseline equivalence");
      Test_Direct_Path;
      Ada.Text_IO.Put_Line ("  owned corpus baseline equivalence");
      Test_Direct_Corpus;
      Ada.Text_IO.Put_Line ("  generated owned AST visitors");
      Test_Generated_Visitors;
   end Run;

end Owned_AST_Tests;
