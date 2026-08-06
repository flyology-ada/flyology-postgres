with Flyology.Postgres.Server_Sessions;

package Flyology.Postgres.Replication.Server_Sessions is
   --  Backend response sequences for PostgreSQL replication-mode commands and
   --  COPY BOTH streaming.

   package Sessions renames Flyology.Postgres.Server_Sessions;

   procedure Send_Identify_System
     (Client         : in out Sessions.Session;
      System_Id      : UInt64;
      Timeline       : UInt32;
      Current_WAL    : LSN;
      Database       : String := "";
      Timeout        : Duration);
   --  Complete IDENTIFY_SYSTEM as a four-column simple-query response. An
   --  empty Database is encoded as SQL NULL for a physical connection.
   --  @param Client Authenticated replication session to write.
   --  @param System_Id Stable system identifier rendered as decimal text.
   --  @param Timeline Current timeline identifier.
   --  @param Current_WAL Current end-of-WAL position.
   --  @param Database Connected database name, or empty for SQL NULL.
   --  @param Timeout Per-message write timeout.

   procedure Send_Show
     (Client    : in out Sessions.Session;
      Parameter : String;
      Value     : String;
      Timeout   : Duration);
   --  Complete replication SHOW as a one-column simple-query response.
   --  @param Client Authenticated replication session to write.
   --  @param Parameter Parameter name used as the result-column label.
   --  @param Value Parameter value encoded as text.
   --  @param Timeout Per-message write timeout.

   procedure Send_Timeline_History
     (Client   : in out Sessions.Session;
      Timeline : UInt32;
      Contents : Byte_Array;
      Timeout  : Duration);
   --  Complete TIMELINE_HISTORY with the filename and exact history bytes.
   --  PostgreSQL declares both columns as text; walreceivers persist Contents
   --  verbatim.
   --  @param Client Authenticated replication session to write.
   --  @param Timeline Timeline whose history filename is returned.
   --  @param Contents Raw history-file contents.
   --  @param Timeout Per-message write timeout.

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
   --  @param Client Authenticated replication session to write.
   --  @param Slot_Name Name assigned to the created slot.
   --  @param Consistent_Point LSN from which decoding can start.
   --  @param Plugin Logical decoding output plugin.
   --  @param Snapshot_Name Exported snapshot, or empty for SQL NULL.
   --  @param Timeout Per-message write timeout.

   procedure Send_Drop_Replication_Slot
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Send DROP_REPLICATION_SLOT completion and ReadyForQuery.
   --  @param Client Authenticated replication session to write.
   --  @param Timeout Per-message write timeout.

   procedure Begin_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Enter COPY BOTH mode for a successful START_REPLICATION command.
   --  @param Client Authenticated replication session to write.
   --  @param Timeout Maximum time allowed for the response write.

   procedure Send_XLog_Data
     (Client    : in out Sessions.Session;
      WAL_Start : LSN;
      WAL_End   : LSN;
      Sent_At   : Replication_Timestamp;
      Data      : Byte_Array;
      Timeout   : Duration);
   --  Send one XLogData frame inside COPY BOTH.
   --  @param Client Streaming replication session to write.
   --  @param WAL_Start LSN of the first byte represented by Data.
   --  @param WAL_End Server's current end-of-WAL position.
   --  @param Sent_At PostgreSQL replication timestamp for the frame.
   --  @param Data Raw WAL or logical-decoding payload.
   --  @param Timeout Maximum time allowed for the write.

   procedure Send_Primary_Keepalive
     (Client          : in out Sessions.Session;
      WAL_End         : LSN;
      Sent_At         : Replication_Timestamp;
      Reply_Requested : Boolean := False;
      Timeout         : Duration);
   --  Send a primary keepalive frame inside COPY BOTH.
   --  @param Client Streaming replication session to write.
   --  @param WAL_End Server's current end-of-WAL position.
   --  @param Sent_At PostgreSQL replication timestamp for the frame.
   --  @param Reply_Requested Ask the standby for immediate status feedback.
   --  @param Timeout Maximum time allowed for the write.

   function Read_Standby_Message
     (Client : in out Sessions.Session; Timeout : Duration)
      return Stream_Message;
   --  Read and decode one standby CopyData message.
   --  @param Client Streaming replication session to read.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return Standby status update or hot-standby feedback.

   procedure Finish_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Close the server-to-standby direction. Continue reading frontend COPY
   --  messages until CopyDone before Complete_Streaming; feedback can remain
   --  in flight while the two directions close.
   --  @param Client Streaming replication session to finish.
   --  @param Timeout Maximum time allowed to send CopyDone.

   procedure Complete_Streaming
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Complete START_REPLICATION after both COPY BOTH directions close. A
   --  frontend CopyFail should instead be answered with an error response.
   --  @param Client Session whose COPY directions have both closed.
   --  @param Timeout Per-message completion write timeout.

end Flyology.Postgres.Replication.Server_Sessions;
