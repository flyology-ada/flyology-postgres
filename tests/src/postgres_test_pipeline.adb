with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;

procedure Postgres_Test_Pipeline is
   --  Exercise pipelined extended-query batches against a real PostgreSQL
   --  server. Every scenario writes whole Sync-terminated batches before it
   --  reads, which is the property that separates pipelining from the
   --  ordinary one-batch-at-a-time extended path.

   package Client renames Flyology.Postgres.Client;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Protocol.Backend_Message_Kind;
   use type Protocol.Transaction_Status;
   use type Client.Operation_State;

   Timeout : constant Duration := 15.0;

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value ("POSTGRES_TEST_PORT", "55433")));

   function Label return String is
     (Ada.Environment_Variables.Value ("POSTGRES_TEST_LABEL", "postgres"));

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

   task Worker is
      pragma Task_Info (Flyology.Lightweight_Task);
   end Worker;

   task body Worker is
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      Failures : Natural := 0;
      Server : constant Sockets.Endpoint :=
        Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port);

      procedure Check (Condition : Boolean; Message : String) is
      begin
         if not Condition then
            Failures := Failures + 1;
            Ada.Text_IO.Put_Line
              (Ada.Text_IO.Standard_Error,
               Label & " pipeline check failed: " & Message);
         end if;
      end Check;

      ------------------------------------------------------------------
      --  One consumed batch, summarized.
      ------------------------------------------------------------------

      type Batch_Result is record
         Rows       : Natural := 0;
         Errors     : Natural := 0;
         Notices    : Natural := 0;
         Parses     : Natural := 0;
         Binds      : Natural := 0;
         Closes     : Natural := 0;
         Suspends   : Natural := 0;
         Completes  : Natural := 0;
         Empties    : Natural := 0;
         Described  : Natural := 0;
         No_Data    : Natural := 0;
         Parameters : Natural := 0;
         First_Text : String (1 .. 64) := (others => ' ');
         First_Size : Natural := 0;
         Last_State : Protocol.Transaction_Status :=
           Protocol.Idle;
         Error_Code : String (1 .. 5) := "     ";
      end record;

      function Consume_Batch return Batch_Result is
         --  Read exactly one batch: everything up to and including its
         --  ReadyForQuery. Pipelining guarantees the batches arrive in the
         --  order they were written, so one call retires the oldest.
         Summary : Batch_Result;
      begin
         loop
            declare
               Event : constant Client.Extended_Query_Event :=
                 Client.Receive_Extended_Event (Session, Timeout);
               Kind  : constant Protocol.Backend_Message_Kind :=
                 Protocol.Response_Kind (Event);
            begin
               case Kind is
                  when Protocol.Data_Row_Response =>
                     Summary.Rows := Summary.Rows + 1;
                     if Summary.First_Size = 0 then
                        declare
                           Text : constant String :=
                             Protocol.Column_Text
                               (Protocol.Column_At
                                  (Protocol.Row_Data (Event), 1));
                        begin
                           if Text'Length <= Summary.First_Text'Length then
                              Summary.First_Size := Text'Length;
                              Summary.First_Text (1 .. Text'Length) := Text;
                           else
                              Summary.First_Size := Text'Length;
                           end if;
                        end;
                     end if;
                  when Protocol.Error_Response =>
                     Summary.Errors := Summary.Errors + 1;
                     declare
                        Code : constant String :=
                          Protocol.Diagnostic_SQL_State
                            (Protocol.Diagnostic_Data (Event));
                     begin
                        if Code'Length = 5 then
                           Summary.Error_Code := Code;
                        end if;
                     end;
                  when Protocol.Notice_Response =>
                     Summary.Notices := Summary.Notices + 1;
                  when Protocol.Parse_Complete_Response =>
                     Summary.Parses := Summary.Parses + 1;
                  when Protocol.Bind_Complete_Response =>
                     Summary.Binds := Summary.Binds + 1;
                  when Protocol.Close_Complete_Response =>
                     Summary.Closes := Summary.Closes + 1;
                  when Protocol.Portal_Suspended_Response =>
                     Summary.Suspends := Summary.Suspends + 1;
                  when Protocol.Command_Complete_Response =>
                     Summary.Completes := Summary.Completes + 1;
                  when Protocol.Empty_Query_Response =>
                     Summary.Empties := Summary.Empties + 1;
                  when Protocol.Row_Description_Response =>
                     Summary.Described := Summary.Described + 1;
                  when Protocol.No_Data_Response =>
                     Summary.No_Data := Summary.No_Data + 1;
                  when Protocol.Parameter_Description_Response =>
                     Summary.Parameters := Summary.Parameters + 1;
                  when Protocol.Ready_For_Query_Response =>
                     Summary.Last_State :=
                       Protocol.Transaction_State (Event);
                     return Summary;
                  when others =>
                     null;
               end case;
            end;
         end loop;
      end Consume_Batch;

      function First_Text (Item : Batch_Result) return String is
        (if Item.First_Size = 0
           or else Item.First_Size > Item.First_Text'Length
         then ""
         else Item.First_Text (1 .. Item.First_Size));

      ------------------------------------------------------------------
      --  Batch writers.
      ------------------------------------------------------------------

      procedure Write_Value_Batch (Name : String; SQL : String) is
         --  One self-contained row-returning batch.
      begin
         Client.Prepare_Statement (Session, Name, SQL, Timeout => Timeout);
         Client.Bind_Portal (Session, Name, Name, Timeout => Timeout);
         Client.Describe_Portal (Session, Name, Timeout => Timeout);
         Client.Execute_Portal (Session, Name, Timeout => Timeout);
         Client.Close_Portal (Session, Name, Timeout => Timeout);
         Client.Close_Statement (Session, Name, Timeout => Timeout);
         Client.Synchronize (Session, Timeout => Timeout);
      end Write_Value_Batch;

      procedure Write_Simple_Batch (SQL : String) is
         --  A command-only batch on the unnamed statement and portal.
      begin
         Client.Prepare_Statement (Session, "", SQL, Timeout => Timeout);
         Client.Bind_Portal (Session, "", "", Timeout => Timeout);
         Client.Execute_Portal (Session, "", Timeout => Timeout);
         Client.Synchronize (Session, Timeout => Timeout);
      end Write_Simple_Batch;

      procedure Run_Simple (SQL : String) is
         --  Run one statement outside pipeline mode and drain it.
      begin
         Client.Send_Query (Session, SQL, Timeout);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout);
            begin
               Check
                 (Protocol.Response_Kind (Event) /= Protocol.Error_Response,
                  "setup statement failed: " & SQL);
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
      end Run_Simple;

      function Simple_Count (SQL : String) return Natural is
         --  Read one integer through the simple-query path.
         Counted : Natural := 0;
      begin
         Client.Send_Query (Session, SQL, Timeout);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout);
            begin
               if Protocol.Response_Kind (Event) = Protocol.Data_Row_Response
               then
                  Counted := Natural'Value
                    (Protocol.Column_Text
                       (Protocol.Column_At (Protocol.Row_Data (Event), 1)));
               end if;
               exit when Protocol.Response_Kind (Event) =
                 Protocol.Ready_For_Query_Response;
            end;
         end loop;
         return Counted;
      end Simple_Count;

      function Rejected (Action : not null access procedure) return Boolean is
      begin
         Action.all;
         return False;
      exception
         when Program_Error =>
            return True;
      end Rejected;

      procedure Invalid_Query is
      begin
         Client.Send_Query (Session, "select 1", Timeout);
      end Invalid_Query;

      procedure Invalid_Exit is
      begin
         Client.Exit_Pipeline_Mode (Session);
      end Invalid_Exit;

      procedure Invalid_Resume is
      begin
         Client.Resume_Portal (Session, "series", Timeout => Timeout);
      end Invalid_Resume;

      Depth : constant := 64;
      --  Deep enough that the server's output for the earlier batches is
      --  already queued while the later ones are still being written.
   begin
      Sockets.Create_Socket (Socket);
      Sockets.Connect (Socket, Server, Timeout);
      Client.Startup
        (Session,
         User             => "flyology",
         Database         => "postgres",
         Application_Name => "flyology_pipeline_tests",
         Timeout          => Timeout);
      Check (Client.Is_Ready (Session), "startup did not reach Ready");
      Check
        (not Client.In_Pipeline_Mode (Session),
         "a new session must not start in pipeline mode");

      Run_Simple
        ("create temporary table pipeline_rows "
         & "(id integer primary key, value text)");

      ------------------------------------------------------------------
      --  1. A deep pipeline: every batch is written before the first read.
      ------------------------------------------------------------------
      Client.Enter_Pipeline_Mode (Session);
      Client.Prepare_Statement
        (Session,
         Statement_Name  => "insert_row",
         SQL             => "insert into pipeline_rows (id, value) "
                            & "values ($1::int4, $2::text)",
         Parameter_Types => (23, 25),
         Timeout         => Timeout);
      for Index in 1 .. Depth loop
         Client.Bind_Portal
           (Session,
            Portal_Name    => "",
            Statement_Name => "insert_row",
            Parameters     =>
              (Protocol.Text_Parameter (Index'Image (2 .. Index'Image'Last)),
               Protocol.Text_Parameter ("row" & Index'Image)),
            Timeout        => Timeout);
         Client.Execute_Portal (Session, "", Timeout => Timeout);
         Client.Synchronize (Session, Timeout => Timeout);
      end loop;
      Check
        (Client.Pending_Synchronizations (Session) = Depth,
         "a deep pipeline must account for every written batch");
      Check
        (Rejected (Invalid_Exit'Access),
         "pipeline mode must not end with batches outstanding");
      Check
        (Rejected (Invalid_Query'Access),
         "a simple query must be rejected in pipeline mode");

      declare
         Completed : Natural := 0;
         Inserted  : Natural := 0;
      begin
         while Client.Pending_Synchronizations (Session) > 0 loop
            declare
               Batch : constant Batch_Result := Consume_Batch;
            begin
               Completed := Completed + 1;
               Inserted := Inserted + Batch.Completes;
               Check (Batch.Errors = 0, "a deep pipeline batch failed");
               Check
                 (Client.Pending_Synchronizations (Session) =
                    Depth - Completed,
                  "each ReadyForQuery must retire exactly one batch");
            end;
         end loop;
         --  The first batch also carries the shared Parse.
         Check (Completed = Depth, "every pipelined batch must complete");
         Check (Inserted = Depth, "every pipelined insert must complete");
      end;
      Check (Client.Is_Ready (Session), "a drained pipeline returns to Ready");

      ------------------------------------------------------------------
      --  2. Interleaved writing and reading, the anti-deadlock pattern.
      ------------------------------------------------------------------
      for Index in 1 .. 16 loop
         Write_Value_Batch
           ("interleaved" & Index'Image (2 .. Index'Image'Last),
            "select" & Index'Image & "::int4");
         if Index mod 4 = 0 then
            --  Drain half of what is outstanding while more is still to be
            --  written, so neither peer's socket buffer has to hold it all.
            for Drain in 1 .. 2 loop
               declare
                  Batch : constant Batch_Result := Consume_Batch;
               begin
                  Check (Batch.Errors = 0, "an interleaved batch failed");
                  Check (Batch.Rows = 1, "an interleaved batch lost its row");
               end;
            end loop;
         end if;
      end loop;
      declare
         Remaining : constant Natural :=
           Client.Pending_Synchronizations (Session);
      begin
         Check (Remaining = 8, "interleaving must leave half outstanding");
         for Drain in 1 .. Remaining loop
            declare
               Batch : constant Batch_Result := Consume_Batch;
            begin
               Check (Batch.Errors = 0, "a trailing batch failed");
               Check (Batch.Closes = 2, "both closes must be acknowledged");
            end;
         end loop;
      end;
      Check (Client.Is_Ready (Session), "interleaving must drain completely");

      ------------------------------------------------------------------
      --  3. Failures at several positions, each contained by its own Sync.
      ------------------------------------------------------------------
      Write_Value_Batch ("ok_one", "select 'one'::text");
      Write_Simple_Batch ("select flyology_missing_function()");
      Write_Value_Batch ("ok_two", "select 'two'::text");
      Write_Simple_Batch ("select flyology_missing_function()");
      Write_Simple_Batch ("select flyology_missing_function()");
      Write_Value_Batch ("ok_three", "select 'three'::text");
      Check
        (Client.Pending_Synchronizations (Session) = 6,
         "six mixed batches must be outstanding");
      declare
         type Expectation is (Succeeds, Fails);
         Plan : constant array (1 .. 6) of Expectation :=
           (Succeeds, Fails, Succeeds, Fails, Fails, Succeeds);
         function Expected_Text (Index : Positive) return String is
           (case Index is
               when 1 => "one",
               when 3 => "two",
               when 6 => "three",
               when others => "");
      begin
         for Index in Plan'Range loop
            declare
               Batch : constant Batch_Result := Consume_Batch;
            begin
               case Plan (Index) is
                  when Succeeds =>
                     Check
                       (Batch.Errors = 0 and then Batch.Rows = 1
                        and then First_Text (Batch) = Expected_Text (Index),
                        "a good batch must survive its failing neighbours");
                  when Fails =>
                     Check
                       (Batch.Errors = 1 and then Batch.Rows = 0,
                        "a failing batch must report exactly one error");
                     Check
                       (Batch.Error_Code = "42883",
                        "an undefined function must report SQLSTATE 42883");
               end case;
               Check
                 (Batch.Last_State = Protocol.Idle,
                  "an implicit transaction must end idle");
               Check
                 (Client.State (Session) /= Client.Recovery_Required,
                  "a synchronized failure must not require recovery");
            end;
         end loop;
      end;
      Check (Client.Is_Ready (Session), "mixed failures must drain to Ready");

      ------------------------------------------------------------------
      --  4. An explicit transaction poisoned mid-pipeline.
      ------------------------------------------------------------------
      Write_Simple_Batch ("begin");
      Write_Simple_Batch
        ("insert into pipeline_rows (id, value) values (1001, 'in_tx')");
      Write_Simple_Batch ("select flyology_missing_function()");
      Write_Simple_Batch
        ("insert into pipeline_rows (id, value) values (1002, 'after')");
      Write_Simple_Batch ("rollback");
      declare
         Expected : constant array (1 .. 5) of Protocol.Transaction_Status :=
           (Protocol.In_Transaction,
            Protocol.In_Transaction,
            Protocol.Failed_Transaction,
            Protocol.Failed_Transaction,
            Protocol.Idle);
      begin
         for Index in Expected'Range loop
            declare
               Batch : constant Batch_Result := Consume_Batch;
            begin
               Check
                 (Batch.Last_State = Expected (Index),
                  "batch" & Index'Image
                  & " reported the wrong transaction status");
               if Index = 3 then
                  Check
                    (Batch.Errors = 1 and then Batch.Error_Code = "42883",
                     "the poisoning batch must carry its own error");
               elsif Index = 4 then
                  Check
                    (Batch.Errors = 1 and then Batch.Error_Code = "25P02",
                     "a batch behind the failure must report 25P02");
               else
                  Check (Batch.Errors = 0, "a control batch must succeed");
               end if;
            end;
         end loop;
      end;

      ------------------------------------------------------------------
      --  5. Portal suspension inside a pipelined batch.
      ------------------------------------------------------------------
      Client.Prepare_Statement
        (Session,
         Statement_Name => "series",
         SQL            => "select n::int4 from generate_series(1, 5) n",
         Timeout        => Timeout);
      Client.Bind_Portal (Session, "series", "series", Timeout => Timeout);
      Client.Describe_Portal (Session, "series", Timeout => Timeout);
      Client.Execute_Portal
        (Session, "series", Maximum_Rows => 2, Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);
      Write_Value_Batch ("behind_suspend", "select 'behind'::text");
      declare
         Suspended : constant Batch_Result := Consume_Batch;
         Behind    : constant Batch_Result := Consume_Batch;
      begin
         Check
           (Suspended.Rows = 2 and then Suspended.Suspends = 1
            and then Suspended.Completes = 0,
            "a row-limited pipelined Execute must suspend its portal");
         Check
           (Behind.Rows = 1 and then First_Text (Behind) = "behind",
            "a suspended batch must not disturb the batch behind it");
      end;
      Check
        (Rejected (Invalid_Resume'Access),
         "Sync ends the batch, so its suspended portal cannot be resumed");

      ------------------------------------------------------------------
      --  6. Statement description, empty queries, and closed statements.
      ------------------------------------------------------------------
      Client.Prepare_Statement
        (Session,
         Statement_Name  => "described",
         SQL             => "select $1::int4 as only_column",
         Parameter_Types => (1 => 23),
         Timeout         => Timeout);
      Client.Describe_Statement (Session, "described", Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);

      Client.Prepare_Statement (Session, "empty", "", Timeout => Timeout);
      Client.Bind_Portal (Session, "empty", "empty", Timeout => Timeout);
      Client.Describe_Portal (Session, "empty", Timeout => Timeout);
      Client.Execute_Portal (Session, "empty", Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);

      Client.Close_Statement (Session, "described", Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);

      Client.Bind_Portal
        (Session,
         Portal_Name    => "gone",
         Statement_Name => "described",
         Parameters     => (1 => Protocol.Text_Parameter ("7")),
         Timeout        => Timeout);
      Client.Execute_Portal (Session, "gone", Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);

      declare
         Described : constant Batch_Result := Consume_Batch;
         Empty     : constant Batch_Result := Consume_Batch;
         Closed    : constant Batch_Result := Consume_Batch;
         Missing   : constant Batch_Result := Consume_Batch;
      begin
         Check
           (Described.Parameters = 1 and then Described.Described = 1
            and then Described.Errors = 0,
            "Describe on a statement must return parameters and columns");
         Check
           (Empty.Empties = 1 and then Empty.No_Data = 1
            and then Empty.Errors = 0,
            "an empty pipelined query must report EmptyQueryResponse");
         Check
           (Closed.Closes = 1 and then Closed.Errors = 0,
            "a pipelined Close must be acknowledged");
         Check
           (Missing.Errors = 1 and then Missing.Error_Code = "26000",
            "binding a closed statement must report SQLSTATE 26000");
      end;

      ------------------------------------------------------------------
      --  7. Multi-statement text is rejected inside its own batch.
      ------------------------------------------------------------------
      Write_Simple_Batch ("select 1; select 2");
      Write_Value_Batch ("after_multi", "select 'after'::text");
      declare
         Multi : constant Batch_Result := Consume_Batch;
         After : constant Batch_Result := Consume_Batch;
      begin
         Check
           (Multi.Errors = 1,
            "multi-statement Parse must fail inside its own batch");
         Check
           (After.Errors = 0 and then First_Text (After) = "after",
            "the batch behind a rejected Parse must still run");
      end;

      ------------------------------------------------------------------
      --  8. A batch left open while an earlier batch is drained.
      ------------------------------------------------------------------
      Write_Value_Batch ("closed_first", "select 'first'::text");
      Client.Prepare_Statement
        (Session, "still_open", "select 'open'::text", Timeout => Timeout);
      Client.Bind_Portal
        (Session, "still_open", "still_open", Timeout => Timeout);
      Check
        (Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 1,
         "an open batch must coexist with an outstanding earlier batch");
      declare
         Earlier : constant Batch_Result := Consume_Batch;
      begin
         Check (Earlier.Errors = 0, "the earlier batch must still succeed");
      end;
      Check
        (Client.State (Session) = Client.Extended_Query_Active
         and then Client.Pending_Synchronizations (Session) = 0,
         "retiring an earlier batch must leave the open batch open");
      Client.Describe_Portal (Session, "still_open", Timeout => Timeout);
      Client.Execute_Portal (Session, "still_open", Timeout => Timeout);
      Client.Synchronize (Session, Timeout => Timeout);
      declare
         Opened : constant Batch_Result := Consume_Batch;
      begin
         Check
           (Opened.Rows = 1 and then First_Text (Opened) = "open",
            "an open batch must complete through its own Sync");
      end;

      ------------------------------------------------------------------
      --  9. An unsynchronized failure still requires recovery.
      ------------------------------------------------------------------
      Client.Prepare_Statement
        (Session, "unsynced", "select flyology_missing_function()",
         Timeout => Timeout);
      Client.Flush (Session, Timeout => Timeout);
      declare
         Event : constant Client.Extended_Query_Event :=
           Client.Receive_Extended_Event (Session, Timeout);
      begin
         Check
           (Protocol.Response_Kind (Event) = Protocol.Error_Response
            and then Client.State (Session) = Client.Recovery_Required
            and then Client.Pending_Synchronizations (Session) = 0,
            "a flushed failure with no Sync must require recovery");
      end;
      Client.Synchronize (Session, Timeout => Timeout);
      declare
         Recovered : constant Batch_Result := Consume_Batch;
      begin
         Check
           (Recovered.Errors = 0,
            "recovery must not report the error a second time");
      end;
      Check (Client.Is_Ready (Session), "recovery must restore Ready");

      ------------------------------------------------------------------
      --  10. Large parameters, written and read in step.
      ------------------------------------------------------------------
      declare
         Bulk : constant String (1 .. 48_000) := (others => 'x');
      begin
         Client.Prepare_Statement
           (Session,
            Statement_Name  => "bulk",
            SQL             => "select length($1::text)::int4",
            Parameter_Types => (1 => 25),
            Timeout         => Timeout);
         Client.Synchronize (Session, Timeout => Timeout);
         declare
            Prepared : constant Batch_Result := Consume_Batch;
         begin
            Check (Prepared.Errors = 0, "the bulk statement must prepare");
         end;

         for Index in 1 .. 12 loop
            Client.Bind_Portal
              (Session,
               Portal_Name    => "",
               Statement_Name => "bulk",
               Parameters     => (1 => Protocol.Text_Parameter (Bulk)),
               Timeout        => Timeout);
            Client.Describe_Portal (Session, "", Timeout => Timeout);
            Client.Execute_Portal (Session, "", Timeout => Timeout);
            Client.Synchronize (Session, Timeout => Timeout);
            if Index mod 3 = 0 then
               declare
                  Batch : constant Batch_Result := Consume_Batch;
               begin
                  Check
                    (Batch.Errors = 0
                     and then First_Text (Batch) = Bulk'Length'Image
                       (2 .. Bulk'Length'Image'Last),
                     "a bulk batch must round-trip its parameter length");
               end;
            end if;
         end loop;
         while Client.Pending_Synchronizations (Session) > 0 loop
            declare
               Batch : constant Batch_Result := Consume_Batch;
            begin
               Check (Batch.Errors = 0, "a trailing bulk batch failed");
            end;
         end loop;
      end;

      ------------------------------------------------------------------
      --  11. Leaving and re-entering the mode.
      ------------------------------------------------------------------
      Client.Exit_Pipeline_Mode (Session);
      Check
        (not Client.In_Pipeline_Mode (Session) and then Client.Is_Ready
           (Session),
         "pipeline mode must end once every batch is consumed");
      Run_Simple ("select 1");
      Client.Enter_Pipeline_Mode (Session);
      Write_Value_Batch ("reentered", "select 'again'::text");
      declare
         Again : constant Batch_Result := Consume_Batch;
      begin
         Check
           (First_Text (Again) = "again",
            "pipeline mode must work again after being re-entered");
      end;
      Client.Exit_Pipeline_Mode (Session);

      ------------------------------------------------------------------
      --  12. Everything the deep pipeline claimed to insert is present.
      ------------------------------------------------------------------
      Check
        (Simple_Count
           ("select count(*)::int4 from pipeline_rows where id <="
            & Depth'Image) = Depth,
         "the deep pipeline must have committed every row");
      Check
        (Simple_Count
           ("select count(*)::int4 from pipeline_rows "
            & "where id in (1001, 1002)") = 0,
         "the rolled-back pipelined transaction must leave nothing behind");

      Client.Send_Command
        (Session, Protocol.Make_Empty_Message ('X'), Timeout);
      Sockets.Close_Socket (Socket);

      if Failures = 0 then
         Result.Pass;
      else
         Result.Fail;
      end if;
   exception
      when Occurrence : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            Label & " pipeline test raised: "
            & Ada.Exceptions.Exception_Information (Occurrence));
         Result.Fail;
   end Worker;

   Succeeded : Boolean;
begin
   Result.Await (Succeeded);
   if not Succeeded then
      raise Program_Error with "Postgres pipelined query interoperability "
        & "failed against " & Label;
   end if;
   Ada.Text_IO.Put_Line
     (Label & " pipelined extended-query integration passed");
end Postgres_Test_Pipeline;
