Title: pgish case-folds double-quoted identifiers and accepts any table or schema qualifier
Labels: bug
Refs: none

## Summary

`Pgish_Catalog.Base_Name` discards everything before the last `.` and lower-cases the remainder. It is the only name normaliser the catalog uses, so a double-quoted identifier that reached pgish with its case intact is folded away, and a qualifier that names no table or schema is dropped instead of being checked. `SELECT "PROTOCOL_VERSION" FROM flyology_server_info` succeeds and returns a column labelled `protocol_version` where PostgreSQL raises 42703, and `SELECT * FROM bogus_schema.flyology_tables` succeeds where the README says tables live only under one synthetic schema.

## Problem

Commit `6f496f5`.

The single normaliser (`examples/pgish/src/pgish_catalog.adb:92-98`):

```ada
   function Base_Name (Name : String) return String is
      Dot : constant Natural := Ada.Strings.Fixed.Index
        (Name, ".", Going => Ada.Strings.Backward);
   begin
      return To_Lower
        ((if Dot = 0 then Name else Name (Dot + 1 .. Name'Last)));
   end Base_Name;
```

Column lookup goes through it and lower-cases the candidate as well (`examples/pgish/src/pgish_catalog.adb:100-109`):

```ada
   function Find_Column (Result : Result_Set; Name : String) return Natural is
      Wanted : constant String := Base_Name (Name);
   begin
      for Index in 1 .. Result.Column_Count loop
         if To_Lower (SQL.Image (Result.Columns (Index).Name)) = Wanted then
```

Table lookup goes through it too (`examples/pgish/src/pgish_catalog.adb:412-419`):

```ada
   procedure Load_Source
     (Context : in out State.Server_State;
      Name         : String;
      Result       : out Result_Set) is
      Base : constant String := Base_Name (Name);
   begin
      Result := (others => <>);
      if Base = "flyology_server_info" then Add_Server_Info (Context, Result);
```

so any qualifier at all resolves, and the output column name is produced by the same function (`examples/pgish/src/pgish_catalog.adb:531`):

```ada
               when SQL.Column_Projection => Name := T (Base_Name (SQL.Image (Projection.Name)));
```

PostgreSQL's scanner folds only unquoted identifiers. A delimited identifier is returned as written (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:799-809`):

```
<xd>{xdstop}	{
					char	   *ident;

					BEGIN(INITIAL);
					if (yyextra->literallen == 0)
						yyerror("zero-length delimited identifier");
					ident = litbufdup(yyscanner);
```

while an unquoted one is lower-cased (`sql/backends/v18/vendor/native_source/backend/parser/scan.l:1088-1094`):

```
					/*
					 * No.  Convert the identifier to lower case, and truncate
					 * if necessary.
					 */
					ident = downcase_truncate_identifier(yytext, yyleng, true);
```

So `"PROTOCOL_VERSION"` and `protocol_version` are different identifiers, and PostgreSQL answers the first with ERRCODE_UNDEFINED_COLUMN, 42703 (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/errcodes.txt:368`). A qualifier that names no visible relation is likewise an error, raised by `errorMissingRTE` with ERRCODE_UNDEFINED_TABLE, 42P01 (`tests/.cache/postgres/18.4-openssl/source/src/backend/parser/parse_relation.c:3756-3761`):

```c
	else
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_TABLE),
				 errmsg("missing FROM-clause entry for table \"%s\"",
						relation->relname),
