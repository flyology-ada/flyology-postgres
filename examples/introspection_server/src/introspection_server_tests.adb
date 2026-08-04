with Ada.Calendar;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Exceptions;
with Ada.Text_IO;
with Introspection_Catalog;
with Introspection_SQL;
with Introspection_State;

procedure Introspection_Server_Tests is
   package SQL renames Introspection_SQL;
   package Catalog renames Introspection_Catalog;
   package State renames Introspection_State;

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
   Reject ("SELECT FROM flyology_tables", "missing projection is rejected");
   Reject
     ("SELECT * FROM flyology_tables LIMIT 65",
      "oversized LIMIT is rejected");
   Reject ("DELETE FROM flyology_tables", "unsupported statement is rejected");
   Reject ("SELECT 1; SELECT 2", "multiple statements are rejected");

   State.Initialize
     (Context,
      (Host            => SQL.Make_Text ("127.0.0.1", SQL.Maximum_Name_Length),
       Port            => 55_432,
       Repository_Path =>
         SQL.Make_Text (Ada.Directories.Current_Directory, 1_024),
       Task_Mode       =>
         SQL.Make_Text ("lightweight", SQL.Maximum_Name_Length),
       Started_At      => Ada.Calendar.Clock));
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
      Ada.Text_IO.Put_Line ("introspection parser/executor tests passed");
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
end Introspection_Server_Tests;
