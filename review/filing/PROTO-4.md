Title: Startup replication values are matched case-sensitively, rejecting spellings PostgreSQL accepts
Labels: bug
Refs: SERVER-1

## Summary

`Decode_Initial` matches the startup `replication` parameter against a closed set of lowercase literals and raises `Protocol_Error` for anything else. PostgreSQL compares the value against `database` and otherwise calls `parse_bool`, which is case-insensitive and accepts unique prefixes, so `TRUE`, `True`, `t`, `On`, `Yes`, `f` and `Off` are all valid replication requests to a real backend and are rejected here. Because the rejection happens while initialising a declared object in `Run_Session`, the exception escapes that subprogram's own handler, so the client sees an unexplained disconnect rather than the FATAL ErrorResponse a later protocol error would produce.

## Problem

Commit `6f496f5`.

The closed literal set (`src/flyology-postgres-protocol.adb:1190-1203`):

```ada
                     if Name = "replication" then
                        if Value = "database" then
                           Result.Startup.Replication_Mode :=
                             Logical_Replication_Connection;
                        elsif Value in "true" | "on" | "yes" | "1" then
                           Result.Startup.Replication_Mode :=
                             Physical_Replication_Connection;
                        elsif Value not in
                          "false" | "off" | "no" | "0"
                        then
                           raise Protocol_Error with
                             "invalid startup replication mode";
                        end if;
                     end if;
```

Ada's `=` and `in` on `String` are case-sensitive, and no normalisation or prefix matching happens anywhere on this path.

The backend rule this deviates from, in `ProcessStartupPacket` (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:771-791`):

```c
			else if (strcmp(nameptr, "replication") == 0)
			{
				...
				if (strcmp(valptr, "database") == 0)
				{
					am_walsender = true;
					am_db_walsender = true;
				}
				else if (!parse_bool(valptr, &am_walsender))
					ereport(FATAL,
```

`parse_bool` delegates to `parse_bool_with_len`, which is documented as accepting unique prefixes and implemented with `pg_strncasecmp` (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/adt/bool.c:25-26` and `:40-53`):

```c
 * Try to interpret value as boolean value.  Valid values are: true,
 * false, yes, no, on, off, 1, 0; as well as unique prefixes thereof.
...
	switch (*value)
	{
		case 't':
		case 'T':
			if (pg_strncasecmp(value, "true", len) == 0)
```

The consequence for the server is that no diagnosis reaches the client. `replication` rides on the first startup packet, and the first `Read_Initial` is the initialiser of a declared object in `Run_Session`'s declarative part (`src/flyology-postgres-server.adb:371-372`):

```ada
      Initial : Protocol.Initial_Request :=
        Server_Sessions.Read_Initial (Client, Startup_Timeout);
```

An exception raised there propagates past that subprogram's own handled sequence of statements, so the `Protocol_Error` handler that would send the FATAL ErrorResponse never runs (`src/flyology-postgres-server.adb:524-532`):

```ada
   exception
      when Error : Protocol.Protocol_Error =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "08P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
```

The second `Read_Initial`, inside the loop body at `:403`, is covered. This is the same escaping-handler mechanism reported separately in {{ISSUE:SERVER-1}}; that issue covers the escape itself, and this one covers the input that should not have been rejected in the first place.

No test covers it. The decoder tests build startup packets with lowercase values only, so the case-sensitive branch is never exercised with a spelling a real backend would accept.

## What happens now

Spike: startup packet contents are built for each `replication` spelling and decoded through `Decode_Initial`. The program asserts the mode PostgreSQL's `parse_bool` would produce for each value. The three lowercase spellings this decoder does accept are included as controls.

```ada
      Protocol.Append_U32 (Contents, Version_3_0);
      Protocol.Append_C_String (Contents, "user");
      Protocol.Append_C_String (Contents, "alice");
      Protocol.Append_C_String (Contents, "replication");
      Protocol.Append_C_String (Contents, Replication);
      Protocol.Append_Byte (Contents, 0);
...
         Actual :=
           Protocol.Startup_Data
             (Protocol.Decode_Initial (Startup_Contents (Value))).
               Replication_Mode;
...
   Expect ("TRUE", Protocol.Physical_Replication_Connection);
   Expect ("True", Protocol.Physical_Replication_Connection);
   Expect ("t", Protocol.Physical_Replication_Connection);
   Expect ("On", Protocol.Physical_Replication_Connection);
   Expect ("Yes", Protocol.Physical_Replication_Connection);
   Expect ("f", Protocol.Normal_Connection);
   Expect ("Off", Protocol.Normal_Connection);
```

```
  -- PostgreSQL matches `replication` with strcmp against "database" and otherwise parse_bool, which is case-insensitive and
  -- accepts unique prefixes: t, tr, tru, true, y, ye, yes, on, 1 and f, fa, fal, fals, false, n, no, of, off, 0.
  -- replication="true" -> PHYSICAL_REPLICATION_CONNECTION
  ok: replication="true" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="database" -> LOGICAL_REPLICATION_CONNECTION
  ok: replication="database" decodes as LOGICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="false" -> NORMAL_CONNECTION
  ok: replication="false" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="TRUE" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="TRUE" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="True" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="True" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="t" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="t" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="On" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="On" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="Yes" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="Yes" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="f" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="f" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="Off" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="Off" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
BUG REPRODUCED: 7 failed expectation(s)
```

The three lowercase controls pass, isolating the defect to case and prefix handling rather than to the packet the spike builds.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A startup packet whose `replication` value a real PostgreSQL backend accepts should be accepted here with the same meaning: `database` for logical replication, and otherwise whatever `parse_bool` yields, matched case-insensitively and admitting unique prefixes (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/adt/bool.c:25-26`).

## Suggested treatment

Replace the literal comparisons at `src/flyology-postgres-protocol.adb:1190-1203` with a helper that mirrors `parse_bool_with_len`: compare `Value` against `"database"` exactly, then case-fold and prefix-match against `true`, `false`, `yes`, `no`, `on`, `off`, `1` and `0`, with the `on`/`off` disambiguation `parse_bool_with_len` performs at `bool.c:81-92` (a bare `o` is not unique) and the exact-length requirement for `1` and `0` at `:94-107`.

How much of that grammar to accept is a compatibility-policy decision, not a mechanical fix. Accepting the full `parse_bool` grammar means this decoder admits inputs no shipping client sends by default, in exchange for matching the backend exactly. Accepting only case-insensitive full words is a smaller change that still rejects `t`, `f` and the other prefixes a real backend accepts. That choice belongs to the maintainer.

The regression test belongs in `tests/src/tests.adb` beside `Test_Startup` (`tests/src/tests.adb:265-277`), covering the accepted spellings and at least one genuinely invalid value that must still raise; the spike is the test. No existing test asserts the current rejection, so none has to change.

## Severity

A client that writes `replication=TRUE`, or a prefix such as `t`, in a conninfo string or URI is disconnected without explanation, where a real PostgreSQL server would accept the connection. Mainstream tools are not affected by default: `pg_basebackup`, `pg_receivewal` and the walreceiver send lowercase `true` or `database`, all of which are accepted here. The spelling has to come from a user-written conninfo string, which libpq passes through verbatim, so this needs an unusual but entirely legal input. The missing FATAL ErrorResponse makes the failure hard to diagnose from the client side. Deterministic.
