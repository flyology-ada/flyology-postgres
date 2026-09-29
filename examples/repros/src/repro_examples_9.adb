--  EXAMPLES-9: expanded (\x on) output must align every field name to one
--  common width.  Psqlish.Display computes Widths (Index) as the per-column
--  maximum of the header and all values for the tabular layout, then reuses it
--  in the expanded renderer:
--     Line (Name & Spaces (Widths (Index) - Name'Length) & " | " & Value);
--  In expanded mode each field is its own line, so the "|" separators must be
--  aligned on the widest NAME.  psql renders
--     n     | 7
--     value | alpha
--  while psqlish renders "n | 7" and pushes the separator of a short name with
--  a wide value far to the right.

with Ada.Strings.Fixed;
with Psqlish.Display;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_9 is
   package Display renames Psqlish.Display;

   function Separator_Column (Text : String; Line_Number : Positive)
     return Natural
   is
      First : Positive := Text'First;
      Seen  : Natural := 0;
   begin
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Seen := Seen + 1;
            if Seen = Line_Number then
               declare
                  Line : constant String := Text (First .. Index - 1);
                  Bar  : constant Natural :=
                    Ada.Strings.Fixed.Index (Line, "|");
               begin
                  return (if Bar = 0 then 0 else Bar - Line'First + 1);
               end;
            end if;
            First := Index + 1;
         end if;
      end loop;
      return 0;
   end Separator_Column;

   function Nth_Line (Text : String; Line_Number : Positive) return String is
      First : Positive := Text'First;
      Seen  : Natural := 0;
   begin
      for Index in Text'Range loop
         if Text (Index) = ASCII.LF then
            Seen := Seen + 1;
            if Seen = Line_Number then
               return Text (First .. Index - 1);
            end if;
            First := Index + 1;
         end if;
      end loop;
      return "";
   end Nth_Line;

   View : Display.Result_State;
begin
   Display.Set_Expanded (View, True);
   Display.Begin_Result
     (View,
      (Display.Make_Column ("n"), Display.Make_Column ("value")));
   Display.Add_Row
     (View, (Display.Text_Cell ("7"), Display.Text_Cell ("alpha")));
   declare
      Output : constant String := Display.Finish_Result (View, "SELECT 1");
      Name_Line  : constant String := Nth_Line (Output, 2);
      Value_Line : constant String := Nth_Line (Output, 3);
      Name_Bar   : constant Natural := Separator_Column (Output, 2);
      Value_Bar  : constant Natural := Separator_Column (Output, 3);
   begin
      Note ("line 2: """ & Name_Line & """");
      Note ("line 3: """ & Value_Line & """");
      Check (Name_Bar > 0 and then Value_Bar > 0,
             "both expanded field lines carry a separator");
      Check (Name_Bar = Value_Bar,
             "the expanded separators align (n at" & Name_Bar'Image
             & ", value at" & Value_Bar'Image & ")");
      Check (Name_Line = "n     | 7",
             "psql renders the short name padded to the widest name");
   end;
   Finish;
end Repro_Examples_9;
