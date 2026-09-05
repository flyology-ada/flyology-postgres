package body Flyology.Postgres.SQL.Native is

   function Character_Position
     (Text        : String;
      Byte_Offset : Natural) return Natural
   is
      Index     : Positive := Text'First;
      Remaining : Natural := Byte_Offset;
      Result    : Natural := 1;
   begin
      while Remaining > 0 loop
         declare
            Byte : constant Natural := Character'Pos (Text (Index));
            --  The pinned PostgreSQL parser sources select UTF-8 and use
            --  pg_utf_mblen while converting scanner offsets to positions.
            Width : constant Positive :=
              (case Byte is
                  when 16#C0# .. 16#DF# => 2,
                  when 16#E0# .. 16#EF# => 3,
                  when 16#F0# .. 16#F7# => 4,
                  when others           => 1);
            Step : constant Positive := Positive'Min (Width, Remaining);
         begin
            Index := Index + Step;
            Remaining := Remaining - Step;
            Result := Result + 1;
         end;
      end loop;
      return Result;
   end Character_Position;

end Flyology.Postgres.SQL.Native;
