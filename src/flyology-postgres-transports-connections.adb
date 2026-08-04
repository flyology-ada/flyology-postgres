package body Flyology.Postgres.Transports.Connections is

   overriding procedure Receive_Exactly
     (Item    : in out Connection_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      Item.Channel.Receive_Exactly
        (Data, Timeout => Timeout, Token => Item.Token);
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Connection_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      Item.Channel.Send_All
        (Data, Timeout => Timeout, Token => Item.Token);
   end Send_All;

end Flyology.Postgres.Transports.Connections;
