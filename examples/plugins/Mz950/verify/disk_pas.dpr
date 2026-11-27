// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Disk reading check, Pascal side: the same dump as disk_cpp.cpp, from S950Disk, and the
// comparison of the two.
//
//     disk_pas <out.txt> <image> [<image> ...]
//     disk_pas --compare <what> <cpp.txt> <pas.txt>
//
// Built with every run-time check on (-Cr -Co -Ct -CR) and the heap tracer (-gh), so an
// index out of range, an overflow or a leaked sound shows.
program disk_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, S950Patch, S950Disk;

var
  Outp: TextFile;
  OutBuf: array[0..65535] of Byte;

{$Q-}{$R-}
function Fnv(P: Pointer; N: NativeInt; H: UInt64 = UInt64(1469598103934665603)): UInt64;
var
  I: NativeInt;
  B: PByte;
begin
  B := P;
  for I := 0 to N - 1 do
  begin
    H := (H xor B[I]) * UInt64(1099511628211);
  end;
  Result := H;
end;
{$Q+}{$R+}

function Hx(U: UInt64): string;
var
  I: Int64;
begin
  Move(U, I, 8);
  Result := IntToHex(I, 16);
end;

function Bits(D: Double): string;
var
  U: UInt64;
begin
  Move(D, U, 8);
  Result := Hx(U);
end;

function B01(B: Boolean): Integer;
begin
  if B then
    Result := 1
  else
    Result := 0;
end;

procedure Line(const S: string);
begin
  WriteLn(Outp, S);
end;

function FnvBytes(const B: TBytes): UInt64;
begin
  if Length(B) = 0 then
    Result := Fnv(nil, 0)
  else
    Result := Fnv(@B[0], Length(B));
end;

procedure DumpZone(const Lbl: string; const Z: TDiskZone);
begin
  Line(Format('    %s ''%s'' ptr %d fine %d trans %d filt %d loud %d pitch %s use %d',
              [Lbl, Z.Name, Z.ZonePointer, Z.Fine, Z.Transpose, Z.Filter, Z.Loudness,
               Bits(Z.PitchOffset), B01(Z.InUse)]));
end;

procedure DumpPatch(D: TS950Disk; const E: TDiskEntry);
var
  Patch, Again: TS950Patch;
  Ids: array of TS950Sound;
  I, J, Id, Shown: Integer;
  S: TS950Sound;
  Same: AnsiString;
  AudioHash: UInt64;
