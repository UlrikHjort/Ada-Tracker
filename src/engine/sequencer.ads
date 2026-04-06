-- ***************************************************************************
--                      Tracker - Sequencer
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
--  Sequencer
--  Reads the song pattern/order data and drives Channel_State
--  according to BPM + speed timing.
--
--  Runs as an Ada task using Ada.Real_Time for accurate tick timing.
--  Communicates with the mixer via Channel_State.Shared_State.
--
--  Tick rate: 2.5 / BPM seconds per tick.
--  Rows per tick: Speed (default 6).
--  A row is processed on tick 0; all ticks process running effects.

with Tracker_Types; use Tracker_Types;
with Song;
with Channel_State;

package Sequencer is

   --  Re-export for convenience (defined in Channel_State to avoid circularity)
   subtype Shared_State_Ptr is Channel_State.Shared_State_Ptr;

   --  ---------------------------------------------------------------
   --  Playback position (readable by the UI)
   --  ---------------------------------------------------------------
   type Position is record
      Order   : Natural := 0;
      Pattern : Pattern_Index := 0;
      Row     : Row_Index := 0;
      Tick    : Natural := 0;
   end record;

   protected Playback_Pos is
      procedure Set (P : Position);
      function  Get return Position;
   private
      Pos : Position;
   end Playback_Pos;

   --  ---------------------------------------------------------------
   --  Main sequencer task
   --  ---------------------------------------------------------------
   task Sequencer_Task is
      --  Start playback from the beginning
      entry Start
        (S         : Song.Song_Type;
         State     : Shared_State_Ptr;
         Output_Hz : Positive);

      --  Stop and reset
      entry Stop;

      --  Jump to a specific order (e.g. from UI)
      entry Jump_To (Order : Natural);
   end Sequencer_Task;

   --  ---------------------------------------------------------------
   --  Transport state (readable by the UI without touching the task)
   --  ---------------------------------------------------------------
   type Transport_State is (Stopped, Playing, Paused);

   protected Transport is
      procedure Set_State (S : Transport_State);
      function  State return Transport_State;
      procedure Set_BPM   (B : BPM_Value);
      procedure Set_Speed (S : Tick_Value);
      function  BPM   return BPM_Value;
      function  Speed return Tick_Value;
   private
      Current     : Transport_State := Stopped;
      Current_BPM : BPM_Value       := Default_BPM;
      Current_Spd : Tick_Value      := Default_Speed;
   end Transport;

end Sequencer;
