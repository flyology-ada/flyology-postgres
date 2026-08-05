with Ada.Exceptions;
with Flyology.Postgres.SQL.Native.LALR;
with Flyology.Postgres.SQL.Native.Semantics;

package body Flyology.Postgres.SQL.Native.Engine is

   use type Ada.Exceptions.Exception_Id;

   procedure Parse
     (SQL           : String;
      Options       : Parse_Options;
      Initial_Token : Natural;
      Build         : aliased in out Builders.Builder;
      Result        : out Builders.Dynamic_Value;
      Error_Offset  : out Natural;
      Error_Message : out Ada.Strings.Unbounded.Unbounded_String;
      Success       : out Boolean)
   is
      Lexer         : Lexical_Scanner.Lexer;
      Parse_Result  : Builders.Dynamic_Value := Builders.No_Value;
      Failed_At     : Natural := 0;
      Failed_At_Set : Boolean := False;
      Last_Location : Natural := 0;

      procedure Report_Error
        (Error       : Ada.Exceptions.Exception_Occurrence;
         Offset      : Natural;
         Add_Context : Boolean;
         Context     : String := "")
      is
         Message : constant String := Ada.Exceptions.Exception_Message (Error);
      begin
         Error_Offset := Natural'Min (Offset, SQL'Length);
         if not Add_Context then
            Error_Message :=
              Ada.Strings.Unbounded.To_Unbounded_String (Message);
         elsif Error_Offset >= SQL'Length then
            Error_Message := Ada.Strings.Unbounded.To_Unbounded_String
              (Message & " at end of input");
         else
            Error_Message := Ada.Strings.Unbounded.To_Unbounded_String
              (Message & " at or near """ &
               Context & """");
         end if;
         Result := Builders.No_Value;
         Success := False;
      end Report_Error;

      procedure Next_Token
        (External_Token : out Integer;
         Value          : out Builders.Dynamic_Value;
         Location       : out Integer) is
      begin
         Lexer.Next_Token (External_Token, Value, Location);
         Last_Location :=
           (if Location < 0 then SQL'Length else Natural (Location));
      end Next_Token;

      procedure Reduce
        (Rule      : Positive;
         Values    : Builders.Semantic_Array;
         Locations : Builders.Location_Array;
         Value     : in out Builders.Dynamic_Value;
         Location  : in out Integer) is
      begin
         Semantic_Reduce
           (Build, Rule, Values, Locations, Value, Location, Parse_Result);
      end Reduce;

      procedure Syntax_Error (Location : Integer; External_Token : Integer) is
         pragma Unreferenced (External_Token);
      begin
         Failed_At := (if Location < 0 then 0 else Natural (Location));
         Failed_At_Set := True;
         raise Semantics.Scanner_Parser_Error with "syntax error";
      end Syntax_Error;

      package Parser is new Flyology.Postgres.SQL.Native.LALR
        (Final_State       => Final_State,
         Last_Table_Index  => Last_Table_Index,
         Terminal_Count    => Terminal_Count,
         Maximum_Token     => Maximum_Token,
         Pact_Default      => Pact_Default,
         Table_Error       => Table_Error,
         Translate         => Translate,
         Rule_Left         => Rule_Left,
         Rule_Length       => Rule_Length,
         Default_Action    => Default_Action,
         Default_Goto      => Default_Goto,
         Action_Offset     => Action_Offset,
         Goto_Offset       => Goto_Offset,
         Action_Table      => Action_Table,
         Action_Check      => Action_Check,
         Next_Token        => Next_Token,
         Reduce            => Reduce,
         Syntax_Error      => Syntax_Error);
   begin
      Error_Offset := 0;
      Error_Message := Ada.Strings.Unbounded.Null_Unbounded_String;
      Success := False;
      Lexer.Initialize
        (SQL, Initial_Token, Options.Backslash_Quote,
         Options.Standard_Conforming_Strings);
      Parser.Parse;
      Result := Parse_Result;
      Success := True;
   exception
      when Error : others =>
         if Ada.Exceptions.Exception_Identity (Error) =
           Lexical_Scanner.Scanner_Error'Identity
         then
            declare
               Offset : constant Natural := Lexer.Error_Position - 1;
            begin
               Report_Error
                 (Error, Offset, True,
                  (if Offset >= SQL'Length then ""
                   else SQL (SQL'First + Offset .. SQL'Last)));
            end;
         elsif Ada.Exceptions.Exception_Identity (Error) =
           Semantics.Scanner_Parser_Error'Identity
         then
            Report_Error
              (Error,
               (if Failed_At_Set then Failed_At else Last_Location),
               True,
               Lexer.Token_Text);
         else
            Report_Error (Error, Last_Location, False);
         end if;
   end Parse;

end Flyology.Postgres.SQL.Native.Engine;
