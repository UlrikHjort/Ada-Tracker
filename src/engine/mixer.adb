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
with Spectrum;

package body Mixer is

   use Song;
   use Channel_State;

   --  ---------------------------------------------------------------
   --  Module-level state accesed by the callback.
   --  Set once in Init; read-only after that from the callback thread.
   --  ---------------------------------------------------------------
   Song_Ptr  : access Song.Song_Type          := null;
   State_Ptr : Channel_State.Shared_State_Ptr := null;

   --  ---------------------------------------------------------------
   --  VU Meter body
   --  ---------------------------------------------------------------

   --  ---------------------------------------------------------------
--  Oscilloscope body
--  ---------------------------------------------------------------

   protected body Oscilloscope is
      procedure Write (Sample : Float) is
      begin
         Buffer (Write_Pos) := Sample;
         Write_Pos := (Write_Pos + 1) mod Osc_Size;
      end Write;

      function Snapshot return Osc_Buffer is
         Result : Osc_Buffer;
      begin
         for I in 0 .. Osc_Size - 1 loop
            Result (I) := Buffer ((Write_Pos + I) mod Osc_Size);
         end loop;
         return Result;
      end Snapshot;
   end Oscilloscope;

   --  ---------------------------------------------------------------
   --  Active_Channels body
   --  ---------------------------------------------------------------

   protected body Active_Channels is
      procedure Set_Instr (Ch : Channel_Index; I : Instrument_Index) is
      begin
         Instrs (Ch) := I;
      end Set_Instr;

      function Get_Instrs return Instr_Array is
      begin
         return Instrs;
      end Get_Instrs;
   end Active_Channels;

   --  ---------------------------------------------------------------
   --  VU Meter body
   --  ---------------------------------------------------------------

   protected body VU_Meter is
      procedure Set (Ch : Channel_Index; Level : Float) is
      begin
         Levels (Ch) := Level;
      end Set;

      function Get (Ch : Channel_Index) return Float is
      begin
         return Levels (Ch);
      end Get;

      function Peaks return VU_Array is
      begin
         return Levels;
      end Peaks;
   end VU_Meter;

   --  ---------------------------------------------------------------
   --  Init / Shutdown
   --  ---------------------------------------------------------------

   procedure Init
     (Song_Data  : Song.Song_Type;
      State      : Channel_State.Shared_State_Ptr;
      Device     : out SDL2.SDL_AudioDeviceID)
   is
      use SDL2;
      Desired  : aliased SDL_AudioSpec;
      Obtained : aliased SDL_AudioSpec;
   begin
      Song_Ptr  := Song_Data'Unrestricted_Access;
      State_Ptr := State;

      Desired.Freq     := Output_Sample_Rate;
      Desired.Format   := AUDIO_S16SYS;
      Desired.Channels := Unsigned_8 (Output_Channels);
      Desired.Samples  := Unsigned_16 (Output_Buffer_Frames);
      Desired.Callback := Audio_Callback'Access;
      Desired.Userdata := System.Null_Address;

      Device := SDL_OpenAudioDevice
        (Device          => System.Null_Address,
         Is_Capture      => 0,
         Desired         => Desired'Access,
         Obtained        => Obtained'Access,
         Allowed_Changes => SDL_AUDIO_ALLOW_FREQUENCY_CHANGE);

      --  Un-pause immediately to start receiving callbacks
      if Device /= 0 then
         SDL_PauseAudioDevice (Device, 0);
      end if;
   end Init;

   procedure Shutdown (Device : SDL2.SDL_AudioDeviceID) is
   begin
      SDL2.SDL_PauseAudioDevice (Device, 1);
      SDL2.SDL_CloseAudioDevice (Device);
      Song_Ptr  := null;
      State_Ptr := null;
   end Shutdown;

   --  ---------------------------------------------------------------
   --  Mix one channel into a Left/Right accumulator pair.
   --  Ch is a local copy; updated Position and Phase-state are returned.
   --  ---------------------------------------------------------------

   procedure Mix_Channel
     (Ch      : in out Channel_State.Channel;
      Samp    : Song.Sample;
      L, R    : in out Float)
   is


      Data    : Song.Float_Array renames Samp.Data.all;
      Len     : constant Natural := Data'Length;
      Pos     : Float            := Float'Max (0.0, Ch.Position);  -- guard against negative
      Inc     : constant Float   := Ch.Phase_Inc;

      --  Clamp helper
      function Clamp (V, Lo, Hi : Float) return Float is
        (Float'Max (Lo, Float'Min (Hi, V)));

      --  4-point cubic Hermite (Catmull-Rom) interpolation
      function Interpolate (P : Float) return Float is
         I1 : constant Natural :=
                Natural'Min (Natural (Float'Floor (P)), Len - 1);
         I0 : constant Natural := (if I1 > 0        then I1 - 1 else 0);
         I2 : constant Natural := Natural'Min (I1 + 1, Len - 1);
         I3 : constant Natural := Natural'Min (I1 + 2, Len - 1);
         T  : constant Float   := P - Float'Floor (P);
         P0 : constant Float   := Data (I0);
         P1 : constant Float   := Data (I1);
         P2 : constant Float   := Data (I2);
         P3 : constant Float   := Data (I3);
      begin
         --  Horner form of Catmull-Rom spline
         return P1 + 0.5 * T * (P2 - P0
           + T * (2.0 * P0 - 5.0 * P1 + 4.0 * P2 - P3
           + T * (3.0 * (P1 - P2) + P3 - P0)));
      end Interpolate;

      Out_Sample : Float;
      --  Vol_Env.Value is 0-64 (64 = full); initialized to 64 on note-on
      --  so this is correct for both MOD (envelope disabled, Value stays 64)
      --  and XM (envelope modulates it each tick).
      Vol        : constant Float :=
                     Float'Max (0.0, Float'Min (1.0,
                       Ch.Volume + Ch.Tremolo_Offset))
                     * Ch.Fadeout_Vol * (Ch.Vol_Env.Value / 64.0);
      --  Pan envelope: value 0..64, 32=centre; disabled -> stays 32.0 -> 0 offset
      Pan        : constant Float :=
                     Clamp (Ch.Panning + (Ch.Pan_Env.Value - 32.0) / 32.0,
                            -1.0, 1.0);
      Pan_L      : constant Float := Clamp (1.0 - Pan, 0.0, 1.0);
      Pan_R      : constant Float := Clamp (1.0 + Pan, 0.0, 1.0);
   begin
      if not Ch.Active or Samp.Data = null or Len = 0 then
         return;
      end if;

      Out_Sample := Interpolate (Pos) * Vol;

      --  IT resonant lowpass filter (2-pole state-variable, Chamberlin form)
      --  Filter_Cutoff 128 = bypas.  Coefficients precomputed at tick rate.
      if Ch.Filter_Cutoff < 128 and then Ch.Filter_F > 0.0 then
         declare
            F  : constant Float := Ch.Filter_F;
            Q  : constant Float := Ch.Filter_Q;
            HP : constant Float := Out_Sample - Q * Ch.Filter_S1 - Ch.Filter_S2;
            BP : constant Float := F * HP + Ch.Filter_S1;
            LP : constant Float := F * BP + Ch.Filter_S2;
         begin
            Ch.Filter_S1 := BP;
            Ch.Filter_S2 := LP;
            Out_Sample   := LP;
         end;
      end if;

      L := L + Out_Sample * Pan_L;
      R := R + Out_Sample * Pan_R;

      --  Advance position (always forward; ping-pong direction in Play_Forward)
      if Ch.Play_Forward then
         Pos := Pos + Inc;
      else
         Pos := Pos - Inc;
      end if;

      --  Handle loop / end of sample
      case Samp.Loop_Kind is

         when No_Loop =>
            if Pos >= Float (Len) then
               Ch.Active := False;
               Pos       := 0.0;
            end if;

         when Forward_Loop =>
            declare
               LS : constant Float := Float (Samp.Loop_Start);
               LE : constant Float := Float (Samp.Loop_End);
               Span : constant Float := LE - LS;
            begin
               if LE > LS and Pos >= LE then
                  Pos := LS + Float'Remainder (Pos - LS, Span);
               end if;
            end;

         when Ping_Pong_Loop =>
            declare
               LS   : constant Float := Float (Samp.Loop_Start);
               LE   : constant Float := Float (Samp.Loop_End);
            begin
               if LE > LS then
                  if Ch.Play_Forward and Pos >= LE then
                     Pos := LE - (Pos - LE);
                     Ch.Play_Forward := False;
                  elsif not Ch.Play_Forward and Pos <= LS then
                     Pos := LS + (LS - Pos);
                     Ch.Play_Forward := True;
                  end if;
               end if;
            end;

      end case;

      Ch.Position := Pos;
   end Mix_Channel;

   --  ---------------------------------------------------------------
   --  Audio callback
   --  Called from SDL2's audio thread; must be real-time safe.
   --  No blocking, no allocation.
   --  ---------------------------------------------------------------

   procedure Audio_Callback
     (Userdata   : System.Address;
      Stream_Ptr : System.Address;
      Len        : Interfaces.C.int)
   is
      pragma Unreferenced (Userdata);



      --  Map the SDL2 output buffer as a signed-16 array
      Num_Frames  : constant Natural := Natural (Len) / 4;  -- 2 ch * 2 bytes
      Num_Samples : constant Natural := Num_Frames * 2;     -- L + R interleaved

      type S16_Array is array (0 .. Num_Samples - 1) of Interfaces.Integer_16;
      Output : S16_Array;
      for Output'Address use Stream_Ptr;
      pragma Volatile (Output);

      --  Local snapshot of channel state (avoid repeated protected calls)
      Num_Ch  : Positive;
      Local   : Channel_Array;

      --  Per-channel VU accumulator
      VU      : VU_Array := [others => 0.0];

      L, R    : Float;
      Scale   : Float    := 28_000.0;

      function Clamp_S16 (V : Float) return Interfaces.Integer_16 is
         Scaled : constant Float := V * Scale;
      begin
         if    Scaled >  32767.0 then return  32767;
         elsif Scaled < -32768.0 then return -32768;
         else  return Interfaces.Integer_16 (Scaled);
         end if;
      end Clamp_S16;

   begin
      if State_Ptr = null or Song_Ptr = null then
         --  Not yet initialised - output silence
         for I in 0 .. Num_Samples - 1 loop
            Output (I) := 0;
         end loop;
         return;
      end if;

      --  Snapshot state
      Num_Ch := State_Ptr.Num_Channels;
      Scale  := 28_000.0 / Float (Num_Ch);
      for I in Channel_Index range 0 .. Channel_Index'Last loop
         Local (I) := State_Ptr.Get_Channel (I);
      end loop;

      --  Mix (song channels + NNA background voices)
      for Frame in 0 .. Num_Frames - 1 loop
         L := 0.0;
         R := 0.0;

         for Ch_Idx in Channel_Index range 0 .. Channel_Index'Last loop
            declare
               Ch   : Channel renames Local (Ch_Idx);
               Inst : Song.Instrument renames
                        Song_Ptr.Instruments (
                          (if Ch.Instrument = 0 then 1 else Ch.Instrument));
               Samp : Song.Sample renames Inst.Samples (Ch.Sample_Slot);
               Muted : constant Boolean :=
                         Ch_Idx < Channel_Index (Num_Ch)
                         and then State_Ptr.Muted (Ch_Idx);
            begin
               if Ch.Active
                  and then not Muted
                  and then Samp.Data /= null
               then
                  Mix_Channel (Ch, Samp, L, R);

                  --  Peak VU for song channels only
                  if Ch_Idx < Channel_Index (Num_Ch) then
                     declare
                        Peak : constant Float := abs (Ch.Volume);
                     begin
                        if Peak > VU (Ch_Idx) then VU (Ch_Idx) := Peak; end if;
                     end;
                  end if;
               end if;
            end;
         end loop;

         declare
            Mono : constant Float := (L + R) * 0.5;
         begin
            Oscilloscope.Write (Mono);
            Spectrum.Capture.Write (Mono);
         end;
         Output (Frame * 2)     := Clamp_S16 (L);
         Output (Frame * 2 + 1) := Clamp_S16 (R);
      end loop;

      --  Write back updated playback positions (all channels)
      for I in Channel_Index range 0 .. Channel_Index'Last loop
         State_Ptr.Update_Channel (I, Local (I));
      end loop;

      --  Publish VU levels + active instruments (song channels only)
      for I in Channel_Index range 0 .. Channel_Index (Num_Ch) - 1 loop
         VU_Meter.Set (I, VU (I));
         Active_Channels.Set_Instr (I, Local (I).Instrument);
      end loop;
   end Audio_Callback;

end Mixer;