begin
  Patch := D.BuildPatch(E);
  if Patch = nil then
  begin
    Line('  patch nil');
    Exit;
  end;

  Line(Format('  patch ''%s'' xfade %d entries %d', [Patch.Name, B01(Patch.PositionalCrossfade),
                                                    Length(Patch.Keygroups)]));

  Ids := nil;
  Shown := 0;
  for I := 0 to High(Patch.Keygroups) do
  begin
    Id := -1;
    S := Patch.Keygroups[I].Sound;
    if S <> nil then
    begin
      for J := 0 to High(Ids) do
        if Ids[J] = S then
          Id := J;
      if Id < 0 then
      begin
        Id := Length(Ids);
        SetLength(Ids, Id + 1);
        Ids[Id] := S;
        if Length(S.Audio) = 0 then
          AudioHash := Fnv(nil, 0)
        else
          AudioHash := Fnv(@S.Audio[0], Length(S.Audio) * SizeOf(Single));
        Line(Format('   sound %d ''%s'' fp %s rate %d root %s loop %d-%d loops %d alt %d smooth %d len %d hash %s',
                    [Id, S.Name, Hx(S.Fingerprint), S.SourceRate, Bits(S.RootPitch), S.LoopFrom, S.LoopTo,
                     B01(S.Loops), B01(S.Alternates), S.LoopSmoothed, Length(S.Audio), Hx(AudioHash)]));
      end;
    end;

    Inc(Shown);
    if Shown > 2000 then
      Continue;
    with Patch.Keygroups[I] do
      Line(Format('   pk keys %d-%d kg %d vel %d-%d sound %d vca %d,%d,%d,%d vcf %d,%d,%d,%d w %d amt %d', [
                  LowKey, HighKey, KeygroupIndex, VelocityFrom, VelocityTo, Id,
                  VcaAttack, VcaDecay, VcaSustain, VcaRelease,
                  VcfAttack, VcfDecay, VcfSustain, VcfRelease, B01(VcfWritten), VcfAmount]) +
           Format(' vtf %d ktf %d vtl %d vta %d vtr %d vro %d warp %d,%d,%d port %d lfo %d,%d,%d,%d,%d ds %d', [
                  VelToFilter, KeyToFilter, VelToLoudness, VelToAttack, VelToRelease,
                  B01(VelocityReleaseOn), WarpVelocity, WarpDepth, WarpTime, OutputPort,
                  LfoDelay, LfoRate, LfoDepth, LfoModwheelDepth, LfoAftertouchDepth, B01(LfoDesync)]) +
           Format(' zf %d zl %d zt %s cp %d os %d', [
                  ZoneFilter, ZoneLoudness, Bits(ZoneTranspose), B01(ConstantPitch), B01(OneShot)]));
  end;

  // Rebuilt with the first as `reuse`: every sound must be the very same object.
  Again := D.BuildPatch(E, Patch);
  Same := '';
  for I := 0 to High(Again.Keygroups) do
    if (I <= High(Patch.Keygroups)) and (Again.Keygroups[I].Sound = Patch.Keygroups[I].Sound) then
      Same := Same + 's'
    else
      Same := Same + 'd';
  if Length(Same) = 0 then
    Line(Format('  reuse %d hash %s', [Length(Again.Keygroups), Hx(Fnv(nil, 0))]))
  else
    Line(Format('  reuse %d hash %s', [Length(Again.Keygroups), Hx(Fnv(@Same[1], Length(Same)))]));

  ReleasePatch(Again);
  ReleasePatch(Patch);
end;

procedure DumpDisk(const Path: string);
var
  D, W, Again: TS950Disk;
  Error, Why, S, Slots: string;
  Img, Raw: TBytes;
  Words: TSmallIntArray;
  Groups: TDiskKeygroupArray;
  EI, G, N, Kg, P, O, I, Shown, First, Second, Third, Z: Integer;
  F, Pe, Es: PDiskEntry;
  Which: array of Integer;
  At: array of Int64;
  A: NativeInt;
  Ns: TNewSample;
  Ok, Ok2: Boolean;
  WordsHash: UInt64;
