with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Psqlbench_JSON is
   use Ada.Strings.Unbounded;

   function Quote (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
   begin
      for Item of Value loop
         case Item is
            when '"' | Character'Val (92) =>
               Append (Result, Character'Val (92));
               Append (Result, Item);
            when ASCII.BS | ASCII.HT | ASCII.LF | ASCII.FF | ASCII.CR =>
               Append (Result, Character'Val (92));
               Append
                 (Result,
                  (case Item is
                      when ASCII.BS => 'b',
                      when ASCII.HT => 't',
                      when ASCII.LF => 'n',
                      when ASCII.FF => 'f',
                      when ASCII.CR => 'r',
                      when others   => raise Program_Error));
            when others =>
               if Character'Pos (Item) < 32 then
                  Append (Result, '?');
               else
                  Append (Result, Item);
               end if;
         end case;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Quote;

   procedure Skip_Space (Document : String; Cursor : in out Natural) is
   begin
      while Cursor <= Document'Last
        and then Document (Cursor) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF
      loop
         Cursor := Cursor + 1;
      end loop;
   end Skip_Space;

   function Value_Start
     (Document : String;
      Name     : String) return Natural
   is
      Marker : constant String := Quote (Name);
      Cursor : Natural := Ada.Strings.Fixed.Index (Document, Marker);
   begin
      if Cursor = 0 then
         return 0;
      end if;
      Cursor := Cursor + Marker'Length;
      Skip_Space (Document, Cursor);
      if Cursor > Document'Last or else Document (Cursor) /= ':' then
         raise Constraint_Error with "invalid JSON field " & Name;
      end if;
      Cursor := Cursor + 1;
      Skip_Space (Document, Cursor);
      return Cursor;
   end Value_Start;

   function String_Field
     (Document : String;
      Name     : String) return String
   is
      Cursor : Natural := Value_Start (Document, Name);
      Result : Unbounded_String;
   begin
      if Cursor = 0 then
         return "";
      end if;
      if Cursor > Document'Last or else Document (Cursor) /= '"' then
         raise Constraint_Error with "JSON field " & Name & " is not a string";
      end if;
      Cursor := Cursor + 1;
      while Cursor <= Document'Last loop
         case Document (Cursor) is
            when '"' => return To_String (Result);
            when Character'Val (92) =>
               Cursor := Cursor + 1;
               if Cursor > Document'Last then
                  raise Constraint_Error with "unterminated JSON escape";
               end if;
               case Document (Cursor) is
                  when '"' | Character'Val (92) | '/' =>
                     Append (Result, Document (Cursor));
                  when 'b' => Append (Result, ASCII.BS);
                  when 'f' => Append (Result, ASCII.FF);
                  when 'n' => Append (Result, ASCII.LF);
                  when 'r' => Append (Result, ASCII.CR);
                  when 't' => Append (Result, ASCII.HT);
                  when others =>
                     raise Constraint_Error with "unsupported JSON escape";
               end case;
            when others =>
               if Character'Pos (Document (Cursor)) < 32 then
                  raise Constraint_Error with "control byte in JSON string";
               end if;
               Append (Result, Document (Cursor));
         end case;
         Cursor := Cursor + 1;
      end loop;
      raise Constraint_Error with "unterminated JSON string";
   end String_Field;

   function Natural_Field
     (Document : String;
      Name     : String;
      Default  : Natural) return Natural
   is
      First : constant Natural := Value_Start (Document, Name);
      Last  : Natural := First;
   begin
      if First = 0 then
         return Default;
      end if;
      while Last <= Document'Last and then Document (Last) in '0' .. '9' loop
         Last := Last + 1;
      end loop;
      if Last = First then
         raise Constraint_Error with "JSON field " & Name & " is not natural";
      end if;
      return Natural'Value (Document (First .. Last - 1));
   end Natural_Field;

   function Valid_Name (Value : String) return Boolean is
   begin
      if Value'Length not in 1 .. 40
        or else Value (Value'First) not in 'a' .. 'z'
      then
         return False;
      end if;
      for Item of Value loop
         if Item not in 'a' .. 'z' | '0' .. '9' | '-' then
            return False;
         end if;
      end loop;
      return True;
   end Valid_Name;

   function Valid_Version (Value : String) return Boolean is
     (Value in "14.23" | "15.18" | "16.14" | "17.10" | "18.4");

end Psqlbench_JSON;
