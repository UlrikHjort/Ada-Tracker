-- ***************************************************************************
--                      Tracker - Mixer
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
--  Mixer
--  Real-time audio mixer - runs inside the SDL2 audio callback thread.
--
--  The callback snapshots Channel_State at the start of each buffer,
--  mixes all active channels using linear-interpolated sample playback,
--  writes stereo signed-16 PCM, then writes back updated playback positions.
--
--  Shared_State (from Channel_State) is the only synchronisation point
--  between this callback and the Sequencer task.

with Tracker_Types;  use Tracker_Types;
with Channel_State;
with Song;
with SDL2;
with System;
with Interfaces;     use Interfaces;
with Interfaces.C;   use Interfaces.C;

--  Sequencer is NOT included here to avoid circularity;
--  Shared_State_Ptr comes from Channel_State.

package Mixer is

   --  ---------------------------------------------------------------
   --  Output format
   --  ---------------------------------------------------------------
   Output_Sample_Rate : constant := 44_100;  --  Hz
   Output_Buffer_Frames : constant := 512;   --  frames per callback (~11 ms)
   Output_Channels    : constant := 2;       --  stereo

   --  ---------------------------------------------------------------
   --  Initialise / teardown
   --  ---------------------------------------------------------------
   procedure Init
     (Song_Data  : Song.Song_Type;
      State      : Channel_State.Shared_State_Ptr;
      Device     : out SDL2.SDL_AudioDeviceID);
   --  Opens an SDL2 audio device and installs the callback.
   --  Song_Data and State must remain valid for the lifetime of the device.

   procedure Shutdown (Device : SDL2.SDL_AudioDeviceID);

   --  ---------------------------------------------------------------
   --  SDL2 audio callback (exported so SDL2 can call it directly)
   --  ---------------------------------------------------------------
   procedure Audio_Callback
     (Userdata   : System.Address;
      Stream_Ptr : System.Address;
      Len        : int)
     with Export, Convention => C, External_Name => "tracker_audio_cb";

   --  ---------------------------------------------------------------
   --  VU meter (read by the UI after each callback)
   --  Protected so the UI thread can sample it safely.
   --  ---------------------------------------------------------------
   type VU_Array is array (Channel_Index range 0 .. 31) of Float;

   protected VU_Meter is
      procedure Set (Ch : Channel_Index; Level : Float);
      function  Get (Ch : Channel_Index) return Float;
      function  Peaks return VU_Array;
   private
      Levels : VU_Array := [others => 0.0];
   end VU_Meter;

   --  ---------------------------------------------------------------
   --  Per-channel active instrument snapshot (read by UI each frame)
   --  ---------------------------------------------------------------
   type Instr_Array is array (Channel_Index range 0 .. 31) of Instrument_Index;

   protected Active_Channels is
      procedure Set_Instr  (Ch : Channel_Index; I : Instrument_Index);
      function  Get_Instrs return Instr_Array;
   private
      Instrs : Instr_Array := [others => 0];
   end Active_Channels;

   --  ---------------------------------------------------------------
   --  Mix one channel into a stereo accumulator pair.
   --  Can be called offline (e.g. from Wav_Export) without SDL2.
   --  Ch is updated in place (position / loop state advanced).
   --  ---------------------------------------------------------------
   procedure Mix_Channel
     (Ch      : in out Channel_State.Channel;
      Samp    : Song.Sample;
      L, R    : in out Float);

   --  ---------------------------------------------------------------
   --  Oscilloscope ring buffer (mixed mono, written by audio callback)
   --  UI reads a snapshot each frame for waveform display.
   --  ---------------------------------------------------------------
   Osc_Size : constant := 512;
   type Osc_Buffer is array (0 .. Osc_Size - 1) of Float;

   protected Oscilloscope is
      procedure Write (Sample : Float);
      function  Snapshot return Osc_Buffer;
   private
      Buffer    : Osc_Buffer := [others => 0.0];
      Write_Pos : Natural    := 0;
   end Oscilloscope;

end Mixer;
