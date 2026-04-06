-- ***************************************************************************
--                      Tracker - Tracker UI
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
--  Tracker_UI
--  Draws the tracker interface using SDL2 primitives + Bitmap_Font.
--  Layout inspired by FastTracker II: dark background, colored columns,
--  highlighted current row, VU bars at the bottom.
--
--  Window: 1024 * 768
--  Characters: 16*16 px (8*8 font at 2* scale)
--  Columns: 64 chars wide, 48 chars tall

with SDL2;
with Song;
with Sequencer;
with Spectrum;

package Tracker_UI is

   Window_W : constant := 1024;
   Window_H : constant := 768;

   --  ---------------------------------------------------------------
   --  Color palette (FastTracker II inspired)
   --  ---------------------------------------------------------------
   Col_Background : constant SDL2.SDL_Color := (R => 16#00#, G => 16#00#, B => 16#14#, A => 16#FF#);
   Col_Header_BG  : constant SDL2.SDL_Color := (R => 16#00#, G => 16#14#, B => 16#3C#, A => 16#FF#);
   Col_Row_BG     : constant SDL2.SDL_Color := (R => 16#00#, G => 16#00#, B => 16#1A#, A => 16#FF#);
   Col_Row_Beat   : constant SDL2.SDL_Color := (R => 16#00#, G => 16#00#, B => 16#28#, A => 16#FF#);
   Col_Row_Cur    : constant SDL2.SDL_Color := (R => 16#00#, G => 16#28#, B => 16#3C#, A => 16#FF#);
   Col_Row_Cur2   : constant SDL2.SDL_Color := (R => 16#00#, G => 16#20#, B => 16#30#, A => 16#FF#);

   --  Note, instrument, volume, effect columns get distinct colors
   Col_Note       : constant SDL2.SDL_Color := (R => 16#FF#, G => 16#FF#, B => 16#00#, A => 16#FF#); -- yellow
   Col_Sharp      : constant SDL2.SDL_Color := (R => 16#FF#, G => 16#CC#, B => 16#00#, A => 16#FF#); -- amber
   Col_Instr      : constant SDL2.SDL_Color := (R => 16#00#, G => 16#FF#, B => 16#88#, A => 16#FF#); -- green
   Col_Vol        : constant SDL2.SDL_Color := (R => 16#00#, G => 16#CC#, B => 16#FF#, A => 16#FF#); -- cyan
   Col_Effect     : constant SDL2.SDL_Color := (R => 16#FF#, G => 16#88#, B => 16#00#, A => 16#FF#); -- orange
   Col_Empty      : constant SDL2.SDL_Color := (R => 16#33#, G => 16#33#, B => 16#55#, A => 16#FF#); -- dim
   Col_Header_TXT : constant SDL2.SDL_Color := (R => 16#AA#, G => 16#CC#, B => 16#FF#, A => 16#FF#); -- light blue
   Col_Label      : constant SDL2.SDL_Color := (R => 16#66#, G => 16#88#, B => 16#AA#, A => 16#FF#); -- dim blue
   Col_VU_LO      : constant SDL2.SDL_Color := (R => 16#00#, G => 16#AA#, B => 16#00#, A => 16#FF#); -- green
   Col_VU_HI      : constant SDL2.SDL_Color := (R => 16#FF#, G => 16#44#, B => 16#00#, A => 16#FF#); -- red
   Col_White      : constant SDL2.SDL_Color := (R => 16#FF#, G => 16#FF#, B => 16#FF#, A => 16#FF#);
   Col_Chan_Sep   : constant SDL2.SDL_Color := (R => 16#11#, G => 16#22#, B => 16#44#, A => 16#FF#);

   --  ---------------------------------------------------------------
   --  Visible rows above/below the current row in pattern editor
   --  ---------------------------------------------------------------
   Rows_Above : constant := 14;
   Rows_Below : constant := 14;
   Total_Visible_Rows : constant := Rows_Above + 1 + Rows_Below;

   --  ---------------------------------------------------------------
   --  File browser popup
   --  ---------------------------------------------------------------
   Max_Browser_Entries : constant := 512;
   Browser_Name_Max    : constant := 80;

   type Browser_Entry is record
      Name   : String (1 .. Browser_Name_Max) := [others => ' '];
      Len    : Natural                         := 0;
      Is_Dir : Boolean                         := False;
   end record;

   type Browser_List is array (1 .. Max_Browser_Entries) of Browser_Entry;

   procedure Draw_File_Browser
     (Rend     : SDL2.SDL_Renderer;
      Dir      : String;
      Entries  : Browser_List;
      Count    : Natural;
      Selected : Natural;
      Scroll   : Natural);

   --  ---------------------------------------------------------------
   --  Song info popup
   --  ---------------------------------------------------------------
   procedure Draw_Song_Info
     (Rend   : SDL2.SDL_Renderer;
      S      : Song.Song_Type;
      Scroll : Natural);

   --  ---------------------------------------------------------------
   --  Spectrum analyser popup
   --  ---------------------------------------------------------------
   procedure Draw_Spectrum
     (Rend  : SDL2.SDL_Renderer;
      Bars  : Spectrum.Bar_Array;
      Frame : Natural);

   --  ---------------------------------------------------------------
   --  Top-level draw call - replaces the entire frame.
   --  If Show_About is True, the About popup is drawn on top.
   --  ---------------------------------------------------------------
   procedure Draw
     (Rend        : SDL2.SDL_Renderer;
      S           : Song.Song_Type;
      Pos         : Sequencer.Position;
      Show_About  : Boolean := False;
      About_Frame : Natural := 0);

end Tracker_UI;
