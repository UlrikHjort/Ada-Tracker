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
--  Wav_Export
--  Offline renderer: runs the sequencer engine in a tight loop (no real-time
--  timing) and writes 44100 Hz stereo 16-bit PCM to a WAV file.
--
--  Render stops after the song has played through once (Song_Length orders).
--  A safety cap of Max_Export_Minutes prevents runaway on looping songs.

with Song;

package Wav_Export is

   Max_Export_Minutes : constant := 30;

   procedure Render (S : Song.Song_Type; Path : String);
   --  Write Path as a RIFF/WAV file containing one full pass through the song.
   --  Raises Ada.IO_Exceptions.Name_Error if Path cannot be created.

end Wav_Export;
