--  SCRAM-1: the server's mock SCRAM exchange for a role with no verifier
--  uses one fixed salt compiled into the library source, so an
--  unauthenticated client learns from AuthenticationSASLContinue whether the
--  startup role exists.
--
--  Location: src/flyology-postgres-server.adb:28-35 declares
--     Dummy_SCRAM_Verifier : constant String :=
--       "SCRAM-SHA-256$4096:Zml4ZWQgZHVtbXkgc2FsdA==$...";
--  (Zml4ZWQgZHVtbXkgc2FsdA== is base64 of the 16 octets "fixed dummy salt")
--  and Admit (:286-295) parses it whenever Lookup_SCRAM_Verifier returns "".
--  Server_First_Message (src/flyology-postgres-scram.adb:439-448) emits
--  Credential.Encoded_Salt verbatim, so the constant reaches the wire before
--  any proof is exchanged.
--
--  PostgreSQL does not do this.  auth-scram.c builds a mock secret with
--  mock_scram_secret, whose salt comes from scram_mock_salt: a SHA-256 over
--  the role name and the per-cluster mock_authentication_nonce, truncated to
--  the default salt length.  Two unknown roles therefore get two different,
--  unpredictable salts, and neither is distinguishable from a real one.
--
--  Correct behavior asserted below: two distinct unknown roles receive
--  different salts, and an unknown role's salt is not the constant published
--  in this library's source.

