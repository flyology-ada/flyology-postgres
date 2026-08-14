with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.Postgres.Client;
with Flyology.Postgres.Client_Sockets;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Transports.Sockets;
with Psqlbench_JSON;

package body Psqlbench_Query is

   package Client renames Flyology.Postgres.Client;
   package Client_Sockets renames Flyology.Postgres.Client_Sockets;
   package Protocol renames Flyology.Postgres.Protocol;
   package Sockets renames Flyology.IO.Sockets;
   package Transports renames Flyology.Postgres.Transports.Sockets;

   use type Ada.Real_Time.Time;
   use type Protocol.Backend_Message_Kind;
   use type Protocol.UInt32;
   use type Psqlbench_Context.Event_Sequence;

   type Type_Name_Array is array (Positive range <>) of Unbounded_String;

   function Compact (Value : Protocol.UInt32) return String is
     (Ada.Strings.Fixed.Trim
        (Protocol.UInt32'Image (Value), Ada.Strings.Both));

   function Output_Truncated_Document return String is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value
        (Document, "type", "query.output-truncated");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Output_Truncated_Document;

   protected body Event_Stream is
      procedure Append (Value : String) is
         Slot : Positive;
         Stored : constant String :=
           (if Value'Length <= Max_Query_Event_Bytes
            then Value
            else Output_Truncated_Document);
      begin
         if Count = Query_Event_Capacity then
            Slot := Head;
            Head := (if Head = Query_Event_Capacity then 1 else Head + 1);
         else
            Slot := ((Head - 1 + Count) mod Query_Event_Capacity) + 1;
            Count := Count + 1;
         end if;
         Events (Slot) := (others => <>);
         Events (Slot).Sequence := Next_Sequence;
         Events (Slot).Data := To_Unbounded_String (Stored);
         Next_Sequence := Next_Sequence + 1;
      end Append;

      procedure Finish is
      begin
         Finished := True;
      end Finish;

      function Done return Boolean is (Finished);

      procedure Read_After
        (After     : Psqlbench_Context.Event_Sequence;
         Value     : out Query_Event;
         Available : out Boolean;
         Dropped   : out Psqlbench_Context.Event_Sequence)
      is
         Slot : Positive;
      begin
         Value := (others => <>);
         Available := False;
         Dropped := 0;
         if Count = 0 then
            return;
         end if;
         for Offset in 0 .. Count - 1 loop
            Slot := ((Head - 1 + Offset) mod Query_Event_Capacity) + 1;
            if Events (Slot).Sequence > After then
               Value := Events (Slot);
               Available := True;
               Dropped := Events (Slot).Sequence - After - 1;
               return;
            end if;
         end loop;
      end Read_After;
   end Event_Stream;

   protected body Query_Control is
      procedure Request_Cancel is
      begin
         Is_Cancelled := True;
      end Request_Cancel;

      function Cancel_Requested return Boolean is (Is_Cancelled);

      procedure Request_Page (Request_Id : Natural) is
      begin
         if Request_Id = 0 or else Request_Id > Last_Page_Request then
            if Request_Id > 0 then
               Last_Page_Request := Request_Id;
            end if;
            if not Is_Cancelled then
               if Rows_Available = 0 then
                  Rows_Available := Query_Page_Size;
               else
                  Page_Pending := True;
               end if;
            end if;
         end if;
      end Request_Page;

      function Page_Exhausted return Boolean is
        (Rows_Available = 0);

      entry Wait_For_Row (Proceed : out Boolean)
        when Rows_Available > 0 or else Is_Cancelled
      is
      begin
         Proceed := not Is_Cancelled;
         if Proceed then
            Rows_Available := Rows_Available - 1;
            if Rows_Available = 0 and then Page_Pending then
               Rows_Available := Query_Page_Size;
               Page_Pending := False;
            end if;
         end if;
      end Wait_For_Row;
   end Query_Control;

   procedure Execute
     (Name         : String;
      Port         : Positive;
      SQL          : String;
      Events       : in out Event_Stream;
      Control      : in out Query_Control)
   is
      Server : constant Sockets.Endpoint := Sockets.Network_Endpoint
        (Sockets.Loopback_IPv4, Sockets.Port (Port));
      Socket  : aliased Sockets.Socket_Type;
      Channel : aliased Transports.Socket_Transport (Socket'Access);
      Session : Client.Session (Channel'Access);
      Started : constant Ada.Real_Time.Time := Ada.Real_Time.Clock;
      Row_Count : Natural := 0;
      Truncated : Boolean := False;
      Cancel_Sent : Boolean := False;

      function Elapsed_Milliseconds return Natural is
        (Natural
           (Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started)
            * 1_000.0));

      procedure Send_Error
        (Kind, Message : String;
         SQL_State : String := "")
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", Kind);
         Psqlbench_JSON.String_Value (Document, "message", Message);
         if SQL_State'Length > 0 then
            Psqlbench_JSON.String_Value
              (Document, "sql_state", SQL_State);
         end if;
         Psqlbench_JSON.End_Object (Document);
         Events.Append (Psqlbench_JSON.Finish (Document));
      end Send_Error;

      procedure Send_Simple (Kind : String) is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", Kind);
         Psqlbench_JSON.End_Object (Document);
         Events.Append (Psqlbench_JSON.Finish (Document));
      end Send_Simple;

      procedure Send_Page_Ready is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value
           (Document, "type", "query.page-ready");
         Psqlbench_JSON.Integer_Value
           (Document, "rows", Long_Long_Integer (Row_Count));
         Psqlbench_JSON.Integer_Value
           (Document, "page_size", Query_Page_Size);
         Psqlbench_JSON.End_Object (Document);
         Events.Append (Psqlbench_JSON.Finish (Document));
      end Send_Page_Ready;

      procedure Cancel_Query is
      begin
         if not Cancel_Sent then
            Client_Sockets.Cancel (Session, Server, Timeout => 5.0);
            Cancel_Sent := True;
            Send_Simple ("query.cancelling");
         end if;
      end Cancel_Query;

      procedure Send_Ready is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value
           (Document, "type", "query.ready");
         Psqlbench_JSON.Integer_Value
           (Document, "rows", Long_Long_Integer (Row_Count));
         Psqlbench_JSON.Integer_Value
           (Document, "elapsed_ms",
            Long_Long_Integer (Elapsed_Milliseconds));
         Psqlbench_JSON.Boolean_Value
           (Document, "truncated", Truncated);
         Psqlbench_JSON.Boolean_Value
           (Document, "cancelled", Cancel_Sent);
         Psqlbench_JSON.End_Object (Document);
         Events.Append (Psqlbench_JSON.Finish (Document));
      end Send_Ready;

      procedure Resolve_Type_Names
        (Description : Protocol.Row_Description;
         Names       : in out Type_Name_Array)
      is
         Resolver_Socket : aliased Sockets.Socket_Type;
         Resolver_Channel : aliased Transports.Socket_Transport
           (Resolver_Socket'Access);
         Resolver : Client.Session (Resolver_Channel'Access);
         Query : Unbounded_String := To_Unbounded_String
           ("select oid::text, format_type(oid, null) "
            & "from pg_type where oid in (");
      begin
         for Index in Names'Range loop
            declare
               Field : constant Protocol.Field_Description :=
                 Protocol.Field_At (Description, Index);
               Oid : constant Protocol.UInt32 := Protocol.Type_Oid (Field);
            begin
               Names (Index) := To_Unbounded_String ("oid " & Compact (Oid));
               if Index > Names'First then
                  Append (Query, ',');
               end if;
               Append (Query, Compact (Oid));
            end;
         end loop;
         Append (Query, ')');

         Sockets.Create_Socket
           (Resolver_Socket, Family => Server.Family);
         Sockets.Connect (Resolver_Socket, Server, Timeout => 5.0);
         Client.Startup
           (Resolver,
            User             => "psqlbench",
            Database         => "postgres",
            Password         => "psqlbench",
            Application_Name => "psqlbench/type-resolver/" & Name,
            Timeout          => 10.0);
         Client.Send_Query (Resolver, To_String (Query), Timeout => 10.0);
         loop
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Resolver, Timeout => 10.0);
            begin
               case Protocol.Response_Kind (Event) is
                  when Protocol.Data_Row_Response =>
                     declare
                        Row : constant Protocol.Data_Row :=
                          Protocol.Row_Data (Event);
                        Oid : constant Protocol.UInt32 :=
                          Protocol.UInt32'Value
                            (Protocol.Column_Text
                               (Protocol.Column_At (Row, 1)));
                        Type_Name : constant String :=
                          Protocol.Column_Text
                            (Protocol.Column_At (Row, 2));
                     begin
                        for Index in Names'Range loop
                           if Protocol.Type_Oid
                                (Protocol.Field_At (Description, Index)) = Oid
                           then
                              Names (Index) :=
                                To_Unbounded_String (Type_Name);
                           end if;
                        end loop;
                     end;
                  when Protocol.Ready_For_Query_Response =>
                     exit;
                  when Protocol.Error_Response =>
                     exit;
                  when others => null;
               end case;
            end;
         end loop;
         begin
            Client.Send_Command
              (Resolver, Protocol.Make_Empty_Message ('X'), Timeout => 2.0);
         exception
            when others => null;
         end;
         Sockets.Close_Socket (Resolver_Socket);
      exception
         when others =>
            if Sockets.Is_Open (Resolver_Socket) then
               Sockets.Close_Socket (Resolver_Socket);
            end if;
      end Resolve_Type_Names;
   begin
      if SQL'Length = 0 or else SQL'Length > Max_Query_Bytes then
         Send_Error
           ("query.error",
            "SQL must contain between 1 and 16384 bytes");
         Events.Finish;
         return;
      end if;

      Sockets.Create_Socket (Socket, Family => Server.Family);
      Sockets.Connect (Socket, Server, Timeout => 5.0);
      Client.Startup
        (Session,
         User             => "psqlbench",
         Database         => "postgres",
         Password         => "psqlbench",
         Application_Name => "psqlbench/" & Name,
         Timeout          => 10.0);
      declare
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", "query.started");
         Psqlbench_JSON.String_Value (Document, "instance", Name);
         Psqlbench_JSON.End_Object (Document);
         Events.Append (Psqlbench_JSON.Finish (Document));
      end;
      Client.Send_Query (Session, SQL, Timeout => 10.0);

      loop
         if Control.Cancel_Requested and then not Cancel_Sent then
            Cancel_Query;
         end if;
         begin
            declare
               Event : constant Client.Simple_Query_Event :=
                 Client.Receive_Query_Event (Session, Timeout => 0.100);
            begin
               case Protocol.Response_Kind (Event) is
                  when Protocol.Row_Description_Response =>
                     declare
                        Description : constant Protocol.Row_Description :=
                          Protocol.Description (Event);
                        Type_Names : Type_Name_Array
                          (1 .. Protocol.Field_Count (Description));
                        Document : Psqlbench_JSON.Writer;
                     begin
                        Resolve_Type_Names (Description, Type_Names);
                        Psqlbench_JSON.Initialize (Document);
                        Psqlbench_JSON.Start_Object (Document);
                        Psqlbench_JSON.String_Value
                          (Document, "type", "query.columns");
                        Psqlbench_JSON.Start_Array (Document, "columns");
                        for Index in
                          1 .. Protocol.Field_Count (Description)
                        loop
                           declare
                              Field : constant Protocol.Field_Description :=
                                Protocol.Field_At (Description, Index);
                           begin
                              Psqlbench_JSON.Start_Object (Document);
                              Psqlbench_JSON.String_Value
                                (Document, "name",
                                 Protocol.Field_Name (Field));
                              Psqlbench_JSON.Integer_Value
                                (Document, "type_oid",
                                 Long_Long_Integer
                                   (Protocol.Type_Oid (Field)));
                              Psqlbench_JSON.String_Value
                                (Document, "type_name",
                                 To_String (Type_Names (Index)));
                              Psqlbench_JSON.End_Object (Document);
                           end;
                        end loop;
                        Psqlbench_JSON.End_Array (Document, "columns");
                        Psqlbench_JSON.End_Object (Document);
                        Events.Append (Psqlbench_JSON.Finish (Document));
                     end;

                  when Protocol.Data_Row_Response =>
                     if Control.Page_Exhausted then
                        Send_Page_Ready;
                     end if;
                     declare
                        Proceed : Boolean;
                     begin
                        Control.Wait_For_Row (Proceed);
                        if not Proceed then
                           Cancel_Sent := True;
                           Send_Simple ("query.cancelling");
                           if Sockets.Is_Open (Socket) then
                              Sockets.Close_Socket (Socket);
                           end if;
                           Send_Ready;
                           exit;
                        else
                           Row_Count := Row_Count + 1;
                           declare
                              Row : constant Protocol.Data_Row :=
                                Protocol.Row_Data (Event);
                              Document : Psqlbench_JSON.Writer;
                           begin
                              Psqlbench_JSON.Initialize (Document);
                              Psqlbench_JSON.Start_Object (Document);
                              Psqlbench_JSON.String_Value
                                (Document, "type", "query.row");
                              Psqlbench_JSON.Start_Array (Document, "values");
                              for Index in
                                1 .. Protocol.Column_Count (Row)
                              loop
                                 declare
                                    Value : constant Protocol.Column_Value :=
                                      Protocol.Column_At (Row, Index);
                                 begin
                                    if Protocol.Is_Null (Value) then
                                       Psqlbench_JSON.Null_Value (Document);
                                    else
                                       Psqlbench_JSON.String_Value
                                         (Document, "",
                                          Protocol.Column_Text (Value));
                                    end if;
                                 end;
                              end loop;
                              Psqlbench_JSON.End_Array (Document, "values");
                              Psqlbench_JSON.End_Object (Document);
                              declare
                                 Data : constant String :=
                                   Psqlbench_JSON.Finish (Document);
                              begin
                                 if Data'Length <= Max_Query_Event_Bytes then
                                    Events.Append (Data);
                                 else
                                    Truncated := True;
                                 end if;
                              end;
                           end;
                        end if;
                     end;

                  when Protocol.Command_Complete_Response =>
                     declare
                        Document : Psqlbench_JSON.Writer;
                     begin
                        Psqlbench_JSON.Initialize (Document);
                        Psqlbench_JSON.Start_Object (Document);
                        Psqlbench_JSON.String_Value
                          (Document, "type", "query.complete");
                        Psqlbench_JSON.String_Value
                          (Document, "command",
                           Protocol.Completion_Tag (Event));
                        Psqlbench_JSON.End_Object (Document);
                        Events.Append (Psqlbench_JSON.Finish (Document));
                     end;

                  when Protocol.Empty_Query_Response =>
                     Send_Simple ("query.empty");

                  when Protocol.Error_Response | Protocol.Notice_Response =>
                     declare
                        Diagnostic : constant Protocol.Diagnostic :=
                          Protocol.Diagnostic_Data (Event);
                     begin
                        Send_Error
                          ((if Protocol.Response_Kind (Event) =
                                 Protocol.Error_Response
                            then "query.error" else "query.notice"),
                           Protocol.Diagnostic_Message (Diagnostic),
                           Protocol.Diagnostic_SQL_State (Diagnostic));
                     end;

                  when Protocol.Ready_For_Query_Response =>
                     Send_Ready;
                     exit;

                  when Protocol.Copy_In_Response |
                       Protocol.Copy_Out_Response |
                       Protocol.Copy_Both_Response =>
                     Send_Error
                       ("query.error",
                        "COPY streaming is not available in this slice",
                        "0A000");
                     exit;

                  when others =>
                     null;
               end case;
            end;
         exception
            when Flyology.IO.Timeout_Error =>
               null;
         end;
      end loop;

      if Sockets.Is_Open (Socket) then
         begin
            Client.Send_Command
              (Session, Protocol.Make_Empty_Message ('X'), Timeout => 2.0);
         exception
            when others => null;
         end;
         Sockets.Close_Socket (Socket);
      end if;
      Events.Finish;
   exception
      when Error : others =>
         if Sockets.Is_Open (Socket) then
            Sockets.Close_Socket (Socket);
         end if;
         Send_Error
           ("query.error", Ada.Exceptions.Exception_Message (Error));
         Events.Finish;
   end Execute;

end Psqlbench_Query;
