package Example_Repro_Support is
   --  Shared helpers for example-crate reproduction programs.  Convention:
   --  a program asserts the CORRECT behavior.  On current sources it prints
   --  "BUG REPRODUCED" and exits with status 1; after a fix it prints "PASS"
   --  and exits 0.

   procedure Check (Condition : Boolean; Description : String);
   --  Record a failed expectation when Condition is False.

   procedure Note (Text : String);
   --  Print an informational line.

   procedure Finish;
   --  Print the verdict and set the process exit status.

end Example_Repro_Support;