begin
  D := TS950Disk.Create;
  try
    Line('file ' + ExtractFileName(Path));

    if not D.LoadFile(Path, Error) then
    begin
      Line(Format('load fail ''%s'' badcrc %d missing %d hfe %d', [Error, D.BadCrcSectors,
                                                                    D.MissingSectors, B01(D.WasHfe)]));
      Exit;
    end;

    Img := D.Image;
    Line(Format('load ok hfe %d size %d badcrc %d missing %d rev %d hd %d header %d image %s entries %d',
                [B01(D.WasHfe), Length(Img), D.BadCrcSectors, D.MissingSectors, D.Revision,
                 B01(D.IsHighDensity), D.HeaderBlocks, Hx(FnvBytes(Img)), Length(D.Entries)]));

    for EI := 0 to High(D.Entries) do
    begin
      Es := @D.Entries[EI];
      with Es^ do
        Line(Format('entry %d type %d ''%s'' len %d start %d blocks %d ok %d count %d rate %d tuning %d', [
                    Slot, Ord(EntryType), Name, Length, StartBlock, ChainBlocks, B01(ChainOk),
                    SampleCount, SampleRate, Tuning]) +
             Format(' mode %d dir %d loop %d/%d/%d loud %d pitch %d/%d secs %s', [
                    Ord(LoopMode), Ord(LoopDirection), LoopStart, LoopEnd, LoopLength, Loudness,
                    NominalPitch, FinePitch, Bits(Seconds)]));

      Raw := D.ReadFile(Es^);
      Words := D.SampleWords12(Es^);
      F := D.Find(Es^.Name, Es^.EntryType);
      if Length(Words) = 0 then
        WordsHash := Fnv(nil, 0)
      else
        WordsHash := Fnv(@Words[0], Length(Words) * SizeOf(SmallInt));
      if F <> nil then
        I := F^.Slot
      else
        I := -1;
      Line(Format('  file %d %s words %d %s kgcount %d find %d index %d norm ''%s''',
                  [Length(Raw), Hx(FnvBytes(Raw)), Length(Words), Hx(WordsHash),
                   TS950Disk.KeygroupCount(Es^), I, D.SampleIndex(Es^.Name),
                   TS950Disk.NormaliseNameFor(Es^.Name + ' x')]));

      Groups := D.Keygroups(Es^);
      Line(Format('  keygroups %d', [Length(Groups)]));

      Shown := 0;
      for G := 0 to High(Groups) do
      begin
        Inc(Shown);
        if Shown > 2000 then
          Break;
        with Groups[G] do
        begin
          Line(Format('   kg %d keys %d-%d vsw %d vca %d,%d,%d,%d vcf %d,%d,%d,%d amt %d vtf %d ktf %d vtl %d', [
                      Index, LowKey, HighKey, VelocitySwitch,
                      VcaAttack, VcaDecay, VcaSustain, VcaRelease,
                      VcfAttack, VcfDecay, VcfSustain, VcfRelease, VcfAmount,
                      VelToFilter, KeyToFilter, VelToLoudness]) +
               Format(' vta %d vtr %d warp %d,%d,%d port %d lfo %d,%d,%d,%d,%d flags %d bits %d%d%d%d second %d', [
                      VelToAttack, VelToRelease,
                      WarpVelocity, WarpDepth, WarpTime, OutputPort,
                      LfoDelay, LfoRate, LfoDepth, LfoAftertouchDepth, LfoModwheelDepth,
                      Flags, B01(ConstantPitch), B01(LfoDesync), B01(OneShot),
                      B01(VelocityReleaseOn), B01(HasSecondZone)]));
          DumpZone('z1', Zone1);
          DumpZone('z2', Zone2);
        end;
      end;

      // Every setting, through the reader the editor uses, and where each byte lives -
      // one keygroup before the first and one past the last included.
      N := TS950Disk.KeygroupCount(Es^);
      Which := nil;
      Kg := -1;
      while (Kg <= N) and (Kg <= 70) do
      begin
        SetLength(Which, Length(Which) + 1);
        Which[High(Which)] := Kg;
        Inc(Kg);
      end;
      if N > 70 then
      begin
        SetLength(Which, Length(Which) + 2);
        Which[High(Which) - 1] := N - 1;
        Which[High(Which)] := N;
      end;

      for G := 0 to High(Which) do
      begin
        Kg := Which[G];
        S := '  get ' + IntToStr(Kg) + ':';
        for P := 0 to KeygroupParamCount - 1 do
          S := S + ' ' + IntToStr(D.GetKeygroupParam(Es^, Kg, TKeygroupParam(P)));
        S := S + ' blank ' + IntToStr(B01(D.VcfBlank(Es^, Kg)));

        SetLength(At, 72);
        for O := -1 to 70 do
          if D.KeygroupByteAt(Es^, Kg, O, A) then
            At[O + 1] := A
          else
            At[O + 1] := -1;
        Line(S + ' at ' + Hx(Fnv(@At[0], Length(At) * SizeOf(Int64))));
      end;

      DumpPatch(D, Es^);
    end;

    Slots := '';
    for I := -1 to 64 do
    begin
      Pe := D.EntryInSlot(I);
      if Pe <> nil then
        Slots := Slots + ' ' + IntToStr(Pe^.Slot)
      else
        Slots := Slots + ' -1';
    end;
    Line('slots' + Slots);

    // The writing half on whatever this disk holds: rebuild, then add a sample and a
    // programme and point a zone at it.
    W := TS950Disk.Create;
    try
      W.Assign(D);
      First := W.RebuildPointers;
      Second := W.RebuildPointers;
      Line(Format('rebuild %d %d image %s rev %d', [First, Second, Hx(FnvBytes(W.Image)), W.Revision]));

      Ns.Init;
      Ns.Name := 'zz test';
      SetLength(Ns.Words12, 3001);
      for I := 0 to 3000 do
        Ns.Words12[I] := (I * 37) mod 4096 - 2048;
      Ok := W.AddSample(Ns, Why);
      Line(Format('addsample %d ''%s''', [B01(Ok), Why]));
      Ok2 := W.AddProgram('zz prog', 3, Why);
      Line(Format('addprogram %d ''%s''', [B01(Ok2), Why]));
      Pe := W.Find('ZZ PROG', 'P');
      Z := -1;
      if Pe <> nil then
      begin
        Z := B01(W.SetZoneSample(Pe^, 1, 0, 'zz test')) + 2 * B01(W.SetZoneSample(Pe^, 2, 1, 'nothing'));
        W.SetKeygroupParam(Pe^, 1, kpVcfDecay, 12);
      end;
      Third := W.RebuildPointers;
      Line(Format('written zone %d rebuild %d entries %d image %s rev %d',
                  [Z, Third, Length(W.Entries), Hx(FnvBytes(W.Image)), W.Revision]));
    finally
      W.Free;
    end;

    // The same image again, from its bytes: a plain image, read the same.
    Again := TS950Disk.Create;
    try
      Ok := Again.LoadBytes('again', D.Image, Why);
      Line(Format('reload %d hfe %d entries %d image %s', [B01(Ok), B01(Again.WasHfe),
                  Length(Again.Entries), Hx(FnvBytes(Again.Image))]));
    finally
      Again.Free;
    end;
  finally
    D.Free;
  end;
