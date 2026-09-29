--  SCRAM-2: optional SCRAM extension attributes are rejected instead of
--  ignored.
--
--  RFC 5802 section 7 (formal syntax) defines
--     extensions = attr-val *("," attr-val)
--  with the normative comment "All extensions are optional, i.e.,
--  unrecognized attributes not defined in this document MUST be ignored",
--  and places `["," extensions]` at the end of client-first-message-bare,
--  client-final-message-without-proof and server-final-message.
--
--  This library rejects all three:
--    * src/flyology-postgres-scram.adb:399-401  (Parse_Client_First:
--      "if Cursor <= Bare_Text'Last then Fail")
--    * src/flyology-postgres-scram.adb:589-597  (Verify_Client_Final: the
--      third token must literally be the p= proof)
--    * src/flyology-postgres-scram.adb:554-555  (Verify_Server_Final:
--      Attribute_Value consumes the whole message, so the trailing
--      ",x=1" becomes part of the base64 text)
--
--  Correct behavior (RFC 5802, and PostgreSQL's own auth-scram.c for the two
--  server-side cases): the extension is skipped, and it stays part of the
--  AuthMessage, so a proof computed over the extended
--  client-final-message-without-proof authenticates.

with Ada.Exceptions;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.SCRAM_Core;
with HMAC_SHA256;
with Repro_Support; use Repro_Support;

procedure Repro_Scram_2 is

   package SCRAM renames Flyology.Postgres.SCRAM;
   package SCRAM_Core renames Flyology.Postgres.SCRAM_Core;

   --  RFC 7677 section 3 test vector, as used by
   --  tests/src/tests.adb:Test_RFC_7677_SCRAM_SHA_256.
   Password       : constant String := "pencil";
   Client_Nonce   : constant String := "rOprNGfwEbeRWgbNEkqO";
   Combined_Nonce : constant String :=
     "rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0";
   Encoded_Salt   : constant String := "W22ZaJ0SNY7soEsUEjb6gQ==";
   Server_First   : constant String :=
     "r=" & Combined_Nonce & ",s=" & Encoded_Salt & ",i=4096";
   Bare           : constant String :=
     SCRAM.Client_First_Bare ("user", Client_Nonce);
   Server_Final   : constant String :=
     "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";

   Extension : constant String := "x=1";
   --  An unrecognized (therefore optional) attribute.  It is NOT "m=", the
   --  reserved mandatory extension, which every implementation must refuse.

   Bare_Extension_Accepted : Boolean := False;
   Final_Extension_Accepted : Boolean := False;
   Server_Final_Extension_Accepted : Boolean := False;

