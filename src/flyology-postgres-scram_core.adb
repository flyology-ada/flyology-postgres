package body Flyology.Postgres.SCRAM_Core
  with SPARK_Mode
is
   use type System.Storage_Elements.Storage_Element;

   procedure PBKDF2_HMAC_SHA256
     (Password   : Byte_Array;
      Salt       : Byte_Array;
      Iterations : Positive;
      Result     : out Digest) is
      Block : Byte_Array (1 .. Salt'Length + 4) := (others => 0);
      U     : Digest;
      Next  : Digest;
   begin
      for Index in Salt'Range loop
         Block (Block'First + (Index - Salt'First)) := Salt (Index);
      end loop;
      Block (Block'Last) := 1;

      HMAC_SHA256.Compute (Password, Block, U);
      Result := U;
      for Count in 2 .. Iterations loop
         pragma Loop_Invariant (Count in 2 .. Iterations);
         HMAC_SHA256.Compute
           (Password, HMAC_SHA256.Byte_Array (U), Next);
         for Index in Result'Range loop
            Result (Index) := Result (Index) xor Next (Index);
         end loop;
         U := Next;
      end loop;

      --  These stores are intentionally the final uses of the intermediates.
      pragma Warnings (Off, "unused assignment");
      Block := (others => 0);
      U := (others => 0);
      Next := (others => 0);
      pragma Inspection_Point (Block, U, Next);
      pragma Warnings (On, "unused assignment");
   end PBKDF2_HMAC_SHA256;

   procedure Hash (Data : Byte_Array; Result : out Digest) is
      Context : SHA256.Context;
      Output  : SHA256.Digest;
   begin
      SHA256.Initialize (Context);
      SHA256.Update (Context, Data);
      pragma Warnings
        (Off, "is set by ""Finalize"" but not used after the call");
      SHA256.Finalize (Context, Output);
      pragma Warnings
        (On, "is set by ""Finalize"" but not used after the call");
      Result := Digest (Output);
      --  This store is intentionally the final use of the intermediate.
      pragma Warnings (Off, "unused assignment");
      Output := (others => 0);
      pragma Inspection_Point (Output);
      pragma Warnings (On, "unused assignment");
   end Hash;

   procedure Exclusive_Or
     (Left, Right : Digest; Result : out Digest) is
   begin
      for Index in Result'Range loop
         Result (Index) := Left (Index) xor Right (Index);
      end loop;
   end Exclusive_Or;

   procedure Wipe (Value : out Digest) is
   begin
      Value := (others => 0);
      pragma Inspection_Point (Value);
   end Wipe;

end Flyology.Postgres.SCRAM_Core;
