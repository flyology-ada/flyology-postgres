with Ada.Exceptions;
with Ada.Directories;
with Ada.Real_Time;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Base_Backups;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Server_Sessions;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Flyology.Postgres.Transports.Sockets;
with Flyology.Supervision.Families;
with Flyology.Supervision.Input_Children;
with Interfaces;
with Psqlbench_Docker;
with Psqlbench_JSON;

package body Psqlbench_Links is

   package Client renames Flyology.Postgres.Client;
   package Logical renames Flyology.Postgres.Replication.Logical;
   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Base_Backups renames
     Flyology.Postgres.Replication.Base_Backups;
   package Replication_Server renames
     Flyology.Postgres.Replication.Server_Sessions;
   package Server_Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Ada.Real_Time.Time;
   use type Client.Operation_State;
   use type Logical.Message_Kind;
   use type Logical.Old_Tuple_Kind;
   use type Logical.Tuple_Value_Kind;
   use type Protocol.Backend_Message_Kind;
   use type Ada.Real_Time.Time_Span;
   use type Interfaces.Unsigned_32;
   use type Protocol.Frontend_Kind;
   use type Protocol.Replication_Connection_Mode;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Replication.Stream_Message_Kind;
   use type Base_Backups.Event_Kind;
   use type Psqlbench_Context.Link_Command_Kind;
   use type Psqlbench_Context.Link_Mode;

   function Text
     (Value : String; Length : Natural) return String is
     (if Length = 0 then ""
      else Value (Value'First .. Value'First + Length - 1));

   function Link_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Name, Item.Name_Length));

   function Source_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Source, Item.Source_Length));

   function Target_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Target, Item.Target_Length));

   function Target_Version
     (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Target_Version, Item.Target_Version_Length));

   function Table_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Table_Name, Item.Table_Length));

   function Source_Schema (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Source_Schema, Item.Source_Schema_Length));

   function Source_Table (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Source_Table, Item.Source_Table_Length));

   function Target_Schema (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Target_Schema, Item.Target_Schema_Length));

   function Target_Table (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Target_Table, Item.Target_Table_Length));

   function Slot_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Table_Name (Item));

   function Publication_Name
     (Item : Psqlbench_Context.Link_Record) return String is
     (Table_Name (Item) & "_pub");

   function Protocol_Version
     (Item : Psqlbench_Context.Link_Record)
      return Logical.Protocol_Version is
     (if Item.Mode = Psqlbench_Context.Logical_Two_Phase_Streaming then 4
      elsif Item.Mode = Psqlbench_Context.Logical_Two_Phase then 3
      elsif Item.Mode = Psqlbench_Context.Logical_Streaming then 2 else 1);

   function Streaming_Mode
     (Item : Psqlbench_Context.Link_Record)
      return Logical.Streaming_Mode is
     (if Item.Mode in Psqlbench_Context.Logical_Streaming |
          Psqlbench_Context.Logical_Two_Phase_Streaming
      then Logical.In_Progress else Logical.Disabled);

   function Is_Streaming (Item : Psqlbench_Context.Link_Record) return Boolean is
     (Item.Mode in Psqlbench_Context.Logical_Streaming |
        Psqlbench_Context.Logical_Two_Phase_Streaming);

   function Is_Two_Phase (Item : Psqlbench_Context.Link_Record) return Boolean is
     (Item.Mode in Psqlbench_Context.Logical_Two_Phase |
        Psqlbench_Context.Logical_Two_Phase_Streaming);

   function Mode_Image (Item : Psqlbench_Context.Link_Record) return String is
     (case Item.Mode is
         when Psqlbench_Context.Logical_Committed => "logical committed",
         when Psqlbench_Context.Logical_Streaming => "logical streaming",
         when Psqlbench_Context.Logical_Two_Phase => "logical two-phase",
         when Psqlbench_Context.Logical_Two_Phase_Streaming =>
           "logical two-phase streaming",
         when Psqlbench_Context.Physical_Streaming => "physical streaming");

   function Compact (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Preview (Value : String; Limit : Positive := 140) return String is
     (if Value'Length <= Limit then Value
      else Value (Value'First .. Value'First + Limit - 1) & "...");

   function Tuple_Value_Image (Item : Logical.Tuple_Value) return String is
   begin
      case Logical.Kind (Item) is
         when Logical.Null_Value =>
            return "NULL";
         when Logical.Unchanged_Toast_Value =>
            return "<unchanged TOAST>";
         when Logical.Text_Value =>
            return '"' & Preview (Logical.Text (Item)) & '"';
         when Logical.Binary_Value =>
            declare
               Bytes : constant Logical.Byte_Array := Logical.Value (Item);
            begin
               return "<binary " & Compact (Bytes'Length) & " bytes>";
            end;
      end case;
   end Tuple_Value_Image;

   function Tuple_Image (Item : Logical.Tuple_Data) return String is
      Result : Unbounded_String := To_Unbounded_String ("{");
   begin
      for Index in 1 .. Logical.Column_Count (Item) loop
         if Index > 1 then
            Append (Result, ", ");
         end if;
         Append
           (Result,
            "column_" & Compact (Index) & "="
            & Tuple_Value_Image (Logical.Column (Item, Index)));
      end loop;
      Append (Result, "}");
      return To_String (Result);
   end Tuple_Image;

   function Change_Context (Item : Logical.Message) return String is
      Relation : constant String :=
        Ada.Strings.Fixed.Trim
          (Logical.UInt32'Image (Logical.Relation_Id (Item)),
           Ada.Strings.Both);
      Transaction : constant Logical.Transaction_Id :=
        Logical.Transaction (Item);
   begin
      return "relation=" & Relation
        & (if Transaction = 0 then ""
           else " xid="
             & Ada.Strings.Fixed.Trim
               (Logical.Transaction_Id'Image (Transaction),
                Ada.Strings.Both));
   end Change_Context;

   function Message_Detail (Item : Logical.Message) return String is
   begin
      case Logical.Kind (Item) is
         when Logical.Insert_Message =>
            return Change_Context (Item) & " new="
              & Tuple_Image (Logical.New_Tuple (Item));
         when Logical.Update_Message =>
            return Change_Context (Item)
              & (if Logical.Old_Kind (Item) = Logical.No_Old_Tuple
                 then ""
                 else " old=" & Tuple_Image (Logical.Old_Tuple (Item)))
              & " new=" & Tuple_Image (Logical.New_Tuple (Item));
         when Logical.Delete_Message =>
            return Change_Context (Item)
              & " old=" & Tuple_Image (Logical.Old_Tuple (Item));
         when Logical.Logical_Decoding_Message =>
            return
              (if Logical.Is_Transactional (Item)
               then "transactional message: "
               else "non-transactional message: ")
              & Logical.Prefix (Item);
         when Logical.Stream_Start_Message =>
            return
              (if Logical.Is_First_Stream_Segment (Item)
               then "first transaction segment"
               else "continued transaction segment");
         when Logical.Begin_Prepare_Message |
              Logical.Prepare_Message |
              Logical.Commit_Prepared_Message |
              Logical.Rollback_Prepared_Message |
              Logical.Stream_Prepare_Message =>
            return "gid=" & Logical.GID (Item);
         when others =>
            return "";
      end case;
   end Message_Detail;

   function Quote_Literal (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("'");
   begin
      for Character of Value loop
         if Character = ''' then
            Append (Result, "''");
         else
            Append (Result, Character);
         end if;
      end loop;
      Append (Result, "'");
      return To_String (Result);
   end Quote_Literal;

   function Quote_Identifier (Value : String) return String is
      Result : Unbounded_String := To_Unbounded_String ("""");
   begin
      for Character of Value loop
         if Character = '"' then
            Append (Result, """""");
         else
            Append (Result, Character);
         end if;
      end loop;
      Append (Result, '"');
      return To_String (Result);
   end Quote_Identifier;

   function Qualified (Schema, Relation : String) return String is
     (Quote_Identifier (Schema) & "." & Quote_Identifier (Relation));

   function Target_GID
     (Item : Psqlbench_Context.Link_Record;
      Message : Logical.Message) return String
   is
      Prefix : constant String := Link_Name (Item) & ":";
      Source : constant String := Logical.GID (Message);
      Available : constant Natural := 200 - Prefix'Length;
   begin
      return Prefix
        & (if Source'Length <= Available then Source
           else Source (Source'First .. Source'First + Available - 1));
   end Target_GID;

   function Activity_Document
     (Name, Stage, Direction, Kind, Detail : String;
      LSN : Replication.LSN := 0) return String
   is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "type", "link.activity");
      Psqlbench_JSON.String_Value (Document, "link", Name);
      Psqlbench_JSON.String_Value (Document, "stage", Stage);
      Psqlbench_JSON.String_Value (Document, "direction", Direction);
      Psqlbench_JSON.String_Value (Document, "kind", Kind);
      if LSN > 0 then
         Psqlbench_JSON.String_Value
           (Document, "lsn", Replication.Image (LSN));
      end if;
      if Detail'Length > 0 then
         Psqlbench_JSON.String_Value (Document, "detail", Detail);
      end if;
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Activity_Document;

   procedure Emit
     (Context : in out Psqlbench_Context.Context;
      Item : Psqlbench_Context.Link_Record;
      Stage, Direction, Kind : String;
      LSN : Replication.LSN := 0;
      Detail : String := "") is
   begin
      Context.Events.Append
        (Activity_Document
           (Link_Name (Item), Stage, Direction, Kind, Detail, LSN));
   end Emit;

   procedure Raise_Server_Error (Event : Protocol.Backend_Message) is
   begin
      if Protocol.Response_Kind (Event) = Protocol.Error_Response then
         raise Program_Error with
           Protocol.Diagnostic_SQL_State (Protocol.Diagnostic_Data (Event))
           & ": "
           & Protocol.Diagnostic_Message (Protocol.Diagnostic_Data (Event));
      end if;
   end Raise_Server_Error;

   procedure Consume_Query
     (Session   : in out Client.Session;
      First     : out Unbounded_String;
      Has_First : out Boolean) is
   begin
      First := Null_Unbounded_String;
      Has_First := False;
      loop
         declare
            Event : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Session, Timeout => 20.0);
         begin
            Raise_Server_Error (Event);
            if not Has_First
              and then Protocol.Response_Kind (Event) =
                Protocol.Data_Row_Response
            then
               declare
                  Row : constant Protocol.Data_Row := Protocol.Row_Data (Event);
               begin
                  if Protocol.Column_Count (Row) > 0
                    and then not Protocol.Is_Null (Protocol.Column_At (Row, 1))
                  then
                     First := To_Unbounded_String
                       (Protocol.Column_Text (Protocol.Column_At (Row, 1)));
                     Has_First := True;
                  end if;
               end;
            elsif Protocol.Response_Kind (Event) =
              Protocol.Ready_For_Query_Response
            then
               return;
            end if;
         end;
      end loop;
   end Consume_Query;

   procedure Run_SQL
     (Session : in out Client.Session; SQL : String) is
      Ignored : Unbounded_String;
      Has_Row : Boolean;
   begin
      Client.Send_Query (Session, SQL, Timeout => 20.0);
      Consume_Query (Session, Ignored, Has_Row);
   end Run_SQL;

   function Scalar_SQL
     (Session : in out Client.Session; SQL : String) return String is
      Value : Unbounded_String;
      Has_Row : Boolean;
   begin
      Client.Send_Query (Session, SQL, Timeout => 20.0);
      Consume_Query (Session, Value, Has_Row);
      return (if Has_Row then To_String (Value) else "");
   end Scalar_SQL;

   procedure Connect
     (Socket  : in out Sockets.Socket_Type;
      Session : in out Client.Session;
      Port    : Positive;
      Application_Name : String;
      Replication_Mode : Protocol.Replication_Connection_Mode :=
        Protocol.Normal_Connection)
   is
      Endpoint : constant Sockets.Endpoint :=
        Sockets.Network_Endpoint
          (Sockets.Loopback_IPv4, Sockets.Port (Port));
   begin
      Sockets.Create_Socket (Socket, Family => Endpoint.Family);
      Sockets.Connect (Socket, Endpoint, Timeout => 10.0);
      Client.Startup
        (Session,
         User             => "psqlbench",
         Database         => "postgres",
         Password         => "psqlbench",
         Application_Name => Application_Name,
         Timeout          => 20.0,
         Replication_Mode => Replication_Mode);
   end Connect;

   function Instance_Port (Name : String) return Positive is
      Value : constant Psqlbench_Docker.Result :=
        Psqlbench_Docker.Instance_Port (Name);
      Port : Positive;
   begin
      if not Value.Success then
         raise Program_Error with
           "cannot resolve " & Name & ": " & Psqlbench_Docker.Text (Value);
      end if;
      Port := Positive'Value
        (Ada.Strings.Fixed.Trim
           (Psqlbench_Docker.Text (Value), Ada.Strings.Both));
      return Port;
   end Instance_Port;

   function Instance_Major (Name : String) return Positive is
      Value : constant Psqlbench_Docker.Result :=
        Psqlbench_Docker.Instance_Version (Name);
      Version : constant String :=
        (if Value.Success
         then Ada.Strings.Fixed.Trim
           (Psqlbench_Docker.Text (Value), Ada.Strings.Both)
         else "");
      Dot : constant Natural := Ada.Strings.Fixed.Index (Version, ".");
   begin
      if not Value.Success or else Version'Length = 0 then
         raise Program_Error with
           "cannot resolve " & Name & " version: "
           & Psqlbench_Docker.Text (Value);
      end if;
      return Positive'Value
        (Version
           (Version'First ..
              (if Dot = 0 then Version'Last else Dot - 1)));
   end Instance_Major;

   type Relay_Frame is record
      WAL_Start : Replication.LSN := 0;
      WAL_End   : Replication.LSN := 0;
      Sent_At   : Replication.Replication_Timestamp := 0;
      Data      : Flyology.Bytes.Unbounded_Bytes;
   end record;

   Relay_Capacity : constant := 32;
   type Relay_Frame_Array is array (Positive range 1 .. Relay_Capacity) of
     Relay_Frame;

   protected type Relay_State is
      entry Push (Frame : Relay_Frame; Accepted : out Boolean);
      procedure Try_Pop (Frame : out Relay_Frame; Available : out Boolean);
      procedure Stop;
      function Stopped return Boolean;
      procedure Fail (Detail : String);
      procedure Read_Failure
        (Failed : out Boolean; Detail : out String; Last : out Natural);
      procedure Set_Server_Ready;
      function Server_Ready return Boolean;
      procedure Set_Upstream_Ready;
      function Upstream_Ready return Boolean;
      procedure Acknowledge (LSN : Replication.LSN);
      function Acknowledged return Replication.LSN;
      procedure Observe_WAL (LSN : Replication.LSN);
      function Current_WAL return Replication.LSN;
      procedure Request_Start (LSN : Replication.LSN);
      function Start_Requested return Boolean;
      function Requested_Start return Replication.LSN;
   private
      Frames : Relay_Frame_Array;
      Head : Positive := 1;
      Count : Natural range 0 .. Relay_Capacity := 0;
      Is_Stopped : Boolean := False;
      Is_Failed : Boolean := False;
      Failure_Length : Natural range 0 .. 320 := 0;
      Failure : String (1 .. 320) := (others => ' ');
      Server_Is_Ready : Boolean := False;
      Upstream_Is_Ready : Boolean := False;
      Applied : Replication.LSN := 0;
      Current : Replication.LSN := 0;
      Has_Start_Request : Boolean := False;
      Requested_Position : Replication.LSN := 0;
   end Relay_State;

   protected body Relay_State is
      entry Push (Frame : Relay_Frame; Accepted : out Boolean)
        when Count < Relay_Capacity or Is_Stopped is
         Slot : Positive;
      begin
         Accepted := not Is_Stopped;
         if Accepted then
            Slot := ((Head - 1 + Count) mod Relay_Capacity) + 1;
            Frames (Slot) := Frame;
            Count := Count + 1;
         end if;
      end Push;

      procedure Try_Pop
        (Frame : out Relay_Frame; Available : out Boolean) is
      begin
         Available := Count > 0;
         Frame := (others => <>);
         if Available then
            Frame := Frames (Head);
            Frames (Head) := (others => <>);
            Head := (if Head = Relay_Capacity then 1 else Head + 1);
            Count := Count - 1;
         end if;
      end Try_Pop;

      procedure Stop is
      begin
         Is_Stopped := True;
      end Stop;

      function Stopped return Boolean is (Is_Stopped);

      procedure Fail (Detail : String) is
      begin
         Is_Failed := True;
         Is_Stopped := True;
         Failure_Length := Natural'Min (Failure'Length, Detail'Length);
         if Failure_Length > 0 then
            Failure (1 .. Failure_Length) :=
              Detail (Detail'First .. Detail'First + Failure_Length - 1);
         end if;
      end Fail;

      procedure Read_Failure
        (Failed : out Boolean; Detail : out String; Last : out Natural) is
      begin
         Failed := Is_Failed;
         Last := Natural'Min (Failure_Length, Detail'Length);
         if Last > 0 then
            Detail (Detail'First .. Detail'First + Last - 1) :=
              Failure (1 .. Last);
         end if;
      end Read_Failure;

      procedure Set_Server_Ready is
      begin
         Server_Is_Ready := True;
      end Set_Server_Ready;

      function Server_Ready return Boolean is (Server_Is_Ready);

      procedure Set_Upstream_Ready is
      begin
         Upstream_Is_Ready := True;
      end Set_Upstream_Ready;

      function Upstream_Ready return Boolean is (Upstream_Is_Ready);

      procedure Acknowledge (LSN : Replication.LSN) is
      begin
         if LSN > Applied then
            Applied := LSN;
         end if;
      end Acknowledge;

      function Acknowledged return Replication.LSN is (Applied);

      procedure Observe_WAL (LSN : Replication.LSN) is
      begin
         if LSN > Current then
            Current := LSN;
         end if;
      end Observe_WAL;

      function Current_WAL return Replication.LSN is (Current);

      procedure Request_Start (LSN : Replication.LSN) is
      begin
         Requested_Position := LSN;
         Has_Start_Request := True;
      end Request_Start;

      function Start_Requested return Boolean is (Has_Start_Request);

      function Requested_Start return Replication.LSN is
        (Requested_Position);
   end Relay_State;

   type Relay_Context is limited record
      Relay : access Relay_State;
      Root  : access Psqlbench_Context.Context;
      Link  : Psqlbench_Context.Link_Record;
      System_Id : Replication.UInt64 := 0;
      Timeline : Replication.UInt32 := 1;
      Current_WAL : Replication.LSN := 0;
   end record;

   function Authenticate
     (State    : in out Relay_Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
   begin
      return To_String (Startup.User) = "psqlbench"
        and then Password = "psqlbench"
        and then
          (if State.Link.Mode = Psqlbench_Context.Physical_Streaming
           then Startup.Replication_Mode =
             Protocol.Physical_Replication_Connection
           else Startup.Replication_Mode =
             Protocol.Logical_Replication_Connection);
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Relay_Context;
      Startup : Protocol.Startup_Information) return String is
      pragma Unreferenced (State, Startup);
   begin
      return "";
   end Lookup_SCRAM_Verifier;

   procedure Handle_Relay
     (State   : in out Relay_Context;
      Client  : in out Server_Sessions.Session;
      Message : Protocol.Message)
   is
      Command : Replication.Command;
      Last_Keepalive : Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Streaming : Boolean := False;
   begin
      if Protocol.Kind (Message) /= Protocol.Query then
         Server_Sessions.Send_Error
           (Client, "psqlbench relay only accepts replication commands",
            SQL_State => "0A000", Timeout => 10.0);
         Server_Sessions.Send_Ready (Client, Timeout => 10.0);
         return;
      end if;

      Command := Replication.Decode_Command (Message);
      if State.Link.Mode = Psqlbench_Context.Physical_Streaming then
         case Replication.Kind (Command) is
            when Replication.Identify_System_Command =>
               Replication_Server.Send_Identify_System
                 (Client,
                  System_Id   => State.System_Id,
                  Timeline    => State.Timeline,
                  Current_WAL => State.Current_WAL,
                  Timeout     => 10.0);
               return;
            when Replication.Show_Command =>
               declare
                  Parameter : constant String :=
                    Replication.Parameter (Command);
                  Value : constant String :=
                    (if Parameter = "wal_segment_size" then "16MB"
                     elsif Parameter = "data_directory_mode" then "0700"
                     elsif Parameter = "wal_level" then "logical"
                     else "on");
               begin
                  Replication_Server.Send_Show
                    (Client, Parameter, Value, Timeout => 10.0);
               end;
               return;
            when Replication.Timeline_History_Command =>
               Server_Sessions.Send_Error
                 (Client, "timeline history is unavailable for this live proxy",
                  SQL_State => "0A000", Timeout => 10.0);
               Server_Sessions.Send_Ready (Client, Timeout => 10.0);
               return;
            when Replication.Start_Physical_Command =>
               if Replication.Slot_Name (Command) /= Slot_Name (State.Link) then
                  Server_Sessions.Send_Error
                    (Client, "physical slot does not belong to this relay",
                     SQL_State => "42704", Timeout => 10.0);
                  Server_Sessions.Send_Ready (Client, Timeout => 10.0);
                  return;
               end if;
               State.Relay.Request_Start (Replication.Position (Command));
            when others =>
               Server_Sessions.Send_Error
                 (Client, "command is not available on a physical relay",
                  SQL_State => "0A000", Timeout => 10.0);
               Server_Sessions.Send_Ready (Client, Timeout => 10.0);
               return;
         end case;
      elsif Replication.Kind (Command) /=
        Replication.Start_Logical_Command
      then
         Server_Sessions.Send_Error
           (Client, "psqlbench logical relay expects START_REPLICATION",
            SQL_State => "0A000", Timeout => 10.0);
         Server_Sessions.Send_Ready (Client, Timeout => 10.0);
         return;
      elsif Replication.Slot_Name (Command) /= Slot_Name (State.Link) then
         Server_Sessions.Send_Error
           (Client, "logical slot does not belong to this relay",
            SQL_State => "42704", Timeout => 10.0);
         Server_Sessions.Send_Ready (Client, Timeout => 10.0);
         return;
      end if;

      Replication_Server.Begin_Streaming (Client, Timeout => 10.0);
      Streaming := True;
      Emit
        (State.Root.all, State.Link, "relay", "downstream", "copy-both");
      while not State.Relay.Stopped loop
         declare
            Frame : Relay_Frame;
            Available : Boolean;
         begin
            State.Relay.Try_Pop (Frame, Available);
            if Available then
               declare
                  Data : constant Replication.Byte_Array :=
                    Flyology.Bytes.To_Array (Frame.Data);
               begin
                  Replication_Server.Send_XLog_Data
                    (Client, Frame.WAL_Start, Frame.WAL_End, Frame.Sent_At,
                     Data, Timeout => 10.0);
               end;
            elsif Ada.Real_Time.Clock - Last_Keepalive >=
              Ada.Real_Time.Seconds (1)
            then
               Replication_Server.Send_Primary_Keepalive
                 (Client,
                  WAL_End => State.Relay.Current_WAL,
                  Sent_At => 0,
                  Reply_Requested => True,
                  Timeout => 10.0);
               Emit
                 (State.Root.all, State.Link, "relay", "relay-to-downstream",
                  "PRIMARY_KEEPALIVE", State.Relay.Current_WAL,
                  "reply requested");
               Last_Keepalive := Ada.Real_Time.Clock;
            else
               delay 0.010;
            end if;

            begin
               declare
                  Feedback : constant Replication.Stream_Message :=
                    Replication_Server.Read_Standby_Message
                      (Client, Timeout => 0.001);
               begin
                  if Replication.Kind (Feedback) =
                    Replication.Standby_Status_Update
                  then
                     State.Relay.Acknowledge
                       (Replication.Applied_LSN (Feedback));
                     State.Root.Links.Record_Applied
                       (Link_Name (State.Link),
                        Replication.Applied_LSN (Feedback));
                     Emit
                       (State.Root.all, State.Link, "feedback",
                        "downstream-to-relay", "STANDBY_STATUS_UPDATE",
                        Replication.Applied_LSN (Feedback),
                        "write="
                        & Replication.Image
                          (Replication.Received_LSN (Feedback))
                        & " flush="
                        & Replication.Image
                          (Replication.Flushed_LSN (Feedback))
                        & " apply="
                        & Replication.Image
                          (Replication.Applied_LSN (Feedback)));
                  elsif Replication.Kind (Feedback) =
                    Replication.Hot_Standby_Feedback
                  then
                     Emit
                       (State.Root.all, State.Link, "feedback",
                        "downstream-to-relay", "HOT_STANDBY_FEEDBACK",
                        Detail => "xmin horizon received");
                  end if;
               end;
            exception
               when Flyology.IO.Timeout_Error => null;
            end;
         end;
      end loop;
   exception
      when Error : others =>
         if Streaming and then not State.Relay.Stopped then
            State.Relay.Fail
              ("downstream replication consumer: "
               & Ada.Exceptions.Exception_Message (Error));
         end if;
         raise;
   end Handle_Relay;

   package Relay_Server is new Flyology.Postgres.Server
     (Handler_Context       => Relay_Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle_Relay,
      Authentication        => Flyology.Postgres.Cleartext_Password,
      Handler_Model         => Flyology.Lightweight_Task,
      Command_Timeout       => 2.0);

   procedure Start_Copy
     (Session : in out Client.Session; Command : Protocol.Message) is
   begin
      Client.Send_Command (Session, Command, Timeout => 10.0);
      loop
         declare
            Event : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Session, Timeout => 20.0);
         begin
            Raise_Server_Error (Event);
            exit when Protocol.Response_Kind (Event) =
              Protocol.Copy_Both_Response;
         end;
      end loop;
      if Client.State (Session) /= Client.Copy_Both_Active then
         raise Program_Error with "replication stream did not enter COPY BOTH";
      end if;
   end Start_Copy;

   function Tuple_SQL (Value : Logical.Tuple_Value) return String is
   begin
      case Logical.Kind (Value) is
         when Logical.Null_Value =>
            return "NULL";
         when Logical.Text_Value =>
            return Quote_Literal (Logical.Text (Value));
         when Logical.Unchanged_Toast_Value =>
            raise Program_Error with
              "unchanged TOAST cannot be used as a complete row value";
         when Logical.Binary_Value =>
            raise Program_Error with
              "binary pgoutput values are not enabled by this link";
      end case;
   end Tuple_SQL;

   Max_Relation_Columns : constant := 64;
   type Relation_Column_Names is
     array (Positive range 1 .. Max_Relation_Columns) of Unbounded_String;
   type Relation_Key_Flags is
     array (Positive range 1 .. Max_Relation_Columns) of Boolean;
   type Relation_State is record
      Oid : Logical.UInt32 := 0;
      Count : Natural range 0 .. Max_Relation_Columns := 0;
      Names : Relation_Column_Names;
      Keys : Relation_Key_Flags := (others => False);
   end record;

   procedure Apply_Message
     (Session : in out Client.Session;
      Item    : Psqlbench_Context.Link_Record;
      Message : Logical.Message;
      Relation : in out Relation_State;
      In_Transaction : in out Boolean;
      Active_Stream : in out Replication.Transaction_Id;
      Applied : out Boolean)
   is
      Table : constant String :=
        Qualified (Target_Schema (Item), Target_Table (Item));

      function Tuple_Value
        (Tuple : Logical.Tuple_Data; Index : Positive) return String is
        (Tuple_SQL (Logical.Column (Tuple, Index)));

      function Key_Count return Natural is
         Result : Natural := 0;
      begin
         for Index in 1 .. Relation.Count loop
            if Relation.Keys (Index) then
               Result := Result + 1;
            end if;
         end loop;
         return Result;
      end Key_Count;

      function Where_Clause
        (Tuple : Logical.Tuple_Data; Key_Only : Boolean) return String
      is
         SQL : Unbounded_String;
         Tuple_Index : Positive := 1;
         Use_Keys : constant Boolean := Key_Count > 0;
      begin
         for Index in 1 .. Relation.Count loop
            if (Use_Keys and then Relation.Keys (Index))
              or else not Use_Keys
            then
               if Length (SQL) > 0 then
                  Append (SQL, " AND ");
               end if;
               Append
                 (SQL,
                  Quote_Identifier (To_String (Relation.Names (Index)))
                  & " IS NOT DISTINCT FROM "
                  & Tuple_Value
                    (Tuple, (if Key_Only then Tuple_Index else Index)));
               Tuple_Index := Tuple_Index + 1;
            end if;
         end loop;
         if Length (SQL) = 0 then
            raise Program_Error with
              "mapped relation has no usable replica identity";
         end if;
         return To_String (SQL);
      end Where_Clause;
   begin
      Applied := False;
      case Logical.Kind (Message) is
         when Logical.Begin_Message =>
            Run_SQL (Session, "BEGIN");
            In_Transaction := True;

         when Logical.Relation_Message =>
            if Logical.Namespace_Name (Message) = Source_Schema (Item)
              and then Logical.Object_Name (Message) = Source_Table (Item)
            then
               if Logical.Relation_Column_Count (Message) not in
                 1 .. Max_Relation_Columns
               then
                  raise Program_Error with
                    "mapped relations support 1 through 64 columns";
               end if;
               Relation := (others => <>);
               Relation.Oid := Logical.Relation_Id (Message);
               Relation.Count := Logical.Relation_Column_Count (Message);
               for Index in 1 .. Relation.Count loop
                  declare
                     Column : constant Logical.Relation_Column :=
                       Logical.Relation_Column_At (Message, Index);
                  begin
                     Relation.Names (Index) :=
                       To_Unbounded_String (Logical.Name (Column));
                     Relation.Keys (Index) := Logical.Is_Key (Column);
                  end;
               end loop;
            end if;

         when Logical.Insert_Message =>
            if Logical.Relation_Id (Message) = Relation.Oid then
               declare
                  New_Row : constant Logical.Tuple_Data :=
                    Logical.New_Tuple (Message);
                  SQL : Unbounded_String :=
                    To_Unbounded_String ("INSERT INTO " & Table & " (");
               begin
                  for Index in 1 .. Relation.Count loop
                     if Index > 1 then
                        Append (SQL, ",");
                     end if;
                     Append
                       (SQL, Quote_Identifier
                          (To_String (Relation.Names (Index))));
                  end loop;
                  Append (SQL, ") VALUES (");
                  for Index in 1 .. Relation.Count loop
                     if Index > 1 then
                        Append (SQL, ",");
                     end if;
                     Append (SQL, Tuple_Value (New_Row, Index));
                  end loop;
                  Append (SQL, ") ON CONFLICT DO NOTHING");
                  Run_SQL (Session, To_String (SQL));
                  Applied := True;
               end;
            end if;

         when Logical.Update_Message =>
            if Logical.Relation_Id (Message) = Relation.Oid then
               declare
                  New_Row : constant Logical.Tuple_Data :=
                    Logical.New_Tuple (Message);
                  SQL : Unbounded_String := To_Unbounded_String
                    ("UPDATE " & Table & " SET ");
                  Assignments : Natural := 0;
               begin
                  for Index in 1 .. Relation.Count loop
                     if Logical.Kind (Logical.Column (New_Row, Index)) /=
                       Logical.Unchanged_Toast_Value
                     then
                        if Assignments > 0 then
                           Append (SQL, ",");
                        end if;
                        Append
                          (SQL, Quote_Identifier
                             (To_String (Relation.Names (Index)))
                           & "=" & Tuple_Value (New_Row, Index));
                        Assignments := Assignments + 1;
                     end if;
                  end loop;
                  if Assignments > 0 then
                     if Logical.Old_Kind (Message) =
                       Logical.No_Old_Tuple
                       and then Key_Count = 0
                     then
                        raise Program_Error with
                          "UPDATE requires a replica identity key or FULL";
                     end if;
                     Append
                       (SQL, " WHERE "
                        & (if Logical.Old_Kind (Message) =
                              Logical.No_Old_Tuple
                           then Where_Clause (New_Row, False)
                           else Where_Clause
                             (Logical.Old_Tuple (Message),
                              Logical.Old_Kind (Message) =
                                Logical.Key_Old_Tuple)));
                     Run_SQL (Session, To_String (SQL));
                     Applied := True;
                  end if;
               end;
            end if;

         when Logical.Delete_Message =>
            if Logical.Relation_Id (Message) = Relation.Oid then
               Run_SQL
                 (Session, "DELETE FROM " & Table
                  & " WHERE "
                  & Where_Clause
                    (Logical.Old_Tuple (Message),
                     Logical.Old_Kind (Message) = Logical.Key_Old_Tuple));
               Applied := True;
            end if;

         when Logical.Truncate_Message =>
            for Index in 1 .. Logical.Truncated_Relation_Count (Message) loop
               if Logical.Truncated_Relation (Message, Index) = Relation.Oid then
                  Run_SQL (Session, "TRUNCATE TABLE " & Table);
                  Applied := True;
               end if;
            end loop;

         when Logical.Commit_Message =>
            if In_Transaction then
               Run_SQL (Session, "COMMIT");
               In_Transaction := False;
            end if;

         when Logical.Stream_Start_Message =>
            if Logical.Is_First_Stream_Segment (Message) then
               if Active_Stream /= 0 then
                  raise Program_Error with
                    "interleaved streamed transactions are not yet supported";
               end if;
               Active_Stream := Logical.Transaction (Message);
               Run_SQL (Session, "BEGIN");
               In_Transaction := True;
            elsif Active_Stream /= Logical.Transaction (Message) then
               raise Program_Error with
                 "stream segment does not continue the active transaction";
            end if;

         when Logical.Stream_Stop_Message =>
            null;

         when Logical.Stream_Commit_Message =>
            if Active_Stream /= Logical.Transaction (Message) then
               raise Program_Error with
                 "stream commit does not match the active transaction";
            end if;
            if In_Transaction then
               Run_SQL (Session, "COMMIT");
               In_Transaction := False;
            end if;
            Active_Stream := 0;

         when Logical.Stream_Abort_Message =>
            if Active_Stream /= Logical.Transaction (Message) then
               raise Program_Error with
                 "stream abort does not match the active transaction";
            end if;
            if In_Transaction then
               Run_SQL (Session, "ROLLBACK");
               In_Transaction := False;
            end if;
            Active_Stream := 0;

         when Logical.Begin_Prepare_Message =>
            Run_SQL (Session, "BEGIN");
            In_Transaction := True;

         when Logical.Prepare_Message =>
            if not In_Transaction then
               raise Program_Error with
                 "prepare arrived without an active target transaction";
            end if;
            Run_SQL
              (Session, "PREPARE TRANSACTION "
               & Quote_Literal (Target_GID (Item, Message)));
            In_Transaction := False;

         when Logical.Commit_Prepared_Message =>
            Run_SQL
              (Session, "COMMIT PREPARED "
               & Quote_Literal (Target_GID (Item, Message)));

         when Logical.Rollback_Prepared_Message =>
            Run_SQL
              (Session, "ROLLBACK PREPARED "
               & Quote_Literal (Target_GID (Item, Message)));

         when Logical.Stream_Prepare_Message =>
            if Active_Stream /= Logical.Transaction (Message)
              or else not In_Transaction
            then
               raise Program_Error with
                 "stream prepare does not match the active transaction";
            end if;
            Run_SQL
              (Session, "PREPARE TRANSACTION "
               & Quote_Literal (Target_GID (Item, Message)));
            In_Transaction := False;
            Active_Stream := 0;

         when others =>
            null;
      end case;
   end Apply_Message;

   procedure Start_Logical_Copy
     (Session : in out Client.Session;
      Item : Psqlbench_Context.Link_Record;
      Slot : String;
      Position : Replication.LSN;
      Publication : String) is
   begin
      if Is_Two_Phase (Item) and then Is_Streaming (Item) then
         Start_Copy
           (Session,
            Replication.Start_Logical
              (Slot, Position,
               (Replication.Option ("proto_version", "4"),
                Replication.Option ("publication_names", Publication),
                Replication.Option ("streaming", "on"),
                Replication.Option ("two_phase", "on"),
                Replication.Option ("messages", "true"))));
      elsif Is_Two_Phase (Item) then
         Start_Copy
           (Session,
            Replication.Start_Logical
              (Slot, Position,
               (Replication.Option ("proto_version", "3"),
                Replication.Option ("publication_names", Publication),
                Replication.Option ("two_phase", "on"),
                Replication.Option ("messages", "true"))));
      elsif Is_Streaming (Item) then
         Start_Copy
           (Session,
            Replication.Start_Logical
              (Slot, Position,
               (Replication.Option ("proto_version", "2"),
                Replication.Option ("publication_names", Publication),
                Replication.Option ("streaming", "on"),
                Replication.Option ("messages", "true"))));
      else
         Start_Copy
           (Session,
            Replication.Start_Logical
              (Slot, Position,
               (Replication.Option ("proto_version", "1"),
                Replication.Option ("publication_names", Publication),
                Replication.Option ("messages", "true"))));
      end if;
   end Start_Logical_Copy;

   procedure Run_Logical_Link
     (Context : in out Psqlbench_Context.Context;
      Item    : Psqlbench_Context.Link_Record;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Source_Port : constant Positive := Instance_Port (Source_Name (Item));
      Target_Port : constant Positive := Instance_Port (Target_Name (Item));
      Link : constant String := Link_Name (Item);
      Table : constant String := Table_Name (Item);
      Source_Relation : constant String :=
        Qualified (Source_Schema (Item), Source_Table (Item));
      Target_Relation : constant String :=
        Qualified (Target_Schema (Item), Target_Table (Item));
      Publication : constant String := Publication_Name (Item);
      Slot : constant String := Slot_Name (Item);
      Start_LSN : Replication.LSN := 0;
      Relay : aliased Relay_State;
      Listener : Sockets.Socket_Type;
      Server : aliased Relay_Server.Server (Capacity => 2);
      Server_Context : aliased Relay_Context :=
        (Relay => Relay'Unrestricted_Access,
         Root  => Context'Unrestricted_Access,
         Link  => Item,
         others => <>);

      procedure Setup is
         Source_Socket : aliased Sockets.Socket_Type;
         Source_Channel : aliased Transports.Socket_Transport
           (Source_Socket'Access);
         Source : Client.Session (Source_Channel'Access);
         Target_Socket : aliased Sockets.Socket_Type;
         Target_Channel : aliased Transports.Socket_Transport
           (Target_Socket'Access);
         Target : Client.Session (Target_Channel'Access);
         Existing : Unbounded_String;
         Has_Row : Boolean;
         Source_Major : constant Positive :=
           Instance_Major (Source_Name (Item));
         Source_Schema_SQL : constant String :=
           "CREATE TABLE IF NOT EXISTS " & Source_Relation & " ("
           & "id bigint PRIMARY KEY, payload text NOT NULL, "
           & "changed_at timestamptz NOT NULL DEFAULT clock_timestamp())";
         Target_Schema_SQL : constant String :=
           "CREATE TABLE IF NOT EXISTS " & Target_Relation & " ("
           & "id bigint PRIMARY KEY, payload text NOT NULL, "
           & "changed_at timestamptz NOT NULL DEFAULT clock_timestamp())";
         Managed_Source : constant Boolean :=
           Source_Schema (Item) = "public"
           and then Source_Table (Item) = Table;
         Managed_Target : constant Boolean :=
           Target_Schema (Item) = "public"
           and then Target_Table (Item) = Table;
      begin
         if Is_Two_Phase (Item) and then Source_Major < 15 then
            raise Program_Error with
              "two-phase logical replication requires PostgreSQL 15 or newer";
         end if;
         Connect
           (Source_Socket, Source, Source_Port,
            "psqlbench/link-setup/source/" & Link);
         Connect
           (Target_Socket, Target, Target_Port,
            "psqlbench/link-setup/target/" & Link);
         if Managed_Source then
            Run_SQL (Source, Source_Schema_SQL);
         end if;
         if Managed_Target then
            Run_SQL (Target, Target_Schema_SQL);
         end if;
         if Scalar_SQL
           (Source,
            "SELECT count(*)::text FROM information_schema.columns "
            & "WHERE table_schema=" & Quote_Literal (Source_Schema (Item))
            & " AND table_name=" & Quote_Literal (Source_Table (Item))) = "0"
           or else Scalar_SQL
             (Target,
              "SELECT count(*)::text FROM information_schema.columns "
              & "WHERE table_schema=" & Quote_Literal (Target_Schema (Item))
              & " AND table_name=" & Quote_Literal (Target_Table (Item))) = "0"
         then
            raise Program_Error with
              "both mapped relations must exist";
         end if;
         Run_SQL
           (Target,
            "CREATE TABLE IF NOT EXISTS public.psqlbench_link_state ("
            & "link_name text PRIMARY KEY, slot_name text NOT NULL, "
            & "source_relation text, target_relation text, "
            & "snapshot_lsn pg_lsn NOT NULL, copied_rows bigint NOT NULL, "
            & "initialized_at timestamptz NOT NULL DEFAULT clock_timestamp())");
         Run_SQL
           (Target,
            "ALTER TABLE public.psqlbench_link_state "
            & "ADD COLUMN IF NOT EXISTS source_relation text, "
            & "ADD COLUMN IF NOT EXISTS target_relation text");
         if Is_Streaming (Item) then
            Run_SQL
              (Source,
               "ALTER ROLE psqlbench IN DATABASE postgres SET "
               & "logical_decoding_work_mem='64kB'");
         end if;
         Client.Send_Query
           (Source,
            "SELECT 1 FROM pg_publication_tables WHERE pubname="
            & Quote_Literal (Publication)
            & " AND schemaname=" & Quote_Literal (Source_Schema (Item))
            & " AND tablename=" & Quote_Literal (Source_Table (Item)),
            Timeout => 20.0);
         Consume_Query (Source, Existing, Has_Row);
         if not Has_Row then
            if Scalar_SQL
              (Source, "SELECT 1 FROM pg_publication WHERE pubname="
               & Quote_Literal (Publication))'Length > 0
            then
               raise Program_Error with
                 "existing publication belongs to another source relation";
            else
               Run_SQL
                 (Source, "CREATE PUBLICATION """ & Publication
                  & """ FOR TABLE " & Source_Relation);
            end if;
         end if;
         declare
            Position : constant String := Scalar_SQL
              (Source,
               "SELECT COALESCE(confirmed_flush_lsn,restart_lsn)::text "
               & "FROM pg_replication_slots WHERE slot_name="
               & Quote_Literal (Slot) & " AND slot_type='logical'");
            Initialized : constant String := Scalar_SQL
              (Target,
               "SELECT snapshot_lsn::text FROM public.psqlbench_link_state "
               & "WHERE link_name=" & Quote_Literal (Link)
               & " AND slot_name=" & Quote_Literal (Slot)
               & " AND source_relation="
               & Quote_Literal
                 (Source_Schema (Item) & "." & Source_Table (Item))
               & " AND target_relation="
               & Quote_Literal
                 (Target_Schema (Item) & "." & Target_Table (Item)));
         begin
            if Position'Length > 0 and then Initialized'Length > 0 then
               Start_LSN := Replication.Value (Position);
               Emit
                 (Context, Item, "snapshot", "source-to-target",
                  "SNAPSHOT_REUSED", Start_LSN,
                  "completed initialization boundary retained");
            else
               if Position'Length > 0 then
                  Run_SQL
                    (Source, "SELECT pg_drop_replication_slot("
                     & Quote_Literal (Slot) & ")");
               end if;
               declare
                  Slot_Socket : aliased Sockets.Socket_Type;
                  Slot_Channel : aliased Transports.Socket_Transport
                    (Slot_Socket'Access);
                  Slot_Session : Client.Session (Slot_Channel'Access);
                  Snapshot_Name : Unbounded_String;
                  Consistent_Point : Unbounded_String;
                  Snapshot_Columns : Relation_Column_Names;
                  Snapshot_Column_Count : Natural range
                    0 .. Max_Relation_Columns := 0;
                  Rows : Natural := 0;
               begin
                  Connect
                    (Slot_Socket, Slot_Session, Source_Port,
                     "psqlbench/snapshot-slot/" & Link,
                     Protocol.Logical_Replication_Connection);
                  Client.Send_Command
                    (Slot_Session,
                     Replication.Create_Logical_Slot
                       (Slot, Snapshot => Replication.Export_Snapshot,
                        Server_Major => Source_Major,
                        Two_Phase => Is_Two_Phase (Item)),
                     Timeout => 20.0);
                  loop
                     declare
                        Event : constant Client.Simple_Query_Event :=
                          Client.Receive_Query_Event
                            (Slot_Session, Timeout => 20.0);
                     begin
                        Raise_Server_Error (Event);
                        if Protocol.Response_Kind (Event) =
                          Protocol.Data_Row_Response
                        then
                           declare
                              Row : constant Protocol.Data_Row :=
                                Protocol.Row_Data (Event);
                           begin
                              if Protocol.Column_Count (Row) < 3
                                or else Protocol.Is_Null
                                  (Protocol.Column_At (Row, 2))
                                or else Protocol.Is_Null
                                  (Protocol.Column_At (Row, 3))
                              then
                                 raise Program_Error with
                                   "logical slot did not export a snapshot";
                              end if;
                              Consistent_Point := To_Unbounded_String
                                (Protocol.Column_Text
                                   (Protocol.Column_At (Row, 2)));
                              Snapshot_Name := To_Unbounded_String
                                (Protocol.Column_Text
                                   (Protocol.Column_At (Row, 3)));
                           end;
                        elsif Protocol.Response_Kind (Event) =
                          Protocol.Ready_For_Query_Response
                        then
                           exit;
                        end if;
                     end;
                  end loop;
                  if Length (Consistent_Point) = 0
                    or else Length (Snapshot_Name) = 0
                  then
                     raise Program_Error with
                       "logical slot creation returned no snapshot boundary";
                  end if;
                  Start_LSN := Replication.Value
                    (To_String (Consistent_Point));
                  Emit
                    (Context, Item, "snapshot", "source-to-target",
                     "SNAPSHOT_EXPORTED", Start_LSN,
                     To_String (Snapshot_Name));

                  Run_SQL
                    (Source,
                     "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY");
                  Run_SQL
                    (Source, "SET TRANSACTION SNAPSHOT "
                     & Quote_Literal (To_String (Snapshot_Name)));
                  Run_SQL (Target, "BEGIN");
                  begin
                     Run_SQL
                       (Target, "TRUNCATE TABLE " & Target_Relation);
                     Client.Send_Query
                       (Source,
                        "SELECT * FROM " & Source_Relation,
                        Timeout => 20.0);
                     loop
                        declare
                           Event : constant Client.Simple_Query_Event :=
                             Client.Receive_Query_Event
                               (Source, Timeout => 20.0);
                        begin
                           Raise_Server_Error (Event);
                           if Protocol.Response_Kind (Event) =
                             Protocol.Row_Description_Response
                           then
                              declare
                                 Description : constant Protocol.Row_Description :=
                                   Protocol.Description (Event);
                              begin
                                 if Protocol.Field_Count (Description) not in
                                   1 .. Max_Relation_Columns
                                 then
                                    raise Program_Error with
                                      "snapshot supports 1 through 64 columns";
                                 end if;
                                 Snapshot_Column_Count :=
                                   Protocol.Field_Count (Description);
                                 for Index in 1 .. Snapshot_Column_Count loop
                                    Snapshot_Columns (Index) :=
                                      To_Unbounded_String
                                        (Protocol.Field_Name
                                           (Protocol.Field_At
                                              (Description, Index)));
                                 end loop;
                              end;
                           elsif Protocol.Response_Kind (Event) =
                             Protocol.Data_Row_Response
                           then
                              declare
                                 Row : constant Protocol.Data_Row :=
                                   Protocol.Row_Data (Event);
                              begin
                                 if Snapshot_Column_Count = 0
                                   or else Protocol.Column_Count (Row) /=
                                     Snapshot_Column_Count
                                 then
                                    raise Program_Error with
                                      "snapshot row shape changed";
                                 end if;
                                 declare
                                    SQL : Unbounded_String :=
                                      To_Unbounded_String
                                        ("INSERT INTO " & Target_Relation
                                         & " (");
                                 begin
                                    for Index in 1 .. Snapshot_Column_Count loop
                                       if Index > 1 then
                                          Append (SQL, ",");
                                       end if;
                                       Append
                                         (SQL, Quote_Identifier
                                            (To_String
                                               (Snapshot_Columns (Index))));
                                    end loop;
                                    Append (SQL, ") VALUES (");
                                    for Index in 1 .. Snapshot_Column_Count loop
                                       if Index > 1 then
                                          Append (SQL, ",");
                                       end if;
                                       Append
                                         (SQL,
                                          (if Protocol.Is_Null
                                             (Protocol.Column_At (Row, Index))
                                           then "NULL"
                                           else Quote_Literal
                                             (Protocol.Column_Text
                                                (Protocol.Column_At
                                                   (Row, Index)))));
                                    end loop;
                                    Append (SQL, ")");
                                    Run_SQL (Target, To_String (SQL));
                                 end;
                                 Rows := Rows + 1;
                              end;
                           elsif Protocol.Response_Kind (Event) =
                             Protocol.Ready_For_Query_Response
                           then
                              exit;
                           end if;
                        end;
                     end loop;
                     Run_SQL
                       (Target,
                        "INSERT INTO public.psqlbench_link_state "
                        & "(link_name,slot_name,source_relation,"
                        & "target_relation,snapshot_lsn,copied_rows) "
                        & "VALUES (" & Quote_Literal (Link) & ","
                        & Quote_Literal (Slot) & ","
                        & Quote_Literal
                          (Source_Schema (Item) & "." & Source_Table (Item))
                        & "," & Quote_Literal
                          (Target_Schema (Item) & "." & Target_Table (Item))
                        & ","
                        & Quote_Literal (Replication.Image (Start_LSN)) & ","
                        & Compact (Rows) & ") ON CONFLICT (link_name) "
                        & "DO UPDATE SET slot_name=EXCLUDED.slot_name, "
                        & "source_relation=EXCLUDED.source_relation, "
                        & "target_relation=EXCLUDED.target_relation, "
                        & "snapshot_lsn=EXCLUDED.snapshot_lsn, "
                        & "copied_rows=EXCLUDED.copied_rows, "
                        & "initialized_at=clock_timestamp()");
                     Run_SQL (Target, "COMMIT");
                     Run_SQL (Source, "COMMIT");
                  exception
                     when others =>
                        begin
                           Run_SQL (Target, "ROLLBACK");
                        exception
                           when others => null;
                        end;
                        begin
                           Run_SQL (Source, "ROLLBACK");
                        exception
                           when others => null;
                        end;
                        raise;
                  end;
                  Emit
                    (Context, Item, "snapshot", "source-to-target",
                     "SNAPSHOT_COPIED", Start_LSN,
                     Compact (Rows) & " rows at a consistent boundary");
               end;
            end if;
         end;
         Emit
           (Context, Item, "setup", "source", "slot-ready",
            Start_LSN, Table);
      end Setup;
   begin
      Context.Links.Set_Status (Link, Psqlbench_Context.Link_Starting,
                                "preparing publication and logical slot");
      Setup;
      Context.Links.Record_Start (Link, Start_LSN);

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Loopback_IPv4, Sockets.Port (Item.Relay_Port)));
      Sockets.Listen_Socket (Listener, Length => 2);

      declare
         task Relay_Server_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Relay_Server_Task;

         task body Relay_Server_Task is
         begin
            Relay.Set_Server_Ready;
            Relay_Server.Serve
              (Server, Listener, Server_Context, Drain_Timeout => 1.0);
         exception
            when Error : others =>
               Relay.Fail
                 ("relay server: " & Ada.Exceptions.Exception_Message (Error));
         end Relay_Server_Task;

         task Upstream_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Upstream_Task;

         task body Upstream_Task is
            Socket : aliased Sockets.Socket_Type;
            Channel : aliased Transports.Socket_Transport (Socket'Access);
            Session : Client.Session (Channel'Access);
            Decoder : Logical.Decoder;
            Last_Ack : Replication.LSN := 0;
            Last_Feedback : Ada.Real_Time.Time := Ada.Real_Time.Clock;
         begin
            Connect
              (Socket, Session, Source_Port,
               "psqlbench/upstream/" & Link,
               Protocol.Logical_Replication_Connection);
            Logical.Configure
              (Decoder, Protocol_Version (Item), Streaming_Mode (Item));
            Start_Logical_Copy
              (Session, Item, Slot, Start_LSN, Publication);
            Relay.Set_Upstream_Ready;
            Emit
              (Context, Item, "upstream", "source-to-relay", "copy-both",
               Start_LSN);
            while not Relay.Stopped loop
               begin
                  declare
                     Event : constant Client.Copy_Event :=
                       Client.Receive_Copy_Event (Session, Timeout => 0.5);
                  begin
                     Raise_Server_Error (Event);
                     if Protocol.Response_Kind (Event) =
                       Protocol.Copy_Data_Response
                     then
                        declare
                           Frame : constant Replication.Stream_Message :=
                             Replication.Decode
                               (Protocol.Original_Message (Event));
                        begin
                           if Replication.Kind (Frame) = Replication.XLog_Data then
                              declare
                                 Logical_Message : constant Logical.Message :=
                                   Logical.Decode
                                     (Decoder, Replication.Data (Frame));
                                 Encoded : constant Logical.Byte_Array :=
                                   Logical.Encode
                                     (Logical_Message,
                                      Protocol_Version (Item),
                                      Streaming_Mode (Item));
                                 Forward : constant Relay_Frame :=
                                   (WAL_Start => Replication.WAL_Start (Frame),
                                    WAL_End   => Replication.WAL_End (Frame),
                                    Sent_At   => Replication.Sent_At (Frame),
                                    Data      =>
                                      Flyology.Bytes.To_Unbounded_Bytes
                                        (Encoded));
                                 Accepted : Boolean;
                              begin
                                 Emit
                                   (Context, Item, "decode",
                                    "source-to-relay",
                                    Logical.Message_Kind'Image
                                      (Logical.Kind (Logical_Message)),
                                    Replication.WAL_End (Frame),
                                    Message_Detail (Logical_Message));
                                 Relay.Push (Forward, Accepted);
                                 Relay.Observe_WAL
                                   (Replication.WAL_End (Frame));
                                 exit when not Accepted;
                              end;
                           elsif Replication.Kind (Frame) =
                             Replication.Primary_Keepalive
                           then
                              Relay.Observe_WAL
                                (Replication.WAL_End (Frame));
                              Emit
                                (Context, Item, "upstream",
                                 "source-to-relay", "PRIMARY_KEEPALIVE",
                                 Replication.WAL_End (Frame),
                                 (if Replication.Reply_Requested (Frame)
                                  then "reply requested" else "observed"));
                           end if;
                        end;
                     end if;
                  end;
               exception
                  when Flyology.IO.Timeout_Error => null;
               end;

               if Relay.Acknowledged > Last_Ack
                 or else Ada.Real_Time.Clock - Last_Feedback >=
                   Ada.Real_Time.Seconds (1)
               then
                  if Relay.Acknowledged > Last_Ack then
                     Last_Ack := Relay.Acknowledged;
                     Emit
                       (Context, Item, "ack", "relay-to-source",
                        "STANDBY_STATUS_UPDATE", Last_Ack,
                        "target commit acknowledged upstream");
                  end if;
                  Client.Send_Command
                    (Session,
                     Replication.Make_Standby_Status_Update
                       (Last_Ack, Last_Ack, Last_Ack, Sent_At => 0),
                     Timeout => 10.0);
                  Last_Feedback := Ada.Real_Time.Clock;
               end if;
            end loop;
         exception
            when Error : others =>
               Relay.Fail
                 ("upstream client: "
                  & Ada.Exceptions.Exception_Message (Error));
         end Upstream_Task;

         Downstream_Socket : aliased Sockets.Socket_Type;
         Downstream_Channel : aliased Transports.Socket_Transport
           (Downstream_Socket'Access);
         Downstream : Client.Session (Downstream_Channel'Access);
         Target_Socket : aliased Sockets.Socket_Type;
         Target_Channel : aliased Transports.Socket_Transport
           (Target_Socket'Access);
         Target : Client.Session (Target_Channel'Access);
         Decoder : Logical.Decoder;
         Relation : Relation_State;
         In_Transaction : Boolean := False;
         Active_Stream : Replication.Transaction_Id := 0;
         Ready_Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
      begin
         while not (Relay.Server_Ready and Relay.Upstream_Ready) loop
            exit when Relay.Stopped;
            if Ada.Real_Time.Clock >= Ready_Deadline then
               raise Program_Error with "replication bridge readiness timed out";
            end if;
            delay 0.020;
         end loop;
         Connect
           (Target_Socket, Target, Target_Port,
            "psqlbench/apply/" & Link);
         Connect
           (Downstream_Socket, Downstream, Positive (Item.Relay_Port),
            "psqlbench/downstream/" & Link,
            Protocol.Logical_Replication_Connection);
         Logical.Configure
           (Decoder, Protocol_Version (Item), Streaming_Mode (Item));
         Start_Logical_Copy
           (Downstream, Item, Slot, Start_LSN, Publication);
         Context.Links.Set_Status
           (Link, Psqlbench_Context.Link_Running,
            "Flyology " & Mode_Image (Item)
            & " client -> server -> client bridge is live");
         Emit
           (Context, Item, "bridge", "relay-to-target", "ready", Start_LSN);
         Flyology.Supervision.Mark_Ready (Control.all);

         while not Relay.Stopped loop
            if Flyology.Supervision.Stopping (Control.all).Requested then
               Relay.Stop;
               exit;
            end if;
            begin
               declare
                  Event : constant Client.Copy_Event :=
                    Client.Receive_Copy_Event (Downstream, Timeout => 0.5);
               begin
                  Raise_Server_Error (Event);
                  if Protocol.Response_Kind (Event) =
                    Protocol.Copy_Data_Response
                  then
                     declare
                        Frame : constant Replication.Stream_Message :=
                          Replication.Decode
                            (Protocol.Original_Message (Event));
                     begin
                        if Replication.Kind (Frame) = Replication.XLog_Data then
                           declare
                              Message : constant Logical.Message :=
                                Logical.Decode
                                  (Decoder, Replication.Data (Frame));
                              Changed : Boolean;
                           begin
                              Apply_Message
                                (Target, Item, Message, Relation,
                                 In_Transaction, Active_Stream, Changed);
                              Emit
                                (Context, Item, "apply", "relay-to-target",
                                 Logical.Message_Kind'Image
                                   (Logical.Kind (Message)),
                                 Replication.WAL_End (Frame),
                                 (if Message_Detail (Message)'Length > 0
                                  then (if Changed then "applied: " else "")
                                    & Message_Detail (Message)
                                  elsif Changed then "row applied"
                                  else "observed"));
                              if Changed then
                                 Context.Links.Record_Change
                                   (Link, Replication.WAL_End (Frame));
                              end if;
                              if Logical.Kind (Message) in
                                Logical.Commit_Message |
                                Logical.Stream_Commit_Message |
                                Logical.Prepare_Message |
                                Logical.Commit_Prepared_Message |
                                Logical.Rollback_Prepared_Message |
                                Logical.Stream_Prepare_Message
                              then
                                 declare
                                    Commit : constant Replication.LSN :=
                                      Logical.End_LSN (Message);
                                 begin
                                    Client.Send_Command
                                      (Downstream,
                                       Replication.Make_Standby_Status_Update
                                         (Commit, Commit, Commit, Sent_At => 0),
                                       Timeout => 10.0);
                                 end;
                              end if;
                           end;
                        elsif Replication.Kind (Frame) =
                          Replication.Primary_Keepalive
                          and then Replication.Reply_Requested (Frame)
                        then
                           declare
                              Ack : constant Replication.LSN :=
                                Relay.Acknowledged;
                           begin
                              Client.Send_Command
                                (Downstream,
                                 Replication.Make_Standby_Status_Update
                                   (Ack, Ack, Ack, Sent_At => 0),
                                 Timeout => 10.0);
                           end;
                        end if;
                     end;
                  end if;
               end;
            exception
               when Flyology.IO.Timeout_Error => null;
            end;
         end loop;

         Relay.Stop;
         Relay_Server.Request_Shutdown (Server);
         Context.Links.Set_Status
           (Link, Psqlbench_Context.Link_Stopped, "link stopped");
         if Flyology.Supervision.Stopping (Control.all).Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         else
            raise Program_Error with
              "replication bridge stopped without a shutdown request";
         end if;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Relay.Stop;
            Relay_Server.Request_Shutdown (Server);
            Context.Links.Set_Status
              (Link, Psqlbench_Context.Link_Stopped, "link stopped");
            raise;
         when Error : others =>
            Relay.Stop;
            Relay_Server.Request_Shutdown (Server);
            declare
               Failed : Boolean;
               Detail : String (1 .. 320);
               Last : Natural;
            begin
               Relay.Read_Failure (Failed, Detail, Last);
               Context.Links.Set_Status
                 (Link, Psqlbench_Context.Link_Failed,
                  (if Failed and Last > 0 then Detail (1 .. Last)
                   else Ada.Exceptions.Exception_Message (Error)));
            end;
            raise;
      end;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         raise;
      when Error : others =>
         Context.Links.Set_Status
           (Link_Name (Item), Psqlbench_Context.Link_Failed,
            Ada.Exceptions.Exception_Message (Error));
         raise;
   end Run_Logical_Link;

   procedure Receive_Native_Base_Backup
     (Context : in out Psqlbench_Context.Context;
      Item    : Psqlbench_Context.Link_Record;
      Source_Port : Positive;
      Major   : Base_Backups.Server_Major;
      Path    : String;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Socket : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : aliased Client.Session (Channel'Access);
      Receiver : Base_Backups.Receiver (Session'Access);
      Settings : Base_Backups.Options := Base_Backups.Defaults (Major);
      Archive : Ada.Streams.Stream_IO.File_Type;
      Archive_Open : Boolean := False;
      Archive_Count : Natural := 0;
      Bytes : Replication.UInt64 := 0;
      Last_Reported : Replication.UInt64 := 0;

      procedure Close_Archive is
      begin
         if Archive_Open then
            Ada.Streams.Stream_IO.Close (Archive);
            Archive_Open := False;
         end if;
      end Close_Archive;
   begin
      if Ada.Directories.Exists (Path) then
         Ada.Directories.Delete_File (Path);
      end if;
      Connect
        (Socket, Session, Source_Port,
         "psqlbench/native-base-backup/" & Link_Name (Item),
         Protocol.Physical_Replication_Connection);
      Base_Backups.Set_Label
        (Settings, "psqlbench native standby " & Target_Name (Item));
      Base_Backups.Set_Progress (Settings);
      Base_Backups.Set_Checkpoint
        (Settings, Base_Backups.Fast_Checkpoint);
      Base_Backups.Include_WAL (Settings);
      Base_Backups.Wait_For_Archive (Settings, False);
      Base_Backups.Start (Receiver, Settings, Timeout => 20.0);

      loop
         if Flyology.Supervision.Stopping (Control.all).Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         begin
            declare
               Event : constant Base_Backups.Event :=
                 Base_Backups.Receive (Receiver, Timeout => 1.0);
            begin
               case Base_Backups.Kind (Event) is
                  when Base_Backups.Backup_Start =>
                     Emit
                       (Context, Item, "bootstrap", "source-to-workbench",
                        "BASE_BACKUP_START",
                        Base_Backups.Start_LSN (Event),
                        "native protocol receiver");
                  when Base_Backups.Tablespace =>
                     if Base_Backups.Has_Tablespace_Location (Event) then
                        raise Program_Error with
                          "psqlbench native bootstrap does not yet map "
                          & "external tablespaces";
                     end if;
                  when Base_Backups.Archive_Start =>
                     Archive_Count := Archive_Count + 1;
                     if Archive_Count /= 1 then
                        raise Program_Error with
                          "psqlbench native bootstrap expected one base archive";
                     end if;
                     Ada.Streams.Stream_IO.Create
                       (Archive, Ada.Streams.Stream_IO.Out_File, Path);
                     Archive_Open := True;
                     Emit
                       (Context, Item, "bootstrap", "source-to-workbench",
                        "BASE_BACKUP_ARCHIVE",
                        Detail =>
                          (if Base_Backups.Archive_Name (Event)'Length = 0
                           then "base.tar"
                           else Base_Backups.Archive_Name (Event)));
                  when Base_Backups.Archive_Data =>
                     if not Archive_Open then
                        raise Program_Error with
                          "native base backup data preceded its archive";
                     end if;
                     declare
                        Data : constant Replication.Byte_Array :=
                          Base_Backups.Data (Event);
                     begin
                        Ada.Streams.Stream_IO.Write (Archive, Data);
                        Bytes := Bytes + Replication.UInt64 (Data'Length);
                     end;
                     if Bytes - Last_Reported >= 16 * 1_024 * 1_024 then
                        Emit
                          (Context, Item, "bootstrap",
                           "source-to-workbench", "BASE_BACKUP_PROGRESS",
                           Detail => Ada.Strings.Fixed.Trim
                             (Replication.UInt64'Image (Bytes),
                              Ada.Strings.Both) & " bytes");
                        Last_Reported := Bytes;
                     end if;
                  when Base_Backups.Backup_End =>
                     Close_Archive;
                     Emit
                       (Context, Item, "bootstrap", "source-to-workbench",
                        "BASE_BACKUP_END", Base_Backups.End_LSN (Event),
                        Ada.Strings.Fixed.Trim
                          (Replication.UInt64'Image (Bytes), Ada.Strings.Both)
                        & " bytes received");
                  when Base_Backups.Error =>
                     raise Program_Error with
                       "native base backup: "
                       & Protocol.Diagnostic_Message
                         (Base_Backups.Diagnostic (Event));
                  when Base_Backups.Complete =>
                     exit;
                  when Base_Backups.Manifest_Start |
                       Base_Backups.Manifest_Data |
                       Base_Backups.Progress |
                       Base_Backups.Notice |
                       Base_Backups.Parameter_Status =>
                     null;
               end case;
            end;
         exception
            when Flyology.IO.Timeout_Error => null;
         end;
      end loop;
      Close_Archive;
      if Archive_Count /= 1 or else Bytes = 0 then
         raise Program_Error with "native base backup returned no base archive";
      end if;
   exception
      when others =>
         Close_Archive;
         raise;
   end Receive_Native_Base_Backup;

   procedure Run_Physical_Link
     (Context : in out Psqlbench_Context.Context;
      Item    : Psqlbench_Context.Link_Record;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Source_Port : constant Positive := Instance_Port (Source_Name (Item));
      Link : constant String := Link_Name (Item);
      Slot : constant String := Slot_Name (Item);
      Target : constant String := Target_Name (Item);
      Relay : aliased Relay_State;
      Listener : Sockets.Socket_Type;
      Server : aliased Relay_Server.Server (Capacity => 2);
      Server_Context : aliased Relay_Context :=
        (Relay => Relay'Unrestricted_Access,
         Root  => Context'Unrestricted_Access,
         Link  => Item,
         others => <>);
      Bootstrap_Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (180);
      Version_Text : constant String := Target_Version (Item);
      Version_Dot : constant Natural :=
        Ada.Strings.Fixed.Index (Version_Text, ".");
      Major : constant Base_Backups.Server_Major :=
        Base_Backups.Server_Major'Value
          (Version_Text
             (Version_Text'First ..
                (if Version_Dot = 0
                 then Version_Text'Last else Version_Dot - 1)));
      Archive_Path : constant String :=
        "/tmp/psqlbench-" & Target & "-base.tar";

      procedure Delete_Archive is
      begin
         if Ada.Directories.Exists (Archive_Path) then
            Ada.Directories.Delete_File (Archive_Path);
         end if;
      exception
         when others => null;
      end Delete_Archive;

      procedure Setup is
         Source_Socket : aliased Sockets.Socket_Type;
         Source_Channel : aliased Transports.Socket_Transport
           (Source_Socket'Access);
         Source : Client.Session (Source_Channel'Access);
         Position : Unbounded_String;
         Has_Row : Boolean;
         Existing_Target : Psqlbench_Docker.Result;
      begin
         Connect
           (Source_Socket, Source, Source_Port,
            "psqlbench/physical-setup/" & Link);
         Client.Send_Query
           (Source,
            "SELECT restart_lsn::text FROM pg_replication_slots "
            & "WHERE slot_name=" & Quote_Literal (Slot)
            & " AND slot_type='physical'",
            Timeout => 20.0);
         Consume_Query (Source, Position, Has_Row);
         if not Has_Row then
            declare
               Created : constant String := Scalar_SQL
                 (Source,
                  "SELECT COALESCE(lsn,pg_current_wal_lsn())::text "
                  & "FROM pg_create_physical_replication_slot("
                  & Quote_Literal (Slot) & ",true)");
            begin
               Position := To_Unbounded_String (Created);
            end;
         end if;
         Emit
           (Context, Item, "setup", "source", "physical-slot-ready",
            (if Length (Position) = 0 then 0
             else Replication.Value (To_String (Position))),
            Slot);

         Existing_Target := Psqlbench_Docker.Inspect_Instance (Target);
         if not Existing_Target.Success then
            declare
               Access_Result : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Enable_Replication_Access
                   (Source_Name (Item), Deadline => Bootstrap_Deadline);
            begin
               if not Access_Result.Success then
                  raise Program_Error with
                    "source replication access: "
                    & Psqlbench_Docker.Text (Access_Result);
               end if;
            end;
            Context.Links.Set_Status
              (Link, Psqlbench_Context.Link_Starting,
               "streaming a native BASE_BACKUP before live WAL starts");
            begin
               Receive_Native_Base_Backup
                 (Context, Item, Source_Port, Major, Archive_Path, Control);
               declare
                  Result : constant Psqlbench_Docker.Result :=
                    Psqlbench_Docker.Bootstrap_Physical_Standby
                      (Name         => Target,
                       Version      => Target_Version (Item),
                       Port         => Positive (Item.Target_Port),
                       Slot         => Slot,
                       Relay_Port   => Positive (Item.Relay_Port),
                       Archive_Path => Archive_Path,
                       Deadline     => Bootstrap_Deadline);
               begin
                  if not Result.Success then
                     raise Program_Error with
                       "standby bootstrap: " & Psqlbench_Docker.Text (Result);
                  end if;
               end;
               Delete_Archive;
            exception
               when others =>
                  Delete_Archive;
                  raise;
            end;
            Emit
              (Context, Item, "bootstrap", "source-to-target",
               "base-backup-complete",
               Detail => "native Flyology BASE_BACKUP receiver");
         else
            Emit
              (Context, Item, "bootstrap", "target", "standby-reused");
         end if;

         Server_Context.System_Id := Replication.UInt64'Value
           (Scalar_SQL
              (Source,
               "SELECT system_identifier::text FROM pg_control_system()"));
         Server_Context.Timeline := Replication.UInt32'Value
           (Scalar_SQL
              (Source,
               "SELECT timeline_id::text FROM pg_control_checkpoint()"));
         Server_Context.Current_WAL := Replication.Value
           (Scalar_SQL (Source, "SELECT pg_current_wal_lsn()::text"));
         Relay.Observe_WAL (Server_Context.Current_WAL);
      end Setup;
   begin
      Context.Links.Set_Status
        (Link, Psqlbench_Context.Link_Starting,
         "reserving a physical slot and preparing the standby");
      Setup;

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener,
         Sockets.Network_Endpoint
           (Sockets.Any_IPv4, Sockets.Port (Item.Relay_Port)));
      Sockets.Listen_Socket (Listener, Length => 2);

      declare
         task Relay_Server_Task is
            pragma Task_Info (Flyology.Native_Task);
         end Relay_Server_Task;

         task body Relay_Server_Task is
         begin
            Relay.Set_Server_Ready;
            Relay_Server.Serve
              (Server, Listener, Server_Context, Drain_Timeout => 1.0);
         exception
            when Error : others =>
               Relay.Fail
                 ("physical relay server: "
                  & Ada.Exceptions.Exception_Message (Error));
         end Relay_Server_Task;

         task Upstream_Task is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Upstream_Task;

         task body Upstream_Task is
            Socket : aliased Sockets.Socket_Type;
            Channel : aliased Transports.Socket_Transport (Socket'Access);
            Session : Client.Session (Channel'Access);
            Last_Ack : Replication.LSN := 0;
            Last_Feedback : Ada.Real_Time.Time := Ada.Real_Time.Clock;
            Start : Replication.LSN;
         begin
            while not Relay.Start_Requested and then not Relay.Stopped loop
               delay 0.020;
            end loop;
            if Relay.Stopped then
               raise Flyology.Cancellation.Operation_Cancelled;
            end if;
            Start := Relay.Requested_Start;
            Context.Links.Record_Start (Link, Start);
            Connect
              (Socket, Session, Source_Port,
               "psqlbench/physical-upstream/" & Link,
               Protocol.Physical_Replication_Connection);
            Start_Copy
              (Session, Replication.Start_Physical (Start, Slot));
            Relay.Set_Upstream_Ready;
            Emit
              (Context, Item, "upstream", "source-to-relay", "copy-both",
               Start);

            while not Relay.Stopped loop
               begin
                  declare
                     Event : constant Client.Copy_Event :=
                       Client.Receive_Copy_Event (Session, Timeout => 0.5);
                  begin
                     Raise_Server_Error (Event);
                     if Protocol.Response_Kind (Event) =
                       Protocol.Copy_Data_Response
                     then
                        declare
                           Frame : constant Replication.Stream_Message :=
                             Replication.Decode
                               (Protocol.Original_Message (Event));
                        begin
                           if Replication.Kind (Frame) = Replication.XLog_Data then
                              declare
                                 Data : constant Replication.Byte_Array :=
                                   Replication.Data (Frame);
                                 Forward : constant Relay_Frame :=
                                   (WAL_Start => Replication.WAL_Start (Frame),
                                    WAL_End   => Replication.WAL_End (Frame),
                                    Sent_At   => Replication.Sent_At (Frame),
                                    Data      =>
                                      Flyology.Bytes.To_Unbounded_Bytes (Data));
                                 Accepted : Boolean;
                              begin
                                 Relay.Push (Forward, Accepted);
                                 exit when not Accepted;
                                 Relay.Observe_WAL
                                   (Replication.WAL_End (Frame));
                                 Context.Links.Record_Change
                                   (Link, Replication.WAL_End (Frame));
                                 Emit
                                   (Context, Item, "proxy", "source-to-standby",
                                    "XLOG_DATA", Replication.WAL_End (Frame),
                                    Compact (Data'Length) & " WAL bytes");
                              end;
                           end if;
                           if Replication.Kind (Frame) =
                             Replication.Primary_Keepalive
                           then
                              Relay.Observe_WAL
                                (Replication.WAL_End (Frame));
                              Emit
                                (Context, Item, "upstream",
                                 "source-to-relay", "PRIMARY_KEEPALIVE",
                                 Replication.WAL_End (Frame),
                                 (if Replication.Reply_Requested (Frame)
                                  then "reply requested" else "observed"));
                           end if;
                        end;
                     end if;
                  end;
               exception
                  when Flyology.IO.Timeout_Error => null;
               end;

               if Relay.Acknowledged > Last_Ack
                 or else Ada.Real_Time.Clock - Last_Feedback >=
                   Ada.Real_Time.Seconds (1)
               then
                  if Relay.Acknowledged > Last_Ack then
                     Last_Ack := Relay.Acknowledged;
                     Emit
                       (Context, Item, "ack", "relay-to-source",
                        "STANDBY_STATUS_UPDATE", Last_Ack,
                        "standby apply acknowledged upstream");
                  end if;
                  Client.Send_Command
                    (Session,
                     Replication.Make_Standby_Status_Update
                       (Last_Ack, Last_Ack, Last_Ack, Sent_At => 0),
                     Timeout => 10.0);
                  Last_Feedback := Ada.Real_Time.Clock;
               end if;
            end loop;
         exception
            when Flyology.Cancellation.Operation_Cancelled =>
               null;
            when Error : others =>
               Relay.Fail
                 ("physical upstream client: "
                  & Ada.Exceptions.Exception_Message (Error));
         end Upstream_Task;

         Ready_Deadline : constant Ada.Real_Time.Time :=
           Ada.Real_Time.Clock + Ada.Real_Time.Seconds (60);
      begin
         while not Relay.Server_Ready loop
            exit when Relay.Stopped;
            if Ada.Real_Time.Clock >= Ready_Deadline then
               raise Program_Error with "physical relay readiness timed out";
            end if;
            delay 0.020;
         end loop;

         declare
            Started : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Apply
                (Target, Psqlbench_Docker.Start_Instance,
                 Deadline => Ready_Deadline);
         begin
            if not Started.Success then
               raise Program_Error with
                 "standby start: " & Psqlbench_Docker.Text (Started);
            end if;
         end;

         while not Relay.Upstream_Ready loop
            exit when Relay.Stopped;
            if Ada.Real_Time.Clock >= Ready_Deadline then
               raise Program_Error with
                 "standby did not request WAL through the relay";
            end if;
            delay 0.050;
         end loop;
         if Relay.Stopped then
            raise Program_Error with "physical relay stopped during startup";
         end if;

         Context.Links.Set_Status
           (Link, Psqlbench_Context.Link_Running,
            "Flyology physical client -> server -> Postgres walreceiver is live");
         Emit
           (Context, Item, "bridge", "relay-to-standby", "recovery-streaming",
            Relay.Requested_Start);
         Flyology.Supervision.Mark_Ready (Control.all);

         while not Relay.Stopped loop
            if Flyology.Supervision.Stopping (Control.all).Requested then
               Relay.Stop;
               exit;
            end if;
            delay 0.100;
         end loop;

         declare
            Ignored : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Apply
                (Target, Psqlbench_Docker.Stop_Instance,
                 Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (20));
            pragma Unreferenced (Ignored);
         begin
            null;
         end;
         Relay.Stop;
         Relay_Server.Request_Shutdown (Server);
         Context.Links.Set_Status
           (Link, Psqlbench_Context.Link_Stopped, "physical link stopped");
         if Flyology.Supervision.Stopping (Control.all).Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         else
            raise Program_Error with
              "physical bridge stopped without a shutdown request";
         end if;
      exception
         when Flyology.Cancellation.Operation_Cancelled =>
            Relay.Stop;
            Relay_Server.Request_Shutdown (Server);
            Context.Links.Set_Status
              (Link, Psqlbench_Context.Link_Stopped, "physical link stopped");
            raise;
         when Error : others =>
            Relay.Stop;
            Relay_Server.Request_Shutdown (Server);
            declare
               Ignored : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Apply
                   (Target, Psqlbench_Docker.Stop_Instance,
                    Deadline => Ada.Real_Time.Clock + Ada.Real_Time.Seconds (20));
               Failed : Boolean;
               Detail : String (1 .. 320);
               Last : Natural;
               pragma Unreferenced (Ignored);
            begin
               Relay.Read_Failure (Failed, Detail, Last);
               Context.Links.Set_Status
                 (Link, Psqlbench_Context.Link_Failed,
                  (if Failed and Last > 0 then Detail (1 .. Last)
                   else Ada.Exceptions.Exception_Message (Error)));
            end;
            raise;
      end;
   exception
      when Flyology.Cancellation.Operation_Cancelled =>
         raise;
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "physical link " & Link & " failed: "
            & Ada.Exceptions.Exception_Information (Error));
         Context.Links.Set_Status
           (Link, Psqlbench_Context.Link_Failed,
            Ada.Exceptions.Exception_Message (Error));
         raise;
   end Run_Physical_Link;

   procedure Run_Link
     (Context : in out Psqlbench_Context.Context;
      Item    : Psqlbench_Context.Link_Record;
      Control : not null access Flyology.Supervision.Generation_Control) is
   begin
      if Item.Mode = Psqlbench_Context.Physical_Streaming then
         Run_Physical_Link (Context, Item, Control);
      else
         Run_Logical_Link (Context, Item, Control);
      end if;
   end Run_Link;

   type Family_Context is limited record
      Root : access Psqlbench_Context.Context;
   end record;

   procedure Run_Link_Child
     (State   : in out Family_Context;
      Item    : Psqlbench_Context.Link_Record;
      Control : not null access Flyology.Supervision.Generation_Control) is
   begin
      Run_Link (State.Root.all, Item, Control);
   end Run_Link_Child;

   package Link_Children is new Flyology.Supervision.Input_Children
     (Input_Type          => Psqlbench_Context.Link_Record,
      Application_Context => Family_Context,
      Execute             => Run_Link_Child,
      Task_Model          => Flyology.Native_Task);

   function Link_Policy return Flyology.Supervision.Child_Specification is
      Value : Flyology.Supervision.Child_Specification := (others => <>);
   begin
      Value.Restart := Flyology.Supervision.On_Failure;
      Value.Impact := Flyology.Supervision.Isolate_Child;
      Value.Stopping :=
        (Grace             => Ada.Real_Time.Seconds (25),
         Request_Abort     => False,
         Abort_Observation => Ada.Real_Time.Seconds (1));
      Value.Readiness_Timeout := Ada.Real_Time.Seconds (240);
      Value.Restart_Safe := True;
      Value.Task_Model := Flyology.Native_Task;
      return Value;
   end Link_Policy;

   package Link_Families is new Flyology.Supervision.Families
      (Request             => Psqlbench_Context.Link_Record,
      Application_Context => Family_Context,
      Run_One_Generation  => Link_Children.Run,
      Policy              => Link_Policy,
      First_Child_Id      => 100,
      Maximum_Children    => Psqlbench_Context.Max_Links);

   procedure Execute
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Family : aliased Link_Families.Family;
      Family_State : aliased Family_Context :=
        (Root => Context'Unrestricted_Access);
      Result : Flyology.Supervision.Supervisor_Result;
      type Handle_Entry is record
         Occupied : Boolean := False;
         Name_Length : Natural range 0 .. Psqlbench_Context.Max_Link_Name_Bytes
           := 0;
         Name : String (1 .. Psqlbench_Context.Max_Link_Name_Bytes) :=
           (others => ' ');
         Handle : Flyology.Supervision.Child_Handle;
      end record;
      type Handle_Array is array (1 .. Psqlbench_Context.Max_Links) of
        Handle_Entry;
      Handles : Handle_Array;

      function Matches (Item : Handle_Entry; Name : String) return Boolean is
        (Item.Occupied and then Item.Name_Length = Name'Length
         and then Item.Name (1 .. Item.Name_Length) = Name);

      procedure Remember
        (Name : String; Handle : Flyology.Supervision.Child_Handle) is
      begin
         for Item of Handles loop
            if not Item.Occupied then
               Item.Occupied := True;
               Item.Name_Length := Name'Length;
               Item.Name (1 .. Name'Length) := Name;
               Item.Handle := Handle;
               return;
            end if;
         end loop;
         raise Program_Error with "link handle directory is full";
      end Remember;

      task Runner is
         pragma Task_Info (Flyology.Native_Task);
      end Runner;

      task body Runner is
      begin
         Link_Families.Run_Nested
           (Family, Family_State, Control.all, Result);
      end Runner;
   begin
      while not Link_Families.Accepting (Family) loop
         if Flyology.Supervision.Stopping (Control.all).Requested then
            Link_Families.Request_Shutdown (Family);
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.020;
      end loop;
      Flyology.Supervision.Mark_Ready (Control.all);

      loop
         if Flyology.Supervision.Stopping (Control.all).Requested then
            Link_Families.Request_Shutdown (Family);
            exit;
         end if;
         declare
            Command : Psqlbench_Context.Link_Command;
            Available : Boolean;
         begin
            Context.Links.Take_Command (Command, Available);
            if Available then
               declare
                  Name : constant String :=
                    Text (Command.Name, Command.Name_Length);
               begin
                  case Command.Kind is
                     when Psqlbench_Context.Create_Link =>
                        declare
                           Links : Psqlbench_Context.Link_Array;
                           Count : Natural;
                           Found : Boolean := False;
                        begin
                           Context.Links.Snapshot (Links, Count);
                           for Index in 1 .. Count loop
                              if Link_Name (Links (Index)) = Name then
                                 declare
                                    Handle : Flyology.Supervision.Child_Handle;
                                 begin
                                    Link_Families.Start
                                      (Family, Links (Index), Handle);
                                    Remember (Name, Handle);
                                    Context.Links.Set_Status
                                      (Name, Psqlbench_Context.Link_Starting,
                                       "supervised link child admitted");
                                    Found := True;
                                 end;
                                 exit;
                              end if;
                           end loop;
                           if not Found then
                              Context.Links.Set_Status
                                (Name, Psqlbench_Context.Link_Failed,
                                 "link request disappeared before admission");
                           end if;
                        end;

                     when Psqlbench_Context.Stop_Link |
                          Psqlbench_Context.Remove_Link =>
                        for Item of Handles loop
                           if Matches (Item, Name) then
                              begin
                                 Link_Families.Stop (Family, Item.Handle);
                              exception
                                 when Link_Families.Stale_Handle => null;
                              end;
                              Item.Occupied := False;
                              exit;
                           end if;
                        end loop;
                        if Command.Kind = Psqlbench_Context.Remove_Link then
                           Context.Links.Forget (Name);
                        else
                           Context.Links.Set_Status
                             (Name, Psqlbench_Context.Link_Stopped,
                              "link stopped");
                        end if;
                  end case;
               end;
            else
               delay 0.050;
            end if;
         end;
      end loop;
   end Execute;

end Psqlbench_Links;
