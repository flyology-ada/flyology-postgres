with Ada.Strings.Unbounded;
with Flyology.Postgres.SQL.Native.Builders;
with Flyology.Postgres.SQL.Native.DFA;
with Flyology.Postgres.SQL.Native.Tables;

generic
   with package Lexical_DFA is new Flyology.Postgres.SQL.Native.DFA (<>);
   Actions  : Tables.Scanner_Action_Array;
   Keywords : Tables.Keyword_Array;
   Profile  : Tables.Scanner_Profile;
   Token_Ident, Token_Uident, Token_Fconst, Token_Sconst : Positive;
   Token_Usconst, Token_Bconst, Token_Xconst, Token_Op : Positive;
   Token_Iconst, Token_Param, Token_Sql_Comment, Token_C_Comment : Positive;
   Token_Format, Token_Format_La, Token_Json : Natural;
   Token_Not, Token_Not_La, Token_Between, Token_In : Positive;
   Token_Like, Token_Ilike, Token_Similar : Positive;
   Token_Nulls, Token_Nulls_La, Token_First, Token_Last : Positive;
   Token_With, Token_With_La : Positive;
   Token_Without, Token_Without_La : Natural;
   Token_Time, Token_Ordinality, Token_Uescape : Positive;
package Flyology.Postgres.SQL.Native.Scanner is

   Scanner_Error : exception;

   type Lexer is tagged limited private;

   procedure Initialize
     (Self                        : in out Lexer;
      Input                       : String;
      Initial_Token               : Natural := 0;
      Backslash_Quote             : Boolean := True;
      Standard_Conforming_Strings : Boolean := True);

   procedure Next_Token
     (Self     : in out Lexer;
      Token    : out Integer;
      Value    : out Builders.Dynamic_Value;
      Location : out Integer);

   function Error_Position (Self : Lexer) return Natural;
   procedure Error_Context
     (Self        : Lexer;
      Positioned  : out Boolean;
      Add_Context : out Boolean;
      Text        : out Ada.Strings.Unbounded.Unbounded_String);
   function Token_Text (Self : Lexer) return String;

private

   use Ada.Strings.Unbounded;

   type Lexer is tagged limited record
      Engine                      : Lexical_DFA.Scanner;
      Literal                     : Unbounded_String;
      Dollar_Delimiter            : Unbounded_String;
      Previous_String_Condition   : Positive := 1;
      Token_Location              : Natural := 0;
      Last_Error_Position         : Natural := 0;
      Last_Error_Positioned       : Boolean := True;
      Last_Error_Add_Context      : Boolean := True;
      Last_Error_Context          : Unbounded_String;
      Saw_Non_ASCII               : Boolean := False;
      Comment_Depth               : Natural := 0;
      First_Surrogate             : Natural := 0;
      Initial_Token               : Natural := 0;
      Lookahead_Token             : Integer := -1;
      Lookahead_Value             : Builders.Dynamic_Value;
      Lookahead_Location          : Integer := 0;
      Current_Text                : Unbounded_String;
      Lookahead_Text              : Unbounded_String;
      Backslash_Quote             : Boolean := True;
      Standard_Conforming_Strings : Boolean := True;
   end record;

end Flyology.Postgres.SQL.Native.Scanner;
