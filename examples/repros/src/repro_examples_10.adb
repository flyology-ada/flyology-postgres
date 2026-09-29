--  EXAMPLES-10: a simple Query carrying no statement must produce
--  EmptyQueryResponse, not ERROR 42601.
--
--  Pgish_Handler.Handle (Protocol.Query) sends EmptyQueryResponse only when
--  Ada.Strings.Fixed.Trim (Text, Both) is empty.  RM A.4.3 says Trim removes
--  Space characters only, so a query made of other whitespace still reaches
--  Pgish_SQL.Parse.  Parse then raises Syntax_Error whenever the parsed tree
--  holds zero statements, and Pgish_Handler.SQL_State_For maps Syntax_Error to
--  SQLSTATE 42601.  PostgreSQL's exec_simple_query sends EmptyQueryResponse
--  for a query string with no statements; psql prints nothing for a bare ";".

with Ada.Exceptions;
with Ada.Strings;
with Ada.Strings.Fixed;
with Pgish_SQL;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_10 is
   package SQL renames Pgish_SQL;

   procedure Expect_Not_Syntax_Error (Text, Description : String) is
      Query : SQL.Query;
      pragma Unreferenced (Query);
   begin
      Query := SQL.Parse (Text);
      Check (True, Description);
   exception
      when Error : SQL.Syntax_Error =>
         Note (Description & ": Pgish_SQL.Syntax_Error """
               & Ada.Exceptions.Exception_Message (Error)
               & """ -> SQLSTATE 42601");
         Check (False, Description);
      when Error : others =>
         Note (Description & ": " & Ada.Exceptions.Exception_Name (Error));
         Check (False, Description);
   end Expect_Not_Syntax_Error;

   Newline : constant String := (1 => ASCII.LF);
begin
   --  The handler's own emptiness test must recognise a whitespace-only query.
   Check (Ada.Strings.Fixed.Trim (Newline, Ada.Strings.Both)'Length = 0,
          "Pgish_Handler treats a newline-only Query as empty");
   Check (Ada.Strings.Fixed.Trim
            ((1 => ASCII.HT), Ada.Strings.Both)'Length = 0,
          "Pgish_Handler treats a tab-only Query as empty");

   --  Everything below reaches Pgish_SQL.Parse and must not be reported as a
   --  syntax error; PostgreSQL answers EmptyQueryResponse for each.
   Expect_Not_Syntax_Error (";", "a bare semicolon is an empty query");
   Expect_Not_Syntax_Error ("-- note", "a line comment is an empty query");
   Expect_Not_Syntax_Error ("/* c */", "a block comment is an empty query");
   Expect_Not_Syntax_Error (Newline, "a newline-only Query is an empty query");
   Expect_Not_Syntax_Error ("", "an empty string is an empty query");
   Finish;
end Repro_Examples_10;
