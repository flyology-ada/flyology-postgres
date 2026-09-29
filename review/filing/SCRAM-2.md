Title: Optional SCRAM extension attributes are rejected in client-first, client-final and server-final messages
Labels: bug
Refs: none

## Summary

RFC 5802 allows an optional list of extension attributes at the end of `client-first-message-bare`, `client-final-message-without-proof` and `server-final-message`, and requires unrecognized attributes to be ignored. This library raises `SCRAM_Error` at all three places: the server role refuses a client-first message with a trailing attribute and refuses a client-final message whose attribute after the nonce is not the proof, and the client role feeds a trailing attribute in the server-final message into base64 decoding. A peer that emits a conforming extension is answered with a protocol error rather than being authenticated, and a valid server signature is reported as invalid base64.

## Problem

Commit `6f496f5`.

RFC 5802 Section 7 defines `extensions = attr-val *("," attr-val)` and carries the comment that all extensions are optional, so unrecognized attributes not defined in that document MUST be ignored. The same section places `["," extensions]` at the end of `client-first-message-bare`, `client-final-message-without-proof` and `server-final-message`. RFC 7677 inherits that grammar for SCRAM-SHA-256. The reserved mandatory-extension attribute `m=` must still be rejected, and this report does not ask for that to change.

PostgreSQL quotes the same grammar in its own source when it builds the server-final message (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:1440-1444`).

### Client-first message, server role

`Parse_Client_First` fails as soon as anything follows the nonce (`src/flyology-postgres-scram.adb:399-401`):

```ada
if Cursor <= Bare_Text'Last then
   Fail ("malformed SCRAM client-first-message");
end if;
```

PostgreSQL consumes and discards whatever follows (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:1098-1103`):

```c
	/*
	 * There can be any number of optional extensions after this.  We don't
	 * support any extensions, so ignore them.
	 */
	while (*p != '\0')
		read_any_attr(&p, NULL);
```

### Client-final message, server role

`Verify_Client_Final` requires the token after the nonce to be the proof (`src/flyology-postgres-scram.adb:585-591`):

```ada
C : constant String := Attribute_Value
  (Next_Token (Client_Final, Cursor), 'c');
R : constant String := Attribute_Value
  (Next_Token (Client_Final, Cursor), 'r');
P_Token : constant String := Next_Token (Client_Final, Cursor);
P : constant String := Attribute_Value (P_Token, 'p');
Proof_Data : constant Byte_Array := Base64_Decode (P);
```

With an extension between `r=` and `p=`, the third `Next_Token` returns the extension and `Attribute_Value (P_Token, 'p')` at `src/flyology-postgres-scram.adb:590` fails first, with `malformed SCRAM attribute; expected p` (`src/flyology-postgres-scram.adb:341-343`). The composite check at `:593-597` never runs.

