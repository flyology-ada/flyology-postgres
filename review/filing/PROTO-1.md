Title: Framing.Read_Message promises a single deadline but re-arms the full Timeout for each of its three reads
Labels: bug
Refs: none

## Summary

`Framing.Read_Message` issues three separate transport reads for one message and passes the caller's whole `Timeout` to each. Every concrete transport implements `Timeout` per transfer, as its own contract requires, so nothing between the framing layer and the socket subtracts elapsed time. A peer that stalls just under `Timeout` before each read keeps the call alive for nearly three times the documented deadline. Callers that size `Timeout` as a liveness bound, including the server's pre-authentication `Startup_Timeout`, get one three times looser than the specification promises.

## Problem

Commit `6f496f5`.

`Read_Message` reads the tag, the length and the body in three calls and gives each the same `Timeout` (`src/flyology-postgres-framing.adb:69-81`):

```ada
begin
   Channel.Receive_Exactly (Tag, Timeout, On_Wait);
   Length := Read_Length (Channel, Timeout, On_Wait);
   if not Wire.Valid_Typed_Length (Length) then
      raise Protocol.Protocol_Error with
        "invalid typed Postgres message length";
   end if;
   return Protocol.Make_Message
     (Character'Val (Tag (Tag'First)),
      Read_Contents
        (Channel, Natural (Wire.Content_Length (Length)), Timeout,
         On_Wait));
end Read_Message;
```

`Read_Initial` does the same across two calls (`src/flyology-postgres-framing.adb:48-60`):

```ada
   Length : constant Protocol.UInt32 := Read_Length (Channel, Timeout);
begin
   ...
   return Protocol.Decode_Initial
     (Read_Contents
        (Channel, Natural (Wire.Content_Length (Length)), Timeout));
```

The contract being violated (`src/flyology-postgres-framing.ads:15-17`):

```ada
   --  Read one typed message under a single deadline.
   --  @param Channel Transport to read.
   --  @param Timeout Maximum time allowed for the whole message.
```

Two further specifications repeat the same promise one layer up, so a fix must correct three of them (`src/flyology-postgres-server_sessions.ads:16-24`):

```ada
   --  Read a startup, SSL, GSS, or cancellation request before authentication.
   --  @param Item New server session to read.
   --  @param Timeout Maximum time allowed for the complete packet.
   --  @return Decoded initial request.
   function Read_Command
     (Item : in out Session; Timeout : Duration) return Protocol.Message;
   --  Read one complete typed frontend message after startup.
   --  @param Item Authenticated server session to read.
   --  @param Timeout Maximum time allowed for the complete message.
```

Both session operations forward `Timeout` unchanged to the framing layer, so they inherit the framing behaviour exactly (`src/flyology-postgres-server_sessions.adb:56-68`).

Nothing below `Framing` compensates, because the transport contract is deliberately per-transfer (`src/flyology-postgres-transports.ads:33-36`):

```ada
   --  Fill Data with exactly Data'Length bytes received from Item.
   --  @param Item Channel from which bytes are read.
   --  @param Data Buffer filled before the operation returns.
   --  @param Timeout Maximum time allowed for the complete transfer.
```

All three concrete transports implement that contract as written. `Socket_Transport.Receive_Exactly` forwards `Timeout` verbatim (`src/flyology-postgres-transports-sockets.adb:12-13`), `Connection_Transport.Receive_Exactly` forwards it verbatim (`src/flyology-postgres-transports-connections.adb:44-45`), and `TLS_Socket_Transport.Receive_Exactly` computes a fresh deadline inside each call (`src/flyology-postgres-transports-tls_sockets.adb:33-36`):

```ada
      Deadline : constant Ada.Real_Time.Time :=
        (if Bounded
         then Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout)
         else Ada.Real_Time.Time_First);
```

Every message the library reads takes this path. `Run_Session` reads both of its startup packets with `Startup_Timeout` (`src/flyology-postgres-server.adb:372` and `:403`; the generic formal defaults to `30.0` at `src/flyology-postgres-server.ads:36`), and the client's copy-event read hands its caller's timeout straight to `Framing.Read_Message` (`src/flyology-postgres-client.adb:2291-2292`), which is the path the replication-feedback loop uses.

