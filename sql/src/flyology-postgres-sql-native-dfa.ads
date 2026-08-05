with Ada.Strings.Unbounded;
with Flyology.Postgres.SQL.Native.Tables;

generic
   Transitions : Tables.Transition_Array;
   Starts      : Tables.Integer_Array;
package Flyology.Postgres.SQL.Native.DFA is

   type Scanner is tagged limited private;

   procedure Initialize (Self : in out Scanner; Input : String);
   procedure Match
     (Self : in out Scanner; Action : out Positive;
      First, Last : out Natural; At_End : out Boolean);

   function Slice (Self : Scanner; First, Last : Natural) return String;
   function Position (Self : Scanner) return Natural;
   procedure Less (Self : in out Scanner; First : Natural; Length : Natural);
   function Start_Condition (Self : Scanner) return Positive;
   procedure Set_Start_Condition (Self : in out Scanner; Value : Positive);

private

   type Scanner is tagged limited record
      Input     : Ada.Strings.Unbounded.Unbounded_String;
      Cursor    : Natural := 0;
      Condition : Positive := 1;
   end record;

end Flyology.Postgres.SQL.Native.DFA;
