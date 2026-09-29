# Flyology Postgres #31–#93 triage ledger

This is the master task's local orchestration record, not a repository change or
substitute for GitHub issue/PR state. Recheck GitHub and current main before
acting on an entry. Keep one issue per branch/PR except approved shared fixes.
Priority order: core P0, core P1, core P2, then examples. At most three lanes;
serialize Alire and integration runs. Do not use `/tmp` for artifacts.

## Merged and verified

- Protocol/server: #38 PR95; #39 PR96; #40 PR105; #41 PR111; #31 PR113;
  #46 PR115; #47 PR122 (merge 662aef03); #34 PR123 (merge fcba903c).
  #36 PR124 (merge df3ac9ba); #32 PR125 (merge 5a59ba6d); #45 PR128
  (merge c856ea8a). #46 was approved as a documentation-only correction.
- Client: #50 PR114; #51 PR116; #52 PR126 (merge ae25dd23). #51's approved fix retires the pre-COPY
  discarded Sync, and PR116 passed all 17 checks before merge.
- Replication: #56/#57/#58 PR99; #61 PR106; #62 PR112; #63 PR117; #67
  PR118; #66 PR119 (merge 0f706f9b); #70 PR120 (merge 3e9128f8);
  #69 PR121 (merge d6e587d5); #64 PR127 (merge 6e440efa).
  PR99 includes TLC broken
  configurations, TLAPS proof, and Ada replay.
  #63 and #67 passed independent review, local core and PostgreSQL 14–18
  replication gates, and all 17 exact-head CI checks before merge. #63's
  approved API adds `Standby_Copy_Done`.
- SQL parser: #74 PR94; #73/#81 PR97; #78 PR98; #82 PR102; #79 PR108;
  #80 PR109; #75/#76/#77 PR110.
- Examples completed before the maintainer's later examples-last priority
  direction: #83 PR100; #84 PR103; #85 PR107. Further example work is held.

## Core P1 decisions and evidence (including resolved #66)

- #47: confirmed fixed public SCRAM mock salt for two absent roles; real psql
  confirms a nonempty callback-provided mock verifier can authenticate.
  Maintainer approved an application-supplied, persistent cluster-stable
  secret for role-specific mock salts, an optional additive verifier classifier
  that cannot authenticate an absent role, and retaining 4096 mock iterations
  with the non-default-real-count limitation disclosed. On current main
  c57de39, the pre-fix raw TLS spike
  reconfirmed unknown-a and unknown-b return the same source-published salt
  and 4096 iterations; cached PG18.4 `psql` authenticated the known role and
  rejected the unknown role. No fix started.
  Proposed exact trailing optional `Server` generic formals: a
  `Provide_SCRAM_Mock_Secret` procedure with in-out `SCRAM.Digest` and
  `Provided : in out Boolean`, plus `Classify_SCRAM_Verifier` with in-out
  `Has_Credential`; both null defaults. SCRAM Serve would raise Program_Error
  without a supplied nonzero secret. Maintainer approved the exact names,
  types, public generic visibility, null defaults, classifier direction, and
  fail-closed behavior on 2026-09-22. Trust/cleartext remain unchanged. Lane
  implemented on current main d6e587d5. Targeted real PG18.4/raw/psql tests
  and literal `cd tests && alr -n build && ./scripts/test.sh` pass. Independent
  review found and closed P1 abort-unsafe wiping with Limited_Controlled guards
  and P2 missing exact HMAC regression; final rereview has no actionable
  P0/P1/P2. No Wire/SCRAM_Core change, so GNATprove was not triggered. PR122
  exact head 55228e75 passed all 17 CI checks and merged 2026-09-22
  (662aef03); issue closed.
