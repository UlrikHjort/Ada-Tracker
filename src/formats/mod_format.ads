-- ***************************************************************************
--                      Tracker - MOD Format
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
--  Mod_Format
--  MOD file format structures and loader.
--
--  Supports the 31-instrument "M.K." format (ProTracker) and variants:
--    "M.K." / "M!K!" -- 4 channels, up to 99 patterns
--    "6CHN"          -- 6 channels
--    "8CHN"          -- 8 channels
--    "FLT4"          -- StarTrekker 4ch
--    "FLT8"          -- StarTrekker 8ch
--    "xxCH" / "xxCN" -- generic N-channel
--
--  MOD layout (binary, big-endian):
--    [20]  Song name
--    [31 * 30]  Instrument headers
--    [1]   Song length (number of orders)
--    [1]   Restart position (ignored / set to 127 in older files)
--    [128] Order table (pattern indices)
--    [4]   Tag ("M.K." etc.)
--    [N * 64 * channels * 4]  Pattern data
--    sample data for each instrument

with Tracker_Types; use Tracker_Types;
with Interfaces;    use Interfaces;

package Mod_Format is

   --  ---------------------------------------------------------------
   --  Constants
   --  ---------------------------------------------------------------
   Max_Instruments : constant := 31;
   Rows_Per_Pattern : constant := 64;
   Max_Orders      : constant := 128;
   Max_Channels    : constant := 8;   --  standard MOD variants

   --  ---------------------------------------------------------------
   --  Binary instrument header (exactly 30 bytes, big-endian)
   --  ---------------------------------------------------------------
   type Mod_Instrument_Header is record
      Name        : String (1 .. 22) := [others => ' '];  --  not null-terminated
      Length      : Unsigned_16;               --  in words (*2 = bytes)
      Finetune    : Unsigned_8;                --  lower nibble, signed (-8..7)
      Volume      : Unsigned_8;                --  0-64
      Loop_Start  : Unsigned_16;              --  in words
      Loop_Length : Unsigned_16;              --  in words; 1 = no loop
   end record
     with Size => 30 * 8;

   type Instrument_Header_Array is
     array (1 .. Max_Instruments) of Mod_Instrument_Header;

   --  ---------------------------------------------------------------
   --  Raw 4-byte note cell (big-endian encoding)
   --  Bits:  iiiipppp pppppppp iiiieeff ffffffff
   --    i = instrument (upper + lower nibbles combined -> 0-31)
   --    p = Amiga period (0 = no note)
   --    e = effect code (0-F)
   --    f = effect parameter
   --  ---------------------------------------------------------------
   type Raw_Cell is array (0 .. 3) of Unsigned_8
     with Size => 32;

   --  ---------------------------------------------------------------
   --  Amiga period table (used to convert period -> note value)
   --  Index: note value 1-96 (C-0 .. B-7)
   --  These are standard ProTracker fine-tuned periods for finetune=0
   --  ---------------------------------------------------------------
   type Period_Table is array (Note_Value range 1 .. 96) of Natural;

   Amiga_Periods : constant Period_Table :=
     --  Octave 0: C-0 .. B-0
     [1712, 1616, 1524, 1440, 1356, 1280, 1208, 1140, 1076, 1016,  960,  906,
      --  Octave 1
       856,  808,  762,  720,  678,  640,  604,  570,  538,  508,  480,  453,
      --  Octave 2
       428,  404,  381,  360,  339,  320,  302,  285,  269,  254,  240,  226,
      --  Octave 3
       214,  202,  190,  180,  170,  160,  151,  143,  135,  127,  120,  113,
      --  Octave 4
       107,  101,   95,   90,   85,   80,   75,   71,   67,   63,   60,   56,
      --  Octave 5 (high - some players don't support)
        53,   50,   47,   45,   42,   40,   37,   35,   33,   31,   30,   28,
      --  Octave 6
        27,   25,   24,   22,   21,   20,   19,   18,   17,   16,   15,   14,
      --  Octave 7
        13,   12,   11,   11,   10,   10,    9,    9,    8,    8,    7,    7];

   --  ---------------------------------------------------------------
   --  In-memory representation after loading
   --  ---------------------------------------------------------------
   type Mod_Sample_Data is access Sample_Data_8;

   type Mod_Instrument is record
      Header : Mod_Instrument_Header;
      Data   : Mod_Sample_Data := null;
   end record;

   type Mod_Instrument_Array is
     array (1 .. Max_Instruments) of Mod_Instrument;

   type Mod_Row is array (Natural range <>) of Pattern_Cell;
   type Mod_Row_Access is access Mod_Row;

   --  A pattern: 64 rows * N channels
   type Mod_Pattern is record
      Rows     : Natural := Rows_Per_Pattern;
      Channels : Natural := 4;
      Cells    : Mod_Row_Access := null;
      --  Indexed as Cells (Row * Channels + Channel), 0-based
   end record;

   type Mod_Pattern_Array is array (Pattern_Index) of Mod_Pattern;
   type Mod_Order_Array   is array (0 .. Max_Orders - 1) of Pattern_Index;

   type Mod_Tag is (Tag_MK, Tag_MK_Over, Tag_6CH, Tag_8CH,
                    Tag_FLT4, Tag_FLT8, Tag_Unknown);

   type Mod_Song is record
      Name         : String (1 .. 20) := [others => ' '];
      Tag          : Mod_Tag         := Tag_MK;
      Num_Channels : Positive        := 4;
      Song_Length  : Positive        := 1;    --  number of orders used
      Orders       : Mod_Order_Array := [others => 0];
      Instruments  : Mod_Instrument_Array;
      Patterns     : Mod_Pattern_Array;
      --  Timing defaults
      BPM          : BPM_Value  := 125;
      Speed        : Tick_Value := 6;
   end record;

   --  ---------------------------------------------------------------
   --  Loader
   --  ---------------------------------------------------------------
   type Load_Error is (None, File_Not_Found, Invalid_Header, IO_Error);

   procedure Load
     (Path   : in  String;
      Song   : out Mod_Song;
      Status : out Load_Error);
   --  Reads and parses a MOD file into Song.
   --  Caller owns all allocated sample data (Song.Instruments(i).Data).

   procedure Free (Song : in out Mod_Song);
   --  Releases all heap-allocated sample data.

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------
   function Decode_Cell
     (Raw      : Raw_Cell;
      Channels : Positive) return Pattern_Cell;
   --  Convert a raw 4-byte MOD note cell to a Pattern_Cell.

   function Period_To_Note (Period : Natural) return Note_Value;
   --  Find the closest note for a given Amiga period value.
   --  Returns Note_Empty if period = 0 or not found.

   function Finetune_Signed (Raw : Unsigned_8) return Integer;
   --  Interpret lower nibble of Raw as a signed 4-bit value (-8..7).

end Mod_Format;
