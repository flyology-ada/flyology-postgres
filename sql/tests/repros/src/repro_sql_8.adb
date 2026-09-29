with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_8 is
   --  SQL-8: flex's YY_DO_BEFORE_ACTION writes '\0' at yytext + yyleng, so
   --  scanner_yyerror's "loc = scanbuf + *yylloc" quotes only the current
   --  match; only the <<EOF>> rules quote through end of input.  The Ada
   --  engine (native-engine.adb:112-119) always builds the context as
   --  SQL (SQL'First + Offset .. SQL'Last), quoting the rest of the input.
   --  Two related divergences are covered here: str_udeescape's ereport
   --  carries no "at or near" suffix at all, base_yylex un-truncates the
   --  U&'...' UESCAPE '...' token before reporting a syntax error, and the
   --  zero-length delimited identifier is reported at the opening quote in
   --  scan.l (SET_YYLLOC at {xdstart}) but at the closing quote in Ada.

   procedure Expect_Message (Text : String; Version : SQL.Major_Version) is
   begin
      Note (Version'Image & " native: [" & Native_Error (Text, Version)
            & "] @" & Native_Error_Position (Text, Version)'Image);
      Note (Version'Image & " oracle: [" & Oracle_Error (Text, Version)
            & "] @" & Oracle_Error_Position (Text, Version)'Image);
      Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
             Version'Image & ": message matches the C oracle for <<" & Text & ">>");
   end Expect_Message;

   procedure Expect_Position (Text : String; Version : SQL.Major_Version) is
   begin
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": cursor matches the C oracle for <<" & Text & ">>");
   end Expect_Position;

   Unicode_Ctx  : constant String := "SELECT E'wrong: \U002FFFFF'";
   Param_Large  : constant String := "SELECT $12345678901, 1";
   Numeric_Junk : constant String := "SELECT 1x, 2";
   Udeescape    : constant String := "SELECT U&'\061'";
   Zero_Ident   : constant String := "SELECT """"";
   Uescape_Stmt : constant String := "SELECT * FROM U&'t' UESCAPE '!'";
begin
   for Version in SQL.Major_Version loop
      Expect_Message (Unicode_Ctx, Version);
   end loop;

   --  {param} gained a range check only in v18; on v14..v17 scan.l uses a
   --  plain atol and the oracle accepts this statement outright.
   for Version in SQL.Major_Version loop
      Expect_Message (Param_Large, Version);
   end loop;

   --  The numeric-junk rules exist from v16 on.
   for Version in SQL.Major_Version range SQL.PostgreSQL_16 .. SQL.PostgreSQL_18 loop
      Expect_Message (Numeric_Junk, Version);
   end loop;

   for Version in SQL.Major_Version loop
      Expect_Message (Udeescape, Version);
      Expect_Message (Zero_Ident, Version);
      Expect_Position (Zero_Ident, Version);
      Expect_Message (Uescape_Stmt, Version);
   end loop;

   --  Control: the EOF-shaped scanner errors the differential suite already
   --  covers quote to end of input on both sides.
   for Version in SQL.Major_Version loop
      Check (Native_Error ("SELECT 'unterminated", Version) =
               Oracle_Error ("SELECT 'unterminated", Version),
             Version'Image & ": control unterminated literal matches");
   end loop;

   Finish;
end Repro_SQL_8;
