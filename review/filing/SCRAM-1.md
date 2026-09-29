Title: SCRAM server answers every role without a verifier using one fixed salt published in the library source
Labels: bug
Refs: none

## Summary

When the application's `Lookup_SCRAM_Verifier` returns the empty string, the server parses a constant dummy verifier compiled into `src/flyology-postgres-server.adb` and sends that constant's salt and iteration count in `AuthenticationSASLContinue`. The salt is the base64 form of the ASCII octets `fixed dummy salt`, the same for every role without a credential and published in the library's own source. An unauthenticated client therefore learns whether a startup role exists from the server's second message, before sending any proof and without producing an authentication failure. PostgreSQL avoids exactly this by deriving a per-role mock salt from a cluster secret.

## Problem

Commit `6f496f5`.

The constant (`src/flyology-postgres-server.adb:28-35`):

```ada
--  Precomputed from a non-secret dummy password and salt. Keep this as
--  verifier text so known and unknown users take the same per-attempt
--  Parse_Verifier and constant-time proof-verification path without
--  attacker-controlled PBKDF2 work on the server.
Dummy_SCRAM_Verifier : constant String :=
  "SCRAM-SHA-256$4096:Zml4ZWQgZHVtbXkgc2FsdA==$"
  & "6noiwI8hQdf8Z+HCRIbshx1qqrjQPi1wyxZ1+7fQdIM=:"
  & "KctKYif+hWsn2f75oSuDVm9zGdZUQ4iWXqV1PDhONRs=";
```

`Zml4ZWQgZHVtbXkgc2FsdA==` decodes to the 16 octets `fixed dummy salt`, and this declaration is the only occurrence of that text in the repository.

`Admit` (`src/flyology-postgres-server.adb:257`) substitutes the constant whenever the callback returns nothing (`src/flyology-postgres-server.adb:286-295`):

```ada
when SCRAM_SHA_256 =>
   declare
      Supplied : constant String :=
        Lookup_SCRAM_Verifier (Context, Startup);
      Has_Credential : constant Boolean := Supplied'Length > 0;
      Credential : constant Flyology.Postgres.SCRAM.Verifier :=
        Flyology.Postgres.SCRAM.Parse_Verifier
          ((if Has_Credential
            then Supplied
            else Dummy_SCRAM_Verifier));
```

That credential is handed to `Server_First_Message` (`src/flyology-postgres-server.adb:317-319`), which emits the salt and the iteration count verbatim (`src/flyology-postgres-scram.adb:439-448`):

```ada
return "r=" & Combined_Nonce
  & ",s=" & To_String (Credential.Encoded_Salt)
  & ",i=" & Positive'Image (Credential.Iteration_Count)
    (2 .. Positive'Image (Credential.Iteration_Count)'Last);
```

The constant salt therefore reaches the wire in `AuthenticationSASLContinue`, which the server sends after receiving only the startup message and the client-first message.

