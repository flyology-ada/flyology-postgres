pragma Warnings (Off);
pragma Ada_95;
with System;
with System.Parameters;
with System.Secondary_Stack;
package ada_main is

   gnat_argc : Integer;
   gnat_argv : System.Address;
   gnat_envp : System.Address;

   pragma Import (C, gnat_argc);
   pragma Import (C, gnat_argv);
   pragma Import (C, gnat_envp);

   gnat_exit_status : Integer;
   pragma Import (C, gnat_exit_status);

   GNAT_Version : constant String :=
                    "GNAT Version: 16.1.0" & ASCII.NUL;
   pragma Export (C, GNAT_Version, "__gnat_version");

   GNAT_Version_Address : constant System.Address := GNAT_Version'Address;
   pragma Export (C, GNAT_Version_Address, "__gnat_version_address");

   Ada_Main_Program_Name : constant String := "_ada_repro_examples_10" & ASCII.NUL;
   pragma Export (C, Ada_Main_Program_Name, "__gnat_ada_main_program_name");

   procedure adainit;
   pragma Export (C, adainit, "adainit");

   procedure adafinal;
   pragma Export (C, adafinal, "adafinal");

   function main
     (argc : Integer;
      argv : System.Address;
      envp : System.Address)
      return Integer;
   pragma Export (C, main, "main");

   type Version_32 is mod 2 ** 32;
   u00001 : constant Version_32 := 16#ecb79e3a#;
   pragma Export (C, u00001, "repro_examples_10B");
   u00002 : constant Version_32 := 16#b2cfab41#;
   pragma Export (C, u00002, "system__standard_libraryB");
   u00003 : constant Version_32 := 16#986fbd5a#;
   pragma Export (C, u00003, "system__standard_libraryS");
   u00004 : constant Version_32 := 16#76789da1#;
   pragma Export (C, u00004, "adaS");
   u00005 : constant Version_32 := 16#6ce3be0f#;
   pragma Export (C, u00005, "ada__exceptionsB");
   u00006 : constant Version_32 := 16#0fa7c4bb#;
   pragma Export (C, u00006, "ada__exceptionsS");
   u00007 : constant Version_32 := 16#85bf25f7#;
   pragma Export (C, u00007, "ada__exceptions__last_chance_handlerB");
   u00008 : constant Version_32 := 16#c1262c0b#;
   pragma Export (C, u00008, "ada__exceptions__last_chance_handlerS");
   u00009 : constant Version_32 := 16#8a611ac3#;
   pragma Export (C, u00009, "systemS");
   u00010 : constant Version_32 := 16#7fa0a598#;
   pragma Export (C, u00010, "system__soft_linksB");
   u00011 : constant Version_32 := 16#acdd2381#;
   pragma Export (C, u00011, "system__soft_linksS");
   u00012 : constant Version_32 := 16#33935a56#;
   pragma Export (C, u00012, "system__secondary_stackB");
   u00013 : constant Version_32 := 16#b0931c82#;
   pragma Export (C, u00013, "system__secondary_stackS");
   u00014 : constant Version_32 := 16#3007a9ef#;
   pragma Export (C, u00014, "system__parametersB");
   u00015 : constant Version_32 := 16#2bcfb19f#;
   pragma Export (C, u00015, "system__parametersS");
   u00016 : constant Version_32 := 16#46bfce2b#;
   pragma Export (C, u00016, "system__storage_elementsS");
   u00017 : constant Version_32 := 16#0286ce9f#;
   pragma Export (C, u00017, "system__soft_links__initializeB");
   u00018 : constant Version_32 := 16#ac2e8b53#;
   pragma Export (C, u00018, "system__soft_links__initializeS");
   u00019 : constant Version_32 := 16#8599b27b#;
   pragma Export (C, u00019, "system__stack_checkingB");
   u00020 : constant Version_32 := 16#4d3e0fd5#;
   pragma Export (C, u00020, "system__stack_checkingS");
   u00021 : constant Version_32 := 16#45e1965e#;
   pragma Export (C, u00021, "system__exception_tableB");
   u00022 : constant Version_32 := 16#074a6cda#;
   pragma Export (C, u00022, "system__exception_tableS");
   u00023 : constant Version_32 := 16#b8c4a5f1#;
   pragma Export (C, u00023, "system__exceptionsS");
   u00024 : constant Version_32 := 16#c367aa24#;
   pragma Export (C, u00024, "system__exceptions__machineB");
   u00025 : constant Version_32 := 16#8d1d496c#;
   pragma Export (C, u00025, "system__exceptions__machineS");
   u00026 : constant Version_32 := 16#2f7ce883#;
   pragma Export (C, u00026, "system__exceptions_debugB");
   u00027 : constant Version_32 := 16#ba6f4290#;
   pragma Export (C, u00027, "system__exceptions_debugS");
   u00028 : constant Version_32 := 16#1d4109f1#;
   pragma Export (C, u00028, "system__img_intS");
   u00029 : constant Version_32 := 16#5c7d9c20#;
   pragma Export (C, u00029, "system__tracebackB");
   u00030 : constant Version_32 := 16#0cfbee7e#;
   pragma Export (C, u00030, "system__tracebackS");
   u00031 : constant Version_32 := 16#5f6b6486#;
   pragma Export (C, u00031, "system__traceback_entriesB");
   u00032 : constant Version_32 := 16#427da54f#;
   pragma Export (C, u00032, "system__traceback_entriesS");
   u00033 : constant Version_32 := 16#727e0fa1#;
   pragma Export (C, u00033, "system__traceback__symbolicB");
   u00034 : constant Version_32 := 16#3e2e1203#;
   pragma Export (C, u00034, "system__traceback__symbolicS");
   u00035 : constant Version_32 := 16#701f9d88#;
   pragma Export (C, u00035, "ada__exceptions__tracebackB");
   u00036 : constant Version_32 := 16#47e3d2a3#;
   pragma Export (C, u00036, "ada__exceptions__tracebackS");
   u00037 : constant Version_32 := 16#f9910acc#;
   pragma Export (C, u00037, "system__address_imageB");
   u00038 : constant Version_32 := 16#2b8d87f9#;
   pragma Export (C, u00038, "system__address_imageS");
   u00039 : constant Version_32 := 16#bfdff066#;
   pragma Export (C, u00039, "system__img_address_32S");
   u00040 : constant Version_32 := 16#9111f9c1#;
   pragma Export (C, u00040, "interfacesS");
   u00041 : constant Version_32 := 16#92ff51e4#;
   pragma Export (C, u00041, "system__img_address_64S");
   u00042 : constant Version_32 := 16#fd158a37#;
   pragma Export (C, u00042, "system__wch_conB");
   u00043 : constant Version_32 := 16#536239a0#;
   pragma Export (C, u00043, "system__wch_conS");
   u00044 : constant Version_32 := 16#5c289972#;
   pragma Export (C, u00044, "system__wch_stwB");
   u00045 : constant Version_32 := 16#7e7315a1#;
   pragma Export (C, u00045, "system__wch_stwS");
   u00046 : constant Version_32 := 16#7cd63de5#;
   pragma Export (C, u00046, "system__wch_cnvB");
   u00047 : constant Version_32 := 16#55a2f3d0#;
   pragma Export (C, u00047, "system__wch_cnvS");
   u00048 : constant Version_32 := 16#e538de43#;
   pragma Export (C, u00048, "system__wch_jisB");
   u00049 : constant Version_32 := 16#e01591fa#;
   pragma Export (C, u00049, "system__wch_jisS");
   u00050 : constant Version_32 := 16#e6d4fa36#;
   pragma Export (C, u00050, "ada__stringsS");
   u00051 : constant Version_32 := 16#eab62ba6#;
   pragma Export (C, u00051, "ada__strings__fixedB");
   u00052 : constant Version_32 := 16#f9c1b568#;
   pragma Export (C, u00052, "ada__strings__fixedS");
   u00053 : constant Version_32 := 16#9a8aed35#;
   pragma Export (C, u00053, "ada__strings__mapsB");
   u00054 : constant Version_32 := 16#879d83f1#;
   pragma Export (C, u00054, "ada__strings__mapsS");
   u00055 : constant Version_32 := 16#d55f7fbe#;
   pragma Export (C, u00055, "system__bit_opsB");
   u00056 : constant Version_32 := 16#4792b6ff#;
   pragma Export (C, u00056, "system__bit_opsS");
   u00057 : constant Version_32 := 16#704b659a#;
   pragma Export (C, u00057, "system__unsigned_typesS");
   u00058 : constant Version_32 := 16#5b4659fa#;
   pragma Export (C, u00058, "ada__charactersS");
   u00059 : constant Version_32 := 16#cde9ea2d#;
   pragma Export (C, u00059, "ada__characters__latin_1S");
   u00060 : constant Version_32 := 16#28efec31#;
   pragma Export (C, u00060, "ada__strings__searchB");
   u00061 : constant Version_32 := 16#7f896bb3#;
   pragma Export (C, u00061, "ada__strings__searchS");
   u00062 : constant Version_32 := 16#1d8e4f39#;
   pragma Export (C, u00062, "example_repro_supportB");
   u00063 : constant Version_32 := 16#6f9acea2#;
   pragma Export (C, u00063, "example_repro_supportS");
   u00064 : constant Version_32 := 16#60337ee1#;
   pragma Export (C, u00064, "ada__command_lineB");
   u00065 : constant Version_32 := 16#3cdef8c9#;
   pragma Export (C, u00065, "ada__command_lineS");
   u00066 : constant Version_32 := 16#a201b8c5#;
   pragma Export (C, u00066, "ada__strings__text_buffersB");
   u00067 : constant Version_32 := 16#a7cfd09b#;
   pragma Export (C, u00067, "ada__strings__text_buffersS");
   u00068 : constant Version_32 := 16#8b7604c4#;
   pragma Export (C, u00068, "ada__strings__utf_encodingB");
   u00069 : constant Version_32 := 16#c9e86997#;
   pragma Export (C, u00069, "ada__strings__utf_encodingS");
   u00070 : constant Version_32 := 16#bb780f45#;
   pragma Export (C, u00070, "ada__strings__utf_encoding__stringsB");
   u00071 : constant Version_32 := 16#b85ff4b6#;
   pragma Export (C, u00071, "ada__strings__utf_encoding__stringsS");
   u00072 : constant Version_32 := 16#d1d1ed0b#;
   pragma Export (C, u00072, "ada__strings__utf_encoding__wide_stringsB");
   u00073 : constant Version_32 := 16#5678478f#;
   pragma Export (C, u00073, "ada__strings__utf_encoding__wide_stringsS");
   u00074 : constant Version_32 := 16#c2b98963#;
   pragma Export (C, u00074, "ada__strings__utf_encoding__wide_wide_stringsB");
   u00075 : constant Version_32 := 16#d7af3358#;
   pragma Export (C, u00075, "ada__strings__utf_encoding__wide_wide_stringsS");
   u00076 : constant Version_32 := 16#df45aed8#;
   pragma Export (C, u00076, "ada__tagsB");
   u00077 : constant Version_32 := 16#99822aba#;
   pragma Export (C, u00077, "ada__tagsS");
   u00078 : constant Version_32 := 16#3548d972#;
   pragma Export (C, u00078, "system__htableB");
   u00079 : constant Version_32 := 16#0bb84228#;
   pragma Export (C, u00079, "system__htableS");
   u00080 : constant Version_32 := 16#1f1abe38#;
   pragma Export (C, u00080, "system__string_hashB");
   u00081 : constant Version_32 := 16#acfdc257#;
   pragma Export (C, u00081, "system__string_hashS");
   u00082 : constant Version_32 := 16#159aaf05#;
   pragma Export (C, u00082, "system__val_lluS");
   u00083 : constant Version_32 := 16#0d1904b9#;
   pragma Export (C, u00083, "system__val_utilB");
   u00084 : constant Version_32 := 16#66caf8e0#;
   pragma Export (C, u00084, "system__val_utilS");
   u00085 : constant Version_32 := 16#8b956324#;
   pragma Export (C, u00085, "system__case_util_nssB");
   u00086 : constant Version_32 := 16#ef0e9ee9#;
   pragma Export (C, u00086, "system__case_util_nssS");
   u00087 : constant Version_32 := 16#c7620b41#;
   pragma Export (C, u00087, "ada__text_ioB");
   u00088 : constant Version_32 := 16#46a4a696#;
   pragma Export (C, u00088, "ada__text_ioS");
   u00089 : constant Version_32 := 16#6e6e3f5b#;
   pragma Export (C, u00089, "ada__streamsB");
   u00090 : constant Version_32 := 16#bd793559#;
   pragma Export (C, u00090, "ada__streamsS");
   u00091 : constant Version_32 := 16#367911c4#;
   pragma Export (C, u00091, "ada__io_exceptionsS");
   u00092 : constant Version_32 := 16#44f765f3#;
   pragma Export (C, u00092, "system__put_imagesB");
   u00093 : constant Version_32 := 16#9a7e9601#;
   pragma Export (C, u00093, "system__put_imagesS");
   u00094 : constant Version_32 := 16#22b9eb9f#;
   pragma Export (C, u00094, "ada__strings__text_buffers__utilsB");
   u00095 : constant Version_32 := 16#89062ac3#;
   pragma Export (C, u00095, "ada__strings__text_buffers__utilsS");
   u00096 : constant Version_32 := 16#1cacf006#;
   pragma Export (C, u00096, "interfaces__c_streamsB");
   u00097 : constant Version_32 := 16#ecfa876a#;
   pragma Export (C, u00097, "interfaces__c_streamsS");
   u00098 : constant Version_32 := 16#22b1fb99#;
   pragma Export (C, u00098, "system__crtlB");
   u00099 : constant Version_32 := 16#a9f4d4a9#;
   pragma Export (C, u00099, "system__crtlS");
   u00100 : constant Version_32 := 16#a94e7662#;
   pragma Export (C, u00100, "system__file_ioB");
   u00101 : constant Version_32 := 16#ec2e4f85#;
   pragma Export (C, u00101, "system__file_ioS");
   u00102 : constant Version_32 := 16#7598b591#;
   pragma Export (C, u00102, "ada__finalizationS");
   u00103 : constant Version_32 := 16#d00f339c#;
   pragma Export (C, u00103, "system__finalization_rootB");
   u00104 : constant Version_32 := 16#801d2417#;
   pragma Export (C, u00104, "system__finalization_rootS");
   u00105 : constant Version_32 := 16#14fb286b#;
   pragma Export (C, u00105, "system__case_utilB");
   u00106 : constant Version_32 := 16#5499fba9#;
   pragma Export (C, u00106, "system__case_utilS");
   u00107 : constant Version_32 := 16#8e328749#;
   pragma Export (C, u00107, "system__finalization_primitivesB");
   u00108 : constant Version_32 := 16#a30892a3#;
   pragma Export (C, u00108, "system__finalization_primitivesS");
   u00109 : constant Version_32 := 16#afd63177#;
   pragma Export (C, u00109, "system__os_locksS");
   u00110 : constant Version_32 := 16#b9ada65a#;
   pragma Export (C, u00110, "interfaces__cB");
   u00111 : constant Version_32 := 16#610373b9#;
   pragma Export (C, u00111, "interfaces__cS");
   u00112 : constant Version_32 := 16#1311b8a5#;
   pragma Export (C, u00112, "system__os_constantsS");
   u00113 : constant Version_32 := 16#861c956a#;
   pragma Export (C, u00113, "system__os_libB");
   u00114 : constant Version_32 := 16#b4b4641d#;
   pragma Export (C, u00114, "system__os_libS");
   u00115 : constant Version_32 := 16#94d23d25#;
   pragma Export (C, u00115, "system__atomic_operations__test_and_setB");
   u00116 : constant Version_32 := 16#57acee8e#;
   pragma Export (C, u00116, "system__atomic_operations__test_and_setS");
   u00117 : constant Version_32 := 16#4d0260e6#;
   pragma Export (C, u00117, "system__atomic_operationsS");
   u00118 : constant Version_32 := 16#553a519e#;
   pragma Export (C, u00118, "system__atomic_primitivesB");
   u00119 : constant Version_32 := 16#b0203cad#;
   pragma Export (C, u00119, "system__atomic_primitivesS");
   u00120 : constant Version_32 := 16#256dbbe5#;
   pragma Export (C, u00120, "system__stringsB");
   u00121 : constant Version_32 := 16#11e31adb#;
   pragma Export (C, u00121, "system__stringsS");
   u00122 : constant Version_32 := 16#e0daad44#;
   pragma Export (C, u00122, "system__file_control_blockS");
   u00123 : constant Version_32 := 16#ca878138#;
   pragma Export (C, u00123, "system__concat_2B");
   u00124 : constant Version_32 := 16#3f9a6934#;
   pragma Export (C, u00124, "system__concat_2S");
   u00125 : constant Version_32 := 16#752a67ed#;
   pragma Export (C, u00125, "system__concat_3B");
   u00126 : constant Version_32 := 16#001b0361#;
   pragma Export (C, u00126, "system__concat_3S");
   u00127 : constant Version_32 := 16#14335906#;
   pragma Export (C, u00127, "pgish_sqlB");
   u00128 : constant Version_32 := 16#67718885#;
   pragma Export (C, u00128, "pgish_sqlS");
   u00129 : constant Version_32 := 16#75913d83#;
   pragma Export (C, u00129, "ada__characters__handlingB");
   u00130 : constant Version_32 := 16#729cc5db#;
   pragma Export (C, u00130, "ada__characters__handlingS");
   u00131 : constant Version_32 := 16#5c2ece6d#;
   pragma Export (C, u00131, "ada__strings__maps__constantsS");
   u00132 : constant Version_32 := 16#179d7d28#;
   pragma Export (C, u00132, "ada__containersS");
   u00133 : constant Version_32 := 16#7e321c90#;
   pragma Export (C, u00133, "ada__strings__unboundedB");
   u00134 : constant Version_32 := 16#d6cc3e91#;
   pragma Export (C, u00134, "ada__strings__unboundedS");
   u00135 : constant Version_32 := 16#49d4c8e0#;
   pragma Export (C, u00135, "system__return_stackS");
   u00136 : constant Version_32 := 16#52627794#;
   pragma Export (C, u00136, "system__atomic_countersB");
   u00137 : constant Version_32 := 16#5679f500#;
   pragma Export (C, u00137, "system__atomic_countersS");
   u00138 : constant Version_32 := 16#72726776#;
   pragma Export (C, u00138, "system__stream_attributesB");
   u00139 : constant Version_32 := 16#3bf21799#;
   pragma Export (C, u00139, "system__stream_attributesS");
   u00140 : constant Version_32 := 16#c027a94e#;
   pragma Export (C, u00140, "system__stream_attributes__xdrB");
   u00141 : constant Version_32 := 16#35ff530d#;
   pragma Export (C, u00141, "system__stream_attributes__xdrS");
   u00142 : constant Version_32 := 16#4953c5af#;
   pragma Export (C, u00142, "system__fat_fltS");
   u00143 : constant Version_32 := 16#6f61cca2#;
   pragma Export (C, u00143, "system__fat_lfltS");
   u00144 : constant Version_32 := 16#15b16248#;
   pragma Export (C, u00144, "system__fat_llfS");
   u00145 : constant Version_32 := 16#beebd5e7#;
   pragma Export (C, u00145, "flyologyS");
   u00146 : constant Version_32 := 16#e0fce7f8#;
   pragma Export (C, u00146, "system__task_infoB");
   u00147 : constant Version_32 := 16#0a7ba7c2#;
   pragma Export (C, u00147, "system__task_infoS");
   u00148 : constant Version_32 := 16#923977c9#;
   pragma Export (C, u00148, "flyology__postgresS");
   u00149 : constant Version_32 := 16#295b8047#;
   pragma Export (C, u00149, "flyology__postgres__sqlB");
   u00150 : constant Version_32 := 16#c3a6d08f#;
   pragma Export (C, u00150, "flyology__postgres__sqlS");
   u00151 : constant Version_32 := 16#5d06da8f#;
   pragma Export (C, u00151, "flyology__postgres__sql_backendsB");
   u00152 : constant Version_32 := 16#ca3ff766#;
   pragma Export (C, u00152, "flyology__postgres__sql_backendsS");
   u00153 : constant Version_32 := 16#c3b32edd#;
   pragma Export (C, u00153, "ada__containers__helpersB");
   u00154 : constant Version_32 := 16#f29f054d#;
   pragma Export (C, u00154, "ada__containers__helpersS");
   u00155 : constant Version_32 := 16#09e071d6#;
   pragma Export (C, u00155, "system__img_lfltS");
   u00156 : constant Version_32 := 16#1b28662b#;
   pragma Export (C, u00156, "system__float_controlB");
   u00157 : constant Version_32 := 16#6a9d59ff#;
   pragma Export (C, u00157, "system__float_controlS");
   u00158 : constant Version_32 := 16#e1b1c000#;
   pragma Export (C, u00158, "system__img_lluS");
   u00159 : constant Version_32 := 16#eeeda2c4#;
   pragma Export (C, u00159, "system__img_utilB");
   u00160 : constant Version_32 := 16#fd78be7a#;
   pragma Export (C, u00160, "system__img_utilS");
   u00161 : constant Version_32 := 16#d13cd62d#;
   pragma Export (C, u00161, "system__img_unsS");
   u00162 : constant Version_32 := 16#2669480b#;
   pragma Export (C, u00162, "system__powten_lfltS");
   u00163 : constant Version_32 := 16#02e43f40#;
   pragma Export (C, u00163, "system__pool_globalB");
   u00164 : constant Version_32 := 16#928ad74c#;
   pragma Export (C, u00164, "system__pool_globalS");
   u00165 : constant Version_32 := 16#a56a70fa#;
   pragma Export (C, u00165, "system__memoryB");
   u00166 : constant Version_32 := 16#92f586d9#;
   pragma Export (C, u00166, "system__memoryS");
   u00167 : constant Version_32 := 16#9969561e#;
   pragma Export (C, u00167, "system__storage_poolsB");
   u00168 : constant Version_32 := 16#0a664c89#;
   pragma Export (C, u00168, "system__storage_poolsS");
   u00169 : constant Version_32 := 16#36601f03#;
   pragma Export (C, u00169, "system__storage_pools__subpoolsB");
   u00170 : constant Version_32 := 16#219014ff#;
   pragma Export (C, u00170, "system__storage_pools__subpoolsS");
   u00171 : constant Version_32 := 16#20ec7aa3#;
   pragma Export (C, u00171, "system__ioB");
   u00172 : constant Version_32 := 16#1423ed8c#;
   pragma Export (C, u00172, "system__ioS");
   u00173 : constant Version_32 := 16#3676fd0b#;
   pragma Export (C, u00173, "system__storage_pools__subpools__finalizationB");
   u00174 : constant Version_32 := 16#4c972977#;
   pragma Export (C, u00174, "system__storage_pools__subpools__finalizationS");
   u00175 : constant Version_32 := 16#be6f5d2e#;
   pragma Export (C, u00175, "system__strings__stream_opsB");
   u00176 : constant Version_32 := 16#9a9c0b11#;
   pragma Export (C, u00176, "system__strings__stream_opsS");
   u00177 : constant Version_32 := 16#9542d1ea#;
   pragma Export (C, u00177, "flyology__postgres__sql__astS");
   u00178 : constant Version_32 := 16#1708aada#;
   pragma Export (C, u00178, "flyology__postgres__sql__ast__v18B");
   u00179 : constant Version_32 := 16#77501c80#;
   pragma Export (C, u00179, "flyology__postgres__sql__ast__v18S");
   u00180 : constant Version_32 := 16#bc168047#;
   pragma Export (C, u00180, "flyology__postgres__sql__ast_materialization_v18B");
   u00181 : constant Version_32 := 16#7dc83784#;
   pragma Export (C, u00181, "flyology__postgres__sql__ast_materialization_v18S");
   u00182 : constant Version_32 := 16#7085444c#;
   pragma Export (C, u00182, "flyology__postgres__sql__ast_ownership_v18B");
   u00183 : constant Version_32 := 16#41fda567#;
   pragma Export (C, u00183, "flyology__postgres__sql__ast_ownership_v18S");
   u00184 : constant Version_32 := 16#20804eed#;
   pragma Export (C, u00184, "flyology__postgres__sql__viewsB");
   u00185 : constant Version_32 := 16#3986aaf0#;
   pragma Export (C, u00185, "flyology__postgres__sql__viewsS");
   u00186 : constant Version_32 := 16#96310099#;
   pragma Export (C, u00186, "flyology__postgres__sql__views__v18B");
   u00187 : constant Version_32 := 16#3d26ab7a#;
   pragma Export (C, u00187, "flyology__postgres__sql__views__v18S");
   u00188 : constant Version_32 := 16#536fcfa7#;
   pragma Export (C, u00188, "flyology__postgres__sql__internalsB");
   u00189 : constant Version_32 := 16#a3278051#;
   pragma Export (C, u00189, "flyology__postgres__sql__internalsS");
   u00190 : constant Version_32 := 16#194c0dd5#;
   pragma Export (C, u00190, "flyology__postgres__sql__nativeS");
   u00191 : constant Version_32 := 16#afbdce75#;
   pragma Export (C, u00191, "flyology__postgres__sql__native__backend_v18B");
   u00192 : constant Version_32 := 16#50f48166#;
   pragma Export (C, u00192, "flyology__postgres__sql__native__backend_v18S");
   u00193 : constant Version_32 := 16#c61dcb1d#;
   pragma Export (C, u00193, "flyology__postgres__sql__native__backendB");
   u00194 : constant Version_32 := 16#96f1ba19#;
   pragma Export (C, u00194, "flyology__postgres__sql__native__backendS");
   u00195 : constant Version_32 := 16#db162d6f#;
   pragma Export (C, u00195, "flyology__postgres__sql__native__convertersB");
   u00196 : constant Version_32 := 16#0122b37c#;
   pragma Export (C, u00196, "flyology__postgres__sql__native__convertersS");
   u00197 : constant Version_32 := 16#918738a8#;
   pragma Export (C, u00197, "flyology__postgres__sql__arena_storageB");
   u00198 : constant Version_32 := 16#72e370c8#;
   pragma Export (C, u00198, "flyology__postgres__sql__arena_storageS");
   u00199 : constant Version_32 := 16#0831a97a#;
   pragma Export (C, u00199, "flyology__postgres__sql__native__buildersB");
   u00200 : constant Version_32 := 16#e9a16bb1#;
   pragma Export (C, u00200, "flyology__postgres__sql__native__buildersS");
   u00201 : constant Version_32 := 16#842e1788#;
   pragma Export (C, u00201, "flyology__postgres__sql__native__schemaS");
   u00202 : constant Version_32 := 16#3de4cc77#;
   pragma Export (C, u00202, "flyology__postgres__sql__native__schema_v18S");
   u00203 : constant Version_32 := 16#5b523531#;
   pragma Export (C, u00203, "flyology__postgres__sql__native__version_v18B");
   u00204 : constant Version_32 := 16#b1522a2e#;
   pragma Export (C, u00204, "flyology__postgres__sql__native__version_v18S");
   u00205 : constant Version_32 := 16#b62d8592#;
   pragma Export (C, u00205, "flyology__postgres__sql__native__actions_v18B");
   u00206 : constant Version_32 := 16#c76e4e53#;
   pragma Export (C, u00206, "flyology__postgres__sql__native__actions_v18S");
   u00207 : constant Version_32 := 16#ce6e6bbb#;
   pragma Export (C, u00207, "flyology__postgres__sql__native__action_catalogB");
   u00208 : constant Version_32 := 16#14905244#;
   pragma Export (C, u00208, "flyology__postgres__sql__native__action_catalogS");
   u00209 : constant Version_32 := 16#ed433efb#;
   pragma Export (C, u00209, "flyology__postgres__sql__native__action_catalog_chunk_01B");
   u00210 : constant Version_32 := 16#efc4683e#;
   pragma Export (C, u00210, "flyology__postgres__sql__native__action_catalog_chunk_01S");
   u00211 : constant Version_32 := 16#fb7c3118#;
   pragma Export (C, u00211, "flyology__postgres__sql__native__semanticsB");
   u00212 : constant Version_32 := 16#54ad91fc#;
   pragma Export (C, u00212, "flyology__postgres__sql__native__semanticsS");
   u00213 : constant Version_32 := 16#b2148485#;
   pragma Export (C, u00213, "system__img_lliS");
   u00214 : constant Version_32 := 16#c2b9a7cd#;
   pragma Export (C, u00214, "flyology__postgres__sql__native__action_catalog_chunk_02B");
   u00215 : constant Version_32 := 16#c6b24798#;
   pragma Export (C, u00215, "flyology__postgres__sql__native__action_catalog_chunk_02S");
   u00216 : constant Version_32 := 16#10b96031#;
   pragma Export (C, u00216, "flyology__postgres__sql__native__action_catalog_chunk_03B");
   u00217 : constant Version_32 := 16#68b0a0c5#;
   pragma Export (C, u00217, "flyology__postgres__sql__native__action_catalog_chunk_03S");
   u00218 : constant Version_32 := 16#4d40ec28#;
   pragma Export (C, u00218, "flyology__postgres__sql__native__action_catalog_chunk_04B");
   u00219 : constant Version_32 := 16#945e18d4#;
   pragma Export (C, u00219, "flyology__postgres__sql__native__action_catalog_chunk_04S");
   u00220 : constant Version_32 := 16#5ee40c1a#;
   pragma Export (C, u00220, "flyology__postgres__sql__native__action_catalog_chunk_05B");
   u00221 : constant Version_32 := 16#3a5cff89#;
   pragma Export (C, u00221, "flyology__postgres__sql__native__action_catalog_chunk_05S");
   u00222 : constant Version_32 := 16#ff2f6009#;
   pragma Export (C, u00222, "flyology__postgres__sql__native__action_catalog_chunk_06B");
   u00223 : constant Version_32 := 16#132ad02f#;
   pragma Export (C, u00223, "flyology__postgres__sql__native__action_catalog_chunk_06S");
   u00224 : constant Version_32 := 16#234b6d3c#;
   pragma Export (C, u00224, "flyology__postgres__sql__native__action_catalog_chunk_07B");
   u00225 : constant Version_32 := 16#bd283772#;
   pragma Export (C, u00225, "flyology__postgres__sql__native__action_catalog_chunk_07S");
   u00226 : constant Version_32 := 16#d5623bd7#;
   pragma Export (C, u00226, "flyology__postgres__sql__native__action_catalog_chunk_08B");
   u00227 : constant Version_32 := 16#3186a64c#;
   pragma Export (C, u00227, "flyology__postgres__sql__native__action_catalog_chunk_08S");
   u00228 : constant Version_32 := 16#e694220d#;
   pragma Export (C, u00228, "flyology__postgres__sql__native__action_catalog_chunk_09B");
   u00229 : constant Version_32 := 16#9f844111#;
   pragma Export (C, u00229, "flyology__postgres__sql__native__action_catalog_chunk_09S");
   u00230 : constant Version_32 := 16#bf47e8e1#;
   pragma Export (C, u00230, "flyology__postgres__sql__native__action_catalog_chunk_10B");
   u00231 : constant Version_32 := 16#54b2a0cd#;
   pragma Export (C, u00231, "flyology__postgres__sql__native__action_catalog_chunk_10S");
   u00232 : constant Version_32 := 16#02a99c05#;
   pragma Export (C, u00232, "flyology__postgres__sql__native__action_catalog_chunk_11B");
   u00233 : constant Version_32 := 16#fab04790#;
   pragma Export (C, u00233, "flyology__postgres__sql__native__action_catalog_chunk_11S");
   u00234 : constant Version_32 := 16#71685d60#;
   pragma Export (C, u00234, "flyology__postgres__sql__native__action_catalog_chunk_12B");
   u00235 : constant Version_32 := 16#d3c66836#;
   pragma Export (C, u00235, "flyology__postgres__sql__native__action_catalog_chunk_12S");
   u00236 : constant Version_32 := 16#0d7987c8#;
   pragma Export (C, u00236, "flyology__postgres__sql__native__action_catalog_chunk_13B");
   u00237 : constant Version_32 := 16#7dc48f6b#;
   pragma Export (C, u00237, "flyology__postgres__sql__native__action_catalog_chunk_13S");
   u00238 : constant Version_32 := 16#cd68fff6#;
   pragma Export (C, u00238, "flyology__postgres__sql__native__action_catalog_chunk_14B");
   u00239 : constant Version_32 := 16#812a377a#;
   pragma Export (C, u00239, "flyology__postgres__sql__native__action_catalog_chunk_14S");
   u00240 : constant Version_32 := 16#bef5f844#;
   pragma Export (C, u00240, "flyology__postgres__sql__native__actions_v18_supportB");
   u00241 : constant Version_32 := 16#9d6b126f#;
   pragma Export (C, u00241, "flyology__postgres__sql__native__actions_v18_supportS");
   u00242 : constant Version_32 := 16#09b7ffcf#;
   pragma Export (C, u00242, "flyology__postgres__sql__native__action_helper_catalogB");
   u00243 : constant Version_32 := 16#a427bbdb#;
   pragma Export (C, u00243, "flyology__postgres__sql__native__action_helper_catalogS");
   u00244 : constant Version_32 := 16#2e4fe61c#;
   pragma Export (C, u00244, "flyology__postgres__sql__native__action_helper_catalog_chunk_01B");
   u00245 : constant Version_32 := 16#9343e166#;
   pragma Export (C, u00245, "flyology__postgres__sql__native__action_helper_catalog_chunk_01S");
   u00246 : constant Version_32 := 16#c060c055#;
   pragma Export (C, u00246, "flyology__postgres__sql__native__action_helper_catalog_chunk_02B");
   u00247 : constant Version_32 := 16#1688a912#;
   pragma Export (C, u00247, "flyology__postgres__sql__native__action_helper_catalog_chunk_02S");
   u00248 : constant Version_32 := 16#58b05ca1#;
   pragma Export (C, u00248, "flyology__postgres__sql__native__action_helper_catalog_chunk_03B");
   u00249 : constant Version_32 := 16#6a31913e#;
   pragma Export (C, u00249, "flyology__postgres__sql__native__action_helper_catalog_chunk_03S");
   u00250 : constant Version_32 := 16#35d88fa9#;
   pragma Export (C, u00250, "flyology__postgres__sql__native__dfaB");
   u00251 : constant Version_32 := 16#45952539#;
   pragma Export (C, u00251, "flyology__postgres__sql__native__dfaS");
   u00252 : constant Version_32 := 16#dddd0e3d#;
   pragma Export (C, u00252, "flyology__postgres__sql__native__tablesS");
   u00253 : constant Version_32 := 16#acc838b2#;
   pragma Export (C, u00253, "flyology__postgres__sql__native__engineB");
   u00254 : constant Version_32 := 16#2550e56b#;
   pragma Export (C, u00254, "flyology__postgres__sql__native__engineS");
   u00255 : constant Version_32 := 16#96173b6e#;
   pragma Export (C, u00255, "flyology__postgres__sql__native__lalrB");
   u00256 : constant Version_32 := 16#15964aac#;
   pragma Export (C, u00256, "flyology__postgres__sql__native__lalrS");
   u00257 : constant Version_32 := 16#72bfd889#;
   pragma Export (C, u00257, "flyology__postgres__sql__native__scannerB");
   u00258 : constant Version_32 := 16#d401e7df#;
   pragma Export (C, u00258, "flyology__postgres__sql__native__scannerS");
   u00259 : constant Version_32 := 16#42e1fe73#;
   pragma Export (C, u00259, "flyology__postgres__sql__native__generated_v18S");
   u00260 : constant Version_32 := 16#0b1df16c#;
   pragma Export (C, u00260, "flyology__postgres__sql__ast_parser_v18B");
   u00261 : constant Version_32 := 16#330194cf#;
   pragma Export (C, u00261, "flyology__postgres__sql__ast_parser_v18S");
   u00262 : constant Version_32 := 16#93aeaf8d#;
   pragma Export (C, u00262, "flyology__postgres__sql__ast__v18__visitorsB");
   u00263 : constant Version_32 := 16#a02f1a4f#;
   pragma Export (C, u00263, "flyology__postgres__sql__ast__v18__visitorsS");
   u00264 : constant Version_32 := 16#53662346#;
   pragma Export (C, u00264, "system__val_intS");
   u00265 : constant Version_32 := 16#bfedde8f#;
   pragma Export (C, u00265, "system__val_unsS");
   u00266 : constant Version_32 := 16#bcc987d2#;
   pragma Export (C, u00266, "system__concat_4B");
   u00267 : constant Version_32 := 16#b99945fd#;
   pragma Export (C, u00267, "system__concat_4S");

   --  BEGIN ELABORATION ORDER
   --  ada%s
   --  ada.characters%s
   --  ada.characters.latin_1%s
   --  interfaces%s
   --  system%s
   --  system.atomic_operations%s
   --  system.case_util_nss%s
   --  system.case_util_nss%b
   --  system.float_control%s
   --  system.float_control%b
   --  system.io%s
   --  system.io%b
   --  system.parameters%s
   --  system.parameters%b
   --  system.crtl%s
   --  system.crtl%b
   --  interfaces.c_streams%s
   --  interfaces.c_streams%b
   --  system.powten_lflt%s
   --  system.storage_elements%s
   --  system.img_address_32%s
   --  system.img_address_64%s
   --  system.return_stack%s
   --  system.stack_checking%s
   --  system.stack_checking%b
   --  system.string_hash%s
   --  system.string_hash%b
   --  system.htable%s
   --  system.htable%b
   --  system.strings%s
   --  system.strings%b
   --  system.task_info%s
   --  system.task_info%b
   --  system.traceback_entries%s
   --  system.traceback_entries%b
   --  system.unsigned_types%s
   --  system.wch_con%s
   --  system.wch_con%b
   --  system.wch_jis%s
   --  system.wch_jis%b
   --  system.wch_cnv%s
   --  system.wch_cnv%b
   --  system.concat_2%s
   --  system.concat_2%b
   --  system.concat_3%s
   --  system.concat_3%b
   --  system.concat_4%s
   --  system.concat_4%b
   --  system.img_int%s
   --  system.img_lli%s
   --  system.img_llu%s
   --  system.img_uns%s
   --  system.img_util%s
   --  system.img_util%b
   --  system.traceback%s
   --  system.traceback%b
   --  system.secondary_stack%s
   --  system.standard_library%s
   --  ada.exceptions%s
   --  system.exceptions_debug%s
   --  system.exceptions_debug%b
   --  system.soft_links%s
   --  system.wch_stw%s
   --  system.wch_stw%b
   --  ada.exceptions.last_chance_handler%s
   --  ada.exceptions.last_chance_handler%b
   --  ada.exceptions.traceback%s
   --  ada.exceptions.traceback%b
   --  system.address_image%s
   --  system.address_image%b
   --  system.exception_table%s
   --  system.exception_table%b
   --  system.exceptions%s
   --  system.exceptions.machine%s
   --  system.exceptions.machine%b
   --  system.memory%s
   --  system.memory%b
   --  system.secondary_stack%b
   --  system.soft_links.initialize%s
   --  system.soft_links.initialize%b
   --  system.soft_links%b
   --  system.standard_library%b
   --  system.traceback.symbolic%s
   --  system.traceback.symbolic%b
   --  ada.exceptions%b
   --  ada.command_line%s
   --  ada.command_line%b
   --  ada.containers%s
   --  ada.io_exceptions%s
   --  ada.strings%s
   --  ada.strings.utf_encoding%s
   --  ada.strings.utf_encoding%b
   --  ada.strings.utf_encoding.strings%s
   --  ada.strings.utf_encoding.strings%b
   --  ada.strings.utf_encoding.wide_strings%s
   --  ada.strings.utf_encoding.wide_strings%b
   --  ada.strings.utf_encoding.wide_wide_strings%s
   --  ada.strings.utf_encoding.wide_wide_strings%b
   --  interfaces.c%s
   --  interfaces.c%b
   --  system.atomic_primitives%s
   --  system.atomic_primitives%b
   --  system.atomic_counters%s
   --  system.atomic_counters%b
   --  system.atomic_operations.test_and_set%s
   --  system.atomic_operations.test_and_set%b
   --  system.case_util%s
   --  system.case_util%b
   --  system.fat_flt%s
   --  system.fat_lflt%s
   --  system.fat_llf%s
   --  system.os_constants%s
   --  system.os_lib%s
   --  system.os_lib%b
   --  system.os_locks%s
   --  system.finalization_primitives%s
   --  system.finalization_primitives%b
   --  system.val_util%s
   --  system.val_util%b
   --  system.val_llu%s
   --  ada.tags%s
   --  ada.tags%b
   --  ada.strings.text_buffers%s
   --  ada.strings.text_buffers%b
   --  ada.strings.text_buffers.utils%s
   --  ada.strings.text_buffers.utils%b
   --  system.put_images%s
   --  system.put_images%b
   --  ada.streams%s
   --  ada.streams%b
   --  system.file_control_block%s
   --  system.finalization_root%s
   --  system.finalization_root%b
   --  ada.finalization%s
   --  ada.containers.helpers%s
   --  ada.containers.helpers%b
   --  system.file_io%s
   --  system.file_io%b
   --  system.storage_pools%s
   --  system.storage_pools%b
   --  system.storage_pools.subpools%s
   --  system.storage_pools.subpools.finalization%s
   --  system.storage_pools.subpools.finalization%b
   --  system.storage_pools.subpools%b
   --  system.stream_attributes%s
   --  system.stream_attributes.xdr%s
   --  system.stream_attributes.xdr%b
   --  system.stream_attributes%b
   --  system.val_uns%s
   --  system.val_int%s
   --  ada.text_io%s
   --  ada.text_io%b
   --  system.bit_ops%s
   --  system.bit_ops%b
   --  ada.strings.maps%s
   --  ada.strings.maps%b
   --  ada.strings.maps.constants%s
   --  ada.characters.handling%s
   --  ada.characters.handling%b
   --  ada.strings.search%s
   --  ada.strings.search%b
   --  ada.strings.fixed%s
   --  ada.strings.fixed%b
   --  ada.strings.unbounded%s
   --  ada.strings.unbounded%b
   --  system.img_lflt%s
   --  system.pool_global%s
   --  system.pool_global%b
   --  system.strings.stream_ops%s
   --  system.strings.stream_ops%b
   --  flyology%s
   --  example_repro_support%s
   --  example_repro_support%b
   --  flyology.postgres%s
   --  flyology.postgres.sql%s
   --  flyology.postgres.sql_backends%s
   --  flyology.postgres.sql_backends%b
   --  flyology.postgres.sql%b
   --  flyology.postgres.sql.arena_storage%s
   --  flyology.postgres.sql.arena_storage%b
   --  flyology.postgres.sql.ast%s
   --  flyology.postgres.sql.internals%s
   --  flyology.postgres.sql.internals%b
   --  flyology.postgres.sql.native%s
   --  flyology.postgres.sql.native.builders%s
   --  flyology.postgres.sql.native.builders%b
   --  flyology.postgres.sql.native.schema%s
   --  flyology.postgres.sql.native.converters%s
   --  flyology.postgres.sql.native.converters%b
   --  flyology.postgres.sql.native.backend%s
   --  flyology.postgres.sql.native.backend%b
   --  flyology.postgres.sql.native.schema_v18%s
   --  flyology.postgres.sql.native.semantics%s
   --  flyology.postgres.sql.native.semantics%b
   --  flyology.postgres.sql.native.action_catalog%s
   --  flyology.postgres.sql.native.action_catalog_chunk_01%s
   --  flyology.postgres.sql.native.action_catalog_chunk_01%b
   --  flyology.postgres.sql.native.action_catalog_chunk_02%s
   --  flyology.postgres.sql.native.action_catalog_chunk_02%b
   --  flyology.postgres.sql.native.action_catalog_chunk_03%s
   --  flyology.postgres.sql.native.action_catalog_chunk_03%b
   --  flyology.postgres.sql.native.action_catalog_chunk_04%s
   --  flyology.postgres.sql.native.action_catalog_chunk_04%b
   --  flyology.postgres.sql.native.action_catalog_chunk_05%s
   --  flyology.postgres.sql.native.action_catalog_chunk_05%b
   --  flyology.postgres.sql.native.action_catalog_chunk_06%s
   --  flyology.postgres.sql.native.action_catalog_chunk_06%b
   --  flyology.postgres.sql.native.action_catalog_chunk_07%s
   --  flyology.postgres.sql.native.action_catalog_chunk_07%b
   --  flyology.postgres.sql.native.action_catalog_chunk_08%s
   --  flyology.postgres.sql.native.action_catalog_chunk_08%b
   --  flyology.postgres.sql.native.action_catalog_chunk_09%s
   --  flyology.postgres.sql.native.action_catalog_chunk_09%b
   --  flyology.postgres.sql.native.action_catalog_chunk_10%s
   --  flyology.postgres.sql.native.action_catalog_chunk_10%b
   --  flyology.postgres.sql.native.action_catalog_chunk_11%s
   --  flyology.postgres.sql.native.action_catalog_chunk_11%b
   --  flyology.postgres.sql.native.action_catalog_chunk_12%s
   --  flyology.postgres.sql.native.action_catalog_chunk_12%b
   --  flyology.postgres.sql.native.action_catalog_chunk_13%s
   --  flyology.postgres.sql.native.action_catalog_chunk_13%b
   --  flyology.postgres.sql.native.action_catalog_chunk_14%s
   --  flyology.postgres.sql.native.action_catalog_chunk_14%b
   --  flyology.postgres.sql.native.action_catalog%b
   --  flyology.postgres.sql.native.action_helper_catalog%s
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_01%s
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_01%b
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_02%s
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_02%b
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_03%s
   --  flyology.postgres.sql.native.action_helper_catalog_chunk_03%b
   --  flyology.postgres.sql.native.action_helper_catalog%b
   --  flyology.postgres.sql.native.actions_v18_support%s
   --  flyology.postgres.sql.native.actions_v18_support%b
   --  flyology.postgres.sql.native.actions_v18%s
   --  flyology.postgres.sql.native.actions_v18%b
   --  flyology.postgres.sql.native.tables%s
   --  flyology.postgres.sql.native.dfa%s
   --  flyology.postgres.sql.native.dfa%b
   --  flyology.postgres.sql.native.generated_v18%s
   --  flyology.postgres.sql.native.lalr%s
   --  flyology.postgres.sql.native.lalr%b
   --  flyology.postgres.sql.native.scanner%s
   --  flyology.postgres.sql.native.scanner%b
   --  flyology.postgres.sql.native.engine%s
   --  flyology.postgres.sql.native.engine%b
   --  flyology.postgres.sql.native.version_v18%s
   --  flyology.postgres.sql.native.version_v18%b
   --  flyology.postgres.sql.native.backend_v18%s
   --  flyology.postgres.sql.native.backend_v18%b
   --  flyology.postgres.sql.views%s
   --  flyology.postgres.sql.views%b
   --  flyology.postgres.sql.views.v18%s
   --  flyology.postgres.sql.views.v18%b
   --  flyology.postgres.sql.ast.v18%s
   --  flyology.postgres.sql.ast_materialization_v18%s
   --  flyology.postgres.sql.ast_ownership_v18%s
   --  flyology.postgres.sql.ast_ownership_v18%b
   --  flyology.postgres.sql.ast_materialization_v18%b
   --  flyology.postgres.sql.ast_parser_v18%s
   --  flyology.postgres.sql.ast_parser_v18%b
   --  flyology.postgres.sql.ast.v18%b
   --  flyology.postgres.sql.ast.v18.visitors%s
   --  flyology.postgres.sql.ast.v18.visitors%b
   --  pgish_sql%s
   --  pgish_sql%b
   --  repro_examples_10%b
   --  END ELABORATION ORDER

end ada_main;