- #66: current code omits parent history. Filed summary correctly says a
  standby *still on timeline 1* cannot follow timeline 3, but severity prose
  incorrectly said one that already followed the first switch cannot follow.
  Maintainer approved amendment; issue #66 severity text corrected on GitHub
  2026-09-22. Current-main pre-fix two-promotion spike rebuilt and reproduced:
  TLI2 history is `1\\t0/64\\tpromotion\\n`, TLI3 is only
  `2\\t0/C8\\tpromotion\\n`, so the inherited TLI1-line assertion fails.
  PG18.4 real-standby probe then confirmed managed requests for histories 2
  and 3 and standby rejection `new timeline 3 is not a child of database system
  timeline 1`; logs in replication lane `.tool-probes/issue-66/pg18.dGhxx2`.
  P1 impact confirmed. Also corrected issue's erroneous claim that `Capacity`
  bounds history bytes; it bounds entry count.
  Private Memory.Promote fix plus exact-format conformance regression now pass
  the focused tests (pre-fix assertion failed). Maintained PG18 integration
  reaches a TLI1 standby requesting histories 2 and 3 after two promotions,
  and now passes end-to-end under PG18.4: reserved-slot WAL staging retained
  ancestor segments, the original TLI1 standby replayed the real TLI3 marker,
  and final slot feedback passed. Earlier fixture failures were inherited
  recovery settings, recycled/stale WAL copies, and a boundary-LSN preflight
  name; all corrected test-only. Independent full-diff findings sweep found no
  actionable P0/P1/P2. Literal `cd tests && alr -n build && ./scripts/test.sh`
  passed, then five separate ordered replication integration runs passed at
  14.23, 15.18, 16.14, 17.10, 18.4. PR119 exact head db0dfec0 passed all
  17 CI checks and merged 2026-09-22 (0f706f9b). Issue should auto-close.
- #70: spike confirmed identical PREPARE replay invokes target twice and a new
  XID reusing the GID before old acknowledgement breaks acknowledgement.
  Maintainer approved preserving the applied marker for same-XID replay and
  raising `Protocol_Error` for different-XID collision until old acknowledgement.
  Current merged main 0f706f9 reproduces both Ada spike failures. Stock
  PG18.4 accepted GID reuse after COMMIT PREPARED (first xid 753, second 754);
  the P1 consumer impact needs first source commit while old consumer
  acknowledgement/marker removal is pending. First sequence is duplicate
  target invocation, mitigated by documented target idempotence. No tracked
  fix now passes replay/collision/old-ack/invalid-input regressions. Independent
  three-file diff review found no actionable P0/P1/P2. Literal core script and
  strictly sequential separate 14.23→18.4 replication runs all passed. An
  earlier accidental parallel 14/15 attempt is not counted. Commit/PR pending.
  PR120 exact head e78961f2 passed all 17 CI checks and merged 2026-09-22
  (3e9128f8); issue should auto-close.
- #69: spike confirmed inactive released slot returns Generation=1 after
  reload, contrary to public zero-when-inactive contract. Maintainer approved
  clearing the stored lease on successful Release while retaining the
  independent future fencing counter. Current merged main reproduced the
  ordinary acquire/release/load failure; tracked fix is one assignment plus
  shared conformance regression. Independent review found no actionable
  P0/P1/P2. Literal core suite and strictly sequential separate 14.23→18.4
  replication integrations all passed. PR121 exact head 1d25c234 passed all
  17 CI checks and merged 2026-09-22 (d6e587d5); issue closed.

## Formal assurance decision

- The producer model is on main under `formal/tla/`, with broken #56/#57/#58
  configurations, TLAPS kernel, trace, and Ada replay (PR99). The #59 LSN
  agreement decision/model extension remains in the later core P2 queue.
- No client extended-protocol model exists on main as of merge c57de390.
  Client lane proposed TLC qualification bounds: two ordered batches, two
  statements, two portals, row widths 1/2, at most two pending Syncs, one
  COPY episode (IN/BOTH/OUT) with one chunk and CopyDone. Asked maintainer
  to approve these non-product bounds before model implementation. #53/#54
  behavior choices remain for the later core P2 phase.

## Core P2 decisions

