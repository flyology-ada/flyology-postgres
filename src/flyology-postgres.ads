--  Postgres client and protocol-server primitives for Flyology tasks.
package Flyology.Postgres is
   --  Common configuration types and limits shared by the PostgreSQL client,
   --  protocol server, authentication, and transport packages.

   Maximum_Message_Size : constant := 16 * 1_024 * 1_024;
   --  Largest complete PostgreSQL wire message accepted by the library,
   --  including its type byte and encoded length.

   type Authentication_Method is
     (Trust, Cleartext_Password, SCRAM_SHA_256);
   --  Authentication policy used by a server instance.
   --  @enum Trust Accept a startup user without requesting a credential.
   --  @enum Cleartext_Password Request and verify a plaintext password.
   --  @enum SCRAM_SHA_256 Authenticate with the SCRAM-SHA-256 SASL mechanism.

   type TLS_Policy is (TLS_Disabled, TLS_Allowed, TLS_Required);
   --  Server-side policy for PostgreSQL SSLRequest negotiation.
   --  @enum TLS_Disabled Do not offer TLS on the listener.
   --  @enum TLS_Allowed Accept either plaintext or TLS startup.
   --  @enum TLS_Required Reject plaintext startup and require TLS.

end Flyology.Postgres;
