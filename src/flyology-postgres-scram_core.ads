with HMAC_SHA256;
with Interfaces;
with SHA256;
with System.Storage_Elements;

package Flyology.Postgres.SCRAM_Core
  with SPARK_Mode
is
   --  Constant-shape cryptographic primitives used by SCRAM-SHA-256.
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Offset;
   subtype Byte_Array is HMAC_SHA256.Byte_Array;
   --  Byte sequence accepted by the HMAC-SHA-256 implementation.
   subtype Digest is HMAC_SHA256.HMAC_Digest;
   --  Fixed-size SHA-256 digest.

   procedure PBKDF2_HMAC_SHA256
     (Password   : Byte_Array;
      Salt       : Byte_Array;
      Iterations : Positive;
      Result     : out Digest)
   with
     Pre =>
       Password'First >= 0
       and then Password'Last <= HMAC_SHA256.Max_Data_Length
       and then Interfaces.Unsigned_64 (Password'Length) <=
         SHA256.Max_Message_Bytes
       and then Salt'First >= 0
       and then Salt'Last <= HMAC_SHA256.Max_Data_Length -
         System.Storage_Elements.Storage_Offset'(4)
       and then Interfaces.Unsigned_64 (Salt'Length) <=
         SHA256.Max_Message_Bytes -
           Interfaces.Unsigned_64 (SHA256.Block_Length) - 4;
   --  Derive one SHA-256 block using PBKDF2-HMAC-SHA-256.
   --  @param Password Exact password octets; no text normalization occurs.
   --  @param Salt Salt octets mixed into every derivation round.
   --  @param Iterations Positive PBKDF2 iteration count.
   --  @param Result Derived 32-byte key.

   procedure Hash (Data : Byte_Array; Result : out Digest)
   with
     Pre =>
       Data'First >= 0
       and then Data'Last <= HMAC_SHA256.Max_Data_Length
       and then Interfaces.Unsigned_64 (Data'Length) <=
         SHA256.Max_Message_Bytes;
   --  Compute SHA-256 over Data.
   --  @param Data Exact byte sequence to hash.
   --  @param Result Resulting 32-byte digest.

   procedure Exclusive_Or
     (Left, Right : Digest; Result : out Digest);
   --  Compute the bytewise exclusive-or of two digests.
   --  @param Left First digest operand.
   --  @param Right Second digest operand.
   --  @param Result Left xor Right.

   procedure Wipe (Value : out Digest);
   --  Overwrite a digest with zeros before it leaves sensitive scope.
   --  @param Value Digest storage to clear.

end Flyology.Postgres.SCRAM_Core;
