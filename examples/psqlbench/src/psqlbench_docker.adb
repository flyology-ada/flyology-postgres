with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Bounded;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.IO;
with Flyology.Native_Executors;
with GNAT.Expect;
with GNAT.OS_Lib;

package body Psqlbench_Docker is

   package Argument_Strings is new Ada.Strings.Bounded.Generic_Bounded_Length
     (Max => 256);

   Max_Arguments : constant := 48;
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
      Result : Unbounded_String := To_Unbounded_String ("[");
      First  : Natural := Lines'First;
      Added  : Boolean := False;
   begin
      while First <= Lines'Last loop
         declare
            Last : Natural := First;
         begin
            while Last <= Lines'Last and then Lines (Last) /= ASCII.LF loop
               Last := Last + 1;
            end loop;
            if Last > First then
               if Added then
                  Append (Result, ',');
               end if;
               Append (Result, Lines (First .. Last - 1));
               Added := True;
            end if;
            First := Last + 1;
         end;
      end loop;
      Append (Result, ']');
      return To_String (Result);
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

   function Apply
     (Name     : String;
      Action   : Instance_Action;
      Token    : access Flyology.Cancellation.Token := null;
      Deadline : Ada.Real_Time.Time := Ada.Real_Time.Time_Last) return Result
   is
      Item : Command;
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
      return Run (Item, Token, Deadline);
   end Apply;

end Psqlbench_Docker;
