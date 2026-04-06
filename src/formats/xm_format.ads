-- ***************************************************************************
--                      Tracker - XM Format
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
--  XM_Format
--  Extended Module (.XM) file format structures and loader.
--  Specification: FastTracker II XM format, version 1.04
--
--  Layout (little-endian throughout):
--    File header (60 bytes)
--    Patterns  (variable, pattern_count entries)
--    Instruments (variable, instrument_count entries)
--      Each instrument has sub-headers for its samples

with Tracker_Types; use Tracker_Types;
with Interfaces;    use Interfaces;

package XM_Format is

   --  ---------------------------------------------------------------
   --  Limits
   --  ---------------------------------------------------------------
   Max_Channels    : constant := 32;
   Max_Instruments : constant := 128;
   Max_Samples_Per_Instrument : constant := 16;
   Max_Orders      : constant := 256;
   Max_Rows        : constant := 256;

   --  ---------------------------------------------------------------
   --  File header (little-endian, 60 bytes)
   --
   --  Offset  Size  Field
   --  0       17    ID: "Extended Module: "
   --  17      20    Module name
   --  37       1    0x1A (DOS EOF marker)
   --  38      20    Tracker name
   --  58       2    Format version (must be 0x0104)
   --  60       4    Header size (from offset 60, typically 276)
   --  64       2    Song length (number of orders, 1-256)
   --  66       2    Restart position
   --  68       2    Number of channels (2-32, even)
   --  70       2    Number of patterns (0-256)
   --  72       2    Number of instruments (1-128)
   --  74       2    Flags (bit 0: linear frequency table; 0=Amiga)
   --  76       2    Default tempo (ticks per row, 1-31)
   --  78       2    Default BPM
   --  80     256    Pattern order table
   --  ---------------------------------------------------------------
   ID_String   : constant String := "Extended Module: ";
   XM_Version  : constant Unsigned_16 := 16#0104#;

   Flag_Linear_Freq : constant Unsigned_16 := 1;  --  bit 0 of Flags

   type XM_Order_Table is array (0 .. Max_Orders - 1) of Unsigned_8;

   type XM_File_Header is record
      ID            : String (1 .. 17);    --  "Extended Module: "
      Module_Name   : String (1 .. 20);
      DOS_EOF       : Unsigned_8;          --  0x1A
      Tracker_Name  : String (1 .. 20);
      Version       : Unsigned_16;         --  little-endian 0x0104
      Header_Size   : Unsigned_32;
      Song_Length   : Unsigned_16;
      Restart_Pos   : Unsigned_16;
      Num_Channels  : Unsigned_16;
      Num_Patterns  : Unsigned_16;
      Num_Instruments : Unsigned_16;
      Flags         : Unsigned_16;
      Default_Tempo : Unsigned_16;
      Default_BPM   : Unsigned_16;
      Orders        : XM_Order_Table;
   end record;

   --  ---------------------------------------------------------------
   --  Pattern header (little-endian)
   --
   --  Offset  Size  Field
   --  0        4    Pattern header size (9)
   --  4        1    Packing type (always 0)
   --  5        2    Number of rows (1-256)
   --  7        2    Packed pattern data size (0 = empty pattern)
   --  ---------------------------------------------------------------
   type XM_Pattern_Header is record
      Header_Size  : Unsigned_32;
      Packing_Type : Unsigned_8;
      Num_Rows     : Unsigned_16;
      Data_Size    : Unsigned_16;
   end record;

   --  XM note cell packed format:
   --  If bit 7 of first byte is set -> compressed:
   --    byte 0:  1nnnnnnn  (mask bits: 1=note 2=instr 3=vol 4=eff 5=param)
   --    remaining bytes present only if corresponding mask bit is set
   --  Else -> uncompressed: note, instrument, volume, effect, param (5 bytes)
   --
   --  Note: 0=empty, 1-96=C-0..B-7, 97=key-off
   --  Instrument: 0=empty, 1-128
   --  Volume: 0=empty, 0x10-0x50=vol 0-64, 0x60-0xFF=volume effects
   --  Effect: 0-0x24 (Axx uses letter codes: T=tempo, G=glide, etc.)

   --  ---------------------------------------------------------------
   --  Volume column effects (upper nibble when byte > 0x50)
   --  ---------------------------------------------------------------
   Vol_Fx_Fine_Vol_Down  : constant := 16#6#;
   Vol_Fx_Fine_Vol_Up    : constant := 16#7#;
   Vol_Fx_Set_Vibrato    : constant := 16#8#;
   Vol_Fx_Panning        : constant := 16#9#;
   Vol_Fx_Slide_Left     : constant := 16#A#;
   Vol_Fx_Slide_Right    : constant := 16#B#;
   Vol_Fx_Fine_Slide_L   : constant := 16#C#;
   Vol_Fx_Fine_Slide_R   : constant := 16#D#;
   Vol_Fx_Tone_Porta     : constant := 16#F#;

   --  ---------------------------------------------------------------
   --  Instrument header (little-endian)
   --  Note: header_size varies; read it first, then seek past it.
   --  ---------------------------------------------------------------
   Max_Env_Points : constant := 12;

   type Envelope_Point is record
      X : Unsigned_16;  --  time (ticks from note-on)
      Y : Unsigned_16;  --  value 0-64
   end record;

   type Envelope_Points is array (0 .. Max_Env_Points - 1) of Envelope_Point;

   type Keymap is array (0 .. 95) of Unsigned_8;
   --  Maps note (0=C-0 .. 95=B-7) to sample index (0-based within instrument)

   type XM_Instrument_Header is record
      Header_Size     : Unsigned_32;
      Name            : String (1 .. 22);
      Instr_Type      : Unsigned_8;         --  always 0
      Num_Samples     : Unsigned_16;
      --  Following fields only present if Num_Samples > 0:
      Sample_Header_Size : Unsigned_32;     --  typically 40
      Note_To_Sample  : Keymap;
      Vol_Env_Points  : Envelope_Points;
      Pan_Env_Points  : Envelope_Points;
      Vol_Env_Num     : Unsigned_8;
      Pan_Env_Num     : Unsigned_8;
      Vol_Sustain     : Unsigned_8;
      Vol_Loop_Start  : Unsigned_8;
      Vol_Loop_End    : Unsigned_8;
      Pan_Sustain     : Unsigned_8;
      Pan_Loop_Start  : Unsigned_8;
      Pan_Loop_End    : Unsigned_8;
      Vol_Env_Flags   : Unsigned_8;  --  bit0=on, bit1=sustain, bit2=loop
      Pan_Env_Flags   : Unsigned_8;
      Vibrato_Type    : Unsigned_8;
      Vibrato_Sweep   : Unsigned_8;
      Vibrato_Depth   : Unsigned_8;
      Vibrato_Rate    : Unsigned_8;
      Vol_Fadeout     : Unsigned_16; --  0-0xFFF (subtracted per tick)
      Reserved        : Unsigned_16;
   end record;

   --  ---------------------------------------------------------------
   --  Sample header within an instrument (40 bytes, little-endian)
   --  ---------------------------------------------------------------
   Sample_Flag_16bit     : constant Unsigned_8 := 16#10#;
   Sample_Flag_Ping_Pong : constant Unsigned_8 := 16#02#;
   Sample_Flag_Loop      : constant Unsigned_8 := 16#01#;

   type XM_Sample_Header is record
      Length        : Unsigned_32;  --  in bytes
      Loop_Start    : Unsigned_32;  --  in bytes
      Loop_Length   : Unsigned_32;  --  in bytes
      Volume        : Unsigned_8;   --  0-64
      Finetune      : Integer_8;    --  -128..127 (1/128 semitone)
      Sample_Type   : Unsigned_8;   --  flags: loop/16bit
      Panning       : Unsigned_8;   --  0-255
      Relative_Note : Integer_8;    --  relative note offset (-96..95)
      Reserved      : Unsigned_8;
      Name          : String (1 .. 22);
   end record;

   --  Sample data is delta-encoded (each byte = previous + delta)
   --  For 16-bit: deltas are 16-bit little-endian pairs, same scheme

   --  ---------------------------------------------------------------
   --  In-memory representation
   --  ---------------------------------------------------------------
   type XM_Sample_Data_8  is access Sample_Data_8;
   type XM_Sample_Data_16 is access Sample_Data_16;

   type XM_Sample (Depth : Sample_Depth := Depth_8) is record
      Header : Sample_Header;
      case Depth is
         when Depth_8  => Data_8  : XM_Sample_Data_8  := null;
         when Depth_16 => Data_16 : XM_Sample_Data_16 := null;
      end case;
   end record;

   type XM_Sample_Array is
     array (0 .. Max_Samples_Per_Instrument - 1) of XM_Sample;

   type Envelope_Flag is (Env_Off, Env_On, Env_Sustain, Env_Loop);

   type XM_Envelope is record
      Points      : Envelope_Points;
      Num_Points  : Natural         := 0;
      Sustain_Pt  : Natural         := 0;
      Loop_Start  : Natural         := 0;
      Loop_End    : Natural         := 0;
      Enabled     : Boolean         := False;
      Has_Sustain : Boolean         := False;
      Has_Loop    : Boolean         := False;
   end record;

   type XM_Instrument is record
      Name        : String (1 .. 22);
      Num_Samples : Natural               := 0;
      Note_Map    : Keymap               := [others => 0];
      Vol_Env     : XM_Envelope;
      Pan_Env     : XM_Envelope;
      Vibrato_Type  : Unsigned_8         := 0;
      Vibrato_Sweep : Unsigned_8         := 0;
      Vibrato_Depth : Unsigned_8         := 0;
      Vibrato_Rate  : Unsigned_8         := 0;
      Fadeout       : Natural            := 0;
      Samples       : XM_Sample_Array;
   end record;

   type XM_Instrument_Array is
     array (1 .. Max_Instruments) of XM_Instrument;

   type XM_Row is array (Natural range <>) of Pattern_Cell;
   type XM_Row_Access is access XM_Row;

   type XM_Pattern is record
      Num_Rows    : Positive     := 64;
      Num_Channels : Positive    := 2;
      Cells       : XM_Row_Access := null;
      --  Indexed as Cells (Row * Num_Channels + Channel), 0-based
   end record;

   type XM_Pattern_Array is array (Pattern_Index) of XM_Pattern;

   type Frequency_Table is (Amiga_Table, Linear_Table);

   type XM_Song is record
      Name           : String (1 .. 20);
      Tracker_Name   : String (1 .. 20);
      Num_Channels   : Positive          := 2;
      Song_Length    : Positive          := 1;
      Restart_Pos    : Natural           := 0;
      Freq_Table     : Frequency_Table   := Linear_Table;
      BPM            : BPM_Value         := 125;
      Speed          : Tick_Value        := 6;
      Orders         : XM_Order_Table;
      Instruments    : XM_Instrument_Array;
      Patterns       : XM_Pattern_Array;
   end record;

   --  ---------------------------------------------------------------
   --  Loader
   --  ---------------------------------------------------------------
   type Load_Error is (None, File_Not_Found, Invalid_Header,
                       Unsupported_Version, IO_Error);

   procedure Load
     (Path   : in  String;
      Song   : out XM_Song;
      Status : out Load_Error);
   --  Parse an XM file into Song.
   --  Delta-decodes sample data on load.

   procedure Free (Song : in out XM_Song);
   --  Release all heap-allocated sample data.

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------
   procedure Delta_Decode_8  (Data : in out Sample_Data_8);
   procedure Delta_Decode_16 (Data : in out Sample_Data_16);
   --  XM stores samples as deltas; call after reading raw bytes.

   function Linear_Period (Note : Note_Value; Finetune : Integer) return Float;
   --  XM linear frequency table: period = 10*12*16*4 - note*16*4 - finetune/2
   --  Then frequency = 8363 * 2^((6*12*16*4 - period) / (12*16*4))

   function Amiga_Period (Note : Note_Value; Finetune : Integer) return Float;
   --  XM Amiga table (same as MOD but with finetune in 1/128-semitone units)

end XM_Format;
