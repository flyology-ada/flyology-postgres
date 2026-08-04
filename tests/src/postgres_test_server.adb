with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;

procedure Postgres_Test_Server is

   package Protocol renames Flyology.Postgres.Protocol;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;

   use type Protocol.Frontend_Kind;

   type Context is limited record
      Password : Unbounded_String := To_Unbounded_String ("flyology-secret");
   end record;

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (Startup);
   begin
      return Password = To_String (State.Password);
   end Authenticate;

   function Is_Select (SQL : String) return Boolean is
      Trimmed : constant String := Ada.Strings.Fixed.Trim
        (SQL, Ada.Strings.Both);
      Lower   : constant String := Ada.Characters.Handling.To_Lower (Trimmed);
   begin
      return Lower'Length >= 6
        and then Lower (Lower'First .. Lower'First + 5) = "select";
   end Is_Select;

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Command : Protocol.Message) is
      pragma Unreferenced (State);
      Timeout : constant Duration := 5.0;
   begin
      case Protocol.Kind (Command) is
         when Protocol.Query =>
            declare
               SQL : constant String := Sessions.Query_Text (Command);
               Trimmed : constant String :=
                 Ada.Strings.Fixed.Trim (SQL, Ada.Strings.Both);
            begin
               if Trimmed'Length = 0 then
                  Sessions.Send_Empty_Query_Response (Client, Timeout);
               elsif Is_Select (SQL) then
                  Sessions.Send_Row_Description
                    (Client, Name => "result", Timeout => Timeout);
                  Sessions.Send_Data_Row (Client, "1", Timeout);
                  Sessions.Send_Command_Complete
                    (Client, "SELECT 1", Timeout);
               else
                  Sessions.Send_Command_Complete (Client, "OK", Timeout);
               end if;
               Sessions.Send_Ready (Client, Timeout => Timeout);
            end;

         when Protocol.Parse =>
            Sessions.Send_Parse_Complete (Client, Timeout);

         when Protocol.Bind =>
            Sessions.Send_Bind_Complete (Client, Timeout);

         when Protocol.Describe =>
            Sessions.Send_No_Data (Client, Timeout);

         when Protocol.Execute =>
            Sessions.Send_Command_Complete (Client, "SELECT 0", Timeout);

         when Protocol.Close =>
            Sessions.Send_Close_Complete (Client, Timeout);

         when Protocol.Sync =>
            Sessions.Send_Ready (Client, Timeout => Timeout);

         when Protocol.Flush | Protocol.Terminate_Command =>
            null;

         when others =>
            Sessions.Send_Error
              (Client,
               Message   => "unsupported command in test server",
               SQL_State => "0A000",
               Timeout   => Timeout);
            Sessions.Send_Ready (Client, Timeout => Timeout);
      end case;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context => Context,
      Authenticate    => Authenticate,
      Handle          => Handle,
      Authentication  => Flyology.Postgres.Cleartext_Password,
      Handler_Model   => Flyology.Lightweight_Task);

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_TEST_PORT", "55432"));
   end Port;

   Listener : Sockets.Socket_Type;
   State    : aliased Context;
   Server   : aliased Test_Server.Server (Capacity => 8);
begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener,
      (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 16);
   Ada.Text_IO.Put_Line ("ready");
   Ada.Text_IO.Flush;
   Test_Server.Serve
     (Server, Listener, State, Drain_Timeout => 1.0);
end Postgres_Test_Server;
