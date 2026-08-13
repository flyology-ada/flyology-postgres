with Ada.Strings.Unbounded;
with Psqlbench_Context;

package Psqlbench_Query is

   Max_Query_Bytes : constant := 16 * 1_024;
   Max_Query_Event_Bytes : constant := 16 * 1_024;
   Query_Event_Capacity : constant := 1_024;

   type Query_Event is record
      Sequence : Psqlbench_Context.Event_Sequence := 0;
      Data     : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Query_Event_Array is array (Positive range <>) of Query_Event;

   protected type Event_Stream is
      procedure Append (Value : String);
      procedure Finish;
      function Done return Boolean;
      procedure Read_After
        (After     : Psqlbench_Context.Event_Sequence;
         Value     : out Query_Event;
         Available : out Boolean;
         Dropped   : out Psqlbench_Context.Event_Sequence);
   private
      Events        : Query_Event_Array (1 .. Query_Event_Capacity);
      Head          : Positive := 1;
      Count         : Natural range 0 .. Query_Event_Capacity := 0;
      Next_Sequence : Psqlbench_Context.Event_Sequence := 1;
      Finished      : Boolean := False;
   end Event_Stream;

   protected type Cancellation_State is
      procedure Request;
      function Requested return Boolean;
   private
      Is_Requested : Boolean := False;
   end Cancellation_State;

   procedure Execute
     (Name         : String;
      Port         : Positive;
      SQL          : String;
      Events       : in out Event_Stream;
      Cancellation : in out Cancellation_State);

end Psqlbench_Query;
