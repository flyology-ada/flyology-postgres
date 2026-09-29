--  SERVER-7: Run_Session's catch-all handler
--  (src/flyology-postgres-server.adb:537-548) turns every non-Protocol_Error
--  exception into
--     FATAL / SQLSTATE XX000 / Ada.Exceptions.Exception_Message (Error)
--  which has two consequences on the wire:
--
--  (a) Forced handler cancellation -- what Request_Shutdown plus a finite
--      Drain_Timeout produces, via Read_Command raising Operation_Cancelled
--      -- reaches the catch-all, which tries to answer XX000.  That
--      Send_Error uses the SAME Handler_Stop token that was just requested,
--      so the write is cancelled too and the nested
--      "exception when others => null" swallows it: the peer is told
--      nothing at all and simply sees the connection drop.  PostgreSQL
--      reports an administrator-initiated disconnect as SQLSTATE 57P01
--      (ERRCODE_ADMIN_SHUTDOWN), "terminating connection due to
--      administrator command", which client libraries key their reconnect
--      logic on.
--
--  (b) The raw GNAT Exception_Message of any handler-raised
--      Constraint_Error / Storage_Error is forwarded verbatim to the peer.
--      With GNAT that text carries the source file name and line number of
--      the failing check, so server internals are disclosed to any peer,
--      including unauthenticated ones.
--
--  Correct behavior: administrator-initiated termination is reported as
--  57P01, and an internal Ada check failure does not put a server source
--  location on the wire.

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Client;
with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Flyology.Postgres.Transports.TLS_Sockets;
with Repro_Support; use Repro_Support;

