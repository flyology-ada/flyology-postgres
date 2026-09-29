pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__repro_sql_smoke.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__repro_sql_smoke.adb");
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
   E305 : Short_Integer; pragma Import (Ada, E305, "interfaces__c__strings_E");
   E251 : Short_Integer; pragma Import (Ada, E251, "system__os_lib_E");
   E062 : Short_Integer; pragma Import (Ada, E062, "ada__tags_E");
   E051 : Short_Integer; pragma Import (Ada, E051, "ada__strings__text_buffers_E");
   E093 : Short_Integer; pragma Import (Ada, E093, "ada__streams_E");
   E255 : Short_Integer; pragma Import (Ada, E255, "system__file_control_block_E");
   E100 : Short_Integer; pragma Import (Ada, E100, "system__finalization_root_E");
   E091 : Short_Integer; pragma Import (Ada, E091, "ada__finalization_E");
   E247 : Short_Integer; pragma Import (Ada, E247, "system__file_io_E");
   E137 : Short_Integer; pragma Import (Ada, E137, "system__storage_pools_E");
   E139 : Short_Integer; pragma Import (Ada, E139, "system__storage_pools__subpools_E");
   E243 : Short_Integer; pragma Import (Ada, E243, "ada__text_io_E");
   E108 : Short_Integer; pragma Import (Ada, E108, "ada__strings__maps_E");
   E178 : Short_Integer; pragma Import (Ada, E178, "ada__strings__maps__constants_E");
   E106 : Short_Integer; pragma Import (Ada, E106, "ada__strings__unbounded_E");
   E131 : Short_Integer; pragma Import (Ada, E131, "system__pool_global_E");
   E078 : Short_Integer; pragma Import (Ada, E078, "flyology__postgres__sql_E");
   E080 : Short_Integer; pragma Import (Ada, E080, "flyology__postgres__sql_backends_E");
   E169 : Short_Integer; pragma Import (Ada, E169, "flyology__postgres__sql__arena_storage_E");
   E303 : Short_Integer; pragma Import (Ada, E303, "flyology__postgres__sql__backends_E");
   E309 : Short_Integer; pragma Import (Ada, E309, "flyology__postgres__sql__decoders_E");
   E307 : Short_Integer; pragma Import (Ada, E307, "flyology__postgres__sql__decoder_v14_E");
   E311 : Short_Integer; pragma Import (Ada, E311, "flyology__postgres__sql__decoder_v15_E");
   E313 : Short_Integer; pragma Import (Ada, E313, "flyology__postgres__sql__decoder_v16_E");
   E315 : Short_Integer; pragma Import (Ada, E315, "flyology__postgres__sql__decoder_v17_E");
   E317 : Short_Integer; pragma Import (Ada, E317, "flyology__postgres__sql__decoder_v18_E");
   E301 : Short_Integer; pragma Import (Ada, E301, "flyology__postgres__sql__c_oracle_E");
   E160 : Short_Integer; pragma Import (Ada, E160, "flyology__postgres__sql__internals_E");
   E171 : Short_Integer; pragma Import (Ada, E171, "flyology__postgres__sql__native__builders_E");
   E167 : Short_Integer; pragma Import (Ada, E167, "flyology__postgres__sql__native__converters_E");
   E165 : Short_Integer; pragma Import (Ada, E165, "flyology__postgres__sql__native__backend_E");
   E262 : Short_Integer; pragma Import (Ada, E262, "flyology__postgres__sql__native__schema_v14_E");
   E272 : Short_Integer; pragma Import (Ada, E272, "flyology__postgres__sql__native__schema_v15_E");
   E282 : Short_Integer; pragma Import (Ada, E282, "flyology__postgres__sql__native__schema_v16_E");
   E292 : Short_Integer; pragma Import (Ada, E292, "flyology__postgres__sql__native__schema_v17_E");
   E173 : Short_Integer; pragma Import (Ada, E173, "flyology__postgres__sql__native__schema_v18_E");
   E188 : Short_Integer; pragma Import (Ada, E188, "flyology__postgres__sql__native__semantics_E");
   E184 : Short_Integer; pragma Import (Ada, E184, "flyology__postgres__sql__native__action_catalog_E");
   E186 : Short_Integer; pragma Import (Ada, E186, "flyology__postgres__sql__native__action_catalog_chunk_01_E");
   E191 : Short_Integer; pragma Import (Ada, E191, "flyology__postgres__sql__native__action_catalog_chunk_02_E");
   E193 : Short_Integer; pragma Import (Ada, E193, "flyology__postgres__sql__native__action_catalog_chunk_03_E");
   E195 : Short_Integer; pragma Import (Ada, E195, "flyology__postgres__sql__native__action_catalog_chunk_04_E");
   E197 : Short_Integer; pragma Import (Ada, E197, "flyology__postgres__sql__native__action_catalog_chunk_05_E");
   E199 : Short_Integer; pragma Import (Ada, E199, "flyology__postgres__sql__native__action_catalog_chunk_06_E");
   E201 : Short_Integer; pragma Import (Ada, E201, "flyology__postgres__sql__native__action_catalog_chunk_07_E");
   E203 : Short_Integer; pragma Import (Ada, E203, "flyology__postgres__sql__native__action_catalog_chunk_08_E");
   E205 : Short_Integer; pragma Import (Ada, E205, "flyology__postgres__sql__native__action_catalog_chunk_09_E");
   E207 : Short_Integer; pragma Import (Ada, E207, "flyology__postgres__sql__native__action_catalog_chunk_10_E");
   E209 : Short_Integer; pragma Import (Ada, E209, "flyology__postgres__sql__native__action_catalog_chunk_11_E");
   E211 : Short_Integer; pragma Import (Ada, E211, "flyology__postgres__sql__native__action_catalog_chunk_12_E");
   E213 : Short_Integer; pragma Import (Ada, E213, "flyology__postgres__sql__native__action_catalog_chunk_13_E");
   E215 : Short_Integer; pragma Import (Ada, E215, "flyology__postgres__sql__native__action_catalog_chunk_14_E");
   E219 : Short_Integer; pragma Import (Ada, E219, "flyology__postgres__sql__native__action_helper_catalog_E");
   E221 : Short_Integer; pragma Import (Ada, E221, "flyology__postgres__sql__native__action_helper_catalog_chunk_01_E");
   E223 : Short_Integer; pragma Import (Ada, E223, "flyology__postgres__sql__native__action_helper_catalog_chunk_02_E");
   E225 : Short_Integer; pragma Import (Ada, E225, "flyology__postgres__sql__native__action_helper_catalog_chunk_03_E");
   E268 : Short_Integer; pragma Import (Ada, E268, "flyology__postgres__sql__native__actions_v14_support_E");
   E266 : Short_Integer; pragma Import (Ada, E266, "flyology__postgres__sql__native__actions_v14_E");
   E278 : Short_Integer; pragma Import (Ada, E278, "flyology__postgres__sql__native__actions_v15_support_E");
   E276 : Short_Integer; pragma Import (Ada, E276, "flyology__postgres__sql__native__actions_v15_E");
   E288 : Short_Integer; pragma Import (Ada, E288, "flyology__postgres__sql__native__actions_v16_support_E");
   E286 : Short_Integer; pragma Import (Ada, E286, "flyology__postgres__sql__native__actions_v16_E");
   E298 : Short_Integer; pragma Import (Ada, E298, "flyology__postgres__sql__native__actions_v17_support_E");
   E296 : Short_Integer; pragma Import (Ada, E296, "flyology__postgres__sql__native__actions_v17_E");
   E217 : Short_Integer; pragma Import (Ada, E217, "flyology__postgres__sql__native__actions_v18_support_E");
   E182 : Short_Integer; pragma Import (Ada, E182, "flyology__postgres__sql__native__actions_v18_E");
   E227 : Short_Integer; pragma Import (Ada, E227, "flyology__postgres__sql__native__dfa_E");
   E232 : Short_Integer; pragma Import (Ada, E232, "flyology__postgres__sql__native__lalr_E");
   E234 : Short_Integer; pragma Import (Ada, E234, "flyology__postgres__sql__native__scanner_E");
   E230 : Short_Integer; pragma Import (Ada, E230, "flyology__postgres__sql__native__engine_E");
   E264 : Short_Integer; pragma Import (Ada, E264, "flyology__postgres__sql__native__version_v14_E");
   E261 : Short_Integer; pragma Import (Ada, E261, "flyology__postgres__sql__native__backend_v14_E");
   E274 : Short_Integer; pragma Import (Ada, E274, "flyology__postgres__sql__native__version_v15_E");
   E271 : Short_Integer; pragma Import (Ada, E271, "flyology__postgres__sql__native__backend_v15_E");
   E284 : Short_Integer; pragma Import (Ada, E284, "flyology__postgres__sql__native__version_v16_E");
   E281 : Short_Integer; pragma Import (Ada, E281, "flyology__postgres__sql__native__backend_v16_E");
   E294 : Short_Integer; pragma Import (Ada, E294, "flyology__postgres__sql__native__version_v17_E");
   E291 : Short_Integer; pragma Import (Ada, E291, "flyology__postgres__sql__native__backend_v17_E");
   E175 : Short_Integer; pragma Import (Ada, E175, "flyology__postgres__sql__native__version_v18_E");
   E163 : Short_Integer; pragma Import (Ada, E163, "flyology__postgres__sql__native__backend_v18_E");
   E257 : Short_Integer; pragma Import (Ada, E257, "flyology__postgres__sql__repro_oracle_E");
   E156 : Short_Integer; pragma Import (Ada, E156, "flyology__postgres__sql__views_E");
   E158 : Short_Integer; pragma Import (Ada, E158, "flyology__postgres__sql__views__v18_E");
   E150 : Short_Integer; pragma Import (Ada, E150, "flyology__postgres__sql__ast__v18_E");
   E152 : Short_Integer; pragma Import (Ada, E152, "flyology__postgres__sql__ast_materialization_v18_E");
   E154 : Short_Integer; pragma Import (Ada, E154, "flyology__postgres__sql__ast_ownership_v18_E");
   E237 : Short_Integer; pragma Import (Ada, E237, "flyology__postgres__sql__ast_parser_v18_E");
   E239 : Short_Integer; pragma Import (Ada, E239, "sql_repro_support_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      E150 := E150 - 1;
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
         E175 := E175 - 1;
         F2;
      end;
      declare
         procedure F3;
         pragma Import (Ada, F3, "flyology__postgres__sql__native__version_v17__finalize_body");
      begin
         E294 := E294 - 1;
         F3;
      end;
      declare
         procedure F4;
         pragma Import (Ada, F4, "flyology__postgres__sql__native__version_v16__finalize_body");
      begin
         E284 := E284 - 1;
         F4;
      end;
      declare
         procedure F5;
         pragma Import (Ada, F5, "flyology__postgres__sql__native__version_v15__finalize_body");
      begin
         E274 := E274 - 1;
         F5;
      end;
      declare
         procedure F6;
         pragma Import (Ada, F6, "flyology__postgres__sql__native__version_v14__finalize_body");
      begin
         E264 := E264 - 1;
         F6;
      end;
      E171 := E171 - 1;
      declare
         procedure F7;
         pragma Import (Ada, F7, "flyology__postgres__sql__native__builders__finalize_spec");
      begin
         F7;
      end;
      E078 := E078 - 1;
      declare
         procedure F8;
         pragma Import (Ada, F8, "flyology__postgres__sql__finalize_spec");
      begin
         F8;
      end;
      E131 := E131 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "system__pool_global__finalize_spec");
      begin
         F9;
      end;
      E106 := E106 - 1;
      declare
         procedure F10;
         pragma Import (Ada, F10, "ada__strings__unbounded__finalize_spec");
      begin
         F10;
      end;
      E243 := E243 - 1;
      declare
         procedure F11;
         pragma Import (Ada, F11, "ada__text_io__finalize_spec");
      begin
         F11;
      end;
      E139 := E139 - 1;
      declare
         procedure F12;
         pragma Import (Ada, F12, "system__storage_pools__subpools__finalize_spec");
      begin
         F12;
      end;
      declare
         procedure F13;
         pragma Import (Ada, F13, "system__file_io__finalize_body");
      begin
         E247 := E247 - 1;
         F13;
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
      E305 := E305 + 1;
      System.Os_Lib'Elab_Body;
      E251 := E251 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E062 := E062 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E051 := E051 + 1;
      Ada.Streams'Elab_Spec;
      E093 := E093 + 1;
      System.File_Control_Block'Elab_Spec;
      E255 := E255 + 1;
      System.Finalization_Root'Elab_Spec;
      E100 := E100 + 1;
      Ada.Finalization'Elab_Spec;
      E091 := E091 + 1;
      System.File_Io'Elab_Body;
      E247 := E247 + 1;
      System.Storage_Pools'Elab_Spec;
      E137 := E137 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E139 := E139 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E243 := E243 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E108 := E108 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E178 := E178 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E106 := E106 + 1;
      System.Pool_Global'Elab_Spec;
      E131 := E131 + 1;
      Flyology.Postgres.Sql'Elab_Spec;
      E080 := E080 + 1;
      Flyology.Postgres.Sql'Elab_Body;
      E078 := E078 + 1;
      E169 := E169 + 1;
      E303 := E303 + 1;
      Flyology.Postgres.Sql.Decoders'Elab_Spec;
      E309 := E309 + 1;
      E307 := E307 + 1;
      E311 := E311 + 1;
      E313 := E313 + 1;
      E315 := E315 + 1;
      E317 := E317 + 1;
      E301 := E301 + 1;
      E160 := E160 + 1;
      Flyology.Postgres.Sql.Native.Builders'Elab_Spec;
      Flyology.Postgres.Sql.Native.Builders'Elab_Body;
      E171 := E171 + 1;
      Flyology.Postgres.Sql.Native.Converters'Elab_Spec;
      E167 := E167 + 1;
      E165 := E165 + 1;
      Flyology.Postgres.Sql.Native.Schema_V14'Elab_Spec;
      E262 := E262 + 1;
      Flyology.Postgres.Sql.Native.Schema_V15'Elab_Spec;
      E272 := E272 + 1;
      Flyology.Postgres.Sql.Native.Schema_V16'Elab_Spec;
      E282 := E282 + 1;
      Flyology.Postgres.Sql.Native.Schema_V17'Elab_Spec;
      E292 := E292 + 1;
      Flyology.Postgres.Sql.Native.Schema_V18'Elab_Spec;
      E173 := E173 + 1;
      Flyology.Postgres.Sql.Native.Semantics'Elab_Spec;
      E188 := E188 + 1;
      E186 := E186 + 1;
      E191 := E191 + 1;
      E193 := E193 + 1;
      E195 := E195 + 1;
      E197 := E197 + 1;
      E199 := E199 + 1;
      E201 := E201 + 1;
      E203 := E203 + 1;
      E205 := E205 + 1;
      E207 := E207 + 1;
      E209 := E209 + 1;
      E211 := E211 + 1;
      E213 := E213 + 1;
      E215 := E215 + 1;
      E184 := E184 + 1;
      E221 := E221 + 1;
      E223 := E223 + 1;
      E225 := E225 + 1;
      E219 := E219 + 1;
      E268 := E268 + 1;
      E266 := E266 + 1;
      E278 := E278 + 1;
      E276 := E276 + 1;
      E288 := E288 + 1;
      E286 := E286 + 1;
      E298 := E298 + 1;
      E296 := E296 + 1;
      E217 := E217 + 1;
      E182 := E182 + 1;
      E227 := E227 + 1;
      E232 := E232 + 1;
      E234 := E234 + 1;
      E230 := E230 + 1;
      Flyology.Postgres.Sql.Native.Version_V14'Elab_Body;
      E264 := E264 + 1;
      Flyology.Postgres.Sql.Native.Backend_V14'Elab_Body;
      E261 := E261 + 1;
      Flyology.Postgres.Sql.Native.Version_V15'Elab_Body;
      E274 := E274 + 1;
      Flyology.Postgres.Sql.Native.Backend_V15'Elab_Body;
      E271 := E271 + 1;
      Flyology.Postgres.Sql.Native.Version_V16'Elab_Body;
      E284 := E284 + 1;
      Flyology.Postgres.Sql.Native.Backend_V16'Elab_Body;
      E281 := E281 + 1;
      Flyology.Postgres.Sql.Native.Version_V17'Elab_Body;
      E294 := E294 + 1;
      Flyology.Postgres.Sql.Native.Backend_V17'Elab_Body;
      E291 := E291 + 1;
      Flyology.Postgres.Sql.Native.Version_V18'Elab_Body;
      E175 := E175 + 1;
      Flyology.Postgres.Sql.Native.Backend_V18'Elab_Body;
      E163 := E163 + 1;
      E257 := E257 + 1;
      E156 := E156 + 1;
      E158 := E158 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Spec;
      E154 := E154 + 1;
      E152 := E152 + 1;
      E237 := E237 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Body;
      E150 := E150 + 1;
      E239 := E239 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_repro_sql_smoke");

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
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/sql/tests/repros/obj/repro_sql_smoke.o
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
