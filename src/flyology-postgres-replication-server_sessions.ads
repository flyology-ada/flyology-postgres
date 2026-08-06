with Flyology.Postgres.Server_Sessions;

package Flyology.Postgres.Replication.Server_Sessions is

   package Sessions renames Flyology.Postgres.Server_Sessions;

   --  Complete the simple-query response for IDENTIFY_SYSTEM.  An empty
   --  Database is encoded as SQL NULL, as required for a physical
   --  replication connection.
   procedure Send_Identify_System
     (Client         : in out Sessions.Session;
      System_Id      : UInt64;
      Timeline       : UInt32;
      Current_WAL    : LSN;
      Database       : String := "";
      Timeout        : Duration);

   procedure Send_Show
     (Client    : in out Sessions.Session;
      Parameter : String;
      Value     : String;
      Timeout   : Duration);

   --  PostgreSQL declares both result columns as text and sends history-file
   --  contents verbatim; walreceivers persist the returned bytes directly.
   procedure Send_Timeline_History
     (Client   : in out Sessions.Session;
      Timeline : UInt32;
      Contents : Byte_Array;
      Timeout  : Duration);

   procedure Send_Create_Logical_Slot
     (Client           : in out Sessions.Session;
      Slot_Name        : String;
      Consistent_Point : LSN;
      Plugin           : String;
      Snapshot_Name    : String := "";
      Timeout          : Duration);
   --  Send the four-column CREATE_REPLICATION_SLOT result and ReadyForQuery.
   --  Snapshot_Name is SQL NULL when empty, as required for SNAPSHOT 'use'
   --  and SNAPSHOT 'nothing'.

   procedure Send_Drop_Replication_Slot
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Send DROP_REPLICATION_SLOT completion and ReadyForQuery.

   procedure Begin_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);

   procedure Send_XLog_Data
     (Client    : in out Sessions.Session;
      WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array;
      Timeout   : Duration);

   procedure Send_Primary_Keepalive
     (Client          : in out Sessions.Session;
      WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False;
      Timeout         : Duration);

   function Read_Standby_Message
     (Client : in out Sessions.Session; Timeout : Duration)
      return Stream_Message;

   --  Close the server-to-standby direction.  The caller must continue
   --  reading frontend COPY messages until it receives CopyDone before
   --  calling Complete_Streaming; standby feedback can remain in flight
   --  while the two directions close.
   procedure Finish_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);

   --  Complete START_REPLICATION after both COPY BOTH directions have
   --  closed.  A frontend CopyFail should instead be answered with an error.
   procedure Complete_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);

end Flyology.Postgres.Replication.Server_Sessions;
