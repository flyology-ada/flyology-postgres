with Ada.Command_Line;
with Ada.Characters.Handling;
with Ada.Exceptions;
with Ada.Real_Time;
with Ada.Text_IO;
with Flyology;
with Flyology.Cancellation;
with Flyology.Supervision;
with Flyology.Supervision.Children;
with Flyology.Supervision.Static;
with Psqlbench_Context;
with Psqlbench_Docker;
with Psqlbench_Logs;
with Psqlbench_JSON;
with Psqlbench_Links;
with Psqlbench_Persistence;
with Psqlbench_Server;
with Psqlbench_Signals;

procedure Psqlbench is
   use type Flyology.Execution_Model;
   use type Flyology.Supervision.Supervisor_Outcome;

   type Service_Kind is
     (Docker_Control, Topology_Control, Log_Control, Link_Control,
      HTTP_Control);

   function Logical_Id
     (Child : Service_Kind) return Flyology.Supervision.Child_Id is
     (case Child is
         when Docker_Control => 1,
         when Topology_Control => 2,
         when Log_Control    => 3,
         when Link_Control   => 4,
         when HTTP_Control   => 5);

   function Service_Key (Child : Service_Kind) return String is
     (case Child is
         when Docker_Control   => "service.docker",
         when Topology_Control => "service.topology",
         when Log_Control      => "service.logs",
         when Link_Control     => "service.links",
         when HTTP_Control     => "service.http");

   function Service_Name (Child : Service_Kind) return String is
     (case Child is
         when Docker_Control   => "Docker control",
         when Topology_Control => "Topology reconciliation",
         when Log_Control      => "Postgres log collection",
         when Link_Control     => "Replication link control",
         when HTTP_Control     => "HTTP control plane");

   function Execution_Model_Name
     (Model : Flyology.Execution_Model) return String is
     (if Model = Flyology.Native_Task then "native task"
      elsif Model = Flyology.Lightweight_Task then "lightweight task"
      else Ada.Characters.Handling.To_Lower (Model'Image));

   function Specification
     (Child : Service_Kind)
      return Flyology.Supervision.Child_Specification
   is
      Value : Flyology.Supervision.Child_Specification :=
        (others => <>);
   begin
      Value.Restart := Flyology.Supervision.On_Failure;
      Value.Impact :=
        (case Child is
            when Docker_Control => Flyology.Supervision.Restart_Dependents,
            when Topology_Control => Flyology.Supervision.Restart_Dependents,
            when Log_Control    => Flyology.Supervision.Restart_Dependents,
            when Link_Control   => Flyology.Supervision.Restart_Dependents,
            when HTTP_Control   => Flyology.Supervision.Isolate_Child);
      Value.Stopping :=
        (Grace             => Ada.Real_Time.Seconds (3),
         Request_Abort     => False,
         Abort_Observation => Ada.Real_Time.Seconds (1));
      Value.Readiness_Timeout :=
        (if Child = Topology_Control
         then Ada.Real_Time.Seconds (120)
         else Ada.Real_Time.Seconds (15));
      Value.Restart_Safe := True;
      Value.Task_Model := Flyology.Native_Task;
      Value.Has_Group := False;
      Value.Group := 0;
      return Value;
   end Specification;

   function Depends_On
     (Child        : Service_Kind;
      Prerequisite : Service_Kind) return Boolean is
     ((Child = Topology_Control and then Prerequisite = Docker_Control)
      or else (Child = Log_Control and then Prerequisite = Topology_Control)
      or else (Child = Link_Control and then Prerequisite = Topology_Control)
      or else (Child = HTTP_Control and then Prerequisite = Log_Control)
      or else (Child = HTTP_Control and then Prerequisite = Link_Control));

   function No_Cohort
     (Trigger : Service_Kind;
      Member  : Service_Kind) return Boolean
   is
      pragma Unreferenced (Trigger, Member);
   begin
      return False;
   end No_Cohort;

   function Docker_Ready_Document return String is
      Document : Psqlbench_JSON.Writer;
   begin
      Psqlbench_JSON.Initialize (Document);
      Psqlbench_JSON.Start_Object (Document);
      Psqlbench_JSON.String_Value (Document, "type", "docker.ready");
      Psqlbench_JSON.String_Value (Document, "transport", "unix-http");
      Psqlbench_JSON.End_Object (Document);
      return Psqlbench_JSON.Finish (Document);
   end Docker_Ready_Document;

   procedure Run_Docker
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      use type Ada.Real_Time.Time;
      Deadline : constant Ada.Real_Time.Time :=
        Ada.Real_Time.Clock + Ada.Real_Time.Seconds (10);
      Checked : constant Psqlbench_Docker.Result :=
        Psqlbench_Docker.Check
          (Flyology.Supervision.Stopping (Control.all), Deadline);
   begin
      if not Checked.Success then
         Context.Docker.Set (False, Psqlbench_Docker.Text (Checked));
         raise Program_Error with
           "Docker is not ready: " & Psqlbench_Docker.Text (Checked);
      end if;

      declare
         Network : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.Ensure_Network
             (Flyology.Supervision.Stopping (Control.all), Deadline);
      begin
         if not Network.Success then
            Context.Docker.Set (False, Psqlbench_Docker.Text (Network));
            raise Program_Error with
              "cannot prepare Docker network: "
              & Psqlbench_Docker.Text (Network);
         end if;
      end;

      Context.Docker.Set
        (True, "Docker daemon connected over Flyology HTTP Unix transport");
      Context.Events.Append (Docker_Ready_Document);
      Flyology.Supervision.Mark_Ready (Control.all);
      loop
         if Flyology.Supervision.Stopping (Control.all).Requested then
            Context.Docker.Set (False, "Docker control service stopped");
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.100;
      end loop;
   end Run_Docker;

   package Docker_Child is new Flyology.Supervision.Children
     (Application_Context => Psqlbench_Context.Context,
      Execute             => Run_Docker,
      Task_Model          => Flyology.Native_Task);

   procedure Run_Topology
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control) is
      use type Ada.Real_Time.Time;
   begin
      Psqlbench_Persistence.Load_And_Reconcile
        (Context,
         Flyology.Supervision.Stopping (Control.all),
         Ada.Real_Time.Clock + Ada.Real_Time.Seconds (120));
      Flyology.Supervision.Mark_Ready (Control.all);
      loop
         if Flyology.Supervision.Stopping (Control.all).Requested then
            raise Flyology.Cancellation.Operation_Cancelled;
         end if;
         delay 0.100;
      end loop;
   exception
      when Error : others =>
         Ada.Text_IO.Put_Line
           (Ada.Text_IO.Standard_Error,
            "topology reconciliation failed: "
            & Ada.Exceptions.Exception_Information (Error));
         raise;
   end Run_Topology;

   package Topology_Child is new Flyology.Supervision.Children
     (Application_Context => Psqlbench_Context.Context,
      Execute             => Run_Topology,
      Task_Model          => Flyology.Native_Task);

   package HTTP_Child is new Flyology.Supervision.Children
     (Application_Context => Psqlbench_Context.Context,
      Execute             => Psqlbench_Server.Execute,
      Task_Model          => Flyology.Native_Task);

   package Log_Child is new Flyology.Supervision.Children
     (Application_Context => Psqlbench_Context.Context,
      Execute             => Psqlbench_Logs.Execute,
      Task_Model          => Flyology.Native_Task);

   package Link_Child is new Flyology.Supervision.Children
     (Application_Context => Psqlbench_Context.Context,
      Execute             => Psqlbench_Links.Execute,
      Task_Model          => Flyology.Native_Task);

   procedure Run_One_Generation
     (Context : aliased in out Psqlbench_Context.Context;
      Child   : Service_Kind;
      Control : aliased in out Flyology.Supervision.Generation_Control;
      Result  : out Flyology.Supervision.Generation_Result) is
   begin
      case Child is
         when Docker_Control =>
            Docker_Child.Run (Context, Control, Result);
         when Topology_Control =>
            Topology_Child.Run (Context, Control, Result);
         when Log_Control =>
            Log_Child.Run (Context, Control, Result);
         when Link_Control =>
            Link_Child.Run (Context, Control, Result);
         when HTTP_Control =>
            HTTP_Child.Run (Context, Control, Result);
      end case;
   end Run_One_Generation;

   package Supervisors is new Flyology.Supervision.Static
     (Child_Kind          => Service_Kind,
      Application_Context => Psqlbench_Context.Context,
      Logical_Id          => Logical_Id,
      Specification       => Specification,
      Depends_On          => Depends_On,
      Cohort_Member       => No_Cohort,
      Run_One_Generation  => Run_One_Generation);

   Context    : aliased Psqlbench_Context.Context;
   Supervisor : aliased Supervisors.Supervisor;
   Result     : Flyology.Supervision.Supervisor_Result;
   Docker_Started : Boolean := False;

   procedure Publish_Supervision is
      type Snapshot_Array is array (Service_Kind) of
        Flyology.Supervision.Child_Snapshot;
      Snapshots : Snapshot_Array;
      Ready_Count : Natural := 0;
   begin
      for Child in Service_Kind loop
         Snapshots (Child) := Supervisors.Current (Supervisor, Child);
         if Snapshots (Child).Ready then
            Ready_Count := Ready_Count + 1;
         end if;
      end loop;

      Context.Supervision.Upsert
        (Key         => "psqlbench",
         Parent      => "",
         Name        => "psqlbench service supervisor",
         Kind        => Psqlbench_Context.Supervisor_Node,
         State       =>
           (if Ready_Count = Service_Kind'Pos (Service_Kind'Last) + 1
            then "running"
            else "starting"),
         Model       => "static supervisor",
         Ready       => Ready_Count = Service_Kind'Pos (Service_Kind'Last) + 1,
         Live        => True,
         Capacity    => Service_Kind'Pos (Service_Kind'Last) + 1,
         Child_Count => Service_Kind'Pos (Service_Kind'Last) + 1);

      for Child in Service_Kind loop
         declare
            Snapshot : Flyology.Supervision.Child_Snapshot
              renames Snapshots (Child);
         begin
            Context.Supervision.Upsert
              (Key         => Service_Key (Child),
               Parent      => "psqlbench",
               Name        => Service_Name (Child),
               Kind        => Psqlbench_Context.Static_Child_Node,
               State       => Ada.Characters.Handling.To_Lower
                 (Snapshot.State'Image),
               Model       => Execution_Model_Name (Snapshot.Task_Model),
               Child       => Snapshot.Id,
               Generation  => Snapshot.Generation,
               Attempts    => Snapshot.Attempts,
               Ready       => Snapshot.Ready,
               Live        => Snapshot.Live,
               Escalated   => Snapshot.Escalated);
         end;
      end loop;
   end Publish_Supervision;

   task Signal_Watcher is
      pragma Task_Info (Flyology.Native_Task);
   end Signal_Watcher;

   task body Signal_Watcher is
   begin
      loop
         exit when Psqlbench_Signals.Completed;
         if Psqlbench_Signals.Stop_Requested then
            Supervisors.Request_Shutdown (Supervisor);
            exit;
         end if;
         delay 0.050;
      end loop;
   end Signal_Watcher;

   task Supervision_Observer is
      pragma Task_Info (Flyology.Native_Task);
   end Supervision_Observer;

   task body Supervision_Observer is
   begin
      loop
         Publish_Supervision;
         exit when Psqlbench_Signals.Completed;
         delay 0.100;
      end loop;
   end Supervision_Observer;

begin
   Psqlbench_Docker.Start;
   Docker_Started := True;
   Supervisors.Run (Supervisor, Context, Result);
   Psqlbench_Signals.Complete;
   Psqlbench_Docker.Shutdown;
   Docker_Started := False;

   if Result.Outcome /= Flyology.Supervision.Shutdown_Completed then
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "psqlbench stopped: " & Result.Outcome'Image
         & " child=" & Result.Child'Image
         & " reason=" & Result.Termination.Kind'Image
         & (if Result.Termination.Message_Length = 0 then ""
            else " " & Result.Termination.Message
              (1 .. Result.Termination.Message_Length)));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
   end if;
exception
   when Error : others =>
      Psqlbench_Signals.Complete;
      if Docker_Started then
         Psqlbench_Docker.Shutdown;
      end if;
      Ada.Text_IO.Put_Line
        (Ada.Text_IO.Standard_Error,
         "psqlbench failed: " & Ada.Exceptions.Exception_Information (Error));
      Ada.Command_Line.Set_Exit_Status (Ada.Command_Line.Failure);
end Psqlbench;
