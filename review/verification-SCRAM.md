# Adversarial verification: SCRAM-SHA-256 findings

Scope verified by reading `src/flyology-postgres-scram.ads/.adb`,
`src/flyology-postgres-scram_core.ads`, `src/flyology-postgres-server.ads/.adb`,
`src/flyology-postgres-server_sessions.adb`, `src/flyology-postgres-client.ads/.adb`,
`tests/src/tests.adb`, `tests/scripts/run-integration.sh`, and the `hmac_ada` 0.2.0 spec.

All three findings survived refutation. Three reproduction programs were added under
`tests/repros/src/`; nothing under `src/`, `sql/`, `examples/`, `tests/src/`, or any existing
script was modified, and nothing was committed.

RFC and PostgreSQL statements below are from my own knowledge; where I am not certain of an
exact upstream sentence I say so rather than inventing a citation.

| ID | Verdict | Severity (was) | Repro |
|----|---------|----------------|-------|
| SCRAM-1 | CONFIRMED | P1 (P1) | `tests/repros/src/repro_scram_1.adb` |
| SCRAM-2 | CONFIRMED (one supporting claim about libpq refuted) | P2 (P2) | `tests/repros/src/repro_scram_2.adb` |
| SCRAM-3 | CONFIRMED as a policy value with interop consequence | P2 (P2) | `tests/repros/src/repro_scram_3.adb` |

---

### SCRAM-1: Server mock exchange uses a fixed, source-published salt

**Verdict:** CONFIRMED. Every claim in the finding checks out against the source, and the
observable property was demonstrated end to end over a real loopback socket against the
library's own generic server.

Verified by reading:

- `src/flyology-postgres-server.adb:32-35` declares `Dummy_SCRAM_Verifier` with
  `s=Zml4ZWQgZHVtbXkgc2FsdA==` (base64 of the 16 ASCII octets `fixed dummy salt`) and
  `i=4096`. The whole repository contains exactly one occurrence of this constant
  (`grep Zml4ZWQ` matches only `src/flyology-postgres-server.adb:32-33` and its single use at
  `:295`), so nothing else compensates for it.
- `src/flyology-postgres-server.adb:288-295`: `Has_Credential := Supplied'Length > 0`, and the
  `Credential` handed to the exchange is `Parse_Verifier (Dummy_SCRAM_Verifier)` whenever the
  application's `Lookup_SCRAM_Verifier` returns `""`.
- `src/flyology-postgres-server.adb:317-319` builds `Server_First` from that credential, and
  `src/flyology-postgres-scram.adb:444-447` emits `Credential.Encoded_Salt` and the iteration
  count verbatim. The salt therefore reaches the wire in `AuthenticationSASLContinue`, before
  any proof is exchanged.
- Existing coverage really is silent on this: `tests/scripts/run-integration.sh:188-197` only
  checks that an unknown user is ultimately *rejected*, and confirms in its own comment that
  the dummy input is intentionally non-secret.

Refutation attempts that failed:

- *"An application can avoid it by returning its own mock verifier."* It can, but unsafely:
  `Has_Credential` is derived from the returned string being non-empty, so any non-empty mock
  makes `Admit` accept a proof that matches it (`:340`, `if not Proof_Valid or else not
  Has_Credential`). A mitigation therefore has to return a per-user verifier whose StoredKey
  the attacker cannot predict; returning the library's own published dummy would turn the leak
  into a full bypass. There is no supported hook that only changes the mock salt.
- *"The comment says the constant exists for constant-time reasons, so it is deliberate."* The
  comment (`:28-31`) explains why the dummy is *verifier text* rather than a password (to avoid
  attacker-controlled PBKDF2 work and to keep both paths identical). That rationale is
  unaffected by making the salt per-user; PostgreSQL keeps exactly the same constant-time
  property while varying the salt.

**Severity:** P1 (unchanged). Under the given rubric, P0's security-relevant examples are
authentication bypass, missing verification and secret exposure; this is none of those — the
server still returns `False` for a role with no verifier, and no secret escapes. It is a
pre-authentication information leak, which fits P1 better. A reader who reads "security-relevant"
more broadly could argue P0; I record the disagreement rather than hiding it.

**Repro:** `tests/repros/src/repro_scram_1.adb`. It instantiates
`Flyology.Postgres.Server` with `Authentication => Flyology.Postgres.SCRAM_SHA_256` and a
`Lookup_SCRAM_Verifier` that returns a real verifier only for the role `known`, listens on
loopback, and runs three raw-socket SCRAM exchanges (StartupMessage, SASLInitialResponse,
read `AuthenticationSASLContinue`, then a well-formed wrong proof so each connection ends with
a normal 28P01 rather than a truncated stream).

