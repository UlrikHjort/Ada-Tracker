-- ***************************************************************************
--                      Tracker - S3M Format
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
--  S3M_Format
--  ScreamTracker 3 (.S3M) file format structures and loader.
--
--  Header layout (little-endian, 96 bytes):
--    [0..27]   Song name
--    [28]      0x1A (DOS EOF marker)
--    [29]      File type (16 = module)
--    [30..31]  Reserved
--    [32..33]  OrdNum  - number of orders
--    [34..35]  InsNum  - number of instruments
--    [36..37]  PatNum  - number of patterns
--    [38..39]  Flags
--    [40..41]  Cwtv    - created with tracker version
--    [42..43]  Ffi     - 1=unsigned samples, 2=signed
--    [44..47]  "SCRM"  - magic identifier
--    [48]      Global volume
--    [49]      Initial speed (ticks per row)
--    [50]      Initial tempo (BPM)
--    [51]      Master volume (bit7=stereo)
--    [52]      Ultra click removal
--    [53]      Default panning (0xFC = use per-channel panning table)
--    [54..61]  Reserved
--    [62..63]  Special (paragraph pointer to custom data)
--    [64..95]  Channel settings (32 bytes; bit7=disabled, 0..7=Lch, 8..15=Rch)
--
--  After header:
--    [OrdNum bytes]     Order list (0xFF=end marker, 0xFE=skip)
--    [InsNum * 2 bytes] Instrument paragraph pointers (offset = para * 16)
--    [PatNum * 2 bytes] Pattern paragraph pointers
--    [32 bytes]         Per-channel panning (only if default_panning == 0xFC)
--
--  Each PCM instrument at its paragraph offset (80 bytes):
--    [0]       Type (1 = PCM sample)
--    [1..12]   DOS filename
--    [13]      Sample data paragraph high byte
--    [14..15]  Sample data paragraph low word (LE)
--    [16..19]  Sample length in bytes (LE)
--    [20..23]  Loop begin in bytes (LE)
--    [24..27]  Loop end in bytes (LE)
--    [28]      Default volume (0-64)
--    [29]      Reserved
--    [30]      Packing (0 = unpacked PCM)
--    [31]      Flags (bit0=loop, bit1=stereo, bit2=16-bit)
--    [32..35]  C5Speed - Hz at middle-C (standard = 8363)
--    [36..43]  Reserved
--    [44..71]  Sample name (28 bytes)
--    [72..75]  "SCRS" magic
--
--  Pattern packed format (at paragraph offset):
--    [0..1] Packed data size (Uint16 LE)
--    Rows 0..63, each ended by a 0x00 byte.
--    Cell byte: bits[4:0]=channel, bit5=note+instr, bit6=volume, bit7=effect+param.

with Tracker_Types; use Tracker_Types;
with Interfaces;    use Interfaces;

package S3M_Format is

   --  ---------------------------------------------------------------
   --  Limits
   --  ---------------------------------------------------------------
   Max_Instruments : constant := 99;
   Max_Patterns    : constant := 256;
   Max_Channels    : constant := 32;
   Max_Orders      : constant := 256;
   S3M_Rows        : constant := 64;

   --  ---------------------------------------------------------------
   --  Sample flags (byte 31 of instrument header)
   --  ---------------------------------------------------------------
   Flag_Loop   : constant Unsigned_8 := 16#01#;
   Flag_16Bit  : constant Unsigned_8 := 16#04#;

   --  ---------------------------------------------------------------
   --  In-memory S3M sample
   --  ---------------------------------------------------------------
   type S3M_Sample_8  is access Sample_Data_8;
   type S3M_Sample_16 is access Sample_Data_16;

   type S3M_Sample (Depth : Sample_Depth := Depth_8) is record
      Name       : String (1 .. 28)  := [others => ' '];
      Volume     : Volume_Value       := 64;
      C5Speed    : Natural            := 8363;
      Has_Loop   : Boolean            := False;
      Loop_Start : Natural            := 0;
      Loop_End   : Natural            := 0;
      case Depth is
         when Depth_8  => Data_8  : S3M_Sample_8  := null;
         when Depth_16 => Data_16 : S3M_Sample_16 := null;
      end case;
   end record;

   type S3M_Sample_Array is array (1 .. Max_Instruments) of S3M_Sample;

   --  ---------------------------------------------------------------
   --  Pattern storage
   --  ---------------------------------------------------------------
   type S3M_Cell_Array is array (Natural range <>) of Pattern_Cell;
   type S3M_Cell_Array_Access is access S3M_Cell_Array;

   type S3M_Pattern is record
      Num_Channels : Positive             := 1;
      Cells        : S3M_Cell_Array_Access := null;
      --  Indexed as Cells (Row * Num_Channels + Channel), 0-based; 64 rows fixed
   end record;

   type S3M_Pattern_Array is array (Pattern_Index) of S3M_Pattern;

   --  ---------------------------------------------------------------
   --  Per-channel panning: -128 = full left, 0 = centre, 127 = full right
   --  ---------------------------------------------------------------
   subtype Pan_Entry is Integer range -128 .. 127;
   type S3M_Channel_Panning is array (0 .. Max_Channels - 1) of Pan_Entry;

   --  ---------------------------------------------------------------
   --  In-memory S3M song
   --  ---------------------------------------------------------------
   type S3M_Order_Array is array (0 .. Max_Orders - 1) of Natural;

   type S3M_Song is record
      Name            : String (1 .. 28)     := [others => ' '];
      Num_Channels    : Positive             := 1;
      Song_Length     : Positive             := 1;
      Num_Instruments : Natural              := 0;
      Num_Patterns    : Natural              := 0;
      BPM             : BPM_Value            := 125;
      Speed           : Tick_Value           := 6;
      Orders          : S3M_Order_Array      := [others => 0];
      Channel_Pan     : S3M_Channel_Panning  := [others => 0];
      Instruments     : S3M_Sample_Array;
      Patterns        : S3M_Pattern_Array;
   end record;

   --  ---------------------------------------------------------------
   --  Loader
   --  ---------------------------------------------------------------
   type Load_Error is (None, File_Not_Found, Invalid_Header, IO_Error);

   procedure Load
     (Path   : in  String;
      Song   : out S3M_Song;
      Status : out Load_Error);

   procedure Free (Song : in out S3M_Song);

end S3M_Format;
