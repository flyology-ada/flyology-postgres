with Flyology.Postgres.Server_Sessions;

package Flyology.Postgres.Replication.Base_Backups.Server_Sessions is
   --  Minimal backend primitives for serving or proxying native base backups.
   --  Storage, tar production, manifest generation, privileges, and backup
   --  consistency remain application responsibilities.

   package Sessions renames Flyology.Postgres.Server_Sessions;

   procedure Send_Start_Position
     (Client   : in out Sessions.Session;
      Position : LSN;
      Timeline : UInt32;
      Timeout  : Duration);
   --  Send the first result containing consistent start LSN and timeline.
   --  @param Client Authenticated replication backend session.
   --  @param Position Consistent backup start LSN.
   --  @param Timeline Timeline containing Position.
   --  @param Timeout Per-message transport timeout.
   procedure Begin_Tablespaces
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Begin the tablespace metadata result set.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Tablespace
     (Client           : in out Sessions.Session;
      Oid_Present      : Boolean;
      Oid              : UInt32 := 0;
      Location_Present : Boolean;
      Location         : String := "";
      Size_Present     : Boolean;
      Size_KiB         : UInt64 := 0;
      Timeout          : Duration);
   --  Send one tablespace metadata row with explicit SQL NULL presence.
   --  @param Client Replication backend session.
   --  @param Oid_Present Whether Oid is non-NULL.
   --  @param Oid Tablespace OID when present.
   --  @param Location_Present Whether Location is non-NULL.
   --  @param Location External tablespace path when present.
   --  @param Size_Present Whether Size_KiB is non-NULL.
   --  @param Size_KiB Estimated size when progress was requested.
   --  @param Timeout Per-message transport timeout.
   procedure Complete_Tablespaces
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Complete the tablespace metadata result set.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.

   procedure Begin_Stream
     (Client : in out Sessions.Session; Timeout : Duration);
   --  PostgreSQL 14 calls this once per archive and optional manifest;
   --  PostgreSQL 15+ calls it once for the multiplexed stream.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Archive_Start
     (Client   : in out Sessions.Session;
      File_Name : String;
      Location : String;
      Timeout  : Duration);
   --  Send a PostgreSQL 15+ archive-start frame.
   --  @param Client Replication backend session.
   --  @param File_Name Safe archive base name.
   --  @param Location Associated tablespace location, possibly empty.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Manifest_Start
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Send a PostgreSQL 15+ manifest-start frame.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Data
     (Client      : in out Sessions.Session;
      Major       : Server_Major;
      Data        : Byte_Array;
      Timeout     : Duration);
   --  Sends raw PostgreSQL 14 stream bytes or a PostgreSQL 15+ `d` frame.
   --  @param Client Replication backend session.
   --  @param Major Wire format expected by the peer.
   --  @param Data One bounded archive or manifest fragment.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Progress
     (Client          : in out Sessions.Session;
      Bytes_Completed : UInt64;
      Timeout         : Duration);
   --  Send a PostgreSQL 15+ progress frame.
   --  @param Client Replication backend session.
   --  @param Bytes_Completed Bytes completed in the current archive/tablespace.
   --  @param Timeout Per-message transport timeout.
   procedure Finish_Stream
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Send CopyDone only.  PostgreSQL sends the next legacy COPY result, or
   --  the final stop-LSN result, without an intervening CommandComplete.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.

   procedure Send_End_Position
     (Client   : in out Sessions.Session;
      Position : LSN;
      Timeline : UInt32;
      Timeout  : Duration);
   --  Send the final result set and ReadyForQuery.
   --  @param Client Replication backend session.
   --  @param Position Consistent backup stop LSN.
   --  @param Timeline Timeline containing Position.
   --  @param Timeout Per-message transport timeout.

   procedure Begin_Manifest_Upload
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Begin a PostgreSQL 17+ UPLOAD_MANIFEST COPY IN exchange.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.
   function Read_Manifest_Command
     (Client : in out Sessions.Session; Timeout : Duration)
      return Protocol.Frontend_Copy_Message;
   --  Read one bounded manifest COPY IN message.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.
   --  @return CopyData, CopyDone, or CopyFail command.
   procedure Complete_Manifest_Upload
     (Client : in out Sessions.Session; Timeout : Duration);
   --  Finish a successful manifest upload with ReadyForQuery.
   --  @param Client Replication backend session.
   --  @param Timeout Per-message transport timeout.

end Flyology.Postgres.Replication.Base_Backups.Server_Sessions;
