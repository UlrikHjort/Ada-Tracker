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
with Ada.Numerics.Elementary_Functions;
with Ada.Numerics;
with Bitmap_Font;
with Mixer;
with Interfaces;      use Interfaces;
with Interfaces.C;    use Interfaces.C;
with Tracker_Types;   use Tracker_Types;

package body Tracker_UI is

   use Song;

   use Bitmap_Font;
   use SDL2;

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------

   procedure Fill_Rect
     (Rend : SDL_Renderer; X, Y, W, H : int; Col : SDL_Color)
   is
      R    : aliased SDL_Rect := (X, Y, W, H);
      Dummy : int;
      pragma Unreferenced (Dummy);
   begin
      Dummy := SDL_SetRenderDrawColor (Rend, Col.R, Col.G, Col.B, 255);
      Dummy := SDL_RenderFillRect (Rend, R'Access);
   end Fill_Rect;

   function Hex_Char (V : Natural) return Character is
      Hex : constant String := "0123456789ABCDEF";
   begin
      return Hex (Hex'First + (V mod 16));
   end Hex_Char;

   function Hex_Byte (V : Natural) return String is
   begin
      return [1 => Hex_Char (V / 16), 2 => Hex_Char (V mod 16)];
   end Hex_Byte;

   function Pad_Right (S : String; Width : Natural) return String is
      Result : String (1 .. Width) := [others => ' '];
   begin
      for I in 1 .. Natural'Min (S'Length, Width) loop
         Result (I) := S (S'First + I - 1);
      end loop;
      return Result;
   end Pad_Right;

   --  ---------------------------------------------------------------
   --  Note name formatting: "C-4", "C#4", "---"
   --  ---------------------------------------------------------------

   Note_Names : constant array (0 .. 11) of String (1 .. 2) :=
     ["C-", "C#", "D-", "D#", "E-", "F-", "F#", "G-", "G#", "A-", "A#", "B-"];

   function Format_Note (N : Note_Value) return String is
   begin
      if N = Note_Empty   then return "---";
      elsif N = Note_Key_Off then return "===";
      else
         declare
            Semi : constant Natural := (Integer (N) - 1) mod 12;
            Oct  : constant Natural := (Integer (N) - 1) / 12;
         begin
            return Note_Names (Semi) & Character'Val (Character'Pos ('0') + Oct);
         end;
      end if;
   end Format_Note;

   function Format_Instr (I : Instrument_Index) return String is
   begin
      if I = 0 then return "--";
      else          return Hex_Byte (I);
      end if;
   end Format_Instr;

   function Format_Vol (V : Natural) return String is
   begin
      if V = 0             then return "..";
      elsif V in 16#10# .. 16#50# then
         return Hex_Byte (V - 16#10#);
      else
         return Hex_Byte (V);
      end if;
   end Format_Vol;

   function Format_Effect (E : Effect_Code; P : Effect_Param) return String is
   begin
      if E = 0 and P = 0 then return "...";
      else                     return Hex_Char (Natural (E)) & Hex_Byte (Natural (P));
      end if;
   end Format_Effect;

   --  ---------------------------------------------------------------
   --  Layout constants
   --  ---------------------------------------------------------------

   --  Header area
   Header_H  : constant int := Char_H * 2 + 4;  --  ~36 px

   --  Channel info strip (active instrument names) + column header
   Chan_Info_H : constant int := Char_H + 2;  --  instrument names
   Chan_Hdr_H  : constant int := Char_H;      --  "C01|C02|..." labels

   --  Pattern editor area starts just below header + strips
   Pat_Y     : constant int := Header_H + Chan_Info_H + Chan_Hdr_H + 2;

   --  Cell width in characters:
   --  "NNN II VV EEE" = 3+1+2+1+2+1+3 = 13 chars + 1 sep = 14
   Cell_Chars : constant int := 14;
   pragma Unreferenced (Cell_Chars);

   --  VU meter area at the bottom
   VU_H  : constant int := 64;
   VU_Y  : constant int := Window_H - VU_H - 2;

   --  Oscilloscope strip between pattern editor and VU meters
   Osc_H : constant int := 56;
   Osc_Y : constant int := VU_Y - Osc_H - 4;

   --  Pattern editor height (ends above oscilloscope)
   Pat_H : constant int := Osc_Y - Pat_Y - 4;

   --  ---------------------------------------------------------------
   --  Draw the header bar
   --  ---------------------------------------------------------------

   procedure Draw_Header
     (Rend : SDL_Renderer;
      S    : Song.Song_Type;
      Pos  : Sequencer.Position)
   is
      X : int := 4;
      Y : constant int := 4;
   begin
      --  Background
      Fill_Rect (Rend, 0, 0, Window_W, Header_H, Col_Header_BG);

      --  Song name (up to 20 chars)
      Draw_String (Rend, X, Y, Pad_Right (S.Name, 20), Col_White);
      X := X + 20 * Char_W + 8;

      --  BPM
      Draw_String (Rend, X, Y, "BPM:", Col_Label);
      X := X + 4 * Char_W;
      declare
         B   : constant BPM_Value := Sequencer.Transport.BPM;
         Str : constant String    :=
                 Character'Val (Character'Pos ('0') + B / 100) &
                 Character'Val (Character'Pos ('0') + (B / 10) mod 10) &
                 Character'Val (Character'Pos ('0') + B mod 10);
      begin
         Draw_String (Rend, X, Y, Str, Col_Header_TXT);
         X := X + 3 * Char_W + 8;
      end;

      --  Speed
      Draw_String (Rend, X, Y, "SPD:", Col_Label);
      X := X + 4 * Char_W;
      declare
         Spd : constant Tick_Value := Sequencer.Transport.Speed;
         Str : constant String     :=
                 Character'Val (Character'Pos ('0') + Spd / 10) &
                 Character'Val (Character'Pos ('0') + Spd mod 10);
      begin
         Draw_String (Rend, X, Y, Str, Col_Header_TXT);
         X := X + 2 * Char_W + 8;
      end;

      --  Order / pattern / row
      Draw_String (Rend, X, Y, "ORD:", Col_Label);
      X := X + 4 * Char_W;
      Draw_String (Rend, X, Y, Hex_Byte (Pos.Order), Col_Header_TXT);
      X := X + 2 * Char_W;
      Draw_String (Rend, X, Y, "/", Col_Label);
      X := X + Char_W;
      Draw_String (Rend, X, Y, Hex_Byte (S.Song_Length - 1), Col_Label);
      X := X + 2 * Char_W + 8;

      Draw_String (Rend, X, Y, "PAT:", Col_Label);
      X := X + 4 * Char_W;
      Draw_String (Rend, X, Y, Hex_Byte (Natural (Pos.Pattern)), Col_Header_TXT);
      X := X + 2 * Char_W + 8;

      Draw_String (Rend, X, Y, "ROW:", Col_Label);
      X := X + 4 * Char_W;
      Draw_String (Rend, X, Y, Hex_Byte (Natural (Pos.Row)), Col_Header_TXT);
      X := X + 2 * Char_W + 8;

      --  Format indicator
      Draw_String (Rend, X, Y,
                   (case S.Format is
                      when Song.Format_MOD => "MOD",
                      when Song.Format_XM  => " XM",
                      when Song.Format_S3M => "S3M",
                      when Song.Format_IT  => " IT"),
                   Col_Label);

      --  Transport state
      declare
         St_Str : constant String :=
                    (case Sequencer.Transport.State is
                     when Sequencer.Playing => ">>",
                     when Sequencer.Paused  => "||",
                     when Sequencer.Stopped => "[]");
      begin
         Draw_String (Rend, Window_W - 4 * Char_W, Y, St_Str, Col_Note);
      end;
   end Draw_Header;

   --  ---------------------------------------------------------------
   --  Draw one pattern row at screen Y
   --  ---------------------------------------------------------------

   procedure Draw_Row
     (Rend        : SDL_Renderer;
      S           : Song.Song_Type;
      Pat_Idx     : Pattern_Index;
      Row         : Natural;
      Screen_Y    : int;
      Is_Current  : Boolean;
      Is_Beat     : Boolean)
   is
      Pat     : Song.Pattern renames S.Patterns (Pat_Idx);
      Row_BG  : constant SDL_Color :=
                  (if Is_Current then Col_Row_Cur
                   elsif Is_Beat then Col_Row_Beat
                   else Col_Row_BG);
      Sx      : int := 0;
   begin
      --  Row background
      Fill_Rect (Rend, 0, Screen_Y, Window_W, Char_H, Row_BG);

      --  Row number
      declare
         Hi : constant Character :=
                Hex_Char (Row / 16);
         Lo : constant Character :=
                Hex_Char (Row mod 16);
         Col : constant SDL_Color :=
                 (if Is_Current then Col_White
                  elsif Is_Beat then Col_Header_TXT
                  else Col_Label);
      begin
         Draw_Char (Rend, 2, Screen_Y, Hi, Col.R, Col.G, Col.B);
         Draw_Char (Rend, 2 + Char_W, Screen_Y, Lo, Col.R, Col.G, Col.B);
         --  Separator after row number
         Draw_Char (Rend, 2 + 2 * Char_W, Screen_Y, '|', Col_Chan_Sep.R,
                    Col_Chan_Sep.G, Col_Chan_Sep.B);
         Sx := 2 + 3 * Char_W;
      end;

      --  Draw each channel
      for Ch in Channel_Index range 0 .. Channel_Index (Pat.Num_Channels - 1) loop
         declare
            Cell  : constant Pattern_Cell :=
                      (if Row < Pat.Num_Rows
                       then Song.Cell (Pat, Row_Index (Row), Ch)
                       else (others => <>));
            Cx    : int := Sx;

            procedure Put_Note is
            begin
               if Cell.Note = Note_Empty then
                  Draw_String (Rend, Cx, Screen_Y, "---", Col_Empty.R,
                               Col_Empty.G, Col_Empty.B);
               elsif Cell.Note = Note_Key_Off then
                  Draw_String (Rend, Cx, Screen_Y, "===", Col_Vol.R,
                               Col_Vol.G, Col_Vol.B);
               else
                  declare
                     Ns : constant String := Format_Note (Cell.Note);
                     NC : constant SDL_Color :=
                            (if Ns (2) = '#' then Col_Sharp else Col_Note);
                  begin
                     Draw_Char (Rend, Cx, Screen_Y, Ns (1), NC.R, NC.G, NC.B);
                     Cx := Cx + Char_W;
                     Draw_Char (Rend, Cx, Screen_Y, Ns (2),
                                (if Ns (2) = '#' then Col_Sharp.R else NC.R),
                                (if Ns (2) = '#' then Col_Sharp.G else NC.G),
                                (if Ns (2) = '#' then Col_Sharp.B else NC.B));
                     Cx := Cx + Char_W;
                     Draw_Char (Rend, Cx, Screen_Y, Ns (3), NC.R, NC.G, NC.B);
                  end;
               end if;
               Cx := Sx + 3 * Char_W + 2;
            end Put_Note;

         begin
            Put_Note;

            --  Instrument
            declare
               Is_Str : constant String := Format_Instr (Cell.Instrument);
               IC     : constant SDL_Color :=
                          (if Cell.Instrument = 0 then Col_Empty else Col_Instr);
            begin
               Draw_String (Rend, Cx, Screen_Y, Is_Str, IC);
               Cx := Cx + 2 * Char_W + 2;
            end;

            --  Volume column
            declare
               Vs  : constant String := Format_Vol (Cell.Volume);
               VC  : constant SDL_Color :=
                       (if Cell.Volume = 0 then Col_Empty else Col_Vol);
            begin
               Draw_String (Rend, Cx, Screen_Y, Vs, VC);
               Cx := Cx + 2 * Char_W + 2;
            end;

            --  Effect
            declare
               Es  : constant String := Format_Effect (Cell.Effect, Cell.Param);
               EC  : constant SDL_Color :=
                       (if Cell.Effect = 0 and Cell.Param = 0
                        then Col_Empty else Col_Effect);
            begin
               Draw_String (Rend, Cx, Screen_Y, Es, EC);
               Cx := Cx + 3 * Char_W;
            end;

            --  Channel separator
            Draw_Char (Rend, Cx, Screen_Y, '|', Col_Chan_Sep.R,
                       Col_Chan_Sep.G, Col_Chan_Sep.B);
            Sx := Cx + Char_W;
         end;
      end loop;
   end Draw_Row;

   --  ---------------------------------------------------------------
   --  Draw channel info strip (active instrument names)
   --  and column header row (channel numbers aligned with pattern)
   --  ---------------------------------------------------------------

   procedure Draw_Channel_Info
     (Rend  : SDL_Renderer;
      S     : Song.Song_Type)
   is
      use Mixer;
      Instrs  : constant Instr_Array := Active_Channels.Get_Instrs;
      --  Compute column positions mirroring Draw_Row layout
      Sx      : int := 2 + 3 * Char_W;
      Info_Y  : constant int := Header_H + 2;
      Hdr_Y   : constant int := Info_Y + Chan_Info_H;
      Dummy   : int;
      pragma Unreferenced (Dummy);

      --  Max chars available per channel cell (same as Draw_Row: 13 + sep)
      Chan_Cell_W : constant int := 13 * Char_W;

      procedure Draw_Sep (X : int; Y : int) is
      begin
         Draw_Char (Rend, X, Y, '|', Col_Chan_Sep.R, Col_Chan_Sep.G, Col_Chan_Sep.B);
      end Draw_Sep;
   begin
      Fill_Rect (Rend, 0, Info_Y, Window_W, Chan_Info_H + Chan_Hdr_H, Col_Header_BG);

      --  Row-number placeholder (spaces to align with pattern)
      Draw_String (Rend, 2, Hdr_Y, "  ", Col_Label);
      Draw_Sep (2 + 2 * Char_W, Hdr_Y);

      for Ch in Channel_Index range 0 .. Channel_Index (S.Num_Channels - 1) loop
         declare
            Instr_No : constant Instrument_Index := Instrs (Ch);
            --  Truncated instrument name (up to 9 chars to fit cell)
            Max_Name : constant Natural := 9;
            Name     : constant String :=
                         (if Instr_No /= 0
                          then Pad_Right
                                 (S.Instruments (Instr_No).Name, Max_Name)
                          else String'(1 .. Max_Name => ' '));
            Ch_Num   : constant String :=
                         "C" & Hex_Char (Natural (Ch) / 10)
                              & Hex_Char (Natural (Ch) mod 10);
            Is_Active : constant Boolean := Instr_No /= 0;
         begin
            --  Instrument name (info strip)
            Draw_String (Rend, Sx, Info_Y + 1, Name,
                         (if Is_Active then Col_Instr else Col_Empty));

            --  Channel label (header row)
            Draw_String (Rend, Sx, Hdr_Y, Ch_Num, Col_Label);
            --  Separator placeholder at end of cell
            Draw_Sep (Sx + Chan_Cell_W, Hdr_Y);

            Sx := Sx + Chan_Cell_W + Char_W;
         end;
      end loop;
   end Draw_Channel_Info;

   --  ---------------------------------------------------------------
   --  Draw the full pattern editor
   --  ---------------------------------------------------------------

   procedure Draw_Pattern_Editor
     (Rend : SDL_Renderer;
      S    : Song.Song_Type;
      Pos  : Sequencer.Position)
   is
      Pat_Idx : constant Pattern_Index := S.Orders (Pos.Order);
      Pat     : Song.Pattern renames S.Patterns (Pat_Idx);
      Cur_Row : constant Natural := Natural (Pos.Row);
      Sy      : int := Pat_Y;

      Max_Rows_Visible : constant Natural :=
        Natural (Pat_H / Char_H);
      Half  : constant Natural := Max_Rows_Visible / 2;

      --  First row to display (center current row)
      First_Row : constant Integer :=
                    Integer (Cur_Row) - Integer (Half);
   begin
      for I in 0 .. Max_Rows_Visible - 1 loop
         declare
            Row : constant Integer := First_Row + I;
         begin
            if Row >= 0 and Row < Pat.Num_Rows then
               Draw_Row
                 (Rend, S, Pat_Idx, Row, Sy,
                  Is_Current => Row = Integer (Cur_Row),
                  Is_Beat    => Row mod 4 = 0);
            else
               --  Out of range - blank row
               Fill_Rect (Rend, 0, Sy, Window_W, Char_H, Col_Background);
            end if;
         end;
         Sy := Sy + Char_H;
      end loop;
   end Draw_Pattern_Editor;

   --  ---------------------------------------------------------------
   --  Draw oscilloscope waveform
   --  ---------------------------------------------------------------

   procedure Draw_Oscilloscope (Rend : SDL_Renderer) is
      Buf   : constant Mixer.Osc_Buffer := Mixer.Oscilloscope.Snapshot;
      Mid_Y : constant int   := Osc_Y + Osc_H / 2;
      Amp   : constant Float := Float (Osc_H / 2 - 4);
      Dummy : int;
      pragma Unreferenced (Dummy);
   begin
      Fill_Rect (Rend, 0, Osc_Y, Window_W, Osc_H, Col_Background);

      --  Dim centre line
      Dummy := SDL_SetRenderDrawColor (Rend, 16#11#, 16#22#, 16#33#, 255);
      Dummy := SDL_RenderDrawLine (Rend, 0, Mid_Y, Window_W - 1, Mid_Y);

      --  Waveform: 512 samples across the window width (2 px per sample)
      Dummy := SDL_SetRenderDrawColor (Rend, 16#00#, 16#EE#, 16#88#, 255);
      for I in 0 .. Mixer.Osc_Size - 2 loop
         declare
            X1 : constant int := int (I * 2);
            X2 : constant int := int ((I + 1) * 2);
            Y1 : constant int := Mid_Y - int (Buf (I)     * Amp);
            Y2 : constant int := Mid_Y - int (Buf (I + 1) * Amp);
         begin
            Dummy := SDL_RenderDrawLine (Rend, X1, Y1, X2, Y2);
         end;
      end loop;

      Draw_String (Rend, 4, Osc_Y + 2, "OSC", Col_Label);
   end Draw_Oscilloscope;

   --  ---------------------------------------------------------------
   --  Draw VU meters
   --  ---------------------------------------------------------------

   procedure Draw_VU_Meters
     (Rend    : SDL_Renderer;
      Num_Ch  : Positive)
   is
      Levels  : constant Mixer.VU_Array := Mixer.VU_Meter.Peaks;
      Total_W : constant int := Window_W - 8;
      Bar_W   : constant int := Total_W / int (Num_Ch) - 2;
      Sx      : int          := 4;
      Dummy   : int;
      pragma Unreferenced (Dummy);
   begin
      Fill_Rect (Rend, 0, VU_Y - 2, Window_W, VU_H + 4, Col_Background);
      Draw_String (Rend, 4, VU_Y - Char_H - 2, "VU", Col_Label);

      for Ch in Channel_Index range 0 .. Channel_Index (Num_Ch - 1) loop
         declare
            Level  : constant Float := Float'Min (1.0, Levels (Ch));
            Fill_H : constant int   := int (Float (VU_H - 4) * Level);
            Bar_Y  : constant int   := VU_Y + (VU_H - 4 - Fill_H);
            Col    : constant SDL_Color :=
                       (if Level > 0.75 then Col_VU_HI else Col_VU_LO);
         begin
            --  Background (empty bar)
            Fill_Rect (Rend, Sx, VU_Y, Bar_W, VU_H - 4, Col_Chan_Sep);
            --  Filled portion
            if Fill_H > 0 then
               Fill_Rect (Rend, Sx, Bar_Y, Bar_W, Fill_H, Col);
            end if;
            --  Channel number label
            Draw_Char (Rend, Sx + Bar_W / 2 - Char_W / 2,
                       VU_Y + VU_H - 4 - Char_H,
                       Hex_Char (Natural (Ch)),
                       Col_Label.R, Col_Label.G, Col_Label.B);
         end;
         Sx := Sx + Bar_W + 2;
      end loop;
   end Draw_VU_Meters;

   --  ---------------------------------------------------------------
   --  About popup
   --  ---------------------------------------------------------------

   procedure Draw_About (Rend : SDL_Renderer; Frame : Natural) is
      Pop_W : constant int := 420;
      Pop_H : constant int := 220;
      Pop_X : constant int := (Window_W - Pop_W) / 2;
      Pop_Y : constant int := (Window_H - Pop_H) / 2;

      Dummy : int;
      pragma Unreferenced (Dummy);

      --  Rainbow color from a hue value 0..359
      procedure Hue_To_RGB
        (Hue     : Natural;
         R, G, B : out Unsigned_8)
      is
         H  : constant Float  := Float (Hue mod 360) / 60.0;
         Hi : constant Natural := Natural (Float'Floor (H)) mod 6;
         F  : constant Float  := H - Float'Floor (H);
      begin
         case Hi is
            when 0 => R := 255;                        G := Unsigned_8 (F * 255.0);       B := 0;
            when 1 => R := Unsigned_8 ((1.0-F)*255.0); G := 255;                          B := 0;
            when 2 => R := 0;                          G := 255;                          B := Unsigned_8 (F * 255.0);
            when 3 => R := 0;                          G := Unsigned_8 ((1.0-F)*255.0);   B := 255;
            when 4 => R := Unsigned_8 (F * 255.0);    G := 0;                            B := 255;
            when others => R := 255;                   G := 0;                            B := Unsigned_8 ((1.0-F)*255.0);
         end case;
      end Hue_To_RGB;

      function Center_X (Len : Natural) return int is
        (Pop_X + (Pop_W - int (Len) * Char_W) / 2);

      Title : constant String := "AdaTracker";
      By    : constant String := "By Ulrik H" & Character'Val (248) & "rlyk Hjort";
      Year  : constant String := "2015";
      Hint  : constant String := "Right-click to close";

   begin
      --  Semi-transparent dark overlay
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_BLEND);
      Dummy := SDL_SetRenderDrawColor (Rend, 0, 0, 0, 170);
      declare
         R : aliased SDL_Rect := (0, 0, Window_W, Window_H);
      begin
         Dummy := SDL_RenderFillRect (Rend, R'Access);
      end;
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_NONE);

      --  Popup background
      Fill_Rect (Rend, Pop_X, Pop_Y, Pop_W, Pop_H,
                 (R => 16#04#, G => 16#08#, B => 16#22#, A => 255));

      --  Pulsing two-pixel border
      declare
         P  : constant Float :=
                (Ada.Numerics.Elementary_Functions.Sin
                   (Float (Frame) / 20.0) + 1.0) / 2.0;
         BR : constant Unsigned_8 := Unsigned_8 (68.0  + P * 187.0);
         BG : constant Unsigned_8 := Unsigned_8 (P * 88.0);
         BB : constant Unsigned_8 := Unsigned_8 (136.0 + P * 119.0);
         R1 : aliased SDL_Rect := (Pop_X,     Pop_Y,     Pop_W,     Pop_H);
         R2 : aliased SDL_Rect := (Pop_X + 1, Pop_Y + 1, Pop_W - 2, Pop_H - 2);
      begin
         Dummy := SDL_SetRenderDrawColor (Rend, BR, BG, BB, 255);
         Dummy := SDL_RenderDrawRect (Rend, R1'Access);
         Dummy := SDL_RenderDrawRect (Rend, R2'Access);
      end;

      --  "AdaTracker" - each letter waves and glows a different rainbow hue
      declare
         Tx : int := Center_X (Title'Length);
         TY : constant int := Pop_Y + 28;
      begin
         for I in Title'Range loop
            declare
               Idx   : constant Natural := I - Title'First;
               Phase : constant Float :=
                         Float (Frame) / 12.0
                         + Float (Idx) * Ada.Numerics.Pi / 3.0;
               Y_Off : constant int := int (Ada.Numerics.Elementary_Functions.Sin (Phase) * 5.0);
               Hue   : constant Natural := (Frame * 2 + Idx * 30) mod 360;
               R, G, B : Unsigned_8;
            begin
               Hue_To_RGB (Hue, R, G, B);
               Draw_Char (Rend, Tx, TY + Y_Off, Title (I), R, G, B);
               Tx := Tx + Char_W;
            end;
         end loop;
      end;

      --  Author
      Draw_String (Rend, Center_X (By'Length), Pop_Y + 90,
                   By, Col_Header_TXT);

      --  Year
      Draw_String (Rend, Center_X (Year'Length), Pop_Y + 122,
                   Year, Col_Label);

      --  Hint at bottom
      Draw_String (Rend, Center_X (Hint'Length), Pop_Y + Pop_H - Char_H - 10,
                   Hint,
                   (R => 16#33#, G => 16#44#, B => 16#55#, A => 255));

   end Draw_About;

   --  ---------------------------------------------------------------
   --  Draw file browser popup
   --  ---------------------------------------------------------------

   procedure Draw_File_Browser
     (Rend     : SDL_Renderer;
      Dir      : String;
      Entries  : Browser_List;
      Count    : Natural;
      Selected : Natural;
      Scroll   : Natural)
   is
      Pop_W  : constant int := 700;
      Pop_H  : constant int := 500;
      Pop_X  : constant int := (Window_W - Pop_W) / 2;
      Pop_Y  : constant int := (Window_H - Pop_H) / 2;
      Title  : constant String := "Open File";
      Row_H  : constant int := Char_H + 2;
      List_Y : constant int := Pop_Y + 2 * Char_H + 8;
      List_H : constant int := Pop_H - 3 * Char_H - 16;
      Vis    : constant Natural := Natural (List_H / Row_H);
      Dummy  : int;
      pragma Unreferenced (Dummy);
   begin
      --  Dark overlay
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_BLEND);
      Dummy := SDL_SetRenderDrawColor (Rend, 0, 0, 0, 180);
      declare
         R : aliased SDL_Rect := (0, 0, Window_W, Window_H);
      begin
         Dummy := SDL_RenderFillRect (Rend, R'Access);
      end;
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_NONE);

      --  Panel
      Fill_Rect (Rend, Pop_X, Pop_Y, Pop_W, Pop_H,
                 (R => 16#02#, G => 16#05#, B => 16#18#, A => 255));

      --  Border
      Dummy := SDL_SetRenderDrawColor (Rend, 16#44#, 16#66#, 16#99#, 255);
      declare
         R : aliased SDL_Rect := (Pop_X, Pop_Y, Pop_W, Pop_H);
      begin
         Dummy := SDL_RenderDrawRect (Rend, R'Access);
      end;

      --  Title
      Draw_String (Rend,
                   Pop_X + (Pop_W - int (Title'Length) * Char_W) / 2,
                   Pop_Y + 6, Title, Col_White);

      --  Current directory (truncated from end)
      declare
         Max_Dir_Chars : constant Natural := Natural ((Pop_W - 8) / Char_W);
         D_Start       : constant Natural :=
                           (if Dir'Length > Max_Dir_Chars
                            then Dir'Last - Max_Dir_Chars + 1
                            else Dir'First);
         Shown         : constant String := Dir (D_Start .. Dir'Last);
      begin
         Draw_String (Rend, Pop_X + 4, Pop_Y + Char_H + 8, Shown, Col_Label);
      end;

      --  Separator line
      Dummy := SDL_SetRenderDrawColor (Rend, 16#22#, 16#33#, 16#55#, 255);
      Dummy := SDL_RenderDrawLine
        (Rend, Pop_X + 2, List_Y - 2, Pop_X + Pop_W - 2, List_Y - 2);

      --  List rows
      for I in 0 .. Vis - 1 loop
         declare
            Idx : constant Natural := Scroll + 1 + I;
         begin
            if Idx <= Count then
               declare
                  E     : Browser_Entry renames Entries (Idx);
                  Ry    : constant int := List_Y + int (I) * Row_H;
                  Is_Sel : constant Boolean := Idx = Selected;
                  Col   : constant SDL_Color :=
                            (if E.Is_Dir then Col_Instr else Col_Note);
                  Name_S : constant String :=
                             (if E.Len > 0
                              then E.Name (1 .. E.Len)
                              else "");
               begin
                  if Is_Sel then
                     Fill_Rect (Rend, Pop_X + 2, Ry, Pop_W - 4, Row_H,
                                Col_Row_Cur);
                  end if;
                  --  Dir prefix
                  if E.Is_Dir then
                     Draw_Char (Rend, Pop_X + 6, Ry + 1, '[',
                                Col.R, Col.G, Col.B);
                  end if;
                  Draw_String (Rend,
                               Pop_X + 6 + (if E.Is_Dir then Char_W else 0),
                               Ry + 1, Name_S,
                               (if Is_Sel then Col_White else Col));
                  if E.Is_Dir then
                     Draw_Char (Rend,
                                Pop_X + 6 + Char_W + int (Name_S'Length) * Char_W,
                                Ry + 1, ']', Col.R, Col.G, Col.B);
                  end if;
               end;
            end if;
         end;
      end loop;

      --  Scrollbar: only meaningsful when there are more entries than visible rows
      if Count > Vis then
         declare
            SB_X    : constant int := Pop_X + Pop_W - 6;
            SB_Top  : constant int := List_Y;
            SB_H    : constant int := List_H;
            Overflow : constant int := int (Count) - int (Vis);
            Thumb_H : constant int :=
                        int'Max (4, int'Min (SB_H,
                          SB_H * int (Vis) / int (Count)));
            Thumb_Y : constant int :=
                        SB_Top
                        + (SB_H - Thumb_H) * int (Scroll) / Overflow;
         begin
            Fill_Rect (Rend, SB_X, SB_Top, 4, SB_H, Col_Chan_Sep);
            Fill_Rect (Rend, SB_X, Thumb_Y, 4, Thumb_H, Col_Label);
         end;
      end if;

      --  Footer hint
      Draw_String
        (Rend,
         Pop_X + (Pop_W - 38 * Char_W) / 2,
         Pop_Y + Pop_H - Char_H - 6,
         "UP/DOWN: navigate  ENTER: load  ESC: cancel",
         Col_Label);
   end Draw_File_Browser;

   --  ---------------------------------------------------------------
   --  Draw_Spectrum - real-time spectrum analyser popup
   --  ---------------------------------------------------------------

   --  Peak-hold per bar: decays 1 dB/frame.  Package-level so it
   --  persists between calls without needing a caller-owned buffer.
   Peak_Hold : Spectrum.Bar_Array := [others => -80.0];

   procedure Draw_Spectrum
     (Rend  : SDL_Renderer;
      Bars  : Spectrum.Bar_Array;
      Frame : Natural)
   is
      pragma Unreferenced (Frame);

      Pop_W    : constant int := 980;
      Pop_H    : constant int := 460;
      Pop_X    : constant int := (Window_W - Pop_W) / 2;
      Pop_Y    : constant int := (Window_H - Pop_H) / 2;

      --  Inner chart area
      Chart_X  : constant int := Pop_X + 40;   --  left  (dB labels)
      Chart_Y  : constant int := Pop_Y + 30;   --  top   (title)
      Chart_W  : constant int := Pop_W - 50;
      Chart_H  : constant int := Pop_H - 80;   --  bottom (freq labels)

      Bar_W    : constant int :=
                   int'Max (1, (Chart_W - int (Spectrum.Num_Bars) + 1)
                               / int (Spectrum.Num_Bars));
      DB_Min   : constant Float := -80.0;
      DB_Max   : constant Float :=   0.0;
      DB_Range : constant Float := DB_Max - DB_Min;

      Dummy    : int;
      pragma Unreferenced (Dummy);

      function DB_To_Y (DB : Float) return int is
         Frac : constant Float :=
                  Float'Max (0.0, Float'Min (1.0,
                    (DB - DB_Min) / DB_Range));
      begin
         return Chart_Y + Chart_H - int (Frac * Float (Chart_H));
      end DB_To_Y;

      procedure Bar_Color (DB : Float; R, G, B : out Unsigned_8) is
      begin
         if DB >= -10.0 then         R := 255; G :=  50; B :=  20;
         elsif DB >= -25.0 then      R := 255; G := 180; B :=   0;
         elsif DB >= -45.0 then      R :=  60; G := 220; B :=  60;
         else                        R :=   0; G := 120; B :=  80;
         end if;
      end Bar_Color;

   begin
      --  Dark overlay
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_BLEND);
      Dummy := SDL_SetRenderDrawColor (Rend, 0, 0, 0, 170);
      declare
         R : aliased SDL_Rect := (0, 0, Window_W, Window_H);
      begin
         Dummy := SDL_RenderFillRect (Rend, R'Access);
      end;
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_NONE);

      --  Panel
      Fill_Rect (Rend, Pop_X, Pop_Y, Pop_W, Pop_H,
                 (R => 16#02#, G => 16#04#, B => 16#14#, A => 255));

      --  Border
      Dummy := SDL_SetRenderDrawColor (Rend, 16#33#, 16#55#, 16#88#, 255);
      declare
         R : aliased SDL_Rect := (Pop_X, Pop_Y, Pop_W, Pop_H);
      begin
         Dummy := SDL_RenderDrawRect (Rend, R'Access);
      end;

      --  Title
      Draw_String (Rend,
                   Pop_X + (Pop_W - 18 * Char_W) / 2,
                   Pop_Y + 6,
                   "SPECTRUM ANALYSER",
                   Col_Header_TXT);

      --  Chart background
      Fill_Rect (Rend, Chart_X, Chart_Y, Chart_W, Chart_H,
                 (R => 16#01#, G => 16#02#, B => 16#0A#, A => 255));

      --  dB grid lines + labels
      declare
         Grid_DBs : constant array (1 .. 5) of Integer :=
                      [-10, -20, -40, -60, -80];
      begin
         for I in Grid_DBs'Range loop
            declare
               GY  : constant int := DB_To_Y (Float (Grid_DBs (I)));
               Lbl : constant String :=
                       (if Grid_DBs (I) > -10
                        then " " & Integer'Image (Grid_DBs (I))
                        else Integer'Image (Grid_DBs (I)));
            begin
               Dummy := SDL_SetRenderDrawColor
                 (Rend, 16#11#, 16#18#, 16#30#, 255);
               Dummy := SDL_RenderDrawLine
                 (Rend, Chart_X, GY, Chart_X + Chart_W - 1, GY);
               Draw_String (Rend, Pop_X + 2, GY - Char_H / 2,
                            Lbl, Col_Label);
            end;
         end loop;
      end;

      --  Update peak hold and draw bars
      for B in 0 .. Spectrum.Num_Bars - 1 loop
         declare
            DB : constant Float := Bars (B);
            BX : constant int   :=
                   Chart_X + int (B) * (Bar_W + 1);
            BY : constant int   := DB_To_Y (DB);
            BH : constant int   := Chart_Y + Chart_H - BY;
            R, G, Bc : Unsigned_8;
         begin
            --  Update peak hold
            if DB > Peak_Hold (B) then
               Peak_Hold (B) := DB;
            else
               Peak_Hold (B) := Float'Max (-80.0, Peak_Hold (B) - 1.0);
            end if;

            --  Bar fill
            if BH > 0 then
               Bar_Color (DB, R, G, Bc);
               Fill_Rect (Rend, BX, BY, Bar_W, BH,
                          (R => R, G => G, B => Bc, A => 255));
            end if;

            --  Peak hold line
            declare
               PY : constant int := DB_To_Y (Peak_Hold (B));
            begin
               if PY >= Chart_Y and PY < Chart_Y + Chart_H then
                  Dummy := SDL_SetRenderDrawColor
                    (Rend, 255, 255, 255, 255);
                  Dummy := SDL_RenderDrawLine
                    (Rend, BX, PY, BX + Bar_W - 1, PY);
               end if;
            end;
         end;
      end loop;

      --  Frequency axis labels
      declare
         type Freq_Label is record
            Hz  : Positive;
            Txt : String (1 .. 5);
         end record;
         Labels : constant array (1 .. 9) of Freq_Label :=
           [(50,    " 50Hz"),
            (100,   "100Hz"),
            (200,   "200Hz"),
            (500,   "500Hz"),
            (1000,  " 1kHz"),
            (2000,  " 2kHz"),
            (5000,  " 5kHz"),
            (10000, "10kHz"),
            (20000, "20kHz")];
         F_Min     : constant Float := 20.0;
         F_Max     : constant Float := 20_000.0;
         Log_Range : constant Float :=
                       Ada.Numerics.Elementary_Functions.Log (F_Max / F_Min);
         Label_Y   : constant int := Chart_Y + Chart_H + 4;
      begin
         for I in Labels'Range loop
            declare
               F   : constant Float := Float (Labels (I).Hz);
               Frac : constant Float :=
                        Ada.Numerics.Elementary_Functions.Log (F / F_Min)
                        / Log_Range;
               LX  : constant int :=
                       Chart_X
                       + int (Frac * Float (Chart_W))
                       - 2 * Char_W;
            begin
               if LX >= Chart_X and LX + 5 * Char_W < Chart_X + Chart_W then
                  Draw_String (Rend, LX, Label_Y, Labels (I).Txt, Col_Label);
               end if;
            end;
         end loop;
      end;

      --  Footer hint
      Draw_String
        (Rend,
         Pop_X + (Pop_W - 22 * Char_W) / 2,
         Pop_Y + Pop_H - Char_H - 6,
         "A: toggle  ESC: close",
         Col_Label);
   end Draw_Spectrum;

   --  ---------------------------------------------------------------
   --  Draw_Song_Info popup
   --  ---------------------------------------------------------------

   procedure Draw_Song_Info
     (Rend   : SDL_Renderer;
      S      : Song.Song_Type;
      Scroll : Natural)
   is
      Pop_W : constant int := 700;
      Pop_H : constant int := 520;
      Pop_X : constant int := (Window_W - Pop_W) / 2;
      Pop_Y : constant int := (Window_H - Pop_H) / 2;

      Sep1_Y        : constant int := Pop_Y + Char_H + 10;
      Meta_Y        : constant int := Sep1_Y + 4;
      Meta_Row_H    : constant int := Char_H + 2;
      Instr_Label_Y : constant int := Meta_Y + 3 * Meta_Row_H + 4;
      Sep2_Y        : constant int := Instr_Label_Y + Char_H + 2;
      List_Y        : constant int := Sep2_Y + 4;
      Footer_Y      : constant int := Pop_Y + Pop_H - Char_H - 6;
      List_H        : constant int := Footer_Y - List_Y;
      Vis_Rows      : constant int := List_H / Char_H;

      Inner_X  : constant int := Pop_X + 8;
      Col_W    : constant int := (Pop_W - 16) / 2;

      Dummy : int;
      pragma Unreferenced (Dummy);

      --  Strip trailing spaces
      function Trim (Str : String) return String is
         Last : Natural := Str'Last;
      begin
         while Last >= Str'First and then Str (Last) = ' ' loop
            Last := Last - 1;
         end loop;
         if Last < Str'First then return ""; end if;
         return Str (Str'First .. Last);
      end Trim;

      --  Decimal image without leading space
      function Img (N : Natural) return String is
         S : constant String := N'Image;
      begin
         return S (S'First + 1 .. S'Last);
      end Img;

      --  Instrument index list
      type Index_Array is array (1 .. Song.Max_Instruments) of Natural;
      Instr_Idx  : Index_Array := [others => 0];
      Num_Instrs : Natural     := 0;

   begin
      --  Build instrument index
      for I in 1 .. Song.Max_Instruments loop
         if S.Instruments (I).Num_Samples > 0 then
            Num_Instrs := Num_Instrs + 1;
            Instr_Idx (Num_Instrs) := I;
         end if;
      end loop;

      --  Semi-transparent overlay
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_BLEND);
      Dummy := SDL_SetRenderDrawColor (Rend, 0, 0, 0, 160);
      declare
         R : aliased SDL_Rect := (0, 0, Window_W, Window_H);
      begin
         Dummy := SDL_RenderFillRect (Rend, R'Access);
      end;
      Dummy := SDL_SetRenderDrawBlendMode (Rend, SDL_BLENDMODE_NONE);

      --  Popup background
      Fill_Rect (Rend, Pop_X, Pop_Y, Pop_W, Pop_H,
                 (R => 16#04#, G => 16#08#, B => 16#22#, A => 255));

      --  Border
      declare
         R1 : aliased SDL_Rect := (Pop_X,     Pop_Y,     Pop_W,     Pop_H);
         R2 : aliased SDL_Rect := (Pop_X + 1, Pop_Y + 1, Pop_W - 2, Pop_H - 2);
      begin
         Dummy := SDL_SetRenderDrawColor (Rend, 16#44#, 16#58#, 16#88#, 255);
         Dummy := SDL_RenderDrawRect (Rend, R1'Access);
         Dummy := SDL_SetRenderDrawColor (Rend, 16#22#, 16#33#, 16#55#, 255);
         Dummy := SDL_RenderDrawRect (Rend, R2'Access);
      end;

      --  Title
      Draw_String (Rend, Inner_X, Pop_Y + 6, "SONG INFO", Col_Note);
      Draw_String (Rend, Pop_X + Pop_W - 10 * Char_W - 8,
                   Pop_Y + 6, "I: close", Col_Label);

      --  Separator below title
      Fill_Rect (Rend, Pop_X + 2, Sep1_Y, Pop_W - 4, 1, Col_Chan_Sep);

      --  Metadata rows
      declare
         Y : int := Meta_Y;
      begin
         --  Row 1: Name
         Draw_String (Rend, Inner_X, Y, "Name:   ", Col_Label);
         Draw_String (Rend, Inner_X + 8 * Char_W, Y,
                      Pad_Right (Trim (S.Name), 30), Col_White);
         Y := Y + Meta_Row_H;

         --  Row 2: Format / channels / orders
         Draw_String (Rend, Inner_X, Y, "Format:", Col_Label);
         Draw_String (Rend, Inner_X + 8 * Char_W, Y,
                      (case S.Format is
                         when Song.Format_MOD => "MOD",
                         when Song.Format_XM  => " XM",
                         when Song.Format_S3M => "S3M",
                         when Song.Format_IT  => " IT"),
                      Col_Instr);
         Draw_String (Rend, Inner_X + 13 * Char_W, Y, "Channels:", Col_Label);
         Draw_String (Rend, Inner_X + 22 * Char_W, Y,
                      Pad_Right (Img (S.Num_Channels), 4), Col_Header_TXT);
         Draw_String (Rend, Inner_X + 27 * Char_W, Y, "Orders:", Col_Label);
         Draw_String (Rend, Inner_X + 34 * Char_W, Y,
                      Pad_Right (Img (S.Song_Length), 4), Col_Header_TXT);
         Y := Y + Meta_Row_H;

         --  Row 3: BPM / Speed / Instruments count
         Draw_String (Rend, Inner_X, Y, "BPM:", Col_Label);
         Draw_String (Rend, Inner_X + 4 * Char_W, Y,
                      Pad_Right (Img (Natural (S.BPM)), 5), Col_Header_TXT);
         Draw_String (Rend, Inner_X + 10 * Char_W, Y, "Speed:", Col_Label);
         Draw_String (Rend, Inner_X + 16 * Char_W, Y,
                      Pad_Right (Img (Natural (S.Speed)), 4), Col_Header_TXT);
         Draw_String (Rend, Inner_X + 21 * Char_W, Y, "Instruments:", Col_Label);
         Draw_String (Rend, Inner_X + 33 * Char_W, Y,
                      Img (Num_Instrs), Col_Header_TXT);
      end;

      --  Instruments section label + separator
      Draw_String (Rend, Inner_X, Instr_Label_Y, "Instruments", Col_Label);
      Fill_Rect (Rend, Pop_X + 2, Sep2_Y, Pop_W - 4, 1, Col_Chan_Sep);

      --  Instrument list (two columns) + scrollbar
      declare
         Total_Instr_Rows : constant Natural := (Num_Instrs + 1) / 2;
         Clamped_Scroll   : constant Natural :=
                              (if Total_Instr_Rows <= Natural (Vis_Rows) then 0
                               else Natural'Min (Scroll,
                                      Total_Instr_Rows - Natural (Vis_Rows)));
         Name_Chars       : constant Natural :=
                              Natural (Col_W / Char_W) - 4;
      begin
         for Row in 0 .. Natural (Vis_Rows) - 1 loop
            declare
               L_Idx : constant Natural := (Clamped_Scroll + Row) * 2 + 1;
               R_Idx : constant Natural := L_Idx + 1;
               Ry    : constant int     := List_Y + int (Row) * Char_H;
            begin
               if L_Idx <= Num_Instrs then
                  declare
                     I    : constant Natural := Instr_Idx (L_Idx);
                     Name : constant String  :=
                              Pad_Right (Trim (S.Instruments (I).Name), Name_Chars);
                  begin
                     Draw_String (Rend, Inner_X, Ry, Hex_Byte (I), Col_Instr);
                     Draw_String (Rend, Inner_X + 3 * Char_W, Ry, Name, Col_Header_TXT);
                  end;
               end if;

               if R_Idx <= Num_Instrs then
                  declare
                     I    : constant Natural := Instr_Idx (R_Idx);
                     Rx   : constant int     := Inner_X + Col_W;
                     Name : constant String  :=
                              Pad_Right (Trim (S.Instruments (I).Name), Name_Chars);
                  begin
                     Draw_String (Rend, Rx, Ry, Hex_Byte (I), Col_Instr);
                     Draw_String (Rend, Rx + 3 * Char_W, Ry, Name, Col_Header_TXT);
                  end;
               end if;
            end;
         end loop;

         --  Scrollbar
         if Total_Instr_Rows > Natural (Vis_Rows) then
            declare
               SB_X    : constant int := Pop_X + Pop_W - 6;
               Overflow : constant int :=
                            int (Total_Instr_Rows) - Vis_Rows;
               Thumb_H : constant int :=
                           int'Max (4,
                             int'Min (List_H,
                               List_H * Vis_Rows / int (Total_Instr_Rows)));
               Thumb_Y : constant int :=
                           List_Y
                           + (List_H - Thumb_H) * int (Clamped_Scroll)
                             / Overflow;
            begin
               Fill_Rect (Rend, SB_X, List_Y, 4, List_H, Col_Chan_Sep);
               Fill_Rect (Rend, SB_X, Thumb_Y, 4, Thumb_H, Col_Label);
            end;
         end if;
      end;

      --  Footer hint
      Draw_String
        (Rend,
         Pop_X + (Pop_W - 32 * Char_W) / 2,
         Footer_Y,
         "UP/DOWN: scroll  I or ESC: close",
         Col_Label);
   end Draw_Song_Info;

   --  ---------------------------------------------------------------
   --  Draw
   --  ---------------------------------------------------------------

   procedure Draw
     (Rend        : SDL_Renderer;
      S           : Song.Song_Type;
      Pos         : Sequencer.Position;
      Show_About  : Boolean := False;
      About_Frame : Natural := 0)
   is
      Dummy : int;
      pragma Unreferenced (Dummy);
   begin
      --  Clear
      Dummy := SDL_SetRenderDrawColor (Rend,
                 Col_Background.R, Col_Background.G, Col_Background.B, 255);
      Dummy := SDL_RenderClear (Rend);

      Draw_Header         (Rend, S, Pos);
      Draw_Channel_Info   (Rend, S);
      Draw_Pattern_Editor (Rend, S, Pos);
      Draw_Oscilloscope   (Rend);
      Draw_VU_Meters      (Rend, S.Num_Channels);

      if Show_About then
         Draw_About (Rend, About_Frame);
      end if;
   end Draw;

end Tracker_UI;
