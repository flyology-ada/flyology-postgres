with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;

package body Flyology.Postgres.SQL.Native.DFA is

   procedure Initialize (Self : in out Scanner; Input : String) is
   begin
      Self.Input := To_Unbounded_String (Input);
      Self.Cursor := 0;
      Self.Condition := 1;
   end Initialize;

   procedure Match
     (Self : in out Scanner; Action : out Positive;
      First, Last : out Natural; At_End : out Boolean)
   is
      State : Integer;
      Byte  : Natural;
      Index : Integer;
      Step  : Tables.Transition;
      Limit : constant Natural := Length (Self.Input);
      Last_Action : Natural := 0;
      Last_Cursor : Natural := Self.Cursor;
   begin
      First := Self.Cursor;
      if Self.Cursor >= Limit then
         Last := Self.Cursor;
         At_End := True;
         Action := 1;
         return;
      end if;
      if Self.Condition > Starts'Last then
         raise Constraint_Error with "invalid generated scanner start condition";
      end if;
      State := Starts (Self.Condition);

      loop
         if Self.Cursor >= Limit then
            exit;
         end if;
         if Self.Cursor < Limit then
            Byte := Character'Pos (Element (Self.Input, Self.Cursor + 1));
         else
            Byte := 0;
         end if;
         Index := State + Integer (Byte);
         exit when Index not in Transitions'Range;
         Step := Transitions (Index);
         exit when Step.Verify /= Integer (Byte);
         State := State + Step.Offset;
         Self.Cursor := Self.Cursor + 1;
         if State - 1 in Transitions'Range
           and then Transitions (State - 1).Verify = 0
           and then Transitions (State - 1).Offset > 0
         then
            Last_Action := Natural (Transitions (State - 1).Offset);
            Last_Cursor := Self.Cursor;
         end if;
      end loop;

      if Last_Action = 0 then
         raise Constraint_Error with "generated PostgreSQL scanner jammed";
      end if;
      Action := Positive (Last_Action);
      Self.Cursor := Last_Cursor;
      Last := Last_Cursor;
      At_End := False;
   end Match;

   function Slice (Self : Scanner; First, Last : Natural) return String is
     (if Last <= First then ""
      else Ada.Strings.Unbounded.Slice (Self.Input, First + 1, Last));

   function Position (Self : Scanner) return Natural is (Self.Cursor);

   procedure Less (Self : in out Scanner; First : Natural; Length : Natural) is
   begin
      Self.Cursor := First + Length;
   end Less;

   function Start_Condition (Self : Scanner) return Positive is
     (Self.Condition);

   procedure Set_Start_Condition (Self : in out Scanner; Value : Positive) is
   begin
      if Value not in Starts'Range then
         raise Constraint_Error with "invalid scanner start condition";
      end if;
      Self.Condition := Value;
   end Set_Start_Condition;

end Flyology.Postgres.SQL.Native.DFA;
