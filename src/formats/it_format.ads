-- ***************************************************************************
--                      Tracker - IT Format
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
--  IT_Format
--  ImpulseTracker (.IT) file format structures and loader.
--
--  File header (128 bytes, "IMPM"):
--    [0..3]   "IMPM" magic
--    [4..29]  Song name (26 bytes)
--    [30..31] Pattern row highlight
--    [32..33] OrdNum - order count
--    [34..35] InsNum - instrument count
--    [36..37] SmpNum - sample count
--    [38..39] PatNum - pattern count
--    [40..41] Cwt    - created-with tracker version
--    [42..43] Cmwt   - compatible-with version (>= 0x215 -> new predictor)
--    [44..45] Flags  - bit 2: use instruments; bit 3: linear slides
--    [46..47] Special
--    [48]     Global volume
--    [49]     Mix volume
--    [50]     Initial speed
--    [51]     Initial tempo
--    [52..63] Misc / reserved
--    [64..95] Channel panning (32 bytes; 0=left, 32=centre, 64=right, >=100=disabled)
--    [96..127] Channel volume (32 bytes; 0..64)
--
--  After header:
--    [OrdNum bytes]      Order list (0xFF = end, 0xFE = skip)
--    [InsNum * 4 bytes]  Instrument file offsets (uint32 LE)
--    [SmpNum * 4 bytes]  Sample header file offsets (uint32 LE)
--    [PatNum * 4 bytes]  Pattern data file offsets (uint32 LE)
--
--  Sample header (80 bytes, "IMPS") at its offset:
--    [0..3]   "IMPS"
--    [4..15]  DOS filename (12 bytes)
--    [16]     Reserved
--    [17]     Global volume (0..64)
--    [18]     Flags: bit0=present, bit1=16-bit, bit2=stereo,
--                    bit3=compressed, bit4=loop, bit5=sus-loop, bit6=ping-pong
--    [19]     Default volume (0..64)
--    [20..45] Sample name (26 bytes)
--    [46]     Convert flag (bit0: signed samples)
--    [47]     Default panning (bit7=use, bits0-6=0..64)
--    [48..51] Sample length in frames (uint32 LE)
--    [52..55] Loop start (uint32 LE)
--    [56..59] Loop end (uint32 LE)
--    [60..63] C5Speed - Hz at middle-C (uint32 LE)
--    [64..71] Sustain loop start/end
--    [72..75] Sample data file offset (uint32 LE)
--    [76..79] Vibrato speed / depth / type / rate
--
--  Instrument header (550 bytes, "IMPI") at its offset:
--    [0..3]   "IMPI"
--    [4..15]  DOS filename (12 bytes)
--    [16]     Reserved
--    [17..21] NNA, DCT, DCA, Fadeout(2)
--    [22..31] PPS, PPC, GBV, DFP(pan), RV, RP, TrkVer(2), NOS, reserved
--    [32..57] Instrument name (26 bytes)
--    [58..63] IFC, IFR, MCh, MPr, MBank(2)
--    [64..303] Note/sample table: 120 * (uint8 note, uint8 sample_no)
--    [304..385] Volume envelope (82 bytes)
--    [386..467] Panning envelope (82 bytes)
--    [468..549] Pitch envelope (82 bytes)
--
--  Pattern data at its offset:
--    [0..1]  Packed data length (uint16 LE), not including 8-byte header
--    [2..3]  Number of rows (uint16 LE)
--    [4..7]  Reserved
--    Packed rows: channel variable-byte encoding, row terminated by 0x00.

with Tracker_Types; use Tracker_Types;
with Interfaces;    use Interfaces;

