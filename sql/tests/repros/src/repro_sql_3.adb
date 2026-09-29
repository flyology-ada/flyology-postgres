with SQL_Repro_Support; use SQL_Repro_Support;

procedure Repro_SQL_3 is
   --  SQL-3: scan.l's {xeunicode} action reads the 8 hex digits with
   --  strtoul into a pg_wchar and lets addunicode() reject the value
   --  ("invalid Unicode escape value", reported at the backslash).  The Ada
   --  Based_Value accumulates into Natural, so any \U value >= 2**31
   --  overflows before the range test runs and the engine reports a GNAT
   --  overflow message at the first token instead.

   Overflowing : constant String := "SELECT E'\UFFFFFFFF'";
   In_Range    : constant String := "SELECT E'\U7FFFFFFF'";
   Expected    : constant String := "invalid Unicode escape value";

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);
begin
   for Version in SQL.Major_Version loop
      Note (Version'Image & " native: [" & Native_Error (Overflowing, Version)
            & "] @" & Native_Error_Position (Overflowing, Version)'Image);
      Note (Version'Image & " oracle: [" & Oracle_Error (Overflowing, Version)
            & "] @" & Oracle_Error_Position (Overflowing, Version)'Image);
      Check (Starts_With (Native_Error (Overflowing, Version), Expected),
             Version'Image & ": \UFFFFFFFF reports " & Expected);
      Check (Native_Error_Position (Overflowing, Version) =
               Oracle_Error_Position (Overflowing, Version),
             Version'Image & ": \UFFFFFFFF cursor matches the C oracle");
   end loop;

   --  Control: the same escape one bit lower stays inside Natural and is
   --  classified correctly (its context text is a separate finding, SQL-8).
   Note ("control \U7FFFFFFF native: [" & Native_Error (In_Range, SQL.PostgreSQL_18)
         & "] @" & Native_Error_Position (In_Range, SQL.PostgreSQL_18)'Image);
   Check (Starts_With (Native_Error (In_Range, SQL.PostgreSQL_18), Expected),
          "control: \U7FFFFFFF reports " & Expected);
   Check (Native_Error_Position (In_Range, SQL.PostgreSQL_18) =
            Oracle_Error_Position (In_Range, SQL.PostgreSQL_18),
          "control: \U7FFFFFFF cursor matches the C oracle");

   Finish;
end Repro_SQL_3;
