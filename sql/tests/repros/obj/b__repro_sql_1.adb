pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__repro_sql_1.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__repro_sql_1.adb");
pragma Suppress (Overflow_Check);
with Ada.Exceptions;

package body ada_main is

   E005 : Short_Integer; pragma Import (Ada, E005, "ada__exceptions_E");
   E011 : Short_Integer; pragma Import (Ada, E011, "system__soft_links_E");
   E022 : Short_Integer; pragma Import (Ada, E022, "system__exception_table_E");
   E023 : Short_Integer; pragma Import (Ada, E023, "system__exceptions_E");
   E018 : Short_Integer; pragma Import (Ada, E018, "system__soft_links__initialize_E");
   E088 : Short_Integer; pragma Import (Ada, E088, "ada__containers_E");
   E094 : Short_Integer; pragma Import (Ada, E094, "ada__io_exceptions_E");
   E052 : Short_Integer; pragma Import (Ada, E052, "ada__strings_E");
   E054 : Short_Integer; pragma Import (Ada, E054, "ada__strings__utf_encoding_E");
   E085 : Short_Integer; pragma Import (Ada, E085, "interfaces__c_E");
   E272 : Short_Integer; pragma Import (Ada, E272, "interfaces__c__strings_E");
   E300 : Short_Integer; pragma Import (Ada, E300, "system__os_lib_E");
   E062 : Short_Integer; pragma Import (Ada, E062, "ada__tags_E");
   E051 : Short_Integer; pragma Import (Ada, E051, "ada__strings__text_buffers_E");
   E093 : Short_Integer; pragma Import (Ada, E093, "ada__streams_E");
   E304 : Short_Integer; pragma Import (Ada, E304, "system__file_control_block_E");
   E100 : Short_Integer; pragma Import (Ada, E100, "system__finalization_root_E");
   E091 : Short_Integer; pragma Import (Ada, E091, "ada__finalization_E");
   E296 : Short_Integer; pragma Import (Ada, E296, "system__file_io_E");
   E137 : Short_Integer; pragma Import (Ada, E137, "system__storage_pools_E");
   E139 : Short_Integer; pragma Import (Ada, E139, "system__storage_pools__subpools_E");
   E292 : Short_Integer; pragma Import (Ada, E292, "ada__text_io_E");
   E108 : Short_Integer; pragma Import (Ada, E108, "ada__strings__maps_E");
   E169 : Short_Integer; pragma Import (Ada, E169, "ada__strings__maps__constants_E");
   E106 : Short_Integer; pragma Import (Ada, E106, "ada__strings__unbounded_E");
   E131 : Short_Integer; pragma Import (Ada, E131, "system__pool_global_E");
   E078 : Short_Integer; pragma Import (Ada, E078, "flyology__postgres__sql_E");
   E080 : Short_Integer; pragma Import (Ada, E080, "flyology__postgres__sql_backends_E");
   E160 : Short_Integer; pragma Import (Ada, E160, "flyology__postgres__sql__arena_storage_E");
   E270 : Short_Integer; pragma Import (Ada, E270, "flyology__postgres__sql__backends_E");
   E276 : Short_Integer; pragma Import (Ada, E276, "flyology__postgres__sql__decoders_E");
   E274 : Short_Integer; pragma Import (Ada, E274, "flyology__postgres__sql__decoder_v14_E");
   E278 : Short_Integer; pragma Import (Ada, E278, "flyology__postgres__sql__decoder_v15_E");
   E280 : Short_Integer; pragma Import (Ada, E280, "flyology__postgres__sql__decoder_v16_E");
   E282 : Short_Integer; pragma Import (Ada, E282, "flyology__postgres__sql__decoder_v17_E");
   E284 : Short_Integer; pragma Import (Ada, E284, "flyology__postgres__sql__decoder_v18_E");
   E268 : Short_Integer; pragma Import (Ada, E268, "flyology__postgres__sql__c_oracle_E");
   E286 : Short_Integer; pragma Import (Ada, E286, "flyology__postgres__sql__internals_E");
   E162 : Short_Integer; pragma Import (Ada, E162, "flyology__postgres__sql__native__builders_E");
   E158 : Short_Integer; pragma Import (Ada, E158, "flyology__postgres__sql__native__converters_E");
   E156 : Short_Integer; pragma Import (Ada, E156, "flyology__postgres__sql__native__backend_E");
   E164 : Short_Integer; pragma Import (Ada, E164, "flyology__postgres__sql__native__schema_v14_E");
   E229 : Short_Integer; pragma Import (Ada, E229, "flyology__postgres__sql__native__schema_v15_E");
   E239 : Short_Integer; pragma Import (Ada, E239, "flyology__postgres__sql__native__schema_v16_E");
   E249 : Short_Integer; pragma Import (Ada, E249, "flyology__postgres__sql__native__schema_v17_E");
   E259 : Short_Integer; pragma Import (Ada, E259, "flyology__postgres__sql__native__schema_v18_E");
   E179 : Short_Integer; pragma Import (Ada, E179, "flyology__postgres__sql__native__semantics_E");
   E175 : Short_Integer; pragma Import (Ada, E175, "flyology__postgres__sql__native__action_catalog_E");
   E177 : Short_Integer; pragma Import (Ada, E177, "flyology__postgres__sql__native__action_catalog_chunk_01_E");
   E182 : Short_Integer; pragma Import (Ada, E182, "flyology__postgres__sql__native__action_catalog_chunk_02_E");
   E184 : Short_Integer; pragma Import (Ada, E184, "flyology__postgres__sql__native__action_catalog_chunk_03_E");
   E186 : Short_Integer; pragma Import (Ada, E186, "flyology__postgres__sql__native__action_catalog_chunk_04_E");
   E188 : Short_Integer; pragma Import (Ada, E188, "flyology__postgres__sql__native__action_catalog_chunk_05_E");
   E190 : Short_Integer; pragma Import (Ada, E190, "flyology__postgres__sql__native__action_catalog_chunk_06_E");
   E192 : Short_Integer; pragma Import (Ada, E192, "flyology__postgres__sql__native__action_catalog_chunk_07_E");
   E194 : Short_Integer; pragma Import (Ada, E194, "flyology__postgres__sql__native__action_catalog_chunk_08_E");
   E196 : Short_Integer; pragma Import (Ada, E196, "flyology__postgres__sql__native__action_catalog_chunk_09_E");
   E198 : Short_Integer; pragma Import (Ada, E198, "flyology__postgres__sql__native__action_catalog_chunk_10_E");
   E200 : Short_Integer; pragma Import (Ada, E200, "flyology__postgres__sql__native__action_catalog_chunk_11_E");
   E202 : Short_Integer; pragma Import (Ada, E202, "flyology__postgres__sql__native__action_catalog_chunk_12_E");
   E204 : Short_Integer; pragma Import (Ada, E204, "flyology__postgres__sql__native__action_catalog_chunk_13_E");
   E206 : Short_Integer; pragma Import (Ada, E206, "flyology__postgres__sql__native__action_catalog_chunk_14_E");
   E210 : Short_Integer; pragma Import (Ada, E210, "flyology__postgres__sql__native__action_helper_catalog_E");
   E212 : Short_Integer; pragma Import (Ada, E212, "flyology__postgres__sql__native__action_helper_catalog_chunk_01_E");
   E214 : Short_Integer; pragma Import (Ada, E214, "flyology__postgres__sql__native__action_helper_catalog_chunk_02_E");
   E216 : Short_Integer; pragma Import (Ada, E216, "flyology__postgres__sql__native__action_helper_catalog_chunk_03_E");
   E208 : Short_Integer; pragma Import (Ada, E208, "flyology__postgres__sql__native__actions_v14_support_E");
   E173 : Short_Integer; pragma Import (Ada, E173, "flyology__postgres__sql__native__actions_v14_E");
   E235 : Short_Integer; pragma Import (Ada, E235, "flyology__postgres__sql__native__actions_v15_support_E");
   E233 : Short_Integer; pragma Import (Ada, E233, "flyology__postgres__sql__native__actions_v15_E");
   E245 : Short_Integer; pragma Import (Ada, E245, "flyology__postgres__sql__native__actions_v16_support_E");
   E243 : Short_Integer; pragma Import (Ada, E243, "flyology__postgres__sql__native__actions_v16_E");
   E255 : Short_Integer; pragma Import (Ada, E255, "flyology__postgres__sql__native__actions_v17_support_E");
   E253 : Short_Integer; pragma Import (Ada, E253, "flyology__postgres__sql__native__actions_v17_E");
   E265 : Short_Integer; pragma Import (Ada, E265, "flyology__postgres__sql__native__actions_v18_support_E");
   E263 : Short_Integer; pragma Import (Ada, E263, "flyology__postgres__sql__native__actions_v18_E");
   E218 : Short_Integer; pragma Import (Ada, E218, "flyology__postgres__sql__native__dfa_E");
   E223 : Short_Integer; pragma Import (Ada, E223, "flyology__postgres__sql__native__lalr_E");
   E225 : Short_Integer; pragma Import (Ada, E225, "flyology__postgres__sql__native__scanner_E");
   E221 : Short_Integer; pragma Import (Ada, E221, "flyology__postgres__sql__native__engine_E");
   E166 : Short_Integer; pragma Import (Ada, E166, "flyology__postgres__sql__native__version_v14_E");
   E154 : Short_Integer; pragma Import (Ada, E154, "flyology__postgres__sql__native__backend_v14_E");
   E231 : Short_Integer; pragma Import (Ada, E231, "flyology__postgres__sql__native__version_v15_E");
   E228 : Short_Integer; pragma Import (Ada, E228, "flyology__postgres__sql__native__backend_v15_E");
   E241 : Short_Integer; pragma Import (Ada, E241, "flyology__postgres__sql__native__version_v16_E");
   E238 : Short_Integer; pragma Import (Ada, E238, "flyology__postgres__sql__native__backend_v16_E");
   E251 : Short_Integer; pragma Import (Ada, E251, "flyology__postgres__sql__native__version_v17_E");
   E248 : Short_Integer; pragma Import (Ada, E248, "flyology__postgres__sql__native__backend_v17_E");
   E261 : Short_Integer; pragma Import (Ada, E261, "flyology__postgres__sql__native__version_v18_E");
   E258 : Short_Integer; pragma Import (Ada, E258, "flyology__postgres__sql__native__backend_v18_E");
   E149 : Short_Integer; pragma Import (Ada, E149, "flyology__postgres__sql__repro_oracle_E");
   E288 : Short_Integer; pragma Import (Ada, E288, "sql_repro_support_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      declare
         procedure F1;
         pragma Import (Ada, F1, "flyology__postgres__sql__native__version_v18__finalize_body");
      begin
         E261 := E261 - 1;
         F1;
      end;
      declare
         procedure F2;
         pragma Import (Ada, F2, "flyology__postgres__sql__native__version_v17__finalize_body");
      begin
         E251 := E251 - 1;
         F2;
      end;
      declare
         procedure F3;
         pragma Import (Ada, F3, "flyology__postgres__sql__native__version_v16__finalize_body");
      begin
         E241 := E241 - 1;
         F3;
      end;
      declare
         procedure F4;
         pragma Import (Ada, F4, "flyology__postgres__sql__native__version_v15__finalize_body");
      begin
         E231 := E231 - 1;
         F4;
      end;
      declare
         procedure F5;
         pragma Import (Ada, F5, "flyology__postgres__sql__native__version_v14__finalize_body");
      begin
         E166 := E166 - 1;
         F5;
      end;
      E162 := E162 - 1;
      declare
         procedure F6;
         pragma Import (Ada, F6, "flyology__postgres__sql__native__builders__finalize_spec");
      begin
         F6;
      end;
      E078 := E078 - 1;
      declare
         procedure F7;
         pragma Import (Ada, F7, "flyology__postgres__sql__finalize_spec");
      begin
         F7;
      end;
      E131 := E131 - 1;
      declare
         procedure F8;
         pragma Import (Ada, F8, "system__pool_global__finalize_spec");
      begin
         F8;
      end;
      E106 := E106 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "ada__strings__unbounded__finalize_spec");
      begin
         F9;
      end;
      E292 := E292 - 1;
      declare
         procedure F10;
         pragma Import (Ada, F10, "ada__text_io__finalize_spec");
      begin
         F10;
      end;
      E139 := E139 - 1;
      declare
         procedure F11;
         pragma Import (Ada, F11, "system__storage_pools__subpools__finalize_spec");
      begin
         F11;
      end;
      declare
         procedure F12;
         pragma Import (Ada, F12, "system__file_io__finalize_body");
      begin
         E296 := E296 - 1;
         F12;
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

      Finalize_Library_Objects := finalize_library'access;

      Ada.Exceptions'Elab_Spec;
      System.Soft_Links'Elab_Spec;
      System.Exception_Table'Elab_Body;
      E022 := E022 + 1;
      System.Exceptions'Elab_Spec;
      E023 := E023 + 1;
      System.Soft_Links.Initialize'Elab_Body;
      E018 := E018 + 1;
      E011 := E011 + 1;
      E005 := E005 + 1;
      Ada.Containers'Elab_Spec;
      E088 := E088 + 1;
      Ada.Io_Exceptions'Elab_Spec;
      E094 := E094 + 1;
      Ada.Strings'Elab_Spec;
      E052 := E052 + 1;
      Ada.Strings.Utf_Encoding'Elab_Spec;
      E054 := E054 + 1;
      Interfaces.C'Elab_Spec;
      E085 := E085 + 1;
      Interfaces.C.Strings'Elab_Spec;
      E272 := E272 + 1;
      System.Os_Lib'Elab_Body;
      E300 := E300 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E062 := E062 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E051 := E051 + 1;
      Ada.Streams'Elab_Spec;
      E093 := E093 + 1;
      System.File_Control_Block'Elab_Spec;
      E304 := E304 + 1;
      System.Finalization_Root'Elab_Spec;
      E100 := E100 + 1;
      Ada.Finalization'Elab_Spec;
      E091 := E091 + 1;
      System.File_Io'Elab_Body;
      E296 := E296 + 1;
      System.Storage_Pools'Elab_Spec;
      E137 := E137 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E139 := E139 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E292 := E292 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E108 := E108 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E169 := E169 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E106 := E106 + 1;
      System.Pool_Global'Elab_Spec;
      E131 := E131 + 1;
      Flyology.Postgres.Sql'Elab_Spec;
      E080 := E080 + 1;
      Flyology.Postgres.Sql'Elab_Body;
      E078 := E078 + 1;
      E160 := E160 + 1;
      E270 := E270 + 1;
      Flyology.Postgres.Sql.Decoders'Elab_Spec;
      E276 := E276 + 1;
      E274 := E274 + 1;
      E278 := E278 + 1;
      E280 := E280 + 1;
      E282 := E282 + 1;
      E284 := E284 + 1;
      E268 := E268 + 1;
      E286 := E286 + 1;
      Flyology.Postgres.Sql.Native.Builders'Elab_Spec;
      Flyology.Postgres.Sql.Native.Builders'Elab_Body;
      E162 := E162 + 1;
      Flyology.Postgres.Sql.Native.Converters'Elab_Spec;
      E158 := E158 + 1;
      E156 := E156 + 1;
      Flyology.Postgres.Sql.Native.Schema_V14'Elab_Spec;
      E164 := E164 + 1;
      Flyology.Postgres.Sql.Native.Schema_V15'Elab_Spec;
      E229 := E229 + 1;
      Flyology.Postgres.Sql.Native.Schema_V16'Elab_Spec;
      E239 := E239 + 1;
      Flyology.Postgres.Sql.Native.Schema_V17'Elab_Spec;
      E249 := E249 + 1;
      Flyology.Postgres.Sql.Native.Schema_V18'Elab_Spec;
      E259 := E259 + 1;
      Flyology.Postgres.Sql.Native.Semantics'Elab_Spec;
      E179 := E179 + 1;
      E177 := E177 + 1;
      E182 := E182 + 1;
      E184 := E184 + 1;
      E186 := E186 + 1;
      E188 := E188 + 1;
      E190 := E190 + 1;
      E192 := E192 + 1;
      E194 := E194 + 1;
      E196 := E196 + 1;
      E198 := E198 + 1;
      E200 := E200 + 1;
      E202 := E202 + 1;
      E204 := E204 + 1;
      E206 := E206 + 1;
      E175 := E175 + 1;
      E212 := E212 + 1;
      E214 := E214 + 1;
      E216 := E216 + 1;
      E210 := E210 + 1;
      E208 := E208 + 1;
      E173 := E173 + 1;
      E235 := E235 + 1;
      E233 := E233 + 1;
      E245 := E245 + 1;
      E243 := E243 + 1;
      E255 := E255 + 1;
      E253 := E253 + 1;
      E265 := E265 + 1;
      E263 := E263 + 1;
      E218 := E218 + 1;
      E223 := E223 + 1;
      E225 := E225 + 1;
      E221 := E221 + 1;
      Flyology.Postgres.Sql.Native.Version_V14'Elab_Body;
      E166 := E166 + 1;
      Flyology.Postgres.Sql.Native.Backend_V14'Elab_Body;
      E154 := E154 + 1;
      Flyology.Postgres.Sql.Native.Version_V15'Elab_Body;
      E231 := E231 + 1;
      Flyology.Postgres.Sql.Native.Backend_V15'Elab_Body;
      E228 := E228 + 1;
      Flyology.Postgres.Sql.Native.Version_V16'Elab_Body;
      E241 := E241 + 1;
      Flyology.Postgres.Sql.Native.Backend_V16'Elab_Body;
      E238 := E238 + 1;
      Flyology.Postgres.Sql.Native.Version_V17'Elab_Body;
      E251 := E251 + 1;
      Flyology.Postgres.Sql.Native.Backend_V17'Elab_Body;
      E248 := E248 + 1;
      Flyology.Postgres.Sql.Native.Version_V18'Elab_Body;
      E261 := E261 + 1;
      Flyology.Postgres.Sql.Native.Backend_V18'Elab_Body;
      E258 := E258 + 1;
      E149 := E149 + 1;
      E288 := E288 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_repro_sql_1");

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
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/flyology-postgres-sql-repro_oracle.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/sql_repro_support.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/repro_sql_1.o
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/
   --   -L/Users/yrashk/.local/share/alire/builds/aunit_26.0.0_b882e96a/c7d2d3946a9f4db393078f76bdd765207c7ecb1cb4501e646254fd6d2ff8f3f3/lib/aunit/native-full/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v14/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/core/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_0.1.1_bd95746d/3cf1f8e431e0343b4154ab650e51121b9e3441939b55a10702aab1165f04bd0a/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_6f91b1af/ce5a6cb5c23b9204ed30aafa3511ec1573b30b3a1b47dd8721b7721c266f17ae/flyology_allocators/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/hmac_ada_0.2.0_6cab7904/76e9122652dc905df27753c9448614fa19e645efd9d11ce9ee33520edd1b8616/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/system_random_1.0.0_3db7f76e/8e772b64f4c98910d054fb00f95b9ff4d4ec2bc960e27711b878528e74ef5617/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v15/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v16/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v17/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/v18/lib/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/lib/oracle/
   --   -L/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/backends/lib/
   --   -L/Users/yrashk/.local/share/alire/builds/flyology_0.1.1_bd95746d/3cf1f8e431e0343b4154ab650e51121b9e3441939b55a10702aab1165f04bd0a/build/alire-rts/adalib/
   --   -shared
   --   -lgnat-16
--  END Object file/option list   

end ada_main;
