with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Bounded;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.IO;
with Flyology.Native_Executors;
with GNAT.Expect;
with GNAT.OS_Lib;
with Psqlbench_JSON;

package body Psqlbench_Docker is

   package Argument_Strings is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => 256);

   Max_Arguments : constant := 64;
   type Argument_Array is array (Positive range 1 .. Max_Arguments) of
     Argument_Strings.Bounded_String;

   type Command is record
      Count : Natural range 0 .. Max_Arguments := 0;
      Args  : Argument_Array;
   end record;

   procedure Add (Item : in out Command; Value : String) is
   begin
      if Item.Count = Max_Arguments then
         raise Constraint_Error with "too many Docker arguments";
      end if;
      Item.Count := Item.Count + 1;
      Item.Args (Item.Count) := Argument_Strings.To_Bounded_String (Value);
   end Add;

   function Compact (Value : Positive) return String is
     (Ada.Strings.Fixed.Trim (Positive'Image (Value), Ada.Strings.Both));

   procedure Store
     (Item      : in out Result;
      Value     : String;
      Truncated : Boolean := False) is
   begin
      Item.Length := Natural'Min (Value'Length, Max_Output_Bytes);
      if Item.Length > 0 then
         Item.Output (1 .. Item.Length) :=
           Value (Value'First .. Value'First + Item.Length - 1);
      end if;
      Item.Truncated := Truncated or else Value'Length > Max_Output_Bytes;
   end Store;

   function Text (Item : Result) return String is
     (if Item.Length = 0 then "" else Item.Output (1 .. Item.Length));

   procedure Execute_Command
     (Input    : Command;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time;
      Value    : out Result)
   is
      use type Ada.Real_Time.Time;
      use type GNAT.Expect.Expect_Match;
      use type GNAT.OS_Lib.String_Access;

      Program    : GNAT.OS_Lib.String_Access :=
        GNAT.OS_Lib.Locate_Exec_On_Path ("docker");
      Descriptor : GNAT.Expect.Process_Descriptor;
      Spawned    : Boolean := False;
      Output     : Unbounded_String;

      procedure Close_Quietly is
      begin
         if Spawned then
            begin
               GNAT.Expect.Close (Descriptor);
            exception
               when others => null;
            end;
            Spawned := False;
         end if;
      end Close_Quietly;
   begin
      Value := (others => <>);
      if Program = null then
         Store (Value, "docker executable was not found on PATH");
         return;
      end if;
      if Input.Count = 0 then
         Store (Value, "empty Docker command");
         GNAT.OS_Lib.Free (Program);
         return;
      end if;

      declare
         Args : GNAT.OS_Lib.Argument_List (1 .. Input.Count);
      begin
         for Index in Args'Range loop
            Args (Index) := new String'
              (Argument_Strings.To_String (Input.Args (Index)));
         end loop;
         begin
            GNAT.Expect.Non_Blocking_Spawn
              (Descriptor,
               Program.all,
               Args,
               Buffer_Size => Max_Output_Bytes,
               Err_To_Out  => True);
            Spawned := True;
         exception
            when others =>
               for Index in Args'Range loop
                  GNAT.OS_Lib.Free (Args (Index));
               end loop;
               GNAT.OS_Lib.Free (Program);
               raise;
         end;
         for Index in Args'Range loop
            GNAT.OS_Lib.Free (Args (Index));
         end loop;
      end;
      GNAT.OS_Lib.Free (Program);

      loop
         if Token /= null and then Token.Requested then
            Close_Quietly;
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         if Deadline /= Ada.Real_Time.Time_Last
           and then Ada.Real_Time.Clock >= Deadline
         then
            Close_Quietly;
            raise Flyology.IO.Timeout_Error;
         end if;

         declare
            Match : GNAT.Expect.Expect_Match;
         begin
            begin
               GNAT.Expect.Expect
                 (Descriptor,
                  Match,
                  ".+",
                  Timeout     => 100,
                  Full_Buffer => True);
               if Match > 0 then
                  Append (Output, GNAT.Expect.Expect_Out (Descriptor));
                  if Length (Output) > Max_Output_Bytes then
                     Store
                       (Value, Slice (Output, 1, Max_Output_Bytes),
                        Truncated => True);
                     Close_Quietly;
                     Value.Exit_Code := -1;
                     return;
                  end if;
               elsif Match = GNAT.Expect.Expect_Full_Buffer then
                  Store
                    (Value, To_String (Output),
                     Truncated => True);
                  Close_Quietly;
                  Value.Exit_Code := -1;
                  return;
               end if;
            exception
               when GNAT.Expect.Process_Died =>
                  Store (Value, To_String (Output));
                  declare
                     Status : Integer;
                  begin
                     GNAT.Expect.Close (Descriptor, Status);
                     Spawned := False;
                     Value.Exit_Code := Status;
                     Value.Success := Status = 0;
                     return;
                  end;
            end;
         end;
      end loop;
   exception
      when others =>
         Close_Quietly;
         if Program /= null then
            GNAT.OS_Lib.Free (Program);
         end if;
         raise;
   end Execute_Command;

   package Operations is new Flyology.Native_Executors
     (Input_Type  => Command,
      Result_Type => Result,
      Execute     => Execute_Command);

   Executor : aliased Operations.Executor (Workers => 1, Capacity => 32);

   procedure Start is
   begin
      Operations.Start (Executor);
   end Start;

   procedure Shutdown is
   begin
      Operations.Shutdown (Executor);
   end Shutdown;

   function Run
     (Item     : Command;
      Token    : access Flyology.Cancellation.Token;
      Deadline : Ada.Real_Time.Time) return Result
   is
      Handle   : Operations.Operation_Handle (Executor'Access);
      Accepted : Boolean;
      Value    : Result;
   begin
      Operations.Submit
        (Executor, Item, Token, Deadline, Handle, Accepted);
      if not Accepted then
         Store (Value, "Docker command queue is full");
         return Value;
      end if;
      Operations.Await
        (Executor, Handle, Value, Token => Token, Deadline => Deadline);
      return Value;
   end Run;

   function Check
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "version");
      Add (Item, "--format");
      Add (Item, "{{json .Server.Version}}");
      return Run (Item, Token, Deadline);
   end Check;

   function Ensure_Network
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Inspect : Command;
      Create  : Command;
      Value   : Result;
   begin
      Add (Inspect, "network");
      Add (Inspect, "inspect");
      Add (Inspect, "psqlbench");
      Value := Run (Inspect, Token, Deadline);
      if Value.Success then
         return Value;
      end if;
      Add (Create, "network");
      Add (Create, "create");
      Add (Create, "--driver");
      Add (Create, "bridge");
      Add (Create, "--label");
      Add (Create, "org.flyology.psqlbench.network=true");
      Add (Create, "psqlbench");
      return Run (Create, Token, Deadline);
   end Ensure_Network;

   function JSON_Array (Lines : String) return String is
      Document : Psqlbench_JSON.Writer;
      First  : Natural := Lines'First;
   begin
      Psqlbench_JSON.Initialize (Document, Max_Output_Bytes);
      Psqlbench_JSON.Start_Array (Document);
      while First <= Lines'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Lines'Last and then Lines (Last) /= ASCII.LF loop
               Last := Last + 1;
            end loop;
            if Last > First then
               declare
                  Line : constant String := Lines (First .. Last - 1);
                  procedure Add_Field (Field : String) is
                  begin
                     Psqlbench_JSON.String_Value
                       (Document, Field,
                        Psqlbench_JSON.String_Field (Line, Field));
                  end Add_Field;
               begin
                  Psqlbench_JSON.Start_Object (Document);
                  Add_Field ("Labels");
                  Add_Field ("Names");
                  Add_Field ("Image");
                  Add_Field ("State");
                  Add_Field ("Status");
                  Psqlbench_JSON.End_Object (Document);
               end;
            end if;
            First := Last + 1;
         end;
      end loop;
      Psqlbench_JSON.End_Array (Document);
      return Psqlbench_JSON.Finish (Document);
   end JSON_Array;

   function List_Instances
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item  : Command;
      Value : Result;
   begin
      Add (Item, "container");
      Add (Item, "ls");
      Add (Item, "--all");
      Add (Item, "--filter");
      Add (Item, "label=org.flyology.psqlbench.instance");
      Add (Item, "--format");
      Add (Item, "{{json .}}");
      Value := Run (Item, Token, Deadline);
      if Value.Success then
         declare
            Wrapped : constant String := JSON_Array (Text (Value));
         begin
            Value.Length := 0;
            Store (Value, Wrapped);
         end;
      end if;
      return Value;
   end List_Instances;

   function List_Instance_Names
     (Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "ls");
      Add (Item, "--all");
      Add (Item, "--filter");
      Add (Item, "label=org.flyology.psqlbench.instance");
      Add (Item, "--format");
      Add (Item, "{{.Label ""org.flyology.psqlbench.instance""}}");
      return Run (Item, Token, Deadline);
   end List_Instance_Names;

   function Instance_Port
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "inspect");
      Add (Item, "--format");
      Add
        (Item,
         "{{index .Config.Labels ""org.flyology.psqlbench.port""}}");
      Add (Item, "psqlbench-" & Name);
      return Run (Item, Token, Deadline);
   end Instance_Port;

   function Instance_Version
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "inspect");
      Add (Item, "--format");
      Add
        (Item,
         "{{index .Config.Labels ""org.flyology.psqlbench.version""}}");
      Add (Item, "psqlbench-" & Name);
      return Run (Item, Token, Deadline);
   end Instance_Version;

   function Instance_Role
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "inspect");
      Add (Item, "--format");
      Add
        (Item,
         "{{index .Config.Labels ""org.flyology.psqlbench.role""}}");
      Add (Item, "psqlbench-" & Name);
      return Run (Item, Token, Deadline);
   end Instance_Role;

   function Inspect_Instance
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "inspect");
      Add (Item, "psqlbench-" & Name);
      return Run (Item, Token, Deadline);
   end Inspect_Instance;

   function Enable_Replication_Access
     (Name     : String;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "exec");
      Add (Item, "--user");
      Add (Item, "postgres");
      Add (Item, "psqlbench-" & Name);
      Add (Item, "sh");
      Add (Item, "-c");
      Add
        (Item,
         "grep -qxF 'host replication psqlbench samenet scram-sha-256' "
         & """$PGDATA/pg_hba.conf"" || printf '%s\n' "
         & "'host replication psqlbench samenet scram-sha-256' >> "
         & """$PGDATA/pg_hba.conf""; pg_ctl reload");
      return Run (Item, Token, Deadline);
   end Enable_Replication_Access;

   function Logs
     (Name     : String;
      Since    : String;
      Initial  : Boolean;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
   begin
      Add (Item, "container");
      Add (Item, "logs");
      Add (Item, "--timestamps");
      if Initial then
         Add (Item, "--tail");
         Add (Item, "200");
      else
         Add (Item, "--since");
         Add (Item, Since);
      end if;
      Add (Item, "psqlbench-" & Name);
      return Run (Item, Token, Deadline);
   end Logs;

   function Container_Name (Name : String) return String is
     ("psqlbench-" & Name);

   function Create_Instance
     (Name     : String;
      Version  : String;
      Port     : Positive;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item  : Command;
      Value : Result;
   begin
      Add (Item, "container");
      Add (Item, "create");
      Add (Item, "--name");
      Add (Item, Container_Name (Name));
      Add (Item, "--hostname");
      Add (Item, Name);
      Add (Item, "--network");
      Add (Item, "psqlbench");
      Add (Item, "--add-host");
      Add (Item, "host.docker.internal:host-gateway");
      Add (Item, "--label");
      Add (Item, "org.flyology.psqlbench.instance=" & Name);
      Add (Item, "--label");
      Add (Item, "org.flyology.psqlbench.version=" & Version);
      Add (Item, "--label");
      Add (Item, "org.flyology.psqlbench.port=" & Compact (Port));
      Add (Item, "--publish");
      Add (Item, "127.0.0.1:" & Compact (Port) & ":5432");
      Add (Item, "--env");
      Add (Item, "POSTGRES_USER=psqlbench");
      Add (Item, "--env");
      Add (Item, "POSTGRES_PASSWORD=psqlbench");
      Add (Item, "--env");
      Add (Item, "POSTGRES_DB=postgres");
      Add (Item, "--health-cmd");
      Add (Item, "pg_isready -U psqlbench -d postgres");
      Add (Item, "--health-interval");
      Add (Item, "1s");
      Add (Item, "--health-timeout");
      Add (Item, "3s");
      Add (Item, "--health-retries");
      Add (Item, "30");
      Add (Item, "postgres:" & Version & "-bookworm");
      Add (Item, "-c");
      Add (Item, "listen_addresses=*");
      Add (Item, "-c");
      Add (Item, "wal_level=logical");
      Add (Item, "-c");
      Add (Item, "max_wal_senders=20");
      Add (Item, "-c");
      Add (Item, "max_replication_slots=20");
      Add (Item, "-c");
      Add (Item, "hot_standby=on");
      Value := Run (Item, Token, Deadline);
      if not Value.Success then
         return Value;
      end if;
      return Apply (Name, Start_Instance, Token, Deadline);
   end Create_Instance;

   function Bootstrap_Physical_Standby
     (Name       : String;
      Source     : String;
      Version    : String;
      Port       : Positive;
      Slot       : String;
      Relay_Port : Positive;
      Token      : access Flyology.Cancellation.Token := null;
      Deadline   : Ada.Real_Time.Time := Ada.Real_Time.Time_Last)
      return Result
   is
      Volume_Name : constant String := Container_Name (Name) & "-data";
      Image : constant String := "postgres:" & Version & "-bookworm";
      Volume : Command;
      Prepare : Command;
      Backup : Command;
      Create : Command;
      Value : Result;
   begin
      declare
         Remove_Stale : Command;
         Ignored : Result;
         pragma Unreferenced (Ignored);
      begin
         Add (Remove_Stale, "volume");
         Add (Remove_Stale, "rm");
         Add (Remove_Stale, Volume_Name);
         Ignored := Run (Remove_Stale, Token, Deadline);
      end;

      Add (Volume, "volume");
      Add (Volume, "create");
      Add (Volume, "--label");
      Add (Volume, "org.flyology.psqlbench.instance=" & Name);
      Add (Volume, Volume_Name);
      Value := Run (Volume, Token, Deadline);
      if not Value.Success then
         return Value;
      end if;

      Add (Prepare, "container");
      Add (Prepare, "run");
      Add (Prepare, "--rm");
      Add (Prepare, "--env");
      Add (Prepare, "PGDATA=/var/lib/postgresql/data");
      Add (Prepare, "--mount");
      Add
        (Prepare,
         "type=volume,source=" & Volume_Name
         & ",target=/var/lib/postgresql/data");
      Add (Prepare, Image);
      Add (Prepare, "sh");
      Add (Prepare, "-c");
      Add
        (Prepare,
         "chown -R postgres:postgres /var/lib/postgresql/data");
      Value := Run (Prepare, Token, Deadline);
      if not Value.Success then
         return Value;
      end if;

      Add (Backup, "container");
      Add (Backup, "run");
      Add (Backup, "--rm");
      Add (Backup, "--network");
      Add (Backup, "psqlbench");
      Add (Backup, "--env");
      Add (Backup, "PGPASSWORD=psqlbench");
      Add (Backup, "--env");
      Add (Backup, "PGDATA=/var/lib/postgresql/data");
      Add (Backup, "--user");
      Add (Backup, "postgres");
      Add (Backup, "--mount");
      Add
        (Backup,
         "type=volume,source=" & Volume_Name
         & ",target=/var/lib/postgresql/data");
      Add (Backup, Image);
      Add (Backup, "pg_basebackup");
      Add (Backup, "--host");
      Add (Backup, Container_Name (Source));
      Add (Backup, "--username");
      Add (Backup, "psqlbench");
      Add (Backup, "--pgdata");
      Add (Backup, "/var/lib/postgresql/data");
      Add (Backup, "--format=plain");
      Add (Backup, "--wal-method=stream");
      Add (Backup, "--checkpoint=fast");
      Add (Backup, "--slot");
      Add (Backup, Slot);
      Add (Backup, "--write-recovery-conf");
      Value := Run (Backup, Token, Deadline);
      if not Value.Success then
         return Value;
      end if;

      Add (Create, "container");
      Add (Create, "create");
      Add (Create, "--name");
      Add (Create, Container_Name (Name));
      Add (Create, "--hostname");
      Add (Create, Name);
      Add (Create, "--network");
      Add (Create, "psqlbench");
      Add (Create, "--add-host");
      Add (Create, "host.docker.internal:host-gateway");
      Add (Create, "--label");
      Add (Create, "org.flyology.psqlbench.instance=" & Name);
      Add (Create, "--label");
      Add (Create, "org.flyology.psqlbench.version=" & Version);
      Add (Create, "--label");
      Add (Create, "org.flyology.psqlbench.port=" & Compact (Port));
      Add (Create, "--label");
      Add (Create, "org.flyology.psqlbench.role=physical-standby");
      Add (Create, "--env");
      Add (Create, "PGDATA=/var/lib/postgresql/data");
      Add (Create, "--env");
      Add (Create, "POSTGRES_PASSWORD=psqlbench");
      Add (Create, "--publish");
      Add (Create, "127.0.0.1:" & Compact (Port) & ":5432");
      Add (Create, "--mount");
      Add
        (Create,
         "type=volume,source=" & Volume_Name
         & ",target=/var/lib/postgresql/data");
      Add (Create, "--health-cmd");
      Add (Create, "pg_isready -U psqlbench -d postgres");
      Add (Create, "--health-interval");
      Add (Create, "1s");
      Add (Create, "--health-timeout");
      Add (Create, "3s");
      Add (Create, "--health-retries");
      Add (Create, "60");
      Add (Create, Image);
      Add (Create, "-c");
      Add (Create, "listen_addresses=*");
      Add (Create, "-c");
      Add
        (Create,
         "primary_conninfo=host=host.docker.internal port="
         & Compact (Relay_Port)
         & " user=psqlbench password=psqlbench application_name=" & Name);
      Add (Create, "-c");
      Add (Create, "primary_slot_name=" & Slot);
      Add (Create, "-c");
      Add (Create, "hot_standby=on");
      Add (Create, "-c");
      Add (Create, "wal_level=logical");
      Add (Create, "-c");
      Add (Create, "max_wal_senders=20");
      Add (Create, "-c");
      Add (Create, "max_replication_slots=20");
      return Run (Create, Token, Deadline);
   end Bootstrap_Physical_Standby;

   function Apply
     (Name     : String;
      Action   : Instance_Action;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
      Value : Result;
   begin
      Add (Item, "container");
      Add
        (Item,
         (case Action is
             when Start_Instance  => "start",
             when Stop_Instance   => "stop",
             when Remove_Instance => "rm"));
      if Action = Stop_Instance then
         Add (Item, "--time");
         Add (Item, "10");
      elsif Action = Remove_Instance then
         Add (Item, "--force");
         Add (Item, "--volumes");
      end if;
      Add (Item, Container_Name (Name));
      Value := Run (Item, Token, Deadline);
      if Value.Success and then Action = Remove_Instance then
         declare
            Volume : Command;
            Ignored : Result;
            pragma Unreferenced (Ignored);
         begin
            Add (Volume, "volume");
            Add (Volume, "rm");
            Add (Volume, Container_Name (Name) & "-data");
            Ignored := Run (Volume, Token, Deadline);
         end;
      end if;
      return Value;
   end Apply;

end Psqlbench_Docker;
