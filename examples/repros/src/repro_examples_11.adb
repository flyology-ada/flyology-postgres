--  EXAMPLES-11: "SELECT *" without a FROM clause must be rejected.
--  PostgreSQL answers ERROR 42601 "SELECT * with no tables specified is not
--  valid".  In Pgish_Catalog.Project the star expansion loops over an empty
--  Source, so no column and no value is added, and Add_Projected_Row
--  (Empty_Row) still appends one row.  The handler then puts a RowDescription
--  with zero fields and a DataRow with zero columns on the wire, which is what
--  makes psqlish fail (EXAMPLES-4).

with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_11 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   procedure Expect_Rejected (Text, Description : String) is
      Rejected : Boolean := False;
   begin
      begin
         Catalog.Execute (Context, Session, SQL.Parse (Text), Result);
      exception
         when Error : SQL.Syntax_Error
            | Catalog.Undefined_Column_Error
            | Catalog.Undefined_Table_Error
            | Catalog.Unsupported_Error =>
            Rejected := True;
            Note (Description & ": rejected with "
                  & Ada.Exceptions.Exception_Name (Error));
      end;
      if not Rejected then
         Note (Description & ": accepted, Column_Count ="
               & Result.Column_Count'Image & ", Row_Count ="
               & Result.Row_Count'Image);
      end if;
      Check (Rejected, Description);
   end Expect_Rejected;
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

   Expect_Rejected ("SELECT *", "SELECT * with no FROM clause is rejected");
   Expect_Rejected ("SELECT *;", "SELECT *; with no FROM clause is rejected");
   Finish;
end Repro_Examples_11;
