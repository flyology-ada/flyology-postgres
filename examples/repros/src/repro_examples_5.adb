--  EXAMPLES-5: information_schema.columns must be readable without a
--  "table_name = ..." predicate.  Add_Information_Columns materializes one row
--  per column of every virtual table (9+16+8+8+5+3+4+2 = 55) before Project or
--  LIMIT run, and Add_Row raises Resource_Limit_Error at Maximum_Rows = 32.
--  Execute pushes down only the first predicate whose column is table_name
--  with operator Equal_To, so LIMIT alone, or a table_schema filter, still
--  materializes all 55 rows and fails with SQLSTATE 54000.

with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_5 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   procedure Try (Text : String; Expected_Rows : Natural) is
   begin
      Catalog.Execute (Context, Session, SQL.Parse (Text), Result);
      Check (Result.Row_Count = Expected_Rows,
             Text & " returns" & Expected_Rows'Image & " rows (got"
             & Result.Row_Count'Image & ")");
   exception
      when Error : others =>
         Note ("unexpected " & Ada.Exceptions.Exception_Name (Error)
               & " : " & Ada.Exceptions.Exception_Message (Error));
         Check (False, Text & " must not raise");
   end Try;
begin
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

   --  Baseline: the pushdown shape already covered by pgish_tests works.
   Try ("SELECT column_name FROM information_schema.columns " &
        "WHERE table_name = 'flyology_server_info'", 9);

   --  A bare LIMIT, documented by the README as part of the subset.
   Try ("SELECT column_name FROM information_schema.columns LIMIT 5", 5);

   --  A schema filter plus LIMIT: still no table_name = pushdown.
   Try ("SELECT column_name FROM information_schema.columns " &
        "WHERE table_schema = 'flyology' LIMIT 1", 1);

   --  A LIKE filter on table_name is not an Equal_To pushdown either.
   Try ("SELECT column_name FROM information_schema.columns " &
        "WHERE table_name LIKE 'flyology_server%' LIMIT 5", 5);
   Finish;
end Repro_Examples_5;
