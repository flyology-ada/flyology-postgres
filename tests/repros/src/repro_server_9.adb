--  SERVER-9: TLS_Socket_Transport.Receive_Exactly behaves differently
--  depending on whether an observer was supplied, for the same event, and a
--  zero timeout fails before any read is attempted.
--  (src/flyology-postgres-transports-tls_sockets.adb:41-50, :52-59, :64-72)
--
--  (a) On an un-upgraded (plaintext) transport the observer-less path
--      delegates to Flyology.IO.Sockets.Receive_Exactly, whose documented
--      early-close report is Device_Error ("Polling fails or peer closes
--      before completion").  The observer path instead calls
--      Flyology.IO.Sockets.Receive, sees the orderly-close report
--      Last = Data'First - 1, and raises Flyology.IO.TLS.TLS_Error with the
--      text "TLS peer closed before receive completed" even though no TLS is
--      involved.  Callers therefore see a different exception class based on
--      whether they passed On_Wait, not on what happened.
--
--  (b) With Timeout = 0.0 the observer path computes Deadline = Clock and
--      then raises Timeout_Error on the first loop iteration, before calling
--      Receive_Chunk at all -- so bytes already buffered are never read.
--      The observer-less path passes 0.0 straight down, where it means "one
--      immediate attempt".
--
--  Correct behavior: the same event produces the same exception class with
--  and without an observer, and a zero timeout still attempts one read.

with Ada.Exceptions;
with Ada.Streams;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres.Transports;
with Flyology.Postgres.Transports.TLS_Sockets;
with Repro_Support; use Repro_Support;

procedure Repro_Server_9 is

   use type Ada.Streams.Stream_Element_Array;

   package Sockets renames Flyology.IO.Sockets;
   package TLS_Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   use type Sockets.Selector_Status;

   type Counting_Observer is limited new Transports.Wait_Observer with record
      Calls : Natural := 0;
   end record;

   overriding procedure On_Wait (Item : in out Counting_Observer);

   overriding procedure On_Wait (Item : in out Counting_Observer) is
   begin
      Item.Calls := Item.Calls + 1;
   end On_Wait;

   procedure Make_Loopback_Pair
     (Client : in out Sockets.Socket_Type;
      Server : in out Sockets.Socket_Type);

   procedure Make_Loopback_Pair
     (Client : in out Sockets.Socket_Type;
      Server : in out Sockets.Socket_Type)
   is
      Listener : Sockets.Socket_Type;
      Peer     : Sockets.Endpoint;
      Status   : Sockets.Selector_Status;
   begin
      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Sockets.Any_Port));
      Sockets.Listen_Socket (Listener, Length => 4);
      Sockets.Create_Socket (Client);
      Sockets.Connect
        (Client, Sockets.Get_Socket_Name (Listener), Timeout => 2.0);
      Sockets.Accept_Socket (Listener, Server, Peer, 2.0, Status);
      if Status /= Sockets.Completed then
         raise Program_Error with "loopback accept did not complete";
      end if;
      Sockets.Close_Socket (Listener);
   end Make_Loopback_Pair;

   Prefix : constant Ada.Streams.Stream_Element_Array (1 .. 3) :=
     (1, 2, 3);
   Full   : constant Ada.Streams.Stream_Element_Array (1 .. 8) :=
     (1, 2, 3, 4, 5, 6, 7, 8);

   function Early_Close_Exception (With_Observer : Boolean) return String is
      Writer  : Sockets.Socket_Type;
      Reader  : aliased Sockets.Socket_Type;
      Channel : aliased TLS_Transports.TLS_Socket_Transport (Reader'Access);
      Watcher : aliased Counting_Observer;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 8) := (others => 0);
   begin
      Make_Loopback_Pair (Writer, Reader);
      Sockets.Send_All (Writer, Prefix, Timeout => 1.0);
      Sockets.Close_Socket (Writer);
      begin
         if With_Observer then
            Channel.Receive_Exactly (Data, 1.0, Watcher'Access);
         else
            Channel.Receive_Exactly (Data, 1.0);
         end if;
         Sockets.Close_Socket (Reader);
         return "<no exception>";
      exception
         when E : others =>
            Sockets.Close_Socket (Reader);
            return Ada.Exceptions.Exception_Name (E) & ": "
              & Ada.Exceptions.Exception_Message (E);
      end;
   end Early_Close_Exception;

   Without_Observer : constant String := Early_Close_Exception (False);
   With_Observer    : constant String := Early_Close_Exception (True);

begin
   Note ("plaintext peer closes after 3 of 8 bytes");
   Note ("  without an observer -> " & Without_Observer);
   Note ("  with an observer    -> " & With_Observer);

   Check
     (Without_Observer = With_Observer,
      "an early peer close on an un-upgraded transport reports the same "
      & "exception with and without an observer");

   declare
      Writer  : Sockets.Socket_Type;
      Reader  : aliased Sockets.Socket_Type;
      Channel : aliased TLS_Transports.TLS_Socket_Transport (Reader'Access);
      Watcher : aliased Counting_Observer;
      Data    : Ada.Streams.Stream_Element_Array (1 .. 8) := (others => 0);
      Result  : Boolean := False;
      Outcome : Boolean := False;
   begin
      Make_Loopback_Pair (Writer, Reader);
      Sockets.Send_All (Writer, Full, Timeout => 1.0);
      --  Every byte is already in the receive buffer before the call.
      delay 0.05;
      begin
         Channel.Receive_Exactly (Data, 0.0, Watcher'Access);
         Result := Data = Full;
         Outcome := True;
         Note ("Receive_Exactly (Timeout => 0.0, observer) returned "
               & (if Result then "the 8 buffered bytes"
                  else "the wrong bytes"));
      exception
         when E : others =>
            Note ("Receive_Exactly (Timeout => 0.0, observer) raised "
                  & Ada.Exceptions.Exception_Name (E) & ": "
                  & Ada.Exceptions.Exception_Message (E));
      end;
      Sockets.Close_Socket (Writer);
      Sockets.Close_Socket (Reader);
      Check
        (Outcome and then Result,
         "a zero timeout with an observer still attempts one read and "
         & "returns bytes that are already available");
   end;

   Finish;
end Repro_Server_9;
