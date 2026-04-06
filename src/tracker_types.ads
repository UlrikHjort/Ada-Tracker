-- ***************************************************************************
--                      Tracker - Tracker Types
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
--  Tracker_Types
--  Fundamental types shared across formats, engine, and UI.

with Interfaces;

package Tracker_Types is

   --  ---------------------------------------------------------------
   --  Note values - unified across MOD and XM.
   --  MOD uses Amiga period values; we convert to this on load.
   --  XM stores 1-96 natively.
   --  ---------------------------------------------------------------
   subtype Note_Value is Natural range 0 .. 97;
   --  0  = empty / no note
   --  1  = C-0, 2 = C#0, 3 = D-0, ... 96 = B-7
   --  97 = Key-Off

   Note_Empty   : constant Note_Value := 0;
   Note_Key_Off : constant Note_Value := 97;

   --  Octave and semitone helpers
   subtype Semitone is Natural range 0 .. 11;
   --  0=C 1=C# 2=D 3=D# 4=E 5=F 6=F# 7=G 7=G# 8=A 9=A# 11=B

   function Note_Semitone (N : Note_Value) return Semitone
     with Pre => N in 1 .. 96;
   function Note_Octave   (N : Note_Value) return Natural
     with Pre => N in 1 .. 96;

   --  ---------------------------------------------------------------
   --  Indices
   --  ---------------------------------------------------------------
   subtype Instrument_Index is Natural range 0 .. 128;
   --  0 = none; MOD supports 1-31, XM 1-128

   subtype Sample_Index is Natural range 0 .. 255;
   --  0 = none

   subtype Channel_Index is Natural range 0 .. 63;
   --  MOD: 4 channels; XM: up to 32; IT: up to 32 + 32 NNA background voices

   subtype Pattern_Index is Natural range 0 .. 255;
   subtype Order_Index   is Natural range 0 .. 255;
   subtype Row_Index     is Natural range 0 .. 255;
   --  MOD: 64 rows/pattern; XM: 1-256 rows/pattern

   --  ---------------------------------------------------------------
   --  Volume
   --  ---------------------------------------------------------------
   subtype Volume_Value is Natural range 0 .. 64;
   --  64 = maximum; matches XM convention (MOD uses 0-64 too)

   --  ---------------------------------------------------------------
   --  Effects
   --  ---------------------------------------------------------------
   subtype Effect_Code   is Interfaces.Unsigned_8;
   subtype Effect_Param  is Interfaces.Unsigned_8;

   --  Common effect codes (shared subset of MOD/XM)
   Effect_None          : constant Effect_Code := 16#00#;
   Effect_Arpeggio      : constant Effect_Code := 16#00#;  --  0xy
   Effect_Porta_Up      : constant Effect_Code := 16#01#;  --  1xx
   Effect_Porta_Down    : constant Effect_Code := 16#02#;  --  2xx
   Effect_Tone_Porta    : constant Effect_Code := 16#03#;  --  3xx
   Effect_Vibrato       : constant Effect_Code := 16#04#;  --  4xy
   Effect_Vol_Slide     : constant Effect_Code := 16#0A#;  --  Axy
   Effect_Jump_To_Order : constant Effect_Code := 16#0B#;  --  Bxx
   Effect_Set_Volume    : constant Effect_Code := 16#0C#;  --  Cxx
   Effect_Pattern_Break : constant Effect_Code := 16#0D#;  --  Dxx
   Effect_Set_Speed     : constant Effect_Code := 16#0F#;  --  Fxx (< 32 = ticks, >= 32 = BPM)

   --  XM-only extended effects go in Effect_Ext (Exy / 14xy in MOD)
   Effect_Extended      : constant Effect_Code := 16#0E#;
   Effect_Set_BPM       : constant Effect_Code := 16#F0#;  -- XM Txx

   --  ---------------------------------------------------------------
   --  Sample storage
   --  ---------------------------------------------------------------
   type Sample_Data_8  is array (Natural range <>) of Interfaces.Integer_8;
   type Sample_Data_16 is array (Natural range <>) of Interfaces.Integer_16;

   type Sample_Depth is (Depth_8, Depth_16);

   type Loop_Type is (No_Loop, Forward_Loop, Ping_Pong_Loop);

   type Sample_Header is record
      Name       : String (1 .. 22);
      Depth      : Sample_Depth  := Depth_8;
      Loop_Kind  : Loop_Type     := No_Loop;
      Loop_Start : Natural       := 0;  --  in samples
      Loop_End   : Natural       := 0;  --  in samples
      Volume     : Volume_Value  := 64;
      Finetune   : Integer range -128 .. 127 := 0;
      --  1/128 semitone; MOD finetune (-8..7) is scaled *16 on load
      Panning    : Natural range 0 .. 255    := 128;
      --  XM raw panning: 0=left, 128=centre, 255=right; MOD default = 128
      Relative_Note : Integer range -96 .. 96 := 0;
   end record;

   --  ---------------------------------------------------------------
   --  A single cell in a pattern
   --  ---------------------------------------------------------------
   type Pattern_Cell is record
      Note       : Note_Value     := Note_Empty;
      Instrument : Instrument_Index := 0;
      Volume     : Natural range 0 .. 255 := 0;
      --  0 = column not set; 1-64 = vol 0-63; >64 = volume effect (XM)
      Effect     : Effect_Code    := Effect_None;
      Param      : Effect_Param   := 0;
   end record;

   --  ---------------------------------------------------------------
   --  Timing
   --  ---------------------------------------------------------------
   subtype BPM_Value   is Natural range 32 .. 255;
   subtype Tick_Value  is Natural range 1  .. 31;

   Default_BPM   : constant BPM_Value  := 125;
   Default_Speed : constant Tick_Value := 6;

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------
   --  Amiga PAL clock used by MOD period -> Hz conversion
   Amiga_Clock : constant := 7_093_789.2;

   function Period_To_Hz (Period : Positive) return Float is
     (Float (Amiga_Clock) / (Float (Period) * 2.0));

private

   function Note_Semitone (N : Note_Value) return Semitone is
     (Semitone ((N - 1) mod 12));

   function Note_Octave (N : Note_Value) return Natural is
     ((N - 1) / 12);

end Tracker_Types;
