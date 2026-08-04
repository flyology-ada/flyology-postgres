with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Server;
with GNAT.OS_Lib;
with Introspection_Handler;
with Introspection_Signals;
with Introspection_SQL;
with Introspection_State;

procedure Flyology_Postgres_Server_Example is

   package Sockets renames Flyology.IO.Sockets;
   package SQL renames Introspection_SQL;

   type Parsed_Configuration is record
      Settings : Introspection_State.Configuration;
      Help     : Boolean := False;
   end record;

   function Read_Configuration return Parsed_Configuration is
      Result : Parsed_Configuration;
      Host : SQL.Name_Text := SQL.Make_Text
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_POSTGRES_EXAMPLE_HOST", "127.0.0.1"),
         SQL.Maximum_Name_Length);
      Port : Natural := Natural'Value
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_POSTGRES_EXAMPLE_PORT", "55432"));
      Repository : SQL.Text (1_024) := SQL.Make_Text
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_POSTGRES_EXAMPLE_REPO",
            Ada.Directories.Current_Directory),
         1_024);
      Task_Mode : SQL.Name_Text := SQL.Make_Text
        (Ada.Characters.Handling.To_Lower
           (Ada.Environment_Variables.Value
              ("FLYOLOGY_POSTGRES_EXAMPLE_TASK_MODE", "lightweight")),
         SQL.Maximum_Name_Length);
      Index : Positive := 1;

      function Next_Value (Option : String) return String is
      begin
         if Index = Ada.Command_Line.Argument_Count then
            raise Constraint_Error with Option & " requires a value";
         end if;
         Index := Index + 1;
         return Ada.Command_Line.Argument (Index);
      end Next_Value;
   begin
      while Index <= Ada.Command_Line.Argument_Count loop
         declare
            Argument : constant String := Ada.Command_Line.Argument (Index);
         begin
            if Argument = "--host" then
               Host := SQL.Make_Text
                 (Next_Value (Argument), SQL.Maximum_Name_Length);
            elsif Argument = "--port" then
               Port := Natural'Value (Next_Value (Argument));
            elsif Argument = "--repo" then
               Repository := SQL.Make_Text (Next_Value (Argument), 1_024);
            elsif Argument = "--task-mode" then
               Task_Mode := SQL.Make_Text
                 (Ada.Characters.Handling.To_Lower (Next_Value (Argument)),
                  SQL.Maximum_Name_Length);
            elsif Argument in "--help" | "-h" then
               Result.Help := True;
            else
               raise Constraint_Error with "unknown option: " & Argument;
            end if;
            Index := Index + 1;
         end;
      end loop;
      if Port not in 1 .. 65_535 then
         raise Constraint_Error with "port must be in 1 .. 65535";
      end if;
      if SQL.Image (Task_Mode) not in "lightweight" | "native" then
         raise Constraint_Error with
           "task mode must be lightweight or native";
      end if;
      declare
         Normalized : constant String := GNAT.OS_Lib.Normalize_Pathname
           (SQL.Image (Repository));
      begin
         if Normalized'Length > 0 then
            Repository := SQL.Make_Text (Normalized, 1_024);
         end if;
      end;
      Result.Settings :=
        (Host            => Host,
         Port            => Port,
         Repository_Path => Repository,
         Task_Mode       => Task_Mode,
         Started_At      => Ada.Calendar.Clock);
      return Result;
   end Read_Configuration;

   Options : constant Parsed_Configuration := Read_Configuration;

   package Example_Server is new Flyology.Postgres.Server
     (Handler_Context       => Introspection_State.Server_State,
      Authenticate          => Introspection_Handler.Authenticate,
      Lookup_SCRAM_Verifier => Introspection_Handler.Lookup_SCRAM_Verifier,
      Handle                => Introspection_Handler.Handle,
      Authentication        => Flyology.Postgres.Trust,
      Handler_Model         =>
        (if SQL.Image (Options.Settings.Task_Mode) = "lightweight"
         then Flyology.Lightweight_Task else Flyology.Native_Task),
      Startup_Timeout       => 15.0,
      Command_Timeout       => 300.0,
      Write_Timeout         => 10.0);

   Context  : aliased Introspection_State.Server_State;
   Server   : aliased Example_Server.Server
     (Capacity => Introspection_State.Maximum_Sessions);
   Listener : Sockets.Socket_Type;

   task Shutdown_Watcher is
      pragma Task_Info (Flyology.Native_Task);
   end Shutdown_Watcher;

   task body Shutdown_Watcher is
   begin
      loop
         exit when Introspection_Signals.Server_Complete;
         if Introspection_Signals.Stop_Requested then
            Example_Server.Request_Shutdown (Server);
            exit;
         end if;
         delay 0.05;
      end loop;
   end Shutdown_Watcher;

   procedure Usage is
   begin
      Ada.Text_IO.Put_Line
        ("usage: flyology_postgres_server_example " &
         "[--host NUMERIC_IP] [--port PORT] [--repo PATH] " &
         "[--task-mode lightweight|native]");
      Ada.Text_IO.Put_Line
        ("environment: FLYOLOGY_POSTGRES_EXAMPLE_HOST, " &
         "FLYOLOGY_POSTGRES_EXAMPLE_PORT, FLYOLOGY_POSTGRES_EXAMPLE_REPO, " &
         "FLYOLOGY_POSTGRES_EXAMPLE_TASK_MODE");
   end Usage;
begin
   if Options.Help then
      Usage;
      Introspection_Signals.Complete;
      return;
   end if;
   Introspection_State.Initialize (Context, Options.Settings);
   declare
      Address : constant Sockets.IP_Address :=
        Sockets.Parse_IP_Address (SQL.Image (Options.Settings.Host));
   begin
      Sockets.Create_Socket (Listener, Family => Address.Family);
      Sockets.Set_Socket_Option
        (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Address, Sockets.Port (Options.Settings.Port)));
      Sockets.Listen_Socket (Listener, Length => 16);
   end;
   Ada.Text_IO.Put_Line
     ("ready host=" & SQL.Image (Options.Settings.Host) &
      " port=" & Ada.Strings.Fixed.Trim
        (Options.Settings.Port'Image, Ada.Strings.Both));
   Ada.Text_IO.Flush;
   begin
      Example_Server.Serve
        (Server, Listener, Context, Drain_Timeout => 2.0);
   exception
      when others =>
         Introspection_Signals.Complete;
         raise;
   end;
   Introspection_Signals.Complete;
exception
   when Error : others =>
      Introspection_Signals.Complete;
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "flyology_postgres_server_example: " &
         Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Flyology_Postgres_Server_Example;