- #34: maintainer approved matching PostgreSQL's complete `parse_bool`
  grammar for startup `replication` values: case-insensitive full words and
  unique prefixes, exact-length `0`/`1`, bare `o` invalid, while `database`
  remains exact and case-sensitive. Current-main fail-before unit and real
  PG18.4 psql/libpq probes confirmed `TRUE`, `t`, `Off` are passed verbatim
  and rejected FATAL 08P01; `database` succeeds; `Database`/`o` reject.
  pg_basebackup overwrites any user spelling with canonical true/database.
  Private helper + prescribed regression pass focused and literal full-core
  suites; independent review found no actionable P0/P1/P2. PR123 exact head
  405819cf passed all 17 CI checks and merged 2026-09-24 (fcba903c); issue
  closed.
- #36: current main fcba903c reconfirmed that an empty buffer and an empty
  Query payload raise `Postgres string exceeds the configured limit`, while a
  one-byte unterminated string raises `unterminated Postgres string`. Severity
  remains P2: malformed input is rejected either way, but the peer-visible
  diagnostic is wrong. The model-first public Wire Post makes oversized and
  exhausted/beyond-end failure explicit without changing the signature or
  accepted input. The exact-message regression failed before at the empty
  buffer assertion and passes after splitting the Protocol size/exhaustion
  guards. Exact Wire and SCRAM README GNATprove gates pass with no unproved
  checks (341 and 375 checks respectively; only the documented five hmac_ada
  termination assumptions), and the literal full-core suite passes.
  Independent review found no actionable P0/P1/P2. PR124 exact head f5d654ed
  passed all 17 CI checks and merged 2026-09-24 (df3ac9ba); issue closed.
- #43: current main df3ac9ba confirmed both filed mechanisms with real cached
  PG18.4 psql. An authenticated handler exception sent its Ada source path and
  line as FATAL XX000; finite-drain cancellation of an active `\\watch 1`
  client sent no ErrorResponse/SQLSTATE, only an unexpected connection close.
  P2 is accurate; the latter requires finite drain expiry. Fixed internal text
  is local, but 57P01 is blocked by the Flyology connection contract:
  Structured_Servers requests both Handler_Stop and Manager shutdown, and all
  Connection sends observe Manager shutdown even with a null cancellation
  token. A Postgres-local null-token adapter cannot work. Decision requested:
  recommend an upstream, narrowly scoped bounded final-send capability that
  preserves the existing connection lease/TLS state while ignoring only the
  already-requested manager/handler cancellation for that terminal write,
  followed by a reviewed dependency revision. Alternative is a two-phase
  Structured_Servers shutdown/order change, which affects every consumer and
  needs a second grace/acknowledgement policy to preserve finite drain.
  Exact recommended contract awaiting approval: additive public child
  `Flyology.IO.Connections.Shutdown_Writes.Send_All (Item, Shutdown, Data,
  Timeout)`, with no defaults; `Shutdown` is a nonnull already-requested
  handler token, `Timeout` must be nonnegative, and one attempt is consumed per
  adopted descriptor even on failure/abort. It retains the generation-checked
  lease and TLS session, ignores only Manager shutdown and that already-fired
  token, still observes concurrent Close, and resets only on new adoption.
  Misuse/second attempt is Program_Error; the existing timeout/I/O/TLS/socket
  exceptions remain. This requires a separate reviewed Flyology PR and an
  explicitly approved pinned dependency revision before the Postgres PR.
  No tracked #43 edits yet; temporary probes removed and branch clean.
- #44: current main df3ac9ba confirmed the filed four-byte spike reaches a
  16,777,212-byte payload allocation before the second transport call and then
  times out. PostgreSQL 14.23–18.4 all subtract the four-byte length word before
  comparing the remaining payload with `MAX_STARTUP_PACKET_LENGTH = 10000`.
  Real PG18.4 psql/PostgreSQL accepted exact total 10,004 and rejected 10,005;
  stock libpq can emit both through whitespace-only PGOPTIONS. Thus the brief's
  bare 10000 must not be applied to Flyology's total-length predicate.
  Recommended decision: approve **10,004 declared total / 10,000 payload** and
  represent it inline in the existing visible `Wire.Valid_Initial_Length`
  expression with an adjacent PostgreSQL-authority comment. This adds no public
  constant/name/generic/default and keeps Framing's existing pre-allocation
  check. Regression: Wire boundary table plus recording transport proving
  10,004 requests exactly 10,000 payload bytes and 10,005/16MiB reject after
  only the header. Both GNATprove commands and full core suite required. No
  tracked edits; exact value/representation approval pending.
