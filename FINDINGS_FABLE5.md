# Security & Correctness Review — Flyology Postgres

**Reviewer:** Claude Fable 5 (senior security engineering pass)
**Date:** 2026-08-07
**Scope:** The hand-written Ada in `src/`, the `pgish`/`psqlish` examples, and the
build/CI/test scripts. The vendored PostgreSQL C parser under
`sql/backends/*/vendor/` (libpg_query) and the external `flyology`,
`hmac_ada`, and `system_random` dependency crates are third-party and out of
scope except where this repository's code calls into them.

---

## Verdict

**No HIGH or MEDIUM security vulnerabilities were found.** After a manual review
of the authentication, cryptographic, wire-parsing, and protocol code plus four
parallel deep-dive reviews (TLS, cancellation-key handling, replication
decoding, and the examples/scripts), nothing rose to the ≥ 0.8-confidence bar
for an exploitable vulnerability. There is **one Low-severity, defense-in-depth
robustness note** (a public API that trusts a caller-supplied flag), included
below for completeness — it is not reachable as a vulnerability through the
library's own call paths.

This is a genuinely well-secured codebase: constant-time credential
comparisons, CSPRNG-sourced secrets, explicit key wiping, a SPARK-proved
allocation-free wire core (README reports 326/326 GNATprove checks), fail-closed
TLS with no plaintext fallback, and injection-safe replication command
construction. The result of this review is a **clean bill of health with
evidence**, not a list of fixes to make before release.

### Findings summary

| # | Severity | Category | Location | Status |
|---|----------|----------|----------|--------|
| 1 | Low (defense-in-depth) | correctness / data-integrity | `src/flyology-postgres-replication-logical.adb:846` | **Resolved** — `Streamed` contract made explicit; stream-unaware consumers directed to the stateful `Decoder` |

No High or Medium findings.

---

## Finding 1 — Public `Decode` trusts the caller-supplied `Streamed` flag (Low)

* **File:** `src/flyology-postgres-replication-logical.adb:846` (and
  `Read_Stream_Xid`, `:213-223`)
* **Severity:** Low (defense-in-depth / correctness). **Not a memory-safety or
  authentication issue.**
* **Category:** `data-integrity`
* **Description:** The public `Decode` entry point for logical-replication
  (pgoutput) messages takes a `Streamed` boolean that tells it whether the
  data-bearing messages (`I`/`U`/`D`/`R`/`Y`/`T`/`M`) carry a leading streamed
  transaction id. If a *consumer that hand-rolls this flag* passes
  `Streamed => False` for a message that actually carried the XID prefix on the
  wire, `Read_Stream_Xid` consumes nothing and the four XID bytes are then
  reinterpreted as the following field (e.g. a relation OID) — wrong data is
  decoded. It never reads out of bounds (all reads remain bounds-checked and the
  trailing `Require_End` frequently catches the resulting length mismatch), so
  the worst case is a decode error or a misparsed record, not a crash or memory
  corruption.
* **Why it is not a vulnerability today:** The in-tree stateful `Decoder`
  (`:1213-1243`) always supplies `Streamed` correctly from its own `In_Stream`
  state, so no code path in this repository can trigger the mismatch. It is only
  a hazard for an external consumer that bypasses the stateful decoder and drives
  the raw `Decode` with an incorrect flag.
* **Recommendation (optional):** Either document at the `Decode` declaration that
  a mismatched `Streamed` yields undefined field mapping, or fold the flag
  entirely under the stateful `Decoder` so it cannot be supplied incorrectly.
* **Resolution (applied):** The `Streamed` parameter's contract was made explicit
  in the spec (`flyology-postgres-replication-logical.ads`): it is now documented
  as a precondition that must match the true on-wire stream context, with an
  explicit note that a mismatch yields an undefined — though memory-safe and
  `Protocol_Error`-bounded — decode, and a directive that consumers who do not
  themselves track Stream Start/Stop boundaries **must** use the stateful
  `Decoder` (which derives the flag from its own `In_Stream` state). A
  cross-referencing comment was added at the `Decode` body head. The signature
  and default were intentionally left unchanged: the stateless form is a
  legitimate primitive used throughout the test suite for known-context decoding,
  and removing the default would neither prevent the explicit-wrong-value misuse
  this note describes nor be proportionate to a Low, not-externally-reachable
  item.

---

## What was reviewed and verified safe

The bulk of the value of this review is the coverage below. Each area was traced
to concrete evidence.

### Authentication — SCRAM-SHA-256 (`src/flyology-postgres-scram.adb`, `-server.adb`)

* **Constant-time proof and signature comparison.** Client-proof verification and
  server-signature verification both use `HMAC_SHA256.Equal`
  (`scram.adb:558`, `scram.adb:616`), the dependency's constant-time digest
  compare, rather than `=` on the byte arrays. A wrong proof wipes intermediates
  and returns `Valid => False` without leaking timing about *where* it differed
  (`scram.adb:616-623`).
