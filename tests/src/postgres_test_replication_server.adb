with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Streams.Stream_IO;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Server_Sessions;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;

procedure Postgres_Test_Replication_Server is

   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Replication_Sessions renames
     Flyology.Postgres.Replication.Server_Sessions;
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Stream_IO renames Ada.Streams.Stream_IO;

   use type Ada.Streams.Stream_Element_Offset;
   use type Ada.Streams.Stream_IO.Count;
   use type Protocol.Replication_Connection_Mode;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Replication.Stream_Message_Kind;
   use type Replication.UInt32;

   type Context is limited record
      System_Id    : Replication.UInt64 := 0;
      Current_WAL  : Replication.LSN := 0;
      WAL_Directory : Unbounded_String;
      Expected_Slot : Unbounded_String;
      Segment_Size : Replication.UInt64 := 16 * 1_024 * 1_024;
      Verifier     : Unbounded_String := To_Unbounded_String
        (Flyology.Postgres.SCRAM.Make_Verifier_Raw
           ("flyology-secret",
            Flyology.Postgres.SCRAM.To_Bytes
              ("Flyology replication test salt")));
   end record;

   function Port return Sockets.Port is
   begin
      return Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_REPLICATION_SERVER_PORT", "55435"));
   end Port;

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (State, Password);
   begin
      return Startup.Replication_Mode =
        Protocol.Physical_Replication_Connection;
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String is
   begin
      return
        (if To_String (Startup.User) = "flyology"
           and then Startup.Replication_Mode =
             Protocol.Physical_Replication_Connection
         then To_String (State.Verifier)
         else "");
   end Lookup_SCRAM_Verifier;

   function Hex_8 (Value : Replication.UInt32) return String is
      Hexadecimal : constant String := "0123456789ABCDEF";
      Result      : String (1 .. 8) := (others => '0');
      Work        : Replication.UInt32 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Hexadecimal (Natural (Work mod 16) + 1);
         Work := Work / 16;
      end loop;
      return Result;
   end Hex_8;

   function WAL_File_Name
     (State : Context; Position : Replication.LSN) return String is
      Segment_Number : constant Replication.UInt64 :=
        Position / State.Segment_Size;
      Segments_Per_Id : constant Replication.UInt64 :=
        16#1_0000_0000# / State.Segment_Size;
      Log_Id : constant Replication.UInt32 := Replication.UInt32
        (Segment_Number / Segments_Per_Id);
      Segment_Id : constant Replication.UInt32 := Replication.UInt32
        (Segment_Number mod Segments_Per_Id);
   begin
      return To_String (State.WAL_Directory) & "/00000001"
        & Hex_8 (Log_Id) & Hex_8 (Segment_Id);
   end WAL_File_Name;

   procedure Stream_WAL
     (State  : in out Context;
      Client : in out Sessions.Session;
      Start  : Replication.LSN) is
      Chunk_Size : constant Replication.UInt64 := 32 * 1_024;
      Current    : Replication.LSN := Start;
   begin
      if Current > State.Current_WAL then
         raise Protocol.Protocol_Error with
           "standby requested WAL beyond the primary flush position";
      end if;
      Replication_Sessions.Begin_Streaming (Client, Timeout => 10.0);
      while Current < State.Current_WAL loop
         declare
            Offset : constant Replication.UInt64 :=
              Current mod State.Segment_Size;
            Remaining : constant Replication.UInt64 :=
              Replication.UInt64'Min
                (State.Current_WAL - Current,
                 Replication.UInt64'Min
                   (State.Segment_Size - Offset, Chunk_Size));
            Data : Replication.Byte_Array
              (1 .. Ada.Streams.Stream_Element_Offset (Remaining));
            Last : Ada.Streams.Stream_Element_Offset;
            File : Stream_IO.File_Type;
         begin
            Stream_IO.Open
              (File, Stream_IO.In_File, WAL_File_Name (State, Current));
            Stream_IO.Set_Index (File, Stream_IO.Count (Offset) + 1);
            Stream_IO.Read (File, Data, Last);
            Stream_IO.Close (File);
            if Last < Data'Last then
               raise Protocol.Protocol_Error with
                 "WAL segment ended before the advertised flush position";
            end if;
            Replication_Sessions.Send_XLog_Data
              (Client,
               WAL_Start => Current,
               WAL_End   => State.Current_WAL,
               Sent_At   => 0,
               Data      => Data,
               Timeout   => 10.0);
            Current := Current + Replication.LSN (Data'Length);
         end;
      end loop;
      Replication_Sessions.Send_Primary_Keepalive
        (Client,
         WAL_End         => State.Current_WAL,
         Sent_At         => 0,
         Reply_Requested => True,
         Timeout         => 10.0);

      loop
         declare
            Feedback : constant Replication.Stream_Message :=
              Replication_Sessions.Read_Standby_Message
                (Client, Timeout => 30.0);
         begin
            if Replication.Kind (Feedback) =
              Replication.Standby_Status_Update
              and then Replication.Received_LSN (Feedback) =
                State.Current_WAL
              and then Replication.Flushed_LSN (Feedback) =
                State.Current_WAL
              and then Replication.Applied_LSN (Feedback) =
                State.Current_WAL
            then
               Ada.Text_IO.Put_Line
                 ("standby feedback received="
                  & Replication.Image
                    (Replication.Received_LSN (Feedback))
                  & " flushed="
                  & Replication.Image
                    (Replication.Flushed_LSN (Feedback))
                  & " applied="
                  & Replication.Image
                    (Replication.Applied_LSN (Feedback)));
               Ada.Text_IO.Flush;
               exit;
            end if;
         end;
      end loop;

      Replication_Sessions.Finish_Streaming (Client, Timeout => 10.0);
      loop
         declare
            Copy_Command : constant Protocol.Frontend_Copy_Message :=
              Sessions.Read_Copy_Command (Client, Timeout => 30.0);
         begin
            case Protocol.Copy_Kind (Copy_Command) is
               when Protocol.Frontend_Copy_Data =>
                  declare
                     Feedback : constant Replication.Stream_Message :=
                       Replication.Decode
                         (Protocol.Original_Message (Copy_Command));
                  begin
                     if Replication.Kind (Feedback) not in
                       Replication.Standby_Status_Update |
                       Replication.Hot_Standby_Feedback
                     then
                        raise Protocol.Protocol_Error with
                          "standby sent backend replication data";
                     end if;
                  end;
               when Protocol.Frontend_Copy_Done =>
                  exit;
               when Protocol.Frontend_Copy_Fail =>
                  raise Protocol.Protocol_Error with
                    "standby aborted graceful COPY BOTH completion";
            end case;
         end;
      end loop;
      Replication_Sessions.Complete_Streaming (Client, Timeout => 10.0);
      Ada.Text_IO.Put_Line ("streaming complete");
      Ada.Text_IO.Flush;
   end Stream_WAL;

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Message : Protocol.Message) is
      Command : constant Replication.Command :=
        Replication.Decode_Command (Message);
   begin
      case Replication.Kind (Command) is
         when Replication.Identify_System_Command =>
            Replication_Sessions.Send_Identify_System
              (Client,
               System_Id   => State.System_Id,
               Timeline    => 1,
               Current_WAL => State.Current_WAL,
               Timeout     => 10.0);

         when Replication.Show_Command =>
            declare
               Parameter : constant String :=
                 Replication.Parameter (Command);
               Lower : constant String :=
                 Ada.Characters.Handling.To_Lower (Parameter);
               Value : constant String :=
                 (if Lower = "wal_segment_size"
                  then Ada.Strings.Fixed.Trim
                    (Replication.UInt64'Image
                       (State.Segment_Size / (1_024 * 1_024)),
                     Ada.Strings.Both) & "MB"
                  elsif Lower = "wal_level" then "replica"
                  else "on");
            begin
               Replication_Sessions.Send_Show
                 (Client, Parameter, Value, Timeout => 10.0);
            end;

         when Replication.Timeline_History_Command =>
            raise Protocol.Protocol_Error with
              "timeline 1 does not have a history file";

         when Replication.Start_Physical_Command =>
            if Length (State.Expected_Slot) > 0
              and then Replication.Slot_Name (Command) /=
                To_String (State.Expected_Slot)
            then
               raise Protocol.Protocol_Error with
                 "standby did not request the configured physical slot";
            end if;
            if Replication.Has_Timeline (Command)
              and then Replication.Timeline (Command) /= 1
            then
               raise Protocol.Protocol_Error with
                 "test primary only serves timeline 1";
            end if;
            Stream_WAL (State, Client, Replication.Position (Command));

         when Replication.Start_Logical_Command =>
            raise Protocol.Protocol_Error with
              "test primary only serves physical WAL";
      end case;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.SCRAM_SHA_256,
      Handler_Model         => Flyology.Lightweight_Task);

   Listener : Sockets.Socket_Type;
   State    : aliased Context;
   Server   : aliased Test_Server.Server (Capacity => 1);
   TLS_Backend : aliased OpenSSL.OpenSSL_Provider;
