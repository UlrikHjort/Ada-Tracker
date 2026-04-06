-- ***************************************************************************
--                      Tracker - WAV Export
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
with Ada.Streams.Stream_IO;  use Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Interfaces;              use Interfaces;
with Tracker_Types;           use Tracker_Types;
with Song;
use type Song.Format_Kind;
use type Song.Float_Array_Access;
with Channel_State;
with Sequencer_Engine;
with Mixer;

package body Wav_Export is

   Output_Hz : constant Positive := Mixer.Output_Sample_Rate;  -- 44100

   function S16_To_U16 is new Ada.Unchecked_Conversion (Integer_16, Unsigned_16);

   --  ---------------------------------------------------------------
   --  WAV writing helpers (little-endian)
   --  ---------------------------------------------------------------

   procedure Write_U16 (S : Stream_Access; V : Unsigned_16) is
   begin
      Unsigned_8'Write (S, Unsigned_8 (V and 16#FF#));
      Unsigned_8'Write (S, Unsigned_8 (Shift_Right (V, 8)));
   end Write_U16;

   procedure Write_U32 (S : Stream_Access; V : Unsigned_32) is
   begin
      Unsigned_8'Write (S, Unsigned_8 (V and 16#FF#));
      Unsigned_8'Write (S, Unsigned_8 (Shift_Right (V,  8) and 16#FF#));
      Unsigned_8'Write (S, Unsigned_8 (Shift_Right (V, 16) and 16#FF#));
      Unsigned_8'Write (S, Unsigned_8 (Shift_Right (V, 24)));
   end Write_U32;

   procedure Write_Tag (S : Stream_Access; Tag : String) is
   begin
      for C of Tag loop
         Unsigned_8'Write (S, Character'Pos (C));
      end loop;
   end Write_Tag;

   procedure Write_S16 (S : Stream_Access; V : Float; Scale : Float) is
      Scaled : constant Float := V * Scale;
      Clamped : Float;
   begin
      if    Scaled >  32767.0 then Clamped :=  32767.0;
      elsif Scaled < -32768.0 then Clamped := -32768.0;
      else  Clamped := Scaled;
      end if;
      Write_U16 (S, S16_To_U16 (Integer_16 (Clamped)));
   end Write_S16;

   --  ---------------------------------------------------------------
   --  Write a placeholder WAV header (sizes = 0; fixed up at end)
   --  ---------------------------------------------------------------
   --  Layout:
   --    0   "RIFF"
   --    4   file_size - 8        (Unsigned_32, filled at end)
   --    8   "WAVE"
   --   12   "fmt "
   --   16   16                   (fmt chunk size)
   --   20   1                    (PCM)
   --   22   2                    (stereo)
   --   24   44100                (sample rate)
   --   28   176400               (byte rate)
   --   32   4                    (block align)
   --   34   16                   (bits/sample)
   --   36   "data"
   --   40   data_size            (Unsigned_32, filled at end)
   --   44   <samples>
   --  Total header = 44 bytes.

   procedure Write_Header (S : Stream_Access) is
   begin
      Write_Tag (S, "RIFF");
      Write_U32 (S, 0);               --  placeholder: file size - 8
      Write_Tag (S, "WAVE");
      Write_Tag (S, "fmt ");
      Write_U32 (S, 16);              --  fmt chunk size (PCM)
      Write_U16 (S, 1);               --  PCM format
      Write_U16 (S, 2);               --  stereo
      Write_U32 (S, Unsigned_32 (Output_Hz));
      Write_U32 (S, Unsigned_32 (Output_Hz) * 4);  --  byte rate (2ch * 2bytes)
      Write_U16 (S, 4);               --  block align
      Write_U16 (S, 16);              --  bits per sample
      Write_Tag (S, "data");
      Write_U32 (S, 0);               --  placeholder: data size
   end Write_Header;

   --  ---------------------------------------------------------------
   --  Render
   --  ---------------------------------------------------------------

   procedure Render (S : Song.Song_Type; Path : String) is

      File : File_Type;
      Strm : Stream_Access;

      --  Scale factor matching the real-time mixer (28000 / num_channels)
      Scale : constant Float := 28_000.0 / Float (S.Num_Channels);

      --  ---------------------------------------------------------------
      --  Offline channel state - plain array, no protected object needed
      --  ---------------------------------------------------------------
      Local : Channel_State.Channel_Array;

      --  ---------------------------------------------------------------
      --  Sequencer state (mirrors task-body local vars in sequencer.adb)
      --  ---------------------------------------------------------------
      BPM   : BPM_Value  := S.BPM;
      Speed : Tick_Value := S.Speed;

      Order_Idx  : Natural := 0;
      Row_Idx    : Natural := 0;
      Tick_Count : Natural := 0;

      Jump_To_Order        : Boolean := False;
      Jump_Order_Val       : Natural := 0;
      Break_To_Row         : Boolean := False;
      Break_Row_Val        : Natural := 0;
      Do_Pattern_Loop      : Boolean := False;
      Pattern_Loop_Row     : Natural := 0;
      Pattern_Loop_Count   : Natural := 0;
      Pattern_Delay_Remain : Natural := 0;

      Song_Restarted : Boolean := False;
      Done           : Boolean := False;

      --  Fractional sample accumulator for accurate tick timing
      Sample_Frac  : Float    := 0.0;
      Total_Frames : Unsigned_32 := 0;

      --  Safety cap
      Max_Frames : constant Unsigned_32 :=
        Unsigned_32 (Max_Export_Minutes) * 60 * Unsigned_32 (Output_Hz);

      --  ---------------------------------------------------------------
      procedure Advance_Row is
      begin
         Row_Idx := Row_Idx + 1;
         if Row_Idx >= S.Patterns (S.Orders (Order_Idx)).Num_Rows then
            Row_Idx   := 0;
            Order_Idx := Order_Idx + 1;
            if Order_Idx >= S.Song_Length then
               Order_Idx      := S.Restart_Pos;
               Song_Restarted := True;
            end if;
         end if;
      end Advance_Row;

      --  ---------------------------------------------------------------
      --  One sequencer tick: updates channel state from pattern data
      --  ---------------------------------------------------------------
      procedure Do_Tick is
         Pat : Song.Pattern renames S.Patterns (S.Orders (Order_Idx));
      begin
         --  Tick 0: trigger notes
         if Tick_Count = 0 then
            for Ch_Idx in Channel_Index range
                            0 .. Channel_Index (S.Num_Channels - 1)
            loop
               declare
                  Cell : constant Pattern_Cell :=
                           Song.Cell (Pat, Row_Index (Row_Idx), Ch_Idx);
                  Ch   : Channel_State.Channel renames Local (Ch_Idx);
               begin
                  --  IT NNA: push old voice to background before trigger
                  if S.Format = Song.Format_IT
                    and then Ch.Active
                    and then Ch.Instrument /= 0
                    and then Cell.Note not in Note_Empty | Note_Key_Off
                    and then Cell.Effect /= Effect_Tone_Porta
                    and then Cell.Effect /= 16#05#
                  then
                     declare
                        NNA : constant Natural :=
                                S.Instruments (Ch.Instrument).NNA;
                     begin
                        if NNA > 0 then
                           for BG in Channel_Index range
                               Channel_Index (Channel_State.Max_Song_Channels)
                               .. Channel_Index (Channel_State.Max_Channels - 1)
                           loop
                              if not Local (BG).Active then
                                 Local (BG) := Ch;
                                 if NNA >= 2 then
                                    Local (BG).Key_On := False;
                                 end if;
                                 exit;
                              end if;
                           end loop;
                        end if;
                     end;
                  end if;

                  Sequencer_Engine.Trigger_Row (Cell, Ch, S, Output_Hz);

                  --  Song-level effects (Bxx, Dxx, Fxx, E6x, EEx)
                  if Cell.Effect = Effect_Jump_To_Order then
                     Jump_To_Order  := True;
                     Jump_Order_Val := Natural (Cell.Param);
                  elsif Cell.Effect = Effect_Pattern_Break then
                     Break_To_Row  := True;
                     Break_Row_Val :=
                       Natural (Interfaces.Shift_Right (Cell.Param, 4)) * 10
                       + Natural (Cell.Param and 16#0F#);
                  elsif Cell.Effect = Effect_Set_Speed then
                     if Cell.Param < 32 then
                        Speed := Tick_Value'Max (1,
                          Tick_Value'Min (Tick_Value'Last,
                            Tick_Value (Cell.Param)));
                     else
                        BPM := BPM_Value'Max (BPM_Value'First,
                          BPM_Value'Min (BPM_Value'Last,
                            BPM_Value (Cell.Param)));
                     end if;
                  elsif Cell.Effect = Effect_Extended then
                     declare
                        Sub : constant Natural :=
                                Natural (Interfaces.Shift_Right (Cell.Param, 4));
                        Prm : constant Natural :=
                                Natural (Cell.Param and 16#0F#);
                     begin
                        if Sub = 16#6# then  --  E6x: pattern loop
                           if Prm = 0 then
                              Pattern_Loop_Row := Row_Idx;
                           else
                              if Pattern_Loop_Count = 0 then
                                 Pattern_Loop_Count := Prm;
                              else
                                 Pattern_Loop_Count := Pattern_Loop_Count - 1;
                              end if;
                              if Pattern_Loop_Count > 0 then
                                 Do_Pattern_Loop := True;
                              end if;
                           end if;
                        elsif Sub = 16#E# then  --  EEx: pattern delay
                           Pattern_Delay_Remain := Prm;
                        end if;
                     end;
                  end if;

                  --  MOD Amiga hard panning
                  if S.Format = Song.Format_MOD and Ch.Active then
                     case Ch_Idx mod 4 is
                        when 0 | 3 => Ch.Panning := -0.75;
                        when others => Ch.Panning :=  0.75;
                     end case;
                  end if;

                  --  S3M / IT per-channel default panning
                  if S.Format in Song.Format_S3M | Song.Format_IT
                    and Cell.Note not in Note_Empty | Note_Key_Off
                  then
                     Ch.Panning := Float (S.Channel_Pan (Ch_Idx)) / 128.0;
                  end if;
               end;
            end loop;
         end if;

         --  Every tick: process running effects
         for Ch_Idx in Channel_Index range
                          0 .. Channel_Index (S.Num_Channels - 1)
         loop
            declare
               Pat2 : Song.Pattern renames S.Patterns (S.Orders (Order_Idx));
               Cell : constant Pattern_Cell :=
                        Song.Cell (Pat2, Row_Index (Row_Idx), Ch_Idx);
               Ch   : Channel_State.Channel renames Local (Ch_Idx);
            begin
               Sequencer_Engine.Process_Effects
                 (Cell, Ch, S, Tick_Count, Output_Hz, BPM);
            end;
         end loop;

         --  Every tick: advance IT NNA background voice envelopes
         if S.Format = Song.Format_IT then
            for BG in Channel_Index range
                Channel_Index (Channel_State.Max_Song_Channels)
                .. Channel_Index (Channel_State.Max_Channels - 1)
            loop
               declare
                  BG_Ch : Channel_State.Channel renames Local (BG);
               begin
                  if BG_Ch.Active and then BG_Ch.Instrument /= 0 then
                     declare
                        Inst : Song.Instrument renames
                                 S.Instruments (BG_Ch.Instrument);
                     begin
                        Channel_State.Advance_Envelope
                          (BG_Ch.Vol_Env, Inst.Vol_Env, BG_Ch.Key_On);
                        Channel_State.Advance_Envelope
                          (BG_Ch.Pan_Env, Inst.Pan_Env, BG_Ch.Key_On);
                        if not BG_Ch.Key_On and then Inst.Fadeout > 0 then
                           BG_Ch.Fadeout_Vol := Float'Max (0.0,
                             BG_Ch.Fadeout_Vol
                               - Float (Inst.Fadeout) / 65536.0);
                        end if;
                        if BG_Ch.Fadeout_Vol <= 0.0 then
                           BG_Ch.Active := False;
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;

         --  Advance tick counter
         Tick_Count := Tick_Count + 1;
         if Tick_Count >= Natural (Speed) then
            Tick_Count := 0;

            if Do_Pattern_Loop then
               Do_Pattern_Loop := False;
               Row_Idx         := Pattern_Loop_Row;
            elsif Pattern_Delay_Remain > 0 then
               Pattern_Delay_Remain := Pattern_Delay_Remain - 1;
               Tick_Count           := 1;
            elsif Jump_To_Order then
               Jump_To_Order := False;
               Order_Idx     := Natural'Min (Jump_Order_Val,
                                             S.Song_Length - 1);
               Row_Idx       := 0;
               Pattern_Loop_Row   := 0;
               Pattern_Loop_Count := 0;
            elsif Break_To_Row then
               Break_To_Row := False;
               Order_Idx    := Order_Idx + 1;
               if Order_Idx >= S.Song_Length then
                  Order_Idx := S.Restart_Pos;
               end if;
               Row_Idx := Natural'Min (Break_Row_Val,
                 S.Patterns (S.Orders (Order_Idx)).Num_Rows - 1);
               Pattern_Loop_Row   := 0;
               Pattern_Loop_Count := 0;
            else
               Advance_Row;
               if Song_Restarted then
                  Song_Restarted := False;
                  Done := True;
               end if;
            end if;
         end if;
      end Do_Tick;

      --  ---------------------------------------------------------------
      --  Mix one audio frame into L/R
      --  ---------------------------------------------------------------
      procedure Mix_Frame (L, R : out Float) is
      begin
         L := 0.0;
         R := 0.0;
         for Ch_Idx in Channel_Index range 0 .. Channel_Index'Last loop
            declare
               Ch : Channel_State.Channel renames Local (Ch_Idx);
            begin
               if Ch.Active and then Ch.Instrument /= 0 then
                  declare
                     Inst : Song.Instrument renames
                              S.Instruments (Ch.Instrument);
                     Samp : Song.Sample renames
                              Inst.Samples (Ch.Sample_Slot);
                  begin
                     if Samp.Data /= null then
                        Mixer.Mix_Channel (Ch, Samp, L, R);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end Mix_Frame;

   begin
      Create (File, Out_File, Path);
      Strm := Stream (File);

      Write_Header (Strm);

      while not Done and Total_Frames < Max_Frames loop
         --  Compute how many samples to render for this tick
         declare
            Spf    : constant Float :=
                       Float (Output_Hz) * 2.5 / Float (BPM);
            Frames : constant Natural :=
                       Natural (Float'Floor (Spf + Sample_Frac));
            L, R   : Float;
         begin
            Sample_Frac := (Spf + Sample_Frac) - Float (Frames);

            Do_Tick;

            for F in 1 .. Frames loop
               Mix_Frame (L, R);
               Write_S16 (Strm, L, Scale);
               Write_S16 (Strm, R, Scale);
            end loop;

            Total_Frames := Total_Frames + Unsigned_32 (Frames);
         end;
      end loop;

      --  Fix up RIFF and data chunk sizes
      declare
         Data_Bytes : constant Unsigned_32 := Total_Frames * 4;
         --  RIFF size = everything after the first 8 bytes:
         --    "WAVE" (4) + "fmt " chunk (24) + "data" (8) + data
         Riff_Size  : constant Unsigned_32 := 36 + Data_Bytes;
      begin
         Set_Index (File, 5);           --  offset 4: RIFF chunk size
         Write_U32 (Strm, Riff_Size);
         Set_Index (File, 41);          --  offset 40: data chunk size
         Write_U32 (Strm, Data_Bytes);
      end;

      Close (File);
   end Render;

end Wav_Export;
