--  EXAMPLES-1: LIKE '%' (and '%%') must match every non-NULL value.
--  Pgish_Catalog.Like computes an empty Needle for those patterns and calls
--  Ada.Strings.Fixed.Index with a null pattern, which propagates
--  Ada.Strings.Pattern_Error (RM A.4.3) out of Pgish_Catalog.Execute.

with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_1 is
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

   --  Baseline: the six flyology_settings rows all have a non-NULL name.
   Try ("SELECT name FROM flyology_settings", 6);
   --  PostgreSQL: LIKE '%' matches every non-NULL value.
   Try ("SELECT name FROM flyology_settings WHERE name LIKE '%'", 6);
   --  PostgreSQL: '%%' is also 'match anything'.
   Try ("SELECT name FROM flyology_settings WHERE name LIKE '%%'", 6);
   Finish;
end Repro_Examples_1;
