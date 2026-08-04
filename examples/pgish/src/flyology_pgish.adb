with Ada.Calendar;
with Ada.Characters.Handling;
with Ada.Command_Line;
with Ada.Directories;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres;
with Flyology.Postgres.Server;
with GNAT.OS_Lib;
with Pgish_Handler;
with Pgish_Signals;
with Pgish_SQL;
with Pgish_State;

procedure Flyology_Pgish is

   package Sockets renames Flyology.IO.Sockets;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package SQL renames Pgish_SQL;

   type Parsed_Configuration is record
      Settings : Pgish_State.Configuration;
      TLS_Certificate : Ada.Strings.Unbounded.Unbounded_String;
      TLS_Private_Key : Ada.Strings.Unbounded.Unbounded_String;
      Help     : Boolean := False;
   end record;

   function Read_Configuration return Parsed_Configuration is
      Result : Parsed_Configuration;
      Host : SQL.Name_Text := SQL.Make_Text
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_PGISH_HOST", "127.0.0.1"),
         SQL.Maximum_Name_Length);
      Port : Natural := Natural'Value
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_PGISH_PORT", "55432"));
      Repository : SQL.Text (1_024) := SQL.Make_Text
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_PGISH_REPO",
            Ada.Directories.Current_Directory),
         1_024);
      Task_Mode : SQL.Name_Text := SQL.Make_Text
        (Ada.Characters.Handling.To_Lower
           (Ada.Environment_Variables.Value
              ("FLYOLOGY_PGISH_TASK_MODE", "lightweight")),
         SQL.Maximum_Name_Length);
      TLS_Certificate : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Ada.Environment_Variables.Value
             ("FLYOLOGY_PGISH_TLS_CERT", ""));
      TLS_Private_Key : Ada.Strings.Unbounded.Unbounded_String :=
        Ada.Strings.Unbounded.To_Unbounded_String
          (Ada.Environment_Variables.Value
             ("FLYOLOGY_PGISH_TLS_KEY", ""));
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
            elsif Argument = "--tls-cert" then
               TLS_Certificate := Ada.Strings.Unbounded.To_Unbounded_String
                 (Next_Value (Argument));
            elsif Argument = "--tls-key" then
               TLS_Private_Key := Ada.Strings.Unbounded.To_Unbounded_String
                 (Next_Value (Argument));
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
      if (Ada.Strings.Unbounded.Length (TLS_Certificate) = 0)
        /= (Ada.Strings.Unbounded.Length (TLS_Private_Key) = 0)
      then
         raise Constraint_Error with
           "--tls-cert and --tls-key must be provided together";
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
         TLS_Enabled     =>
           Ada.Strings.Unbounded.Length (TLS_Certificate) > 0,
         Started_At      => Ada.Calendar.Clock);
      Result.TLS_Certificate := TLS_Certificate;
      Result.TLS_Private_Key := TLS_Private_Key;
      return Result;
   end Read_Configuration;

   Options : constant Parsed_Configuration := Read_Configuration;

   package Example_Server is new Flyology.Postgres.Server
     (Handler_Context       => Pgish_State.Server_State,
      Authenticate          => Pgish_Handler.Authenticate,
      Lookup_SCRAM_Verifier => Pgish_Handler.Lookup_SCRAM_Verifier,
      Handle                => Pgish_Handler.Handle,
      Authentication        => Flyology.Postgres.Trust,
      Handler_Model         =>
        (if SQL.Image (Options.Settings.Task_Mode) = "lightweight"
         then Flyology.Lightweight_Task else Flyology.Native_Task),
      Startup_Timeout       => 15.0,
      Command_Timeout       => 300.0,
      Write_Timeout         => 10.0);

   TLS_Backend : aliased OpenSSL.OpenSSL_Provider;
   Context  : aliased Pgish_State.Server_State;
   Server   : aliased Example_Server.Server
     (Capacity => Pgish_State.Maximum_Sessions);
   Listener : Sockets.Socket_Type;

   task Shutdown_Watcher is
      pragma Task_Info (Flyology.Native_Task);
   end Shutdown_Watcher;

   task body Shutdown_Watcher is
   begin
      loop
         exit when Pgish_Signals.Server_Complete;
         if Pgish_Signals.Stop_Requested then
            Example_Server.Request_Shutdown (Server);
            exit;
         end if;
         delay 0.05;
      end loop;
   end Shutdown_Watcher;

   procedure Usage is
   begin
      Ada.Text_IO.Put_Line
        ("usage: flyology_pgish " &
         "[--host NUMERIC_IP] [--port PORT] [--repo PATH] " &
         "[--task-mode lightweight|native] " &
         "[--tls-cert FILE --tls-key FILE]");
      Ada.Text_IO.Put_Line
        ("environment: FLYOLOGY_PGISH_HOST, " &
         "FLYOLOGY_PGISH_PORT, FLYOLOGY_PGISH_REPO, " &
         "FLYOLOGY_PGISH_TASK_MODE, FLYOLOGY_PGISH_TLS_CERT, " &
         "FLYOLOGY_PGISH_TLS_KEY");
   end Usage;
begin
   if Options.Help then
      Usage;
      Pgish_Signals.Complete;
      return;
   end if;
   Pgish_State.Initialize (Context, Options.Settings);
   if Options.Settings.TLS_Enabled then
      OpenSSL.Initialize_Server
        (TLS_Backend,
         Certificate_File => Ada.Strings.Unbounded.To_String
           (Options.TLS_Certificate),
         Private_Key_File => Ada.Strings.Unbounded.To_String
           (Options.TLS_Private_Key),
         Library_Directory => Ada.Environment_Variables.Value
           ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));
   end if;
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
        (Options.Settings.Port'Image, Ada.Strings.Both) &
      " tls=" &
        (if Options.Settings.TLS_Enabled then "required" else "off"));
   Ada.Text_IO.Flush;
   begin
      if Options.Settings.TLS_Enabled then
         Example_Server.Serve_TLS
           (Server,
            Listener,
            Context,
            TLS_Backend,
            Policy        => Flyology.Postgres.TLS_Required,
            Drain_Timeout => 2.0);
      else
         Example_Server.Serve
           (Server, Listener, Context, Drain_Timeout => 2.0);
      end if;
   exception
      when others =>
         Pgish_Signals.Complete;
         raise;
   end;
   Pgish_Signals.Complete;
exception
   when Error : others =>
      Pgish_Signals.Complete;
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "flyology_pgish: " &
         Ada.Exceptions.Exception_Message (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Flyology_Pgish;
