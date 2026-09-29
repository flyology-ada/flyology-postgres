--  PROTO-1: Framing.Read_Message documents "a single deadline" for the whole
--  message but hands the full Timeout to each of its three transport reads.
--  Correct behavior: Read_Message either completes within Timeout or raises
--  Flyology.IO.Timeout_Error.

with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Streams;
with Flyology.IO;
with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_1 is

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;

   package Framing renames Flyology.Postgres.Framing;

   Message_Timeout : constant Duration := 0.30;
   --  Deadline handed to Read_Message for the complete message.
   Stall_Per_Read  : constant Duration := 0.25;
   --  Time the peer stalls before satisfying each individual transport read.
   Tolerance       : constant Duration := 0.10;
   --  Scheduling slack allowed on top of the documented deadline.

   procedure Burn (Amount : Duration) is
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Amount);
   begin
      while Ada.Real_Time.Clock < Deadline loop
         null;
      end loop;
   end Burn;

   Max_Calls : constant := 8;

   type Duration_Log is array (1 .. Max_Calls) of Duration;

   type Stalling_Transport is limited new Transports.Transport with record
      Buffer  : Protocol.Byte_Array (1 .. 64) := (others => 0);
      Length  : Protocol.Byte_Offset := 0;
      Next    : Protocol.Byte_Offset := 1;
      Calls   : Natural := 0;
      Granted : Duration_Log := (others => 0.0);
   end record;
   --  Peer that answers every read, but only after stalling for
   --  Stall_Per_Read.  It records the Timeout the framing layer granted to
   --  each individual read.

   overriding procedure Receive_Exactly
     (Item    : in out Stalling_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null);

   overriding procedure Send_All
     (Item    : in out Stalling_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Receive_Exactly
     (Item    : in out Stalling_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
   is
      pragma Unreferenced (On_Wait);
   begin
      Item.Calls := Item.Calls + 1;
      if Item.Calls <= Max_Calls then
         Item.Granted (Item.Calls) := Timeout;
      end if;

      Burn (Stall_Per_Read);

      if Data'Length > Item.Length - Item.Next + 1 then
         raise Program_Error with "stalling transport input is exhausted";
      end if;
      for Index in Data'Range loop
         Data (Index) := Item.Buffer (Item.Next);
         Item.Next := Item.Next + 1;
      end loop;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Stalling_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration)
   is
      pragma Unreferenced (Item, Data, Timeout);
   begin
      raise Program_Error with "unexpected send";
   end Send_All;

   Frame : constant Protocol.Byte_Array :=
     Protocol.Encode
       (Protocol.Make_Message
          ('Z', (1 => Protocol.Byte (Character'Pos ('I')))));
   --  ReadyForQuery: one tag byte, a four-byte length, one payload byte, so
   --  Read_Message issues exactly three transport reads.

   Channel   : Stalling_Transport;
   Started   : Ada.Real_Time.Time;
   Elapsed   : Duration := 0.0;
   Completed : Boolean := False;
   Timed_Out : Boolean := False;
   Other     : Boolean := False;

begin
   Channel.Buffer (Frame'First .. Frame'Last) := Frame;
   Channel.Length := Frame'Last;

   Note ("frame bytes: " & Hex (Frame));
   Note ("Read_Message Timeout =" & Duration'Image (Message_Timeout) & "s;"
         & " peer stalls" & Duration'Image (Stall_Per_Read)
         & "s before satisfying each transport read");

   Started := Ada.Real_Time.Clock;
   begin
      declare
         Result : constant Protocol.Message :=
           Framing.Read_Message (Channel, Message_Timeout);
      begin
         Completed := True;
         Note ("Read_Message returned a '" & Protocol.Code (Result)
               & "' message");
      end;
   exception
      when Flyology.IO.Timeout_Error =>
         Timed_Out := True;
         Note ("Read_Message raised Flyology.IO.Timeout_Error");
      when E : others =>
         Other := True;
         Note ("Read_Message raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;
   Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);

   Note ("transport reads issued:" & Natural'Image (Channel.Calls));
   for Index in 1 .. Natural'Min (Channel.Calls, Max_Calls) loop
      Note ("  read" & Natural'Image (Index) & " was granted a timeout of"
            & Duration'Image (Channel.Granted (Index)) & "s");
   end loop;
   Note ("wall-clock time spent inside Read_Message:"
         & Duration'Image (Elapsed) & "s");

   Check (not Other, "Read_Message raises no unrelated exception");
   Check
     (Timed_Out or else Elapsed <= Message_Timeout + Tolerance,
      "Read_Message honors its documented single deadline: it either "
      & "completes within Timeout or raises Timeout_Error");

   if Completed and then Elapsed > Message_Timeout + Tolerance then
      Note ("the whole-message deadline was exceeded by"
            & Duration'Image (Elapsed - Message_Timeout) & "s"
            & " because each read re-armed the full timeout");
   end if;

   Finish;
end Repro_Proto_1;
