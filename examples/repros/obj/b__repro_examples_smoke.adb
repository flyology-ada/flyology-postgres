pragma Warnings (Off);
pragma Ada_95;
pragma Source_File_Name (ada_main, Spec_File_Name => "b__repro_examples_smoke.ads");
pragma Source_File_Name (ada_main, Body_File_Name => "b__repro_examples_smoke.adb");
pragma Suppress (Overflow_Check);
with Ada.Exceptions;

package body ada_main is

   E005 : Short_Integer; pragma Import (Ada, E005, "ada__exceptions_E");
   E011 : Short_Integer; pragma Import (Ada, E011, "system__soft_links_E");
   E022 : Short_Integer; pragma Import (Ada, E022, "system__exception_table_E");
   E023 : Short_Integer; pragma Import (Ada, E023, "system__exceptions_E");
   E018 : Short_Integer; pragma Import (Ada, E018, "system__soft_links__initialize_E");
   E276 : Short_Integer; pragma Import (Ada, E276, "ada__assertions_E");
   E128 : Short_Integer; pragma Import (Ada, E128, "ada__containers_E");
   E081 : Short_Integer; pragma Import (Ada, E081, "ada__io_exceptions_E");
   E052 : Short_Integer; pragma Import (Ada, E052, "ada__strings_E");
   E054 : Short_Integer; pragma Import (Ada, E054, "ada__strings__utf_encoding_E");
   E101 : Short_Integer; pragma Import (Ada, E101, "interfaces__c_E");
   E104 : Short_Integer; pragma Import (Ada, E104, "system__os_lib_E");
   E062 : Short_Integer; pragma Import (Ada, E062, "ada__tags_E");
   E051 : Short_Integer; pragma Import (Ada, E051, "ada__strings__text_buffers_E");
   E080 : Short_Integer; pragma Import (Ada, E080, "ada__streams_E");
   E112 : Short_Integer; pragma Import (Ada, E112, "system__file_control_block_E");
   E094 : Short_Integer; pragma Import (Ada, E094, "system__finalization_root_E");
   E092 : Short_Integer; pragma Import (Ada, E092, "ada__finalization_E");
   E091 : Short_Integer; pragma Import (Ada, E091, "system__file_io_E");
   E168 : Short_Integer; pragma Import (Ada, E168, "system__storage_pools_E");
   E170 : Short_Integer; pragma Import (Ada, E170, "system__storage_pools__subpools_E");
   E078 : Short_Integer; pragma Import (Ada, E078, "ada__text_io_E");
   E124 : Short_Integer; pragma Import (Ada, E124, "ada__strings__maps_E");
   E127 : Short_Integer; pragma Import (Ada, E127, "ada__strings__maps__constants_E");
   E134 : Short_Integer; pragma Import (Ada, E134, "ada__strings__unbounded_E");
   E164 : Short_Integer; pragma Import (Ada, E164, "system__pool_global_E");
   E074 : Short_Integer; pragma Import (Ada, E074, "example_repro_support_E");
   E150 : Short_Integer; pragma Import (Ada, E150, "flyology__postgres__sql_E");
   E152 : Short_Integer; pragma Import (Ada, E152, "flyology__postgres__sql_backends_E");
   E198 : Short_Integer; pragma Import (Ada, E198, "flyology__postgres__sql__arena_storage_E");
   E189 : Short_Integer; pragma Import (Ada, E189, "flyology__postgres__sql__internals_E");
   E200 : Short_Integer; pragma Import (Ada, E200, "flyology__postgres__sql__native__builders_E");
   E196 : Short_Integer; pragma Import (Ada, E196, "flyology__postgres__sql__native__converters_E");
   E194 : Short_Integer; pragma Import (Ada, E194, "flyology__postgres__sql__native__backend_E");
   E202 : Short_Integer; pragma Import (Ada, E202, "flyology__postgres__sql__native__schema_v18_E");
   E212 : Short_Integer; pragma Import (Ada, E212, "flyology__postgres__sql__native__semantics_E");
   E208 : Short_Integer; pragma Import (Ada, E208, "flyology__postgres__sql__native__action_catalog_E");
   E210 : Short_Integer; pragma Import (Ada, E210, "flyology__postgres__sql__native__action_catalog_chunk_01_E");
   E215 : Short_Integer; pragma Import (Ada, E215, "flyology__postgres__sql__native__action_catalog_chunk_02_E");
   E217 : Short_Integer; pragma Import (Ada, E217, "flyology__postgres__sql__native__action_catalog_chunk_03_E");
   E219 : Short_Integer; pragma Import (Ada, E219, "flyology__postgres__sql__native__action_catalog_chunk_04_E");
   E221 : Short_Integer; pragma Import (Ada, E221, "flyology__postgres__sql__native__action_catalog_chunk_05_E");
   E223 : Short_Integer; pragma Import (Ada, E223, "flyology__postgres__sql__native__action_catalog_chunk_06_E");
   E225 : Short_Integer; pragma Import (Ada, E225, "flyology__postgres__sql__native__action_catalog_chunk_07_E");
   E227 : Short_Integer; pragma Import (Ada, E227, "flyology__postgres__sql__native__action_catalog_chunk_08_E");
   E229 : Short_Integer; pragma Import (Ada, E229, "flyology__postgres__sql__native__action_catalog_chunk_09_E");
   E231 : Short_Integer; pragma Import (Ada, E231, "flyology__postgres__sql__native__action_catalog_chunk_10_E");
   E233 : Short_Integer; pragma Import (Ada, E233, "flyology__postgres__sql__native__action_catalog_chunk_11_E");
   E235 : Short_Integer; pragma Import (Ada, E235, "flyology__postgres__sql__native__action_catalog_chunk_12_E");
   E237 : Short_Integer; pragma Import (Ada, E237, "flyology__postgres__sql__native__action_catalog_chunk_13_E");
   E239 : Short_Integer; pragma Import (Ada, E239, "flyology__postgres__sql__native__action_catalog_chunk_14_E");
   E243 : Short_Integer; pragma Import (Ada, E243, "flyology__postgres__sql__native__action_helper_catalog_E");
   E245 : Short_Integer; pragma Import (Ada, E245, "flyology__postgres__sql__native__action_helper_catalog_chunk_01_E");
   E247 : Short_Integer; pragma Import (Ada, E247, "flyology__postgres__sql__native__action_helper_catalog_chunk_02_E");
   E249 : Short_Integer; pragma Import (Ada, E249, "flyology__postgres__sql__native__action_helper_catalog_chunk_03_E");
   E241 : Short_Integer; pragma Import (Ada, E241, "flyology__postgres__sql__native__actions_v18_support_E");
   E206 : Short_Integer; pragma Import (Ada, E206, "flyology__postgres__sql__native__actions_v18_E");
   E251 : Short_Integer; pragma Import (Ada, E251, "flyology__postgres__sql__native__dfa_E");
   E256 : Short_Integer; pragma Import (Ada, E256, "flyology__postgres__sql__native__lalr_E");
   E258 : Short_Integer; pragma Import (Ada, E258, "flyology__postgres__sql__native__scanner_E");
   E254 : Short_Integer; pragma Import (Ada, E254, "flyology__postgres__sql__native__engine_E");
   E204 : Short_Integer; pragma Import (Ada, E204, "flyology__postgres__sql__native__version_v18_E");
   E192 : Short_Integer; pragma Import (Ada, E192, "flyology__postgres__sql__native__backend_v18_E");
   E185 : Short_Integer; pragma Import (Ada, E185, "flyology__postgres__sql__views_E");
   E187 : Short_Integer; pragma Import (Ada, E187, "flyology__postgres__sql__views__v18_E");
   E179 : Short_Integer; pragma Import (Ada, E179, "flyology__postgres__sql__ast__v18_E");
   E181 : Short_Integer; pragma Import (Ada, E181, "flyology__postgres__sql__ast_materialization_v18_E");
   E183 : Short_Integer; pragma Import (Ada, E183, "flyology__postgres__sql__ast_ownership_v18_E");
   E261 : Short_Integer; pragma Import (Ada, E261, "flyology__postgres__sql__ast_parser_v18_E");
   E263 : Short_Integer; pragma Import (Ada, E263, "flyology__postgres__sql__ast__v18__visitors_E");
   E118 : Short_Integer; pragma Import (Ada, E118, "pgish_sql_E");
   E268 : Short_Integer; pragma Import (Ada, E268, "psqlish__display_E");

   Sec_Default_Sized_Stacks : array (1 .. 1) of aliased System.Secondary_Stack.SS_Stack (System.Parameters.Runtime_Default_Sec_Stack_Size);

   Local_Priority_Specific_Dispatching : constant String := "";
   Local_Interrupt_States : constant String := "";

   Is_Elaborated : Boolean := False;

   procedure finalize_library is
   begin
      E268 := E268 - 1;
      declare
         procedure F1;
         pragma Import (Ada, F1, "psqlish__display__finalize_spec");
      begin
         F1;
      end;
      E179 := E179 - 1;
      declare
         procedure F2;
         pragma Import (Ada, F2, "flyology__postgres__sql__ast__v18__finalize_spec");
      begin
         F2;
      end;
      declare
         procedure F3;
         pragma Import (Ada, F3, "flyology__postgres__sql__native__version_v18__finalize_body");
      begin
         E204 := E204 - 1;
         F3;
      end;
      E200 := E200 - 1;
      declare
         procedure F4;
         pragma Import (Ada, F4, "flyology__postgres__sql__native__builders__finalize_spec");
      begin
         F4;
      end;
      E150 := E150 - 1;
      declare
         procedure F5;
         pragma Import (Ada, F5, "flyology__postgres__sql__finalize_spec");
      begin
         F5;
      end;
      E164 := E164 - 1;
      declare
         procedure F6;
         pragma Import (Ada, F6, "system__pool_global__finalize_spec");
      begin
         F6;
      end;
      E134 := E134 - 1;
      declare
         procedure F7;
         pragma Import (Ada, F7, "ada__strings__unbounded__finalize_spec");
      begin
         F7;
      end;
      E078 := E078 - 1;
      declare
         procedure F8;
         pragma Import (Ada, F8, "ada__text_io__finalize_spec");
      begin
         F8;
      end;
      E170 := E170 - 1;
      declare
         procedure F9;
         pragma Import (Ada, F9, "system__storage_pools__subpools__finalize_spec");
      begin
         F9;
      end;
      declare
         procedure F10;
         pragma Import (Ada, F10, "system__file_io__finalize_body");
      begin
         E091 := E091 - 1;
         F10;
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
      Ada.Assertions'Elab_Spec;
      E276 := E276 + 1;
      Ada.Containers'Elab_Spec;
      E128 := E128 + 1;
      Ada.Io_Exceptions'Elab_Spec;
      E081 := E081 + 1;
      Ada.Strings'Elab_Spec;
      E052 := E052 + 1;
      Ada.Strings.Utf_Encoding'Elab_Spec;
      E054 := E054 + 1;
      Interfaces.C'Elab_Spec;
      E101 := E101 + 1;
      System.Os_Lib'Elab_Body;
      E104 := E104 + 1;
      Ada.Tags'Elab_Spec;
      Ada.Tags'Elab_Body;
      E062 := E062 + 1;
      Ada.Strings.Text_Buffers'Elab_Spec;
      E051 := E051 + 1;
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
      E168 := E168 + 1;
      System.Storage_Pools.Subpools'Elab_Spec;
      E170 := E170 + 1;
      Ada.Text_Io'Elab_Spec;
      Ada.Text_Io'Elab_Body;
      E078 := E078 + 1;
      Ada.Strings.Maps'Elab_Spec;
      E124 := E124 + 1;
      Ada.Strings.Maps.Constants'Elab_Spec;
      E127 := E127 + 1;
      Ada.Strings.Unbounded'Elab_Spec;
      E134 := E134 + 1;
      System.Pool_Global'Elab_Spec;
      E164 := E164 + 1;
      E074 := E074 + 1;
      Flyology.Postgres.Sql'Elab_Spec;
      E152 := E152 + 1;
      Flyology.Postgres.Sql'Elab_Body;
      E150 := E150 + 1;
      E198 := E198 + 1;
      E189 := E189 + 1;
      Flyology.Postgres.Sql.Native.Builders'Elab_Spec;
      Flyology.Postgres.Sql.Native.Builders'Elab_Body;
      E200 := E200 + 1;
      Flyology.Postgres.Sql.Native.Converters'Elab_Spec;
      E196 := E196 + 1;
      E194 := E194 + 1;
      Flyology.Postgres.Sql.Native.Schema_V18'Elab_Spec;
      E202 := E202 + 1;
      Flyology.Postgres.Sql.Native.Semantics'Elab_Spec;
      E212 := E212 + 1;
      E210 := E210 + 1;
      E215 := E215 + 1;
      E217 := E217 + 1;
      E219 := E219 + 1;
      E221 := E221 + 1;
      E223 := E223 + 1;
      E225 := E225 + 1;
      E227 := E227 + 1;
      E229 := E229 + 1;
      E231 := E231 + 1;
      E233 := E233 + 1;
      E235 := E235 + 1;
      E237 := E237 + 1;
      E239 := E239 + 1;
      E208 := E208 + 1;
      E245 := E245 + 1;
      E247 := E247 + 1;
      E249 := E249 + 1;
      E243 := E243 + 1;
      E241 := E241 + 1;
      E206 := E206 + 1;
      E251 := E251 + 1;
      E256 := E256 + 1;
      E258 := E258 + 1;
      E254 := E254 + 1;
      Flyology.Postgres.Sql.Native.Version_V18'Elab_Body;
      E204 := E204 + 1;
      Flyology.Postgres.Sql.Native.Backend_V18'Elab_Body;
      E192 := E192 + 1;
      E185 := E185 + 1;
      E187 := E187 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Spec;
      E183 := E183 + 1;
      E181 := E181 + 1;
      E261 := E261 + 1;
      Flyology.Postgres.Sql.Ast.V18'Elab_Body;
      E179 := E179 + 1;
      Flyology.Postgres.Sql.Ast.V18.Visitors'Elab_Spec;
      E263 := E263 + 1;
      Pgish_Sql'Elab_Spec;
      E118 := E118 + 1;
      Psqlish.Display'Elab_Spec;
      Psqlish.Display'Elab_Body;
      E268 := E268 + 1;
   end adainit;

   procedure Ada_Main_Program;
   pragma Import (Ada, Ada_Main_Program, "_ada_repro_examples_smoke");

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
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/psqlish.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/psqlish-display.o
   --   /Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd/examples/repros/obj/repro_examples_smoke.o
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
   --   -lgnat
--  END Object file/option list   

end ada_main;
