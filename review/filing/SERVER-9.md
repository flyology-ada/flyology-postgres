Title: TLS_Socket_Transport.Receive_Exactly changes its exception and zero-timeout behaviour given an observer
Labels: bug
Refs: none

## Summary

`TLS_Socket_Transport.Receive_Exactly` takes two different routes depending on whether the caller supplied a wait observer. Without one, a plaintext peer that closes mid-message surfaces as `Flyology.IO.Device_Error`; with one, the same event on the same un-upgraded socket surfaces as `Flyology.IO.TLS.TLS_Error "TLS peer closed before receive completed"`. The observer path also treats `Timeout => 0.0` as an expired deadline and raises before attempting any read, so bytes already sitting in the receive buffer are never returned. A caller's exception handler therefore has to depend on its own choice of `On_Wait` rather than on what happened.

## Problem

Commit `6f496f5`.

### The exception depends on the observer, not on the event

The two routes are chosen at the top of the operation (`src/flyology-postgres-transports-tls_sockets.adb:41-50`):

```ada
      if On_Wait = null then
         if Item.Encrypted then
            Flyology.IO.TLS.Receive_Exactly
              (Item.Secure, Data, Timeout => Timeout);
         else
            Flyology.IO.Sockets.Receive_Exactly
              (Item.Socket.all, Data, Timeout => Timeout);
         end if;
         return;
      end if;
```

`Flyology.IO.Sockets.Receive_Exactly` documents an early close as `Device_Error` (`flyology-io-sockets.ads:545` in the pinned runtime: "@exception Device_Error Polling fails or peer closes before completion").

The observer path instead reads chunks through `Flyology.IO.Sockets.Receive`, whose orderly close is reported as `Last = Item'First - 1` (`flyology-io-sockets.ads:474`: "@param Last Last element received, or Item'First - 1 on orderly closure"), and converts that into a TLS failure whether or not the transport was ever upgraded (`src/flyology-postgres-transports-tls_sockets.adb:69-72`):

```ada
            if Last < Cursor then
               raise Flyology.IO.TLS.TLS_Error with
                 "TLS peer closed before receive completed";
            end if;
```

The `Transport` contract documents only `Timeout_Error` (`src/flyology-postgres-transports.ads:28-40`), so neither exception is specified. What is wrong is that the choice between them follows the caller's `On_Wait` argument.

### A zero timeout raises before any read

`Bounded` is true for `0.0` (`src/flyology-postgres-transports-tls_sockets.adb:32-36`), so `Deadline` is the current `Clock`, and the first loop iteration finds the deadline expired (`:52-59`):

```ada
      while Cursor <= Data'Last loop
         if Bounded then
            Left := Ada.Real_Time.To_Duration (Deadline - Ada.Real_Time.Clock);
            if Left <= 0.0 then
               raise Flyology.IO.Timeout_Error with
                 "Postgres transport deadline expired before the buffer"
                 & " filled";
            end if;
```

`Receive_Chunk` is never called. The observer-less path passes `0.0` down to the socket and TLS layers, where zero means one immediate attempt (`flyology-io-tls.ads:189-190`: "Negative Timeout means no limit and zero is an immediate poll").

Both reach a shipped path. `TLS_Socket_Transport` is the standard socket client transport (`src/flyology-postgres-client_sockets.adb:42`), and `Client.Receive_Copy_Event` threads its `On_Wait` into `Framing.Read_Message` (`src/flyology-postgres-client.adb:2288-2292`) for `Replication.Feedback.Standby_Reporter` (`src/flyology-postgres-replication-feedback.adb:27`), a public observer whose entire purpose is to be passed there.

No test covers the observer path of this transport: the in-repo `Memory_Transport` declares `pragma Unreferenced (On_Wait)` (`tests/src/tests.adb:124-126`), so it never exercises the chunked loop.

## What happens now

Spike: real loopback TCP pairs, never upgraded to TLS. The peer writes 3 of 8 expected bytes and closes; `Receive_Exactly` is called once without an observer and once with one. Then a second pair delivers all 8 bytes before the call, which is made with `Timeout => 0.0` and an observer.

```ada
      Make_Loopback_Pair (Writer, Reader);
      Sockets.Send_All (Writer, Prefix, Timeout => 1.0);
      Sockets.Close_Socket (Writer);
      begin
         if With_Observer then
            Channel.Receive_Exactly (Data, 1.0, Watcher'Access);
         else
            Channel.Receive_Exactly (Data, 1.0);
         end if;
```

```ada
      Sockets.Send_All (Writer, Full, Timeout => 1.0);
      --  Every byte is already in the receive buffer before the call.
      delay 0.05;
      begin
         Channel.Receive_Exactly (Data, 0.0, Watcher'Access);
```

```
  -- plaintext peer closes after 3 of 8 bytes
  --   without an observer -> FLYOLOGY.IO.DEVICE_ERROR: socket closed while receiving
  --   with an observer    -> FLYOLOGY.IO.TLS.TLS_ERROR: TLS peer closed before receive completed
  FAILED: an early peer close on an un-upgraded transport reports the same exception with and without an observer
  -- Receive_Exactly (Timeout => 0.0, observer) raised FLYOLOGY.IO.TIMEOUT_ERROR: Postgres transport deadline expired before the buffer filled
  FAILED: a zero timeout with an observer still attempts one read and returns bytes that are already available
BUG REPRODUCED: 2 failed expectation(s)
```

Both cases run on identical sockets in one run, so the only difference is the `On_Wait` argument.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

The same event produces the same exception whether or not an observer was supplied, and an un-upgraded transport does not report a TLS failure. A zero timeout means one immediate attempt, as it does at the socket and TLS layers and on this transport's own observer-less path, so bytes already buffered are returned.

## Suggested treatment

In the observer loop, raise the same exception the observer-less path produces for an early close: replace the `Flyology.IO.TLS.TLS_Error` at `src/flyology-postgres-transports-tls_sockets.adb:69-72` with `Flyology.IO.Device_Error` when the transport is not encrypted, keeping the TLS exception for the encrypted case where it is accurate.

For the zero timeout, test the deadline after an attempt rather than before it, so the loop always performs one `Receive_Chunk` before it can raise `Timeout_Error`.

While the exceptions are being settled, `src/flyology-postgres-transports.ads:28-40` should document the early-close exception alongside `Timeout_Error`, so callers have something to program against.

The spike is the regression test. It needs real sockets, so it belongs with the socket-level coverage rather than the `Memory_Transport` tests in `tests/src/tests.adb`, whose transport ignores `On_Wait` at `:124-126`. No existing test asserts the wrong behaviour.

## Severity

Inconsistent diagnostics plus one edge-case incorrectness. A caller on the replication feedback path, which is the shipped user of `On_Wait`, catches `Device_Error` for a peer that goes away and gets `TLS_Error` instead, so its handler does not fire. The zero-timeout case needs a caller that polls with `0.0` and an observer, which is unusual. Neither affects the mainstream query path, where no observer is passed. Both are deterministic.
