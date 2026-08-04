with Ada.Streams;
with Flyology.Cancellation;
with Flyology.IO.Connections;

package Flyology.Postgres.Transports.Connections is

   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection;
      Token   : access Flyology.Cancellation.Token)
   is limited new Transport with private;

   overriding procedure Receive_Exactly
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

private
   type Connection_Transport
     (Channel : not null access Flyology.IO.Connections.Connection;
      Token   : access Flyology.Cancellation.Token)
   is limited new Transport with null record;

end Flyology.Postgres.Transports.Connections;
