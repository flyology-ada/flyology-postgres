with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server_Sessions;
with Introspection_State;

package Introspection_Handler is

   function Authenticate
     (Context  : in out Introspection_State.Server_State;
      Startup  : Flyology.Postgres.Protocol.Startup_Information;
      Password : String) return Boolean;

   function Lookup_SCRAM_Verifier
     (Context : in out Introspection_State.Server_State;
      Startup : Flyology.Postgres.Protocol.Startup_Information) return String;

   procedure Handle
     (Context : in out Introspection_State.Server_State;
      Client  : in out Flyology.Postgres.Server_Sessions.Session;
      Command : Flyology.Postgres.Protocol.Message);

end Introspection_Handler;
