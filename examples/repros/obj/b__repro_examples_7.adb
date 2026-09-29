pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__repro_examples_7.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__repro_examples_7.adb");
pragma Suppress (Overflow_Check);

with System.Restrictions;
with Ada.Exceptions;

package body ada_main is

   E008 : Short_Integer; pragma Import (Ada, E008, "ada__exceptions_E");
   E013 : Short_Integer; pragma Import (Ada, E013, "system__soft_links_E");
   E024 : Short_Integer; pragma Import (Ada, E024, "system__exception_table_E");
   E025 : Short_Integer; pragma Import (Ada, E025, "system__exceptions_E");
   E020 : Short_Integer; pragma Import (Ada, E020, "system__soft_links__initialize_E");
   E175 : Short_Integer; pragma Import (Ada, E175, "ada__assertions_E");
   E100 : Short_Integer; pragma Import (Ada, E100, "ada__containers_E");
   E106 : Short_Integer; pragma Import (Ada, E106, "ada__io_exceptions_E");
   E094 : Short_Integer; pragma Import (Ada, E094, "ada__strings_E");
   E110 : Short_Integer; pragma Import (Ada, E110, "ada__strings__utf_encoding_E");
   E350 : Short_Integer; pragma Import (Ada, E350, "gnat_E");
   E053 : Short_Integer; pragma Import (Ada, E053, "interfaces__c_E");
   E228 : Short_Integer; pragma Import (Ada, E228, "interfaces__c__strings_E");
   E055 : Short_Integer; pragma Import (Ada, E055, "system__os_lib_E");
   E118 : Short_Integer; pragma Import (Ada, E118, "ada__tags_E");
   E108 : Short_Integer; pragma Import (Ada, E108, "ada__strings__text_buffers_E");
   E105 : Short_Integer; pragma Import (Ada, E105, "ada__streams_E");
   E158 : Short_Integer; pragma Import (Ada, E158, "system__file_control_block_E");
   E129 : Short_Integer; pragma Import (Ada, E129, "system__finalization_root_E");
   E103 : Short_Integer; pragma Import (Ada, E103, "ada__finalization_E");
   E155 : Short_Integer; pragma Import (Ada, E155, "system__file_io_E");
   E162 : Short_Integer; pragma Import (Ada, E162, "system__storage_pools_E");
   E235 : Short_Integer; pragma Import (Ada, E235, "system__storage_pools__subpools_E");
   E006 : Short_Integer; pragma Import (Ada, E006, "ada__calendar_E");
   E075 : Short_Integer; pragma Import (Ada, E075, "ada__calendar__delays_E");
   E081 : Short_Integer; pragma Import (Ada, E081, "ada__calendar__time_zones_E");
   E222 : Short_Integer; pragma Import (Ada, E222, "ada__text_io_E");
   E182 : Short_Integer; pragma Import (Ada, E182, "system__flyology__scheduler_E");
   E164 : Short_Integer; pragma Import (Ada, E164, "ada__real_time_E");
   E096 : Short_Integer; pragma Import (Ada, E096, "ada__strings__maps_E");
   E099 : Short_Integer; pragma Import (Ada, E099, "ada__strings__maps__constants_E");
   E141 : Short_Integer; pragma Import (Ada, E141, "ada__strings__unbounded_E");
   E256 : Short_Integer; pragma Import (Ada, E256, "system__pool_global_E");
   E160 : Short_Integer; pragma Import (Ada, E160, "system__regexp_E");
   E077 : Short_Integer; pragma Import (Ada, E077, "ada__directories_E");
   E363 : Short_Integer; pragma Import (Ada, E363, "system__tasking__initialization_E");
   E353 : Short_Integer; pragma Import (Ada, E353, "system__tasking__protected_objects_E");
   E369 : Short_Integer; pragma Import (Ada, E369, "system__tasking__protected_objects__entries_E");
   E367 : Short_Integer; pragma Import (Ada, E367, "system__tasking__queuing_E");
   E383 : Short_Integer; pragma Import (Ada, E383, "system__flyology__task_results_E");
   E379 : Short_Integer; pragma Import (Ada, E379, "system__tasking__stages_E");
   E231 : Short_Integer; pragma Import (Ada, E231, "flyology__execution_groups_E");
   E218 : Short_Integer; pragma Import (Ada, E218, "example_repro_support_E");
   E244 : Short_Integer; pragma Import (Ada, E244, "flyology__postgres__sql_E");
   E246 : Short_Integer; pragma Import (Ada, E246, "flyology__postgres__sql_backends_E");
   E282 : Short_Integer; pragma Import (Ada, E282, "flyology__postgres__sql__arena_storage_E");
   E273 : Short_Integer; pragma Import (Ada, E273, "flyology__postgres__sql__internals_E");
   E284 : Short_Integer; pragma Import (Ada, E284, "flyology__postgres__sql__native__builders_E");
   E280 : Short_Integer; pragma Import (Ada, E280, "flyology__postgres__sql__native__converters_E");
   E278 : Short_Integer; pragma Import (Ada, E278, "flyology__postgres__sql__native__backend_E");
   E286 : Short_Integer; pragma Import (Ada, E286, "flyology__postgres__sql__native__schema_v18_E");
   E296 : Short_Integer; pragma Import (Ada, E296, "flyology__postgres__sql__native__semantics_E");
   E292 : Short_Integer; pragma Import (Ada, E292, "flyology__postgres__sql__native__action_catalog_E");
   E294 : Short_Integer; pragma Import (Ada, E294, "flyology__postgres__sql__native__action_catalog_chunk_01_E");
   E298 : Short_Integer; pragma Import (Ada, E298, "flyology__postgres__sql__native__action_catalog_chunk_02_E");
   E300 : Short_Integer; pragma Import (Ada, E300, "flyology__postgres__sql__native__action_catalog_chunk_03_E");
   E302 : Short_Integer; pragma Import (Ada, E302, "flyology__postgres__sql__native__action_catalog_chunk_04_E");
   E304 : Short_Integer; pragma Import (Ada, E304, "flyology__postgres__sql__native__action_catalog_chunk_05_E");
   E306 : Short_Integer; pragma Import (Ada, E306, "flyology__postgres__sql__native__action_catalog_chunk_06_E");
   E308 : Short_Integer; pragma Import (Ada, E308, "flyology__postgres__sql__native__action_catalog_chunk_07_E");
   E310 : Short_Integer; pragma Import (Ada, E310, "flyology__postgres__sql__native__action_catalog_chunk_08_E");
   E312 : Short_Integer; pragma Import (Ada, E312, "flyology__postgres__sql__native__action_catalog_chunk_09_E");
   E314 : Short_Integer; pragma Import (Ada, E314, "flyology__postgres__sql__native__action_catalog_chunk_10_E");
   E316 : Short_Integer; pragma Import (Ada, E316, "flyology__postgres__sql__native__action_catalog_chunk_11_E");
   E318 : Short_Integer; pragma Import (Ada, E318, "flyology__postgres__sql__native__action_catalog_chunk_12_E");
   E320 : Short_Integer; pragma Import (Ada, E320, "flyology__postgres__sql__native__action_catalog_chunk_13_E");
   E322 : Short_Integer; pragma Import (Ada, E322, "flyology__postgres__sql__native__action_catalog_chunk_14_E");
   E326 : Short_Integer; pragma Import (Ada, E326, "flyology__postgres__sql__native__action_helper_catalog_E");
   E328 : Short_Integer; pragma Import (Ada, E328, "flyology__postgres__sql__native__action_helper_catalog_chunk_01_E");
   E330 : Short_Integer; pragma Import (Ada, E330, "flyology__postgres__sql__native__action_helper_catalog_chunk_02_E");
   E332 : Short_Integer; pragma Import (Ada, E332, "flyology__postgres__sql__native__action_helper_catalog_chunk_03_E");
   E324 : Short_Integer; pragma Import (Ada, E324, "flyology__postgres__sql__native__actions_v18_support_E");
   E290 : Short_Integer; pragma Import (Ada, E290, "flyology__postgres__sql__native__actions_v18_E");
   E334 : Short_Integer; pragma Import (Ada, E334, "flyology__postgres__sql__native__dfa_E");
   E339 : Short_Integer; pragma Import (Ada, E339, "flyology__postgres__sql__native__lalr_E");
   E341 : Short_Integer; pragma Import (Ada, E341, "flyology__postgres__sql__native__scanner_E");
   E337 : Short_Integer; pragma Import (Ada, E337, "flyology__postgres__sql__native__engine_E");
   E288 : Short_Integer; pragma Import (Ada, E288, "flyology__postgres__sql__native__version_v18_E");
   E276 : Short_Integer; pragma Import (Ada, E276, "flyology__postgres__sql__native__backend_v18_E");
   E269 : Short_Integer; pragma Import (Ada, E269, "flyology__postgres__sql__views_E");
   E271 : Short_Integer; pragma Import (Ada, E271, "flyology__postgres__sql__views__v18_E");
   E263 : Short_Integer; pragma Import (Ada, E263, "flyology__postgres__sql__ast__v18_E");
   E265 : Short_Integer; pragma Import (Ada, E265, "flyology__postgres__sql__ast_materialization_v18_E");
   E267 : Short_Integer; pragma Import (Ada, E267, "flyology__postgres__sql__ast_ownership_v18_E");
   E344 : Short_Integer; pragma Import (Ada, E344, "flyology__postgres__sql__ast_parser_v18_E");
   E346 : Short_Integer; pragma Import (Ada, E346, "flyology__postgres__sql__ast__v18__visitors_E");
   E241 : Short_Integer; pragma Import (Ada, E241, "pgish_sql_E");
   E349 : Short_Integer; pragma Import (Ada, E349, "pgish_state_E");
   E224 : Short_Integer; pragma Import (Ada, E224, "pgish_catalog_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      E263 := E263 - 1;
      declare
         procedure F1;
         pragma Import (Ada, F1, "flyology__postgres__sql__ast__v18__finalize_spec");
      begin
         F1;
      end;
      declare
         procedure F2;
         pragma Import (Ada, F2, "flyology__postgres__sql__native__version_v18__finalize_body");
      begin
         E288 := E288 - 1;
         F2;
      end;
      E284 := E284 - 1;
      declare
         procedure F3;
         pragma Import (Ada, F3, "flyology__postgres__sql__native__builders__finalize_spec");
      begin
         F3;
      end;
      E244 := E244 - 1;
      declare
         procedure F4;
         pragma Import (Ada, F4, "flyology__postgres__sql__finalize_spec");
      begin
         F4;
      end;
      E231 := E231 - 1;
      declare
         procedure F5;
         pragma Import (Ada, F5, "flyology__execution_groups__finalize_spec");
      begin
         F5;
      end;
      E369 := E369 - 1;
      declare
         procedure F6;
         pragma Import (Ada, F6, "system__tasking__protected_objects__entries__finalize_spec");
      begin
         F6;
      end;
      declare
         procedure F7;
         pragma Import (Ada, F7, "ada__directories__finalize_body");
      begin
         E077 := E077 - 1;
         F7;
      end;
      declare
         procedure F8;
         pragma Import (Ada, F8, "ada__directories__finalize_spec");
      begin
         F8;
      end;
      E160 := E160 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "system__regexp__finalize_spec");
      begin
         F9;
      end;
      E256 := E256 - 1;
      declare
         procedure F10;
         pragma Import (Ada, F10, "system__pool_global__finalize_spec");
      begin
         F10;
      end;
      E141 := E141 - 1;
      declare
         procedure F11;
         pragma Import (Ada, F11, "ada__strings__unbounded__finalize_spec");
      begin
         F11;
      end;
      E222 := E222 - 1;
      declare
         procedure F12;
         pragma Import (Ada, F12, "ada__text_io__finalize_spec");
      begin
         F12;
      end;
      E235 := E235 - 1;
      declare
         procedure F13;
         pragma Import (Ada, F13, "system__storage_pools__subpools__finalize_spec");
      begin
         F13;
      end;
      declare
         procedure F14;
         pragma Import (Ada, F14, "system__file_io__finalize_body");
      begin
         E155 := E155 - 1;
         F14;
      end;
      declare
         procedure Reraise_Library_Exception_If_Any;
            pragma Import (Ada, Reraise_Library_Exception_If_Any, "__gnat_reraise_library_exception_if_any");
      begin
         Reraise_Library_Exception_If_Any;
      end;
   end finalize_library;

   procedure adafinal is
      procedure s_stalib_adafinal;
      pragma Import (Ada, s_stalib_adafinal, "system__standard_library__adafinal");

      procedure Runtime_Finalize;
      pragma Import (C, Runtime_Finalize, "__gnat_runtime_finalize");

   begin
      if not Is_Elaborated then
         return;
      end if;
      Is_Elaborated := False;
      Runtime_Finalize;
      s_stalib_adafinal;
   end adafinal;

   type No_Param_Proc is access procedure;
   pragma Favor_Top_Level (No_Param_Proc);

   procedure adainit is
      Main_Priority : Integer;
      pragma Import (C, Main_Priority, "__gl_main_priority");
      Time_Slice_Value : Integer;
      pragma Import (C, Time_Slice_Value, "__gl_time_slice_val");
      WC_Encoding : Character;
      pragma Import (C, WC_Encoding, "__gl_wc_encoding");
      Locking_Policy : Character;
      pragma Import (C, Locking_Policy, "__gl_locking_policy");
      Queuing_Policy : Character;
      pragma Import (C, Queuing_Policy, "__gl_queuing_policy");
      Task_Dispatching_Policy : Character;
      pragma Import (C, Task_Dispatching_Policy, "__gl_task_dispatching_policy");
      Priority_Specific_Dispatching : System.Address;
      pragma Import (C, Priority_Specific_Dispatching, "__gl_priority_specific_dispatching");
      Num_Specific_Dispatching : Integer;
      pragma Import (C, Num_Specific_Dispatching, "__gl_num_specific_dispatching");
      Main_CPU : Integer;
      pragma Import (C, Main_CPU, "__gl_main_cpu");
      Interrupt_States : System.Address;
      pragma Import (C, Interrupt_States, "__gl_interrupt_states");
      Num_Interrupt_States : Integer;
      pragma Import (C, Num_Interrupt_States, "__gl_num_interrupt_states");
      Unreserve_All_Interrupts : Integer;
      pragma Import (C, Unreserve_All_Interrupts, "__gl_unreserve_all_interrupts");
      Exception_Tracebacks : Integer;
      pragma Import (C, Exception_Tracebacks, "__gl_exception_tracebacks");
      Exception_Tracebacks_Symbolic : Integer;
      pragma Import (C, Exception_Tracebacks_Symbolic, "__gl_exception_tracebacks_symbolic");
      Detect_Blocking : Integer;
      pragma Import (C, Detect_Blocking, "__gl_detect_blocking");
      Default_Stack_Size : Integer;
      pragma Import (C, Default_Stack_Size, "__gl_default_stack_size");
      Default_Secondary_Stack_Size : System.Parameters.Size_Type;
      pragma Import (C, Default_Secondary_Stack_Size, "__gnat_default_ss_size");
      Bind_Env_Addr : System.Address;
      pragma Import (C, Bind_Env_Addr, "__gl_bind_env_addr");
      Interrupts_Default_To_System : Integer;
      pragma Import (C, Interrupts_Default_To_System, "__gl_interrupts_default_to_system");

      procedure Runtime_Initialize (Install_Handler : Integer);
      pragma Import (C, Runtime_Initialize, "__gnat_runtime_initialize");

      procedure Tasking_Runtime_Initialize;
      pragma Import (C, Tasking_Runtime_Initialize, "__gnat_tasking_runtime_initialize");

      Finalize_Library_Objects : No_Param_Proc;
      pragma Import (C, Finalize_Library_Objects, "__gnat_finalize_library_objects");
      Binder_Sec_Stacks_Count : Natural;
      pragma Import (Ada, Binder_Sec_Stacks_Count, "__gnat_binder_ss_count");
      Default_Sized_SS_Pool : System.Address;
      pragma Import (Ada, Default_Sized_SS_Pool, "__gnat_default_ss_pool");

   begin
      if Is_Elaborated then
         return;
      end if;
      Is_Elaborated := True;
      Main_Priority := -1;
      Time_Slice_Value := -1;
      WC_Encoding := 'b';
      Locking_Policy := ' ';
      Queuing_Policy := ' ';
      Task_Dispatching_Policy := ' ';
      System.Restrictions.Run_Time_Restrictions :=
        (Set =>
          (False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, True, False, False, False, False, 
           False, False, False, False, False, False, False, False, 
           False, False, False, False),
         Value => (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
         Violated =>
          (False, False, False, False, True, True, False, False, 
           True, False, False, True, True, True, True, False, 
           False, False, False, True, False, False, True, True, 
           False, True, True, False, True, True, True, True, 
           False, False, False, False, False, True, True, False, 
           True, True, False, True, False, True, True, False, 
           True, False, True, True, False, False, True, False, 
           True, False, False, False, False, True, False, False, 
           False, True, False, True, True, True, False, False, 
           True, False, True, True, True, False, True, True, 
           False, True, True, True, True, False, False, False, 
           True, False, False, False, False, True, False, True, 
           True, False, True, False),
         Count => (0, 0, 0, 1, 0, 1, 1, 0, 2, 0),
         Unknown => (False, False, False, False, False, False, True, False, True, False));
      Priority_Specific_Dispatching :=
        Local_Priority_Specific_Dispatching'Address;
      Num_Specific_Dispatching := 0;
      Main_CPU := -1;
      Interrupt_States := Local_Interrupt_States'Address;
      Num_Interrupt_States := 0;
      Unreserve_All_Interrupts := 0;
      Exception_Tracebacks := 1;
      Exception_Tracebacks_Symbolic := 1;
      Detect_Blocking := 0;
      Default_Stack_Size := -1;

      ada_main'Elab_Body;
      Default_Secondary_Stack_Size := System.Parameters.Runtime_Default_Sec_Stack_Size;
      Binder_Sec_Stacks_Count := 1;
      Default_Sized_SS_Pool := Sec_Default_Sized_Stacks'Address;

      Runtime_Initialize (1);
      Tasking_Runtime_Initialize;

      Finalize_Library_Objects := finalize_library'access;

      Ada.Exceptions'Elab_Spec;
      System.Soft_Links'Elab_Spec;
      System.Exception_Table'Elab_Body;
      E024 := E024 + 1;
      System.Exceptions'Elab_Spec;
      E025 := E025 + 1;
      System.Soft_Links.Initialize'Elab_Body;
      E020 := E020 + 1;
      E013 := E013 + 1;
      E008 := E008 + 1;
      Ada.Assertions'Elab_Spec;
      E175 := E175 + 1;
      Ada.Containers'Elab_Spec;
      E100 := E100 + 1;
      Ada.Io_Exceptions'Elab_Spec;
      E106 := E106 + 1;
      Ada.Strings'Elab_Spec;
      E094 := E094 + 1;
      Ada.Strings.Utf_Encoding'Elab_Spec;
      E110 := E110 + 1;
      Gnat'Elab_Spec;
      E350 := E350 + 1;
      Interfaces.C'Elab_Spec;
      E053 := E053 + 1;
      Interfaces.C.Strings'Elab_Spec;
      E228 := E228 + 1;
      System.Os_Lib'Elab_Body;
      E055 := E055 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E118 := E118 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E108 := E108 + 1;
      Ada.Streams'Elab_Spec;
      E105 := E105 + 1;
      System.File_Control_Block'Elab_Spec;
      E158 := E158 + 1;
      System.Finalization_Root'Elab_Spec;
      E129 := E129 + 1;
      Ada.Finalization'Elab_Spec;
      E103 := E103 + 1;
      System.File_Io'Elab_Body;
      E155 := E155 + 1;
      System.Storage_Pools'Elab_Spec;
      E162 := E162 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E235 := E235 + 1;
      Ada.Calendar'Elab_Spec;
      Ada.Calendar'Elab_Body;
      E006 := E006 + 1;
      Ada.Calendar.Delays'Elab_Body;
      E075 := E075 + 1;
      Ada.Calendar.Time_Zones'Elab_Spec;
      E081 := E081 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E222 := E222 + 1;
      System.Flyology.Scheduler'Elab_Body;
      E182 := E182 + 1;
      Ada.Real_Time'Elab_Spec;
      Ada.Real_Time'Elab_Body;
      E164 := E164 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E096 := E096 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E099 := E099 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E141 := E141 + 1;
      System.Pool_Global'Elab_Spec;
      E256 := E256 + 1;
      System.Regexp'Elab_Spec;
      E160 := E160 + 1;
      Ada.Directories'Elab_Spec;
      Ada.Directories'Elab_Body;
      E077 := E077 + 1;
      System.Tasking.Initialization'Elab_Body;
      E363 := E363 + 1;
      System.Tasking.Protected_Objects'Elab_Body;
      E353 := E353 + 1;
      System.Tasking.Protected_Objects.Entries'Elab_Spec;
      E369 := E369 + 1;
      System.Tasking.Queuing'Elab_Body;
      E367 := E367 + 1;
      System.Flyology.Task_Results'Elab_Body;
      E383 := E383 + 1;
      System.Tasking.Stages'Elab_Body;
      E379 := E379 + 1;
      Flyology.Execution_Groups'Elab_Spec;
      E231 := E231 + 1;
      E218 := E218 + 1;
      Flyology.Postgres.Sql'Elab_Spec;
      E246 := E246 + 1;
      Flyology.Postgres.Sql'Elab_Body;
      E244 := E244 + 1;
      E282 := E282 + 1;
      E273 := E273 + 1;
      Flyology.Postgres.Sql.Native.Builders'Elab_Spec;
      Flyology.Postgres.Sql.Native.Builders'Elab_Body;
      E284 := E284 + 1;
      Flyology.Postgres.Sql.Native.Converters'Elab_Spec;
      E280 := E280 + 1;
      E278 := E278 + 1;
      Flyology.Postgres.Sql.Native.Schema_V18'Elab_Spec;
      E286 := E286 + 1;
      Flyology.Postgres.Sql.Native.Semantics'Elab_Spec;
      E296 := E296 + 1;
      E294 := E294 + 1;
      E298 := E298 + 1;
      E300 := E300 + 1;
      E302 := E302 + 1;
      E304 := E304 + 1;
      E306 := E306 + 1;
      E308 := E308 + 1;
      E310 := E310 + 1;
      E312 := E312 + 1;
      E314 := E314 + 1;
      E316 := E316 + 1;
      E318 := E318 + 1;
      E320 := E320 + 1;
      E322 := E322 + 1;
      E292 := E292 + 1;
      E328 := E328 + 1;
      E330 := E330 + 1;
      E332 := E332 + 1;
      E326 := E326 + 1;
      E324 := E324 + 1;
      E290 := E290 + 1;
      E334 := E334 + 1;
      E339 := E339 + 1;
      E341 := E341 + 1;
      E337 := E337 + 1;
      Flyology.Postgres.Sql.Native.Version_V18'Elab_Body;
      E288 := E288 + 1;
      Flyology.Postgres.Sql.Native.Backend_V18'Elab_Body;
      E276 := E276 + 1;
      E269 := E269 + 1;
      E271 := E271 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Spec;
      E267 := E267 + 1;
      E265 := E265 + 1;
      E344 := E344 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Body;
      E263 := E263 + 1;
      Flyology.Postgres.Sql.Ast.V18.Visitors'Elab_Spec;
      E346 := E346 + 1;
      Pgish_Sql'Elab_Spec;
      E241 := E241 + 1;
      E349 := E349 + 1;
      Pgish_Catalog'Elab_Spec;
      Pgish_Catalog'Elab_Body;
      E224 := E224 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_repro_examples_7");

   function main
     (argc : Integer;
      argv : System.Address;
      envp : System.Address)
      return Integer
   is
      procedure Initialize (Addr : System.Address);
      pragma Import (C, Initialize, "__gnat_initialize");

      procedure Finalize;
      pragma Import (C, Finalize, "__gnat_finalize");
      SEH : aliased array (1 .. 2) of Integer;

      Ensure_Reference : aliased System.Address := Ada_Main_Program_Name'Address;
      pragma Volatile (Ensure_Reference);

   begin
      if gnat_argc = 0 then
         gnat_argc := argc;
         gnat_argv := argv;
      end if;
      gnat_envp := envp;

      Initialize (SEH'Address);
      adainit;
      Ada_Main_Program;
      adafinal;
      Finalize;
      return (gnat_exit_status);
   end;

--  BEGIN Object file/option list
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/example_repro_support.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/pgish_sql.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/pgish_state.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/pgish_catalog.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/repro_examples_7.o
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_0.1.1_bd95746d/3cf1f8e431e0343b4154ab650e51121b9e3441939b55a10702aab1165f04bd0a/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_6f91b1af/ce5a6cb5c23b9204ed30aafa3511ec1573b30b3a1b47dd8721b7721c266f17ae/flyology_allocators/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/hmac_ada_0.2.0_6cab7904/76e9122652dc905df27753c9448614fa19e645efd9d11ce9ee33520edd1b8616/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/system_random_1.0.0_3db7f76e/8e772b64f4c98910d054fb00f95b9ff4d4ec2bc960e27711b878528e74ef5617/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v18/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/core/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/linenoise_ada_1.1.2_d96796f6/25369ec00ad073095506c76079e658939c3de54081cba6cd99a44584f230bfbc/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_0.1.1_bd95746d/3cf1f8e431e0343b4154ab650e51121b9e3441939b55a10702aab1165f04bd0a/build/alire-rts/adalib/
   --   -static
   --   -lgnarl
   --   -lgnat
--  END Object file/option list   

end ada_main;