begin
   --  1. Server role, client-first-message.
   declare
      Extended : constant String :=
        "n,,n=user,r=" & Client_Nonce & "," & Extension;
      Expected : constant String :=
        "n=user,r=" & Client_Nonce & "," & Extension;
   begin
      declare
         Got : constant String := SCRAM.Bare_From_Client_First (Extended);
      begin
         Note ("Bare_From_Client_First returned: " & Got);
         Bare_Extension_Accepted := Got = Expected;
      end;
   exception
      when Error : SCRAM.SCRAM_Error =>
         Note
           ("Bare_From_Client_First (""" & Extended & """) raised "
            & "SCRAM_Error: " & Ada.Exceptions.Exception_Message (Error));
   end;

   --  2. Server role, client-final-message.  The proof below is computed over
   --  the AuthMessage that includes the extension, which is exactly what
   --  PostgreSQL's read_client_final_message produces (it reads attributes
   --  until it reaches 'p', and client_final_message_without_proof spans
   --  everything before the proof, extensions included).  A conforming
   --  verifier must therefore accept it.
   declare
      Credential : constant SCRAM.Verifier :=
        SCRAM.Parse_Verifier
          (SCRAM.Make_Verifier_Raw
             (Password, SCRAM.Base64_Decode (Encoded_Salt)));
      Without_Proof : constant String :=
        "c=biws,r=" & Combined_Nonce & "," & Extension;
      Auth_Message : constant String :=
        Bare & "," & Server_First & "," & Without_Proof;
      Salt : constant SCRAM.Byte_Array := SCRAM.Base64_Decode (Encoded_Salt);
      Password_Data : constant SCRAM.Byte_Array := SCRAM.To_Bytes (Password);
      Salted, Client_Key, Stored_Key, Client_Signature, Proof : SCRAM.Digest;
      Server_Signature : SCRAM.Digest := (others => 0);
      Valid : Boolean := False;
   begin
      SCRAM_Core.PBKDF2_HMAC_SHA256 (Password_Data, Salt, 4096, Salted);
      HMAC_SHA256.Compute
        (SCRAM.Byte_Array (Salted), SCRAM.To_Bytes ("Client Key"),
         Client_Key);
      SCRAM_Core.Hash (SCRAM.Byte_Array (Client_Key), Stored_Key);
      HMAC_SHA256.Compute
        (SCRAM.Byte_Array (Stored_Key), SCRAM.To_Bytes (Auth_Message),
         Client_Signature);
      SCRAM_Core.Exclusive_Or (Client_Key, Client_Signature, Proof);

      declare
         Client_Final : constant String :=
           Without_Proof & ",p="
           & SCRAM.Base64_Encode (SCRAM.Byte_Array (Proof));
      begin
         Note ("client-final under test: " & Client_Final);
         SCRAM.Verify_Client_Final
           (Credential,
            Bare,
            Server_First,
            Combined_Nonce,
            Client_Final,
            Server_Signature,
            Valid);
         Note ("Verify_Client_Final returned Valid = " & Valid'Image);
         Final_Extension_Accepted := Valid;
      exception
         when Error : SCRAM.SCRAM_Error =>
            Note
              ("Verify_Client_Final raised SCRAM_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
      SCRAM_Core.Wipe (Salted);
      SCRAM_Core.Wipe (Client_Key);
      SCRAM_Core.Wipe (Stored_Key);
      SCRAM_Core.Wipe (Client_Signature);
      SCRAM_Core.Wipe (Proof);
      SCRAM_Core.Wipe (Server_Signature);
   end;

   --  3. Client role, server-final-message.  The signature is the published
   --  RFC 7677 value; only a trailing optional extension is added.
   declare
      Signature : SCRAM.Digest := (others => 0);
      Client_Final : constant String :=
        SCRAM.Client_Final_Message
          (Password, Bare, Server_First, Client_Nonce, Signature);
      Extended : constant String := Server_Final & "," & Extension;
   begin
      pragma Assert (Client_Final'Length > 0);
      Note ("server-final under test: " & Extended);
      SCRAM.Verify_Server_Final (Extended, Signature);
      Server_Final_Extension_Accepted := True;
      SCRAM_Core.Wipe (Signature);
   exception
      when Error : SCRAM.SCRAM_Error =>
         Note
           ("Verify_Server_Final raised SCRAM_Error: "
            & Ada.Exceptions.Exception_Message (Error));
   end;

   Check
     (Bare_Extension_Accepted,
      "an unrecognized extension attribute after the client-first nonce is "
      & "ignored and kept in the bare message (RFC 5802 sec. 7; PostgreSQL "
      & "read_client_first_message consumes trailing attributes and "
      & "discards them)");
   Check
     (Final_Extension_Accepted,
      "an unrecognized extension attribute between the client-final nonce "
      & "and the proof is ignored, and the proof computed over the extended "
      & "without-proof text is accepted (PostgreSQL "
      & "read_client_final_message reads attributes until 'p' and includes "
      & "them in client_final_message_without_proof)");
   Check
     (Server_Final_Extension_Accepted,
      "an unrecognized extension attribute after the server-final v= "
      & "signature is ignored and the signature still verifies (RFC 5802 "
      & "sec. 7)");

   Finish;
end Repro_Scram_2;
