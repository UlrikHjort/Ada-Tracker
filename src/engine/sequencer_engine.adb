-- ***************************************************************************
--                      Tracker - Sequencer Engine
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
with Ada.Numerics.Elementary_Functions;
with Interfaces; use Interfaces;
with Mod_Format;
with Song;

use type Song.Format_Kind;

package body Sequencer_Engine is

   use Ada.Numerics.Elementary_Functions;

   --  ---------------------------------------------------------------
   --  Sine table for vibrato / tremolo (256 entries, 0-255 range)
   --  ---------------------------------------------------------------
   type Sine_Table_T is array (0 .. 255) of Integer;
   Sine_Tab : constant Sine_Table_T :=
     [0,   3,   6,   9,  12,  16,  19,  22,  25,  28,  31,  34,  37,  40,  43,  46,
      49,  51,  54,  57,  60,  63,  65,  68,  71,  73,  76,  78,  81,  83,  85,  88,
      90,  92,  94,  96,  98, 100, 102, 104, 106, 107, 109, 111, 112, 113, 115, 116,
     117, 118, 120, 121, 122, 123, 123, 124, 125, 125, 126, 126, 126, 127, 127, 127,
     127, 127, 127, 127, 126, 126, 126, 125, 125, 124, 123, 123, 122, 121, 120, 118,
     117, 116, 115, 113, 112, 111, 109, 107, 106, 104, 102, 100,  98,  96,  94,  92,
      90,  88,  85,  83,  81,  78,  76,  73,  71,  68,  65,  63,  60,  57,  54,  51,
      49,  46,  43,  40,  37,  34,  31,  28,  25,  22,  19,  16,  12,   9,   6,   3,
       0,  -3,  -6,  -9, -12, -16, -19, -22, -25, -28, -31, -34, -37, -40, -43, -46,
     -49, -51, -54, -57, -60, -63, -65, -68, -71, -73, -76, -78, -81, -83, -85, -88,
     -90, -92, -94, -96, -98,-100,-102,-104,-106,-107,-109,-111,-112,-113,-115,-116,
    -117,-118,-120,-121,-122,-123,-123,-124,-125,-125,-126,-126,-126,-127,-127,-127,
    -127,-127,-127,-127,-126,-126,-126,-125,-125,-124,-123,-123,-122,-121,-120,-118,
    -117,-116,-115,-113,-112,-111,-109,-107,-106,-104,-102,-100, -98, -96, -94, -92,
     -90, -88, -85, -83, -81, -78, -76, -73, -71, -68, -65, -63, -60, -57, -54, -51,
     -49, -46, -43, -40, -37, -34, -31, -28, -25, -22, -19, -16, -12,  -9,  -6,  -3];

   function Vibrato_Delta
     (Wave  : Channel_State.Vibrato_Wave;
      Phase : Natural;
      Depth : Natural) return Float
   is
      P   : constant Natural := Phase mod 256;
      Raw : Integer;
   begin
      case Wave is
         when Channel_State.Sine      => Raw := Sine_Tab (P);
         when Channel_State.Square    => Raw := (if P < 128 then 127 else -127);
         when Channel_State.Ramp_Down => Raw := 127 - Integer (P);
         when Channel_State.Ramp_Up   => Raw := Integer (P) - 127;
      end case;
      return Float (Raw * Integer (Depth)) / 128.0;
   end Vibrato_Delta;

   function Tremolo_Delta
     (Wave  : Channel_State.Tremolo_Wave;
      Phase : Natural;
      Depth : Natural) return Float
   is
      P   : constant Natural := Phase mod 256;
      Raw : Integer;
   begin
      case Wave is
         when Channel_State.Sine      => Raw := Sine_Tab (P);
         when Channel_State.Square    => Raw := (if P < 128 then 127 else -127);
         when Channel_State.Ramp_Down => Raw := 127 - Integer (P);
         when Channel_State.Ramp_Up   => Raw := Integer (P) - 127;
      end case;
      return Float (Raw * Integer (Depth)) / 128.0;
   end Tremolo_Delta;

   --  ---------------------------------------------------------------
   --  Per-row note trigger
   --  ---------------------------------------------------------------

   procedure Trigger_Row
     (Cell      : Tracker_Types.Pattern_Cell;
      Ch        : in out Channel_State.Channel;
      S         : Song.Song_Type;
      Output_Hz : Positive)
   is
   begin
      --  Note trigger (but 3xx / 5xx / vol-col Fxx preserve porta target)
      if Cell.Note /= Note_Empty
        and then Cell.Effect /= Effect_Tone_Porta
        and then Cell.Effect /= 16#05#   --  5xx = tone porta + vol slide
        and then Cell.Volume < 16#F0#    --  vol col tone porta
      then
         Channel_State.Trigger_Note (Ch, S, Cell.Note, Cell.Instrument,
                                     Output_Hz);
      end if;

      --  Tone portamento: update target, don't retrigger
      if Cell.Effect = Effect_Tone_Porta or Cell.Effect = 16#05# then
         if Cell.Note /= Note_Empty and Cell.Note /= Note_Key_Off then
            declare
               Tgt_Note : constant Note_Value := Cell.Note;
               Fine     : constant Integer :=
                 (if Cell.Instrument /= 0
                  then S.Instruments (Cell.Instrument)
                         .Samples (Ch.Sample_Slot).Finetune
                  else 0);
            begin
               if S.Linear_Freq then
                  Ch.Tone_Porta_Target :=
                    Float (10 * 12 * 16 * 4
                           - (Integer (Tgt_Note) - 1) * 64) - Float (Fine) / 2.0;
               else
                  Ch.Tone_Porta_Target :=
                    Float (Mod_Format.Amiga_Periods (Tgt_Note))
                    * (2.0 ** (Float (-Fine) / (128.0 * 12.0)));
               end if;
            end;
         end if;
         if Cell.Instrument /= 0 then
            Ch.Instrument := Cell.Instrument;
         end if;
      end if;

      --  Volume column (XM)
      declare
         V : constant Natural := Cell.Volume;
      begin
         if V in 16#10# .. 16#50# then
            Ch.Volume := Float (V - 16#10#) / 64.0;
         elsif V in 16#80# .. 16#8F# then  --  fine vol slide down
            Ch.Volume := Float'Max (0.0,
                           Ch.Volume - Float (V mod 16) / 64.0);
         elsif V in 16#90# .. 16#9F# then  --  fine vol slide up
            Ch.Volume := Float'Min (1.0,
                           Ch.Volume + Float (V mod 16) / 64.0);
         elsif V in 16#A0# .. 16#AF# then  --  set vibrato speed
            if V mod 16 /= 0 then
               Ch.Vibrato_Speed := V mod 16;
            end if;
         elsif V in 16#B0# .. 16#BF# then  --  set vibrato depth
            if V mod 16 /= 0 then
               Ch.Vibrato_Depth := V mod 16;
            end if;
         elsif V in 16#C0# .. 16#CF# then  --  set panning (0..15 -> full range)
            Ch.Panning := Float (V mod 16) / 7.5 - 1.0;
         elsif V in 16#F0# .. 16#FF# then  --  tone portamento
            if Cell.Note not in Note_Empty | Note_Key_Off then
               declare
                  Tgt  : constant Note_Value := Cell.Note;
                  Fine : constant Integer :=
                    (if Cell.Instrument /= 0
                     then S.Instruments (Cell.Instrument)
                            .Samples (Ch.Sample_Slot).Finetune
                     else 0);
               begin
                  if S.Linear_Freq then
                     Ch.Tone_Porta_Target :=
                       Float (10 * 12 * 16 * 4 - (Integer (Tgt) - 1) * 64)
                       - Float (Fine) / 2.0;
                  else
                     Ch.Tone_Porta_Target :=
                       Float (Mod_Format.Amiga_Periods (Tgt))
                       * (2.0 ** (Float (-Fine) / (128.0 * 12.0)));
                  end if;
               end;
            end if;
            if Cell.Instrument /= 0 then Ch.Instrument := Cell.Instrument; end if;
            if V mod 16 /= 0 then
               Ch.Tone_Porta_Speed := V mod 16;
               Ch.Mem_Tone_Porta   := V mod 16;
            end if;
         end if;
      end;

      --  Set volume (Cxx)
      if Cell.Effect = Effect_Set_Volume then
         Ch.Volume := Float (Natural'Min (64, Natural (Cell.Param))) / 64.0;
      end if;

      --  Sample offset (9xx)
      if Cell.Effect = 16#09# then
         if Cell.Param /= 0 then
            Ch.Mem_Offset := Natural (Cell.Param) * 256;
         end if;
         Ch.Position := Float (Ch.Mem_Offset);
      end if;

      --  Effect speed memory
      if Cell.Effect = Effect_Porta_Up and Cell.Param /= 0 then
         Ch.Mem_Porta_Up := Natural (Cell.Param);
      end if;
      if Cell.Effect = Effect_Porta_Down and Cell.Param /= 0 then
         Ch.Mem_Porta_Down := Natural (Cell.Param);
      end if;
      if Cell.Effect = Effect_Vol_Slide and Cell.Param /= 0 then
         Ch.Mem_Vol_Slide := Natural (Cell.Param);
      end if;
      if Cell.Effect = Effect_Vibrato and Cell.Param /= 0 then
         Ch.Mem_Vibrato := Natural (Cell.Param);
      end if;
      if Cell.Effect = Effect_Tone_Porta and Cell.Param /= 0 then
         Ch.Tone_Porta_Speed := Natural (Cell.Param);
         Ch.Mem_Tone_Porta   := Natural (Cell.Param);
      end if;
      if Cell.Effect = 16#07# and Cell.Param /= 0 then  --  tremolo
         Ch.Mem_Tremolo := Natural (Cell.Param);
      end if;

      --  Arpeggio setup (0xy)
      if Cell.Effect = Effect_Arpeggio then
         Ch.Arpeggio_Note1 := Natural (Shift_Right (Cell.Param, 4));
         Ch.Arpeggio_Note2 := Natural (Cell.Param and 16#0F#);
      end if;

      --  Vibrato speed/depth from 4xy
      if Cell.Effect = Effect_Vibrato then
         if Cell.Param /= 0 then
            declare
               Speed : constant Natural :=
                         Natural (Shift_Right (Cell.Param, 4));
               Depth : constant Natural := Natural (Cell.Param and 16#0F#);
            begin
               if Speed /= 0 then Ch.Vibrato_Speed := Speed; end if;
               if Depth /= 0 then Ch.Vibrato_Depth := Depth; end if;
            end;
         end if;
      end if;

      --  Tremolo (7xy)
      if Cell.Effect = 16#07# then
         if Cell.Param /= 0 then
            declare
               Speed : constant Natural :=
                         Natural (Shift_Right (Cell.Param, 4));
               Depth : constant Natural := Natural (Cell.Param and 16#0F#);
            begin
               if Speed /= 0 then Ch.Tremolo_Speed := Speed; end if;
               if Depth /= 0 then Ch.Tremolo_Depth := Depth; end if;
            end;
         end if;
      end if;

      --  E-extended effects (row-trigger phase only)
      if Cell.Effect = Effect_Extended then
         declare
            Sub   : constant Natural := Natural (Shift_Right (Cell.Param, 4));
            Param : constant Natural := Natural (Cell.Param and 16#0F#);
         begin
            case Sub is
               when 16#9# =>  --  E9x: retrigger note
                  null;  --  handled in tick phase
               when 16#C# =>  --  ECx: note cut on tick x
                  null;  --  handled in tick phase
               when 16#D# =>  --  EDx: note delay (trigger on tick x)
                  null;  --  handled in tick phase
               when 16#A# =>  --  EAx: fine volume slide up
                  Ch.Volume := Float'Min (1.0,
                                 Ch.Volume + Float (Param) / 64.0);
               when 16#B# =>  --  EBx: fine volume slide down
                  Ch.Volume := Float'Max (0.0,
                                 Ch.Volume - Float (Param) / 64.0);
               when 16#1# =>  --  E1x: fine porta up
                  if S.Linear_Freq then
                     Ch.Period := Ch.Period - Float (Param) * 4.0;
                  else
                     Ch.Period := Ch.Period * (2.0 ** (Float (-Param) / (12.0 * 16.0)));
                  end if;
                  Ch.Phase_Inc := Channel_State.Compute_Phase_Inc
                    (Ch.Period, S.Linear_Freq, Output_Hz);
               when 16#2# =>  --  E2x: fine porta down
                  if S.Linear_Freq then
                     Ch.Period := Ch.Period + Float (Param) * 4.0;
                  else
                     Ch.Period := Ch.Period * (2.0 ** (Float (Param) / (12.0 * 16.0)));
                  end if;
                  Ch.Phase_Inc := Channel_State.Compute_Phase_Inc
                    (Ch.Period, S.Linear_Freq, Output_Hz);
               when others => null;
            end case;
         end;
      end if;
   end Trigger_Row;

   --  ---------------------------------------------------------------
   --  Per-tick effect update
   --  ---------------------------------------------------------------

   procedure Process_Effects
     (Cell        : Tracker_Types.Pattern_Cell;
      Ch          : in out Channel_State.Channel;
      S           : Song.Song_Type;
      Tick        : Natural;
      Output_Hz   : Positive;
      Current_BPM : in out BPM_Value)
   is
      use Channel_State;

      Eff   : constant Effect_Code  := Cell.Effect;
      Param : constant Effect_Param := Cell.Param;

      procedure Update_Freq is
      begin
         Ch.Phase_Inc := Compute_Phase_Inc (Ch.Period, S.Linear_Freq, Output_Hz);
      end Update_Freq;

      procedure Slide_Period_Toward_Target is
         Speed : constant Float := Float (Ch.Tone_Porta_Speed) * 4.0;
      begin
         if Ch.Period > Ch.Tone_Porta_Target then
            Ch.Period := Float'Max (Ch.Tone_Porta_Target, Ch.Period - Speed);
         elsif Ch.Period < Ch.Tone_Porta_Target then
            Ch.Period := Float'Min (Ch.Tone_Porta_Target, Ch.Period + Speed);
         end if;
         Update_Freq;
      end Slide_Period_Toward_Target;

      procedure Apply_Vol_Slide (P : Effect_Param) is
         Up   : constant Natural := Natural (Shift_Right (P, 4));
         Down : constant Natural := Natural (P and 16#0F#);
      begin
         if Up /= 0 then
            Ch.Volume := Float'Min (1.0, Ch.Volume + Float (Up) / 64.0);
         elsif Down /= 0 then
            Ch.Volume := Float'Max (0.0, Ch.Volume - Float (Down) / 64.0);
         end if;
      end Apply_Vol_Slide;

   begin
      if not Ch.Active then return; end if;

      --  Envelope + fadeout (XM and IT both use the same mechanism)
      if S.Format in Song.Format_XM | Song.Format_IT
        and Ch.Instrument /= 0
      then
         declare
            Inst : Song.Instrument renames S.Instruments (Ch.Instrument);
         begin
            Channel_State.Advance_Envelope (Ch.Vol_Env, Inst.Vol_Env, Ch.Key_On);
            Channel_State.Advance_Envelope (Ch.Pan_Env, Inst.Pan_Env, Ch.Key_On);

            --  IT filter envelope
            if S.Format = Song.Format_IT
              and then Inst.Flt_Env.Enabled
              and then Inst.Flt_Cutoff < 128
            then
               Channel_State.Advance_Envelope
                 (Ch.Flt_Env, Inst.Flt_Env, Ch.Key_On);
               declare
                  --  Envelope value 0-64; 32 = no change.
                  --  Each unit above/below 32 shifts cutoff by 2.
                  Env_Cut : constant Integer :=
                              Inst.Flt_Cutoff
                              + (Integer (Ch.Flt_Env.Value) - 32) * 2;
                  New_Cut : constant Natural :=
                              Natural (Integer'Max (0,
                                Integer'Min (127, Env_Cut)));
               begin
                  if New_Cut /= Ch.Filter_Cutoff then
                     Channel_State.Update_Filter
                       (Ch, New_Cut, Ch.Filter_Resonance, Output_Hz);
                  end if;
               end;
            end if;

            if not Ch.Key_On and Inst.Fadeout > 0 then
               Ch.Fadeout_Vol := Float'Max (0.0,
                 Ch.Fadeout_Vol - Float (Inst.Fadeout) / 65536.0);
            end if;

            if Ch.Fadeout_Vol <= 0.0 then
               Ch.Active := False;
               return;
            end if;
         end;
      end if;

      case Eff is

         when Effect_Arpeggio =>
            if Param /= 0 then
               declare
                  Phase     : constant Natural := Tick mod 3;
                  Semis     : Natural;
                  Base_Note : constant Integer := Integer (Ch.Note);
                  New_Note  : Note_Value;
               begin
                  case Phase is
                     when 0 => Semis := 0;
                     when 1 => Semis := Ch.Arpeggio_Note1;
                     when 2 => Semis := Ch.Arpeggio_Note2;
                     when others => Semis := 0;
                  end case;
                  New_Note := Note_Value'Max (1,
                    Note_Value'Min (96,
                      Note_Value (Base_Note + Integer (Semis))));
                  if S.Linear_Freq then
                     Ch.Period :=
                       Float (10 * 12 * 16 * 4 - (Integer (New_Note) - 1) * 64);
                  else
                     Ch.Period := Float (Mod_Format.Amiga_Periods (New_Note));
                  end if;
                  Update_Freq;
               end;
            end if;

         when Effect_Porta_Up =>
            declare
               Speed : constant Natural :=
                 (if Param /= 0 then Natural (Param) else Ch.Mem_Porta_Up);
            begin
               if Tick > 0 then
                  if S.Linear_Freq then
                     Ch.Period := Ch.Period - Float (Speed) * 4.0;
                  else
                     Ch.Period := Ch.Period / (2.0 ** (Float (Speed) / (12.0 * 16.0)));
                  end if;
                  Update_Freq;
               end if;
            end;

         when Effect_Porta_Down =>
            declare
               Speed : constant Natural :=
                 (if Param /= 0 then Natural (Param) else Ch.Mem_Porta_Down);
            begin
               if Tick > 0 then
                  if S.Linear_Freq then
                     Ch.Period := Ch.Period + Float (Speed) * 4.0;
                  else
                     Ch.Period := Ch.Period * (2.0 ** (Float (Speed) / (12.0 * 16.0)));
                  end if;
                  Update_Freq;
               end if;
            end;

         when Effect_Tone_Porta =>
            if Tick > 0 then
               Slide_Period_Toward_Target;
            end if;

         when Effect_Vibrato =>
            if Tick > 0 then
               Ch.Vibrato_Phase :=
                 (Ch.Vibrato_Phase + Ch.Vibrato_Speed * 4) mod 256;
            end if;
            declare
               Dlt : constant Float :=
                 Vibrato_Delta (Ch.Vibrato_Wave_Form,
                                Ch.Vibrato_Phase,
                                Ch.Vibrato_Depth);
               Vibr_Period : Float;
            begin
               if S.Linear_Freq then
                  Vibr_Period := Ch.Period + Dlt;
               else
                  Vibr_Period := Ch.Period * (2.0 ** (Dlt / (12.0 * 64.0)));
               end if;
               Ch.Phase_Inc := Compute_Phase_Inc (Vibr_Period, S.Linear_Freq,
                                                   Output_Hz);
            end;

         when 16#05# =>  --  5xy: tone porta + vol slide
            if Tick > 0 then
               Slide_Period_Toward_Target;
               declare
                  P : constant Effect_Param :=
                        (if Param /= 0 then Param
                         else Effect_Param (Ch.Mem_Vol_Slide));
               begin
                  Apply_Vol_Slide (P);
               end;
            end if;

         when 16#06# =>  --  6xy: vibrato + vol slide
            if Tick > 0 then
               Ch.Vibrato_Phase :=
                 (Ch.Vibrato_Phase + Ch.Vibrato_Speed * 4) mod 256;
               declare
                  Dlt : constant Float :=
                    Vibrato_Delta (Ch.Vibrato_Wave_Form,
                                   Ch.Vibrato_Phase,
                                   Ch.Vibrato_Depth);
                  Vp : Float;
               begin
                  if S.Linear_Freq then Vp := Ch.Period + Dlt;
                  else Vp := Ch.Period * (2.0 ** (Dlt / (12.0 * 64.0)));
                  end if;
                  Ch.Phase_Inc := Compute_Phase_Inc (Vp, S.Linear_Freq, Output_Hz);
               end;
               declare
                  P : constant Effect_Param :=
                        (if Param /= 0 then Param
                         else Effect_Param (Ch.Mem_Vol_Slide));
               begin
                  Apply_Vol_Slide (P);
               end;
            end if;

         when 16#07# =>  --  7xy: tremolo
            if Tick > 0 then
               Ch.Tremolo_Phase :=
                 (Ch.Tremolo_Phase + Ch.Tremolo_Speed * 4) mod 256;
            end if;
            Ch.Tremolo_Offset :=
              Tremolo_Delta (Ch.Tremolo_Wave_Form,
                             Ch.Tremolo_Phase,
                             Ch.Tremolo_Depth) / 64.0;

         when 16#08# =>  --  8xx: set panning
            Ch.Panning := (Float (Param) - 128.0) / 128.0;

         when Effect_Vol_Slide =>
            if Tick > 0 then
               declare
                  P : constant Effect_Param :=
                        (if Param /= 0 then Param
                         else Effect_Param (Ch.Mem_Vol_Slide));
               begin
                  Apply_Vol_Slide (P);
               end;
            end if;

         when Effect_Extended =>
            declare
               Sub  : constant Natural := Natural (Shift_Right (Param, 4));
               Prm  : constant Natural := Natural (Param and 16#0F#);
            begin
               case Sub is
                  when 16#4# =>  --  E4x: set vibrato waveform
                     case Prm is
                        when 0 | 4 => Ch.Vibrato_Wave_Form := Channel_State.Sine;
                        when 1 | 5 => Ch.Vibrato_Wave_Form := Channel_State.Ramp_Down;
                        when 2 | 6 => Ch.Vibrato_Wave_Form := Channel_State.Square;
                        when 3 | 7 => Ch.Vibrato_Wave_Form := Channel_State.Ramp_Up;
                        when others => null;
                     end case;
                  when 16#5# =>  --  E5x: set finetune
                     declare
                        Fine : constant Integer :=
                          (if Prm >= 8 then Integer (Prm) - 16
                                       else Integer (Prm)) * 16;
                        N    : constant Integer := Integer (Ch.Note) - 1;
                     begin
                        if Ch.Note in 1 .. 96 then
                           if S.Linear_Freq then
                              Ch.Period :=
                                Float (10 * 12 * 16 * 4 - N * 64)
                                - Float (Fine) / 2.0;
                           else
                              declare
                                 NC : constant Note_Value :=
                                   Note_Value'Max (1, Note_Value'Min (96,
                                     Note_Value (N + 1)));
                              begin
                                 Ch.Period :=
                                   Float (Mod_Format.Amiga_Periods (NC))
                                   * (2.0 ** (Float (-Fine) / (128.0 * 12.0)));
                              end;
                           end if;
                           Update_Freq;
                        end if;
                     end;
                  when 16#7# =>  --  E7x: set tremolo waveform
                     case Prm is
                        when 0 | 4 => Ch.Tremolo_Wave_Form := Channel_State.Sine;
                        when 1 | 5 => Ch.Tremolo_Wave_Form := Channel_State.Ramp_Down;
                        when 2 | 6 => Ch.Tremolo_Wave_Form := Channel_State.Square;
                        when 3 | 7 => Ch.Tremolo_Wave_Form := Channel_State.Ramp_Up;
                        when others => null;
                     end case;
                  when 16#8# =>  --  E8x: set panning
                     Ch.Panning := Float (Prm) / 7.5 - 1.0;
                  when 16#9# =>  --  E9x: retrigger every x ticks
                     if Prm > 0 and then Tick mod Prm = 0 and then Tick > 0 then
                        Ch.Position := 0.0;
                     end if;
                  when 16#C# =>  --  ECx: cut note on tick x
                     if Tick = Prm then
                        Ch.Volume := 0.0;
                     end if;
                  when 16#D# =>  --  EDx: delay note (trigger on tick x)
                     if Tick = Prm then
                        Channel_State.Trigger_Note
                          (Ch, S, Cell.Note, Cell.Instrument, Output_Hz);
                     end if;
                  when others => null;
               end case;
            end;

         --  14 (Txx) - XM set BPM; update caller's BPM variable
         when 16#14# =>
            if Param >= 32 then
               Current_BPM := BPM_Value'Max (BPM_Value'First,
                 BPM_Value'Min (BPM_Value'Last, BPM_Value (Param)));
            end if;

         --  19 (Pxx) - XM panning slide
         when 16#19# =>
            if Tick > 0 then
               declare
                  Up   : constant Natural := Natural (Shift_Right (Param, 4));
                  Down : constant Natural := Natural (Param and 16#0F#);
               begin
                  if Up /= 0 then
                     Ch.Panning := Float'Min (1.0,
                                     Ch.Panning + Float (Up) / 128.0);
                  elsif Down /= 0 then
                     Ch.Panning := Float'Max (-1.0,
                                     Ch.Panning - Float (Down) / 128.0);
                  end if;
               end;
            end if;

         when others => null;
      end case;

      --  Volume column per-tick effects (XM)
      declare
         V : constant Natural := Cell.Volume;
      begin
         if V in 16#60# .. 16#6F# and then Tick > 0 then  --  vol slide down
            Ch.Volume := Float'Max (0.0,
                           Ch.Volume - Float (V mod 16) / 64.0);
         elsif V in 16#70# .. 16#7F# and then Tick > 0 then  --  vol slide up
            Ch.Volume := Float'Min (1.0,
                           Ch.Volume + Float (V mod 16) / 64.0);
         elsif V in 16#B0# .. 16#BF# then  --  vibrato with depth from nibble
            if Tick > 0 then
               Ch.Vibrato_Phase :=
                 (Ch.Vibrato_Phase + Ch.Vibrato_Speed * 4) mod 256;
            end if;
            declare
               Dlt : constant Float :=
                 Vibrato_Delta (Ch.Vibrato_Wave_Form,
                                Ch.Vibrato_Phase, V mod 16);
               Vp : Float;
            begin
               if S.Linear_Freq then Vp := Ch.Period + Dlt;
               else Vp := Ch.Period * (2.0 ** (Dlt / (12.0 * 64.0)));
               end if;
               Ch.Phase_Inc := Compute_Phase_Inc (Vp, S.Linear_Freq, Output_Hz);
            end;
         elsif V in 16#D0# .. 16#DF# and then Tick > 0 then  --  pan slide left
            Ch.Panning := Float'Max (-1.0,
                            Ch.Panning - Float (V mod 16) / 128.0);
         elsif V in 16#E0# .. 16#EF# and then Tick > 0 then  --  pan slide right
            Ch.Panning := Float'Min (1.0,
                            Ch.Panning + Float (V mod 16) / 128.0);
         elsif V in 16#F0# .. 16#FF# and then Tick > 0 then  --  tone porta
            Slide_Period_Toward_Target;
         end if;
      end;

      --  Auto-vibrato (instrument-level, XM)
      if S.Format = Song.Format_XM and then Ch.Instrument /= 0 then
         declare
            Inst : Song.Instrument renames S.Instruments (Ch.Instrument);
         begin
            if Inst.Vib_Depth > 0 then
               Ch.Auto_Vib_Phase :=
                 (Ch.Auto_Vib_Phase + Inst.Vib_Rate) mod 256;
               if Inst.Vib_Sweep > 0 then
                  Ch.Auto_Vib_Amp := Float'Min (Float (Inst.Vib_Depth),
                    Ch.Auto_Vib_Amp
                    + Float (Inst.Vib_Depth) / Float (Inst.Vib_Sweep));
               else
                  Ch.Auto_Vib_Amp := Float (Inst.Vib_Depth);
               end if;
               declare
                  P        : constant Natural := Ch.Auto_Vib_Phase mod 256;
                  Wave_Val : Float;
                  AV_Delta : Float;
               begin
                  case Inst.Vib_Type is
                     when 0      => Wave_Val := Float (Sine_Tab (P)) / 127.0;
                     when 1      => Wave_Val := (if P < 128 then 1.0 else -1.0);
                     when 2      => Wave_Val := 1.0 - Float (P) / 128.0;
                     when 3      => Wave_Val := Float (P) / 128.0 - 1.0;
                     when others => Wave_Val := 0.0;
                  end case;
                  AV_Delta := Wave_Val * Ch.Auto_Vib_Amp / 64.0;
                  if S.Linear_Freq then
                     Ch.Phase_Inc := Compute_Phase_Inc
                       (Ch.Period + AV_Delta, S.Linear_Freq, Output_Hz);
                  else
                     Ch.Phase_Inc := Compute_Phase_Inc
                       (Ch.Period * (2.0 ** (AV_Delta / (12.0 * 64.0))),
                        S.Linear_Freq, Output_Hz);
                  end if;
               end;
            end if;
         end;
      end if;

   end Process_Effects;

end Sequencer_Engine;
