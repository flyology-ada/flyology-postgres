with Flyology.Postgres.Client;
with Flyology.Postgres.Transports;
private with Flyology.Bytes;

package Flyology.Postgres.Replication.Base_Backups is
   --  Native, bounded-memory BASE_BACKUP commands and response streaming for
   --  PostgreSQL 14 through 18.  A Receiver returns at most one PostgreSQL
   --  CopyData payload per call and never accumulates archive or manifest
   --  contents.

   subtype Server_Major is Positive range 14 .. 18;
   --  PostgreSQL major whose BASE_BACKUP grammar and wire format are used.

   type Checkpoint_Mode is (Spread_Checkpoint, Fast_Checkpoint);
   --  Checkpoint pacing at backup start.
   --  @enum Spread_Checkpoint Spread I/O over checkpoint_completion_target.
   --  @enum Fast_Checkpoint Complete the checkpoint as quickly as possible.
   type Backup_Target is (Client_Target, Server_Target, Blackhole_Target);
   --  Destination selected by PostgreSQL 15+ TARGET.
   --  @enum Client_Target Stream archive and manifest bytes to this client.
   --  @enum Server_Target Write beneath a database-host path.
   --  @enum Blackhole_Target Generate and discard the backup server-side.
   type Compression_Method is
     (No_Compression, Gzip_Compression, LZ4_Compression, Zstandard_Compression);
   --  PostgreSQL 15+ server-side archive compression.
   --  @enum No_Compression Produce uncompressed tar streams.
   --  @enum Gzip_Compression Compress archives with gzip.
   --  @enum LZ4_Compression Compress archives with LZ4.
   --  @enum Zstandard_Compression Compress archives with Zstandard.
   type Manifest_Mode is (No_Manifest, Include_Manifest, Force_Encode_Manifest);
   --  Backup-manifest generation and filename encoding.
   --  @enum No_Manifest Do not request a manifest.
   --  @enum Include_Manifest Request conditional filename encoding.
   --  @enum Force_Encode_Manifest Hex-encode every filename for testing.
   type Manifest_Checksum is
     (No_Checksum, CRC32C_Checksum, SHA224_Checksum, SHA256_Checksum,
      SHA384_Checksum, SHA512_Checksum);
   --  Per-file checksum stored in a requested manifest.
   --  @enum No_Checksum Do not checksum individual files.
   --  @enum CRC32C_Checksum Use the fast default CRC32C checksum.
   --  @enum SHA224_Checksum Use SHA-224.
   --  @enum SHA256_Checksum Use SHA-256.
   --  @enum SHA384_Checksum Use SHA-384.
   --  @enum SHA512_Checksum Use SHA-512.

   type Options is private;
   --  Owned BASE_BACKUP options tied to one target server major.

   function Defaults (Major : Server_Major) return Options;
   --  Construct default options for one known server major.
   --  @param Major Actual PostgreSQL server major.
   --  @return Client-target options matching PostgreSQL defaults.
   function Major (Item : Options) return Server_Major;
   --  Return the server major bound to an option set.
   --  @param Item Options to inspect.
   --  @return Major passed to Defaults.
   procedure Set_Label (Item : in out Options; Label : String);
   --  Set the exact label, including an explicitly empty label.
   --  @param Item Options to update.
   --  @param Label Label encoded as a PostgreSQL string constant.
   procedure Set_Target
     (Item   : in out Options;
      Target : Backup_Target;
      Detail : String := "");
   --  Select a PostgreSQL 15+ backup target.
   --  @param Item Options to update.
   --  @param Target Client, server, or blackhole destination.
   --  @param Detail Required server path, otherwise empty.
   procedure Set_Progress (Item : in out Options; Enabled : Boolean := True);
   --  Request or suppress tablespace sizes/progress frames.
   --  @param Item Options to update.
   --  @param Enabled Whether PostgreSQL should calculate progress.
   procedure Set_Checkpoint
     (Item : in out Options; Mode : Checkpoint_Mode);
   --  Select spread or fast checkpoint behavior.
   --  @param Item Options to update.
   --  @param Mode Desired checkpoint pacing.
   procedure Include_WAL (Item : in out Options; Enabled : Boolean := True);
   --  Include WAL needed to make the archive self-contained.
   --  @param Item Options to update.
   --  @param Enabled Whether required WAL is included.
   procedure Wait_For_Archive
     (Item : in out Options; Enabled : Boolean := True);
   --  Control waiting for the final WAL segment to be archived.
   --  @param Item Options to update.
   --  @param Enabled True to retain PostgreSQL's default wait.
   procedure Set_Compression
     (Item   : in out Options;
      Method : Compression_Method;
      Detail : String := "");
   --  Select PostgreSQL 15+ server-side archive compression.
   --  @param Item Options to update.
   --  @param Method Compression codec, or No_Compression.
   --  @param Detail Server codec options such as level/workers.
   procedure Set_Maximum_Rate
     (Item : in out Options; Kilobytes_Per_Second : UInt32);
   --  Throttle the server-to-client transfer rate.
   --  @param Item Options to update.
   --  @param Kilobytes_Per_Second Zero or 32 through 1_048_576 KiB/s.
   procedure Include_Tablespace_Map
     (Item : in out Options; Enabled : Boolean := True);
   --  Include symbolic-link mappings in tablespace_map.
   --  @param Item Options to update.
   --  @param Enabled Whether to include the map file.
   procedure Verify_Checksums
     (Item : in out Options; Enabled : Boolean := True);
   --  Enable or disable server-side data-checksum verification.
   --  @param Item Options to update.
   --  @param Enabled Whether enabled page checksums are verified.
   procedure Set_Manifest
     (Item      : in out Options;
      Mode      : Manifest_Mode;
      Checksums : Manifest_Checksum := CRC32C_Checksum);
   --  Configure manifest generation and per-file checksums.
   --  @param Item Options to update.
   --  @param Mode Whether and how to generate a manifest.
   --  @param Checksums Per-file checksum for an enabled manifest.
   procedure Set_Incremental
     (Item : in out Options; Enabled : Boolean := True);
   --  Request PostgreSQL 17+ incremental backup after manifest upload.
   --  @param Item Options to update.
   --  @param Enabled Whether to request an incremental backup.
   --  Setters reject options unavailable on Item's server major, invalid
   --  target/detail combinations, embedded NUL bytes, and invalid rate
   --  limits.  PostgreSQL 14 accepts 0 or 32..1_048_576 KiB/s.

   function Command (Item : Options) return Protocol.Message;
   --  Construct the version-correct BASE_BACKUP simple Query command.
   --  @param Item Validated options to encode.
   --  @return Owned Query message ready for Client.Send.
   function Upload_Manifest_Command
     (Major : Server_Major) return Protocol.Message;
   --  Construct PostgreSQL 17+ UPLOAD_MANIFEST.
   --  @param Major Actual PostgreSQL server major.
   --  @return Owned Query message ready for Client.Send.

   procedure Begin_Manifest_Upload
     (Connection : in out Client.Session;
      Major      : Server_Major;
      Timeout    : Duration := 30.0);
   --  Send UPLOAD_MANIFEST and consume responses through CopyInResponse.
   --  @param Connection Authenticated physical-replication session.
   --  @param Major Actual PostgreSQL server major.
   --  @param Timeout Per-message transport timeout.
   procedure Send_Manifest_Chunk
     (Connection : in out Client.Session;
      Data       : Byte_Array;
      Timeout    : Duration := 30.0);
   --  Send one bounded manifest fragment through COPY IN.
   --  @param Connection Session prepared by Begin_Manifest_Upload.
   --  @param Data Caller-owned fragment copied into one protocol message.
   --  @param Timeout Per-message transport timeout.
   procedure Finish_Manifest_Upload
     (Connection : in out Client.Session;
      Timeout    : Duration := 30.0);
   --  Finish manifest COPY IN successfully.
   --  @param Connection Session with an active manifest upload.
   --  @param Timeout Per-message transport timeout.
   procedure Abort_Manifest_Upload
     (Connection : in out Client.Session;
      Reason     : String;
      Timeout    : Duration := 30.0);
   --  Abort manifest COPY IN with a client error message.
   --  @param Connection Session with an active manifest upload.
   --  @param Reason Nonempty diagnostic sent in CopyFail.
   --  @param Timeout Per-message transport timeout.
   --  Manifest upload uses the existing bounded COPY IN path.  After finish
   --  or abort, consume Client.Receive_Copy_Event and Receive_Query_Event
   --  until Client.Is_Ready before issuing BASE_BACKUP.

   type Event_Kind is
     (Backup_Start,
      Tablespace,
      Archive_Start,
      Archive_Data,
      Manifest_Start,
      Manifest_Data,
      Progress,
      Backup_End,
      Notice,
      Parameter_Status,
      Error,
      Complete);
   --  Semantic event returned while receiving one base backup.
   --  @enum Backup_Start Consistent start LSN and timeline are available.
   --  @enum Tablespace One row of tablespace metadata is available.
   --  @enum Archive_Start A named archive stream is beginning.
   --  @enum Archive_Data One bounded archive fragment is available.
   --  @enum Manifest_Start The requested manifest stream is beginning.
   --  @enum Manifest_Data One bounded manifest fragment is available.
   --  @enum Progress Current archive's completed byte count is available.
   --  @enum Backup_End Consistent stop LSN and timeline are available.
   --  @enum Notice An asynchronous server notice is available.
   --  @enum Parameter_Status A changed server parameter is available.
   --  @enum Error The server rejected or aborted the backup.
   --  @enum Complete ReadyForQuery has completed the exchange.

   type Event is private;
   --  Owned semantic backup event; payload data remains valid after Receive.
   function Kind (Item : Event) return Event_Kind;
   --  Return the event variant.
   --  @param Item Event to inspect.
   --  @return Discriminating semantic event kind.
   function Start_LSN (Item : Event) return LSN;
   --  Return the consistent backup start position.
   --  @param Item Backup_Start event.
   --  @return Server-selected consistent start LSN.
   function End_LSN (Item : Event) return LSN;
   --  Return the consistent backup stop position.
   --  @param Item Backup_End event.
   --  @return Server-selected consistent stop LSN.
   function Timeline (Item : Event) return UInt32;
   --  Return the timeline associated with a backup boundary.
   --  @param Item Backup_Start or Backup_End event.
   --  @return Timeline associated with the event LSN.
   function Has_Tablespace_Oid (Item : Event) return Boolean;
   --  Test whether a tablespace row contains an OID.
   --  @param Item Tablespace event.
   --  @return Whether PostgreSQL supplied a tablespace OID.
   function Tablespace_Oid (Item : Event) return UInt32;
   --  Return a tablespace row's OID.
   --  @param Item Tablespace event with an OID.
   --  @return Tablespace OID.
   function Has_Tablespace_Location (Item : Event) return Boolean;
   --  Test whether a tablespace row contains an external location.
   --  @param Item Tablespace event.
   --  @return Whether PostgreSQL supplied an external location.
   function Tablespace_Location (Item : Event) return String;
   --  Return a tablespace row's external location.
   --  @param Item Tablespace event with a location.
   --  @return Owned external tablespace path.
   function Has_Tablespace_Size (Item : Event) return Boolean;
   --  Test whether a tablespace row contains a size estimate.
   --  @param Item Tablespace event.
   --  @return Whether progress mode supplied a size estimate.
   function Tablespace_Size_KiB (Item : Event) return UInt64;
   --  Return a tablespace row's size estimate.
   --  @param Item Tablespace event with a size.
   --  @return Estimated tablespace size in kibibytes.
   function Archive_Name (Item : Event) return String;
   --  Return the name announced for an archive.
   --  @param Item Archive_Start event.
   --  @return Server-selected archive file name.
   function Archive_Location (Item : Event) return String;
   --  Return the tablespace location announced for an archive.
   --  @param Item Archive_Start event.
   --  @return Tablespace location associated with the archive.
   function Stream_Index (Item : Event) return Positive;
   --  Return the one-based stream/archive ordinal.
   --  @param Item Archive_Start, Archive_Data, or manifest event.
   --  @return One-based stream/archive ordinal.
   function Data (Item : Event) return Byte_Array;
   --  Return one bounded archive or manifest fragment.
   --  @param Item Archive_Data or Manifest_Data event.
   --  @return One owned bounded COPY payload.
   function Bytes_Completed (Item : Event) return UInt64;
   --  Return the latest current-archive progress count.
   --  @param Item Progress event.
   --  @return Bytes completed in the current archive/tablespace.
   function Diagnostic (Item : Event) return Protocol.Diagnostic;
   --  Return a notice or error diagnostic.
   --  @param Item Notice or Error event.
   --  @return Structured server diagnostic.
   function Status (Item : Event) return Protocol.Parameter_Status;
   --  Return a server parameter update.
   --  @param Item Parameter_Status event.
   --  @return Owned server parameter update.
   function Original_Message (Item : Event) return Protocol.Message;
   --  Return the owned backend message underlying an event.
   --  @param Item Any event.
   --  @return Original owned backend message when one exists.
   --  Accessors reject inapplicable event variants with Protocol_Error.

   type Receiver
     (Connection : not null access Client.Session) is limited private;
   --  Stateful bounded BASE_BACKUP response decoder.
   --  @field Connection Authenticated physical-replication session.
   procedure Start
     (Item    : in out Receiver;
      Options : Base_Backups.Options;
      Timeout : Duration := 30.0);
   --  Send BASE_BACKUP and prepare to receive its semantic event stream.
   --  @param Item Idle receiver to start.
   --  @param Options Version-bound command options.
   --  @param Timeout Per-message transport timeout.
   function Receive
     (Item : in out Receiver; Timeout : Duration := 30.0) return Event;
   --  Receive the next semantic event, internally skipping only bounded
   --  RowDescription, CommandComplete, and CopyDone framing.  Call until
   --  Complete, including after Error, so ReadyForQuery is consumed.
   --  @param Item Active receiver.
   --  @param Timeout Per-message transport timeout.
   --  @return Next owned semantic event.
   procedure Cancel
     (Item                 : Receiver;
      Cancellation_Channel : in out Transports.Transport'Class;
      Timeout              : Duration := 30.0);
   --  Send a PostgreSQL CancelRequest on a distinct caller-owned transport.
   --  @param Item Receiver whose session supplies backend key data.
   --  @param Cancellation_Channel Fresh transport to the same PostgreSQL.
   --  @param Timeout Cancellation transport timeout.

