with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Psqlbench_Assets;
with Psqlbench_Docker;
with Psqlbench_JSON;

package body Psqlbench_Server is

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Owned renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   function Compact (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value ("PSQLBENCH_PORT", "8080")));

   function Diagnostic (Value : String) return String is
      Limit : constant Natural := Natural'Min (Value'Length, 320);
   begin
      return
        (if Limit = 0 then "Docker command failed"
         else Value (Value'First .. Value'First + Limit - 1));
   end Diagnostic;

   procedure Execute
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      type Application_Context is limited record
         Root   : access Psqlbench_Context.Context;
         Assets : Psqlbench_Assets.Bundle;
      end record;

      package Routing is new HTTP.Routing (Application_Context);

      procedure Home
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/html; charset=utf-8", To_String (State.Assets.HTML));
      end Home;

      procedure Stylesheet
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/css; charset=utf-8",
            To_String (State.Assets.Stylesheet));
      end Stylesheet;

      procedure Script
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/javascript; charset=utf-8",
            To_String (State.Assets.Script));
      end Script;

      procedure Status
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Detail : String (1 .. 256);
         Last   : Natural;
      begin
         State.Root.Docker.Read_Detail (Detail, Last);
         X.JSON
           (200,
            "{""docker_ready"":"
            & (if State.Root.Docker.Ready then "true" else "false")
            & ",""docker_transport"":""cli"",""detail"":"
            & Psqlbench_JSON.Quote
                ((if Last = 0 then "" else Detail (1 .. Last)))
            & "}");
      end Status;

      procedure Instances
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
         Value : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.List_Instances (X.Cancellation, X.Deadline);
      begin
         if Value.Success then
            X.JSON (200, Psqlbench_Docker.Text (Value));
         else
            X.Problem
              (503, "docker-list-failed",
               Diagnostic (Psqlbench_Docker.Text (Value)));
         end if;
      end Instances;

      procedure Create_Instance
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name    : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "name");
         Version : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "version");
         Port_No : constant Natural :=
           Psqlbench_JSON.Natural_Field (X.Content, "port", 55_432);
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem
              (400, "invalid-instance-name",
               "Use 1 to 40 lowercase letters, digits, or hyphens");
            return;
         elsif not Psqlbench_JSON.Valid_Version (Version) then
            X.Problem
              (400, "unsupported-postgres-version",
               "Choose PostgreSQL 14.23, 15.18, 16.14, 17.10, or 18.4");
            return;
         elsif Port_No not in 1_024 .. 65_535 then
            X.Problem
              (400, "invalid-postgres-port",
               "Choose an unprivileged TCP port from 1024 through 65535");
            return;
         end if;

         declare
            Value : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Create_Instance
                (Name, Version, Positive (Port_No),
                 X.Cancellation, X.Deadline);
         begin
            if not Value.Success then
               X.Problem
                 (409, "docker-create-failed",
                  Diagnostic (Psqlbench_Docker.Text (Value)));
               return;
            end if;
            State.Root.Events.Append
              ("{""type"":""instance.created"",""name"":"
               & Psqlbench_JSON.Quote (Name)
               & ",""version"":" & Psqlbench_JSON.Quote (Version)
               & ",""port"":" & Compact (Port_No) & "}");
            X.JSON
              (201,
               "{""name"":" & Psqlbench_JSON.Quote (Name)
               & ",""version"":" & Psqlbench_JSON.Quote (Version)
               & ",""port"":" & Compact (Port_No) & "}");
         end;
      exception
         when Error : Constraint_Error =>
            X.Problem
              (400, "invalid-json", Ada.Exceptions.Exception_Message (Error));
      end Create_Instance;

      procedure Apply_Action
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name   : constant String := X.Parameter ("name");
         Action : constant String := X.Parameter ("action");
         Kind   : Psqlbench_Docker.Instance_Action;
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem (400, "invalid-instance-name", "Invalid instance name");
            return;
         end if;
         if Action = "start" then
            Kind := Psqlbench_Docker.Start_Instance;
         elsif Action = "stop" then
            Kind := Psqlbench_Docker.Stop_Instance;
         elsif Action = "remove" then
            Kind := Psqlbench_Docker.Remove_Instance;
         else
            X.Problem (404, "unknown-instance-action", "Unknown action");
            return;
         end if;

         declare
            Value : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Apply
                (Name, Kind, X.Cancellation, X.Deadline);
         begin
            if not Value.Success then
               X.Problem
                 (409, "docker-action-failed",
                  Diagnostic (Psqlbench_Docker.Text (Value)));
               return;
            end if;
            State.Root.Events.Append
              ("{""type"":""instance." & Action
               & """,""name"":" & Psqlbench_JSON.Quote (Name) & "}");
            X.JSON
              (200,
               "{""name"":" & Psqlbench_JSON.Quote (Name)
               & ",""action"":" & Psqlbench_JSON.Quote (Action) & "}");
         end;
      end Apply_Action;

      procedure Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         use type Psqlbench_Context.Event_Sequence;
         Expected_Origin : constant String :=
           "http://" & X.Request_Header ("Host");
         Cursor    : Psqlbench_Context.Event_Sequence := 0;
         Value     : Psqlbench_Context.Event_Record;
         Available : Boolean;
         Dropped   : Psqlbench_Context.Event_Sequence;
         Idle      : Natural := 0;
      begin
         if X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            X.Problem (403, "websocket-origin", "Origin is not allowed");
            return;
         end if;
         X.Accept_WebSocket
           (Origin_Policy  => HTTP.Require_Exact_Origin,
            Allowed_Origin => Expected_Origin);
         loop
            State.Root.Events.Read_After
              (Cursor, Value, Available, Dropped);
            if Available then
               if Dropped > 0 then
                  X.Send_WebSocket
                    ("{""type"":""events.dropped"",""count"":"
                     & Psqlbench_Context.Event_Sequence'Image (Dropped) & "}");
               end if;
               X.Send_WebSocket (Value.Data (1 .. Value.Length));
               Cursor := Value.Sequence;
               Idle := 0;
            else
               delay 0.100;
               Idle := Idle + 1;
               if Idle = 100 then
                  X.Send_WebSocket ("{""type"":""heartbeat""}");
                  Idle := 0;
               end if;
            end if;
         end loop;
      end Events;

      type Service_Context is limited record
         Application : aliased Application_Context;
         Routes      : aliased Routing.Router
           (Capacity => 8, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 4 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Service_Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         Channel : aliased HTTP.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : aliased HTTP.Connection (Channel'Access);
      begin
         HTTP.Configure_Ingress_Budget (Client, State.Budget'Access);
         State.Routes.Serve
           (State.Application, Client, Peer,
            Timeout => 30.0, Header_Timeout => 5.0,
            Token => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Service_Context,
         Handle          => Handle,
         Handler_Model   => Flyology.Lightweight_Task);

      Server   : aliased Server_Instance.Server (Capacity => 64);
      State    : aliased Service_Context;
      Listener : Sockets.Socket_Type;

      protected Lifecycle is
         procedure Complete;
         function Done return Boolean;
      private
         Finished : Boolean := False;
      end Lifecycle;

      protected body Lifecycle is
         procedure Complete is
         begin
            Finished := True;
         end Complete;
         function Done return Boolean is (Finished);
      end Lifecycle;
   begin
      State.Application.Root := Context'Unrestricted_Access;
      Psqlbench_Assets.Load (State.Application.Assets);

      State.Routes.Get ("/", Home'Access, Name => "home");
      State.Routes.Get
        ("/assets/app.css", Stylesheet'Access, Name => "assets.css");
      State.Routes.Get
        ("/assets/app.js", Script'Access, Name => "assets.js");
      State.Routes.Get ("/api/status", Status'Access, Name => "api.status");
      State.Routes.Get
        ("/api/instances", Instances'Access, Name => "api.instances");
      State.Routes.Post
        ("/api/instances", Create_Instance'Access, Name => "api.create",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Buffer_Body,
              Max_Body      => 4 * 1_024,
              Timeout       => 300.0,
              Concurrency   => 8));
      State.Routes.Post
        ("/api/instances/{name}/{action}", Apply_Action'Access,
         Name => "api.action",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Timeout => 30.0, Concurrency => 8));
      State.Routes.Get
        ("/api/events", Events'Access, Name => "api.events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket,
              Timeout => 86_400.0,
              Concurrency => 32));

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => 64);
      Context.Events.Append
        ("{""type"":""http.ready"",""port"":"
         & Compact (Natural (Port)) & "}");
      Flyology.Supervision.Mark_Ready (Control.all);
      Ada.Text_IO.Put_Line
        ("READY psqlbench http://127.0.0.1:"
         & Compact (Natural (Port)) & "/");
      Ada.Text_IO.Flush;

      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task body Stopper is
         begin
            loop
               exit when Lifecycle.Done;
               if Flyology.Supervision.Stopping (Control.all).Requested then
                  Server_Instance.Request_Shutdown (Server);
                  exit;
               end if;
               delay 0.050;
            end loop;
         end Stopper;
      begin
         begin
            Server_Instance.Serve
              (Server, Listener, State, Drain_Timeout => 2.0);
            Lifecycle.Complete;
         exception
            when others =>
               Lifecycle.Complete;
               raise;
         end;
      end;
   end Execute;

end Psqlbench_Server;
