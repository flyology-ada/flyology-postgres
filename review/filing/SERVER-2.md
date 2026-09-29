Title: TLS_Required rejects a plaintext CancelRequest, so psql's Ctrl-C never cancels a running query
Labels: bug
Refs: none

## Summary

`Run_Session` applies the `TLS_Required` gate before it looks at what the initial request is, so a `CancelRequest` that arrives on a plaintext connection is answered with `FATAL 08004 "TLS is required"` and never reaches the cancellation router. PostgreSQL handles a cancel packet first and unconditionally, and psql's Ctrl-C still sends it over a bare socket through the legacy `PQcancel` path. Against a `TLS_Required` server, which is the policy this repository's own test server ships, Ctrl-C and every driver built on `PQcancel` silently stop working.

## Problem

Commit `6f496f5`.

The gate runs first (`src/flyology-postgres-server.adb:406-419`):

```ada
      if Context.TLS_Mode = TLS_Required and then not TLS_Active then
         Server_Sessions.Send_Error
           (Client,
            Message   => "TLS is required",
            SQL_State => "08004",
            Severity  => "FATAL",
            Timeout   => Write_Timeout);
         return;
      end if;

      if Protocol.Kind (Initial) = Protocol.Cancel_Request then
         Context.Router.Route
           (Protocol.Process_Id (Initial), Protocol.Secret_Key (Initial));
         return;
```

There is no earlier cancel path, so the `return` at `:413` is the end of the packet's life.

The library's own specification is narrower than this behaviour. `src/flyology-postgres-server.ads:85` scopes the parameter to startup:

```ada
   --  @param Policy Whether plaintext startup is allowed or rejected.
```

and `:77-78` frames `TLS_Required` the same way ("TLS_Allowed accepts both modes; TLS_Required rejects plaintext"). A CancelRequest is not a startup.

PostgreSQL processes `CANCEL_REQUEST_CODE` before any SSL handling and with no `hostssl`-style condition (`tests/.cache/postgres/18.4-openssl/source/src/backend/tcop/backend_startup.c:568-575`):

```c
	if (proto == CANCEL_REQUEST_CODE)
	{
		ProcessCancelRequestPacket(port, buf, len);
		/* Not really an error, but we don't want to proceed further */
		return STATUS_ERROR;
	}

	if (proto == NEGOTIATE_SSL_CODE && !ssl_done)
```

The ordering is the same in every supported major: in PostgreSQL 14.23 the equivalent code is `tests/.cache/postgres/14.23-openssl/source/src/backend/postmaster/postmaster.c:2028` for the cancel request and `:2042` for the SSL negotiation. A cancel packet carries no credential beyond the secret key it must already know, which is why it needs no encrypted channel.

psql sends it in plaintext. `handle_sigint` calls `PQcancel` from the signal handler (`tests/.cache/postgres/18.4-openssl/source/src/fe_utils/cancel.c:153-165`, and again at `:211` for the Windows handler), and `PQcancel` is introduced as the legacy path (`tests/.cache/postgres/18.4-openssl/source/src/interfaces/libpq/fe-cancel.c:528`):

```c
 * PQcancel: old, non-encrypted, but signal-safe way of requesting query cancel
```

It opens a raw socket and writes the cancel packet with no SSLRequest, because a SIGINT handler has to stay async-signal-safe. Only `PQcancelCreate`/`PQcancelBlocking` negotiate TLS, and psql's SIGINT path does not use them.

The affected policy is the shipped one: `tests/src/postgres_test_server.adb:287` passes `Policy => Flyology.Postgres.TLS_Required`.

The existing cancellation test does not reach the plaintext path. `tests/src/postgres_test_cancellation.adb:59-69` sends `Encode_SSL_Request`, checks for `S`, calls `Upgrade_TLS`, and only then writes the CancelRequest, so every cancel it sends is encrypted. `tests/scripts/run-integration.sh` does not exercise Ctrl-C at all.

## What happens now

Spike: two servers run on loopback ports, identical except for `Policy`, and each receives the same plaintext `CancelRequest`. The TLS provider is a stub that raises if it is touched, so a reply proves the TLS machinery was never reached.

```ada
      Sockets.Send_All
        (Socket,
         Protocol.Encode_Cancel_Request (12_345, Secret),
         Timeout => 2.0);
      Sockets.Receive (Socket, Data, Last, Timeout => 3.0);
      if Last < Data'First then
         Sockets.Close_Socket (Socket);
         return "<silent close>";
      end if;
```

```
  -- Policy => TLS_Allowed,  plaintext CancelRequest -> <silent close>
  -- Policy => TLS_Required, plaintext CancelRequest -> 45 00 00 00 2b 53 46 41 54 41 4c 00 56 46 41 54 41 4c 00 43 30 38 30 30 34 00 4d 54 4c 53 20 69 73 20 72 65 71 75 69 72 65 64 00 00   (E   +SFATAL VFATAL C08004 MTLS is required  )
  ok: control: under TLS_Allowed a plaintext CancelRequest is routed and the connection closes silently
  FAILED: under TLS_Required a plaintext CancelRequest is still routed and closed silently, as PostgreSQL handles CANCEL_REQUEST_CODE before any SSL negotiation
  -- psql's Ctrl-C (fe_utils/cancel.c -> PQcancel, the 'old, non-encrypted, signal-safe' path) therefore never cancels anything against a TLS_Required server
BUG REPRODUCED: 1 failed expectation(s)
```

The control server, which differs only in `Policy`, closes silently as PostgreSQL does, so the gate is the sole cause.

Host: macOS 26.6.2, arm64, GNAT 16.1.0 via Alire. PostgreSQL 18.4 and 14.23 server and libpq sources used for reference.

## What should happen

A `CancelRequest` should be routed and the connection closed silently whatever the TLS policy is, matching `ProcessStartupPacket` and the documented scope of `Policy`, which covers plaintext startup only.

## Suggested treatment

Move the `Protocol.Kind (Initial) = Protocol.Cancel_Request` branch at `src/flyology-postgres-server.adb:416-419` above the `TLS_Required` gate at `:406-414`. The gate then applies only to `Startup` and to unsupported initial kinds, which is what `server.ads:85` documents.

The spike is the regression test: it belongs beside the existing cancellation coverage in `tests/src/postgres_test_cancellation.adb`, as a plaintext variant of `Send_Raw_Cancel` that skips the `Encode_SSL_Request`/`Upgrade_TLS` pair at `:59-65` and asserts a silent close. No existing test asserts the wrong behaviour.

## Severity

Query cancellation does not work at all against a `TLS_Required` server for any client that uses `PQcancel`, which includes psql's Ctrl-C and the drivers built on the same entry point. The user sees "Cancel request sent" and the query runs to completion. Nothing is corrupted and no connection is broken, so the damage is a lost feature rather than a wrong result, but it is lost under the policy the repository's own test server ships. Deterministic.