**Output** (`cd tests/repros && ./run.sh repro_scram_1 90`, exit status **1**):

```
  -- listening on 127.0.0.1: 50087
  -- unknown-a: server-first = r=rOprNGfwEbeRWgbNEkqOe5OOFm+7I4zpNSmln1ssdwQm,s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096
  -- unknown-a: final backend message tag 'E'
  -- unknown-b: server-first = r=rOprNGfwEbeRWgbNEkqOeRNBKkzzPboskNy0XP/EGtih,s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096
  -- unknown-b: final backend message tag 'E'
  -- known: server-first = r=rOprNGfwEbeRWgbNEkqOS2W0TaikuMhOL0h4Cm16v6ks,s=Rmx5b2xvZ3kgdGVzdCBzYWx0,i=4096
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

Both distinguishers are demonstrated: the two unknown roles receive byte-identical
`s=`/`i=` values, and the known role receives a different salt. The nonces differ (they are
freshly random), so the salt is the whole channel.

**Description:** A PostgreSQL server built on `Flyology.Postgres.Server` with
`Authentication => SCRAM_SHA_256` answers every startup role for which the application's
`Lookup_SCRAM_Verifier` returns `""` with the same `AuthenticationSASLContinue` salt and
iteration count — `s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096`, a constant compiled into
`src/flyology-postgres-server.adb:32-35` and therefore public in the library's source. A role
that does have a verifier answers with that verifier's own (random) salt. An unauthenticated
client learns whether a role exists from the server's *second* message, before sending any
proof and without triggering an authentication failure, simply by comparing the salt against the
published constant. PostgreSQL deliberately avoids this: `src/backend/libpq/auth-scram.c` builds
a mock secret with `mock_scram_secret`, whose salt comes from `scram_mock_salt` — a SHA-256 over
the role name together with the per-cluster `mock_authentication_nonce`, truncated to the default
salt length — so unknown roles get stable, per-user, unpredictable salts that a client cannot
distinguish from a real role's; the upstream comment states that the purpose is to avoid
revealing whether the user exists. Note that an application cannot safely work around this
through the existing callback: returning any non-empty verifier sets `Has_Credential`, so a
client that produces a matching proof is authenticated. A fix changes an externally visible
policy (the mock scheme) and so needs the user's decision, not a silent edit.

---

### SCRAM-2: Optional SCRAM extension attributes are rejected instead of ignored

**Verdict:** CONFIRMED for all three locations. One *supporting* claim inside the finding is
refuted, and one cited mechanism is slightly mis-stated; neither changes the verdict.

Verified by reading:

- Client-first (server role): `src/flyology-postgres-scram.adb:399-401`, `if Cursor <=
  Bare_Text'Last then Fail ("malformed SCRAM client-first-message")`. Confirmed as cited.
- Client-final (server role): the finding cites the composite test at `:593-597`
  (`Cursor <= Client_Final'Last`). **Mis-stated mechanism:** with an extension between `r=` and
  `p=`, the third `Next_Token` returns the extension and `Attribute_Value (P_Token, 'p')` at
  `:590` fails first, with `"malformed SCRAM attribute; expected p"` — see the repro output.
  Same outcome (`SCRAM_Error` before any proof check), different line.
- Server-final (client role): `src/flyology-postgres-scram.adb:554-555`,
  `Attribute_Value (Message, 'v')` returns everything after `v=` to the end of the message, so a
  trailing `,x=1` is fed to `Base64_Decode`. Confirmed.

Normative basis, stated precisely: RFC 5802's formal syntax (Section 7) defines
`extensions = attr-val *("," attr-val)` and carries the comment "All extensions are optional,
i.e., unrecognized attributes not defined in this document MUST be ignored", and places
`["," extensions]` at the end of `client-first-message-bare`,
`client-final-message-without-proof` and `server-final-message`. RFC 7677 inherits that grammar.
The finding's separate observation that `m=` (reserved-mext) must be rejected is correct and is
correctly excluded from the finding.

PostgreSQL's server behaviour, as relied on: `read_client_first_message` in
`src/backend/libpq/auth-scram.c` finishes by consuming any remaining attributes with
`read_any_attr` and discarding them (its comment says extensions are not supported and are
ignored); `read_client_final_message` reads attributes until it reaches the one named `p`, and
`client_final_message_without_proof` spans everything before the proof, extensions included —
which is exactly what the fixed slice at `src/flyology-postgres-scram.adb:600-601` would produce
here if parsing did not reject first.

