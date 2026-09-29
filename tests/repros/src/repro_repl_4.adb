--  REPL-4: replication SHOW rejects the dotted GUC names PostgreSQL accepts.
--
--  Both the Show constructor (replication.adb:183-189) and Decode_Command's
--  SHOW branch (replication.adb:503-514) validate the parameter with
--    replication.adb:100-104
--      function Is_Option_Name (Name : String) return Boolean is
--        (Name'Length > 0
--         and then (for all Item of Name =>
--                     Item in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_'));
--  which forbids '.'.
--
--  PostgreSQL's replication grammar builds a dotted GUC name explicitly:
--    repl_gram.y 18.4:153-164 (identical in 14.23:141-152)
--      show: K_SHOW var_name { ... n->name = $2; ... }
--      var_name: IDENT              { $$ = $1; }
--              | var_name '.' IDENT { $$ = psprintf("%s.%s", $1, $3); }
--  and repl_scanner.l 18.4:211-214 returns '.' as itself, so
--  SHOW myext.my_setting is valid replication-mode syntax on every supported
--  major.  Namespaced GUCs are how PostgreSQL extensions expose settings.
--
--  No stock PostgreSQL client sends a dotted SHOW today -- streamutil.c
--  18.4:293 and :367 only issue SHOW wal_segment_size and
--  SHOW data_directory_mode -- so this is an edge-case rejection of valid
--  input rather than a default-path interop break.
--
--  Correct behavior asserted here: Show builds the command, and
--  Decode_Command round-trips the dotted parameter name.

with Ada.Exceptions;
with Ada.Streams;
with Flyology.Bytes;
with Flyology.Postgres.Replication;
with Repro_Support; use Repro_Support;

procedure Repro_Repl_4 is

   package Replication renames Flyology.Postgres.Replication;

   use type Ada.Streams.Stream_Element_Offset;
   use type Replication.Command_Kind;

   Guc : constant String := "myext.my_setting";

   function Query (Text : String) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, Text);
      return Protocol.Make_Message
        ('Q', Flyology.Bytes.To_Array (Contents));
   end Query;

   function Query_Text (Item : Protocol.Message) return String is
      Data : constant Protocol.Byte_Array := Protocol.Payload (Item);
   begin
      return Flyology.Bytes.To_Byte_String
        (Flyology.Bytes.To_Unbounded_Bytes
           (Data (Data'First .. Data'Last - 1)));
   end Query_Text;

   Constructor_Built  : Boolean := False;
   Constructor_Text   : Boolean := False;
   Decoder_Accepted   : Boolean := False;
   Decoder_Parameter  : Boolean := False;

   Control_Works : Boolean := False;

begin
   --  Control: an ordinary core GUC works, so the harness is sound.
   begin
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command (Replication.Show ("wal_segment_size"));
      begin
         Control_Works :=
           Replication.Kind (Item) = Replication.Show_Command
           and then Replication.Parameter (Item) = "wal_segment_size";
         Note ("control: SHOW wal_segment_size decodes with parameter "
               & Replication.Parameter (Item));
      end;
   exception
      when E : others =>
         Note ("control failed: " & Ada.Exceptions.Exception_Name (E)
               & ": " & Ada.Exceptions.Exception_Message (E));
   end;

   Note ("constructing Replication.Show (""" & Guc & """)");
   begin
      declare
         Command : constant Protocol.Message := Replication.Show (Guc);
      begin
         Constructor_Built := True;
         Constructor_Text := Query_Text (Command) = "SHOW " & Guc;
         Note ("  built query text: " & Query_Text (Command));
      end;
   exception
      when E : Protocol.Protocol_Error =>
         Note ("  Show raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (E));
      when E : others =>
         Note ("  Show raised " & Ada.Exceptions.Exception_Name (E) & ": "
               & Ada.Exceptions.Exception_Message (E));
   end;

   Note ("decoding the query text PostgreSQL accepts: SHOW " & Guc);
   begin
      declare
         Item : constant Replication.Command :=
           Replication.Decode_Command (Query ("SHOW " & Guc));
      begin
         Decoder_Accepted :=
           Replication.Kind (Item) = Replication.Show_Command;
         Decoder_Parameter := Replication.Parameter (Item) = Guc;
         Note ("  decoded parameter: " & Replication.Parameter (Item));
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
     (Control_Works,
      "harness sanity check: SHOW wal_segment_size still round-trips");
   Check
     (Constructor_Built,
      "Replication.Show accepts a namespaced GUC name");
   Check
     (Constructor_Text,
      "and renders it verbatim as SHOW " & Guc);
   Check
     (Decoder_Accepted,
      "Decode_Command classifies SHOW " & Guc & " as a SHOW command");
   Check
     (Decoder_Parameter,
      "and exposes the complete dotted parameter name");

   Finish;
end Repro_Repl_4;
