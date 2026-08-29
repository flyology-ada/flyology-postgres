# Composable operations performance report

This report records the controlled before/after benchmark for the migration to
Flyology composable operations. Both measurements use the benchmark source and
protocol documented in `README.md`; only the Flyology dependency and PostgreSQL
implementation differ.

## Environment

Measurements run on 2026-08-21 in America/Vancouver on a MacBook Pro
(`Mac15,9`) with an Apple M3 Max, 16 cores (12 performance, 4 efficiency), and
48 GB RAM. The host ran macOS 26.5.2 / Darwin 25.5.0. The Ada toolchain was
GNAT 16.1.0 through Alire 2.1.1; OpenSSL was 3.6.3.

`tests/scripts/ensure-postgres.sh` supplied PostgreSQL 18.4, compiled with its
documented default four build jobs and PostgreSQL's optimized build defaults.
Every benchmark invocation initialized a new cluster with host authentication
set to `scram-sha-256` and ran the server on loopback with:

```text
-h 127.0.0.1 -p 55439 -F -c synchronous_commit=off
-c full_page_writes=off -c jit=off -c ssl=off -c max_connections=100
```

The benchmark crate and Flyology Postgres were compiled in release mode. The
recorded command, from `benchmarks/client_operations`, was:

```sh
./run.sh
```

Defaults were seven samples, 50 connection warmups, 500 query warmups, 500
measured full connection cycles per sample, 5,000 measured persistent queries
per sample, and eight two-column rows per query.

## Baseline

Baseline Flyology Postgres revision: `f9101bc486e76f458d424a2ce93f916a6fc29839`.
The dependency was the indexed `flyology 0.1.1-dev`; no GitHub pin or operation
implementation was present.

| Sample | Full cycles/s | Full latency (µs) | Query cycles/s | Query latency (µs) | Rows/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 96.173 | 10,397.915 | 13,143.888 | 76.081 | 105,151.100 |
| 2 | 96.839 | 10,326.451 | 13,803.488 | 72.445 | 110,427.902 |
| 3 | 61.645 | 16,221.932 | 4,482.945 | 223.068 | 35,863.561 |
| 4 | 72.004 | 13,888.185 | 13,505.438 | 74.044 | 108,043.501 |
| 5 | 95.549 | 10,465.802 | 12,743.667 | 78.470 | 101,949.335 |
| 6 | 96.067 | 10,409.437 | 13,610.255 | 73.474 | 108,882.041 |
| 7 | 75.261 | 13,287.075 | 2,394.809 | 417.570 | 19,158.475 |

| Metric | Min | Median | Mean | Max | Population σ |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full connect/query/result cycles/s | 61.645 | 95.549 | 84.791 | 96.839 | 13.668 |
| Persistent query/result cycles/s | 2,394.809 | 13,143.888 | 10,526.356 | 13,803.488 | 4,528.288 |
| Persistent result rows/s | 19,158.475 | 105,151.100 | 84,210.845 | 110,427.902 | 36,226.306 |

The whole timed process consumed 48.74 s wall time, 28.25 s user CPU, and
1.31 s system CPU. macOS `/usr/bin/time -l` reported 2,850,816 bytes maximum
resident set size and 1,638,736 bytes peak memory footprint.

Samples 3 and 7 show simultaneous full-cycle and persistent-query slowdowns,
consistent with external host contention rather than one protocol path. The
median is therefore the primary before/after signal; the complete distribution
is retained so the noise is not hidden.

## Composable-operations result

Initial candidate Flyology Postgres revision:
`d7e0f090ff3b30423d3fac074eb7501d6c084279`.  The GitHub dependency resolved
the `codex/composable-operations` branch of Flyology PR #60 at
`1810fc60ba41bd9029a7d1c96c0e326af1ad415a`.

