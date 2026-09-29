--  SCRAM-3: iteration counts below Minimum_Iterations (4096) are refused on
--  both roles, so this library cannot interoperate with a PostgreSQL 16+
--  cluster whose roles were created under a lower scram_iterations setting.
--
--  Location: src/flyology-postgres-scram.ads:13-16 declares
--     Minimum_Iterations : constant := 4_096;
--     Maximum_Iterations : constant := 1_000_000;
--  and src/flyology-postgres-scram.adb:174-176 (Parse_Positive) rejects
--  anything outside that range.  Parse_Positive is used both by
--  Parse_Verifier (server role, scram.adb:209) and by Parse_Server_First
--  (client role, scram.adb:483), and Complete_Startup re-raises SCRAM_Error
--  as Protocol.Protocol_Error (src/flyology-postgres-client.adb:372-378).
--
--  PostgreSQL 16 added the scram_iterations GUC (minimum 1, maximum INT_MAX,
--  default 4096); a role created while it is set to 1000 stores
--  "SCRAM-SHA-256$1000:...".  libpq's read_server_first_message accepts any
--  count with iterations >= 1, and the backend's parse_scram_secret imposes
--  no 4096 floor, so psql authenticates against exactly the verifier and the
--  server-first challenge exercised below.
--
--  These are constants in an .ads specification, so per the repository's
--  interface-value rules the values themselves are a user policy decision.
--  This program only establishes the factual interop consequence.
--
--  Correct (libpq-compatible) behavior: all three checks below succeed.

with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Fixed;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with Flyology.Postgres.Transports;
with HMAC_SHA256;
with Repro_Support; use Repro_Support;

