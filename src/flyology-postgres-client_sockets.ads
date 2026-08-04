with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.Postgres.Client;

package Flyology.Postgres.Client_Sockets is

   --  Open a separate socket, send Item's stored cancellation credentials,
   --  and close it without waiting for a response, as required by Postgres.
   procedure Cancel
     (Item    : Client.Session;
      Server  : Flyology.IO.Sockets.Endpoint;
      Timeout : Duration := 30.0);

   --  Open a separate socket, require TLS with the same verification name,
   --  send the stored cancellation credentials, and close silently.
   procedure Cancel_TLS
     (Item        : Client.Session;
      Server      : Flyology.IO.Sockets.Endpoint;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration := 30.0);

end Flyology.Postgres.Client_Sockets;