```

The pgish README states the folding rule it does not implement (`examples/pgish/README.md:82`):

> Identifiers are case-insensitive unless double quoted.

and bounds the accepted schemas (`examples/pgish/README.md:102-103`):

> All data is read-only. Tables may be named directly or under the synthetic `flyology` schema.

The suite's one quoted-identifier test uses all-lower-case names, so folding is invisible (`examples/pgish/src/pgish_tests.adb:63-69`), and its assertion is on the parse result, not on execution. No test names a schema other than `flyology`, and no test uses a column qualifier.

## What happens now

Spike: the program confirms that unquoted identifiers fold, as documented, then submits four statements PostgreSQL rejects and asserts that each is rejected: an upper-case quoted column, an upper-case quoted table, an unknown column qualifier, and an unknown schema qualifier.

```ada
   --  Baseline: unquoted identifiers are case-insensitive, as documented.
   Catalog.Execute
     (Context, Session,
      SQL.Parse ("SELECT PROTOCOL_VERSION FROM FLYOLOGY_SERVER_INFO"), Result);
   ...
   --  PostgreSQL: 42703, column "PROTOCOL_VERSION" does not exist.
   Expect_Rejected
     ("SELECT ""PROTOCOL_VERSION"" FROM flyology_server_info",
      "a double-quoted upper-case column name is case sensitive");
   ...
   --  README: tables are named directly or under the flyology schema only.
   Expect_Rejected
     ("SELECT * FROM bogus_schema.flyology_tables",
      "an unknown schema qualifier is rejected");
```

```
  ok: unquoted identifiers are case-insensitive
  -- a double-quoted upper-case column name is case sensitive: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: a double-quoted upper-case column name is case sensitive
  -- a double-quoted upper-case table name is case sensitive: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: a double-quoted upper-case table name is case sensitive
  -- an unknown column qualifier is rejected: accepted,  1 column(s) named "protocol_version", 1 row(s)
  FAILED: an unknown column qualifier is rejected
  -- an unknown schema qualifier is rejected: accepted,  3 column(s) named "table_schema", 8 row(s)
  FAILED: an unknown schema qualifier is rejected
BUG REPRODUCED: 4 failed expectation(s)
```

The control confirms the documented half of the rule works, so the failures are the quoting exception and the missing qualifier check, not identifier handling in general. The reported output column name shows the folding: the quoted upper-case request comes back labelled `protocol_version`.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18 scanner and 18.4 server sources used for reference.

## What should happen

A double-quoted identifier keeps its case, as `scan.l:799-809` shows and as the README states, so `"PROTOCOL_VERSION"` should be reported as an undefined column and `"FLYOLOGY_SERVER_INFO"` as an undefined table. A qualifier that names no known table or schema should be rejected rather than discarded, so `nowhere.protocol_version` and `bogus_schema.flyology_tables` should both produce an ErrorResponse.

## Suggested treatment

Two separate changes are needed, and the first depends on information the catalog does not currently receive.

For quoting, the lowering in `Pgish_SQL` has to record whether an identifier arrived quoted, and `Base_Name` has to fold only unquoted ones. The owned AST node the lowering reads carries the identifier after the scanner has folded it, so the quoted and unquoted spellings are distinguishable only if the lowering preserves that fact. This needs a maintainer decision, because carrying it means adding a field to the public projection and predicate records in `examples/pgish/src/pgish_sql.ads`. The options are to add a quoted flag to those records, to make the catalog reject any identifier that is not already lower case, or to change the README sentence to say identifiers are always case-insensitive.

For qualifiers, `Base_Name` should not be the only check. `Load_Source` (`examples/pgish/src/pgish_catalog.adb:412-434`) should verify that a table qualifier, when present, is `flyology`, and `Find_Column` (`examples/pgish/src/pgish_catalog.adb:100-109`) should verify that a column qualifier, when present, names the query's table. Both raise the exceptions the handler already maps to 42P01 and 42703.

The regression test belongs in `examples/pgish/src/pgish_tests.adb` beside the existing quoted-identifier parse test (`examples/pgish/src/pgish_tests.adb:63-69`), asserting rejection for an upper-case quoted name and for a bogus schema. The spike is that test. No existing test asserts the current behaviour, so none has to change.

## Severity

pgish accepts statements PostgreSQL rejects and answers them from the wrong identifier, so a client that quotes to disambiguate gets a silent success, and a client that mistypes a schema gets rows from the table it did not name. No correctly written query returns a wrong value, and reaching any of it needs an upper-case quoted identifier or a bogus qualifier, which is not what an ordinary query contains. Deterministic.
