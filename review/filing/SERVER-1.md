Title: Run_Session's first Read_Initial runs in the declarative part, so a bare TCP probe terminates the server
Labels: bug
Refs: PROTO-4

## Summary

`Run_Session` initialises its `Initial` object by calling `Read_Initial` in the subprogram's declarative part, where its own exception handlers cannot reach. Any failure on the very first packet therefore escapes the session, escapes `Process_Connection`, and is recorded by the Flyology structured worker as a server failure: the lifecycle phase moves to `Stop_Requested`, every worker leaves its accept loop, the listener is closed and `Serve` raises `Server_Failed`. One peer that completes a TCP handshake and closes without sending a byte shuts the whole server down.

## Problem

Commit `6f496f5`.

The first read is an object initialisation in the declarative part (`src/flyology-postgres-server.adb:366-374`):

```ada
   procedure Run_Session
     (Context : in out Internal_Context;
      Client  : in out Server_Sessions.Session;
      Connection : in out Flyology.IO.Connections.Connection;
      Cancellation : not null access Flyology.Cancellation.Token) is
      Initial : Protocol.Initial_Request :=
        Server_Sessions.Read_Initial (Client, Startup_Timeout);
      TLS_Active : Boolean := False;
   begin
```

In Ada an exception raised while elaborating a declarative part is not covered by that subprogram's handled sequence of statements. The handlers exist and are written for exactly this failure (`src/flyology-postgres-server.adb:524-532`):

```ada
   exception
      when Error : Protocol.Protocol_Error =>
         begin
            Server_Sessions.Send_Error
              (Client,
               Message   => Ada.Exceptions.Exception_Message (Error),
               SQL_State => "08P01",
               Severity  => "FATAL",
               Timeout   => Write_Timeout);
```

The identical `Read_Initial` inside the negotiation loop (`src/flyology-postgres-server.adb:403`) is covered by them, so the intent is clear and the first read is the odd one out. `Process_Connection` adds no handler of its own (`src/flyology-postgres-server.adb:551-563`).

The exception therefore reaches the Flyology structured worker, which treats an escaped handler exception as a server failure (`flyology-io-structured_servers.adb:451-460` in the pinned runtime):

```ada
                        if Admitted then
                           begin
                              Handle (Context, Connection, Peer, Item.Handler_Stop'Access);
                           exception
                              when Connections.Operation_Cancelled =>
                                 Cancelled := True;
                              when Event : others =>
                                 Report (Handler_Callback, Event);
                                 Failed := True;
                           end;
```

`Report` is `Item.State.Record_Failure (...)` followed by `Stop_Accepting`, which is `Item.Accept_Stop.Request` (`flyology-io-structured_servers.adb:406-410`, `:225-228`). `Record_Failure` ends with `Phase := Policy.Phase_After_Stop (Phase);` (`:126`), so the lifecycle moves to `Stop_Requested` at once; every worker's next `Accept_Connection` raises `Operation_Cancelled` and sets `Stop_Worker := True` (`:444-445`), and `Serve` raises `Server_Failed` on its way out (`:535-537`). The shutdown is prompt and does not wait for a `Request_Shutdown` from the application.

Every trigger is ordinary client behaviour under the documented contract of `Flyology.IO.Connections.Receive_Exactly` (`flyology-io-connections.ads:286-295`): `Device_Error` for a peer that "closes early", `Timeout_Error` for a peer that stays silent past `Startup_Timeout`, and `Protocol.Protocol_Error` from `Wire.Valid_Initial_Length` for a first word outside 8 .. 16 MiB, which the four bytes `GET ` of an HTTP probe satisfy at 1 195 725 856. A protocol option value that `Decode_Initial` rejects reaches the same place, which is why the startup `replication` parsing reported in {{ISSUE:PROTO-4}} produces a silent disconnect instead of a FATAL `ErrorResponse`: it is the same escaping declarative part.

