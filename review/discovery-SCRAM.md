# Correctness discovery: SCRAM-SHA-256 (client and server roles)

Scope: `src/flyology-postgres-scram.ads/.adb`, `src/flyology-postgres-scram_core.ads/.adb`,
the client SASL loop in `src/flyology-postgres-client.adb` (synchronous `Complete_Startup`
lines 192-384 and the asynchronous startup operation lines 1690-1830, 2049-2063, 2116),
the server flow in `src/flyology-postgres-server.adb` (`Admit`, lines 257-364, dummy verifier
lines 28-35) and `src/flyology-postgres-server_sessions.adb` (SASL encoders 122-148, decoders
514-565), `HMAC_SHA256` from hmac_ada 0.2.0 and `System_Random` 1.0.0 (specs only).
Read-only review against RFC 5802 / RFC 7677 and PostgreSQL's `fe-auth-scram.c` /
`auth-scram.c` behaviour. Existing coverage inspected: `tests/src/tests.adb`
(`Test_RFC_7677_SCRAM_SHA_256`, `Test_SCRAM_Failures`, `Test_Raw_Password_Boundary`),
`tests/src/postgres_test_server.adb`, `tests/scripts/run-integration.sh`.

Severity rubric (as given): P0 = memory/aliasing unsafety, security-relevant (authentication
bypass, missing verification, secret exposure), hang, or interop-breaking protocol violation;
P1 = wrong result or unexpected exception on valid input via a reachable path, or a documented
contract violated; P2 = edge-case incorrectness, wrong diagnostics, or contract drift needing
unusual input. SCRAM-1 is a security-relevant weakness short of bypass/secret exposure, so it
is filed as P1 rather than P0.

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| SCRAM-1 | Server mock exchange uses a fixed, source-published salt: unknown users are enumerable from `server-first` | P1 | High |
| SCRAM-2 | Optional SCRAM extensions are rejected in client-first, client-final (server) and server-final (client); RFC 5802 says MUST ignore, PostgreSQL ignores | P2 | High |
| SCRAM-3 | Iteration count outside `[4096, 1_000_000]` is rejected, refusing valid PostgreSQL 16+ `scram_iterations` configurations on both roles | P2 | High (behaviour) / Medium (frequency) |

---

### SCRAM-1: Server mock exchange uses a fixed, source-published salt: unknown users are enumerable from `server-first`

**Location:** `src/flyology-postgres-server.adb:28-35` (constant), `:286-295` (selection),
`:315-319` (server-first built from it); `src/flyology-postgres-scram.adb:439-448`
(`Server_First_Message` emits `Credential.Encoded_Salt` verbatim).

**Severity:** P1. **Confidence:** High.

**Evidence:**

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
```ada
               Supplied : constant String :=
                 Lookup_SCRAM_Verifier (Context, Startup);
               Has_Credential : constant Boolean := Supplied'Length > 0;
               Credential : constant Flyology.Postgres.SCRAM.Verifier :=
                 Flyology.Postgres.SCRAM.Parse_Verifier
                   ((if Has_Credential
                     then Supplied
                     else Dummy_SCRAM_Verifier));
```
```ada
      return "r=" & Combined_Nonce
        & ",s=" & To_String (Credential.Encoded_Salt)
        & ",i=" & Positive'Image (Credential.Iteration_Count) ...
```

`Zml4ZWQgZHVtbXkgc2FsdA==` is base64 of the 16 octets `fixed dummy salt`. Every startup user
for which `Lookup_SCRAM_Verifier` returns `""` receives exactly this `s=` value (and `i=4096`)
in `AuthenticationSASLContinue`, on every server built from this source, before any proof is
exchanged. A real role's verifier carries a random salt (`Make_Verifier_Raw` / PostgreSQL both
store a random 16-byte salt). An unauthenticated client therefore learns, from the first
server message, whether the role exists (or has a SCRAM verifier) simply by comparing the salt
with the published constant. The comment documents the constant-time intent but the salt value
itself is the distinguishing channel.

