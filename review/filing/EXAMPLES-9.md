Title: psqlish expanded output pads each field name to its column's data width instead of the widest name
Labels: bug
Refs: none

## Summary

`Psqlish.Display.Finish_Result` computes one width per column as the maximum of the header text and every value in that column, which is what the tabular layout needs. The expanded renderer reuses the same array to pad the field name. In expanded mode each field is on its own line, so the name column must be padded to the widest field name, not to each column's data width. The separators therefore land in different columns within one record, and a short name with a wide value pushes its separator far to the right.

## Problem

Commit `6f496f5`.

The widths are computed per column over headers and values (`examples/psqlish/src/psqlish-display.adb:304-322`):

```ada
            for Index in 1 .. Count loop
               Widths (Index) := Length (Item.Columns.Element (Index).Name);
            end loop;
            for Value_Row of Item.Rows loop
               for Index in 1 .. Count loop
                  declare
                     Value : constant Cell := Value_Row.Values.Element (Index);
                     Text  : constant String := Cell_Text (Item, Value);
                  begin
                     Widths (Index) :=
                       Natural'Max (Widths (Index), Text'Length);
```

and the expanded renderer pads the name with the same array (`examples/psqlish/src/psqlish-display.adb:332-343`):

```ada
                  for Index in 1 .. Count loop
                     declare
                        Name  : constant String :=
                          To_String (Item.Columns.Element (Index).Name);
                        Value : constant String := Cell_Text
                          (Item, Item.Rows.Element (Row_Index).Values.Element
                             (Index));
                     begin
                        Line
                          (Name & Spaces (Widths (Index) - Name'Length)
                           & " | " & Value);
                     end;
                  end loop;
```

`psql` uses a single header width for the whole record. `print_aligned_vertical` computes `hwidth` as the maximum over all headers (`tests/.cache/postgres/18.4-openssl/source/src/fe_utils/print.c:1383-1393`):

```c
	/* Find the maximum dimensions for the headers */
	for (i = 0; i < cont->ncolumns; i++)
	{
		int			width,
					height,
					fs;

		pg_wcssize((const unsigned char *) cont->headers[i], strlen(cont->headers[i]),
				   encoding, &width, &height, &fs);
		if (width > hwidth)
			hwidth = width;
```

and pads every field name to that one value (`tests/.cache/postgres/18.4-openssl/source/src/fe_utils/print.c:1649-1671`):

```c
				int			swidth = hwidth,
							target_width = hwidth;
...
				swidth -= target_width;
				if (swidth > 0)
					fprintf(fout, "%*s", swidth, " ");
```

The psqlish README lists expanded output as a supported meta command (`examples/psqlish/README.md:89`):

```text
\x on|off          expanded output
```

The nested suite's expanded test uses a single column, so no cross-field alignment is ever compared (`examples/psqlish/tests/src/fixture_tests.adb:84-104`); it asserts only that the record header line appears and that display state survives between results.

## What happens now

Spike: the program renders one row of two columns, `n` with the value `7` and `value` with the value `alpha`, in expanded mode, then locates the separator in each of the two field lines and asserts that they are in the same column and that the short name is padded to the width of the longer name.

```ada
   Display.Set_Expanded (View, True);
   Display.Begin_Result
     (View,
      (Display.Make_Column ("n"), Display.Make_Column ("value")));
   Display.Add_Row
     (View, (Display.Text_Cell ("7"), Display.Text_Cell ("alpha")));
...
      Check (Name_Bar = Value_Bar,
             "the expanded separators align (n at" & Name_Bar'Image
             & ", value at" & Value_Bar'Image & ")");
      Check (Name_Line = "n     | 7",
             "psql renders the short name padded to the widest name");
```

```
  -- line 2: "n | 7"
  -- line 3: "value | alpha"
  ok: both expanded field lines carry a separator
  FAILED: the expanded separators align (n at 3, value at 7)
  FAILED: psql renders the short name padded to the widest name
BUG REPRODUCED: 2 failed expectation(s)
```

`psql` renders the same result as `n     | 7` and `value | alpha`, with both separators in column 7.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 client sources used for reference.

## What should happen

In expanded mode every field name should be padded to the width of the widest field name in the result, so all separators line up in one column, as `print_aligned_vertical` does (`tests/.cache/postgres/18.4-openssl/source/src/fe_utils/print.c:1383-1393`).

## Suggested treatment

Compute a separate name width for the expanded branch and use it instead of `Widths (Index)`. The maximum over `Item.Columns.Element (Index).Name` lengths is already available where `Widths` is seeded (`examples/psqlish/src/psqlish-display.adb:304-306`), so a single `Name_Width : Natural` accumulated in that loop and used at `examples/psqlish/src/psqlish-display.adb:341` is enough. The tabular branch keeps `Widths` unchanged.

The regression test belongs in `examples/psqlish/tests/src/fixture_tests.adb` beside the existing expanded-output assertions (`examples/psqlish/tests/src/fixture_tests.adb:84-92`), using two columns with different name lengths and comparing the separator positions. The spike is that test. No existing test asserts the current behaviour, so none has to change. The shell fixture that checks the test executable's output exactly (`examples/psqlish/tests/scripts/test.sh`) has to be updated with the new expected text.

## Severity

Cosmetic. Expanded output is harder to read because the separators wander from line to line inside one record, and a short field name with a wide value pushes its separator far to the right, but no value is lost, altered or mislabelled. It affects any expanded result with more than one column whose names differ in length. Deterministic.
