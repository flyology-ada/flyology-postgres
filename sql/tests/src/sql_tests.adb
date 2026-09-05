with Ada.Text_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with AUnit.Assertions; use AUnit.Assertions;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.All_Versions;
pragma Elaborate_All (Flyology.Postgres.SQL.All_Versions);
with Flyology.Postgres.SQL.Views;
with Flyology.Postgres.SQL.Decoder_Testing;
with Flyology.Postgres.SQL.Differential_Testing;
with Flyology.Postgres.SQL.Native_Testing;
with Flyology.Postgres.SQL.Regression_Corpus_Testing;
with Flyology.Postgres.SQL.Views.V14;
with Flyology.Postgres.SQL.Views.V15;
with Flyology.Postgres.SQL.Views.V16;
with Flyology.Postgres.SQL.Views.V17;
with Flyology.Postgres.SQL.Views.V18;
with Flyology.Postgres.Types;
with Flyology.Postgres.Types.V18;
with Owned_AST_Tests;

procedure SQL_Tests is

   package SQL renames Flyology.Postgres.SQL;
   package Views renames Flyology.Postgres.SQL.Views;
   package V14 renames Flyology.Postgres.SQL.Views.V14;
   package V15 renames Flyology.Postgres.SQL.Views.V15;
   package V16 renames Flyology.Postgres.SQL.Views.V16;
   package V17 renames Flyology.Postgres.SQL.Views.V17;
   package V18 renames Flyology.Postgres.SQL.Views.V18;
   package Types renames Flyology.Postgres.Types;
   package Types_18 renames Flyology.Postgres.Types.V18;

   use type SQL.Major_Version;
   use type V18.Node_Kind;
   use type V18.A_Expr_Kind;
   use type Types.OID;
   use type Types.Length_Kind;
   use type Types.Passing_Kind;
   use type Types.Type_Category;

   procedure Test_Common_Syntax is
      Text : constant String :=
        "WITH recent AS (SELECT id, payload FROM events WHERE created_at > $1) "
        & "SELECT id, payload->>'kind' AS kind FROM recent "
        & "ORDER BY id DESC NULLS LAST LIMIT 50;";
   begin
      for Version in SQL.Major_Version loop
         declare
            Tree : Views.Syntax_Tree;
         begin
            Views.Parse (Text, Version, Tree);
            Assert (Views.Is_Valid (Tree), "common SQL parses for " & Version'Image);
            Assert (Views.Version (Tree) = Version, "tree retains its parser version");
            Assert (Views.Source (Tree) = Text, "tree owns the original SQL text");
         end;
      end loop;
   end Test_Common_Syntax;

   procedure Test_Protobuf_Corpus is
      procedure Parse_For_All (Text : String) is
      begin
         for Version in SQL.Major_Version loop
            declare
               Tree : Views.Syntax_Tree;
            begin
               Views.Parse (Text, Version, Tree);
               Assert
                 (Views.Is_Valid (Tree),
                  "protobuf corpus parses for " & Version'Image & ": " & Text);
            end;
         end loop;
      end Parse_For_All;

      NUL_Tree : Views.Syntax_Tree;
   begin
      Parse_For_All ("SELECT 0, FALSE, NULL");
      Parse_For_All ("SELECT 1; SELECT 2;");
      Parse_For_All ("SELECT ""Mixed Case"" FROM ""Quoted Table""");
      Parse_For_All ("SELECT 'é雪' AS unicode_text");
      Parse_For_All ("-- leading comment" & ASCII.LF & "SELECT /* inner */ 42");
      Parse_For_All ("SELECT $$dollar 'quoted' ; text$$");
      Parse_For_All ("COPY demo FROM STDIN WITH (FORMAT csv)");

      for Version in SQL.Major_Version loop
         declare
            Tree : Views.Syntax_Tree;
         begin
            Views.Parse ("SELECT 'unterminated", Version, Tree);
            Assert (not Views.Is_Valid (Tree), "invalid corpus input is rejected");
         end;
      end loop;

      Views.Parse
        ("SELECT 1" & Character'Val (0) & "SELECT 2",
         SQL.PostgreSQL_18,
         NUL_Tree);
      Assert (not Views.Is_Valid (NUL_Tree), "embedded NUL input is rejected");
      Assert
        (Views.Cursor_Position (Views.Error (NUL_Tree)) = 9,
         "embedded NUL diagnostic identifies the character position");
   end Test_Protobuf_Corpus;

   procedure Test_Version_Layers is
      Merge_SQL : constant String :=
        "MERGE INTO inventory AS i USING changes AS c ON i.id = c.id "
        & "WHEN MATCHED THEN UPDATE SET quantity = c.quantity "
        & "WHEN NOT MATCHED THEN INSERT (id, quantity) VALUES (c.id, c.quantity);";
      PG14 : Views.Syntax_Tree;
   begin
      Views.Parse (Merge_SQL, SQL.PostgreSQL_14, PG14);
      Assert (not Views.Is_Valid (PG14), "MERGE is rejected by PostgreSQL 14");

      for Version in SQL.PostgreSQL_15 .. SQL.PostgreSQL_18 loop
         declare
            Tree : Views.Syntax_Tree;
         begin
            Views.Parse (Merge_SQL, Version, Tree);
            Assert (Views.Is_Valid (Tree), "MERGE parses from PostgreSQL 15 onward");
         end;
      end loop;
   end Test_Version_Layers;

   procedure Test_Diagnostic is
      Tree : Views.Syntax_Tree;
   begin
      Views.Parse ("SELECT FROM WHERE", SQL.PostgreSQL_18, Tree);
      Assert (not Views.Is_Valid (Tree), "invalid SQL produces an invalid tree");
      Assert (Views.Message (Views.Error (Tree))'Length > 0, "diagnostic has a message");
      Assert
        (Views.Cursor_Position (Views.Error (Tree)) > 0,
         "diagnostic retains PostgreSQL's cursor position");
   end Test_Diagnostic;

   procedure Test_Parse_Options is
      Tree     : Views.Syntax_Tree;
      Rejected : Boolean := False;
   begin
      Assert
        (not SQL.Supports_Parse_Options (SQL.PostgreSQL_14),
         "PostgreSQL 14 reports its extraction's option limitation");
      Assert
        (SQL.Supports_Parse_Options (SQL.PostgreSQL_15),
         "PostgreSQL 15 supports parser modes and lexer GUC options");
      begin
         Views.Parse
           ("integer",
            SQL.PostgreSQL_14,
            Tree,
            (Mode => SQL.Type_Name, others => <>));
      exception
         when SQL.Unsupported_Parse_Options =>
            Rejected := True;
      end;
      Assert (Rejected, "PostgreSQL 14 does not silently ignore parse options");
      Views.Parse
        ("integer",
         SQL.PostgreSQL_15,
         Tree,
         (Mode => SQL.Type_Name, others => <>));
      Assert (Views.Is_Valid (Tree), "PostgreSQL 15 type-name mode parses a type");
   end Test_Parse_Options;

   procedure Test_Typed_V18_Tree is
      Tree : Views.Syntax_Tree;
   begin
      Views.Parse ("SELECT 1 AS answer", SQL.PostgreSQL_18, Tree);
      Assert (Views.Is_Valid (Tree), "typed-tree input parses");
      declare
         Parsed : constant V18.Parse_Result :=
           V18.View (Tree, V18.Root (Tree));
         Statements : constant V18.Sequence_Of_Raw_Stmt := Parsed.Statements;
         Raw_Ref : constant V18.Raw_Stmt_Reference :=
           V18.Element (Tree, Statements, 1);
         Raw_View : constant V18.Raw_Stmt := V18.View (Tree, Raw_Ref);
         Item : constant V18.Node_Reference := V18.Statement (Tree, Raw_Ref);
         Select_Ref : constant V18.Select_Stmt_Reference :=
           V18.As_Select_Stmt (Tree, Item);
         Select_View : constant V18.Select_Stmt :=
           V18.View (Tree, Select_Ref);
         Target_Node : constant V18.Node_Reference :=
           V18.Element (Tree, Select_View.Target_List, 1);
         Target : constant V18.Res_Target :=
           V18.View (Tree, V18.As_Res_Target (Tree, Target_Node));
      begin
         Assert
           (V18.Length (Tree, Statements) = 1,
            "typed root contains one statement");
         Assert (Raw_View.Statement.Present, "RawStmt preserves statement presence");
         Assert
           (V18.Kind (Tree, Item) = V18.Node_Select_Stmt,
            "statement is a SelectStmt");
         Assert
           (V18.Length (Tree, Select_View.Target_List) = 1,
            "SelectStmt exposes its target-list sequence as a field");
         Assert
           (not Select_View.Where_Clause.Present,
            "an omitted WHERE is distinct from a present node");
         Assert (Target.Name.Present, "the target alias is present");
         Assert
           (To_String (Target.Name.Value) = "answer",
            "public text fields own their Ada string value");
      end;
   end Test_Typed_V18_Tree;

   procedure Test_Every_Typed_Root is
      T14 : Views.Syntax_Tree;
      T15 : Views.Syntax_Tree;
      T16 : Views.Syntax_Tree;
      T17 : Views.Syntax_Tree;
   begin
      Views.Parse ("SELECT 1", SQL.PostgreSQL_14, T14);
      Views.Parse ("SELECT 1", SQL.PostgreSQL_15, T15);
      Views.Parse ("SELECT 1", SQL.PostgreSQL_16, T16);
      Views.Parse ("SELECT 1", SQL.PostgreSQL_17, T17);
      Assert
        (V14.Length (T14, V14.View (T14, V14.Root (T14)).Statements) = 1,
         "V14 shallow typed root works");
      Assert
        (V15.Length (T15, V15.View (T15, V15.Root (T15)).Statements) = 1,
         "V15 shallow typed root works");
      Assert
        (V16.Length (T16, V16.View (T16, V16.Root (T16)).Statements) = 1,
         "V16 shallow typed root works");
      Assert
        (V17.Length (T17, V17.View (T17, V17.Root (T17)).Statements) = 1,
         "V17 shallow typed root works");
   end Test_Every_Typed_Root;

   procedure Test_Complex_Record_Views is
      Tree : Views.Syntax_Tree;

      function First_Statement return V18.Node_Reference is
         Items : constant V18.Sequence_Of_Raw_Stmt :=
           V18.Statements (Tree, V18.Root (Tree));
      begin
         return V18.Statement (Tree, V18.Element (Tree, Items, 1));
      end First_Statement;
   begin
      Views.Parse
        ("WITH active AS (SELECT id FROM accounts WHERE enabled) "
         & "SELECT a.id FROM active AS a JOIN audit AS b ON a.id = b.id "
         & "WHERE a.id > 10",
         SQL.PostgreSQL_18,
         Tree);
      Assert (Views.Is_Valid (Tree), "complex SELECT parses");
      declare
         Select_View : constant V18.Select_Stmt :=
           V18.View
             (Tree, V18.As_Select_Stmt (Tree, First_Statement));
         With_View : constant V18.With_Clause :=
           V18.View (Tree, Select_View.With_Clause.Value);
         CTE_Node : constant V18.Node_Reference :=
           V18.Element (Tree, With_View.Ctes, 1);
         CTE_View : constant V18.Common_Table_Expr :=
           V18.View (Tree, V18.As_Common_Table_Expr (Tree, CTE_Node));
         Join_Node : constant V18.Node_Reference :=
           V18.Element (Tree, Select_View.From_Clause, 1);
         Join_View : constant V18.Join_Expr :=
           V18.View (Tree, V18.As_Join_Expr (Tree, Join_Node));
         Expression_Node : constant V18.Node_Reference :=
           Select_View.Where_Clause.Value;
         Expression : constant V18.A_Expr :=
           V18.View (Tree, V18.As_A_Expr (Tree, Expression_Node));
      begin
         Assert (Select_View.With_Clause.Present, "WITH clause reference is present");
         Assert (V18.Length (Tree, With_View.Ctes) = 1, "CTE sequence is exposed");
         Assert
           (CTE_View.Ctequery.Present,
            "CTE query remains an opaque nested node reference");
         Assert (Join_View.Larg.Present and Join_View.Rarg.Present,
                 "join child references are present");
         Assert (Join_View.Quals.Present, "join expression reference is present");
         Assert (Expression.Kind.Present, "expression enum presence is retained");
         Assert
           (Expression.Kind.Value = V18.A_Expr_Kind_Aexpr_Op,
            "expression enum value is decoded into the generated Ada enum");
      end;

      Views.Parse
        ("MERGE INTO inventory AS i USING changes AS c ON i.id = c.id "
         & "WHEN MATCHED THEN UPDATE SET quantity = c.quantity",
         SQL.PostgreSQL_18,
         Tree);
      declare
         Merge_View : constant V18.Merge_Stmt :=
           V18.View (Tree, V18.As_Merge_Stmt (Tree, First_Statement));
      begin
         Assert (Merge_View.Relation.Present, "MERGE relation is typed");
         Assert
           (V18.Length (Tree, Merge_View.Merge_When_Clauses) = 1,
            "MERGE actions are a typed node sequence");
      end;

      Views.Parse
        ("CREATE TABLE typed_example "
         & "(id bigint PRIMARY KEY, payload jsonb NOT NULL)",
         SQL.PostgreSQL_18,
         Tree);
      declare
         Create_View : constant V18.Create_Stmt :=
           V18.View (Tree, V18.As_Create_Stmt (Tree, First_Statement));
      begin
         Assert (Create_View.Relation.Present, "DDL relation reference is typed");
         Assert
           (V18.Length (Tree, Create_View.Table_Elts) = 2,
            "DDL elements are available through field notation");
      end;

      Views.Parse ("SHOW search_path", SQL.PostgreSQL_18, Tree);
      declare
         Show_View : constant V18.Variable_Show_Stmt :=
           V18.View
             (Tree, V18.As_Variable_Show_Stmt (Tree, First_Statement));
      begin
         Assert (Show_View.Name.Present, "utility statement text is optional-owned");
         Assert
           (To_String (Show_View.Name.Value) = "search_path",
            "utility statement text is retained");
      end;
   end Test_Complex_Record_Views;

   procedure Test_Catalog_Types is
      JSONB : constant Types.Type_Descriptor :=
        Types.Lookup (SQL.PostgreSQL_18, Types_18.Jsonb_OID);
      Integer_Type : constant Types.Type_Descriptor :=
        Types.Lookup (SQL.PostgreSQL_18, "INT4");
   begin
      Assert (Types.Is_Known (JSONB), "jsonb OID is known");
      Assert (Types.SQL_Name (JSONB) = "jsonb", "catalog type name is retained");
      Assert
        (Types.Array_Type_OID (JSONB) = Types_18.Jsonb_Array_OID,
         "catalog array OID is retained");
      Assert
        (Types.Category (JSONB) = Types.User_Category,
         "jsonb category matches pg_type.dat");
      Assert
        (Types.Length_Form (JSONB) = Types.Variable_Length,
         "jsonb is a varlena type");
      Assert (Types.Is_Known (Integer_Type), "name lookup folds unquoted SQL names");
      Assert (Types.Fixed_Size (Integer_Type) = 4, "int4 has four-byte storage");
      Assert
        (Types.Passing (Integer_Type) = Types.By_Value,
         "int4 is passed by value");
      Assert
        (not Types.Is_Known (Types.Lookup (SQL.PostgreSQL_18, Types.No_OID)),
         "unknown OIDs return Unknown_Type");
   end Test_Catalog_Types;

begin
   Ada.Text_IO.Put_Line ("Test_Native_Parser_Runtime");
   Flyology.Postgres.SQL.Native_Testing.Run;
   Ada.Text_IO.Put_Line ("Test_Protobuf_Wire_Decoder");
   Flyology.Postgres.SQL.Decoder_Testing.Run;
   Ada.Text_IO.Put_Line ("Test_Native_C_Differential");
   Flyology.Postgres.SQL.Differential_Testing.Run;
   Flyology.Postgres.SQL.Regression_Corpus_Testing.Run;
   Ada.Text_IO.Put_Line ("Test_Common_Syntax");
   Test_Common_Syntax;
   Ada.Text_IO.Put_Line ("Test_Protobuf_Corpus");
   Test_Protobuf_Corpus;
   Ada.Text_IO.Put_Line ("Test_Version_Layers");
   Test_Version_Layers;
   Ada.Text_IO.Put_Line ("Test_Diagnostic");
   Test_Diagnostic;
   Ada.Text_IO.Put_Line ("Test_Parse_Options");
   Test_Parse_Options;
   Ada.Text_IO.Put_Line ("Test_Typed_V18_Tree");
   Test_Typed_V18_Tree;
   Ada.Text_IO.Put_Line ("Test_Every_Typed_Root");
   Test_Every_Typed_Root;
   Ada.Text_IO.Put_Line ("Test_Complex_Record_Views");
   Test_Complex_Record_Views;
   Ada.Text_IO.Put_Line ("Test_Owned_ASTs");
   Owned_AST_Tests.Run;
   Ada.Text_IO.Put_Line ("Test_Catalog_Types");
   Test_Catalog_Types;
   Ada.Text_IO.Put_Line ("All PostgreSQL SQL parser tests passed");
end SQL_Tests;