**Refuted supporting claim:** the finding asserts that libpq's `read_server_final_message`
"does not check for trailing data". `read_attr_value` does stop at the first `,`, so libpq
decodes the signature correctly rather than failing in base64 — but I am not able to confirm
that libpq then ignores the remainder; fe-auth-scram.c carries a
"garbage at end of server-final-message" diagnostic, and I cannot verify from memory whether it
is fatal. The defensible statement is narrower: this library fails at base64 decoding *before*
comparing the signature, whereas libpq compares the signature; and RFC 5802 requires the
extension to be ignored. Case (c) below is therefore the weakest of the three: it is an RFC
conformance gap, not a demonstrated libpq divergence. Cases (a) and (b) are genuine divergences
from PostgreSQL's own server.

**Severity:** P2 (unchanged). No mainstream PostgreSQL driver sends SCRAM extensions
(libpq sends exactly `n,,n=,r=<nonce>` and `c=biws,r=<nonce>,p=<proof>`), and PostgreSQL itself
never emits one, so this needs unusual input to reach — the definition of P2 under the given
rubric. It is not P1: no valid input from any known peer takes this path.

**Repro:** `tests/repros/src/repro_scram_2.adb`. For case (b) the client proof is computed by
hand with `SCRAM_Core.PBKDF2_HMAC_SHA256` / `HMAC_SHA256.Compute` / `SCRAM_Core.Hash` /
`SCRAM_Core.Exclusive_Or` over the AuthMessage that *includes* the extension, so a conforming
verifier must return `Valid = True`; the program asserts that, not merely "no exception".

**Output** (`cd tests/repros && ./run.sh repro_scram_2 120`, exit status **1**):

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

**Description:** RFC 5802's grammar allows an optional `extensions` list at the end of
`client-first-message-bare`, `client-final-message-without-proof` and `server-final-message`, and
requires unrecognized attributes to be ignored. This library rejects all three. In the server
role, `Parse_Client_First` (`src/flyology-postgres-scram.adb:399-401`) raises `SCRAM_Error` for
any token after the nonce, and `Verify_Client_Final` (`:589-590`) requires the token after the
nonce to be the `p=` proof, so an extension makes parsing fail before the proof is examined;
`Admit` converts both to `Protocol.Protocol_Error`, so a third-party SCRAM client that appends an
extension is refused with a connection-level protocol error rather than being authenticated. In
the client role, `Verify_Server_Final` (`:554-555`) passes everything after `v=` to
`Base64_Decode`, so a server-final with a trailing extension is reported as invalid base64
instead of verifying. PostgreSQL's own server ignores extensions in both client messages
(`read_client_first_message` discards trailing attributes; `read_client_final_message` reads
attributes until `p` and keeps them inside `client_final_message_without_proof`), so cases (a)
and (b) are divergences from the reference server as well as from the RFC. Case (c) is an RFC
conformance gap; libpq's `read_attr_value` stops at the comma and would compare the signature,
but libpq also carries a "garbage at end of server-final-message" diagnostic whose fatality I
could not confirm. Reaching any of this needs a peer that actually emits an extension, which no
mainstream PostgreSQL client or server does.

---

### SCRAM-3: Iteration count outside `[4096, 1_000_000]` is rejected on both roles

**Verdict:** CONFIRMED as a **policy value with interop consequence**, not a plain bug. The
values are visible constants in `src/flyology-postgres-scram.ads:13-16` whose documented meaning
is exactly the observed behaviour ("Smallest verifier iteration count accepted or generated"),
so under the repository's Ada-interface-values rule the decision belongs to the user. What I
establish here is only the factual consequence, on both roles and through the public client API.

Verified by reading `src/flyology-postgres-scram.adb:174-176` (`Parse_Positive` fails outside
the range), used by `Parse_Verifier` at `:209` (server role) and `Parse_Server_First` at `:483`
(client role); `Make_Verifier_Raw` applies the same bounds at `:237-241`; and
`Complete_Startup`'s handler at `src/flyology-postgres-client.adb:372-378` re-raises
`SCRAM_Error` as `Protocol.Protocol_Error`. No documentation outside the `.ads` comments
discusses the range, and every existing fixture uses 4096.

Interop facts relied on: PostgreSQL 16 added the `scram_iterations` GUC (default 4096, minimum 1,
maximum `INT_MAX`); a role whose password is set while it is lowered stores
`SCRAM-SHA-256$<N>:...`. libpq's `read_server_first_message` accepts any iteration count that
parses and is `>= 1`, and the backend's `parse_scram_secret` applies no 4096 floor, so psql
authenticates against exactly the verifier and the server-first challenge exercised below. RFC
5802 recommends (SHOULD) an iteration count of at least 4096 in the description of the `i`
attribute and RFC 7677 repeats that recommendation for SCRAM-SHA-256; neither obliges a client
to *refuse* a lower count.

