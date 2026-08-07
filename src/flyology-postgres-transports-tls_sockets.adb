with Ada.Real_Time;

package body Flyology.Postgres.Transports.TLS_Sockets is

   use type Ada.Streams.Stream_Element_Offset;

   Wait_Slice : constant Duration := 0.25;
   --  How long a chunk read waits before the observer runs again.  Short
   --  enough that a stalled peer still hears from us well inside a primary's
   --  replication timeout, long enough not to spin on an idle channel.

   procedure Receive_Chunk
     (Item    : in out TLS_Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Last    : out Ada.Streams.Stream_Element_Offset;
      Timeout : Duration) is
   begin
      if Item.Encrypted then
         Flyology.IO.TLS.Receive (Item.Secure, Data, Last, Timeout => Timeout);
      else
         Flyology.IO.Sockets.Receive
           (Item.Socket.all, Data, Last, Timeout => Timeout);
      end if;
   end Receive_Chunk;

   overriding procedure Receive_Exactly
     (Item    : in out TLS_Socket_Transport;
      Data    : out Ada.Streams.Stream_Element_Array;
      Timeout : Duration;
      On_Wait : access Wait_Observer'Class := null) is
      use type Ada.Real_Time.Time;
      Bounded  : constant Boolean := Timeout >= 0.0;
      Deadline : constant Ada.Real_Time.Time :=
        (if Bounded
         then Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout)
         else Ada.Real_Time.Time_First);
      Cursor   : Ada.Streams.Stream_Element_Offset := Data'First;
      Last     : Ada.Streams.Stream_Element_Offset;
      Left     : Duration;
   begin
      if On_Wait = null then
         if Item.Encrypted then
            Flyology.IO.TLS.Receive_Exactly
              (Item.Secure, Data, Timeout => Timeout);
         else
            Flyology.IO.Sockets.Receive_Exactly
              (Item.Socket.all, Data, Timeout => Timeout);
         end if;
         return;
      end if;

      while Cursor <= Data'Last loop
         if Bounded then
            Left := Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
            if Left <= 0.0 then
               raise Flyology.IO.Timeout_Error with
                 "Postgres transport deadline expired before the buffer"
                 & " filled";
            end if;
         else
            Left := Wait_Slice;
         end if;
         begin
            Receive_Chunk
              (Item,
               Data (Cursor .. Data'Last),
               Last,
               Duration'Min (Wait_Slice, Left));
            if Last < Cursor then
               raise Flyology.IO.TLS.TLS_Error with
                 "TLS peer closed before receive completed";
            end if;
            Cursor := Last + 1;
         exception
            when Flyology.IO.Timeout_Error =>
               null;
               --  Nothing arrived inside this slice.  The overall deadline
               --  above still governs; keep waiting and let the observer act.
         end;
         if Cursor <= Data'Last then
            On_Wait.On_Wait;
         end if;
      end loop;
   end Receive_Exactly;

   overriding procedure Send_All
     (Item    : in out TLS_Socket_Transport;
      Data    : Ada.Streams.Stream_Element_Array;
      Timeout : Duration) is
   begin
      if Item.Encrypted then
         Flyology.IO.TLS.Send_All
           (Item.Secure, Data, Timeout => Timeout);
      else
         Flyology.IO.Sockets.Send_All
           (Item.Socket.all, Data, Timeout => Timeout);
      end if;
   end Send_All;

   overriding procedure Upgrade_TLS
     (Item        : in out TLS_Socket_Transport;
      Backend     : in out Flyology.IO.TLS.Provider'Class;
      Server_Name : String;
      Timeout     : Duration) is
   begin
      if Item.Encrypted or else Flyology.IO.TLS.Is_Open (Item.Secure) then
         raise Program_Error with "Postgres transport already uses TLS";
      end if;
      Flyology.IO.TLS.Take
        (Backend,
         Item.Socket.all,
         Flyology.IO.TLS.Client,
         Server_Name,
         Item.Secure);
      begin
         Flyology.IO.TLS.Handshake (Item.Secure, Timeout => Timeout);
         Item.Encrypted := True;
      exception
         when others =>
            Flyology.IO.TLS.Close (Item.Secure);
            raise;
      end;
   end Upgrade_TLS;

   function Is_Encrypted (Item : TLS_Socket_Transport) return Boolean is
     (Item.Encrypted);

end Flyology.Postgres.Transports.TLS_Sockets;
