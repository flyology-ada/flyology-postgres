package Flyology.Postgres.SQL.Native.Tables is

   type Integer_Array is array (Natural range <>) of Integer;

   type Transition is record
      Verify : Integer;
      Offset : Integer;
   end record;

   type Transition_Array is array (Natural range <>) of Transition;

   Maximum_Keyword_Length : constant := 32;
   subtype Keyword_Text is String (1 .. Maximum_Keyword_Length);
   type Keyword_Entry is record
      Text   : Keyword_Text;
      Length : Positive;
      Token  : Positive;
   end record;
   type Keyword_Array is array (Natural range <>) of Keyword_Entry;

   type Scanner_Action_Kind is
     (Ignore,
      Return_Token,
      Comment_Start,
      Comment_Nest,
      Comment_End,
      Bit_Start,
      Hex_Start,
      Nchar_Start,
      Quote_Start,
      Escape_Start,
      Unicode_String_Start,
      Quote_Stop,
      Quote_Continue,
      Quote_Finish,
      Quote_Double,
      Literal_Add,
      Unicode_Escape,
      Unicode_Surrogate,
      Unicode_Surrogate_Error,
      Unicode_Escape_Error,
      Escape_Character,
      Octal_Escape,
      Hex_Escape,
      Escape_Trailing,
      Dollar_Start,
      Dollar_Failed,
      Dollar_Delimiter,
      Dollar_Character,
      Identifier_Start,
      Unicode_Identifier_Start,
      Identifier_Stop,
      Unicode_Identifier_Stop,
      Identifier_Double,
      Unicode_Failed,
      Self_Character,
      Operator_Token,
      Parameter_Token,
      Integer_Literal,
      Integer_Less,
      Float_Literal,
      Invalid_Integer,
      Invalid_Numeric,
      Invalid_Parameter,
      Identifier_Token,
      Other_Character,
      Scanner_Jam);

   type Scanner_Action is record
      Kind     : Scanner_Action_Kind;
      Argument : Integer := 0;
   end record;
   type Scanner_Action_Array is array (Positive range <>) of Scanner_Action;

end Flyology.Postgres.SQL.Native.Tables;
