with Ada.Exceptions;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Postgres.Transports.Connections;

package body Flyology.Postgres.Server is

   use type Protocol.Frontend_Kind;
   use type Protocol.Initial_Kind;
   use type Protocol.UInt16;

   procedure Send_Startup_Complete
     (Client  : in out Server_Sessions.Session;
      Startup : Protocol.Startup_Information) is
   begin
      Server_Sessions.Send_Authentication_Ok
        (Client, Timeout => Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "server_version", "18.4", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "server_encoding", "UTF8", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "client_encoding", "UTF8", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "DateStyle", "ISO, MDY", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "integer_datetimes", "on", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "standard_conforming_strings", "on", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "TimeZone", "UTC", Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client,
         "session_authorization",
         To_String (Startup.User),
         Write_Timeout);
      Server_Sessions.Send_Parameter_Status
        (Client, "is_superuser", "off", Write_Timeout);
      Server_Sessions.Send_Ready (Client, Timeout => Write_Timeout);
   end Send_Startup_Complete;

   function Admit
     (Context : in out Handler_Context;
      Client  : in out Server_Sessions.Session;
      Startup : Protocol.Startup_Information) return Boolean is
   begin
      case Authentication is
         when Trust =>
            return Authenticate (Context, Startup, "");

         when Cleartext_Password =>
            Server_Sessions.Send_Authentication_Cleartext_Password
              (Client, Timeout => Write_Timeout);
            declare
               Password_Message : constant Protocol.Message :=
                 Server_Sessions.Read_Command
                   (Client, Timeout => Startup_Timeout);
            begin
               if Protocol.Kind (Password_Message) /=
                 Protocol.Password_Or_SASL_Response
               then
                  raise Protocol.Protocol_Error with
                    "expected a password response";
               end if;
               return Authenticate
                 (Context,
                  Startup,
                  Server_Sessions.Password_Text (Password_Message));
            end;
      end case;
   end Admit;

   procedure Run_Session
     (Context : in out Handler_Context;
      Client  : in out Server_Sessions.Session) is
      Initial : Protocol.Initial_Request :=
        Server_Sessions.Read_Initial (Client, Startup_Timeout);
   begin
      for Attempt in 1 .. 2 loop
         pragma Unreferenced (Attempt);
         case Protocol.Kind (Initial) is
            when Protocol.SSL_Request =>
               Server_Sessions.Refuse_TLS (Client, Write_Timeout);
            when Protocol.GSS_Request =>
               Server_Sessions.Refuse_GSS (Client, Write_Timeout);
            when others =>
               exit;
         end case;
         Initial := Server_Sessions.Read_Initial (Client, Startup_Timeout);
      end loop;

      if Protocol.Kind (Initial) = Protocol.Cancel_Request then
         return;
      elsif Protocol.Kind (Initial) /= Protocol.Startup then
         Server_Sessions.Send_Error
           (Client,
            Message   => "unsupported initial Postgres request",
            SQL_State => "08P01",
            Severity  => "FATAL",
            Timeout   => Write_Timeout);
         return;
      end if;

      declare
         Startup : constant Protocol.Startup_Information :=
           Protocol.Startup_Data (Initial);
      begin
         if Startup.Protocol_Major /= 3 then
            Server_Sessions.Send_Error
              (Client,
               Message   => "unsupported Postgres protocol version",
               SQL_State => "0A000",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
            return;
         end if;

         if Startup.Protocol_Minor > 0 then
            Server_Sessions.Send_Negotiate_Protocol
              (Client, Latest_Minor => 0, Timeout => Write_Timeout);
         end if;

         if not Admit (Context, Client, Startup) then
            Server_Sessions.Send_Error
              (Client,
               Message   => "password authentication failed",
               SQL_State => "28P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
            return;
         end if;

         Send_Startup_Complete (Client, Startup);
      end;

      loop
         declare
            Command : constant Protocol.Message :=
              Server_Sessions.Read_Command (Client, Command_Timeout);
         begin
            Handle (Context, Client, Command);
            exit when Protocol.Kind (Command) = Protocol.Terminate_Command;
         end;
      end loop;
   exception
      when Error : Protocol.Protocol_Error =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "08P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
         exception
            when others =>
               null;
         end;
      when Error : others =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "XX000",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
         exception
            when others =>
               null;
         end;
   end Run_Session;

   procedure Process_Connection
     (Context      : in out Handler_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Cancellation : not null access Flyology.Cancellation.Token) is
      pragma Unreferenced (Peer);
      Channel : aliased Transports.Connections.Connection_Transport
        (Connection'Unchecked_Access, Cancellation);
      Client : Server_Sessions.Session (Channel'Access);
   begin
      Run_Session (Context, Client);
   end Process_Connection;

   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out Flyology.IO.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Flyology.IO.Infinite) is
   begin
      Structured.Serve
        (Item.Inner, Listener, Context, Drain_Timeout => Drain_Timeout);
   end Serve;

   procedure Request_Shutdown (Item : in out Server) is
   begin
      Structured.Request_Shutdown (Item.Inner);
   end Request_Shutdown;

end Flyology.Postgres.Server;
