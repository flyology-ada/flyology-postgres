with Ada.Streams;
with Ada.Real_Time;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication.Logical.Producer;
with Flyology.Postgres.Replication.Server_Sessions;

package body Flyology.Postgres.Replication.Managed_Primary is

   package Producer renames Flyology.Postgres.Replication.Logical.Producer;
   package Replication_Sessions renames
     Flyology.Postgres.Replication.Server_Sessions;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Real_Time.Time;
   use type Logical.Streaming_Mode;
   use type Protocol.Frontend_Copy_Kind;
   use type Stream_Message_Kind;
   use type Stores.Acquire_Result;
   use type Stores.Create_Result;
   use type Stores.Slot_Kind;
   use type LSN;
   use type Producer.Transaction_State;

   procedure Require (Condition : Boolean; Reason : String) is
   begin
      if not Condition then
         raise Protocol.Protocol_Error with Reason;
      end if;
   end Require;

   procedure Initialize
     (Item      : in out Primary;
      System_Id : UInt64;
      Database  : String := "";
      Timeout   : Duration := 30.0) is
   begin
      if System_Id = 0 or else Timeout <= 0.0 then
         raise Constraint_Error with "invalid managed primary configuration";
      end if;
      Item.Identifier := System_Id;
      Item.Database_Name := To_Unbounded_String (Database);
      Item.Operation_Timeout := Timeout;
      Item.Initialized := True;
   end Initialize;

   procedure Complete_Copy
     (Item : Primary; Client : in out Sessions.Session) is
   begin
      Replication_Sessions.Finish_Streaming
        (Client, Timeout => Item.Operation_Timeout);
      loop
         declare
            Copy_Command : constant Protocol.Frontend_Copy_Message :=
              Sessions.Read_Copy_Command
                (Client, Timeout => Item.Operation_Timeout);
         begin
            case Protocol.Copy_Kind (Copy_Command) is
               when Protocol.Frontend_Copy_Data =>
                  declare
                     Ignored : constant Stream_Message :=
                       Replication.Decode
                         (Protocol.Original_Message (Copy_Command));
                     pragma Unreferenced (Ignored);
                  begin
                     null;
                  end;
               when Protocol.Frontend_Copy_Done =>
                  exit;
               when Protocol.Frontend_Copy_Fail =>
                  raise Protocol.Protocol_Error with
                    "replica aborted COPY BOTH completion";
            end case;
         end;
      end loop;
      Replication_Sessions.Complete_Streaming
        (Client, Timeout => Item.Operation_Timeout);
   end Complete_Copy;

   procedure Await_Feedback
     (Item      : Primary;
      Client    : in out Sessions.Session;
      Minimum   : LSN;
      Received  : out LSN;
      Flushed   : out LSN) is
   begin
      loop
         declare
            Feedback : constant Stream_Message :=
              Replication_Sessions.Read_Standby_Message
                (Client, Timeout => Item.Operation_Timeout);
         begin
            if Kind (Feedback) = Standby_Status_Update
              and then Flushed_LSN (Feedback) >= Minimum
            then
               Received := Received_LSN (Feedback);
               Flushed := Flushed_LSN (Feedback);
               return;
            end if;
         end;
      end loop;
   end Await_Feedback;

   procedure Apply_Retention (Item : in out Primary) is
      Floor : constant LSN :=
        Stores.Oldest_Restart_LSN (Item.Slots.all);
   begin
      if Floor > Stores.First_LSN (Item.WAL.all) then
         Require
           (Floor <= Stores.Current_LSN (Item.WAL.all),
            "slot retention floor exceeds available WAL");
         Stores.Retain_From (Item.WAL.all, Floor);
      end if;
   end Apply_Retention;

   procedure Stream_Physical
     (Item    : in out Primary;
      Client  : in out Sessions.Session;
      Command : Replication.Command) is
      Slot_Name : constant String := Replication.Slot_Name (Command);
      Position  : LSN := Replication.Position (Command);
      End_LSN   : constant LSN := Stores.Current_LSN (Item.WAL.all);
      Lease     : Stores.UInt64 := 0;
      State     : Stores.Slot_State;
      Acquired  : Stores.Acquire_Result;
      Has_Lease : Boolean := False;
      Received  : LSN := 0;
      Flushed   : LSN := 0;
      Advanced  : Boolean;
      Released  : Boolean;
   begin
      if Slot_Name'Length > 0 then
         Stores.Acquire
           (Item.Slots.all, Slot_Name, Stores.Physical_Slot,
            Acquired, Lease, State);
         Require (Acquired = Stores.Acquired, "physical slot is unavailable");
         Has_Lease := True;
      end if;
      Require
        (Position >= Stores.First_LSN (Item.WAL.all)
         and then Position <= End_LSN,
         "requested physical WAL is not retained");

      Replication_Sessions.Begin_Streaming
        (Client, Timeout => Item.Operation_Timeout);
      while Position < End_LSN loop
         declare
            Data : constant Stores.Byte_Array :=
              Stores.Read (Item.WAL.all, Position, Maximum => 32 * 1_024);
         begin
            Require (Data'Length > 0, "WAL store made no stream progress");
            Replication_Sessions.Send_XLog_Data
              (Client, Position, End_LSN, Sent_At => 0, Data => Data,
               Timeout => Item.Operation_Timeout);
            Position := Position + LSN (Data'Length);
         end;
      end loop;
      Replication_Sessions.Send_Primary_Keepalive
        (Client, End_LSN, Sent_At => 0, Reply_Requested => True,
         Timeout => Item.Operation_Timeout);
      Await_Feedback (Item, Client, End_LSN, Received, Flushed);
      Require
        (Received <= End_LSN and then Flushed <= Received,
         "standby feedback exceeds streamed physical WAL");
      if Has_Lease then
         Stores.Advance
           (Item.Slots.all, Slot_Name, Lease,
            Restart => Flushed, Confirmed => 0, Advanced => Advanced);
         Require (Advanced, "physical slot advancement lost its lease");
      end if;
      Complete_Copy (Item, Client);
      if Has_Lease then
         Stores.Release
           (Item.Slots.all, Slot_Name, Lease, Released);
         Require (Released, "physical slot release lost its lease");
      end if;
      Apply_Retention (Item);
   exception
      when others =>
         if Has_Lease then
            Stores.Release
              (Item.Slots.all, Slot_Name, Lease, Released);
         end if;
         raise;
   end Stream_Physical;

   procedure Logical_Configuration
     (Command   : Replication.Command;
      Version   : out Logical.Protocol_Version;
      Streaming : out Logical.Streaming_Mode) is
   begin
      Version := 1;
      Streaming := Logical.Disabled;
      for Option of Replication.Options (Command) loop
         if Replication.Option_Name (Option) = "proto_version" then
            Version := Logical.Protocol_Version'Value
              (Replication.Option_Value (Option));
         elsif Replication.Option_Name (Option) = "streaming" then
            declare
               Value : constant String := Replication.Option_Value (Option);
            begin
               Streaming :=
                 (if Value = "parallel" then Logical.Parallel
                  elsif Value = "on" then Logical.In_Progress
                  else Logical.Disabled);
            end;
         end if;
      end loop;
      Require
        (Logical.Configuration_Is_Valid (Version, Streaming),
         "logical replication options are incompatible");
   exception
      when Constraint_Error =>
         raise Protocol.Protocol_Error with
           "invalid logical replication protocol version";
   end Logical_Configuration;

   procedure Stream_Logical
     (Item    : in out Primary;
      Client  : in out Sessions.Session;
      Command : Replication.Command) is
      Slot_Name : constant String := Replication.Slot_Name (Command);
      Position  : LSN := Replication.Position (Command);
      Lease     : Stores.UInt64 := 0;
      State     : Stores.Slot_State;
      Acquired  : Stores.Acquire_Result;
      Has_Lease : Boolean := False;
      Released  : Boolean;
      Advanced  : Boolean;
      Version   : Logical.Protocol_Version;
      Streaming : Logical.Streaming_Mode;
      Encoder   : Producer.Encoder;
      Available : Boolean;
      Start_LSN : LSN;
      End_LSN   : LSN;
      Message   : Logical.Message;
      Received  : LSN := 0;
      Flushed   : LSN := 0;
   begin
      Stores.Acquire
        (Item.Slots.all, Slot_Name, Stores.Logical_Slot,
         Acquired, Lease, State);
      Require (Acquired = Stores.Acquired, "logical slot is unavailable");
      Has_Lease := True;
      if Position < Stores.Confirmed_LSN (State) then
         Position := Stores.Confirmed_LSN (State);
      end if;
      Require
        (Stores.Plugin (State) = "pgoutput",
         "managed logical primary only produces pgoutput");
      Logical_Configuration (Command, Version, Streaming);
      Producer.Configure (Encoder, Version, Streaming);
      Replication_Sessions.Begin_Streaming
        (Client, Timeout => Item.Operation_Timeout);

      loop
         Next_Logical
           (Item.Logical_Source.all, Slot_Name, Position,
            Available, Start_LSN, End_LSN, Message);
         exit when not Available;
         Require
           (Start_LSN >= Position and then End_LSN > Start_LSN,
            "logical source positions are not strictly ordered");
         declare
            Data : constant Logical.Byte_Array :=
              Producer.Emit (Encoder, Message, Start_LSN, End_LSN);
         begin
            Replication_Sessions.Send_XLog_Data
              (Client, Start_LSN, End_LSN, Sent_At => 0, Data => Data,
               Timeout => Item.Operation_Timeout);
         end;
         Position := End_LSN;
      end loop;

      Require
        (Producer.State (Encoder) = Producer.Idle,
         "logical source ended inside a transaction");
      Replication_Sessions.Send_Primary_Keepalive
        (Client, Position, Sent_At => 0, Reply_Requested => True,
         Timeout => Item.Operation_Timeout);
      Await_Feedback (Item, Client, Position, Received, Flushed);
      Require
        (Received <= Position and then Flushed <= Received,
         "standby feedback exceeds produced logical WAL");
      Stores.Advance
        (Item.Slots.all, Slot_Name, Lease,
         Restart => Flushed, Confirmed => Flushed, Advanced => Advanced);
      Require (Advanced, "logical slot advancement lost its lease");
      Complete_Copy (Item, Client);
      Stores.Release (Item.Slots.all, Slot_Name, Lease, Released);
      Require (Released, "logical slot release lost its lease");
      Has_Lease := False;
      Apply_Retention (Item);
   exception
      when others =>
         if Has_Lease then
            Stores.Release
              (Item.Slots.all, Slot_Name, Lease, Released);
         end if;
         raise;
   end Stream_Logical;

   procedure Handle
     (Item    : in out Primary;
      Client  : in out Sessions.Session;
      Command : Replication.Command) is
   begin
      Require (Item.Initialized, "managed primary is not initialized");
      case Replication.Kind (Command) is
         when Identify_System_Command =>
            Replication_Sessions.Send_Identify_System
              (Client, Item.Identifier,
               Stores.Current_Timeline (Item.Timelines.all),
               Stores.Current_LSN (Item.WAL.all),
               Database => To_String (Item.Database_Name),
               Timeout => Item.Operation_Timeout);
         when Show_Command =>
            declare
               Parameter : constant String :=
                 Replication.Parameter (Command);
               Value : constant String :=
                 (if Parameter = "data_directory_mode" then "0700"
                  elsif Parameter = "wal_segment_size" then "16MB"
                  elsif Parameter = "wal_level" then "logical"
                  elsif Parameter = "max_replication_slots" then "10"
                  else "on");
            begin
               Replication_Sessions.Send_Show
                 (Client, Parameter, Value,
                  Timeout => Item.Operation_Timeout);
            end;
         when Timeline_History_Command =>
            Replication_Sessions.Send_Timeline_History
              (Client, Replication.Timeline (Command),
               Stores.History
                 (Item.Timelines.all, Replication.Timeline (Command)),
               Timeout => Item.Operation_Timeout);
         when Create_Logical_Slot_Command =>
            declare
               Position : constant LSN := Stores.Current_LSN (Item.WAL.all);
               Result   : Stores.Create_Result;
            begin
               Require
                 (not Command.Temporary_Value,
                  "managed primary does not support temporary logical slots");
               Require
                 (Replication.Plugin (Command) = "pgoutput",
                  "managed logical primary only supports pgoutput slots");
               Require
                 (Replication.Snapshot (Command) /= Export_Snapshot,
                  "exported snapshots require an application SQL provider");
               Require
                 (not Replication.Two_Phase (Command),
                  "managed logical primary does not retain prepared state");
               Require
                 (not Replication.Failover (Command),
                  "managed logical primary does not support failover slots");
               Stores.Create
                 (Item.Slots.all,
                  Replication.Slot_Name (Command),
                  Stores.Make_Slot
                    (Stores.Logical_Slot,
                     Restart_LSN   => Position,
                     Confirmed_LSN => Position,
                     Plugin        => Replication.Plugin (Command)),
                  Result);
               Require
                 (Result = Stores.Created,
                  "replication slot already exists");
               Replication_Sessions.Send_Create_Logical_Slot
                 (Client,
                  Replication.Slot_Name (Command),
                  Position,
                  Replication.Plugin (Command),
                  Timeout => Item.Operation_Timeout);
               Apply_Retention (Item);
            end;
         when Create_Physical_Slot_Command =>
            raise Protocol.Protocol_Error with
              "managed primary does not support physical slot creation";
         when Drop_Replication_Slot_Command =>
            declare
               Dropped  : Boolean;
               Deadline : constant Ada.Real_Time.Time :=
                 Ada.Real_Time.Clock
                   + Ada.Real_Time.To_Time_Span (Item.Operation_Timeout);
            begin
               loop
                  Stores.Drop
                    (Item.Slots.all,
                     Replication.Slot_Name (Command),
                     Dropped);
                  exit when Dropped or else not Replication.Wait (Command);
                  Require
                    (Ada.Real_Time.Clock < Deadline,
                     "timed out waiting for active replication slot");
                  delay 0.01;
               end loop;
               Require (Dropped, "replication slot is missing or active");
               Replication_Sessions.Send_Drop_Replication_Slot
                 (Client, Timeout => Item.Operation_Timeout);
               Apply_Retention (Item);
            end;
         when Upload_Manifest_Command | Base_Backup_Command =>
            raise Protocol.Protocol_Error with
              "managed primary does not provide base-backup storage";

         when Start_Physical_Command =>
            Stream_Physical (Item, Client, Command);
         when Start_Logical_Command =>
            Stream_Logical (Item, Client, Command);
      end case;
   end Handle;

end Flyology.Postgres.Replication.Managed_Primary;
