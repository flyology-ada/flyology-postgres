Title: Read_Initial has no startup-specific length bound, so four unauthenticated bytes commit a 16 MiB buffer
Labels: bug
Refs: none

## Summary

`Framing.Read_Initial` checks the client's length word only against the generic 16 MiB message limit, then allocates a heap buffer of that size before asking the peer for a single payload byte. A pre-authentication peer that writes four bytes and stalls therefore commits about 16 MiB for the whole startup window, on every worker the listener admits. PostgreSQL bounds exactly this allocation at 10000 bytes and rejects anything larger before allocating. The library has no startup-specific bound at all.

## Problem

Commit `6f496f5`.

The only check is the generic frame limit (`src/flyology-postgres-wire.ads:316-317`):

```ada
   function Valid_Initial_Length (Length : UInt32) return Boolean is
     (Length >= 8 and then Length <= UInt32 (Maximum_Frame_Size));
```

`Maximum_Frame_Size` is `Flyology.Postgres.Maximum_Message_Size` (`src/flyology-postgres-wire.ads:47`), which is `16 * 1_024 * 1_024` (`src/flyology-postgres.ads:6`).

`Read_Initial` applies it and hands the accepted length straight to `Read_Contents` (`src/flyology-postgres-framing.adb:48-59`):

```ada
   function Read_Initial
     (Channel : in out Transports.Transport'Class;
      Timeout : Duration) return Protocol.Initial_Request is
      Length : constant Protocol.UInt32 := Read_Length (Channel, Timeout);
   begin
      if not Wire.Valid_Initial_Length (Length) then
         raise Protocol.Protocol_Error with
           "invalid initial Postgres packet length";
      end if;
      return Protocol.Decode_Initial
        (Read_Contents
           (Channel, Natural (Wire.Content_Length (Length)), Timeout));
```

`Read_Contents` allocates first and reads afterwards (`src/flyology-postgres-framing.adb:30-41`):

```ada
      Buffer : Byte_Array_Access :=
        new Protocol.Byte_Array (1 .. Protocol.Byte_Offset (Count));
   begin
      if Count > 0 then
         Channel.Receive_Exactly (Buffer.all, Timeout, On_Wait);
      end if;
      declare
         Result : constant Protocol.Byte_Array := Buffer.all;
      begin
         Free (Buffer);
         return Result;
      end;
```

The heap `Buffer` and the local `Result` are live at the same time, so the concurrent peak is about twice the declared length, roughly 32 MiB for the largest accepted value. `Free (Buffer)` runs before the function result is copied out, so no third copy is held alongside those two.

PostgreSQL caps the same unauthenticated allocation (`tests/.cache/postgres/18.4-openssl/source/src/include/libpq/pqcomm.h:118`):

```c
#define MAX_STARTUP_PACKET_LENGTH 10000
```

and rejects an oversized packet before `palloc` (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:536-543`, with the allocation at `:550`):

```c
	if (len < (int32) sizeof(ProtocolVersion) ||
		len > MAX_STARTUP_PACKET_LENGTH)
	{
		ereport(COMMERROR,
				(errcode(ERRCODE_PROTOCOL_VIOLATION),
				 errmsg("invalid length of startup packet")));
		return STATUS_ERROR;
	}
```

The exposure is bounded, which caps how bad this is: concurrency is limited by `Worker_Capacity (Item.Capacity)`, which is `Capacity + 1` (`src/flyology-postgres-server.adb:209-216`), so the worst case is roughly `(Capacity + 1)` times the per-connection peak.

No test declares an oversized startup length or observes the allocation.

## What happens now

Spike: a transport supplies the four length bytes `01 00 00 00` and nothing else, and reports how many payload bytes `Read_Initial` asks for, which is the size of the buffer already on the heap.

```ada
      Item.Reads := Item.Reads + 1;
      if Item.Reads = 1 then
         --  The four-byte length word: 0x01000000.
         Data := (16#01#, 16#00#, 16#00#, 16#00#);
         return;
      end if;
      --  The library has already allocated Data'Length bytes on the heap by
      --  the time it asks the peer for the payload.
      Item.Requested := Data'Length;
      Data := (others => 0);
      raise Flyology.IO.Timeout_Error with "peer sends no payload";
```

```
  -- client-declared initial packet length: 16777216 (Wire.Valid_Initial_Length accepts up to Maximum_Message_Size)
  -- PostgreSQL's cap on the same unauthenticated packet: 10004
  -- Read_Initial raised FLYOLOGY.IO.TIMEOUT_ERROR: peer sends no payload
  -- transport reads issued: 2
  -- payload bytes the library asked for (= heap buffer it had already allocated): 16777212
  FAILED: an unauthenticated startup packet does not cause an allocation larger than PostgreSQL's MAX_STARTUP_PACKET_LENGTH before any payload byte has been received
  -- four attacker-supplied bytes committed 16777212 bytes of heap per connection, held for the whole startup timeout, on every worker the listener admits
BUG REPRODUCED: 1 failed expectation(s)
```

The assertion is written against PostgreSQL's published cap because that is the only externally established reference point available. The finding is the absence of any startup-specific bound, not the specific number.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A startup packet length that no legitimate client sends should be rejected before a buffer of that size is committed, as `ProcessStartupPacket` does at `backend_startup.c:536-543`. The generic per-message limit is the wrong bound for an unauthenticated packet.

## Suggested treatment

Add a startup-specific length check in `Framing.Read_Initial`, applied in the same place as `Wire.Valid_Initial_Length` and before `Read_Contents` is called, so the buffer is never allocated.

Choosing the bound is a maintainer decision under the repository's decision-authority rule (`AGENTS.md`, section "Decision authority"), because it is a new externally visible limit that decides which clients are refused. The options are:

- Match PostgreSQL's `MAX_STARTUP_PACKET_LENGTH` of 10000, which is the only externally established value and keeps parity with the backend a client expects.
- Derive a value from the existing constants, for example a fraction of `Maximum_Message_Size`, which avoids a second unrelated number but has no external authority.
- Make it a generic formal alongside `Startup_Timeout` on `Flyology.Postgres.Server`, which lets an application widen it and adds a public parameter.

Whichever is chosen, the value should carry a comment recording its authority, as the same rule requires.

The spike is the regression test, and it belongs with the framing coverage in `tests/src/tests.adb`. No existing test asserts the wrong behaviour.

## Severity

Four attacker-supplied bytes commit about 16 MiB of heap per connection, roughly 32 MiB at the copy peak, held for the whole startup timeout and needing no authentication. The amplification is large but the total is bounded by the configured session capacity, so this is a resource and parity gap rather than an unbounded denial of service, and a server with a small `Capacity` is barely exposed. Deterministic.
