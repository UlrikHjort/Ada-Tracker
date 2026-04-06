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
--  Channel_State
--  Per-channel runtime state for the mixer.
--  One instance per channel, updated by the sequencer each tick,
--  read by the audio callback to generate PCM.

with Tracker_Types; use Tracker_Types;
with Song;

package Channel_State is

   --  ---------------------------------------------------------------
   --  Envelope runtime
   --  ---------------------------------------------------------------
   type Envelope_State is record
      Position    : Natural  := 0;   --  current tick within envelope
      Point_Index : Natural  := 0;   --  current segment (between points)
      Value       : Float    := 0.0; --  current interpolated value 0-64
      Sustained   : Boolean  := False;
      Done        : Boolean  := True;
   end record;

   --  ---------------------------------------------------------------
   --  Per-channel state
   --  ---------------------------------------------------------------
   type Vibrato_Wave is (Sine, Square, Ramp_Down, Ramp_Up);
   type Tremolo_Wave is (Sine, Square, Ramp_Down, Ramp_Up);

   type Channel is record
      --  Current trigger
      Active       : Boolean        := False;
      Instrument   : Instrument_Index := 0;  --  1-based; 0 = none
      Sample_Slot  : Natural        := 0;    --  0-based within instrument
      Note         : Note_Value     := Note_Empty;

      --  Playback position in sample data
      Position     : Float          := 0.0;  --  fractional sample index
      Phase_Inc    : Float          := 0.0;  --  samples to advance per output sample
      Play_Forward : Boolean        := True; --  False during ping-pong reverse phase

      --  Volume (0.0-1.0 after scaling)
      Volume       : Float          := 1.0;
      Panning      : Float          := 0.0;  --  -1.0=left, 0=center, +1.0=right
      Fadeout_Vol  : Float          := 1.0;  --  XM fadeout accumulator
      Key_On       : Boolean        := False;

      --  Frequency
      Period       : Float          := 0.0;
      --  Curent period/note index (format-dependent):
      --  MOD/XM-Amiga: Amiga period value (float for slides)
      --  XM-linear: internal note index *64 + finetune

      --  Effects - current values
      Tone_Porta_Target : Float     := 0.0;  --  3xx destination period
      Tone_Porta_Speed  : Natural   := 0;
      Vol_Slide_Speed   : Integer   := 0;    --  positive=up, negative=down
      Porta_Speed       : Natural   := 0;
      Vibrato_Speed     : Natural   := 0;
      Vibrato_Depth     : Natural   := 0;
      Vibrato_Phase     : Natural   := 0;
      Vibrato_Wave_Form : Vibrato_Wave := Sine;
      Tremolo_Speed     : Natural   := 0;
      Tremolo_Depth     : Natural   := 0;
      Tremolo_Phase     : Natural   := 0;
      Tremolo_Wave_Form : Tremolo_Wave := Sine;
      Arpeggio_Note1    : Natural   := 0;    --  0xx upper nibble
      Arpeggio_Note2    : Natural   := 0;    --  0xx lower nibble
      Arpeggio_Phase    : Natural   := 0;    --  0,1,2 cycling per tick

      --  Effect memory (last non-zero param, reused when param=0)
      Mem_Vol_Slide  : Natural := 0;
      Mem_Porta_Up   : Natural := 0;
      Mem_Porta_Down : Natural := 0;
      Mem_Vibrato    : Natural := 0;
      Mem_Tremolo    : Natural := 0;
      Mem_Tone_Porta : Natural := 0;
      Mem_Offset     : Natural := 0;   --  9xx sample offset

      --  XM / IT envelopes
      Vol_Env  : Envelope_State;
      Pan_Env  : Envelope_State;
      Flt_Env  : Envelope_State;

      --  IT resonant lowpass filter
      --  Filter_Cutoff 128 = bypass (disabled).  0-127 = active.
      Filter_Cutoff    : Natural := 128;
      Filter_Resonance : Natural := 0;
      Filter_F         : Float   := 0.0;  --  precomputed SVF f coefficient
      Filter_Q         : Float   := 0.0;  --  precomputed SVF q (damping)
      Filter_S1        : Float   := 0.0;  --  bandpass state
      Filter_S2        : Float   := 0.0;  --  lowpass state

      --  Tremolo output offset (temporary; does not modify stored Volume)
      Tremolo_Offset : Float := 0.0;

      --  XM auto-vibrato (instrument-level)
      Auto_Vib_Phase : Natural := 0;
      Auto_Vib_Amp   : Float   := 0.0;
   end record;

   Max_Song_Channels   : constant := 32;  --  max song channels (pattern data)
   Max_BG_Channels     : constant := 32;  --  NNA background voice pool
   Max_Channels        : constant := Max_Song_Channels + Max_BG_Channels;

   type Channel_Array is array (Channel_Index range 0 .. Max_Channels - 1)
     of Channel;

   type Mute_Array is array (Channel_Index range 0 .. Max_Song_Channels - 1)
     of Boolean;

   --  ---------------------------------------------------------------
   --  Protected object: shared between sequencer task and audio callback
   --  ---------------------------------------------------------------
   protected type Shared_State is

      procedure Update_Channel (Idx : Channel_Index; Ch : Channel);
      function  Get_Channel    (Idx : Channel_Index) return Channel;

      procedure Set_Num_Channels (N : Positive);
      function  Num_Channels return Positive;

      procedure Mute         (Idx : Channel_Index; Value : Boolean);
      function  Muted        (Idx : Channel_Index) return Boolean;

      procedure Reset_Channels;
      --  Set every channel (song + background) to the default inactive state.

   private
      Channels     : Channel_Array;
      Active_Count : Positive   := 4;
      Mute_Flags   : Mute_Array := [others => False];
   end Shared_State;

   --  Named access type - used by Mixer and Sequencer to avoid
   --  anonymous access parameters in task entries.
   type Shared_State_Ptr is access all Shared_State;

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------
   procedure Trigger_Note
     (Ch         : in out Channel;
      S          : Song.Song_Type;
      Note       : Note_Value;
      Instr      : Instrument_Index;
      Output_Hz  : Positive);
   --  Set up Ch for a new note trigger.
   --  Calculates Phase_Inc from note + sample tuning + song frequency table.

   procedure Advance_Envelope
     (State  : in out Envelope_State;
      Env    : Song.Envelope;
      Key_On : Boolean);
   --  Step envelope by one tick, updating State.Value.

   function Compute_Phase_Inc
     (Period     : Float;
      Linear     : Boolean;
      Output_Hz  : Positive) return Float;
   --  Convert a period (Amiga or linear) to samples-per-output-sample increment.

   procedure Update_Filter
     (Ch        : in out Channel;
      Cutoff    : Natural;
      Resonance : Natural;
      Output_Hz : Positive);
   --  Recompute the SVF coeficients Filter_F and Filter_Q from
   --  Cutoff (0-127; 128 = bypass) and Resonance (0-127) and store them
   --  in Ch so that Mix_Channel can use them without calling sin() per sample.

end Channel_State;
