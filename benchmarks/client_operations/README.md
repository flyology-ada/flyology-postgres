# PostgreSQL client operations benchmark

This benchmark measures two synchronous public-API paths against a local real
PostgreSQL server:

- a full TCP connect, SCRAM startup, simple query, streamed result, terminate,
  and close cycle; and
- repeated simple-query and streamed-result cycles on one established session.

The query returns a row description, eight two-column rows, a command-complete
message, and ready-for-query. Results are consumed without accumulating the
result set. Seven measured samples follow separate connection and query
warmups. The executable reports per-sample throughput and mean latency plus
min/median/mean/max/population-standard-deviation summaries. `run.sh` also
reports total process CPU time and peak resident memory through the platform
`time` utility.

Run the complete reproducible protocol from this directory:

```sh
./run.sh
```

The script uses PostgreSQL 18.4 from the integration-test cache, initializes a
fresh temporary cluster, binds only `127.0.0.1`, and removes the cluster at
exit. Environment variables can override sample counts, warmup counts,
connection/query counts, rows per query, and port; their names and defaults are
printed by the executable.

This is a loopback microbenchmark. It is useful for before/after regression
detection in Flyology/PostgreSQL protocol machinery, but it does not model
network latency, TLS, application work, concurrent clients, or production
database storage. System load, CPU frequency, compiler, PostgreSQL build, and
the first-run fixture build can affect results.