**Severity:** P2 (unchanged), with the label corrected from "bug" to "policy value with interop
consequence". It is not P1: the rejection is what the specification comment documents, so no
documented contract is violated, and it needs a non-default server configuration. It is not P0:
refusing a below-recommendation iteration count is not a protocol violation.

**Repro:** `tests/repros/src/repro_scram_3.adb`. Three checks: (1) `Parse_Verifier` on a genuine
rolpassword built with PBKDF2 at 1000 iterations (server role); (2) `Client_Final_Message`
against `i=1000` (client role); (3) the full public path — `Client.Startup` over a scripted
transport that plays a PostgreSQL server sending `AuthenticationSASL` and then
`AuthenticationSASLContinue` with `i=1000` and a nonce that extends the client's own randomly
generated one.

**Output** (`cd tests/repros && ./run.sh repro_scram_3 120`, exit status **1**):

```
  -- verifier under test: SCRAM-SHA-256$1000:W22ZaJ0SNY7soEsUEjb6gQ==$A7Cm0NrG3AFMNXYvoYKO3pDoaPPmqMJvmB38BNQzecg=:kyhP+VzX9vuGpnNS4by3UyHkedgzBWv0ceFzKMuu+74=
  -- Parse_Verifier raised SCRAM_Error: SCRAM iteration count is outside the supported range
  -- server-first under test: r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000
  -- Client_Final_Message raised SCRAM_Error: SCRAM iteration count is outside the supported range
  -- scripted server-first: r=6YN3nniQToBr4jqfheil3q2l0123456789abcdef01234567,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=1000
  -- Client.Startup raised FLYOLOGY.POSTGRES.PROTOCOL.PROTOCOL_ERROR: SCRAM iteration count is outside the supported range
  -- informational: i=2000000 (allowed by PostgreSQL 16+, whose scram_iterations maximum is INT_MAX) raised SCRAM_Error: invalid SCRAM iteration count
  FAILED: a PostgreSQL rolpassword stored with scram_iterations = 1000 parses (the backend's parse_scram_secret imposes no 4096 floor)
  FAILED: a server-first challenge carrying i=1000 is answered with a client proof (libpq's read_server_first_message accepts any count >= 1)
  FAILED: Client.Startup against a server offering i=1000 sends its client-final proof instead of failing with Protocol_Error
BUG REPRODUCED: 3 failed expectation(s)
```

The third line is the important one: the failure is reached through the documented public API
`Flyology.Postgres.Client.Startup`, and surfaces to the caller as `Protocol_Error`, not as an
authentication failure — so the application cannot distinguish it from a broken server.

**Description:** `Minimum_Iterations` (4096) and `Maximum_Iterations` (1_000_000) in
`src/flyology-postgres-scram.ads:13-16` are enforced by `Parse_Positive`
(`src/flyology-postgres-scram.adb:174-176`) on *parsing* as well as on generation, on both
roles. Consequences: a client connecting to a PostgreSQL 16+ server whose role verifier was
created under `scram_iterations = 1000` receives `i=1000` in `AuthenticationSASLContinue` and
`Client.Startup` fails with `Protocol.Protocol_Error "SCRAM iteration count is outside the
supported range"`, where psql/libpq authenticates normally (libpq's `read_server_first_message`
only requires `iterations >= 1`); and a server whose `Lookup_SCRAM_Verifier` returns a
rolpassword copied from such a cluster fails in `Parse_Verifier` before `AuthenticationSASL` is
even sent, so the client sees a connection-level protocol failure instead of an authentication
exchange (PostgreSQL's `parse_scram_secret` applies no floor). The same applies above
1_000_000, which PostgreSQL 16+ permits up to `INT_MAX`, though an upper bound that caps
authentication work is far more defensible than the floor. RFC 5802/7677 make 4096 a SHOULD-level
recommendation to the party choosing the count, not an obligation on a peer to refuse a lower
one. Because these are visible constants in a specification, changing either bound — or moving
the check so that only generation is bounded while parsing follows the peer — is a user decision
under the repository's Ada interface-value rules; the options are: keep both bounds as-is and
document the interop limit, keep the floor for `Make_Verifier_Raw` only and accept any count
`>= 1` when parsing (libpq-compatible), or expose the bounds as configuration.

---

## Files added

- `tests/repros/src/repro_scram_1.adb`
- `tests/repros/src/repro_scram_2.adb`
- `tests/repros/src/repro_scram_3.adb`

No existing file was modified; nothing was committed; the full test suites were not run.
