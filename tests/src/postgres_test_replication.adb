with Ada.Environment_Variables;
with Ada.Exceptions;
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
         Last_WAL_End       : Replication.LSN := 0;
         Messages           : Natural := 0;

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
               return Saw_Begin and Saw_Commit and Saw_Relation
                 and Saw_Type and Saw_Insert and Saw_Update and Saw_Delete
                 and Saw_Truncate and Saw_Message;
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
               when Logical.Commit_Message =>
                  Saw_Commit := True;
                  Require
                    (Logical.Commit_LSN (Item) > 0
                     and then Logical.End_LSN (Item) > 0,
                     "real Commit has invalid LSNs");
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
               when Logical.Update_Message =>
                  Saw_Update := True;
                  Require
                    (Logical.Old_Kind (Item) =
                       Logical.Full_Old_Tuple,
                     "real Update lost REPLICA IDENTITY FULL data");
               when Logical.Delete_Message =>
                  Saw_Delete := True;
                  Require
                    (Logical.Old_Kind (Item) =
                       Logical.Full_Old_Tuple,
                     "real Delete lost REPLICA IDENTITY FULL data");
               when Logical.Truncate_Message =>
                  Saw_Truncate := True;
                  Require
                    (Logical.Cascade (Item)
                     and then Logical.Restart_Identity (Item),
                     "real Truncate flags changed");
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
      else
         Test_Logical;
      end if;

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 10.0);
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