- #45: current main df3ac9ba confirmed both mechanisms on production IPv4
  loopback TCP: incomplete plaintext close is Device_Error without observer
  but TLS_Error with observer; a complete queued eight-byte payload with an
  observer and timeout zero raises before reading. P2/preconditions unchanged.
  Smallest fix uses an `Attempted` local so timeout zero performs one immediate
  receive, preserves one absolute deadline/multi-chunk behavior, and maps an
  observer plaintext early close to Device_Error while retaining TLS_Error for
  encrypted mode. Add TCP regressions and document the already-established
  mode-specific exceptions on the public transport contract. No new API,
  parameter/default/value or unresolved decision. Production IPv4 regressions
  failed before and pass after; exact rebased head e1a98469 passed the literal
  full-core suite and clean independent review. PR128 exact head e1a98469
  passed all 17 CI checks and merged 2026-09-24 (c856ea8a); issue closed.
- #35: current main df3ac9ba confirmed Decode_Initial produces identical
  requests with/without `_pq_.some_option`, and a raw TLS protocol-3.0 startup
  to the maintained server receives AuthenticationSASL first with no `v`.
  Stock libpq 14–18 cannot originate these options, so the affected peer is a
  custom client; P2 unchanged. PostgreSQL 14–18 preserve `_pq_.` names only,
  case-sensitively, in encounter order including duplicates; other names are
  GUCs and must not be reported. Recommended public decision: additive private
  owned `Protocol_Option_List` with Count/Name accessors and
  `Unrecognized_Protocol_Options (Initial_Request)`; keep Startup_Information
  unchanged. Add a four-parameter Send_Negotiate_Protocol overload accepting
  that list and retain the existing zero-option overload, with no default.
  Server sends when requested minor >2 or list nonempty and reports packed
  version `3.min(requested_minor,2)` (so ordinary 3.0 + option reports 3.0,
  not 3.2). Approval of exact list/accessor/overload API pending. Branch clean,
  no tracked edits.
- #48: current main df3ac9ba reproduced all three filed RFC-valid unknown
  `x=1` extension failures exactly: client-first malformed, client-final
  expected-p, server-final invalid-base64. P2/mainstream-interoperability
  qualification unchanged; stock PostgreSQL peers emit no such extensions.
  Body-only SCRAM fix: validate/skip unknown case-sensitive ALPHA attributes
  at the three filed extension slots, explicitly reject reserved `m=` and
  assigned mandatory-name duplicates/out-of-order uses, retain extensions in
  the client-first/client-final proof transcript, and require proof final.
  Add positive and strict negative regressions in tests/src/tests.adb; full
  core suite required, no GNATprove because SCRAM_Core is untouched. No public
  API/decision; implementation held behind earlier ordered items. Branch clean.
- #49: current main df3ac9ba direct and real PG18.4 tests confirmed stored/
  server challenge counts 1,1000,4095 and 1,000,001 authenticate with psql but
  Flyology rejects below 4096 and above 1M; 4096 succeeds. P2 requires a
  non-default/imported verifier. Recommended decision preserves the visible
  names/values/signatures but separates contracts: Make_Verifier_Raw continues
  generating only 4096..1M; Parse_Verifier accepts 1..Positive'Last because no
  PBKDF2 work is done server-side; untrusted server-first remains capped at the
  existing Maximum_Iterations=1M to preserve the established client CPU/DoS
  ceiling. Comments explicitly disclose that roles above 1M remain incompatible.
  Private Parse_Positive takes a required maximum; no new public value/default.
  Full PostgreSQL parity would remove the hostile-server work cap; configurable
  parity would require broad new Startup overloads. Exact option-B approval
  pending. Branch clean, no tracked edits.
