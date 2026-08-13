with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;

package body Psqlbench_Assets is

   function Root return String is
   begin
      if Ada.Environment_Variables.Exists ("PSQLBENCH_ASSET_ROOT") then
         return Ada.Environment_Variables.Value ("PSQLBENCH_ASSET_ROOT");
      elsif Ada.Directories.Exists ("assets/index.html") then
         return "assets";
      else
         return "examples/psqlbench/assets";
      end if;
   end Root;

   function Read_All (Path : String) return Unbounded_String is
      File   : Ada.Text_IO.File_Type;
      Result : Unbounded_String;
   begin
      Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Path);
      while not Ada.Text_IO.End_Of_File (File) loop
         Append (Result, Ada.Text_IO.Get_Line (File));
         Append (Result, ASCII.LF);
      end loop;
      Ada.Text_IO.Close (File);
      return Result;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (File) then
            Ada.Text_IO.Close (File);
         end if;
         raise;
   end Read_All;

   procedure Load (Item : out Bundle) is
      Directory : constant String := Root;
   begin
      Item.HTML := Read_All (Directory & "/index.html");
      Item.Stylesheet := Read_All (Directory & "/app.css");
      Item.Script := Read_All (Directory & "/app.js");
   end Load;

end Psqlbench_Assets;
