package body Flyology.Postgres.Transports.TLS_Sockets is

   overriding procedure Receive_Exactly
     (Item    : in out TLS_Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      if Item.Encrypted then
         Flyology.IO.TLS.Receive_Exactly
           (Item.Secure, Data, Timeout => Timeout);
      else
         Flyology.IO.Sockets.Receive_Exactly
           (Item.Socket.all, Data, Timeout => Timeout);
      end if;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out TLS_Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      if Item.Encrypted then
         Flyology.IO.TLS.Send_All
           (Item.Secure, Data, Timeout => Timeout);
      else
         Flyology.IO.Sockets.Send_All
           (Item.Socket.all, Data, Timeout => Timeout);
      end if;
   end Send_All;

   overriding procedure Upgrade_TLS
     (Item        : in out TLS_Socket_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
   begin
      if Item.Encrypted or else Flyology.IO.TLS.Is_Open (Item.Secure) then
         raise Program_Error with "Postgres transport already uses TLS";
      end if;
      Flyology.IO.TLS.Take
        (Backend,
         Item.Socket.all,
         Flyology.IO.TLS.Client,
         Server_Name,
         Item.Secure);
      begin
         Flyology.IO.TLS.Handshake (Item.Secure, Timeout => Timeout);
         Item.Encrypted := True;
      exception
         when others =>
            Flyology.IO.TLS.Close (Item.Secure);
            raise;
      end;
   end Upgrade_TLS;

   function Is_Encrypted (Item : TLS_Socket_Transport) return Boolean is
     (Item.Encrypted);

end Flyology.Postgres.Transports.TLS_Sockets;
