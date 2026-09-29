--  SERVER-1: the first Read_Initial runs in Run_Session's DECLARATIVE part
--  (src/flyology-postgres-server.adb:371-372), so an exception raised while
--  reading the very first packet propagates past Run_Session's own handlers
--  (:524-548) and past Process_Connection (:551-563), which has none.
--
--  The Flyology structured server treats an escaped handler exception as a
--  server failure: the worker's `when Event : others => Report (...)` calls
--  Record_Failure -- which moves the lifecycle Phase to Stop_Requested -- and
--  Stop_Accepting, so every worker leaves its accept loop and Serve raises
--  Server_Failed.  One client that connects and closes without sending a
--  byte (a TCP health probe, `nc -z`, a port scanner) therefore terminates
--  the whole server.
--
--  The identical Read_Initial inside the loop (:403) IS covered by the
--  handlers, so the design intent -- turn a client-caused failure into a
--  FATAL response and return normally -- is clear; the first read is the odd
--  one out.
--
--  Correct behavior: a client that connects and disconnects without sending
--  anything is dropped, the listener keeps accepting, and the next client is
--  served normally.

with Ada.Exceptions;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Server_1 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Frontend_Kind;

   type Context is limited record
      Served : Natural := 0;
   end record;

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
      pragma Unreferenced (Startup, Password);
   begin
      State.Served := State.Served + 1;
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
      pragma Unreferenced (State);
   begin
      if Protocol.Kind (Command) = Protocol.Query then
         Sessions.Send_Command_Complete (Client, "OK", 5.0);
         Sessions.Send_Ready (Client, Timeout => 5.0);
      end if;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.Trust,
      Startup_Timeout       => 5.0,
      Command_Timeout       => 5.0,
      Write_Timeout         => 5.0);

   protected Serve_Result is
      procedure Record_Failure (Text : String);
      procedure Mark_Returned;
      function Failure return String;
      function Returned return Boolean;
   private
      Stored   : String (1 .. 512) := (others => ' ');
      Length   : Natural := 0;
      Done     : Boolean := False;
   end Serve_Result;

   protected body Serve_Result is
      procedure Record_Failure (Text : String) is
         Count : constant Natural := Natural'Min (Text'Length, Stored'Length);
      begin
         Length := Count;
         if Count > 0 then
            Stored (1 .. Count) :=
              Text (Text'First .. Text'First + Count - 1);
         end if;
      end Record_Failure;

      procedure Mark_Returned is
      begin
         Done := True;
      end Mark_Returned;

      function Failure return String is (Stored (1 .. Length));
      function Returned return Boolean is (Done);
   end Serve_Result;

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

   Listener : Sockets.Socket_Type;
   State    : aliased Context;
   Server   : aliased Test_Server.Server (Capacity => 4);
   Endpoint : Sockets.Endpoint;

   task Serve_Task;

   task body Serve_Task is
   begin
      Gate.Wait;
      Test_Server.Serve (Server, Listener, State, Drain_Timeout => 1.0);
      Serve_Result.Mark_Returned;
   exception
      when E : others =>
         Serve_Result.Record_Failure
           (Ada.Exceptions.Exception_Name (E) & ": "
            & Ada.Exceptions.Exception_Message (E));
         Serve_Result.Mark_Returned;
   end Serve_Task;

   function Startup_Is_Answered (Label : String) return Boolean;

   function Startup_Is_Answered (Label : String) return Boolean is
      Client : Sockets.Socket_Type;
      Packet : constant Protocol.Byte_Array :=
        Protocol.Encode_Startup (User => "flyology", Database => "postgres");
      Reply  : Ada.Streams.Stream_Element_Array (1 .. 1);
   begin
      Sockets.Create_Socket (Client);
      Sockets.Connect (Client, Endpoint, Timeout => 2.0);
      Sockets.Send_All (Client, Packet, Timeout => 2.0);
      Sockets.Receive_Exactly (Client, Reply, Timeout => 3.0);
      Note (Label & " received a backend message tagged '"
            & Character'Val (Natural (Reply (Reply'First))) & "'");
      Sockets.Close_Socket (Client);
      return True;
   exception
      when E : others =>
         Note (Label & " failed: " & Ada.Exceptions.Exception_Name (E)
               & ": " & Ada.Exceptions.Exception_Message (E));
         if Sockets.Is_Open (Client) then
            Sockets.Close_Socket (Client);
         end if;
         return False;
   end Startup_Is_Answered;

   Control_Served : Boolean := False;
   Second_Client_Served : Boolean := False;

begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 8);
   Endpoint := Sockets.Get_Socket_Name (Listener);
   Note ("listening on 127.0.0.1:" & Sockets.Port'Image (Endpoint.Port));
   Gate.Open;

   delay 0.5;   --  let the workers reach Accept_Connection

   --  Control: an ordinary client BEFORE any misbehaving one, to show the
   --  harness itself works.
   Control_Served := Startup_Is_Answered ("control client");

   --  Probe 1: a bare TCP connect and immediate close, sending nothing.
   declare
      Probe : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket (Probe);
      Sockets.Connect (Probe, Endpoint, Timeout => 2.0);
      Sockets.Close_Socket (Probe);
      Note ("probe 1 connected and closed without sending a byte");
   end;

   delay 0.5;

   --  Probe 2: the same ordinary client, after the early close.
   Second_Client_Served := Startup_Is_Answered ("client after the probe");

   --  Let the server settle, then stop it if it is still running.
   Test_Server.Request_Shutdown (Server);
   for Wait in 1 .. 60 loop
      exit when Serve_Result.Returned;
      delay 0.1;
   end loop;

   if Serve_Result.Failure'Length > 0 then
      Note ("Serve terminated with " & Serve_Result.Failure);
   end if;

   Check
     (Control_Served,
      "control: an ordinary client is served before any misbehaving one "
      & "connects (harness sanity check)");
   Check
     (Second_Client_Served,
      "after a client connects and disconnects without sending anything, "
      & "the listener still serves the next connection");
   Check
     (Serve_Result.Failure'Length = 0,
      "a client that connects and closes early does not make Serve raise a "
      & "server failure");

   Finish;
end Repro_Server_1;