procedure Repro_Server_7 is

   package Client renames Flyology.Postgres.Client;
   package Framing renames Flyology.Postgres.Framing;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package TLS_Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   use type Protocol.Frontend_Kind;

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

   Sink : Natural := 0;

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Command : Protocol.Message)
   is
      pragma Unreferenced (State, Client);
      Table : constant array (1 .. 2) of Natural := (10, 20);
      Index : Natural := 0;
   begin
      if Protocol.Kind (Command) = Protocol.Query then
         --  A genuine GNAT range check failure inside the application
         --  handler, exactly the class of bug whose message ends up on the
         --  wire.  Index is computed so the check cannot be folded away.
         Index := Sink + 5;
         Sink := Table (Index);
      end if;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.Trust,
      Startup_Timeout       => 5.0,
      Command_Timeout       => 30.0,
      Write_Timeout         => 5.0);

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
   Where    : Sockets.Endpoint;

   task Serve_Task;

   task body Serve_Task is
   begin
      Gate.Wait;
      Test_Server.Serve (Server, Listener, State, Drain_Timeout => 0.5);
   exception
      when E : others =>
         Note ("Serve raised " & Ada.Exceptions.Exception_Name (E));
   end Serve_Task;

   Leak_Socket   : aliased Sockets.Socket_Type;
   Admin_Socket  : aliased Sockets.Socket_Type;
   Leak_Channel  : aliased TLS_Transports.TLS_Socket_Transport
     (Leak_Socket'Access);
   Admin_Channel : aliased TLS_Transports.TLS_Socket_Transport
     (Admin_Socket'Access);

   procedure Start_Client
     (Socket  : in out Sockets.Socket_Type;
      Channel : in out TLS_Transports.TLS_Socket_Transport) is
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
   end Start_Client;

   Leak_State    : String (1 .. 5) := (others => ' ');
   Leak_Text     : String (1 .. 256) := (others => ' ');
   Leak_Length   : Natural := 0;
   Leak_Seen     : Boolean := False;

   Admin_State   : String (1 .. 5) := (others => ' ');
   Admin_Text    : String (1 .. 256) := (others => ' ');
   Admin_Length  : Natural := 0;
   Admin_Seen    : Boolean := False;

   procedure Capture
     (Channel : in out TLS_Transports.TLS_Socket_Transport;
      Code    : out String;
      Text    : out String;
      Length  : out Natural;
      Seen    : out Boolean) is
   begin
      Code := (others => ' ');
      Text := (others => ' ');
      Length := 0;
      Seen := False;
      loop
         declare
            Reply : constant Protocol.Message :=
              Framing.Read_Message (Channel, 5.0);
         begin
            if Protocol.Code (Reply) = 'E' then
               declare
                  Sql   : constant String := Client.SQL_State (Reply);
                  Detail : constant String := Client.Error_Message (Reply);
                  Count : constant Natural :=
                    Natural'Min (Detail'Length, Text'Length);
               begin
                  if Sql'Length = Code'Length then
                     Code := Sql;
                  end if;
                  Length := Count;
                  if Count > 0 then
                     Text (Text'First .. Text'First + Count - 1) :=
                       Detail (Detail'First .. Detail'First + Count - 1);
                  end if;
                  Seen := True;
                  return;
               end;
            end if;
         end;
      end loop;
   exception
      when E : others =>
         Note ("no ErrorResponse arrived: "
               & Ada.Exceptions.Exception_Name (E));
   end Capture;

begin
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener,
      Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
   Sockets.Listen_Socket (Listener, Length => 8);
   Where := Sockets.Get_Socket_Name (Listener);
   Gate.Open;
   delay 0.5;

   --  (b) an internal Ada check failure inside the application handler.
   Start_Client (Leak_Socket, Leak_Channel);
   declare
      Text  : constant String := "select 1";
      Query : Protocol.Byte_Array (1 .. Protocol.Byte_Offset (Text'Length + 1))
        := (others => 0);
   begin
      for Index in Text'Range loop
         Query (Protocol.Byte_Offset (Index - Text'First + 1)) :=
           Protocol.Byte (Character'Pos (Text (Index)));
      end loop;
      Framing.Write_Message
        (Leak_Channel, Protocol.Make_Message ('Q', Query), 3.0);
   end;
   Capture (Leak_Channel, Leak_State, Leak_Text, Leak_Length, Leak_Seen);
   Note ("handler Constraint_Error -> SQLSTATE " & Leak_State
         & " message """ & Leak_Text (1 .. Leak_Length) & """");

   --  (a) administrator-initiated shutdown of an idle session.
   Start_Client (Admin_Socket, Admin_Channel);
   Note ("administrator client is idle; calling Request_Shutdown");
   Test_Server.Request_Shutdown (Server);
   Capture (Admin_Channel, Admin_State, Admin_Text, Admin_Length, Admin_Seen);
   if Admin_Seen then
      Note ("forced shutdown -> SQLSTATE " & Admin_State
            & " message """ & Admin_Text (1 .. Admin_Length) & """");
   else
      Note ("forced shutdown -> no ErrorResponse reached the peer at all: "
            & "the XX000 Send_Error at server.adb:539-544 uses the same "
            & "cancelled Handler_Stop token and its failure is discarded "
            & "by the nested handler at :545-547");
   end if;

   Check
     (Leak_Seen
      and then Ada.Strings.Fixed.Index
        (Leak_Text (1 .. Leak_Length), ".adb:") = 0,
      "an internal Ada check failure in the handler does not put a server "
      & "source file and line number into the ErrorResponse sent to the "
      & "peer");
   Check
     (Admin_Seen and then Admin_State = "57P01",
      "a session terminated by Request_Shutdown is told SQLSTATE 57P01 "
      & "(ERRCODE_ADMIN_SHUTDOWN), as PostgreSQL does, instead of receiving "
      & "no diagnostic at all");

   if Sockets.Is_Open (Leak_Socket) then
      Sockets.Close_Socket (Leak_Socket);
   end if;
   if Sockets.Is_Open (Admin_Socket) then
      Sockets.Close_Socket (Admin_Socket);
   end if;

   Finish;
end Repro_Server_7;
