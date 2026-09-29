--  EXAMPLES-3: ORDER BY on an integer column must order numerically.
--  Pgish_Catalog.Sort.Before always compares SQL.Image (String) values, while
--  Pgish_Catalog.Matches compares both-numeric operands as Long_Long_Integer,
--  so WHERE and ORDER BY disagree for int4/int8 columns.

with Ada.Calendar;
with Ada.Directories;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_3 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   function Cell_Text (Row : Positive) return String is
     (SQL.Image (Result.Rows (Row).Values (1).Value));

   function Listing return String is
      Text : String (1 .. 256) := (others => ' ');
      Last : Natural := 0;
      procedure Put (Value : String) is
      begin
         if Last + Value'Length <= Text'Last then
            Text (Last + 1 .. Last + Value'Length) := Value;
            Last := Last + Value'Length;
         end if;
      end Put;
   begin
      for Row in 1 .. Result.Row_Count loop
         if Row > 1 then
            Put (",");
         end if;
         Put (Cell_Text (Row));
      end loop;
      return Text (1 .. Last);
   end Listing;
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

   --  information_schema.columns exposes ordinal_position as int4 (OID 23).
   --  flyology_runtime_groups has 16 columns, so positions 1 .. 16 are sorted.
   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT ordinal_position FROM information_schema.columns " &
         "WHERE table_name = 'flyology_runtime_groups' " &
         "ORDER BY ordinal_position"),
      Result);
   Note ("ascending order: " & Listing);
   Check (Result.Row_Count = 16,
          "flyology_runtime_groups reports 16 columns (got"
          & Result.Row_Count'Image & ")");
   Check (Result.Row_Count = 16 and then Cell_Text (2) = "2",
          "ascending ORDER BY places 2 second, not 10");
   Check (Result.Row_Count = 16 and then Cell_Text (16) = "16",
          "ascending ORDER BY places 16 last, not 9");

   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT ordinal_position FROM information_schema.columns " &
         "WHERE table_name = 'flyology_runtime_groups' " &
         "ORDER BY ordinal_position DESC"),
      Result);
   Note ("descending order: " & Listing);
   Check (Result.Row_Count = 16 and then Cell_Text (1) = "16",
          "descending ORDER BY places 16 first, not 9");

   --  WHERE compares the same column numerically, so the two disagree.
   Catalog.Execute
     (Context, Session,
      SQL.Parse
        ("SELECT ordinal_position FROM information_schema.columns " &
         "WHERE table_name = 'flyology_runtime_groups' " &
         "AND ordinal_position > 9"),
      Result);
   Check (Result.Row_Count = 7,
          "WHERE ordinal_position > 9 is numeric and yields 7 rows (got"
          & Result.Row_Count'Image & ")");
   Finish;
end Repro_Examples_3;
