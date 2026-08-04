with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server_Sessions;
with System.Multiprocessors;

generic
   type Handler_Context (<>) is limited private;

   with function Authenticate
     (Context  : in out Handler_Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean;

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

   procedure Request_Shutdown (Item : in out Server);

private
   procedure Process_Connection
     (Context      : in out Handler_Context;
      Connection   : in out Flyology.IO.Connections.Connection;
      Peer         : Flyology.IO.Sockets.Endpoint;
      Cancellation : not null access Flyology.Cancellation.Token);

   package Structured is new Flyology.IO.Structured_Servers
     (Handler_Context => Handler_Context,
      Handle          => Process_Connection,
      Handler_Model   => Handler_Model,
      Handler_CPU     => Handler_CPU);

   type Server (Capacity : Positive) is limited record
      Inner : aliased Structured.Server (Capacity);
   end record;

end Flyology.Postgres.Server;
