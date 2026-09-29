--  CLIENT-4: the extended-query DataRow column check uses whichever
--  RowDescription arrived last, not the one describing the executed portal.
--
--  Apply_Extended_Event (client.adb) stores Described_Columns /
--  Has_Row_Description for every RowDescription and compares every DataRow
--  against them.  A RowDescription is not tied to the statement or portal it
--  describes, and the flags are cleared only by CommandComplete,
--  EmptyQueryResponse, NoData, ErrorResponse or ReadyForQuery.
--
--  Describing statement "two" (2 columns) and executing portal "p1" of
--  statement "one" (1 column) in the same batch is legal extended-query
--  traffic.  The server answers 1, 1, 2, t, T(2 fields), D(1 column), C, and
--  Receive_Extended_Event raises Protocol_Error at the DataRow.

with Ada.Exceptions;
with Flyology.Bytes;
with Flyology.Postgres.Client;
with Repro_Support; use Repro_Support;

procedure Repro_Client_4 is

   package Client renames Flyology.Postgres.Client;

   use type Protocol.Backend_Message_Kind;

   Ready_Payload : constant Protocol.Byte_Array (1 .. 1) :=
     (1 => Protocol.Byte (Character'Pos ('I')));

   function Row_Description (Fields : Positive) return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U16 (Contents, Protocol.UInt16 (Fields));
      for Index in 1 .. Fields loop
         Protocol.Append_C_String
           (Contents, "c" & Character'Val (Character'Pos ('0') + Index));
         Protocol.Append_U32 (Contents, 0);        --  table OID
         Protocol.Append_U16 (Contents, 0);        --  column attribute number
         Protocol.Append_U32 (Contents, 23);       --  type OID (int4)
         Protocol.Append_U16 (Contents, 4);        --  type size
         Protocol.Append_U32 (Contents, 16#FFFF_FFFF#);  --  type modifier -1
         Protocol.Append_U16 (Contents, 0);        --  text format
      end loop;
      return Protocol.Make_Message
        ('T', Flyology.Bytes.To_Array (Contents));
   end Row_Description;

   function Single_Column_Row return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U16 (Contents, 1);
      Protocol.Append_U32 (Contents, 1);
      Protocol.Append_Byte (Contents, Protocol.Byte (Character'Pos ('1')));
      return Protocol.Make_Message
        ('D', Flyology.Bytes.To_Array (Contents));
   end Single_Column_Row;

   function Parameter_Description return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_U16 (Contents, 0);
      return Protocol.Make_Message
        ('t', Flyology.Bytes.To_Array (Contents));
   end Parameter_Description;

   function Command_Complete return Protocol.Message is
      Contents : Flyology.Bytes.Unbounded_Bytes;
   begin
      Protocol.Append_C_String (Contents, "SELECT 1");
      return Protocol.Make_Message
        ('C', Flyology.Bytes.To_Array (Contents));
   end Command_Complete;

   Channel : aliased Memory_Transport;
   Session : Client.Session (Channel'Access);
   Authentication : Flyology.Bytes.Unbounded_Bytes;

   Rows_Seen : Natural := 0;
   Failed    : Boolean := False;

begin
   Protocol.Append_U32 (Authentication, 0);
   Queue
     (Channel,
      Protocol.Make_Message ('R', Flyology.Bytes.To_Array (Authentication)));
   Queue (Channel, Protocol.Make_Message ('Z', Ready_Payload));
   Client.Startup (Session, User => "tester", Timeout => 1.0);

   --  One batch: Parse one, Parse two, Bind p1 -> one, Describe statement
   --  "two", Execute p1, Flush.
   Client.Prepare_Statement (Session, "one", "select 1", Timeout => 1.0);
   Client.Prepare_Statement (Session, "two", "select 1, 2", Timeout => 1.0);
   Client.Bind_Portal (Session, "p1", "one", Timeout => 1.0);
   Client.Describe_Statement (Session, "two", Timeout => 1.0);
   Client.Execute_Portal (Session, "p1", Timeout => 1.0);
   Client.Flush (Session, Timeout => 1.0);

   --  Exactly what the backend replies, in message order.
   Queue (Channel, Protocol.Make_Empty_Message ('1'));   --  Parse one
   Queue (Channel, Protocol.Make_Empty_Message ('1'));   --  Parse two
   Queue (Channel, Protocol.Make_Empty_Message ('2'));   --  Bind p1
   Queue (Channel, Parameter_Description);               --  Describe "two"
   Queue (Channel, Row_Description (2));                 --  Describe "two"
   Queue (Channel, Single_Column_Row);                   --  Execute p1
   Queue (Channel, Command_Complete);                    --  Execute p1

   while Bytes_Remaining (Channel) > 0 and then not Failed loop
      begin
         declare
            Event : constant Client.Extended_Query_Event :=
              Client.Receive_Extended_Event (Session, Timeout => 1.0);
         begin
            if Protocol.Response_Kind (Event) = Protocol.Data_Row_Response
            then
               Rows_Seen := Rows_Seen + 1;
               Note
                 ("DataRow delivered with"
                  & Natural'Image
                      (Protocol.Column_Count (Protocol.Row_Data (Event)))
                  & " column(s)");
            end if;
         end;
      exception
         when Error : Protocol.Protocol_Error =>
            Failed := True;
            Note
              ("Receive_Extended_Event raised Protocol_Error: "
               & Ada.Exceptions.Exception_Message (Error));
      end;
   end loop;

   Check
     (not Failed,
      "a RowDescription for another statement does not invalidate the "
      & "executed portal's rows");
   Check
     (Rows_Seen = 1,
      "the executed portal's single-column DataRow is delivered");

   Finish;
exception
   when Error : others =>
      Note
        ("unexpected exception: " & Ada.Exceptions.Exception_Name (Error)
         & ": " & Ada.Exceptions.Exception_Message (Error));
      Check (False, "no unexpected exception escapes the reproduction");
      Finish;
end Repro_Client_4;
