with Flyology.Postgres.SQL;

package SQL_Repro_Support is
   --  Shared helpers for SQL bug reproduction programs.  Convention: a
   --  program asserts the CORRECT behavior.  On current sources it prints
   --  "BUG REPRODUCED" and exits with status 1; after a fix it prints "PASS"
   --  and exits 0.

   package SQL renames Flyology.Postgres.SQL;

   procedure Check (Condition : Boolean; Description : String);
   --  Record a failed expectation when Condition is False.

   procedure Note (Text : String);
   --  Print an informational line.

   procedure Finish;
   --  Print the verdict and set the process exit status.

   function Native_Error
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String;
   --  Parse through the native arena parser (SQL.Views.Parse) and return the
   --  diagnostic text, or "" when the parse succeeded.

   function Native_Error_Position
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return Natural;
   --  Cursor position of the native diagnostic, 0 when the parse succeeded.

   function Oracle_Error
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String;
   --  Same through the version-pinned C/protobuf oracle.

   function Oracle_Error_Position
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return Natural;

   function Oracle_Difference
     (Text    : String;
      Version : SQL.Major_Version;
      Options : SQL.Parse_Options := SQL.Default_Options) return String;
   --  Parse Text through the native arena parser and through the C oracle
   --  and return the first logical arena path that differs, or "" when the
   --  two arenas are equivalent (this is what the differential suite asserts).

end SQL_Repro_Support;
