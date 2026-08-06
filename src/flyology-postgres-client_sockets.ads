with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.Postgres.Client;

package Flyology.Postgres.Client_Sockets is
   --  Convenience operations for cancelling socket-backed client sessions.

   procedure Cancel
     (Item    : Client.Session;
      Server  : Flyology.IO.Sockets.Endpoint;
      Timeout : Duration := 30.0);
   --  Open a separate socket, send Item's stored cancellation credentials,
   --  and close it without waiting for a response, as required by PostgreSQL.
   --  @param Item Active session whose backend key data is sent.
   --  @param Server Endpoint of the same PostgreSQL server.
   --  @param Timeout Maximum time allowed to connect and send the packet.

   procedure Cancel_TLS
     (Item        : Client.Session;
      Server      : Flyology.IO.Sockets.Endpoint;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration := 30.0);
   --  Open a separate socket, require TLS with the same verification name,
   --  send Item's cancellation credentials, and close without reading.
   --  @param Item Active session whose backend key data is sent.
   --  @param Server Endpoint of the same PostgreSQL server.
   --  @param Backend TLS provider and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param Timeout Maximum time allowed to connect, negotiate, and send.

end Flyology.Postgres.Client_Sockets;
