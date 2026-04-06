-- ***************************************************************************
--                      Tracker - Sequencer
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
with Ada.Real_Time;
with Interfaces; use Interfaces;
with Mixer;
with Sequencer_Engine;

package body Sequencer is

   use Song;

   --  ---------------------------------------------------------------
   --  Protected bodies
   --  ---------------------------------------------------------------

   protected body Playback_Pos is
      procedure Set (P : Position) is begin Pos := P; end Set;
      function  Get return Position  is begin return Pos; end Get;
   end Playback_Pos;

   protected body Transport is
      procedure Set_State (S : Transport_State) is begin Current     := S;   end Set_State;
      function  State     return Transport_State  is begin return Current;    end State;
      procedure Set_BPM   (B : BPM_Value)         is begin Current_BPM := B;  end Set_BPM;
      procedure Set_Speed (S : Tick_Value)         is begin Current_Spd := S;  end Set_Speed;
      function  BPM       return BPM_Value         is begin return Current_BPM; end BPM;
      function  Speed     return Tick_Value        is begin return Current_Spd; end Speed;
   end Transport;

   --  ---------------------------------------------------------------
   --  Sequencer task body
   --  (Trigger_Row / Process_Effects are in Sequencer_Engine so they
   --   can be shared with the offline WAV renderer.)
   --  ---------------------------------------------------------------

   task body Sequencer_Task is
      use Ada.Real_Time;

      S_Local    : Song.Song_Type;
      St         : Shared_State_Ptr;
      Out_Hz     : Positive := Mixer.Output_Sample_Rate;

      --  Playback cursors
      Order_Idx  : Natural       := 0;
      Row_Idx    : Natural       := 0;
      Tick_Count : Natural       := 0;

      --  Jump request
      Pending_Jump : Boolean := False;
      Jump_Order   : Natural := 0;

      --  Pattern break / order jump from effect
      Jump_To_Order   : Boolean := False;
      Jump_Order_Val  : Natural := 0;
      Break_To_Row    : Boolean := False;
      Break_Row_Val   : Natural := 0;

      --  Pattern loop (E6x) and pattern delay (EEx)
      Pattern_Loop_Row     : Natural := 0;
      Pattern_Loop_Count   : Natural := 0;
      Do_Pattern_Loop      : Boolean := False;
      Pattern_Delay_Remain : Natural := 0;

      Running : Boolean := False;

      Next_Tick : Time;

      function Tick_Span return Time_Span is
         BPM_F : constant Float := Float (Transport.BPM);
      begin
         return To_Time_Span (Duration (2.5 / BPM_F));
      end Tick_Span;

      Song_Restarted : Boolean := False;

      procedure Advance_Row is
      begin
         Row_Idx := Row_Idx + 1;
         if Row_Idx >= S_Local.Patterns
               (S_Local.Orders (Order_Idx)).Num_Rows
         then
            Row_Idx   := 0;
            Order_Idx := Order_Idx + 1;
            if Order_Idx >= S_Local.Song_Length then
               Order_Idx    := S_Local.Restart_Pos;
               Song_Restarted := True;
            end if;
         end if;
      end Advance_Row;

      procedure Process_Tick is
         Pat : Song.Pattern renames
                 S_Local.Patterns (S_Local.Orders (Order_Idx));
      begin
         --  On tick 0: read and trigger the row
         if Tick_Count = 0 then
            for Ch_Idx in Channel_Index range
                            0 .. Channel_Index (S_Local.Num_Channels - 1)
            loop
               declare
                  Cell : constant Pattern_Cell :=
                           Song.Cell (Pat, Row_Index (Row_Idx), Ch_Idx);
                  Ch   : Channel_State.Channel := St.Get_Channel (Ch_Idx);
               begin
                  --  IT NNA: before triggering a new note, handle old voice
                  if S_Local.Format = Song.Format_IT
                    and then Ch.Active
                    and then Ch.Instrument /= 0
                    and then Cell.Note not in Note_Empty | Note_Key_Off
                    and then Cell.Effect /= Effect_Tone_Porta
                    and then Cell.Effect /= 16#05#
                  then
                     declare
                        NNA : constant Natural :=
                                S_Local.Instruments (Ch.Instrument).NNA;
                     begin
                        if NNA > 0 then
                           for BG in Channel_Index range
                               Channel_Index (Channel_State.Max_Song_Channels)
                               .. Channel_Index (Channel_State.Max_Channels - 1)
                           loop
                              if not St.Get_Channel (BG).Active then
                                 St.Update_Channel (BG, Ch);
                                 declare
                                    BG_Ch : Channel_State.Channel :=
                                              St.Get_Channel (BG);
                                 begin
                                    if NNA >= 2 then
                                       BG_Ch.Key_On := False;
                                    end if;
                                    St.Update_Channel (BG, BG_Ch);
                                 end;
                                 exit;
                              end if;
                           end loop;
                        end if;
                     end;
                  end if;

                  Sequencer_Engine.Trigger_Row (Cell, Ch, S_Local, Out_Hz);

                  --  Song-level effects (Bxx, Dxx, Fxx, E6x, EEx) - row 0
                  if Cell.Effect = Effect_Jump_To_Order then
                     Jump_To_Order  := True;
                     Jump_Order_Val := Natural (Cell.Param);
                  elsif Cell.Effect = Effect_Pattern_Break then
                     Break_To_Row  := True;
                     Break_Row_Val :=
                       Natural (Shift_Right (Cell.Param, 4)) * 10
                       + Natural (Cell.Param and 16#0F#);
                  elsif Cell.Effect = Effect_Set_Speed then
                     if Cell.Param < 32 then
                        Transport.Set_Speed (
                          Tick_Value'Max (1,
                            Tick_Value'Min (Tick_Value'Last,
                              Tick_Value (Cell.Param))));
                     else
                        Transport.Set_BPM (
                          BPM_Value'Max (BPM_Value'First,
                            BPM_Value'Min (BPM_Value'Last,
                              BPM_Value (Cell.Param))));
                     end if;
                  elsif Cell.Effect = Effect_Extended then
                     declare
                        Sub : constant Natural :=
                                Natural (Shift_Right (Cell.Param, 4));
                        Prm : constant Natural :=
                                Natural (Cell.Param and 16#0F#);
                     begin
                        if Sub = 16#6# then  --  E6x: pattern loop
                           if Prm = 0 then
                              Pattern_Loop_Row := Row_Idx;
                           else
                              if Pattern_Loop_Count = 0 then
                                 Pattern_Loop_Count := Prm;
                              else
                                 Pattern_Loop_Count :=
                                   Pattern_Loop_Count - 1;
                              end if;
                              if Pattern_Loop_Count > 0 then
                                 Do_Pattern_Loop := True;
                              end if;
                           end if;
                        elsif Sub = 16#E# then  --  EEx: pattern delay
                           Pattern_Delay_Remain := Prm;
                        end if;
                     end;
                  end if;

                  --  MOD Amiga hard panning: ch 0,3=left  ch 1,2=right
                  if S_Local.Format = Song.Format_MOD and Ch.Active then
                     case Ch_Idx mod 4 is
                        when 0 | 3 => Ch.Panning := -0.75;
                        when others => Ch.Panning :=  0.75;
                     end case;
                  end if;

                  --  S3M / IT per-channel default panning (applied on note trigger)
                  if S_Local.Format in Song.Format_S3M | Song.Format_IT
                    and Cell.Note not in Note_Empty | Note_Key_Off
                  then
                     Ch.Panning :=
                       Float (S_Local.Channel_Pan (Ch_Idx)) / 128.0;
                  end if;

                  St.Update_Channel (Ch_Idx, Ch);
               end;
            end loop;
         end if;

         --  Every tick: process running effects
         declare
            Cur_BPM : BPM_Value := Transport.BPM;
         begin
            for Ch_Idx in Channel_Index range
                             0 .. Channel_Index (S_Local.Num_Channels - 1)
            loop
               declare
                  Pat2 : Song.Pattern renames
                           S_Local.Patterns (S_Local.Orders (Order_Idx));
                  Cell : constant Pattern_Cell :=
                           Song.Cell (Pat2, Row_Index (Row_Idx), Ch_Idx);
                  Ch   : Channel_State.Channel := St.Get_Channel (Ch_Idx);
                  New_BPM : BPM_Value := Cur_BPM;
               begin
                  Sequencer_Engine.Process_Effects
                    (Cell, Ch, S_Local, Tick_Count, Out_Hz, New_BPM);
                  St.Update_Channel (Ch_Idx, Ch);
                  if New_BPM /= Cur_BPM then
                     Transport.Set_BPM (New_BPM);
                     Cur_BPM := New_BPM;
                  end if;
               end;
            end loop;
         end;

         --  Every tick: advance envelopes on IT NNA background voices
         if S_Local.Format = Song.Format_IT then
            for BG in Channel_Index range
                Channel_Index (Channel_State.Max_Song_Channels)
                .. Channel_Index (Channel_State.Max_Channels - 1)
            loop
               declare
                  BG_Ch : Channel_State.Channel := St.Get_Channel (BG);
               begin
                  if BG_Ch.Active and then BG_Ch.Instrument /= 0 then
                     declare
                        Inst : Song.Instrument renames
                                 S_Local.Instruments (BG_Ch.Instrument);
                     begin
                        Channel_State.Advance_Envelope
                          (BG_Ch.Vol_Env, Inst.Vol_Env, BG_Ch.Key_On);
                        Channel_State.Advance_Envelope
                          (BG_Ch.Pan_Env, Inst.Pan_Env, BG_Ch.Key_On);
                        if not BG_Ch.Key_On and then Inst.Fadeout > 0 then
                           BG_Ch.Fadeout_Vol := Float'Max (0.0,
                             BG_Ch.Fadeout_Vol
                               - Float (Inst.Fadeout) / 65536.0);
                        end if;
                        if BG_Ch.Fadeout_Vol <= 0.0 then
                           BG_Ch.Active := False;
                        end if;
                     end;
                     St.Update_Channel (BG, BG_Ch);
                  end if;
               end;
            end loop;
         end if;

         --  Publish position
         Playback_Pos.Set ((Order   => Order_Idx,
                            Pattern => S_Local.Orders (Order_Idx),
                            Row     => Row_Index (Row_Idx),
                            Tick    => Tick_Count));

         --  Advance tick counter
         Tick_Count := Tick_Count + 1;
         if Tick_Count >= Natural (Transport.Speed) then
            Tick_Count := 0;

            --  Handle song-structure effects at end of row
            if Do_Pattern_Loop then
               Do_Pattern_Loop := False;
               Row_Idx         := Pattern_Loop_Row;
            elsif Pattern_Delay_Remain > 0 then
               Pattern_Delay_Remain := Pattern_Delay_Remain - 1;
               Tick_Count           := 1;  --  replay ticks 1..Speed-1 only
            elsif Jump_To_Order then
               Jump_To_Order := False;
               Order_Idx     := Natural'Min (Jump_Order_Val,
                                             S_Local.Song_Length - 1);
               Row_Idx       := 0;
               Pattern_Loop_Row   := 0;
               Pattern_Loop_Count := 0;
            elsif Break_To_Row then
               Break_To_Row := False;
               Order_Idx    := Order_Idx + 1;
               if Order_Idx >= S_Local.Song_Length then
                  Order_Idx := S_Local.Restart_Pos;
               end if;
               Row_Idx := Natural'Min (Break_Row_Val,
                 S_Local.Patterns (S_Local.Orders (Order_Idx)).Num_Rows - 1);
               Pattern_Loop_Row   := 0;
               Pattern_Loop_Count := 0;
            else
               Advance_Row;
               if Song_Restarted then
                  Song_Restarted := False;
                  --  Reset all channels so stale fadeout/envelope state
                  --  from end-of-song does not silence the next loop.
                  for I in Channel_Index range
                             0 .. Channel_Index (S_Local.Num_Channels - 1)
                  loop
                     declare
                        Ch : Channel_State.Channel := St.Get_Channel (I);
                     begin
                        Ch.Active         := False;
                        Ch.Key_On         := False;
                        Ch.Fadeout_Vol    := 1.0;
                        Ch.Tremolo_Offset := 0.0;
                        St.Update_Channel (I, Ch);
                     end;
                  end loop;
                  --  Also clear NNA background voices
                  for I in Channel_Index range
                      Channel_Index (Channel_State.Max_Song_Channels)
                      .. Channel_Index (Channel_State.Max_Channels - 1)
                  loop
                     declare
                        Ch : Channel_State.Channel := St.Get_Channel (I);
                     begin
                        Ch.Active := False;
                        St.Update_Channel (I, Ch);
                     end;
                  end loop;
               end if;
            end if;
         end if;
      end Process_Tick;

   begin
      loop
         --  Wait for Start
         select
            accept Start
              (S         : Song.Song_Type;
               State     : Shared_State_Ptr;
               Output_Hz : Positive)
            do
               S_Local   := S;
               St        := State;
               Out_Hz    := Output_Hz;
               Running   := True;
               Order_Idx := 0;
               Row_Idx   := 0;
               Tick_Count := 0;
               Pending_Jump := False;
               Transport.Set_BPM   (S_Local.BPM);
               Transport.Set_Speed (S_Local.Speed);
               Transport.Set_State (Playing);
               St.Reset_Channels;
            end Start;
         or
            terminate;
         end select;

         Next_Tick := Clock;

         while Running loop
            Next_Tick := Next_Tick + Tick_Span;

            --  Check for stop or jump before each tick
            select
               accept Stop do
                  Running := False;
                  Transport.Set_State (Stopped);
               end Stop;
            or
               accept Jump_To (Order : Natural) do
                  Pending_Jump := True;
                  Jump_Order   := Order;
               end Jump_To;
            else
               null;
            end select;

            exit when not Running;

            if Pending_Jump then
               Pending_Jump := False;
               Order_Idx    := Natural'Min (Jump_Order,
                                            S_Local.Song_Length - 1);
               Row_Idx      := 0;
               Tick_Count   := 0;
            end if;

            begin
               Process_Tick;
            exception
               when others =>
                  --  Skip the bad tick; do not let the task die.
                  null;
            end;

            delay until Next_Tick;
         end loop;
      end loop;
   end Sequencer_Task;

end Sequencer;
