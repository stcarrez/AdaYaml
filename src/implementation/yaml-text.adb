--  part of AdaYaml, (c) 2017 Felix Krause
--  released under the terms of the MIT license, see the file "copying.txt"

with Ada.Unchecked_Deallocation;

package body Yaml.Text is
   type Header_Access is access Header;
   for Header_Access'Size use Standard'Address_Size;

   --  it is important that all allocated strings are aligned to the header
   --  length. else, it may happen that we generate a region of free memory that
   --  is not large enough to hold a header – but we need to write the header
   --  there to hold information for the ring list. therefore, whenever we
   --  calculate offsets, we use this to round them up to a multiple of
   --  Header_Size.
   function Round_To_Header_Size (Length : Pool_Offset)
                                  return Pool_Offset is
     ((Length + Header_Size - 1) / Header_Size * Header_Size);

   procedure Create (P : in out Pool; Initial_Size : Pool_Offset)
   is
     Initial_Chunk : constant Chunk := new Pool_Array
          (Pool_Offset (1) .. Round_To_Header_Size (Initial_Size));
   begin
      if P.Data /= null then
         Finalize (P);
      end if;
      P.Data := new Pool_Data;
      P.Data.Chunks (1) := Initial_Chunk;
      P.Data.Pos := 1;
      declare
         H : Header with Import;
         for H'Address use Initial_Chunk.all (1)'Address;
      begin
         H.Refcount := 0;
         H.Last := Pool_Offset (Initial_Chunk'Last) - Header_Size;
      end;
   end Create;

   function Header_Of (S : UTF_8_String_Access) return access Header
     with Inline is
      function Convert is new Ada.Unchecked_Conversion
        (System.Address, Header_Access);
      use System.Storage_Elements;
   begin
      return Convert (S.all'Address - Storage_Offset (Header_Size));
   end Header_Of;

   function Value (Object : Reference) return Accessor is
     (Accessor'(Data => Object.Data, Hold => Object));

   function Length (Object : Reference) return Natural is
     (Object.Data'Length);

   function "&" (Left, Right : Reference) return String is
     (Left.Data.all & Right.Data.all);

   function "&" (Left : Reference; Right : String) return String is
     (Left.Data.all & Right);

   function "&" (Left : Reference; Right : Character) return String is
     (Left.Data.all & Right);

   function "&" (Left : String; Right : Reference) return String is
     (Left & Right.Data.all);

   function "&" (Left : Character; Right : Reference) return String is
     (Left & Right.Data.all);

   function "=" (Left, Right : Reference) return Boolean is
     (Left.Data = Right.Data or else
        (Left.Data /= null and then Right.Data /= null and then
         Left.Data.all = Right.Data.all));

   function "=" (Left : Reference; Right : String) return Boolean is
     (Left.Data.all = Right);

   function "=" (Left : String; Right : Reference) return Boolean is
     (Left = Right.Data.all);

   function From_String (P : in out Pool'Class; Data : String)
                         return Reference is
      Necessary : constant Pool_Offset :=
        Round_To_Header_Size (Data'Length + 1);

      function Fitting_Position return System.Address is
         Cur : Pool_Offset := P.Data.Pos;

         procedure Allocate_Next_Chunk is
            Next : Chunk_Index_Type;
         begin
            for I in Chunk_Index_Type loop
               if P.Data.Chunks (I) = null then
                  Next := I;
                  goto Found;
               end if;
            end loop;

            raise Storage_Error with "String pool depleted.";

            <<Found>>

            P.Data.Chunks (Next) := new Pool_Array
              (Pool_Offset (1) .. Pool_Offset'Max (
               P.Data.Chunks (P.Data.Cur)'Length * 2,
               Necessary + Header_Size));
            P.Data.Cur := Next;
            P.Data.Pos := 1;
         end Allocate_Next_Chunk;
      begin
         loop
            declare
               C : constant Chunk := P.Data.Chunks (P.Data.Cur);
               pragma Warnings (Off, C);
                 --  no 'may be modified via address clause'
               H : Header with Import;
               for H'Address use C (Cur)'Address;
            begin
               <<Check_Length>>

               if H.Last >= Necessary then
                  P.Data.Pos := Cur + Header_Size + Necessary;
                  if H.Last > Necessary then
                     declare
                        Next : Header with Import;
                        for Next'Address use C (P.Data.Pos)'Address;
                        use System.Storage_Elements;
                     begin
                        Next.Refcount := 0;
                        Next.Last := H.Last - Necessary - Header_Size;
                     end;
                  else
                     loop
                        if P.Data.Pos > C.all'Last then
                           P.Data.Pos := 1;
                        end if;
                        if P.Data.Pos = Cur then
                           Allocate_Next_Chunk;
                           exit;
                        end if;
                        declare
                           Next : Header with Import;
                           for Next'Address use C (P.Data.Pos)'Address;
                        begin
                           exit when Next.Refcount = 0;
                           P.Data.Pos := P.Data.Pos + Header_Size +
                             Round_To_Header_Size (Next.Last + 1);
                        end;
                     end loop;
                  end if;
                  H.Refcount := 1;
                  H.Pool := P.Data;
                  H.Chunk_Index := P.Data.Cur;
                  H.Last := Data'Length;
                  H.First := 1;
                  P.Data.Usage (P.Data.Cur) :=
                    P.Data.Usage (P.Data.Cur) + 1;
                  return H'Address + Header_Size;
               else
                  declare
                     Next_Pos : constant Pool_Offset :=
                       Cur + Header_Size + H.Last;
                  begin
                     if Next_Pos <= C.all'Last then
                        declare
                           Next : Header with Import;
                           for Next'Address use C (Next_Pos)'Address;
                        begin
                           if Next.Refcount = 0 then
                              H.Last := H.Last + Header_Size + Next.Last;
                              goto Check_Length;
                           end if;
                        end;
                     end if;
                  end;
               end if;
               Cur := Cur + H.Last + Header_Size;
               loop
                  if Cur >= C.all'Last then
                     Cur := 1;
                  end if;
                  if Cur = P.Data.Pos then
                     Allocate_Next_Chunk;
                     exit;
                  end if;
                  declare
                     Next : Header with Import;
                     for Next'Address use C (Cur)'Address;
                  begin
                     exit when Next.Refcount = 0;
                     Cur := Cur + Round_To_Header_Size (Next.Last + 1);
                  end;
               end loop;
            end;
         end loop;
      end Fitting_Position;

      function Convert is new Ada.Unchecked_Conversion
        (System.Address, UTF_8_String_Access);

      New_String_Address : constant System.Address := Fitting_Position;
      Target_Data : constant UTF_8_String_Access :=
        Convert (New_String_Address);
      Null_Terminator : Character with Import;
      for Null_Terminator'Address use New_String_Address + Data'Length;
   begin
      Null_Terminator := Character'Val (0);
      Target_Data.all := UTF_8_String (Data);
      return (Ada.Finalization.Controlled with Data => Target_Data);
   end From_String;

   procedure Adjust (Object : in out Reference) is
   begin
      if Object.Data /= null then
         declare
            H : constant access Header := Header_Of (Object.Data);
         begin
            if H.Pool /= null then
               H.Refcount := H.Refcount + 1;
            end if;
         end;
      end if;
   end Adjust;

   procedure Decrease_Usage (Pool : in out Pool_Data_Access;
                             Chunk_Index : Chunk_Index_Type) is
      procedure Free_Chunk is new Ada.Unchecked_Deallocation
        (Pool_Array, Chunk);
      procedure Free_Data is new Ada.Unchecked_Deallocation
        (Pool_Data, Pool_Data_Access);
   begin
      Pool.Usage (Chunk_Index) := Pool.Usage (Chunk_Index) - 1;
      if Pool.Usage (Chunk_Index) = 0 then
         Free_Chunk (Pool.Chunks (Chunk_Index));
         for I in Chunk_Index_Type loop
            if Pool.Chunks (I) /= null then
               return;
            end if;
         end loop;
         Free_Data (Pool);
      end if;
   end Decrease_Usage;

   procedure Finalize (Object : in out Reference) is
      Reference : constant UTF_8_String_Access := Object.Data;
   begin
      Object.Data := null;
      if Reference /= null then
         declare
            H : constant access Header := Header_Of (Reference);
         begin
            if H.Pool /= null then
               H.Refcount := H.Refcount - 1;
               if H.Refcount = 0 then
                  H.Last := Round_To_Header_Size (H.Last);
                  Decrease_Usage (H.Pool, H.Chunk_Index);
               end if;
            end if;
         end;
      end if;
   end Finalize;

   procedure Adjust (Object : in out Pool) is
   begin
      if Object.Data /= null then
         Object.Data.Refcount := Object.Data.Refcount + 1;
      end if;
   end Adjust;

   procedure Finalize (Object : in out Pool) is
      Reference : Pool_Data_Access := Object.Data;
   begin
      Object.Data := null;
      if Reference /= null then
         Reference.Refcount := Reference.Refcount - 1;
         if Reference.Refcount = 0 then
            --  no reference around; take away Usage + 1 from the current Chunk.
            --  this enables the whole pool data to be freed once all Content
            --  references vanish.
            Decrease_Usage (Reference, Reference.Cur);
         end if;
      end if;
   end Finalize;

   function Current_Chunk_As_String (P : Pool) return String is
      C : constant Chunk := P.Data.Chunks (P.Data.Cur);
      function Hex (Val : Integer) return Character is
        (if Val < 10 then Character'Val (Val + Character'Pos ('0')) else
            Character'Val (Val - 10 + Character'Pos ('A')));
   begin
      return Ret : String (1 .. Positive (C.all'Last) * 2) do
         for I in C.all'Range loop
            Ret (Integer (I) * 2 - 1) := Hex (Integer (C (I)) / 16);
            Ret (Integer (I) * 2) := Hex (Integer (C (I)) mod 16);
         end loop;
      end return;
   end Current_Chunk_As_String;

   function Held (Holder : Constant_Instance) return Reference is
     ((Reference'(Ada.Finalization.Controlled with
                Data => To_UTF_8_String_Access (Holder.S'Address))));

   function Export (Object : Reference) return Exported is
      H : constant access Header := Header_Of (Object.Data);
   begin
      H.Refcount := H.Refcount + 1;
      return Object.Data.all'Address;
   end Export;

   function Import (Pointer : Exported) return Reference is
      function Convert is new Ada.Unchecked_Conversion
        (Exported, UTF_8_String_Access);
   begin
      return Value : constant Reference := (Ada.Finalization.Controlled with
                                            Data => Convert (Pointer)) do
         declare
            H : constant access Header := Header_Of (Value.Data);
         begin
            H.Refcount := H.Refcount + 1;
         end;
      end return;
   end Import;

   procedure Delete_Exported (Pointer : Exported) is
      use System.Storage_Elements;
      H : Header with Import;
      for H'Address use Pointer - Storage_Offset (Header_Size);
   begin
      H.Refcount := H.Refcount - 1;
      if H.Refcount = 0 then
         H.Last := Round_To_Header_Size (H.Last);
         Decrease_Usage (H.Pool, H.Chunk_Index);
      end if;
   end Delete_Exported;

end Yaml.Text;