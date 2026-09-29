with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_5 is
   --  SQL-5: parser.c check_uescapechar() rejects an escape character when
   --  isxdigit(), '+', '\'', '"' or scanner_isspace().  scansup.c's
   --  scanner_isspace() lists ' ', '\t', '\n', '\r' and '\f' on every major
   --  and adds '\v' in v17/v18.  The Ada test at native-scanner.adb:717-722
   --  omits Character'Val (12) (form feed) entirely, and Character'Val (11)
   --  for v17/v18.

   Form_Feed : constant String := "SELECT U&'a' UESCAPE E'\f'";
   Vert_Tab  : constant String := "SELECT U&'a' UESCAPE E'\v'";

   procedure Expect_Same (Text : String; Version : SQL.Major_Version) is
   begin
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
   end Expect_Same;
begin
   --  Form feed: rejected by PostgreSQL on every supported major.
   for Version in SQL.Major_Version loop
      Expect_Same (Form_Feed, Version);
   end loop;

   --  Vertical tab: rejected from v17 on.  (Before v17 the Ada scanner also
   --  turns E'\v' into the letter 'v', which is a legal escape character;
   --  see SQL-1.)
   for Version in SQL.Major_Version range SQL.PostgreSQL_17 .. SQL.PostgreSQL_18 loop
      Expect_Same (Vert_Tab, Version);
   end loop;

   --  Control: v14..v16 accept E'\v' as the letter 'v'.
   for Version in SQL.Major_Version range SQL.PostgreSQL_14 .. SQL.PostgreSQL_16 loop
      Check (Oracle_Difference (Vert_Tab, Version) = "",
             Version'Image & ": control UESCAPE E'\v' matches the C oracle");
   end loop;

   Finish;
end Repro_SQL_5;
