-- ***************************************************************************
--                      Tracker - IT Format
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
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;

package body IT_Format is

   use Ada.Streams.Stream_IO;

   function U8_To_I8   is new Ada.Unchecked_Conversion (Unsigned_8,  Integer_8);
   function U16_To_I16 is new Ada.Unchecked_Conversion (Unsigned_16, Integer_16);

   subtype Stream_Access is Ada.Streams.Stream_IO.Stream_Access;

   type Byte_Array is array (Natural range <>) of Unsigned_8;

   --  ---------------------------------------------------------------
   --  Low-level I/O helpers (little-endian)
   --  ---------------------------------------------------------------

   function Read_U8 (S : Stream_Access) return Unsigned_8 is
      V : Unsigned_8;
   begin
      Unsigned_8'Read (S, V);
      return V;
   end Read_U8;

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
        or   Shift_Left (Unsigned_32 (B2), 16)
        or   Shift_Left (Unsigned_32 (B1),  8)
        or              Unsigned_32 (B0);
   end Read_U32_LE;

   procedure Read_Str (S : Stream_Access; Str : out String) is
   begin
      for I in Str'Range loop
         Str (I) := Character'Val (Read_U8 (S));
      end loop;
   end Read_Str;

   procedure Skip (S : Stream_Access; N : Natural) is
      Dummy : Unsigned_8;
   begin
      for I in 1 .. N loop
         Unsigned_8'Read (S, Dummy);
      end loop;
   end Skip;

   procedure Seek_To (File : File_Type; Offset : Natural) is
   begin
      Set_Index (File, Count (Offset) + 1);
   end Seek_To;

   --  ---------------------------------------------------------------
   --  Map IT effect (1-based, A=1..Z=26) to engine effect code
   --  ---------------------------------------------------------------

   procedure Map_IT_Effect
     (IT_Cmd  : Unsigned_8;
      IT_Param : Unsigned_8;
      Effect  : out Effect_Code;
      Param   : out Effect_Param)
   is
      Hi : constant Natural := Natural (Shift_Right (IT_Param, 4));
      Lo : constant Natural := Natural (IT_Param and 16#0F#);
   begin
      Effect := Effect_None;
      Param  := IT_Param;

      case IT_Cmd is
         when 1  => Effect := Effect_Set_Speed;      --  A: set speed
         when 2  => Effect := Effect_Jump_To_Order;  --  B: jump to order
         when 3  => Effect := Effect_Pattern_Break;  --  C: break to row
         when 4  => Effect := Effect_Vol_Slide;      --  D: volume slide
         when 5  => Effect := Effect_Porta_Down;     --  E: portamento down
         when 6  => Effect := Effect_Porta_Up;       --  F: portamento up
         when 7  => Effect := Effect_Tone_Porta;     --  G: tone portamento
         when 8  => Effect := Effect_Vibrato;        --  H: vibrato
         when 10 => Effect := Effect_Arpeggio;       --  J: arpeggio
         when 11 => Effect := 16#06#;                --  K: vibrato + vol slide
         when 12 => Effect := 16#05#;                --  L: tone porta + vol slide
         when 13 =>                                  --  M: set channel volume
            Effect := Effect_Set_Volume;
            Param  := Effect_Param (Natural'Min (64, Natural (IT_Param)));
         when 15 => Effect := 16#09#;                --  O: sample offset
         when 18 => Effect := 16#07#;                --  R: tremolo
         when 19 =>                                  --  S: special sub-effects
            Effect := Effect_Extended;
            declare
               L : constant Unsigned_8 := Unsigned_8 (Lo);
            begin
               case Hi is
                  when 16#1# => Param := 16#30# or L;  --  S1x: glissando
                  when 16#2# => Param := 16#50# or L;  --  S2x: finetune
                  when 16#3# => Param := 16#40# or L;  --  S3x: vibrato waveform
                  when 16#4# => Param := 16#70# or L;  --  S4x: tremolo waveform
                  when 16#8# => Param := 16#80# or L;  --  S8x: set panning nibble
                  when 16#B# => Param := 16#60# or L;  --  SBx: pattern loop
                  when 16#C# => Param := 16#C0# or L;  --  SCx: note cut
                  when 16#D# => Param := 16#D0# or L;  --  SDx: note delay
                  when 16#E# => Param := 16#E0# or L;  --  SEx: pattern delay
                  when others =>
                     Effect := Effect_None; Param := 0;
               end case;
            end;
         when 20 => Effect := 16#14#;                --  T: set tempo (BPM)
         when 21 => Effect := Effect_Vibrato;        --  U: fine vibrato
         when 24 => Effect := 16#08#;                --  X: set panning
         when others =>
            Effect := Effect_None;
            Param  := 0;
      end case;
   end Map_IT_Effect;

   --  ---------------------------------------------------------------
   --  Convert IT volume column byte to engine volume column value
   --  ---------------------------------------------------------------

   function IT_Vol_To_Engine (V : Unsigned_8) return Natural is
   begin
      if V = 255 then           return 0;                               --  empty
      elsif V <= 64 then        return 16#10# + Natural (V);           --  set vol 0..64
      elsif V <= 74 then        return 16#90# + Natural (V - 65);      --  fine vol up
      elsif V <= 84 then        return 16#80# + Natural (V - 75);      --  fine vol down
      elsif V <= 94 then        return 16#90# + Natural (V - 85);      --  vol slide up
      elsif V <= 104 then       return 16#80# + Natural (V - 95);      --  vol slide down
      elsif V in 128 .. 192 then
         return 16#C0# + Natural (V - 128) * 15 / 64;  --  set panning 0..64->0..15
      elsif V in 193 .. 202 then           return 16#F0# + Natural (V - 193); --  portamento
      elsif V in 203 .. 212 then           return 16#B0# + Natural (V - 203); --  vibrato depth
      else                                 return 0;
      end if;
   end IT_Vol_To_Engine;

   --  ---------------------------------------------------------------
   --  Convert IT note byte to engine Note_Value
   --  IT notes: 0..119 = C-0..B-9, 254 = note cut, 255 = note off
   --  Engine notes: 1..96 = C-0..B-7, 97 = key-off
   --  ---------------------------------------------------------------

   function IT_Note_To_Engine (N : Unsigned_8) return Note_Value is
   begin
      if N >= 254 then
         return Note_Key_Off;
      elsif N >= 96 then
         return Note_Value (96);   --  clamp to B-7
      else
         return Note_Value (Natural (N) + 1);  --  0 -> 1 (C-0)
      end if;
   end IT_Note_To_Engine;

   --  ---------------------------------------------------------------
   --  IT sample compression - 8-bit (standard or IT 2.15 predictor)
   --
   --  Schismtracker / OpenMPT algorithm:
   --    Initial: width=9, d1=0, d2=0
   --    For each block of <=0x8000 samples:
   --      Read uint16 compressed block size, fill byte buffer.
   --      width<7  : sign-extend V, d1 += V
   --      width=7  : V<64  -> change width=V+1;  V>=64 -> d1 += V-96
   --      width=8  : V>=128 -> change width=V-127; else d1 += V-64
   --      width=9  : V>=256 -> change width=V-255; else d1 = (int8)V
   --      IT215: d2 += d1; output d2; else output d1
   --  ---------------------------------------------------------------

   function Decomp_8
     (S     : Stream_Access;
      Len   : Natural;
      It215 : Boolean) return IT_Sample_8
   is
      Result  : constant IT_Sample_8 := new Sample_Data_8 (0 .. Len - 1);
      Dst_Pos : Natural := 0;
   begin
      while Dst_Pos < Len loop
         declare
            Block_Size : constant Natural :=
              Natural (Read_U16_LE (S));
            Block_Len  : constant Natural :=
              Natural'Min (16#8000#, Len - Dst_Pos);
         begin
            if Block_Size > 0 then
               declare
                  Buf       : Byte_Array (0 .. Block_Size - 1);
                  Buf_Pos   : Natural     := 0;
                  Bit_Buf   : Unsigned_32 := 0;
                  Bits_Left : Natural     := 0;

                  function Get_Byte return Unsigned_8 is
                     B : Unsigned_8;
                  begin
                     if Buf_Pos < Buf'Length then
                        B := Buf (Buf_Pos);
                        Buf_Pos := Buf_Pos + 1;
                     else
                        B := 0;
                     end if;
                     return B;
                  end Get_Byte;

                  function Read_Bits (N : Natural) return Unsigned_32 is
                     R : Unsigned_32;
                  begin
                     while Bits_Left < N loop
                        Bit_Buf   := Bit_Buf
                          or Shift_Left (Unsigned_32 (Get_Byte), Bits_Left);
                        Bits_Left := Bits_Left + 8;
                     end loop;
                     R         := Bit_Buf and (Shift_Left (Unsigned_32'(1), N) - 1);
                     Bit_Buf   := Shift_Right (Bit_Buf, N);
                     Bits_Left := Bits_Left - N;
                     return R;
                  end Read_Bits;

                  Width  : Natural  := 9;
                  D1, D2 : Integer  := 0;

               begin
                  --  Fill the block buffer from stream
                  for I in Buf'Range loop
                     Buf (I) := Read_U8 (S);
                  end loop;

                  --  Decompress Block_Len samples
                  for J in 0 .. Block_Len - 1 loop
                     declare
                        V    : constant Unsigned_32 := Read_Bits (Width);
                        VS   : Integer              := 0;
                        W_Ch : Boolean              := False;
                     begin
                        if Width < 7 then
                           if V >= Shift_Left (Unsigned_32'(1), Width - 1) then
                              VS := Integer (V)
                                - Integer (Shift_Left (Unsigned_32'(1), Width));
                           else
                              VS := Integer (V);
                           end if;
                           D1 := Integer (U8_To_I8 (Unsigned_8 ((D1 + VS) mod 256)));

                        elsif Width = 7 then
                           if V < 64 then
                              Width := Natural (V) + 1;
                              W_Ch  := True;
                           else
                              VS := Integer (V) - 96;   --  centred at 96, range -32..+31
                              D1 := Integer (U8_To_I8 (Unsigned_8 ((D1 + VS) mod 256)));
                           end if;

                        elsif Width = 8 then
                           if V >= 16#80# then
                              Width := Natural'Max (1,
                                         Natural'Min (9, Natural (V) - 16#7F#));
                              W_Ch  := True;
                           else
                              VS := Integer (V) - 64;   --  range -64..+63
                              D1 := Integer (U8_To_I8 (Unsigned_8 ((D1 + VS) mod 256)));
                           end if;

                        else  --  Width = 9
                           if V >= 16#100# then
                              Width := Natural'Max (1,
                                         Natural'Min (9, Natural (V) - 16#FF#));
                              W_Ch  := True;
                           else
                              --  Absolute 8-bit value
                              D1 := (if V >= 16#80#
                                     then Integer (V) - 16#100#
                                     else Integer (V));
                           end if;
                        end if;

                        if not W_Ch then
                           if It215 then
                              D2 := Integer (U8_To_I8 (
                                      Unsigned_8 ((D2 + D1) mod 256)));
                           end if;
                           Result (Dst_Pos) :=
                             U8_To_I8 (Unsigned_8 (
                               (if It215 then D2 else D1) mod 256));
                           Dst_Pos := Dst_Pos + 1;
                        end if;
                     end;
                  end loop;
               end;

            else  --  Block_Size = 0 - emit silence for this block
               for J in 0 .. Block_Len - 1 loop
                  Result (Dst_Pos) := 0;
                  Dst_Pos := Dst_Pos + 1;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Decomp_8;

   --  ---------------------------------------------------------------
   --  IT sample compression - 16-bit
   --  Same algorithm, 16-bit predictor, initial width = 17.
   --    width<15  : sign-extend V, d1 += V  (int16 wrap)
   --    width=15  : V<0x4000 -> change width=V+1; else d1 += V-0x6000
   --    width=16  : V>=0x8000 -> change width=V-0x7FFF; else d1 += V-0x4000
   --    width=17  : V>=0x10000 -> change width=V-0xFFFF; else d1 = (int16)V
   --  ---------------------------------------------------------------

   function Decomp_16
     (S     : Stream_Access;
      Len   : Natural;
      It215 : Boolean) return IT_Sample_16
   is
      Result  : constant IT_Sample_16 := new Sample_Data_16 (0 .. Len - 1);
      Dst_Pos : Natural := 0;
   begin
      while Dst_Pos < Len loop
         declare
            Block_Size : constant Natural :=
              Natural (Read_U16_LE (S));
            Block_Len  : constant Natural :=
              Natural'Min (16#8000#, Len - Dst_Pos);
         begin
            if Block_Size > 0 then
               declare
                  Buf       : Byte_Array (0 .. Block_Size - 1);
                  Buf_Pos   : Natural     := 0;
                  Bit_Buf   : Unsigned_32 := 0;
                  Bits_Left : Natural     := 0;

                  function Get_Byte return Unsigned_8 is
                     B : Unsigned_8;
                  begin
                     if Buf_Pos < Buf'Length then
                        B := Buf (Buf_Pos);
                        Buf_Pos := Buf_Pos + 1;
                     else
                        B := 0;
                     end if;
                     return B;
                  end Get_Byte;

                  function Read_Bits (N : Natural) return Unsigned_32 is
                     R : Unsigned_32;
                  begin
                     while Bits_Left < N loop
                        Bit_Buf   := Bit_Buf
                          or Shift_Left (Unsigned_32 (Get_Byte), Bits_Left);
                        Bits_Left := Bits_Left + 8;
                     end loop;
                     R         := Bit_Buf and (Shift_Left (Unsigned_32'(1), N) - 1);
                     Bit_Buf   := Shift_Right (Bit_Buf, N);
                     Bits_Left := Bits_Left - N;
                     return R;
                  end Read_Bits;

                  Width  : Natural  := 17;
                  D1, D2 : Integer  := 0;

               begin
                  for I in Buf'Range loop
                     Buf (I) := Read_U8 (S);
                  end loop;

                  for J in 0 .. Block_Len - 1 loop
                     declare
                        V    : constant Unsigned_32 := Read_Bits (Width);
                        VS   : Integer              := 0;
                        W_Ch : Boolean              := False;
                     begin
                        if Width < 15 then
                           if V >= Shift_Left (Unsigned_32'(1), Width - 1) then
                              VS := Integer (V)
                                - Integer (Shift_Left (Unsigned_32'(1), Width));
                           else
                              VS := Integer (V);
                           end if;
                           D1 := Integer (U16_To_I16 (
                                   Unsigned_16 ((D1 + VS) mod 65536)));

                        elsif Width = 15 then
                           if V < 16#4000# then
                              Width := Natural (V) + 1;
                              W_Ch  := True;
                           else
                              VS := Integer (V) - 16#6000#;
                              D1 := Integer (U16_To_I16 (
                                      Unsigned_16 ((D1 + VS) mod 65536)));
                           end if;

                        elsif Width = 16 then
                           if V >= 16#8000# then
                              Width := Natural'Max (1,
                                         Natural'Min (17, Natural (V) - 16#7FFF#));
                              W_Ch  := True;
                           else
                              VS := Integer (V) - 16#4000#;
                              D1 := Integer (U16_To_I16 (
                                      Unsigned_16 ((D1 + VS) mod 65536)));
                           end if;

                        else  --  Width = 17
                           if V >= 16#10000# then
                              Width := Natural'Max (1,
                                         Natural'Min (17, Natural (V) - 16#FFFF#));
                              W_Ch  := True;
                           else
                              D1 := (if V >= 16#8000#
                                     then Integer (V) - 16#10000#
                                     else Integer (V));
                           end if;
                        end if;

                        if not W_Ch then
                           if It215 then
                              D2 := Integer (U16_To_I16 (
                                      Unsigned_16 ((D2 + D1) mod 65536)));
                           end if;
                           Result (Dst_Pos) :=
                             U16_To_I16 (Unsigned_16 (
                               (if It215 then D2 else D1) mod 65536));
                           Dst_Pos := Dst_Pos + 1;
                        end if;
                     end;
                  end loop;
               end;

            else
               for J in 0 .. Block_Len - 1 loop
                  Result (Dst_Pos) := 0;
                  Dst_Pos := Dst_Pos + 1;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Decomp_16;

   --  ---------------------------------------------------------------
   --  Read one 82-byte envelope block (6 header + 25*3 nodes + 1 pad)
   --  ---------------------------------------------------------------

   procedure Read_Envelope
     (S   : Stream_Access;
      Env : out IT_Envelope)
   is
      Flags : constant Unsigned_8 := Read_U8 (S);
      NP    : constant Natural    := Natural (Read_U8 (S));
      LB    : constant Natural    := Natural (Read_U8 (S));
      LE    : constant Natural    := Natural (Read_U8 (S));
      SLB   : constant Natural    := Natural (Read_U8 (S));
      SLE   : constant Natural    := Natural (Read_U8 (S));
   begin
      Env.Enabled     := (Flags and 16#01#) /= 0;
      Env.Has_Loop    := (Flags and 16#02#) /= 0;
      Env.Has_Sustain := (Flags and 16#04#) /= 0;
      Env.Is_Filter   := (Flags and 16#80#) /= 0;
      Env.Num_Points  := Natural'Min (NP, Max_Env_Points);
      Env.Loop_Start  := LB;
      Env.Loop_End    := LE;
      Env.Sus_Start   := SLB;
      Env.Sus_End     := SLE;

      --  25 nodes * 3 bytes each: uint16 tick (LE) + uint8 value
      for I in 0 .. Max_Env_Points - 1 loop
         declare
            Tick : constant Natural := Natural (Read_U16_LE (S));
            Val  : constant Natural := Natural (Read_U8 (S));
         begin
            Env.Points (I).Tick  := Tick;
            Env.Points (I).Value := Natural'Min (64, Val);
         end;
      end loop;

      Skip (S, 1);   --  alignment byte
   end Read_Envelope;

   --  ---------------------------------------------------------------
   --  Load
   --  ---------------------------------------------------------------

   procedure Load
     (Path   : in  String;
      Song   : out IT_Song;
      Status : out Load_Error)
   is
      File : File_Type;
      S    : Stream_Access;

      Ord_Num : Natural;
      Ins_Num : Natural;
      Smp_Num : Natural;
      Pat_Num : Natural;
      Flags   : Unsigned_16;

      Ins_Offsets : array (1 .. Max_Instruments) of Unsigned_32 := [others => 0];
      Smp_Offsets : array (1 .. Max_Samples)     of Unsigned_32 := [others => 0];
      Pat_Offsets : array (0 .. Max_Patterns - 1) of Unsigned_32 := [others => 0];

      Max_Ch : Integer := 0;

   begin
      Song   := [others => <>];
      Status := None;

      begin
         Open (File, In_File, Path);
      exception
         when Ada.Streams.Stream_IO.Name_Error =>
            Status := File_Not_Found; return;
         when others =>
            Status := IO_Error; return;
      end;

      S := Stream (File);

      begin
         --  -------------------------------------------------------
         --  Header (128 bytes)
         --  -------------------------------------------------------

         --  Verify "IMPM" magic
         declare
            Tag : String (1 .. 4);
         begin
            Read_Str (S, Tag);
            if Tag /= "IMPM" then
               Close (File); Status := Invalid_Header; return;
            end if;
         end;

         Read_Str (S, Song.Name);        --  [4..29] song name (26 bytes)
         Skip (S, 2);                    --  [30..31] pattern highlight

         Ord_Num := Natural (Read_U16_LE (S));   --  32..33
         Ins_Num := Natural (Read_U16_LE (S));   --  34..35
         Smp_Num := Natural (Read_U16_LE (S));   --  36..37
         Pat_Num := Natural (Read_U16_LE (S));   --  38..39

         Ord_Num := Natural'Min (Ord_Num, Max_Orders);
         Ins_Num := Natural'Min (Ins_Num, Max_Instruments);
         Smp_Num := Natural'Min (Smp_Num, Max_Samples);
         Pat_Num := Natural'Min (Pat_Num, Max_Patterns);

         Song.Num_Instruments := Ins_Num;
         Song.Num_Samples     := Smp_Num;
         Song.Num_Patterns    := Pat_Num;

         Skip (S, 2);   --  40..41: Cwt
         Song.Cmwt := Natural (Read_U16_LE (S));  --  42..43

         Flags := Read_U16_LE (S);  --  44..45 Flags
         Song.Mode := (if (Flags and 16#04#) /= 0
                       then Instrument_Mode else Sample_Mode);

         Skip (S, 2);   --  46..47: Special
         Skip (S, 1);   --  48: global volume (we read it but just store 128)
         Skip (S, 1);   --  49: mix volume

         declare
            Spd : constant Natural := Natural (Read_U8 (S));  --  50
         begin
            Song.Speed := Tick_Value (Natural'Max (1, Natural'Min (31, Spd)));
         end;

         declare
            Bpm : constant Natural := Natural (Read_U8 (S));  --  51
         begin
            Song.BPM := BPM_Value (Natural'Max (32, Natural'Min (255, Bpm)));
         end;

         Skip (S, 12);  --  52..63: misc / reserved

         --  64..127: channel panning (64 bytes, IT supports up to 64 channels)
         --  0=left 32=centre 64=right >=100=disabled
         for I in 0 .. 63 loop
            declare
               P : constant Unsigned_8 := Read_U8 (S);
            begin
               if I < Max_Channels and then Natural (P) <= 64 then
                  Song.Channel_Pan (I) :=
                    Pan_Entry'Max (-128,
                      Pan_Entry'Min (127,
                        (Integer (P) - 32) * 4));
               end if;
               --  100/200 (surround/disabled) -> leave at 0 (centre)
            end;
         end loop;

         Skip (S, 64);  --  128..191: channel volumes (64 bytes, ignored for now)

         --  -------------------------------------------------------
         --  Orders (OrdNum bytes after header)
         --  0xFF = end of song, 0xFE = skip
         --  -------------------------------------------------------
         declare
            Pos : Natural := 0;
         begin
            for I in 0 .. Ord_Num - 1 loop
               declare
                  B : constant Unsigned_8 := Read_U8 (S);
               begin
                  if B < 16#FE# and Pos < Max_Orders then
                     Song.Orders (Pos) := Natural (B);
                     Pos := Pos + 1;
                  end if;
               end;
            end loop;
            Song.Song_Length := Positive'Max (1, Pos);
         end;

         --  -------------------------------------------------------
         --  Instrument offsets (InsNum * 4 bytes)
         --  -------------------------------------------------------
         for I in 1 .. Ins_Num loop
            Ins_Offsets (I) := Read_U32_LE (S);
         end loop;

         --  -------------------------------------------------------
         --  Sample header offsets (SmpNum * 4 bytes)
         --  -------------------------------------------------------
         for I in 1 .. Smp_Num loop
            Smp_Offsets (I) := Read_U32_LE (S);
         end loop;

         --  -------------------------------------------------------
         --  Pattern offsets (PatNum * 4 bytes)
         --  -------------------------------------------------------
         for I in 0 .. Pat_Num - 1 loop
            Pat_Offsets (I) := Read_U32_LE (S);
         end loop;

         --  -------------------------------------------------------
         --  Load instrument headers (instrument mode only)
         --  IMPI header layout (550 bytes):
         --    +0   "IMPI" (4)
         --    +4   filename (12)
         --    +16  reserved (1)
         --    +17  nna, dct, dca (3)
         --    +20  fadeout uint16 (2)
         --    +22  pps, ppc, gbv, dfp (4)
         --    +26  rv, rp (2)
         --    +28  trkver (2), nos (1), reserved (1)
         --    +32  name (26)
         --    +58  ifc, ifr, mch, mpr (4)
         --    +62  mbank (2)
         --    +64  note/sample table (240)
         --    +304 volume envelope (82)
         --    +386 panning envelope (82)
         --    +468 pitch envelope (82)
         --  -------------------------------------------------------
         if Song.Mode = Instrument_Mode then
            for I in 1 .. Ins_Num loop
               if Ins_Offsets (I) /= 0 then
                  Seek_To (File, Natural (Ins_Offsets (I)));
                  declare
                     Tag : String (1 .. 4);
                  begin
                     Read_Str (S, Tag);
                     if Tag = "IMPI" then
                        declare
                           Inst : IT_Instrument renames Song.Instruments (I);
                        begin
                           Skip (S, 12);   --  DOS filename
                           Skip (S, 1);    --  reserved
                           Inst.NNA := Natural (Read_U8 (S));
                           Skip (S, 2);    --  DCT, DCA

                           declare
                              FO : constant Natural :=
                                Natural (Read_U16_LE (S));  --  fadeout
                           begin
                              Inst.Fadeout := FO * 4;  --  0..512
                           end;

                           Skip (S, 2);    --  PPS, PPC

                           declare
                              GBV : constant Natural := Natural (Read_U8 (S));
                              DFP : constant Unsigned_8 := Read_U8 (S);
                           begin
                              Inst.Global_Vol := GBV;
                              if (DFP and 16#80#) /= 0 then
                                 Inst.Has_Pan := True;
                                 Inst.Default_Pan :=
                                   Pan_Entry'Max (-128,
                                     Pan_Entry'Min (127,
                                       (Integer (DFP and 16#7F#) - 32) * 4));
                              end if;
                           end;

                           Skip (S, 2);    --  RV, RP
                           Skip (S, 2);    --  TrkVer
                           Skip (S, 2);    --  NOS, reserved

                           Read_Str (S, Inst.Name);  --  26-byte name

                           declare
                              IFC : constant Unsigned_8 := Read_U8 (S);
                              IFR : constant Unsigned_8 := Read_U8 (S);
                           begin
                              if (IFC and 16#80#) /= 0 then
                                 Inst.Flt_Cutoff := Natural (IFC and 16#7F#);
                              end if;
                              if (IFR and 16#80#) /= 0 then
                                 Inst.Flt_Resonance := Natural (IFR and 16#7F#);
                              end if;
                           end;
                           Skip (S, 4);    --  MCh, MPr, MBank

                           --  Note/sample table: 120 pairs
                           for N in 0 .. 119 loop
                              declare
                                 Note_B  : constant Unsigned_8 := Read_U8 (S);
                                 Samp_No : constant Natural    := Natural (Read_U8 (S));
                                 pragma Unreferenced (Note_B);
                              begin
                                 Inst.Note_Map (N) :=
                                   Natural'Min (Smp_Num, Samp_No);
                              end;
                           end loop;

                           --  Envelopes (volume, panning, pitch/filter)
                           Read_Envelope (S, Inst.Vol_Env);
                           Read_Envelope (S, Inst.Pan_Env);
                           Read_Envelope (S, Inst.Flt_Env);
                        end;
                     end if;
                  end;
               end if;
            end loop;
         end if;

         --  -------------------------------------------------------
         --  Load sample headers + data
         --  IMPS header (80 bytes):
         --    +0   "IMPS" (4)
         --    +4   filename (12)
         --    +16  reserved (1)
         --    +17  global_vol (1)
         --    +18  flags (1)
         --    +19  default_vol (1)
         --    +20  name (26)
         --    +46  convert (1)
         --    +47  dfp (1)
         --    +48  length (4)
         --    +52  loop_begin (4)
         --    +56  loop_end (4)
         --    +60  c5speed (4)
         --    +64  sus_begin (4)
         --    +68  sus_end (4)
         --    +72  data_offset (4)
         --    +76  vib_speed, vib_depth, vib_type, vib_rate (4)
         --  -------------------------------------------------------
         for I in 1 .. Smp_Num loop
            if Smp_Offsets (I) /= 0 then
               Seek_To (File, Natural (Smp_Offsets (I)));
               declare
                  Tag : String (1 .. 4);
               begin
                  Read_Str (S, Tag);
                  if Tag = "IMPS" then
                     declare
                        Smp    : IT_Sample renames Song.Samples (I);
                        Sflags : Unsigned_8;
                        Slen   : Natural;
                        Data_Off : Unsigned_32;
                     begin
                        Skip (S, 12);  --  filename
                        Skip (S, 1);   --  reserved
                        Skip (S, 1);   --  global_vol (use default 64)

                        Sflags := Read_U8 (S);   --  +18 flags

                        declare
                           DV : constant Natural := Natural (Read_U8 (S));
                        begin
                           Smp.Default_Vol := Natural'Min (64, DV);
                        end;

                        Read_Str (S, Smp.Name);  --  +20..+45 (26 bytes)

                        Skip (S, 1);   --  convert
                        declare
                           DFP : constant Unsigned_8 := Read_U8 (S);
                        begin
                           if (DFP and 16#80#) /= 0 then
                              Smp.Has_Pan := True;
                              Smp.Default_Pan :=
                                Pan_Entry'Max (-128,
                                  Pan_Entry'Min (127,
                                    (Integer (DFP and 16#7F#) - 32) * 4));
                           end if;
                        end;

                        Slen := Natural (Read_U32_LE (S));   --  +48 length

                        Smp.Loop_Start :=
                          Natural'Min (Slen, Natural (Read_U32_LE (S)));  --  +52
                        Smp.Loop_End   :=
                          Natural'Min (Slen, Natural (Read_U32_LE (S)));  --  +56
                        Smp.C5Speed    :=
                          Natural'Max (1, Natural (Read_U32_LE (S)));     --  +60

                        Smp.Has_Loop  := (Sflags and SFlag_Loop)      /= 0
                                         and Smp.Loop_End > Smp.Loop_Start;
                        Smp.Ping_Pong := (Sflags and SFlag_Ping_Pong) /= 0;

                        Skip (S, 8);              --  +64..+71 sustain loop
                        Data_Off := Read_U32_LE (S);  --  +72 data offset
                        Skip (S, 4);              --  +76..+79 vibrato

                        --  Load sample data (mono only - skip stereo)
                        if (Sflags and SFlag_Present) /= 0
                          and Slen > 0
                          and (Sflags and SFlag_Stereo) = 0
                          and Data_Off /= 0
                        then
                           Seek_To (File, Natural (Data_Off));

                           if (Sflags and SFlag_16Bit) /= 0 then
                              --  16-bit sample
                              declare
                                 It215 : constant Boolean :=
                                           Song.Cmwt >= 16#215#;
                              begin
                                 if (Sflags and SFlag_Compress) /= 0 then
                                    Song.Samples (I) :=
                                      (Depth    => Depth_16,
                                       Name     => Smp.Name,
                                       Default_Vol => Smp.Default_Vol,
                                       Global_Vol  => Smp.Global_Vol,
                                       Has_Loop    => Smp.Has_Loop,
                                       Ping_Pong   => Smp.Ping_Pong,
                                       Loop_Start  => Smp.Loop_Start,
                                       Loop_End    => Smp.Loop_End,
                                       C5Speed     => Smp.C5Speed,
                                       Default_Pan => Smp.Default_Pan,
                                       Has_Pan     => Smp.Has_Pan,
                                       Data_16     => Decomp_16 (S, Slen, It215));
                                 else
                                    declare
                                       D : constant IT_Sample_16 :=
                                             new Sample_Data_16 (0 .. Slen - 1);
                                    begin
                                       for J in D'Range loop
                                          D (J) := U16_To_I16 (Read_U16_LE (S));
                                       end loop;
                                       Song.Samples (I) :=
                                         (Depth    => Depth_16,
                                          Name     => Smp.Name,
                                          Default_Vol => Smp.Default_Vol,
                                          Global_Vol  => Smp.Global_Vol,
                                          Has_Loop    => Smp.Has_Loop,
                                          Ping_Pong   => Smp.Ping_Pong,
                                          Loop_Start  => Smp.Loop_Start,
                                          Loop_End    => Smp.Loop_End,
                                          C5Speed     => Smp.C5Speed,
                                          Default_Pan => Smp.Default_Pan,
                                          Has_Pan     => Smp.Has_Pan,
                                          Data_16     => D);
                                    end;
                                 end if;
                              end;

                           else
                              --  8-bit sample
                              declare
                                 It215 : constant Boolean :=
                                           Song.Cmwt >= 16#215#;
                              begin
                                 if (Sflags and SFlag_Compress) /= 0 then
                                    Song.Samples (I) :=
                                      (Depth    => Depth_8,
                                       Name     => Smp.Name,
                                       Default_Vol => Smp.Default_Vol,
                                       Global_Vol  => Smp.Global_Vol,
                                       Has_Loop    => Smp.Has_Loop,
                                       Ping_Pong   => Smp.Ping_Pong,
                                       Loop_Start  => Smp.Loop_Start,
                                       Loop_End    => Smp.Loop_End,
                                       C5Speed     => Smp.C5Speed,
                                       Default_Pan => Smp.Default_Pan,
                                       Has_Pan     => Smp.Has_Pan,
                                       Data_8      => Decomp_8 (S, Slen, It215));
                                 else
                                    declare
                                       D : constant IT_Sample_8 :=
                                             new Sample_Data_8 (0 .. Slen - 1);
                                    begin
                                       for J in D'Range loop
                                          D (J) := U8_To_I8 (Read_U8 (S));
                                       end loop;
                                       Song.Samples (I) :=
                                         (Depth    => Depth_8,
                                          Name     => Smp.Name,
                                          Default_Vol => Smp.Default_Vol,
                                          Global_Vol  => Smp.Global_Vol,
                                          Has_Loop    => Smp.Has_Loop,
                                          Ping_Pong   => Smp.Ping_Pong,
                                          Loop_Start  => Smp.Loop_Start,
                                          Loop_End    => Smp.Loop_End,
                                          C5Speed     => Smp.C5Speed,
                                          Default_Pan => Smp.Default_Pan,
                                          Has_Pan     => Smp.Has_Pan,
                                          Data_8      => D);
                                    end;
                                 end if;
                              end;
                           end if;
                        end if;
                     end;
                  end if;
               end;
            end if;
         end loop;

         --  -------------------------------------------------------
         --  Decode patterns
         --  Pattern header (8 bytes):
         --    uint16 data_len, uint16 num_rows, uint32 reserved
         --  Then packed rows: channel-variable-byte encoding.
         --    chanvar byte: 0=end of row; else (chanvar-1) & 63 = channel (0-based)
         --    bit 7 of chanvar: if set, read next byte as maskvar
         --    maskvar bits: 1=note,2=instr,4=volcol,8=effect;
         --                  16=last note,32=last instr,64=last vol,128=last cmd
         --  -------------------------------------------------------
         for P in 0 .. Pat_Num - 1 loop
            if Pat_Offsets (P) /= 0 then
               Seek_To (File, Natural (Pat_Offsets (P)));
               declare
                  Data_Len : constant Natural := Natural (Read_U16_LE (S));
                  Rows     : constant Natural :=
                    Natural'Max (1, Natural'Min (200, Natural (Read_U16_LE (S))));
                  pragma Unreferenced (Data_Len);
               begin
                  Skip (S, 4);   --  reserved

                  --  Allocate pattern cells (64 channels * Rows)
                  declare
                     Pat : IT_Pattern renames Song.Patterns (P);
                  begin
                     Pat.Num_Rows := Rows;

                     --  We'll determine Num_Channels after scanning

                     declare
                        Cells : IT_Cell_Array_Access :=
                          new IT_Cell_Array (0 .. Max_Channels * Rows - 1);

                        --  Per-channel last-value memory
                        Last_Mask   : array (0 .. 63) of Unsigned_8 := [others => 0];
                        Last_Note   : array (0 .. 63) of Unsigned_8 := [others => 255];
                        Last_Instr  : array (0 .. 63) of Unsigned_8 := [others => 0];
                        Last_Volcmd : array (0 .. 63) of Unsigned_8 := [others => 255];
                        Last_Cmd    : array (0 .. 63) of Unsigned_8 := [others => 0];
                        Last_Cmdval : array (0 .. 63) of Unsigned_8 := [others => 0];

                        Pat_Max_Ch : Integer := -1;

                        procedure Set_Cell
                          (Row, Ch : Natural;
                           Cell    : Pattern_Cell)
                        is
                        begin
                           if Ch < Max_Channels then
                              Cells (Row * Max_Channels + Ch) := Cell;
                              if Integer (Ch) > Pat_Max_Ch then
                                 Pat_Max_Ch := Integer (Ch);
                              end if;
                           end if;
                        end Set_Cell;

                     begin
                        for Row in 0 .. Rows - 1 loop
                           loop
                              declare
                                 Chanvar : constant Unsigned_8 := Read_U8 (S);
                              begin
                                 exit when Chanvar = 0;

                                 declare
                                    Ch      : constant Natural :=
                                                Natural (Chanvar - 1) mod 64;
                                    Maskvar : Unsigned_8;
                                 begin
                                    if (Chanvar and 16#80#) /= 0 then
                                       Maskvar := Read_U8 (S);
                                       Last_Mask (Ch) := Maskvar;
                                    else
                                       Maskvar := Last_Mask (Ch);
                                    end if;

                                    --  Read new values
                                    declare
                                       Note    : Unsigned_8 := Last_Note (Ch);
                                       Instr   : Unsigned_8 := Last_Instr (Ch);
                                       Volcmd  : Unsigned_8 := Last_Volcmd (Ch);
                                       Cmd     : Unsigned_8 := Last_Cmd (Ch);
                                       Cmdval  : Unsigned_8 := Last_Cmdval (Ch);
                                       Have_Note  : Boolean := False;
                                       Have_Instr : Boolean := False;
                                       Have_Vol   : Boolean := False;
                                       Have_Cmd   : Boolean := False;
                                    begin
                                       if (Maskvar and 16#01#) /= 0 then
                                          Note := Read_U8 (S);
                                          Last_Note (Ch) := Note;
                                          Have_Note := True;
                                       end if;
                                       if (Maskvar and 16#02#) /= 0 then
                                          Instr := Read_U8 (S);
                                          Last_Instr (Ch) := Instr;
                                          Have_Instr := True;
                                       end if;
                                       if (Maskvar and 16#04#) /= 0 then
                                          Volcmd := Read_U8 (S);
                                          Last_Volcmd (Ch) := Volcmd;
                                          Have_Vol := True;
                                       end if;
                                       if (Maskvar and 16#08#) /= 0 then
                                          Cmd    := Read_U8 (S);
                                          Cmdval := Read_U8 (S);
                                          Last_Cmd (Ch) := Cmd;
                                          Last_Cmdval (Ch) := Cmdval;
                                          Have_Cmd := True;
                                       end if;
                                       if (Maskvar and 16#10#) /= 0 then
                                          Note      := Last_Note (Ch);
                                          Have_Note := True;
                                       end if;
                                       if (Maskvar and 16#20#) /= 0 then
                                          Instr      := Last_Instr (Ch);
                                          Have_Instr := True;
                                       end if;
                                       if (Maskvar and 16#40#) /= 0 then
                                          Volcmd  := Last_Volcmd (Ch);
                                          Have_Vol := True;
                                       end if;
                                       if (Maskvar and 16#80#) /= 0 then
                                          Cmd    := Last_Cmd (Ch);
                                          Cmdval := Last_Cmdval (Ch);
                                          Have_Cmd := True;
                                       end if;

                                       --  Build and store cell
                                       declare
                                          Cell : Pattern_Cell;
                                          Eff  : Effect_Code;
                                          Par  : Effect_Param;
                                       begin
                                          if Have_Note then
                                             Cell.Note := IT_Note_To_Engine (Note);
                                          end if;
                                          if Have_Instr then
                                             declare
                                                IV : constant Natural :=
                                                  Natural (Instr);
                                             begin
                                                Cell.Instrument :=
                                                  Instrument_Index'Min (
                                                    Instrument_Index'Last,
                                                    Instrument_Index (IV));
                                             end;
                                          end if;
                                          if Have_Vol then
                                             Cell.Volume :=
                                               IT_Vol_To_Engine (Volcmd);
                                          end if;
                                          if Have_Cmd then
                                             Map_IT_Effect (Cmd, Cmdval, Eff, Par);
                                             Cell.Effect := Eff;
                                             Cell.Param  := Par;
                                          end if;

                                          Set_Cell (Row, Ch, Cell);
                                       end;
                                    end;
                                 end;
                              end;
                           end loop;
                        end loop;

                        --  Compact: copy only the columns used
                        if Pat_Max_Ch >= 0 then
                           declare
                              N_Ch : constant Positive := Pat_Max_Ch + 1;
                           begin
                              Pat.Num_Channels := N_Ch;
                              Pat.Cells        :=
                                new IT_Cell_Array (0 .. N_Ch * Rows - 1);
                              for Row in 0 .. Rows - 1 loop
                                 for Ch in 0 .. N_Ch - 1 loop
                                    Pat.Cells (Row * N_Ch + Ch) :=
                                      Cells (Row * Max_Channels + Ch);
                                 end loop;
                              end loop;
                              if Pat_Max_Ch > Max_Ch then
                                 Max_Ch := Pat_Max_Ch;
                              end if;
                           end;
                        end if;

                        --  Free the wide temporary cell array
                        declare
                           procedure Free_Wide is new Ada.Unchecked_Deallocation
                             (IT_Cell_Array, IT_Cell_Array_Access);
                        begin
                           Free_Wide (Cells);
                        end;
                     end;
                  end;
               end;
            end if;
         end loop;

         Song.Num_Channels := Positive'Max (1, Max_Ch + 1);

      exception
         when others =>
            Close (File);
            Status := IO_Error;
            return;
      end;

      Close (File);
   end Load;

   --  ---------------------------------------------------------------
   --  Free
   --  ---------------------------------------------------------------

   procedure Free (Song : in out IT_Song) is

      procedure Free_S8 is new Ada.Unchecked_Deallocation
        (Sample_Data_8, IT_Sample_8);
      procedure Free_S16 is new Ada.Unchecked_Deallocation
        (Sample_Data_16, IT_Sample_16);
      procedure Free_Cells is new Ada.Unchecked_Deallocation
        (IT_Cell_Array, IT_Cell_Array_Access);

   begin
      for I in 1 .. Max_Samples loop
         case Song.Samples (I).Depth is
            when Depth_8  =>
               if Song.Samples (I).Data_8 /= null then
                  Free_S8 (Song.Samples (I).Data_8);
               end if;
            when Depth_16 =>
               if Song.Samples (I).Data_16 /= null then
                  Free_S16 (Song.Samples (I).Data_16);
               end if;
         end case;
      end loop;

      for P in 0 .. Max_Patterns - 1 loop
         if Song.Patterns (P).Cells /= null then
            Free_Cells (Song.Patterns (P).Cells);
         end if;
      end loop;
   end Free;

end IT_Format;
