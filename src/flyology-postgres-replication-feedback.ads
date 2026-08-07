with Ada.Real_Time;
with Flyology.Postgres.Transports;

package Flyology.Postgres.Replication.Feedback is
   --  Keeps a replication stream answerable while one message is still
   --  arriving.  A primary packs pending WAL into a single XLogData of up to
   --  128 kB and terminates a standby that goes quiet for wal_sender_timeout,
   --  but a standby reading that message has nowhere to speak from until it
   --  completes.  A reporter fills that gap: the transport hands it the waits,
   --  and it answers with the position the caller has acknowledged so far.

   type Standby_Reporter
     (Channel : not null access Transports.Transport'Class)
      --  Borrowed channel the stream is being read from.
   is limited new Transports.Wait_Observer with private;

   procedure Set_Position
     (Item : in out Standby_Reporter; Position : LSN);
   --  Record the position later reports should carry.  Callers advance this
   --  as they durably accept WAL; it is never advanced by the reporter.  A
   --  caller resuming from a checkpoint should set only what it has
   --  acknowledged, since a report moves a slot's confirmed position.  Until
   --  a position is set the reporter stays quiet rather than claim zero.
   --  @param Item Reporter to update.
   --  @param Position Write, flush, and apply position to report.

   procedure Set_Interval
     (Item : in out Standby_Reporter; Value : Duration);
   --  Set the shortest gap between two reports.  Keep this well under the
   --  primary's wal_sender_timeout.
   --  @param Item Reporter to update.
   --  @param Value Minimum seconds between reports.

   function Reports (Item : Standby_Reporter) return Natural;
   --  @return How many status updates the reporter has sent.

   overriding procedure On_Wait (Item : in out Standby_Reporter);
   --  Send a Standby Status Update when one is due.  Called by the transport
   --  between reads, so the send never overlaps one.
   --  @param Item Reporter deciding whether a report is due.

private

   type Standby_Reporter
     (Channel : not null access Transports.Transport'Class)
   is limited new Transports.Wait_Observer with record
      Position : LSN := 0;
      Interval : Duration := 1.0;
      Sent     : Natural := 0;
      Due      : Ada.Real_Time.Time := Ada.Real_Time.Time_First;
      Started  : Boolean := False;
   end record;

end Flyology.Postgres.Replication.Feedback;
