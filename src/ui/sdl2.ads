-- ***************************************************************************
--                      Tracker - SDL2 Bindings
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
--  SDL2
--  Thin Ada bindings to SDL2.
--  Only what the tracker needs: window, renderer, audio, events.
--  All functions use C calling convention; link with -lSDL2.

with Interfaces;   use Interfaces;
with Interfaces.C; use Interfaces.C;
with System;

package SDL2 is

   --  ---------------------------------------------------------------
   --  Fundamental types
   --  ---------------------------------------------------------------
   subtype SDL_Bool   is int;
   SDL_False : constant SDL_Bool := 0;
   SDL_True  : constant SDL_Bool := 1;

   type SDL_Window   is new System.Address;
   type SDL_Renderer is new System.Address;

   Null_Window   : constant SDL_Window   := SDL_Window   (System.Null_Address);
   Null_Renderer : constant SDL_Renderer := SDL_Renderer (System.Null_Address);

   --  ---------------------------------------------------------------
   --  Init flags
   --  ---------------------------------------------------------------
   SDL_INIT_AUDIO : constant Unsigned_32 := 16#00000010#;
   SDL_INIT_VIDEO : constant Unsigned_32 := 16#00000020#;

   --  ---------------------------------------------------------------
   --  Window flags
   --  ---------------------------------------------------------------
   SDL_WINDOW_SHOWN       : constant Unsigned_32 := 16#00000004#;
   SDL_WINDOW_RESIZABLE   : constant Unsigned_32 := 16#00000020#;
   SDL_WINDOWPOS_CENTERED : constant int         := 805240832;  -- 0x2FFF0000 | 0

   --  ---------------------------------------------------------------
   --  Renderer flags
   --  ---------------------------------------------------------------
   SDL_RENDERER_ACCELERATED : constant Unsigned_32 := 16#00000002#;
   SDL_RENDERER_PRESENTVSYNC : constant Unsigned_32 := 16#00000004#;

   --  ---------------------------------------------------------------
   --  Geometry
   --  ---------------------------------------------------------------
   type SDL_Rect is record
      X, Y, W, H : int;
   end record
     with Convention => C;

   type SDL_Point is record
      X, Y : int;
   end record
     with Convention => C;

   --  ---------------------------------------------------------------
   --  Color
   --  ---------------------------------------------------------------
   type SDL_Color is record
      R, G, B, A : Unsigned_8;
   end record
     with Convention => C;

   --  ---------------------------------------------------------------
   --  Audio
   --  ---------------------------------------------------------------
   AUDIO_S16SYS : constant Unsigned_16 := 16#8010#;  --  signed 16-bit native endian
   AUDIO_F32SYS : constant Unsigned_16 := 16#8120#;  --  32-bit float native endian

   type SDL_Audio_Callback is access procedure
     (Userdata : System.Address;
      Stream   : System.Address;
      Len      : int)
     with Convention => C;

   --  SDL_AudioSpec (C layout, 32 bytes)
   type SDL_AudioSpec is record
      Freq     : int;
      Format   : Unsigned_16;
      Channels : Unsigned_8;
      Silence  : Unsigned_8;
      Samples  : Unsigned_16;
      Padding  : Unsigned_16;
      Size     : Unsigned_32;
      Callback : SDL_Audio_Callback;
      Userdata : System.Address;
   end record
     with Convention => C;

   type SDL_AudioDeviceID is new Unsigned_32;

   SDL_AUDIO_ALLOW_FREQUENCY_CHANGE : constant int := 16#01#;
   SDL_AUDIO_ALLOW_FORMAT_CHANGE    : constant int := 16#02#;
   SDL_AUDIO_ALLOW_CHANNELS_CHANGE  : constant int := 16#04#;

   --  ---------------------------------------------------------------
   --  Events
   --  ---------------------------------------------------------------

   --  Event types (prefixed with SDL_EVENT_ to avoid clash with SDL_Quit procedure)
   SDL_EVENT_QUIT      : constant Unsigned_32 := 16#100#;
   SDL_EVENT_KEYDOWN   : constant Unsigned_32 := 16#300#;
   SDL_EVENT_KEYUP     : constant Unsigned_32 := 16#301#;
   SDL_EVENT_MOUSEDOWN : constant Unsigned_32 := 16#401#;
   SDL_EVENT_WHEEL     : constant Unsigned_32 := 16#403#;

   --  SDL_Event is a 56-byte union; represent as a byte array
   --  and extract fields with helpers below.
   Event_Size : constant := 56;
   type SDL_Event_Bytes is array (0 .. Event_Size - 1) of Unsigned_8
     with Convention => C;

   type SDL_Event is record
      Bytes : SDL_Event_Bytes;
   end record
     with Convention => C, Size => Event_Size * 8;

   --  Offsets within SDL_Event union (common to all event types)
   --  Byte 0-3: type (Uint32)
   function Event_Type (E : SDL_Event) return Unsigned_32;

   --  Key event (SDL_KeyboardEvent): same layout in all SDL2 versions
   --  Offset  Size  Field
   --  0        4    type
   --  4        4    timestamp
   --  8        4    windowID
   --  12       1    state (SDL_PRESSED=1 / SDL_RELEASED=0)
   --  13       1    repeat (non-zero if key repeat)
   --  14       2    padding
   --  16       4    scancode (SDL_Scancode)
   --  20       4    sym (SDLK keycode)
   --  24       2    mod (SDL_Keymod)
   function Key_Scancode (E : SDL_Event) return Unsigned_32;
   function Key_Sym      (E : SDL_Event) return Unsigned_32;
   function Key_Repeat   (E : SDL_Event) return Boolean;

   --  Mouse button event offsets (SDL_MouseButtonEvent)
   --  0  type, 4 ts, 8 windowID, 12 which(Uint32), 16 button, 17 state,
   --  18 clicks, 19 padding, 20 x, 24 y
   function Mouse_Button (E : SDL_Event) return Unsigned_8;
   function Mouse_X      (E : SDL_Event) return int;
   function Mouse_Y      (E : SDL_Event) return int;

   --  Mouse wheel event
   --  0 type, 4 ts, 8 windowID, 12 which, 16 x, 20 y
   function Wheel_X (E : SDL_Event) return int;
   function Wheel_Y (E : SDL_Event) return int;

   --  ---------------------------------------------------------------
   --  Scancodes (subset - what the tracker uses)
   --  ---------------------------------------------------------------
   SDL_SCANCODE_UNKNOWN  : constant := 0;
   SDL_SCANCODE_A        : constant := 4;
   SDL_SCANCODE_B        : constant := 5;
   SDL_SCANCODE_C        : constant := 6;
   SDL_SCANCODE_D        : constant := 7;
   SDL_SCANCODE_E        : constant := 8;
   SDL_SCANCODE_F        : constant := 9;
   SDL_SCANCODE_G        : constant := 10;
   SDL_SCANCODE_H        : constant := 11;
   SDL_SCANCODE_I        : constant := 12;
   SDL_SCANCODE_J        : constant := 13;
   SDL_SCANCODE_K        : constant := 14;
   SDL_SCANCODE_L        : constant := 15;
   SDL_SCANCODE_M        : constant := 16;
   SDL_SCANCODE_N        : constant := 17;
   SDL_SCANCODE_O        : constant := 18;
   SDL_SCANCODE_P        : constant := 19;
   SDL_SCANCODE_Q        : constant := 20;
   SDL_SCANCODE_R        : constant := 21;
   SDL_SCANCODE_S        : constant := 22;
   SDL_SCANCODE_T        : constant := 23;
   SDL_SCANCODE_U        : constant := 24;
   SDL_SCANCODE_V        : constant := 25;
   SDL_SCANCODE_W        : constant := 26;
   SDL_SCANCODE_X        : constant := 27;
   SDL_SCANCODE_Y        : constant := 28;
   SDL_SCANCODE_Z        : constant := 29;
   SDL_SCANCODE_1        : constant := 30;
   SDL_SCANCODE_2        : constant := 31;
   SDL_SCANCODE_3        : constant := 32;
   SDL_SCANCODE_4        : constant := 33;
   SDL_SCANCODE_5        : constant := 34;
   SDL_SCANCODE_6        : constant := 35;
   SDL_SCANCODE_7        : constant := 36;
   SDL_SCANCODE_8        : constant := 37;
   SDL_SCANCODE_9        : constant := 38;
   SDL_SCANCODE_0        : constant := 39;
   SDL_SCANCODE_RETURN   : constant := 40;
   SDL_SCANCODE_ESCAPE   : constant := 41;
   SDL_SCANCODE_BACKSPACE : constant := 42;
   SDL_SCANCODE_TAB      : constant := 43;
   SDL_SCANCODE_SPACE    : constant := 44;
   SDL_SCANCODE_F1       : constant := 58;
   SDL_SCANCODE_F2       : constant := 59;
   SDL_SCANCODE_F3       : constant := 60;
   SDL_SCANCODE_F4       : constant := 61;
   SDL_SCANCODE_F5       : constant := 62;
   SDL_SCANCODE_F6       : constant := 63;
   SDL_SCANCODE_F7       : constant := 64;
   SDL_SCANCODE_F8       : constant := 65;
   SDL_SCANCODE_F9       : constant := 66;
   SDL_SCANCODE_F10      : constant := 67;
   SDL_SCANCODE_F11      : constant := 68;
   SDL_SCANCODE_F12      : constant := 69;
   SDL_SCANCODE_INSERT   : constant := 73;
   SDL_SCANCODE_DELETE   : constant := 76;
   SDL_SCANCODE_HOME     : constant := 74;
   SDL_SCANCODE_END      : constant := 77;
   SDL_SCANCODE_PAGEUP   : constant := 75;
   SDL_SCANCODE_PAGEDOWN : constant := 78;
   SDL_SCANCODE_RIGHT    : constant := 79;
   SDL_SCANCODE_LEFT     : constant := 80;
   SDL_SCANCODE_DOWN     : constant := 81;
   SDL_SCANCODE_UP       : constant := 82;
   SDL_SCANCODE_LCTRL    : constant := 224;
   SDL_SCANCODE_LSHIFT   : constant := 225;
   SDL_SCANCODE_LALT     : constant := 226;
   SDL_SCANCODE_RCTRL    : constant := 228;
   SDL_SCANCODE_RSHIFT   : constant := 229;
   SDL_SCANCODE_RALT     : constant := 230;

   --  Modifier masks (SDL_Keymod)
   KMOD_NONE  : constant Unsigned_16 := 16#0000#;
   KMOD_LSHIFT : constant Unsigned_16 := 16#0001#;
   KMOD_RSHIFT : constant Unsigned_16 := 16#0002#;
   KMOD_LCTRL  : constant Unsigned_16 := 16#0040#;
   KMOD_RCTRL  : constant Unsigned_16 := 16#0080#;
   KMOD_LALT   : constant Unsigned_16 := 16#0100#;
   KMOD_RALT   : constant Unsigned_16 := 16#0200#;
   KMOD_SHIFT  : constant Unsigned_16 := KMOD_LSHIFT or KMOD_RSHIFT;
   KMOD_CTRL   : constant Unsigned_16 := KMOD_LCTRL  or KMOD_RCTRL;
   KMOD_ALT    : constant Unsigned_16 := KMOD_LALT   or KMOD_RALT;

   --  ---------------------------------------------------------------
   --  SDL2 C functions
   --  ---------------------------------------------------------------

   function SDL_Init (Flags : Unsigned_32) return int
     with Import, Convention => C, External_Name => "SDL_Init";

   procedure SDL_Quit
     with Import, Convention => C, External_Name => "SDL_Quit";

   function SDL_GetError return System.Address
     with Import, Convention => C, External_Name => "SDL_GetError";

   --  Window
   function SDL_CreateWindow
     (Title  : char_array;
      X, Y   : int;
      W, H   : int;
      Flags  : Unsigned_32) return SDL_Window
     with Import, Convention => C, External_Name => "SDL_CreateWindow";

   procedure SDL_DestroyWindow (Win : SDL_Window)
     with Import, Convention => C, External_Name => "SDL_DestroyWindow";

   function SDL_GetWindowSize
     (Win : SDL_Window; W, H : access int) return int
     with Import, Convention => C, External_Name => "SDL_GetWindowSize";

   --  Renderer
   function SDL_CreateRenderer
     (Win   : SDL_Window;
      Index : int;
      Flags : Unsigned_32) return SDL_Renderer
     with Import, Convention => C, External_Name => "SDL_CreateRenderer";

   procedure SDL_DestroyRenderer (Rend : SDL_Renderer)
     with Import, Convention => C, External_Name => "SDL_DestroyRenderer";

   function SDL_SetRenderDrawColor
     (Rend        : SDL_Renderer;
      R, G, B, A  : Unsigned_8) return int
     with Import, Convention => C, External_Name => "SDL_SetRenderDrawColor";

   function SDL_RenderClear (Rend : SDL_Renderer) return int
     with Import, Convention => C, External_Name => "SDL_RenderClear";

   procedure SDL_RenderPresent (Rend : SDL_Renderer)
     with Import, Convention => C, External_Name => "SDL_RenderPresent";

   function SDL_RenderFillRect
     (Rend : SDL_Renderer; Rect : access SDL_Rect) return int
     with Import, Convention => C, External_Name => "SDL_RenderFillRect";

   function SDL_RenderDrawRect
     (Rend : SDL_Renderer; Rect : access SDL_Rect) return int
     with Import, Convention => C, External_Name => "SDL_RenderDrawRect";

   function SDL_RenderDrawLine
     (Rend       : SDL_Renderer;
      X1, Y1     : int;
      X2, Y2     : int) return int
     with Import, Convention => C, External_Name => "SDL_RenderDrawLine";

   function SDL_SetRenderDrawBlendMode
     (Rend : SDL_Renderer; Mode : int) return int
     with Import, Convention => C, External_Name => "SDL_SetRenderDrawBlendMode";

   SDL_BLENDMODE_NONE  : constant int := 0;
   SDL_BLENDMODE_BLEND : constant int := 1;
   SDL_BLENDMODE_ADD   : constant int := 2;

   --  Audio
   function SDL_OpenAudioDevice
     (Device          : System.Address;  --  null = default
      Is_Capture      : int;
      Desired         : access SDL_AudioSpec;
      Obtained        : access SDL_AudioSpec;
      Allowed_Changes : int) return SDL_AudioDeviceID
     with Import, Convention => C, External_Name => "SDL_OpenAudioDevice";

   procedure SDL_CloseAudioDevice (Dev : SDL_AudioDeviceID)
     with Import, Convention => C, External_Name => "SDL_CloseAudioDevice";

   procedure SDL_PauseAudioDevice (Dev : SDL_AudioDeviceID; Pause : int)
     with Import, Convention => C, External_Name => "SDL_PauseAudioDevice";

   procedure SDL_LockAudioDevice (Dev : SDL_AudioDeviceID)
     with Import, Convention => C, External_Name => "SDL_LockAudioDevice";

   procedure SDL_UnlockAudioDevice (Dev : SDL_AudioDeviceID)
     with Import, Convention => C, External_Name => "SDL_UnlockAudioDevice";

   --  Events
   function SDL_PollEvent (Event : access SDL_Event) return int
     with Import, Convention => C, External_Name => "SDL_PollEvent";

   --  Timing
   function SDL_GetTicks return Unsigned_32
     with Import, Convention => C, External_Name => "SDL_GetTicks";

   procedure SDL_Delay (Ms : Unsigned_32)
     with Import, Convention => C, External_Name => "SDL_Delay";

