with Ada.Environment_Variables;
with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded; use Ada.Strings.Unbounded;
with Ada.Text_IO;
with Flyology;
with Flyology.Bytes;
with Flyology.HTTP.Server;
with Flyology.HTTP.Server.Applications;
with Flyology.HTTP.Server.Connections;
with Flyology.HTTP.Server.Routing;
with Flyology.IO.Connections;
with Flyology.IO;
with Flyology.IO.Sockets;
with Flyology.IO.Structured_Servers;
with Flyology.Postgres.Replication;
with Interfaces;
with Psqlbench_Assets;
with Psqlbench_Docker;
with Psqlbench_JSON;
with Psqlbench_Query;

package body Psqlbench_Server is

   package HTTP renames Flyology.HTTP.Server;
   package App renames Flyology.HTTP.Server.Applications;
   package Owned renames Flyology.IO.Connections;
   package Sockets renames Flyology.IO.Sockets;

   use type Interfaces.Unsigned_64;
   use type Psqlbench_Context.Link_Mode;

   function Compact (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function JSON_Integer
     (Value : Interfaces.Unsigned_64) return Long_Long_Integer is
     (if Value > Interfaces.Unsigned_64 (Long_Long_Integer'Last)
      then Long_Long_Integer'Last
      else Long_Long_Integer (Value));

   function Port return Sockets.Port is
     (Sockets.Port'Value
        (Ada.Environment_Variables.Value ("PSQLBENCH_PORT", "8080")));

   function Diagnostic (Value : String) return String is
      Limit : constant Natural := Natural'Min (Value'Length, 320);
   begin
      return
        (if Limit = 0 then "Docker command failed"
         else Value (Value'First .. Value'First + Limit - 1));
   end Diagnostic;

   procedure Execute
     (Context : in out Psqlbench_Context.Context;
      Control : not null access Flyology.Supervision.Generation_Control)
   is
      type Application_Context is limited record
         Root   : access Psqlbench_Context.Context;
         Assets : Psqlbench_Assets.Bundle;
      end record;

      package Routing is new HTTP.Routing (Application_Context);

      function Status_Document
        (Ready : Boolean; Detail : String) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.Boolean_Value (Document, "docker_ready", Ready);
         Psqlbench_JSON.String_Value (Document, "docker_transport", "cli");
         Psqlbench_JSON.String_Value (Document, "detail", Detail);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Status_Document;

      function Instance_Document
        (Name, Version : String; Port_No : Natural;
         Event         : Boolean) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         if Event then
            Psqlbench_JSON.String_Value
              (Document, "type", "instance.created");
         end if;
         Psqlbench_JSON.String_Value (Document, "name", Name);
         Psqlbench_JSON.String_Value (Document, "version", Version);
         Psqlbench_JSON.Integer_Value
           (Document, "port", Long_Long_Integer (Port_No));
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Instance_Document;

      function Action_Document
        (Name, Action : String; Event : Boolean) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         if Event then
            Psqlbench_JSON.String_Value
              (Document, "type", "instance." & Action);
         end if;
         Psqlbench_JSON.String_Value (Document, "name", Name);
         Psqlbench_JSON.String_Value (Document, "action", Action);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Action_Document;

      function Count_Document
        (Kind : String; Count : Psqlbench_Context.Event_Sequence)
         return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", Kind);
         Psqlbench_JSON.Integer_Value
           (Document, "count", Long_Long_Integer (Count));
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Count_Document;

      function Log_Document
        (Value : Psqlbench_Context.Log_Record) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document, 4 * 1_024);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", "instance.log");
         Psqlbench_JSON.String_Value
           (Document, "name", Value.Name (1 .. Value.Name_Length));
         Psqlbench_JSON.Integer_Value
           (Document, "sequence", Long_Long_Integer (Value.Sequence));
         Psqlbench_JSON.String_Value
           (Document, "line", Value.Data (1 .. Value.Data_Length));
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Log_Document;

      function Attached_Document
        (Name : String; Port_No : Positive) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", "query.attached");
         Psqlbench_JSON.String_Value (Document, "instance", Name);
         Psqlbench_JSON.Integer_Value
           (Document, "port", Long_Long_Integer (Port_No));
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Attached_Document;

      function Message_Document
        (Kind, Message : String) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", Kind);
         Psqlbench_JSON.String_Value (Document, "message", Message);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Message_Document;

      function Simple_Document (Kind : String) return String is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", Kind);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Simple_Document;

      function HTTP_Ready_Document (Port_No : Natural) return String is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", "http.ready");
         Psqlbench_JSON.Integer_Value
           (Document, "port", Long_Long_Integer (Port_No));
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end HTTP_Ready_Document;

      function Link_Status_Image
        (Value : Psqlbench_Context.Link_Status) return String is
      begin
         case Value is
            when Psqlbench_Context.Link_Empty    => return "empty";
            when Psqlbench_Context.Link_Pending  => return "pending";
            when Psqlbench_Context.Link_Starting => return "starting";
            when Psqlbench_Context.Link_Running  => return "running";
            when Psqlbench_Context.Link_Stopping => return "stopping";
            when Psqlbench_Context.Link_Stopped  => return "stopped";
            when Psqlbench_Context.Link_Failed   => return "failed";
         end case;
      end Link_Status_Image;

      function Link_Mode_Image
        (Value : Psqlbench_Context.Link_Mode) return String is
        (case Value is
            when Psqlbench_Context.Logical_Committed => "logical-committed",
            when Psqlbench_Context.Logical_Streaming => "logical-streaming",
            when Psqlbench_Context.Logical_Two_Phase => "logical-two-phase",
            when Psqlbench_Context.Logical_Two_Phase_Streaming =>
              "logical-two-phase-streaming",
            when Psqlbench_Context.Physical_Streaming => "physical-streaming");

      function Links_Document
        (Value : Psqlbench_Context.Link_Array; Count : Natural)
         return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Array (Document);
         for Index in 1 .. Count loop
            Psqlbench_JSON.Start_Object (Document);
            Psqlbench_JSON.String_Value
              (Document, "name",
               Value (Index).Name (1 .. Value (Index).Name_Length));
            Psqlbench_JSON.String_Value
              (Document, "source",
               Value (Index).Source (1 .. Value (Index).Source_Length));
            Psqlbench_JSON.String_Value
              (Document, "target",
               Value (Index).Target (1 .. Value (Index).Target_Length));
            if Value (Index).Target_Version_Length > 0 then
               Psqlbench_JSON.String_Value
                 (Document, "target_version",
                  Value (Index).Target_Version
                    (1 .. Value (Index).Target_Version_Length));
            end if;
            if Value (Index).Target_Port > 0 then
               Psqlbench_JSON.Integer_Value
                 (Document, "target_port",
                  Long_Long_Integer (Value (Index).Target_Port));
            end if;
            Psqlbench_JSON.String_Value
              (Document, "table",
               Value (Index).Table_Name (1 .. Value (Index).Table_Length));
            Psqlbench_JSON.String_Value
              (Document, "source_relation",
               Value (Index).Source_Schema
                 (1 .. Value (Index).Source_Schema_Length) & "."
               & Value (Index).Source_Table
                 (1 .. Value (Index).Source_Table_Length));
            Psqlbench_JSON.String_Value
              (Document, "target_relation",
               Value (Index).Target_Schema
                 (1 .. Value (Index).Target_Schema_Length) & "."
               & Value (Index).Target_Table
                 (1 .. Value (Index).Target_Table_Length));
            Psqlbench_JSON.String_Value
              (Document, "status", Link_Status_Image (Value (Index).Status));
            Psqlbench_JSON.String_Value
              (Document, "mode", Link_Mode_Image (Value (Index).Mode));
            Psqlbench_JSON.Integer_Value
              (Document, "relay_port",
               Long_Long_Integer (Value (Index).Relay_Port));
            Psqlbench_JSON.Integer_Value
              (Document, "changes",
               Long_Long_Integer (Value (Index).Change_Count));
            if Value (Index).Last_LSN > 0 then
               Psqlbench_JSON.String_Value
                 (Document, "last_lsn",
                  Flyology.Postgres.Replication.Image
                    (Flyology.Postgres.Replication.LSN
                       (Value (Index).Last_LSN)));
            end if;
            if Value (Index).Applied_LSN > 0 then
               Psqlbench_JSON.String_Value
                 (Document, "applied_lsn",
                  Flyology.Postgres.Replication.Image
                    (Flyology.Postgres.Replication.LSN
                       (Value (Index).Applied_LSN)));
            end if;
            declare
               Start : constant Interfaces.Unsigned_64 :=
                 Value (Index).Start_LSN;
               Current : constant Interfaces.Unsigned_64 :=
                 Value (Index).Last_LSN;
               Applied : constant Interfaces.Unsigned_64 :=
                 Value (Index).Applied_LSN;
               Span : constant Interfaces.Unsigned_64 :=
                 (if Current > Start then Current - Start else 0);
               Replayed : constant Interfaces.Unsigned_64 :=
                 (if Applied > Start
                  then Interfaces.Unsigned_64'Min (Applied - Start, Span)
                  else 0);
               Lag : constant Interfaces.Unsigned_64 :=
                 (if Current > Applied then Current - Applied else 0);
            begin
               Psqlbench_JSON.Integer_Value
                 (Document, "span_bytes", JSON_Integer (Span));
               Psqlbench_JSON.Integer_Value
                 (Document, "replayed_bytes", JSON_Integer (Replayed));
               Psqlbench_JSON.Integer_Value
                 (Document, "lag_bytes", JSON_Integer (Lag));
               Psqlbench_JSON.Boolean_Value
                 (Document, "caught_up",
                  Current > 0 and then Applied >= Current);
            end;
            Psqlbench_JSON.String_Value
              (Document, "detail",
               (if Value (Index).Detail_Length = 0 then ""
                else Value (Index).Detail
                  (1 .. Value (Index).Detail_Length)));
            Psqlbench_JSON.End_Object (Document);
         end loop;
         Psqlbench_JSON.End_Array (Document);
         return Psqlbench_JSON.Finish (Document);
      end Links_Document;

      function Link_Document
        (Name, Source, Target, Status : String) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "name", Name);
         if Source'Length > 0 then
            Psqlbench_JSON.String_Value (Document, "source", Source);
            Psqlbench_JSON.String_Value (Document, "target", Target);
         end if;
         Psqlbench_JSON.String_Value (Document, "status", Status);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Link_Document;

      function Link_Event_Document
        (Name, Kind : String) return String
      is
         Document : Psqlbench_JSON.Writer;
      begin
         Psqlbench_JSON.Initialize (Document);
         Psqlbench_JSON.Start_Object (Document);
         Psqlbench_JSON.String_Value (Document, "type", "link.activity");
         Psqlbench_JSON.String_Value (Document, "link", Name);
         Psqlbench_JSON.String_Value (Document, "stage", "control");
         Psqlbench_JSON.String_Value
           (Document, "direction", "source-to-target");
         Psqlbench_JSON.String_Value (Document, "kind", Kind);
         Psqlbench_JSON.End_Object (Document);
         return Psqlbench_JSON.Finish (Document);
      end Link_Event_Document;

      procedure Home
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/html; charset=utf-8", To_String (State.Assets.HTML));
      end Home;

      procedure Stylesheet
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/css; charset=utf-8",
            To_String (State.Assets.Stylesheet));
      end Stylesheet;

      procedure Script
        (State : in out Application_Context;
         X     : in out App.Exchange) is
      begin
         X.Set_Header ("Cache-Control", "no-store");
         X.Respond
           (200, "text/javascript; charset=utf-8",
            To_String (State.Assets.Script));
      end Script;

      procedure Status
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Detail : String (1 .. 256);
         Last   : Natural;
      begin
         State.Root.Docker.Read_Detail (Detail, Last);
         X.JSON
           (200,
            Status_Document
              (State.Root.Docker.Ready,
               (if Last = 0 then "" else Detail (1 .. Last))));
      end Status;

      procedure Instances
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
         Value : constant Psqlbench_Docker.Result :=
           Psqlbench_Docker.List_Instances (X.Cancellation, X.Deadline);
      begin
         if Value.Success then
            X.JSON (200, Psqlbench_Docker.Text (Value));
         else
            X.Problem
              (503, "docker-list-failed",
               Diagnostic (Psqlbench_Docker.Text (Value)));
         end if;
      end Instances;

      procedure Links
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Value : Psqlbench_Context.Link_Array;
         Count : Natural;
      begin
         State.Root.Links.Snapshot (Value, Count);
         X.JSON (200, Links_Document (Value, Count));
      end Links;

      procedure Create_Link
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "name");
         Source : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "source");
         Target : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "target");
         Mode_Text : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "mode");
         Source_Schema : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "source_schema");
         Source_Table : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "source_table");
         Target_Schema : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "target_schema");
         Target_Table : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "target_table");
         Target_Port : constant Natural :=
           Psqlbench_JSON.Natural_Field (X.Content, "target_port", 55_433);
         Mode : Psqlbench_Context.Link_Mode;
         Accepted : Boolean;
         Detail : String (1 .. 192);
         Last : Natural;
      begin
         if Mode_Text in "" | "logical-committed" then
            Mode := Psqlbench_Context.Logical_Committed;
         elsif Mode_Text = "logical-streaming" then
            Mode := Psqlbench_Context.Logical_Streaming;
         elsif Mode_Text = "logical-two-phase" then
            Mode := Psqlbench_Context.Logical_Two_Phase;
         elsif Mode_Text = "logical-two-phase-streaming" then
            Mode := Psqlbench_Context.Logical_Two_Phase_Streaming;
         elsif Mode_Text = "physical-streaming" then
            Mode := Psqlbench_Context.Physical_Streaming;
         else
            X.Problem
              (400, "invalid-link-mode",
               "Choose a logical committed, streaming, two-phase mode, "
               & "or physical-streaming");
            return;
         end if;
         if not Psqlbench_JSON.Valid_Name (Name) or else Name'Length > 24 then
            X.Problem
              (400, "invalid-link-name",
               "Use 1 to 24 lowercase letters, digits, or hyphens");
            return;
         elsif not Psqlbench_JSON.Valid_Name (Source)
           or else not Psqlbench_JSON.Valid_Name (Target)
         then
            X.Problem
              (400, "invalid-link-endpoint",
               "Source and target must be valid instance names");
            return;
         elsif Source = Target then
            X.Problem
              (400, "identical-link-endpoints",
               "Choose different source and target instances");
            return;
         elsif Mode /= Psqlbench_Context.Physical_Streaming
           and then
             ((Source_Schema'Length > 0
               and then not Psqlbench_JSON.Valid_SQL_Identifier
                 (Source_Schema))
              or else
                (Source_Table'Length > 0
                 and then not Psqlbench_JSON.Valid_SQL_Identifier
                   (Source_Table))
              or else
                (Target_Schema'Length > 0
                 and then not Psqlbench_JSON.Valid_SQL_Identifier
                   (Target_Schema))
              or else
                (Target_Table'Length > 0
                 and then not Psqlbench_JSON.Valid_SQL_Identifier
                   (Target_Table)))
         then
            X.Problem
              (400, "invalid-relation-mapping",
               "Schema and table names use lowercase SQL identifiers");
            return;
         elsif Mode = Psqlbench_Context.Physical_Streaming
           and then Target_Port not in 1_024 .. 65_535
         then
            X.Problem
              (400, "invalid-standby-port",
               "Choose an unprivileged TCP port from 1024 through 65535");
            return;
         end if;

         if Mode = Psqlbench_Context.Physical_Streaming then
            declare
               Source_Version : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Instance_Version
                   (Source, X.Cancellation, X.Deadline);
               Target_Inspect : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Inspect_Instance
                   (Target, X.Cancellation, X.Deadline);
               Target_Role : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Instance_Role
                   (Target, X.Cancellation, X.Deadline);
               Target_Version : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Instance_Version
                   (Target, X.Cancellation, X.Deadline);
               Existing_Port : constant Psqlbench_Docker.Result :=
                 Psqlbench_Docker.Instance_Port
                   (Target, X.Cancellation, X.Deadline);
               Version : constant String :=
                 (if Source_Version.Success
                  then Ada.Strings.Fixed.Trim
                    (Psqlbench_Docker.Text (Source_Version), Ada.Strings.Both)
                  else "");

               function Port_Matches return Boolean is
               begin
                  return Existing_Port.Success
                    and then Natural'Value
                      (Ada.Strings.Fixed.Trim
                         (Psqlbench_Docker.Text (Existing_Port),
                          Ada.Strings.Both)) = Target_Port;
               exception
                  when Constraint_Error => return False;
               end Port_Matches;
            begin
               if not Source_Version.Success then
                  X.Problem
                    (404, "physical-source-not-found",
                     "The physical source must be a managed instance");
                  return;
               elsif Target_Inspect.Success
                 and then
                   (not Target_Role.Success
                    or else Ada.Strings.Fixed.Trim
                      (Psqlbench_Docker.Text (Target_Role),
                       Ada.Strings.Both) /=
                        "physical-standby"
                    or else not Target_Version.Success
                    or else Ada.Strings.Fixed.Trim
                      (Psqlbench_Docker.Text (Target_Version),
                       Ada.Strings.Both) /=
                        Version
                    or else not Port_Matches)
               then
                  X.Problem
                    (409, "physical-target-incompatible",
                     "An existing target must be a matching psqlbench "
                     & "physical standby");
                  return;
               end if;

               State.Root.Links.Create
                 (Name, Source, Target, Mode, "", "", "", "",
                  Version, Target_Port,
                  Accepted, Detail, Last);
            end;
         else
            State.Root.Links.Create
              (Name, Source, Target, Mode,
               Source_Schema, Source_Table, Target_Schema, Target_Table,
               "", 0,
               Accepted, Detail, Last);
         end if;
         if not Accepted then
            X.Problem
              (409, "link-create-failed",
               (if Last = 0 then "link was not accepted"
                else Detail (1 .. Last)));
            return;
         end if;
         State.Root.Events.Append
           (Link_Event_Document (Name, "created"));
         X.JSON
           (202, Link_Document (Name, Source, Target, "pending"));
      exception
         when Error : Constraint_Error =>
            X.Problem
              (400, "invalid-json", Ada.Exceptions.Exception_Message (Error));
      end Create_Link;

      procedure Apply_Link_Action
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name : constant String := X.Parameter ("name");
         Action : constant String := X.Parameter ("action");
         Kind : Psqlbench_Context.Link_Command_Kind;
         Accepted : Boolean;
      begin
         if Action = "stop" then
            Kind := Psqlbench_Context.Stop_Link;
         elsif Action = "remove" then
            Kind := Psqlbench_Context.Remove_Link;
         else
            X.Problem (404, "unknown-link-action", "Unknown link action");
            return;
         end if;
         State.Root.Links.Request (Name, Kind, Accepted);
         if not Accepted then
            X.Problem (404, "link-not-found", "Link was not found");
            return;
         end if;
         X.JSON
           (202, Link_Document (Name, "", "", Action & "-requested"));
      end Apply_Link_Action;

      procedure Create_Instance
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name    : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "name");
         Version : constant String :=
           Psqlbench_JSON.String_Field (X.Content, "version");
         Port_No : constant Natural :=
           Psqlbench_JSON.Natural_Field (X.Content, "port", 55_432);
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem
              (400, "invalid-instance-name",
               "Use 1 to 40 lowercase letters, digits, or hyphens");
            return;
         elsif not Psqlbench_JSON.Valid_Version (Version) then
            X.Problem
              (400, "unsupported-postgres-version",
               "Choose PostgreSQL 14.23, 15.18, 16.14, 17.10, or 18.4");
            return;
         elsif Port_No not in 1_024 .. 65_535 then
            X.Problem
              (400, "invalid-postgres-port",
               "Choose an unprivileged TCP port from 1024 through 65535");
            return;
         end if;

         declare
            Value : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Create_Instance
                (Name, Version, Positive (Port_No),
                 X.Cancellation, X.Deadline);
         begin
            if not Value.Success then
               X.Problem
                 (409, "docker-create-failed",
                  Diagnostic (Psqlbench_Docker.Text (Value)));
               return;
            end if;
            State.Root.Events.Append
              (Instance_Document (Name, Version, Port_No, Event => True));
            X.JSON
              (201, Instance_Document
                 (Name, Version, Port_No, Event => False));
         end;
      exception
         when Error : Constraint_Error =>
            X.Problem
              (400, "invalid-json", Ada.Exceptions.Exception_Message (Error));
      end Create_Instance;

      procedure Apply_Action
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name   : constant String := X.Parameter ("name");
         Action : constant String := X.Parameter ("action");
         Kind   : Psqlbench_Docker.Instance_Action;
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem (400, "invalid-instance-name", "Invalid instance name");
            return;
         end if;
         if Action = "start" then
            Kind := Psqlbench_Docker.Start_Instance;
         elsif Action = "stop" then
            Kind := Psqlbench_Docker.Stop_Instance;
         elsif Action = "remove" then
            Kind := Psqlbench_Docker.Remove_Instance;
         else
            X.Problem (404, "unknown-instance-action", "Unknown action");
            return;
         end if;

         declare
            Value : constant Psqlbench_Docker.Result :=
              Psqlbench_Docker.Apply
                (Name, Kind, X.Cancellation, X.Deadline);
         begin
            if not Value.Success then
               X.Problem
                 (409, "docker-action-failed",
                  Diagnostic (Psqlbench_Docker.Text (Value)));
               return;
            end if;
            State.Root.Events.Append
              (Action_Document (Name, Action, Event => True));
            X.JSON (200, Action_Document (Name, Action, Event => False));
         end;
      end Apply_Action;

      procedure Events
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         use type Psqlbench_Context.Event_Sequence;
         Expected_Origin : constant String :=
           "http://" & X.Request_Header ("Host");
         Cursor    : Psqlbench_Context.Event_Sequence := 0;
         Value     : Psqlbench_Context.Event_Record;
         Available : Boolean;
         Dropped   : Psqlbench_Context.Event_Sequence;
         Idle      : Natural := 0;
      begin
         if X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            X.Problem (403, "websocket-origin", "Origin is not allowed");
            return;
         end if;
         X.Accept_WebSocket
           (Origin_Policy  => HTTP.Require_Exact_Origin,
            Allowed_Origin => Expected_Origin);
         loop
            State.Root.Events.Read_After
              (Cursor, Value, Available, Dropped);
            if Available then
               if Dropped > 0 then
                  X.Send_WebSocket
                    (Count_Document ("events.dropped", Dropped));
               end if;
               X.Send_WebSocket (Value.Data (1 .. Value.Length));
               Cursor := Value.Sequence;
               Idle := 0;
            else
               delay 0.100;
               Idle := Idle + 1;
               if Idle = 100 then
                  X.Send_WebSocket (Simple_Document ("heartbeat"));
                  Idle := 0;
               end if;
            end if;
         end loop;
      end Events;

      procedure Logs
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         Name : constant String := X.Parameter ("name");
         Expected_Origin : constant String :=
           "http://" & X.Request_Header ("Host");
         Cursor    : Psqlbench_Context.Event_Sequence := 0;
         Value     : Psqlbench_Context.Log_Record;
         Available : Boolean;
         Idle      : Natural := 0;
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem (400, "invalid-instance-name", "Invalid instance name");
            return;
         elsif X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            X.Problem (403, "websocket-origin", "Origin is not allowed");
            return;
         end if;
         X.Accept_WebSocket
           (Origin_Policy  => HTTP.Require_Exact_Origin,
            Allowed_Origin => Expected_Origin);
         loop
            State.Root.Logs.Read_After
              (Name, Cursor, Value, Available);
            if Available then
               X.Send_WebSocket (Log_Document (Value));
               Cursor := Value.Sequence;
               Idle := 0;
            else
               delay 0.100;
               Idle := Idle + 1;
               if Idle = 100 then
                  X.Send_WebSocket (Message_Document ("heartbeat", Name));
                  Idle := 0;
               end if;
            end if;
         end loop;
      end Logs;

      procedure Query
        (State : in out Application_Context;
         X     : in out App.Exchange)
      is
         pragma Unreferenced (State);
         use type HTTP.WebSocket_Data_Kind;
         use type Psqlbench_Context.Event_Sequence;
         Name : constant String := X.Parameter ("name");
         Expected_Origin : constant String :=
           "http://" & X.Request_Header ("Host");
         Port_Result : Psqlbench_Docker.Result;
         Port_No : Positive;
      begin
         if not Psqlbench_JSON.Valid_Name (Name) then
            X.Problem (400, "invalid-instance-name", "Invalid instance name");
            return;
         end if;
         Port_Result := Psqlbench_Docker.Instance_Port
           (Name, X.Cancellation, X.Deadline);
         if not Port_Result.Success then
            X.Problem
              (404, "instance-not-found",
               Diagnostic (Psqlbench_Docker.Text (Port_Result)));
            return;
         end if;
         begin
            Port_No := Positive'Value
              (Ada.Strings.Fixed.Trim
                 (Psqlbench_Docker.Text (Port_Result), Ada.Strings.Both));
            if Port_No not in 1_024 .. 65_535 then
               raise Constraint_Error;
            end if;
         exception
            when Constraint_Error =>
               X.Problem
                 (409, "invalid-instance-port",
                  "The instance has no usable host port");
               return;
         end;
         if X.Request_Header_Count ("Origin") /= 1
           or else X.Request_Header ("Origin") /= Expected_Origin
         then
            X.Problem (403, "websocket-origin", "Origin is not allowed");
            return;
         end if;

         X.Accept_WebSocket
           (Origin_Policy  => HTTP.Require_Exact_Origin,
            Allowed_Origin => Expected_Origin);
         X.Send_WebSocket (Attached_Document (Name, Port_No));

         loop
            declare
               Kind   : HTTP.WebSocket_Data_Kind;
               Data   : Flyology.Bytes.Unbounded_Bytes;
               Closed : Boolean;
            begin
               X.Receive_WebSocket
                 (Kind, Data, Closed,
                  Max_Message => Psqlbench_Query.Max_Query_Bytes,
                  Timeout => 30.0, Message_Timeout => 30.0);
               if Closed then
                  X.Complete_WebSocket;
                  return;
               elsif Kind /= HTTP.Text_Frame then
                  X.Send_WebSocket
                    (Message_Document
                       ("query.error", "Query commands must be text JSON"));
               else
                  declare
                     Command : constant String :=
                       Flyology.Bytes.To_Byte_String (Data);
                     SQL : constant String :=
                       Psqlbench_JSON.String_Field (Command, "sql");
                     Command_Kind : constant String :=
                       Psqlbench_JSON.String_Field (Command, "type");
                  begin
                     if Command_Kind = "cancel" then
                        X.Send_WebSocket
                          (Message_Document
                             ("query.idle", "No query is currently running"));
                     elsif SQL'Length = 0 then
                        X.Send_WebSocket
                          (Message_Document
                             ("query.error", "A non-empty sql field is required"));
                     else
                        declare
                           Query_Events : Psqlbench_Query.Event_Stream;
                           Query_Cancel : Psqlbench_Query.Cancellation_State;
                           Cursor : Psqlbench_Context.Event_Sequence := 0;
                           Peer_Closed : Boolean := False;

                           task Worker is
                              pragma Task_Info (Flyology.Lightweight_Task);
                           end Worker;

                           task body Worker is
                           begin
                              Psqlbench_Query.Execute
                                (Name, Port_No, SQL,
                                 Query_Events, Query_Cancel);
                           end Worker;
                        begin
                           loop
                              loop
                                 declare
                                    Event : Psqlbench_Query.Query_Event;
                                    Available : Boolean;
                                    Dropped :
                                      Psqlbench_Context.Event_Sequence;
                                 begin
                                    Query_Events.Read_After
                                      (Cursor, Event, Available, Dropped);
                                    exit when not Available;
                                    if not Peer_Closed then
                                       if Dropped > 0 then
                                          X.Send_WebSocket
                                            (Count_Document
                                               ("query.events-dropped",
                                                Dropped));
                                       end if;
                                       X.Send_WebSocket
                                         (To_String (Event.Data));
                                    end if;
                                    Cursor := Event.Sequence;
                                 end;
                              end loop;
                              exit when Query_Events.Done;

                              if not Peer_Closed then
                                 declare
                                    Next_Kind : HTTP.WebSocket_Data_Kind;
                                    Next_Data : Flyology.Bytes.Unbounded_Bytes;
                                    Next_Closed : Boolean;
                                 begin
                                    X.Receive_WebSocket
                                      (Next_Kind, Next_Data, Next_Closed,
                                       Max_Message =>
                                         Psqlbench_Query.Max_Query_Bytes,
                                       Timeout => 0.005,
                                       Message_Timeout => 30.0);
                                    if Next_Closed then
                                       Peer_Closed := True;
                                       Query_Cancel.Request;
                                    elsif Next_Kind = HTTP.Text_Frame then
                                       declare
                                          Next : constant String :=
                                            Flyology.Bytes.To_Byte_String
                                              (Next_Data);
                                       begin
                                          if Psqlbench_JSON.String_Field
                                               (Next, "type") = "cancel"
                                          then
                                             Query_Cancel.Request;
                                          else
                                             X.Send_WebSocket
                                               (Message_Document
                                                  ("query.busy",
                                                   "Cancel or wait for the current query"));
                                          end if;
                                       end;
                                    end if;
                                 exception
                                    when Flyology.IO.Timeout_Error => null;
                                 end;
                              else
                                 delay 0.005;
                              end if;
                           end loop;
                           if Peer_Closed then
                              X.Complete_WebSocket;
                              return;
                           end if;
                        end;
                     end if;
                  exception
                     when Error : others =>
                        X.Send_WebSocket
                          (Message_Document
                             ("query.error",
                              Ada.Exceptions.Exception_Message (Error)));
                  end;
               end if;
            exception
               when Flyology.IO.Timeout_Error =>
                  X.Send_WebSocket (Simple_Document ("heartbeat"));
            end;
         end loop;
      end Query;

      type Service_Context is limited record
         Application : aliased Application_Context;
         Routes      : aliased Routing.Router
           (Capacity => 13, Slashes => Routing.Strict_Slashes);
         Budget      : aliased HTTP.Ingress_Budget
           (Limit => 4 * 1_024 * 1_024);
      end record;

      procedure Handle
        (State        : in out Service_Context;
         Connection   : in out Owned.Connection;
         Peer         : Sockets.Endpoint;
         Cancellation : not null access Owned.Cancellation_Token)
      is
         Channel : aliased HTTP.Connections.Connection_Transport
           (Connection'Unchecked_Access);
         Client : aliased HTTP.Connection (Channel'Access);
      begin
         HTTP.Configure_Ingress_Budget (Client, State.Budget'Access);
         State.Routes.Serve
           (State.Application, Client, Peer,
            Timeout => 30.0, Header_Timeout => 5.0,
            Token => Cancellation);
      end Handle;

      package Server_Instance is new Flyology.IO.Structured_Servers
        (Handler_Context => Service_Context,
         Handle          => Handle,
         Handler_Model   => Flyology.Lightweight_Task);

      Server   : aliased Server_Instance.Server (Capacity => 64);
      State    : aliased Service_Context;
      Listener : Sockets.Socket_Type;

      protected Lifecycle is
         procedure Complete;
         function Done return Boolean;
      private
         Finished : Boolean := False;
      end Lifecycle;

      protected body Lifecycle is
         procedure Complete is
         begin
            Finished := True;
         end Complete;
         function Done return Boolean is (Finished);
      end Lifecycle;
   begin
      State.Application.Root := Context'Unrestricted_Access;
      Psqlbench_Assets.Load (State.Application.Assets);

      State.Routes.Get ("/", Home'Access, Name => "home");
      State.Routes.Get
        ("/assets/app.css", Stylesheet'Access, Name => "assets.css");
      State.Routes.Get
        ("/assets/app.js", Script'Access, Name => "assets.js");
      State.Routes.Get ("/api/status", Status'Access, Name => "api.status");
      State.Routes.Get
        ("/api/instances", Instances'Access, Name => "api.instances");
      State.Routes.Get ("/api/links", Links'Access, Name => "api.links");
      State.Routes.Post
        ("/api/links", Create_Link'Access, Name => "api.link.create",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Buffer_Body,
              Max_Body      => 4 * 1_024,
              Timeout       => 30.0,
              Concurrency   => 8));
      State.Routes.Post
        ("/api/links/{name}/{action}", Apply_Link_Action'Access,
         Name => "api.link.action",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Timeout => 30.0, Concurrency => 8));
      State.Routes.Post
        ("/api/instances", Create_Instance'Access, Name => "api.create",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Body_Handling => App.Buffer_Body,
              Max_Body      => 4 * 1_024,
              Timeout       => 300.0,
              Concurrency   => 8));
      State.Routes.Post
        ("/api/instances/{name}/{action}", Apply_Action'Access,
         Name => "api.action",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Timeout => 30.0, Concurrency => 8));
      State.Routes.Get
        ("/api/events", Events'Access, Name => "api.events",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket,
              Timeout => 86_400.0,
              Concurrency => 32));
      State.Routes.Get
        ("/api/instances/{name}/logs", Logs'Access, Name => "api.logs",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket,
              Timeout => 86_400.0,
              Concurrency => 32));
      State.Routes.Get
        ("/api/instances/{name}/query", Query'Access, Name => "api.query",
         Policy =>
           (Routing.Default_Route_Policy with delta
              Upgrade => Routing.Allow_WebSocket,
              Timeout => 86_400.0,
              Concurrency => 32));

      Sockets.Create_Socket (Listener);
      Sockets.Set_Socket_Option
        (Listener, Sockets.Socket_Level, (Sockets.Reuse_Address, True));
      Sockets.Bind_Socket
        (Listener, Sockets.Network_Endpoint (Sockets.Loopback_IPv4, Port));
      Sockets.Listen_Socket (Listener, Length => 64);
      Context.Events.Append (HTTP_Ready_Document (Natural (Port)));
      Flyology.Supervision.Mark_Ready (Control.all);
      Ada.Text_IO.Put_Line
        ("READY psqlbench http://127.0.0.1:"
         & Compact (Natural (Port)) & "/");
      Ada.Text_IO.Flush;

      declare
         task Stopper is
            pragma Task_Info (Flyology.Native_Task);
         end Stopper;

         task body Stopper is
         begin
            loop
               exit when Lifecycle.Done;
               if Flyology.Supervision.Stopping (Control.all).Requested then
                  Server_Instance.Request_Shutdown (Server);
                  exit;
               end if;
               delay 0.050;
            end loop;
         end Stopper;
      begin
         begin
            Server_Instance.Serve
              (Server, Listener, State, Drain_Timeout => 2.0);
            Lifecycle.Complete;
         exception
            when others =>
               Lifecycle.Complete;
               raise;
         end;
      end;
   end Execute;

end Psqlbench_Server;