- #37: current main df3ac9ba confirmed typed length Max and payload Max-4
  produce a 16,777,217-byte frame while the published total-frame ceiling is
  16,777,216; Max-5 produces exactly Max. P2 contract-only impact confirmed.
  Recommended decision is tighten, preserving the existing constant/name/docs:
  Valid_Typed_Length uses `Length < Maximum_Frame_Size`; Make_Message allows
  payload <= Maximum_Message_Size-5; shared Content_Length Pre becomes valid
  initial OR typed with conditional Posts so exact-Max initial packets remain
  proved. No new public value/type/default; one previously accepted typed edge
  is rejected. Alternative re-documents the constant as a length-word bound
  and leaves initial/typed totals inconsistent. Wire/model-first boundary table,
  real constructor/encode regressions, both GNATprove commands and full core
  suite required. Exact option-A approval pending; branch clean/no edits.
- #32: current main df3ac9ba confirmed wrong-variant accessors return record
  defaults (startup 3/empty, PID 0, empty secret) although the public contract
  promises Protocol_Error. In-repo callers check Kind; external misuse can be
  silently accepted. Existing contract and sibling accessor behavior establish
  the fix: add the three body guards and a fail-before regression. No public
  signature/policy decision. Body guards and fail-before regression passed the
  literal full-core gate and clean independent review. PR125 exact head
  0b7a1dba passed all 17 CI checks and merged 2026-09-24 (5a59ba6d); issue
  closed.
- #33: current main df3ac9ba confirmed complete encoded SSL, Cancel, and Startup
  packets all decode as Unknown because Decode_Initial consumes only bytes after
  the four-byte length. Every repository caller already strips the length and
  Framing owns length validation. Recommend documentation-only correction while
  retaining parameter name Contents (renaming breaks Ada named associations).
  No behavior change; documentation-only regression waiver pending.
- #42: current main df3ac9ba confirmed Serve_TLS(TLS_Disabled) raises
  Program_Error, first pre-stopped Serve returns, and a second Serve raises
  Program_Error because Server is permanently one-shot. Recommend documenting
  the deliberate Program_Error/single-use lifecycle; reusable behavior would
  require broader lifecycle policy because Stop_Requested also persists.
  Exact contract choice and documentation-only regression waiver pending.
- #53: current main df3ac9ba confirmed the filed legal extended sequence fails
  identically on synchronous and scoped typed receives: an unrelated 2-column
  RowDescription poisons a later 1-column DataRow from another portal. Severity
  P2; requires a batch that describes and executes different objects with
  unequal widths. Choice pending between dropping extended cross-event column
  validation (smallest, weakens documented validation) and private ordered
  statement/portal ownership tracking (precise, overlaps #54 and needs lifetime
  semantics). No tracked edits; probe removed.
- #59: current main df3ac9ba confirmed ordinary Begin/Commit and prepared
  BeginPrepare/Prepare payload-LSN mismatches are accepted; stock pgoutput
  itself emits matching pairs, but PostgreSQL 14-18 apply workers reject the
  ordinary mismatch and 15-18 reject the prepared mismatch. Recommend enforcing
  with one private pending LSN and existing Protocol_Error, plus rollback tests.
  The brief explicitly includes #59 in the Producer model scope even though the
  check is straight-line; exact enforcement/model-extension decision pending.
- #60: current main df3ac9ba confirmed Make_Stream_Abort(51,52,53,54)
  encodes correct v4/parallel bytes but both accessors reject the constructed
  value; decoding identical bytes returns 53/54. Fix needs a semantic decision:
  recommend setting Parallel_Stream when either optional metadata value is
  nonzero, preserving signatures/defaults and defining explicit (0,0) as
  metadata absent. Representing explicit zero/zero metadata needs a new public
  presence signal. No tracked edits.
- #64: current main df3ac9ba confirmed undotted SHOW succeeds while constructor
  and decoder reject `myext.my_setting`. PostgreSQL 14-18 all accept recursive
  `var_name '.' IDENT`; stock utilities use undotted names, so P2/custom-peer
  precondition stands. Authorized narrow private dotted-segment predicate using
  the existing ASCII segment grammar only; no `$`/high-bit/quoted/full-IDENT
  widening. Exact rebased head 814aab29 passed the literal full-core suite plus
  five separate ordered 14.23-18.4 replication integrations and clean
  independent review. PR127 exact head 814aab29 passed all 17 CI checks and
  merged 2026-09-24 (6e440efa); issue closed.
