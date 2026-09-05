with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;

procedure Pgish_Tests is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   use type SQL.Comparison_Operator;
   use type SQL.Statement_Kind;

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Message : String) is
   begin
      if not Condition then
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line (Ada.Text_IO.Standard_Error, "FAIL: " & Message);
      end if;
   end Check;

   procedure Reject (Text : String; Message : String) is
      Rejected : Boolean := False;
   begin
      begin
         declare
            Ignored : constant SQL.Query := SQL.Parse (Text);
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
      exception
         when SQL.Syntax_Error => Rejected := True;
      end;
      Check (Rejected, Message);
   end Reject;

   Context : State.Server_State;
   Accepted : Boolean;
   Session : State.Session_Snapshot;
   Result : Catalog.Result_Set;
begin
   declare
      Query : constant SQL.Query := SQL.Parse
        ("SeLeCt table_name AS name, 'it''s safe' label " &
         "FROM information_schema.tables " &
         "WHERE table_schema = 'flyology' AND table_name LIKE 'flyology_%' " &
         "ORDER BY name DESC LIMIT 3;");
   begin
      Check (Query.Projection_Count = 2, "case-insensitive SELECT parses");
      Check (Query.Predicate_Count = 2, "AND predicates parse");
      Check (Query.Order_Descending and then Query.Limit = 3,
             "ORDER BY DESC and LIMIT parse");
      Check (SQL.Image (Query.Projections (2).Literal) = "it's safe",
             "doubled quoted string is decoded");
   end;
   declare
      Query : constant SQL.Query := SQL.Parse
        ("SELECT ""table_name"" FROM ""information_schema"".""tables""");
   begin
      Check (SQL.Image (Query.Table_Name) = "information_schema.tables",
             "quoted qualified identifiers parse");
   end;
   declare
      Query : constant SQL.Query := SQL.Parse
        ("SELECT -12 AS signed_value FROM metrics " &
         "WHERE a != 1 AND b <> 2 AND c < 3 AND d <= 4 " &
         "AND e > 5 AND f >= 6");
   begin
      Check
        (SQL.Image (Query.Projections (1).Literal) = "-12",
         "signed integer literals lower from A_Const");
      Check
        (Query.Predicate_Count = 6
         and then Query.Predicates (1).Operator = SQL.Not_Equal_To
         and then Query.Predicates (2).Operator = SQL.Not_Equal_To
         and then Query.Predicates (3).Operator = SQL.Less_Than
         and then Query.Predicates (4).Operator = SQL.Less_Or_Equal
         and then Query.Predicates (5).Operator = SQL.Greater_Than
         and then Query.Predicates (6).Operator = SQL.Greater_Or_Equal,
         "all supported comparison operators lower from A_Expr");
   end;
   Reject
     ("SELECT name FROM flyology_settings " &
      "WHERE name NOT LIKE 'maximum%'",
      "NOT LIKE remains outside the pgish subset");
   declare
      Query : constant SQL.Query := SQL.Parse
        ("SELECT '' AS empty_value, 0 AS zero_value;");
   begin
      Check
        (SQL.Image (Query.Projections (1).Literal) = ""
         and then SQL.Image (Query.Projections (2).Literal) = "0",
         "protobuf-default literals retain their SQL values");
   end;
   declare
      Query : constant SQL.Query := SQL.Parse ("SHOW server_version");
   begin
      Check
        (Query.Kind = SQL.Show_Statement
         and then SQL.Image (Query.Show_Name) = "server_version",
         "SHOW lowers from Variable_Show_Stmt");
   end;
   Reject ("SELECT FROM flyology_tables", "missing projection is rejected");
   Reject
     ("SELECT * FROM flyology_tables LIMIT 65",
      "oversized LIMIT is rejected");
   Reject ("DELETE FROM flyology_tables", "unsupported statement is rejected");
   Reject ("SELECT 1; SELECT 2", "multiple statements are rejected");
   Reject ("SELECT DISTINCT name FROM flyology_tables",
           "DISTINCT remains outside the pgish subset");
   Reject ("SELECT * FROM a JOIN b ON a.id = b.id",
           "joins remain outside the pgish subset");
   Reject ("SELECT * FROM flyology_tables AS t",
           "table aliases remain outside the pgish subset");
   Reject ("SELECT value + 1 FROM flyology_settings",
           "computed projections remain outside the pgish subset");
   Reject ("SELECT arbitrary_function()",
           "arbitrary functions remain outside the pgish subset");
   Reject ("SELECT * FROM flyology_settings WHERE a = 1 OR b = 2",
           "OR predicates remain outside the pgish subset");
   Reject ("SELECT * FROM flyology_settings OFFSET 1",
           "OFFSET remains outside the pgish subset");
   Reject ("SELECT 1.5", "non-integer numeric projections remain unsupported");
   Reject ("SELECT * FROM flyology_tables LIMIT -1",
           "negative LIMIT remains unsupported");

   State.Initialize
     (Context,
      (Host            => SQL.Make_Text ("127.0.0.1", SQL.Maximum_Name_Length),
       Port            => 55_432,
       Repository_Path =>
         SQL.Make_Text (Ada.Directories.Current_Directory, 1_024),
       Task_Mode       =>
         SQL.Make_Text ("lightweight", SQL.Maximum_Name_Length),
       TLS_Enabled     => False,
       Started_At      => Ada.Calendar.Clock));
   declare
      Matched : Boolean;
   begin
      Catalog.Psql_Compatibility
        (Context,
         "SELECT schemaname AS schema, tablename AS name, " &
         "tableowner AS owner FROM pg_catalog.pg_tables " &
         "WHERE schemaname NOT IN ('pg_catalog', 'information_schema') " &
         "ORDER BY schemaname, tablename;",
         Matched,
         Result);
      Check
        (Matched and then Result.Column_Count = 3
         and then Result.Row_Count > 0,
         "psqlish table-list query is compatible");
   end;
   declare
      Query : constant SQL.Query := SQL.Parse
        ("SELECT column_name AS name, data_type AS data_type, " &
         "is_nullable AS nullable, column_default AS default_value " &
         "FROM information_schema.columns " &
         "WHERE table_name = 'flyology_server_info' " &
         "AND table_schema = 'flyology' ORDER BY name;");
   begin
      Catalog.Execute (Context, Session, Query, Result);
      Check
        (Result.Column_Count = 4 and then Result.Row_Count = 9,
         "filtered information_schema columns stay within result bounds");
   end;
   State.Register_Session
     (Context, "flyology", "flyology", "tests", Accepted);
   Check (Accepted, "test session registers");

   State.Begin_Query (Context, "test", Session);
   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT table_name AS name FROM information_schema.tables " &
         "WHERE table_schema = 'flyology' ORDER BY name DESC LIMIT 2"),
      Result);
   Check (Result.Column_Count = 1 and then Result.Row_Count = 2,
          "projection, filtering, ordering, and limiting execute");
   Check
     (SQL.Image (Result.Rows (1).Values (1).Value) >
        SQL.Image (Result.Rows (2).Values (1).Value),
      "descending order is applied");

   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT name, unit FROM flyology_settings " &
         "WHERE unit IS NULL ORDER BY name LIMIT 4"),
      Result);
   Check (Result.Row_Count = 2, "NULL predicates preserve NULL semantics");
   Check (Result.Rows (1).Values (2).Is_Null, "NULL differs from empty text");

   declare
      procedure Check_Like (Pattern : String) is
      begin
         begin
            Catalog.Execute
              (Context, Session,
               SQL.Parse
                 ("SELECT name FROM flyology_settings WHERE name LIKE '" &
                  Pattern & "'"),
               Result);
            Check
              (Result.Row_Count = 6,
               "LIKE '" & Pattern & "' matches every non-NULL name");
         exception
            when Error : others =>
               Check
                 (False,
                  "LIKE '" & Pattern & "' does not raise " &
                  Ada.Exceptions.Exception_Name (Error));
         end;
      end Check_Like;
   begin
      Catalog.Execute
        (Context, Session,
         SQL.Parse ("SELECT name FROM flyology_settings"), Result);
      Check (Result.Row_Count = 6, "flyology_settings has six named rows");
      Check_Like ("%");
      Check_Like ("%%");
   end;

   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT current_database(), current_user, version(), now()"),
      Result);
   Check (Result.Row_Count = 1 and then Result.Column_Count = 4,
          "literal-free SELECT functions execute");
   Check (SQL.Image (Result.Rows (1).Values (1).Value) = "flyology",
          "current_database uses startup state");

   begin
      Catalog.Execute
        (Context, Session, SQL.Parse ("SELECT * FROM absent_table"), Result);
      Check (False, "undefined table should fail");
   exception
      when Catalog.Undefined_Table_Error => null;
   end;
   State.End_Query (Context);
   State.Remove_Session (Context);

   if Failures = 0 then
      Ada.Text_IO.Put_Line ("pgish parser/executor tests passed");
   else
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error, Failures'Image & " tests failed");
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "unexpected test exception: " &
         Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Pgish_Tests;
