with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;
with Flyology.Postgres.Transports.TLS_Sockets;

package body Flyology.Postgres.Client_Sockets is

   package Sockets renames Flyology.IO.Sockets;
   package Protocol renames Flyology.Postgres.Protocol;
   package Transports renames Flyology.Postgres.Transports.Sockets;
   package TLS_Transports renames
     Flyology.Postgres.Transports.TLS_Sockets;

   use type Protocol.Byte;

   procedure Cancel
     (Item    : Client.Session;
      Server  : Sockets.Endpoint;
      Timeout : Duration := 30.0) is
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
   begin
      Sockets.Create_Socket (Socket, Family => Server.Family);
      Sockets.Connect (Socket, Server, Timeout => Timeout);
      Client.Send_Cancel_Request (Item, Channel, Timeout);
      Sockets.Close_Socket (Socket);
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Cancel;

   procedure Cancel_TLS
     (Item        : Client.Session;
      Server      : Sockets.Endpoint;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration := 30.0) is
      Socket   : aliased Sockets.Socket_Type;
      Channel  : aliased TLS_Transports.TLS_Socket_Transport
        (Socket'Access);
      Response : Protocol.Byte_Array (1 .. 1);
   begin
      if Server_Name'Length = 0 then
         raise Program_Error with
           "Postgres TLS cancellation requires a server name";
      end if;
      Sockets.Create_Socket (Socket, Family => Server.Family);
      Sockets.Connect (Socket, Server, Timeout => Timeout);
      Flyology.Postgres.Framing.Write_Packet
        (Channel, Protocol.Encode_SSL_Request, Timeout);
      Channel.Receive_Exactly (Response, Timeout);
      if Response (Response'First) /=
        Protocol.Byte (Character'Pos ('S'))
      then
         raise Client.TLS_Not_Available with
           "Postgres cancellation server refused TLS";
      end if;
      Channel.Upgrade_TLS (Backend, Server_Name, Timeout);
      Client.Send_Cancel_Request (Item, Channel, Timeout);
      --  The cancellation protocol has no response. Finalization closes the
      --  TLS connection without waiting for a bidirectional shutdown.
   exception
      when others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         raise;
   end Cancel_TLS;

end Flyology.Postgres.Client_Sockets;
