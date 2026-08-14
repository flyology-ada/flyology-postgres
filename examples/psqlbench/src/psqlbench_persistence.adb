with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Strings; use Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Psqlbench_Docker;
with Psqlbench_JSON;

package body Psqlbench_Persistence is

   protected File_Guard is
      entry Acquire;
      procedure Release;
   private
      Held : Boolean := False;
   end File_Guard;

   protected body File_Guard is
      entry Acquire when not Held is
      begin
         Held := True;
      end Acquire;

      procedure Release is
      begin
         Held := False;
      end Release;
   end File_Guard;

   function State_Path return String is
     (Ada.Environment_Variables.Value
        ("PSQLBENCH_STATE_FILE", "psqlbench-state.jsonl"));

   function Text
     (Value : String; Length : Natural) return String is
     (if Length = 0 then ""
      else Value (Value'First .. Value'First + Length - 1));

   function Mode_Image (Value : Psqlbench_Context.Link_Mode) return String is
     (case Value is
         when Psqlbench_Context.Logical_Committed => "logical-committed",
         when Psqlbench_Context.Logical_Streaming => "logical-streaming",
         when Psqlbench_Context.Logical_Two_Phase => "logical-two-phase",
         when Psqlbench_Context.Logical_Two_Phase_Streaming =>
           "logical-two-phase-streaming",
         when Psqlbench_Context.Physical_Streaming => "physical-streaming");

   function Parse_Mode (Value : String) return Psqlbench_Context.Link_Mode is
   begin
      if Value = "logical-committed" then
         return Psqlbench_Context.Logical_Committed;
      elsif Value = "logical-streaming" then
         return Psqlbench_Context.Logical_Streaming;
      elsif Value = "logical-two-phase" then
         return Psqlbench_Context.Logical_Two_Phase;
      elsif Value = "logical-two-phase-streaming" then
         return Psqlbench_Context.Logical_Two_Phase_Streaming;
      elsif Value = "physical-streaming" then
         return Psqlbench_Context.Physical_Streaming;
      end if;
      raise Constraint_Error with "unknown persisted link mode: " & Value;
   end Parse_Mode;

   function Format_Document return String is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "kind", "psqlbench-state");
      Psqlbench_JSON.Integer_Value (Document, "version", 1);
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Format_Document;

   function Instance_Document
     (Item : Psqlbench_Context.Instance_Record) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "kind", "instance");
      Psqlbench_JSON.String_Value
        (Document, "name", Text (Item.Name, Item.Name_Length));
      Psqlbench_JSON.String_Value
        (Document, "version", Text (Item.Version, Item.Version_Length));
      Psqlbench_JSON.Integer_Value
        (Document, "port", Long_Long_Integer (Item.Port));
      Psqlbench_JSON.Boolean_Value
        (Document, "running", Item.Desired_Running);
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Instance_Document;

   function Link_Document
     (Item : Psqlbench_Context.Link_Record) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "kind", "link");
      Psqlbench_JSON.String_Value
        (Document, "name", Text (Item.Name, Item.Name_Length));
      Psqlbench_JSON.String_Value
        (Document, "source", Text (Item.Source, Item.Source_Length));
      Psqlbench_JSON.String_Value
        (Document, "target", Text (Item.Target, Item.Target_Length));
      Psqlbench_JSON.String_Value (Document, "mode", Mode_Image (Item.Mode));
      Psqlbench_JSON.String_Value
        (Document, "source_schema",
         Text (Item.Source_Schema, Item.Source_Schema_Length));
      Psqlbench_JSON.String_Value
        (Document, "source_table",
         Text (Item.Source_Table, Item.Source_Table_Length));
      Psqlbench_JSON.String_Value
        (Document, "target_schema",
         Text (Item.Target_Schema, Item.Target_Schema_Length));
      Psqlbench_JSON.String_Value
        (Document, "target_table",
         Text (Item.Target_Table, Item.Target_Table_Length));
      Psqlbench_JSON.String_Value
        (Document, "column_map",
         Text (Item.Column_Map, Item.Column_Map_Length));
      Psqlbench_JSON.String_Value
        (Document, "target_version",
         Text (Item.Target_Version, Item.Target_Version_Length));
      Psqlbench_JSON.Integer_Value
        (Document, "target_port", Long_Long_Integer (Item.Target_Port));
      Psqlbench_JSON.Boolean_Value
        (Document, "running", Item.Desired_Running);
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Link_Document;

   procedure Write_State (Context : in out Psqlbench_Context.Context) is
      Path : constant String := State_Path;
      Temporary : constant String := Path & ".tmp";
      Previous : constant String := Path & ".previous";
      Output : Ada.Text_IO.File_Type;
      Instances : Psqlbench_Context.Instance_Array;
      Instance_Count : Natural;
      Links : Psqlbench_Context.Link_Array;
      Link_Count : Natural;
   begin
      Context.Instances.Snapshot (Instances, Instance_Count);
      Context.Links.Snapshot (Links, Link_Count);
      Ada.Text_IO.Create (Output, Ada.Text_IO.Out_File, Temporary);
      Ada.Text_IO.Put_Line (Output, Format_Document);
      for Index in 1 .. Instance_Count loop
         Ada.Text_IO.Put_Line (Output, Instance_Document (Instances (Index)));
      end loop;
      for Index in 1 .. Link_Count loop
         Ada.Text_IO.Put_Line (Output, Link_Document (Links (Index)));
      end loop;
      Ada.Text_IO.Close (Output);

      if Ada.Directories.Exists (Previous) then
         Ada.Directories.Delete_File (Previous);
      end if;
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Rename (Path, Previous);
      end if;
      begin
         Ada.Directories.Rename (Temporary, Path);
      exception
         when others =>
            if Ada.Directories.Exists (Previous)
              and then not Ada.Directories.Exists (Path)
            then
               Ada.Directories.Rename (Previous, Path);
            end if;
            raise;
      end;
      if Ada.Directories.Exists (Previous) then
         Ada.Directories.Delete_File (Previous);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Output) then
            Ada.Text_IO.Close (Output);
         end if;
         raise;
   end Write_State;

   procedure Save (Context : in out Psqlbench_Context.Context) is
   begin
      File_Guard.Acquire;
      begin
         Write_State (Context);
         File_Guard.Release;
      exception
         when others =>
            File_Guard.Release;
            raise;
      end;
   end Save;

   procedure Require_Instance
     (Context  : in out Psqlbench_Context.Context;
      Document : String;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time)
   is
      Name : constant String := Psqlbench_JSON.String_Field (Document, "name");
      Version : constant String :=
        Psqlbench_JSON.String_Field (Document, "version");
      Port : constant Natural :=
        Psqlbench_JSON.Natural_Field (Document, "port", 0);
      Running : constant Boolean :=
        Psqlbench_JSON.Boolean_Field (Document, "running", True);
      Accepted : Boolean;
      Existing : constant Psqlbench_Docker.Result :=
        Psqlbench_Docker.Inspect_Instance (Name, Token, Deadline);
   begin
      if not Psqlbench_JSON.Valid_Name (Name)
        or else not Psqlbench_JSON.Valid_Version (Version)
        or else Port not in 1_024 .. 65_535
      then
         raise Constraint_Error with "invalid persisted instance";
      end if;
      Context.Instances.Upsert (Name, Version, Port, Running, Accepted);
      if not Accepted then
         raise Program_Error with "persisted instance capacity is full";
      end if;

      if Existing.Success then
         declare
            Actual_Version : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Instance_Version (Name, Token, Deadline);
            Actual_Port : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Instance_Port (Name, Token, Deadline);
         begin
            if not Actual_Version.Success or else not Actual_Port.Success
              or else Ada.Strings.Fixed.Trim
                (Psqlbench_Docker.Text (Actual_Version), Both) /= Version
              or else Natural'Value
                (Ada.Strings.Fixed.Trim
                   (Psqlbench_Docker.Text (Actual_Port), Both)) /= Port
            then
               raise Program_Error with
                 "existing instance " & Name
                 & " does not match its persisted version and port";
            end if;
         end;
      else
         declare
            Created : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Create_Instance
                (Name, Version, Positive (Port), Token, Deadline);
         begin
            if not Created.Success then
               raise Program_Error with
                 "cannot restore instance " & Name & ": "
                 & Psqlbench_Docker.Text (Created);
            end if;
         end;
      end if;

      declare
         Action : constant Psqlbench_Docker.Instance_Action :=
           (if Running then Psqlbench_Docker.Start_Instance
            else Psqlbench_Docker.Stop_Instance);
         Applied : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Apply (Name, Action, Token, Deadline);
      begin
         if not Applied.Success then
            raise Program_Error with
              "cannot reconcile instance " & Name & ": "
              & Psqlbench_Docker.Text (Applied);
         end if;
      end;
   end Require_Instance;

   procedure Restore_Link
     (Context : in out Psqlbench_Context.Context; Document : String)
   is
      use type Psqlbench_Context.Link_Mode;
      Name : constant String := Psqlbench_JSON.String_Field (Document, "name");
      Source : constant String :=
        Psqlbench_JSON.String_Field (Document, "source");
      Target : constant String :=
        Psqlbench_JSON.String_Field (Document, "target");
      Mode : constant Psqlbench_Context.Link_Mode :=
        Parse_Mode (Psqlbench_JSON.String_Field (Document, "mode"));
      Source_Schema : constant String :=
        Psqlbench_JSON.String_Field (Document, "source_schema");
      Source_Table : constant String :=
        Psqlbench_JSON.String_Field (Document, "source_table");
      Target_Schema : constant String :=
        Psqlbench_JSON.String_Field (Document, "target_schema");
      Target_Table : constant String :=
        Psqlbench_JSON.String_Field (Document, "target_table");
      Column_Map : constant String :=
        Psqlbench_JSON.String_Field (Document, "column_map");
      Target_Version : constant String :=
        Psqlbench_JSON.String_Field (Document, "target_version");
      Target_Port : constant Natural :=
        Psqlbench_JSON.Natural_Field (Document, "target_port", 0);
      Running : constant Boolean :=
        Psqlbench_JSON.Boolean_Field (Document, "running", True);
      Accepted : Boolean;
      Detail : String (1 .. Psqlbench_Context.Max_Link_Detail_Bytes);
      Last : Natural;
      Existing_Links : Psqlbench_Context.Link_Array;
      Existing_Count : Natural;
   begin
      if not Psqlbench_JSON.Valid_Name (Name)
        or else Name'Length > Psqlbench_Context.Max_Link_Name_Bytes
        or else not Psqlbench_JSON.Valid_Name (Source)
        or else not Psqlbench_JSON.Valid_Name (Target)
      then
         raise Constraint_Error with "invalid persisted link";
      end if;
      Context.Links.Snapshot (Existing_Links, Existing_Count);
      for Index in 1 .. Existing_Count loop
         declare
            Existing : Psqlbench_Context.Link_Record
              renames Existing_Links (Index);
         begin
            if Text (Existing.Name, Existing.Name_Length) = Name then
               if Text (Existing.Source, Existing.Source_Length) /= Source
                 or else Text
                   (Existing.Target, Existing.Target_Length) /= Target
                 or else Existing.Mode /= Mode
                 or else Text
                   (Existing.Source_Schema, Existing.Source_Schema_Length) /=
                     Source_Schema
                 or else Text
                   (Existing.Source_Table, Existing.Source_Table_Length) /=
                     Source_Table
                 or else Text
                   (Existing.Target_Schema, Existing.Target_Schema_Length) /=
                     Target_Schema
                 or else Text
                   (Existing.Target_Table, Existing.Target_Table_Length) /=
                     Target_Table
                 or else Text
                   (Existing.Column_Map, Existing.Column_Map_Length) /=
                     Column_Map
                 or else Text
                   (Existing.Target_Version,
                    Existing.Target_Version_Length) /= Target_Version
                 or else Existing.Target_Port /= Target_Port
               then
                  raise Program_Error with
                    "running link " & Name
                    & " does not match its persisted configuration";
               end if;
               if Existing.Desired_Running /= Running then
                  Context.Links.Request
                    (Name,
                     (if Running
                      then Psqlbench_Context.Create_Link
                      else Psqlbench_Context.Stop_Link),
                     Accepted);
                  if not Accepted then
                     raise Program_Error with
                       "cannot reconcile running state for link " & Name;
                  end if;
               end if;
               return;
            end if;
         end;
      end loop;
      Context.Links.Create
        (Name, Source, Target, Mode,
         Source_Schema, Source_Table, Target_Schema, Target_Table,
         Target_Version, Target_Port, Accepted, Detail, Last,
         Desired_Running => Running, Restoring => True,
         Column_Map => Column_Map);
      if not Accepted then
         raise Program_Error with
           "cannot restore link " & Name & ": "
           & (if Last = 0 then "link capacity is full"
              else Detail (1 .. Last));
      end if;
   end Restore_Link;

   function Reconciled_Document
     (Instances, Links : Natural; Path : String) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value
        (Document, "type", "topology.reconciled");
      Psqlbench_JSON.Integer_Value
        (Document, "instances", Long_Long_Integer (Instances));
      Psqlbench_JSON.Integer_Value
        (Document, "links", Long_Long_Integer (Links));
      Psqlbench_JSON.String_Value (Document, "path", Path);
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Reconciled_Document;

   function Adopt_Existing_Instances
     (Context  : in out Psqlbench_Context.Context;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Natural
   is
      Listed : constant Psqlbench_Docker.Result :=
        Psqlbench_Docker.List_Instance_Names (Token, Deadline);
      Count : Natural := 0;

      procedure Adopt (Raw_Name : String) is
         Name : constant String := Ada.Strings.Fixed.Trim (Raw_Name, Both);
         Version : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Instance_Version (Name, Token, Deadline);
         Port : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Instance_Port (Name, Token, Deadline);
         Role : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Instance_Role (Name, Token, Deadline);
         Running : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Instance_Running (Name, Token, Deadline);
         Accepted : Boolean;
      begin
         if Name'Length = 0
           or else not Version.Success
           or else not Port.Success
           or else not Running.Success
           or else
             (Role.Success
              and then Ada.Strings.Fixed.Trim
                (Psqlbench_Docker.Text (Role), Both) = "physical-standby")
         then
            return;
         end if;
         Context.Instances.Upsert
           (Name,
            Ada.Strings.Fixed.Trim (Psqlbench_Docker.Text (Version), Both),
            Natural'Value
              (Ada.Strings.Fixed.Trim (Psqlbench_Docker.Text (Port), Both)),
            Ada.Strings.Fixed.Trim
              (Psqlbench_Docker.Text (Running), Both) = "true",
            Accepted);
         if not Accepted then
            raise Program_Error with "persisted instance capacity is full";
         end if;
         Count := Count + 1;
      end Adopt;
   begin
      if not Listed.Success then
         raise Program_Error with
           "cannot discover managed instances: "
           & Psqlbench_Docker.Text (Listed);
      end if;
      declare
         Names : constant String := Psqlbench_Docker.Text (Listed);
         First : Positive := Names'First;
      begin
         for Index in Names'Range loop
            if Names (Index) = ASCII.LF then
               if Index > First then
                  Adopt (Names (First .. Index - 1));
               end if;
               First := Index + 1;
            end if;
         end loop;
         if Names'Length > 0 and then First <= Names'Last then
            Adopt (Names (First .. Names'Last));
         end if;
      end;
      return Count;
   end Adopt_Existing_Instances;

   procedure Load_And_Reconcile
     (Context  : in out Psqlbench_Context.Context;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
   is
      Path : constant String := State_Path;
      Temporary : constant String := Path & ".tmp";
      Previous : constant String := Path & ".previous";
      Read_Path : constant String :=
        (if Ada.Directories.Exists (Path) then Path
         elsif Ada.Directories.Exists (Temporary) then Temporary
         elsif Ada.Directories.Exists (Previous) then Previous
         else "");
      Input : Ada.Text_IO.File_Type;
      Instance_Count : Natural := 0;
      Link_Count : Natural := 0;
      Saw_Format : Boolean := False;
   begin
      if Read_Path'Length = 0 then
         Instance_Count :=
           Adopt_Existing_Instances (Context, Token, Deadline);
         Save (Context);
         Context.Events.Append
           (Reconciled_Document (Instance_Count, 0, Path));
         return;
      end if;
      Ada.Text_IO.Open (Input, Ada.Text_IO.In_File, Read_Path);
      while not Ada.Text_IO.End_Of_File (Input) loop
         declare
            Line : constant String := Ada.Text_IO.Get_Line (Input);
            Kind : constant String :=
              (if Line'Length = 0 then ""
               else Psqlbench_JSON.String_Field (Line, "kind"));
         begin
            if Kind = "psqlbench-state" then
               if Psqlbench_JSON.Natural_Field (Line, "version", 0) /= 1 then
                  raise Constraint_Error with
                    "unsupported psqlbench state format";
               end if;
               Saw_Format := True;
            elsif Kind = "instance" then
               Require_Instance (Context, Line, Token, Deadline);
               Instance_Count := Instance_Count + 1;
            elsif Kind = "link" then
               Restore_Link (Context, Line);
               Link_Count := Link_Count + 1;
            elsif Kind'Length > 0 then
               raise Constraint_Error with
                 "unknown psqlbench state record: " & Kind;
            end if;
         end;
      end loop;
      Ada.Text_IO.Close (Input);
      if not Saw_Format then
         raise Constraint_Error with "psqlbench state header is missing";
      end if;
      Context.Events.Append
        (Reconciled_Document (Instance_Count, Link_Count, Path));
      if Read_Path /= Path then
         Save (Context);
      end if;
   exception
      when others =>
         if Ada.Text_IO.Is_Open (Input) then
            Ada.Text_IO.Close (Input);
         end if;
         raise;
   end Load_And_Reconcile;

end Psqlbench_Persistence;
