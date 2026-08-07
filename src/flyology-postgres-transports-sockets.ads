with Ada.Streams;
with Flyology.IO.Sockets;

package Flyology.Postgres.Transports.Sockets is
   --  PostgreSQL transport adapter for an already-open Flyology socket.

   type Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
      --  Borrowed open socket.
   is limited new Transport with private;
   --  Non-owning transport view of Socket.

   overriding procedure Receive_Exactly
     (Item    : in out Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null);
   --  Fill Data from Item's socket.
   --  @param Item Socket adapter to read.
   --  @param Data Buffer filled with exactly Data'Length bytes.
   --  @param Timeout Maximum time allowed for the complete read.

   overriding procedure Send_All
     (Item    : in out Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);
   --  Write every byte of Data to Item's socket.
   --  @param Item Socket adapter to write.
   --  @param Data Complete buffer to transmit.
   --  @param Timeout Maximum time allowed for the complete write.

private
   type Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new Transport with null record;

end Flyology.Postgres.Transports.Sockets;
