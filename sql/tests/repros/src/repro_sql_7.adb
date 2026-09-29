with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_7 is
   --  SQL-7: generate_native_actions.py turns a gram.y ereport() into
   --  "raise Semantics.Parser_Error with Semantics.Text_Of (<errmsg format
   --  literal>)".  The parser_errposition(@n) argument and every %s/%d
   --  argument are dropped, so the raised message keeps the raw printf
   --  format and the engine reports it at Last_Location (the lookahead
   --  token that finished the production) rather than at the grammar
   --  location the ereport named.

   procedure Expect_Message (Text : String; Version : SQL.Major_Version) is
   begin
      Note (Version'Image & " " & Text);
      Note ("    native: [" & Native_Error (Text, Version) & "] @"
            & Native_Error_Position (Text, Version)'Image);
      Note ("    oracle: [" & Oracle_Error (Text, Version) & "] @"
            & Oracle_Error_Position (Text, Version)'Image);
      Check (Native_Error (Text, Version) = Oracle_Error (Text, Version),
             Version'Image & ": " & Text & " message matches the C oracle");
   end Expect_Message;

   procedure Expect_Position (Text : String; Version : SQL.Major_Version) is
   begin
      Check (Native_Error_Position (Text, Version) =
               Oracle_Error_Position (Text, Version),
             Version'Image & ": " & Text & " cursor matches the C oracle");
   end Expect_Position;

   Limit_Comma : constant String := "SELECT 1 LIMIT 1, 2";
   Deferrable  : constant String :=
     "CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)";
   Role_Option : constant String := "CREATE ROLE r WITH foo";
   Json_Encode : constant String :=
     "SELECT JSON_OBJECT('a': 1 RETURNING text FORMAT JSON ENCODING foo)";
begin
   --  Position only: the message survives, parser_errposition(@1) does not.
   for Version in SQL.Major_Version loop
      Expect_Message (Limit_Comma, Version);
      Expect_Position (Limit_Comma, Version);
   end loop;

   --  processCASbits: both the "%s" argument and the position are lost.
   for Version in SQL.Major_Version loop
      Expect_Message (Deferrable, Version);
      Expect_Position (Deferrable, Version);
   end loop;

   for Version in SQL.Major_Version loop
      Expect_Message (Role_Option, Version);
   end loop;

   --  JSON_OBJECT ... ENCODING exists from v16 on.
   for Version in SQL.Major_Version range SQL.PostgreSQL_16 .. SQL.PostgreSQL_18 loop
      Expect_Message (Json_Encode, Version);
   end loop;

   Finish;
end Repro_SQL_7;
