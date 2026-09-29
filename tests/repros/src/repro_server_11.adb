--  SERVER-11: Request_Shutdown is documented as "Request listener shutdown
--  and cancellation of active connection work"
--  (src/flyology-postgres-server.ads:89-92), but with the DEFAULT
--  Drain_Timeout => Flyology.IO.Infinite (:63, :76) no handler is ever
--  cancelled, so a single idle client keeps Serve from returning.
--
--  In the Flyology runtime, Request_Shutdown only requests Accept_Stop
--  (flyology-io-structured_servers.adb:184-191).  Handler_Stop is requested
--  by Force_Handlers (:230-235), which runs only from the
--  `delay Drain_Timeout` branch of Serve (:512-521); when Drain_Timeout is
--  Infinite, Serve waits in Await_All_Workers unconditionally.  A session
--  parked in Read_Command (Client, Command_Timeout) -- also Infinite by
--  default (server.ads:37) -- never observes the request.
--
--  Correct behavior: after Request_Shutdown, Serve returns within a bounded
--  time even though a connected client is idle.

with Ada.Exceptions;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Flyology.Postgres.Transports.TLS_Sockets;
with Repro_Support; use Repro_Support;

procedure Repro_Server_11 is

   package Framing renames Flyology.Postgres.Framing;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package TLS_Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   Bounded_Wait : constant Duration := 5.0;
   --  How long a caller is willing to wait for a requested shutdown.

   type Context is limited null record;

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean;
   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String;
   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Command : Protocol.Message);

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean
   is
      pragma Unreferenced (State, Startup, Password);
   begin
      return True;
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String
   is
      pragma Unreferenced (State, Startup);
   begin
      return "";
   end Lookup_SCRAM_Verifier;

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Command : Protocol.Message)
   is
      pragma Unreferenced (State, Client, Command);
   begin
      null;
   end Handle;

   --  Command_Timeout and Write_Timeout keep their package defaults so this
   --  is the configuration an application gets without saying anything.
   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.Trust);

   protected type Completion is
      procedure Mark;
      function Done return Boolean;
   private
      Value : Boolean := False;
   end Completion;

   protected body Completion is
      procedure Mark is
      begin
         Value := True;
      end Mark;
      function Done return Boolean is (Value);
   end Completion;

   protected Gate is
      procedure Open;
      entry Wait;
   private
      Ready : Boolean := False;
   end Gate;

   protected body Gate is
      procedure Open is
      begin
         Ready := True;
      end Open;
      entry Wait when Ready is
      begin
         null;
      end Wait;
   end Gate;

   Control_Listener : Sockets.Socket_Type;
   Default_Listener : Sockets.Socket_Type;
   Control_State    : aliased Context;
   Default_State    : aliased Context;
   Control_Server   : aliased Test_Server.Server (Capacity => 2);
   Default_Server   : aliased Test_Server.Server (Capacity => 2);
   Control_Where    : Sockets.Endpoint;
   Default_Where    : Sockets.Endpoint;
   Control_Done     : Completion;
   Default_Done     : Completion;

   task Control_Task;
   task Default_Task;

   task body Control_Task is
   begin
      Gate.Wait;
      --  Explicit finite drain: the documented cancellation does happen.
      Test_Server.Serve
        (Control_Server, Control_Listener, Control_State,
         Drain_Timeout => 1.0);
      Control_Done.Mark;
   exception
      when E : others =>
         Note ("control Serve raised " & Ada.Exceptions.Exception_Name (E));
         Control_Done.Mark;
   end Control_Task;

   task body Default_Task is
   begin
      Gate.Wait;
      --  Drain_Timeout left at its documented default of Infinite.
      Test_Server.Serve (Default_Server, Default_Listener, Default_State);
      Default_Done.Mark;
   exception
      when E : others =>
         Note ("default Serve raised " & Ada.Exceptions.Exception_Name (E));
         Default_Done.Mark;
   end Default_Task;

   procedure Open_Listener
     (Socket : in out Sockets.Socket_Type; Where : out Sockets.Endpoint) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Set_Socket_Option
        (Socket, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Socket, Length => 4);
      Where := Sockets.Get_Socket_Name (Socket);
   end Open_Listener;

   Control_Socket  : aliased Sockets.Socket_Type;
   Default_Socket  : aliased Sockets.Socket_Type;
   Control_Channel : aliased TLS_Transports.TLS_Socket_Transport
     (Control_Socket'Access);
   Default_Channel : aliased TLS_Transports.TLS_Socket_Transport
     (Default_Socket'Access);

   procedure Start_Idle_Client
     (Socket  : in out Sockets.Socket_Type;
      Channel : in out TLS_Transports.TLS_Socket_Transport;
      Where   : Sockets.Endpoint;
      Label   : String) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Where, Timeout => 3.0);
      Framing.Write_Packet
        (Channel,
         Protocol.Encode_Startup (User => "flyology", Database => "postgres"),
         Timeout => 3.0);
      loop
         declare
            Reply : constant Protocol.Message :=
              Framing.Read_Message (Channel, 3.0);
         begin
            exit when Protocol.Code (Reply) = 'Z';
         end;
      end loop;
      Note (Label & " reached ReadyForQuery and is now idle");
   end Start_Idle_Client;

   function Wait_For (Item : Completion; Limit : Duration) return Boolean is
      Steps : constant Natural := Natural (Limit / 0.1);
   begin
      for Step in 1 .. Steps loop
         if Item.Done then
            return True;
         end if;
         delay 0.1;
      end loop;
      return Item.Done;
   end Wait_For;

   Control_Returned : Boolean;
   Default_Returned : Boolean;

begin
   Open_Listener (Control_Listener, Control_Where);
   Open_Listener (Default_Listener, Default_Where);
   Gate.Open;
   delay 0.5;

   Start_Idle_Client
     (Control_Socket, Control_Channel, Control_Where, "control client");
   Start_Idle_Client
     (Default_Socket, Default_Channel, Default_Where, "default client");

   Note ("calling Request_Shutdown on both servers while both clients idle");
   Test_Server.Request_Shutdown (Control_Server);
   Test_Server.Request_Shutdown (Default_Server);

   Control_Returned := Wait_For (Control_Done, Bounded_Wait);
   Default_Returned := Wait_For (Default_Done, Bounded_Wait);

   Note ("Drain_Timeout => 1.0        : Serve returned within"
         & Duration'Image (Bounded_Wait) & "s -> "
         & Boolean'Image (Control_Returned));
   Note ("Drain_Timeout => default    : Serve returned within"
         & Duration'Image (Bounded_Wait) & "s -> "
         & Boolean'Image (Default_Returned));

   Check
     (Control_Returned,
      "control: with an explicit finite Drain_Timeout, Request_Shutdown "
      & "cancels the idle session and Serve returns");
   Check
     (Default_Returned,
      "with the documented default Drain_Timeout, Request_Shutdown also "
      & "cancels active connection work and Serve returns "
      & "(server.ads:89-90)");

   if not Default_Returned then
      Note ("Serve is still blocked in Await_All_Workers; only closing the "
            & "client releases it");
   end if;

   --  Release both servers so the program can terminate.
   if Sockets.Is_Open (Control_Socket) then
      Sockets.Close_Socket (Control_Socket);
   end if;
   if Sockets.Is_Open (Default_Socket) then
      Sockets.Close_Socket (Default_Socket);
   end if;

   if not Wait_For (Default_Done, 10.0) then
      Note ("default Serve still has not returned after the client closed");
   end if;

   Finish;
end Repro_Server_11;