* **User-enumeration resistance.** When the startup role has no stored verifier,
  the server runs the *same* `Parse_Verifier` + `Verify_Client_Final` path
  against a fixed, non-secret `Dummy_SCRAM_Verifier` (`server.adb:32-35`,
  `:291-295`), so known and unknown users take an equivalent code path and PBKDF2
  work factor. The final decision then forces failure for unknown users via
  `if not Proof_Valid or else not Has_Credential then return False`
  (`server.adb:342-345`) — the dummy verifier can never authenticate anyone.
* **Mutual authentication is enforced on the client.** The client computes and
  checks the server signature via `Verify_Server_Final` (`client.adb:247`) and
  refuses to reach the `Ready` state unless `AuthenticationOk` was seen
  (`client.adb:290-293`). The SASL phase state machine rejects `AuthenticationOk`
  arriving mid-SCRAM (`client.adb:166-170`) and duplicate/again-out-of-order
  SASL messages (`:173-175`, `:223-226`, `:243-246`).
* **Secret hygiene.** Passwords, salted keys, client keys, signatures, and proofs
  are zeroized with `SCRAM_Core.Wipe` / `(others => 0)` and pinned with
  `pragma Inspection_Point` after use in `Make_Verifier_Raw`
  (`scram.adb:263-268`), `Client_Final_Message` (`:530-537`), and
  `Verify_Client_Final` (`:619-630`).
* **Input validation.** Nonces are length- and charset-validated
  (`Validate_Nonce`, `scram.adb:274-286`); iteration counts are overflow-guarded
  and range-checked to 4 096..1 000 000 (`Parse_Positive`, `:159-178`); the
  base64 decoder rejects non-canonical padding and invalid characters
  (`Base64_Decode`, `:93-157`); verifier and message lengths are capped at 4 096.
* **PBKDF2/HMAC core** (`scram_core.adb`) is SPARK-mode and correctly encodes the
  single-block INT(1) counter, XOR-accumulates the iterations, and wipes
  intermediates.
* **Nonce entropy.** `Random_Nonce` draws 18 bytes (144 bits) from the OS CSPRNG
  before base64 encoding (`scram.adb:288-298`).
* **Channel-binding downgrade handling.** `Parse_Client_First` accepts only
  `n,,` / `y,,` GS2 headers and rejects a `p=…` (channel-binding-required) header
  outright (`scram.adb:380-384`); since the server does not advertise
  `-PLUS`, the `y` path is the correct expectation and the client-final `c=`
  value is checked against it (`server.adb:312-314`, `:341`).

### Transport security — TLS (client, server, transport layer)

* **No silent downgrade.** `Startup_TLS` sends the SSLRequest and treats *any*
  non-`'S'` reply (including `'N'`, `'E'`, or injected bytes) as terminal:
  `raise TLS_Not_Available` with no plaintext fallback (`client.adb:361-365`);
  the `when others` handler closes and re-raises (`:381-383`).
* **Verification is mandatory and fails closed.** The client requires a non-empty
  `Server_Name` (`client.adb:348-349`) and passes it with the `Client` role into
  `Upgrade_TLS`, which calls `TLS.Take` + `Handshake` and, on any exception,
  closes the connection and re-raises without swallowing the error
  (`transports-tls_sockets.adb:40-53`). The underlying provider enforces
  `SSL_VERIFY_PEER` plus `SSL_set1_host` (chain + DNS-hostname verification) with
  no insecure mode — verified by reading the external OpenSSL C adapter and its
  Ada spec.
* **Server enforces `TLS_Required`.** A connection that never upgraded is rejected
  with a FATAL error when policy is `TLS_Required` (`server.adb:406-414`); TLS is
  only refused (`'N'`) when policy is `TLS_Disabled` (`:382-397`).
* **Examples are configured correctly.** `psqlish` offers only `disable` /
  `verify-full` (no auto-fallback `prefer`/`allow` mode) and passes the TLS host
  name even when a separate connect IP is used; `pgish` serves with
  `TLS_Required` when a cert/key are configured.

### Query-cancellation keys (`src/flyology-postgres-server.adb`)

* **CSPRNG-sourced.** Keys and the 31-bit process id are drawn from
  `System_Random` (`getentropy`/`BCryptGenRandom`), not a PRNG or clock
  (`server.adb:23-26`, `Generate` `:74-98`). Key length is 32 bytes for protocol
  ≥ 3.2 and 4 bytes for legacy 3.0 (`:460-461`), matching real PostgreSQL.
* **Constant-time, truncation-proof comparison.** `Matches` (`:50-72`) XORs across
  the full fixed 32-byte width regardless of the presented length and additionally
  requires `Secret'Length = Item.Length`, defeating prefix/truncation guessing;
  `Same_Credentials` (`:37-48`) is likewise constant-time.
* **No enumeration oracle.** `Route` (`:160-177`) — reached on the unauthenticated
  CancelRequest path — scans every slot without early exit and returns no result
  to the caller, so an attacker gets zero feedback and must guess a 31-bit pid
  plus the full CSPRNG secret.

### Wire & protocol parsing

