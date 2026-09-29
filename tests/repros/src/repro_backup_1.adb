--  BACKUP-1: Memory.Promote stores only the newest history line, so the
--  history file for the third and later timelines is not a PostgreSQL
--  timeline history file.
--
--  Persistence.History is documented (persistence.ads:219-224) as "Read a
--  timeline history file exactly as sent to a standby", and
--  Managed_Primary.Timeline_History_Command
--  (managed_primary.adb:332-336) forwards those exact bytes to a real
--  standby through Replication.Server_Sessions.Send_Timeline_History.
--
--  PostgreSQL's writeTimeLineHistory (src/backend/access/transam/timeline.c)
--  copies the parent timeline's history file verbatim and only then appends
--  the "<parentTLI>\t<switchpoint>\t<reason>" line, so 00000003.history
--  lists BOTH ancestors.  readTimeLineHistory builds the ancestry list from
--  that file and rescanLatestTimeLine refuses a timeline whose history does
--  not contain the standby's current timeline ("new timeline %u is not a
--  child of database system timeline %u", xlogrecovery.c:4188).
--
--  Memory.Promote (memory.adb:255-283) writes one line and drops the
--  parent's history, so a standby still on timeline 1 cannot follow a
--  primary that has promoted twice.
--
--  Correct behavior: the history of timeline 3 records every ancestor, so it
--  contains the timeline-1 switch line inherited from timeline 2 as well as
--  the timeline-2 switch line.

with Ada.Streams;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Repro_Support; use Repro_Support;

procedure Repro_Backup_1 is

   package Replication renames Flyology.Postgres.Replication;
   package Persistence renames Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);

   use type Ada.Streams.Stream_Element_Array;
   use type Replication.UInt32;

   HT : constant Character := Character'Val (9);
   LF : constant Character := Character'Val (10);

   Fork_1_2 : constant Replication.LSN := 16#64#;
   Fork_2_3 : constant Replication.LSN := 16#C8#;

   Line_1 : constant String :=
     "1" & HT & Replication.Image (Fork_1_2) & HT & "promotion" & LF;
   Line_2 : constant String :=
     "2" & HT & Replication.Image (Fork_2_3) & HT & "promotion" & LF;

   function Text (Data : Persistence.Byte_Array) return String;
   function Contains (Whole, Part : String) return Boolean;
   function Visible (Text : String) return String;

   function Text (Data : Persistence.Byte_Array) return String is
      Result : String (1 .. Data'Length);
      Cursor : Positive := 1;
   begin
      for Octet of Data loop
         Result (Cursor) := Character'Val (Octet);
         Cursor := Cursor + 1;
      end loop;
      return Result;
   end Text;

   function Contains (Whole, Part : String) return Boolean is
   begin
      if Part'Length = 0 or else Part'Length > Whole'Length then
         return Part'Length = 0;
      end if;
      for Start in Whole'First .. Whole'Last - Part'Length + 1 loop
         if Whole (Start .. Start + Part'Length - 1) = Part then
            return True;
         end if;
      end loop;
      return False;
   end Contains;

   function Visible (Text : String) return String is
      Result : String (1 .. 4 * Text'Length);
      Cursor : Natural := 0;
      procedure Put (Item : String);
      procedure Put (Item : String) is
      begin
         Result (Cursor + 1 .. Cursor + Item'Length) := Item;
         Cursor := Cursor + Item'Length;
      end Put;
   begin
      for Item of Text loop
         if Item = HT then
            Put ("\t");
         elsif Item = LF then
            Put ("\n");
         else
            Put ((1 => Item));
         end if;
      end loop;
      return Result (1 .. Cursor);
   end Visible;

   Store      : aliased Memory.Store;
   Timeline_2 : Replication.UInt32;
   Timeline_3 : Replication.UInt32;

begin
   Memory.Promote (Store, Parent => 1, Fork_LSN => Fork_1_2,
                   New_Timeline => Timeline_2);
   Memory.Promote (Store, Parent => 2, Fork_LSN => Fork_2_3,
                   New_Timeline => Timeline_3);

   Check (Timeline_2 = 2 and then Timeline_3 = 3,
          "two promotions allocate timelines 2 and 3 (harness sanity check)");

   declare
      History_2 : constant Persistence.Byte_Array :=
        Memory.History (Store, 2);
      History_3 : constant Persistence.Byte_Array :=
        Memory.History (Store, 3);
   begin
      Note ("00000002.history = """ & Visible (Text (History_2)) & """");
      Note ("00000003.history = """ & Visible (Text (History_3)) & """");
      Note ("PostgreSQL would store, for 00000003.history, the whole parent "
            & "file """ & Visible (Line_1) & """ followed by """
            & Visible (Line_2) & """");

      Check (Text (History_2) = Line_1,
             "the history of timeline 2 is its single switch line "
             & "(harness sanity check)");
      Check (Contains (Text (History_3), Line_2),
             "the history of timeline 3 records its own switch point from "
             & "timeline 2");
      Check (Contains (Text (History_3), Line_1),
             "the history of timeline 3 also records the inherited "
             & "timeline-1 switch line, so a standby still on timeline 1 "
             & "finds itself in the ancestry of timeline 3");
   end;

   Finish;
end Repro_Backup_1;
