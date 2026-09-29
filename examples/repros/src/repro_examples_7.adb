--  EXAMPLES-7: a session whose connection is gone must not keep a
--  flyology_sessions slot.
--
--  Pgish_Handler calls Pgish_State.Remove_Session only from the
--  Protocol.Terminate_Command branch, and Flyology.Postgres.Server offers no
--  disconnect callback (its generic formals are Authenticate,
--  Lookup_SCRAM_Verifier and Handle only): when Read_Command raises on peer
--  EOF/reset, TLS failure, or the 300 s Command_Timeout, the library removes
--  its own cancellation-router entry and re-raises, so the pgish registry slot
--  stays Occupied with State = "idle".  Pgish_State.Register only reuses a
--  slot whose Owner is the same handler task, so the slot is consumed until
--  that one task serves another connection.
--
--  Consequences: flyology_sessions reports dead sessions, and because
--  Pgish_State.Maximum_Sessions = 16 slots are shared by 17 handler workers
--  (Flyology.Postgres.Server.Worker_Capacity = Capacity + 1), phantom slots
--  also refuse admission for live clients.
--
--  Observed end to end against bin/flyology_pgish (trust auth, no TLS):
--    * control: 16 fresh connections -> 16 admitted;
--    * 16 connections closed with SO_LINGER 0 (RST, no Terminate), then 16
--      fresh connections -> 8 admitted, 8 refused with
--      "ERROR FATAL 28P01 password authentication failed", and
--      flyology_sessions still listed all 16 dead sessions as "idle".

with Ada.Calendar;
with Ada.Directories;
with Pgish_Catalog;
with Pgish_SQL;
with Pgish_State;
with Example_Repro_Support; use Example_Repro_Support;

procedure Repro_Examples_7 is
   package SQL renames Pgish_SQL;
   package Catalog renames Pgish_Catalog;
   package State renames Pgish_State;

   Context : State.Server_State;
   Session : State.Session_Snapshot;
   Result  : Catalog.Result_Set;

   --  One handler task per dropped connection, as in the fixed worker pool.
   task type Dropped_Connection is
      entry Start (Index : Positive);
   end Dropped_Connection;

   task body Dropped_Connection is
      Accepted : Boolean;
      Snapshot : State.Session_Snapshot;
      Number   : Positive;
   begin
      accept Start (Index : Positive) do
         Number := Index;
      end Start;
      --  Pgish_Handler.Authenticate registers the session.
      State.Register_Session
        (Context, "flyology", "flyology",
         "dropped" & Number'Image, Accepted);
      --  One ordinary Query, then the peer disappears.  Read_Command raises,
      --  the library loop re-raises, and Handle is never called with
      --  Terminate_Command, so Remove_Session is never reached.
      State.Begin_Query (Context, "SELECT 1", Snapshot);
      State.End_Query (Context);
   end Dropped_Connection;

   Peers : array (1 .. State.Maximum_Sessions) of Dropped_Connection;
   Admitted : Boolean;
begin
   State.Initialize
     (Context,
      (Host            => SQL.Make_Text ("127.0.0.1", SQL.Maximum_Name_Length),
       Port            => 55_432,
       Repository_Path =>
         SQL.Make_Text (Ada.Directories.Current_Directory, 1_024),
       Task_Mode       =>
         SQL.Make_Text ("lightweight", SQL.Maximum_Name_Length),
       TLS_Enabled     => False,
       Started_At      => Ada.Calendar.Clock));

   for Index in Peers'Range loop
      Peers (Index).Start (Index);
   end loop;
   for Index in Peers'Range loop
      while not Peers (Index)'Terminated loop
         delay 0.02;
      end loop;
   end loop;

   Catalog.Execute
     (Context, Session,
      SQL.Parse ("SELECT session_id, state FROM flyology_sessions"), Result);
   Note ("flyology_sessions still reports" & Result.Row_Count'Image
         & " session(s) after all peers disconnected");
   Check (Result.Row_Count = 0,
          "flyology_sessions lists no session once every peer is gone");

   --  A new connection served by any other handler task finds no free slot;
   --  Pgish_Handler.Authenticate returns False and the library answers
   --  FATAL 28P01 "password authentication failed" on a trust-auth server.
   State.Register_Session
     (Context, "flyology", "flyology", "fresh_client", Admitted);
   Check (Admitted,
          "a fresh client is admitted while no live session exists");
   Finish;
end Repro_Examples_7;
