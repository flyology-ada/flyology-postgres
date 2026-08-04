with Ada.Strings.Unbounded;
with Flyology.Postgres.SCRAM_Core;

package Flyology.Postgres.SCRAM is

   SCRAM_Error : exception;

   Mechanism : constant String := "SCRAM-SHA-256";
   Minimum_Iterations : constant := 4_096;
   Maximum_Iterations : constant := 1_000_000;
   Maximum_Message_Length : constant := 4_096;

   subtype Byte_Array is SCRAM_Core.Byte_Array;
   subtype Digest is SCRAM_Core.Digest;

   type Verifier is private;

   function Parse_Verifier (Value : String) return Verifier;
   --  Raw means Password is used as its exact String octets. This routine
   --  deliberately does not claim or perform SASLprep.
   function Make_Verifier_Raw
     (Password   : String;
      Salt       : Byte_Array;
      Iterations : Positive := Minimum_Iterations) return String;

   function Random_Nonce return String;
   function Client_First_Bare (User, Nonce : String) return String;
   function Client_First_Message (User, Nonce : String) return String;
   function Bare_From_Client_First (Message : String) return String;
   function Nonce_From_Client_First (Message : String) return String;

   function Server_First_Message
     (Credential     : Verifier;
      Combined_Nonce : String) return String;

   function Client_Final_Message
     (Password                  : String;
      Bare_Client_First         : String;
      Server_First              : String;
      Client_Nonce              : String;
      Expected_Server_Signature : out Digest) return String;

   procedure Verify_Server_Final
     (Message : String; Expected_Server_Signature : Digest);

   procedure Verify_Client_Final
     (Credential        : Verifier;
      Bare_Client_First : String;
      Server_First      : String;
      Combined_Nonce    : String;
      Client_Final      : String;
      Server_Signature  : out Digest;
      Valid             : out Boolean);

   function To_Bytes (Value : String) return Byte_Array;
   function To_String (Value : Byte_Array) return String;
   function Base64_Encode (Value : Byte_Array) return String;
   function Base64_Decode (Value : String) return Byte_Array;

private
   type Verifier is record
      Iteration_Count : Positive := Minimum_Iterations;
      Encoded_Salt    : Ada.Strings.Unbounded.Unbounded_String;
      Stored_Key      : Digest := (others => 0);
      Server_Key      : Digest := (others => 0);
   end record;

end Flyology.Postgres.SCRAM;
