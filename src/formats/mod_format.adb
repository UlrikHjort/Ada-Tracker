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
with Ada.Streams.Stream_IO;
with Ada.Unchecked_Conversion;
with Ada.Unchecked_Deallocation;

package body Mod_Format is

   use Ada.Streams.Stream_IO;

   function U8_To_I8 is new Ada.Unchecked_Conversion (Unsigned_8, Integer_8);

   subtype Stream_Access is Ada.Streams.Stream_IO.Stream_Access;

   --  ---------------------------------------------------------------
   --  Low-level endian-safe readers (MOD is big-endian)
   --  ---------------------------------------------------------------

   function Read_U8 (S : Stream_Access) return Unsigned_8 is
      V : Unsigned_8;
   begin
      Unsigned_8'Read (S, V);
      return V;
   end Read_U8;

   function Read_U16_BE (S : Stream_Access) return Unsigned_16 is
      Hi : constant Unsigned_8 := Read_U8 (S);
      Lo : constant Unsigned_8 := Read_U8 (S);
   begin
      return Shift_Left (Unsigned_16 (Hi), 8) or Unsigned_16 (Lo);
   end Read_U16_BE;

   procedure Read_String (S : Stream_Access; Str : out String) is
   begin
      for I in Str'Range loop
         Str (I) := Character'Val (Read_U8 (S));
      end loop;
   end Read_String;

   procedure Skip (S : Stream_Access; N : Positive) is
      Dummy : Unsigned_8;
   begin
      for I in 1 .. N loop
         Unsigned_8'Read (S, Dummy);
      end loop;
   end Skip;

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------

   function Detect_Tag (Tag : String) return Mod_Tag is
   begin
      if    Tag = "M.K." then return Tag_MK;
      elsif Tag = "M!K!" then return Tag_MK_Over;
      elsif Tag = "6CHN" then return Tag_6CH;
      elsif Tag = "8CHN" then return Tag_8CH;
      elsif Tag = "FLT4" then return Tag_FLT4;
      elsif Tag = "FLT8" then return Tag_FLT8;
      else                     return Tag_Unknown;
      end if;
   end Detect_Tag;

   function Channels_For_Tag (T : Mod_Tag; Tag_Raw : String) return Positive is
   begin
      case T is
         when Tag_MK | Tag_MK_Over | Tag_FLT4 => return 4;
         when Tag_6CH                          => return 6;
         when Tag_8CH | Tag_FLT8              => return 8;
         when Tag_Unknown =>
            --  Try "xxCH" / "xxCN" pattern
            if Tag_Raw'Length = 4
              and then Tag_Raw (Tag_Raw'First + 2 .. Tag_Raw'Last) = "CH"
            then
               declare
                  N : constant Integer :=
                    Character'Pos (Tag_Raw (Tag_Raw'First))     - Character'Pos ('0') * 10
                    + Character'Pos (Tag_Raw (Tag_Raw'First + 1)) - Character'Pos ('0');
               begin
                  if N in 1 .. Max_Channels then return N; end if;
               end;
            end if;
            return 4;  --  default fallback
      end case;
   end Channels_For_Tag;

   function Finetune_Signed (Raw : Unsigned_8) return Integer is
      Nibble : constant Integer := Integer (Raw and 16#0F#);
   begin
      --  Lower nibble as 4-bit signed: 8-15 -> -8..-1
      if Nibble >= 8 then return Nibble - 16;
      else                return Nibble;
      end if;
   end Finetune_Signed;

   function Period_To_Note (Period : Natural) return Note_Value is
      Best       : Note_Value := Note_Empty;
      Best_Delta : Natural    := Natural'Last;
      D          : Natural;
   begin
      if Period = 0 then return Note_Empty; end if;
      for N in Note_Value range 1 .. 96 loop
         D := (if Amiga_Periods (N) >= Period
               then Amiga_Periods (N) - Period
               else Period - Amiga_Periods (N));
         if D < Best_Delta then
            Best_Delta := D;
            Best       := N;
         end if;
         exit when D = 0;
      end loop;
      return Best;
   end Period_To_Note;

   function Decode_Cell
     (Raw      : Raw_Cell;
      Channels : Positive) return Pattern_Cell
   is
      pragma Unreferenced (Channels);
      --  Byte layout:  [0]=iiiiHHHH  [1]=LLLLLLLL  [2]=IIIIeeee  [3]=pppppppp
      --    period    = (Raw(0) & 0x0F) << 8 | Raw(1)
      --    instrument = (Raw(0) & 0xF0) | (Raw(2) >> 4)
      --    effect     = Raw(2) & 0x0F
      --    param      = Raw(3)
      Period : constant Natural :=
        Natural (Shift_Left (Unsigned_16 (Raw (0) and 16#0F#), 8)
                 or Unsigned_16 (Raw (1)));
      Instr  : constant Natural :=
        Natural ((Raw (0) and 16#F0#) or Shift_Right (Raw (2), 4));
      Eff    : constant Effect_Code := Raw (2) and 16#0F#;
      Param  : constant Effect_Param := Raw (3);
      Cell   : Pattern_Cell;
   begin
      Cell.Note       := Period_To_Note (Period);
      Cell.Instrument := Instrument_Index'Min (Instrument_Index'Last,
                                               Instr);
      Cell.Effect     := Eff;
      Cell.Param      := Param;
      --  Volume column not used in MOD
      Cell.Volume     := 0;
      return Cell;
   end Decode_Cell;

   --  ---------------------------------------------------------------
   --  Instrument header reader (30 bytes, big-endian)
   --  ---------------------------------------------------------------

   function Read_Instrument_Header
     (S : Stream_Access) return Mod_Instrument_Header
   is
      H : Mod_Instrument_Header;
   begin
      Read_String (S, H.Name);           --  22 bytes
      H.Length      := Read_U16_BE (S);  --  in words
      H.Finetune    := Read_U8 (S);
      H.Volume      := Read_U8 (S);
      H.Loop_Start  := Read_U16_BE (S);
      H.Loop_Length := Read_U16_BE (S);
      return H;
   end Read_Instrument_Header;

   --  ---------------------------------------------------------------
   --  Pattern reader
   --  ---------------------------------------------------------------

   procedure Read_Pattern
     (S        : Stream_Access;
      Pat      : in out Mod_Pattern;
      Channels : Positive)
   is
      procedure Free_Row is new Ada.Unchecked_Deallocation
        (Mod_Row, Mod_Row_Access);
      Total : constant Natural := Rows_Per_Pattern * Channels;
      Raw   : Raw_Cell;
   begin
      if Pat.Cells /= null then Free_Row (Pat.Cells); end if;
      Pat.Rows     := Rows_Per_Pattern;
      Pat.Channels := Channels;
      Pat.Cells    := new Mod_Row (0 .. Total - 1);

      for R in 0 .. Rows_Per_Pattern - 1 loop
         for C in 0 .. Channels - 1 loop
            for B in 0 .. 3 loop
               Raw (B) := Read_U8 (S);
            end loop;
            Pat.Cells (R * Channels + C) := Decode_Cell (Raw, Channels);
         end loop;
      end loop;
   end Read_Pattern;

   --  ---------------------------------------------------------------
   --  Load
   --  ---------------------------------------------------------------

   procedure Load
     (Path   : in  String;
      Song   : out Mod_Song;
      Status : out Load_Error)
   is
      File   : Ada.Streams.Stream_IO.File_Type;
      S      : Stream_Access;
      Tag    : String (1 .. 4);
      Num_Pat : Natural := 0;

   begin
      Status := None;
      pragma Warnings (Off, "aggregate not fully initialized");
      Song   := [others => <>];
      pragma Warnings (On, "aggregate not fully initialized");

      begin
         Open (File, In_File, Path);
      exception
         when Ada.Streams.Stream_IO.Name_Error =>
            Status := File_Not_Found;
            return;
         when others =>
            Status := IO_Error;
            return;
      end;

      S := Stream (File);

      begin
         --  Song name (20 bytes)
         Read_String (S, Song.Name);

         --  31 instrument headers (30 bytes each)
         for I in 1 .. Max_Instruments loop
            Song.Instruments (I).Header := Read_Instrument_Header (S);
         end loop;

         --  Song length and restart position
         Song.Song_Length := Natural'Max (1,
                               Natural'Min (128, Natural (Read_U8 (S))));
         Skip (S, 1);  --  restart position (unused here)

         --  Order table (128 bytes)
         for I in 0 .. Max_Orders - 1 loop
            Song.Orders (I) := Pattern_Index (Read_U8 (S));
            if I < Song.Song_Length then
               Num_Pat := Natural'Max (Num_Pat,
                                       Natural (Song.Orders (I)) + 1);
            end if;
         end loop;

         --  Tag (4 bytes)
         Read_String (S, Tag);
         Song.Tag          := Detect_Tag (Tag);
         Song.Num_Channels := Channels_For_Tag (Song.Tag, Tag);

         --  Patterns
         for P in 0 .. Pattern_Index (Num_Pat - 1) loop
            Read_Pattern (S, Song.Patterns (P), Song.Num_Channels);
         end loop;

         --  Sample data for each instrument
         for I in 1 .. Max_Instruments loop
            declare
               H          : Mod_Instrument_Header
                              renames Song.Instruments (I).Header;
               Byte_Count : constant Natural := Natural (H.Length) * 2;
            begin
               if Byte_Count > 0 then
                  Song.Instruments (I).Data :=
                    new Sample_Data_8 (0 .. Byte_Count - 1);
                  for B in 0 .. Byte_Count - 1 loop
                     Song.Instruments (I).Data (B) :=
                       U8_To_I8 (Read_U8 (S));
                  end loop;
               end if;
            end;
         end loop;

      exception
         when Ada.Streams.Stream_IO.End_Error =>
            null;  --  short files are common (truncated samples) - accept
         when others =>
            Status := IO_Error;
      end;

      Close (File);
   end Load;

   --  ---------------------------------------------------------------
   --  Free
   --  ---------------------------------------------------------------

   procedure Free (Song : in out Mod_Song) is
      procedure Free_Sample is new Ada.Unchecked_Deallocation
        (Sample_Data_8, Mod_Sample_Data);
      procedure Free_Row is new Ada.Unchecked_Deallocation
        (Mod_Row, Mod_Row_Access);
   begin
      for I in 1 .. Max_Instruments loop
         if Song.Instruments (I).Data /= null then
            Free_Sample (Song.Instruments (I).Data);
         end if;
      end loop;
      for P in Pattern_Index loop
         if Song.Patterns (P).Cells /= null then
            Free_Row (Song.Patterns (P).Cells);
         end if;
      end loop;
   end Free;

end Mod_Format;
