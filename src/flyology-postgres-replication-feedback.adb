with Flyology.Postgres.Framing;

package body Flyology.Postgres.Replication.Feedback is

   use type Ada.Real_Time.Time;
   use type LSN;

   Report_Timeout : constant Duration := 5.0;
   --  A report is small and the channel is already writable in practice, so
   --  this only bounds a peer that has stopped reading altogether.

   procedure Set_Position
     (Item : in out Standby_Reporter; Position : LSN) is
   begin
      Item.Position := Position;
   end Set_Position;

   procedure Set_Interval
     (Item : in out Standby_Reporter; Value : Duration) is
   begin
      Item.Interval := Value;
   end Set_Interval;

   function Reports (Item : Standby_Reporter) return Natural is
     (Item.Sent);

   overriding procedure On_Wait (Item : in out Standby_Reporter) is
      Now : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if not Item.Started then
         --  The first wait only starts the clock.  A stream that is merely
         --  keeping up should not pay for a report it does not owe.
         Item.Started := True;
         Item.Due := Now + Ada.Real_Time.To_Time_Span (Item.Interval);
         return;
      end if;
      if Now < Item.Due then
         return;
      end if;
      if Item.Position = 0 then
         --  Nothing has been accepted yet, so there is no position to stand
         --  behind.  Reporting zero would tell the primary this standby has
         --  flushed nothing, which is worse than staying quiet.
         return;
      end if;
      Framing.Write_Message
        (Item.Channel.all,
         Make_Standby_Status_Update
           (Item.Position, Item.Position, Item.Position, Sent_At => 0),
         Report_Timeout);
      Item.Sent := Item.Sent + 1;
      Item.Due := Now + Ada.Real_Time.To_Time_Span (Item.Interval);
   end On_Wait;

end Flyology.Postgres.Replication.Feedback;