end;

// Line by line; the first few differences shown. Exit code 1 on any.
function Compare(const What, A, B: string): Integer;
var
  X, Y: TStringList;
  I, Diffs, N: Integer;
begin
  X := TStringList.Create;
  Y := TStringList.Create;
  try
    X.LoadFromFile(A);
    Y.LoadFromFile(B);
    Diffs := 0;
    N := X.Count;
    if Y.Count > N then
      N := Y.Count;
    for I := 0 to N - 1 do
    begin
      if (I < X.Count) and (I < Y.Count) and (X[I] = Y[I]) then
        Continue;
      Inc(Diffs);
      if Diffs <= 10 then
      begin
        WriteLn('  line ', I + 1, ':');
        if I < X.Count then WriteLn('    c++: ', X[I]) else WriteLn('    c++: <end>');
        if I < Y.Count then WriteLn('    pas: ', Y[I]) else WriteLn('    pas: <end>');
      end;
    end;
    WriteLn(Format('%s: %d lines compared, %d mismatches', [What, N, Diffs]));
    if Diffs = 0 then
      Result := 0
    else
      Result := 1;
  finally
    X.Free;
    Y.Free;
  end;
end;

var
  I, J, Images: Integer;
  List: TStringList;
begin
  if (ParamCount = 4) and (ParamStr(1) = '--compare') then
  begin
    ExitCode := Compare(ParamStr(2), ParamStr(3), ParamStr(4));
    Exit;
  end;

  if ParamCount < 2 then
  begin
    WriteLn('usage: disk_pas <out.txt> <image> [<image> ...]');
    ExitCode := 2;
    Exit;
  end;

  AssignFile(Outp, ParamStr(1));
  SetTextBuf(Outp, OutBuf, SizeOf(OutBuf));
  Rewrite(Outp);
  // An argument @file names a file listing images, one to a line.
  Images := 0;
  for I := 2 to ParamCount do
  begin
    if Copy(ParamStr(I), 1, 1) <> '@' then
    begin
      DumpDisk(ParamStr(I));
      Inc(Images);
      Continue;
    end;
    List := TStringList.Create;
    try
      List.LoadFromFile(Copy(ParamStr(I), 2, MaxInt));
      for J := 0 to List.Count - 1 do
        if TrimRight(List[J]) <> '' then
        begin
          DumpDisk(TrimRight(List[J]));
          Inc(Images);
        end;
    finally
      List.Free;
    end;
  end;
  CloseFile(Outp);
  WriteLn('disk_pas: ', Images, ' images dumped');
end.
