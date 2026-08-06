with Ada.Strings.Unbounded;
with Flyology.Postgres.SCRAM_Core;

package Flyology.Postgres.SCRAM is
   --  PostgreSQL SCRAM-SHA-256 client/server message and verifier support.
   --  Strings are treated as exact octets; SASLprep is not performed.

   SCRAM_Error : exception;
   --  Raised when a verifier, SCRAM attribute, proof, or signature is invalid.

   Mechanism : constant String := "SCRAM-SHA-256";
   --  SASL mechanism name advertised on the PostgreSQL wire.
   Minimum_Iterations : constant := 4_096;
   --  Smallest verifier iteration count accepted or generated.
   Maximum_Iterations : constant := 1_000_000;
   --  Largest verifier iteration count accepted, bounding authentication work.
   Maximum_Message_Length : constant := 4_096;
   --  Largest SCRAM message or verifier string accepted by the parser.

   subtype Byte_Array is SCRAM_Core.Byte_Array;
   --  Byte sequence used by SCRAM cryptographic operations.
   subtype Digest is SCRAM_Core.Digest;
   --  SHA-256 digest used for keys, proofs, and signatures.

   type Verifier is private;
   --  Parsed PostgreSQL rolpassword verifier containing no plaintext password.

   function Parse_Verifier (Value : String) return Verifier;
   --  Parse and validate a PostgreSQL SCRAM-SHA-256 rolpassword value.
   --  @param Value Text in
   --     `SCRAM-SHA-256$iterations:salt$StoredKey:ServerKey` form.
   --  @return Validated verifier ready for server authentication.
   --  @exception SCRAM_Error Value is malformed or outside configured limits.

   function Make_Verifier_Raw
     (Password   : String;
      Salt       : Byte_Array;
      Iterations : Positive := Minimum_Iterations) return String;
   --  Derive a PostgreSQL rolpassword verifier. Password is consumed as exact
   --  String octets; this operation deliberately does not perform SASLprep.
   --  @param Password Raw password octets.
   --  @param Salt Nonempty random salt stored in the verifier.
   --  @param Iterations PBKDF2 work factor within the supported bounds.
   --  @return PostgreSQL SCRAM-SHA-256 rolpassword text.
   --  @exception SCRAM_Error An input is empty, invalid, or out of range.

   function Random_Nonce return String;
   --  Generate a cryptographically random printable SCRAM nonce.
   --  @return Fresh nonce suitable for a client-first message.
   function Client_First_Bare (User, Nonce : String) return String;
   --  Construct the bare client-first attributes.
   --  @param User PostgreSQL role name, escaped according to SCRAM.
   --  @param Nonce Nonempty client nonce.
   --  @return `n=<user>,r=<nonce>` attribute sequence.
   --  @exception SCRAM_Error User or Nonce is invalid.
   function Client_First_Message (User, Nonce : String) return String;
   --  Construct a complete client-first message using no channel binding.
   --  @param User PostgreSQL role name.
   --  @param Nonce Nonempty client nonce.
   --  @return GS2 header followed by the bare client-first attributes.
   function Bare_From_Client_First (Message : String) return String;
   --  Validate a client-first message and remove its GS2 header.
   --  @param Message Complete client-first message.
   --  @return Bare client-first attribute sequence.
   --  @exception SCRAM_Error Message is malformed or uses unsupported binding.
   function Nonce_From_Client_First (Message : String) return String;
   --  Extract the client nonce from a validated client-first message.
   --  @param Message Complete client-first message.
   --  @return Value of its `r` attribute.
   --  @exception SCRAM_Error Message lacks a valid nonce.
   function Channel_Binding_From_Client_First
     (Message : String) return String;
   --  Derive the base64 channel-binding value for a client-first GS2 header.
   --  @param Message Complete client-first message.
   --  @return Value expected in the client-final `c` attribute.
   --  @exception SCRAM_Error The GS2 header is invalid or unsupported.

   function Server_First_Message
     (Credential     : Verifier;
      Combined_Nonce : String) return String;
   --  Construct the server-first challenge for a parsed credential.
   --  @param Credential Verifier supplying salt and iteration count.
   --  @param Combined_Nonce Client nonce followed by fresh server entropy.
   --  @return SCRAM server-first attribute sequence.
   --  @exception SCRAM_Error Combined_Nonce is invalid.

   function Client_Final_Message
     (Password                  : String;
      Bare_Client_First         : String;
      Server_First              : String;
      Client_Nonce              : String;
      Expected_Server_Signature : out Digest) return String;
   --  Verify a server-first challenge and construct the client proof.
   --  @param Password Exact password octets; no SASLprep is performed.
   --  @param Bare_Client_First Previously sent bare client-first attributes.
   --  @param Server_First Server challenge to validate.
   --  @param Client_Nonce Original nonce, which must prefix the combined one.
   --  @param Expected_Server_Signature Signature required in server-final.
   --  @return Complete client-final message with proof.
   --  @exception SCRAM_Error The challenge is malformed or inconsistent.

   procedure Verify_Server_Final
     (Message : String; Expected_Server_Signature : Digest);
   --  Authenticate a server-final message against the locally derived value.
   --  @param Message Server-final attributes containing `v` or `e`.
   --  @param Expected_Server_Signature Signature derived by the client.
   --  @exception SCRAM_Error The server reports an error or signatures differ.

   procedure Verify_Client_Final
     (Credential        : Verifier;
      Bare_Client_First : String;
      Server_First      : String;
      Combined_Nonce    : String;
      Client_Final      : String;
      Server_Signature  : out Digest;
      Valid             : out Boolean;
      Channel_Binding   : String := "biws");
   --  Validate a client's final proof and derive the server signature.
   --  @param Credential Stored verifier for the startup role.
   --  @param Bare_Client_First Client's validated bare first message.
   --  @param Server_First Challenge previously sent by this server.
   --  @param Combined_Nonce Exact nonce included in Server_First.
   --  @param Client_Final Client proof message to authenticate.
   --  @param Server_Signature Signature returned only for an authentic client.
   --  @param Valid Set True only when the proof matches Credential.
   --  @param Channel_Binding Expected base64 GS2 channel-binding value.
   --  @exception SCRAM_Error A message is malformed or inconsistent.

   function To_Bytes (Value : String) return Byte_Array;
   --  Convert String character codes to identical byte values.
   --  @param Value String interpreted as octets.
   --  @return Byte array with the same length and values.
   function To_String (Value : Byte_Array) return String;
   --  Convert byte values to characters without text transcoding.
   --  @param Value Octets to convert.
   --  @return String with the same length and values.
   function Base64_Encode (Value : Byte_Array) return String;
   --  Encode bytes using canonical padded base64.
   --  @param Value Bytes to encode.
   --  @return Base64 text.
   function Base64_Decode (Value : String) return Byte_Array;
   --  Decode canonical padded base64 text.
   --  @param Value Base64 text to decode.
   --  @return Decoded bytes.
   --  @exception SCRAM_Error Value is not valid canonical base64.

private
   type Verifier is record
      Iteration_Count : Positive := Minimum_Iterations;
      Encoded_Salt    : Ada.Strings.Unbounded.Unbounded_String;
      Stored_Key      : Digest := (others => 0);
      Server_Key      : Digest := (others => 0);
   end record;

end Flyology.Postgres.SCRAM;
