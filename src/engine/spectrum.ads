-- ***************************************************************************
--                      Tracker - Spectrum Analyser
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
--  Spectrum
--  Real-time spectrum analyser using a Cooley-Tukey radix-2 DIT FFT.
--
--  The audio callback feed mono samples into a ring buffer (Capture).
--  The UI calls Compute_Bars each frame to obtain log-spaced magnitude bars.
--
--  FFT_Size   = 2048 -> frequency resolution ~ 21.5 Hz/bin @ 44100 Hz
--  Num_Bars   = 120  -> logarithmically spaced 20 Hz - 20 kHz

package Spectrum is

   FFT_Size    : constant := 2048;
   Num_Bars    : constant := 120;
   Sample_Rate : constant := 44_100;

   type Sample_Buffer is array (0 .. FFT_Size - 1) of Float;

   --  Bar magnitudes in dB, clamped to -80 .. 0.
   type Bar_Array is array (0 .. Num_Bars - 1) of Float;

   --  Ring buffer fed by the audio callback.
   protected Capture is
      procedure Write    (S : Float);
      function  Snapshot return Sample_Buffer;
   private
      Buf : Sample_Buffer := [others => 0.0];
      Pos : Natural        := 0;
   end Capture;

   --  Apply Hann window + FFT + map to Num_Bars log-spaced dB values.
   function Compute_Bars (Buf : Sample_Buffer) return Bar_Array;

end Spectrum;
