with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;

procedure Postgres_Test_Client is

   package Client renames Flyology.Postgres.Client;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Protocol.Backend_Message_Kind;
   use type Protocol.Transaction_Status;

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
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      All_Good : Boolean := True;

      procedure Check (Condition : Boolean) is
      begin
         All_Good := All_Good and Condition;
      end Check;
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect
        (Socket,
         Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port),
         Timeout => 5.0);
      Client.Startup
        (Session,
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

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout => 5.0);
      Sockets.Close_Socket (Socket);
      if All_Good then
         Result.Pass;
      else
         Result.Fail;
      end if;
   exception
      when others =>
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
           "lightweight Postgres typed simple-query integration failed";
      end if;
   end;
   Ada.Text_IO.Put_Line ("Flyology Postgres client integration passed");
end Postgres_Test_Client;
