--  EXAMPLES-2: NOT LIKE must not be evaluated as LIKE.
--  The PostgreSQL grammar lowers "a NOT LIKE b" to the same AEXPR_LIKE kind
--  with operator name "!~~"; Pgish_SQL.Add_Predicate ignores the name for that
--  kind and stores Like_Match, so the predicate is silently inverted.
--  Correct behaviour: either negate (PostgreSQL semantics) or reject the
--  statement as outside the documented subset.

with Ada.Calendar;
with Ada.Directories;
with Ada.Exceptions;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_2 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   function First_Name return String is
     (SQL.Image (Result.Rows (1).Values (1).Value));
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

   --  Baseline: the positive form selects the four maximum_* settings.
   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT name FROM flyology_settings WHERE name LIKE 'maximum%' " &
         "ORDER BY name"),
      Result);
   Check (Result.Row_Count = 4,
          "LIKE 'maximum%' selects the four maximum_* settings (got"
          & Result.Row_Count'Image & ")");

   declare
      Query : SQL.Query;
      Accepted : Boolean := True;
   begin
      begin
         Query := SQL.Parse
           ("SELECT name FROM flyology_settings WHERE name NOT LIKE " &
            "'maximum%' ORDER BY name");
      exception
         when Error : SQL.Syntax_Error =>
            Accepted := False;
            Note ("NOT LIKE rejected at parse time: "
                  & Ada.Exceptions.Exception_Message (Error));
      end;
      if Accepted then
         Note ("NOT LIKE parsed; stored operator is "
               & Query.Predicates (1).Operator'Image);
         Catalog.Execute (Context, Session, Query, Result);
         Note ("NOT LIKE 'maximum%' returned" & Result.Row_Count'Image
               & " row(s); first ="
               & (if Result.Row_Count > 0 then " " & First_Name else " <none>"));
         Check (Result.Row_Count = 2,
                "NOT LIKE 'maximum%' selects authentication and tls (got"
                & Result.Row_Count'Image & ")");
         Check (Result.Row_Count > 0 and then First_Name = "authentication",
                "first NOT LIKE row is 'authentication'");
      else
         Note ("rejecting NOT LIKE is acceptable: the subset is documented");
      end if;
   end;
   Finish;
end Repro_Examples_2;
