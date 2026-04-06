-- ***************************************************************************
--                      Tracker - Bitmap Font
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
package body Bitmap_Font is

   procedure Draw_Char
     (Rend    : SDL2.SDL_Renderer;
      X, Y    : int;
      Ch      : Character;
      R, G, B : Unsigned_8)
   is
      Code : constant Integer := Character'Pos (Ch);
      Idx  : constant Integer :=
               (if Code in 32 .. 255 then Code else 63);  --  '?' for unknown
      Rows : Char_Row renames Font (Idx);
      Rect : aliased SDL2.SDL_Rect;
      Dummy : int;
      pragma Unreferenced (Dummy);
   begin
      Dummy := SDL2.SDL_SetRenderDrawColor (Rend, R, G, B, 255);
      for Row in 0 .. 7 loop
         for Col in 0 .. 7 loop
            if (Shift_Right (Rows (Row), Col) and 1) /= 0 then
               Rect := (X => X + int (Col) * Scale,
                        Y => Y + int (Row) * Scale,
                        W => Scale,
                        H => Scale);
               Dummy := SDL2.SDL_RenderFillRect (Rend, Rect'Access);
            end if;
         end loop;
      end loop;
   end Draw_Char;

   procedure Draw_String
     (Rend    : SDL2.SDL_Renderer;
      X, Y    : int;
      Str     : String;
      R, G, B : Unsigned_8)
   is
      Cx : int := X;
   begin
      for Ch of Str loop
         Draw_Char (Rend, Cx, Y, Ch, R, G, B);
         Cx := Cx + Char_W;
      end loop;
   end Draw_String;

   procedure Draw_String
     (Rend : SDL2.SDL_Renderer;
      X, Y : int;
      Str  : String;
      Col  : SDL2.SDL_Color)
   is
   begin
      Draw_String (Rend, X, Y, Str, Col.R, Col.G, Col.B);
   end Draw_String;

end Bitmap_Font;