private

   --  Inline helpers: extract fields from raw event bytes using
   --  little-endian byte assembly (SDL2 always uses host byte order for events)

   function U32_At (E : SDL_Event; Offset : Natural) return Unsigned_32 is
     (Unsigned_32 (E.Bytes (Offset))
      or Shift_Left (Unsigned_32 (E.Bytes (Offset + 1)), 8)
      or Shift_Left (Unsigned_32 (E.Bytes (Offset + 2)), 16)
      or Shift_Left (Unsigned_32 (E.Bytes (Offset + 3)), 24));

   function I32_At (E : SDL_Event; Offset : Natural) return int is
     (int (U32_At (E, Offset)));

   function Event_Type (E : SDL_Event) return Unsigned_32 is
     (U32_At (E, 0));

   function Key_Scancode (E : SDL_Event) return Unsigned_32 is
     (U32_At (E, 16));

   function Key_Sym (E : SDL_Event) return Unsigned_32 is
     (U32_At (E, 20));

   function Key_Repeat (E : SDL_Event) return Boolean is
     (E.Bytes (13) /= 0);

   function Mouse_Button (E : SDL_Event) return Unsigned_8 is
     (E.Bytes (16));

   function Mouse_X (E : SDL_Event) return int is (I32_At (E, 20));
   function Mouse_Y (E : SDL_Event) return int is (I32_At (E, 24));

   function Wheel_X (E : SDL_Event) return int is (I32_At (E, 16));
   function Wheel_Y (E : SDL_Event) return int is (I32_At (E, 20));

end SDL2;
