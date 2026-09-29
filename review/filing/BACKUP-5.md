Title: Prepared_Consumer.Prepare overwrites the Target_Applied marker for the same GID, defeating the replay guard
Labels: bug
Refs: none

## Summary

`Prepared_Consumer.Prepare` persists its payload with an unconditional `Stores.Put`, which is documented to insert or replace the state for a `(slot, GID)` pair. A second PREPARE for a GID whose transaction has already reached `Target_Applied` therefore demotes the durable phase back to `Prepared` and destroys the replay guard the package header promises. A replayed PREPARE after a crash makes `Commit` invoke `Apply_Target` a second time, and a GID reused by the source before the earlier commit has been acknowledged makes the pending `Acknowledge_Commit` raise `Protocol_Error` instead of removing the state the consumer recorded.

## Problem

Commit `6f496f5`.

`Prepare` writes unconditionally (`src/flyology-postgres-replication-prepared_consumer.adb:7-20`):

```ada
procedure Prepare
  (Item        : in out Consumer;
   Slot_Name   : String;
   GID         : String;
   XID         : Transaction_Id;
   Prepare_LSN : LSN;
   Payload     : Stores.Byte_Array) is
begin
   Stores.Put
     (Item.Store.all,
      Slot_Name,
      GID,
      Stores.Make_Prepared (XID, Prepare_LSN, Payload));
end Prepare;
```

`Make_Prepared` defaults the phase to `Prepared` (`src/flyology-postgres-replication-persistence.ads:246-250`), and `Put` is documented to replace (`src/flyology-postgres-replication-persistence.ads:281-286`):

```ada
procedure Put
  (Item        : in out Prepared_Store;
   Slot_Name   : String;
   GID         : String;
   Transaction : Prepared_Transaction) is abstract;
--  Durably insert or replace prepared state identified by slot and GID.
```

`Persistence.Memory.Put` implements exactly that: an existing entry for the pair is found by `Prepared_Index` and overwritten whole (`src/flyology-postgres-replication-persistence-memory.adb:299-326`). `Memory` is the bounded volatile reference implementation (`README.md:362-364`), and the test store used by the durable-backend suite delegates `Put` to it after journalling (`tests/src/replication_test_durable_store.adb:747-763`):

```ada
Memory.Put (Item.Inner, Slot_Name, GID, Transaction);
```

So the store is behaving to contract. The layer that promised the marker survives is the consumer (`src/flyology-postgres-replication-prepared_consumer.ads:3-5`):

```ada
--  Recovery coordinator for pgoutput two-phase transactions. Durable prepared
--  state survives consumer replacement, while an applied marker prevents
--  replay after target application has been recorded.
```

and again on `Acknowledge_Commit` (`src/flyology-postgres-replication-prepared_consumer.ads:71-72`):

```ada
--  Remove Target_Applied state after the source commit LSN has itself been
--  durably acknowledged. Retaining the marker until then bounds replay.
```

`README.md:369-371` restates the separation: durable prepare, idempotent target application, durable applied marking, source acknowledgement, and final removal, "so a replacement consumer can resume the same store safely".

`Commit` decides purely from the durable phase (`src/flyology-postgres-replication-prepared_consumer.adb:35-49`):

```ada
Applied_Now := Stores.Phase (Transaction) = Stores.Prepared;
if Applied_Now then
   Apply_Target
     (Item.Target.all, Slot_Name, GID,
      Stores.XID (Transaction), Stores.Payload (Transaction));
```

and `Acknowledge_Commit` rejects anything that is not marked (`src/flyology-postgres-replication-prepared_consumer.adb:60-65`):

```ada
if not Stores.Exists (Transaction)
  or else Stores.Phase (Transaction) /= Stores.Target_Applied
then
   raise Flyology.Postgres.Protocol.Protocol_Error with
     "prepared commit acknowledgement precedes target application";
end if;
```

Two reachable sequences follow. In the first, a consumer applies and marks a transaction and then fails before its feedback confirms the commit LSN; PostgreSQL re-decodes from the confirmed flush position and re-sends the same PREPARE, `Prepare` clears the marker, and the following `Commit` applies the transaction again. The header does require `Apply_Target` to be idempotent for `(Slot_Name, GID, XID)` (`prepared_consumer.ads:7-10`), which bounds the damage here to a redundant apply, but the sentence at `:3-5` is unconditional and `:71-72` describes exactly this window.

In the second, PostgreSQL permits a GID to be reused once the earlier prepared transaction has committed. The source prepares a new transaction under that GID before the consumer has acknowledged the earlier commit LSN, which is the deferral the API itself directs (`prepared_consumer.ads:71-72`). The earlier transaction's `Target_Applied` record is replaced, and the pending `Acknowledge_Commit` raises `Protocol_Error`. The idempotence requirement does not cover this case, because the XID differs.