PostgreSQL does not do this. When the role has no usable secret, `scram_init` builds a mock one and records why (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:313-326`):

```c
	/*
	 * If the user did not have a valid SCRAM secret, we still go through the
	 * motions with a mock one, and fail as if the client supplied an
	 * incorrect password.  This is to avoid revealing information to an
	 * attacker.
	 */
	if (!got_secret)
	{
		mock_scram_secret(state->port->user_name, &state->hash_type,
						  &state->iterations, &state->key_length,
						  &state->salt,
						  state->StoredKey, state->ServerKey);
```

`mock_scram_secret` takes the salt from `scram_mock_salt` (`auth-scram.c:703`), which hashes the role name together with the per-cluster mock authentication nonce (`auth-scram.c:1465-1484`):

```c
	/*
	 * Generate salt using a SHA256 hash of the username and the cluster's
	 * mock authentication nonce.  (This works as long as the salt length is
	 * not larger than the SHA256 digest length.  If the salt is smaller, the
	 * caller will just ignore the extra data.)
	 */
	...
	ctx = pg_cryptohash_create(hash_type);
	if (pg_cryptohash_init(ctx) < 0 ||
		pg_cryptohash_update(ctx, (uint8 *) username, strlen(username)) < 0 ||
		pg_cryptohash_update(ctx, (uint8 *) mock_auth_nonce, MOCK_AUTH_NONCE_LEN) < 0 ||
```

Two unknown roles therefore receive two different salts on PostgreSQL, and neither is predictable by a client that does not know the cluster nonce.

The existing callback cannot be used as a workaround. `Has_Credential` is derived from the returned string being non-empty (`src/flyology-postgres-server.adb:290`) and is the only thing that distinguishes a real role from a mock one after the proof check (`src/flyology-postgres-server.adb:342`):

```ada
if not Proof_Valid or else not Has_Credential then
```

An application that returns its own per-role mock verifier to vary the salt sets `Has_Credential`, so any client whose proof matches that mock verifier is admitted. There is no supported hook that changes the mock salt alone.

The existing coverage does not look at the salt. The generic-server test returns a verifier for its own role and `""` for everything else (`tests/src/postgres_test_server.adb:42-50`), and the integration script only checks that an unknown role is ultimately rejected (`tests/scripts/run-integration.sh:189-198`).

## What happens now

Spike: a `Flyology.Postgres.Server` instantiated with `Authentication => SCRAM_SHA_256` and a `Lookup_SCRAM_Verifier` that returns a real verifier only for the role `known`, listening on loopback. The program runs three raw-socket SCRAM exchanges for the roles `unknown-a`, `unknown-b` and `known`, records the `s=` and `i=` attributes of each `AuthenticationSASLContinue`, and asserts that two roles without a verifier get different salts and that neither gets the constant published in the library source.

```ada
function Lookup_SCRAM_Verifier
  (State   : in out Context;
   Startup : Protocol.Startup_Information) return String is
begin
   State.Lookups := State.Lookups + 1;
   if To_String (Startup.User) = Known_Role then
      return SCRAM.Make_Verifier_Raw
        ("secret", SCRAM.To_Bytes (Known_Salt_Text));
   else
      return "";
   end if;
end Lookup_SCRAM_Verifier;

Published_Dummy_Salt : constant String := "Zml4ZWQgZHVtbXkgc2FsdA==";

Check
  (To_String (Salt_A) /= To_String (Salt_B),
   "two different roles with no SCRAM verifier receive different salts ...");
Check
  (To_String (Salt_A) /= Published_Dummy_Salt,
   "a role with no SCRAM verifier does not receive the fixed salt "
   & "published in this library's own source");
```

Output, exit status 1:

```
  -- listening on 127.0.0.1: 63717
  -- unknown-a: server-first = r=rOprNGfwEbeRWgbNEkqOeezQvMi1l4Ra3PBah2Vhliuy,s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096
  -- unknown-a: final backend message tag 'E'
  -- unknown-b: server-first = r=rOprNGfwEbeRWgbNEkqOawLDxXalHc5g2ho7WtPyscVm,s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096
  -- unknown-b: final backend message tag 'E'
  -- known: server-first = r=rOprNGfwEbeRWgbNEkqOkKD68V6ptFOoJqg0WmV/LqcL,s=Rmx5b2xvZ3kgdGVzdCBzYWx0,i=4096
  -- known: final backend message tag 'E'
  -- unknown-a: s=Zml4ZWQgZHVtbXkgc2FsdA== i=4096
  -- unknown-b: s=Zml4ZWQgZHVtbXkgc2FsdA== i=4096
  -- known:     s=Rmx5b2xvZ3kgdGVzdCBzYWx0 i=4096
  -- base64 of the library's dummy salt is "Zml4ZWQgZHVtbXkgc2FsdA==", i.e. the ASCII octets "fixed dummy salt"
  ok: control: all three roles complete a server-first exchange (harness sanity check)
  FAILED: two different roles with no SCRAM verifier receive different salts (PostgreSQL derives the mock salt per role with scram_mock_salt from the cluster's mock_authentication_nonce)
  FAILED: a role with no SCRAM verifier does not receive the fixed salt published in this library's own source
BUG REPRODUCED: 2 failed expectation(s)
```

The nonces differ on every connection because they are freshly random, so the salt is the whole distinguisher. The two unknown roles receive byte-identical `s=` and `i=` values, and the known role receives its own salt.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A role with no SCRAM verifier should receive a salt that is specific to that role and unpredictable to the client, so that the `AuthenticationSASLContinue` message carries no information about whether the role exists. This is what PostgreSQL's `mock_scram_secret` and `scram_mock_salt` provide (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:683-723`, `:1457-1492`), and the stated purpose of the upstream mechanism is to avoid revealing information to an attacker (`auth-scram.c:313-318`).

## Suggested treatment

Replace the fixed dummy salt with a per-role derived one: hash the startup role name together with a server-lifetime secret nonce, take the leading bytes as the salt, and build the mock verifier from that salt with the iteration count the real path would use. The rest of the current design can stay: the mock stays verifier text, so both paths run the same `Parse_Verifier` and constant-time proof check, and `Has_Credential` still decides admission at `src/flyology-postgres-server.adb:342`.

This needs a maintainer decision, because the mock scheme is externally visible and the nonce is new state:

- generate the secret nonce inside the server object when it is created, so it is per-process and changes on restart, closer to a random per-run mock than to PostgreSQL's per-cluster nonce;
- take the nonce as a new generic formal or a `Server` discriminant supplied by the application, so a cluster of processes can present a stable mock like PostgreSQL does;
- extend the credential callback so the application can return a mock verifier and a separate existence flag, which would also remove the coupling that makes any non-empty return set `Has_Credential`.

The spike is the regression test, and it belongs with the existing generic-server coverage in `tests/src/postgres_test_server.adb`. One existing check depends on the constant and must change: `tests/scripts/run-integration.sh:189-198` passes `PGPASSWORD='Flyology invalid SCRAM credential'` precisely so that the client proof is valid for the static dummy verifier, and its comment says so. Once the mock salt varies per role, that password no longer produces a valid proof, so the check stops exercising the "proof valid, role unknown" path and needs rewriting against whichever mock scheme is chosen.

## Severity

Any client that can open a connection can enumerate roles before authenticating: it sends a startup message and a client-first message, reads `AuthenticationSASLContinue`, and compares the salt against a constant that is public in this library's source. No authentication failure is logged for the role, because the client can abandon the exchange after the server-first message. This is the behaviour of a default `Authentication => SCRAM_SHA_256` server whose credential callback returns `""` for unknown roles, which is the documented way to report a missing credential (`src/flyology-postgres-server.ads:22-25`). No secret is exposed and a role without a verifier is still refused. Deterministic.
