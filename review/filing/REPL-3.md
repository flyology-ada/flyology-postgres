Title: Read_Standby_Message raises Protocol_Error on the standby-initiated CopyDone PostgreSQL treats as normal
Labels: bug
Refs: none

## Summary

`Read_Standby_Message` feeds every frontend message it reads into `Decode`, which requires a CopyData frame. A standby that closes its send direction mid-stream sends `CopyDone`, which PostgreSQL's walsender answers with its own `CopyDone` rather than failing. The library instead raises `Protocol.Protocol_Error` with the same text a malformed frame produces, and the unwind through `Stream_Physical` skips the slot advancement, so progress the standby already reported is lost.

## Problem

Commit `6f496f5`.

`Read_Standby_Message` decodes whatever `Read_Command` returned (`src/flyology-postgres-replication-server_sessions.adb:201-206`):

```ada
   function Read_Standby_Message
     (Client : in out Sessions.Session; Timeout : Duration)
      return Stream_Message is
   begin
      return Decode (Sessions.Read_Command (Client, Timeout));
   end Read_Standby_Message;
```

`Decode` rejects anything that is not CopyData (`src/flyology-postgres-replication.adb:929-931`):

```ada
      Require
        (Protocol.Code (Item) = 'd',
         "replication streaming requires a CopyData message");
```

A standby closing its send direction mid-stream is normal PostgreSQL, not an error. `ProcessRepliesIfAny` reads standby replies while the walsender is still streaming (`src/backend/replication/walsender.c` 18.4:2246, loop at 18.4:2260) and answers `CopyDone` with its own (`walsender.c` 18.4:2319-2332):

```c
				/*
				 * CopyDone means the standby requested to finish streaming.
				 * Reply with CopyDone, if we had not sent that already.
				 */
			case PqMsg_CopyDone:
				if (!streamingDoneSending)
				{
					pq_putmessage_noblock('c', NULL, 0);
					streamingDoneSending = true;
				}

				streamingDoneReceiving = true;
				received = true;
				break;
```

PostgreSQL's own WAL-streaming clients send exactly that while the server is still sending. `src/bin/pg_basebackup/receivelog.c` 18.4:1156-1165 does it at a WAL segment boundary:

```c
			if (still_sending && stream->stream_stop(*blockpos, stream->timeline, true))
			{
				if (PQputCopyEnd(conn, NULL) <= 0 || PQflush(conn))
				{
					pg_log_error("could not send copy-end packet: %s",
								 PQerrorMessage(conn));
					return false;
				}
				still_sending = false;
				return true;	/* ignore the rest of this XLogData packet */
			}
```

and `CheckCopyStreamStop` does it on the stop callback (`receivelog.c` 18.4:1216-1231). That is how `pg_receivewal` and `pg_basebackup`'s background WAL streamer stop.

The path is reachable from inside this library. `Await_Feedback` loops on `Read_Standby_Message` (`src/flyology-postgres-replication-managed_primary.adb:80-102`):

```ada
   procedure Await_Feedback
     (Item      : Primary;
      Client    : in out Sessions.Session;
      Minimum   : LSN;
      Received  : out LSN;
      Flushed   : out LSN) is
   begin
      loop
         declare
            Feedback : constant Stream_Message :=
              Replication_Sessions.Read_Standby_Message
                (Client, Timeout => Item.Operation_Timeout);
```

and it runs at `src/flyology-postgres-replication-managed_primary.adb:161` (physical) and `:281` (logical), both before `Complete_Copy` at `:171` and `:289` switches to `Sessions.Read_Copy_Command`, which does classify `CopyDone` as `Protocol.Frontend_Copy_Done` (`src/flyology-postgres-replication-managed_primary.adb:68-69`). The window in which the exception is raised is exactly the window in which the standby is expected to stop.

The exception is not contained. In `Stream_Physical` it propagates from `:161` past the slot advancement at `:165-170` into the handler at `:178-184`:

```ada
      Await_Feedback (Item, Client, End_LSN, Received, Flushed);
      ...
      if Has_Lease then
         Stores.Advance
           (Item.Slots.all, Slot_Name, Lease,
            Restart => Flushed, Confirmed => 0, Advanced => Advanced);
```

```ada
   exception
      when others =>
         if Has_Lease then
            Stores.Release
              (Item.Slots.all, Slot_Name, Lease, Released);
         end if;
         raise;
```

The lease is released and the exception is re-raised, but `Stores.Advance` never runs, so the slot keeps its old restart LSN even though the standby had already reported a higher flushed position. `Stream_Logical` has the same shape at `:281`, `:285-288` and `:294-300`.

The spec documents no way to tell the two cases apart (`src/flyology-postgres-replication-server_sessions.ads:106-112`):

