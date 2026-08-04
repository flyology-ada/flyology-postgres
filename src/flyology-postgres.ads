--  Postgres client and protocol-server primitives for Flyology tasks.
package Flyology.Postgres is

   Maximum_Message_Size : constant := 16 * 1_024 * 1_024;

   type Authentication_Method is
     (Trust, Cleartext_Password, SCRAM_SHA_256);

   type TLS_Policy is (TLS_Disabled, TLS_Allowed, TLS_Required);

end Flyology.Postgres;
