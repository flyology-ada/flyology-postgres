--  PROTO-3: Decode_Initial is documented as taking the complete packet
--  "including its length field" (protocol.ads:589-590) but actually decodes
--  the bytes AFTER the length word.  Feeding it a complete packet, as the
--  documentation instructs, silently misclassifies it as Unknown_Initial.

with Ada.Exceptions;
with Repro_Support; use Repro_Support;

procedure Repro_Proto_3 is

   use type Protocol.Initial_Kind;

   procedure Classify
     (Label    : String;
      Packet   : Protocol.Byte_Array;
      Expected : Protocol.Initial_Kind)
   is
      Result : Protocol.Initial_Kind := Protocol.Unknown_Initial;
      Failed : Boolean := False;
   begin
      begin
         Result := Protocol.Kind (Protocol.Decode_Initial (Packet));
      exception
         when E : Protocol.Protocol_Error =>
            Failed := True;
            Note (Label & ": raised Protocol_Error: "
                  & Ada.Exceptions.Exception_Message (E));
      end;
      if not Failed then
         Note (Label & ": Decode_Initial -> " & Result'Image
               & " (expected " & Expected'Image & ")");
      end if;
      Check
        (not Failed and then Result = Expected,
         Label & " decodes as " & Expected'Image
         & " when the complete packet is passed, as documented");
   end Classify;

begin
   Note ("protocol.ads:589 -- ""Strictly decode an untagged initial packet "
         & "including its length field.""");
   Note ("protocol.ads:590 -- ""@param Contents Complete packet bytes.""");

   Classify
     ("complete 8-byte SSLRequest packet",
      Protocol.Encode_SSL_Request,
      Protocol.SSL_Request);

   Classify
     ("complete CancelRequest packet",
      Protocol.Encode_Cancel_Request (12345, (1 .. 4 => 16#AB#)),
      Protocol.Cancel_Request);

   Classify
     ("complete startup packet",
      Protocol.Encode_Startup (User => "alice"),
      Protocol.Startup);

   Finish;
end Repro_Proto_3;
