# Native PostgreSQL BASE_BACKUP

`Flyology.Postgres.Replication.Base_Backups` takes or proxies physical base
backups without executing `pg_basebackup`. The caller creates and authenticates
a `Client.Session`, chooses plaintext or verified TLS, and owns archive storage
and durability.

## Client flow

Start in `Physical_Replication_Connection` mode, construct options for the
server's actual major version, and consume events until `Complete`:

```ada
declare
   Settings : Base_Backups.Options := Base_Backups.Defaults (18);
   Stream   : Base_Backups.Receiver (Session'Access);
begin
   Base_Backups.Set_Checkpoint
     (Settings, Base_Backups.Fast_Checkpoint);
   Base_Backups.Include_WAL (Settings);
   Base_Backups.Wait_For_Archive (Settings, False);
   Base_Backups.Set_Progress (Settings);
   Base_Backups.Set_Manifest
     (Settings, Base_Backups.Include_Manifest,
      Base_Backups.SHA256_Checksum);
   Base_Backups.Start (Stream, Settings);

   loop
      declare
         Event : constant Base_Backups.Event := Base_Backups.Receive (Stream);
      begin
         case Base_Backups.Kind (Event) is
            when Base_Backups.Archive_Data |
                 Base_Backups.Manifest_Data =>
               --  Write Data (Event) before receiving the next event.
               null;
            when Base_Backups.Error =>
               --  Record Diagnostic (Event), then drain through Complete.
               null;
            when Base_Backups.Complete =>
               exit;
            when others =>
               null;
         end case;
      end;
   end loop;
end;
```

Each `Receive` returns at most one PostgreSQL `CopyData` payload. The library
does not collect a tar archive, manifest, or tablespace list. This supplies
natural backpressure, and every frame is bounded by the 16 MiB protocol limit.
PostgreSQL tar streams use ustar and omit the two terminal zero blocks.

`Backup_Start` and `Backup_End` expose LSN and timeline. The receiver rejects a
final LSN before the starting LSN, a zero timeline, or a timeline change during
one backup. `Tablespace` preserves SQL NULL separately for the base directory's
OID/location and for an unavailable progress estimate.

## Compatibility

| Major | Command options | Wire stream | Manifest | Incremental |
| --- | --- | --- | --- | --- |
| 14 | Legacy keywords such as `FAST` and `NOWAIT` | One COPY OUT per archive; optional manifest stream | Yes | No |
| 15 | Parenthesized options; targets and server compression | One multiplexed `n`/`m`/`d`/`p` COPY OUT | Yes | No |
| 16 | PostgreSQL 15 protocol; zstd `long` detail | Multiplexed | Yes | No |
| 17 | PostgreSQL 16 protocol | Multiplexed | Yes | `UPLOAD_MANIFEST`, then `INCREMENTAL` |
| 18 | PostgreSQL 17 protocol | Multiplexed | Yes | Yes |

Option setters reject unavailable capabilities locally and never downgrade an
option silently. `Receiver.Start` accepts only the client target. Server and
blackhole targets can be encoded with `Command`, but intentionally have no
fictitious archive stream.

For PostgreSQL 17 or 18 incremental backup, call `Begin_Manifest_Upload`, send
bounded prior-manifest chunks with `Send_Manifest_Chunk`, finish, and drain the
ordinary COPY completion through `Client` until ready. Then enable
`Set_Incremental` and start the backup. PostgreSQL validates the uploaded
manifest chain and checksums. The server must have `summarize_wal=on`, and the
caller must retain the prior manifest independently of the archive destination.

## Security and cancellation

A base backup contains the entire cluster, configuration, and credential
material. Use a dedicated `REPLICATION` role, restrict `pg_hba.conf`, and prefer
`Startup_TLS` with hostname and CA verification. Do not log archive contents,
manifests, target details, passwords, or cancellation secrets. The server target
additionally requires superuser or `pg_write_server_files`; its path is on the
database host.

`Cancel` uses the active session's backend key on a distinct, already-open
transport. Negotiate verified TLS there first when required. PostgreSQL closes
the cancellation connection without a response. Continue receiving on the main
session: cancellation normally yields SQLSTATE `57014`, then `Complete` after
`ReadyForQuery`. Treat output as incomplete until both `Backup_End` and
`Complete`; quarantine or remove partial destinations on every failure.

The package does not extract tar paths. Extractors must independently reject
absolute paths, `..` traversal, unexpected links, device nodes, and tablespace
mappings outside approved roots.

## Server/proxy boundary

`Replication.Decode_Command` classifies `BASE_BACKUP` and `UPLOAD_MANIFEST` so
servers can route or proxy the original owned query. The
`Base_Backups.Server_Sessions` child emits result sets, tablespace rows, legacy
or multiplexed streams, and upload COPY IN. It deliberately does not implement
filesystem walking, tar creation, backup mode, privilege checks, manifest
validation, or durable storage; applications must provide those semantics.

## psqlbench migration

This checkout does not contain an `examples/psqlbench` source tree, so the
finished protocol slice cannot patch that example directly. When it is present:

1. Keep the primary container and authentication, but remove the disposable
   sidecar or command that executes `pg_basebackup`.
2. Open a Flyology transport, start a physical replication session, and create
   options for the probed server major. Include WAL for a self-contained backup.
3. Map each `Archive_Start` to a bounded file sink, write every data chunk
   immediately, and map external tablespaces only into explicit disposable
   example directories.
4. Publish the completed directory only after consistent `Backup_End` and
   `Complete`. On timeout, cancellation, diagnostic, or filesystem error,
   cancel, drain to `Complete`, and discard the partial directory.
5. Start the disposable PostgreSQL instance from that directory and retain the
   benchmark's existing readiness probe. This preserves its lifecycle while
   removing the `pg_basebackup` executable dependency.
