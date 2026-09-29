Title: Logical.Producer accepts a Commit whose commit LSN disagrees with the pending Begin's final LSN
Labels: bug
Refs: none

## Summary

`Producer.Emit` stores only the XID when it sees a `Begin`, and compares only the XID when it sees the matching `Commit`. The Begin's final LSN is never retained, so a Commit carrying a different commit LSN is validated and encoded. PostgreSQL's apply worker compares the two and raises `ERRCODE_PROTOCOL_VIOLATION` on the mismatch, so the producer signs off on a stream a real subscriber refuses. The same gap exists between `BeginPrepare` and `Prepare`.

## Problem

Commit `6f496f5`.

The `Begin` arm keeps the XID and nothing else (`src/flyology-postgres-replication-logical-producer.adb:54-59`):

```ada
when Begin_Message =>
   Require
     (Item.Current = Idle and then Logical.Transaction (Message) > 0,
      "Begin requires an idle pgoutput producer");
   Item.Current := Regular_Transaction;
   Item.XID := Logical.Transaction (Message);
```

The `Commit` arm does not even compare the XID (`src/flyology-postgres-replication-logical-producer.adb:61-66`):

```ada
when Commit_Message =>
   Require
     (Item.Current = Regular_Transaction,
      "Commit requires a regular transaction");
   Item.Current := Idle;
   Item.XID := 0;
```

`Begin_Prepare_Message` (`:100-105`) and `Prepare_Message` (`:107-113`) form the same pair, comparing the XID only. The private encoder record has no field for a pending LSN (`src/flyology-postgres-replication-logical-producer.ads:63-70`).

PostgreSQL's apply worker records the Begin's final LSN (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/worker.c:1000-1003`):

```c
	logicalrep_read_begin(s, &begin_data);
	set_apply_error_context_xact(begin_data.xid, begin_data.final_lsn);

	remote_final_lsn = begin_data.final_lsn;
```

and `apply_handle_commit` rejects a Commit that disagrees with it (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/worker.c:1017-1029`):

```c
apply_handle_commit(StringInfo s)
{
	LogicalRepCommitData commit_data;

	logicalrep_read_commit(s, &commit_data);

	if (commit_data.commit_lsn != remote_final_lsn)
		ereport(ERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg_internal("incorrect commit LSN %X/%X in commit message (expected %X/%X)",
								 LSN_FORMAT_ARGS(commit_data.commit_lsn),
								 LSN_FORMAT_ARGS(remote_final_lsn))));
```

`apply_handle_prepare` performs the identical comparison against `prepare_data.prepare_lsn` (`worker.c:1116-1121`). The check is present in every supported major: the same `ereport` appears at `tests/.cache/postgres/14.23-openssl/source/src/backend/replication/logical/worker.c:770-773`.

pgoutput's own output always agrees. `logicalrep_write_begin` sends `txn->final_lsn` (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/proto.c:60-67`), and `logicalrep_write_commit` sends the `commit_lsn` argument (`proto.c:89-102`) that the reorder buffer supplies as `txn->final_lsn` (`tests/.cache/postgres/17.10-openssl/source/src/backend/replication/logical/reorderbuffer.c:2864`).

Not checking this is a deliberate scope choice rather than an oversight, which is why closing it changes a published contract. The producer's promise is to validate "transaction ordering" (`src/flyology-postgres-replication-logical-producer.ads:2-3`) and "The transaction sequence, envelope, or negotiated protocol configuration" (`src/flyology-postgres-replication-logical-producer.ads:43-44`); LSN values are caller data everywhere else in this API. The producer test emits `Make_Begin (101, 0, 10)` and then `Make_Commit (103, 104, 0)`, a deliberately mismatched pair, and asserts that both succeed (`tests/src/replication_tests.adb:1386-1401`):

```ada
Producer.Configure (Encoder, Version => 1);
Emit (Logical.Make_Begin (101, 0, 10), 100, 101);
...
Emit (Logical.Make_Commit (103, 104, 0), 103, 104);
Assert
  (Producer.State (Encoder) = Producer.Idle
   and then Producer.Last_WAL_End (Encoder) = 104,
   "regular pgoutput production ends at its commit LSN");
```

That test asserts the current behaviour and would have to change if the check is added.

The interop matrix cannot detect the gap either, because `pg_recvlogical` does not perform the comparison; only a `CREATE SUBSCRIPTION` apply worker does.

The missing GID comparison between `BeginPrepare` and `Prepare` is a separate omission with no wire consequence, since the apply worker keys on `prepare_lsn` rather than on the GID.

## What happens now

Spike: the program emits a Begin with final LSN `16#101#` followed by a Commit with commit LSN `16#103#`, then a BeginPrepare at `16#301#` followed by a Prepare at `16#302#`, and asserts that both mismatched pairs are refused. It then emits an agreeing Begin/Commit pair and asserts that it is still accepted.

