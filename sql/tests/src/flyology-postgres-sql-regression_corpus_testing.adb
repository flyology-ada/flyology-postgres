with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.IO_Exceptions;
with Ada.Strings.Fixed;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Text_IO;
with AUnit.Assertions; use AUnit.Assertions;
with Interfaces;

with Flyology.Postgres.SQL.AST.V14;
with Flyology.Postgres.SQL.AST.V14.Testing;
with Flyology.Postgres.SQL.AST.V15;
with Flyology.Postgres.SQL.AST.V15.Testing;
with Flyology.Postgres.SQL.AST.V16;
with Flyology.Postgres.SQL.AST.V16.Testing;
with Flyology.Postgres.SQL.AST.V17;
with Flyology.Postgres.SQL.AST.V17.Testing;
with Flyology.Postgres.SQL.AST.V18;
with Flyology.Postgres.SQL.AST.V18.Testing;
with Flyology.Postgres.SQL.C_Oracle;
with Flyology.Postgres.SQL.Internals;

package body Flyology.Postgres.SQL.Regression_Corpus_Testing is

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;
   use type Interfaces.Integer_64;

   package AST_14 renames Flyology.Postgres.SQL.AST.V14;
   package AST_15 renames Flyology.Postgres.SQL.AST.V15;
   package AST_16 renames Flyology.Postgres.SQL.AST.V16;
   package AST_17 renames Flyology.Postgres.SQL.AST.V17;
   package AST_18 renames Flyology.Postgres.SQL.AST.V18;
   package Test_14 renames Flyology.Postgres.SQL.AST.V14.Testing;
   package Test_15 renames Flyology.Postgres.SQL.AST.V15.Testing;
   package Test_16 renames Flyology.Postgres.SQL.AST.V16.Testing;
   package Test_17 renames Flyology.Postgres.SQL.AST.V17.Testing;
   package Test_18 renames Flyology.Postgres.SQL.AST.V18.Testing;

   type Statistics is record
      Files      : Natural := 0;
      Accepted   : Natural := 0;
      Fallback   : Natural := 0;
      Statements : Natural := 0;
      Bytes      : Natural := 0;
      Rejected   : Natural := 0;
      Failures   : Natural := 0;
   end record;

   function Image (Value : Natural) return String is
      Raw : constant String := Value'Image;
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   function Version_Image (Version : Major_Version) return String is
     (case Version is
         when PostgreSQL_14 => "14",
         when PostgreSQL_15 => "15",
         when PostgreSQL_16 => "16",
         when PostgreSQL_17 => "17",
         when PostgreSQL_18 => "18");

   function Signed_Field
     (Tree : Syntax_Tree; Item : Value_Id; Name : String)
      return Interfaces.Integer_64 is
     (if Internals.Has_Field (Tree, Item, Name)
      then Internals.Signed_Data (Tree, Internals.Field (Tree, Item, Name))
      else 0);

   function Read_File (Path : String) return String is
      package Stream_IO renames Ada.Streams.Stream_IO;
      File : Stream_IO.File_Type;
   begin
      Stream_IO.Open (File, Stream_IO.In_File, Path);
      declare
         Length : constant Stream_IO.Count := Stream_IO.Size (File);
      begin
         if Length = 0 then
            Stream_IO.Close (File);
            return "";
         end if;
         declare
            Data : Ada.Streams.Stream_Element_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Length));
            Last : Ada.Streams.Stream_Element_Offset;
            Text : String (1 .. Natural (Length));
         begin
            Stream_IO.Read (File, Data, Last);
            Stream_IO.Close (File);
            if Last /= Data'Last then
               raise Ada.IO_Exceptions.End_Error with "short read from " & Path;
            end if;
            for Index in Data'Range loop
               Text (Natural (Index)) := Character'Val (Data (Index));
            end loop;
            return Text;
         exception
            when others =>
               if Stream_IO.Is_Open (File) then
                  Stream_IO.Close (File);
               end if;
               raise;
         end;
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         raise;
   end Read_File;

   procedure Compare_Owned
     (Text : String; Version : Major_Version; Label : String) is
   begin
      case Version is
         when PostgreSQL_14 =>
            declare
               Baseline, Direct : AST_14.Owned_Syntax_Tree;
            begin
               Test_14.Parse_Baseline (Text, Baseline);
               AST_14.Parse (Text, Direct);
               if not Test_14.Equivalent (Baseline, Direct) then
                  raise Program_Error with "owned AST differs for " & Label;
               end if;
            end;
         when PostgreSQL_15 =>
            declare
               Baseline, Direct : AST_15.Owned_Syntax_Tree;
            begin
               Test_15.Parse_Baseline (Text, Baseline);
               AST_15.Parse (Text, Direct);
               if not Test_15.Equivalent (Baseline, Direct) then
                  raise Program_Error with "owned AST differs for " & Label;
               end if;
            end;
         when PostgreSQL_16 =>
            declare
               Baseline, Direct : AST_16.Owned_Syntax_Tree;
            begin
               Test_16.Parse_Baseline (Text, Baseline);
               AST_16.Parse (Text, Direct);
               if not Test_16.Equivalent (Baseline, Direct) then
                  raise Program_Error with "owned AST differs for " & Label;
               end if;
            end;
         when PostgreSQL_17 =>
            declare
               Baseline, Direct : AST_17.Owned_Syntax_Tree;
            begin
               Test_17.Parse_Baseline (Text, Baseline);
               AST_17.Parse (Text, Direct);
               if not Test_17.Equivalent (Baseline, Direct) then
                  raise Program_Error with "owned AST differs for " & Label;
               end if;
            end;
         when PostgreSQL_18 =>
            declare
               Baseline, Direct : AST_18.Owned_Syntax_Tree;
            begin
               Test_18.Parse_Baseline (Text, Baseline);
               AST_18.Parse (Text, Direct);
               if not Test_18.Equivalent (Baseline, Direct) then
                  raise Program_Error with "owned AST differs for " & Label;
               end if;
            end;
      end case;
   end Compare_Owned;

   procedure Check_Statement
     (Text    : String;
      Label   : String;
      Version : Major_Version;
      Totals  : in out Statistics)
   is
      C_Tree      : Syntax_Tree;
      Native_Tree : Syntax_Tree;
   begin
      C_Oracle.Parse (Text, Version, C_Tree);
      if not Is_Valid (C_Tree) then
         raise Program_Error with "isolated oracle statement is invalid";
      end if;
      Totals.Bytes := Totals.Bytes + Text'Length;
      Parse (Text, Version, Native_Tree);
      declare
         Difference : constant String :=
           Internals.First_Difference (Native_Tree, C_Tree);
      begin
         if Difference'Length /= 0 then
            raise Program_Error with
              "native arena differs for " & Label & ": " & Difference &
              (if not Is_Valid (Native_Tree)
               then " (native diagnostic: " & Message (Error (Native_Tree)) & ")"
               else "");
         end if;
      end;
      Compare_Owned (Text, Version, Label);
   exception
      when Error : others =>
         Totals.Failures := Totals.Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "  FAIL PostgreSQL " & Version_Image (Version) & " " & Label &
            ": " & Ada.Exceptions.Exception_Information (Error));
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error, "    SQL: " & Text);
   end Check_Statement;

   function Statement_Count (Tree : Syntax_Tree) return Natural is
      Root : constant Value_Id := Internals.Root (Tree);
   begin
      if not Is_Valid (Tree) or else not Internals.Has_Field (Tree, Root, "stmts") then
         return 0;
      end if;
      return Internals.Length
        (Tree,
         Internals.To_Sequence
           (Tree, Internals.Field (Tree, Root, "stmts")));
   end Statement_Count;

   procedure Check_Fallback_File
     (Directory : String;
      Name      : String;
      Version   : Major_Version;
      Totals    : in out Statistics)
   is
      Statement_Directory : constant String :=
        Ada.Directories.Compose (Directory, "statements");
      Bundle : constant String := Read_File
        (Ada.Directories.Compose (Statement_Directory, Name));
      Spans : Ada.Text_IO.File_Type;
      Index : Natural := 0;
   begin
      Ada.Text_IO.Open
        (Spans, Ada.Text_IO.In_File,
         Ada.Directories.Compose (Statement_Directory, Name & ".spans"));
      while not Ada.Text_IO.End_Of_File (Spans) loop
         declare
            Line      : constant String := Ada.Text_IO.Get_Line (Spans);
            Separator : constant Natural := Ada.Strings.Fixed.Index (Line, " ");
            Offset    : constant Natural :=
              Natural'Value (Line (Line'First .. Separator - 1));
            Length    : constant Natural :=
              Natural'Value (Line (Separator + 1 .. Line'Last));
            Text      : constant String :=
              Bundle (Bundle'First + Offset .. Bundle'First + Offset + Length - 1);
            C_Tree    : Syntax_Tree;
            Count     : Natural;
         begin
            Index := Index + 1;
            C_Oracle.Parse (Text, Version, C_Tree);
            Count := Statement_Count (C_Tree);
            if Count = 0 then
               Totals.Rejected := Totals.Rejected + 1;
            else
               Totals.Statements := Totals.Statements + Count;
               Check_Statement
                 (Text, Name & "~" & Image (Index), Version, Totals);
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (Spans);
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Spans) then
            Ada.Text_IO.Close (Spans);
         end if;
         raise;
   end Check_Fallback_File;

   procedure Check_File
     (Path    : String;
      Name    : String;
      Version : Major_Version;
      Totals  : in out Statistics)
   is
      Text   : constant String := Read_File (Path);
      C_Tree : Syntax_Tree;
   begin
      Totals.Files := Totals.Files + 1;
      C_Oracle.Parse (Text, Version, C_Tree);
      if not Is_Valid (C_Tree) then
         Totals.Fallback := Totals.Fallback + 1;
         Check_Fallback_File
           (Ada.Directories.Containing_Directory (Path), Name, Version, Totals);
         return;
      end if;

      Totals.Accepted := Totals.Accepted + 1;
      declare
         Root       : constant Value_Id := Internals.Root (C_Tree);
         Statements : constant Internals.Sequence_Id :=
           Internals.To_Sequence (C_Tree, Internals.Field (C_Tree, Root, "stmts"));
         Count      : constant Natural := Internals.Length (C_Tree, Statements);
      begin
         Totals.Statements := Totals.Statements + Count;
         for Index in 1 .. Count loop
            declare
               Raw      : constant Value_Id :=
                 Internals.Element (C_Tree, Statements, Index);
               Location : constant Interfaces.Integer_64 :=
                 Signed_Field (C_Tree, Raw, "stmt_location");
               Length   : constant Interfaces.Integer_64 :=
                 Signed_Field (C_Tree, Raw, "stmt_len");
               First    : constant Positive := Positive (Location + 1);
               Last     : constant Natural :=
                 (if Length > 0
                  then Natural (Location + Length)
                  elsif Index < Count
                  then Natural
                    (Signed_Field
                       (C_Tree,
                        Internals.Element (C_Tree, Statements, Index + 1),
                        "stmt_location"))
                  else Text'Last);
            begin
               Check_Statement
                 (Text (First .. Last),
                  Name & "#" & Image (Index), Version, Totals);
            end;
         end loop;
      end;
   exception
      when Error : others =>
         Totals.Failures := Totals.Failures + 1;
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "  FAIL PostgreSQL " & Version_Image (Version) & " " & Name &
            " corpus extraction: " & Ada.Exceptions.Exception_Information (Error));
   end Check_File;

   procedure Run_Version
     (Root : String; Version : Major_Version; Failures : out Natural) is
      Directory : constant String :=
        Ada.Directories.Compose (Root, "v" & Version_Image (Version));
      List_Path : constant String :=
        Ada.Directories.Compose (Directory, "files.txt");
      List      : Ada.Text_IO.File_Type;
      Totals    : Statistics;
   begin
      Assert
        (Ada.Directories.Exists (List_Path),
         "PostgreSQL regression corpus is missing " & List_Path);
      Ada.Text_IO.Open (List, Ada.Text_IO.In_File, List_Path);
      while not Ada.Text_IO.End_Of_File (List) loop
         declare
            Name : constant String := Ada.Text_IO.Get_Line (List);
         begin
            if Name'Length > 0 then
               Check_File
                 (Ada.Directories.Compose (Directory, Name), Name, Version, Totals);
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (List);

      Ada.Text_IO.Put_Line
        ("  PostgreSQL " & Version_Image (Version) & ": " &
         Image (Totals.Accepted) & "/" & Image (Totals.Files) &
         " whole files accepted, " & Image (Totals.Fallback) &
         " files lexically recovered; " & Image (Totals.Statements) &
         " statements and " & Image (Totals.Bytes) & " bytes compared; " &
         Image (Totals.Rejected) & " oracle-rejected fragments, " &
         Image (Totals.Failures) & " failures");
      Assert
        (Totals.Accepted + Totals.Fallback = Totals.Files
         and then Totals.Statements > 0,
         "PostgreSQL " & Version_Image (Version) &
         " regression corpus did not exercise every file");
      Failures := Totals.Failures;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (List) then
            Ada.Text_IO.Close (List);
         end if;
         raise;
   end Run_Version;

   procedure Run is
      Root : constant String := Ada.Environment_Variables.Value
        ("FLYOLOGY_POSTGRES_REGRESSION_CORPUS",
         ".cache/postgres-regress/corpus");
      Selected : constant String := Ada.Environment_Variables.Value
        ("FLYOLOGY_POSTGRES_REGRESSION_MAJOR", "");
      Failures : Natural := 0;
   begin
      Ada.Text_IO.Put_Line
        ("Test_PostgreSQL_Regression_Corpus (every regression file)");
      for Version in Major_Version loop
         if Selected'Length = 0 or else Selected = Version_Image (Version) then
            declare
               Version_Failures : Natural;
            begin
               Run_Version (Root, Version, Version_Failures);
               Failures := Failures + Version_Failures;
            end;
         end if;
      end loop;
      Assert
        (Failures = 0,
         "PostgreSQL regression corpus has " & Image (Failures) & " failures");
   end Run;

end Flyology.Postgres.SQL.Regression_Corpus_Testing;