```ada
   function Read_Standby_Message
     (Client : in out Sessions.Session; Timeout : Duration)
      return Stream_Message;
   --  Read and decode one standby CopyData message.
   --  @param Client Streaming replication session to read.
   --  @param Timeout Maximum time allowed for the complete message.
   --  @return Standby status update or hot-standby feedback.
```

The caller receives `Protocol.Protocol_Error "replication streaming requires a CopyData message"` for a routine event and for a genuinely malformed frame alike.

The tests do not catch it because no test ever queues a `CopyDone` on the feedback path. `tests/src/replication_tests.adb:571-583` decodes a `StandbyStatusUpdate` built by the library's own constructor, and the integration server at `tests/src/postgres_test_replication_server.adb:115-134` loops on `Read_Standby_Message` only until the expected status update arrives, so the standby in that test never stops early.

## What happens now

Spike: the program queues a bare `CopyDone` frame on a session and calls `Read_Standby_Message`, asserting that it does not report a malformed replication frame and that the caller can observe end-of-COPY through the same API. A `StandbyStatusUpdate` on the same session is read first as a control, and the identical bytes are then passed to `Sessions.Read_Copy_Command` for contrast.

```ada
      Queue (Channel, Protocol.Make_Empty_Message ('c'));
      Note ("standby sends a bare CopyDone ('c') while the primary awaits "
            & "feedback");
      declare
         Feedback : constant Replication.Stream_Message :=
           Replication_Sessions.Read_Standby_Message (Client, 1.0);
      begin
         Returned_Normally := True;
...
         Command : constant Protocol.Frontend_Copy_Message :=
           Sessions.Read_Copy_Command (Client, 1.0);
      begin
         Session_Layer_Sees_Done :=
           Protocol.Copy_Kind (Command) = Protocol.Frontend_Copy_Done;
```

Output:

```
  -- control: a StandbyStatusUpdate decodes as STANDBY_STATUS_UPDATE
  -- standby sends a bare CopyDone ('c') while the primary awaits feedback
  --   Read_Standby_Message raised Protocol_Error: replication streaming requires a CopyData message
  -- contrast: Sessions.Read_Copy_Command classifies the same bytes as FRONTEND_COPY_DONE
  ok: harness sanity check: a StandbyStatusUpdate is read and decoded
  ok: harness sanity check: the session layer classifies the queued frame as Frontend_Copy_Done
  FAILED: a standby-initiated CopyDone is not reported as a malformed replication frame (PostgreSQL's walsender answers it with its own CopyDone)
  FAILED: the primary can observe end-of-COPY through the feedback-reading API instead of unwinding on Protocol_Error
BUG REPRODUCED: 2 failed expectation(s)
```

The contrast line shows the session layer already classifies the frame correctly. Only the replication feedback API cannot.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A standby-initiated `CopyDone` arriving while the primary reads feedback should be reported to the caller as end-of-stream, so the caller can close the other direction and record the progress it already has, the way `walsender.c` 18.4:2323-2330 answers it with its own `CopyDone`. Only a frame that is neither CopyData nor CopyDone should raise `Protocol.Protocol_Error`.

## Suggested treatment

This needs a maintainer decision, because either shape changes the public interface at `src/flyology-postgres-replication-server_sessions.ads:106-112`. The options are: give `Stream_Message` a `Standby_Copy_Done` kind so `Read_Standby_Message` returns the event like any other, which changes the exhaustiveness of every existing `case` over `Stream_Message_Kind`; add an `out` or predicate parameter that reports end-of-stream while the returned message stays undefined; or raise a distinct exception that callers can handle separately from a malformed frame. Whichever is chosen, `Await_Feedback` (`src/flyology-postgres-replication-managed_primary.adb:80-102`) has to exit its loop on the event and let `Stream_Physical` and `Stream_Logical` record the last reported flushed LSN through `Stores.Advance` before completing the COPY, rather than losing it on the unwind at `:178-184` and `:294-300`.

The regression test belongs beside the existing streaming-message tests in `tests/src/replication_tests.adb:571-583`; the spike is that test. No existing test asserts the current rejection, so nothing has to be inverted.

## Severity

A standby that stops streaming at a normal point, which is how `pg_receivewal` and `pg_basebackup`'s WAL streamer always stop, turns a clean end-of-COPY into `Protocol.Protocol_Error` on a path the library itself drives in a loop. The primary loses the slot advancement for WAL the standby had already flushed, so the slot holds WAL that could have been released, and the caller cannot distinguish the event from a corrupt frame. It needs the standby to stop during the feedback window rather than after `Complete_Copy` begins, which is the window PostgreSQL's clients actually stop in. Deterministic; not reproduced against a live server.
