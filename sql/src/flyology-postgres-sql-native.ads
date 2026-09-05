private package Flyology.Postgres.SQL.Native is

   function Character_Position
     (Text        : String;
      Byte_Offset : Natural) return Natural
     with Pre =>
       Byte_Offset <= Text'Length or else Byte_Offset = Natural'Last;

end Flyology.Postgres.SQL.Native;
