with Ada.Streams;
with Flyology.IO.Sockets;

package Flyology.Postgres.Transports.Sockets is

   type Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new Transport with private;

   overriding procedure Receive_Exactly
     (Item    : in out Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Send_All
     (Item    : in out Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

private
   type Socket_Transport
     (Socket : not null access Flyology.IO.Sockets.Socket_Type)
   is limited new Transport with null record;

end Flyology.Postgres.Transports.Sockets;
