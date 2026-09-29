Title: Run_Session sends raw GNAT exception text to peers, and a shutdown-cancelled session gets no diagnostic
Labels: bug
Refs: none

## Summary

`Run_Session`'s catch-all handler builds the client's `ErrorResponse` from `Ada.Exceptions.Exception_Message` under SQLSTATE `XX000`, so a `Constraint_Error` raised inside the application handler puts a server source file name and line number on the wire. When shutdown forces handler cancellation, the same handler tries to write that answer through the very cancellation token that was just fired, the write fails, and a nested `when others => null` discards it: the peer receives no diagnostic at all, where PostgreSQL sends `FATAL 57P01 terminating connection due to administrator command`.

## Problem

Commit `6f496f5`.

The catch-all forwards the exception message verbatim (`src/flyology-postgres-server.adb:537-548`):

```ada
      when Error : others =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "XX000",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
         exception
            when others =>
               null;
         end;
```

Any non-`Protocol_Error` exception reaches it, including one raised inside the application's own `Handle` callback, which the command loop re-raises (`src/flyology-postgres-server.adb:504-508`). With GNAT the message of a failed language check names the source file and line of the check.

The second consequence comes from the token the answer is written through. `Process_Connection` binds the session's transport to the handler's cancellation token (`src/flyology-postgres-server.adb:557-559`):

```ada
      Channel : aliased Transports.Connections.Connection_Transport
        (Connection'Unchecked_Access, Cancellation);
      Client : Server_Sessions.Session (Channel'Access);
```

and every write on that transport passes the token down (`src/flyology-postgres-transports-connections.adb:52-55`):

```ada
   begin
      Item.Channel.Send_All
        (Data, Timeout => Timeout, Token => Item.Token);
   end Send_All;
```

The token is the structured server's `Handler_Stop`, requested by `Force_Handlers` (`flyology-io-structured_servers.adb:230-235` in the pinned runtime), which is what a shutdown with a finite `Drain_Timeout` runs. `Read_Command` then raises `Operation_Cancelled`, the catch-all attempts its `XX000` answer through the cancelled token, that write is cancelled too, and the nested handler at `:545-547` swallows the failure. The client sees an unexplained connection drop.

PostgreSQL reports the same event explicitly (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/postgres.c:3354-3356`):

```c
			ereport(FATAL,
					(errcode(ERRCODE_ADMIN_SHUTDOWN),
					 errmsg("terminating connection due to administrator command")));
```

`ERRCODE_ADMIN_SHUTDOWN` is SQLSTATE `57P01` (`tests/.cache/postgres/18.4-openssl/source/src/backend/utils/errcodes.txt:435`), which is the code client libraries key their reconnect logic on.

No test inspects the `ErrorResponse` produced by either path.

## What happens now

Spike: a server runs with `Drain_Timeout => 0.5`. One client sends a query whose handler performs a genuine GNAT range check failure, and the client reads back the resulting `ErrorResponse`. A second client stays idle at `ReadyForQuery` while `Request_Shutdown` is called, and reads whatever arrives.

```ada
      if Protocol.Kind (Command) = Protocol.Query then
         --  A genuine GNAT range check failure inside the application
         --  handler, exactly the class of bug whose message ends up on the
         --  wire.  Index is computed so the check cannot be folded away.
         Index := Sink + 5;
         Sink := Table (Index);
      end if;
```

```ada
   Start_Client (Admin_Socket, Admin_Channel);
   Note ("administrator client is idle; calling Request_Shutdown");
   Test_Server.Request_Shutdown (Server);
   Capture (Admin_Channel, Admin_State, Admin_Text, Admin_Length, Admin_Seen);
```

```
  -- handler Constraint_Error -> SQLSTATE XX000 message "repro_server_7.adb:102 index check failed"
  -- administrator client is idle; calling Request_Shutdown
  -- no ErrorResponse arrived: FLYOLOGY.IO.DEVICE_ERROR
  -- forced shutdown -> no ErrorResponse reached the peer at all: the XX000 Send_Error at server.adb:539-544 uses the same cancelled Handler_Stop token and its failure is discarded by the nested handler at :545-547
  FAILED: an internal Ada check failure in the handler does not put a server source file and line number into the ErrorResponse sent to the peer
  FAILED: a session terminated by Request_Shutdown is told SQLSTATE 57P01 (ERRCODE_ADMIN_SHUTDOWN), as PostgreSQL does, instead of receiving no diagnostic at all
BUG REPRODUCED: 2 failed expectation(s)
```

The first line is text read back off the socket by the client, from a real range check inside the application handler rather than a synthetic `raise ... with`.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

An internal failure is reported to the peer as an internal error without disclosing server source coordinates, and an administrator-initiated termination is reported as `FATAL 57P01`, the SQLSTATE PostgreSQL uses at `postgres.c:3354-3356` and the one client reconnect logic recognises.

## Suggested treatment

Give `Operation_Cancelled` its own handler arm in `Run_Session`, ahead of the `when Error : others` arm, that sends `FATAL 57P01 "terminating connection due to administrator command"`. It must not be written through the cancelled token: either write it on a path that does not carry `Handler_Stop`, or write it before the handler token is consumed. Sending it through the same token, as the catch-all does today, is what makes the message disappear.

For the disclosure, stop forwarding `Ada.Exceptions.Exception_Message` for the `XX000` arm and report the detail through the application's own logging instead. What replaces it is a maintainer decision, because the replacement text is externally visible: send a fixed message for every internal error, or forward the exception text only to authenticated sessions and a fixed message otherwise.

The spike is the regression test for both halves, and it belongs with the other `Flyology.Postgres.Server` session coverage in `tests/src/tests.adb`. No existing test asserts the wrong behaviour.

## Severity

The disclosure gives any peer, authenticated or not, a server source file name and line number for each internal check failure. That is low-value information, no secrets and no memory contents, so the impact is small, and it needs a bug in the application handler to appear at all. The missing shutdown diagnostic is on an administrative path: a client that was connected when the operator shut the server down sees a bare connection drop and cannot distinguish it from a network failure, so reconnect logic keyed on `57P01` does not fire. Both are deterministic.
