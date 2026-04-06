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
with Ada.Numerics;
with Ada.Numerics.Elementary_Functions;

package body Spectrum is

   use Ada.Numerics.Elementary_Functions;
   use Ada.Numerics;

   --  ---------------------------------------------------------------
   --  Internal complex type and working array
   --  ---------------------------------------------------------------

   type Complex is record
      Re, Im : Float := 0.0;
   end record;

   type Work_Array is array (0 .. FFT_Size - 1) of Complex;

   --  ---------------------------------------------------------------
   --  Cooley-Tukey radix-2 DIT in-place FFT
   --  Input length must be a power of two (FFT_Size = 2048).
   --  ---------------------------------------------------------------

   procedure Do_FFT (X : in out Work_Array) is
      Rev  : Natural := 0;
      Bit  : Natural;
      Temp : Complex;
      Step : Natural := 1;
      Angle, D_Re, D_Im : Float;
      W_Re, W_Im, NWR   : Float;
      E_Re, E_Im         : Float;
      O_Re, O_Im         : Float;
   begin
      --  Bit-reversal permutation (integer arithmetic, no bitwise ops)
      for I in 1 .. FFT_Size - 2 loop
         Bit := FFT_Size / 2;
         while Rev >= Bit loop
            Rev := Rev - Bit;
            Bit := Bit / 2;
         end loop;
         Rev := Rev + Bit;
         if I < Rev then
            Temp := X (I); X (I) := X (Rev); X (Rev) := Temp;
         end if;
      end loop;

      --  Butterfly stages (log2 2048 = 11 stages)
      while Step < FFT_Size loop
         Angle := -Pi / Float (Step);
         D_Re  := Cos (Angle);
         D_Im  := Sin (Angle);
         declare
            K : Natural := 0;
         begin
            while K < FFT_Size loop
               W_Re := 1.0;
               W_Im := 0.0;
               for M in 0 .. Step - 1 loop
                  E_Re := X (K + M).Re;
                  E_Im := X (K + M).Im;
                  O_Re := W_Re * X (K + M + Step).Re
                        - W_Im * X (K + M + Step).Im;
                  O_Im := W_Re * X (K + M + Step).Im
                        + W_Im * X (K + M + Step).Re;
                  X (K + M).Re        := E_Re + O_Re;
                  X (K + M).Im        := E_Im + O_Im;
                  X (K + M + Step).Re := E_Re - O_Re;
                  X (K + M + Step).Im := E_Im - O_Im;
                  NWR  := W_Re * D_Re - W_Im * D_Im;
                  W_Im := W_Re * D_Im + W_Im * D_Re;
                  W_Re := NWR;
               end loop;
               K := K + 2 * Step;
            end loop;
         end;
         Step := Step * 2;
      end loop;
   end Do_FFT;

   --  ---------------------------------------------------------------
   --  Protected ring buffer
   --  ---------------------------------------------------------------

   protected body Capture is

      procedure Write (S : Float) is
      begin
         Buf (Pos) := S;
         Pos := (Pos + 1) mod FFT_Size;
      end Write;

      function Snapshot return Sample_Buffer is
         Result : Sample_Buffer;
      begin
         for I in 0 .. FFT_Size - 1 loop
            Result (I) := Buf ((Pos + I) mod FFT_Size);
         end loop;
         return Result;
      end Snapshot;

   end Capture;

   --  ---------------------------------------------------------------
   --  Compute_Bars
   --  Hann-window the snapshot, run the FFT, convert to dB,
   --  map to Num_Bars logarithmically-spaced bars.
   --  ---------------------------------------------------------------

   function Compute_Bars (Buf : Sample_Buffer) return Bar_Array is
      Work      : Work_Array;
      Bars      : Bar_Array;
      F_Min     : constant Float := 20.0;
      F_Max     : constant Float := 20_000.0;
      Log_Range : constant Float := Log (F_Max / F_Min);
      --  Normalise by N/2 so a full-scale sine -> magnitude ~ 1.0
      Norm      : constant Float := Float (FFT_Size / 2);
   begin
      --  Apply Hann window
      for I in 0 .. FFT_Size - 1 loop
         declare
            W : constant Float :=
                  0.5 * (1.0 - Cos (2.0 * Pi * Float (I)
                                    / Float (FFT_Size - 1)));
         begin
            Work (I) := (Re => Buf (I) * W, Im => 0.0);
         end;
      end loop;

      Do_FFT (Work);

      --  Map FFT bins to log-spaced display bars
      for B in 0 .. Num_Bars - 1 loop
         declare
            F_Lo    : constant Float :=
                        F_Min * Exp (Log_Range * Float (B)
                                     / Float (Num_Bars));
            F_Hi    : constant Float :=
                        F_Min * Exp (Log_Range * Float (B + 1)
                                     / Float (Num_Bars));
            Bin_Lo  : constant Natural :=
                        Natural'Max (1,
                          Natural (F_Lo * Float (FFT_Size)
                                   / Float (Sample_Rate)));
            Bin_Hi  : constant Natural :=
                        Natural'Min (FFT_Size / 2,
                          Natural (F_Hi * Float (FFT_Size)
                                   / Float (Sample_Rate)) + 1);
            Peak_Sq : Float := 0.0;
            Mag_Sq  : Float;
         begin
            for K in Bin_Lo .. Bin_Hi loop
               Mag_Sq := Work (K).Re ** 2 + Work (K).Im ** 2;
               if Mag_Sq > Peak_Sq then Peak_Sq := Mag_Sq; end if;
            end loop;

            if Peak_Sq > 0.0 then
               Bars (B) := Float'Max (-80.0,
                 10.0 * Log (Peak_Sq) / Log (10.0)
                 - 20.0 * Log (Norm) / Log (10.0));
            else
               Bars (B) := -80.0;
            end if;
         end;
      end loop;

      return Bars;
   end Compute_Bars;

end Spectrum;
