with HMAC_SHA256;
with Interfaces;
with SHA256;
with System.Storage_Elements;

package Flyology.Postgres.SCRAM_Core
  with SPARK_Mode
is
   use type Interfaces.Unsigned_64;
   use type System.Storage_Elements.Storage_Offset;
   subtype Byte_Array is HMAC_SHA256.Byte_Array;
   subtype Digest is HMAC_SHA256.HMAC_Digest;

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

   procedure Hash (Data : Byte_Array; Result : out Digest)
   with
     Pre =>
       Data'First >= 0
       and then Data'Last <= HMAC_SHA256.Max_Data_Length
       and then Interfaces.Unsigned_64 (Data'Length) <=
         SHA256.Max_Message_Bytes;

   procedure Exclusive_Or
     (Left, Right : Digest; Result : out Digest);

   procedure Wipe (Value : out Digest);

end Flyology.Postgres.SCRAM_Core;
