with Ada.Environment_Variables;
with Ada.Text_IO;
with Flyology;
with Flyology.IO.Sockets;
with Flyology.Postgres;
with Flyology.Postgres.Protocol;
with Flyology.Postgres.Replication;
with Flyology.Postgres.Replication.Logical;
with Flyology.Postgres.Replication.Managed_Primary;
with Flyology.Postgres.Replication.Persistence;
with Flyology.Postgres.Replication.Persistence.Memory;
with Flyology.Postgres.Server;
with Flyology.Postgres.Server_Sessions;

procedure Postgres_Test_Logical_Primary is

   package Protocol renames Flyology.Postgres.Protocol;
   package Replication renames Flyology.Postgres.Replication;
   package Logical renames Flyology.Postgres.Replication.Logical;
   package Persistence renames
     Flyology.Postgres.Replication.Persistence;
   package Memory is new
     Flyology.Postgres.Replication.Persistence.Memory (Capacity => 8);
   package Sessions renames Flyology.Postgres.Server_Sessions;
   package Sockets renames Flyology.IO.Sockets;

   use type Protocol.Replication_Connection_Mode;
   use type Protocol.Frontend_Kind;
   use type Replication.Command_Kind;
   use type Replication.LSN;
   use type Persistence.Create_Result;

   type Logical_Event is record
      Start_LSN : Replication.LSN := 0;
      End_LSN   : Replication.LSN := 0;
      Message   : Logical.Message;
   end record;
   type Logical_Event_Array is array (Positive range <>) of Logical_Event;

   type Logical_Source is limited record
      Events : Logical_Event_Array (1 .. 4);
   end record;

   procedure Next_Logical
     (Context    : in out Logical_Source;
      Slot_Name : String;
      After_LSN  : Replication.LSN;
      Available  : out Boolean;
      WAL_Start  : out Replication.LSN;
      WAL_End    : out Replication.LSN;
      Message    : out Logical.Message) is
      pragma Unreferenced (Slot_Name);
   begin
      for Item of Context.Events loop
         if Item.End_LSN > After_LSN then
            Available := True;
            WAL_Start := Item.Start_LSN;
            WAL_End := Item.End_LSN;
            Message := Item.Message;
            return;
         end if;
      end loop;
      Available := False;
      WAL_Start := After_LSN;
      WAL_End := After_LSN;
      Message := Logical.Make_Begin (1, 0, 1);
   end Next_Logical;

   package Managed is new
     Flyology.Postgres.Replication.Managed_Primary
       (Logical_Context => Logical_Source,
        Next_Logical    => Next_Logical);

   type Context is limited null record;

   Store  : aliased Memory.Store;
   Source : aliased Logical_Source;
   Primary : Managed.Primary
     (Slots         => Store'Access,
      WAL           => Store'Access,
      Timelines     => Store'Access,
      Logical_Source => Source'Access);

   function Authenticate
     (State    : in out Context;
      Startup  : Protocol.Startup_Information;
      Password : String) return Boolean is
      pragma Unreferenced (State, Password);
   begin
      return Startup.Replication_Mode =
        Protocol.Logical_Replication_Connection;
   end Authenticate;

   function Lookup_SCRAM_Verifier
     (State   : in out Context;
      Startup : Protocol.Startup_Information) return String is
      pragma Unreferenced (State, Startup);
   begin
      return "";
   end Lookup_SCRAM_Verifier;

   procedure Handle
     (State   : in out Context;
      Client  : in out Sessions.Session;
      Message : Protocol.Message) is
      pragma Unreferenced (State);
   begin
      if Protocol.Kind (Message) = Protocol.Query
        and then Sessions.Query_Text (Message) =
          "SELECT pg_catalog.set_config('search_path', '', false);"
      then
         Sessions.Send_Row_Description
           (Client, "set_config", Timeout => 10.0);
         Sessions.Send_Data_Row (Client, "", Timeout => 10.0);
         Sessions.Send_Command_Complete
           (Client, "SELECT 1", Timeout => 10.0);
         Sessions.Send_Ready (Client, Timeout => 10.0);
      else
         declare
            Command : constant Replication.Command :=
              Replication.Decode_Command (Message);
         begin
            Managed.Handle (Primary, Client, Command);
            if Replication.Kind (Command) =
              Replication.Start_Logical_Command
            then
               declare
                  Slot : constant Persistence.Slot_State :=
                    Memory.Load
                      (Store, Replication.Slot_Name (Command));
               begin
                  Ada.Text_IO.Put_Line
                    ("logical stream complete confirmed="
                     & Replication.Image
                       (Persistence.Confirmed_LSN (Slot)));
                  Ada.Text_IO.Flush;
               end;
            end if;
         end;
      end if;
   end Handle;

   package Test_Server is new Flyology.Postgres.Server
     (Handler_Context       => Context,
      Authenticate          => Authenticate,
      Lookup_SCRAM_Verifier => Lookup_SCRAM_Verifier,
      Handle                => Handle,
      Authentication        => Flyology.Postgres.Trust,
      Handler_Model         => Flyology.Lightweight_Task);

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value
           ("POSTGRES_LOGICAL_PRIMARY_PORT", "55438")));

   Marker : constant String := Ada.Environment_Variables.Value
     ("POSTGRES_LOGICAL_PRIMARY_MARKER", "managed-pgoutput");
   Tuple : constant Logical.Tuple_Data := Logical.Make_Tuple
     ((Logical.Text_Column ("1"), Logical.Text_Column (Marker)));
   Created : Persistence.Create_Result;
   Listener : Sockets.Socket_Type;
   State : aliased Context;
   Server : aliased Test_Server.Server (Capacity => 1);
begin
   Memory.Create
     (Store,
      "flyology_output",
      Persistence.Make_Slot
        (Persistence.Logical_Slot,
         Restart_LSN   => 16#100#,
         Confirmed_LSN => 16#100#,
         Plugin        => "pgoutput"),
      Created);
   if Created /= Persistence.Created then
      raise Program_Error with "logical primary slot was not created";
   end if;
   Memory.Append
     (Store, Start => 16#100#, Data => (1 .. 64 => 0));

   Source.Events :=
     ((16#100#, 16#110#, Logical.Make_Begin (16#130#, 0, 10)),
      (16#110#, 16#120#,
       Logical.Make_Relation
         (42, "public", "flyology_output", Logical.Default_Identity,
          (Logical.Make_Relation_Column
             ("id", Type_Oid => 23, Is_Key => True),
           Logical.Make_Relation_Column ("payload", Type_Oid => 25)))),
      (16#120#, 16#130#, Logical.Make_Insert (42, Tuple)),
      (16#130#, 16#140#, Logical.Make_Commit (16#130#, 16#140#, 0)));
   Managed.Initialize
     (Primary, System_Id => 7_777_777, Database => "postgres",
      Timeout => 10.0);

   Sockets.Create_Socket (Listener);
   Sockets.Set_Socket_Option
     (Listener, (Name => Sockets.Reuse_Address, Enabled => True));
   Sockets.Bind_Socket
     (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
   Sockets.Listen_Socket (Listener, Length => 4);
   Ada.Text_IO.Put_Line ("ready");
   Ada.Text_IO.Flush;
   Test_Server.Serve (Server, Listener, State, Drain_Timeout => 1.0);
end Postgres_Test_Logical_Primary;
