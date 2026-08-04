with Ada.Streams;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;

package Flyology.Postgres.Transports.TLS_Sockets is

   --  Starts by borrowing Socket as plaintext. Upgrade_TLS transfers Socket
   --  into the TLS connection, which then remains the sole closing owner.
   type TLS_Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new TLS_Upgradable_Transport with private;

   overriding procedure Receive_Exactly
     (Item    : in out TLS_Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Send_All
     (Item    : in out TLS_Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Upgrade_TLS
     (Item        : in out TLS_Socket_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration);

   function Is_Encrypted (Item : TLS_Socket_Transport) return Boolean;

private
   type TLS_Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new TLS_Upgradable_Transport with record
      Secure    : Flyology.IO.TLS.Connection;
      Encrypted : Boolean := False;
   end record;

end Flyology.Postgres.Transports.TLS_Sockets;
