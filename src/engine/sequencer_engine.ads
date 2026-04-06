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
--  Sequencer_Engine
--  Stateless per-row / per-tick helpers shared by the real-time Sequencer
--  task and the offline Wav_Export renderer.
--
--  Trigger_Row   - called once per channel on tick 0 to start notes.
--  Process_Effects - called every tick for running effects.
--
--  Current_BPM is an in-out parameter to Process_Effects so that the
--  caller can update its own BPM state without touching the protected
--  Transport object (needed for the offline renderer).

with Tracker_Types; use Tracker_Types;
with Song;
with Channel_State;

package Sequencer_Engine is

   procedure Trigger_Row
     (Cell      : Tracker_Types.Pattern_Cell;
      Ch        : in out Channel_State.Channel;
      S         : Song.Song_Type;
      Output_Hz : Positive);

   procedure Process_Effects
     (Cell        : Tracker_Types.Pattern_Cell;
      Ch          : in out Channel_State.Channel;
      S           : Song.Song_Type;
      Tick        : Natural;
      Output_Hz   : Positive;
      Current_BPM : in out BPM_Value);
   --  Current_BPM may be updated by the Txx (XM set BPM) effect.

end Sequencer_Engine;
