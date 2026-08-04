with Flyology.IO.Connections.TLS;

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

   overriding procedure Upgrade_TLS
     (Item        : in out Connection_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
   begin
      Flyology.IO.Connections.TLS.Upgrade
        (Item.Channel.all,
         Backend,
         Flyology.IO.TLS.Client,
         Server_Name,
         Timeout => Timeout,
         Token   => Item.Token);
   end Upgrade_TLS;

end Flyology.Postgres.Transports.Connections;
