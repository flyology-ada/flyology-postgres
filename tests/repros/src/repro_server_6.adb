--  SERVER-6: two lifecycle contracts on Flyology.Postgres.Server drift from
--  the body.
--
--  (a) src/flyology-postgres-server.ads:87 documents
--        "@exception Constraint_Error Policy is TLS_Disabled."
--      but src/flyology-postgres-server.adb:622-625 raises Program_Error.
--      A caller that handles the documented exception does not catch the one
--      that is actually raised.
--
--  (b) src/flyology-postgres-server.ads:65 and :80-81 say
--        "Serve may be called only once at a time"
--      which permits sequential reuse, while
--      src/flyology-postgres-server.adb:184-186 enforces one-shot:
--        if Serve_Started then
--           raise Program_Error with "Postgres server is one-shot";
--      even though every Serve_Internal allocates a fresh Structured.Server.
--
--  Correct behavior: the exception identity matches the specification, and a
--  Serve that has returned may be started again.

with Ada.Exceptions;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Server_6 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;

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
      Authentication        => Flyology.Postgres.Trust);

   procedure Open_Listener (Socket : in out Sockets.Socket_Type) is
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Set_Socket_Option
        (Socket, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Socket, Length => 4);
   end Open_Listener;

   Provider : aliased Unused_Provider;

begin
   --  (a) documented Constraint_Error versus raised Program_Error.
   declare
      Listener : Sockets.Socket_Type;
      State    : aliased Context;
      Server   : aliased Test_Server.Server (Capacity => 2);
      Caught   : Boolean := False;
      Actual   : String (1 .. 128) := (others => ' ');
      Length   : Natural := 0;
   begin
      Open_Listener (Listener);
      begin
         Test_Server.Serve_TLS
           (Server, Listener, State, Provider,
            Policy => Flyology.Postgres.TLS_Disabled);
      exception
         when Constraint_Error =>
            Caught := True;
         when E : others =>
            declare
               Text : constant String :=
                 Ada.Exceptions.Exception_Name (E) & ": "
                 & Ada.Exceptions.Exception_Message (E);
               Count : constant Natural :=
                 Natural'Min (Text'Length, Actual'Length);
            begin
               Length := Count;
               Actual (1 .. Count) :=
                 Text (Text'First .. Text'First + Count - 1);
            end;
      end;
      Sockets.Close_Socket (Listener);

      if not Caught then
         Note ("Serve_TLS (Policy => TLS_Disabled) raised "
               & Actual (1 .. Length));
      end if;
      Check
        (Caught,
         "Serve_TLS with Policy => TLS_Disabled raises the Constraint_Error "
         & "its specification documents (server.ads:87)");
   end;

   --  (b) "only once at a time" versus one-shot.
   declare
      First_Listener  : Sockets.Socket_Type;
      Second_Listener : Sockets.Socket_Type;
      State           : aliased Context;
      Server          : aliased Test_Server.Server (Capacity => 2);
      First_Returned  : Boolean := False;
      Reused          : Boolean := False;
      Actual          : String (1 .. 128) := (others => ' ');
      Length          : Natural := 0;
   begin
      Open_Listener (First_Listener);
      Open_Listener (Second_Listener);

      --  Ask for shutdown first so the initial Serve returns promptly.
      Test_Server.Request_Shutdown (Server);
      begin
         Test_Server.Serve (Server, First_Listener, State);
         First_Returned := True;
      exception
         when E : others =>
            Note ("first Serve raised " & Ada.Exceptions.Exception_Name (E));
      end;

      begin
         Test_Server.Request_Shutdown (Server);
         Test_Server.Serve (Server, Second_Listener, State);
         Reused := True;
      exception
         when E : others =>
            declare
               Text : constant String :=
                 Ada.Exceptions.Exception_Name (E) & ": "
                 & Ada.Exceptions.Exception_Message (E);
               Count : constant Natural :=
                 Natural'Min (Text'Length, Actual'Length);
            begin
               Length := Count;
               Actual (1 .. Count) :=
                 Text (Text'First .. Text'First + Count - 1);
            end;
      end;

      if Sockets.Is_Open (Second_Listener) then
         Sockets.Close_Socket (Second_Listener);
      end if;

      Check
        (First_Returned,
         "control: the first Serve returns cleanly after Request_Shutdown");
      if not Reused then
         Note ("the second sequential Serve raised " & Actual (1 .. Length));
      end if;
      Check
        (Reused,
         "a Server whose Serve has returned can be served again, as "
         & "'Serve may be called only once at a time' (server.ads:65) says");
   end;

   Finish;
end Repro_Server_6;
