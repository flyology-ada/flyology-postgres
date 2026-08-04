with Ada.Environment_Variables;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Interfaces.C_Streams;
with Linenoise;

package body Psqlish.Input is

   History_Limit : constant Linenoise.History_Length := 1_000;

   function Is_Interactive return Boolean is
     (Interfaces.C_Streams.isatty
        (Interfaces.C_Streams.fileno (Interfaces.C_Streams.stdin)) /= 0);

   Interactive : constant Boolean := Is_Interactive;

   function History_Filename return String is
      package Environment renames Ada.Environment_Variables;
   begin
      if Environment.Exists ("PSQLISH_HISTORY") then
         return Environment.Value ("PSQLISH_HISTORY");
      elsif Environment.Exists ("HOME") then
         return Environment.Value ("HOME") & "/.psqlish_history";
      else
         return "";
      end if;
   end History_Filename;

   procedure Initialize is
      Filename : constant String := History_Filename;
   begin
      if not Interactive then
         return;
      end if;

      Linenoise.Multiline_Mode (True);
      Linenoise.History_Set_Maximum_Length (History_Limit);
      if Filename'Length > 0 then
         begin
            Linenoise.History_Load (Filename);
         exception
            when Linenoise.History_File_Error =>
               --  A missing history file is normal on first use.
               null;
         end;
      end if;
   end Initialize;

   function Get_Line (Prompt : String) return String is
      use Ada.Strings;
      use Ada.Strings.Fixed;
      Line : constant String := Linenoise.Get_Line (Prompt);
   begin
      if Interactive and then Trim (Line, Both)'Length > 0 then
         Linenoise.History_Add (Line);
      end if;
      return Line;
   end Get_Line;

   procedure Save_History is
      Filename : constant String := History_Filename;
   begin
      if Interactive and then Filename'Length > 0 then
         begin
            Linenoise.History_Save (Filename);
         exception
            when Linenoise.History_File_Error =>
               Ada.Text_IO.Put_Line
                 (Ada.Text_IO.Standard_Error,
                  "warning: could not save command history to " & Filename);
         end;
      end if;
   end Save_History;

end Psqlish.Input;
