--  REPL-2: Replication.Decode_Command hard-codes LOGICAL immediately after
--  the slot name, so it rejects the TEMPORARY and PHYSICAL forms of
--  CREATE_REPLICATION_SLOT.
--
--  PostgreSQL's grammar is
--    repl_gram.y 18.4:178-199 (identical in 14.23:230-252, 15.18:178-200,
--    16.14:176-198, 17.10)
--      K_CREATE_REPLICATION_SLOT IDENT opt_temporary K_PHYSICAL
--          create_slot_options
--    | K_CREATE_REPLICATION_SLOT IDENT opt_temporary K_LOGICAL IDENT
--          create_slot_options
--  so TEMPORARY sits between the slot name and the PHYSICAL/LOGICAL keyword,
--  and a physical slot has no plugin.
--
--  pg_basebackup sends the temporary physical form BY DEFAULT.  Its
--  temp_replication_slot flag is initialized true (pg_basebackup.c 18.4:148)
--  and the default -X stream reaches pg_basebackup.c 18.4:664-671:
--      replication_slot = psprintf("pg_basebackup_%u", ...);
--      CreateReplicationSlot(param->bgconn, replication_slot, NULL,
--                            temp_replication_slot, true, true, ...)
--  which streamutil.c 18.4:601-616 renders as
--      CREATE_REPLICATION_SLOT "pg_basebackup_NNNN" TEMPORARY PHYSICAL
--          (RESERVE_WAL)
--  A PostgreSQL walreceiver with wal_receiver_create_temp_slot on emits the
--  same shape (walreceiver.c 18.4:356-362 with temporary => true, rendered by
--  libpqwalreceiver.c 18.4:925-926 and :985 " PHYSICAL (RESERVE_WAL)").
--  pg_receivewal --create-slot and pg_basebackup -C send the non-temporary
--  physical form (pg_receivewal.c 18.4:891-892).
--
--  Correct behavior asserted here: each of those three commands decodes and
--  names its slot instead of raising "expected LOGICAL in replication
--  command".

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Repro_Support; use Repro_Support;

procedure Repro_Repl_2 is

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

   procedure Try_Decode
     (Label     : String;
      Text      : String;
      Expected  : String;
      Decoded   : out Boolean;
      Slot_Seen : out Boolean);
   --  Decode Text, reporting whether it decoded at all and whether the
   --  decoded command names Expected as its slot.

   procedure Try_Decode
     (Label     : String;
      Text      : String;
      Expected  : String;
      Decoded   : out Boolean;
      Slot_Seen : out Boolean) is
   begin
      Decoded := False;
      Slot_Seen := False;
      Note (Label & " sends: " & Text);
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query (Text));
      begin
         Decoded := True;
         Slot_Seen := Replication.Slot_Name (Item) = Expected;
         Note ("  decoded: kind="
               & Replication.Command_Kind'Image (Replication.Kind (Item))
               & " slot=" & Replication.Slot_Name (Item));
      end;
   exception
      when E : Protocol.Protocol_Error =>
         Note ("  Decode_Command raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Note ("  Decode_Command raised "
               & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end Try_Decode;

   Temp_Physical_Decoded : Boolean;
   Temp_Physical_Slot    : Boolean;
   Physical_Decoded      : Boolean;
   Physical_Slot         : Boolean;
   Temp_Logical_Decoded  : Boolean;
   Temp_Logical_Slot     : Boolean;

   Temp_Logical_Kind     : Boolean := False;
   Temp_Logical_Plugin   : Boolean := False;
   Temp_Logical_Snapshot : Boolean := False;

begin
   Try_Decode
     ("pg_basebackup, default -X stream",
      "CREATE_REPLICATION_SLOT ""pg_basebackup_1234"" TEMPORARY PHYSICAL"
      & " (RESERVE_WAL)",
      "pg_basebackup_1234",
      Temp_Physical_Decoded,
      Temp_Physical_Slot);

   Try_Decode
     ("pg_receivewal --create-slot",
      "CREATE_REPLICATION_SLOT ""wal_archive"" PHYSICAL (RESERVE_WAL)",
      "wal_archive",
      Physical_Decoded,
      Physical_Slot);

   Try_Decode
     ("a temporary logical slot (libpqrcv_create_slot, temporary => true)",
      "CREATE_REPLICATION_SLOT ""sub_slot"" TEMPORARY LOGICAL pgoutput"
      & " (SNAPSHOT 'nothing')",
      "sub_slot",
      Temp_Logical_Decoded,
      Temp_Logical_Slot);

   --  The temporary LOGICAL form has an unambiguous decoded shape today, so
   --  check its fields as well.
   begin
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command
             (Query
                ("CREATE_REPLICATION_SLOT ""sub_slot"" TEMPORARY LOGICAL"
                 & " pgoutput (SNAPSHOT 'nothing')"));
      begin
         Temp_Logical_Kind :=
           Replication.Kind (Item) = Replication.Create_Logical_Slot_Command;
         Temp_Logical_Plugin := Replication.Plugin (Item) = "pgoutput";
         Temp_Logical_Snapshot :=
           Replication.Snapshot (Item) = Replication.No_Snapshot;
      end;
   exception
      when Protocol.Protocol_Error =>
         null;
   end;

   Check
     (Temp_Physical_Decoded,
      "Decode_Command accepts the temporary physical slot creation "
      & "pg_basebackup sends by default");
   Check
     (Temp_Physical_Slot,
      "that command names slot pg_basebackup_1234");
   Check
     (Physical_Decoded,
      "Decode_Command accepts the physical slot creation "
      & "pg_receivewal --create-slot sends");
   Check
     (Physical_Slot,
      "that command names slot wal_archive");
   Check
     (Temp_Logical_Decoded,
      "Decode_Command accepts TEMPORARY between the slot name and LOGICAL");
   Check
     (Temp_Logical_Slot and then Temp_Logical_Kind,
      "the temporary logical form still classifies as "
      & "Create_Logical_Slot_Command naming slot sub_slot");
   Check
     (Temp_Logical_Plugin and then Temp_Logical_Snapshot,
      "the temporary logical form still exposes plugin pgoutput and "
      & "SNAPSHOT 'nothing'");

   Finish;
end Repro_Repl_2;
