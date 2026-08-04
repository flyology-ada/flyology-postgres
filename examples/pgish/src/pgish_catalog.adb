with Ada.Calendar;
with Ada.Calendar.Formatting;
with Ada.Characters.Handling;
with Ada.Environment_Variables;
with Ada.Strings;
with Ada.Strings.Fixed;
with Flyology.Execution_Groups;
with Flyology.Observability;

package body Pgish_Catalog is

   use Ada.Characters.Handling;
   use type Ada.Calendar.Time;
   use type Pgish_SQL.Comparison_Operator;
   use type Pgish_SQL.Function_Kind;
   use type Pgish_SQL.Projection_Kind;
   use type Pgish_SQL.Statement_Kind;

   package SQL renames Pgish_SQL;
   package State renames Pgish_State;
   package Groups renames Flyology.Execution_Groups;
   package Observability renames Flyology.Observability;

   type Table_Metadata is record
      Name        : SQL.Name_Text;
      Description : SQL.Value_Text;
   end record;
   type Metadata_Array is array (Positive range <>) of Table_Metadata;

   Tables : constant Metadata_Array :=
     ((SQL.Make_Text ("flyology_server_info", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Server identity, uptime, listener, and repository", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_runtime_groups", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Inert snapshots of created Flyology execution groups", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_runtime_stack_pool", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Process-wide Flyology lightweight stack allocator", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_sessions", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Bounded live Postgres sessions", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_repo_commits", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Recent commits cached safely at server startup", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_tables", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Descriptions of the example virtual tables", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_settings", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Effective server limits and non-secret configuration", SQL.Maximum_Value_Length)),
      (SQL.Make_Text ("flyology_environment", SQL.Maximum_Name_Length),
       SQL.Make_Text ("Strict allowlist of non-secret environment values", SQL.Maximum_Value_Length)));

   function T (Value : String) return SQL.Name_Text is
     (SQL.Make_Text (Value, SQL.Maximum_Name_Length));
   function V (Value : String) return SQL.Value_Text is
     (SQL.Make_Text
        ((if Value'Length <= SQL.Maximum_Value_Length
          then Value
          else Value (Value'First .. Value'First + SQL.Maximum_Value_Length - 1)),
         SQL.Maximum_Value_Length));
   function Text_Cell (Value : String) return Cell is
     (Is_Null => False, Value => V (Value));
   function Null_Cell return Cell is (Is_Null => True, Value => V (""));

   function Trim_Image (Value : String) return String is
     (Ada.Strings.Fixed.Trim (Value, Ada.Strings.Both));
   function B (Value : Boolean) return String is
     (if Value then "true" else "false");

   function Timestamp (Value : Ada.Calendar.Time) return String is
     (Ada.Calendar.Formatting.Image
        (Value, Include_Time_Fraction => False, Time_Zone => 0) & "+00");

   procedure Add_Column
     (Result : in out Result_Set;
      Name : String;
      Type_Oid : Natural := 25;
      Type_Size : Integer := -1) is
   begin
      if Result.Column_Count = Maximum_Columns then
         raise Resource_Limit_Error with "result column limit exceeded";
      end if;
      Result.Column_Count := Result.Column_Count + 1;
      Result.Columns (Result.Column_Count) :=
        (Name => T (Name), Type_Oid => Type_Oid, Type_Size => Type_Size);
   end Add_Column;

   procedure Add_Row (Result : in out Result_Set; Values : Cell_Array) is
   begin
      if Result.Row_Count = Maximum_Rows then
         raise Resource_Limit_Error with "result row limit exceeded";
      end if;
      Result.Row_Count := Result.Row_Count + 1;
      Result.Rows (Result.Row_Count).Values := Values;
   end Add_Row;

   function Base_Name (Name : String) return String is
      Dot : constant Natural := Ada.Strings.Fixed.Index
        (Name, ".", Going => Ada.Strings.Backward);
   begin
      return To_Lower
        ((if Dot = 0 then Name else Name (Dot + 1 .. Name'Last)));
   end Base_Name;

   function Find_Column (Result : Result_Set; Name : String) return Natural is
      Wanted : constant String := Base_Name (Name);
   begin
      for Index in 1 .. Result.Column_Count loop
         if To_Lower (SQL.Image (Result.Columns (Index).Name)) = Wanted then
            return Index;
         end if;
      end loop;
      return 0;
   end Find_Column;

   procedure Add_Server_Info
     (State_Value : State.Server_State; Result : in out Result_Set) is
      Config : constant State.Configuration := State.Config (State_Value);
      Values : Cell_Array := (others => Null_Cell);
      Uptime : constant Duration := Ada.Calendar.Clock - Config.Started_At;
   begin
      Add_Column (Result, "server_version");
      Add_Column (Result, "protocol_version");
      Add_Column (Result, "uptime_seconds", 20, 8);
      Add_Column (Result, "task_mode");
      Add_Column (Result, "listen_host");
      Add_Column (Result, "listen_port", 23, 4);
      Add_Column (Result, "repository_path");
      Add_Column (Result, "repository_head");
      Add_Column (Result, "started_at", 1_184, 8);
      Values (1) := Text_Cell ("18.4");
      Values (2) := Text_Cell ("3.2");
      Values (3) := Text_Cell (Trim_Image (Long_Long_Integer (Uptime)'Image));
      Values (4) := Text_Cell (SQL.Image (Config.Task_Mode));
      Values (5) := Text_Cell (SQL.Image (Config.Host));
      Values (6) := Text_Cell (Trim_Image (Config.Port'Image));
      Values (7) := Text_Cell (SQL.Image (Config.Repository_Path));
      Values (8) :=
        (if State.Repository_Head (State_Value)'Length = 0
         then Null_Cell
         else Text_Cell (State.Repository_Head (State_Value)));
      Values (9) := Text_Cell (Timestamp (Config.Started_At));
      Add_Row (Result, Values);
   end Add_Server_Info;

   procedure Add_Runtime_Groups (Result : in out Result_Set) is
      Snapshot : Observability.Group_Snapshot;
      Values   : Cell_Array := (others => Null_Cell);
   begin
      Add_Column (Result, "group_id", 23, 4);
      Add_Column (Result, "thread_state");
      Add_Column (Result, "dedicated", 16, 1);
      Add_Column (Result, "reserved", 16, 1);
      Add_Column (Result, "members", 20, 8);
      Add_Column (Result, "pinned_members", 20, 8);
      Add_Column (Result, "ready", 20, 8);
      Add_Column (Result, "waiting", 20, 8);
      Add_Column (Result, "running", 20, 8);
      Add_Column (Result, "timer_waits", 20, 8);
      Add_Column (Result, "descriptor_waits", 20, 8);
      Add_Column (Result, "interrupt_waits", 20, 8);
      Add_Column (Result, "file_waits", 20, 8);
      Add_Column (Result, "dispatches", 20, 8);
      Add_Column (Result, "poll_events", 20, 8);
      Add_Column (Result, "wakeups", 20, 8);
      for Group in Groups.Group_Id loop
         exit when Result.Row_Count = Maximum_Rows;
         if Observability.Snapshot (Group, Snapshot) then
            Values := (others => Null_Cell);
            Values (1) := Text_Cell (Trim_Image (Group'Image));
            Values (2) := Text_Cell (To_Lower (Snapshot.Thread_State'Image));
            Values (3) := Text_Cell (B (Snapshot.Dedicated));
            Values (4) := Text_Cell (B (Snapshot.Reserved));
            Values (5) := Text_Cell (Trim_Image (Snapshot.Members'Image));
            Values (6) := Text_Cell (Trim_Image (Snapshot.Pinned_Members'Image));
            Values (7) := Text_Cell (Trim_Image (Snapshot.Ready'Image));
            Values (8) := Text_Cell (Trim_Image (Snapshot.Waiting'Image));
            Values (9) := Text_Cell (Trim_Image (Snapshot.Running'Image));
            Values (10) := Text_Cell (Trim_Image (Snapshot.Timer_Waits'Image));
            Values (11) := Text_Cell (Trim_Image (Snapshot.Descriptor_Waits'Image));
            Values (12) := Text_Cell (Trim_Image (Snapshot.Interrupt_Waits'Image));
            Values (13) := Text_Cell (Trim_Image (Snapshot.File_Waits'Image));
            Values (14) := Text_Cell (Trim_Image (Snapshot.Dispatches'Image));
            Values (15) := Text_Cell (Trim_Image (Snapshot.Poll_Events'Image));
            Values (16) := Text_Cell (Trim_Image (Snapshot.Wakeups'Image));
            Add_Row (Result, Values);
         end if;
      end loop;
   end Add_Runtime_Groups;

   procedure Add_Stack_Pool (Result : in out Result_Set) is
      Snapshot : constant Observability.Stack_Pool_Snapshot :=
        Observability.Stack_Pool;
      Values : Cell_Array := (others => Null_Cell);
      Names : constant array (Positive range <>) of SQL.Name_Text :=
        (T ("active_arenas"), T ("live_stacks"),
         T ("live_usable_bytes"), T ("reserved_bytes"),
         T ("arena_mappings"), T ("arena_unmappings"),
         T ("shared_stacks"), T ("discarded_stacks"));
   begin
      for Name of Names loop
         Add_Column (Result, SQL.Image (Name), 20, 8);
      end loop;
      Values (1) := Text_Cell (Trim_Image (Snapshot.Active_Arenas'Image));
      Values (2) := Text_Cell (Trim_Image (Snapshot.Live_Stacks'Image));
      Values (3) := Text_Cell (Trim_Image (Snapshot.Live_Usable_Bytes'Image));
      Values (4) := Text_Cell (Trim_Image (Snapshot.Reserved_Bytes'Image));
      Values (5) := Text_Cell (Trim_Image (Snapshot.Arena_Mappings'Image));
      Values (6) := Text_Cell (Trim_Image (Snapshot.Arena_Unmappings'Image));
      Values (7) := Text_Cell (Trim_Image (Snapshot.Shared_Stacks'Image));
      Values (8) := Text_Cell (Trim_Image (Snapshot.Discarded_Stacks'Image));
      Add_Row (Result, Values);
   end Add_Stack_Pool;

   procedure Add_Sessions
     (State_Value : in out State.Server_State; Result : in out Result_Set) is
      Sessions : State.Session_Array;
      Count    : Natural;
      Values   : Cell_Array := (others => Null_Cell);
   begin
      Add_Column (Result, "session_id", 23, 4);
      Add_Column (Result, "user_name");
      Add_Column (Result, "database_name");
      Add_Column (Result, "application_name");
      Add_Column (Result, "query_count", 20, 8);
      Add_Column (Result, "connected_at", 1_184, 8);
      Add_Column (Result, "state");
      Add_Column (Result, "current_query");
      State.Sessions (State_Value, Sessions, Count);
      for Index in 1 .. Count loop
         Values := (others => Null_Cell);
         Values (1) := Text_Cell (Trim_Image (Sessions (Index).Session_Id'Image));
         Values (2) := Text_Cell (SQL.Image (Sessions (Index).User_Name));
         Values (3) := Text_Cell (SQL.Image (Sessions (Index).Database_Name));
         Values (4) := Text_Cell (SQL.Image (Sessions (Index).Application_Name));
         Values (5) := Text_Cell (Trim_Image (Sessions (Index).Query_Count'Image));
         Values (6) := Text_Cell (Timestamp (Sessions (Index).Connected_At));
         Values (7) := Text_Cell (SQL.Image (Sessions (Index).State));
         Values (8) :=
           (if SQL.Is_Empty (Sessions (Index).Current_Query)
            then Null_Cell
            else Text_Cell (SQL.Image (Sessions (Index).Current_Query)));
         Add_Row (Result, Values);
      end loop;
   end Add_Sessions;

   procedure Add_Commits
     (State_Value : State.Server_State; Result : in out Result_Set) is
      Commits : State.Commit_Array;
      Count   : Natural;
      Values  : Cell_Array := (others => Null_Cell);
   begin
      Add_Column (Result, "hash");
      Add_Column (Result, "short_hash");
      Add_Column (Result, "author");
      Add_Column (Result, "committed_at", 1_184, 8);
      Add_Column (Result, "subject");
      State.Repository_Commits (State_Value, Commits, Count);
      for Index in 1 .. Count loop
         Values := (others => Null_Cell);
         Values (1) := Text_Cell (SQL.Image (Commits (Index).Hash));
         Values (2) := Text_Cell (SQL.Image (Commits (Index).Short_Hash));
         Values (3) := Text_Cell (SQL.Image (Commits (Index).Author));
         Values (4) := Text_Cell (SQL.Image (Commits (Index).Committed_At));
         Values (5) := Text_Cell (SQL.Image (Commits (Index).Subject));
         Add_Row (Result, Values);
      end loop;
   end Add_Commits;

   procedure Add_Tables (Result : in out Result_Set) is
      Values : Cell_Array := (others => Null_Cell);
   begin
      Add_Column (Result, "table_schema");
      Add_Column (Result, "table_name");
      Add_Column (Result, "description");
      for Table of Tables loop
         Values := (others => Null_Cell);
         Values (1) := Text_Cell ("flyology");
         Values (2) := Text_Cell (SQL.Image (Table.Name));
         Values (3) := Text_Cell (SQL.Image (Table.Description));
         Add_Row (Result, Values);
      end loop;
   end Add_Tables;

   procedure Add_Settings
     (State_Value : State.Server_State; Result : in out Result_Set) is
      Values : Cell_Array := (others => Null_Cell);
      procedure Add (Name, Value, Unit, Description : String) is
      begin
         Values := (others => Null_Cell);
         Values (1) := Text_Cell (Name);
         Values (2) := Text_Cell (Value);
         Values (3) := (if Unit'Length = 0 then Null_Cell else Text_Cell (Unit));
         Values (4) := Text_Cell (Description);
         Add_Row (Result, Values);
      end Add;
   begin
      Add_Column (Result, "name");
      Add_Column (Result, "value");
      Add_Column (Result, "unit");
      Add_Column (Result, "description");
      Add ("maximum_query_length", Trim_Image (SQL.Maximum_Query_Length'Image), "bytes", "Maximum accepted SQL text");
      Add ("maximum_tokens", Trim_Image (SQL.Maximum_Tokens'Image), "tokens", "Lexer token budget");
      Add ("maximum_result_rows", Trim_Image (Maximum_Rows'Image), "rows", "Hard result and LIMIT bound");
      Add ("maximum_sessions", Trim_Image (State.Maximum_Sessions'Image), "sessions", "Server admission capacity");
      Add ("authentication", "trust", "", "Default local demonstration mode");
      declare
         Enabled : constant Boolean := State.Config (State_Value).TLS_Enabled;
      begin
         Add
           ("tls",
            (if Enabled then "required" else "off"),
            "",
            (if Enabled
             then "Verified server TLS is required"
             else "The plaintext server entry point is selected"));
      end;
   end Add_Settings;

   procedure Add_Environment (Result : in out Result_Set) is
      Values : Cell_Array := (others => Null_Cell);
      Names : constant array (Positive range <>) of SQL.Name_Text :=
        (T ("FLYOLOGY_DEFAULT"), T ("FLYOLOGY_LOOP_POOL_SIZE"),
         T ("FLYOLOGY_LOOP_PLACEMENT"), T ("LANG"), T ("TZ"));
   begin
      Add_Column (Result, "name");
      Add_Column (Result, "value");
      for Name of Names loop
         declare
            Key : constant String := SQL.Image (Name);
         begin
            if Ada.Environment_Variables.Exists (Key) then
               Values := (others => Null_Cell);
               Values (1) := Text_Cell (Key);
               Values (2) := Text_Cell (Ada.Environment_Variables.Value (Key));
               Add_Row (Result, Values);
            end if;
         end;
      end loop;
   end Add_Environment;

   procedure Add_Information_Tables (Result : in out Result_Set) is
      Values : Cell_Array := (others => Null_Cell);
   begin
      Add_Column (Result, "table_catalog");
      Add_Column (Result, "table_schema");
      Add_Column (Result, "table_name");
      Add_Column (Result, "table_type");
      for Table of Tables loop
         Values := (others => Null_Cell);
         Values (1) := Text_Cell ("flyology");
         Values (2) := Text_Cell ("flyology");
         Values (3) := Text_Cell (SQL.Image (Table.Name));
         Values (4) := Text_Cell ("VIEW");
         Add_Row (Result, Values);
      end loop;
   end Add_Information_Tables;

   procedure Add_Information_Columns
     (State_Value : in out State.Server_State;
      Result      : in out Result_Set;
      Only_Table  : String := "") is
      Source : Result_Set;
      Values : Cell_Array := (others => Null_Cell);

      procedure Load (Name : String) is
      begin
         Source := (others => <>);
         if Name = "flyology_server_info" then Add_Server_Info (State_Value, Source);
         elsif Name = "flyology_runtime_groups" then Add_Runtime_Groups (Source);
         elsif Name = "flyology_runtime_stack_pool" then Add_Stack_Pool (Source);
         elsif Name = "flyology_sessions" then Add_Sessions (State_Value, Source);
         elsif Name = "flyology_repo_commits" then Add_Commits (State_Value, Source);
         elsif Name = "flyology_tables" then Add_Tables (Source);
         elsif Name = "flyology_settings" then
            Add_Settings (State_Value, Source);
         elsif Name = "flyology_environment" then Add_Environment (Source);
         end if;
      end Load;
   begin
      Add_Column (Result, "table_catalog");
      Add_Column (Result, "table_schema");
      Add_Column (Result, "table_name");
      Add_Column (Result, "column_name");
      Add_Column (Result, "ordinal_position", 23, 4);
      Add_Column (Result, "is_nullable");
      Add_Column (Result, "data_type");
      Add_Column (Result, "column_default");
      for Table of Tables loop
         if Only_Table'Length = 0
           or else Base_Name (Only_Table) = Base_Name (SQL.Image (Table.Name))
         then
            Load (SQL.Image (Table.Name));
            for Column in 1 .. Source.Column_Count loop
               Values := (others => Null_Cell);
               Values (1) := Text_Cell ("flyology");
               Values (2) := Text_Cell ("flyology");
               Values (3) := Text_Cell (SQL.Image (Table.Name));
               Values (4) := Text_Cell (SQL.Image (Source.Columns (Column).Name));
               Values (5) := Text_Cell (Trim_Image (Column'Image));
               Values (6) := Text_Cell ("YES");
               Values (7) := Text_Cell
                 ((case Source.Columns (Column).Type_Oid is
                    when 16 => "boolean", when 20 => "bigint",
                    when 23 => "integer",
                    when 1_184 => "timestamp with time zone",
                    when others => "text"));
               Values (8) := Null_Cell;
               Add_Row (Result, Values);
            end loop;
         end if;
      end loop;
   end Add_Information_Columns;

   procedure Load_Source
     (Context : in out State.Server_State;
      Name         : String;
      Result       : out Result_Set) is
      Base : constant String := Base_Name (Name);
   begin
      Result := (others => <>);
      if Base = "flyology_server_info" then Add_Server_Info (Context, Result);
      elsif Base = "flyology_runtime_groups" then Add_Runtime_Groups (Result);
      elsif Base = "flyology_runtime_stack_pool" then Add_Stack_Pool (Result);
      elsif Base = "flyology_sessions" then Add_Sessions (Context, Result);
      elsif Base = "flyology_repo_commits" then Add_Commits (Context, Result);
      elsif Base = "flyology_tables" then Add_Tables (Result);
      elsif Base = "flyology_settings" then
         Add_Settings (Context, Result);
      elsif Base = "flyology_environment" then Add_Environment (Result);
      elsif To_Lower (Name) = "information_schema.tables" then Add_Information_Tables (Result);
      elsif To_Lower (Name) = "information_schema.columns" then
         Add_Information_Columns (Context, Result);
      else
         raise Undefined_Table_Error with "unknown virtual table: " & Name;
      end if;
   end Load_Source;

   function Numeric (Value : String; Number : out Long_Long_Integer) return Boolean is
   begin
      Number := Long_Long_Integer'Value (Value);
      return True;
   exception
      when Constraint_Error => Number := 0; return False;
   end Numeric;

   function Like (Value, Pattern : String) return Boolean is
      Leading  : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'First) = '%';
      Trailing : constant Boolean := Pattern'Length > 0 and then Pattern (Pattern'Last) = '%';
      First    : constant Integer := Pattern'First + Boolean'Pos (Leading);
      Last     : constant Integer := Pattern'Last - Boolean'Pos (Trailing);
      Needle   : constant String := (if First > Last then "" else Pattern (First .. Last));
   begin
      if Ada.Strings.Fixed.Index (Needle, "%") /= 0
        or else Ada.Strings.Fixed.Index (Needle, "_") /= 0
      then
         raise Unsupported_Error with "LIKE supports only leading/trailing percent wildcards";
      elsif Leading and Trailing then
         return Ada.Strings.Fixed.Index (Value, Needle) /= 0;
      elsif Leading then
         return Needle'Length <= Value'Length
           and then Value (Value'Last - Needle'Length + 1 .. Value'Last) = Needle;
      elsif Trailing then
         return Needle'Length <= Value'Length
           and then Value (Value'First .. Value'First + Needle'Length - 1) = Needle;
      else
         return Value = Needle;
      end if;
   end Like;

   function Matches
     (Source : Result_Set; Row : Result_Row; Predicate : SQL.Predicate)
      return Boolean is
      Index : constant Natural := Find_Column (Source, SQL.Image (Predicate.Column));
      Cell_Value : Cell;
      Left_Number, Right_Number : Long_Long_Integer;
      Both_Numeric : Boolean;
      Comparison : Integer;
   begin
      if Index = 0 then
         raise Undefined_Column_Error with
           "unknown predicate column: " & SQL.Image (Predicate.Column);
      end if;
      Cell_Value := Row.Values (Index);
      if Predicate.Operator = SQL.Is_Null then return Cell_Value.Is_Null;
      elsif Predicate.Operator = SQL.Is_Not_Null then return not Cell_Value.Is_Null;
      elsif Cell_Value.Is_Null then return False;
      elsif Predicate.Operator = SQL.Like_Match then
         return Like (SQL.Image (Cell_Value.Value), SQL.Image (Predicate.Value));
      end if;
      Both_Numeric := Numeric (SQL.Image (Cell_Value.Value), Left_Number)
        and then Numeric (SQL.Image (Predicate.Value), Right_Number);
      if Both_Numeric then
         Comparison := (if Left_Number < Right_Number then -1
                        elsif Left_Number > Right_Number then 1 else 0);
      else
         Comparison :=
           (if SQL.Image (Cell_Value.Value) < SQL.Image (Predicate.Value) then -1
            elsif SQL.Image (Cell_Value.Value) > SQL.Image (Predicate.Value) then 1 else 0);
      end if;
      return (case Predicate.Operator is
         when SQL.Equal_To => Comparison = 0,
         when SQL.Not_Equal_To => Comparison /= 0,
         when SQL.Less_Than => Comparison < 0,
         when SQL.Less_Or_Equal => Comparison <= 0,
         when SQL.Greater_Than => Comparison > 0,
         when SQL.Greater_Or_Equal => Comparison >= 0,
         when others => False);
   end Matches;

   procedure Project
     (Source  : Result_Set;
      Session : State.Session_Snapshot;
      Query   : SQL.Query;
      Result  : in out Result_Set) is
      Current_Time : constant String := Timestamp (Ada.Calendar.Clock);

      procedure Add_Projected_Column (Projection : SQL.Projection) is
         Source_Index : Natural;
         Name : SQL.Name_Text;
      begin
         if Projection.Kind = SQL.Star_Projection then
            for Index in 1 .. Source.Column_Count loop
               Add_Column
                 (Result, SQL.Image (Source.Columns (Index).Name),
                  Source.Columns (Index).Type_Oid,
                  Source.Columns (Index).Type_Size);
            end loop;
            return;
         end if;
         Name := Projection.Alias;
         if SQL.Is_Empty (Name) then
            case Projection.Kind is
               when SQL.Column_Projection => Name := T (Base_Name (SQL.Image (Projection.Name)));
               when SQL.Literal_Projection => Name := T ("?column?");
               when SQL.Function_Projection => Name := T
                 ((case Projection.Function_Id is
                    when SQL.Current_Database_Function => "current_database",
                    when SQL.Current_User_Function => "current_user",
                    when SQL.Version_Function => "version",
                    when SQL.Now_Function => "now"));
               when SQL.Star_Projection => null;
            end case;
         end if;
         if Projection.Kind = SQL.Column_Projection then
            Source_Index := Find_Column (Source, SQL.Image (Projection.Name));
            if Source_Index = 0 then
               raise Undefined_Column_Error with
                 "unknown projection column: " & SQL.Image (Projection.Name);
            end if;
            Add_Column
              (Result, SQL.Image (Name), Source.Columns (Source_Index).Type_Oid,
               Source.Columns (Source_Index).Type_Size);
         elsif Projection.Kind = SQL.Function_Projection
           and then Projection.Function_Id = SQL.Now_Function
         then
            Add_Column (Result, SQL.Image (Name), 1_184, 8);
         else
            Add_Column (Result, SQL.Image (Name));
         end if;
      end Add_Projected_Column;

      procedure Add_Projected_Row (Source_Row : Result_Row) is
         Values : Cell_Array := (others => Null_Cell);
         Output : Natural := 0;
         Source_Index : Natural;
      begin
         for Projection_Index in 1 .. Query.Projection_Count loop
            declare
               Projection : SQL.Projection renames Query.Projections (Projection_Index);
            begin
               if Projection.Kind = SQL.Star_Projection then
                  for Index in 1 .. Source.Column_Count loop
                     Output := Output + 1;
                     Values (Output) := Source_Row.Values (Index);
                  end loop;
               else
                  Output := Output + 1;
                  case Projection.Kind is
                     when SQL.Column_Projection =>
                        Source_Index := Find_Column (Source, SQL.Image (Projection.Name));
                        Values (Output) := Source_Row.Values (Source_Index);
                     when SQL.Literal_Projection =>
                        Values (Output) := Text_Cell (SQL.Image (Projection.Literal));
                     when SQL.Function_Projection =>
                        Values (Output) := Text_Cell
                          ((case Projection.Function_Id is
                             when SQL.Current_Database_Function => SQL.Image (Session.Database_Name),
                             when SQL.Current_User_Function => SQL.Image (Session.User_Name),
                             when SQL.Version_Function =>
                               "pgish 0.1 " &
                               "(Postgres 18.4 compatible protocol)",
                             when SQL.Now_Function => Current_Time));
                     when SQL.Star_Projection => null;
                  end case;
               end if;
            end;
         end loop;
         Add_Row (Result, Values);
      end Add_Projected_Row;

      Keep : Boolean;
      Empty_Row : constant Result_Row := (Values => (others => Null_Cell));
   begin
      for Index in 1 .. Query.Projection_Count loop
         Add_Projected_Column (Query.Projections (Index));
      end loop;
      if SQL.Is_Empty (Query.Table_Name) then
         Add_Projected_Row (Empty_Row);
      else
         for Row_Index in 1 .. Source.Row_Count loop
            Keep := True;
            for Predicate_Index in 1 .. Query.Predicate_Count loop
               if not Matches
                 (Source, Source.Rows (Row_Index), Query.Predicates (Predicate_Index))
               then
                  Keep := False;
                  exit;
               end if;
            end loop;
            if Keep then Add_Projected_Row (Source.Rows (Row_Index)); end if;
         end loop;
      end if;
   end Project;

   procedure Sort (Result : in out Result_Set; Column : String; Descending : Boolean) is
      Index : constant Natural := Find_Column (Result, Column);
      function Before (Left, Right : Cell) return Boolean is
      begin
         if Left.Is_Null then return Descending and then not Right.Is_Null;
         elsif Right.Is_Null then return not Descending;
         elsif Descending then return SQL.Image (Left.Value) > SQL.Image (Right.Value);
         else return SQL.Image (Left.Value) < SQL.Image (Right.Value);
         end if;
      end Before;
   begin
      if Index = 0 then
         raise Undefined_Column_Error with "ORDER BY column is not projected: " & Column;
      end if;
      for Position in 2 .. Result.Row_Count loop
         declare
            Value : constant Result_Row := Result.Rows (Position);
            Cursor : Natural := Position;
         begin
            while Cursor > 1
              and then Before (Value.Values (Index), Result.Rows (Cursor - 1).Values (Index))
            loop
               Result.Rows (Cursor) := Result.Rows (Cursor - 1);
               Cursor := Cursor - 1;
            end loop;
            Result.Rows (Cursor) := Value;
         end;
      end loop;
   end Sort;

   procedure Execute
     (State   : in out Pgish_State.Server_State;
      Session : Pgish_State.Session_Snapshot;
      Query   : Pgish_SQL.Query;
      Result  : out Result_Set) is
      Source : Result_Set := (others => <>);
      Limit  : Natural;
   begin
      Result := (others => <>);
      if Query.Kind = SQL.Show_Statement then
         Add_Column (Result, SQL.Image (Query.Show_Name));
         declare
            Name : constant String := To_Lower (SQL.Image (Query.Show_Name));
            Values : Cell_Array := (others => Null_Cell);
         begin
            if Name = "server_version" then Values (1) := Text_Cell ("18.4");
            elsif Name = "server_encoding" or else Name = "client_encoding" then Values (1) := Text_Cell ("UTF8");
            elsif Name = "timezone" then Values (1) := Text_Cell ("UTC");
            elsif Name = "standard_conforming_strings" then Values (1) := Text_Cell ("on");
            else raise Undefined_Column_Error with "unknown SHOW setting: " & Name;
            end if;
            Add_Row (Result, Values);
         end;
         return;
      end if;
      if not SQL.Is_Empty (Query.Table_Name) then
         if To_Lower (SQL.Image (Query.Table_Name)) =
           "information_schema.columns"
         then
            declare
               Table_Filter : SQL.Value_Text;
            begin
               for Index in 1 .. Query.Predicate_Count loop
                  if Base_Name (SQL.Image (Query.Predicates (Index).Column)) =
                    "table_name"
                    and then Query.Predicates (Index).Operator = SQL.Equal_To
                  then
                     Table_Filter := Query.Predicates (Index).Value;
                     exit;
                  end if;
               end loop;
               Source := (others => <>);
               Add_Information_Columns
                 (State, Source, SQL.Image (Table_Filter));
            end;
         else
            Load_Source (State, SQL.Image (Query.Table_Name), Source);
         end if;
      end if;
      Project (Source, Session, Query, Result);
      if not SQL.Is_Empty (Query.Order_Column) then
         Sort (Result, SQL.Image (Query.Order_Column), Query.Order_Descending);
      end if;
      Limit := (if Query.Has_Limit then Query.Limit else Maximum_Rows);
      if Result.Row_Count > Limit then Result.Row_Count := Limit; end if;
   end Execute;

   procedure Psql_Compatibility
     (Context : in out State.Server_State;
      SQL_Text : String;
      Matched  : out Boolean;
      Result   : out Result_Set) is
      Lower  : constant String := To_Lower (SQL_Text);
      Psqlish_Tables : constant Boolean :=
        Ada.Strings.Fixed.Index
          (Lower, "from pg_catalog.pg_tables") /= 0;
      Values : Cell_Array := (others => Null_Cell);
      Source : Result_Set := (others => <>);
   begin
      Result := (others => <>);
      Matched :=
        Psqlish_Tables
        or else Ada.Strings.Fixed.Index
          (Lower, "from pg_catalog.pg_class c") /= 0
        or else Ada.Strings.Fixed.Index
          (Lower, "from pg_catalog.pg_attribute a") /= 0;
      if not Matched then
         return;
      end if;
      if Psqlish_Tables then
         Add_Column (Result, "schema");
         Add_Column (Result, "name");
         Add_Column (Result, "owner");
         for Table of Tables loop
            Values := (others => Null_Cell);
            Values (1) := Text_Cell ("flyology");
            Values (2) := Text_Cell (SQL.Image (Table.Name));
            Values (3) := Text_Cell ("flyology");
            Add_Row (Result, Values);
         end loop;
      elsif Ada.Strings.Fixed.Index
        (Lower, "from pg_catalog.pg_attribute a") /= 0
      then
         for Index in Tables'Range loop
            if Ada.Strings.Fixed.Index
              (Lower, "'" & Trim_Image (Integer'Image (10_000 + Index)) & "'")
              /= 0
            then
               Load_Source
                 (Context, SQL.Image (Tables (Index).Name), Source);
               exit;
            end if;
         end loop;
         Add_Column (Result, "attname");
         Add_Column (Result, "format_type");
         Add_Column (Result, "default");
         Add_Column (Result, "attnotnull", 16, 1);
         Add_Column (Result, "attcollation");
         Add_Column (Result, "attidentity");
         Add_Column (Result, "attgenerated");
         for Column in 1 .. Source.Column_Count loop
            Values := (others => Null_Cell);
            Values (1) := Text_Cell (SQL.Image (Source.Columns (Column).Name));
            Values (2) := Text_Cell
              ((case Source.Columns (Column).Type_Oid is
                 when 16 => "boolean",
                 when 20 => "bigint",
                 when 23 => "integer",
                 when 1_184 => "timestamp with time zone",
                 when others => "text"));
            Values (3) := Null_Cell;
            Values (4) := Text_Cell ("f");
            Values (5) := Null_Cell;
            Values (6) := Text_Cell ("");
            Values (7) := Text_Cell ("");
            Add_Row (Result, Values);
         end loop;
      elsif Ada.Strings.Fixed.Index (Lower, "select c.relchecks") /= 0 then
         declare
            Names : constant array (Positive range <>) of SQL.Name_Text :=
              (T ("relchecks"), T ("relkind"), T ("relhasindex"),
               T ("relhasrules"), T ("relhastriggers"),
               T ("relrowsecurity"), T ("relforcerowsecurity"),
               T ("relhasoids"), T ("relispartition"),
               T ("partition_key"), T ("reltablespace"), T ("reloftype"),
               T ("relpersistence"), T ("relreplident"), T ("amname"));
         begin
            for Name of Names loop
               Add_Column (Result, SQL.Image (Name));
            end loop;
         end;
         Values := (others => Null_Cell);
         Values (1) := Text_Cell ("0");
         Values (2) := Text_Cell ("v");
         for Index in 3 .. 9 loop
            Values (Index) := Text_Cell ("f");
         end loop;
         Values (10) := Text_Cell ("");
         Values (11) := Text_Cell ("0");
         Values (12) := Text_Cell ("");
         Values (13) := Text_Cell ("p");
         Values (14) := Text_Cell ("d");
         Values (15) := Null_Cell;
         Add_Row (Result, Values);
      elsif Ada.Strings.Fixed.Index
        (Lower, "pg_catalog.pg_get_userbyid") /= 0
      then
         Add_Column (Result, "Schema");
         Add_Column (Result, "Name");
         Add_Column (Result, "Type");
         Add_Column (Result, "Owner");
         for Table of Tables loop
            Values := (others => Null_Cell);
            Values (1) := Text_Cell ("flyology");
            Values (2) := Text_Cell (SQL.Image (Table.Name));
            Values (3) := Text_Cell ("view");
            Values (4) := Text_Cell ("flyology");
            Add_Row (Result, Values);
         end loop;
      else
         Add_Column (Result, "oid", 26, 4);
         Add_Column (Result, "nspname");
         Add_Column (Result, "relname");
         for Index in Tables'Range loop
            if Ada.Strings.Fixed.Index
              (Lower, SQL.Image (Tables (Index).Name)) /= 0
            then
               Values := (others => Null_Cell);
               Values (1) := Text_Cell
                 (Trim_Image (Integer'Image (10_000 + Index)));
               Values (2) := Text_Cell ("flyology");
               Values (3) := Text_Cell (SQL.Image (Tables (Index).Name));
               Add_Row (Result, Values);
            end if;
         end loop;
      end if;
   end Psql_Compatibility;

end Pgish_Catalog;
