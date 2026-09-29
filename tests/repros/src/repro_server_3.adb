--  SERVER-3: NegotiateProtocolVersion must carry the full protocol version
--  word (major << 16 | minor), not the bare minor number.
--
--  PostgreSQL's backend sends `pq_sendint32(&buf, FrontendProtocol)` in
--  SendNegotiateProtocolVersion (src/backend/tcop/backend_startup.c), where
--  FrontendProtocol is a ProtocolVersion, i.e. PG_PROTOCOL(m,n) =
--  ((m) << 16) | (n)  (src/include/libpq/pqcomm.h).  libpq reads the field
--  back as a ProtocolVersion in pqGetNegotiateProtocolVersion3
--  (src/interfaces/libpq/fe-protocol3.c) and rejects anything below
--  PG_PROTOCOL(3, 0):
--     "received invalid protocol negotiation message: server requested
--      downgrade to pre-3.0 protocol version"
--  A bare minor of 2 is 0x00000002, far below 0x00030000, so the message
--  this library emits for the only case in which it is ever sent aborts the
--  connection.
--
--  Correct behavior: the 'v' frame's first Int32 payload word is 00 03 00 02
--  when the server negotiates down to protocol 3.2.

with Flyology.Postgres.Server_Sessions;
with Repro_Support; use Repro_Support;

procedure Repro_Server_3 is

   package Sessions renames Flyology.Postgres.Server_Sessions;

   use type Protocol.Byte;
   use type Protocol.Byte_Offset;

   Channel : aliased Memory_Transport;
   Session : Sessions.Session (Channel'Access);

   Latest_Minor : constant := 2;
   --  The value Server.Run_Session passes (src/flyology-postgres-server.adb
   --  :444-447) when the client requests a minor above 2.

   Expected_Frame : constant Protocol.Byte_Array (1 .. 13) :=
     (1  => Protocol.Byte (Character'Pos ('v')),
      2  => 0, 3 => 0, 4 => 0, 5 => 12,   --  length: 4 + 4 + 4
      6  => 0, 7 => 3, 8 => 0, 9 => 2,    --  PG_PROTOCOL(3, 2)
      10 => 0, 11 => 0, 12 => 0, 13 => 0); --  0 unrecognized options

begin
   Sessions.Send_Negotiate_Protocol (Session, Latest_Minor, 1.0);

   declare
      Frame : constant Protocol.Byte_Array := Sent (Channel);
   begin
      Note ("Send_Negotiate_Protocol (Latest_Minor => 2) emitted: "
            & Hex (Frame));
      Note ("PostgreSQL would emit:                             "
            & Hex (Expected_Frame));

      Check
        (Frame'Length = Expected_Frame'Length
         and then Frame (Frame'First) =
           Protocol.Byte (Character'Pos ('v')),
         "a NegotiateProtocolVersion frame of the documented size is sent");

      if Frame'Length = 13 then
         Note
           ("version word on the wire: "
            & Hex (Frame (Frame'First + 5 .. Frame'First + 8)));
         Check
           (Frame (Frame'First + 5) = 0
            and then Frame (Frame'First + 6) = 3
            and then Frame (Frame'First + 7) = 0
            and then Frame (Frame'First + 8) = 2,
            "the version word is the full ProtocolVersion 00 03 00 02, as "
            & "PostgreSQL's SendNegotiateProtocolVersion emits and libpq's "
            & "pqGetNegotiateProtocolVersion3 requires (>= PG_PROTOCOL(3,0))");
         Check
           (Frame (Frame'First + 9) = 0
            and then Frame (Frame'First + 10) = 0
            and then Frame (Frame'First + 11) = 0
            and then Frame (Frame'First + 12) = 0,
            "the unrecognized-option count is zero");
      end if;
   end;

   Finish;
end Repro_Server_3;
