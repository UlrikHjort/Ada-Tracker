-- ***************************************************************************
--                      Tracker - Channel State
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
with Mod_Format;

package body Channel_State is

   use Ada.Numerics.Elementary_Functions;

   --  ---------------------------------------------------------------
   --  Protected body
   --  ---------------------------------------------------------------

   protected body Shared_State is

      procedure Update_Channel (Idx : Channel_Index; Ch : Channel) is
      begin
         Channels (Idx) := Ch;
      end Update_Channel;

      function Get_Channel (Idx : Channel_Index) return Channel is
      begin
         return Channels (Idx);
      end Get_Channel;

      procedure Set_Num_Channels (N : Positive) is
      begin
         Active_Count := N;
      end Set_Num_Channels;

      function Num_Channels return Positive is
      begin
         return Active_Count;
      end Num_Channels;

      procedure Mute (Idx : Channel_Index; Value : Boolean) is
      begin
         Mute_Flags (Idx) := Value;
      end Mute;

      function Muted (Idx : Channel_Index) return Boolean is
      begin
         return Mute_Flags (Idx);
      end Muted;

      procedure Reset_Channels is
      begin
         Channels := [others => <>];
      end Reset_Channels;

   end Shared_State;

   --  ---------------------------------------------------------------
   --  Frequency -> phase increment
   --
   --  MOD / XM-Amiga:  hz = Amiga_Clock / (2 * period)
   --  XM-linear:       period is internal note index (see below)
   --                   hz = 8363 * 2^((6*12*16*4 - period) / (12*16*4))
   --  Phase_Inc = hz / Output_Hz  (samples of source per output sample)
   --  ---------------------------------------------------------------

   function Compute_Phase_Inc
     (Period    : Float;
      Linear    : Boolean;
      Output_Hz : Positive) return Float
   is
      Hz : Float;
   begin
      if Period <= 0.0 then return 0.0; end if;

      if Linear then
         --  XM linear table
         declare
            Exponent : constant Float :=
              (6.0 * 12.0 * 16.0 * 4.0 - Period) / (12.0 * 16.0 * 4.0);
         begin
            Hz := 8363.0 * (2.0 ** Exponent);
         end;
      else
         --  Amiga / MOD table
         Hz := Float (Amiga_Clock) / (2.0 * Period);
      end if;

      return Hz / Float (Output_Hz);
   end Compute_Phase_Inc;

   --  ---------------------------------------------------------------
   --  Trigger_Note
   --  ---------------------------------------------------------------

   procedure Trigger_Note
     (Ch        : in out Channel;
      S         : Song.Song_Type;
      Note      : Note_Value;
      Instr     : Instrument_Index;
      Output_Hz : Positive)
   is
   begin
      if Note = Note_Key_Off then
         Ch.Key_On := False;
         return;
      end if;

      if Note = Note_Empty and Instr = 0 then
         return;  --  nothing to do
      end if;

      --  Update instrument if given
      if Instr /= 0 then
         Ch.Instrument := Instr;
      end if;

      if Ch.Instrument = 0 then return; end if;

      --  Determine which sample to use
      declare
         Inst : Song.Instrument renames
                  S.Instruments (Ch.Instrument);
         Note_0 : constant Natural :=
                    (if Note in 1 .. 96 then Natural (Note) - 1 else 0);
      begin
         Ch.Sample_Slot := Inst.Map (Note_0);

         declare
            Samp : Song.Sample renames Inst.Samples (Ch.Sample_Slot);
         begin
            if Note /= Note_Empty then
               Ch.Note          := Note;
               Ch.Active        := True;
               Ch.Key_On        := True;
               Ch.Position      := 0.0;
               Ch.Play_Forward  := True;
               Ch.Fadeout_Vol   := 1.0;
               Ch.Tremolo_Offset := 0.0;

               --  Volume from sample; later modulated by envelope + effects
               Ch.Volume  := Float (Samp.Base_Volume) / 64.0;

               --  Panning: center for MOD, sample panning for XM
               Ch.Panning := Float (Samp.Panning) / 128.0;

               --  Compute period / frequency
               declare
                  Semitones  : constant Integer :=
                                 Integer (Note) - 1 + Samp.Relative_Note;
                  Fine       : constant Integer := Samp.Finetune;
               begin
                  if S.Linear_Freq then
                     --  XM linear: period = 10*12*16*4 - semitones*64 - fine/2
                     Ch.Period :=
                       Float (10 * 12 * 16 * 4 - Semitones * 64)
                       - Float (Fine) / 2.0;
                  else
                     --  Amiga table: find base period for note, apply finetune
                     declare
                        Note_Clamped : constant Note_Value :=
                          Note_Value'Max (1, Note_Value'Min (96,
                            Note_Value (Semitones + 1)));
                        Base_Period : constant Float :=
                          Float (Mod_Format.Amiga_Periods (Note_Clamped));
                        Fine_Factor : constant Float :=
                          2.0 ** (Float (-Fine) / (128.0 * 12.0));
                     begin
                        Ch.Period := Base_Period * Fine_Factor;
                     end;
                  end if;
               end;

               Ch.Phase_Inc := Compute_Phase_Inc (Ch.Period, S.Linear_Freq,
                                                  Output_Hz);

               --  Reset envelopes
               Ch.Vol_Env := (Position    => 0,
                              Point_Index => 0,
                              Value       => 64.0,
                              Sustained   => False,
                              Done        => not S.Instruments (Ch.Instrument)
                                               .Vol_Env.Enabled);
               Ch.Pan_Env := (Position    => 0,
                              Point_Index => 0,
                              Value       => 32.0,
                              Sustained   => False,
                              Done        => not S.Instruments (Ch.Instrument)
                                               .Pan_Env.Enabled);
               Ch.Auto_Vib_Phase := 0;
               Ch.Auto_Vib_Amp   := 0.0;

               --  IT filter: reset state and (re)compute coeficients
               Ch.Filter_S1 := 0.0;
               Ch.Filter_S2 := 0.0;
               Ch.Flt_Env := (Position    => 0,
                              Point_Index => 0,
                              Value       => 32.0,   --  centre = no modulation
                              Sustained   => False,
                              Done        => not Inst.Flt_Env.Enabled);
               if Inst.Flt_Cutoff < 128 then
                  Update_Filter (Ch, Inst.Flt_Cutoff, Inst.Flt_Resonance,
                                 Output_Hz);
               else
                  Ch.Filter_Cutoff := 128;  --  bypass
               end if;
            end if;
         end;
      end;
   end Trigger_Note;

   --  ---------------------------------------------------------------
   --  Advance_Envelope
   --  Linear interpolation between consecutive envelope points.
   --  ---------------------------------------------------------------

   procedure Advance_Envelope
     (State  : in out Envelope_State;
      Env    : Song.Envelope;
      Key_On : Boolean)
   is
   begin
      if State.Done or Env.Num_Points = 0 then return; end if;

      --  Sustain hold
      if Env.Has_Sustain and Key_On
        and State.Point_Index = Env.Sustain_Pt
      then
         State.Value :=
           Float (Env.Points (Env.Sustain_Pt).Value);
         State.Sustained := True;
         return;
      end if;

      State.Sustained := False;

      --  Loop back
      if Env.Has_Loop
        and State.Point_Index >= Env.Loop_End
      then
         State.Point_Index := Env.Loop_Start;
         State.Position    :=
           Env.Points (Env.Loop_Start).Tick;
      end if;

      --  Past last point
      if State.Point_Index >= Env.Num_Points - 1 then
         State.Value := Float (Env.Points (Env.Num_Points - 1).Value);
         State.Done  := True;
         return;
      end if;

      --  Interpolate between Point_Index and Point_Index+1
      declare
         P0    : Song.Env_Point renames Env.Points (State.Point_Index);
         P1    : Song.Env_Point renames Env.Points (State.Point_Index + 1);
         Span  : constant Natural := P1.Tick - P0.Tick;
         Pos   : constant Natural := State.Position - P0.Tick;
         T     : Float;
      begin
         if Span = 0 then
            State.Value := Float (P1.Value);
         else
            T           := Float (Pos) / Float (Span);
            State.Value := Float (P0.Value) * (1.0 - T)
                         + Float (P1.Value) * T;
         end if;

         State.Position := State.Position + 1;

         --  Advance to next segment when we reach it
         if State.Position >= P1.Tick then
            State.Point_Index := State.Point_Index + 1;
         end if;
      end;
   end Advance_Envelope;

   --  ---------------------------------------------------------------
   --  Update_Filter
   --  Precompute state-variable filter coefficients from Cutoff / Resonance.
   --
   --  SVF (Chamberlin):
   --    f = 2 * sin(pi * fc / fs)   -- drive coefficient  (0 < f < 2)
   --    q = 1 - resonance/128        -- damping            (0 < q <= 1)
   --  Per sample:
   --    hp = in - q*s1 - s2
   --    bp = f*hp + s1   (s1 := bp)
   --    lp = f*bp + s2   (s2 := lp)
   --    output = lp
   --  ---------------------------------------------------------------

   procedure Update_Filter
     (Ch        : in out Channel;
      Cutoff    : Natural;
      Resonance : Natural;
      Output_Hz : Positive)
   is
      use Ada.Numerics;
      --  Map cutof 0-127 to Hz: 110 * 2^(cutoff * 5.5 / 128 - 0.5)
      FC_Hz    : constant Float :=
                   110.0 * 2.0 ** (Float (Cutoff) * 5.5 / 128.0 - 0.5);
      --  Clamp below Nyquist for filter stability
      FC_Safe  : constant Float :=
                   Float'Min (FC_Hz, Float (Output_Hz) * 0.499);
      F        : constant Float :=
                   2.0 * Sin (Pi * FC_Safe / Float (Output_Hz));
      --  Damping: high resonance -> low damping; clamp to avoid instability
      Q        : constant Float :=
                   Float'Max (0.01, 1.0 - Float (Resonance) / 128.0);
   begin
      Ch.Filter_Cutoff    := Cutoff;
      Ch.Filter_Resonance := Resonance;
      Ch.Filter_F         := Float'Max (0.0001, Float'Min (1.99, F));
      Ch.Filter_Q         := Q;
   end Update_Filter;

end Channel_State;
