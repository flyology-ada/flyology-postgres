with Ada.Streams;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;

package Flyology.Postgres.Transports.TLS_Sockets is
   --  Socket transport that starts in plaintext and can be upgraded to TLS.

   type TLS_Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
      --  Borrowed open socket.
   is limited new TLS_Upgradable_Transport with private;
   --  Starts by borrowing Socket as plaintext. Upgrade_TLS transfers Socket
   --  into the TLS connection, which then remains the sole closing owner.

   overriding procedure Receive_Exactly
     (Item    : in out TLS_Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null);
   --  Fill Data through the active plaintext or encrypted channel.  Without an
   --  observer the channel is read in one call.  With one, it is read in
   --  chunks under the same deadline so the observer runs between them, and
   --  may send on this transport before the buffer is full.
   --  @param Item Transport to read.
   --  @param Data Buffer filled with exactly Data'Length bytes.
   --  @param Timeout Maximum time allowed for the complete read.
   --  @param On_Wait Observer notified between chunks while Data fills.

   overriding procedure Send_All
     (Item    : in out TLS_Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);
   --  Write every byte of Data through the active channel.
   --  @param Item Transport to write.
   --  @param Data Complete buffer to transmit.
   --  @param Timeout Maximum time allowed for the complete write.

   overriding procedure Upgrade_TLS
     (Item        : in out TLS_Socket_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration);
   --  Transfer Socket into a verified TLS connection.
   --  @param Item Plaintext transport to upgrade exactly once.
   --  @param Backend TLS provider and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param Timeout Maximum time allowed for the handshake.
   --  @exception Program_Error Item has already been upgraded.

   function Is_Encrypted (Item : TLS_Socket_Transport) return Boolean;
   --  Report whether Upgrade_TLS completed successfully.
   --  @param Item Transport whose current mode is queried.
   --  @return True when subsequent traffic uses the TLS connection.

private
   type TLS_Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new TLS_Upgradable_Transport with record
      Secure    : Flyology.IO.TLS.Connection;
      Encrypted : Boolean := False;
   end record;

end Flyology.Postgres.Transports.TLS_Sockets;
