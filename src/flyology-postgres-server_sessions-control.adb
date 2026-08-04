package body Flyology.Postgres.Server_Sessions.Control is

   procedure Set_Operation_Cancellation
     (Item  : in out Session;
      Token : not null access Flyology.Cancellation.Token) is
   begin
      Item.Operation_Cancellation := Token.all'Unchecked_Access;
   end Set_Operation_Cancellation;

   procedure Clear_Operation_Cancellation (Item : in out Session) is
   begin
      Item.Operation_Cancellation := null;
   end Clear_Operation_Cancellation;

   procedure Set_Shutdown_Cancellation
     (Item  : in out Session;
      Token : not null access Flyology.Cancellation.Token) is
   begin
      Item.Shutdown_Cancellation := Token.all'Unchecked_Access;
   end Set_Shutdown_Cancellation;

end Flyology.Postgres.Server_Sessions.Control;