PostgreSQL's reference behaviour (`src/backend/libpq/auth-scram.c`, `mock_scram_secret` /
`scram_mock_salt`) deliberately derives the mock salt as
`SHA-256(username || per-cluster mock_authentication_nonce)` truncated to the default salt
length so that unknown roles get a stable, per-user, unpredictable salt indistinguishable from
a real one; its comment states the purpose is to avoid revealing whether the user exists. The
integration script (`tests/scripts/run-integration.sh:189-198`) even publishes the dummy
password (`Flyology invalid SCRAM credential`), which is fine for the bypass property (the
server still returns `False` on `not Has_Credential`) but confirms the whole dummy is public.

**Failure scenario (concrete):**
1. Client -> server: StartupMessage `user=alice`; server -> client: `R` code 10 `SCRAM-SHA-256\0\0`.
2. Client -> server: `p` `SCRAM-SHA-256\0` len `n,,n=,r=<24-char nonce>`.
3. Server -> client: `R` code 11 `r=<nonce><24 server chars>,s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096`
   when `alice` is unknown; `s=<random salt>` when `alice` exists.
4. The attacker aborts. No password guess or 28P01 response is needed.

**Reproduction test sketch:**
- Direct-call confirmation (no server needed): copy the `Dummy_SCRAM_Verifier` text into a
  repro, call `SCRAM.Parse_Verifier` on it and
  `SCRAM.Server_First_Message (Credential, "rOprNGfwEbeRWgbNEkqO" & "abcdefghijklmnopqrstuvwx")`;
  assert (correct behaviour) that the result does NOT contain `",s=Zml4ZWQgZHVtbXkgc2FsdA=="`
  and that `Base64_Decode` of the salt is not the ASCII string `fixed dummy salt`.
  Current sources: it does contain it.
- End-to-end (real interop, no PostgreSQL needed): start `tests/src/postgres_test_server`
  (its `Lookup_SCRAM_Verifier` returns `""` for any user other than `flyology`). With a raw
  socket (Ada `Flyology.IO.Sockets` or a short Python script) send a StartupMessage for
  `user=unknown-a`, then the SASLInitialResponse above, read the `R`/11 payload and extract
  `s=`. Repeat for `unknown-b` and for `flyology`. Expected (correct): the two unknown users'
  salts differ from each other and neither equals `Zml4ZWQgZHVtbXkgc2FsdA==`. Actual: both
  unknown users get `s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096`; `flyology` gets
  `s=Rmx5b2xvZ3kgdGVzdCBzYWx0` (base64 of `Flyology test salt`).

**Existing coverage:** `run-integration.sh:189-198` checks only that the unknown user is
ultimately rejected. Nothing checks that the mock exchange is indistinguishable.