Two complete candidate campaigns were retained because this shared host was
heavily contended.  The first ran at revision `1e19383` after the full
PostgreSQL 14--18 regression matrix; the only later implementation change
scrubs copied startup credentials during operation cleanup and does not touch
the measured synchronous path.  Its post-run load averages were
53.66/36.20/33.25 on 16 cores, and `/usr/bin/time -l` counted 141,151
involuntary context switches.

| Sample | Full cycles/s | Full latency (µs) | Query cycles/s | Query latency (µs) | Rows/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 95.544 | 10,466.382 | 12,778.200 | 78.258 | 102,225.600 |
| 2 | 93.598 | 10,683.989 | 13,063.100 | 76.552 | 104,504.800 |
| 3 | 86.026 | 11,624.393 | 7,207.640 | 138.742 | 57,661.120 |
| 4 | 84.165 | 11,881.423 | 8,804.230 | 113.582 | 70,433.840 |
| 5 | 88.912 | 11,247.076 | 7,994.340 | 125.089 | 63,954.720 |
| 6 | 57.154 | 17,496.588 | 9,653.020 | 103.595 | 77,224.160 |
| 7 | 72.488 | 13,795.387 | 10,705.000 | 93.414 | 85,640.000 |

| Metric | Min | Median | Mean | Max | Population σ |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full connect/query/result cycles/s | 57.154 | 86.026 | 82.555 | 95.544 | 12.492 |
| Persistent query/result cycles/s | 7,207.640 | 9,653.020 | 10,029.360 | 13,063.100 | 2,103.130 |
| Persistent result rows/s | 57,661.120 | 77,224.160 | 80,234.880 | 104,504.800 | 16,825.040 |

That process consumed 48.13 s wall time, 29.12 s user CPU, and 1.68 s system
CPU.  Maximum resident set size was 2,850,816 bytes and peak memory footprint
was 1,573,200 bytes.

The confirmation campaign used the final candidate revision.  Its post-run
load averages were still 24.29/25.22/27.70, and it counted 121,001 involuntary
context switches.

| Sample | Full cycles/s | Full latency (µs) | Query cycles/s | Query latency (µs) | Rows/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 84.967 | 11,769.293 | 6,069.282 | 164.764 | 48,554.257 |
| 2 | 81.994 | 12,196.087 | 8,576.743 | 116.594 | 68,613.945 |
| 3 | 84.968 | 11,769.142 | 12,377.258 | 80.793 | 99,018.061 |
| 4 | 89.035 | 11,231.553 | 11,357.895 | 88.044 | 90,863.160 |
| 5 | 88.794 | 11,262.021 | 12,331.812 | 81.091 | 98,654.497 |
| 6 | 87.712 | 11,400.953 | 11,802.742 | 84.726 | 94,421.936 |
| 7 | 84.415 | 11,846.288 | 13,089.535 | 76.397 | 104,716.279 |

| Metric | Min | Median | Mean | Max | Population σ |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full connect/query/result cycles/s | 81.994 | 84.968 | 85.983 | 89.035 | 2.410 |
| Persistent query/result cycles/s | 6,069.282 | 11,802.742 | 10,800.752 | 13,089.535 | 2,351.761 |
| Persistent result rows/s | 48,554.257 | 94,421.936 | 86,406.019 | 104,716.279 | 18,814.088 |

The confirmation process consumed 45.14 s wall time, 29.33 s user CPU, and
1.55 s system CPU.  Maximum resident set size was 2,883,584 bytes and peak
memory footprint was 1,605,968 bytes.  Compared with baseline, RSS increased
by 32 KiB while peak footprint decreased by 32 KiB.

The contended candidate medians are 11.1% lower for full cycles and 10.2%
lower for persistent queries than the baseline medians.  This initially looks
material, so the measured path and distribution were investigated rather than
accepting the aggregate.  The benchmark deliberately uses the familiar
synchronous API over `Transports.Sockets.Socket_Transport`; it does not enter
the new operation provider or the Flyology connection-driver capability.  The
socket transport itself has no implementation diff from the baseline.  The
first candidate campaign also reached 95.544 full cycles/s and 13,063.100
persistent queries/s, respectively within 0.01% and 0.62% of the baseline
medians, before both phases slowed together as host load rose.  That
simultaneous degradation, the extreme run-queue load, and the context-switch
counts identify host contention rather than an operation-specific hot path.

