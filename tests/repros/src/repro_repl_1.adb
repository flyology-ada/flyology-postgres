--  REPL-1: Replication.Decode_Command rejects the valueless boolean options
--  PostgreSQL itself emits inside the parenthesized CREATE_REPLICATION_SLOT
--  option list.
--
--  PostgreSQL's replication grammar makes a bare option name a DefElem with a
--  NULL argument:
--    repl_gram.y (15.18:377-381, 17.10:401-405, 18.4:405-409)
--      generic_option:
--          ident_or_keyword           { $$ = makeDefElem($1, NULL, -1); }
--  and walsender.c reads it with defGetBoolean (18.4:1164-1181), whose
--  contract is define.c:94-100 -- "If no parameter value given, assume
--  'true' is meant."  A bare TWO_PHASE therefore means TWO_PHASE = true.
--
--  That is exactly the text PostgreSQL's own clients send.  A PostgreSQL 15+
--  subscriber with two_phase enabled reaches libpqwalreceiver.c
--  libpqrcv_create_slot (15.18:957-965, 18.4:933-940):
--      appendStringInfoString(&cmd, " LOGICAL pgoutput ");
--      appendStringInfoChar(&cmd, '(');
--      if (two_phase) { appendStringInfoString(&cmd, "TWO_PHASE");
--                       appendStringInfoString(&cmd, ", "); }
--      ... "SNAPSHOT 'nothing'" ... ')'
--  and a PostgreSQL 17+ subscriber with failover enabled appends a bare
--  FAILOVER the same way (17.10:1067-1074, 18.4:942-949).  pg_recvlogical
--  --create-slot --two-phase produces the same list through
--  streamutil.c AppendPlainCommandOption (18.4:624-626).
--
--  Correct behavior asserted here: both forms decode, TWO_PHASE without a
--  value means True, and the accompanying SNAPSHOT is still honored.

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Repro_Support; use Repro_Support;

procedure Repro_Repl_1 is

   package Replication renames Flyology.Postgres.Replication;

   use type Replication.Command_Kind;
   use type Replication.Snapshot_Action;

   function Query (Text : String) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Text);
      return Protocol.Make_Message
        ('Q', Flyology.Bytes.To_Array (Contents));
   end Query;

   --  Exactly what libpqrcv_create_slot writes for a two-phase subscription
   --  slot on a PostgreSQL 15 or newer publisher.
   Two_Phase_Text : constant String :=
     "CREATE_REPLICATION_SLOT ""sub_slot"" LOGICAL pgoutput "
     & "(TWO_PHASE, SNAPSHOT 'nothing')";

   --  Exactly what a PostgreSQL 17 or newer subscriber writes when the
   --  subscription requests slot failover.
   Failover_Text : constant String :=
     "CREATE_REPLICATION_SLOT ""sub_slot"" LOGICAL pgoutput "
     & "(FAILOVER, SNAPSHOT 'nothing')";

   Two_Phase_Decoded  : Boolean := False;
   Two_Phase_Kind     : Boolean := False;
   Two_Phase_Flag     : Boolean := False;
   Two_Phase_Snapshot : Boolean := False;
   Failover_Decoded   : Boolean := False;

begin
   Note ("PostgreSQL 15+ two-phase subscriber sends: " & Two_Phase_Text);
   begin
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query (Two_Phase_Text));
      begin
         Two_Phase_Decoded := True;
         Two_Phase_Kind :=
           Replication.Kind (Item) = Replication.Create_Logical_Slot_Command;
         Two_Phase_Flag := Replication.Two_Phase (Item);
         Two_Phase_Snapshot :=
           Replication.Snapshot (Item) = Replication.No_Snapshot;
         Note ("  decoded: slot=" & Replication.Slot_Name (Item)
               & " plugin=" & Replication.Plugin (Item)
               & " two_phase=" & Boolean'Image (Replication.Two_Phase (Item))
               & " snapshot="
               & Replication.Snapshot_Action'Image
                   (Replication.Snapshot (Item)));
      end;
   exception
      when E : Protocol.Protocol_Error =>
         Note ("  Decode_Command raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Note ("  Decode_Command raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   Note ("PostgreSQL 17+ failover subscriber sends: " & Failover_Text);
   begin
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query (Failover_Text));
      begin
         Failover_Decoded :=
           Replication.Kind (Item) = Replication.Create_Logical_Slot_Command;
         Note ("  decoded: slot=" & Replication.Slot_Name (Item)
               & " snapshot="
               & Replication.Snapshot_Action'Image
                   (Replication.Snapshot (Item)));
      end;
   exception
      when E : Protocol.Protocol_Error =>
         Note ("  Decode_Command raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Note ("  Decode_Command raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   Check
     (Two_Phase_Decoded,
      "Decode_Command accepts the valueless TWO_PHASE option a "
      & "PostgreSQL 15+ two-phase subscriber sends");
   Check
     (Two_Phase_Kind,
      "that command classifies as Create_Logical_Slot_Command");
   Check
     (Two_Phase_Flag,
      "a valueless TWO_PHASE means True, as defGetBoolean specifies for a "
      & "DefElem with a NULL argument");
   Check
     (Two_Phase_Snapshot,
      "the accompanying SNAPSHOT 'nothing' is still decoded");
   Check
     (Failover_Decoded,
      "Decode_Command accepts the valueless FAILOVER option a "
      & "PostgreSQL 17+ failover subscriber sends");

   Finish;
end Repro_Repl_1;