private
   type Options is record
      Version             : Server_Major := 18;
      Label_Present       : Boolean := False;
      Label_Data          : Flyology.Bytes.Unbounded_Bytes;
      Target_Value        : Backup_Target := Client_Target;
      Target_Detail_Data  : Flyology.Bytes.Unbounded_Bytes;
      Progress_Value      : Boolean := False;
      Checkpoint_Value    : Checkpoint_Mode := Spread_Checkpoint;
      WAL_Value           : Boolean := False;
      Archive_Wait_Value  : Boolean := True;
      Compression_Value   : Compression_Method := No_Compression;
      Compression_Detail  : Flyology.Bytes.Unbounded_Bytes;
      Maximum_Rate_Value  : UInt32 := 0;
      Tablespace_Map      : Boolean := False;
      Verify_Value        : Boolean := True;
      Manifest_Value      : Manifest_Mode := No_Manifest;
      Checksum_Value      : Manifest_Checksum := CRC32C_Checksum;
      Incremental_Value   : Boolean := False;
   end record;

   type Event is record
      Event_Type        : Event_Kind := Complete;
      Raw               : Protocol.Message;
      First_Position    : LSN := 0;
      Last_Position     : LSN := 0;
      Timeline_Value    : UInt32 := 0;
      Oid_Present       : Boolean := False;
      Oid_Value         : UInt32 := 0;
      Location_Present  : Boolean := False;
      Location_Data     : Flyology.Bytes.Unbounded_Bytes;
      Size_Present      : Boolean := False;
      Size_Value        : UInt64 := 0;
      Name_Data         : Flyology.Bytes.Unbounded_Bytes;
      Stream_Number     : Positive := 1;
      Bytes             : Flyology.Bytes.Unbounded_Bytes;
      Progress_Value    : UInt64 := 0;
   end record;

   type Receive_Phase is
     (Not_Started, Start_Result, Tablespace_Result, Streams, End_Result,
      Awaiting_Ready, Finished);

   type Receiver
     (Connection : not null access Client.Session) is limited record
      Phase                  : Receive_Phase := Not_Started;
      Version                : Server_Major := 18;
      Manifest_Expected      : Boolean := False;
      Tablespace_Count       : Natural := 0;
      Streams_Started        : Natural := 0;
      Archive_Count          : Natural := 0;
      Manifest_Seen          : Boolean := False;
      Current_Is_Manifest    : Boolean := False;
      Start_Position         : LSN := 0;
      Start_Timeline         : UInt32 := 0;
   end record;

end Flyology.Postgres.Replication.Base_Backups;
