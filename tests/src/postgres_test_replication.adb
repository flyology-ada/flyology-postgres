with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Transports.TLS_Sockets;

procedure Postgres_Test_Replication is

   package Client renames Flyology.Postgres.Client;
   package Logical renames Flyology.Postgres.Replication.Logical;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Sockets renames Flyology.IO.Sockets;
   package Unbounded renames Ada.Strings.Unbounded;
   package Transports renames
     Flyology.Postgres.Transports.TLS_Sockets;

   use type Client.Operation_State;
   use type Logical.LSN;
   use type Logical.Message_Kind;
   use type Logical.Old_Tuple_Kind;
   use type Logical.Streaming_Mode;
   use type Logical.Tuple_Value_Kind;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.UInt32;
   use type Replication.Stream_Message_Kind;

   protected Result is
      procedure Pass;
      procedure Fail;
      entry Await (Succeeded : out Boolean);
   private
      Done : Boolean := False;
      Good : Boolean := False;
   end Result;

   protected body Result is
      procedure Pass is
      begin
         Done := True;
         Good := True;
      end Pass;

      procedure Fail is
      begin
         Done := True;
         Good := False;
      end Fail;

      entry Await (Succeeded : out Boolean) when Done is
      begin
         Succeeded := Good;
      end Await;
   end Result;

   function Environment (Name : String; Default : String := "")
      return String is
     (Ada.Environment_Variables.Value (Name, Default));

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Environment ("POSTGRES_REPLICATION_PORT", "55434")));

   procedure Require (Condition : Boolean; Information : String) is
   begin
      if not Condition then
         raise Program_Error with Information;
      end if;
   end Require;

   function Byte_Text (Data : Protocol.Byte_Array) return String is
     (Flyology.Bytes.To_Byte_String
        (Flyology.Bytes.To_Unbounded_Bytes (Data)));

   task Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
      Backend : OpenSSL.OpenSSL_Provider;
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);

      Scenario : constant String :=
        Environment ("POSTGRES_REPLICATION_SCENARIO");
      Server_Major : constant String :=
        Environment ("POSTGRES_SERVER_MAJOR");
      Server : constant Sockets.Endpoint :=
        Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port);

      procedure Raise_Server_Error (Event : Protocol.Backend_Message) is
      begin
         if Protocol.Response_Kind (Event) = Protocol.Error_Response then
            raise Program_Error with
              Protocol.Diagnostic_SQL_State
                (Protocol.Diagnostic_Data (Event))
              & ": "
              & Protocol.Diagnostic_Message
                (Protocol.Diagnostic_Data (Event));
         end if;
      end Raise_Server_Error;

      procedure Finish_Stream is
      begin
         Client.Finish_Copy (Session, Timeout => 10.0);
         while not Client.Is_Ready (Session) loop
            if Client.State (Session) = Client.Simple_Query_Active then
               declare
                  Event : constant Client.Simple_Query_Event :=
                    Client.Receive_Query_Event
                      (Session, Timeout => 10.0);
               begin
                  Raise_Server_Error (Event);
               end;
            else
               declare
                  Event : constant Client.Copy_Event :=
                    Client.Receive_Copy_Event (Session, Timeout => 10.0);
               begin
                  Raise_Server_Error (Event);
               end;
            end if;
         end loop;
      end Finish_Stream;

      procedure Check_Identify_System is
         Saw_Description : Boolean := False;
         Saw_Row         : Boolean := False;
      begin
         Client.Send_Command
           (Session, Replication.Identify_System, Timeout => 10.0);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 10.0);
            begin
               Raise_Server_Error (Event);
               case Protocol.Response_Kind (Event) is
                  when Protocol.Row_Description_Response =>
                     Saw_Description :=
                       Protocol.Field_Count
                         (Protocol.Description (Event)) = 4;
                  when Protocol.Data_Row_Response =>
                     declare
                        Row : constant Protocol.Data_Row :=
                          Protocol.Row_Data (Event);
                     begin
                        Saw_Row :=
                          Protocol.Column_Count (Row) = 4
                          and then not Protocol.Is_Null
                            (Protocol.Column_At (Row, 1))
                          and then not Protocol.Is_Null
                            (Protocol.Column_At (Row, 3));
                     end;
                  when Protocol.Ready_For_Query_Response =>
                     exit;
                  when others =>
                     null;
               end case;
            end;
         end loop;
         Require
           (Saw_Description and then Saw_Row,
            "IDENTIFY_SYSTEM did not return its real four-column result");
      end Check_Identify_System;

      procedure Check_Logical_Server is
         Saw_Logical : Boolean := False;
      begin
         Client.Send_Command
           (Session, Replication.Show ("wal_level"), Timeout => 10.0);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 10.0);
            begin
               Raise_Server_Error (Event);
               if Protocol.Response_Kind (Event) =
                 Protocol.Data_Row_Response
               then
                  declare
                     Row : constant Protocol.Data_Row :=
                       Protocol.Row_Data (Event);
                  begin
                     Saw_Logical :=
                       Protocol.Column_Count (Row) = 1
                       and then Protocol.Column_Text
                         (Protocol.Column_At (Row, 1)) = "logical";
                  end;
               elsif Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response
               then
                  exit;
               end if;
            end;
         end loop;
         Require (Saw_Logical, "real server wal_level is not logical");
      end Check_Logical_Server;

      procedure Start_Copy (Command : Protocol.Message) is
      begin
         Client.Send_Command (Session, Command, Timeout => 10.0);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 10.0);
            begin
               Raise_Server_Error (Event);
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Copy_Both_Response;
            end;
         end loop;
         Require
           (Client.State (Session) = Client.Copy_Both_Active,
            "START_REPLICATION did not enter COPY BOTH");
      end Start_Copy;

      procedure Test_Physical is
         Start : constant Replication.LSN := Replication.Value
           (Environment ("POSTGRES_REPLICATION_START_LSN"));
         Saw_WAL       : Boolean := False;
         Saw_Keepalive : Boolean := False;
         Sent_Feedback : Boolean := False;
      begin
         Check_Identify_System;
         Start_Copy (Replication.Start_Physical (Start));

         while not (Saw_WAL and Saw_Keepalive) loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 15.0);
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
                     case Replication.Kind (Frame) is
                        when Replication.XLog_Data =>
                           Saw_WAL := Saw_WAL or else
                             Replication.Data (Frame)'Length > 0;
                           if not Sent_Feedback then
                              Client.Send_Command
                                (Session,
                                 Replication.Make_Standby_Status_Update
                                   (Replication.WAL_End (Frame),
                                    Replication.WAL_End (Frame),
                                    Replication.WAL_End (Frame),
                                    Sent_At => 0),
                                 Timeout => 10.0);
                              Client.Send_Command
                                (Session,
                                 Replication.Make_Hot_Standby_Feedback
                                   (Sent_At            => 0,
                                    Xmin               => 0,
                                    Xmin_Epoch         => 0,
                                    Catalog_Xmin       => 0,
                                    Catalog_Xmin_Epoch => 0),
                                 Timeout => 10.0);
                              Sent_Feedback := True;
                           end if;
                        when Replication.Primary_Keepalive =>
                           Saw_Keepalive := True;
                           if Replication.Reply_Requested (Frame) then
                              Client.Send_Command
                                (Session,
                                 Replication.Make_Standby_Status_Update
                                   (Replication.WAL_End (Frame),
                                    Replication.WAL_End (Frame),
                                    Replication.WAL_End (Frame),
                                    Sent_At => 0),
                                 Timeout => 10.0);
                           end if;
                        when Replication.Standby_Status_Update |
                             Replication.Hot_Standby_Feedback =>
                           raise Program_Error with
                             "server sent a frontend replication message";
                     end case;
                  end;
               end if;
            end;
         end loop;

         Require
           (Sent_Feedback,
            "physical stream did not accept standby and xmin feedback");
         Finish_Stream;
      end Test_Physical;

      procedure Test_Logical_Resume is
         Slot : constant String :=
           Environment ("POSTGRES_REPLICATION_SLOT");
         Start_Text : constant String :=
           Environment ("POSTGRES_REPLICATION_START_LSN", "0/0");
         Start : constant Replication.LSN := Replication.Value (Start_Text);
         First_Run : constant Boolean :=
           Scenario = "logical_resume_first";
         Decoder : Logical.Decoder;
         Saw_Begin : Boolean := False;
         Saw_Checkpoint_Row : Boolean := False;
         Checkpoint_Commits : Natural := 0;
         Interrupted_Rows   : Natural := 0;
         Expected_Id        : Natural := 800_001;
         Messages           : Natural := 0;
         Finished           : Boolean := False;
         Acknowledged       : Replication.LSN := Start;

         function Tuple_Id (Item : Logical.Tuple_Data) return Natural is
            Column : constant Logical.Tuple_Value :=
              Logical.Column (Item, 1);
         begin
            Require
              (Logical.Kind (Column) = Logical.Text_Value,
               "resume oracle received a non-text primary key");
            return Natural'Value (Logical.Text (Column));
         end Tuple_Id;

         procedure Acknowledge (Position : Replication.LSN) is
         begin
            Require (Position > 0, "resume oracle cannot acknowledge zero");
            Client.Send_Command
              (Session,
               Replication.Make_Standby_Status_Update
                 (Position, Position, Position, Sent_At => 0),
               Timeout => 10.0);
            Acknowledged := Position;
         end Acknowledge;

         procedure Observe (Item : Logical.Message) is
         begin
            case Logical.Kind (Item) is
               when Logical.Begin_Message =>
                  Saw_Begin := True;

               when Logical.Insert_Message =>
                  declare
                     Id : constant Natural :=
                       Tuple_Id (Logical.New_Tuple (Item));
                  begin
                     if Id = 800_000 then
                        Require
                          (not Saw_Checkpoint_Row
                           and then Interrupted_Rows = 0,
                           "checkpoint transaction was replayed more than"
                           & " once");
                        Saw_Checkpoint_Row := True;
                     elsif Id in 800_001 .. 801_000 then
                        Require
                          (Saw_Begin,
                           "resume started inside the interrupted"
                           & " transaction");
                        Require
                          (Id = Expected_Id,
                           "resume oracle found a gap or duplicate at row"
                           & Natural'Image (Expected_Id));
                        Interrupted_Rows := Interrupted_Rows + 1;
                        Expected_Id := Expected_Id + 1;
                     end if;
                  end;

               when Logical.Commit_Message =>
                  if Interrupted_Rows = 0 then
                     Require
                       (Saw_Checkpoint_Row,
                        "resume oracle observed an unrelated transaction");
                     Checkpoint_Commits := Checkpoint_Commits + 1;
                     Require
                       (Checkpoint_Commits = 1,
                        "more than one acknowledged transaction was replayed");
                     if First_Run then
                        Acknowledge (Logical.End_LSN (Item));
                     end if;
                  elsif not First_Run then
                     Require
                       (Interrupted_Rows = 1_000,
                        "resumed transaction committed with missing rows");
                     Acknowledge (Logical.End_LSN (Item));
                     Finished := True;
                  end if;
                  Saw_Begin := False;

               when others =>
                  null;
            end case;
         end Observe;
      begin
         Check_Logical_Server;
         Logical.Configure (Decoder, Version => 1);
         Start_Copy
           (Replication.Start_Logical
              (Slot,
               Start,
               (Replication.Option ("proto_version", "1"),
                Replication.Option
                  ("publication_names", "flyology_publication"))));

         while not Finished loop
            Messages := Messages + 1;
            Require
              (Messages <= 100_000,
               "logical resume scenario did not converge");
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 20.0);
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
                        Observe
                          (Logical.Decode
                             (Decoder, Replication.Data (Frame)));
                        if First_Run and then Interrupted_Rows = 50 then
                           Require
                             (Checkpoint_Commits = 1,
                              "interrupted before the checkpoint was"
                              & " acknowledged");
                           Sockets.Close_Socket (Socket);
                           Finished := True;
                        end if;
                     elsif Replication.Kind (Frame) =
                       Replication.Primary_Keepalive
                       and then Replication.Reply_Requested (Frame)
                     then
                        Client.Send_Command
                          (Session,
                           Replication.Make_Standby_Status_Update
                             (Acknowledged,
                              Acknowledged,
                              Acknowledged,
                              Sent_At => 0),
                           Timeout => 10.0);
                     end if;
                  end;
               end if;
            end;
         end loop;

         if not First_Run then
            Require
              (Expected_Id = 801_001,
               "resume oracle did not apply the exact interrupted"
               & " transaction");
            Finish_Stream;
         end if;
      end Test_Logical_Resume;

      procedure Test_Logical is
         Slot : constant String :=
           Environment ("POSTGRES_REPLICATION_SLOT");
         Version_Text : constant String :=
           Environment ("POSTGRES_LOGICAL_VERSION");
         Version : constant Logical.Protocol_Version :=
           Logical.Protocol_Version'Value (Version_Text);
         Mode : constant Logical.Streaming_Mode :=
           (if Scenario in "logical_v2" | "logical_v3_stream"
            then Logical.In_Progress
            elsif Scenario = "logical_v4"
            then Logical.Parallel
            else Logical.Disabled);
         Decoder : Logical.Decoder;
         Saw_Begin          : Boolean := False;
         Saw_Commit         : Boolean := False;
         Saw_Relation       : Boolean := False;
         Saw_Type           : Boolean := False;
         Saw_Insert         : Boolean := False;
         Saw_Update         : Boolean := False;
         Saw_Delete         : Boolean := False;
         Saw_Truncate       : Boolean := False;
         Saw_Message        : Boolean := False;
         Saw_Stream_Start   : Boolean := False;
         Saw_Stream_Stop    : Boolean := False;
         Saw_Stream_Commit  : Boolean := False;
         Saw_Stream_Abort   : Boolean := False;
         Saw_Begin_Prepare  : Boolean := False;
         Saw_Prepare        : Boolean := False;
         Saw_Commit_Prepared : Boolean := False;
         Saw_Rollback       : Boolean := False;
         Saw_Stream_Prepare : Boolean := False;
         Saw_Binary         : Boolean := False;
         Saw_Origin         : Boolean := False;
         Saw_Unchanged_Toast : Boolean := False;
         Last_WAL_End       : Replication.LSN := 0;
         Messages           : Natural := 0;

         subtype Model_Id is Natural range 1_001 .. 1_003;
         type Model_Row is record
            Present      : Boolean := False;
            Payload_Null : Boolean := False;
            Payload      : Unbounded.Unbounded_String;
            Marker       : Natural := 0;
            Mood         : Unbounded.Unbounded_String;
         end record;
         type Model_State is array (Model_Id) of Model_Row;
         Empty_State : constant Model_State :=
           (others => (others => <>));
         Committed_State : Model_State := Empty_State;
         Pending_State   : Model_State := Empty_State;
         In_Transaction  : Boolean := False;
         Applied_Transactions : Natural := 0;

         function Tuple_Id (Item : Logical.Tuple_Data) return Model_Id is
            Value : constant Logical.Tuple_Value :=
              Logical.Column (Item, 1);
         begin
            Require
              (Logical.Kind (Value) = Logical.Text_Value,
               "logical apply received a non-text primary key");
            return Model_Id'Value (Logical.Text (Value));
         end Tuple_Id;

         function Tuple_Text
           (Item : Logical.Tuple_Data; Index : Positive) return String is
            Value : constant Logical.Tuple_Value :=
              Logical.Column (Item, Index);
         begin
            Require
              (Logical.Kind (Value) = Logical.Text_Value,
               "logical apply received an unexpected non-text value");
            return Logical.Text (Value);
         end Tuple_Text;

         procedure Verify_Old (Item : Logical.Tuple_Data) is
            Id  : constant Model_Id := Tuple_Id (Item);
            Row : constant Model_Row := Pending_State (Id);
            Payload : constant Logical.Tuple_Value :=
              Logical.Column (Item, 2);
         begin
            Require (Row.Present, "logical old tuple names a missing row");
            if Row.Payload_Null then
               Require
                 (Logical.Kind (Payload) = Logical.Null_Value,
                  "logical old tuple lost a NULL payload");
            else
               Require
                 (Logical.Kind (Payload) = Logical.Text_Value
                  and then Logical.Text (Payload) =
                    Unbounded.To_String (Row.Payload),
                  "logical old tuple payload differs from applied state");
            end if;
            Require
              (Natural'Value (Tuple_Text (Item, 3)) = Row.Marker
               and then Tuple_Text (Item, 4) =
                 Unbounded.To_String (Row.Mood),
               "logical old tuple scalar values differ from applied state");
         end Verify_Old;

         procedure Apply_New
           (Item : Logical.Tuple_Data; Must_Exist : Boolean) is
            Id      : constant Model_Id := Tuple_Id (Item);
            Payload : constant Logical.Tuple_Value :=
              Logical.Column (Item, 2);
            Row     : Model_Row := Pending_State (Id);
         begin
            Require
              (Row.Present = Must_Exist,
               "logical apply row existence precondition changed");
            Row.Present := True;
            case Logical.Kind (Payload) is
               when Logical.Null_Value =>
                  Row.Payload_Null := True;
                  Row.Payload := Unbounded.Null_Unbounded_String;
               when Logical.Unchanged_Toast_Value =>
                  Require
                    (Must_Exist and then not Row.Payload_Null,
                     "unchanged TOAST has no prior applied value");
                  Saw_Unchanged_Toast := True;
               when Logical.Text_Value =>
                  Row.Payload_Null := False;
                  Row.Payload := Unbounded.To_Unbounded_String
                    (Logical.Text (Payload));
               when Logical.Binary_Value =>
                  raise Program_Error with
                    "logical v1 apply received a binary tuple";
            end case;
            Row.Marker := Natural'Value (Tuple_Text (Item, 3));
            Row.Mood := Unbounded.To_Unbounded_String
              (Tuple_Text (Item, 4));
            Pending_State (Id) := Row;
         end Apply_New;

         function Applied_State_Is_Exact return Boolean is
           (Applied_Transactions = 3
            and then not Committed_State (1_001).Present
            and then not Committed_State (1_002).Present
            and then Committed_State (1_003).Present
            and then not Committed_State (1_003).Payload_Null
            and then Unbounded.To_String
              (Committed_State (1_003).Payload) = "final-state"
            and then Committed_State (1_003).Marker = 3
            and then Unbounded.To_String
              (Committed_State (1_003).Mood) = "happy");

         function Tuple_Has_Binary
           (Item : Logical.Tuple_Data) return Boolean is
         begin
            for Index in 1 .. Logical.Column_Count (Item) loop
               if Logical.Kind (Logical.Column (Item, Index)) =
                 Logical.Binary_Value
               then
                  return True;
               end if;
            end loop;
            return False;
         end Tuple_Has_Binary;

         function Complete return Boolean is
         begin
            if Scenario = "logical_v1" then
               return
                 (Saw_Begin and Saw_Commit and Saw_Relation
                  and Saw_Type and Saw_Insert and Saw_Update and Saw_Delete
                  and Saw_Truncate and Saw_Message and Saw_Unchanged_Toast)
                 and then Applied_State_Is_Exact;
            elsif Scenario = "logical_v2" then
               return Saw_Stream_Start and Saw_Stream_Stop
                 and Saw_Stream_Commit and Saw_Insert;
            elsif Scenario = "logical_v3" then
               return Saw_Begin_Prepare and Saw_Prepare
                 and Saw_Commit_Prepared and Saw_Rollback;
            elsif Scenario = "logical_v3_stream" then
               return Saw_Stream_Start and Saw_Stream_Stop
                 and Saw_Stream_Prepare and Saw_Commit_Prepared
                 and Saw_Insert;
            elsif Scenario = "logical_v4" then
               return Saw_Stream_Start and Saw_Stream_Stop
                 and Saw_Stream_Abort and Saw_Insert;
            elsif Scenario = "logical_binary" then
               return Saw_Begin and Saw_Commit and Saw_Insert
                 and Saw_Binary;
            elsif Scenario = "logical_origin" then
               return Saw_Begin and Saw_Commit and Saw_Insert
                 and Saw_Origin;
            end if;
            raise Program_Error with
              "unknown logical replication scenario " & Scenario;
         end Complete;

         procedure Observe (Item : Logical.Message) is
         begin
            case Logical.Kind (Item) is
               when Logical.Begin_Message =>
                  Saw_Begin := True;
                  Require
                    (Logical.Final_LSN (Item) > 0
                     and then Logical.Transaction (Item) > 0,
                     "real Begin has invalid transaction metadata");
                  if Scenario = "logical_v1" then
                     Require
                       (not In_Transaction,
                        "logical apply observed a nested transaction");
                     Pending_State := Committed_State;
                     In_Transaction := True;
                  end if;
               when Logical.Commit_Message =>
                  Saw_Commit := True;
                  Require
                    (Logical.Commit_LSN (Item) > 0
                     and then Logical.End_LSN (Item) > 0,
                     "real Commit has invalid LSNs");
                  if Scenario = "logical_v1" then
                     Require
                       (In_Transaction,
                        "logical apply committed outside a transaction");
                     Committed_State := Pending_State;
                     Applied_Transactions := Applied_Transactions + 1;
                     In_Transaction := False;
                  end if;
               when Logical.Origin_Message =>
                  Saw_Origin := True;
                  Require
                    (Logical.Origin_Name (Item) = "flyology_origin",
                     "real Origin did not preserve its name");
               when Logical.Logical_Decoding_Message =>
                  Saw_Message := True;
                  Require
                    (Logical.Is_Transactional (Item)
                     and then Logical.Prefix (Item) = "flyology"
                     and then Byte_Text (Logical.Content (Item)) =
                       "real-message",
                     "real logical message payload changed");
               when Logical.Relation_Message =>
                  Saw_Relation := True;
                  Require
                    (Logical.Object_Name (Item) =
                       "flyology_replication"
                     and then Logical.Relation_Column_Count (Item) = 4,
                     "real Relation metadata changed");
               when Logical.Type_Message =>
                  if Logical.Object_Name (Item) = "flyology_mood" then
                     Saw_Type := True;
                  end if;
               when Logical.Insert_Message =>
                  Saw_Insert := True;
                  Require
                    (Logical.Column_Count (Logical.New_Tuple (Item)) = 4,
                     "real Insert tuple has an unexpected shape");
                  Saw_Binary := Saw_Binary or else
                    Tuple_Has_Binary (Logical.New_Tuple (Item));
                  if Mode /= Logical.Disabled then
                     Require
                       (Logical.Is_Streamed (Item)
                        and then Logical.Transaction (Item) > 0,
                        "streamed Insert is missing its XID");
                  end if;
                  if Scenario = "logical_v1" then
                     Require
                       (In_Transaction,
                        "logical apply inserted outside a transaction");
                     Apply_New (Logical.New_Tuple (Item), False);
                  end if;
               when Logical.Update_Message =>
                  Saw_Update := True;
                  Require
                     (Logical.Old_Kind (Item) =
                       Logical.Full_Old_Tuple,
                     "real Update lost REPLICA IDENTITY FULL data");
                  if Scenario = "logical_v1" then
                     Require
                       (In_Transaction,
                        "logical apply updated outside a transaction");
                     Verify_Old (Logical.Old_Tuple (Item));
                     Apply_New (Logical.New_Tuple (Item), True);
                  end if;
               when Logical.Delete_Message =>
                  Saw_Delete := True;
                  Require
                     (Logical.Old_Kind (Item) =
                       Logical.Full_Old_Tuple,
                     "real Delete lost REPLICA IDENTITY FULL data");
                  if Scenario = "logical_v1" then
                     Require
                       (In_Transaction,
                        "logical apply deleted outside a transaction");
                     declare
                        Id : constant Model_Id :=
                          Tuple_Id (Logical.Old_Tuple (Item));
                     begin
                        Verify_Old (Logical.Old_Tuple (Item));
                        Pending_State (Id) := (others => <>);
                     end;
                  end if;
               when Logical.Truncate_Message =>
                  Saw_Truncate := True;
                  Require
                    (Logical.Cascade (Item)
                     and then Logical.Restart_Identity (Item),
                     "real Truncate flags changed");
                  if Scenario = "logical_v1" then
                     Require
                       (In_Transaction,
                        "logical apply truncated outside a transaction");
                     Pending_State := Empty_State;
                  end if;
               when Logical.Stream_Start_Message =>
                  Saw_Stream_Start := True;
                  Require
                    (Logical.Transaction (Item) > 0,
                     "real StreamStart has no XID");
               when Logical.Stream_Stop_Message =>
                  Saw_Stream_Stop := True;
               when Logical.Stream_Commit_Message =>
                  Saw_Stream_Commit := True;
                  Require
                    (Logical.Commit_LSN (Item) > 0,
                     "real StreamCommit has no commit LSN");
               when Logical.Stream_Abort_Message =>
                  Saw_Stream_Abort := True;
                  Require
                    (Logical.Abort_LSN (Item) > 0,
                     "parallel StreamAbort has no abort LSN");
               when Logical.Begin_Prepare_Message =>
                  Saw_Begin_Prepare := True;
                  Require
                    (Logical.GID (Item)'Length > 0,
                     "real BeginPrepare has no GID");
               when Logical.Prepare_Message =>
                  Saw_Prepare := True;
                  Require
                    (Logical.GID (Item)'Length > 0,
                     "real Prepare has no GID");
               when Logical.Commit_Prepared_Message =>
                  Saw_Commit_Prepared := True;
                  Require
                    (Logical.GID (Item)'Length > 0,
                     "real CommitPrepared has no GID");
               when Logical.Rollback_Prepared_Message =>
                  Saw_Rollback := True;
                  Require
                    (Logical.Prepare_End_LSN (Item) > 0,
                     "real RollbackPrepared has no prepare end LSN");
               when Logical.Stream_Prepare_Message =>
                  Saw_Stream_Prepare := True;
                  Require
                    (Logical.GID (Item)'Length > 0,
                     "real StreamPrepare has no GID");
            end case;
         end Observe;

         procedure Send_Start is
         begin
            if Scenario = "logical_v1" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("messages", "true"))));
            elsif Scenario = "logical_v2" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("streaming", "on"))));
            elsif Scenario = "logical_v3" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("two_phase", "true"))));
            elsif Scenario = "logical_v3_stream" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("streaming", "on"),
                      Replication.Option ("two_phase", "true"))));
            elsif Scenario = "logical_v4" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("streaming", "parallel"))));
            elsif Scenario = "logical_binary" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("binary", "true"))));
            elsif Scenario = "logical_origin" then
               Start_Copy
                 (Replication.Start_Logical
                    (Slot,
                     0,
                     (Replication.Option
                        ("proto_version", Version_Text),
                      Replication.Option
                        ("publication_names", "flyology_publication"),
                      Replication.Option ("origin", "any"))));
            else
               raise Program_Error with
                 "unknown logical replication scenario " & Scenario;
            end if;
         end Send_Start;
      begin
         Check_Logical_Server;
         Logical.Configure (Decoder, Version, Mode);
         Send_Start;

         while not Complete loop
            Messages := Messages + 1;
            Require
              (Messages <= 100_000,
               "logical replication scenario did not converge");
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 20.0);
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
                     if Replication.Kind (Frame) =
                       Replication.XLog_Data
                     then
                        Last_WAL_End := Replication.WAL_End (Frame);
                        Observe
                          (Logical.Decode
                             (Decoder, Replication.Data (Frame)));
                     elsif Replication.Kind (Frame) =
                       Replication.Primary_Keepalive
                       and then Replication.Reply_Requested (Frame)
                     then
                        Last_WAL_End := Replication.WAL_End (Frame);
                        Client.Send_Command
                          (Session,
                           Replication.Make_Standby_Status_Update
                             (Last_WAL_End,
                              Last_WAL_End,
                              Last_WAL_End,
                              Sent_At => 0),
                           Timeout => 10.0);
                     end if;
                  end;
               end if;
            end;
         end loop;

         Require (Last_WAL_End > 0, "logical stream reported no WAL end");
         Client.Send_Command
           (Session,
            Replication.Make_Standby_Status_Update
              (Last_WAL_End,
               Last_WAL_End,
               Last_WAL_End,
               Sent_At => 0),
            Timeout => 10.0);
         Finish_Stream;
      end Test_Logical;
   begin
      OpenSSL.Initialize_Client
        (Backend,
         CA_File => Environment ("POSTGRES_TLS_CA_FILE"),
         Library_Directory =>
           Environment ("FLYOLOGY_OPENSSL_LIBRARY_DIR"));
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Server, Timeout => 10.0);
      Client.Startup_TLS
        (Session,
         Backend,
         Server_Name => "localhost",
         User        => "flyology",
         Database    => "postgres",
         Password    => "flyology-secret",
         Timeout     => 10.0,
         Replication_Mode =>
           (if Scenario = "physical"
            then Protocol.Physical_Replication_Connection
            else Protocol.Logical_Replication_Connection));

      if Scenario = "physical" then
         Test_Physical;
      elsif Scenario in
        "logical_resume_first" | "logical_resume_second"
      then
         Test_Logical_Resume;
      else
         Test_Logical;
      end if;

      if Scenario /= "logical_resume_first" then
         Client.Send_Command
           (Session, Protocol.Make_Empty_Message ('X'), Timeout => 10.0);
      end if;
      Ada.Text_IO.Put_Line
        ("PostgreSQL " & Server_Major & " " & Scenario & " passed");
      Result.Pass;
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "PostgreSQL " & Server_Major & " " & Scenario & ": "
            & Ada.Exceptions.Exception_Information (Error));
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         Result.Fail;
   end Worker;

begin
   declare
      Succeeded : Boolean;
   begin
      Result.Await (Succeeded);
      if not Succeeded then
         raise Program_Error with
           "real PostgreSQL replication interoperability failed";
      end if;
   end;
end Postgres_Test_Replication;
