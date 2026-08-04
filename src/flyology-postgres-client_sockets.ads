with Flyology.IO.Sockets;
with Flyology.Postgres.Client;

package Flyology.Postgres.Client_Sockets is

   --  Open a separate socket, send Item's stored cancellation credentials,
   --  and close it without waiting for a response, as required by Postgres.
   procedure Cancel
     (Item    : Client.Session;
      Server  : Flyology.IO.Sockets.Endpoint;
      Timeout : Duration := 30.0);

end Flyology.Postgres.Client_Sockets;
