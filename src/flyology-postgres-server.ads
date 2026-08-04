with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.IO.TLS;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server_Sessions;
with System.Multiprocessors;

generic
   type Handler_Context (<>) is limited private;

   with function Authenticate
     (Context  : in out Handler_Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean;

   with function Lookup_SCRAM_Verifier
     (Context : in out Handler_Context;
      Startup : Protocol.Startup_Information) return String;
   --  Return the Postgres rolpassword form
   --  SCRAM-SHA-256$iterations:salt$StoredKey:ServerKey, or "" when the
   --  startup user has no credential. Plaintext is never requested by the
   --  SCRAM authentication path.

   with procedure Handle
     (Context : in out Handler_Context;
      Client  : in out Server_Sessions.Session;
      Command : Protocol.Message);

   Authentication : Authentication_Method := Trust;
   Handler_Model   : Flyology.Execution_Model := Flyology.Project_Default;
   Handler_CPU     : System.Multiprocessors.CPU_Range :=
     System.Multiprocessors.Not_A_Specific_CPU;
   Startup_Timeout : Duration := 30.0;
   Command_Timeout : Duration := Flyology.IO.Infinite;
   Write_Timeout   : Duration := 30.0;

package Flyology.Postgres.Server is

   type Server (Capacity : Positive) is limited private;

   procedure Serve
     (Item          : aliased in out Server;
      Listener      : in out Flyology.IO.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Drain_Timeout : Duration := Flyology.IO.Infinite);

   --  Serve with PostgreSQL direct TLS negotiation. Allowed accepts both TLS
   --  and plaintext startup; Required rejects plaintext startup. Disabled is
   --  invalid here and is represented by the ordinary Serve overload.
   procedure Serve_TLS
     (Item          : aliased in out Server;
      Listener      : in out Flyology.IO.Sockets.Socket_Type;
      Context       : aliased in out Handler_Context;
      Backend       : aliased in out Flyology.IO.TLS.Provider'Class;
      Policy        : TLS_Policy := TLS_Required;
      Drain_Timeout : Duration := Flyology.IO.Infinite);

   procedure Request_Shutdown (Item : in out Server);

private
   Maximum_Secret_Length : constant := 32;
   subtype Secret_Length is Natural range 4 .. Maximum_Secret_Length;
   subtype Secret_Key is Protocol.Byte_Array
     (1 .. Protocol.Byte_Offset (Maximum_Secret_Length));

   type Credentials is record
      Process_Id : Protocol.UInt32 := 0;
      Secret     : Secret_Key := (others => 0);
      Length     : Secret_Length := 4;
   end record;

   type Token_Access is access all Flyology.Cancellation.Token;
   type Route_Entry is record
      Occupied      : Boolean := False;
      Key           : Credentials;
      Current_Token : Token_Access := null;
   end record;
   type Entry_Array is array (Positive range <>) of Route_Entry;

   type Registration_Status is (Registered, Collision, Full);

   protected type Registry (Capacity : Positive) is
      procedure Try_Register
        (Item : Credentials; Status : out Registration_Status);
      procedure Begin_Operation
        (Item       : Credentials;
         Token      : Token_Access;
         Registered : out Boolean);
      procedure End_Operation (Item : Credentials);
      procedure Remove (Item : Credentials);
      procedure Route
        (Process_Id : Protocol.UInt32;
         Secret     : Protocol.Byte_Array);
   private
      Entries : Entry_Array (1 .. Capacity);
   end Registry;

   procedure Generate
     (Item : out Credentials; Length : Secret_Length);

   type Handler_Context_Access is access all Handler_Context;
   type Registry_Access is access all Registry;
   type TLS_Provider_Access is access all Flyology.IO.TLS.Provider'Class;

   type Internal_Context is limited record
      Application : Handler_Context_Access;
      Router      : Registry_Access;
      TLS_Backend : TLS_Provider_Access := null;
      TLS_Mode    : TLS_Policy := TLS_Disabled;
   end record;

   procedure Process_Connection
     (Context      : in out Internal_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Cancellation : not null access Flyology.Cancellation.Token);

   package Structured is new Flyology.IO.Structured_Servers
     (Handler_Context => Internal_Context,
      Handle          => Process_Connection,
      Handler_Model   => Handler_Model,
      Handler_CPU     => Handler_CPU);

   type Structured_Access is access Structured.Server;

   protected type Inner_Holder is
      procedure Install
        (Value : Structured_Access; Stop_Already_Requested : out Boolean);
      procedure Request_Stop;
      procedure Clear (Value : Structured_Access);
   private
      Current        : Structured_Access := null;
      Stop_Requested : Boolean := False;
      Serve_Started  : Boolean := False;
   end Inner_Holder;

   type Server (Capacity : Positive) is limited record
      Router : aliased Registry (Capacity);
      Inner  : Inner_Holder;
   end record;

end Flyology.Postgres.Server;