package IT_Format is

   --  ---------------------------------------------------------------
   --  Limits
   --  ---------------------------------------------------------------
   Max_Instruments : constant := 99;
   Max_Samples     : constant := 99;
   Max_Patterns    : constant := 200;
   Max_Channels    : constant := 32;   --  engine limit
   Max_Orders      : constant := 256;

   --  ---------------------------------------------------------------
   --  Sample flags (IMPS offset 18)
   --  ---------------------------------------------------------------
   SFlag_Present   : constant Unsigned_8 := 16#01#;
   SFlag_16Bit     : constant Unsigned_8 := 16#02#;
   SFlag_Stereo    : constant Unsigned_8 := 16#04#;
   SFlag_Compress  : constant Unsigned_8 := 16#08#;
   SFlag_Loop      : constant Unsigned_8 := 16#10#;
   SFlag_Sus_Loop  : constant Unsigned_8 := 16#20#;
   SFlag_Ping_Pong : constant Unsigned_8 := 16#40#;

   --  ---------------------------------------------------------------
   --  In-memory IT sample
   --  ---------------------------------------------------------------
   type IT_Sample_8  is access Sample_Data_8;
   type IT_Sample_16 is access Sample_Data_16;

   type IT_Sample (Depth : Sample_Depth := Depth_8) is record
      Name        : String (1 .. 26)          := [others => ' '];
      Default_Vol : Natural                   := 64;
      Global_Vol  : Natural                   := 64;
      Has_Loop    : Boolean                   := False;
      Ping_Pong   : Boolean                   := False;
      Loop_Start  : Natural                   := 0;
      Loop_End    : Natural                   := 0;
      C5Speed     : Natural                   := 8363;
      Default_Pan : Integer range -128 .. 127 := 0;
      Has_Pan     : Boolean                   := False;
      case Depth is
         when Depth_8  => Data_8  : IT_Sample_8  := null;
         when Depth_16 => Data_16 : IT_Sample_16 := null;
      end case;
   end record;

   type IT_Sample_Array is array (1 .. Max_Samples) of IT_Sample;

   --  ---------------------------------------------------------------
   --  Envelope
   --  ---------------------------------------------------------------
   Max_Env_Points : constant := 25;

   type IT_Env_Node is record
      Tick  : Natural := 0;
      Value : Natural := 0;
   end record;

   type IT_Env_Node_Array is array (0 .. Max_Env_Points - 1) of IT_Env_Node;

   type IT_Envelope is record
      Enabled     : Boolean           := False;
      Has_Loop    : Boolean           := False;
      Has_Sustain : Boolean           := False;
      Is_Filter   : Boolean           := False;  --  bit 7 of flags: pitch -> filter
      Num_Points  : Natural           := 0;
      Loop_Start  : Natural           := 0;
      Loop_End    : Natural           := 0;
      Sus_Start   : Natural           := 0;
      Sus_End     : Natural           := 0;
      Points      : IT_Env_Node_Array;
   end record;

   --  ---------------------------------------------------------------
   --  Instrument
   --  Note map: index 0..119 (IT note), value = 1-based sample no (0=none)
   --  ---------------------------------------------------------------
   type IT_Note_Map is array (0 .. 119) of Natural;

   type IT_Instrument is record
      Name        : String (1 .. 26)          := [others => ' '];
      Global_Vol  : Natural                   := 128;
      Fadeout     : Natural                   := 0;
      NNA         : Natural                   := 0;  --  0=Cut 1=Cont 2=NoteOff 3=Fade
      Default_Pan : Integer range -128 .. 127 := 0;
      Has_Pan     : Boolean                   := False;
      Note_Map    : IT_Note_Map               := [others => 0];
      Vol_Env     : IT_Envelope;
      Pan_Env     : IT_Envelope;
      Flt_Env     : IT_Envelope;              --  pitch/filter envelope
      Flt_Cutoff  : Natural                   := 128;  --  128 = disabled; 0-127 active
      Flt_Resonance : Natural                 := 0;    --  0-127
      Vib_Speed   : Natural                   := 0;
      Vib_Depth   : Natural                   := 0;
      Vib_Sweep   : Natural                   := 0;
      Vib_Type    : Natural                   := 0;
   end record;

   type IT_Instrument_Array is array (1 .. Max_Instruments) of IT_Instrument;

   --  ---------------------------------------------------------------
   --  Pattern storage
   --  ---------------------------------------------------------------
   type IT_Cell_Array is array (Natural range <>) of Pattern_Cell;
   type IT_Cell_Array_Access is access IT_Cell_Array;

   type IT_Pattern is record
      Num_Rows     : Positive              := 64;
      Num_Channels : Positive              := 1;
      Cells        : IT_Cell_Array_Access  := null;
   end record;

   type IT_Pattern_Array is array (0 .. Max_Patterns - 1) of IT_Pattern;

   --  ---------------------------------------------------------------
   --  Per-channel panning: -128 = full left, 0 = centre, 127 = full right
   --  ---------------------------------------------------------------
   subtype Pan_Entry is Integer range -128 .. 127;
   type IT_Channel_Panning is array (0 .. Max_Channels - 1) of Pan_Entry;

   type IT_Mode is (Instrument_Mode, Sample_Mode);

   --  ---------------------------------------------------------------
   --  In-memory IT song
   --  ---------------------------------------------------------------
   type IT_Order_Array is array (0 .. Max_Orders - 1) of Natural;

   type IT_Song is record
      Name            : String (1 .. 26)   := [others => ' '];
      Mode            : IT_Mode            := Sample_Mode;
      Num_Channels    : Positive           := 1;
      Song_Length     : Positive           := 1;
      Num_Instruments : Natural            := 0;
      Num_Samples     : Natural            := 0;
      Num_Patterns    : Natural            := 0;
      BPM             : BPM_Value          := 125;
      Speed           : Tick_Value         := 6;
      Global_Vol      : Natural            := 128;
      Cmwt            : Natural            := 0;
      Orders          : IT_Order_Array     := [others => 0];
      Channel_Pan     : IT_Channel_Panning := [others => 0];
      Instruments     : IT_Instrument_Array;
      Samples         : IT_Sample_Array;
      Patterns        : IT_Pattern_Array;
   end record;

   --  ---------------------------------------------------------------
   --  Loader
   --  ---------------------------------------------------------------
   type Load_Error is (None, File_Not_Found, Invalid_Header, IO_Error);

   procedure Load
     (Path   : in  String;
      Song   : out IT_Song;
      Status : out Load_Error);

   procedure Free (Song : in out IT_Song);

end IT_Format;
