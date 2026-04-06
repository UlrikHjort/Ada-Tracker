-- ***************************************************************************
--                      Tracker - Song
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
--  Song
--  Unified in-memory song model used by the engine and UI.
--  Both MOD and XM are converted to this representation on load.
--
--  Design notes:
--  - Samples are stored as 32-bit float internally (converted on load)
--    for mixer simplicity; no format-specific code in the hot path.
--  - Envelopes and per-instrument vibrato are present for XM;
--    left at defaults for MOD (MOD has no envelopes).

with Tracker_Types; use Tracker_Types;

package Song is

   --  ---------------------------------------------------------------
   --  Sample (format-neutral, float PCM)
   --  ---------------------------------------------------------------
   type Float_Array is array (Natural range <>) of Float;
   type Float_Array_Access is access Float_Array;
   --  Values in -1.0 .. +1.0

   type Sample is record
      Name          : String (1 .. 22) := [others => ' '];
      Data          : Float_Array_Access := null;
      Loop_Kind     : Loop_Type     := No_Loop;
      Loop_Start    : Natural       := 0;
      Loop_End      : Natural       := 0;
      Base_Volume   : Volume_Value  := 64;
      Finetune      : Integer range -128 .. 127 := 0;
      --  1/128 semitone; MOD finetune (-8..7) is scaled *16 on load
      Relative_Note : Integer range -96 .. 96   := 0;
      Panning       : Integer range -128 .. 127 := 0;
      --  0 = center; MOD has no panning (left to engine)
   end record;

   Max_Samples_Per_Instr : constant := 16;

   type Sample_Array is array (0 .. Max_Samples_Per_Instr - 1) of Sample;

   --  ---------------------------------------------------------------
   --  Envelope
   --  ---------------------------------------------------------------
   Max_Env_Points : constant := 12;

   type Env_Point is record
      Tick  : Natural := 0;  --  x-axis: ticks from note trigger
      Value : Natural := 0;  --  y-axis: 0-64
   end record;

   type Env_Point_Array is array (0 .. Max_Env_Points - 1) of Env_Point;

   type Envelope is record
      Points      : Env_Point_Array;
      Num_Points  : Natural  := 0;
      Sustain_Pt  : Natural  := 0;
      Loop_Start  : Natural  := 0;
      Loop_End    : Natural  := 0;
      Enabled     : Boolean  := False;
      Has_Sustain : Boolean  := False;
      Has_Loop    : Boolean  := False;
   end record;

   --  ---------------------------------------------------------------
   --  Instrument
   --  ---------------------------------------------------------------
   type Note_Map is array (0 .. 95) of Natural;
   --  Maps note index (0=C-0 .. 95=B-7) to sample slot (0-based).

   type Instrument is record
      Name        : String (1 .. 22) := [others => ' '];
      Num_Samples : Natural          := 0;
      Map         : Note_Map         := [others => 0];
      Vol_Env     : Envelope;
      Pan_Env     : Envelope;
      Flt_Env     : Envelope;                      --  IT filter envelope (Enabled=False if unused)
      Flt_Cutoff  : Natural := 128;                --  IT initia filter cutoff (128 = off)
      Flt_Resonance : Natural := 0;                --  IT initial filter resonance 0-127
      --  Auto-vibrato (XM only; zero = off)
      Vib_Type    : Natural := 0;  --  0=sine 1=square 2=saw 3=inv-saw
      Vib_Sweep   : Natural := 0;
      Vib_Depth   : Natural := 0;
      Vib_Rate    : Natural := 0;
      Fadeout     : Natural := 0;  --  0 = no fadeout (MOD)
      NNA         : Natural := 0;  --  IT: 0=Cut 1=Continue 2=Note-Off 3=Fade
      Samples     : Sample_Array;
   end record;

   Max_Instruments : constant := 128;
   type Instrument_Array is array (1 .. Max_Instruments) of Instrument;

   --  ---------------------------------------------------------------
   --  Pattern
   --  ---------------------------------------------------------------
   type Cell_Array is array (Natural range <>) of Pattern_Cell;
   type Cell_Array_Access is access Cell_Array;

   type Pattern is record
      Num_Rows     : Positive        := 64;
      Num_Channels : Positive        := 4;
      Cells        : Cell_Array_Access := null;
      --  Cells (Row * Num_Channels + Channel), 0-based
   end record;

   function Cell
     (Pat     : Pattern;
      Row     : Row_Index;
      Channel : Channel_Index) return Pattern_Cell;
   --  Returns an empty cell if Pat.Cells is null or indices are out of range.

   Max_Patterns : constant := 256;
   type Pattern_Array is array (Pattern_Index) of Pattern;

   Max_Orders : constant := 256;
   type Order_Array is array (0 .. Max_Orders - 1) of Pattern_Index;

   --  ---------------------------------------------------------------
   --  Song
   --  ---------------------------------------------------------------
   type Format_Kind is (Format_MOD, Format_XM, Format_S3M, Format_IT);

   --  Per-channel panning: -128=full left, 0=centre, 127=full right.
   --  Used by S3M (per-channel default panning).
   type Channel_Pan_Array is array (0 .. 31) of Integer range -128 .. 127;

   type Song_Type is record
      Name         : String (1 .. 20)    := [others => ' '];
      Format       : Format_Kind         := Format_MOD;
      Channel_Pan  : Channel_Pan_Array   := [others => 0];
      Num_Channels : Positive         := 4;
      Song_Length  : Positive         := 1;   --  active entries in Orders
      Restart_Pos  : Natural          := 0;
      BPM          : BPM_Value        := Default_BPM;
      Speed        : Tick_Value       := Default_Speed;
      Linear_Freq  : Boolean          := False;
      --  True for XM with linear frequency table; False = Amiga table
      Orders       : Order_Array      := [others => 0];
      Instruments  : Instrument_Array;
      Patterns     : Pattern_Array;
   end record;

   --  ---------------------------------------------------------------
   --  Loaders - delegate to Mod_Format / XM_Format then convert
   --  ---------------------------------------------------------------
   type Load_Result is (OK, File_Not_Found, Bad_Format, IO_Error);

   procedure Load_MOD
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result);

   procedure Load_XM
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result);

   procedure Load_S3M
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result);

   procedure Load_IT
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result);

   procedure Free (S : in out Song_Type);
   --  Release all sample float data.

end Song;