- #65: exact main 6e440efa confirmed Flyology always emits IDENTIFY_SYSTEM
  timeline OID 23/size 4. Real PostgreSQL 14.23/15.18 emit 23/4, while
  16.14/17.10/18.4 emit OID 20/size 8. Stock replication tools consume the
  text and remain operational; typed clients/fidelity checks are affected.
  The selector is the emulated server major, not a discoverable peer/client
  major. Recommend a required, non-defaulted Server_Major on
  Send_Identify_System plus required Managed_Primary.Initialize configuration;
  source-breaking but prevents silent mismatch and adds no default/constant.
  Exact public API decision pending; no edits.
- #54: current main df3ac9ba confirmed all four sync/scoped, two-portal traces:
  session-wide suspension rejects unrelated Execute(p2), and later p2 work
  erases p1 suspension so Resume(p1) rejects. Correct private design is a
  dynamically sized suspended-portal set plus ordered execution ownership,
  shared as neutral ledger infrastructure with #53. No public fixed capacity;
  pending client TLA model/bounds and #53 policy keep implementation on hold.
- #52: current main df3ac9ba confirmed synchronous Send_Query rejects in
  pipeline-ready/zero-pending windows while scoped Send_Query writes 14 bytes
  and enters Simple_Query_Active. Existing public contract dictates a shared
  body-private guard, so no decision/API/model change. Four-cell fail-before
  table recorded; post-fix unit and literal full-core suite pass. Independent
  review is clean. PR126 was rebased onto main 5a59ba6d at head d0e5ded5; the
  literal full-core suite and all 17 CI checks passed, and it merged 2026-09-24
  (ae25dd23); issue closed.
- #55: current main df3ac9ba confirmed both synchronous and scoped plaintext
  startup paths remain Not_Started after a 28P01 rejection; retry writes another
  56-byte StartupMessage then fails Device_Error. Public State says Not_Started
  means no packet sent; TLS and libpq/PostgreSQL treat the connection as terminal.
  Recommend Closed for every failure after startup transmission begins while
  preserving Not_Started for preflight/no-byte failures. Exact scope approval
  pending; no edits.

## Deferred discoveries

- Repeated startup `replication` keys have a pre-existing last-value edge:
  after a true value, a later false value leaves Physical mode set because the
  false branch relies on the initial Normal default. This is outside #34's
  filed single-key grammar defect and was not investigated or fixed.
- A clean proof-context cache can fail the README GNATprove commands before
  analysis because the proof solution's GNAT 16.2-specific indirect
  dependencies have not been materialized. `cd proof && alr -n build` before
  the unchanged commands deterministically fixes it; tests use a distinct
  GNAT 16.1 deployment hash. This documentation/workflow correction is outside
  #36 and was not committed there.
- RFC 5802 also permits optional attributes after SCRAM server-first `r,s,i`;
  current `Parse_Server_First` rejects them, and libpq also rejects them. #48
  filed only client-first, client-final, and server-final, so this fourth site
  was classified but not investigated or widened into that fix.

## Next

- Core P1 is complete. Move to core P2 in layer/priority order, with the client
  model once its bounds are approved, and examples last. PR126 (#52), PR127
  (#64), and PR128 (#45) merged and their issues closed. Main is 6e440efa. Earliest
  ordered protocol blocker is unapproved #43; earliest client blocker is the
  #53/model decision; earliest replication blockers are #59/#60 before #65.
  No lane may implement an unresolved public API, bound, or state-machine
  decision.
- Authoritative open-issue audit after main 6e440efa confirms every lane's next
  ordered core item requires a maintainer choice: protocol #43, client #53/model,
  replication #59 (then #60/#65). Advancing to later core items or examples
  would violate the requested queue order.
- Never treat an open decision as approved based on this ledger. Record the
  maintainer's exact answer here and relay it to every affected live lane.
