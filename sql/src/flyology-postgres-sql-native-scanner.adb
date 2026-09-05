with Ada.Characters.Handling;
with Ada.Strings.Fixed;
with Interfaces;

package body Flyology.Postgres.SQL.Native.Scanner is

   use type Interfaces.Unsigned_8;
   use type Interfaces.Integer_64;
   use type Builders.Value_Kind;
   use type Tables.Parameter_Number_Mode;
   use type Tables.Scanner_Action_Kind;

   Initial_Condition : constant := 1;
   XB_Condition      : constant := 3;
   XC_Condition      : constant := 5;
   XD_Condition      : constant := 7;
   XH_Condition      : constant := 9;
   XQ_Condition      : constant := 11;
   XQS_Condition     : constant := 13;
   XE_Condition      : constant := 15;
   XDOLQ_Condition   : constant := 17;
   XUI_Condition     : constant := 19;
   XUS_Condition     : constant := 21;
   XEU_Condition     : constant := 23;

   procedure Fail
     (Self        : in out Lexer;
      Position    : Natural;
      Message     : String;
      Add_Context : Boolean := True)
   is
   begin
      Self.Last_Error_Position := Position;
      Self.Last_Error_Add_Context := Add_Context;
      Self.Last_Error_Context :=
        (if Add_Context
         then To_Unbounded_String
           (Lexical_DFA.Slice
              (Self.Engine, Position, Lexical_DFA.Position (Self.Engine)))
         else Null_Unbounded_String);
      raise Scanner_Error with Message;
   end Fail;

   function Lowercase (Value : String) return String is
      Result : String := Value;
   begin
      for Index in Result'Range loop
         if Result (Index) in 'A' .. 'Z' then
            Result (Index) := Ada.Characters.Handling.To_Lower (Result (Index));
         end if;
      end loop;
      return Result;
   end Lowercase;

   function Truncated_Identifier (Value : String) return String is
      Limit : Natural := Natural'Min (Value'Length, 63);
   begin
      if Limit = Value'Length then
         return Value;
      end if;
      while Limit > 0
        and then
          (Interfaces.Unsigned_8 (Character'Pos (Value (Value'First + Limit)))
           and 16#C0#) = 16#80#
      loop
         Limit := Limit - 1;
      end loop;
      return Value (Value'First .. Value'First + Limit - 1);
   end Truncated_Identifier;

   function Hex_Value (Value : Character) return Natural is
   begin
      if Value in '0' .. '9' then
         return Character'Pos (Value) - Character'Pos ('0');
      elsif Value in 'a' .. 'f' then
         return Character'Pos (Value) - Character'Pos ('a') + 10;
      elsif Value in 'A' .. 'F' then
         return Character'Pos (Value) - Character'Pos ('A') + 10;
      end if;
      raise Constraint_Error with "invalid hexadecimal digit";
   end Hex_Value;

   function Based_Value
     (Value : String; Base : Positive) return Interfaces.Integer_64
   is
      Result : Interfaces.Integer_64 := 0;
   begin
      for Item of Value loop
         Result :=
           Result * Interfaces.Integer_64 (Base) +
           Interfaces.Integer_64 (Hex_Value (Item));
      end loop;
      return Result;
   end Based_Value;

   function Narrow_Signed_32
     (Value : Interfaces.Integer_64) return Interfaces.Integer_64
   is
      Modulus : constant Interfaces.Integer_64 :=
        Interfaces.Integer_64 (Interfaces.Unsigned_32'Modulus);
      Low : constant Interfaces.Integer_64 := Value mod Modulus;
   begin
      return
        (if Low <= Interfaces.Integer_64 (Interfaces.Integer_32'Last)
         then Low
         else Low - Modulus);
   end Narrow_Signed_32;

   procedure Add_Unicode
     (Self        : in out Lexer;
      Code        : Interfaces.Integer_64;
      Position    : Natural;
      Add_Context : Boolean := True)
   is
      procedure Add_Byte (Value : Natural) is
      begin
         Append (Self.Literal, Character'Val (Value));
      end Add_Byte;
   begin
      if Code = 0 or else Code > 16#10_FFFF#
        or else Code in 16#D800# .. 16#DFFF#
      then
         Fail (Self, Position, "invalid Unicode escape value", Add_Context);
      else
         declare
            Value : constant Natural := Natural (Code);
         begin
            if Value <= 16#7F# then
               Add_Byte (Value);
            elsif Value <= 16#7FF# then
               Add_Byte (16#C0# + Value / 64);
               Add_Byte (16#80# + Value mod 64);
            elsif Value <= 16#FFFF# then
               Add_Byte (16#E0# + Value / 4_096);
               Add_Byte (16#80# + (Value / 64) mod 64);
               Add_Byte (16#80# + Value mod 64);
            else
               Add_Byte (16#F0# + Value / 262_144);
               Add_Byte (16#80# + (Value / 4_096) mod 64);
               Add_Byte (16#80# + (Value / 64) mod 64);
               Add_Byte (16#80# + Value mod 64);
            end if;
         end;
      end if;
   end Add_Unicode;

   function Keyword_Token (Value : String) return Natural is
      Name : constant String := Lowercase (Value);
   begin
      for Item of Keywords loop
         if Item.Length = Name'Length
           and then Item.Text (1 .. Item.Length) = Name
         then
            return Item.Token;
         end if;
      end loop;
      return 0;
   end Keyword_Token;

   procedure Initialize
     (Self                        : in out Lexer;
      Input                       : String;
      Initial_Token               : Natural := 0;
      Backslash_Quote             : Boolean := True;
      Standard_Conforming_Strings : Boolean := True) is
   begin
      Lexical_DFA.Initialize (Self.Engine, Input);
      Self.Literal := Null_Unbounded_String;
      Self.Dollar_Delimiter := Null_Unbounded_String;
      Self.Previous_String_Condition := Initial_Condition;
      Self.Token_Location := 0;
      Self.Last_Error_Position := 0;
      Self.Last_Error_Add_Context := True;
      Self.Last_Error_Context := Null_Unbounded_String;
      Self.Comment_Depth := 0;
      Self.First_Surrogate := 0;
      Self.Initial_Token := Initial_Token;
      Self.Lookahead_Token := -1;
      Self.Lookahead_Value := Builders.No_Value;
      Self.Lookahead_Location := 0;
      Self.Current_Text := Null_Unbounded_String;
      Self.Lookahead_Text := Null_Unbounded_String;
      Self.Backslash_Quote := Backslash_Quote;
      Self.Standard_Conforming_Strings := Standard_Conforming_Strings;
   end Initialize;

   procedure Integer_Value
     (Self     : in out Lexer;
      Text     : String;
      Base     : Positive;
      Token    : out Integer;
      Value    : out Builders.Dynamic_Value)
   is
      First  : Positive := Text'First;
      Number : Interfaces.Integer_64 := 0;
      Digit  : Natural;
   begin
      if Base /= 10 and then Text'Length >= 2 then
         First := Text'First + 2;
      end if;
      for Index in First .. Text'Last loop
         if Text (Index) /= '_' then
            begin
               Digit := Hex_Value (Text (Index));
            exception
               when Constraint_Error =>
                  --  PostgreSQL's process_integer_literal also receives the
                  --  truncated decimal prefix of a failed exponent match.
                  --  A decimal point therefore means FCONST, not a scanner
                  --  error (for example, "0.0e" is lexed as "0.0", "e").
                  Token := Token_Fconst;
                  Value := Builders.Text (Text);
                  return;
            end;
            if Digit >= Base
              or else Number >
                (Interfaces.Integer_64'Last - Interfaces.Integer_64 (Digit)) /
                Interfaces.Integer_64 (Base)
            then
               Token := Token_Fconst;
               Value := Builders.Text (Text);
               return;
            end if;
            Number := Number * Interfaces.Integer_64 (Base) +
              Interfaces.Integer_64 (Digit);
         end if;
      end loop;
      if Number <= Interfaces.Integer_64 (Interfaces.Integer_32'Last) then
         Token := Token_Iconst;
         Value := Builders.Number (Number);
      else
         Token := Token_Fconst;
         Value := Builders.Text (Text);
      end if;
      pragma Unreferenced (Self);
   end Integer_Value;

   function Unescaped_Character (Value : Character) return Character is
     (case Value is
         when 'b' => Character'Val (8),
         when 'f' => Character'Val (12),
         when 'n' => Character'Val (10),
         when 'r' => Character'Val (13),
         when 't' => Character'Val (9),
         when 'v' =>
           (if Profile.Unescape_Vertical_Tab then Character'Val (11) else Value),
         when others => Value);

   procedure Finish_Quoted
     (Self : in out Lexer; Token : out Integer; Value : out Builders.Dynamic_Value) is
   begin
      case Self.Previous_String_Condition is
         when XB_Condition => Token := Token_Bconst;
         when XH_Condition => Token := Token_Xconst;
         when XQ_Condition | XE_Condition => Token := Token_Sconst;
         when XUS_Condition => Token := Token_Usconst;
         when others =>
            Fail (Self, Self.Token_Location, "unhandled quoted string state");
      end case;
      Value := Builders.Text (To_String (Self.Literal));
   end Finish_Quoted;

   procedure Raw_Token
     (Self     : in out Lexer;
      Token    : out Integer;
      Value    : out Builders.Dynamic_Value;
      Location : out Integer)
   is
      Action : Positive;
      First  : Natural;
      Last   : Natural;
      At_End : Boolean;
   begin
      if Self.Initial_Token /= 0 then
         Token := Integer (Self.Initial_Token);
         Self.Initial_Token := 0;
         Value := Builders.No_Value;
         Location := 0;
         return;
      end if;

      loop
         Lexical_DFA.Match (Self.Engine, Action, First, Last, At_End);
         if At_End then
            case Lexical_DFA.Start_Condition (Self.Engine) is
               when Initial_Condition =>
                  Token := 0;
                  Value := Builders.No_Value;
                  Location := Integer (First);
                  return;
               when XQS_Condition =>
                  Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                  Finish_Quoted (Self, Token, Value);
                  Location := Integer (Self.Token_Location);
                  return;
               when XC_Condition =>
                  Fail (Self, Self.Token_Location, "unterminated /* comment");
               when XB_Condition =>
                  Fail (Self, Self.Token_Location, "unterminated bit string literal");
               when XH_Condition =>
                  Fail
                    (Self, Self.Token_Location,
                     "unterminated hexadecimal string literal");
               when XQ_Condition | XE_Condition | XUS_Condition =>
                  Fail (Self, Self.Token_Location, "unterminated quoted string");
               when XDOLQ_Condition =>
                  Fail
                    (Self, Self.Token_Location,
                     "unterminated dollar-quoted string");
               when XD_Condition | XUI_Condition =>
                  Fail
                    (Self, Self.Token_Location,
                     "unterminated quoted identifier");
               when XEU_Condition => Fail (Self, First, "invalid Unicode surrogate pair");
               when others => Fail (Self, First, "invalid scanner state at end of input");
            end case;
         end if;
         if Action not in Actions'Range then
            Fail (Self, First, "generated scanner action is out of range");
         end if;
         declare
            Rule : constant Tables.Scanner_Action := Actions (Action);
            Text : constant String := Lexical_DFA.Slice (Self.Engine, First, Last);
         begin
            Token := 0;
            Value := Builders.No_Value;
            Location := Integer (First);
            case Rule.Kind is
               when Tables.Ignore => null;
               when Tables.Return_Token =>
                  Token := Rule.Argument;
                  return;
               when Tables.Comment_Start =>
                  Self.Token_Location := First;
                  Self.Comment_Depth := 0;
                  Lexical_DFA.Set_Start_Condition (Self.Engine, XC_Condition);
                  Lexical_DFA.Less (Self.Engine, First, 2);
               when Tables.Comment_Nest =>
                  Self.Comment_Depth := Self.Comment_Depth + 1;
                  Lexical_DFA.Less (Self.Engine, First, 2);
               when Tables.Comment_End =>
                  if Self.Comment_Depth = 0 then
                     Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                     Token := Token_C_Comment;
                     Location := Integer (Self.Token_Location);
                     return;
                  end if;
                  Self.Comment_Depth := Self.Comment_Depth - 1;
               when Tables.Bit_Start | Tables.Hex_Start =>
                  Self.Token_Location := First;
                  Self.Literal := To_Unbounded_String
                    ((if Rule.Kind = Tables.Bit_Start then "b" else "x"));
                  Lexical_DFA.Set_Start_Condition
                    (Self.Engine,
                     (if Rule.Kind = Tables.Bit_Start then XB_Condition else XH_Condition));
               when Tables.Nchar_Start =>
                  Self.Token_Location := First;
                  Lexical_DFA.Less (Self.Engine, First, 1);
                  Token := Integer (Keyword_Token ("nchar"));
                  if Token = 0 then
                     Token := Token_Ident;
                     Value := Builders.Text ("n");
                  else
                     Value := Builders.Text ("nchar");
                  end if;
                  return;
               when Tables.Quote_Start | Tables.Escape_Start |
                    Tables.Unicode_String_Start =>
                  Self.Token_Location := First;
                  Self.Literal := Null_Unbounded_String;
                  Lexical_DFA.Set_Start_Condition
                    (Self.Engine,
                     (if Rule.Kind = Tables.Quote_Start then
                         (if Self.Standard_Conforming_Strings then XQ_Condition else XE_Condition)
                      elsif Rule.Kind = Tables.Escape_Start then XE_Condition
                      else XUS_Condition));
               when Tables.Quote_Stop =>
                  Self.Previous_String_Condition :=
                    Lexical_DFA.Start_Condition (Self.Engine);
                  Lexical_DFA.Set_Start_Condition (Self.Engine, XQS_Condition);
               when Tables.Quote_Continue =>
                  Lexical_DFA.Set_Start_Condition
                    (Self.Engine, Self.Previous_String_Condition);
               when Tables.Quote_Finish =>
                  Lexical_DFA.Less (Self.Engine, First, 0);
                  Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                  Finish_Quoted (Self, Token, Value);
                  Location := Integer (Self.Token_Location);
                  return;
               when Tables.Quote_Double => Append (Self.Literal, ''');
               when Tables.Literal_Add => Append (Self.Literal, Text);
               when Tables.Unicode_Escape =>
                  declare
                     Code : constant Interfaces.Integer_64 :=
                       Based_Value (Text (Text'First + 2 .. Text'Last), 16);
                  begin
                     if Code in 16#D800# .. 16#DBFF# then
                        Self.First_Surrogate := Natural (Code);
                        Lexical_DFA.Set_Start_Condition (Self.Engine, XEU_Condition);
                     elsif Code in 16#DC00# .. 16#DFFF# then
                        Fail (Self, First, "invalid Unicode surrogate pair");
                     else
                        Add_Unicode (Self, Code, First);
                     end if;
                  end;
               when Tables.Unicode_Surrogate =>
                  declare
                     Second : constant Interfaces.Integer_64 :=
                       Based_Value (Text (Text'First + 2 .. Text'Last), 16);
                  begin
                     if Second not in 16#DC00# .. 16#DFFF# then
                        Fail (Self, First, "invalid Unicode surrogate pair");
                     end if;
                     Add_Unicode
                       (Self,
                        16#1_0000# +
                          (Interfaces.Integer_64 (Self.First_Surrogate) - 16#D800#) *
                            1_024 +
                          Second - 16#DC00#,
                        First);
                     Self.First_Surrogate := 0;
                     Lexical_DFA.Set_Start_Condition (Self.Engine, XE_Condition);
                  end;
               when Tables.Unicode_Surrogate_Error =>
                  Fail (Self, First, "invalid Unicode surrogate pair");
               when Tables.Unicode_Escape_Error =>
                  Fail (Self, First, "invalid Unicode escape");
               when Tables.Escape_Character =>
                  if Text (Text'First + 1) = ''' and then not Self.Backslash_Quote then
                     Fail (Self, First, "unsafe use of backslash quote in a string literal");
                  end if;
                  Append (Self.Literal, Unescaped_Character (Text (Text'First + 1)));
               when Tables.Octal_Escape =>
                  declare
                     Code : constant Natural :=
                       Natural
                         (Based_Value (Text (Text'First + 1 .. Text'Last), 8) mod
                            256);
                  begin
                     if Code = 0 then
                        Fail (Self, First, "invalid zero byte in string literal");
                     end if;
                     Append (Self.Literal, Character'Val (Code));
                  end;
               when Tables.Hex_Escape =>
                  declare
                     Code : constant Natural :=
                       Natural
                         (Based_Value (Text (Text'First + 2 .. Text'Last), 16) mod
                            256);
                  begin
                     if Code = 0 then
                        Fail (Self, First, "invalid zero byte in string literal");
                     end if;
                     Append (Self.Literal, Character'Val (Code));
                  end;
               when Tables.Escape_Trailing => Append (Self.Literal, Text);
               when Tables.Dollar_Start =>
                  Self.Token_Location := First;
                  Self.Dollar_Delimiter := To_Unbounded_String (Text);
                  Self.Literal := Null_Unbounded_String;
                  Lexical_DFA.Set_Start_Condition (Self.Engine, XDOLQ_Condition);
               when Tables.Dollar_Failed =>
                  Lexical_DFA.Less (Self.Engine, First, 1);
                  Token := Character'Pos ('$');
                  return;
               when Tables.Dollar_Delimiter =>
                  if Text = To_String (Self.Dollar_Delimiter) then
                     Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                     Token := Token_Sconst;
                     Value := Builders.Text (To_String (Self.Literal));
                     Location := Integer (Self.Token_Location);
                     return;
                  end if;
                  Append (Self.Literal, Text (Text'First .. Text'Last - 1));
                  Lexical_DFA.Less (Self.Engine, First, Text'Length - 1);
               when Tables.Dollar_Character => Append (Self.Literal, Text);
               when Tables.Identifier_Start | Tables.Unicode_Identifier_Start =>
                  Self.Token_Location := First;
                  Self.Literal := Null_Unbounded_String;
                  Lexical_DFA.Set_Start_Condition
                    (Self.Engine,
                     (if Rule.Kind = Tables.Identifier_Start then XD_Condition else XUI_Condition));
               when Tables.Identifier_Stop | Tables.Unicode_Identifier_Stop =>
                  Lexical_DFA.Set_Start_Condition (Self.Engine, Initial_Condition);
                  if Length (Self.Literal) = 0 then
                     Fail
                       (Self, Self.Token_Location,
                        "zero-length delimited identifier");
                  end if;
                  Token :=
                    (if Rule.Kind = Tables.Identifier_Stop then Token_Ident else Token_Uident);
                  Value := Builders.Text
                    ((if Rule.Kind = Tables.Identifier_Stop then
                         Truncated_Identifier (To_String (Self.Literal))
                      else To_String (Self.Literal)));
                  Location := Integer (Self.Token_Location);
                  return;
               when Tables.Identifier_Double => Append (Self.Literal, '"');
               when Tables.Unicode_Failed =>
                  Lexical_DFA.Less (Self.Engine, First, 1);
                  Token := Token_Ident;
                  Value := Builders.Text (Lowercase (Text (Text'First .. Text'First)));
                  return;
               when Tables.Self_Character | Tables.Other_Character =>
                  Token := Character'Pos (Text (Text'First));
                  return;
               when Tables.Operator_Token =>
                  declare
                     Count : Natural := Text'Length;
                     Cut   : Natural := 0;
                     Has_Non_SQL : Boolean := False;
                  begin
                     for Index in Text'First .. Text'Last - 1 loop
                        if Text (Index .. Index + 1) = "/*" or else
                          Text (Index .. Index + 1) = "--"
                        then
                           Cut := Index - Text'First;
                           exit;
                        end if;
                     end loop;
                     if Cut /= 0 then
                        Count := Cut;
                     end if;
                     if Count > 1 and then Text (Text'First + Count - 1) in '+' | '-' then
                        for Index in Text'First .. Text'First + Count - 2 loop
                           if Text (Index) in '~' | '!' | '@' | '#' | '^' | '&' |
                             '|' | '`' | '?' | '%'
                           then
                              Has_Non_SQL := True;
                           end if;
                        end loop;
                        if not Has_Non_SQL then
                           while Count > 1 and then
                             Text (Text'First + Count - 1) in '+' | '-'
                           loop
                              Count := Count - 1;
                           end loop;
                        end if;
                     end if;
                     if Count < Text'Length then
                        Lexical_DFA.Less (Self.Engine, First, Count);
                     end if;
                     declare
                        Operator : constant String := Text (Text'First .. Text'First + Count - 1);
                     begin
                        if Count = 1 and then
                          Ada.Strings.Fixed.Index (",()[].;:+-*/%^<>=", Operator) /= 0
                        then
                           Token := Character'Pos (Operator (Operator'First));
                        elsif Operator = "=>" then Token := Actions (49).Argument;
                        elsif Operator = ">=" then Token := Actions (51).Argument;
                        elsif Operator = "<=" then Token := Actions (50).Argument;
                        elsif Operator = "<>" or else Operator = "!=" then
                           Token := Actions (52).Argument;
                        elsif Count >= 64 then
                           Fail (Self, First, "operator too long");
                        else
                           Token := Token_Op;
                           Value := Builders.Text (Operator);
                        end if;
                     end;
                     return;
                  end;
               when Tables.Parameter_Token =>
                  declare
                     Number : Interfaces.Integer_64 := 0;
                  begin
                     for Index in Text'First + 1 .. Text'Last loop
                        declare
                           Digit : constant Interfaces.Integer_64 :=
                             Interfaces.Integer_64
                               (Character'Pos (Text (Index)) - Character'Pos ('0'));
                        begin
                           Number := Number * 10 + Digit;
                           if Profile.Parameter_Numbers =
                             Tables.Signed_Low_32_Bits
                           then
                              Number := Narrow_Signed_32 (Number);
                           elsif Number >
                             Interfaces.Integer_64 (Interfaces.Integer_32'Last)
                           then
                              Fail (Self, First, "parameter number too large");
                           end if;
                        end;
                     end loop;
                     Token := Token_Param;
                     Value := Builders.Number (Number);
                     return;
                  end;
               when Tables.Integer_Literal =>
                  Integer_Value (Self, Text, Positive (Rule.Argument), Token, Value);
                  return;
               when Tables.Integer_Less =>
                  Lexical_DFA.Less (Self.Engine, First, Text'Length - Rule.Argument);
                  Integer_Value
                    (Self, Text (Text'First .. Text'Last - Rule.Argument), 10, Token, Value);
                  return;
               when Tables.Float_Literal =>
                  Token := Token_Fconst;
                  Value := Builders.Text (Text);
                  return;
               when Tables.Invalid_Integer =>
                  Fail (Self, First, "invalid based integer");
               when Tables.Invalid_Numeric =>
                  Fail (Self, First, "trailing junk after numeric literal");
               when Tables.Invalid_Parameter =>
                  Fail (Self, First, "trailing junk after parameter");
               when Tables.Identifier_Token =>
                  declare
                     Name    : constant String := Lowercase (Text);
                     Keyword : constant Natural := Keyword_Token (Name);
                  begin
                     if Keyword = 0 then
                        Token := Token_Ident;
                        Value := Builders.Text (Truncated_Identifier (Name));
                     else
                        Token := Integer (Keyword);
                        Value := Builders.Text (Name);
                     end if;
                     return;
                  end;
               when Tables.Scanner_Jam => Fail (Self, First, "scanner jammed");
            end case;
         end;
      end loop;
   end Raw_Token;

   function Unicode_Decode
     (Self : in out Lexer; Text : String; Escape : Character; Position : Natural)
      return String
   is
      Result : Unbounded_String;
      Index  : Natural := Text'First;
      First  : Interfaces.Integer_64 := 0;

      procedure Add_Result_Unicode (Code : Interfaces.Integer_64) is
         Saved : constant Unbounded_String := Self.Literal;
      begin
         Self.Literal := Result;
         Add_Unicode
           (Self, Code, Position + Index - Text'First + 3,
            Add_Context => False);
         Result := Self.Literal;
         Self.Literal := Saved;
      end Add_Result_Unicode;
   begin
      while Index <= Text'Last loop
         if Text (Index) /= Escape then
            if First /= 0 then
               Fail
                 (Self, Position + Index - Text'First + 3,
                  "invalid Unicode surrogate pair", Add_Context => False);
            end if;
            Append (Result, Text (Index));
            Index := Index + 1;
         elsif Index < Text'Last and then Text (Index + 1) = Escape then
            if First /= 0 then
               Fail
                 (Self, Position + Index - Text'First + 3,
                  "invalid Unicode surrogate pair", Add_Context => False);
            end if;
            Append (Result, Escape);
            Index := Index + 2;
         else
            declare
               Plus  : constant Boolean := Index < Text'Last and then Text (Index + 1) = '+';
               Count : constant Positive := (if Plus then 6 else 4);
               Start : constant Natural := Index + (if Plus then 2 else 1);
               Code  : Interfaces.Integer_64;
            begin
               if Start + Count - 1 > Text'Last then
                  Fail
                    (Self, Position + Index - Text'First + 3,
                     "invalid Unicode escape", Add_Context => False);
               end if;
               begin
                  Code := Based_Value (Text (Start .. Start + Count - 1), 16);
               exception
                  when Constraint_Error =>
                     Fail
                       (Self, Position + Index - Text'First + 3,
                        "invalid Unicode escape", Add_Context => False);
               end;
               if First /= 0 then
                  if Code not in 16#DC00# .. 16#DFFF# then
                     Fail
                       (Self, Position + Index - Text'First + 3,
                        "invalid Unicode surrogate pair",
                        Add_Context => False);
                  end if;
                  Add_Result_Unicode
                    (16#1_0000# + (First - 16#D800#) * 1_024 + Code - 16#DC00#);
                  First := 0;
               elsif Code in 16#D800# .. 16#DBFF# then
                  First := Code;
               elsif Code in 16#DC00# .. 16#DFFF# then
                  Fail
                    (Self, Position + Index - Text'First + 3,
                     "invalid Unicode surrogate pair", Add_Context => False);
               else
                  Add_Result_Unicode (Code);
               end if;
               Index := Start + Count;
            end;
         end if;
      end loop;
      if First /= 0 then
         Fail
           (Self, Position + Text'Length + 3,
            "invalid Unicode surrogate pair", Add_Context => False);
      end if;
      return To_String (Result);
   end Unicode_Decode;

   procedure Next_Token
     (Self     : in out Lexer;
      Token    : out Integer;
      Value    : out Builders.Dynamic_Value;
      Location : out Integer)
   is
      Next       : Integer;
      Next_Value : Builders.Dynamic_Value;
      Next_Loc   : Integer;
      Next_Text  : Unbounded_String;

      procedure Read_Raw
        (Item : out Integer; Item_Value : out Builders.Dynamic_Value;
         Item_Location : out Integer; Item_Text : out Unbounded_String) is
      begin
         loop
            Raw_Token (Self, Item, Item_Value, Item_Location);
            Item_Text :=
              (if Item_Location < 0
                 or else Natural (Item_Location) >=
                   Lexical_DFA.Position (Self.Engine)
               then Null_Unbounded_String
               else To_Unbounded_String
                 (Lexical_DFA.Slice
                    (Self.Engine, Natural (Item_Location),
                     Lexical_DFA.Position (Self.Engine))));
            exit when Item /= Token_Sql_Comment and then Item /= Token_C_Comment;
         end loop;
      end Read_Raw;
   begin
      if Self.Lookahead_Token >= 0 then
         Token := Self.Lookahead_Token;
         Value := Self.Lookahead_Value;
         Location := Self.Lookahead_Location;
         Self.Current_Text := Self.Lookahead_Text;
         Self.Lookahead_Token := -1;
      else
         Read_Raw (Token, Value, Location, Self.Current_Text);
      end if;

      if Token /= Token_Not
        and then Token /= Token_Nulls
        and then Token /= Token_With
        and then Token /= Token_Uident
        and then Token /= Token_Usconst
        and then (Token_Format = 0 or else Token /= Token_Format)
        and then (Token_Without = 0 or else Token /= Token_Without)
      then
         return;
      end if;
      Read_Raw (Next, Next_Value, Next_Loc, Next_Text);
      Self.Lookahead_Token := Next;
      Self.Lookahead_Value := Next_Value;
      Self.Lookahead_Location := Next_Loc;
      Self.Lookahead_Text := Next_Text;

      if Token_Format /= 0 and then Token = Token_Format and then Next = Token_Json then
         Token := Token_Format_La;
      elsif Token = Token_Not and then
        Next in Token_Between | Token_In | Token_Like | Token_Ilike | Token_Similar
      then
         Token := Token_Not_La;
      elsif Token = Token_Nulls and then Next in Token_First | Token_Last then
         Token := Token_Nulls_La;
      elsif Token = Token_With and then Next in Token_Time | Token_Ordinality then
         Token := Token_With_La;
      elsif Token_Without /= 0 and then Token = Token_Without and then Next = Token_Time then
         Token := Token_Without_La;
      elsif Token in Token_Uident | Token_Usconst then
         declare
            Escape : Character := '\';
         begin
            if Next = Token_Uescape then
               Read_Raw (Next, Next_Value, Next_Loc, Next_Text);
               if Next /= Token_Sconst or else Next_Value.Kind /= Builders.Text_Value or else
                 Length (Next_Value.Text_Data) /= 1
               then
                  Fail (Self, Natural (Next_Loc),
                        "UESCAPE must be followed by a simple string literal");
               end if;
               Escape := Element (Next_Value.Text_Data, 1);
               if Escape in '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' | '+' | ''' | '"' |
                 ' ' | Character'Val (9) | Character'Val (10) | Character'Val (13)
               then
                  Fail (Self, Natural (Next_Loc), "invalid Unicode escape character");
               end if;
               Self.Lookahead_Token := -1;
               Self.Current_Text := To_Unbounded_String
                 (Lexical_DFA.Slice
                    (Self.Engine, Natural (Location),
                     Lexical_DFA.Position (Self.Engine)));
            end if;
            Value := Builders.Text
              (Unicode_Decode (Self, To_String (Value.Text_Data), Escape, Natural (Location)));
            if Token = Token_Uident then
               Token := Token_Ident;
               Value := Builders.Text
                 (Truncated_Identifier (To_String (Value.Text_Data)));
            else
               Token := Token_Sconst;
            end if;
         end;
      end if;
   end Next_Token;

   function Error_Position (Self : Lexer) return Natural is
     (Self.Last_Error_Position + 1);

   procedure Error_Context
     (Self        : Lexer;
      Add_Context : out Boolean;
      Text        : out Ada.Strings.Unbounded.Unbounded_String)
   is
   begin
      Add_Context := Self.Last_Error_Add_Context;
      Text := Self.Last_Error_Context;
   end Error_Context;

   function Token_Text (Self : Lexer) return String is
     (To_String (Self.Current_Text));

end Flyology.Postgres.SQL.Native.Scanner;
