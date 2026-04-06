-- ***************************************************************************
--                      Tracker - Tracker Main
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
--  Tracker_Main
--  Entry point: initialise SDL2, load song, start engine, run UI loop.
--
--  Usage: tracker <file.mod|file.xm>

with Ada.Command_Line;
with Ada.Text_IO;
with Ada.Characters.Handling;
with Ada.Directories;
with Ada.Exceptions;

with SDL2;           use SDL2;
with Song;
with Channel_State;
with Mixer;
with Sequencer;
with Tracker_UI;
with Spectrum;
with Wav_Export;

with Tracker_Types;  use Tracker_Types;
with Interfaces.C;   use Interfaces.C;
with Interfaces;     use Interfaces;

procedure Tracker_Main is

   use Ada.Text_IO;
   use type Song.Load_Result;

   --  ---------------------------------------------------------------
   --  Helpers
   --  ---------------------------------------------------------------

   function Extension (Path : String) return String is
      Dot : Natural := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '.' then Dot := I; exit; end if;
      end loop;
      if Dot = 0 then return ""; end if;
      return Ada.Characters.Handling.To_Lower (Path (Dot + 1 .. Path'Last));
   end Extension;

   --  ---------------------------------------------------------------
   --  State
   --  ---------------------------------------------------------------

   Song_Data  : Song.Song_Type;
   Load_Res   : Song.Load_Result;
   Shared     : aliased Channel_State.Shared_State;
   Audio_Dev  : SDL_AudioDeviceID := 0;
   Window     : SDL_Window   := Null_Window;
   Renderer   : SDL_Renderer := Null_Renderer;
   Running     : Boolean := True;
   Event       : aliased SDL_Event;
   Paused      : Boolean := False;
   Show_About      : Boolean := False;
   About_Frame     : Natural := 0;
   Show_Spectrum   : Boolean := False;
   Show_Song_Info  : Boolean := False;
   Song_Info_Scroll : Natural := 0;

   --  File browser state
   Song_Loaded  : Boolean := False;
   Show_Browser : Boolean := False;

   --  Path of the currently loaded song (for WAV export naming)
   Song_Path     : String (1 .. 1024) := [others => ' '];
   Song_Path_Len : Natural := 0;

   Browser_Dir  : String (1 .. 1024) := [others => ' '];
   Browser_Dir_Len : Natural := 0;
   Browser_Entries : Tracker_UI.Browser_List;
   Browser_Count   : Natural := 0;
   Browser_Sel     : Natural := 1;
   Browser_Scroll  : Natural := 0;

   procedure Scan_Dir (Dir : String) is
      use Ada.Directories;
      use Ada.Characters.Handling;

      Search  : Search_Type;
      Ent     : Directory_Entry_Type;
      Count   : Natural := 0;

      function Is_Music (Name : String) return Boolean is
         Ext : constant String := To_Lower (Extension (Name));
      begin
         return Ext in "mod" | "xm" | "s3m" | "it";
      end Is_Music;

      procedure Add (Name : String; Is_Dir : Boolean) is
         L : constant Natural :=
               Natural'Min (Name'Length, Tracker_UI.Browser_Name_Max);
      begin
         if Count < Tracker_UI.Max_Browser_Entries then
            Count := Count + 1;
            Browser_Entries (Count).Name (1 .. L) :=
              Name (Name'First .. Name'First + L - 1);
            Browser_Entries (Count).Len    := L;
            Browser_Entries (Count).Is_Dir := Is_Dir;
         end if;
      end Add;

   begin
      Browser_Count := 0;
      Browser_Sel   := 1;
      Browser_Scroll := 0;

      declare
         D_Len : constant Natural :=
                   Natural'Min (Dir'Length, Browser_Dir'Length);
      begin
         Browser_Dir (1 .. D_Len) := Dir (Dir'First .. Dir'First + D_Len - 1);
         Browser_Dir_Len := D_Len;
      end;

      --  Add parent directory entry first
      Browser_Entries (1).Name (1 .. 2) := "..";
      Browser_Entries (1).Len    := 2;
      Browser_Entries (1).Is_Dir := True;
      Count := 1;

      --  Scan for subdirectories
      Start_Search (Search, Dir, "",
                    [Directory => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Ent);
         declare
            N : constant String := Simple_Name (Ent);
         begin
            if N /= "." and N /= ".." then
               Add (N, True);
            end if;
         end;
      end loop;
      End_Search (Search);

      --  Scan for music files
      Start_Search (Search, Dir, "",
                    [Ordinary_File => True, others => False]);
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Ent);
         declare
            N : constant String := Simple_Name (Ent);
         begin
            if Is_Music (N) then
               Add (N, False);
            end if;
         end;
      end loop;
      End_Search (Search);

      Browser_Count := Count;
   exception
      when others => null;  --  skip unreadable dirs
   end Scan_Dir;

   procedure Stop_Engine is
   begin
      if Song_Loaded then
         Sequencer.Sequencer_Task.Stop;
         if Audio_Dev /= 0 then
            Mixer.Shutdown (Audio_Dev);
            Audio_Dev := 0;
         end if;
         Song.Free (Song_Data);
         Song_Loaded := False;
      end if;
   end Stop_Engine;

   procedure Load_And_Start (Path : String) is
      Ext : constant String :=
              Ada.Characters.Handling.To_Lower (Extension (Path));
   begin
      Stop_Engine;

      declare
         L : constant Natural := Natural'Min (Path'Length, Song_Path'Length);
      begin
         Song_Path (1 .. L) := Path (Path'First .. Path'First + L - 1);
         Song_Path_Len := L;
      end;

      Put_Line ("Loading: " & Path);
      if Ext = "xm" then
         Song.Load_XM (Path, Song_Data, Load_Res);
      elsif Ext = "s3m" then
         Song.Load_S3M (Path, Song_Data, Load_Res);
      elsif Ext = "it" then
         Song.Load_IT (Path, Song_Data, Load_Res);
      else
         Song.Load_MOD (Path, Song_Data, Load_Res);
      end if;

      if Load_Res /= Song.OK then
         Put_Line ("Error loading: " & Path);
         return;
      end if;

      Put_Line ("Loaded: " & Song_Data.Name
                & "  ch:" & Song_Data.Num_Channels'Image
                & "  bpm:" & Song_Data.BPM'Image);

      Shared.Set_Num_Channels (Song_Data.Num_Channels);
      Mixer.Init (Song_Data, Shared'Unchecked_Access, Audio_Dev);
      Sequencer.Sequencer_Task.Start
        (Song_Data, Shared'Unchecked_Access, Mixer.Output_Sample_Rate);
      Song_Loaded := True;
      Paused := False;
   end Load_And_Start;

begin
   --  ---------------------------------------------------------------
   --  Command line (optional - no arg opens the file browser)
   --  ---------------------------------------------------------------
   if Ada.Command_Line.Argument_Count >= 1 then
      declare
         Path : constant String := Ada.Command_Line.Argument (1);
         Ext  : constant String := Extension (Path);
      begin
         Put_Line ("Loading: " & Path);

         if Ext = "xm" then
            Song.Load_XM (Path, Song_Data, Load_Res);
         elsif Ext = "s3m" then
            Song.Load_S3M (Path, Song_Data, Load_Res);
         elsif Ext = "it" then
            Song.Load_IT (Path, Song_Data, Load_Res);
         else
            Song.Load_MOD (Path, Song_Data, Load_Res);
         end if;

         case Load_Res is
            when Song.OK =>
               Put_Line ("Loaded: " & Song_Data.Name
                         & "  ch:" & Song_Data.Num_Channels'Image
                         & "  ord:" & Song_Data.Song_Length'Image
                         & "  bpm:" & Song_Data.BPM'Image);
               Song_Loaded := True;
               declare
                  L : constant Natural :=
                        Natural'Min (Path'Length, Song_Path'Length);
               begin
                  Song_Path (1 .. L) := Path (Path'First .. Path'First + L - 1);
                  Song_Path_Len := L;
               end;
            when Song.File_Not_Found =>
               Put_Line ("Error: file not found: " & Path);
            when Song.Bad_Format =>
               Put_Line ("Error: unrecognised format: " & Path);
            when Song.IO_Error =>
               Put_Line ("Error: I/O error reading: " & Path);
         end case;
      end;
   end if;

   --  ---------------------------------------------------------------
   --  SDL2 init
   --  ---------------------------------------------------------------
   if SDL_Init (SDL_INIT_VIDEO or SDL_INIT_AUDIO) /= 0 then
      Put_Line ("SDL_Init failed");
      return;
   end if;

   Window := SDL_CreateWindow
     (To_C ("AdaTracker"),
      SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
      int (Tracker_UI.Window_W), int (Tracker_UI.Window_H),
      SDL_WINDOW_SHOWN);

   if Window = Null_Window then
      Put_Line ("SDL_CreateWindow failed");
      SDL_Quit;
      return;
   end if;

   Renderer := SDL_CreateRenderer
     (Window, -1,
      SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);

   if Renderer = Null_Renderer then
      --  Try software renderer as fallback
      Renderer := SDL_CreateRenderer (Window, -1, 0);
   end if;

   if Renderer = Null_Renderer then
      Put_Line ("SDL_CreateRenderer failed");
      SDL_DestroyWindow (Window);
      SDL_Quit;
      return;
   end if;

   --  ---------------------------------------------------------------
   --  Engine init (only if a song was pre-loaded from command line)
   --  ---------------------------------------------------------------
   if Song_Loaded then
      Shared.Set_Num_Channels (Song_Data.Num_Channels);
      Mixer.Init (Song_Data, Shared'Unchecked_Access, Audio_Dev);

      if Audio_Dev = 0 then
         Put_Line ("Warning: could not open audio device, continuing silently");
      end if;

      Sequencer.Sequencer_Task.Start
        (Song_Data, Shared'Unchecked_Access, Mixer.Output_Sample_Rate);
   else
      --  No song: open file browser at current directory
      Show_Browser := True;
      Scan_Dir (Ada.Directories.Current_Directory);
   end if;

   --  ---------------------------------------------------------------
   --  Event / render loop (~60 fps via VSYNC or SDL_Delay)
   --  ---------------------------------------------------------------
   loop
      --  Process all pending events
      while SDL_PollEvent (Event'Access) /= 0 loop
         case Event_Type (Event) is

            when SDL_EVENT_QUIT =>
               Running := False;

            when SDL_EVENT_KEYDOWN =>
               if not Key_Repeat (Event) then
                  if Show_Browser then
                     --  File browser key handling
                     case Key_Scancode (Event) is

                        when SDL_SCANCODE_ESCAPE =>
                           if Song_Loaded then
                              Show_Browser := False;
                           else
                              Running := False;
                           end if;

                        when SDL_SCANCODE_UP =>
                           if Browser_Sel > 1 then
                              Browser_Sel := Browser_Sel - 1;
                              if Browser_Sel <= Browser_Scroll then
                                 Browser_Scroll := Browser_Sel - 1;
                              end if;
                           end if;

                        when SDL_SCANCODE_DOWN =>
                           if Browser_Sel < Browser_Count then
                              Browser_Sel := Browser_Sel + 1;
                              declare
                                 Vis : constant Natural := 24;
                              begin
                                 if Browser_Sel > Browser_Scroll + Vis then
                                    Browser_Scroll := Browser_Sel - Vis;
                                 end if;
                              end;
                           end if;

                        when SDL_SCANCODE_RETURN =>
                           if Browser_Sel in 1 .. Browser_Count then
                              declare
                                 E : Tracker_UI.Browser_Entry renames
                                       Browser_Entries (Browser_Sel);
                                 Name : constant String :=
                                          E.Name (1 .. E.Len);
                              begin
                                 if E.Is_Dir then
                                    --  Navigate into directory
                                    declare
                                       New_Dir : constant String :=
                                         (if Name = ".."
                                          then Ada.Directories.Containing_Directory
                                                 (Browser_Dir (1 .. Browser_Dir_Len))
                                          else Ada.Directories.Compose
                                                 (Browser_Dir (1 .. Browser_Dir_Len),
                                                  Name));
                                    begin
                                       Scan_Dir (New_Dir);
                                    end;
                                 else
                                    --  Load music file
                                    declare
                                       Full : constant String :=
                                                Ada.Directories.Compose
                                                  (Browser_Dir (1 .. Browser_Dir_Len),
                                                   Name);
                                    begin
                                       Load_And_Start (Full);
                                       if Song_Loaded then
                                          Show_Browser := False;
                                       end if;
                                    end;
                                 end if;
                              end;
                           end if;

                        when others => null;
                     end case;

                  else
                     --  Normal playback key handling
                     case Key_Scancode (Event) is

                        when SDL_SCANCODE_ESCAPE =>
                           if Show_Spectrum then
                              Show_Spectrum := False;
                           elsif Show_Song_Info then
                              Show_Song_Info  := False;
                              Song_Info_Scroll := 0;
                           else
                              Running := False;
                           end if;

                        when SDL_SCANCODE_A =>
                           Show_Spectrum := not Show_Spectrum;

                        when SDL_SCANCODE_I =>
                           if Song_Loaded then
                              Show_Song_Info   := not Show_Song_Info;
                              Song_Info_Scroll := 0;
                           end if;

                        when SDL_SCANCODE_UP =>
                           if Show_Song_Info and Song_Info_Scroll > 0 then
                              Song_Info_Scroll := Song_Info_Scroll - 1;
                           end if;

                        when SDL_SCANCODE_DOWN =>
                           if Show_Song_Info then
                              Song_Info_Scroll := Song_Info_Scroll + 1;
                           end if;

                        when SDL_SCANCODE_O =>
                           --  Open file browser
                           Show_Browser := True;
                           Scan_Dir (Ada.Directories.Current_Directory);

                        when SDL_SCANCODE_W =>
                           --  Export current song to WAV
                           if not Song_Loaded then
                              Put_Line ("W: no song loaded");
                           elsif Song_Path_Len = 0 then
                              Put_Line ("W: song path unknown");
                           end if;
                           if Song_Loaded and Song_Path_Len > 0 then
                              declare
                                 Base : constant String :=
                                          Song_Path (1 .. Song_Path_Len);
                                 Dot  : Natural := 0;
                              begin
                                 for I in reverse Base'Range loop
                                    if Base (I) = '.' then Dot := I; exit; end if;
                                 end loop;
                                 declare
                                    Out_Path : constant String :=
                                      (if Dot > 0
                                       then Base (Base'First .. Dot) & "wav"
                                       else Base & ".wav");
                                 begin
                                    Put_Line ("Exporting: " & Out_Path);
                                    Wav_Export.Render (Song_Data, Out_Path);
                                    Put_Line ("Export done: " & Out_Path);
                                 end;
                              exception
                                 when E : others =>
                                    Put_Line ("Export failed: "
                                      & Ada.Exceptions.Exception_Message (E));
                              end;
                           end if;

                        when SDL_SCANCODE_SPACE =>
                           --  Toggle pause
                           if Paused then
                              if Audio_Dev /= 0 then
                                 SDL_PauseAudioDevice (Audio_Dev, 0);
                              end if;
                              Sequencer.Transport.Set_State (Sequencer.Playing);
                              Paused := False;
                           else
                              if Audio_Dev /= 0 then
                                 SDL_PauseAudioDevice (Audio_Dev, 1);
                              end if;
                              Sequencer.Transport.Set_State (Sequencer.Paused);
                              Paused := True;
                           end if;

                        --  +/- : adjust BPM
                        when SDL_SCANCODE_PAGEUP =>
                           declare
                              B : constant BPM_Value := Sequencer.Transport.BPM;
                           begin
                              if B < BPM_Value'Last then
                                 Sequencer.Transport.Set_BPM (B + 1);
                              end if;
                           end;

                        when SDL_SCANCODE_PAGEDOWN =>
                           declare
                              B : constant BPM_Value := Sequencer.Transport.BPM;
                           begin
                              if B > BPM_Value'First then
                                 Sequencer.Transport.Set_BPM (B - 1);
                              end if;
                           end;

                        --  Left/right: navigate orders
                        when SDL_SCANCODE_RIGHT =>
                           declare
                              Cur : constant Natural :=
                                      Sequencer.Playback_Pos.Get.Order;
                           begin
                              Sequencer.Sequencer_Task.Jump_To
                                (Natural'Min (Song_Data.Song_Length - 1, Cur + 1));
                           end;

                        when SDL_SCANCODE_LEFT =>
                           declare
                              Cur : constant Natural :=
                                      Sequencer.Playback_Pos.Get.Order;
                           begin
                              if Cur > 0 then
                                 Sequencer.Sequencer_Task.Jump_To (Cur - 1);
                              end if;
                           end;

                        --  F1-F8: mute channels (F5 = jump to start)
                        when SDL_SCANCODE_F1 .. SDL_SCANCODE_F8 =>
                           if Key_Scancode (Event) = SDL_SCANCODE_F5 then
                              Sequencer.Sequencer_Task.Jump_To (0);
                           else
                              declare
                                 Ch : constant Channel_Index :=
                                        Channel_Index
                                          (Key_Scancode (Event) - SDL_SCANCODE_F1);
                              begin
                                 if Ch < Channel_Index (Song_Data.Num_Channels) then
                                    Shared.Mute (Ch, not Shared.Muted (Ch));
                                 end if;
                              end;
                           end if;

                        when others => null;
                     end case;
                  end if;
               end if;

            when SDL_EVENT_MOUSEDOWN =>
               if Mouse_Button (Event) = 3 then
                  Show_About  := not Show_About;
                  About_Frame := 0;
               end if;

            when others => null;
         end case;
      end loop;

      exit when not Running;

      --  Advance about animation
      if Show_About then
         About_Frame := About_Frame + 1;
      end if;

      --  Draw frame - all layers, one SDL_RenderPresent at the end
      declare
         Dummy : int;
         pragma Unreferenced (Dummy);
      begin
         if Song_Loaded then
            Tracker_UI.Draw (Renderer, Song_Data, Sequencer.Playback_Pos.Get,
                             Show_About, About_Frame);
         else
            Dummy := SDL_SetRenderDrawColor (Renderer, 0, 0, 16#14#, 255);
            Dummy := SDL_RenderClear (Renderer);
         end if;

         if Show_Song_Info and Song_Loaded then
            Tracker_UI.Draw_Song_Info
              (Renderer, Song_Data, Song_Info_Scroll);
         end if;

         if Show_Spectrum then
            Tracker_UI.Draw_Spectrum
              (Renderer,
               Spectrum.Compute_Bars (Spectrum.Capture.Snapshot),
               About_Frame);
         end if;

         if Show_Browser then
            Tracker_UI.Draw_File_Browser
              (Renderer,
               Browser_Dir (1 .. Browser_Dir_Len),
               Browser_Entries,
               Browser_Count,
               Browser_Sel,
               Browser_Scroll);
         end if;

         SDL_RenderPresent (Renderer);
      end;

      --  Without VSYNC we cap at ~60 fps
      if Audio_Dev = 0 then
         SDL_Delay (16);
      end if;
   end loop;

   --  ---------------------------------------------------------------
   --  Cleanup
   --  ---------------------------------------------------------------
   Stop_Engine;

   SDL_DestroyRenderer (Renderer);
   SDL_DestroyWindow (Window);
   SDL_Quit;

end Tracker_Main;