The existing test never issues a second `Prepare`. It drives Prepare, Commit on a replacement consumer, Commit again, and Acknowledge_Commit (`tests/src/replication_tests.adb:1346-1369`), so the duplicate-application guard it asserts at :1361-1363 is only exercised through a repeated `Commit`, which reads the marker instead of overwriting it.

## What happens now

Spike: two scenarios against separate `Memory` stores, each with an `Apply_Target` that counts its invocations. Scenario 1 prepares and commits a GID, then replays the identical PREPARE and COMMIT PREPARED, and asserts the target is not applied twice. Scenario 2 prepares and commits transaction 11 under a GID, prepares transaction 12 under the same GID, and asserts that acknowledging the first commit still finds the applied state.

```ada
Consumers.Prepare (Replay, "logical", "gid-replay",
   XID => 1, Prepare_LSN => 10, Payload => (1, 2));
Consumers.Commit (Replay, "logical", "gid-replay", Applied);
--  The consumer restarts before its feedback confirmed the commit LSN.
Consumers.Prepare (Replay, "logical", "gid-replay",
   XID => 1, Prepare_LSN => 10, Payload => (1, 2));
Consumers.Commit (Replay, "logical", "gid-replay", Applied);
Check (not Applied and then Replay_Target.Applications = 1, ...);

Consumers.Prepare (Reuse, "logical", "gid-shared",
   XID => 11, Prepare_LSN => 20, Payload => (3, 4));
Consumers.Commit (Reuse, "logical", "gid-shared", Applied);
Consumers.Prepare (Reuse, "logical", "gid-shared",
   XID => 12, Prepare_LSN => 30, Payload => (5, 6));
Consumers.Acknowledge_Commit (Reuse, "logical", "gid-shared");
```

Output:

```
  -- --- scenario 1: PREPARE replayed after target application ---
  -- Apply_Target invoked for GID "gid-replay", XID = 1 (application # 1 )
  ok: the first commit applies the prepared transaction once (harness sanity check)
  -- Apply_Target invoked for GID "gid-replay", XID = 1 (application # 2 )
  -- after the replayed PREPARE and COMMIT PREPARED: Applied_Now = TRUE, Apply_Target calls = 2
  FAILED: the durable applied marker prevents replay: a repeated PREPARE and COMMIT PREPARED for the same GID does not re-apply the target
  -- --- scenario 2: the source reuses the GID before acknowledgement ---
  -- Apply_Target invoked for GID "gid-shared", XID = 11 (application # 1 )
  ok: the first transaction is applied (harness sanity check)
  -- Acknowledge_Commit for transaction 11 raised Protocol_Error: prepared commit acknowledgement precedes target application
  FAILED: acknowledging the commit LSN of the first transaction still finds the applied state the consumer recorded for it
BUG REPRODUCED: 2 failed expectation(s)
```

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

A repeated PREPARE for a `(slot, GID)` whose durable phase is already `Target_Applied` must not clear the marker, so that `Commit` does not invoke `Apply_Target` again and a pending `Acknowledge_Commit` still finds the applied state it was promised. That is what `prepared_consumer.ads:3-5` and `:71-72` state.

## Suggested treatment

Guard the write in `Prepare` on the durable phase rather than changing `Put`, which behaves to its own contract:

```ada
declare
   Existing : constant Stores.Prepared_Transaction :=
     Stores.Load (Item.Store.all, Slot_Name, GID);
begin
   if Stores.Exists (Existing)
     and then Stores.Phase (Existing) = Stores.Target_Applied
   then
      return;
   end if;
   Stores.Put (Item.Store.all, Slot_Name, GID,
               Stores.Make_Prepared (XID, Prepare_LSN, Payload));
end;
```

Whether a reused GID whose earlier transaction is still marked should be silently ignored, as above, or should raise `Protocol_Error` so the application resolves the collision, is a maintainer decision: silently ignoring it makes the second transaction's payload invisible until the first is acknowledged, and raising adds an exception to a documented interface (`prepared_consumer.ads:48-50`). Whichever is chosen, `Prepare`'s `@exception` list must say so.

The regression test belongs in `tests/src/replication_tests.adb` beside the prepared-consumer sequence at :1346-1369, extended with a second `Prepare` after the marker exists; the spike is that test. No existing assertion asserts the current behaviour: the check at :1361-1363 stays true under the fix.

## Severity

The durable applied marker, which is the package's stated reason to exist, can be erased by a message the source is entitled to resend. Scenario 1 costs a duplicate `Apply_Target`, which the header's idempotence requirement absorbs for an application that honours it. Scenario 2 is an unexpected `Protocol_Error` on valid input, reached through the acknowledgement deferral the API itself directs, and it leaves the first transaction's state unrecoverable through the documented sequence. Deterministic; not reproduced against a live server.