* **SPARK-proved core.** `Flyology.Postgres.Wire` is allocation-free with explicit
  `Can_Read`/`Valid_View` bounds predicates and proved postconditions; length
  helpers (`Valid_Initial_Length`, `Valid_Typed_Length`, `Content_Length`) gate
  all framing (`framing.adb:44-74`) so lengths below 4/8 or above the 16 MiB cap
  are rejected before any allocation or slice.
* **Guarded conventional decoders.** `protocol.adb` reads every count/length via
  `Try_Read_*` + `Require` and validates `Count_Fits` before reserving capacity or
  looping (`Decode_Row_Description` `:637-699`, `Decode_Data_Row` `:701-746`,
  `Decode_Parameter_Description`, COPY format decode), and rejects trailing data.
* **No unsafe constructs.** No `pragma Suppress`/`Unsuppress`, `-gnatp`,
  `Unchecked_Conversion`, or address-to-access tricks exist in `src/`, so Ada's
  runtime checks remain active — malformed input at worst raises a handled
  `Protocol_Error`/`Constraint_Error`, never memory corruption (Ada is memory
  safe here).

### Replication

* **Command construction is injection-safe.** Slot and option names are restricted
  to `[a-z0-9_]` / `[A-Za-z0-9_]` (`replication.adb:106-109`, `:100-104`), and all
  string values go through `SQL_Literal`, which doubles single quotes
  (`:111-134`); e.g. `Create_Logical_Slot`/`Start_Logical` validate the slot name
  and escape the snapshot/option values (`:197-275`).
* **Stream-envelope decode is length-checked.** The physical `Decode`
  (`replication.adb:845-909`) requires `≥ 25` for XLogData and exact `18/34/25`
  lengths for keepalive/status/feedback before reading the trailing reply-flag
  byte, and rejects unknown tags.
* **pgoutput decoders are correctly bounded.** Every tuple/column/relation/truncate
  count is validated with `Count_Fits` (or an explicit `≤ remaining` comparison)
  *before* driving a loop or `Reserve_Capacity`, unsigned length fields make a
  "negative int32" appear as an over-large value that the bound rejects, and
  message-kind dispatch/version gating matches PostgreSQL pgoutput. See Finding 1
  for the one by-design caveat.
* **Managed-primary option parsing** converts untrusted option strings with
  `'Value` inside a `Constraint_Error → Protocol_Error` handler
  (`replication-managed_primary.adb:187-216`).

### Examples & scripts

* **`pgish` read-only sandbox holds.** Client SQL is parsed with the real
  PostgreSQL-18 grammar and the statement root is pinned to `SELECT`/`SHOW` only
  (`pgish_sql.adb:655-659`, `:698-703`); the evaluator reads only a fixed set of
  in-memory virtual tables through a hardcoded dispatch (`pgish_catalog.adb`), the
  environment view exposes a 5-name allowlist, and the only process spawn (`git`)
  runs once at startup with an argument array (no shell) on a trusted, CLI/env
  path. Trust-mode auth is by design and documented.
* **`psqlish` client** escapes all control bytes from server rows before display
  and writes only a history file on a trusted env-derived path — no server-driven
  file write or path traversal.
* **Scripts / CI** use argument arrays (no shell string interpolation of untrusted
  data), checksum-verify the PostgreSQL download, validate `POSTGRES_VERSION`, and
  run CI on `pull_request` (not `pull_request_target`) with `contents: read` and no
  interpolation of PR-controlled fields into `run:` steps.

---

## Considered and dismissed (not findings)

* **Client accepts a `trust`-style `AuthenticationOk` without a challenge.** This
  is protocol-correct libpq behavior; over verified TLS an attacker cannot inject
  it, and over plaintext the channel is already fully exposed. The client library
  has no "require that a credential was actually challenged" mode, but neither does
  stock libpq — not a vulnerability.
* **4-byte cancellation key for protocol 3.0.** Protocol-mandated (32 bits); this
  server negotiates 3.2 with 32-byte keys by default. Not a weakness introduced by
  this code.
* **`SASL_Response` reads the full framed payload before SCRAM caps it at 4 096
  bytes.** The excess is bounded by the 16 MiB frame limit and rejected by the
  SCRAM parser; this is a resource-usage consideration (explicitly out of scope),
  not a security defect.
* **SASLprep / Unicode password normalization is not implemented.** This is an
  explicit, documented interoperability boundary (ASCII passwords are fully
  interoperable), not a security flaw.

## Residual risk / caveats

* Certificate-chain and hostname verification ultimately execute inside the
  external OpenSSL C provider in the `flyology` dependency. That code was **read**
  and found correct (`SSL_VERIFY_PEER`, `SSL_set1_host`, TLS 1.2+ floor, no
  insecure mode) but was **not executed** as part of this static review.
* Dependency versions (`hmac_ada`, `system_random`, `flyology`) are managed
  separately and were not audited here.
* This review is static analysis; it did not run a fuzzer against the decoders.
  The `gnatfuzz` harness in the repo is a good next step for the conventional
  (non-SPARK) `protocol.adb` and `replication-logical.adb` decoders.
