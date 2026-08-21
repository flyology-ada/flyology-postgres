with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.IO.Connections;
with Flyology.IO.Sockets;
with Flyology.IO.TLS;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Operations;
with Flyology.Postgres.Client;
with Flyology.Postgres.Client_Sockets;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Connections;
with Flyology.Postgres.Transports.TLS_Sockets;

procedure Postgres_Test_Client is

   package Client renames Flyology.Postgres.Client;
   package Client_Sockets renames Flyology.Postgres.Client_Sockets;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package TLS renames Flyology.IO.TLS;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Connections renames Flyology.IO.Connections;
   package Operations renames Flyology.Operations;
   package Connection_Transports renames
     Flyology.Postgres.Transports.Connections;
   package Transports renames Flyology.Postgres.Transports.TLS_Sockets;

   use type Protocol.Backend_Message_Kind;
   use type Protocol.Byte_Offset;
   use type Protocol.Field_Format;
   use type Protocol.Transaction_Status;
   use type Protocol.UInt32;
   use type Client.Operation_State;

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

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_TEST_PORT", "55433"));
   end Port;

   task Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
      Backend : OpenSSL.OpenSSL_Provider;
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.TLS_Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      All_Good : Boolean := True;
      Saw_Cancellation : Boolean := False;
      Server : constant Sockets.Endpoint :=
        Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port);
      Server_Name : constant String :=
        Ada.Environment_Variables.Value
          ("POSTGRES_TLS_SERVER_NAME", "localhost");

      procedure Check (Condition : Boolean) is
      begin
         All_Good := All_Good and Condition;
      end Check;

      function Bytes (Value : String) return Protocol.Byte_Array is
        (Flyology.Bytes.To_Array
           (Flyology.Bytes.From_Byte_String (Value)));
   begin
      OpenSSL.Initialize_Client
        (Backend,
         CA_File => Ada.Environment_Variables.Value
           ("POSTGRES_TLS_CA_FILE"),
         Library_Directory => Ada.Environment_Variables.Value
           ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));

      --  The same real PostgreSQL endpoint must reject a certificate name
      --  mismatch before any startup credentials are sent.
      declare
         Wrong_Socket  : aliased Sockets.Socket_Type;
         Wrong_Channel : aliased Transports.TLS_Socket_Transport
           (Wrong_Socket'Access);
         Wrong_Session : Client.Session (Wrong_Channel'Access);
         Rejected      : Boolean := False;
      begin
         Sockets.Create_Socket (Wrong_Socket);
         Sockets.Connect (Wrong_Socket, Server, Timeout => 5.0);
         begin
            Client.Startup_TLS
              (Wrong_Session,
               Backend,
               Server_Name => "wrong.example",
               User        => "flyology",
               Database    => "postgres",
               Password    => "flyology-secret",
               Timeout     => 5.0);
         exception
            when TLS.TLS_Error =>
               Rejected := True;
         end;
         Check (Rejected);
      end;

      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Server,
         Timeout => 5.0);
      Client.Startup_TLS
        (Session,
         Backend,
         Server_Name => Server_Name,
         User     => "flyology",
         Database => "postgres",
         Password => "flyology-secret",
         Timeout  => 5.0);
      Client.Send_Query
        (Session,
         "select n, case when n = 2 then null else 'value' end, "
         & "case when n = 1 then '' else 'x' end "
         & "from generate_series(1, 2) n order by n",
         Timeout => 5.0);
      declare
         Descriptions : Natural := 0;
         Rows         : Natural := 0;
         Completed    : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               case Protocol.Response_Kind (Event) is
                  when Protocol.Row_Description_Response =>
                     Descriptions := Descriptions + 1;
                     Check
                       (Protocol.Field_Count
                          (Protocol.Description (Event)) = 3);
                  when Protocol.Data_Row_Response =>
                     Rows := Rows + 1;
                     declare
                        Row : constant Protocol.Data_Row :=
                          Protocol.Row_Data (Event);
                     begin
                        Check (Protocol.Column_Count (Row) = 3);
                        if Rows = 1 then
                           Check
                             (Protocol.Column_Text
                                (Protocol.Column_At (Row, 1)) = "1");
                           Check
                             (Protocol.Column_Text
                                (Protocol.Column_At (Row, 2)) = "value");
                           Check
                             (not Protocol.Is_Null
                                (Protocol.Column_At (Row, 3))
                              and then Protocol.Column_Text
                                (Protocol.Column_At (Row, 3)) = "");
                        elsif Rows = 2 then
                           Check
                             (Protocol.Column_Text
                                (Protocol.Column_At (Row, 1)) = "2");
                           Check
                             (Protocol.Is_Null
                                (Protocol.Column_At (Row, 2)));
                           Check
                             (Protocol.Column_Text
                                (Protocol.Column_At (Row, 3)) = "x");
                        end if;
                     end;
                  when Protocol.Command_Complete_Response =>
                     Completed := Protocol.Completion_Tag (Event) = "SELECT 2";
                  when Protocol.Error_Response =>
                     Check (False);
                  when others =>
                     null;
               end case;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Descriptions = 1 and then Rows = 2 and then Completed);
      end;

      Client.Send_Query
        (Session,
         "select 'first'; select 'second', null",
         Timeout => 5.0);
      declare
         Descriptions : Natural := 0;
         Rows         : Natural := 0;
         Completions  : Natural := 0;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               case Protocol.Response_Kind (Event) is
                  when Protocol.Row_Description_Response =>
                     Descriptions := Descriptions + 1;
                     Check
                       (Protocol.Field_Count
                          (Protocol.Description (Event)) = Descriptions);
                  when Protocol.Data_Row_Response =>
                     Rows := Rows + 1;
                  when Protocol.Command_Complete_Response =>
                     Completions := Completions + 1;
                  when Protocol.Error_Response =>
                     Check (False);
                  when others =>
                     null;
               end case;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check
           (Descriptions = 2 and then Rows = 2 and then Completions = 2);
      end;

      Client.Send_Query
        (Session,
         "create temporary table flyology_typed_test (value integer)",
         Timeout => 5.0);
      declare
         Commands : Natural := 0;
         Rows     : Natural := 0;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) =
                 Protocol.Command_Complete_Response
               then
                  Commands := Commands + 1;
               elsif Protocol.Response_Kind (Event) =
                 Protocol.Data_Row_Response
               then
                  Rows := Rows + 1;
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Commands = 1 and then Rows = 0);
      end;

      Client.Send_Query (Session, "   ", Timeout => 5.0);
      declare
         Saw_Empty : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               Saw_Empty := Saw_Empty or else
                 Protocol.Response_Kind (Event) =
                   Protocol.Empty_Query_Response;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Empty);
      end;

      Client.Send_Query
        (Session,
         "do $$ begin raise notice 'flyology notice'; end $$",
         Timeout => 5.0);
      declare
         Saw_Notice : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Notice_Response
               then
                  Saw_Notice := Protocol.Diagnostic_Message
                    (Protocol.Diagnostic_Data (Event)) = "flyology notice";
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Notice);
      end;

      Client.Send_Query (Session, "select 1 / 0", Timeout => 5.0);
      declare
         Saw_Error : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Saw_Error := Protocol.Diagnostic_SQL_State
                    (Protocol.Diagnostic_Data (Event)) = "22012";
               elsif Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response
               then
                  Check
                    (Protocol.Transaction_State (Event) = Protocol.Idle);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Error);
      end;

      Client.Send_Query (Session, "select 'recovered'", Timeout => 5.0);
      declare
         Recovered : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Data_Row_Response
               then
                  Recovered := Protocol.Column_Text
                    (Protocol.Column_At (Protocol.Row_Data (Event), 1)) =
                      "recovered";
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Recovered);
      end;

      Client.Send_Query
        (Session,
         "set application_name = 'typed-query-tests'",
         Timeout => 5.0);
      declare
         Saw_Status : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) =
                 Protocol.Parameter_Status_Response
               then
                  declare
                     Status : constant Protocol.Parameter_Status :=
                       Protocol.Parameter_Data (Event);
                  begin
                     Saw_Status :=
                       Protocol.Parameter_Name (Status) = "application_name"
                       and then Protocol.Parameter_Value (Status) =
                         "typed-query-tests";
                  end;
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Status);
      end;

      declare
         Binary_Five : constant Protocol.Byte_Array (1 .. 4) :=
           (1 => 0, 2 => 0, 3 => 0, 4 => 5);
         Binary_Bytea : constant Protocol.Byte_Array (1 .. 2) :=
           (1 => 0, 2 => 16#FF#);
         Rows : Natural := 0;
         Saw_Parameter_Description : Boolean := False;
         Saw_Statement_Description : Boolean := False;
         Saw_Portal_Description : Boolean := False;
         Saw_Suspension : Boolean := False;
         Completed : Boolean := False;
      begin
         Client.Prepare_Statement
           (Session,
            Statement_Name  => "flyology_named",
            SQL             =>
              "select $1::int4 + $2::int4 as total, $3::text as label, "
              & "$4::bytea as payload, $5::text as optional, n "
              & "from generate_series(1, 3) n order by n",
            Parameter_Types => (23, 23, 25, 17, 25),
            Timeout         => 5.0);
         Client.Describe_Statement
           (Session, "flyology_named", Timeout => 5.0);
         Client.Bind_Portal
           (Session,
            Portal_Name    => "flyology_portal",
            Statement_Name => "flyology_named",
            Parameters     =>
              (Protocol.Text_Parameter ("7"),
               Protocol.Binary_Parameter (Binary_Five),
               Protocol.Text_Parameter ("hello"),
               Protocol.Binary_Parameter (Binary_Bytea),
               Protocol.Null_Parameter (Protocol.Binary_Format)),
            Result_Formats =>
              (Protocol.Text_Format,
               Protocol.Binary_Format,
               Protocol.Text_Format,
               Protocol.Binary_Format,
               Protocol.Text_Format),
            Timeout => 5.0);
         Client.Describe_Portal
           (Session, "flyology_portal", Timeout => 5.0);
         Client.Execute_Portal
           (Session,
            "flyology_portal",
            Maximum_Rows => 2,
            Timeout      => 5.0);
         Client.Flush (Session, Timeout => 5.0);

         loop
            declare
               Event : constant Client.Extended_Query_Event :=
                 Client.Receive_Extended_Event (Session, Timeout => 5.0);
            begin
               case Protocol.Response_Kind (Event) is
                  when Protocol.Parameter_Description_Response =>
                     declare
                        Types : constant Protocol.Parameter_Description :=
                          Protocol.Parameter_Types (Event);
                     begin
                        Saw_Parameter_Description :=
                          Protocol.Parameter_Count (Types) = 5
                          and then Protocol.Parameter_Type_At (Types, 1) = 23
                          and then Protocol.Parameter_Type_At (Types, 4) = 17;
                     end;
                  when Protocol.Row_Description_Response =>
                     declare
                        Description : constant Protocol.Row_Description :=
                          Protocol.Description (Event);
                     begin
                        Check (Protocol.Field_Count (Description) = 5);
                        if Protocol.Format
                          (Protocol.Field_At (Description, 2)) =
                            Protocol.Binary_Format
                        then
                           Saw_Portal_Description := True;
                        else
                           Saw_Statement_Description := True;
                        end if;
                     end;
                  when Protocol.Data_Row_Response =>
                     Rows := Rows + 1;
                     declare
                        Row : constant Protocol.Data_Row :=
                          Protocol.Row_Data (Event);
                     begin
                        Check
                          (Protocol.Column_Count (Row) = 5
                           and then Protocol.Column_Text
                             (Protocol.Column_At (Row, 1)) = "12"
                           and then Protocol.Column_Text
                             (Protocol.Column_At (Row, 2)) = "hello"
                           and then Protocol.Column_Text
                             (Protocol.Column_At (Row, 3)) = "\x00ff"
                           and then Protocol.Is_Null
                             (Protocol.Column_At (Row, 4))
                           and then Protocol.Column_Text
                             (Protocol.Column_At (Row, 5)) =
                               Rows'Image (2 .. 2));
                     end;
                  when Protocol.Portal_Suspended_Response =>
                     Saw_Suspension := True;
                  when Protocol.Error_Response =>
                     Check (False);
                  when others =>
                     null;
               end case;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Portal_Suspended_Response;
            end;
         end loop;
         Check
           (Rows = 2
            and then Saw_Parameter_Description
            and then Saw_Statement_Description
            and then Saw_Portal_Description
            and then Saw_Suspension);

         Client.Resume_Portal
           (Session,
            "flyology_portal",
            Maximum_Rows => 2,
            Timeout      => 5.0);
         Client.Flush (Session, Timeout => 5.0);
         loop
            declare
               Event : constant Client.Extended_Query_Event :=
                 Client.Receive_Extended_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Data_Row_Response
               then
                  Rows := Rows + 1;
               elsif Protocol.Response_Kind (Event) =
                 Protocol.Command_Complete_Response
               then
                  Completed := Protocol.Completion_Tag (Event) = "SELECT 1";
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Command_Complete_Response;
            end;
         end loop;
         Check (Rows = 3 and then Completed);

         Client.Close_Portal
           (Session, "flyology_portal", Timeout => 5.0);
         Client.Close_Statement
           (Session, "flyology_named", Timeout => 5.0);
         Client.Synchronize (Session, Timeout => 5.0);
         declare
            Closed : Natural := 0;
         begin
            loop
               declare
                  Event : constant Client.Extended_Query_Event :=
                    Client.Receive_Extended_Event (Session, Timeout => 5.0);
               begin
                  if Protocol.Response_Kind (Event) =
                    Protocol.Close_Complete_Response
                  then
                     Closed := Closed + 1;
                  elsif Protocol.Response_Kind (Event) =
                    Protocol.Error_Response
                  then
                     Check (False);
                  end if;
                  exit when Protocol.Response_Kind (Event) =
                    Protocol.Ready_For_Query_Response;
               end;
            end loop;
            Check
              (Closed = 2
               and then Client.State (Session) = Client.Ready);
         end;
      end;

      Client.Prepare_Statement
        (Session,
         Statement_Name  => "",
         SQL             => "select $1::text, $2::int4",
         Parameter_Types => (25, 23),
         Timeout         => 5.0);
      Client.Bind_Portal
        (Session,
         Portal_Name    => "",
         Statement_Name => "",
         Parameters     =>
           (Protocol.Text_Parameter ("unnamed"),
            Protocol.Text_Parameter ("9")),
         Timeout => 5.0);
      Client.Describe_Portal (Session, "", Timeout => 5.0);
      Client.Execute_Portal (Session, "", Timeout => 5.0);
      Client.Close_Portal (Session, "", Timeout => 5.0);
      Client.Close_Statement (Session, "", Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);
      declare
         Saw_Unnamed_Row : Boolean := False;
         Closed          : Natural := 0;
      begin
         loop
            declare
               Event : constant Client.Extended_Query_Event :=
                 Client.Receive_Extended_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Data_Row_Response
               then
                  declare
                     Row : constant Protocol.Data_Row :=
                       Protocol.Row_Data (Event);
                  begin
                     Saw_Unnamed_Row :=
                       Protocol.Column_Text (Protocol.Column_At (Row, 1)) =
                         "unnamed"
                       and then Protocol.Column_Text
                         (Protocol.Column_At (Row, 2)) = "9";
                  end;
               elsif Protocol.Response_Kind (Event) =
                 Protocol.Close_Complete_Response
               then
                  Closed := Closed + 1;
               elsif Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Check (False);
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Unnamed_Row and then Closed = 2);
      end;

      Client.Prepare_Statement
        (Session, "broken", "select +", Timeout => 5.0);
      Client.Flush (Session, Timeout => 5.0);
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 5.0);
      begin
         Check
           (Protocol.Response_Kind (Event) = Protocol.Error_Response
            and then Client.State (Session) = Client.Recovery_Required);
      end;
      Client.Synchronize (Session, Timeout => 5.0);
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout => 5.0);
      begin
         Check
           (Protocol.Response_Kind (Event) =
              Protocol.Ready_For_Query_Response
            and then Client.State (Session) = Client.Ready);
      end;

      --  Pipelined batches over the TLS transport. Every batch is written
      --  before the first response is read, and the failing middle batch
      --  must not disturb the batch queued behind it. This covers the many
      --  small writes a pipeline makes through TLS; postgres_test_pipeline
      --  covers depth, transactions, and recovery across every major. The
      --  last batch skips Describe on purpose, so its rows arrive with no
      --  RowDescription.
      Client.Enter_Pipeline_Mode (Session);
      Client.Prepare_Statement
        (Session,
         Statement_Name  => "pipe_first",
         SQL             => "select $1::int4 + 1",
         Parameter_Types => (1 => 23),
         Timeout         => 5.0);
      Client.Bind_Portal
        (Session,
         Portal_Name    => "pipe_first",
         Statement_Name => "pipe_first",
         Parameters     => (1 => Protocol.Text_Parameter ("41")),
         Timeout        => 5.0);
      Client.Describe_Portal (Session, "pipe_first", Timeout => 5.0);
      Client.Execute_Portal (Session, "pipe_first", Timeout => 5.0);
      Client.Close_Portal (Session, "pipe_first", Timeout => 5.0);
      Client.Close_Statement (Session, "pipe_first", Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);

      Client.Prepare_Statement
        (Session,
         Statement_Name => "pipe_broken",
         SQL            => "select flyology_missing_function()",
         Timeout        => 5.0);
      Client.Bind_Portal
        (Session,
         Portal_Name    => "pipe_broken",
         Statement_Name => "pipe_broken",
         Timeout        => 5.0);
      Client.Describe_Portal (Session, "pipe_broken", Timeout => 5.0);
      Client.Execute_Portal (Session, "pipe_broken", Timeout => 5.0);
      Client.Close_Portal (Session, "pipe_broken", Timeout => 5.0);
      Client.Close_Statement (Session, "pipe_broken", Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);

      Client.Prepare_Statement
        (Session,
         Statement_Name => "pipe_last",
         SQL            => "select 'last'::text",
         Timeout        => 5.0);
      Client.Bind_Portal
        (Session,
         Portal_Name    => "pipe_last",
         Statement_Name => "pipe_last",
         Timeout        => 5.0);
      Client.Execute_Portal (Session, "pipe_last", Timeout => 5.0);
      Client.Close_Portal (Session, "pipe_last", Timeout => 5.0);
      Client.Close_Statement (Session, "pipe_last", Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);
      Check (Client.Pending_Synchronizations (Session) = 3);

      declare
         Completed   : Natural := 0;
         Errors      : Natural := 0;
         Error_Batch : Natural := 0;
         Closes      : Natural := 0;
         Saw_Sum     : Boolean := False;
         Saw_Last    : Boolean := False;
      begin
         while Client.Pending_Synchronizations (Session) > 0 loop
            declare
               Event : constant Client.Extended_Query_Event :=
                 Client.Receive_Extended_Event (Session, Timeout => 5.0);
               Kind  : constant Protocol.Backend_Message_Kind :=
                 Protocol.Response_Kind (Event);
            begin
               if Kind = Protocol.Data_Row_Response then
                  declare
                     Row : constant Protocol.Data_Row :=
                       Protocol.Row_Data (Event);
                     Text : constant String :=
                       Protocol.Column_Text (Protocol.Column_At (Row, 1));
                  begin
                     Saw_Sum := Saw_Sum or else Text = "42";
                     Saw_Last := Saw_Last or else Text = "last";
                  end;
               elsif Kind = Protocol.Error_Response then
                  Errors := Errors + 1;
                  Error_Batch := Completed;
               elsif Kind = Protocol.Close_Complete_Response then
                  Closes := Closes + 1;
               elsif Kind = Protocol.Ready_For_Query_Response then
                  Completed := Completed + 1;
               end if;
            end;
         end loop;
         --  The error belongs to the second batch, so exactly one batch has
         --  already ended when it arrives.
         Check
           (Completed = 3
            and then Errors = 1
            and then Error_Batch = 1
            --  The failing batch is abandoned at its error, so only the two
            --  good batches acknowledge their two closes.
            and then Closes = 4
            and then Saw_Sum
            and then Saw_Last
            and then Client.State (Session) = Client.Ready);
      end;
      Client.Exit_Pipeline_Mode (Session);
      Check (not Client.In_Pipeline_Mode (Session));

      --  Real COPY interoperability. Each Receive_Copy_Event owns exactly one
      --  backend frame, so the session never collects the stream.
      Client.Send_Query
        (Session,
         "create temporary table flyology_copy_test "
         & "(left_value text, right_value text); "
         & "create temporary table flyology_copy_int (value integer); "
         & "create temporary table flyology_copy_cancel as "
         & "select n from generate_series(1, 1000000) n",
         Timeout => 5.0);
      loop
         declare
            Event : constant Client.Simple_Query_Event :=
              Client.Receive_Query_Event (Session, Timeout => 5.0);
         begin
            Check
              (Protocol.Response_Kind (Event) /= Protocol.Error_Response);
            exit when Protocol.Response_Kind (Event) =
              Protocol.Ready_For_Query_Response;
         end;
      end loop;

      Client.Send_Query
        (Session,
         "copy flyology_copy_test from stdin (format text)",
         Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         Formats : constant Protocol.Copy_Format_Description :=
           Protocol.Copy_Formats (Started);
      begin
         Check
           (Protocol.Response_Kind (Started) = Protocol.Copy_In_Response
            and then Protocol.Overall_Format (Formats) =
              Protocol.Text_Format
            and then Protocol.Copy_Column_Count (Formats) = 2);
      end;
      Client.Send_Copy_Data
        (Session,
         Bytes ("alpha" & ASCII.HT & ASCII.LF),
         Timeout => 5.0);
      Client.Send_Copy_Data
        (Session,
         Bytes ("\N" & ASCII.HT & "omega" & ASCII.LF),
         Timeout => 5.0);
      Client.Finish_Copy (Session, Timeout => 5.0);
      declare
         Completed : constant Client.Copy_Event :=
           Client.Receive_Copy_Event (Session, Timeout => 5.0);
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
      begin
         Check
           (Protocol.Response_Kind (Completed) =
              Protocol.Command_Complete_Response
            and then Protocol.Completion_Tag (Completed) = "COPY 2"
            and then Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response);
      end;

      Client.Send_Query
        (Session,
         "copy flyology_copy_test to stdout (format text)",
         Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         Chunks  : Natural := 0;
         Bytes   : Flyology.Bytes.Unbounded_Bytes;
      begin
         Check
           (Protocol.Response_Kind (Started) = Protocol.Copy_Out_Response);
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) =
                 Protocol.Copy_Data_Response
               then
                  Chunks := Chunks + 1;
                  Flyology.Bytes.Append (Bytes, Protocol.Copy_Data (Event));
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Command_Complete_Response;
            end;
         end loop;
         Check
           (Chunks >= 2
            and then Flyology.Bytes.To_Byte_String (Bytes) =
              "alpha" & ASCII.HT & ASCII.LF
              & "\N" & ASCII.HT & "omega" & ASCII.LF);
      end;
      declare
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
      begin
         Check
           (Protocol.Response_Kind (Ready_Event) =
              Protocol.Ready_For_Query_Response);
      end;

      Client.Send_Query
        (Session,
         "copy flyology_copy_test to stdout (format binary)",
         Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         Formats : constant Protocol.Copy_Format_Description :=
           Protocol.Copy_Formats (Started);
         Chunks : Natural := 0;
         Saw_Signature : Boolean := False;
      begin
         Check
           (Protocol.Overall_Format (Formats) = Protocol.Binary_Format
            and then Protocol.Copy_Column_Format (Formats, 1) =
              Protocol.Binary_Format);
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) =
                 Protocol.Copy_Data_Response
               then
                  Chunks := Chunks + 1;
                  declare
                     Data : constant Protocol.Byte_Array :=
                       Protocol.Copy_Data (Event);
                  begin
                     Saw_Signature := Saw_Signature or else
                       (Data'Length >= 11
                        and then Character'Val (Data (Data'First)) = 'P'
                        and then Character'Val
                          (Data (Data'First + Protocol.Byte_Offset (1))) =
                            'G');
                  end;
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Command_Complete_Response;
            end;
         end loop;
         Check (Chunks >= 2 and then Saw_Signature);
      end;
      declare
         Ready_Event : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         pragma Unreferenced (Ready_Event);
      begin
         null;
      end;

      Client.Prepare_Statement
        (Session,
         "copy_out_extended",
         "copy flyology_copy_test to stdout (format text)",
         Timeout => 5.0);
      Client.Bind_Portal
        (Session, "copy_out_portal", "copy_out_extended", Timeout => 5.0);
      Client.Execute_Portal
        (Session, "copy_out_portal", Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);
      loop
         declare
            Event : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Session, Timeout => 5.0);
         begin
            exit when Protocol.Response_Kind (Event) =
              Protocol.Copy_Out_Response;
            Check
              (Protocol.Response_Kind (Event) /= Protocol.Error_Response);
         end;
      end loop;
      declare
         Chunks : Natural := 0;
      begin
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) =
                 Protocol.Copy_Data_Response
               then
                  Chunks := Chunks + 1;
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Chunks >= 2 and then Client.Is_Ready (Session));
      end;

      Client.Prepare_Statement
        (Session,
         "copy_in_extended",
         "copy flyology_copy_test from stdin (format text)",
         Timeout => 5.0);
      Client.Bind_Portal
        (Session, "copy_in_portal", "copy_in_extended", Timeout => 5.0);
      Client.Execute_Portal
        (Session, "copy_in_portal", Timeout => 5.0);
      Client.Flush (Session, Timeout => 5.0);
      loop
         declare
            Event : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Session, Timeout => 5.0);
         begin
            exit when Protocol.Response_Kind (Event) =
              Protocol.Copy_In_Response;
            Check
              (Protocol.Response_Kind (Event) /= Protocol.Error_Response);
         end;
      end loop;
      Client.Send_Copy_Data
        (Session, Bytes ("extended" & ASCII.HT & ASCII.LF), 5.0);
      Client.Finish_Copy (Session, Timeout => 5.0);
      Client.Synchronize (Session, Timeout => 5.0);
      loop
         declare
            Event : constant Client.Copy_Event :=
              Client.Receive_Copy_Event (Session, Timeout => 5.0);
         begin
            Check
              (Protocol.Response_Kind (Event) /= Protocol.Error_Response);
            exit when Protocol.Response_Kind (Event) =
              Protocol.Ready_For_Query_Response;
         end;
      end loop;
      Check (Client.Is_Ready (Session));

      Client.Send_Query
        (Session,
         "copy flyology_copy_test from stdin",
         Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         pragma Unreferenced (Started);
      begin
         Client.Abort_Copy (Session, "integration abort", Timeout => 5.0);
      end;
      declare
         Saw_Abort_Error : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               Saw_Abort_Error := Saw_Abort_Error or else
                 Protocol.Response_Kind (Event) = Protocol.Error_Response;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Abort_Error and then Client.Is_Ready (Session));
      end;

      Client.Send_Query
        (Session, "copy flyology_copy_int from stdin", Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         pragma Unreferenced (Started);
      begin
         Client.Send_Copy_Data
           (Session,
            Bytes ("not-an-integer" & ASCII.LF),
            Timeout => 5.0);
         Client.Finish_Copy (Session, Timeout => 5.0);
      end;
      declare
         Saw_Data_Error : Boolean := False;
      begin
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               Saw_Data_Error := Saw_Data_Error or else
                 (Protocol.Response_Kind (Event) = Protocol.Error_Response
                  and then Protocol.Diagnostic_SQL_State
                    (Protocol.Diagnostic_Data (Event)) = "22P02");
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Data_Error and then Client.Is_Ready (Session));
      end;

      Client.Send_Query
        (Session,
         "copy flyology_copy_cancel to stdout",
         Timeout => 5.0);
      declare
         Started : constant Client.Simple_Query_Event :=
           Client.Receive_Query_Event (Session, Timeout => 5.0);
         pragma Unreferenced (Started);
         Saw_Copy_Cancellation : Boolean := False;
      begin
         --  The source is populated before COPY so the response is not held
         --  behind set-returning-function startup. Its million rows exceed
         --  socket buffering, keeping COPY active after this first frame.
         --  One-frame calls give the application an explicit cancellation and
         --  fairness point.
         declare
            First : constant Client.Copy_Event :=
              Client.Receive_Copy_Event (Session, Timeout => 5.0);
         begin
            Check
              (Protocol.Response_Kind (First) =
                 Protocol.Copy_Data_Response);
         end;
         Client_Sockets.Cancel_TLS
           (Session, Server, Backend, Server_Name, Timeout => 5.0);
         loop
            declare
               Event : constant Client.Copy_Event :=
                 Client.Receive_Copy_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Saw_Copy_Cancellation := Protocol.Diagnostic_SQL_State
                    (Protocol.Diagnostic_Data (Event)) = "57014";
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         Check (Saw_Copy_Cancellation and then Client.Is_Ready (Session));
      end;

      Client.Send_Query (Session, "select pg_sleep(30)", Timeout => 5.0);
      declare
         task Canceller is
            pragma Task_Info (Flyology.Lightweight_Task);
         end Canceller;

         task body Canceller is
         begin
            delay 0.1;
            Client_Sockets.Cancel_TLS
              (Session, Server, Backend, Server_Name, Timeout => 5.0);
         end Canceller;
      begin
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 5.0);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Error_Response
               then
                  Saw_Cancellation := Protocol.Diagnostic_SQL_State
                    (Protocol.Diagnostic_Data (Event)) = "57014";
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
      end;
      Check (Saw_Cancellation);

      --  Exercise the public set-independent connection capability after a
      --  synchronous same-connection PostgreSQL TLS negotiation.  The query
      --  and every result frame are scoped operations over upgraded TLS.
      declare
         Manager : aliased Connections.Server (Capacity => 1);
         Scoped_Socket : aliased Sockets.Socket_Type;
         Connection : aliased Connections.Connection (Manager'Access);
         Scoped_Channel : aliased
           Connection_Transports.Connection_Transport
             (Connection'Access, null);
         Scoped_Session : aliased Client.Session (Scoped_Channel'Access);
         Set : aliased Operations.Completion_Set (Capacity => 2);
         Event : Protocol.Backend_Message;
         Rows  : Natural := 0;
      begin
         Sockets.Create_Socket (Scoped_Socket);
         Sockets.Connect (Scoped_Socket, Server, Timeout => 5.0);
         Connections.Take (Manager, Scoped_Socket, Connection);
         Client.Startup_TLS
           (Scoped_Session,
            Backend,
            Server_Name => Server_Name,
            User        => "flyology",
            Database    => "postgres",
            Password    => "flyology-secret",
            Timeout     => 5.0);
         declare
            Send : Client.Send_Operation :=
              Client.Send_Query
                (Set'Access,
                 Scoped_Session'Access,
                 "select n from generate_series(1, 3) n order by n",
                 Timeout => 5.0);
            Receive : Client.Receive_Operation (Set'Access);
         begin
            Operations.Wait_All (Set);
            Client.Finish (Send);
            loop
               Client.Receive_Query_Event
                 (Scoped_Session'Access,
                  Timeout   => 5.0,
                  Operation => Receive);
               Operations.Wait_All (Set);
               Client.Finish (Receive, Event);
               if Protocol.Response_Kind (Event) =
                 Protocol.Data_Row_Response
               then
                  Rows := Rows + 1;
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end loop;
         end;
         Check (Rows = 3 and then Client.Is_Ready (Scoped_Session));
         Client.Send_Command
           (Scoped_Session,
            Protocol.Make_Empty_Message ('X'),
            Timeout => 5.0);
         Connections.Close (Connection);
      end;

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
      if All_Good then
         Result.Pass;
      else
         Result.Fail;
      end if;
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            Ada.Exceptions.Exception_Information (Error));
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
           "Postgres typed-query or cancellation interoperability failed";
      end if;
   end;
   Ada.Text_IO.Put_Line ("Flyology Postgres client integration passed");
end Postgres_Test_Client;