**Suggested disposition (for the user's decision, not applied):** derive the mock verifier's
salt per user from a per-process random secret (e.g. `HMAC-SHA-256(process_secret, username)`
truncated to 16 bytes) while keeping a fixed StoredKey/ServerKey, matching PostgreSQL. This
touches a visible policy (mock scheme) and so needs explicit approval.

---

### SCRAM-2: Optional SCRAM extensions are rejected in client-first, client-final (server) and server-final (client)

**Location:** `src/flyology-postgres-scram.adb:399-401` (client-first), `:593-597`
(client-final), `:553-555` (server-final).

**Severity:** P2. **Confidence:** High on this library's behaviour and on PostgreSQL's
server behaviour; high on libpq's server-final handling.

**Evidence:**

```ada
         --  Postgres deliberately ignores the SCRAM username and libpq
         --  sends an empty n= value, relying on the startup-message user.
         if Cursor <= Bare_Text'Last then
            Fail ("malformed SCRAM client-first-message");
         end if;
```
```ada
         if C /= Channel_Binding or else R /= Combined_Nonce
           or else Cursor <= Client_Final'Last
           or else Proof_Data'Length /= Digest'Length
         then
            Fail ("invalid SCRAM client-final-message");
```
```ada
         Signature_Text : constant String := Attribute_Value (Message, 'v');
         Signature : constant Byte_Array := Base64_Decode (Signature_Text);
```

RFC 5802 section 5.1 (`extensions`): "All extensions are optional, i.e., unrecognized
attributes not defined in this document MUST be ignored." The grammar allows
`client-first-message-bare = [reserved-mext ","] username "," nonce ["," extensions]`,
`client-final-message-without-proof = channel-binding "," nonce ["," extensions]`, and
`server-final-message = (server-error / verifier) ["," extensions]`.

- Server side, client-first: any token after `r=` raises `SCRAM_Error` (converted to
  `Protocol_Error` in `Admit`). PostgreSQL `read_client_first_message` loops
  `while (*p != '\0') read_any_attr(&p, NULL);` after the nonce, ignoring extensions.
- Server side, client-final: `Verify_Client_Final` requires the third token to be `p=`; any
  extension between `r=` and `p=` fails parsing before the proof is examined. PostgreSQL
  `read_client_final_message` reads attributes in a `do { ... } while (attr != 'p')` loop,
  and its AuthMessage covers the message up to the proof (including the extensions), exactly
  what `Final_Without_Proof` would compute here if parsing did not reject first.
- Client side, server-final: `Attribute_Value (Message, 'v')` consumes the whole message, so
  `v=<sig>,x=1` makes `Base64_Decode` fail on `,`. libpq's `read_server_final_message` reads
  `v` with `read_attr_value`, which stops at the first `,`, and does not check for trailing data.

Note `m=` (reserved-mext) is correctly rejected everywhere (an unsupported mandatory extension
must fail), and the client-side `server-first` rejection of trailing data matches libpq, which
also errors on "garbage at end of server-first-message"; those are not part of this finding.

**Failure scenario:** a third-party SCRAM client (not libpq) that appends an extension
attribute to client-first or client-final is refused with a `Protocol_Error` instead of being
authenticated; a non-PostgreSQL SCRAM server that appends an extension to `server-final` after
a correct `v=` is treated as a signature failure by this client.

**Reproduction test sketch (direct calls, no PostgreSQL):**
1. `SCRAM.Bare_From_Client_First ("n,,n=user,r=rOprNGfwEbeRWgbNEkqO,x=1")` -- expected
   (RFC/PostgreSQL): returns `"n=user,r=rOprNGfwEbeRWgbNEkqO,x=1"`; actual: `SCRAM_Error`
   "malformed SCRAM client-first-message".
2. Using the `Test_SCRAM_Failures` fixture (`Correct` verifier, `Bare`, `Server_First`,
   `Combined_Nonce`), call `Verify_Client_Final (Correct, Bare, Server_First, Combined_Nonce,
   "c=biws,r=" & Combined_Nonce & ",x=1,p=" & (44 chars of valid base64, e.g. the RFC 7677
   proof), Sig, Valid)`. Expected: returns with `Valid = False` (proof checked and rejected;
   a proof computed over the extended without-proof text would be accepted). Actual:
   `SCRAM_Error` "invalid SCRAM client-final-message" raised before any proof check.
   To show acceptance is possible, compute the proof manually with `SCRAM_Core.PBKDF2_HMAC_SHA256`,
   `HMAC_SHA256.Compute`, `SCRAM_Core.Hash`, `SCRAM_Core.Exclusive_Or` over
   `Bare & "," & Server_First & ",c=biws,r=" & Combined_Nonce & ",x=1"`.
3. From `Test_RFC_7677_SCRAM_SHA_256`: after `Client_Final_Message` fills `Signature`, call
   `Verify_Server_Final ("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,x=1", Signature)`.
   Expected: no exception (signature matches, extension ignored). Actual: `SCRAM_Error`
   "invalid base64 data".

**Existing coverage:** none for extension attributes; `Test_SCRAM_Failures` covers wrong
password, non-base64 `v=`, mismatched server nonce, `p=` GS2 header rejection, `y` header
acceptance and one malformed verifier.

---

### SCRAM-3: Iteration count outside `[4096, 1_000_000]` is rejected on both roles, refusing valid PostgreSQL 16+ configurations

**Location:** `src/flyology-postgres-scram.ads:13-16` (constants), `src/flyology-postgres-scram.adb:159-178`
(`Parse_Positive`), `:483` (client, server-first), `:209-210` (server, `Parse_Verifier`),
`:237-241` (`Make_Verifier_Raw`).

**Severity:** P2 (contract drift on a documented policy value; needs a user decision under the
repository's interface-value rules rather than a silent change). **Confidence:** High that the
code rejects; medium on how often deployments use non-default `scram_iterations`.

**Evidence:**

```ada
   Minimum_Iterations : constant := 4_096;
   --  Smallest verifier iteration count accepted or generated.
   Maximum_Iterations : constant := 1_000_000;
   --  Largest verifier iteration count accepted, bounding authentication work.
```
```ada
      if Result < Minimum_Iterations or else Result > Maximum_Iterations then
         Fail ("SCRAM iteration count is outside the supported range");
      end if;
```

PostgreSQL 16 added the `scram_iterations` GUC (range 1 .. INT_MAX, default 4096); roles
created under `SET scram_iterations = N` store `SCRAM-SHA-256$N:...`. libpq's
`read_server_first_message` accepts any `i` with `iterations >= 1`; the server's
`parse_scram_secret` applies no range check at all. RFC 7677 only says the count SHOULD be at
least 4096 (server-side advice); RFC 5802 places no obligation on the client to refuse lower
values.

**Failure scenario:**
- Client role: connect to a PostgreSQL 16+ server whose role was created with
  `scram_iterations = 1000` (or `> 1_000_000`). Server-first `r=...,s=...,i=1000` arrives in
  `AuthenticationSASLContinue`; `Client_Final_Message` raises `SCRAM_Error`, re-raised by
  `Complete_Startup` as `Protocol_Error` "SCRAM iteration count is outside the supported
  range", and the startup fails although libpq would authenticate.
- Server role: `Lookup_SCRAM_Verifier` returns a rolpassword copied from such a cluster
  (`SCRAM-SHA-256$1000:...`); `Parse_Verifier` raises before `AuthenticationSASL` is sent, so
  the client sees a connection-level protocol failure rather than an authentication exchange.

**Reproduction test sketch (direct calls):**
1. Using the RFC 7677 fixture: `Client_Final_Message ("pencil", Bare,
   "r=" & Combined_Nonce & ",s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000", Client_Nonce, Sig)`.
   Expected (libpq-compatible): a client-final string; actual: `SCRAM_Error`.
2. `Parse_Verifier ("SCRAM-SHA-256$1000:W22ZaJ0SNY7soEsUEjb6gQ==$"
   & "6noiwI8hQdf8Z+HCRIbshx1qqrjQPi1wyxZ1+7fQdIM=:KctKYif+hWsn2f75oSuDVm9zGdZUQ4iWXqV1PDhONRs=")`
   -- expected: a `Verifier`; actual: `SCRAM_Error`.
3. Memory_Transport variant for the client loop: queue `R`/10 `SCRAM-SHA-256\0\0`, let the
   client send its SASLInitialResponse, read the nonce from `Sent`, then queue `R`/11 with
   `r=<nonce>+srv,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000`; expected: a `p` message is sent;
   actual: `Protocol_Error`.
   Real PostgreSQL variant: `ALTER SYSTEM SET scram_iterations = 1000; ALTER ROLE flyology
   PASSWORD 'flyology-secret';` then run `tests/src/postgres_test_client` -> startup fails.

**Existing coverage:** none; all fixtures use 4096.

---

## Areas reviewed with no findings

- Base64 (`Base64_Encode` / `Base64_Decode`, scram.adb:48-157): correct RFC 4648 encoding;
  decoder rejects empty input, non-multiple-of-4 length, invalid alphabet characters, `=` in
  positions 1-2, `=` outside the last quad, `x=` followed by non-`=`, and non-canonical
  trailing bits; output length arithmetic matches padding; no index underflow (length >= 4 is
  guaranteed before `Value'Last - 1` is read).
- `Parse_Positive` overflow guard is exact (`Result*10 + digit <= Maximum_Iterations`); leading
  zeros accepted like `strtol`.
- `Parse_Verifier`: field splitting with GNAT `Ada.Strings.Fixed.Index (From => ...)` when
  `From = Source'Last + 1` returns 0 for Going = Forward (verified in
  `adainclude/a-strsea.adb:205-211`), so malformed verifiers raise `SCRAM_Error`, not
  `Index_Error`; salt 1..1024 bytes, StoredKey/ServerKey exactly 32 bytes; salt text is
  re-emitted only after canonical-decode validation.
- `Make_Verifier_Raw`: `Positive'Image` leading blank stripped; rolpassword layout matches
  PostgreSQL; salted password, ClientKey, StoredKey, ServerKey and password copy wiped with
  `Inspection_Point`.
- Nonce: `Random_Nonce` uses `System_Random` (getentropy/BCryptGenRandom), 18 bytes ->
  24 base64 characters, no `,`, no padding; `Validate_Nonce` enforces RFC printable set
  (0x21-0x7E minus `,`).
- Username escaping: `=` -> `=3D`, `,` -> `=2C`, NUL and empty rejected on the client; the
  server validates only well-formed `=2C`/`=3D` escapes and accepts libpq's empty `n=`
  (PostgreSQL ignores the SCRAM username).
- GS2 header: server accepts `n,,` and `y,,`, derives `c=` expectation `biws` / `eSws`
  correctly, rejects `p=...` and `a=` (authzid) as unsupported; since the server never
  advertises `SCRAM-SHA-256-PLUS` (`server_sessions.adb:127`) accepting `y` is exactly RFC
  5802 section 6 / PostgreSQL behaviour, and libpq over TLS with `channel_binding=prefer`
  does send `y,,` (covered by the psql-over-TLS interop run). Client always sends `n,,` and
  `c=biws`, which is consistent because it implements no channel binding.
- Attribute order and duplicates: strict `n,r` / `r,s,i` / `c,r,p` ordering; duplicated or
  reordered attributes fail; `m=` fails as required; empty attributes fail.
- Server-first validation in the client: combined nonce must strictly extend the client nonce
  (`R'Length <= Client_Nonce'Length` rejected), salt decoded and bounded, trailing data
  rejected (matches libpq).
- Key derivation and proof math (`SCRAM_Core.PBKDF2_HMAC_SHA256`, `Client_Final_Message`,
  `Verify_Client_Final`): PBKDF2 block index encoded big-endian `00 00 00 01`; U1 XOR ... XOR Uc;
  ClientKey/StoredKey/ClientSignature/ClientProof/ServerKey/ServerSignature per RFC 5802
  section 3; AuthMessage = bare "," server-first "," final-without-proof on both roles with
  the transmitted bytes; server recovers ClientKey = proof XOR ClientSignature and compares
  H(ClientKey) with StoredKey in constant time (`HMAC_SHA256."="`, `pragma No_Inline`);
  RFC 7677 vector passes in `Test_RFC_7677_SCRAM_SHA_256`.
- Server-final verification by the client is enforced: `Verify_Server_Final` uses the
  constant-time digest comparison after an exact 32-byte length check, and both client loops
  reject `AuthenticationOk` while in `Awaiting_Continue | Awaiting_Final`, reject
  `ReadyForQuery` before `AuthenticationOk`, reject duplicate/out-of-order SASL, SASLContinue
  and SASLFinal messages, and reject a switch to cleartext after SASL began. A server that
  omits `AuthenticationSASLFinal` cannot complete startup (stricter than default libpq).
- Mechanism selection: full-string match on `SCRAM-SHA-256` anywhere in the NUL-terminated
  list; list must be terminated with no trailing bytes; `SCRAM-SHA-256-PLUS`-only offers are
  refused with `Unsupported_Authentication`.
- Wire framing of SASL messages: `SASLInitialResponse` = mechanism C string + Int32 length +
  exact payload (server checks exact length and refuses -1); `SASLResponse` = raw payload;
  `AuthenticationSASL` list is double-NUL terminated; SASLContinue/SASLFinal carry raw text.
- Failure handling and wiping: `SCRAM_Error` is mapped to `Protocol_Error` on both roles;
  `Expected_Server_Signature` is wiped on every exit path of the synchronous loop; the
  asynchronous operation wipes password, nonce, bare-first and signature in `Wipe_Startup`
  on success, failure and finalisation paths; the server wipes the signature before returning
  and after encoding; dummy-verifier path returns `False` even for a valid proof
  (no bypass, and `run-integration.sh:189-198` checks this against real psql).
- Timing: known and unknown users perform identical `Parse_Verifier` +
  `Verify_Client_Final` work (modulo SCRAM-1, which is a data leak, not a timing leak).

## Observations not counted

- SASLprep is deliberately not applied on either role (`scram.ads:5-6`, `client.ads:78-87`).
  Interop consequence worth stating in user documentation: libpq/PostgreSQL run `pg_saslprep`
  on the password (falling back to the raw string only if the input is not valid UTF-8 or
  contains prohibited characters), so a password containing characters that SASLprep changes
  (e.g. U+00A0 NBSP -> space, NFKC-composable sequences, zero-width characters removed) will
  authenticate with psql but not with this client, and verifiers built by `Make_Verifier_Raw`
  will differ from PostgreSQL's for such passwords. Documented contract, not drift.
- `Verify_Server_Final` discards the text of a `e=` server error ("SCRAM server rejected
  authentication"). PostgreSQL never sends `e=` (it uses ErrorResponse), so diagnostics only.
- The server never advertises `SCRAM-SHA-256-PLUS`, so libpq with `channel_binding=require`
  cannot connect. A capability gap, not a protocol error. If PLUS is ever advertised, the
  `y` acceptance in `Parse_Client_First` must become a rejection (RFC 5802 section 6).
- Nonce-length policy: client nonce 16..256 characters accepted by the server, but the
  combined nonce is also limited to 256, so a client nonce longer than 232 characters passes
  `Parse_Client_First` and then fails in `Server_First_Message`. PostgreSQL sets no bounds;
  all mainstream drivers use 24-32 characters. Policy values, flagged for awareness only.
- `Next_Token` accepts a trailing `,` at the end of client-first and client-final (the last
  token is returned and the cursor moves past the end). AuthMessage uses the transmitted
  bytes, so this cannot create a proof mismatch on its own; PostgreSQL would reject it.
- If an application-supplied `Lookup_SCRAM_Verifier` returns a non-SCRAM string (md5/plain)
  the server raises `Protocol_Error` before sending `AuthenticationSASL`, whereas PostgreSQL
  mocks the exchange for invalid secrets too. This is a contract violation by the application
  (`server.ads:22-25`), but the resulting behaviour also distinguishes such users from unknown
  ones; it would be subsumed by a fix for SCRAM-1 that mocks for both cases.
- `Base64_Decode` is stricter than `pg_b64_decode` (rejects non-zero trailing bits). Any
  conforming encoder produces canonical output, so this is unreachable with correct peers.
- Empty passwords are accepted and processed (PBKDF2 on zero-length key) on the client, where
  libpq refuses to start SCRAM without a password; the exchange simply fails at the server.
- `Admit` parses the client-first three times (`Bare_From_Client_First`,
  `Nonce_From_Client_First`, `Channel_Binding_From_Client_First`); redundant work, no
  behavioural effect.
