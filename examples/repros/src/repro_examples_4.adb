--  EXAMPLES-4: a zero-column result must not raise Constraint_Error in the
--  psqlish client.  psqlish_main.adb:234 and :262 narrow the library's
--  Natural-valued Protocol.Field_Count / Protocol.Column_Count to Positive:
--
--     Count : constant Positive := Protocol.Field_Count (Description);
--     Count : constant Positive := Protocol.Column_Count (Row);
--
--  A RowDescription with zero fields is legal on the wire (PostgreSQL accepts
--  "SELECT;" and psql prints "--" / "(1 row)"), so the range check fails,
--  Execute_Query propagates, Run closes the socket without Terminate and
--  re-raises, and the process exits with an unhandled-exception report.
--
--  This program builds exactly those two wire messages, decodes them with the
--  library, and then evaluates the two narrowing declarations copied from
--  psqlish_main.adb.  It also shows Psqlish.Display accepts an empty
--  Column_Array, so the defect is only the narrowing in the client main.

with Ada.Exceptions;
with Flyology.Postgres.Protocol;
with Psqlish.Display;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_4 is
   package Protocol renames Flyology.Postgres.Protocol;
   package Display renames Psqlish.Display;
   use type Protocol.Backend_Message_Kind;

   --  RowDescription payload: Int16 field count = 0.
   Zero_Fields : constant Protocol.Byte_Array := (0, 0);
   --  DataRow payload: Int16 column count = 0.
   Zero_Columns : constant Protocol.Byte_Array := (0, 0);

   Row_Event : constant Protocol.Backend_Message :=
     Protocol.Decode_Backend (Protocol.Make_Message ('T', Zero_Fields));
   Data_Event : constant Protocol.Backend_Message :=
     Protocol.Decode_Backend (Protocol.Make_Message ('D', Zero_Columns));

   Description : constant Protocol.Row_Description :=
     Protocol.Description (Row_Event);
   Row : constant Protocol.Data_Row := Protocol.Row_Data (Data_Event);

   Description_Failed : Boolean := False;
   Row_Failed         : Boolean := False;
   Display_Failed     : Boolean := False;
begin
   Check (Protocol.Response_Kind (Row_Event) =
            Protocol.Row_Description_Response,
          "a zero-field RowDescription decodes as RowDescription");
   Check (Protocol.Field_Count (Description) = 0,
          "the library reports Field_Count = 0 (Natural, not Positive)");
   Check (Protocol.Column_Count (Row) = 0,
          "the library reports Column_Count = 0 (Natural, not Positive)");

   --  psqlish_main.adb:234-235
   begin
      declare
         Count   : constant Positive := Protocol.Field_Count (Description);
         Columns : Display.Column_Array (1 .. Count) :=
           (others => Display.Make_Column ("x"));
      begin
         Columns (1) := Display.Make_Column ("y");
      end;
   exception
      when Error : others =>
         Description_Failed := True;
         Note ("psqlish_main.adb:234 raised "
               & Ada.Exceptions.Exception_Name (Error) & " : "
               & Ada.Exceptions.Exception_Message (Error));
   end;
   Check (not Description_Failed,
          "psqlish accepts a zero-field RowDescription");

   --  psqlish_main.adb:262-263
   begin
      declare
         Count  : constant Positive := Protocol.Column_Count (Row);
         Values : Display.Cell_Array (1 .. Count) :=
           (others => Display.Null_Cell);
      begin
         Values (1) := Display.Null_Cell;
      end;
   exception
      when Error : others =>
         Row_Failed := True;
         Note ("psqlish_main.adb:262 raised "
               & Ada.Exceptions.Exception_Name (Error) & " : "
               & Ada.Exceptions.Exception_Message (Error));
   end;
   Check (not Row_Failed, "psqlish accepts a zero-column DataRow");

   --  The display layer itself already copes with an empty result shape.
   begin
      declare
         View  : Display.Result_State;
         Empty : constant Display.Column_Array (1 .. 0) :=
           (others => Display.Make_Column ("x"));
         None  : constant Display.Cell_Array (1 .. 0) :=
           (others => Display.Null_Cell);
      begin
         Display.Begin_Result (View, Empty);
         Display.Add_Row (View, None);
         Note ("Display renders a zero-column result as: """
               & Display.Finish_Result (View, "SELECT 1") & """");
      end;
   exception
      when Error : others =>
         Display_Failed := True;
         Note ("Psqlish.Display raised "
               & Ada.Exceptions.Exception_Name (Error));
   end;
   Check (not Display_Failed,
          "Psqlish.Display already accepts an empty Column_Array");
   Finish;
end Repro_Examples_4;
