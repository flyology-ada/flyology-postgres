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

To be populated after the migration and full regression suite pass.

## Interpretation and limitations

This loopback workload is designed to detect overhead in connect, startup,
query send, partial/complete result receive, and synchronous waiting. It is not
a database-capacity benchmark and does not cover TLS, wide or large rows,
storage-bound queries, network delay, or many concurrent clients. Small
differences must be interpreted against the sample spread and host load.