The existing tests do not catch this. The in-memory transport they use satisfies every read immediately, no test measures the time spent inside `Read_Message`, and no test drives a transport that stalls between reads.

## What happens now

Spike: a transport that answers every read but stalls 0.25 s first, and records the `Timeout` the framing layer granted to each individual read. `Read_Message` is called with a 0.30 s deadline on a six-byte ReadyForQuery frame, which is exactly three reads. The program asserts what the specification promises: `Read_Message` either returns within `Timeout` plus scheduling slack or raises `Flyology.IO.Timeout_Error`.

```ada
   Message_Timeout : constant Duration := 0.30;
   Stall_Per_Read  : constant Duration := 0.25;
   Tolerance       : constant Duration := 0.10;
...
      Item.Calls := Item.Calls + 1;
      if Item.Calls <= Max_Calls then
         Item.Granted (Item.Calls) := Timeout;
      end if;
      Burn (Stall_Per_Read);
...
   Started := Ada.Real_Time.Clock;
   declare
      Result : constant Protocol.Message :=
        Framing.Read_Message (Channel, Message_Timeout);
   ...
   Elapsed := Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started);
   Check
     (Timed_Out or else Elapsed <= Message_Timeout + Tolerance,
      "Read_Message honors its documented single deadline: it either "
      & "completes within Timeout or raises Timeout_Error");
```

```
  -- frame bytes: 5a 00 00 00 05 49 
  -- Read_Message Timeout = 0.300000000s; peer stalls 0.250000000s before satisfying each transport read
  -- Read_Message returned a 'Z' message
  -- transport reads issued: 3
  --   read 1 was granted a timeout of 0.300000000s
  --   read 2 was granted a timeout of 0.300000000s
  --   read 3 was granted a timeout of 0.300000000s
  -- wall-clock time spent inside Read_Message: 0.750065750s
  ok: Read_Message raises no unrelated exception
  FAILED: Read_Message honors its documented single deadline: it either completes within Timeout or raises Timeout_Error
  -- the whole-message deadline was exceeded by 0.450065750s because each read re-armed the full timeout
BUG REPRODUCED: 1 failed expectation(s)
```

`Burn` is a busy wait on `Ada.Real_Time.Clock`, so 0.75 s is measured wall-clock time spent inside `Read_Message`, not a simulated clock. Each of the three reads was granted the full 0.30 s.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire.

## What should happen

`Read_Message` and `Read_Initial` should establish one deadline on entry and give each transport read only the time remaining until it, so the call either delivers the complete message within `Timeout` or raises `Flyology.IO.Timeout_Error`. That is what `src/flyology-postgres-framing.ads:15-17` states, and what `src/flyology-postgres-server_sessions.ads:18` and `:24` repeat.

## Suggested treatment

Compute `Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Timeout)` once at the top of `Read_Message` and `Read_Initial`, and pass each `Receive_Exactly` the duration remaining until `Deadline` rather than `Timeout`. `Read_Length` (`src/flyology-postgres-framing.adb:12-22`) and `Read_Contents` (`:24-46`) each issue one read and should take the deadline instead of the duration. Preserve the existing unbounded convention: `TLS_Socket_Transport.Receive_Exactly` treats a negative `Timeout` as unbounded (`src/flyology-postgres-transports-tls_sockets.adb:32`), so an unbounded call must keep forwarding that same negative value rather than a computed remainder. `Command_Timeout` defaults to `Flyology.IO.Infinite` (`src/flyology-postgres-server.ads:37`), so that path is exercised by default.

The regression test belongs in `tests/src/tests.adb` next to the other framing tests, using a stalling transport of the kind the spike builds; the spike is the test. No existing test asserts the current behaviour, so none has to change.

## Severity

Every message the library reads is affected, on the default path, with no unusual input required: a peer that fragments its writes gets up to three times the deadline the caller asked for, and up to twice it for an untagged initial packet. On the server this weakens the pre-authentication liveness bound, because an unauthenticated client that fragments its startup packet holds a worker for roughly twice `Startup_Timeout`, and any later typed message for roughly three times `Command_Timeout`. The overrun is bounded at those multiples, so this is a contract violation and a weakened liveness bound rather than a hang. Deterministic.
