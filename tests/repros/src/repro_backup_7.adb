--  BACKUP-7: Base_Backups.Server_Sessions.Send_Position declares the "tli"
--  result column as int4 (OID 23, width 4) where every supported PostgreSQL
--  major declares int8.
--
--  server_sessions.adb:23-46 builds the start/end position result set with
--     Protocol.Make_Field_Description ("tli", Type_Oid => 23, Type_Size => 4)
--  PostgreSQL 14 (src/backend/replication/basebackup.c,
--  SendXlogRecPtrResult) and 15-18 (src/backend/backup/basebackup_copy.c,
--  SendXlogRecPtrResult) both send INT8OID = 20, with the comment
--     "int8 may seem like a surprising data type for this, but in theory
--      int4 would not be wide enough for this, as TimeLineID is unsigned."
--  16-18 build the same descriptor through
--     TupleDescInitBuiltinEntry (tupdesc, 2, "tli", INT8OID, -1, 0).
--
--  Both Send_Start_Position and Send_End_Position route through
--  Send_Position, so a server or proxy built on this package advertises a
--  different row shape from the PostgreSQL server it stands in for.  The
--  text value itself is still correct, so this library's own Receiver and
--  pg_basebackup are unaffected; a typed client is not.
--
--  Correct behavior: the tli column is advertised as int8, OID 20.

with Ada.Streams;
with Flyology.Postgres.Replication.Base_Backups.Server_Sessions;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_7 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Backup_Sessions renames
     Flyology.Postgres.Replication.Base_Backups.Server_Sessions;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Int16;
   use type Protocol.UInt32;

   Int8_Oid : constant Protocol.UInt32 := 20;
   --  PostgreSQL INT8OID, from src/include/catalog/pg_type.dat.

   Channel : aliased Memory_Transport;
   Session : Sessions.Session (Channel'Access);

   function First_Message (Data : Protocol.Byte_Array) return Protocol.Message;

   function First_Message
     (Data : Protocol.Byte_Array) return Protocol.Message
   is
      Length : Natural := 0;
   begin
      for Offset in Ada.Streams.Stream_Element_Offset range 1 .. 4 loop
         Length := Length * 256 + Natural (Data (Data'First + Offset));
      end loop;
      return Protocol.Make_Message
        (Character'Val (Natural (Data (Data'First))),
         Data (Data'First + 5 .. Data'First + 4
                 + Ada.Streams.Stream_Element_Offset (Length) - 4));
   end First_Message;

begin
   Backup_Sessions.Send_Start_Position
     (Session, Position => 16#100#, Timeline => 1, Timeout => 1.0);

   declare
      Frame   : constant Protocol.Byte_Array := Sent (Channel);
      Decoded : constant Protocol.Backend_Message :=
        Protocol.Decode_Backend (First_Message (Frame));
   begin
      Check
        (Protocol.Response_Kind (Decoded) =
           Protocol.Row_Description_Response,
         "the start-position result set opens with a RowDescription "
         & "(harness sanity check)");

      declare
         Row : constant Protocol.Row_Description :=
           Protocol.Description (Decoded);
      begin
         Check (Protocol.Field_Count (Row) = 2,
                "the result set has the two PostgreSQL columns recptr and "
                & "tli (harness sanity check)");

         declare
            Tli : constant Protocol.Field_Description :=
              Protocol.Field_At (Row, 2);
         begin
            Note ("column 2 is """ & Protocol.Field_Name (Tli)
                  & """ with type OID"
                  & Protocol.UInt32'Image (Protocol.Type_Oid (Tli))
                  & " and width"
                  & Protocol.Int16'Image (Protocol.Type_Size (Tli)));
            Note ("PostgreSQL 14 through 18 send type OID"
                  & Protocol.UInt32'Image (Int8_Oid) & " (int8)");

            Check (Protocol.Field_Name (Tli) = "tli",
                   "column 2 is named tli (harness sanity check)");
            Check
              (Protocol.Type_Oid (Tli) = Int8_Oid,
               "the tli column is advertised as int8 (OID 20), the type "
               & "every supported PostgreSQL major sends for it");
         end;
      end;
   end;

   Finish;
end Repro_Backup_7;
