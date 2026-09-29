with Ada.Command_Line;
with Ada.Text_IO;
with Flyology.Postgres.SQL.Repro_Oracle;

package body SQL_Repro_Support is

   package Oracle renames Flyology.Postgres.SQL.Repro_Oracle;

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

   function Native_Error
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String
   is
      Tree : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Native (Text, Version, Tree, Options);
      if SQL.Is_Valid (Tree) then
         return "";
      end if;
      return SQL.Message (SQL.Error (Tree));
   end Native_Error;

   function Native_Error_Position
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return Natural
   is
      Tree : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Native (Text, Version, Tree, Options);
      if SQL.Is_Valid (Tree) then
         return 0;
      end if;
      return SQL.Cursor_Position (SQL.Error (Tree));
   end Native_Error_Position;

   function Oracle_Error
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String
   is
      Tree : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Oracle (Text, Version, Tree, Options);
      if SQL.Is_Valid (Tree) then
         return "";
      end if;
      return SQL.Message (SQL.Error (Tree));
   end Oracle_Error;

   function Oracle_Error_Position
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return Natural
   is
      Tree : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Oracle (Text, Version, Tree, Options);
      if SQL.Is_Valid (Tree) then
         return 0;
      end if;
      return SQL.Cursor_Position (SQL.Error (Tree));
   end Oracle_Error_Position;

   function Oracle_Difference
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String
   is
      Native_Tree : SQL.Syntax_Tree;
      C_Tree      : SQL.Syntax_Tree;
   begin
      Oracle.Parse_Native (Text, Version, Native_Tree, Options);
      Oracle.Parse_Oracle (Text, Version, C_Tree, Options);
      return Oracle.First_Difference (Native_Tree, C_Tree);
   end Oracle_Difference;

end SQL_Repro_Support;
