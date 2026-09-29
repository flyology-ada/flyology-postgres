with Pgish_SQL;
with Psqlish.Display;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_Smoke is
   Query : constant Pgish_SQL.Query := Pgish_SQL.Parse ("SELECT 1");
   pragma Unreferenced (Query);
   State : Psqlish.Display.Result_State;
begin
   Check (not Psqlish.Display.Expanded (State),
          "psqlish display state defaults to non-expanded");
   Check (True, "pgish parser is linked");
   Finish;
end Repro_Examples_Smoke;
