with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology;
with Flyology.Bytes;
with Flyology.Cancellation;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
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

   function Table_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Text (Item.Table_Name, Item.Table_Length));

   function Slot_Name (Item : Psqlbench_Context.Link_Record) return String is
     (Table_Name (Item));

   function Publication_Name
     (Item : Psqlbench_Context.Link_Record) return String is
     (Table_Name (Item) & "_pub");

   function Protocol_Version
     (Item : Psqlbench_Context.Link_Record)
      return Logical.Protocol_Version is
     (if Item.Mode = Psqlbench_Context.Logical_Streaming then 2 else 1);

   function Streaming_Mode
     (Item : Psqlbench_Context.Link_Record)
      return Logical.Streaming_Mode is
     (if Item.Mode = Psqlbench_Context.Logical_Streaming
      then Logical.In_Progress else Logical.Disabled);

   function Mode_Image (Item : Psqlbench_Context.Link_Record) return String is
     (case Item.Mode is
         when Psqlbench_Context.Logical_Committed => "logical committed",
         when Psqlbench_Context.Logical_Streaming => "logical streaming");

   function Message_Detail (Item : Logical.Message) return String is
   begin
      case Logical.Kind (Item) is
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
   end Relay_State;

   type Relay_Context is limited record
      Relay : access Relay_State;
      Root  : access Psqlbench_Context.Context;
      Link  : Psqlbench_Context.Link_Record;
   end record;

   function Authenticate
     (State    : in out Relay_Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (State, Password);
   begin
      return Startup.Replication_Mode =
        Protocol.Logical_Replication_Connection;
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
      Command : constant Replication.Command :=
        Replication.Decode_Command (Message);
      Last_Keepalive : Ada.Real_Time.Time := Ada.Real_Time.Clock;
   begin
      if Protocol.Kind (Message) /= Protocol.Query
        or else Replication.Kind (Command) /=
          Replication.Start_Logical_Command
      then
         Server_Sessions.Send_Error
           (Client, "psqlbench relay only accepts logical START_REPLICATION",
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
                  WAL_End => State.Relay.Acknowledged,
                  Sent_At => 0,
                  Reply_Requested => True,
                  Timeout => 10.0);
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
                  end if;
               end;
            exception
               when Flyology.IO.Timeout_Error => null;
            end;
         end;
      end loop;
   end Handle_Relay;

   package Relay_Server is new Flyology.Postgres.Server
     (Handler_Context       => Relay_Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle_Relay,
      Authentication        => Flyology.Postgres.Trust,
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
         raise Program_Error with "logical stream did not enter COPY BOTH";
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

   procedure Apply_Message
     (Session : in out Client.Session;
      Item    : Psqlbench_Context.Link_Record;
      Message : Logical.Message;
      Relation_Oid : in out Logical.UInt32;
      In_Transaction : in out Boolean;
      Applied : out Boolean)
   is
      Table : constant String := "public.""" & Table_Name (Item) & """";

      function Tuple_Value
        (Tuple : Logical.Tuple_Data; Index : Positive) return String is
        (Tuple_SQL (Logical.Column (Tuple, Index)));

      function Old_Id return String is
         Old : constant Logical.Tuple_Data := Logical.Old_Tuple (Message);
      begin
         return Tuple_Value (Old, 1);
      end Old_Id;
   begin
      Applied := False;
      case Logical.Kind (Message) is
         when Logical.Begin_Message =>
            Run_SQL (Session, "BEGIN");
            In_Transaction := True;

         when Logical.Relation_Message =>
            if Logical.Namespace_Name (Message) = "public"
              and then Logical.Object_Name (Message) = Table_Name (Item)
            then
               if Logical.Relation_Column_Count (Message) /= 3
                 or else Logical.Name
                   (Logical.Relation_Column_At (Message, 1)) /= "id"
                 or else Logical.Name
                   (Logical.Relation_Column_At (Message, 2)) /= "payload"
                 or else Logical.Name
                   (Logical.Relation_Column_At (Message, 3)) /= "changed_at"
               then
                  raise Program_Error with
                    "managed demo table schema changed while linking";
               end if;
               Relation_Oid := Logical.Relation_Id (Message);
            end if;

         when Logical.Insert_Message =>
            if Logical.Relation_Id (Message) = Relation_Oid then
               declare
                  New_Row : constant Logical.Tuple_Data :=
                    Logical.New_Tuple (Message);
               begin
                  Run_SQL
                    (Session,
                     "INSERT INTO " & Table
                     & " (id, payload, changed_at) VALUES ("
                     & Tuple_Value (New_Row, 1) & ","
                     & Tuple_Value (New_Row, 2) & ","
                     & Tuple_Value (New_Row, 3) & ") "
                     & "ON CONFLICT (id) DO UPDATE SET payload=EXCLUDED.payload,"
                     & " changed_at=EXCLUDED.changed_at");
                  Applied := True;
               end;
            end if;

         when Logical.Update_Message =>
            if Logical.Relation_Id (Message) = Relation_Oid then
               declare
                  New_Row : constant Logical.Tuple_Data :=
                    Logical.New_Tuple (Message);
                  Payload : constant Logical.Tuple_Value :=
                    Logical.Column (New_Row, 2);
                  SQL : Unbounded_String := To_Unbounded_String
                    ("UPDATE " & Table & " SET id="
                     & Tuple_Value (New_Row, 1));
               begin
                  if Logical.Kind (Payload) /=
                    Logical.Unchanged_Toast_Value
                  then
                     Append (SQL, ", payload=" & Tuple_SQL (Payload));
                  end if;
                  Append
                    (SQL, ", changed_at=" & Tuple_Value (New_Row, 3)
                     & " WHERE id IS NOT DISTINCT FROM "
                     & (if Logical.Old_Kind (Message) =
                          Logical.No_Old_Tuple
                        then Tuple_Value (New_Row, 1)
                        else Old_Id));
                  Run_SQL (Session, To_String (SQL));
                  Applied := True;
               end;
            end if;

         when Logical.Delete_Message =>
            if Logical.Relation_Id (Message) = Relation_Oid then
               Run_SQL
                 (Session, "DELETE FROM " & Table
                  & " WHERE id IS NOT DISTINCT FROM " & Old_Id);
               Applied := True;
            end if;

         when Logical.Truncate_Message =>
            for Index in 1 .. Logical.Truncated_Relation_Count (Message) loop
               if Logical.Truncated_Relation (Message, Index) = Relation_Oid then
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
            if Logical.Is_First_Stream_Segment (Message)
              and then not In_Transaction
            then
               Run_SQL (Session, "BEGIN");
               In_Transaction := True;
            end if;

         when Logical.Stream_Stop_Message =>
            null;

         when Logical.Stream_Commit_Message =>
            if In_Transaction then
               Run_SQL (Session, "COMMIT");
               In_Transaction := False;
            end if;

         when Logical.Stream_Abort_Message =>
            if In_Transaction then
               Run_SQL (Session, "ROLLBACK");
               In_Transaction := False;
            end if;

         when others =>
            null;
      end case;
   end Apply_Message;

   procedure Run_Link
     (Context : in out Psqlbench_Context.Context;
      Item    : Psqlbench_Context.Link_Record;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      Source_Port : constant Positive := Instance_Port (Source_Name (Item));
      Target_Port : constant Positive := Instance_Port (Target_Name (Item));
      Link : constant String := Link_Name (Item);
      Table : constant String := Table_Name (Item);
      Publication : constant String := Publication_Name (Item);
      Slot : constant String := Slot_Name (Item);
      Start_LSN : Replication.LSN := 0;
      Relay : aliased Relay_State;
      Listener : Sockets.Socket_Type;
      Server : aliased Relay_Server.Server (Capacity => 2);
      Server_Context : aliased Relay_Context :=
        (Relay => Relay'Unrestricted_Access,
         Root  => Context'Unrestricted_Access,
         Link  => Item);

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
         Schema_SQL : constant String :=
           "CREATE TABLE IF NOT EXISTS public.""" & Table & """ ("
           & "id bigint PRIMARY KEY, payload text NOT NULL, "
           & "changed_at timestamptz NOT NULL DEFAULT clock_timestamp())";
      begin
         Connect
           (Source_Socket, Source, Source_Port,
            "psqlbench/link-setup/source/" & Link);
         Connect
           (Target_Socket, Target, Target_Port,
            "psqlbench/link-setup/target/" & Link);
         Run_SQL (Source, Schema_SQL);
         Run_SQL (Target, Schema_SQL);
         if Item.Mode = Psqlbench_Context.Logical_Streaming then
            Run_SQL
              (Source,
               "ALTER ROLE psqlbench IN DATABASE postgres SET "
               & "logical_decoding_work_mem='64kB'");
         end if;
         Client.Send_Query
           (Source,
            "SELECT 1 FROM pg_publication WHERE pubname="
            & Quote_Literal (Publication), Timeout => 20.0);
         Consume_Query (Source, Existing, Has_Row);
         if not Has_Row then
            Run_SQL
              (Source, "CREATE PUBLICATION """ & Publication
               & """ FOR TABLE public.""" & Table & """");
         end if;
         declare
            Position : constant String := Scalar_SQL
              (Source,
               "SELECT COALESCE(confirmed_flush_lsn,restart_lsn)::text "
               & "FROM pg_replication_slots WHERE slot_name="
               & Quote_Literal (Slot));
            Created : constant String :=
              (if Position'Length > 0 then Position
               else Scalar_SQL
                 (Source,
                  "SELECT lsn::text FROM pg_create_logical_replication_slot("
                  & Quote_Literal (Slot) & ",'pgoutput')"));
         begin
            Start_LSN := Replication.Value (Created);
         end;
         Emit
           (Context, Item, "setup", "source", "slot-ready",
            Start_LSN, Table);
      end Setup;
   begin
      Context.Links.Set_Status (Link, Psqlbench_Context.Link_Starting,
                                "preparing publication and logical slot");
      Setup;

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
            if Item.Mode = Psqlbench_Context.Logical_Streaming then
               Start_Copy
                 (Session,
                  Replication.Start_Logical
                    (Slot, Start_LSN,
                     (Replication.Option ("proto_version", "2"),
                      Replication.Option
                        ("publication_names", Publication),
                      Replication.Option ("streaming", "on"),
                      Replication.Option ("messages", "true"))));
            else
               Start_Copy
                 (Session,
                  Replication.Start_Logical
                    (Slot, Start_LSN,
                     (Replication.Option ("proto_version", "1"),
                      Replication.Option
                        ("publication_names", Publication),
                      Replication.Option ("messages", "true"))));
            end if;
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
                                 exit when not Accepted;
                              end;
                           elsif Replication.Kind (Frame) =
                             Replication.Primary_Keepalive
                           then
                              null;
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
         Relation_Oid : Logical.UInt32 := 0;
         In_Transaction : Boolean := False;
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
         if Item.Mode = Psqlbench_Context.Logical_Streaming then
            Start_Copy
              (Downstream,
               Replication.Start_Logical
                 (Slot, Start_LSN,
                  (Replication.Option ("proto_version", "2"),
                   Replication.Option ("publication_names", Publication),
                   Replication.Option ("streaming", "on"),
                   Replication.Option ("messages", "true"))));
         else
            Start_Copy
              (Downstream,
               Replication.Start_Logical
                 (Slot, Start_LSN,
                  (Replication.Option ("proto_version", "1"),
                   Replication.Option ("publication_names", Publication),
                   Replication.Option ("messages", "true"))));
         end if;
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
                                (Target, Item, Message, Relation_Oid,
                                 In_Transaction, Changed);
                              Emit
                                (Context, Item, "apply", "relay-to-target",
                                 Logical.Message_Kind'Image
                                   (Logical.Kind (Message)),
                                 Replication.WAL_End (Frame),
                                 (if Changed then "row applied"
                                  elsif Message_Detail (Message)'Length > 0
                                  then Message_Detail (Message)
                                  else "observed"));
                              if Changed then
                                 Context.Links.Record_Change
                                   (Link, Replication.WAL_End (Frame));
                              end if;
                              if Logical.Kind (Message) in
                                Logical.Commit_Message |
                                Logical.Stream_Commit_Message
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
        (Grace             => Ada.Real_Time.Seconds (3),
         Request_Abort     => False,
         Abort_Observation => Ada.Real_Time.Seconds (1));
      Value.Readiness_Timeout := Ada.Real_Time.Seconds (30);
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