with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Scram_1 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package SCRAM renames Flyology.Postgres.SCRAM;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_Element_Array;

   Known_Role : constant String := "known";
   Known_Salt_Text : constant String := "Flyology test salt";
   --  18 octets, so its base64 form carries no padding and is obviously not
   --  the library's own dummy salt.

   Published_Dummy_Salt : constant String := "Zml4ZWQgZHVtbXkgc2FsdA==";
   --  Copied verbatim from src/flyology-postgres-server.adb:32.

   ------------------------------------------------------------------
   --  Server under test.
   ------------------------------------------------------------------

   type Context is limited record
      Lookups : Natural := 0;
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
      pragma Unreferenced (State, Startup, Password);
   begin
      return False;
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String is
   begin
      State.Lookups := State.Lookups + 1;
      if To_String (Startup.User) = Known_Role then
         return SCRAM.Make_Verifier_Raw
           ("secret", SCRAM.To_Bytes (Known_Salt_Text));
      else
         return "";
      end if;
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
      Authentication        => Flyology.Postgres.SCRAM_SHA_256,
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

   Listener : Sockets.Socket_Type;
   State    : aliased Context;
   Server   : aliased Test_Server.Server (Capacity => 4);
   Endpoint : Sockets.Endpoint;

   task Serve_Task;

   task body Serve_Task is
   begin
      Gate.Wait;
      Test_Server.Serve (Server, Listener, State, Drain_Timeout => 1.0);
   exception
      when Error : others =>
         Note
           ("Serve terminated with " & Ada.Exceptions.Exception_Name (Error)
            & ": " & Ada.Exceptions.Exception_Message (Error));
   end Serve_Task;

   ------------------------------------------------------------------
   --  A minimal SCRAM client speaking raw protocol bytes.
   ------------------------------------------------------------------

   function Attribute (Text : String; Name : Character) return String is
      Padded : constant String := "," & Text;
      Marker : constant Natural :=
        Ada.Strings.Fixed.Index (Padded, "," & Name & "=");
   begin
      if Marker = 0 then
         return "";
      end if;
      declare
         Start : constant Natural := Marker + 3;
         Stop  : Natural :=
           Ada.Strings.Fixed.Index (Padded, ",", From => Start);
      begin
         if Stop = 0 then
            Stop := Padded'Last + 1;
         end if;
         return Padded (Start .. Stop - 1);
      end;
   end Attribute;

   function Frame (Tag : Character; Payload : String)
     return Protocol.Byte_Array is
      Length : constant Natural := 4 + Payload'Length;
   begin
      return
        Protocol.Byte_Array'
          (1 => Protocol.Byte (Character'Pos (Tag)),
           2 => Protocol.Byte (Length / 16_777_216 mod 256),
           3 => Protocol.Byte (Length / 65_536 mod 256),
           4 => Protocol.Byte (Length / 256 mod 256),
           5 => Protocol.Byte (Length mod 256))
        & B (Payload);
   end Frame;

   procedure Read_Backend
     (Sock : in out Sockets.Socket_Type;
      Tag  : out Character;
      Text : out Unbounded_String) is
      Header : Ada.Streams.Stream_Element_Array (1 .. 5);
   begin
      Sockets.Receive_Exactly (Sock, Header, Timeout => 5.0);
      Tag := Character'Val (Natural (Header (1)));
      declare
         Length : constant Natural :=
           Natural (Header (2)) * 16_777_216
           + Natural (Header (3)) * 65_536
           + Natural (Header (4)) * 256
           + Natural (Header (5));
         Remaining : Ada.Streams.Stream_Element_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Length) - 4);
      begin
         if Remaining'Length > 0 then
            Sockets.Receive_Exactly (Sock, Remaining, Timeout => 5.0);
         end if;
         Text := To_Unbounded_String (S (Remaining));
      end;
   end Read_Backend;

   procedure Mock_Exchange
     (User         : String;
      Salt         : out Unbounded_String;
      Iterations   : out Unbounded_String;
      Succeeded    : out Boolean) is
      Sock : Sockets.Socket_Type;
      Nonce : constant String := "rOprNGfwEbeRWgbNEkqO";
      Client_First : constant String := "n,,n=,r=" & Nonce;
      Bogus_Proof : constant String :=
        SCRAM.Base64_Encode (SCRAM.Byte_Array'(1 .. 32 => 0));
      Tag : Character;
      Text : Unbounded_String;
   begin
      Salt := Null_Unbounded_String;
      Iterations := Null_Unbounded_String;
      Succeeded := False;

      Sockets.Create_Socket (Sock);
      Sockets.Connect (Sock, Endpoint, Timeout => 3.0);
      Sockets.Send_All
        (Sock,
         Protocol.Encode_Startup (User => User, Database => "postgres"),
         Timeout => 3.0);

      Read_Backend (Sock, Tag, Text);
      if Tag /= 'R' or else Length (Text) < 4
        or else Element (Text, 4) /= Character'Val (10)
      then
         Note (User & ": expected AuthenticationSASL, got tag '" & Tag & "'");
         Sockets.Close_Socket (Sock);
         return;
      end if;

      Sockets.Send_All
        (Sock,
         Frame
           ('p',
            "SCRAM-SHA-256" & ASCII.NUL
            & Character'Val (0) & Character'Val (0) & Character'Val (0)
            & Character'Val (Client_First'Length)
            & Client_First),
         Timeout => 3.0);

      Read_Backend (Sock, Tag, Text);
      if Tag /= 'R' or else Length (Text) < 5
        or else Element (Text, 4) /= Character'Val (11)
      then
         Note
           (User & ": expected AuthenticationSASLContinue, got tag '"
            & Tag & "'");
         Sockets.Close_Socket (Sock);
         return;
      end if;

      declare
         Server_First : constant String := Slice (Text, 5, Length (Text));
         Combined : constant String := Attribute (Server_First, 'r');
      begin
         Note (User & ": server-first = " & Server_First);
         Salt := To_Unbounded_String (Attribute (Server_First, 's'));
         Iterations := To_Unbounded_String (Attribute (Server_First, 'i'));
         Succeeded := True;

         --  Finish the exchange politely with a wrong proof so the server
         --  answers 28P01 and closes instead of seeing a truncated stream.
         Sockets.Send_All
           (Sock,
            Frame ('p', "c=biws,r=" & Combined & ",p=" & Bogus_Proof),
            Timeout => 3.0);
         Read_Backend (Sock, Tag, Text);
         Note (User & ": final backend message tag '" & Tag & "'");
      end;
      Sockets.Close_Socket (Sock);
   exception
      when Error : others =>
         Note
           (User & ": exchange failed with "
            & Ada.Exceptions.Exception_Name (Error) & ": "
            & Ada.Exceptions.Exception_Message (Error));
         if Sockets.Is_Open (Sock) then
            Sockets.Close_Socket (Sock);
         end if;
   end Mock_Exchange;

   Salt_A, Salt_B, Salt_Known : Unbounded_String;
   Iter_A, Iter_B, Iter_Known : Unbounded_String;
   Ok_A, Ok_B, Ok_Known : Boolean := False;

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

   delay 0.5;

   Mock_Exchange ("unknown-a", Salt_A, Iter_A, Ok_A);
   Mock_Exchange ("unknown-b", Salt_B, Iter_B, Ok_B);
   Mock_Exchange (Known_Role, Salt_Known, Iter_Known, Ok_Known);

   Test_Server.Request_Shutdown (Server);

   Note ("unknown-a: s=" & To_String (Salt_A) & " i=" & To_String (Iter_A));
   Note ("unknown-b: s=" & To_String (Salt_B) & " i=" & To_String (Iter_B));
   Note
     (Known_Role & ":     s=" & To_String (Salt_Known)
      & " i=" & To_String (Iter_Known));
   Note
     ("base64 of the library's dummy salt is """ & Published_Dummy_Salt
      & """, i.e. the ASCII octets """
      & SCRAM.To_String (SCRAM.Base64_Decode (Published_Dummy_Salt)) & """");

   Check
     (Ok_A and then Ok_B and then Ok_Known,
      "control: all three roles complete a server-first exchange "
      & "(harness sanity check)");
   Check
     (To_String (Salt_A) /= To_String (Salt_B),
      "two different roles with no SCRAM verifier receive different salts "
      & "(PostgreSQL derives the mock salt per role with scram_mock_salt "
      & "from the cluster's mock_authentication_nonce)");
   Check
     (To_String (Salt_A) /= Published_Dummy_Salt,
      "a role with no SCRAM verifier does not receive the fixed salt "
      & "published in this library's own source");
   Finish;
end Repro_Scram_1;
