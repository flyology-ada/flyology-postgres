with Ada.Directories;
with Ada.Text_IO;
with GNAT.OS_Lib;

package body Introspection_State is

   use type Ada.Task_Identification.Task_Id;

   function Clipped_Name (Value : String) return Name_Text is
      Last : constant Natural := Natural'Min
        (Value'Length, Introspection_SQL.Maximum_Name_Length);
   begin
      return Introspection_SQL.Make_Text
        ((if Last = 0 then "" else Value (Value'First .. Value'First + Last - 1)),
         Introspection_SQL.Maximum_Name_Length);
   end Clipped_Name;

   function Clipped_Value (Value : String) return Value_Text is
      Last : constant Natural := Natural'Min
        (Value'Length, Introspection_SQL.Maximum_Value_Length);
   begin
      return Introspection_SQL.Make_Text
        ((if Last = 0 then "" else Value (Value'First .. Value'First + Last - 1)),
         Introspection_SQL.Maximum_Value_Length);
   end Clipped_Value;

   protected body Session_Registry is
      procedure Register
        (Owner            : Task_Id;
         User_Name        : String;
         Database_Name    : String;
         Application_Name : String;
         Accepted         : out Boolean) is
         Free : Natural := 0;
      begin
         for Index in Slots'Range loop
            if Slots (Index).Occupied and then Slots (Index).Owner = Owner then
               Free := Index;
               exit;
            elsif not Slots (Index).Occupied and then Free = 0 then
               Free := Index;
            end if;
         end loop;
         Accepted := Free /= 0;
         if Accepted then
            Slots (Free) :=
              (Occupied => True,
               Owner    => Owner,
               Value    =>
                 (Session_Id       => Next_Id,
                  User_Name        => Clipped_Name (User_Name),
                  Database_Name    => Clipped_Name (Database_Name),
                  Application_Name => Clipped_Name (Application_Name),
                  Query_Count      => 0,
                  Connected_At     => Ada.Calendar.Clock,
                  State            => Clipped_Name ("idle"),
                  Current_Query    => Clipped_Value ("")),
               others => <>);
            if Next_Id = Natural'Last then
               Next_Id := 1;
            else
               Next_Id := Next_Id + 1;
            end if;
         end if;
      end Register;

      procedure Begin_Query
        (Owner : Task_Id; SQL : String; Session : out Session_Snapshot) is
      begin
         Session := (others => <>);
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               if Slot.Value.Query_Count < Natural'Last then
                  Slot.Value.Query_Count := Slot.Value.Query_Count + 1;
               end if;
               Slot.Value.State := Clipped_Name ("running");
               Slot.Value.Current_Query := Clipped_Value (SQL);
               Session := Slot.Value;
               return;
            end if;
         end loop;
         raise Program_Error with "Postgres handler has no registered session";
      end Begin_Query;

      procedure End_Query (Owner : Task_Id) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               Slot.Value.State := Clipped_Name ("idle");
               Slot.Value.Current_Query := Clipped_Value ("");
               return;
            end if;
         end loop;
      end End_Query;

      procedure Current (Owner : Task_Id; Session : out Session_Snapshot) is
      begin
         Session := (others => <>);
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               Session := Slot.Value;
               return;
            end if;
         end loop;
         raise Program_Error with "Postgres handler has no registered session";
      end Current;

      procedure Remove (Owner : Task_Id) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               Slot := (others => <>);
               return;
            end if;
         end loop;
      end Remove;

      procedure Snapshot (Values : out Session_Array; Count : out Natural) is
      begin
         Values := (others => <>);
         Count := 0;
         for Slot of Slots loop
            if Slot.Occupied then
               Count := Count + 1;
               Values (Count) := Slot.Value;
            end if;
         end loop;
      end Snapshot;

      procedure Store_Statement
        (Owner : Task_Id; Name : String; SQL : String) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               Slot.Statement_Name := Clipped_Name (Name);
               Slot.Statement_SQL := Introspection_SQL.Make_Text
                 (SQL, Introspection_SQL.Maximum_Query_Length);
               if Name'Length = 0 then
                  Slot.Portal_Name := Clipped_Name ("");
                  Slot.Portal_SQL := Introspection_SQL.Make_Text
                    ("", Introspection_SQL.Maximum_Query_Length);
               end if;
               return;
            end if;
         end loop;
         raise Program_Error with "Postgres handler has no registered session";
      end Store_Statement;

      procedure Bind_Portal
        (Owner : Task_Id; Portal_Name : String; Statement_Name : String) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               if Introspection_SQL.Image (Slot.Statement_Name) /= Statement_Name then
                  raise Constraint_Error with "unknown prepared statement";
               end if;
               Slot.Portal_Name := Clipped_Name (Portal_Name);
               Slot.Portal_SQL := Slot.Statement_SQL;
               return;
            end if;
         end loop;
         raise Program_Error with "Postgres handler has no registered session";
      end Bind_Portal;

      function Get_SQL
        (Owner : Task_Id; Portal : Boolean; Name : String) return Query_Text is
         SQL : Query_Text := Introspection_SQL.Make_Text
           ("", Introspection_SQL.Maximum_Query_Length);
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               if Portal and then Introspection_SQL.Image (Slot.Portal_Name) = Name then
                  SQL := Slot.Portal_SQL;
               elsif not Portal
                 and then Introspection_SQL.Image (Slot.Statement_Name) = Name
               then
                  SQL := Slot.Statement_SQL;
               end if;
               return SQL;
            end if;
         end loop;
         return SQL;
      end Get_SQL;

      procedure Close_Extended
        (Owner : Task_Id; Portal : Boolean; Name : String) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               if Portal and then Introspection_SQL.Image (Slot.Portal_Name) = Name then
                  Slot.Portal_Name := Clipped_Name ("");
                  Slot.Portal_SQL := Introspection_SQL.Make_Text
                    ("", Introspection_SQL.Maximum_Query_Length);
               elsif not Portal
                 and then Introspection_SQL.Image (Slot.Statement_Name) = Name
               then
                  Slot.Statement_Name := Clipped_Name ("");
                  Slot.Statement_SQL := Introspection_SQL.Make_Text
                    ("", Introspection_SQL.Maximum_Query_Length);
               end if;
               return;
            end if;
         end loop;
      end Close_Extended;

      procedure Set_Failed (Owner : Task_Id; Value : Boolean) is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               Slot.Failed_Extended := Value;
               return;
            end if;
         end loop;
      end Set_Failed;

      function Is_Failed (Owner : Task_Id) return Boolean is
      begin
         for Slot of Slots loop
            if Slot.Occupied and then Slot.Owner = Owner then
               return Slot.Failed_Extended;
            end if;
         end loop;
         return False;
      end Is_Failed;
   end Session_Registry;

   procedure Load_Commits (Item : in out Server_State) is
      package OS renames GNAT.OS_Lib;
      use type OS.File_Descriptor;
      use type OS.String_Access;
      Git        : OS.String_Access := OS.Locate_Exec_On_Path ("git");
      Output_FD  : OS.File_Descriptor;
      Output_Name : OS.String_Access;
      Success    : Boolean := False;
      Return_Code : Integer := -1;
      Field      : String (1 .. Introspection_SQL.Maximum_Value_Length);
      Field_Length : Natural := 0;
      Field_Number : Positive := 1;
      Current      : Commit;

      procedure Finish_Field is
         Value : constant String :=
           (if Field_Length = 0 then "" else Field (1 .. Field_Length));
      begin
         case Field_Number is
            when 1 => Current.Hash := Clipped_Name (Value);
            when 2 => Current.Short_Hash := Clipped_Name (Value);
            when 3 => Current.Author := Clipped_Value (Value);
            when 4 => Current.Committed_At := Clipped_Name (Value);
            when 5 => Current.Subject := Clipped_Value (Value);
            when others => null;
         end case;
         Field_Length := 0;
      end Finish_Field;

      procedure Finish_Record is
      begin
         Finish_Field;
         if Item.Commit_Count < Maximum_Commits
           and then not Introspection_SQL.Is_Empty (Current.Hash)
         then
            Item.Commit_Count := Item.Commit_Count + 1;
            Item.Commit_Data (Item.Commit_Count) := Current;
            if Item.Commit_Count = 1 then
               Item.Head := Current.Hash;
            end if;
         end if;
         Current := (others => <>);
         Field_Number := 1;
      end Finish_Record;
   begin
      Item.Commit_Data := (others => <>);
      Item.Commit_Count := 0;
      Item.Head := Clipped_Name ("");
      if Git = null then
         return;
      end if;

      OS.Create_Temp_Output_File (Output_FD, Output_Name);
      if Output_FD = OS.Invalid_FD or else Output_Name = null then
         OS.Free (Git);
         return;
      end if;
      OS.Close (Output_FD);
      declare
         Args : OS.Argument_List (1 .. 8) :=
           (new String'("-C"),
            new String'(Introspection_SQL.Image (Item.Settings.Repository_Path)),
            new String'("log"),
            new String'("--no-decorate"),
            new String'("--date=iso-strict"),
            new String'("-n"),
            new String'(Maximum_Commits'Image),
            new String'("--format=%H%x1f%h%x1f%an%x1f%aI%x1f%s%x1e"));
      begin
         OS.Spawn
           (Program_Name => Git.all,
            Args         => Args,
            Output_File  => Output_Name.all,
            Success      => Success,
            Return_Code  => Return_Code,
            Err_To_Out   => False);
         for Argument of Args loop
            OS.Free (Argument);
         end loop;
      end;
      if Success and then Return_Code = 0 then
         declare
            File : Ada.Text_IO.File_Type;
         begin
            Ada.Text_IO.Open (File, Ada.Text_IO.In_File, Output_Name.all);
            while not Ada.Text_IO.End_Of_File (File) loop
               declare
                  Character_Value : Character;
               begin
                  Ada.Text_IO.Get (File, Character_Value);
                  if Character_Value = Character'Val (16#1F#) then
                     Finish_Field;
                     Field_Number := Field_Number + 1;
                  elsif Character_Value = Character'Val (16#1E#) then
                     Finish_Record;
                  elsif Character_Value not in ASCII.CR | ASCII.LF
                    and then Field_Length < Field'Length
                  then
                     Field_Length := Field_Length + 1;
                     Field (Field_Length) := Character_Value;
                  end if;
               end;
            end loop;
            Ada.Text_IO.Close (File);
         exception
            when others =>
               if Ada.Text_IO.Is_Open (File) then
                  Ada.Text_IO.Close (File);
               end if;
               Item.Commit_Count := 0;
               Item.Head := Clipped_Name ("");
         end;
      end if;
      declare
         Deleted : Boolean;
      begin
         OS.Delete_File (Output_Name.all, Deleted);
      end;
      OS.Free (Output_Name);
      OS.Free (Git);
   exception
      when others =>
         if Git /= null then
            OS.Free (Git);
         end if;
         if Output_Name /= null then
            begin
               Ada.Directories.Delete_File (Output_Name.all);
            exception
               when others => null;
            end;
            OS.Free (Output_Name);
         end if;
         Item.Commit_Count := 0;
         Item.Head := Clipped_Name ("");
   end Load_Commits;

   procedure Initialize
     (Item : in out Server_State; Config : Configuration) is
   begin
      Item.Settings := Config;
      Load_Commits (Item);
   end Initialize;

   function Config (Item : Server_State) return Configuration is
     (Item.Settings);

   function Repository_Head (Item : Server_State) return String is
     (Introspection_SQL.Image (Item.Head));

   procedure Repository_Commits
     (Item : Server_State; Values : out Commit_Array; Count : out Natural) is
   begin
      Values := Item.Commit_Data;
      Count := Item.Commit_Count;
   end Repository_Commits;

   procedure Register_Session
     (Item             : in out Server_State;
      User_Name        : String;
      Database_Name    : String;
      Application_Name : String;
      Accepted         : out Boolean) is
   begin
      Item.Registry.Register
        (Ada.Task_Identification.Current_Task,
         User_Name,
         Database_Name,
         Application_Name,
         Accepted);
   end Register_Session;

   procedure Begin_Query
     (Item : in out Server_State; SQL : String; Session : out Session_Snapshot) is
   begin
      Item.Registry.Begin_Query
        (Ada.Task_Identification.Current_Task, SQL, Session);
   end Begin_Query;

   procedure End_Query (Item : in out Server_State) is
   begin
      Item.Registry.End_Query (Ada.Task_Identification.Current_Task);
   end End_Query;

   procedure Current_Session
     (Item : in out Server_State; Session : out Session_Snapshot) is
   begin
      Item.Registry.Current
        (Ada.Task_Identification.Current_Task, Session);
   end Current_Session;

   procedure Remove_Session (Item : in out Server_State) is
   begin
      Item.Registry.Remove (Ada.Task_Identification.Current_Task);
   end Remove_Session;

   procedure Sessions
     (Item : in out Server_State;
      Values : out Session_Array;
      Count : out Natural) is
   begin
      Item.Registry.Snapshot (Values, Count);
   end Sessions;

   procedure Store_Statement
     (Item : in out Server_State; Name : String; SQL : String) is
   begin
      Item.Registry.Store_Statement
        (Ada.Task_Identification.Current_Task, Name, SQL);
   end Store_Statement;

   procedure Bind_Portal
     (Item : in out Server_State; Portal_Name : String; Statement_Name : String) is
   begin
      Item.Registry.Bind_Portal
        (Ada.Task_Identification.Current_Task, Portal_Name, Statement_Name);
   end Bind_Portal;

   function Statement_SQL
     (Item : Server_State; Name : String; Found : out Boolean) return String is
      Value : constant Query_Text := Item.Registry.Get_SQL
        (Ada.Task_Identification.Current_Task, False, Name);
   begin
      Found := not Introspection_SQL.Is_Empty (Value);
      return Introspection_SQL.Image (Value);
   end Statement_SQL;

   function Portal_SQL
     (Item : Server_State; Name : String; Found : out Boolean) return String is
      Value : constant Query_Text := Item.Registry.Get_SQL
        (Ada.Task_Identification.Current_Task, True, Name);
   begin
      Found := not Introspection_SQL.Is_Empty (Value);
      return Introspection_SQL.Image (Value);
   end Portal_SQL;

   procedure Close_Extended
     (Item : in out Server_State; Portal : Boolean; Name : String) is
   begin
      Item.Registry.Close_Extended
        (Ada.Task_Identification.Current_Task, Portal, Name);
   end Close_Extended;

   procedure Set_Extended_Failed (Item : in out Server_State; Value : Boolean) is
   begin
      Item.Registry.Set_Failed (Ada.Task_Identification.Current_Task, Value);
   end Set_Extended_Failed;

   function Extended_Failed (Item : Server_State) return Boolean is
     (Item.Registry.Is_Failed (Ada.Task_Identification.Current_Task));

end Introspection_State;
