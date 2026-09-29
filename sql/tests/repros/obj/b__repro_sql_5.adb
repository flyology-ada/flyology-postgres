pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__repro_sql_5.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__repro_sql_5.adb");
pragma Suppress (Overflow_Check);
with Ada.Exceptions;

package body ada_main is

   E016 : Short_Integer; pragma Import (Ada, E016, "ada__exceptions_E");
   E012 : Short_Integer; pragma Import (Ada, E012, "system__soft_links_E");
   E010 : Short_Integer; pragma Import (Ada, E010, "system__exception_table_E");
   E019 : Short_Integer; pragma Import (Ada, E019, "system__exceptions_E");
   E050 : Short_Integer; pragma Import (Ada, E050, "system__soft_links__initialize_E");
   E122 : Short_Integer; pragma Import (Ada, E122, "ada__containers_E");
   E081 : Short_Integer; pragma Import (Ada, E081, "ada__io_exceptions_E");
   E007 : Short_Integer; pragma Import (Ada, E007, "ada__strings_E");
   E054 : Short_Integer; pragma Import (Ada, E054, "ada__strings__utf_encoding_E");
   E101 : Short_Integer; pragma Import (Ada, E101, "interfaces__c_E");
   E290 : Short_Integer; pragma Import (Ada, E290, "interfaces__c__strings_E");
   E104 : Short_Integer; pragma Import (Ada, E104, "system__os_lib_E");
   E062 : Short_Integer; pragma Import (Ada, E062, "ada__tags_E");
   E005 : Short_Integer; pragma Import (Ada, E005, "ada__strings__text_buffers_E");
   E080 : Short_Integer; pragma Import (Ada, E080, "ada__streams_E");
   E112 : Short_Integer; pragma Import (Ada, E112, "system__file_control_block_E");
   E094 : Short_Integer; pragma Import (Ada, E094, "system__finalization_root_E");
   E092 : Short_Integer; pragma Import (Ada, E092, "ada__finalization_E");
   E091 : Short_Integer; pragma Import (Ada, E091, "system__file_io_E");
   E157 : Short_Integer; pragma Import (Ada, E157, "system__storage_pools_E");
   E159 : Short_Integer; pragma Import (Ada, E159, "system__storage_pools__subpools_E");
   E078 : Short_Integer; pragma Import (Ada, E078, "ada__text_io_E");
   E130 : Short_Integer; pragma Import (Ada, E130, "ada__strings__maps_E");
   E187 : Short_Integer; pragma Import (Ada, E187, "ada__strings__maps__constants_E");
   E128 : Short_Integer; pragma Import (Ada, E128, "ada__strings__unbounded_E");
   E153 : Short_Integer; pragma Import (Ada, E153, "system__pool_global_E");
   E118 : Short_Integer; pragma Import (Ada, E118, "flyology__postgres__sql_E");
   E120 : Short_Integer; pragma Import (Ada, E120, "flyology__postgres__sql_backends_E");
   E178 : Short_Integer; pragma Import (Ada, E178, "flyology__postgres__sql__arena_storage_E");
   E288 : Short_Integer; pragma Import (Ada, E288, "flyology__postgres__sql__backends_E");
   E294 : Short_Integer; pragma Import (Ada, E294, "flyology__postgres__sql__decoders_E");
   E292 : Short_Integer; pragma Import (Ada, E292, "flyology__postgres__sql__decoder_v14_E");
   E296 : Short_Integer; pragma Import (Ada, E296, "flyology__postgres__sql__decoder_v15_E");
   E298 : Short_Integer; pragma Import (Ada, E298, "flyology__postgres__sql__decoder_v16_E");
   E300 : Short_Integer; pragma Import (Ada, E300, "flyology__postgres__sql__decoder_v17_E");
   E302 : Short_Integer; pragma Import (Ada, E302, "flyology__postgres__sql__decoder_v18_E");
   E286 : Short_Integer; pragma Import (Ada, E286, "flyology__postgres__sql__c_oracle_E");
   E304 : Short_Integer; pragma Import (Ada, E304, "flyology__postgres__sql__internals_E");
   E180 : Short_Integer; pragma Import (Ada, E180, "flyology__postgres__sql__native__builders_E");
   E176 : Short_Integer; pragma Import (Ada, E176, "flyology__postgres__sql__native__converters_E");
   E174 : Short_Integer; pragma Import (Ada, E174, "flyology__postgres__sql__native__backend_E");
   E182 : Short_Integer; pragma Import (Ada, E182, "flyology__postgres__sql__native__schema_v14_E");
   E247 : Short_Integer; pragma Import (Ada, E247, "flyology__postgres__sql__native__schema_v15_E");
   E257 : Short_Integer; pragma Import (Ada, E257, "flyology__postgres__sql__native__schema_v16_E");
   E267 : Short_Integer; pragma Import (Ada, E267, "flyology__postgres__sql__native__schema_v17_E");
   E277 : Short_Integer; pragma Import (Ada, E277, "flyology__postgres__sql__native__schema_v18_E");
   E197 : Short_Integer; pragma Import (Ada, E197, "flyology__postgres__sql__native__semantics_E");
   E193 : Short_Integer; pragma Import (Ada, E193, "flyology__postgres__sql__native__action_catalog_E");
   E195 : Short_Integer; pragma Import (Ada, E195, "flyology__postgres__sql__native__action_catalog_chunk_01_E");
   E200 : Short_Integer; pragma Import (Ada, E200, "flyology__postgres__sql__native__action_catalog_chunk_02_E");
   E202 : Short_Integer; pragma Import (Ada, E202, "flyology__postgres__sql__native__action_catalog_chunk_03_E");
   E204 : Short_Integer; pragma Import (Ada, E204, "flyology__postgres__sql__native__action_catalog_chunk_04_E");
   E206 : Short_Integer; pragma Import (Ada, E206, "flyology__postgres__sql__native__action_catalog_chunk_05_E");
   E208 : Short_Integer; pragma Import (Ada, E208, "flyology__postgres__sql__native__action_catalog_chunk_06_E");
   E210 : Short_Integer; pragma Import (Ada, E210, "flyology__postgres__sql__native__action_catalog_chunk_07_E");
   E212 : Short_Integer; pragma Import (Ada, E212, "flyology__postgres__sql__native__action_catalog_chunk_08_E");
   E214 : Short_Integer; pragma Import (Ada, E214, "flyology__postgres__sql__native__action_catalog_chunk_09_E");
   E216 : Short_Integer; pragma Import (Ada, E216, "flyology__postgres__sql__native__action_catalog_chunk_10_E");
   E218 : Short_Integer; pragma Import (Ada, E218, "flyology__postgres__sql__native__action_catalog_chunk_11_E");
   E220 : Short_Integer; pragma Import (Ada, E220, "flyology__postgres__sql__native__action_catalog_chunk_12_E");
   E222 : Short_Integer; pragma Import (Ada, E222, "flyology__postgres__sql__native__action_catalog_chunk_13_E");
   E224 : Short_Integer; pragma Import (Ada, E224, "flyology__postgres__sql__native__action_catalog_chunk_14_E");
   E228 : Short_Integer; pragma Import (Ada, E228, "flyology__postgres__sql__native__action_helper_catalog_E");
   E230 : Short_Integer; pragma Import (Ada, E230, "flyology__postgres__sql__native__action_helper_catalog_chunk_01_E");
   E232 : Short_Integer; pragma Import (Ada, E232, "flyology__postgres__sql__native__action_helper_catalog_chunk_02_E");
   E234 : Short_Integer; pragma Import (Ada, E234, "flyology__postgres__sql__native__action_helper_catalog_chunk_03_E");
   E226 : Short_Integer; pragma Import (Ada, E226, "flyology__postgres__sql__native__actions_v14_support_E");
   E191 : Short_Integer; pragma Import (Ada, E191, "flyology__postgres__sql__native__actions_v14_E");
   E253 : Short_Integer; pragma Import (Ada, E253, "flyology__postgres__sql__native__actions_v15_support_E");
   E251 : Short_Integer; pragma Import (Ada, E251, "flyology__postgres__sql__native__actions_v15_E");
   E263 : Short_Integer; pragma Import (Ada, E263, "flyology__postgres__sql__native__actions_v16_support_E");
   E261 : Short_Integer; pragma Import (Ada, E261, "flyology__postgres__sql__native__actions_v16_E");
   E273 : Short_Integer; pragma Import (Ada, E273, "flyology__postgres__sql__native__actions_v17_support_E");
   E271 : Short_Integer; pragma Import (Ada, E271, "flyology__postgres__sql__native__actions_v17_E");
   E283 : Short_Integer; pragma Import (Ada, E283, "flyology__postgres__sql__native__actions_v18_support_E");
   E281 : Short_Integer; pragma Import (Ada, E281, "flyology__postgres__sql__native__actions_v18_E");
   E236 : Short_Integer; pragma Import (Ada, E236, "flyology__postgres__sql__native__dfa_E");
   E241 : Short_Integer; pragma Import (Ada, E241, "flyology__postgres__sql__native__lalr_E");
   E243 : Short_Integer; pragma Import (Ada, E243, "flyology__postgres__sql__native__scanner_E");
   E239 : Short_Integer; pragma Import (Ada, E239, "flyology__postgres__sql__native__engine_E");
   E184 : Short_Integer; pragma Import (Ada, E184, "flyology__postgres__sql__native__version_v14_E");
   E172 : Short_Integer; pragma Import (Ada, E172, "flyology__postgres__sql__native__backend_v14_E");
   E249 : Short_Integer; pragma Import (Ada, E249, "flyology__postgres__sql__native__version_v15_E");
   E246 : Short_Integer; pragma Import (Ada, E246, "flyology__postgres__sql__native__backend_v15_E");
   E259 : Short_Integer; pragma Import (Ada, E259, "flyology__postgres__sql__native__version_v16_E");
   E256 : Short_Integer; pragma Import (Ada, E256, "flyology__postgres__sql__native__backend_v16_E");
   E269 : Short_Integer; pragma Import (Ada, E269, "flyology__postgres__sql__native__version_v17_E");
   E266 : Short_Integer; pragma Import (Ada, E266, "flyology__postgres__sql__native__backend_v17_E");
   E279 : Short_Integer; pragma Import (Ada, E279, "flyology__postgres__sql__native__version_v18_E");
   E276 : Short_Integer; pragma Import (Ada, E276, "flyology__postgres__sql__native__backend_v18_E");
   E167 : Short_Integer; pragma Import (Ada, E167, "flyology__postgres__sql__repro_oracle_E");
   E074 : Short_Integer; pragma Import (Ada, E074, "sql_repro_support_E");

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
         E279 := E279 - 1;
         F1;
      end;
      declare
         procedure F2;
         pragma Import (Ada, F2, "flyology__postgres__sql__native__version_v17__finalize_body");
      begin
         E269 := E269 - 1;
         F2;
      end;
      declare
         procedure F3;
         pragma Import (Ada, F3, "flyology__postgres__sql__native__version_v16__finalize_body");
      begin
         E259 := E259 - 1;
         F3;
      end;
      declare
         procedure F4;
         pragma Import (Ada, F4, "flyology__postgres__sql__native__version_v15__finalize_body");
      begin
         E249 := E249 - 1;
         F4;
      end;
      declare
         procedure F5;
         pragma Import (Ada, F5, "flyology__postgres__sql__native__version_v14__finalize_body");
      begin
         E184 := E184 - 1;
         F5;
      end;
      E180 := E180 - 1;
      declare
         procedure F6;
         pragma Import (Ada, F6, "flyology__postgres__sql__native__builders__finalize_spec");
      begin
         F6;
      end;
      E118 := E118 - 1;
      declare
         procedure F7;
         pragma Import (Ada, F7, "flyology__postgres__sql__finalize_spec");
      begin
         F7;
      end;
      E153 := E153 - 1;
      declare
         procedure F8;
         pragma Import (Ada, F8, "system__pool_global__finalize_spec");
      begin
         F8;
      end;
      E128 := E128 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "ada__strings__unbounded__finalize_spec");
      begin
         F9;
      end;
      E078 := E078 - 1;
      declare
         procedure F10;
         pragma Import (Ada, F10, "ada__text_io__finalize_spec");
      begin
         F10;
      end;
      E159 := E159 - 1;
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
         E091 := E091 - 1;
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
      E010 := E010 + 1;
      System.Exceptions'Elab_Spec;
      E019 := E019 + 1;
      System.Soft_Links.Initialize'Elab_Body;
      E050 := E050 + 1;
      E012 := E012 + 1;
      E016 := E016 + 1;
      Ada.Containers'Elab_Spec;
      E122 := E122 + 1;
      Ada.Io_Exceptions'Elab_Spec;
      E081 := E081 + 1;
      Ada.Strings'Elab_Spec;
      E007 := E007 + 1;
      Ada.Strings.Utf_Encoding'Elab_Spec;
      E054 := E054 + 1;
      Interfaces.C'Elab_Spec;
      E101 := E101 + 1;
      Interfaces.C.Strings'Elab_Spec;
      E290 := E290 + 1;
      System.Os_Lib'Elab_Body;
      E104 := E104 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E062 := E062 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E005 := E005 + 1;
      Ada.Streams'Elab_Spec;
      E080 := E080 + 1;
      System.File_Control_Block'Elab_Spec;
      E112 := E112 + 1;
      System.Finalization_Root'Elab_Spec;
      E094 := E094 + 1;
      Ada.Finalization'Elab_Spec;
      E092 := E092 + 1;
      System.File_Io'Elab_Body;
      E091 := E091 + 1;
      System.Storage_Pools'Elab_Spec;
      E157 := E157 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E159 := E159 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E078 := E078 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E130 := E130 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E187 := E187 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E128 := E128 + 1;
      System.Pool_Global'Elab_Spec;
      E153 := E153 + 1;
      Flyology.Postgres.Sql'Elab_Spec;
      E120 := E120 + 1;
      Flyology.Postgres.Sql'Elab_Body;
      E118 := E118 + 1;
      E178 := E178 + 1;
      E288 := E288 + 1;
      Flyology.Postgres.Sql.Decoders'Elab_Spec;
      E294 := E294 + 1;
      E292 := E292 + 1;
      E296 := E296 + 1;
      E298 := E298 + 1;
      E300 := E300 + 1;
      E302 := E302 + 1;
      E286 := E286 + 1;
      E304 := E304 + 1;
      Flyology.Postgres.Sql.Native.Builders'Elab_Spec;
      Flyology.Postgres.Sql.Native.Builders'Elab_Body;
      E180 := E180 + 1;
      Flyology.Postgres.Sql.Native.Converters'Elab_Spec;
      E176 := E176 + 1;
      E174 := E174 + 1;
      Flyology.Postgres.Sql.Native.Schema_V14'Elab_Spec;
      E182 := E182 + 1;
      Flyology.Postgres.Sql.Native.Schema_V15'Elab_Spec;
      E247 := E247 + 1;
      Flyology.Postgres.Sql.Native.Schema_V16'Elab_Spec;
      E257 := E257 + 1;
      Flyology.Postgres.Sql.Native.Schema_V17'Elab_Spec;
      E267 := E267 + 1;
      Flyology.Postgres.Sql.Native.Schema_V18'Elab_Spec;
      E277 := E277 + 1;
      Flyology.Postgres.Sql.Native.Semantics'Elab_Spec;
      E197 := E197 + 1;
      E195 := E195 + 1;
      E200 := E200 + 1;
      E202 := E202 + 1;
      E204 := E204 + 1;
      E206 := E206 + 1;
      E208 := E208 + 1;
      E210 := E210 + 1;
      E212 := E212 + 1;
      E214 := E214 + 1;
      E216 := E216 + 1;
      E218 := E218 + 1;
      E220 := E220 + 1;
      E222 := E222 + 1;
      E224 := E224 + 1;
      E193 := E193 + 1;
      E230 := E230 + 1;
      E232 := E232 + 1;
      E234 := E234 + 1;
      E228 := E228 + 1;
      E226 := E226 + 1;
      E191 := E191 + 1;
      E253 := E253 + 1;
      E251 := E251 + 1;
      E263 := E263 + 1;
      E261 := E261 + 1;
      E273 := E273 + 1;
      E271 := E271 + 1;
      E283 := E283 + 1;
      E281 := E281 + 1;
      E236 := E236 + 1;
      E241 := E241 + 1;
      E243 := E243 + 1;
      E239 := E239 + 1;
      Flyology.Postgres.Sql.Native.Version_V14'Elab_Body;
      E184 := E184 + 1;
      Flyology.Postgres.Sql.Native.Backend_V14'Elab_Body;
      E172 := E172 + 1;
      Flyology.Postgres.Sql.Native.Version_V15'Elab_Body;
      E249 := E249 + 1;
      Flyology.Postgres.Sql.Native.Backend_V15'Elab_Body;
      E246 := E246 + 1;
      Flyology.Postgres.Sql.Native.Version_V16'Elab_Body;
      E259 := E259 + 1;
      Flyology.Postgres.Sql.Native.Backend_V16'Elab_Body;
      E256 := E256 + 1;
      Flyology.Postgres.Sql.Native.Version_V17'Elab_Body;
      E269 := E269 + 1;
      Flyology.Postgres.Sql.Native.Backend_V17'Elab_Body;
      E266 := E266 + 1;
      Flyology.Postgres.Sql.Native.Version_V18'Elab_Body;
      E279 := E279 + 1;
      Flyology.Postgres.Sql.Native.Backend_V18'Elab_Body;
      E276 := E276 + 1;
      E167 := E167 + 1;
      E074 := E074 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_repro_sql_5");

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
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/repro_sql_5.o
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
