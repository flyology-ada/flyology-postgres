with Ada.Streams;
with Flyology.IO.TLS;

package Flyology.Postgres.Transports is
   --  Abstract byte transports used by the PostgreSQL client and server.
   --  Implementations must transfer the complete requested buffer or raise an
   --  exception; partial transfers are not exposed to protocol code.

   type Transport is limited interface;
   --  Bidirectional, blocking byte channel for PostgreSQL wire messages.

   procedure Receive_Exactly
     (Item    : in out Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is abstract;
   --  Fill Data with exactly Data'Length bytes received from Item.
   --  @param Item Channel from which bytes are read.
   --  @param Data Buffer filled before the operation returns.
   --  @param Timeout Maximum time allowed for the complete transfer.
   --  @exception Flyology.IO.Timeout_Error The deadline expires first.

   procedure Send_All
     (Item    : in out Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is abstract;
   --  Send every byte of Data in array order.
   --  @param Item Channel to which bytes are written.
   --  @param Data Complete buffer to transmit.
   --  @param Timeout Maximum time allowed for the complete transfer.
   --  @exception Flyology.IO.Timeout_Error The deadline expires first.

   type TLS_Upgradable_Transport is limited interface and Transport;
   --  Plain transport that can transfer its underlying channel into TLS.

   procedure Upgrade_TLS
     (Item        : in out TLS_Upgradable_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is abstract;
   --  Replace Item's plaintext channel with an authenticated TLS connection.
   --  @param Item Transport to upgrade in place.
   --  @param Backend TLS implementation and trust configuration to use.
   --  @param Server_Name DNS name checked during certificate verification.
   --  @param Timeout Maximum time allowed for the TLS handshake.
   --  @exception Flyology.IO.TLS.TLS_Error The handshake or verification
   --     fails.

end Flyology.Postgres.Transports;
