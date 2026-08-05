with Ada.Characters.Handling;
with Flyology.Postgres.SQL;
with Flyology.Postgres.SQL.Views;

package body Pgish_SQL is

   use Ada.Characters.Handling;

   function Make_Text (Value : String; Capacity : Positive) return Text is
      Result : Text (Capacity);
   begin
      if Value'Length > Capacity then
         raise Syntax_Error with "SQL token exceeds its bounded length";
      end if;
      Result.Length := Value'Length;
      if Value'Length > 0 then
         Result.Data (1 .. Value'Length) := Value;
      end if;
      return Result;
   end Make_Text;

   function Image (Value : Text) return String is
     (if Value.Length = 0 then "" else Value.Data (1 .. Value.Length));

   function Is_Empty (Value : Text) return Boolean is (Value.Length = 0);

   type Token_Kind is
     (Identifier_Token,
      String_Token,
      Number_Token,
      Star_Token,
      Comma_Token,
      Dot_Token,
      Left_Paren_Token,
      Right_Paren_Token,
      Operator_Token,
      Semicolon_Token,
      End_Token);

   type Token is record
      Kind : Token_Kind := End_Token;
      Value : Value_Text;
   end record;
   type Token_Array is array (Positive range 1 .. Maximum_Tokens) of Token;

   procedure Tokenize
     (SQL : String; Tokens : out Token_Array; Count : out Positive) is
      Cursor : Integer := SQL'First;
      Used   : Natural := 0;

      procedure Add (Kind : Token_Kind; Value : String := "") is
      begin
         if Used = Maximum_Tokens then
            raise Syntax_Error with "SQL token limit exceeded";
         end if;
         Used := Used + 1;
         Tokens (Used) :=
           (Kind => Kind, Value => Make_Text (Value, Maximum_Value_Length));
      end Add;

      function At_End return Boolean is (Cursor > SQL'Last);
   begin
      if SQL'Length > Maximum_Query_Length then
         raise Syntax_Error with "SQL query limit exceeded";
      end if;
      Tokens := (others => <>);
      while not At_End loop
         if SQL (Cursor) in ' ' | ASCII.HT | ASCII.CR | ASCII.LF then
            Cursor := Cursor + 1;
         elsif SQL (Cursor) = ''' then
            declare
               Buffer : String (1 .. Maximum_Value_Length);
               Length : Natural := 0;
               Closed : Boolean := False;
            begin
               Cursor := Cursor + 1;
               while not At_End loop
                  if SQL (Cursor) = ''' then
                     if Cursor < SQL'Last and then SQL (Cursor + 1) = ''' then
                        if Length = Buffer'Last then
                           raise Syntax_Error with "string literal is too long";
                        end if;
                        Length := Length + 1;
                        Buffer (Length) := ''';
                        Cursor := Cursor + 2;
                     else
                        Closed := True;
                        Cursor := Cursor + 1;
                        exit;
                     end if;
                  else
                     if Length = Buffer'Last then
                        raise Syntax_Error with "string literal is too long";
                     end if;
                     Length := Length + 1;
                     Buffer (Length) := SQL (Cursor);
                     Cursor := Cursor + 1;
                  end if;
               end loop;
               if not Closed then
                  raise Syntax_Error with "unterminated string literal";
               end if;
               Add (String_Token,
                    (if Length = 0 then "" else Buffer (1 .. Length)));
            end;
         elsif SQL (Cursor) = '"' then
            declare
               Buffer : String (1 .. Maximum_Name_Length);
               Length : Natural := 0;
               Closed : Boolean := False;
            begin
               Cursor := Cursor + 1;
               while not At_End loop
                  if SQL (Cursor) = '"' then
                     if Cursor < SQL'Last and then SQL (Cursor + 1) = '"' then
                        if Length = Buffer'Last then
                           raise Syntax_Error with "quoted identifier is too long";
                        end if;
                        Length := Length + 1;
                        Buffer (Length) := '"';
                        Cursor := Cursor + 2;
                     else
                        Closed := True;
                        Cursor := Cursor + 1;
                        exit;
                     end if;
                  else
                     if Length = Buffer'Last then
                        raise Syntax_Error with "quoted identifier is too long";
                     end if;
                     Length := Length + 1;
                     Buffer (Length) := SQL (Cursor);
                     Cursor := Cursor + 1;
                  end if;
               end loop;
               if not Closed or else Length = 0 then
                  raise Syntax_Error with "invalid quoted identifier";
               end if;
               Add (Identifier_Token, Buffer (1 .. Length));
            end;
         elsif Is_Alphanumeric (SQL (Cursor)) or else SQL (Cursor) = '_' then
            declare
               First : constant Integer := Cursor;
               Numeric : constant Boolean := Is_Digit (SQL (Cursor));
            begin
               while not At_End
                 and then
                   (Is_Alphanumeric (SQL (Cursor))
                    or else SQL (Cursor) in '_' | '$')
               loop
                  Cursor := Cursor + 1;
               end loop;
               Add
                 ((if Numeric then Number_Token else Identifier_Token),
                  (if Numeric
                   then SQL (First .. Cursor - 1)
                   else To_Lower (SQL (First .. Cursor - 1))));
            end;
         elsif SQL (Cursor) = '-'
           and then Cursor < SQL'Last
           and then Is_Digit (SQL (Cursor + 1))
         then
            declare
               First : constant Integer := Cursor;
            begin
               Cursor := Cursor + 2;
               while not At_End and then Is_Digit (SQL (Cursor)) loop
                  Cursor := Cursor + 1;
               end loop;
               Add (Number_Token, SQL (First .. Cursor - 1));
            end;
         else
            case SQL (Cursor) is
               when '*' => Add (Star_Token); Cursor := Cursor + 1;
               when ',' => Add (Comma_Token); Cursor := Cursor + 1;
               when '.' => Add (Dot_Token); Cursor := Cursor + 1;
               when '(' => Add (Left_Paren_Token); Cursor := Cursor + 1;
               when ')' => Add (Right_Paren_Token); Cursor := Cursor + 1;
               when ';' => Add (Semicolon_Token); Cursor := Cursor + 1;
               when '=' => Add (Operator_Token, "="); Cursor := Cursor + 1;
               when '!' | '<' | '>' =>
                  declare
                     First : constant Integer := Cursor;
                  begin
                     Cursor := Cursor + 1;
                     if not At_End and then SQL (Cursor) = '=' then
                        Cursor := Cursor + 1;
                     elsif SQL (First) = '<'
                       and then not At_End
                       and then SQL (Cursor) = '>'
                     then
                        Cursor := Cursor + 1;
                     elsif SQL (First) = '!' then
                        raise Syntax_Error with "expected != operator";
                     end if;
                     Add (Operator_Token, SQL (First .. Cursor - 1));
                  end;
               when others =>
                  raise Syntax_Error with
                    "unsupported character in SQL: " & SQL (Cursor);
            end case;
         end if;
      end loop;
      Add (End_Token);
      Count := Used;
   end Tokenize;

   function Parse (SQL : String) return Query is
      Full_Tree : Flyology.Postgres.SQL.Views.Syntax_Tree;
      Tokens : Token_Array;
      Count  : Positive;
      Cursor : Positive := 1;
      Result : Query;

      function Current return Token is (Tokens (Cursor));
      function Word return String is (To_Lower (Image (Current.Value)));
      function Is_Word (Value : String) return Boolean is
        (Current.Kind = Identifier_Token and then Word = Value);

      procedure Advance is
      begin
         if Cursor < Count then
            Cursor := Cursor + 1;
         end if;
      end Advance;

      procedure Expect (Kind : Token_Kind; Message : String) is
      begin
         if Current.Kind /= Kind then
            raise Syntax_Error with Message;
         end if;
      end Expect;

      procedure Expect_Word (Value : String) is
      begin
         if not Is_Word (Value) then
            raise Syntax_Error with "expected " & Value;
         end if;
         Advance;
      end Expect_Word;

      function Qualified_Name return Name_Text is
         Buffer : String (1 .. Maximum_Name_Length);
         Length : Natural := 0;

         procedure Append (Part : String) is
         begin
            if Length + Part'Length > Buffer'Length then
               raise Syntax_Error with "qualified identifier is too long";
            end if;
            if Part'Length > 0 then
               Buffer (Length + 1 .. Length + Part'Length) := Part;
               Length := Length + Part'Length;
            end if;
         end Append;
      begin
         Expect (Identifier_Token, "expected identifier");
         Append (Image (Current.Value));
         Advance;
         while Current.Kind = Dot_Token loop
            Advance;
            Expect (Identifier_Token, "expected identifier after dot");
            Append (".");
            Append (Image (Current.Value));
            Advance;
         end loop;
         return Make_Text (Buffer (1 .. Length), Maximum_Name_Length);
      end Qualified_Name;

      function Is_Clause return Boolean is
        (Is_Word ("from") or else Is_Word ("where")
         or else Is_Word ("order") or else Is_Word ("limit")
         or else Is_Word ("and") or else Current.Kind in Comma_Token |
           Semicolon_Token | End_Token);

      procedure Parse_Alias (Item : in out Projection) is
      begin
         if Is_Word ("as") then
            Advance;
            Expect (Identifier_Token, "expected alias after AS");
            Item.Alias := Make_Text (Image (Current.Value), Maximum_Name_Length);
            Advance;
         elsif Current.Kind = Identifier_Token and then not Is_Clause then
            Item.Alias := Make_Text (Image (Current.Value), Maximum_Name_Length);
            Advance;
         end if;
      end Parse_Alias;

      procedure Add_Projection is
         Item : Projection;
         Identifier : Name_Text;
         Lower : Value_Text;
      begin
         if Result.Projection_Count = Maximum_Projections then
            raise Syntax_Error with "projection limit exceeded";
         end if;
         if Current.Kind = Star_Token then
            Item.Kind := Star_Projection;
            Advance;
         elsif Current.Kind in String_Token | Number_Token then
            Item.Kind := Literal_Projection;
            Item.Literal := Current.Value;
            Advance;
         elsif Current.Kind = Identifier_Token then
            if Is_Word ("from") or else Is_Word ("where")
              or else Is_Word ("order") or else Is_Word ("limit")
            then
               raise Syntax_Error with "expected projection expression";
            end if;
            Identifier := Qualified_Name;
            Lower := Make_Text (To_Lower (Image (Identifier)), Maximum_Value_Length);
            if Current.Kind = Left_Paren_Token then
               Advance;
               Expect (Right_Paren_Token, "only zero-argument functions are supported");
               Advance;
               Item.Kind := Function_Projection;
               if Image (Lower) = "current_database" then
                  Item.Function_Id := Current_Database_Function;
               elsif Image (Lower) = "version" then
                  Item.Function_Id := Version_Function;
               elsif Image (Lower) = "now" then
                  Item.Function_Id := Now_Function;
               else
                  raise Syntax_Error with "unsupported SQL function: " & Image (Identifier);
               end if;
               Item.Name := Identifier;
            elsif Image (Lower) = "current_user" then
               Item.Kind := Function_Projection;
               Item.Function_Id := Current_User_Function;
               Item.Name := Identifier;
            else
               Item.Kind := Column_Projection;
               Item.Name := Identifier;
            end if;
         else
            raise Syntax_Error with "expected projection expression";
         end if;
         Parse_Alias (Item);
         Result.Projection_Count := Result.Projection_Count + 1;
         Result.Projections (Result.Projection_Count) := Item;
      end Add_Projection;

      procedure Add_Predicate is
         Item : Predicate;
      begin
         if Result.Predicate_Count = Maximum_Predicates then
            raise Syntax_Error with "predicate limit exceeded";
         end if;
         Item.Column := Qualified_Name;
         if Is_Word ("is") then
            Advance;
            if Is_Word ("not") then
               Advance;
               Expect_Word ("null");
               Item.Operator := Is_Not_Null;
            else
               Expect_Word ("null");
               Item.Operator := Is_Null;
            end if;
         elsif Is_Word ("like") then
            Advance;
            Item.Operator := Like_Match;
            Expect (String_Token, "LIKE requires a quoted pattern");
            Item.Value := Current.Value;
            Advance;
         elsif Current.Kind = Operator_Token then
            if Image (Current.Value) = "=" then
               Item.Operator := Equal_To;
            elsif Image (Current.Value) in "!=" | "<>" then
               Item.Operator := Not_Equal_To;
            elsif Image (Current.Value) = "<" then
               Item.Operator := Less_Than;
            elsif Image (Current.Value) = "<=" then
               Item.Operator := Less_Or_Equal;
            elsif Image (Current.Value) = ">" then
               Item.Operator := Greater_Than;
            elsif Image (Current.Value) = ">=" then
               Item.Operator := Greater_Or_Equal;
            else
               raise Syntax_Error with "unsupported comparison operator";
            end if;
            Advance;
            if Current.Kind not in String_Token | Number_Token then
               raise Syntax_Error with "comparison requires a literal value";
            end if;
            Item.Value := Current.Value;
            Advance;
         else
            raise Syntax_Error with "expected predicate operator";
         end if;
         Result.Predicate_Count := Result.Predicate_Count + 1;
         Result.Predicates (Result.Predicate_Count) := Item;
      end Add_Predicate;

      procedure Finish is
      begin
         if Current.Kind = Semicolon_Token then
            Advance;
         end if;
         if Current.Kind /= End_Token then
            raise Syntax_Error with "only one SQL statement is supported";
         end if;
      end Finish;
   begin
      --  The bounded evaluator below intentionally implements only pgish's
      --  read-only subset.  Syntax acceptance and diagnostics nevertheless
      --  come from PostgreSQL 18's actual grammar, so its lexer cannot drift
      --  from the server that pgish emulates.
      Flyology.Postgres.SQL.Views.Parse
        (SQL, Flyology.Postgres.SQL.PostgreSQL_18, Full_Tree);
      if not Flyology.Postgres.SQL.Views.Is_Valid (Full_Tree) then
         declare
            Error : constant Flyology.Postgres.SQL.Diagnostic :=
              Flyology.Postgres.SQL.Views.Error (Full_Tree);
         begin
            raise Syntax_Error with
              Flyology.Postgres.SQL.Views.Message (Error)
              & " at character"
              & Flyology.Postgres.SQL.Views.Cursor_Position (Error)'Image;
         end;
      end if;
      Tokenize (SQL, Tokens, Count);
      if Is_Word ("show") then
         Result.Kind := Show_Statement;
         Advance;
         Result.Show_Name := Qualified_Name;
         Finish;
         return Result;
      end if;

      Expect_Word ("select");
      Result.Kind := Select_Statement;
      loop
         Add_Projection;
         exit when Current.Kind /= Comma_Token;
         Advance;
      end loop;
      if Is_Word ("from") then
         Advance;
         Result.Table_Name := Qualified_Name;
      end if;
      if Is_Word ("where") then
         if Is_Empty (Result.Table_Name) then
            raise Syntax_Error with "WHERE requires a virtual table";
         end if;
         Advance;
         loop
            Add_Predicate;
            exit when not Is_Word ("and");
            Advance;
         end loop;
      end if;
      if Is_Word ("order") then
         Advance;
         Expect_Word ("by");
         Result.Order_Column := Qualified_Name;
         if Is_Word ("asc") then
            Advance;
         elsif Is_Word ("desc") then
            Result.Order_Descending := True;
            Advance;
         end if;
      end if;
      if Is_Word ("limit") then
         Advance;
         Expect (Number_Token, "LIMIT requires a non-negative integer");
         begin
            Result.Limit := Natural'Value (Image (Current.Value));
         exception
            when Constraint_Error =>
               raise Syntax_Error with
                 "LIMIT exceeds the server row limit of" &
                 Maximum_Result_Rows'Image;
         end;
         Result.Has_Limit := True;
         Advance;
      end if;
      Finish;
      return Result;
   end Parse;

end Pgish_SQL;
