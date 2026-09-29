with Ada.Command_Line;
with Ada.Text_IO;

package body Example_Repro_Support is

   Failures : Natural := 0;

   procedure Check (Condition : Boolean; Description : String) is
   begin
      if Condition then
         Ada.Text_IO.Put_Line ("  ok: " & Description);
      else
         Failures := Failures + 1;
         Ada.Text_IO.Put_Line ("  FAILED: " & Description);
      end if;
   end Check;

   procedure Note (Text : String) is
   begin
      Ada.Text_IO.Put_Line ("  -- " & Text);
   end Note;

   procedure Finish is
   begin
      if Failures = 0 then
         Ada.Text_IO.Put_Line ("PASS");
         Ada.Command_Line.Set_Exit_Status (0);
      else
         Ada.Text_IO.Put_Line
           ("BUG REPRODUCED:" & Failures'Image & " failed expectation(s)");
         Ada.Command_Line.Set_Exit_Status (1);
      end if;
   end Finish;

end Example_Repro_Support;
