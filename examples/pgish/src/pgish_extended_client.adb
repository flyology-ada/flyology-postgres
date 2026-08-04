with Ada.Command_Line;
with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.TLS_Sockets;

procedure Pgish_Extended_Client is

   package Client renames Flyology.Postgres.Client;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   use type Protocol.Backend_Message_Kind;

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("FLYOLOGY_PGISH_PORT", "55432")));

   CA_File : constant String := Ada.Environment_Variables.Value
     ("FLYOLOGY_PGISH_TLS_CA", "");
   Server_Name : constant String := Ada.Environment_Variables.Value
     ("FLYOLOGY_PGISH_TLS_SERVER_NAME", "localhost");

   TLS_Backend : OpenSSL.OpenSSL_Provider;
   Socket  : aliased Sockets.Socket_Type;
   Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
   Session : Client.Session (Channel'Access);
   Parse_Complete     : Natural := 0;
   Parameter_Description : Natural := 0;
   Row_Description   : Natural := 0;
   Bind_Complete     : Natural := 0;
   Rows              : Natural := 0;
   Command_Complete  : Natural := 0;
   Close_Complete    : Natural := 0;
   Ready             : Boolean := False;
begin
   Sockets.Create_Socket (Socket);
   Sockets.Connect
     (Socket,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port),
      Timeout => 5.0);
   if CA_File'Length > 0 then
      OpenSSL.Initialize_Client
        (TLS_Backend,
         CA_File => CA_File,
         Library_Directory => Ada.Environment_Variables.Value
           ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));
      Client.Startup_TLS
        (Session,
         TLS_Backend,
         Server_Name      => Server_Name,
         User             => "flyology",
         Database         => "flyology",
         Application_Name => "pgish_extended_client",
         Timeout          => 5.0);
   else
      Client.Startup
        (Session,
         User             => "flyology",
         Database         => "flyology",
         Application_Name => "pgish_extended_client",
         Timeout          => 5.0);
   end if;

   Client.Prepare_Statement
     (Session,
      "server_info",
      "SELECT protocol_version, task_mode FROM flyology_server_info",
      Timeout => 5.0);
   Client.Describe_Statement (Session, "server_info", Timeout => 5.0);
   Client.Bind_Portal
     (Session, "server_info_portal", "server_info", Timeout => 5.0);
   Client.Execute_Portal (Session, "server_info_portal", Timeout => 5.0);
   Client.Close_Portal (Session, "server_info_portal", Timeout => 5.0);
   Client.Close_Statement (Session, "server_info", Timeout => 5.0);
   Client.Synchronize (Session, Timeout => 5.0);

   while not Ready loop
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 5.0);
      begin
         case Protocol.Response_Kind (Event) is
            when Protocol.Parse_Complete_Response =>
               Parse_Complete := Parse_Complete + 1;
            when Protocol.Parameter_Description_Response =>
               Parameter_Description := Parameter_Description + 1;
            when Protocol.Row_Description_Response =>
               Row_Description := Row_Description + 1;
            when Protocol.Bind_Complete_Response =>
               Bind_Complete := Bind_Complete + 1;
            when Protocol.Data_Row_Response =>
               Rows := Rows + 1;
            when Protocol.Command_Complete_Response =>
               Command_Complete := Command_Complete + 1;
            when Protocol.Close_Complete_Response =>
               Close_Complete := Close_Complete + 1;
            when Protocol.Ready_For_Query_Response =>
               Ready := True;
            when Protocol.Error_Response =>
               raise Program_Error with
                 Protocol.Diagnostic_Message
                   (Protocol.Diagnostic_Data (Event));
            when others =>
               null;
         end case;
      end;
   end loop;

   if Parse_Complete /= 1
     or else Parameter_Description /= 1
     or else Row_Description /= 1
     or else Bind_Complete /= 1
     or else Rows /= 1
     or else Command_Complete /= 1
     or else Close_Complete /= 2
   then
      raise Program_Error with "unexpected extended-query response sequence";
   end if;
   Client.Send_Command
     (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
   Ada.Text_IO.Put_Line ("extended-query integration passed");
exception
   when Error : others =>
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Pgish_Extended_Client;
