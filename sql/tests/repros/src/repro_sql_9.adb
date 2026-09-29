with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_9 is
   --  SQL-9: scan.l's scanner_errposition() converts the byte offset into a
   --  character number ("pos = pg_mbstrlen_with_len(yyextra->scanbuf,
   --  location) + 1"), and the oracle wrapper passes that cursorpos through
   --  unchanged.  native-engine.adb:33 keeps a byte offset and
   --  native-backend.adb:24 reports Error_Offset + 1, so every cursor is a
   --  byte position.  The two agree only for ASCII input.

   --  U+00E9 as its two UTF-8 bytes, written explicitly so the reproduction
   --  does not depend on the compiler's source-encoding setting.
   E_Acute : constant String :=
     Character'Val (16#C3#) & Character'Val (16#A9#);

   Syntax_Case : constant String := "SELECT '" & E_Acute & "', 1 1";
   Scanner_Case : constant String := "SELECT '" & E_Acute & "', 'x";
   Ascii_Syntax : constant String := "SELECT 'e', 1 1";
   Ascii_Scan   : constant String := "SELECT 'e', 'x";

   procedure Expect_Position (Text, Label : String; Version : SQL.Major_Version) is
   begin
      Note (Version'Image & " " & Label & " native @"
            & Native_Error_Position (Text, Version)'Image & " ["
            & Native_Error (Text, Version) & "]");
      Note (Version'Image & " " & Label & " oracle @"
            & Oracle_Error_Position (Text, Version)'Image & " ["
            & Oracle_Error (Text, Version) & "]");
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": " & Label & " cursor matches the C oracle");
   end Expect_Position;
begin
   for Version in SQL.Major_Version loop
      Expect_Position (Syntax_Case, "grammar error after 2-byte character", Version);
      Expect_Position (Scanner_Case, "scanner error after 2-byte character", Version);
      --  Controls: the same statements with ASCII only.
      Check (Native_Error_Position (Ascii_Syntax, Version) =
               Oracle_Error_Position (Ascii_Syntax, Version),
             Version'Image & ": control ASCII grammar cursor matches");
      Check (Native_Error_Position (Ascii_Scan, Version) =
               Oracle_Error_Position (Ascii_Scan, Version),
             Version'Image & ": control ASCII scanner cursor matches");
   end loop;

   Finish;
end Repro_SQL_9;