```ada
Producer.Configure (E, Version => 1);
Emit (Logical.Make_Begin (16#101#, 0, 10), 16#100#, 16#101#);
Emit (Logical.Make_Commit (16#103#, 16#104#, 0), 16#103#, 16#104#);

Producer.Configure (E, Version => 3);
Emit (Logical.Make_Begin_Prepare (16#301#, 16#302#, 0, 11, "gid-11"), 16#300#, 16#301#);
Emit (Logical.Make_Prepare (16#302#, 16#303#, 0, 11, "gid-11"), 16#302#, 16#303#);
```

```
  -- Begin final_lsn = 16#101#
  --   emitted 42 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 00 00 00 00 0a
  -- Commit commit_lsn = 16#103# (does not match the Begin)
  --   emitted 43 00 00 00 00 00 00 00 01 03 00 00 00 00 00 00 01 04 00 00 00 00 00 00 00 00
  --   accepted; a PostgreSQL apply worker would raise ERRCODE_PROTOCOL_VIOLATION on these bytes
  -- BeginPrepare prepare_lsn = 16#301#
  --   emitted 62 00 00 00 00 00 00 03 01 00 00 00 00 00 00 03 02 00 00 00 00 00 00 00 00 00 00 00 0b 67 69 64 2d 31 31 00
  -- Prepare prepare_lsn = 16#302# (does not match BeginPrepare)
  --   emitted 50 00 00 00 00 00 00 00 03 02 00 00 00 00 00 00 03 03 00 00 00 00 00 00 00 00 00 00 00 0b 67 69 64 2d 31 31 00
  --   accepted; a PostgreSQL apply worker would raise ERRCODE_PROTOCOL_VIOLATION on these bytes
  -- Begin/Commit both at final_lsn 16#130#
  --   emitted 42 00 00 00 00 00 00 01 30 00 00 00 00 00 00 00 00 00 00 00 0c
  --   emitted 43 00 00 00 00 00 00 00 01 30 00 00 00 00 00 00 01 40 00 00 00 00 00 00 00 00
  FAILED: Producer rejects a Commit whose commit LSN differs from the pending Begin's final LSN
  FAILED: Producer rejects a Prepare whose prepare LSN differs from the pending BeginPrepare's prepare LSN
  ok: Producer still accepts the agreeing Begin/Commit pair pgoutput emits
```

Both mismatched pairs are encoded and sent on. The Begin carries `01 01` at the end of its final LSN and the Commit carries `01 03` in the same field.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 17.10 and 14.23 server sources used for reference.

## What should happen

If the producer is to guarantee that its output is acceptable to a PostgreSQL apply worker, it should reject a `Commit` whose commit LSN differs from the pending `Begin`'s final LSN, and a `Prepare` whose prepare LSN differs from the pending `BeginPrepare`'s prepare LSN, matching `apply_handle_commit` and `apply_handle_prepare`. If the producer's validation deliberately stops at transaction ordering, the boundary should be stated so a caller knows the LSN agreement is its own responsibility.

## Suggested treatment

This needs a maintainer decision, because it changes the producer's published validation scope and an existing test asserts the opposite.

Option one, enforce it: add a pending-LSN field to the private encoder record (`src/flyology-postgres-replication-logical-producer.ads:63-70`), set it from `Logical.Final_LSN` in the `Begin` arm and from the prepare LSN in the `Begin_Prepare` arm, and compare it in the `Commit` and `Prepare` arms alongside the state check. This makes the producer reject a stream that a subscriber would refuse. `tests/src/replication_tests.adb:1386-1397` currently emits `Make_Begin (101, 0, 10)` with `Make_Commit (103, 104, 0)` and asserts success, so it has to change to an agreeing pair; the spike then becomes the regression test in `Test_Logical_Producer`.

Option two, document the boundary: state in `src/flyology-postgres-replication-logical-producer.ads:30-44` and in `README.md:366-367` that the producer validates the transaction sequence and the WAL envelope, and that LSN field agreement between paired messages is the caller's responsibility. That leaves the existing test valid and adds no code.

Whichever is chosen, the missing GID comparison between `BeginPrepare` and `Prepare` should be settled at the same time.

## Severity

An application logical source that gets the two LSNs out of step produces a stream that a `CREATE SUBSCRIPTION` apply worker errors on and then retries indefinitely, with the producer having reported nothing wrong. It needs a source that derives the Begin and Commit LSNs independently, which pgoutput itself never does, so a source that copies one value into both fields is unaffected. The existing interop coverage uses `pg_recvlogical`, which does not perform the check, so the gap is invisible to the current test matrix. Deterministic.
