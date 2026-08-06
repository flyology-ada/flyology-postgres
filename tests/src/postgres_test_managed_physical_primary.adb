with Ada.Environment_Variables;
with Ada.Streams;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.IO.TLS.OpenSSL;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Managed_Primary;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.SCRAM;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;
with Replication_Test_Durable_Store;

procedure Postgres_Test_Managed_Physical_Primary is

   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Logical renames Flyology.Postgres.Replication.Logical;
   package Persistence renames
     Flyology.Postgres.Replication.Persistence;
   package Durable is new Replication_Test_Durable_Store (Capacity => 8);
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;
   package OpenSSL renames Flyology.IO.TLS.OpenSSL;
   package Stream_IO renames Ada.Streams.Stream_IO;

   use type Ada.Streams.Stream_Element_Offset;
   use type Protocol.Replication_Connection_Mode;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Replication.UInt32;

   function Hex_8 (Value : Replication.UInt32) return String is
      Characters : constant String := "0123456789ABCDEF";
      Result     : String (1 .. 8) := (others => '0');
      Work       : Replication.UInt32 := Value;
   begin
      for Index in reverse Result'Range loop
         Result (Index) := Characters (Natural (Work mod 16) + 1);
         Work := Work / 16;
      end loop;
      return Result;
   end Hex_8;

   type File_WAL is limited new Persistence.WAL_Store with record
      Directory    : Unbounded_String;
      First        : Replication.LSN := 0;
      Current      : Replication.LSN := 0;
      Fork         : Replication.LSN := 0;
      Final        : Replication.LSN := 0;
      Segment_Size : Replication.UInt64 := 16 * 1_024 * 1_024;
      Timeline     : Replication.UInt32 := 1;
   end record;

   overriding function First_LSN
     (Item : File_WAL) return Replication.LSN;
   overriding function Current_LSN
     (Item : File_WAL) return Replication.LSN;
   overriding function Read
     (Item    : File_WAL;
      Start   : Replication.LSN;
      Maximum : Positive) return Persistence.Byte_Array;
   overriding procedure Append
     (Item  : in out File_WAL;
      Start : Replication.LSN;
      Data  : Persistence.Byte_Array);
   overriding procedure Retain_From
     (Item : in out File_WAL; Oldest : Replication.LSN);

   function File_Name (Item : File_WAL; Position : Replication.LSN)
      return String is
      Segment_Number : constant Replication.UInt64 :=
        Position / Item.Segment_Size;
      Segments_Per_Id : constant Replication.UInt64 :=
        16#1_0000_0000# / Item.Segment_Size;
      Log_Id : constant Replication.UInt32 := Replication.UInt32
        (Segment_Number / Segments_Per_Id);
      Segment_Id : constant Replication.UInt32 := Replication.UInt32
        (Segment_Number mod Segments_Per_Id);
   begin
      return To_String (Item.Directory) & "/" & Hex_8 (Item.Timeline)
        & Hex_8 (Log_Id) & Hex_8 (Segment_Id);
   end File_Name;

   overriding function First_LSN
     (Item : File_WAL) return Replication.LSN is
     (Item.First);

   overriding function Current_LSN
     (Item : File_WAL) return Replication.LSN is (Item.Current);

   overriding function Read
     (Item    : File_WAL;
      Start   : Replication.LSN;
      Maximum : Positive) return Persistence.Byte_Array is
      Offset : constant Replication.UInt64 := Start mod Item.Segment_Size;
      Count : constant Replication.UInt64 := Replication.UInt64'Min
        (Item.Current - Start,
         Replication.UInt64'Min
           (Item.Segment_Size - Offset, Replication.UInt64 (Maximum)));
      File : Stream_IO.File_Type;
   begin
      if Start < Item.First or else Start > Item.Current then
         raise Persistence.Store_Error with "file WAL read is out of range";
      elsif Count = 0 then
         return (1 .. 0 => 0);
      end if;
      declare
         Data : Persistence.Byte_Array
           (1 .. Ada.Streams.Stream_Element_Offset (Count));
         Last : Ada.Streams.Stream_Element_Offset;
      begin
         Stream_IO.Open (File, Stream_IO.In_File, File_Name (Item, Start));
         Stream_IO.Set_Index
           (File, Stream_IO.Count'Succ (Stream_IO.Count (Offset)));
         Stream_IO.Read (File, Data, Last);
         Stream_IO.Close (File);
         if Last /= Data'Last then
            raise Persistence.Store_Error with
              "timeline WAL file ended before the advertised position";
         end if;
         return Data;
      end;
   exception
      when others =>
         if Stream_IO.Is_Open (File) then
            Stream_IO.Close (File);
         end if;
         raise;
   end Read;

   overriding procedure Append
     (Item  : in out File_WAL;
      Start : Replication.LSN;
      Data  : Persistence.Byte_Array) is
      pragma Unreferenced (Item, Start, Data);
   begin
      raise Persistence.Store_Error with "file WAL source is read-only";
   end Append;

   overriding procedure Retain_From
     (Item : in out File_WAL; Oldest : Replication.LSN) is
      Segment_First : constant Replication.LSN :=
        Oldest - Oldest mod Item.Segment_Size;
   begin
      if Oldest > Item.Current then
         raise Persistence.Store_Error with "file WAL retention exceeds end";
      elsif Segment_First > Item.First then
         --  Physical retention removes whole WAL segments.  Keeping the
         --  prefix of the segment containing a timeline fork is essential:
         --  a standby asks for that segment boundary when it switches to the
         --  promoted timeline.
         Item.First := Segment_First;
      end if;
   end Retain_From;

   type Logical_Source is limited null record;

   procedure Next_Logical
     (Context    : in out Logical_Source;
      Slot_Name : String;
      After_LSN  : Replication.LSN;
      Available  : out Boolean;
      WAL_Start  : out Replication.LSN;
      WAL_End    : out Replication.LSN;
      Message    : out Logical.Message) is
      pragma Unreferenced (Context, Slot_Name);
   begin
      Available := False;
      WAL_Start := After_LSN;
      WAL_End := After_LSN;
      Message := Logical.Make_Begin (1, 0, 1);
   end Next_Logical;

   package Managed is new Flyology.Postgres.Replication.Managed_Primary
     (Logical_Context => Logical_Source,
      Next_Logical    => Next_Logical);

   type Context is limited record
      Verifier : Unbounded_String := To_Unbounded_String
        (Flyology.Postgres.SCRAM.Make_Verifier_Raw
           ("flyology-secret",
            Flyology.Postgres.SCRAM.To_Bytes
              ("Flyology managed timeline salt")));
   end record;

   Store  : aliased Durable.Store;
   WAL    : aliased File_WAL;
   Source : aliased Logical_Source;
   Primary : Managed.Primary
     (Slots          => Store'Access,
      WAL            => WAL'Access,
      Timelines      => Store'Access,
      Logical_Source => Source'Access);

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

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Message : Protocol.Message) is
      pragma Unreferenced (State);
      Command : constant Replication.Command :=
        Replication.Decode_Command (Message);
   begin
      if Replication.Kind (Command) =
        Replication.Timeline_History_Command
      then
         Ada.Text_IO.Put_Line
           ("timeline history requested="
            & Replication.UInt32'Image (Replication.Timeline (Command)));
         Ada.Text_IO.Flush;
      elsif Replication.Kind (Command) =
        Replication.Start_Physical_Command
        and then Replication.Has_Timeline (Command)
      then
         WAL.Timeline := Replication.Timeline (Command);
         if WAL.Timeline = 1 then
            WAL.Current := WAL.Fork;
         elsif WAL.Timeline = 2 then
            WAL.Current := WAL.Final;
         else
            raise Protocol.Protocol_Error with
              "managed test primary has no requested WAL timeline";
         end if;
      end if;
      Managed.Handle (Primary, Client, Command);
      if Replication.Kind (Command) = Replication.Start_Physical_Command
        and then Replication.Slot_Name (Command)'Length > 0
      then
         declare
            Slot : constant Persistence.Slot_State := Durable.Load
              (Store, Replication.Slot_Name (Command));
         begin
            Ada.Text_IO.Put_Line
              ("physical stream complete slot="
               & Replication.Slot_Name (Command) & " restart="
               & Replication.Image (Persistence.Restart_LSN (Slot)));
            Ada.Text_IO.Flush;
         end;
      end if;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.SCRAM_SHA_256,
      Handler_Model         => Flyology.Lightweight_Task);

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_REPLICATION_SERVER_PORT")));

   Listener : Sockets.Socket_Type;
   State : aliased Context;
   Server : aliased Test_Server.Server (Capacity => 2);
   TLS_Backend : aliased OpenSSL.OpenSSL_Provider;
begin
   Durable.Open
     (Store,
      Ada.Environment_Variables.Value ("POSTGRES_DURABLE_STORE_DIR"));
   WAL.Directory := To_Unbounded_String
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_WAL_DIR"));
   WAL.First := Replication.Value
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_FIRST_LSN"));
   WAL.Current := Replication.Value
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_END_LSN"));
   WAL.Final := WAL.Current;
   WAL.Fork := Replication.Value
     (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_FORK_LSN"));
   WAL.Timeline := Durable.Current_Timeline (Store);
   WAL.Segment_Size := Replication.UInt64'Value
     (Ada.Environment_Variables.Value
        ("POSTGRES_PRIMARY_WAL_SEGMENT_SIZE", "16777216"));
   Managed.Initialize
     (Primary,
      System_Id => Replication.UInt64'Value
        (Ada.Environment_Variables.Value ("POSTGRES_PRIMARY_SYSTEM_ID")),
      Timeout => 30.0);

   OpenSSL.Initialize_Server
     (TLS_Backend,
      Certificate_File =>
        Ada.Environment_Variables.Value ("POSTGRES_TLS_CERT_FILE"),
      Private_Key_File =>
        Ada.Environment_Variables.Value ("POSTGRES_TLS_KEY_FILE"),
      Library_Directory =>
        Ada.Environment_Variables.Value
          ("FLYOLOGY_OPENSSL_LIBRARY_DIR", ""));
   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Ada.Text_IO.Put_Line
     ("ready timeline=" & Replication.UInt32'Image (WAL.Timeline));
   Ada.Text_IO.Flush;
   Test_Server.Serve_TLS
     (Server, Listener, State, TLS_Backend,
      Policy => Flyology.Postgres.TLS_Required, Drain_Timeout => 1.0);
   Durable.Close (Store);
end Postgres_Test_Managed_Physical_Primary;
