-- ***************************************************************************
--                      Tracker - XM Format
--
--           Copyright (C) 2026 By Ulrik Hørlyk Hjort
--
-- Permission is hereby granted, free of charge, to any person obtaining
-- a copy of this software and associated documentation files (the
-- "Software"), to deal in the Software without restriction, including
-- without limitation the rights to use, copy, modify, merge, publish,
-- distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to
-- the following conditions:
--
-- The above copyright notice and this permission notice shall be
-- included in all copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
-- EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
-- MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
-- NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
-- LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
-- OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
-- WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
-- ***************************************************************************
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Deallocation;
with Ada.Numerics.Elementary_Functions;
with Ada.Unchecked_Conversion;
with Ada.Exceptions;
with Ada.Text_IO;

package body XM_Format is

   use Ada.Streams.Stream_IO;
   use Ada.Numerics.Elementary_Functions;

   --  Bit-reinterpret helpers (avoid Constraint_Error on high-bit values)
   function U8_To_I8  is new Ada.Unchecked_Conversion (Unsigned_8,  Integer_8);
   function U16_To_I16 is new Ada.Unchecked_Conversion (Unsigned_16, Integer_16);

   subtype Stream_Access is Ada.Streams.Stream_IO.Stream_Access;

   --  ---------------------------------------------------------------
   --  Low-level readers (XM is little-endian throughout)
   --  ---------------------------------------------------------------

   function Read_U8 (S : Stream_Access) return Unsigned_8 is
      V : Unsigned_8;
   begin
      Unsigned_8'Read (S, V);
      return V;
   end Read_U8;

   function Read_I8 (S : Stream_Access) return Integer_8 is
      V : Integer_8;
   begin
      Integer_8'Read (S, V);
      return V;
   end Read_I8;

   function Read_U16_LE (S : Stream_Access) return Unsigned_16 is
      Lo : constant Unsigned_8 := Read_U8 (S);
      Hi : constant Unsigned_8 := Read_U8 (S);
   begin
      return Shift_Left (Unsigned_16 (Hi), 8) or Unsigned_16 (Lo);
   end Read_U16_LE;

   function Read_U32_LE (S : Stream_Access) return Unsigned_32 is
      B0 : constant Unsigned_8 := Read_U8 (S);
      B1 : constant Unsigned_8 := Read_U8 (S);
      B2 : constant Unsigned_8 := Read_U8 (S);
      B3 : constant Unsigned_8 := Read_U8 (S);
   begin
      return Shift_Left (Unsigned_32 (B3), 24)
           or Shift_Left (Unsigned_32 (B2), 16)
           or Shift_Left (Unsigned_32 (B1),  8)
           or             Unsigned_32 (B0);
   end Read_U32_LE;

   procedure Read_String (S : Stream_Access; Str : out String) is
   begin
      for I in Str'Range loop
         Str (I) := Character'Val (Read_U8 (S));
      end loop;
   end Read_String;

   procedure Skip (S : Stream_Access; N : Natural) is
      Dummy : Unsigned_8;
   begin
      for I in 1 .. N loop
         Unsigned_8'Read (S, Dummy);
      end loop;
   end Skip;

   --  ---------------------------------------------------------------
   --  Delta decoding (XM stores sample deltas, not absolute values)
   --  ---------------------------------------------------------------

   function I8_To_U8  is new Ada.Unchecked_Conversion (Integer_8,  Unsigned_8);
   function I16_To_U16 is new Ada.Unchecked_Conversion (Integer_16, Unsigned_16);

   procedure Delta_Decode_8 (Data : in out Sample_Data_8) is
      --  Accumulate using unsigned so wrap-around is well-defined (not CE)
      Acc : Unsigned_8 := 0;
   begin
      for I in Data'Range loop
         Acc      := Acc + I8_To_U8 (Data (I));
         Data (I) := U8_To_I8 (Acc);
      end loop;
   end Delta_Decode_8;

   procedure Delta_Decode_16 (Data : in out Sample_Data_16) is
      Acc : Unsigned_16 := 0;
   begin
      for I in Data'Range loop
         Acc      := Acc + I16_To_U16 (Data (I));
         Data (I) := U16_To_I16 (Acc);
      end loop;
   end Delta_Decode_16;

   --  ---------------------------------------------------------------
   --  Frequency helpers
   --  ---------------------------------------------------------------

   function Linear_Period (Note : Note_Value; Finetune : Integer) return Float
   is
      --  Linear period = 10*12*16*4 - note*16*4 - finetune/2
      --  where note is 0-based (C-0=0)
      Note_0 : constant Integer := Integer (Note) - 1;
   begin
      return Float (10 * 12 * 16 * 4 - Note_0 * 16 * 4) - Float (Finetune) / 2.0;
   end Linear_Period;

   function Amiga_Period (Note : Note_Value; Finetune : Integer) return Float
   is
      --  Base Amiga period for C-5 = 428 (at finetune 0)
      --  period = C5_period * 2^(-note/12) * 2^(-finetune/(12*128))
      --  Simplified: use 7093789.2 / (2 * hz) = period
      C5_Hz    : constant Float := 8363.0;
      Note_0   : constant Float := Float (Integer (Note) - 1);
      Fine     : constant Float := Float (Finetune) / (128.0 * 12.0);
      Hz       : constant Float := C5_Hz * (2.0 ** ((Note_0 - 57.0) / 12.0 + Fine));
   begin
      return Float (Amiga_Clock) / (2.0 * Hz);
   end Amiga_Period;

   --  ---------------------------------------------------------------
   --  Pattern reading (packed XM format)
   --  ---------------------------------------------------------------

   procedure Read_Pattern
     (S        : Stream_Access;
      Pat      : in out XM_Pattern;
      Channels : Positive)
   is
      procedure Free_Row is new Ada.Unchecked_Deallocation
        (XM_Row, XM_Row_Access);

      Hdr_Size : constant Unsigned_32 := Read_U32_LE (S);
      Packing  : constant Unsigned_8  := Read_U8 (S);
      Num_Rows : constant Positive    :=
                   Positive (Unsigned_16'Max (1, Read_U16_LE (S)));
      Data_Sz  : constant Natural     := Natural (Read_U16_LE (S));
      pragma Unreferenced (Packing);

      --  Skip any extra header bytes
      Extra : constant Natural :=
                Natural (Hdr_Size) - 9;  --  9 = standard header size
      Total    : constant Natural := Num_Rows * Channels;
      Byte     : Unsigned_8;
      Mask     : Unsigned_8;
      Cell     : Pattern_Cell;
      Pos      : Natural := 0;  --  bytes consumed from packed data
   begin
      if Extra > 0 then Skip (S, Extra); end if;

      if Pat.Cells /= null then Free_Row (Pat.Cells); end if;
      Pat.Num_Rows     := Num_Rows;
      Pat.Num_Channels := Channels;

      if Data_Sz = 0 then
         --  Empty pattern - allocate zeroed cells
         Pat.Cells := new XM_Row (0 .. Total - 1);
         return;
      end if;

      Pat.Cells := new XM_Row (0 .. Total - 1);

      for R in 0 .. Num_Rows - 1 loop
         for C in 0 .. Channels - 1 loop
            Cell := [others => <>];  --  default empty

            Byte := Read_U8 (S);
            Pos  := Pos + 1;

            if (Byte and 16#80#) /= 0 then
               --  Compressed: Byte is a mask
               Mask := Byte and 16#7F#;

               if (Mask and 16#01#) /= 0 then  --  note
                  Byte := Read_U8 (S); Pos := Pos + 1;
                  if Byte in 1 .. 97 then
                     Cell.Note := Note_Value (Byte);
                  end if;
               end if;

               if (Mask and 16#02#) /= 0 then  --  instrument
                  Byte := Read_U8 (S); Pos := Pos + 1;
                  Cell.Instrument :=
                    Instrument_Index'Min (Instrument_Index'Last,
                                         Instrument_Index (Byte));
               end if;

               if (Mask and 16#04#) /= 0 then  --  volume
                  Byte := Read_U8 (S); Pos := Pos + 1;
                  Cell.Volume := Natural (Byte);
               end if;

               if (Mask and 16#08#) /= 0 then  --  effect type
                  Cell.Effect := Read_U8 (S); Pos := Pos + 1;
               end if;

               if (Mask and 16#10#) /= 0 then  --  effect param
                  Cell.Param := Read_U8 (S); Pos := Pos + 1;
               end if;

            else
               --  Uncompressed: Byte is the note
               if Byte in 1 .. 97 then
                  Cell.Note := Note_Value (Byte);
               end if;
               Byte := Read_U8 (S); Pos := Pos + 1;
               Cell.Instrument :=
                 Instrument_Index'Min (Instrument_Index'Last,
                                       Instrument_Index (Byte));
               Byte := Read_U8 (S); Pos := Pos + 1;
               Cell.Volume := Natural (Byte);
               Cell.Effect := Read_U8 (S); Pos := Pos + 1;
               Cell.Param  := Read_U8 (S); Pos := Pos + 1;
            end if;

            Pat.Cells (R * Channels + C) := Cell;
         end loop;
      end loop;

      --  Skip any remaining bytes in the packed data block
      if Pos < Data_Sz then
         Skip (S, Data_Sz - Pos);
      end if;
   end Read_Pattern;

   --  ---------------------------------------------------------------
   --  Envelope reader (12 points * 4 bytes each = 48 bytes)
   --  ---------------------------------------------------------------

   function Read_Envelope_Points (S : Stream_Access) return Envelope_Points is
      Pts : Envelope_Points;
   begin
      for I in Pts'Range loop
         Pts (I).X := Read_U16_LE (S);
         Pts (I).Y := Read_U16_LE (S);
      end loop;
      return Pts;
   end Read_Envelope_Points;

   --  ---------------------------------------------------------------
   --  Instrument + sample reader
   --  ---------------------------------------------------------------

   procedure Read_Instrument
     (S     : Stream_Access;
      Instr : out XM_Instrument)
   is
      Instr_Hdr_Size : constant Unsigned_32 := Read_U32_LE (S);
      Instr_Name_Buf : String (1 .. 22);
      Instr_Type     : Unsigned_8;
      Num_Samples    : Natural;
   begin
      pragma Warnings (Off, "aggregate not fully initialized");
      Instr := [others => <>];
      pragma Warnings (On, "aggregate not fully initialized");

      Read_String (S, Instr_Name_Buf);
      Instr.Name    := Instr_Name_Buf;
      Instr_Type    := Read_U8 (S);
      pragma Unreferenced (Instr_Type);
      Num_Samples   := Natural (Read_U16_LE (S));
      Instr.Num_Samples := Num_Samples;

      if Num_Samples = 0 then
         --  Skip to end of instrument header
         declare
            Consumed : constant Natural := 4 + 22 + 1 + 2;  --  bytes read so far
            Remain   : constant Natural :=
                         Natural (Instr_Hdr_Size) - Consumed;
         begin
            if Remain > 0 then Skip (S, Remain); end if;
         end;
         return;
      end if;

      --  Sample header size (within each sample header)
      declare
         Sample_Hdr_Sz : constant Unsigned_32 := Read_U32_LE (S);

         --  Note-to-sample map (96 bytes)
         Map_Raw : Keymap;
      begin
         for I in Map_Raw'Range loop
            Map_Raw (I) := Read_U8 (S);
         end loop;
         Instr.Note_Map := Map_Raw;

         --  Volume envelope (12 * 4 bytes)
         Instr.Vol_Env.Points := Read_Envelope_Points (S);
         --  Panning envelope
         Instr.Pan_Env.Points := Read_Envelope_Points (S);

         Instr.Vol_Env.Num_Points  := Natural (Read_U8 (S));
         Instr.Pan_Env.Num_Points  := Natural (Read_U8 (S));
         Instr.Vol_Env.Sustain_Pt  := Natural (Read_U8 (S));
         Instr.Vol_Env.Loop_Start  := Natural (Read_U8 (S));
         Instr.Vol_Env.Loop_End    := Natural (Read_U8 (S));
         Instr.Pan_Env.Sustain_Pt  := Natural (Read_U8 (S));
         Instr.Pan_Env.Loop_Start  := Natural (Read_U8 (S));
         Instr.Pan_Env.Loop_End    := Natural (Read_U8 (S));

         declare
            Vol_Flags : constant Unsigned_8 := Read_U8 (S);
            Pan_Flags : constant Unsigned_8 := Read_U8 (S);
         begin
            Instr.Vol_Env.Enabled     := (Vol_Flags and 1) /= 0;
            Instr.Vol_Env.Has_Sustain := (Vol_Flags and 2) /= 0;
            Instr.Vol_Env.Has_Loop    := (Vol_Flags and 4) /= 0;
            Instr.Pan_Env.Enabled     := (Pan_Flags and 1) /= 0;
            Instr.Pan_Env.Has_Sustain := (Pan_Flags and 2) /= 0;
            Instr.Pan_Env.Has_Loop    := (Pan_Flags and 4) /= 0;
         end;

         Instr.Vibrato_Type  := Read_U8 (S);
         Instr.Vibrato_Sweep := Read_U8 (S);
         Instr.Vibrato_Depth := Read_U8 (S);
         Instr.Vibrato_Rate  := Read_U8 (S);
         Instr.Fadeout       := Natural (Read_U16_LE (S));
         Skip (S, 2);  --  reserved

         --  Skip remaining instrument header bytes if header is larger
         --  Bytes we consumed from the instrument header
         --    4   Instrument header size  (uint32)
         --   22   Instrument name         (char * 22)
         --    1   Instrument type         (uint8,  always 0)
         --    2   Num samples             (uint16)
         --    4   Sample header size      (uint32)
         --   96   Note-to-sample map      (uint8 * 96)
         --   48   Volume envelope         (12 points * 4 bytes)
         --   48   Panning envelope        (12 points * 4 bytes)
         --   10   Envelope control bytes  (counts, sustain, loop * uint8)
         --    4   Auto-vibrato            (type, sweep, depth, rate * uint8)
         --    2   Fadeout                 (uint16)
         --    2   Reserved                (uint16)
         --  ---
         --  243   total
         declare
            Consumed : constant Natural :=
              4 + 22 + 1 + 2 + 4 + 96 + 48 + 48 + 10 + 4 + 2 + 2;
            Remain   : constant Natural :=
              (if Natural (Instr_Hdr_Size) > Consumed
               then Natural (Instr_Hdr_Size) - Consumed
               else 0);
         begin
            if Remain > 0 then Skip (S, Remain); end if;
         end;

         --  Read sample headers
         declare
            type Raw_Sample_Headers is
              array (0 .. Max_Samples_Per_Instrument - 1) of XM_Sample_Header;
            Raw_Hdrs : Raw_Sample_Headers;
            N        : constant Natural :=
                         Natural'Min (Num_Samples,
                                      Max_Samples_Per_Instrument);
         begin
            for I in 0 .. N - 1 loop
               declare
                  H : XM_Sample_Header;
               begin
                  H.Length        := Read_U32_LE (S);
                  H.Loop_Start    := Read_U32_LE (S);
                  H.Loop_Length   := Read_U32_LE (S);
                  H.Volume        := Read_U8 (S);
                  H.Finetune      := Read_I8 (S);
                  H.Sample_Type   := Read_U8 (S);
                  H.Panning       := Read_U8 (S);
                  H.Relative_Note := Read_I8 (S);
                  H.Reserved      := Read_U8 (S);
                  Read_String (S, H.Name);

                  --  Skip extra sample header bytes if larger than 40
                  if Natural (Sample_Hdr_Sz) > 40 then
                     Skip (S, Natural (Sample_Hdr_Sz) - 40);
                  end if;
                  Raw_Hdrs (I) := H;
               end;
            end loop;

            --  Skip sample headers beyond our limit
            for I in N .. Num_Samples - 1 loop
               Skip (S, Natural (Sample_Hdr_Sz));
            end loop;

            --  Read sample data
            for I in 0 .. N - 1 loop
               declare
                  H         : XM_Sample_Header renames Raw_Hdrs (I);
                  Is_16bit  : constant Boolean :=
                                (H.Sample_Type and Sample_Flag_16bit) /= 0;
                  Byte_Len  : constant Natural := Natural (H.Length);
                  Loop_Flg  : constant Unsigned_8 :=
                                H.Sample_Type and 16#03#;
               begin
                  --  Fill in Song-level Sample_Header fields
                  declare
                     SH : Sample_Header;
                  begin
                     SH.Name    := H.Name;
                     SH.Depth   := (if Is_16bit then Depth_16 else Depth_8);
                     SH.Volume  := Volume_Value'Min (64, Volume_Value (H.Volume));
                     SH.Finetune := Integer (H.Finetune);
                     SH.Panning := Natural (H.Panning);
                     SH.Relative_Note := Integer (H.Relative_Note);
                     SH.Loop_Start :=
                       (if Is_16bit then Natural (H.Loop_Start) / 2
                        else Natural (H.Loop_Start));
                     SH.Loop_End   :=
                       (if Is_16bit
                        then (Natural (H.Loop_Start) + Natural (H.Loop_Length)) / 2
                        else Natural (H.Loop_Start) + Natural (H.Loop_Length));
                     case Loop_Flg is
                        when 0      => SH.Loop_Kind := No_Loop;
                        when 1      => SH.Loop_Kind := Forward_Loop;
                        when 2      => SH.Loop_Kind := Ping_Pong_Loop;
                        when others => SH.Loop_Kind := No_Loop;
                     end case;

                     if Is_16bit then
                        Instr.Samples (I) :=
                          (Depth  => Depth_16,
                           Header => SH,
                           Data_16 => null);
                        if Byte_Len >= 2 then
                           declare
                              Smp_Len : constant Natural := Byte_Len / 2;
                           begin
                              Instr.Samples (I).Data_16 :=
                                new Sample_Data_16 (0 .. Smp_Len - 1);
                              for J in 0 .. Smp_Len - 1 loop
                                 declare
                                    Lo : constant Unsigned_8 := Read_U8 (S);
                                    Hi : constant Unsigned_8 := Read_U8 (S);
                                    V  : constant Unsigned_16 :=
                                           Shift_Left (Unsigned_16 (Hi), 8)
                                           or Unsigned_16 (Lo);
                                 begin
                                    Instr.Samples (I).Data_16 (J) :=
                                      U16_To_I16 (V);
                                 end;
                              end loop;
                              Delta_Decode_16 (Instr.Samples (I).Data_16.all);
                           end;
                        end if;
                     else
                        Instr.Samples (I) :=
                          (Depth   => Depth_8,
                           Header  => SH,
                           Data_8  => null);
                        if Byte_Len > 0 then
                           Instr.Samples (I).Data_8 :=
                             new Sample_Data_8 (0 .. Byte_Len - 1);
                           for J in 0 .. Byte_Len - 1 loop
                              Instr.Samples (I).Data_8 (J) :=
                                U8_To_I8 (Read_U8 (S));
                           end loop;
                           Delta_Decode_8 (Instr.Samples (I).Data_8.all);
                        end if;
                     end if;
                  end;
               end;
            end loop;
         end;
      end;
   end Read_Instrument;

   --  ---------------------------------------------------------------
   --  Load
   --  ---------------------------------------------------------------

   procedure Load
     (Path   : in  String;
      Song   : out XM_Song;
      Status : out Load_Error)
   is
      File : Ada.Streams.Stream_IO.File_Type;
      S    : Stream_Access;
      ID   : String (1 .. 17);
   begin
      Status := None;
      pragma Warnings (Off, "aggregate not fully initialized");
      Song   := [others => <>];
      pragma Warnings (On, "aggregate not fully initialized");

      begin
         Open (File, In_File, Path);
      exception
         when Ada.Streams.Stream_IO.Name_Error =>
            Status := File_Not_Found;
            return;
         when others =>
            Status := IO_Error;
            return;
      end;

      S := Stream (File);

      begin
         --  Verify ID string
         Read_String (S, ID);
         if ID /= ID_String then
            Status := Invalid_Header;
            Close (File);
            return;
         end if;

         Read_String (S, Song.Name);
         Skip (S, 1);  --  0x1A
         Read_String (S, Song.Tracker_Name);

         declare
            Ver : constant Unsigned_16 := Read_U16_LE (S);
         begin
            if Ver /= XM_Version then
               Status := Unsupported_Version;
               Close (File);
               return;
            end if;
         end;

         declare
            Hdr_Size    : constant Unsigned_32 := Read_U32_LE (S);
            Song_Len    : constant Positive    :=
                            Positive (Unsigned_16'Max (1, Read_U16_LE (S)));
            Restart     : constant Natural     := Natural (Read_U16_LE (S));
            Num_Ch      : constant Positive    :=
                            Positive (Unsigned_16'Max (2, Read_U16_LE (S)));
            Num_Pat     : constant Natural     := Natural (Read_U16_LE (S));
            Num_Instr   : constant Natural     := Natural (Read_U16_LE (S));
            Flags       : constant Unsigned_16 := Read_U16_LE (S);
            Def_Tempo   : constant Unsigned_16 := Read_U16_LE (S);
            Def_BPM     : constant Unsigned_16 := Read_U16_LE (S);
         begin
            Song.Song_Length   := Song_Len;
            Song.Restart_Pos   := Restart;
            Song.Num_Channels  := Natural'Min (Num_Ch, Max_Channels);
            Song.Freq_Table    :=
              (if (Flags and Flag_Linear_Freq) /= 0
               then Linear_Table else Amiga_Table);
            Song.Speed         :=
              Tick_Value'Max (1,
                Tick_Value'Min (Tick_Value'Last,
                  Tick_Value (Def_Tempo)));
            Song.BPM           :=
              BPM_Value'Max (BPM_Value'First,
                BPM_Value'Min (BPM_Value'Last,
                  BPM_Value (Def_BPM)));

            --  Order table (256 bytes, but only Song_Len are used)
            for I in 0 .. Max_Orders - 1 loop
               Song.Orders (I) := Read_U8 (S);
            end loop;

            --  Skip extra header bytes beyond what we read above.
            --  Each addend is one field in the XM song header 
            --  kept separate so the total can be verified field-by-field:
            --    4   Header size field (uint32)
            --    2   Song length        (uint16)
            --    2   Restart position   (uint16)
            --    2   Num channels       (uint16)
            --    2   Num patterns       (uint16)
            --    2   Num instruments    (uint16)
            --    2   Flags/freq table   (uint16)
            --    2   Default tempo      (uint16)
            --    2   Default BPM        (uint16)
            --  256   Order table        (256 * uint8)
            --  ---
            --  276   total
            declare
               Consumed : constant Natural := 4 + 2 + 2 + 2 + 2 + 2 + 2 + 2 + 2 + 256;
               Remain   : constant Natural :=
                 (if Natural (Hdr_Size) > Consumed
                  then Natural (Hdr_Size) - Consumed else 0);
            begin
               if Remain > 0 then Skip (S, Remain); end if;
            end;

            --  Patterns
            Ada.Text_IO.Put_Line ("DBG: reading" & Num_Pat'Image & " patterns");
            for P in 0 .. Pattern_Index (Natural'Min (Num_Pat, 256) - 1) loop
               Read_Pattern (S, Song.Patterns (P), Song.Num_Channels);
            end loop;
            Ada.Text_IO.Put_Line ("DBG: patterns done, reading" & Num_Instr'Image & " instruments");

            --  Instruments
            for I in 1 .. Natural'Min (Num_Instr, Max_Instruments) loop
               Ada.Text_IO.Put_Line ("DBG: instrument" & I'Image);
               Read_Instrument (S, Song.Instruments (I));
            end loop;
            Ada.Text_IO.Put_Line ("DBG: all done");
         end;

      exception
         when Ada.Streams.Stream_IO.End_Error =>
            null;  --  truncated files - accept what we got
         when E : others =>
            Ada.Text_IO.Put_Line
              ("XM_Load exception: " & Ada.Exceptions.Exception_Name (E)
               & " - " & Ada.Exceptions.Exception_Message (E));
            Status := IO_Error;
      end;

      Close (File);
   end Load;

   --  ---------------------------------------------------------------
   --  Free
   --  ---------------------------------------------------------------

   procedure Free (Song : in out XM_Song) is
      procedure Free_8 is new Ada.Unchecked_Deallocation
        (Sample_Data_8, XM_Sample_Data_8);
      procedure Free_16 is new Ada.Unchecked_Deallocation
        (Sample_Data_16, XM_Sample_Data_16);
      procedure Free_Row is new Ada.Unchecked_Deallocation
        (XM_Row, XM_Row_Access);
   begin
      for I in 1 .. Max_Instruments loop
         for J in 0 .. Max_Samples_Per_Instrument - 1 loop
            case Song.Instruments (I).Samples (J).Depth is
               when Depth_8 =>
                  if Song.Instruments (I).Samples (J).Data_8 /= null then
                     Free_8 (Song.Instruments (I).Samples (J).Data_8);
                  end if;
               when Depth_16 =>
                  if Song.Instruments (I).Samples (J).Data_16 /= null then
                     Free_16 (Song.Instruments (I).Samples (J).Data_16);
                  end if;
            end case;
         end loop;
      end loop;
      for P in Pattern_Index loop
         if Song.Patterns (P).Cells /= null then
            Free_Row (Song.Patterns (P).Cells);
         end if;
      end loop;
   end Free;

end XM_Format;
