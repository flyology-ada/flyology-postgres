package body Flyology.Postgres.Transports.Sockets is

   overriding procedure Receive_Exactly
     (Item    : in out Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      Flyology.IO.Sockets.Receive_Exactly
        (Item.Socket.all, Data, Timeout => Timeout);
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      Flyology.IO.Sockets.Send_All
        (Item.Socket.all, Data, Timeout => Timeout);
   end Send_All;

end Flyology.Postgres.Transports.Sockets;
