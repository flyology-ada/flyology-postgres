with Ada.Containers;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.AST.V14;
with Flyology.Postgres.SQL.AST.V15;
with Flyology.Postgres.SQL.AST.V16;
with Flyology.Postgres.SQL.AST.V17;
with Flyology.Postgres.SQL.AST.V18;
with Interfaces;

package body Owned_AST_Tests is

   package SQL renames Flyology.Postgres.SQL;
   package AST_14 renames Flyology.Postgres.SQL.AST.V14;
   package AST_15 renames Flyology.Postgres.SQL.AST.V15;
   package AST_16 renames Flyology.Postgres.SQL.AST.V16;
   package AST_17 renames Flyology.Postgres.SQL.AST.V17;
   package AST_18 renames Flyology.Postgres.SQL.AST.V18;

   use type AST_14.Node_Kind;
   use type AST_15.Node_Kind;
   use type AST_16.Node_Kind;
   use type AST_17.Node_Kind;
   use type AST_18.A_Expr_Kind;
   use type AST_18.Node_Kind;
   use type Ada.Containers.Count_Type;
   use type Interfaces.Integer_32;

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
      AST_14.Parse ("SELECT 14", T14);
      AST_15.Parse ("SELECT 15", T15);
      AST_16.Parse ("SELECT 16", T16);
      AST_17.Parse ("SELECT 17", T17);
      AST_18.Parse ("SELECT 18", T18);
      AST_14.Parse_Direct ("SELECT 14", D14);
      AST_15.Parse_Direct ("SELECT 15", D15);
      AST_16.Parse_Direct ("SELECT 16", D16);
      AST_17.Parse_Direct ("SELECT 17", D17);
      AST_18.Parse_Direct ("SELECT 18", D18);

      Assert (AST_14.Equivalent (T14, D14),
              "PostgreSQL 14 direct output equals Phase 2");
      Assert (AST_15.Equivalent (T15, D15),
              "PostgreSQL 15 direct output equals Phase 2");
      Assert (AST_16.Equivalent (T16, D16),
              "PostgreSQL 16 direct output equals Phase 2");
      Assert (AST_17.Equivalent (T17, D17),
              "PostgreSQL 17 direct output equals Phase 2");
      Assert (AST_18.Equivalent (T18, D18),
              "PostgreSQL 18 direct output equals Phase 2");

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
      Arena : SQL.Syntax_Tree;
      Tree  : AST_18.Owned_Syntax_Tree;
   begin
      SQL.Parse ("SELECT 1 AS retained", SQL.PostgreSQL_18, Arena);
      AST_18.Materialize (Arena, Tree);
      SQL.Parse ("SELECT 2", SQL.PostgreSQL_18, Arena);
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
      AST_18.Parse (Text, Baseline);
      AST_18.Parse_Direct (Text, Direct);
      Assert (Direct.Valid, "direct semantic construction succeeds");
      Assert
        (AST_18.Equivalent (Baseline, Direct),
         "every owned field matches the Phase 2 baseline");
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
            "direct target sequence matches the Phase 2 baseline");
         Assert
           (Actual.From_Clause.Length = Expected.From_Clause.Length,
            "direct FROM sequence matches the Phase 2 baseline");
         Assert
           (Actual.With_Clause.Present = Expected.With_Clause.Present,
            "direct optional presence matches the Phase 2 baseline");
         Assert
           (Actual.Where_Clause.Present = Expected.Where_Clause.Present,
            "direct expression presence matches the Phase 2 baseline");
      end;
   end Test_Direct_Path;

   procedure Test_Direct_Corpus is
      procedure Compare_14 (Text : String) is
         Baseline, Direct : AST_14.Owned_Syntax_Tree;
      begin
         AST_14.Parse (Text, Baseline);
         AST_14.Parse_Direct (Text, Direct);
         Assert (AST_14.Equivalent (Baseline, Direct),
                 "V14 direct AST differs for: " & Text);
      end Compare_14;

      procedure Compare_15 (Text : String) is
         Baseline, Direct : AST_15.Owned_Syntax_Tree;
      begin
         AST_15.Parse (Text, Baseline);
         AST_15.Parse_Direct (Text, Direct);
         Assert (AST_15.Equivalent (Baseline, Direct),
                 "V15 direct AST differs for: " & Text);
      end Compare_15;

      procedure Compare_16 (Text : String) is
         Baseline, Direct : AST_16.Owned_Syntax_Tree;
      begin
         AST_16.Parse (Text, Baseline);
         AST_16.Parse_Direct (Text, Direct);
         Assert (AST_16.Equivalent (Baseline, Direct),
                 "V16 direct AST differs for: " & Text);
      end Compare_16;

      procedure Compare_17 (Text : String) is
         Baseline, Direct : AST_17.Owned_Syntax_Tree;
      begin
         AST_17.Parse (Text, Baseline);
         AST_17.Parse_Direct (Text, Direct);
         Assert (AST_17.Equivalent (Baseline, Direct),
                 "V17 direct AST differs for: " & Text);
      end Compare_17;

      procedure Compare_18 (Text : String) is
         Baseline, Direct : AST_18.Owned_Syntax_Tree;
      begin
         AST_18.Parse (Text, Baseline);
         AST_18.Parse_Direct (Text, Direct);
         Assert (AST_18.Equivalent (Baseline, Direct),
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
      Compare_Common ("SELECT 1; SELECT 2;");
      Compare_Common ("SELECT ""Mixed Case"" FROM ""Quoted Table""");
      Compare_Common
        ("-- leading" & ASCII.LF
         & "SELECT /* nested /* block */ ok */ 42");
      Compare_Common
        ("WITH q AS (SELECT id FROM events) "
         & "SELECT q.id FROM q JOIN audit a ON q.id = a.id WHERE q.id > 1");
      Compare_Common ("SELECT E'line\n', U&'d\0061t\+000061'");
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
         Baseline, Direct : AST_15.Owned_Syntax_Tree;
         Options : constant SQL.Parse_Options :=
           (Mode => SQL.Type_Name, others => <>);
      begin
         AST_15.Parse ("integer", Baseline, Options);
         AST_15.Parse_Direct ("integer", Direct, Options);
         Assert
           (AST_15.Equivalent (Baseline, Direct),
            "V15 direct AST differs in type-name parse mode");
      end;

      declare
         Direct : AST_14.Owned_Syntax_Tree;
         Raised : Boolean := False;
      begin
         begin
            AST_14.Parse_Direct
              ("integer", Direct, (Mode => SQL.Type_Name, others => <>));
         exception
            when SQL.Unsupported_Parse_Options =>
               Raised := True;
         end;
         Assert (Raised, "V14 direct path rejects unsupported parse options");
      end;
   end Test_Direct_Corpus;

   procedure Run is
   begin
      Ada.Text_IO.Put_Line ("  owned roots and direct equivalence");
      Test_Every_Version;
      Ada.Text_IO.Put_Line ("  owned complex traversal");
      Test_Complex_Traversal;
      Ada.Text_IO.Put_Line ("  owned presence");
      Test_Presence;
      Ada.Text_IO.Put_Line ("  owned lifetime");
      Test_Ownership_And_Replacement;
      Ada.Text_IO.Put_Line ("  owned direct complex equivalence");
      Test_Direct_Path;
      Ada.Text_IO.Put_Line ("  owned direct corpus equivalence");
      Test_Direct_Corpus;
   end Run;

end Owned_AST_Tests;
