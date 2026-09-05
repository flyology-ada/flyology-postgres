with Ada.Exceptions;
with Ada.Streams;
with Ada.Strings.Unbounded;
with Flyology.Postgres.Protocol;
with Flyology_TLA.Command_Line;
with Flyology_TLA.Replay;
with Flyology_TLA.Traces;
with Pgoutput_Producer_Model;

procedure Flyology.Postgres.Replication.Logical.Producer.Conformance is

   package Model renames Pgoutput_Producer_Model;
   package Protocol renames Flyology.Postgres.Protocol;

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;
   use type Ada.Streams.Stream_Element_Offset;
   use type Model.Input_Kind_Type;
   use type Model.Outcome_Wire_Xid_Type;
   use type Model.State_Segments_T1_Type;
   use type Model.State_Segments_T2_Type;
   use type LSN;

   T1 : constant Transaction_Id := 101;
   T2 : constant Transaction_Id := 202;

   Limits : constant Flyology_TLA.Traces.Load_Limits :=
     (Maximum_File_Bytes   => 1_000_000,
      Maximum_Steps        => 32,
      Maximum_JSON_Depth   => 64,
      Maximum_Object_Names => 10_000,
      Maximum_Name_Bytes   => 4_096,
      Maximum_String_Bytes => 100_000,
      Maximum_Value_Bytes  => 500_000);

   Initial_State : constant Model.State_Type :=
     (Context            => Model.State_Context_Idle,
      Current_Xid        => Model.State_Current_Xid_None,
      Paused_T1          => False,
      Paused_T2          => False,
      Recent_Paused      => Model.State_Recent_Paused_None,
      Segments_T1        => 0,
      Segments_T2        => 0,
      Scenario_Step      => 0,
      Last_Action        => Model.State_Last_Action_Init,
      Last_Xid           => Model.State_Last_Xid_None,
      Last_Subxid        => Model.State_Last_Subxid_None,
      Last_First         => False,
      Last_Transactional => False,
      Last_Outcome       => True,
      Last_Has_Prefix    => False,
      Last_Wire_Xid      => Model.State_Last_Wire_Xid_None);

   Tuple : constant Logical.Tuple_Data :=
     Logical.Make_Tuple ((1 => Logical.Text_Column ("value")));

   type Producer_Adapter is new Model.Adapter with record
      Subject : Encoder;
      Current : Model.State_Type := Initial_State;
   end record;

   overriding procedure Reset
     (Self     : in out Producer_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome);

   overriding procedure Apply
     (Self         : in out Producer_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome);

   function XID (Value : Model.Input_Xid_Type) return Transaction_Id is
     (case Value is
         when Model.Input_Xid_None => 0,
         when Model.Input_Xid_T1   => T1,
         when Model.Input_Xid_T2   => T2);

   function Subxid (Value : Model.Input_Subxid_Type) return Transaction_Id is
     (case Value is
         when Model.Input_Subxid_None => 0,
         when Model.Input_Subxid_T1   => T1,
         when Model.Input_Subxid_T2   => T2);

   function Last_XID
     (Value : Model.Input_Xid_Type) return Model.State_Last_Xid_Type is
     (case Value is
         when Model.Input_Xid_None => Model.State_Last_Xid_None,
         when Model.Input_Xid_T1   => Model.State_Last_Xid_T1,
         when Model.Input_Xid_T2   => Model.State_Last_Xid_T2);

   function Last_Subxid
     (Value : Model.Input_Subxid_Type) return Model.State_Last_Subxid_Type is
     (case Value is
         when Model.Input_Subxid_None => Model.State_Last_Subxid_None,
         when Model.Input_Subxid_T1   => Model.State_Last_Subxid_T1,
         when Model.Input_Subxid_T2   => Model.State_Last_Subxid_T2);

   function Last_Action
     (Value : Model.Input_Kind_Type) return Model.State_Last_Action_Type is
     (case Value is
         when Model.Input_Kind_Begin_Regular =>
            Model.State_Last_Action_Begin_Regular,
         when Model.Input_Kind_Commit_Regular =>
            Model.State_Last_Action_Commit_Regular,
         when Model.Input_Kind_Start_Stream =>
            Model.State_Last_Action_Start_Stream,
         when Model.Input_Kind_Stop_Stream =>
            Model.State_Last_Action_Stop_Stream,
         when Model.Input_Kind_Commit_Stream =>
            Model.State_Last_Action_Commit_Stream,
         when Model.Input_Kind_Abort_Stream =>
            Model.State_Last_Action_Abort_Stream,
         when Model.Input_Kind_Data => Model.State_Last_Action_Data,
         when Model.Input_Kind_Logical_Message =>
            Model.State_Last_Action_Logical_Message);

   function Action_Name (Value : Model.Input_Kind_Type) return String is
     (case Value is
         when Model.Input_Kind_Begin_Regular   => "BeginRegular",
         when Model.Input_Kind_Commit_Regular  => "CommitRegular",
         when Model.Input_Kind_Start_Stream    => "StartStream",
         when Model.Input_Kind_Stop_Stream     => "StopStream",
         when Model.Input_Kind_Commit_Stream   => "CommitStream",
         when Model.Input_Kind_Abort_Stream    => "AbortStream",
         when Model.Input_Kind_Data            => "Data",
         when Model.Input_Kind_Logical_Message => "LogicalMessage");

   function Message_For
     (Input : Model.Input_Type; Position : LSN) return Logical.Message is
     (case Input.Kind is
         when Model.Input_Kind_Begin_Regular =>
            Logical.Make_Begin (Position, 0, XID (Input.Xid)),
         when Model.Input_Kind_Commit_Regular =>
            Logical.Make_Commit (Position, Position + 1, 0),
         when Model.Input_Kind_Start_Stream =>
            Logical.Make_Stream_Start (XID (Input.Xid), Input.First_Segment),
         when Model.Input_Kind_Stop_Stream => Logical.Make_Stream_Stop,
         when Model.Input_Kind_Commit_Stream =>
            Logical.Make_Stream_Commit
              (XID (Input.Xid), Position, Position + 1, 0),
         when Model.Input_Kind_Abort_Stream =>
            Logical.Make_Stream_Abort
              (XID (Input.Xid), Subxid (Input.Subxid)),
         when Model.Input_Kind_Data =>
            Logical.Make_Insert (42, Tuple, Xid => XID (Input.Xid)),
         when Model.Input_Kind_Logical_Message =>
            Logical.Make_Logical_Decoding_Message
              (Position,
               "flyology",
               (1 => 16#A5#),
               Transactional => Input.Transactional,
               Xid           => XID (Input.Xid)));

   function Wire_XID
     (Input : Model.Input_Type;
      Data  : Logical.Byte_Array) return Model.Outcome_Wire_Xid_Type is
      First : constant Ada.Streams.Stream_Element_Offset := Data'First;
   begin
      if Input.Kind not in
        Model.Input_Kind_Data | Model.Input_Kind_Logical_Message
        or else Data'Length < 5
        or else Data (First + 1) /= 0
        or else Data (First + 2) /= 0
        or else Data (First + 3) /= 0
      then
         return Model.Outcome_Wire_Xid_None;
      elsif Data (First + 4) = Logical.Byte (T1) then
         return Model.Outcome_Wire_Xid_T1;
      elsif Data (First + 4) = Logical.Byte (T2) then
         return Model.Outcome_Wire_Xid_T2;
      else
         return Model.Outcome_Wire_Xid_None;
      end if;
   end Wire_XID;

   procedure Refresh_Core (Self : in out Producer_Adapter) is
   begin
      case Self.Subject.Current is
         when Idle =>
            Self.Current.Context := Model.State_Context_Idle;
         when Regular_Transaction =>
            Self.Current.Context := Model.State_Context_Regular;
         when Stream_Segment =>
            Self.Current.Context := Model.State_Context_Segment;
         when Stream_Paused =>
            Self.Current.Context := Model.State_Context_Paused;
         when Preparing_Transaction =>
            raise Program_Error with "unexpected prepared transaction state";
      end case;

      case Self.Subject.XID is
         when 0 =>
            Self.Current.Current_Xid := Model.State_Current_Xid_None;
         when T1 =>
            Self.Current.Current_Xid := Model.State_Current_Xid_T1;
         when T2 =>
            Self.Current.Current_Xid := Model.State_Current_Xid_T2;
         when others =>
            raise Program_Error with "unexpected transaction identity";
      end case;

      Self.Current.Paused_T1 := False;
      Self.Current.Paused_T2 := False;
      for Paused_XID of Self.Subject.Paused_XIDs loop
         case Paused_XID is
            when T1 =>
               Self.Current.Paused_T1 := True;
            when T2 =>
               Self.Current.Paused_T2 := True;
            when others =>
               raise Program_Error with
                 "unexpected paused transaction identity";
         end case;
      end loop;

      if Self.Subject.Paused_XIDs.Is_Empty then
         Self.Current.Recent_Paused := Model.State_Recent_Paused_None;
      elsif Self.Subject.Paused_XIDs.Last_Element = T1 then
         Self.Current.Recent_Paused := Model.State_Recent_Paused_T1;
      elsif Self.Subject.Paused_XIDs.Last_Element = T2 then
         Self.Current.Recent_Paused := Model.State_Recent_Paused_T2;
      else
         raise Program_Error with "unexpected recent transaction identity";
      end if;
   end Refresh_Core;

   overriding procedure Reset
     (Self     : in out Producer_Adapter;
      Observed : out Model.State_Type;
      Status   : out Flyology_TLA.Replay.Adapter_Outcome) is
   begin
      Configure (Self.Subject, Version => 2, Streaming => Logical.In_Progress);
      Self.Current := Initial_State;
      Observed := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   end Reset;

   overriding procedure Apply
     (Self         : in out Producer_Adapter;
      Index        : Positive;
      Action       : String;
      Role         : String;
      Input        : Model.Input_Type;
      Model_Source : String;
      Observed     : out Model.Outcome_Type;
      State        : out Model.State_Type;
      Status       : out Flyology_TLA.Replay.Adapter_Outcome) is
      Expected_Action : constant String :=
        "PgoutputProducer!" & Action_Name (Input.Kind);
      Start_Position : constant LSN := LSN (Index * 2);
      End_Position   : constant LSN := Start_Position + 1;
      Accepted       : Boolean := False;
      Encoded_XID    : Model.Outcome_Wire_Xid_Type :=
        Model.Outcome_Wire_Xid_None;
   begin
      if Action /= Expected_Action
        or else Model_Source /= Expected_Action
        or else Role /= "pgoutput-producer"
      then
         Observed :=
           (Accepted  => False,
            Has_Prefix => False,
            Wire_Xid  => Model.Outcome_Wire_Xid_None);
         State := Self.Current;
         Status :=
           (Succeeded => False,
            Detail    => To_Unbounded_String
              ("unsupported modeled action or role"));
         return;
      end if;

      begin
         declare
            Bytes : constant Logical.Byte_Array :=
              Emit
                (Self.Subject,
                 Message_For (Input, End_Position),
                 Start_Position,
                 End_Position);
         begin
            Accepted := True;
            Encoded_XID := Wire_XID (Input, Bytes);
         end;
      exception
         when Protocol.Protocol_Error =>
            Accepted := False;
      end;

      if Accepted and then Input.Kind = Model.Input_Kind_Start_Stream then
         case Input.Xid is
            when Model.Input_Xid_T1 =>
               Self.Current.Segments_T1 := Self.Current.Segments_T1 + 1;
            when Model.Input_Xid_T2 =>
               Self.Current.Segments_T2 := Self.Current.Segments_T2 + 1;
            when Model.Input_Xid_None =>
               null;
         end case;
      end if;

      Self.Current.Scenario_Step := Model.State_Scenario_Step_Type (Index);
      Self.Current.Last_Action := Last_Action (Input.Kind);
      Self.Current.Last_Xid := Last_XID (Input.Xid);
      Self.Current.Last_Subxid := Last_Subxid (Input.Subxid);
      Self.Current.Last_First := Input.First_Segment;
      Self.Current.Last_Transactional := Input.Transactional;
      Self.Current.Last_Outcome := Accepted;
      Self.Current.Last_Has_Prefix :=
        Encoded_XID /= Model.Outcome_Wire_Xid_None;
      Self.Current.Last_Wire_Xid :=
        (case Encoded_XID is
            when Model.Outcome_Wire_Xid_None =>
               Model.State_Last_Wire_Xid_None,
            when Model.Outcome_Wire_Xid_T1 =>
               Model.State_Last_Wire_Xid_T1,
            when Model.Outcome_Wire_Xid_T2 =>
               Model.State_Last_Wire_Xid_T2);
      Refresh_Core (Self);

      Observed :=
        (Accepted   => Accepted,
         Has_Prefix => Encoded_XID /= Model.Outcome_Wire_Xid_None,
         Wire_Xid   => Encoded_XID);
      State := Self.Current;
      Status := (Succeeded => True, Detail => Null_Unbounded_String);
   exception
      when Error : others =>
         Observed :=
           (Accepted   => False,
            Has_Prefix => False,
            Wire_Xid   => Model.Outcome_Wire_Xid_None);
         State := Self.Current;
         Status :=
           (Succeeded => False,
            Detail    => To_Unbounded_String
              (Ada.Exceptions.Exception_Information (Error)));
   end Apply;

begin
   declare
      Config : Flyology_TLA.Command_Line.Configuration :=
        Flyology_TLA.Command_Line.Parse (Limits);
   begin
      if Flyology_TLA.Command_Line.Help_Requested (Config) then
         Flyology_TLA.Command_Line.Put_Help;
         return;
      end if;

      declare
         Trace : constant Flyology_TLA.Traces.Trace :=
           Flyology_TLA.Command_Line.Load (Config);
         Adapter : Producer_Adapter;
         Result  : Flyology_TLA.Replay.Replay_Result;
      begin
         Model.Run
           (Adapter,
            Trace,
            Flyology_TLA.Command_Line.Limits (Config),
            Result);
         Flyology_TLA.Command_Line.Report (Config, Result);
         Flyology_TLA.Command_Line.Set_Exit_Status (Result);
      end;
   end;
exception
   when Error : Flyology_TLA.Command_Line.Usage_Error =>
      Flyology_TLA.Command_Line.Fail
        (Ada.Exceptions.Exception_Message (Error), Show_Help => True);
   when Error : Flyology_TLA.Traces.Trace_Error =>
      Flyology_TLA.Command_Line.Fail
        ("cannot load trace: " & Ada.Exceptions.Exception_Message (Error));
end Flyology.Postgres.Replication.Logical.Producer.Conformance;
