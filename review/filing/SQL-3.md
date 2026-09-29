Title: \U escapes at or above 0x80000000 overflow Natural and report a GNAT overflow message
Labels: bug
Refs: SQL-8

## Summary

`Based_Value` accumulates the eight hexadecimal digits of a `\UXXXXXXXX` escape into a `Natural`, whose upper bound is 2**31-1 on this toolchain, so any value at or above 0x80000000 overflows on the final multiply. The `Constraint_Error` is caught by the engine's generic handler and published as `flyology-postgres-sql-native-scanner.adb:74 overflow check failed` at the first token. PostgreSQL reads the same digits with `strtoul` into a `pg_wchar` and lets `addunicode` reject the value, giving `invalid Unicode escape value at or near "\UFFFFFFFF"` at the backslash. Both parsers reject the statement, so only the diagnostic and cursor are wrong.

## Problem

Commit `6f496f5`.

The accumulator has no upper bound (`sql/src/flyology-postgres-sql-native-scanner.adb:70-77`):

```ada
   function Based_Value (Value : String; Base : Positive) return Natural is
      Result : Natural := 0;
   begin
      for Item of Value loop
         Result := Result * Base + Hex_Value (Item);
      end loop;
      return Result;
   end Based_Value;
```

Line 74 is the multiply that overflows. The range test that would classify the value runs only after the accumulation returns (`sql/src/flyology-postgres-sql-native-scanner.adb:87-90`):

```ada
      if Code = 0 or else Code > 16#10_FFFF#
        or else Code in 16#D800# .. 16#DFFF#
      then
         Fail (Self, Position, "invalid Unicode escape value");
```

PostgreSQL's pattern admits the eight-digit form (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:266`):

```c
xeunicode		[\\](u[0-9A-Fa-f]{4}|U[0-9A-Fa-f]{8})
```

and the value is assembled with `strtoul` into a `pg_wchar` and handed to `addunicode`, which raises the `invalid Unicode escape value` error through `scanner_errposition` and so reports the backslash. The pattern and the action are the same on all five majors.

The `Constraint_Error` reaches the engine's generic handler, which publishes the exception message at `Last_Location` with no PostgreSQL context (`sql/src/flyology-postgres-sql-native-engine.adb:128-129`):

```ada
         else
            Report_Error (Error, Last_Location, False);
```

The native-versus-oracle corpus exercises `\0061` and `\+000061` only (`sql/tests/src/flyology-postgres-sql-differential_testing.adb:48`), both far below the overflow threshold, and the PostgreSQL regression corpus has no eight-digit `\U` value at or above 0x80000000 on any major; the values it uses are of the `\U002FFFFF` shape. The regression corpus check also compares only statements the oracle accepts (`sql/tests/src/flyology-postgres-sql-regression_corpus_testing.adb:183-185`, :256-257), so it never compares diagnostics for rejected input, and the owned corpus compares the owned result against `Parse_Baseline`, which runs the same native scanner.

## What happens now

Spike: parses the statement through the native parser and through the pinned pg_query oracle for PostgreSQL 14 through 18 and compares the diagnostic text and cursor, with `\U7FFFFFFF`, one bit lower, as a control.

```ada
   Overflowing : constant String := "SELECT E'\UFFFFFFFF'";
   In_Range    : constant String := "SELECT E'\U7FFFFFFF'";
   Expected    : constant String := "invalid Unicode escape value";
...
      Check (Starts_With (Native_Error (Overflowing, Version), Expected),
             Version'Image & ": \UFFFFFFFF reports " & Expected);
      Check (Native_Error_Position (Overflowing, Version) =
               Oracle_Error_Position (Overflowing, Version),
             Version'Image & ": \UFFFFFFFF cursor matches the C oracle");
```

```
  -- POSTGRESQL_14 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_14 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_14: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_14: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_15 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_15 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_15: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_15: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_16 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_16 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_16: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_16: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_17 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_17 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_17: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_17: \UFFFFFFFF cursor matches the C oracle
  -- POSTGRESQL_18 native: [flyology-postgres-sql-native-scanner.adb:74 overflow check failed] @ 1
  -- POSTGRESQL_18 oracle: [invalid Unicode escape value at or near "\UFFFFFFFF"] @ 10
  FAILED: POSTGRESQL_18: \UFFFFFFFF reports invalid Unicode escape value
  FAILED: POSTGRESQL_18: \UFFFFFFFF cursor matches the C oracle
  -- control \U7FFFFFFF native: [invalid Unicode escape value at or near "\U7FFFFFFF'"] @ 10
  ok: control: \U7FFFFFFF reports invalid Unicode escape value
  ok: control: \U7FFFFFFF cursor matches the C oracle
BUG REPRODUCED: 10 failed expectation(s)
```

The control reaches the intended classification and the oracle's cursor. Its quoted context still runs to the end of the input, which is the separate defect in {{ISSUE:SQL-8}}.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. Compared against the pinned pg_query C oracle for PostgreSQL 14 through 18.

## What should happen

`SELECT E'\UFFFFFFFF'` must fail with `invalid Unicode escape value at or near "\UFFFFFFFF"` at cursor 10, as `addunicode` does through `scanner_errposition`. Every eight-digit `\U` value must reach that classification instead of raising inside the accumulator.

## Suggested treatment

Accumulate the escape value in a type that holds eight hexadecimal digits without overflow, for instance `Interfaces.Unsigned_32` or `Interfaces.Integer_64`, and range-check into `Natural` after the accumulation, at `sql/src/flyology-postgres-sql-native-scanner.adb:70-77`. `Based_Value` is also used for the octal and two-digit hexadecimal escapes, where the widening is harmless. The existing test at `sql/src/flyology-postgres-sql-native-scanner.adb:87-90` then classifies the value, and the diagnostic and cursor follow from it.

The regression test belongs in `sql/tests/src/flyology-postgres-sql-differential_testing.adb` beside the escape-string entry at line 48, as `Check ("SELECT E'\UFFFFFFFF'")` on all majors. The spike is that test. No existing test asserts the current behaviour.

## Severity

The input is invalid on both sides, so no query is misparsed and no wrong value is produced; only the diagnostic text and the cursor are wrong, and the text that reaches the caller is an Ada source location rather than a PostgreSQL message. It needs an eight-digit `\U` escape with the top bit set inside an `E'...'` literal, which is unusual input. All five supported majors.
