with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_4 is
   --  SQL-4: scan.l's {xeoctesc}/{xehexesc} actions set
   --  yyextra->saw_non_ascii for c == '\0' || IS_HIGHBIT_SET(c), and the
   --  rule that closes an escape string runs pg_verifymbstr() before
   --  returning SCONST.  The Ada scanner appends the byte unconditionally
   --  and never validates the assembled literal, so escape strings that
   --  build invalid UTF-8 are accepted.

   procedure Expect_Same (Text : String) is
   begin
      for Version in SQL.Major_Version loop
         Note (Version'Image & " " & Text & " native: ["
               & Native_Error (Text, Version) & "] @"
               & Native_Error_Position (Text, Version)'Image
               & "  oracle: [" & Oracle_Error (Text, Version) & "] @"
               & Oracle_Error_Position (Text, Version)'Image);
         Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
                Version'Image & ": " & Text & " reports the C oracle message");
         Check (Native_Error_Position (Text, Version) =
                  Oracle_Error_Position (Text, Version),
                Version'Image & ": " & Text & " reports the C oracle cursor");
      end loop;
   end Expect_Same;
begin
   --  Lone 0xFF and a lone UTF-8 lead byte: PostgreSQL rejects, Ada accepts.
   Expect_Same ("SELECT E'\377'");
   Expect_Same ("SELECT E'\xC3'");
   --  A zero byte: both reject, with different message and cursor.
   Expect_Same ("SELECT E'\000'");

   --  Control: escapes that assemble valid UTF-8 agree on every major.
   for Version in SQL.Major_Version loop
      Check (Oracle_Difference ("SELECT E'\303\251'", Version) = "",
             Version'Image & ": control E'\303\251' matches the C oracle");
   end loop;

   Finish;
end Repro_SQL_4;
