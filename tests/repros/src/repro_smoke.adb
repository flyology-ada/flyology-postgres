with Repro_Support; use Repro_Support;

procedure Repro_Smoke is
   Channel : aliased Memory_Transport;
begin
   Queue_Bytes (Channel, B ("hello"));
   Check (Bytes_Remaining (Channel) = 5, "queued bytes are counted");
   Check (S (B ("abc")) = "abc", "byte/string helpers round-trip");
   Finish;
end Repro_Smoke;
