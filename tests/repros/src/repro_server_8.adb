--  SERVER-8: the pre-authentication startup packet length is accepted up to
--  Maximum_Message_Size (16 MiB) and Framing.Read_Contents allocates a heap
--  buffer of that size from the client-supplied length word BEFORE any
--  payload byte has arrived
--  (src/flyology-postgres-framing.adb:30-31, :51-59;
--   src/flyology-postgres-wire.ads:316-317).
--
--  PostgreSQL bounds the same unauthenticated allocation at
--  MAX_STARTUP_PACKET_LENGTH = 10000 (src/include/libpq/pqcomm.h:148) and
--  answers anything larger with
--     FATAL "invalid length of startup packet"
--  before calling palloc (src/backend/tcop/backend_startup.c:543-556).
--
--  Correct behavior asserted here: an initial packet whose declared length
--  exceeds PostgreSQL's startup bound is rejected before a buffer of that
--  size is committed.  The exact bound is a policy value the repository has
--  not chosen; PostgreSQL's own is used as the reference point.

with Ada.Exceptions;
with Ada.Streams;
with Flyology.IO;
with Flyology.Postgres.Framing;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports;
with Repro_Support; use Repro_Support;

procedure Repro_Server_8 is

   use type Ada.Streams.Stream_Element_Offset;

   package Framing renames Flyology.Postgres.Framing;

   PG_Max_Startup_Packet_Length : constant := 10_000;
   --  src/include/libpq/pqcomm.h: #define MAX_STARTUP_PACKET_LENGTH 10000
   --  (the value excludes the four length bytes, as does Content_Length).

   Declared_Length : constant := 16#0100_0000#;
   --  16777216 = Flyology.Postgres.Maximum_Message_Size, the largest value
   --  Wire.Valid_Initial_Length still accepts.

   type Length_Only_Transport is limited new Transports.Transport with record
      Reads     : Natural := 0;
      Requested : Ada.Streams.Stream_Element_Offset := 0;
   end record;
   --  A peer that supplies only the four length bytes and then goes silent,
   --  which is all an attacker has to send to make the server commit the
   --  buffer.

   overriding procedure Receive_Exactly
     (Item    : in out Length_Only_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null);

   overriding procedure Send_All
     (Item    : in out Length_Only_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration);

   overriding procedure Receive_Exactly
     (Item    : in out Length_Only_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Transports.Wait_Observer'Class := null)
   is
      pragma Unreferenced (Timeout, On_Wait);
   begin
      Item.Reads := Item.Reads + 1;
      if Item.Reads = 1 then
         --  The four-byte length word: 0x01000000.
         Data := (16#01#, 16#00#, 16#00#, 16#00#);
         return;
      end if;
      --  The library has already allocated Data'Length bytes on the heap by
      --  the time it asks the peer for the payload.
      Item.Requested := Data'Length;
      Data := (others => 0);
      raise Flyology.IO.Timeout_Error with "peer sends no payload";
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out Length_Only_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration)
   is
      pragma Unreferenced (Item, Data, Timeout);
   begin
      raise Program_Error with "unexpected send";
   end Send_All;

   Channel  : Length_Only_Transport;
   Rejected : Boolean := False;

begin
   Note ("client-declared initial packet length:"
         & Integer'Image (Declared_Length)
         & " (Wire.Valid_Initial_Length accepts up to Maximum_Message_Size)");
   Note ("PostgreSQL's cap on the same unauthenticated packet:"
         & Integer'Image (PG_Max_Startup_Packet_Length + 4));

   begin
      declare
         Ignored : constant Protocol.Initial_Request :=
           Framing.Read_Initial (Channel, 30.0);
         pragma Unreferenced (Ignored);
      begin
         Note ("Read_Initial returned unexpectedly");
      end;
   exception
      when Protocol.Protocol_Error =>
         Rejected := True;
         Note ("Read_Initial rejected the declared length before reading "
               & "any payload");
      when E : others =>
         Note ("Read_Initial raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   Note ("transport reads issued:" & Natural'Image (Channel.Reads));
   Note ("payload bytes the library asked for (= heap buffer it had already"
         & " allocated):" & Ada.Streams.Stream_Element_Offset'Image
           (Channel.Requested));

   Check
     (Rejected or else Channel.Requested <= PG_Max_Startup_Packet_Length,
      "an unauthenticated startup packet does not cause an allocation "
      & "larger than PostgreSQL's MAX_STARTUP_PACKET_LENGTH before any "
      & "payload byte has been received");

   if not Rejected and then Channel.Requested > PG_Max_Startup_Packet_Length
   then
      Note ("four attacker-supplied bytes committed"
            & Ada.Streams.Stream_Element_Offset'Image (Channel.Requested)
            & " bytes of heap per connection, held for the whole startup "
            & "timeout, on every worker the listener admits");
   end if;

   Finish;
end Repro_Server_8;
