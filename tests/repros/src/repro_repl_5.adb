--  REPL-5: Replication.Server_Sessions.Send_Identify_System declares the
--  IDENTIFY_SYSTEM "timeline" result column as int4 (OID 23, width 4) for
--  every peer, but PostgreSQL changed that column's type in 16.
--
--  server_sessions.adb:47-79 builds the four-column result set with
--     Protocol.Make_Field_Description ("timeline", Type_Oid => 23,
--                                      Type_Size => 4)
--  src/backend/replication/walsender.c IdentifySystem() declares column 2 as
--     14.23  :444-445  TupleDescInitBuiltinEntry (.., 2, "timeline", INT4OID)
--     15.18  :460-461  TupleDescInitBuiltinEntry (.., 2, "timeline", INT4OID)
--     16.14  :462-463  TupleDescInitBuiltinEntry (.., 2, "timeline", INT8OID)
--     17.10  :475-476  TupleDescInitBuiltinEntry (.., 2, "timeline", INT8OID)
--     18.4   :445-446  TupleDescInitBuiltinEntry (.., 2, "timeline", INT8OID)
--  and the datum construction follows: Int32GetDatum in 14/15 (:458, :474),
--  Int64GetDatum in 16/17/18 (:476, :489, :459).  So int4 is right for two of
--  the five supported majors and wrong for the other three.
--
--  Send_Identify_System takes no server major (server_sessions.ads:9-15), so
--  the column type is not merely mis-chosen: the API cannot express the 16+
--  answer at all.  A single unconditional constant, as used for BASE_BACKUP's
--  "tli" (BACKUP-7), is not available here because the two answers differ.
--
--  The text value on the wire is unchanged, and the stock clients read the
--  value as text -- libpqwalreceiver.c libpqrcv_identify_system uses
--  PQgetvalue + pg_strtoint32 and streamutil.c RunIdentifySystem uses
--  PQgetvalue + atoi, neither consulting the type OID -- so this is a
--  protocol-fidelity defect against typed clients, not a stock-client break.
--
--  Correct behavior for a PostgreSQL 16, 17 or 18 peer: the timeline column
--  is advertised as int8, OID 20, width 8.

with Ada.Streams;
with Flyology.Postgres.Replication.Server_Sessions;
with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Repl_5 is

   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Replication_Sessions renames
     Flyology.Postgres.Replication.Server_Sessions;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.Int16;
   use type Protocol.UInt32;

   Int4_Oid : constant Protocol.UInt32 := 23;
   Int8_Oid : constant Protocol.UInt32 := 20;
   --  PostgreSQL INT4OID and INT8OID, from src/include/catalog/pg_type.dat.

   Int8_Width : constant Protocol.Int16 := 8;
   --  int8 typlen, sent as the RowDescription type size.

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
   --  A server standing in for a PostgreSQL 16, 17 or 18 primary.
   Replication_Sessions.Send_Identify_System
     (Session,
      System_Id   => 7_000_000_000_000_000_001,
      Timeline    => 1,
      Current_WAL => 16#100#,
      Database    => "",
      Timeout     => 1.0);

   declare
      Frame   : constant Protocol.Byte_Array := Sent (Channel);
      Decoded : constant Protocol.Backend_Message :=
        Protocol.Decode_Backend (First_Message (Frame));
   begin
      Check
        (Protocol.Response_Kind (Decoded) =
           Protocol.Row_Description_Response,
         "the IDENTIFY_SYSTEM result set opens with a RowDescription "
         & "(harness sanity check)");

      declare
         Row : constant Protocol.Row_Description :=
           Protocol.Description (Decoded);
      begin
         Check (Protocol.Field_Count (Row) = 4,
                "the result set has the four PostgreSQL columns systemid, "
                & "timeline, xlogpos and dbname (harness sanity check)");

         declare
            Tli : constant Protocol.Field_Description :=
              Protocol.Field_At (Row, 2);
         begin
            Note ("column 2 is """ & Protocol.Field_Name (Tli)
                  & """ with type OID"
                  & Protocol.UInt32'Image (Protocol.Type_Oid (Tli))
                  & " and width"
                  & Protocol.Int16'Image (Protocol.Type_Size (Tli)));
            Note ("PostgreSQL 14 and 15 send type OID"
                  & Protocol.UInt32'Image (Int4_Oid) & " (int4);"
                  & " PostgreSQL 16, 17 and 18 send type OID"
                  & Protocol.UInt32'Image (Int8_Oid) & " (int8)");
            Note ("Send_Identify_System takes no server major, so one "
                  & "declaration is used for every peer");

            Check (Protocol.Field_Name (Tli) = "timeline",
                   "column 2 is named timeline (harness sanity check)");
            Check
              (Protocol.Type_Oid (Tli) = Int8_Oid,
               "the timeline column is advertised as int8 (OID 20) for a "
               & "PostgreSQL 16 or newer peer, as walsender.c "
               & "IdentifySystem sends");
            Check
              (Protocol.Type_Size (Tli) = Int8_Width,
               "the timeline column carries the int8 width of 8 for a "
               & "PostgreSQL 16 or newer peer");
         end;
      end;
   end;

   Finish;
end Repro_Repl_5;
