with Flyology.Postgres.Transports.Sockets;

package body Flyology.Postgres.Client_Sockets is

   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

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

end Flyology.Postgres.Client_Sockets;
