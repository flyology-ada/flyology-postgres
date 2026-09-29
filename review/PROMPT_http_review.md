# Correctness review of flyology-ada/flyology-http

Run a complete correctness review of `flyology-ada/flyology-http` (the `flyology_http`,
`flyology_quic` and `flyology_iri` crates), verify every finding with a runnable reproduction,
file the confirmed findings as GitHub issues in the established house style, and prepare a
triage brief for Codex. This repeats the procedure used on `flyology-ada/flyology-postgres`
(issues #31 to #93, filed 2026-09-05) and before that on `flyology-ada/flyology` (issues #105
to #197). Use Fable subagents for discovery and other high-level thinking, Opus subagents for
verification, drafting and other routine work.

## Precedent and reusable assets

The flyology-postgres review left its working assets untracked in the worktree
`/Users/yrashk/Projects/flyology-ada/flyology-postgres/.claude/worktrees/ci-pipeline-failure-1b45fd`
(branch `claude/project-correctness-bugs-fcc451`). Copy what you reuse into your own worktree at
the start, since that worktree may be removed:

- `review/filing/STYLE.md`: the issue style (title rules, section order, rules, five reference
  issue bodies from flyology). Reuse verbatim; only the commit hash and the host line change.
- `review/filing/file_issues.py`: validates drafted issue bodies (required sections, commit line,
  no internal IDs, no forbidden words, no em-dashes), files them in dependency order with pacing
  and retry, patches `{{ISSUE:<ID>}}` cross-references after filing, writes `review/ISSUES.md` and
  substitutes issue numbers into the triage brief. Change `REPO`, `ORDER`, the commit hash in the
  validator, and the `FORBIDDEN` list to your harness names.
- `tests/repros/run.sh`, `run-all.sh`, `README.md`, `src/repro_support.ad?`: the repro-harness
  pattern (one program per finding, `Check`/`Note`/`Finish`, exit 1 = `BUG REPRODUCED`, 0 = PASS,
  124 = hang, build lock for concurrent agents). The build side must change for this repository;
  see "Harness" below.
- `review/TRIAGE_FOR_CODEX.md`: the brief to mirror (ground rules, confirm-before-fixing, master
  and lanes of at most three, model-first, layered issue lists with DECISION tags).
- `FINDINGS.md`: the consolidated findings document to mirror.
- `review/discovery-*.md` and `review/verification-*.md`: examples of the discovery and
  verification report formats.

Read three or four of the filed issues to calibrate the register before drafting anything:
https://github.com/flyology-ada/flyology-postgres/issues/38 (P0, server),
https://github.com/flyology-ada/flyology-postgres/issues/51 (P1, client state machine),
https://github.com/flyology-ada/flyology-postgres/issues/73 (parser, oracle comparison),
https://github.com/flyology-ada/flyology/issues/179 (the flyology reference style).

## This repository was audited once already

`proof/proof-status.md` opens with "Fable 5 prevention coverage" and refers to findings #1 to
#47 from an earlier review of this repository; the git log carries their fixes (for example
"HTTP/2 request pseudo-headers reach the application unvalidated", "Repeated Cookie request
lines are comma-joined", "Decoded query values may carry NUL and control bytes", "A blocked
HTTP/2 checkout spins past its deadline", "IDNA admits invisible and bidi-inconsistent host
characters"), and a commit titled "The audit report does not record which findings are closed"
says a report exists. Those findings were fixed in-tree and never filed on GitHub (the
repository has one open issue, #11, and no closed ones). Before discovery:

- Locate the audit report and its findings list (`git log --all -i --grep=audit`,
  `rg -n "Finding #" --glob '!obj/**'`, and the untracked contents of
  `/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/findings-fable5-agent-swarm-f2a48d`).
  Copy it into your `review/` as `prior-audit.md` and read it in full.
- Treat its findings as known. Do not re-report one unless its fix has regressed at current
  `main`, in which case the finding is new and must say so. A cheap regression pass over the
  prior findings' own tests is worth doing; report its result in `FINDINGS.md`.
- Use its subsystem partition and its "no findings" lists to aim the new discovery at what
  has changed since and at what it did not cover. `CHANGELOG.md` "Unreleased" and the merged
  pull requests since #24 list the new surface: composable owner-driven client exchanges (#33,
  #40), the SSE client across all three protocols (#44), scoped H1 stale-lease recovery (#39),
  exact fixed-length response streams (#28, #29), S3-driven request fidelity and streamed H2/H3
  uploads (#24, #25), the HTTP/3 stream receive credit and settlement fixes, and the QUIC
  handshake recovery and listener-slot work (#20 to #22).

## Setup

- The main checkout at `/Users/yrashk/Projects/flyology-ada/flyology-http` is on `main` and
  clean. Create your own worktree from `origin/main` (fetch first) and run everything from that
  worktree with absolute paths; never `cd` into another checkout. The shell's working directory
  persists between calls.
- Follow `AGENTS.md` (generated by APM) and its "Repository workflow" section: `apm install
  --frozen`, `apm compile --target codex`, `git status --short --branch` before changing anything.
  Refer to repository rules by `AGENTS.md` section name everywhere ("Flyology HTTP agent guide",
  "Decision authority", "Ada interface values", "Ada source style", "Review cycle", "Commits",
  "Performance testing", "TLA+ assurance"), never by `.claude/...` path.
- Dependencies: `flyology = "=0.1.1-dev"` (exact), `flyology_cachelines = "=0.1.0"`, and the
  in-tree `flyology_quic` which CI pins with `alr pin flyology_quic --use=flyology_quic`. The
  sibling checkout `/Users/yrashk/Projects/flyology-ada/flyology` is at 0.2.0, not the pinned
  version; `scripts/test.sh` only takes the sibling path when `../scripts/prepare-rts.sh` exists,
  which is false from a worktree, so stay in the worktree and confirm what
  `scripts/resolve-flyology-root.sh` prints before trusting a run. `scripts/test.sh` re-executes
  itself under `alr exec` and prepares a version-matched Flyology runtime under `build/rts`; the
  QUIC test script refuses the default RTS and needs that prepared one (`FLYOLOGY_QUIC_TEST_RTS`).
- Establish the baselines before any review work, in the background, and record which ran and
  how long each took: `alr build`; `./scripts/test.sh` (client, server, WebSocket, TLS, policy,
  negative-lifetime and compile-fail tests, plus the "no tasks in client units" grep); `./scripts/
  http2-test.sh prepare` then `all` (pinned python-hyper h2 peer, HPACK differential);
  `./scripts/http-client-differential.sh run` (Ada versus PycURL); `./scripts/test-http3-interop.sh
  all` (aioquic 1.3.0 and quic-go 0.54.1, both roles); `./scripts/test-http3-h3spec.sh`;
  `./scripts/test-http3-stress.sh`; `./scripts/prove.sh` (the QUIC policy units and about twenty
  HTTP policy units, `--checks-as-errors=on`); `./scripts/check-sse-client-formal.sh` (the SSE
  reconnect TLA+ model and its trace replay through the `flyology-ada/tla` harness);
  `./scripts/check-test-hook-elision.sh`; `flyology_quic/scripts/test.sh`; the `flyology_iri`
  tests and `flyology_iri/scripts/wpt-gate-test.sh` (pinned WPT URL corpus); and, where Docker is
  available, `./scripts/http2-test.sh h2spec` and the Autobahn WebSocket configurations under
  `tests/autobahn`. Docker and the Go toolchain may be absent; say which baselines did not run.
  A baseline that fails is itself a finding; do not proceed on a red baseline without saying so.
- Alire redeploys into one shared cache on every command: never run two `alr` commands
  concurrently across agents. The test scripts also bind loopback ports and start Python peers;
  serialize suite runs, and make every spike pick an ephemeral port. The git stash stack is
  shared across worktrees; never use bare `git stash`. Do not modify any tracked file; every
  output (reports, harness, findings, issue bodies, brief) is an untracked addition. Do not
  commit or push unless the user asks.

## Scope and partition

`src/` is about 53,000 lines in 159 files (largest: `flyology-http-client.adb` 7,400,
`flyology-http-server.adb` 4,800, `server-routing.adb` 3,300, `server-http_2.adb` 2,800,
`http_2_client_connection.adb` 2,400, `server-http_3.adb` 2,100); `flyology_quic/src` is
20,000 lines; `flyology_iri/src` is 3,800. Nothing is generated except the SSE conformance
adapter under `formal/sse_client/ada/generated`. Prioritise the surfaces where a defect is severe:
bytes parsed from a hostile peer, request smuggling and header injection, TLS and QUIC key
handling, path decoding before routing, flow-control and window arithmetic, pool and lease
lifetime under cancellation. Propose about twelve discovery areas along these lines and adjust
after reading the tree and the prior audit:

- H1-CLIENT: `client-http_1_internals`, `http_chunk_encoding`, `headers`, `methods`, the
  response-head and body paths in `client.adb` (RFC 9112 framing: Content-Length versus
  Transfer-Encoding precedence and conflict rejection, chunk-size overflow and extensions,
  trailers, obsolete line folding, header count and size bounds, 1xx and 100-continue handling,
  HEAD/204/304 body rules, connection close and half-close, Upgrade).
- H1-SERVER: `server.adb`, `server-requests`, `server-responses`, `server-connections`,
  `server-connection_handlers`, `expect_policy`, `fixed_response_policy` (request-target forms,
  Host validation, Expect handling, keep-alive and pipelining ordering, body limits and drains,
  deadline delivery, error status mapping, response-length accounting, the smuggling rules).
- ROUTING-MW: `server-routing`, `route_parameter_policy`, `decoded_path_policy`,
  `native_routes`, `server-applications(-internals)`, every `middleware_*`, `server-cors`,
  `server-compression`, `rate_limit_policy`, `server-logging`, `server-metrics` (percent
  decoding and dot segments before matching, parameter capture, method dispatch with 405 and
  Allow, HEAD and OPTIONS, CORS preflight and credential rules, rate-limit window arithmetic,
  bulkhead accounting under exceptions, compression framing and Accept-Encoding parsing,
  security headers, request-id propagation).
- CLIENT-POOL: `client.adb`, `client-pool_controller`, `client-state_lifetime`,
  `client_policy`, `client-authentication`, `client-request_bodies(-channels,-files)`, the
  composable exchange operations (pool admission and release on every exit path including
  cancellation and abort, stale-lease replay eligibility, redirect policy including method
  rewriting and cross-origin credential stripping and loop limits, Basic/Digest/Bearer challenge
  parsing, deadlines, Unix-socket transports, origin binding, body source rewind).
- H2: `http_2_frames`, `http_2_hpack`, `http_2_huffman`, `http_2_payloads`, `http_2_settings`,
  `http_2_policy`, `http_2_requests`, `http_2_responses`, `http_2_client_connection`,
  `server-http_2` (RFC 9113 and RFC 7541: frame length and padding bounds, HPACK integer
  overflow, dynamic-table size updates and eviction order, Huffman padding and EOS rules,
  connection and stream flow-control windows including negative and overflowed windows,
  SETTINGS validation and acknowledgement, the stream state machine, RST_STREAM and GOAWAY
  last-stream-id semantics, CONTINUATION sequencing, header-list size limits, pseudo-header
  validation, preface, PING, concurrent-stream limits).
- H3-QPACK: `http_3*`, `qpack_*`, `header_huffman_policy`, `server-http_3`,
  `http_3_client_connection`, `http_3_connection` (RFC 9114 and RFC 9204: frame types on each
  stream kind, control-stream and SETTINGS rules, unidirectional stream type handling, reserved
  and greased values, QPACK prefixed integers and static-table indexing under the zero
  dynamic-capacity profile, field-section prefix validation, stream receive credit, GOAWAY,
  request and response header validation, trailers).
- QUIC-TRANSPORT: `flyology_quic` connection driver, packet spaces, senders and receivers,
  packet-number, recovery, flow-control, stream-table and reassembly, ack-range,
  transport-parameter, varint, long- and short-header and protection policies (RFC 9000 and
  RFC 9002: packet-number decoding, loss detection and PTO arithmetic, ack ranges and delay,
  anti-amplification limit, retry and version negotiation, connection-id handling, stateless
  reset, idle timeout, stream and data limits, reassembly bounds, key phase).
- QUIC-TLS: `tls_session`, `tls_key_schedule`, `tls_handshake_policy`,
  `tls_extension_policy`, `tls_signature_policy`, `tls_authentication_policy`,
  `crypto_openssl`, `crypto_flight`, `crypto_reassembly_policy` (RFC 8446 and RFC 9001: handshake
  state machine, key schedule and transcript hashing, certificate verification and name
  matching, ALPN, the transport-parameter extension, 0-RTT and HelloRetryRequest rejection,
  signature algorithms, key update, secret wiping on failure paths).
- WEBSOCKET: `websocket_client`, `websocket_client_policy`, `websocket_policy`,
  `websocket_deflate_policy`, `server-websocket_handlers(-lifecycle)`,
  `server-websocket_deflate` (RFC 6455 and RFC 7692: masking, fragmentation with interleaved
  control frames, close codes and close handshake ordering, UTF-8 validation across fragments,
  reserved bits, 64-bit lengths, permessage-deflate context takeover and window-bits
  negotiation, Sec-WebSocket-Accept, subprotocol and origin checks, pool lifetime).
- SSE: `client-sse`, `sse_client_policy`, `server-sse_handlers`, the model under
  `formal/sse_client` (WHATWG EventSource: BOM, CR/LF/CRLF line endings, field parsing,
  comments, `retry`, `id` with NUL, reconnect state and `Last-Event-ID`, 204, media-type
  checks, deadline and cancellation; whether the model's actions still match the Ada boundary
  after the composable-client rework).
- IRI: `flyology_iri` (RFC 3986/3987 and WHATWG URL parsing, IDNA subset per UTS #46,
  resolution and dot-segment removal, percent encoding, IPv4 and IPv6 normalisation, `file:`),
  with the pinned WPT corpus and the Ada URL differential as oracles; note the recorded
  `-gnatp` on `flyology_iri.adb` in the release profile.
- LIFETIME: `client-state_lifetime`, the `compile_fail` tests, `server-request_tasks`,
  `server-exchange_backends`, `server-tls`, `server-development_certificates`, the test hooks
  under `src/test_hooks/connection`, and the barrier points in
  `tests/flyology-io-connections-testing.ads` (cancellation and deadline delivery in native and
  lightweight lanes, abort safety of controlled objects on exception paths, leases released
  exactly once, the "no task in client units" invariant).

Reference material for interop claims: the RFCs named above, the WHATWG HTML and URL
standards, the pinned independent peers the scripts already provide (python-hyper h2, h2spec
2.6.0, aioquic 1.3.0, quic-go 0.54.1, h3spec, PycURL, Autobahn, the WPT URL corpus), and `curl`
where installed. A claim about what a browser or another server does that you cannot check
against one of these must say so.

## Severity rubric

- P0: memory or aliasing unsafety, security-relevant (request smuggling, header or response
  splitting, authentication or TLS-verification bypass, key or secret exposure, path traversal
  through decoded paths, a single hostile packet or frame that stalls or amplifies), silent
  corruption of request or response bytes, hang or deadlock in normal operation, or an
  interop-breaking protocol violation that a stock peer (curl, browsers, nginx, python h2,
  aioquic, quic-go) rejects.
- P1: wrong result or unexpected exception on valid input via a reachable path, or a documented
  contract violated (`.ads` comment, README, guide pages, conformance documents under `tests/`).
- P2: edge-case incorrectness, wrong diagnostics, or contract drift needing unusual input.

Documented policy values (limits, defaults, capacities, timeouts) are not bugs unless they break
a protocol rule or a documented invariant; report them separately under "Observations not
counted". The repository's "Grounded communication" and "Performance testing" sections apply to
any performance observation: measure or do not claim.

## Phase 1: discovery

One Fable subagent per area, read-only, launched in batches of at most four (nine at once hit
the Fable limit in the postgres run; if an agent dies on a rate limit, relaunch it, and fall
back to Opus if the limit persists). Each agent writes `review/discovery-<AREA>.md`
incrementally, creating the file after its first finding so a crash preserves partial results,
and rewrites the header at the end. Report format: scope; the rubric; a summary table (ID, title,
severity, confidence); per finding `### <AREA>-<n>: <title>` with Location (file:line),
Severity, Confidence, Evidence (exact quoted lines), Failure scenario, Reproduction test sketch
(concrete calls, bytes or frames, expected versus actual, expressible without an external peer
where possible), Existing coverage; then "Areas reviewed with no findings" and "Observations not
counted". Instruct each agent to read the `.ads` contracts and the prior audit's entries for
its area first, to check reachability through real callers, and to try to refute each candidate
itself.

## Phase 2: adversarial verification

One Opus subagent per area. It must try to refute each finding against the source (and the RFC
text, the peers or the oracles where relevant), and for every finding that survives write a
reproduction program under the harness and run it. Verdicts: CONFIRMED, REFUTED, PARTIALLY
CONFIRMED, DOCUMENTED LIMITATION, UNVERIFIABLE; corrected severity with the rubric; a
one-paragraph description. Report to `review/verification-<AREA>.md` with sections
`### <ID>: <title>` and fields Verdict, Severity, Repro, Output, Description.

Harness: this repository's tests are not an Alire crate with a plain `alr build`; they are
built by `scripts/test.sh` with `gprbuild --RTS=build/rts --subdirs=<name> -P tests/http_tests.gpr`
under `alr exec`, with `GPR_CONFIG` unset, a macOS sysroot workaround, and
`FLYOLOGY_TLS_TEST_HOOKS=true`. Build the repro harness the same way: a `tests/repros/` directory
whose `run.sh` sources `scripts/alire-test-context.sh`, reuses `test.sh`'s `run_gprbuild`
logic, selects its own `--subdirs`, adds `tests/` to the source path so the barrier points and
TLS test provider are available, and builds one main per finding. Provide support for the four
levels a spike needs: direct package calls (policy units, HPACK, frames, chunk encoding, IRI);
an in-process loopback client and server over Flyology sockets on an ephemeral port (as
`tests/http_smoke.adb` does); a raw peer inside the spike that writes crafted bytes, frames or
packets to the server or answers the client (GNAT.Sockets or Flyology.IO.Sockets, with the
`Flyology.QUIC.Test_Connections` helpers for QUIC); and the pinned independent peers through the
existing scripts and Python environments for interop claims. A spike asserts the correct
behaviour and must print `BUG REPRODUCED` and exit 1 on current sources. Every confirmed finding
gets one program; a finding only reachable through Docker or an absent toolchain is verified as
far as the environment allows and the report says exactly what was and was not run. After all
verifications, run `run-all.sh` so the evidence table is one clean sweep.

Verifiers may raise new findings they trip over; give them the next number in that area and
verify them the same way.

## Phase 3: consolidation

Write `FINDINGS.md` at the worktree root mirroring the postgres one: scope and method, the
prior-audit regression pass and its result, the rubric, how to reproduce, a totals table per
area, an index table (ID, severity, title, location, repro), per-area sections with Severity,
Location, Repro, What is wrong, Notes (maintainer decisions needed, tests that assert the current
wrong behaviour, refuted sub-claims, duplicates), and appendices with per-area coverage evidence
and the artifact list. Copy every discovery and verification report into `review/`. Report
totals honestly, including which baselines and peers could not be exercised.

## Phase 4: issue bodies and filing

- Draft one body per confirmed finding into `review/filing/<ID>.md` using `STYLE.md`, with Opus
  subagents, one per area. Each body re-runs its repro for fresh output, verifies every file:line
  with `sed -n` at the reviewed commit, cites the RFC section or standard clause and the peer
  behaviour it relies on, folds duplicates into the primary issue, uses `{{ISSUE:<ID>}}` for
  cross-references, names any existing test that asserts the wrong behaviour, and says "This
  needs a maintainer decision" with the options wherever a fix adds a public constant, variant,
  parameter or default ("Decision authority" and "Ada interface values"). A fix inside a proved
  policy unit must say that `./scripts/prove.sh` gates it. Label `bug`; add `documentation` only
  for pure contract drift. No internal IDs, no mention of the review, agents, Claude, the harness
  directories, `FINDINGS.md` or the prior audit's numbering in any title or body. Refer to
  repository rules by `AGENTS.md` section, never by `.claude` path.
- Validate with `file_issues.py --dry-run` until every body passes.
- Stop and ask the user before filing (this is an outward-facing action on a public repository):
  show two sample bodies and the totals, and ask three things at once: file all or only P0 and P1;
  push the review branch with the harness or keep it local (the postgres review kept it local,
  so the issues had to be self-contained); the lane order for the brief. Then file with
  `file_issues.py --file` (paced, in dependency order), run `--resolve` to patch forward
  references and to substitute issue numbers into the brief, and check the list on GitHub
  (count, labels, no leaked IDs).
- Record the finding-to-issue mapping in `review/ISSUES.md` and in a project memory note, as the
  postgres review did.

## Phase 5: triage brief for Codex

Write `review/TRIAGE_FOR_CODEX.md` mirroring the postgres brief: ground rules citing `AGENTS.md`
sections and the verification commands per area (`./scripts/test.sh` for any `src/` change;
`./scripts/prove.sh` for the policy units; `./scripts/http2-test.sh all` and the h2spec target
for HTTP/2; `./scripts/test-http3-interop.sh all`, `test-http3-h3spec.sh` and `test-http3-stress.sh`
for HTTP/3 and QUIC, plus `flyology_quic/scripts/test.sh` and its `prove.sh` for the transport
crate; `./scripts/http-client-differential.sh run` and `http-client-conformance.sh` for the
client; `./scripts/check-sse-client-formal.sh` for anything touching the SSE lifecycle; the
Autobahn configurations for WebSocket; `flyology_iri` tests and the WPT gate for IRI;
`./scripts/check-test-hook-elision.sh` for anything touching the hooks; `./scripts/docs.sh` for
public specification changes; `git diff --check` and the maintained formatter); one issue per
PR with `Closes #N`, Problem/Solution commits, no attribution footers; regression tests placed
in the existing smoke, matrix, corpus and conformance suites under `tests/` rather than new
files; "Confirm every finding before fixing it" (re-read at current `main`, rebuild the spike,
drive the real peer where the scripts provide one, report disagreements to the master); "Work
organization" (one master task, lanes of at most three in separate worktrees, serialized Alire,
port and Docker use, reports after every merged PR, DECISIONs through the master); "Model
first" aligned with the "TLA+ assurance" section (SPARK contracts for anything inside the proved
policy boundary; the existing SSE model to extend where a finding touches it; new bounded TLA+
models with a `_broken` configuration for multi-step state machines such as the HTTP/2 stream
state and flow-control interplay, the client pool lease lifecycle, and the QUIC recovery and
packet-space transitions, with TLC and TLAPM both and replay through the shared
`flyology-ada/tla` harness); then the layered issue lists, P0 before P1 before P2, each entry
with the issue number, the one-line fix direction, dependencies, and DECISION or MODEL FIRST
tags; and an "Explicitly out of scope" section for issue #11 and any open PRs. Propose a layer
order that puts the surfaces hostile peers reach first (H1 server and routing, then H2, then
H3 with QUIC, then the client and pool, then WebSocket and SSE, then IRI), and let the user
change it.

## Final report to the user

Lead with the outcome (confirmed counts by severity and area, the P0s in one line each, the
prior-audit regression result), then what was not exercised, then where everything lives
(FINDINGS.md, review/, harness, issue range, brief), then the maintainer decisions the fixes
need. Keep the user's own rules for communication: short sentences, no em-dashes, no hedging
about verified facts, and a plain statement of anything that failed or was skipped.

## Pitfalls seen in the postgres run, plus this repository's own

- Nine Fable discovery agents at once hit the Fable rate limit; eight died mid-review. Batch
  them, and have every agent write its report incrementally.
- `SendMessage` to an existing subagent may be disabled; spawn a fresh agent with the context
  it needs instead.
- The Bash tool's working directory persists between calls; use absolute paths.
- A subagent may be refused when asked to write a findings or report `.md` file; if so, have it
  return the content and write the file yourself, or extract the text from its transcript with
  a script that writes straight to disk (never dump a subagent transcript into your context).
- Pace `gh issue create` (about six seconds apart) and retry on secondary rate limits.
- The issue-body validator must not forbid legitimate domain words, and no `.claude` reference
  belongs in an issue or in the brief at all.
- Several severities moved during verification, both up and down. Keep the verifier's corrected
  severity, with the discovery severity noted.
- This repository's suites are long-running and self-nesting: `scripts/test.sh` re-executes under
  `alr exec`, prepares a runtime, and builds dozens of mains; run baselines in the background
  with generous timeouts and never in parallel with each other or with `alr`.
- Spikes and suites share loopback ports and the Python peer environments under `build/`; use
  ephemeral ports in spikes and never run a spike against a peer while a suite is using it.
- The QUIC scripts refuse the stock RTS; point them at the runtime `scripts/test.sh` prepared.
- The prior audit fixed findings in-tree with SPARK "prevention" units; a regression there is a
  proof failure as much as a test failure, so run `./scripts/prove.sh` in the baseline.
