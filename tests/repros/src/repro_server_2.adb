--  SERVER-2: with Policy => TLS_Required, Run_Session applies the TLS gate
--  BEFORE it looks at the initial request's kind
--  (src/flyology-postgres-server.adb:406-419), so a plaintext CancelRequest
--  is answered with FATAL 08004 "TLS is required" and never reaches
--  Context.Router.Route.
--
--  PostgreSQL handles cancellation first and unconditionally:
--  ProcessStartupPacket (src/backend/tcop/backend_startup.c:575-580) does
--     if (proto == CANCEL_REQUEST_CODE)
--     {  ProcessCancelRequestPacket(port, buf, len); goto fail; }
--  before any NEGOTIATE_SSL_CODE handling and with no hostssl-style gate,
--  because a cancel packet carries no credential beyond the secret key.
--
--  This matters because psql's Ctrl-C still uses the legacy plaintext path:
--  src/fe_utils/cancel.c handle_sigint calls PQcancel(cancelConn, ...), and
--  PQcancel is documented in src/interfaces/libpq/fe-cancel.c as the "old,
--  non-encrypted, but signal-safe way of requesting query cancel" -- it
--  opens a bare socket and writes the cancel packet with no SSLRequest.
--  (Verified in the PostgreSQL tree at REL_18_BETA1-2983-g9fd46ee9347.)
--
--  Correct behavior: a plaintext CancelRequest is routed and the connection
--  is closed silently, exactly as under TLS_Allowed.

with Ada.Exceptions;
with Ada.Streams;
with Flyology;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Server_2 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

   use type Ada.Streams.Stream_Element_Offset;

   --  A provider that is never exercised: no SSLRequest is ever sent here,
   --  so Serve_TLS only needs an object to hold.
   type Unused_Provider is limited new TLS.Provider with null record;

   overriding function Retain
     (Item : in out Unused_Provider) return TLS.Provider_Access;
   overriding function Name (Item : Unused_Provider) return String;
   overriding function Is_Available (Item : Unused_Provider) return Boolean;
   overriding function Create_Session
     (Item        : in out Unused_Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String) return TLS.Session_Access;

   overriding function Retain
     (Item : in out Unused_Provider) return TLS.Provider_Access is
      pragma Unreferenced (Item);
   begin
      raise Program_Error with "the repro provider is never used";
      return null;
   end Retain;

   overriding function Name (Item : Unused_Provider) return String is
      pragma Unreferenced (Item);
   begin
      return "repro-stub";
   end Name;

   overriding function Is_Available (Item : Unused_Provider) return Boolean is
      pragma Unreferenced (Item);
   begin
      return True;
   end Is_Available;

   overriding function Create_Session
     (Item        : in out Unused_Provider;
      FD          : Flyology.IO.Descriptor;
      Side        : TLS.Role;
      Server_Name : String) return TLS.Session_Access
   is
      pragma Unreferenced (Item, FD, Side, Server_Name);
   begin
      raise Program_Error with "the repro provider is never used";
      return null;
   end Create_Session;

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

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.Trust,
      Startup_Timeout       => 5.0,
      Command_Timeout       => 5.0,
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

   Required_Listener : Sockets.Socket_Type;
   Allowed_Listener  : Sockets.Socket_Type;
   Required_State    : aliased Context;
   Allowed_State     : aliased Context;
   Required_Server   : aliased Test_Server.Server (Capacity => 2);
   Allowed_Server    : aliased Test_Server.Server (Capacity => 2);
   Provider          : aliased Unused_Provider;
   Required_Endpoint : Sockets.Endpoint;
   Allowed_Endpoint  : Sockets.Endpoint;

   task Required_Task;
   task Allowed_Task;

   task body Required_Task is
   begin
      Gate.Wait;
      Test_Server.Serve_TLS
        (Required_Server, Required_Listener, Required_State, Provider,
         Policy        => Flyology.Postgres.TLS_Required,
         Drain_Timeout => 1.0);
   exception
      when E : others =>
         Note ("TLS_Required Serve_TLS ended with "
               & Ada.Exceptions.Exception_Name (E));
   end Required_Task;

   task body Allowed_Task is
   begin
      Gate.Wait;
      Test_Server.Serve_TLS
        (Allowed_Server, Allowed_Listener, Allowed_State, Provider,
         Policy        => Flyology.Postgres.TLS_Allowed,
         Drain_Timeout => 1.0);
   exception
      when E : others =>
         Note ("TLS_Allowed Serve_TLS ended with "
               & Ada.Exceptions.Exception_Name (E));
   end Allowed_Task;

   Secret : constant Protocol.Byte_Array (1 .. 4) := (16#DE#, 16#AD#, 16#BE#,
                                                      16#EF#);

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

   --  Send a plaintext CancelRequest and report what came back, if anything.
   function Plaintext_Cancel_Reply (Where : Sockets.Endpoint) return String is
      Socket : Sockets.Socket_Type;
      Data   : Ada.Streams.Stream_Element_Array (1 .. 256);
      Last   : Ada.Streams.Stream_Element_Offset;
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Where, Timeout => 2.0);
      Sockets.Send_All
        (Socket,
         Protocol.Encode_Cancel_Request (12_345, Secret),
         Timeout => 2.0);
      Sockets.Receive (Socket, Data, Last, Timeout => 3.0);
      if Last < Data'First then
         Sockets.Close_Socket (Socket);
         return "<silent close>";
      end if;
      declare
         Reply : constant Protocol.Byte_Array :=
           Protocol.Byte_Array (Data (Data'First .. Last));
      begin
         Sockets.Close_Socket (Socket);
         return Hex (Reply) & "  (" & S (Reply) & ")";
      end;
   exception
      when Flyology.IO.Device_Error =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         return "<silent close>";
      when E : others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         return "<" & Ada.Exceptions.Exception_Name (E) & ">";
   end Plaintext_Cancel_Reply;

begin
   Open_Listener (Required_Listener, Required_Endpoint);
   Open_Listener (Allowed_Listener, Allowed_Endpoint);
   Gate.Open;
   delay 0.5;

   declare
      Allowed_Reply  : constant String :=
        Plaintext_Cancel_Reply (Allowed_Endpoint);
      Required_Reply : constant String :=
        Plaintext_Cancel_Reply (Required_Endpoint);
   begin
      Note ("Policy => TLS_Allowed,  plaintext CancelRequest -> "
            & Allowed_Reply);
      Note ("Policy => TLS_Required, plaintext CancelRequest -> "
            & Required_Reply);

      Check
        (Allowed_Reply = "<silent close>",
         "control: under TLS_Allowed a plaintext CancelRequest is routed "
         & "and the connection closes silently");
      Check
        (Required_Reply = "<silent close>",
         "under TLS_Required a plaintext CancelRequest is still routed and "
         & "closed silently, as PostgreSQL handles CANCEL_REQUEST_CODE "
         & "before any SSL negotiation");

      if Required_Reply /= "<silent close>" then
         Note ("psql's Ctrl-C (fe_utils/cancel.c -> PQcancel, the 'old, "
               & "non-encrypted, signal-safe' path) therefore never cancels "
               & "anything against a TLS_Required server");
      end if;
   end;

   Test_Server.Request_Shutdown (Required_Server);
   Test_Server.Request_Shutdown (Allowed_Server);

   Finish;
end Repro_Server_2;