procedure Repro_Scram_3 is

   package SCRAM renames Flyology.Postgres.SCRAM;
   package SCRAM_Core renames Flyology.Postgres.SCRAM_Core;
   package Client renames Flyology.Postgres.Client;

   use type Protocol.Byte_Offset;

   Password       : constant String := "pencil";
   Client_Nonce   : constant String := "rOprNGfwEbeRWgbNEkqO";
   Combined_Nonce : constant String :=
     "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
   Encoded_Salt   : constant String := "W22ZaJ0SNY7soEsUEjb6gQ==";
   Low_Iterations : constant := 1_000;
   --  A PostgreSQL 16+ cluster running with scram_iterations = 1000.

   ------------------------------------------------------------------
   --  A genuine PostgreSQL rolpassword verifier at any iteration count.
   ------------------------------------------------------------------

   function Verifier_Text (Iterations : Positive) return String is
      Salt : constant SCRAM.Byte_Array := SCRAM.Base64_Decode (Encoded_Salt);
      Password_Data : constant SCRAM.Byte_Array := SCRAM.To_Bytes (Password);
      Salted, Client_Key, Stored_Key, Server_Key : SCRAM.Digest;
   begin
      SCRAM_Core.PBKDF2_HMAC_SHA256
        (Password_Data, Salt, Iterations, Salted);
      HMAC_SHA256.Compute
        (SCRAM.Byte_Array (Salted), SCRAM.To_Bytes ("Client Key"),
         Client_Key);
      SCRAM_Core.Hash (SCRAM.Byte_Array (Client_Key), Stored_Key);
      HMAC_SHA256.Compute
        (SCRAM.Byte_Array (Salted), SCRAM.To_Bytes ("Server Key"),
         Server_Key);
      return
        "SCRAM-SHA-256$"
        & Ada.Strings.Fixed.Trim
            (Positive'Image (Iterations), Ada.Strings.Both)
        & ":" & Encoded_Salt
        & "$" & SCRAM.Base64_Encode (SCRAM.Byte_Array (Stored_Key))
        & ":" & SCRAM.Base64_Encode (SCRAM.Byte_Array (Server_Key));
   end Verifier_Text;

   ------------------------------------------------------------------
   --  A scripted PostgreSQL server that answers over the real client
   --  startup path: AuthenticationSASL, then AuthenticationSASLContinue
   --  carrying i=1000 with a nonce that extends the client's own.
   ------------------------------------------------------------------

   Max_Buffer : constant := 8_192;

   type Script_Transport is limited new Transports.Transport with record
      In_Buf    : Protocol.Byte_Array (1 .. Max_Buffer) := (others => 0);
      In_Last   : Protocol.Byte_Offset := 0;
      In_Next   : Protocol.Byte_Offset := 1;
      Out_Buf   : Protocol.Byte_Array (1 .. Max_Buffer) := (others => 0);
      Out_Last  : Protocol.Byte_Offset := 0;
      Out_Next  : Protocol.Byte_Offset := 1;
      Stage     : Natural := 0;
      Saw_Final : Boolean := False;
   end record;

   overriding procedure Receive_Exactly
     (Item    : in out Script_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null);

   overriding procedure Send_All
     (Item    : in out Script_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   function Read_BE32
     (Data : Protocol.Byte_Array; From : Protocol.Byte_Offset) return Natural
   is (Natural (Data (From)) * 16_777_216
       + Natural (Data (From + 1)) * 65_536
       + Natural (Data (From + 2)) * 256
       + Natural (Data (From + 3)));

   procedure Queue (Item : in out Script_Transport; Data : Protocol.Byte_Array)
   is
   begin
      for Value of Data loop
         Item.In_Last := Item.In_Last + 1;
         Item.In_Buf (Item.In_Last) := Value;
      end loop;
   end Queue;

   procedure Queue_Auth
     (Item : in out Script_Transport; Code : Natural; Text : String) is
      Length : constant Natural := 4 + 4 + Text'Length;
   begin
      Queue (Item, (1 => Character'Pos ('R')));
      Queue
        (Item,
         (Protocol.Byte (Length / 16_777_216 mod 256),
          Protocol.Byte (Length / 65_536 mod 256),
          Protocol.Byte (Length / 256 mod 256),
          Protocol.Byte (Length mod 256)));
      Queue
        (Item,
         (Protocol.Byte (Code / 16_777_216 mod 256),
          Protocol.Byte (Code / 65_536 mod 256),
          Protocol.Byte (Code / 256 mod 256),
          Protocol.Byte (Code mod 256)));
      Queue (Item, B (Text));
   end Queue_Auth;

   procedure Advance (Item : in out Script_Transport) is
      Available : Protocol.Byte_Offset;
   begin
      loop
         Available := Item.Out_Last - Item.Out_Next + 1;
         case Item.Stage is
            when 0 =>
               --  Untagged StartupMessage: Int32 length covering itself.
               exit when Available < 4;
               declare
                  Length : constant Natural :=
                    Read_BE32 (Item.Out_Buf, Item.Out_Next);
               begin
                  exit when Available < Protocol.Byte_Offset (Length);
                  Item.Out_Next :=
                    Item.Out_Next + Protocol.Byte_Offset (Length);
                  Item.Stage := 1;
                  Queue_Auth
                    (Item, 10,
                     "SCRAM-SHA-256" & ASCII.NUL & ASCII.NUL);
               end;

            when 1 =>
               --  SASLInitialResponse: 'p', Int32 length, mechanism C string,
               --  Int32 payload length, client-first-message.
               exit when Available < 5;
               declare
                  Length : constant Natural :=
                    Read_BE32 (Item.Out_Buf, Item.Out_Next + 1);
                  Total : constant Protocol.Byte_Offset :=
                    Protocol.Byte_Offset (Length) + 1;
               begin
                  exit when Available < Total;
                  declare
                     Payload : constant String :=
                       S (Item.Out_Buf
                            (Item.Out_Next + 5 .. Item.Out_Next + Total - 1));
                     Marker : constant Natural :=
                       Ada.Strings.Fixed.Index
                         (Payload, ",r=", Ada.Strings.Backward);
                  begin
                     if Marker = 0 then
                        raise Program_Error with
                          "no client nonce in SASLInitialResponse";
                     end if;
                     declare
                        Nonce : constant String :=
                          Payload (Marker + 3 .. Payload'Last);
                        Server_First : constant String :=
                          "r=" & Nonce & "0123456789abcdef01234567"
                          & ",s=" & Encoded_Salt
                          & ",i="
                          & Ada.Strings.Fixed.Trim
                              (Integer'Image (Low_Iterations),
                               Ada.Strings.Both);
                     begin
                        Note ("scripted server-first: " & Server_First);
                        Queue_Auth (Item, 11, Server_First);
                     end;
                  end;
                  Item.Out_Next := Item.Out_Next + Total;
                  Item.Stage := 2;
               end;

            when 2 =>
               --  SASLResponse carrying the client-final message.
               exit when Available < 5;
               declare
                  Length : constant Natural :=
                    Read_BE32 (Item.Out_Buf, Item.Out_Next + 1);
                  Total : constant Protocol.Byte_Offset :=
                    Protocol.Byte_Offset (Length) + 1;
               begin
                  exit when Available < Total;
                  Note
                    ("client sent a client-final message: "
                     & S (Item.Out_Buf
                            (Item.Out_Next + 5 .. Item.Out_Next + Total - 1)));
                  Item.Out_Next := Item.Out_Next + Total;
                  Item.Saw_Final := True;
                  Item.Stage := 3;
               end;

            when others =>
               exit;
         end case;
      end loop;
   end Advance;

   overriding procedure Receive_Exactly
     (Item    : in out Script_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null) is
      pragma Unreferenced (Timeout, On_Wait);
   begin
      if Data'Length > Item.In_Last - Item.In_Next + 1 then
         raise Program_Error with "scripted server has nothing more to say";
      end if;
      for Index in Data'Range loop
         Data (Index) := Item.In_Buf (Item.In_Next);
         Item.In_Next := Item.In_Next + 1;
      end loop;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Script_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
      pragma Unreferenced (Timeout);
   begin
      for Value of Data loop
         Item.Out_Last := Item.Out_Last + 1;
         Item.Out_Buf (Item.Out_Last) := Value;
      end loop;
      Advance (Item);
   end Send_All;

   Verifier_Accepted     : Boolean := False;
   Server_First_Accepted : Boolean := False;
   Startup_Reached_Proof : Boolean := False;

begin
   --  1. Server role: a rolpassword copied from a cluster running with
   --  scram_iterations = 1000 must parse.
   declare
      Text : constant String := Verifier_Text (Low_Iterations);
   begin
      Note ("verifier under test: " & Text);
      declare
         Parsed : constant SCRAM.Verifier := SCRAM.Parse_Verifier (Text);
         pragma Unreferenced (Parsed);
      begin
         Verifier_Accepted := True;
      end;
   exception
      when Error : SCRAM.SCRAM_Error =>
         Note
           ("Parse_Verifier raised SCRAM_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   --  2. Client role: a server-first challenge with i=1000 must be answered.
   declare
      Bare : constant String :=
        SCRAM.Client_First_Bare ("user", Client_Nonce);
      Server_First : constant String :=
        "r=" & Combined_Nonce & ",s=" & Encoded_Salt & ",i="
        & Ada.Strings.Fixed.Trim
            (Integer'Image (Low_Iterations), Ada.Strings.Both);
      Signature : SCRAM.Digest := (others => 0);
   begin
      Note ("server-first under test: " & Server_First);
      declare
         Final : constant String :=
           SCRAM.Client_Final_Message
             (Password, Bare, Server_First, Client_Nonce, Signature);
      begin
         Note ("client-final produced: " & Final);
         Server_First_Accepted := Final'Length > 0;
      end;
      SCRAM_Core.Wipe (Signature);
   exception
      when Error : SCRAM.SCRAM_Error =>
         Note
           ("Client_Final_Message raised SCRAM_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   --  3. The same challenge through the public client startup path.
   declare
      Channel : aliased Script_Transport;
      Session : Client.Session (Channel'Access);
   begin
      begin
         Client.Startup
           (Session,
            User     => "flyology",
            Database => "postgres",
            Password => Password,
            Timeout  => 5.0);
      exception
         when Error : others =>
            Note
              ("Client.Startup raised "
               & Ada.Exceptions.Exception_Name (Error) & ": "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      Startup_Reached_Proof := Channel.Saw_Final;
   end;

   --  Informational only: the upper bound is a resource-budget policy, but
   --  PostgreSQL 16+ allows scram_iterations up to INT_MAX.
   declare
      High : constant String :=
        "r=" & Combined_Nonce & ",s=" & Encoded_Salt & ",i=2000000";
      Bare : constant String :=
        SCRAM.Client_First_Bare ("user", Client_Nonce);
      Signature : SCRAM.Digest := (others => 0);
   begin
      declare
         Final : constant String :=
           SCRAM.Client_Final_Message
             (Password, Bare, High, Client_Nonce, Signature);
      begin
         Note ("i=2000000 accepted, client-final length"
               & Natural'Image (Final'Length));
      end;
      SCRAM_Core.Wipe (Signature);
   exception
      when Error : SCRAM.SCRAM_Error =>
         Note
           ("informational: i=2000000 (allowed by PostgreSQL 16+, whose "
            & "scram_iterations maximum is INT_MAX) raised SCRAM_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   Check
     (Verifier_Accepted,
      "a PostgreSQL rolpassword stored with scram_iterations = 1000 parses "
      & "(the backend's parse_scram_secret imposes no 4096 floor)");
   Check
     (Server_First_Accepted,
      "a server-first challenge carrying i=1000 is answered with a client "
      & "proof (libpq's read_server_first_message accepts any count >= 1)");
   Check
     (Startup_Reached_Proof,
      "Client.Startup against a server offering i=1000 sends its "
      & "client-final proof instead of failing with Protocol_Error");

   Finish;
end Repro_Scram_3;
