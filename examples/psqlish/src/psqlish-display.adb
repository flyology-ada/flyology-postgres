with Ada.Characters.Latin_1;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Psqlish.Display is

   function Hex_Digit (Value : Natural) return Character is
     (if Value < 10
      then Character'Val (Character'Pos ('0') + Value)
      else Character'Val (Character'Pos ('A') + Value - 10));

   function Limit
     (Value         : String;
      Maximum_Width : Positive;
      Was_Truncated : out Boolean) return String is
      Result : Unbounded_String;
      Used   : Natural := 0;

      procedure Append_Piece (Piece : String) is
      begin
         if Used <= Maximum_Width - Natural'Min (Maximum_Width, Piece'Length)
         then
            Append (Result, Piece);
            Used := Used + Piece'Length;
         else
            Was_Truncated := True;
         end if;
      end Append_Piece;
   begin
      Was_Truncated := False;
      for Byte of Value loop
         exit when Was_Truncated;
         case Byte is
            when Ada.Characters.Latin_1.LF =>
               Append_Piece ("\n");
            when Ada.Characters.Latin_1.CR =>
               Append_Piece ("\r");
            when Ada.Characters.Latin_1.HT =>
               Append_Piece ("\t");
            when Character'Val (0) .. Character'Val (8) |
                 Character'Val (11) .. Character'Val (12) |
                 Character'Val (14) .. Character'Val (31) |
                 Character'Val (127) =>
               declare
                  Code : constant Natural := Character'Pos (Byte);
               begin
                  Append_Piece
                    ((1 => '\', 2 => 'x',
                      3 => Hex_Digit (Code / 16),
                      4 => Hex_Digit (Code mod 16)));
               end;
            when others =>
               Append_Piece ((1 => Byte));
         end case;
      end loop;
      if Was_Truncated then
         declare
            Text : constant String := To_String (Result);
         begin
            if Text'Length > 3 then
               return Text (Text'First .. Text'Last - 3) & "...";
            else
               return "...";
            end if;
         end;
      end if;
      return To_String (Result);
   end Limit;

   function Text_Cell
     (Value : String; Maximum_Width : Positive := Positive'Last) return Cell is
      Truncated : Boolean;
      Text      : constant String := Limit (Value, Maximum_Width, Truncated);
   begin
      return
        (Null_Value => False,
         Binary     => False,
         Value      => To_Unbounded_String (Text),
         Truncated  => Truncated);
   end Text_Cell;

   function Binary_Cell
     (Value : String; Maximum_Width : Positive := Positive'Last) return Cell is
      Encoded : Unbounded_String := To_Unbounded_String ("\x");
      Truncated : Boolean := False;
   begin
      for Byte of Value loop
         if Length (Encoded) > Maximum_Width - Natural'Min (Maximum_Width, 2)
         then
            Truncated := True;
            exit;
         end if;
         declare
            Code : constant Natural := Character'Pos (Byte);
         begin
            Append (Encoded, Hex_Digit (Code / 16));
            Append (Encoded, Hex_Digit (Code mod 16));
         end;
      end loop;
      if Truncated then
         declare
            Text : constant String := To_String (Encoded);
         begin
            Encoded := To_Unbounded_String
              (Text (Text'First .. Text'Last - 3) & "...");
         end;
      end if;
      return
        (Null_Value => False,
         Binary     => True,
         Value      => Encoded,
         Truncated  => Truncated);
   end Binary_Cell;

   function Null_Cell return Cell is
     ((Null_Value => True,
       Binary     => False,
       Value      => Null_Unbounded_String,
       Truncated  => False));

   function Make_Column
     (Name          : String;
      Binary        : Boolean := False;
      Maximum_Width : Positive := Positive'Last) return Column is
      Truncated : Boolean;
      Text      : constant String := Limit (Name, Maximum_Width, Truncated);
      pragma Unreferenced (Truncated);
   begin
      return (Name => To_Unbounded_String (Text), Binary => Binary);
   end Make_Column;

   procedure Configure_Limits
     (Item : in out Result_State; Limits : Display_Limits) is
   begin
      if not Item.Columns.Is_Empty or else not Item.Rows.Is_Empty then
         raise Program_Error with "cannot change limits during a result";
      end if;
      Item.Limits := Limits;
   end Configure_Limits;

   procedure Set_Expanded (Item : in out Result_State; Enabled : Boolean) is
   begin
      Item.Is_Expanded := Enabled;
   end Set_Expanded;

   function Expanded (Item : Result_State) return Boolean is
     (Item.Is_Expanded);

   procedure Set_Null_Text (Item : in out Result_State; Value : String) is
      Truncated : Boolean;
   begin
      Item.Null_Value := To_Unbounded_String
        (Limit (Value, Item.Limits.Cell_Width, Truncated));
   end Set_Null_Text;

   function Null_Text (Item : Result_State) return String is
     (To_String (Item.Null_Value));

   procedure Reset_Result (Item : in out Result_State) is
   begin
      Item.Columns.Clear;
      Item.Rows.Clear;
      Item.Total_Rows := 0;
      Item.Buffered_Bytes := 0;
      Item.Omitted_Rows := 0;
      Item.Truncated_Cells := 0;
   end Reset_Result;

   procedure Begin_Result
     (Item : in out Result_State; Columns : Column_Array) is
   begin
      Reset_Result (Item);
      for Value of Columns loop
         Item.Columns.Append (Value);
         Item.Buffered_Bytes := Item.Buffered_Bytes + Length (Value.Name);
      end loop;
   end Begin_Result;

   function Try_Add_Row
     (Item : in out Result_State; Values : Cell_Array) return Boolean is
      Size : Natural := 0;
      Value_Row : Row;
   begin
      if Values'Length /= Natural (Item.Columns.Length) then
         raise Constraint_Error with "row width does not match result columns";
      end if;
      for Value of Values loop
         Size := Size +
           (if Value.Null_Value
            then Length (Item.Null_Value)
            else Length (Value.Value));
      end loop;
      if Natural (Item.Rows.Length) >= Item.Limits.Buffered_Rows
        or else Size > Item.Limits.Result_Bytes -
          Natural'Min (Item.Limits.Result_Bytes, Item.Buffered_Bytes)
      then
         return False;
      end if;
      Item.Total_Rows := Item.Total_Rows + 1;
      for Value of Values loop
         Value_Row.Values.Append (Value);
         if Value.Truncated then
            Item.Truncated_Cells := Item.Truncated_Cells + 1;
         end if;
      end loop;
      Item.Rows.Append (Value_Row);
      Item.Buffered_Bytes := Item.Buffered_Bytes + Size;
      return True;
   end Try_Add_Row;

   procedure Add_Row (Item : in out Result_State; Values : Cell_Array) is
   begin
      if not Try_Add_Row (Item, Values) then
         Item.Total_Rows := Item.Total_Rows + 1;
         Item.Omitted_Rows := Item.Omitted_Rows + 1;
      end if;
   end Add_Row;

   function Spaces (Count : Natural) return String is
     (1 .. Count => ' ');

   function Dashes (Count : Natural; Fill : Character := '-') return String is
     (1 .. Count => Fill);

   function Image (Value : Natural) return String is
      Raw : constant String := Natural'Image (Value);
   begin
      return Raw (Raw'First + 1 .. Raw'Last);
   end Image;

   function Is_Numeric (Value : String) return Boolean is
      Saw_Digit : Boolean := False;
      Saw_Dot   : Boolean := False;
      Saw_Exp   : Boolean := False;
      Need_Exp_Digit : Boolean := False;
   begin
      if Value'Length = 0 then
         return False;
      end if;
      for Index in Value'Range loop
         declare
            Ch : constant Character := Value (Index);
         begin
            if Ch in '0' .. '9' then
               Saw_Digit := True;
               Need_Exp_Digit := False;
            elsif (Ch = '+' or else Ch = '-')
              and then (Index = Value'First
                        or else Value (Index - 1) in 'e' | 'E')
            then
               null;
            elsif Ch = '.' and then not Saw_Dot and then not Saw_Exp then
               Saw_Dot := True;
            elsif Ch in 'e' | 'E' and then Saw_Digit and then not Saw_Exp then
               Saw_Exp := True;
               Need_Exp_Digit := True;
            else
               return False;
            end if;
         end;
      end loop;
      return Saw_Digit and then not Need_Exp_Digit;
   end Is_Numeric;

   function Cell_Text (Item : Result_State; Value : Cell) return String is
     (if Value.Null_Value
      then To_String (Item.Null_Value)
      else To_String (Value.Value));

   function Finish_Result
     (Item        : in out Result_State;
      Command_Tag : String := "";
      Empty_Query : Boolean := False) return String is
      Output : Unbounded_String;

      procedure Line (Text : String := "") is
      begin
         Append (Output, Text);
         Append (Output, ASCII.LF);
      end Line;
   begin
      if Empty_Query then
         Line ("(empty query)");
      elsif Item.Columns.Is_Empty then
         if Command_Tag'Length > 0 then
            Line (Command_Tag);
         end if;
      else
         declare
            Count : constant Positive := Natural (Item.Columns.Length);
            Widths : array (1 .. Count) of Natural := (others => 0);
            Numeric : array (1 .. Count) of Boolean := (others => True);
            Saw_Value : array (1 .. Count) of Boolean := (others => False);

            function Border (Fill : Character) return String is
               Value : Unbounded_String := To_Unbounded_String ("+");
            begin
               for Width of Widths loop
                  Append (Value, Dashes (Width + 2, Fill));
                  Append (Value, "+");
               end loop;
               return To_String (Value);
            end Border;
         begin
            for Index in 1 .. Count loop
               Widths (Index) := Length (Item.Columns.Element (Index).Name);
            end loop;
            for Value_Row of Item.Rows loop
               for Index in 1 .. Count loop
                  declare
                     Value : constant Cell := Value_Row.Values.Element (Index);
                     Text  : constant String := Cell_Text (Item, Value);
                  begin
                     Widths (Index) :=
                       Natural'Max (Widths (Index), Text'Length);
                     if not Value.Null_Value then
                        Saw_Value (Index) := True;
                        Numeric (Index) := Numeric (Index)
                          and then not Value.Binary and then Is_Numeric (Text);
                     end if;
                  end;
               end loop;
            end loop;
            for Index in Numeric'Range loop
               Numeric (Index) := Numeric (Index) and then Saw_Value (Index);
            end loop;

            if Item.Is_Expanded then
               for Row_Index in 1 .. Natural (Item.Rows.Length) loop
                  Line
                    ("-[ RECORD" & Positive'Image (Row_Index) & " ]-"
                     & Dashes (Natural'Max (1, Row_Index mod 7)));
                  for Index in 1 .. Count loop
                     declare
                        Name  : constant String :=
                          To_String (Item.Columns.Element (Index).Name);
                        Value : constant String := Cell_Text
                          (Item, Item.Rows.Element (Row_Index).Values.Element
                             (Index));
                     begin
                        Line
                          (Name & Spaces (Widths (Index) - Name'Length)
                           & " | " & Value);
                     end;
                  end loop;
               end loop;
            else
               Line (Border ('-'));
               declare
                  Header : Unbounded_String := To_Unbounded_String ("|");
               begin
                  for Index in 1 .. Count loop
                     declare
                        Name : constant String :=
                          To_String (Item.Columns.Element (Index).Name);
                     begin
                        Append
                          (Header,
                           " " & Name & Spaces (Widths (Index) - Name'Length)
                           & " |");
                     end;
                  end loop;
                  Line (To_String (Header));
               end;
               Line (Border ('='));
               for Value_Row of Item.Rows loop
                  declare
                     Row_Text : Unbounded_String := To_Unbounded_String ("|");
                  begin
                     for Index in 1 .. Count loop
                        declare
                           Value : constant Cell :=
                             Value_Row.Values.Element (Index);
                           Text : constant String := Cell_Text (Item, Value);
                           Padding : constant String :=
                             Spaces (Widths (Index) - Text'Length);
                        begin
                           if Numeric (Index)
                             and then not Value.Null_Value
                           then
                              Append (Row_Text, " " & Padding & Text & " |");
                           else
                              Append (Row_Text, " " & Text & Padding & " |");
                           end if;
                        end;
                     end loop;
                     Line (To_String (Row_Text));
                  end;
               end loop;
               Line (Border ('-'));
            end if;
            Line
              ("(" & Image (Item.Total_Rows) &
               (if Item.Total_Rows = 1 then " row)" else " rows)"));
            if Item.Omitted_Rows > 0 then
               Line
                 ("... " & Natural'Image (Item.Omitted_Rows)
                  & " rows not displayed (buffer limit reached)");
            end if;
            if Item.Truncated_Cells > 0 then
               Line
                 ("... " & Natural'Image (Item.Truncated_Cells)
                  & " cells truncated to"
                  & Natural'Image (Item.Limits.Cell_Width) & " bytes");
            end if;
            if Command_Tag'Length > 0 then
               Line (Command_Tag);
            end if;
         end;
      end if;
      declare
         Result : constant String := To_String (Output);
      begin
         Reset_Result (Item);
         return Result;
      end;
   end Finish_Result;

end Psqlish.Display;