PostgreSQL treats the cheapest of these as unremarkable. `ProcessStartupPacket` returns without logging when the first read yields nothing (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:508-521`):

```c
	if (pq_getbytes(&len, 1) == EOF)
	{
		/*
		 * If we get no data at all, don't clutter the log with a complaint;
		 * such cases often occur for legitimate reasons.  An example is that
		 * we might be here after responding to NEGOTIATE_SSL_CODE, and if the
		 * client didn't like our response, it'll probably just drop the
		 * connection.  Service-monitoring software also often just opens and
		 * closes a connection without sending anything.  (So do port
		 * scanners, which may be less benign, but it's not really our job to
		 * notice those.)
		 */
		return STATUS_ERROR;
	}
```

No test covers a connection that is closed before its startup packet. `tests/scripts/run-integration.sh` drives psql and the in-repo clients only, all of which send a well-formed startup packet, and `tests/src/postgres_test_server.adb:282-288` is the server they drive.

## What happens now

Spike: a server is started on a loopback port with `Drain_Timeout => 1.0`; an ordinary client is served first as a control, then one probe connects and closes without sending a byte, then the identical client runs again.

```ada
   Control_Served := Startup_Is_Answered ("control client");

   --  Probe 1: a bare TCP connect and immediate close, sending nothing.
   declare
      Probe : Sockets.Socket_Type;
   begin
      Sockets.Create_Socket (Probe);
      Sockets.Connect (Probe, Endpoint, Timeout => 2.0);
      Sockets.Close_Socket (Probe);
      Note ("probe 1 connected and closed without sending a byte");
   end;

   delay 0.5;

   --  Probe 2: the same ordinary client, after the early close.
   Second_Client_Served := Startup_Is_Answered ("client after the probe");
```

```
  -- listening on 127.0.0.1: 63928
  -- control client received a backend message tagged 'R'
  -- probe 1 connected and closed without sending a byte
  -- client after the probe failed: FLYOLOGY.IO.SOCKETS.SOCKET_ERROR: connect failed [errno=61]
  -- Serve terminated with REPRO_SERVER_1.TEST_SERVER.STRUCTURED.SERVER_FAILED: raised FLYOLOGY.IO.DEVICE_ERROR : connection closed while receiving
  ok: control: an ordinary client is served before any misbehaving one connects (harness sanity check)
  FAILED: after a client connects and disconnects without sending anything, the listener still serves the next connection
  FAILED: a client that connects and closes early does not make Serve raise a server failure
BUG REPRODUCED: 2 failed expectation(s)
```

The recorded failure text also carries a GNAT traceback, omitted above. The control client is answered with `R` (AuthenticationRequest). The client that follows the probe cannot connect at all: errno 61 is `ECONNREFUSED`, so the listener is already closed, before the program asks for shutdown.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 server sources used for reference.

## What should happen

A peer that connects and closes, stays silent, or sends a first packet the framing rejects should have its own connection dropped, with a FATAL `ErrorResponse` where one can still be written, while the listener keeps accepting. This is what the handlers at `src/flyology-postgres-server.adb:524-548` already do for the second and later initial packets, and what PostgreSQL does for all of them.

## Suggested treatment

Move the first `Read_Initial` out of the declarative part: declare `Initial : Protocol.Initial_Request;` and assign it as the first statement of the handled sequence, so the existing handlers cover it. Wrapping the body of `Process_Connection` in a handler would also stop the escape, but it would answer the malformed-length case with a silent close rather than the FATAL 08P01 the statement-part path produces, so the declaration move is the smaller and more faithful fix.

The spike is the regression test: an early-closing probe followed by an ordinary client belongs beside the other server integration checks in `tests/scripts/run-integration.sh`, or as an Ada test that starts a server, connects and closes a raw socket, and asserts the next startup is answered. No existing test asserts the wrong behaviour.

## Severity

Any peer that can complete a TCP handshake terminates the entire server before authentication, with zero bytes sent. A monitoring health check, `nc -z`, an HTTP request to the wrong port, or a port scanner is enough, and none of those is unusual on a listening port. Every established session dies with the listener, and `Serve` raises `Server_Failed` rather than returning. Deterministic.
