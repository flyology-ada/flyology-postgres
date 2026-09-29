with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Flyology.Postgres.SQL.AST.V18;
with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_2 is
   --  SQL-2: scan.l's {xeoctesc} action truncates the octal value to one
   --  byte ("unsigned char c = strtoul(yytext + 1, NULL, 8)"), so E'\401'
   --  is valid SQL whose string value is the single byte 0x01.  The Ada
   --  scanner computes Based_Value (three octal digits reach 511) and calls
   --  Character'Val (Code), which raises Constraint_Error.  The engine's
   --  catch-all turns that into a failed parse whose "diagnostic" is a GNAT
   --  range-check message pointing at the SELECT token.

   package V18 renames Flyology.Postgres.SQL.AST.V18;

   Valid_Octal : constant String := "SELECT E'\401'";
   Tree        : V18.Owned_Syntax_Tree;
   Raised      : Boolean := False;
   Raised_Text : String (1 .. 200) := (others => ' ');
   Raised_Last : Natural := 0;

   procedure Compare (Text : String) is
   begin
      Note (Text & " native: [" & Native_Error (Text, SQL.PostgreSQL_18)
            & "] oracle: [" & Oracle_Error (Text, SQL.PostgreSQL_18) & "]");
   end Compare;
begin
   for Version in SQL.Major_Version loop
      Note (Version'Image & " native: [" & Native_Error (Valid_Octal, Version)
            & "] @" & Native_Error_Position (Valid_Octal, Version)'Image);
      Note (Version'Image & " oracle: [" & Oracle_Error (Valid_Octal, Version)
            & "] @" & Oracle_Error_Position (Valid_Octal, Version)'Image);
      Check (Native_Error (Valid_Octal, Version) = "",
             Version'Image & ": E'\401' parses (C oracle accepts it)");
      Check (Oracle_Difference (Valid_Octal, Version) = "",
             Version'Image & ": E'\401' arena matches the C oracle");
   end loop;

   --  The documented contract (owned_ast_tests.adb) is that Parse reports a
   --  diagnostic and never propagates an exception.  Record whether that
   --  holds, and what the diagnostic actually says.
   begin
      V18.Parse (Valid_Octal, Tree);
   exception
      when Error : others =>
         Raised := True;
         declare
            Text : constant String :=
              Ada.Exceptions.Exception_Name (Error) & ": " &
              Ada.Exceptions.Exception_Message (Error);
         begin
            Raised_Last := Natural'Min (Text'Length, Raised_Text'Length);
            Raised_Text (1 .. Raised_Last) :=
              Text (Text'First .. Text'First + Raised_Last - 1);
         end;
   end;

   if Raised then
      Note ("owned Parse propagated " & Raised_Text (1 .. Raised_Last));
   else
      Note ("owned Parse diagnostic: ["
            & Ada.Strings.Unbounded.To_String (Tree.Diagnostic_Message)
            & "] @" & Tree.Diagnostic_Position'Image);
   end if;
   Check (not Raised, "owned V18.Parse does not propagate an exception");
   Check (Tree.Valid, "owned V18.Parse accepts SELECT E'\401'");

   --  Related inputs the same range check masks: PostgreSQL rejects these
   --  through pg_verifymbstr (see SQL-4), not through a range check.
   Compare ("SELECT E'\400'");
   Compare ("SELECT E'\777'");

   Finish;
end Repro_SQL_2;
