-- ***************************************************************************
--                      Tracker - Song
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
with Mod_Format;  use Mod_Format;
with XM_Format;   use XM_Format;
with S3M_Format;
with IT_Format;
with Ada.Numerics.Elementary_Functions;
with Ada.Unchecked_Deallocation;

use type S3M_Format.S3M_Sample_8;
use type S3M_Format.S3M_Sample_16;
use type S3M_Format.S3M_Cell_Array_Access;
use type IT_Format.IT_Sample_8;
use type IT_Format.IT_Sample_16;
use type IT_Format.IT_Cell_Array_Access;
use type IT_Format.IT_Mode;

package body Song is

   procedure Free_Float is new Ada.Unchecked_Deallocation
     (Float_Array, Float_Array_Access);

   --  ---------------------------------------------------------------
   --  Pattern cell accessor
   --  ---------------------------------------------------------------

   function Cell
     (Pat     : Pattern;
      Row     : Row_Index;
      Channel : Channel_Index) return Pattern_Cell
   is
      Empty : constant Pattern_Cell := [others => <>];
   begin
      if Pat.Cells = null
        or else Row >= Row_Index (Pat.Num_Rows)
        or else Channel >= Channel_Index (Pat.Num_Channels)
      then
         return Empty;
      end if;
      return Pat.Cells (Row * Row_Index (Pat.Num_Channels) + Row_Index (Channel));
   end Cell;

   --  ---------------------------------------------------------------
   --  Sample conversions helpers
   --  ---------------------------------------------------------------

   function Convert_8 (Data : Tracker_Types.Sample_Data_8)
     return Float_Array_Access
   is
      Result : constant Float_Array_Access :=
                 new Float_Array (0 .. Data'Length - 1);
   begin
      for I in Data'Range loop
         Result (I - Data'First) := Float (Data (I)) / 128.0;
      end loop;
      return Result;
   end Convert_8;

   function Convert_16 (Data : Tracker_Types.Sample_Data_16)
     return Float_Array_Access
   is
      Result : constant Float_Array_Access :=
                 new Float_Array (0 .. Data'Length - 1);
   begin
      for I in Data'Range loop
         Result (I - Data'First) := Float (Data (I)) / 32768.0;
      end loop;
      return Result;
   end Convert_16;

   --  ---------------------------------------------------------------
   --  MOD -> Song_Type conversion
   --  ---------------------------------------------------------------

   procedure Load_MOD
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result)
   is
      Mod_Song : Mod_Format.Mod_Song;
      Status   : Mod_Format.Load_Error;
   begin
      S := [others => <>];
      Mod_Format.Load (Path, Mod_Song, Status);

      case Status is
         when Mod_Format.File_Not_Found =>
            Result := File_Not_Found; return;
         when Mod_Format.Invalid_Header =>
            Result := Bad_Format; return;
         when Mod_Format.IO_Error =>
            Result := IO_Error; return;
         when Mod_Format.None => null;
      end case;

      S.Name         := Mod_Song.Name;  --  already exactly 20 chars
      S.Format       := Format_MOD;
      S.Num_Channels := Mod_Song.Num_Channels;
      S.Song_Length  := Mod_Song.Song_Length;
      S.BPM          := Mod_Song.BPM;
      S.Speed        := Mod_Song.Speed;
      S.Linear_Freq  := False;  --  MOD always uses Amiga table

      --  Orders
      for I in 0 .. Mod_Song.Song_Length - 1 loop
         S.Orders (I) := Mod_Song.Orders (I);
      end loop;

      --  Instruments (MOD: 1-31, single sample each)
      for I in 1 .. Mod_Format.Max_Instruments loop
         declare
            MH : Mod_Format.Mod_Instrument_Header
                   renames Mod_Song.Instruments (I).Header;
            MD : Mod_Format.Mod_Sample_Data
                   renames Mod_Song.Instruments (I).Data;
            SI : Instrument renames S.Instruments (I);
            SS : Song.Sample renames SI.Samples (0);
         begin
            SI.Name       := MH.Name;
            SI.Num_Samples := 1;
            --  All notes map to sample 0
            SI.Map        := [others => 0];

            SS.Name       := MH.Name;
            SS.Base_Volume :=
              Volume_Value'Min (64, Volume_Value (MH.Volume));
            SS.Finetune   := Mod_Format.Finetune_Signed (MH.Finetune) * 16;
            SS.Relative_Note := 0;

            --  Loop: loop_length = 1 means no loop in MOD
            if Natural (MH.Loop_Length) > 1 then
               SS.Loop_Kind  := Forward_Loop;
               SS.Loop_Start := Natural (MH.Loop_Start) * 2;
               SS.Loop_End   := (Natural (MH.Loop_Start)
                                   + Natural (MH.Loop_Length)) * 2;
            else
               SS.Loop_Kind  := No_Loop;
            end if;

            --  Convert 8-bit signed sample data to float
            if MD /= null then
               SS.Data := Convert_8 (MD.all);
            end if;
         end;
      end loop;

      --  Patterns
      for P in Pattern_Index loop
         declare
            MP : Mod_Format.Mod_Pattern renames Mod_Song.Patterns (P);
            SP : Song.Pattern renames S.Patterns (P);
         begin
            if MP.Cells /= null then
               SP.Num_Rows     := MP.Rows;
               SP.Num_Channels := MP.Channels;
               SP.Cells        := new Cell_Array (0 .. MP.Cells'Length - 1);
               for J in MP.Cells'Range loop
                  SP.Cells (J) := MP.Cells (J);
               end loop;
            end if;
         end;
      end loop;

      Mod_Format.Free (Mod_Song);
      Result := OK;
   end Load_MOD;

   --  ---------------------------------------------------------------
   --  XM -> Song_Type conversion
   --  ---------------------------------------------------------------

   procedure Load_XM
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result)
   is
      XS     : XM_Format.XM_Song;
      Status : XM_Format.Load_Error;
   begin
      S := [others => <>];
      XM_Format.Load (Path, XS, Status);

      case Status is
         when XM_Format.File_Not_Found      =>
            Result := File_Not_Found; return;
         when XM_Format.Invalid_Header      =>
            Result := Bad_Format; return;
         when XM_Format.Unsupported_Version =>
            Result := Bad_Format; return;
         when XM_Format.IO_Error            =>
            Result := IO_Error; return;
         when XM_Format.None => null;
      end case;

      S.Name         := XS.Name;
      S.Format       := Format_XM;
      S.Num_Channels := XS.Num_Channels;
      S.Song_Length  := XS.Song_Length;
      S.Restart_Pos  := XS.Restart_Pos;
      S.BPM          := XS.BPM;
      S.Speed        := XS.Speed;
      S.Linear_Freq  := XS.Freq_Table = XM_Format.Linear_Table;

      for I in 0 .. XS.Song_Length - 1 loop
         S.Orders (I) := Pattern_Index (XS.Orders (I));
      end loop;

      --  Instruments
      for I in 1 .. XM_Format.Max_Instruments loop
         declare
            XI : XM_Format.XM_Instrument renames XS.Instruments (I);
            SI : Song.Instrument          renames S.Instruments (I);
         begin
            SI.Name        := XI.Name;
            SI.Num_Samples := XI.Num_Samples;
            SI.Fadeout     := XI.Fadeout;
            SI.Vib_Type    := Natural (XI.Vibrato_Type);
            SI.Vib_Sweep   := Natural (XI.Vibrato_Sweep);
            SI.Vib_Depth   := Natural (XI.Vibrato_Depth);
            SI.Vib_Rate    := Natural (XI.Vibrato_Rate);

            --  Note map (0-95)
            for N in 0 .. 95 loop
               SI.Map (N) := Natural (XI.Note_Map (N));
            end loop;

            --  Volume envelope
            declare
               VE : XM_Format.XM_Envelope renames XI.Vol_Env;
               SE : Song.Envelope renames SI.Vol_Env;
            begin
               SE.Enabled     := VE.Enabled;
               SE.Has_Sustain := VE.Has_Sustain;
               SE.Has_Loop    := VE.Has_Loop;
               SE.Num_Points  := VE.Num_Points;
               SE.Sustain_Pt  := VE.Sustain_Pt;
               SE.Loop_Start  := VE.Loop_Start;
               SE.Loop_End    := VE.Loop_End;
               for J in 0 .. Natural'Min (VE.Num_Points,
                                          Max_Env_Points) - 1 loop
                  SE.Points (J).Tick  := Natural (VE.Points (J).X);
                  SE.Points (J).Value := Natural (VE.Points (J).Y);
               end loop;
            end;

            --  Panning envelope
            declare
               PE : XM_Format.XM_Envelope renames XI.Pan_Env;
               SE : Song.Envelope renames SI.Pan_Env;
            begin
               SE.Enabled     := PE.Enabled;
               SE.Has_Sustain := PE.Has_Sustain;
               SE.Has_Loop    := PE.Has_Loop;
               SE.Num_Points  := PE.Num_Points;
               SE.Sustain_Pt  := PE.Sustain_Pt;
               SE.Loop_Start  := PE.Loop_Start;
               SE.Loop_End    := PE.Loop_End;
               for J in 0 .. Natural'Min (PE.Num_Points,
                                          Max_Env_Points) - 1 loop
                  SE.Points (J).Tick  := Natural (PE.Points (J).X);
                  SE.Points (J).Value := Natural (PE.Points (J).Y);
               end loop;
            end;

            --  Samples
            for J in 0 .. Natural'Min (XI.Num_Samples,
                                       XM_Format.Max_Samples_Per_Instrument) - 1 loop
               declare
                  XSample : XM_Format.XM_Sample renames XI.Samples (J);
                  SSample : Song.Sample renames SI.Samples (J);
               begin
                  SSample.Name         := XSample.Header.Name;
                  SSample.Base_Volume  := XSample.Header.Volume;
                  SSample.Finetune     := XSample.Header.Finetune;
                  SSample.Relative_Note := XSample.Header.Relative_Note;
                  SSample.Loop_Kind    := XSample.Header.Loop_Kind;
                  SSample.Loop_Start   := XSample.Header.Loop_Start;
                  SSample.Loop_End     := XSample.Header.Loop_End;
                  SSample.Panning      := Integer (XSample.Header.Panning) - 128;

                  case XSample.Depth is
                     when Depth_8 =>
                        if XSample.Data_8 /= null then
                           SSample.Data := Convert_8 (XSample.Data_8.all);
                        end if;
                     when Depth_16 =>
                        if XSample.Data_16 /= null then
                           SSample.Data := Convert_16 (XSample.Data_16.all);
                        end if;
                  end case;
               end;
            end loop;
         end;
      end loop;

      --  Patterns
      for P in Pattern_Index loop
         declare
            XP : XM_Format.XM_Pattern renames XS.Patterns (P);
            SP : Song.Pattern          renames S.Patterns (P);
         begin
            if XP.Cells /= null then
               SP.Num_Rows     := XP.Num_Rows;
               SP.Num_Channels := XP.Num_Channels;
               SP.Cells        := new Cell_Array (0 .. XP.Cells'Length - 1);
               for J in XP.Cells'Range loop
                  SP.Cells (J) := XP.Cells (J);
               end loop;
            end if;
         end;
      end loop;

      XM_Format.Free (XS);
      Result := OK;
   end Load_XM;

   --  ---------------------------------------------------------------
   --  S3M -> Song_Type conversion
   --  ---------------------------------------------------------------

   procedure Load_S3M
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result)
   is
      use Ada.Numerics.Elementary_Functions;

      SS     : S3M_Format.S3M_Song;
      Status : S3M_Format.Load_Error;

      --  Convert C5Speed to relative_note + finetune (linear table).
      --  With Linear_Freq=True, note 49 (C-4) plays at 8363 Hz.
      --  S3M defines note 61 (C-5) = C5Speed Hz, so:
      --    relative_note = round(12 * log2(C5Speed/8363)) - 12
      procedure C5_Tuning
        (C5Speed       : Positive;
         Relative_Note : out Integer;
         Finetune      : out Integer)
      is
         Semitones : constant Float :=
           12.0 * Log (Float (C5Speed) / 8363.0) / Log (2.0) - 12.0;
         Int_S     : constant Integer :=
           Integer (Float'Rounding (Semitones));
         Frac      : constant Float := Semitones - Float (Int_S);
      begin
         Relative_Note := Integer'Max (-96, Integer'Min (96, Int_S));
         Finetune      := Integer'Max (-128, Integer'Min (127,
                            Integer (Float'Rounding (Frac * 128.0))));
      end C5_Tuning;

   begin
      S := [others => <>];
      S3M_Format.Load (Path, SS, Status);

      case Status is
         when S3M_Format.File_Not_Found => Result := File_Not_Found; return;
         when S3M_Format.Invalid_Header => Result := Bad_Format;     return;
         when S3M_Format.IO_Error       => Result := IO_Error;       return;
         when S3M_Format.None           => null;
      end case;

      --  Copy top-level fields; truncate 28-char S3M name to 20 chars
      S.Name         := SS.Name (1 .. 20);
      S.Format       := Format_S3M;
      S.Num_Channels := SS.Num_Channels;
      S.Song_Length  := SS.Song_Length;
      S.BPM          := SS.BPM;
      S.Speed        := SS.Speed;
      S.Linear_Freq  := True;   --  use XM linear table for S3M

      --  Per-channel panning
      for I in 0 .. 31 loop
         S.Channel_Pan (I) := SS.Channel_Pan (I);
      end loop;

      --  Orders
      for I in 0 .. SS.Song_Length - 1 loop
         S.Orders (I) := Pattern_Index'Min (Pattern_Index'Last,
                           Pattern_Index (SS.Orders (I)));
      end loop;

      --  Instruments (each S3M instrument = one sample in slot 0)
      for I in 1 .. S3M_Format.Max_Instruments loop
         declare
            SI  : Song.Instrument renames S.Instruments (I);
            SS_I : S3M_Format.S3M_Sample renames SS.Instruments (I);
            SSmp : Song.Sample renames SI.Samples (0);
            RN, FT : Integer;
         begin
            SI.Num_Samples := 1;
            SI.Map         := [others => 0];  --  all notes -> sample 0

            --  28-char S3M name -> 22-char sample/instr name
            SSmp.Name := SS_I.Name (1 .. 22);
            SI.Name   := SSmp.Name;

            SSmp.Base_Volume := SS_I.Volume;

            C5_Tuning (Positive'Max (1, SS_I.C5Speed), RN, FT);
            SSmp.Relative_Note := RN;
            SSmp.Finetune      := FT;
            SSmp.Panning       := 0;   --  centre; channel pan applied by sequencer

            if SS_I.Has_Loop and SS_I.Loop_End > SS_I.Loop_Start then
               SSmp.Loop_Kind  := Forward_Loop;
               SSmp.Loop_Start := SS_I.Loop_Start;
               SSmp.Loop_End   := SS_I.Loop_End;
            end if;

            case SS_I.Depth is
               when Depth_8 =>
                  if SS_I.Data_8 /= null then
                     SSmp.Data := Convert_8 (SS_I.Data_8.all);
                  end if;
               when Depth_16 =>
                  if SS_I.Data_16 /= null then
                     SSmp.Data := Convert_16 (SS_I.Data_16.all);
                  end if;
            end case;
         end;
      end loop;

      --  Patterns
      for P in Pattern_Index loop
         declare
            SP  : Song.Pattern renames S.Patterns (P);
            SP3 : S3M_Format.S3M_Pattern renames SS.Patterns (P);
         begin
            if SP3.Cells /= null then
               SP.Num_Rows     := S3M_Format.S3M_Rows;
               SP.Num_Channels := SP3.Num_Channels;
               SP.Cells        :=
                 new Cell_Array (0 .. SP3.Cells'Length - 1);
               for J in SP3.Cells'Range loop
                  SP.Cells (J) := SP3.Cells (J);
               end loop;
            end if;
         end;
      end loop;

      S3M_Format.Free (SS);
      Result := OK;
   end Load_S3M;

   --  ---------------------------------------------------------------
   --  IT -> Song_Type conversion
   --  ---------------------------------------------------------------

   procedure Load_IT
     (Path   : String;
      S      : out Song_Type;
      Result : out Load_Result)
   is
      use Ada.Numerics.Elementary_Functions;

      IS_Song : IT_Format.IT_Song;
      Status  : IT_Format.Load_Error;

      --  Same C5Speed -> Relative_Note + Finetune as S3M
      procedure C5_Tuning
        (C5Speed       : Positive;
         Relative_Note : out Integer;
         Finetune      : out Integer)
      is
         Semitones : constant Float :=
           12.0 * Log (Float (C5Speed) / 8363.0) / Log (2.0) - 12.0;
         Int_S     : constant Integer :=
           Integer (Float'Rounding (Semitones));
         Frac      : constant Float := Semitones - Float (Int_S);
      begin
         Relative_Note := Integer'Max (-96, Integer'Min (96, Int_S));
         Finetune      := Integer'Max (-128, Integer'Min (127,
                            Integer (Float'Rounding (Frac * 128.0))));
      end C5_Tuning;

   begin
      S := [others => <>];
      IT_Format.Load (Path, IS_Song, Status);

      case Status is
         when IT_Format.File_Not_Found => Result := File_Not_Found; return;
         when IT_Format.Invalid_Header => Result := Bad_Format;     return;
         when IT_Format.IO_Error       => Result := IO_Error;       return;
         when IT_Format.None           => null;
      end case;

      S.Name         := IS_Song.Name (1 .. 20);
      S.Format       := Format_IT;
      S.Num_Channels := Natural'Min (32, IS_Song.Num_Channels);
      S.Song_Length  := IS_Song.Song_Length;
      S.BPM          := IS_Song.BPM;
      S.Speed        := IS_Song.Speed;
      S.Linear_Freq  := True;  --  IT always uses linear frequency table

      for I in 0 .. 31 loop
         S.Channel_Pan (I) := IS_Song.Channel_Pan (I);
      end loop;

      for I in 0 .. IS_Song.Song_Length - 1 loop
         S.Orders (I) := Pattern_Index'Min (Pattern_Index'Last,
                           Pattern_Index (IS_Song.Orders (I)));
      end loop;

      --  Convert instruments or samples depending on IT mode
      if IS_Song.Mode = IT_Format.Instrument_Mode then
         --  Instrument mode: IT instruments reference IT samples.
         --  Each IT instrument -> one Song.Instrument.
         --  Build a slot map: which IT samples does this instrument use?
         for I in 1 .. IT_Format.Max_Instruments loop
            declare
               IT_Inst  : IT_Format.IT_Instrument renames IS_Song.Instruments (I);
               SI       : Instrument renames S.Instruments (I);
               Slot_Map : array (0 .. IT_Format.Max_Samples) of Integer :=
                 [others => -1];
               --  Slot_Map (it_sample_no) -> engine slot (0-based), or -1
               Next_Slot : Natural := 0;
            begin
               SI.Name    := IT_Inst.Name (1 .. 22);
               SI.Fadeout := IT_Inst.Fadeout;
               SI.NNA     := IT_Inst.NNA;

               --  Assign sample slots from note map (notes 0..95)
               for N in 0 .. 95 loop
                  declare
                     It_Smp_No : constant Natural :=
                       IT_Inst.Note_Map (N);
                  begin
                     if It_Smp_No in 1 .. IT_Format.Max_Samples
                       and then Slot_Map (It_Smp_No) = -1
                       and then Next_Slot < Max_Samples_Per_Instr
                     then
                        Slot_Map (It_Smp_No) := Next_Slot;
                        Next_Slot := Next_Slot + 1;
                     end if;
                  end;
               end loop;

               SI.Num_Samples := Next_Slot;

               --  Build note map
               for N in 0 .. 95 loop
                  declare
                     It_Smp_No : constant Natural :=
                       IT_Inst.Note_Map (N);
                  begin
                     if It_Smp_No in 1 .. IT_Format.Max_Samples
                       and then Slot_Map (It_Smp_No) /= -1
                     then
                        SI.Map (N) := Slot_Map (It_Smp_No);
                     else
                        SI.Map (N) := 0;
                     end if;
                  end;
               end loop;

               --  Copy envelopes (volume + pan)
               declare
                  procedure Copy_Env
                    (VE : IT_Format.IT_Envelope; SE : in out Song.Envelope) is
                  begin
                     SE.Enabled     := VE.Enabled;
                     SE.Has_Sustain := VE.Has_Sustain;
                     SE.Has_Loop    := VE.Has_Loop;
                     SE.Num_Points  := Natural'Min (VE.Num_Points, Max_Env_Points);
                     SE.Loop_Start  := VE.Loop_Start;
                     SE.Loop_End    := VE.Loop_End;
                     SE.Sustain_Pt  := VE.Sus_Start;
                     for J in 0 .. SE.Num_Points - 1 loop
                        SE.Points (J).Tick  := VE.Points (J).Tick;
                        SE.Points (J).Value := VE.Points (J).Value;
                     end loop;
                  end Copy_Env;
               begin
                  Copy_Env (IT_Inst.Vol_Env, SI.Vol_Env);
                  Copy_Env (IT_Inst.Pan_Env, SI.Pan_Env);
                  --  Pitch envelope doubles as filter envelope when bit 7 is set
                  if IT_Inst.Flt_Env.Is_Filter then
                     Copy_Env (IT_Inst.Flt_Env, SI.Flt_Env);
                  end if;
                  SI.Flt_Cutoff    := IT_Inst.Flt_Cutoff;
                  SI.Flt_Resonance := IT_Inst.Flt_Resonance;
               end;

               --  Copy sample data into instrument slots
               for It_Sno in 1 .. IT_Format.Max_Samples loop
                  if Slot_Map (It_Sno) /= -1 then
                     declare
                        Slot   : constant Natural := Slot_Map (It_Sno);
                        IT_Smp : IT_Format.IT_Sample
                                   renames IS_Song.Samples (It_Sno);
                        SS     : Song.Sample renames SI.Samples (Slot);
                        RN, FT : Integer;
                     begin
                        SS.Name := IT_Smp.Name (1 .. 22);
                        SS.Base_Volume :=
                          Volume_Value'Min (64, Volume_Value (IT_Smp.Default_Vol));
                        C5_Tuning (Positive'Max (1, IT_Smp.C5Speed), RN, FT);
                        SS.Relative_Note := RN;
                        SS.Finetune      := FT;
                        SS.Panning       :=
                          (if IT_Smp.Has_Pan then IT_Smp.Default_Pan else 0);

                        if IT_Smp.Has_Loop
                          and IT_Smp.Loop_End > IT_Smp.Loop_Start
                        then
                           SS.Loop_Kind  :=
                             (if IT_Smp.Ping_Pong then Ping_Pong_Loop
                              else Forward_Loop);
                           SS.Loop_Start := IT_Smp.Loop_Start;
                           SS.Loop_End   := IT_Smp.Loop_End;
                        end if;

                        case IT_Smp.Depth is
                           when Depth_8 =>
                              if IT_Smp.Data_8 /= null then
                                 SS.Data := Convert_8 (IT_Smp.Data_8.all);
                              end if;
                           when Depth_16 =>
                              if IT_Smp.Data_16 /= null then
                                 SS.Data := Convert_16 (IT_Smp.Data_16.all);
                              end if;
                        end case;
                     end;
                  end if;
               end loop;
            end;
         end loop;

      else
         --  Sample mode: each IT sample becomes one instrument with one sample
         for I in 1 .. IT_Format.Max_Samples loop
            declare
               IT_Smp  : IT_Format.IT_Sample renames IS_Song.Samples (I);
               SI      : Instrument renames S.Instruments (I);
               SS      : Song.Sample renames SI.Samples (0);
               RN, FT  : Integer;
            begin
               SI.Num_Samples := 1;
               SI.Map         := [others => 0];
               SS.Name := IT_Smp.Name (1 .. 22);
               SI.Name := SS.Name;

               SS.Base_Volume :=
                 Volume_Value'Min (64, Volume_Value (IT_Smp.Default_Vol));
               C5_Tuning (Positive'Max (1, IT_Smp.C5Speed), RN, FT);
               SS.Relative_Note := RN;
               SS.Finetune      := FT;
               SS.Panning       :=
                 (if IT_Smp.Has_Pan then IT_Smp.Default_Pan else 0);

               if IT_Smp.Has_Loop
                 and IT_Smp.Loop_End > IT_Smp.Loop_Start
               then
                  SS.Loop_Kind  :=
                    (if IT_Smp.Ping_Pong then Ping_Pong_Loop
                     else Forward_Loop);
                  SS.Loop_Start := IT_Smp.Loop_Start;
                  SS.Loop_End   := IT_Smp.Loop_End;
               end if;

               case IT_Smp.Depth is
                  when Depth_8 =>
                     if IT_Smp.Data_8 /= null then
                        SS.Data := Convert_8 (IT_Smp.Data_8.all);
                     end if;
                  when Depth_16 =>
                     if IT_Smp.Data_16 /= null then
                        SS.Data := Convert_16 (IT_Smp.Data_16.all);
                     end if;
               end case;
            end;
         end loop;
      end if;

      --  Patterns
      for P in Pattern_Index loop
         if P < Pattern_Index (IT_Format.Max_Patterns) then
            declare
               SP  : Song.Pattern renames S.Patterns (P);
               IP  : IT_Format.IT_Pattern renames IS_Song.Patterns (P);
            begin
               if IP.Cells /= null then
                  SP.Num_Rows     := IP.Num_Rows;
                  SP.Num_Channels := IP.Num_Channels;
                  SP.Cells        :=
                    new Cell_Array (0 .. IP.Cells'Length - 1);
                  for J in IP.Cells'Range loop
                     SP.Cells (J) := IP.Cells (J);
                  end loop;
               end if;
            end;
         end if;
      end loop;

      IT_Format.Free (IS_Song);
      Result := OK;
   end Load_IT;

   --  ---------------------------------------------------------------
   --  Free
   --  ---------------------------------------------------------------

   procedure Free (S : in out Song_Type) is
      procedure Free_Cells is new Ada.Unchecked_Deallocation
        (Cell_Array, Cell_Array_Access);
   begin
      for I in 1 .. Max_Instruments loop
         for J in 0 .. Max_Samples_Per_Instr - 1 loop
            if S.Instruments (I).Samples (J).Data /= null then
               Free_Float (S.Instruments (I).Samples (J).Data);
            end if;
         end loop;
      end loop;
      for P in Pattern_Index loop
         if S.Patterns (P).Cells /= null then
            Free_Cells (S.Patterns (P).Cells);
         end if;
      end loop;
   end Free;

end Song;
