with Flyology.Cancellation;

package Flyology.Postgres.Server_Sessions.Control is

   procedure Set_Operation_Cancellation
     (Item  : in out Session;
      Token : not null access Flyology.Cancellation.Token);

   procedure Clear_Operation_Cancellation (Item : in out Session);

   procedure Set_Shutdown_Cancellation
     (Item  : in out Session;
      Token : not null access Flyology.Cancellation.Token);

end Flyology.Postgres.Server_Sessions.Control;
