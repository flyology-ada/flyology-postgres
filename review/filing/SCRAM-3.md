Title: Parsing refuses SCRAM iteration counts below 4096, locking out PostgreSQL roles with a lower scram_iterations
Labels: bug
Refs: none

## Summary

`Minimum_Iterations` and `Maximum_Iterations` are enforced when parsing a peer's values, not only when generating a verifier. A client connecting to a PostgreSQL 16 or later server whose role secret was created under `scram_iterations = 1000` receives `i=1000` in `AuthenticationSASLContinue` and fails with `Protocol.Protocol_Error`, where psql authenticates normally. A server built on this library refuses the same stored verifier in `Parse_Verifier` before it sends `AuthenticationSASL`. The two bounds are visible constants in the specification whose comments document this behaviour, so the range itself is a maintainer decision, and what is reported here is the interop consequence.

## Problem

Commit `6f496f5`.

The bounds are public, and their comments state that they apply to what is accepted (`src/flyology-postgres-scram.ads:13-16`):

```ada
Minimum_Iterations : constant := 4_096;
--  Smallest verifier iteration count accepted or generated.
Maximum_Iterations : constant := 1_000_000;
--  Largest verifier iteration count accepted, bounding authentication work.
```

`Parse_Positive` applies them (`src/flyology-postgres-scram.adb:174-176`):

```ada
if Result < Minimum_Iterations or else Result > Maximum_Iterations then
   Fail ("SCRAM iteration count is outside the supported range");
end if;
```

and it is used on both roles: by `Parse_Verifier` on a stored rolpassword (`src/flyology-postgres-scram.adb:209-210`) and by `Parse_Server_First` on the value the server sends (`src/flyology-postgres-scram.adb:483`). `Make_Verifier_Raw` applies the same bounds to its own parameter (`src/flyology-postgres-scram.adb:236-241`), which is the generation case the specification comment describes.

On the client path the failure is not reported as an authentication problem. `Complete_Startup` turns every `SCRAM_Error` into a protocol error (`src/flyology-postgres-client.adb:375-379`):

```ada
when Error : Flyology.Postgres.SCRAM.SCRAM_Error =>
   Flyology.Postgres.SCRAM_Core.Wipe
     (Expected_Server_Signature);
   raise Protocol.Protocol_Error with
     Ada.Exceptions.Exception_Message (Error);
```

PostgreSQL permits the counts this library refuses. The `scram_iterations` setting added in PostgreSQL 16 has a minimum of 1 and a maximum of `INT_MAX` (`tests/.cache/postgres/17.10-openssl/source/src/backend/utils/misc/guc_tables.c:3654-3663`):

```c
	{
		{"scram_iterations", PGC_USERSET, CONN_AUTH_AUTH,
			gettext_noop("Sets the iteration count for SCRAM secret generation."),
			NULL,
			GUC_REPORT
		},
		&scram_sha_256_iterations,
		SCRAM_SHA_256_DEFAULT_ITERATIONS, 1, INT_MAX,
```