begin
   OpenSSL.Initialize_Server
     (TLS_Backend,
      Certificate_File =>
        Ada.Environment_Variables.Value ("POSTGRES_TLS_CERT_FILE"),
      Private_Key_File =>
        Ada.Environment_Variables.Value ("POSTGRES_TLS_KEY_FILE"),
      Library_Directory =>
        Ada.Environment_Variables.Value
          ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));
   State.System_Id := Replication.UInt64'Value
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_SYSTEM_ID"));
   State.Current_WAL := Replication.Value
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_END_LSN"));
   State.WAL_Directory := To_Unbounded_String
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_WAL_DIR"));
   State.Expected_Slot := To_Unbounded_String
     (Ada.Environment_Variables.Value
        ("POSTGRES_PRIMARY_SLOT", ""));
   State.Segment_Size := Replication.UInt64'Value
     (Ada.Environment_Variables.Value
        ("POSTGRES_PRIMARY_WAL_SEGMENT_SIZE", "16777216"));

   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Ada.Text_IO.Put_Line ("ready");
   Ada.Text_IO.Flush;
   Test_Server.Serve_TLS
     (Server,
      Listener,
      State,
      TLS_Backend,
      Policy        => Flyology.Postgres.TLS_Required,
      Drain_Timeout => 1.0);
end Postgres_Test_Replication_Server;
