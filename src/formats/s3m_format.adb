-- ***************************************************************************
--                      Tracker - S3M Format
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

package body S3M_Format is

   use Ada.Streams.Stream_IO;

   function U8_To_I8   is new Ada.Unchecked_Conversion (Unsigned_8,  Integer_8);
   function U16_To_I16 is new Ada.Unchecked_Conversion (Unsigned_16, Integer_16);

   subtype Stream_Access is Ada.Streams.Stream_IO.Stream_Access;

   --  ---------------------------------------------------------------
   --  Low-level IO helpers (all little-endian)
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

   --  ---------------------------------------------------------------
   --  Seek to absolute byte offset in the file (0-based offset)
   --  Ada.Streams.Stream_IO uses 1-based indices.
   --  ---------------------------------------------------------------
   procedure Seek_To (File : File_Type; Offset : Natural) is
   begin
      Set_Index (File, Count (Offset) + 1);
   end Seek_To;

   --  ---------------------------------------------------------------
   --  Map S3M effect (1-based letter index, A=1) to Pattern_Cell
   --  effect code and param.  Unmapped effects -> Effect_None / 0.
   --  ---------------------------------------------------------------
   procedure Map_Effect
     (S3M_Effect : Unsigned_8;
      S3M_Param  : Unsigned_8;
      Effect     : out Effect_Code;
      Param      : out Effect_Param)
   is
      Hi : constant Natural := Natural (Shift_Right (S3M_Param, 4));
      Lo : constant Natural := Natural (S3M_Param and 16#0F#);
   begin
      Effect := Effect_None;
      Param  := S3M_Param;

      case S3M_Effect is
         when 1  =>  --  A: set speed (ticks per row)
            Effect := Effect_Set_Speed;

         when 2  =>  --  B: jump to order
            Effect := Effect_Jump_To_Order;

         when 3  =>  --  C: break to row (decimal, packed like XM Dxx)
            Effect := Effect_Pattern_Break;

         when 4  =>  --  D: volume slide (Dxy same as XM Axy)
            Effect := Effect_Vol_Slide;

         when 5  =>  --  E: portamento down
            Effect := Effect_Porta_Down;

         when 6  =>  --  F: portamento up
            Effect := Effect_Porta_Up;

         when 7  =>  --  G: tone portamento
            Effect := Effect_Tone_Porta;

         when 8  =>  --  H: vibrato
            Effect := Effect_Vibrato;

         when 10 =>  --  J: arpeggio
            Effect := Effect_Arpeggio;

         when 11 =>  --  K: vibrato + volume slide
            Effect := 16#06#;

         when 12 =>  --  L: tone portamento + volume slide
            Effect := 16#05#;

         when 15 =>  --  O: set sample offset
            Effect := 16#09#;

         when 18 =>  --  R: tremolo
            Effect := 16#07#;

         when 19 =>  --  S: special sub-effects
            Effect := Effect_Extended;
            declare
               L : constant Unsigned_8 := Unsigned_8 (Lo);
            begin
               case Hi is
                  when 16#1# =>  --  S1x: glissando control -> E3x
                     Param := 16#30# or L;
                  when 16#2# =>  --  S2x: set finetune -> E5x
                     Param := 16#50# or L;
                  when 16#3# =>  --  S3x: set vibrato waveform -> E4x
                     Param := 16#40# or L;
                  when 16#4# =>  --  S4x: set tremolo waveform -> E7x
                     Param := 16#70# or L;
                  when 16#8# =>  --  S8x: set panning (0=L, 8=C, F=R) -> E8x
                     Param := 16#80# or L;
                  when 16#B# =>  --  SBx: pattern loop -> E6x
                     Param := 16#60# or L;
                  when 16#C# =>  --  SCx: note cut -> ECx
                     Param := 16#C0# or L;
                  when 16#D# =>  --  SDx: note delay -> EDx
                     Param := 16#D0# or L;
                  when 16#E# =>  --  SEx: pattern delay -> EEx
                     Param := 16#E0# or L;
                  when others =>
                     Effect := Effect_None; Param := 0;
               end case;
            end;

         when 20 =>  --  T: set BPM -> XM Txx (effect 0x14)
            Effect := 16#14#;

         when 21 =>  --  U: fine vibrato (same as H for our engine)
            Effect := Effect_Vibrato;

         when 24 =>  --  X: set panning (0x00=L, 0x80=C, 0xFF=R) -> 0x08
            Effect := 16#08#;

         when others =>
            Effect := Effect_None;
            Param  := 0;
      end case;
   end Map_Effect;

   --  ---------------------------------------------------------------
   --  Load
   --  ---------------------------------------------------------------

   procedure Load
     (Path   : in  String;
      Song   : out S3M_Song;
      Status : out Load_Error)
   is
      File    : File_Type;
      S       : Stream_Access;

      Ord_Num     : Natural;
      Ins_Num     : Natural;
      Pat_Num     : Natural;
      Default_Pan : Unsigned_8;
      Stereo_Mode : Boolean;

      --  Channel settings (32 bytes at header offset 64)
      Ch_Settings : array (0 .. Max_Channels - 1) of Unsigned_8 :=
        [others => 16#FF#];

      --  Paragraph pointers read after the order list
      Ins_Paras : array (1 .. Max_Instruments) of Unsigned_16 :=
        [others => 0];
      Pat_Paras : array (0 .. Max_Patterns - 1) of Unsigned_16 :=
        [others => 0];


   begin
      Song := [others => <>];
      Status := None;

      --  Open file
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
         --  -----------------------------------------------------------------
         --  Header (96 bytes)
         --  -----------------------------------------------------------------

         --  Song name: 28 bytes
         Read_Str (S, Song.Name);

         --  Byte 28: DOS EOF marker
         Skip (S, 1);

         --  Byte 29: file type (16 = module)
         Skip (S, 1);

         --  Bytes 30..31: reserved
         Skip (S, 2);

         Ord_Num := Natural (Read_U16_LE (S));   --  32..33
         Ins_Num := Natural (Read_U16_LE (S));   --  34..35
         Pat_Num := Natural (Read_U16_LE (S));   --  36..37

         --  Clamp to our limits
         Ins_Num := Natural'Min (Ins_Num, Max_Instruments);
         Pat_Num := Natural'Min (Pat_Num, Max_Patterns);
         Ord_Num := Natural'Min (Ord_Num, Max_Orders);

         Song.Num_Instruments := Ins_Num;
         Song.Num_Patterns    := Pat_Num;

         Skip (S, 2);  --  Flags (38..39)
         Skip (S, 2);  --  Cwtv  (40..41)

         Skip (S, 2);  --  42..43: Ffi (8-bit always unsigned, only 16-bit differs)

         --  Verify "SCRM" magic at offset 44
         declare
            Tag : String (1 .. 4);
         begin
            Read_Str (S, Tag);
            if Tag /= "SCRM" then
               Close (File);
               Status := Invalid_Header;
               return;
            end if;
         end;

         Skip (S, 1);  --  48: global volume

         declare
            Spd : constant Natural := Natural (Read_U8 (S));  --  49: initial speed
         begin
            Song.Speed := Tick_Value (Natural'Max (1, Natural'Min (31, Spd)));
         end;

         declare
            Bpm : constant Natural := Natural (Read_U8 (S));  --  50: initial tempo
         begin
            Song.BPM := BPM_Value (Natural'Max (32, Natural'Min (255, Bpm)));
         end;

         declare
            Mv : constant Unsigned_8 := Read_U8 (S);   --  51: master volume
         begin
            Stereo_Mode := (Mv and 16#80#) /= 0;
         end;

         Skip (S, 1);  --  52: ultra click removal

         Default_Pan := Read_U8 (S);  --  53: 0xFC = use panning table

         Skip (S, 8);  --  54..61: reserved
         Skip (S, 2);  --  62..63: special pointer

         --  64..95: channel settings (32 bytes)
         for I in Ch_Settings'Range loop
            Ch_Settings (I) := Read_U8 (S);
         end loop;

         --  Determine active channels and their default panning.
         --  A channel is active if bit7=0 and raw value < 16 (PCM channel).
         --  Values 0..7 = left, 8..15 = right.
         declare
            Max_Ch : Integer := -1;
         begin
            for I in Ch_Settings'Range loop
               declare
                  V : constant Unsigned_8 := Ch_Settings (I);
                  Raw : constant Natural := Natural (V and 16#7F#);
               begin
                  if (V and 16#80#) = 0 and Raw < 16 then
                     if I > Max_Ch then
                        Max_Ch := I;
                     end if;
                     --  Default stereo pan from channel type
                     if Stereo_Mode then
                        Song.Channel_Pan (I) :=
                          (if Raw < 8 then -96 else 96);
                     end if;
                  end if;
               end;
            end loop;
            Song.Num_Channels :=
              Positive'Max (1, Positive (Max_Ch + 1));
         end;

         --  -----------------------------------------------------------------
         --  Order list (OrdNum bytes), skip 0xFE/0xFF markers
         --  -----------------------------------------------------------------
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

         --  -----------------------------------------------------------------
         --  Instrument paragraph pointers (InsNum * 2 bytes)
         --  -----------------------------------------------------------------
         for I in 1 .. Ins_Num loop
            Ins_Paras (I) := Read_U16_LE (S);
         end loop;

         --  -----------------------------------------------------------------
         --  Pattern paragraph pointers (PatNum * 2 bytes)
         --  -----------------------------------------------------------------
         for I in 0 .. Pat_Num - 1 loop
            Pat_Paras (I) := Read_U16_LE (S);
         end loop;

         --  -----------------------------------------------------------------
         --  Optional per-channel panning table (32 bytes)
         --  Present when Default_Pan == 0xFC.
         --  Byte format: if (byte & 0x20) != 0: pan = byte & 0x0F (0..15)
         --               0 = full left, 8 = centre, 15 = full right
         --  -----------------------------------------------------------------
         if Default_Pan = 16#FC# then
            for I in 0 .. Max_Channels - 1 loop
               declare
                  B : constant Unsigned_8 := Read_U8 (S);
               begin
                  if (B and 16#20#) /= 0 then
                     declare
                        Val : constant Natural := Natural (B and 16#0F#);
                        --  Map 0..15 -> -128..127
                        Pan : constant Integer :=
                          Integer (Float'Rounding (
                            Float (Val) * 255.0 / 15.0)) - 128;
                     begin
                        Song.Channel_Pan (I) :=
                          Pan_Entry'Max (-128, Pan_Entry'Min (127, Pan));
                     end;
                  end if;
               end;
            end loop;
         end if;

         --  -----------------------------------------------------------------
         --  Load instruments
         --  -----------------------------------------------------------------
         for I in 1 .. Ins_Num loop
            if Ins_Paras (I) /= 0 then
               Seek_To (File, Natural (Ins_Paras (I)) * 16);

               declare
                  Inst_Type : constant Unsigned_8 := Read_U8 (S);
               begin
                  if Inst_Type = 1 then
                     --  PCM sample
                     Skip (S, 12);  --  DOS filename

                     declare
                        Seg_Hi  : constant Unsigned_8  := Read_U8 (S);
                        Seg_Lo  : constant Unsigned_16 := Read_U16_LE (S);
                        Data_Para : constant Natural :=
                          Natural (Shift_Left (Unsigned_32 (Seg_Hi), 16)
                                   or Unsigned_32 (Seg_Lo));
                        Len     : constant Natural :=
                          Natural (Read_U32_LE (S));
                        L_Start : constant Natural :=
                          Natural (Read_U32_LE (S));
                        L_End   : constant Natural :=
                          Natural (Read_U32_LE (S));
                        Vol     : constant Unsigned_8 := Read_U8 (S);
                     begin
                        Skip (S, 1);  --  reserved
                        Skip (S, 1);  --  packing (0=raw)

                        declare
                           Flags : constant Unsigned_8 := Read_U8 (S);
                           C5Sp  : constant Natural :=
                             Natural (Read_U32_LE (S));
                        begin
                           Skip (S, 12);  --  4 unused + 2 int_gp + 2 int512 + 4 int_last

                           declare
                              Name : String (1 .. 28);
                           begin
                              Read_Str (S, Name);

                              --  Verify "SCRS" magic
                              declare
                                 Magic : String (1 .. 4);
                              begin
                                 Read_Str (S, Magic);
                                 if Magic /= "SCRS" then
                                    --  Not a valid PCM instrument, skip
                                    null;
                                 else
                                    declare
                                       Sixteen_Bit : constant Boolean :=
                                         (Flags and Flag_16Bit) /= 0;
                                    begin
                                       declare
                                          Safe_Vol : constant Volume_Value :=
                                            Volume_Value (
                                              Natural'Min (64, Natural (Vol)));
                                       begin
                                          if Sixteen_Bit then
                                             Song.Instruments (I) :=
                                               (Depth      => Depth_16,
                                                Name       => Name,
                                                Volume     => Safe_Vol,
                                                C5Speed    => C5Sp,
                                                Has_Loop   =>
                                                  (Flags and Flag_Loop) /= 0,
                                                Loop_Start => L_Start / 2,
                                                Loop_End   => L_End / 2,
                                                Data_16    => null);
                                          else
                                             Song.Instruments (I) :=
                                               (Depth      => Depth_8,
                                                Name       => Name,
                                                Volume     => Safe_Vol,
                                                C5Speed    => C5Sp,
                                                Has_Loop   =>
                                                  (Flags and Flag_Loop) /= 0,
                                                Loop_Start => L_Start,
                                                Loop_End   => L_End,
                                                Data_8     => null);
                                          end if;
                                       end;

                                       --  Load sample data
                                       if Len > 0 and Data_Para > 0 then
                                          Seek_To (File, Data_Para * 16);
                                          if Sixteen_Bit then
                                             declare
                                                Words : constant Natural :=
                                                  Len / 2;
                                                Arr : constant
                                                  S3M_Sample_16 :=
                                                  new Sample_Data_16
                                                        (0 .. Words - 1);
                                             begin
                                                for J in Arr'Range loop
                                                   declare
                                                      Lo : constant Unsigned_8
                                                        := Read_U8 (S);
                                                      Hi : constant Unsigned_8
                                                        := Read_U8 (S);
                                                      V16 : constant
                                                        Unsigned_16 :=
                                                          Shift_Left (
                                                            Unsigned_16 (Hi),
                                                            8)
                                                          or Unsigned_16 (Lo);
                                                   begin
                                                      Arr (J) :=
                                                        U16_To_I16 (V16);
                                                   end;
                                                end loop;
                                                Song.Instruments (I).Data_16
                                                  := Arr;
                                             end;
                                          else
                                             declare
                                                Arr : constant S3M_Sample_8 :=
                                                  new Sample_Data_8
                                                        (0 .. Len - 1);
                                             begin
                                                for J in Arr'Range loop
                                                   --  S3M 8-bit samples are
                                                   --  always unsigned (0-255)
                                                   --  regardless of Ffi flag.
                                                   Arr (J) := U8_To_I8 (
                                                     Read_U8 (S) xor 16#80#);
                                                end loop;
                                                Song.Instruments (I).Data_8
                                                  := Arr;
                                             end;
                                          end if;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end;
                        end;
                     end;
                  end if;
               end;
            end if;
         end loop;

         --  -----------------------------------------------------------------
         --  Load patterns
         --  -----------------------------------------------------------------
         for P in 0 .. Pat_Num - 1 loop
            if Pat_Paras (P) /= 0 then
               Seek_To (File, Natural (Pat_Paras (P)) * 16);

               declare
                  Packed_Sz : constant Natural :=
                    Natural (Read_U16_LE (S));
                  pragma Unreferenced (Packed_Sz);

                  Num_Ch : constant Positive := Song.Num_Channels;
                  Cells  : constant S3M_Cell_Array_Access :=
                    new S3M_Cell_Array
                          (0 .. S3M_Rows * Num_Ch - 1);
               begin
                  --  Parse 64 rows of packed cell data
                  for Row in 0 .. S3M_Rows - 1 loop
                     loop
                        declare
                           B : constant Unsigned_8 := Read_U8 (S);
                        begin
                           exit when B = 0;

                           declare
                              Ch_Idx : constant Natural :=
                                Natural (B and 16#1F#);
                              Flags  : constant Unsigned_8 :=
                                B and 16#E0#;
                           begin
                              --  Read note + instrument
                              if (Flags and 16#20#) /= 0 then
                                 declare
                                    Note_B : constant Unsigned_8 :=
                                      Read_U8 (S);
                                    Inst_B : constant Unsigned_8 :=
                                      Read_U8 (S);
                                 begin
                                    if Ch_Idx < Num_Ch then
                                       declare
                                          Cell : Pattern_Cell renames
                                            Cells (Row * Num_Ch + Ch_Idx);
                                       begin
                                          if Note_B = 16#FF# then
                                             Cell.Note := Note_Empty;
                                          elsif Note_B = 16#FE# then
                                             Cell.Note := Note_Key_Off;
                                          else
                                             --  S3M: (octave<<4)|semitone
                                             declare
                                                Oct : constant Natural :=
                                                  Natural (
                                                    Shift_Right (Note_B, 4));
                                                Sem : constant Natural :=
                                                  Natural (Note_B and 16#0F#);
                                                Raw : constant Natural :=
                                                  Oct * 12 + Sem + 1;
                                             begin
                                                Cell.Note := Note_Value (
                                                  Natural'Min (
                                                    Natural (Note_Value'Last),
                                                    Raw));
                                             end;
                                          end if;
                                          Cell.Instrument := Instrument_Index (
                                            Natural'Min (
                                              Natural (Instrument_Index'Last),
                                              Natural (Inst_B)));
                                       end;
                                    end if;
                                 end;
                              end if;

                              --  Read volume (0-64 -> stored as 0x10+vol)
                              if (Flags and 16#40#) /= 0 then
                                 declare
                                    Vol : constant Unsigned_8 := Read_U8 (S);
                                 begin
                                    if Ch_Idx < Num_Ch then
                                       Cells (Row * Num_Ch + Ch_Idx)
                                         .Volume :=
                                           16#10# + Natural'Min (64,
                                             Natural (Vol));
                                    end if;
                                 end;
                              end if;

                              --  Read effect + param
                              if (Flags and 16#80#) /= 0 then
                                 declare
                                    Eff_B  : constant Unsigned_8 :=
                                      Read_U8 (S);
                                    Par_B  : constant Unsigned_8 :=
                                      Read_U8 (S);
                                    Eff_Out : Effect_Code;
                                    Par_Out : Effect_Param;
                                 begin
                                    Map_Effect (Eff_B, Par_B,
                                                Eff_Out, Par_Out);
                                    if Ch_Idx < Num_Ch then
                                       declare
                                          Cell : Pattern_Cell renames
                                            Cells (Row * Num_Ch + Ch_Idx);
                                       begin
                                          Cell.Effect := Eff_Out;
                                          Cell.Param  := Par_Out;
                                       end;
                                    end if;
                                 end;
                              end if;
                           end;
                        end;
                     end loop;
                  end loop;

                  Song.Patterns (Pattern_Index (P)).Num_Channels := Num_Ch;
                  Song.Patterns (Pattern_Index (P)).Cells        := Cells;
               end;
            end if;
         end loop;

      exception
         when Ada.Streams.Stream_IO.End_Error =>
            null;  --  truncated file - use what we have
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

   procedure Free (Song : in out S3M_Song) is
      procedure Free_8 is new Ada.Unchecked_Deallocation
        (Sample_Data_8, S3M_Sample_8);
      procedure Free_16 is new Ada.Unchecked_Deallocation
        (Sample_Data_16, S3M_Sample_16);
      procedure Free_Cells is new Ada.Unchecked_Deallocation
        (S3M_Cell_Array, S3M_Cell_Array_Access);
   begin
      for I in 1 .. Song.Num_Instruments loop
         case Song.Instruments (I).Depth is
            when Depth_8 =>
               if Song.Instruments (I).Data_8 /= null then
                  Free_8 (Song.Instruments (I).Data_8);
               end if;
            when Depth_16 =>
               if Song.Instruments (I).Data_16 /= null then
                  Free_16 (Song.Instruments (I).Data_16);
               end if;
         end case;
      end loop;
      for P in Pattern_Index loop
         if Song.Patterns (P).Cells /= null then
            Free_Cells (Song.Patterns (P).Cells);
         end if;
      end loop;
   end Free;

end S3M_Format;
