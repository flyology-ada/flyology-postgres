--  Postgres client and protocol-server primitives for Flyology tasks.
package Flyology.Postgres is

   Maximum_Message_Size : constant := 16 * 1_024 * 1_024;

   type Authentication_Method is (Trust, Cleartext_Password);

end Flyology.Postgres;