A role whose password is set while it is lowered stores `SCRAM-SHA-256$<N>:...`, and the backend imposes no floor when reading it back (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:628-631`):

```c
	errno = 0;
	*iterations = strtol(iterations_str, &p, 10);
	if (*p || errno != 0)
		goto invalid_secret;
```

libpq accepts any count that parses and is at least 1 (`tests/.cache/postgres/17.10-openssl/source/src/interfaces/libpq/fe-auth-scram.c:671-676`):

```c
	state->iterations = strtol(iterations_str, &endptr, 10);
	if (*endptr != '\0' || state->iterations < 1)
	{
		libpq_append_conn_error(conn, "malformed SCRAM message (invalid iteration count)");
		return false;
	}
```

RFC 5802 recommends an iteration count of at least 4096 in its description of the `i` attribute, and RFC 7677 repeats that recommendation for SCRAM-SHA-256. Both address the party choosing the count. Neither obliges a peer to refuse a lower one.

The upper bound has the same shape. A count of 2000000 is inside what PostgreSQL 16 and later allow and is refused here, with the message coming from the overflow guard at `src/flyology-postgres-scram.adb:165-171` rather than from the range check.

No test covers a count other than 4096. The RFC 7677 vectors use 4096 (`tests/src/tests.adb:2459-2510`), the failure tests build their fixtures through `Make_Verifier_Raw`, whose default is `Minimum_Iterations` (`src/flyology-postgres-scram.adb:232-235`), and the only malformed verifier asserted in `tests/src/tests.adb:2595-2607` carries `4096`.

## What happens now

Spike: three checks plus one informational probe. It builds a genuine PostgreSQL rolpassword with PBKDF2 at 1000 iterations and parses it as a server would; it calls `Client_Final_Message` against a server-first message carrying `i=1000`; and it drives the public `Client.Startup` over a scripted transport that plays a PostgreSQL server sending `AuthenticationSASL` and then `AuthenticationSASLContinue` with `i=1000` and a nonce extending the client's own. Each check asserts the libpq-compatible outcome.

```ada
Low_Iterations : constant := 1_000;

Parsed : constant SCRAM.Verifier := SCRAM.Parse_Verifier (Text);

Server_First : constant String :=
  "r=" & Combined_Nonce & ",s=" & Encoded_Salt & ",i="
  & Ada.Strings.Fixed.Trim
      (Integer'Image (Low_Iterations), Ada.Strings.Both);
Final : constant String :=
  SCRAM.Client_Final_Message
    (Password, Bare, Server_First, Client_Nonce, Signature);

Client.Startup
  (Session,
   User     => "flyology",
   Database => "postgres",
   Password => Password,
   Timeout  => 5.0);
```

Output, exit status 1:

```
  -- verifier under test: SCRAM-SHA-256$1000:W22ZaJ0SNY7soEsUEjb6gQ==$A7Cm0NrG3AFMNXYvoYKO3pDoaPPmqMJvmB38BNQzecg=:kyhP+VzX9vuGpnNS4by3UyHkedgzBWv0ceFzKMuu+74=
  -- Parse_Verifier raised SCRAM_Error: SCRAM iteration count is outside the supported range
  -- server-first under test: r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000
  -- Client_Final_Message raised SCRAM_Error: SCRAM iteration count is outside the supported range
  -- scripted server-first: r=8+97b3wV4tGbVbG2CNWcNs4+0123456789abcdef01234567,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000
  -- Client.Startup raised FLYOLOGY.POSTGRES.PROTOCOL.PROTOCOL_ERROR: SCRAM iteration count is outside the supported range
  -- informational: i=2000000 (allowed by PostgreSQL 16+, whose scram_iterations maximum is INT_MAX) raised SCRAM_Error: invalid SCRAM iteration count
  FAILED: a PostgreSQL rolpassword stored with scram_iterations = 1000 parses (the backend's parse_scram_secret imposes no 4096 floor)
  FAILED: a server-first challenge carrying i=1000 is answered with a client proof (libpq's read_server_first_message accepts any count >= 1)
  FAILED: Client.Startup against a server offering i=1000 sends its client-final proof instead of failing with Protocol_Error
BUG REPRODUCED: 3 failed expectation(s)
```

The third line is the one that reaches a caller: the failure arrives through the documented public API `Flyology.Postgres.Client.Startup` and surfaces as `Protocol_Error`, not as an authentication failure, so an application cannot tell it apart from a broken server.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A count chosen by the peer should either be accepted as libpq accepts it (`tests/.cache/postgres/17.10-openssl/source/src/interfaces/libpq/fe-auth-scram.c:671-676`), or the range should be documented as a deliberate interop limit so that a caller knows why a PostgreSQL 16 or later cluster with a lowered `scram_iterations` is unreachable. RFC 5802 and RFC 7677 make 4096 a recommendation to the party generating the verifier, not an obligation on the peer reading it.

## Suggested treatment

This needs a maintainer decision. `Minimum_Iterations` and `Maximum_Iterations` are visible constants in `src/flyology-postgres-scram.ads:13-16` and their comments document the current behaviour, so changing either value, or splitting the parse check from the generation check, changes a published interface value. The options are:

- accept any count of at least 1 when parsing, as libpq does, and keep `Minimum_Iterations` as the floor for `Make_Verifier_Raw` only, which means moving the range test out of `Parse_Positive` (`src/flyology-postgres-scram.adb:174-176`) and leaving the check at `src/flyology-postgres-scram.adb:236-241` in place;
- widen the accepted range so that it covers what PostgreSQL 16 and later permit, keeping a bound on authentication work;
- keep the range as it is and document the incompatibility, stating in `src/flyology-postgres-scram.ads:13-16` and the user-facing documentation that a PostgreSQL 16 or later cluster or role configured with `scram_iterations` below 4096 cannot be used.

If the first or second option is chosen, the spike is the regression test and belongs beside the SCRAM cases in `tests/src/tests.adb:2512`, with a verifier and a server-first message carrying a count below 4096. No existing test asserts the current rejection, so none has to change.

## Severity

A PostgreSQL 16 or later server, or a single role, configured with `scram_iterations` below 4096 cannot be authenticated against: `Client.Startup` raises `Protocol.Protocol_Error` before the client sends its proof, and the caller sees a protocol failure rather than an authentication failure. In the server role, a stored verifier with such a count is refused by `Parse_Verifier` before `AuthenticationSASL` is sent, so the connection fails at the protocol level as well. It needs a non-default cluster or role configuration, and the counts above 1_000_000 that PostgreSQL also permits are refused the same way. Deterministic; not reproduced against a live server.
