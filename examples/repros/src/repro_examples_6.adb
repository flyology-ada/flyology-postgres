--  EXAMPLES-6: double-quoted identifiers must keep their case, and a column or
--  table qualifier must be validated.  Pgish_Catalog.Base_Name strips any
--  qualifier and lowercases what remains; Find_Column, Load_Source and the
--  projected output name all go through it.  The pgish README states
--  "Identifiers are case-insensitive unless double quoted" and that tables may
--  be named "directly or under the synthetic flyology schema", so quoting has
--  no effect and any schema/table qualifier is accepted.

with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_6 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   procedure Expect_Rejected (Text : String; Description : String) is
      Rejected : Boolean := False;
   begin
      begin
         Catalog.Execute (Context, Session, SQL.Parse (Text), Result);
      exception
         when Error : SQL.Syntax_Error
            | Catalog.Undefined_Column_Error
            | Catalog.Undefined_Table_Error =>
            Rejected := True;
            Note (Description & ": rejected with "
                  & Ada.Exceptions.Exception_Name (Error));
      end;
      if not Rejected then
         Note (Description & ": accepted, "
               & Result.Column_Count'Image & " column(s) named """
               & (if Result.Column_Count > 0
                  then SQL.Image (Result.Columns (1).Name) else "")
               & """," & Result.Row_Count'Image & " row(s)");
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

   --  Baseline: unquoted identifiers are case-insensitive, as documented.
   Catalog.Execute
     (Context, Session,
      SQL.Parse ("SELECT PROTOCOL_VERSION FROM FLYOLOGY_SERVER_INFO"), Result);
   Check (Result.Column_Count = 1 and then Result.Row_Count = 1,
          "unquoted identifiers are case-insensitive");

   --  PostgreSQL: 42703, column "PROTOCOL_VERSION" does not exist.
   Expect_Rejected
     ("SELECT ""PROTOCOL_VERSION"" FROM flyology_server_info",
      "a double-quoted upper-case column name is case sensitive");

   --  PostgreSQL: 42P01, relation "FLYOLOGY_SERVER_INFO" does not exist.
   Expect_Rejected
     ("SELECT protocol_version FROM ""FLYOLOGY_SERVER_INFO""",
      "a double-quoted upper-case table name is case sensitive");

   --  PostgreSQL: 42P01, missing FROM-clause entry for table "nowhere".
   Expect_Rejected
     ("SELECT nowhere.protocol_version FROM flyology_server_info",
      "an unknown column qualifier is rejected");

   --  README: tables are named directly or under the flyology schema only.
   Expect_Rejected
     ("SELECT * FROM bogus_schema.flyology_tables",
      "an unknown schema qualifier is rejected");
   Finish;
end Repro_Examples_6;