PostgreSQL reads attributes until it reaches `p` (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:1364-1371`):

```c
	state->client_final_nonce = read_attr_value(&p, 'r');

	/* ignore optional extensions, read until we find "p" attribute */
	do
	{
		proof = p - 1;
		value = read_any_attr(&p, &attr);
	} while (attr != 'p');
```

and then keeps everything before the proof as `client_final_message_without_proof` (`auth-scram.c:1390-1392`), extensions included. This library's slice at `src/flyology-postgres-scram.adb:600-601` would produce the same text if parsing did not fail first:

```ada
Final_Without_Proof : constant String :=
  Client_Final (Client_Final'First .. P_Token'First - 2);
```

The separate rejection of trailing data after the proof (`src/flyology-postgres-scram.adb:594`) matches PostgreSQL (`auth-scram.c:1384-1388`) and is correct.

### Server-final message, client role

`Verify_Server_Final` calls `Attribute_Value` on the whole message rather than on a token (`src/flyology-postgres-scram.adb:554-555`):

```ada
Signature_Text : constant String := Attribute_Value (Message, 'v');
Signature : constant Byte_Array := Base64_Decode (Signature_Text);
```

`Attribute_Value` returns everything after the two-character prefix (`src/flyology-postgres-scram.adb:345`), so a trailing `,x=1` becomes part of the base64 text and decoding fails before the signature is compared.

Of the three, the two server-role cases are demonstrated divergences from PostgreSQL's own server: `read_client_first_message` discards trailing attributes and `read_client_final_message` reads past them to the proof. The client-role case rests on RFC 5802 alone. libpq does not silently accept a trailing attribute in the server-final message either: it records `malformed SCRAM message (garbage at end of server-final-message)` (`tests/.cache/postgres/17.10-openssl/source/src/interfaces/libpq/fe-auth-scram.c:727-728`). It differs from this library only in what happens next, since it goes on to decode and compare the signature rather than failing in base64.

The existing tests exercise malformed input and the RFC 7677 vectors, neither of which carries an extension: `tests/src/tests.adb:2459-2510` uses the published SCRAM-SHA-256 test vectors, and `tests/src/tests.adb:2512-2624` asserts rejection of a wrong proof, a non-base64 server-final, a mismatched nonce, an unsupported GS2 header and a malformed verifier. No test passes a well-formed unrecognized attribute.

## What happens now

Spike: three direct calls against the SCRAM message layer, each with the single unrecognized attribute `x=1` added at the position the RFC allows. For the client-final case the proof is computed by hand over the AuthMessage that includes the extension, which is what PostgreSQL's `client_final_message_without_proof` contains, so a conforming verifier must return `Valid = True`. The program asserts that, not merely the absence of an exception.

```ada
Extension : constant String := "x=1";

--  1. Server role, client-first-message.
Extended : constant String :=
  "n,,n=user,r=" & Client_Nonce & "," & Extension;
Got : constant String := SCRAM.Bare_From_Client_First (Extended);

--  2. Server role, client-final-message.
Without_Proof : constant String :=
  "c=biws,r=" & Combined_Nonce & "," & Extension;
Auth_Message : constant String :=
  Bare & "," & Server_First & "," & Without_Proof;
...
SCRAM.Verify_Client_Final
  (Credential, Bare, Server_First, Combined_Nonce, Client_Final,
   Server_Signature, Valid);

--  3. Client role, server-final-message.
Extended : constant String := Server_Final & "," & Extension;
SCRAM.Verify_Server_Final (Extended, Signature);
```

Output, exit status 1:

```
  -- Bare_From_Client_First ("n,,n=user,r=rOprNGfwEbeRWgbNEkqO,x=1") raised SCRAM_Error: malformed SCRAM client-first-message
  -- client-final under test: c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,x=1,p=IhwEOhboL25RstTdvZrPEOlE5bjYNyL1Go4fmyTI92U=
  -- Verify_Client_Final raised SCRAM_Error: malformed SCRAM attribute; expected p
  -- server-final under test: v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,x=1
  -- Verify_Server_Final raised SCRAM_Error: invalid base64 data
  FAILED: an unrecognized extension attribute after the client-first nonce is ignored and kept in the bare message (RFC 5802 sec. 7; PostgreSQL read_client_first_message consumes trailing attributes and discards them)
  FAILED: an unrecognized extension attribute between the client-final nonce and the proof is ignored, and the proof computed over the extended without-proof text is accepted (PostgreSQL read_client_final_message reads attributes until 'p' and includes them in client_final_message_without_proof)
  FAILED: an unrecognized extension attribute after the server-final v= signature is ignored and the signature still verifies (RFC 5802 sec. 7)
BUG REPRODUCED: 3 failed expectation(s)
```

In the server role both failures happen before the proof is examined, so `Admit` (`src/flyology-postgres-server.adb:257`) converts them into a connection-level `Protocol.Protocol_Error`.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

An unrecognized attribute at any of the three positions the RFC 5802 grammar allows should be skipped rather than rejected, while `m=` stays refused. In the client-final message the extension must remain inside the without-proof text, so that a proof computed over it verifies, as PostgreSQL's `read_client_final_message` requires (`tests/.cache/postgres/17.10-openssl/source/src/backend/libpq/auth-scram.c:1364-1392`).

## Suggested treatment

Three small changes in `src/flyology-postgres-scram.adb`:

- In `Parse_Client_First`, replace the rejection at `:399-401` with a loop that consumes the remaining tokens and discards them, matching `read_client_first_message`. The bare text returned to the caller already spans the whole message after the GS2 header, so the extension stays in the AuthMessage with no further change.
- In `Verify_Client_Final`, read tokens after the nonce until the one whose attribute name is `p`, instead of requiring the third token to be the proof at `:589-590`. Keep the trailing-data check at `:594` and the slice at `:600-601`, which then yields the without-proof text including the extension.
- In `Verify_Server_Final`, take the signature as the first token of the message instead of passing the whole message to `Attribute_Value` at `:554`, so anything after the first comma is ignored.

The spike is the regression test, and it belongs in `Test_SCRAM_Failures` in `tests/src/tests.adb:2512`, next to the existing malformed-message assertions, with the client-final case asserting `Valid = True`. No existing test asserts the current rejection, so none has to change.

## Severity

A third-party SCRAM client that appends an extension to its client-first or client-final message is refused with a connection-level protocol error instead of being authenticated, and a server that appends one to its server-final message makes this library's client report a valid signature as invalid base64. Reaching any of this needs a peer that actually emits an extension. No mainstream PostgreSQL peer does: libpq sends exactly `n,,n=,r=<nonce>` and `c=biws,r=<nonce>,p=<proof>`, and PostgreSQL's own server never emits one, so a standard psql or libpq client is unaffected. Deterministic.