The evidence therefore shows that the existing performance profile remains
reachable, with no steady-state memory-footprint regression attributable to
waiting.  It does not support a precise small before/after delta on this host.
A dedicated or otherwise quiet runner is required before treating differences
below the observed contention spread as implementation signal.

## Final foundation campaign

The final campaign used benchmark source revision
`72a16b6c007a297d873216b6eb5e43c2df427f7f` plus the uncommitted exact
dependency pin that was subsequently committed with this report.  All three
consumer workspaces resolved Flyology PR #60 at
`195b2289cb436a404ea67a7784799be6daa55d6a`.  This revision includes the
cross-operation liveness fix that performs a zero-time descriptor pass after
an immediate provider pass.  The benchmark workspace was regenerated from
scratch and its checkout SHA was verified before measurement.

The campaign was serialized against the other consumer benchmark and started
only after unrelated CPU-saturated compiler probes were paused.  Host load
averages were 7.27/18.37/33.60 immediately before the run and
11.24/17.30/31.83 immediately after it.  The one-minute load remained below
the machine's 16 logical cores at both recorded boundaries;
the longer averages retain load from the earlier contention.

| Sample | Full cycles/s | Full latency (µs) | Query cycles/s | Query latency (µs) | Rows/s |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 103.332 | 9,677.584 | 12,941.025 | 77.274 | 103,528.198 |
| 2 | 102.555 | 9,750.845 | 12,968.456 | 77.110 | 103,747.646 |
| 3 | 100.670 | 9,933.465 | 14,119.057 | 70.826 | 112,952.458 |
| 4 | 98.670 | 10,134.813 | 12,927.652 | 77.354 | 103,421.217 |
| 5 | 99.224 | 10,078.185 | 12,934.960 | 77.310 | 103,479.677 |
| 6 | 101.482 | 9,854.000 | 12,740.272 | 78.491 | 101,922.178 |
| 7 | 102.473 | 9,758.656 | 13,253.371 | 75.453 | 106,026.971 |

| Metric | Min | Median | Mean | Max | Population σ |
| --- | ---: | ---: | ---: | ---: | ---: |
| Full connect/query/result cycles/s | 98.670 | 101.482 | 101.201 | 103.332 | 1.633 |
| Persistent query/result cycles/s | 12,740.272 | 12,941.025 | 13,126.399 | 14,119.057 | 428.627 |
| Persistent result rows/s | 101,922.178 | 103,528.198 | 105,011.192 | 112,952.458 | 3,429.013 |

The timed process consumed 38.15 s wall time, 27.16 s user CPU, and 1.14 s
system CPU.  macOS `/usr/bin/time -l` reported 2,834,432 bytes maximum
resident set size, 1,556,792 bytes peak memory footprint, 55,877 involuntary
context switches, and no voluntary context switches.

Against the baseline medians, final full connect/query/result throughput is
6.21% higher and persistent query/result throughput is 1.54% lower.  Maximum
RSS is 16 KiB lower and peak footprint is 81,944 bytes lower.  The persistent
difference is well inside the measured sample spread, while the full-cycle
distribution improves beyond the baseline.  This complete, lower-contention
campaign therefore finds no material performance or memory regression from
the composable-operations migration or final Flyology foundation revision.

## Interpretation and limitations

This loopback workload is designed to detect overhead in connect, startup,
query send, partial/complete result receive, and synchronous waiting. It is not
a database-capacity benchmark and does not cover TLS, wide or large rows,
storage-bound queries, network delay, or many concurrent clients. Small
differences must be interpreted against the sample spread and host load.  The
current benchmark intentionally protects synchronous parity; the synthetic
and real-TLS regression suites cover operation composition, but a separate
concurrent operation-throughput workload remains useful future work once a
quiet performance runner is available.
