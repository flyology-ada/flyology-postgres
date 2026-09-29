--  PROTO-6: Read_C_String bundles "buffer too large", "cursor before the
--  buffer" and "cursor past the end" into one Require whose message is
--  "Postgres string exceeds the configured limit".  An exhausted (or empty)
--  buffer therefore reports a size-limit violation instead of the documented
--  "No terminator remains in Source" condition.

with Ada.Exceptions;
with Ada.Strings.Fixed;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_6 is

   package Sessions renames Flyology.Postgres.Server_Sessions;

   function Message_Of_Failure
     (Label : String; Payload : Protocol.Byte_Array) return String
   is
      Cursor : Protocol.Byte_Offset := Payload'First;
   begin
      declare
         Text : constant String := Protocol.Read_C_String (Payload, Cursor);
      begin
         Note (Label & ": Read_C_String unexpectedly succeeded, returning """
               & Text & """");
         return "";
      end;
   exception
      when E : Protocol.Protocol_Error =>
         return Ada.Exceptions.Exception_Message (E);
   end Message_Of_Failure;

   function Mentions_Termination (Text : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, "unterminated") > 0
      or else Ada.Strings.Fixed.Index (Text, "terminator") > 0);

   Empty     : constant Protocol.Byte_Array (1 .. 0) := (others => 0);
   One_Byte  : constant Protocol.Byte_Array := B ("a");

   Empty_Message    : constant String :=
     Message_Of_Failure ("empty buffer", Empty);
   Nonempty_Message : constant String :=
     Message_Of_Failure ("one unterminated byte", One_Byte);

   Query_Message : String (1 .. 200);
   Query_Last    : Natural := 0;

begin
   Note ("protocol.ads:690 -- ""@exception Protocol_Error No terminator "
         & "remains in Source.""");
   Note ("empty (1 .. 0) buffer, cursor 1 -> """ & Empty_Message & """");
   Note ("one-byte unterminated buffer      -> """ & Nonempty_Message & """");

   Check
     (Mentions_Termination (Nonempty_Message),
      "an unterminated non-empty buffer reports a missing terminator");
   Check
     (Mentions_Termination (Empty_Message),
      "an empty buffer reports a missing terminator, not a size-limit "
      & "violation");

   --  Reachable path: a frontend Query message with an empty payload.
   begin
      declare
         Text : constant String :=
           Sessions.Query_Text (Protocol.Make_Message ('Q', Empty));
      begin
         Note ("Query_Text on an empty 'Q' payload returned """ & Text & """");
      end;
   exception
      when E : Protocol.Protocol_Error =>
         declare
            Text : constant String := Ada.Exceptions.Exception_Message (E);
         begin
            Query_Last := Natural'Min (Text'Length, Query_Message'Length);
            Query_Message (1 .. Query_Last) :=
              Text (Text'First .. Text'First + Query_Last - 1);
         end;
   end;

   Note ("Server_Sessions.Query_Text on an empty 'Q' payload -> """
         & Query_Message (1 .. Query_Last) & """");
   Check
     (Query_Last > 0
      and then Mentions_Termination (Query_Message (1 .. Query_Last)),
      "an empty Query payload is diagnosed as an unterminated string, not "
      & "as exceeding the configured message-size limit");

   Finish;
end Repro_Proto_6;
