// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Disk editing and writing check, Pascal side: diskedit_cpp.cpp's checks, step for step,
// through S950Disk. The two logs, and every image the two write, must be identical.
//
//     diskedit_pas <log.txt> <imagedir> <tag> <image> [<image> ...]
//
// Built with every run-time check on and the heap tracer, so a range error or a leaked
// sound or patch shows.
program diskedit_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, S950Patch, S950Disk;

var
  Outp: TextFile;
  OutBuf: array[0..65535] of Byte;
  Checks, Failures, Edits: Integer;

{$Q-}{$R-}
function Fnv(P: Pointer; N: NativeInt): UInt64;
var
  I: NativeInt;
  B: PByte;
begin
  Result := UInt64(1469598103934665603);
  B := P;
  for I := 0 to N - 1 do
    Result := (Result xor B[I]) * UInt64(1099511628211);
end;
{$Q+}{$R+}

function Hx(U: UInt64): string;
var
  I: Int64;
begin
  Move(U, I, 8);
  Result := IntToHex(I, 16);
end;

function ImageHash(D: TS950Disk): string;
var
  Img: TBytes;
begin
  Img := D.Image;
  if Length(Img) = 0 then
    Result := Hx(Fnv(nil, 0))
  else
    Result := Hx(Fnv(@Img[0], Length(Img)));
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

procedure Fail(const Where, What: string; Got, Want: Integer);
begin
  Inc(Failures);
  Line(Format('FAIL %s %s: got %d, want %d', [Where, What, Got, Want]));
  if Failures <= 40 then
    WriteLn(Format('  FAIL %s %s: got %d, want %d', [Where, What, Got, Want]));
end;

function Save(D: TS950Disk; const Path: string): Boolean;
var
  F: TFileStream;
  Img: TBytes;
begin
  Result := False;
  Img := D.Image;
  try
    F := TFileStream.Create(Path, fmCreate);
    try
      if Length(Img) > 0 then
        F.WriteBuffer(Img[0], Length(Img));
      Result := True;
    finally
      F.Free;
    end;
  except
    Result := False;
  end;
end;

function SameImage(A, B: TS950Disk): Boolean;
var
  X, Y: TBytes;
begin
  X := A.Image;
  Y := B.Image;
  Result := (Length(X) = Length(Y)) and ((Length(X) = 0) or (CompareByte(X[0], Y[0], Length(X)) = 0));
end;

// The same setting as the playing reader parses it.
function Parsed(const K: TDiskKeygroup; P: TKeygroupParam): Integer;
begin
  case P of
    kpHighKey:          Result := K.HighKey;
    kpLowKey:           Result := K.LowKey;
    kpVelocitySwitch:   Result := K.VelocitySwitch;
    kpVcaAttack:        Result := K.VcaAttack;
    kpVcaDecay:         Result := K.VcaDecay;
    kpVcaSustain:       Result := K.VcaSustain;
    kpVcaRelease:       Result := K.VcaRelease;
    kpVelToFilter:      Result := K.VelToFilter;
    kpKeyToFilter:      Result := K.KeyToFilter;
    kpVelToAttack:      Result := K.VelToAttack;
    kpVelToRelease:     Result := K.VelToRelease;
    kpVelToLoudness:    Result := K.VelToLoudness;
    kpWarpVelocity:     Result := K.WarpVelocity;
    kpWarpDepth:        Result := K.WarpDepth;
    kpWarpTime:         Result := K.WarpTime;
    kpLfoDelay:         Result := K.LfoDelay;
    kpLfoRate:          Result := K.LfoRate;
    kpLfoDepth:         Result := K.LfoDepth;
    kpLfoAftertouch:    Result := K.LfoAftertouchDepth;
    kpLfoModwheel:      Result := K.LfoModwheelDepth;
    kpOutputPort:       Result := K.OutputPort;
    kpVcfAmount:        Result := K.VcfAmount;
    kpVcfAttack:        Result := K.VcfAttack;
    kpVcfDecay:         Result := K.VcfDecay;
    kpVcfSustain:       Result := K.VcfSustain;
    kpVcfRelease:       Result := K.VcfRelease;
    kpZone1Fine:        Result := K.Zone1.Fine;
    kpZone1Transpose:   Result := K.Zone1.Transpose;
    kpZone1Filter:      Result := K.Zone1.Filter;
    kpZone1Loudness:    Result := K.Zone1.Loudness;
    kpZone2Fine:        Result := K.Zone2.Fine;
    kpZone2Transpose:   Result := K.Zone2.Transpose;
    kpZone2Filter:      Result := K.Zone2.Filter;
    kpZone2Loudness:    Result := K.Zone2.Loudness;
    kpConstantPitch:    Result := B01(K.ConstantPitch);
    kpLfoDesync:        Result := B01(K.LfoDesync);
    kpOneShot:          Result := B01(K.OneShot);
    kpVelocityReleaseOn:Result := B01(K.VelocityReleaseOn);
  else
    Result := -9999;
  end;
end;

function IsVcfStage(P: TKeygroupParam): Boolean;
begin
  Result := (P = kpVcfAttack) or (P = kpVcfDecay) or (P = kpVcfSustain) or (P = kpVcfRelease);
end;

// One write of one value, checked every way there is - and logged, bytes and all.
procedure TryValue(Original: TS950Disk; ProgramIndex, Kg: Integer; P: TKeygroupParam; Value: Integer);
var
  D: TS950Disk;
  Info: TKeygroupParamInfo;
  Where, Moved: string;
  BlankBefore: Boolean;
  Want, Got, Seen, O, Strays: Integer;
  Groups: TDiskKeygroupArray;
  Allowed: array[0..4] of NativeInt;
  NAllowed, J: Integer;
  At: NativeInt;
  Before, After: TBytes;
  C, Len, I: NativeInt;
  Ok: Boolean;
const
  Chunk = 4096;
begin
  D := TS950Disk.Create;                     // a fresh copy each time: nothing leaks
  try
    D.Assign(Original);
    Info := KeygroupParamInfo(P);

    Where := D.Entries[ProgramIndex].Name + ' kg' + IntToStr(Kg) + ' ' + Info.Name
           + ' <- ' + IntToStr(Value);

    BlankBefore := IsVcfStage(P) and D.VcfBlank(D.Entries[ProgramIndex], Kg);
    Inc(Edits);

    Inc(Checks);
    if not D.SetKeygroupParam(D.Entries[ProgramIndex], Kg, P, Value) then
    begin
      Line(Format('e %d kg %d p %d v %d refused', [ProgramIndex, Kg, Ord(P), Value]));
      Fail(Where, 'write refused', 0, 1);
      Exit;
    end;

    if Value < Info.Lo then
      Want := Info.Lo
    else if Value > Info.Hi then
      Want := Info.Hi
    else
      Want := Value;

    Inc(Checks);
    Got := D.GetKeygroupParam(D.Entries[ProgramIndex], Kg, P);
    if Got <> Want then
      Fail(Where, 'reads back', Got, Want);

    Inc(Checks);
    Seen := -9999;
    Groups := D.Keygroups(D.Entries[ProgramIndex]);
    if Kg < Length(Groups) then
    begin
      Seen := Parsed(Groups[Kg], P);
      if Seen <> Want then
        Fail(Where, 'the playing reader sees', Seen, Want);
    end;

    // Which bytes were allowed to move.
    NAllowed := 0;
    if D.KeygroupByteAt(D.Entries[ProgramIndex], Kg, Info.Offset, At) then
    begin
      Allowed[NAllowed] := At;
      Inc(NAllowed);
    end;

    if BlankBefore then
      for O := 34 to 37 do
        if D.KeygroupByteAt(D.Entries[ProgramIndex], Kg, O, At) then
        begin
          Allowed[NAllowed] := At;
          Inc(NAllowed);
        end;

    Before := Original.Image;
    After := D.Image;

    Inc(Checks);
    if Length(Before) <> Length(After) then
    begin
      Fail(Where, 'image size changed', Length(After), Length(Before));
      Exit;
    end;

    Moved := '';
    Strays := 0;
    C := 0;
    while C < Length(Before) do
    begin
      Len := Chunk;
      if Length(Before) - C < Len then
        Len := Length(Before) - C;
      if CompareByte(Before[C], After[C], Len) <> 0 then
        for I := C to C + Len - 1 do
          if Before[I] <> After[I] then
          begin
            Moved := Moved + ' ' + IntToStr(I);
            Ok := False;
            for J := 0 to NAllowed - 1 do
              if Allowed[J] = I then
                Ok := True;
            if not Ok then
              Inc(Strays);
          end;
      Inc(C, Chunk);
    end;

    if Strays <> 0 then
      Fail(Where, 'bytes changed outside the setting', Strays, 0);

    Line(Format('e %d kg %d p %d v %d get %d seen %d blank %d rev %d moved%s',
                [ProgramIndex, Kg, Ord(P), Value, Got, Seen, B01(BlankBefore), D.Revision, Moved]));
  finally
    D.Free;
  end;
end;

// A value for the edited copy: distinct per keygroup and setting, always in range.
function Scrambled(const Info: TKeygroupParamInfo; Prog, Kg, P: Integer): Integer;
var
  Span: Integer;
begin
  Span := Info.Hi - Info.Lo + 1;
  Result := Info.Lo + (Prog * 31 + Kg * 17 + P * 7 + 3) mod Span;
end;

function NewSample(const AName: string; const Words: TSmallIntArray): TNewSample;
begin
  Result.Init;
  Result.Name := AName;
  Result.Words12 := Words;
end;

// DiskEditCheck's checks, on one disk.
procedure EditDisk(Original: TS950Disk; const Lbl, Dir, Tag: string);
const
  Extra: array[0..1] of Integer = (-100000, 100000);
var
  E, N, Kg, P, Programs, Keygroups, Want, I, Pi_, Got, Marked, Cut, VI: Integer;
  Info: TKeygroupParamInfo;
  Vals: array[0..7] of Integer;
  D, Reread: TS950Disk;
  Before, After: TS950Patch;
  Seen: array of string;
  SeenNew: Boolean;
  K: Integer;
  S: PDiskEntry;
  Words: TSmallIntArray;
  Size, EndW, Stop, Plays, FirstW: Int64;
  Where, Path, Error: string;
  Patch: TS950Patch;
  Sound: TS950Sound;
  Refused: array[0..2] of Integer;
  R: Integer;
  F32: Single;
begin
  Line(Format('disk %s image %s', [Lbl, ImageHash(Original)]));

  Programs := 0;
  Keygroups := 0;

  for E := 0 to High(Original.Entries) do
  begin
    if Original.Entries[E].EntryType <> 'P' then
      Continue;

    Inc(Programs);
    N := TS950Disk.KeygroupCount(Original.Entries[E]);

    for Kg := 0 to N - 1 do
    begin
      Inc(Keygroups);

      for P := 0 to KeygroupParamCount - 1 do
      begin
        Info := KeygroupParamInfo(TKeygroupParam(P));

        Vals[0] := Info.Lo;
        Vals[1] := Info.Hi;
        Vals[2] := (Info.Lo + Info.Hi) div 2;
        Vals[3] := Info.Lo - 5;
        Vals[4] := Info.Hi + 5;
        Vals[5] := Info.Lo + 1;
        Vals[6] := Extra[0];
        Vals[7] := Extra[1];
        for VI := 0 to 7 do
          TryValue(Original, E, Kg, TKeygroupParam(P), Vals[VI]);
      end;
    end;

    // Past the last keygroup nothing may be written, and nothing may move.
    Refused[0] := N;
    Refused[1] := -1;
    Refused[2] := N + 7;
    for R := 0 to 2 do
    begin
      D := TS950Disk.Create;
      try
        D.Assign(Original);
        Inc(Checks);
        if D.SetKeygroupParam(D.Entries[E], Refused[R], kpVcaDecay, 50) then
          Fail(Original.Entries[E].Name, 'wrote past the last keygroup', 1, 0);
        Inc(Checks);
        if not SameImage(D, Original) then
          Fail(Original.Entries[E].Name, 'a refused write moved bytes', 1, 0);
      finally
        D.Free;
      end;
    end;
  end;

  Line(Format('  %d programmes, %d keygroups, %d settings each', [Programs, Keygroups, KeygroupParamCount]));

  //
  // A rebuild after an edit hears the edit, and keeps the samples it had.
  //
  for E := 0 to High(Original.Entries) do
  begin
    if (Original.Entries[E].EntryType <> 'P') or (TS950Disk.KeygroupCount(Original.Entries[E]) = 0) then
      Continue;

    D := TS950Disk.Create;
    Before := nil;
    After := nil;
    try
      D.Assign(Original);

      Before := D.BuildPatch(D.Entries[E]);
      if (Before = nil) or (Length(Before.Keygroups) = 0) then
        Continue;

      Kg := Before.Keygroups[0].KeygroupIndex;
      if Before.Keygroups[0].VcaSustain = 40 then
        Want := 41
      else
        Want := 40;
      D.SetKeygroupParam(D.Entries[E], Kg, kpVcaSustain, Want);

      After := D.BuildPatch(D.Entries[E], Before);

      Inc(Checks);
      if (After = nil) or (Length(After.Keygroups) <> Length(Before.Keygroups)) then
      begin
        Fail(Original.Entries[E].Name, 'rebuild changed the keygroups', 0, 1);
        Continue;
      end;

      Inc(Checks);
      if After.Keygroups[0].VcaSustain <> Want then
        Fail(Original.Entries[E].Name, 'the rebuild hears the edit', After.Keygroups[0].VcaSustain, Want);

      for I := 0 to High(After.Keygroups) do
      begin
        Inc(Checks);
        if After.Keygroups[I].Sound <> Before.Keygroups[I].Sound then
          Fail(Original.Entries[E].Name, 'a rebuild decoded a sample afresh', 0, 1);
      end;
      Line(Format('  rebuilt %s %d', [Original.Entries[E].Name, Length(After.Keygroups)]));
    finally
      ReleasePatch(After);
      ReleasePatch(Before);
      D.Free;
    end;
  end;

  //
  // A note starts at the sample's start marker (header 0x20), measured on the machine.
  //
  begin
    Marked := 0;
    Cut := 0;
    Seen := nil;
    for E := 0 to High(Original.Entries) do
    begin
      if Original.Entries[E].EntryType <> 'P' then
        Continue;
      Patch := Original.BuildPatch(Original.Entries[E]);
      if Patch = nil then
        Continue;
      try
        for K := 0 to High(Patch.Keygroups) do
        begin
          Sound := Patch.Keygroups[K].Sound;
          if Sound = nil then
            Continue;
          SeenNew := True;
          for I := 0 to High(Seen) do
            if Seen[I] = Sound.Name then
              SeenNew := False;
          if not SeenNew then
            Continue;
          SetLength(Seen, Length(Seen) + 1);
          Seen[High(Seen)] := Sound.Name;

          S := Original.Find(Sound.Name, 'S');
          if S = nil then
            Continue;

          Words := Original.SampleWords12(S^);
          Size := Length(Words);
          if S^.LoopEnd < Size then
            EndW := S^.LoopEnd
          else
            EndW := Size;
          if Sound.Loops then
            Stop := Size
          else if (S^.LoopEnd > 0) and (S^.LoopEnd < Size) then
            Stop := S^.LoopEnd
          else
            Stop := Size;
          if Sound.Loops then
            Plays := EndW
          else
            Plays := Stop;
          if (S^.LoopStart > 0) and (S^.LoopStart < Plays) then
            FirstW := S^.LoopStart
          else
            FirstW := 0;
          if FirstW > 0 then
            Inc(Marked);
          if Stop < Size then
            Inc(Cut);

          Where := 'sample ' + S^.Name;
          Inc(Checks);
          if Length(Sound.Audio) <> Stop - FirstW then
          begin
            Fail(Where, 'plays from the start marker to the end marker (length)',
                 Length(Sound.Audio), Integer(Stop - FirstW));
            Continue;
          end;
          Inc(Checks);
          if Length(Sound.Audio) > 0 then
          begin
            F32 := Words[FirstW] / 2048.0;
            if Sound.Audio[0] <> F32 then
              Fail(Where, 'plays from the start marker (first word)', 0, 1);
          end;

          if Sound.Loops then
          begin
            Inc(Checks);
            if Sound.LoopTo <> Integer(EndW - FirstW) then
              Fail(Where, 'the loop end moves with the start', Sound.LoopTo, Integer(EndW - FirstW));
          end;
        end;
      finally
        ReleasePatch(Patch);
      end;
    end;
    Line(Format('  %d sounds played, %d of them from a start marker past word 0, %d one-shots cut at an end marker',
                [Length(Seen), Marked, Cut]));
  end;

  // ------------------------------------------------------------- the edited copy
  D := TS950Disk.Create;
  Reread := TS950Disk.Create;
  try
    D.Assign(Original);

    Pi_ := 0;
    for E := 0 to High(D.Entries) do
    begin
      if D.Entries[E].EntryType <> 'P' then
        Continue;

      N := TS950Disk.KeygroupCount(D.Entries[E]);
      for Kg := 0 to N - 1 do
        for P := 0 to KeygroupParamCount - 1 do
          D.SetKeygroupParam(D.Entries[E], Kg, TKeygroupParam(P),
                             Scrambled(KeygroupParamInfo(TKeygroupParam(P)), Pi_, Kg, P));
      Inc(Pi_);
    end;

    Path := Dir + '\edited_' + Lbl + '_' + Tag + '.img';
    Inc(Checks);
    if not Save(D, Path) then
      Fail(Path, 'could not write', 0, 1);

    // And read back from the file, not from memory: what was saved is what counts.
    Inc(Checks);
    if not Reread.LoadFile(Path, Error) then
      Fail(Path, 'the edited copy will not open', 0, 1)
    else
    begin
      Pi_ := 0;
      for E := 0 to High(Reread.Entries) do
      begin
        if Reread.Entries[E].EntryType <> 'P' then
          Continue;

        N := TS950Disk.KeygroupCount(Reread.Entries[E]);
        for Kg := 0 to N - 1 do
          for P := 0 to KeygroupParamCount - 1 do
          begin
            Want := Scrambled(KeygroupParamInfo(TKeygroupParam(P)), Pi_, Kg, P);
            Inc(Checks);
            Got := Reread.GetKeygroupParam(Reread.Entries[E], Kg, TKeygroupParam(P));
            if Got <> Want then
              Fail(Reread.Entries[E].Name + ' kg' + IntToStr(Kg) + ' (saved)',
                   KeygroupParamInfo(TKeygroupParam(P)).Name, Got, Want);
          end;
        Inc(Pi_);
      end;
    end;

    Line(Format('  edited image %s rev %d', [ImageHash(D), D.Revision]));
  finally
    Reread.Free;
    D.Free;
  end;
end;

function SawWords(N: Integer): TSmallIntArray;
var
  I: Integer;
begin
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := -2048 + (4095 * (I mod 153)) div 152;
end;

procedure LogEntries(D: TS950Disk; const What: string);
var
  I: Integer;
begin
  Line(Format('%s entries %d image %s rev %d', [What, Length(D.Entries), ImageHash(D), D.Revision]));
  for I := 0 to High(D.Entries) do
    with D.Entries[I] do
      Line(Format('  %d %s ''%s'' len %d start %d blocks %d ok %d', [Slot, string(EntryType), Name,
                  Length, StartBlock, ChainBlocks, B01(ChainOk)]));
end;

procedure Res(const What: string; Ok: Boolean; const Why: string);
begin
  Line(Format('%s %d ''%s''', [What, B01(Ok), Why]));
end;

function HeaderByte(D: TS950Disk; const E: TDiskEntry; At: Integer): Integer;
begin
  Result := D.Image[E.StartBlock * TS950Disk.BlockSize + At];
end;

function Mem(D: TS950Disk; const E: TDiskEntry): Integer;
begin
  Result := HeaderByte(D, E, $36) or (HeaderByte(D, E, $37) shl 8) or (HeaderByte(D, E, $38) shl 16);
end;

function Lp(D: TS950Disk; const E: TDiskEntry): Integer;
begin
  Result := HeaderByte(D, E, $28) or (HeaderByte(D, E, $29) shl 8);
end;

function U16Of(const B: TBytes; At: Integer): Integer;
begin
  Result := B[At] or (B[At + 1] shl 8);
end;

procedure SameWords(D: TS950Disk; const E: TDiskEntry; const Want: TSmallIntArray; const What: string);
var
  Got: TSmallIntArray;
  N, I: Integer;
begin
  Got := D.SampleWords12(E);
  N := Length(Want) and not 1;
  Inc(Checks);
  if Length(Got) <> N then
  begin
    Fail('built', What, Length(Got), N);
    Exit;
  end;
  for I := 0 to N - 1 do
    if Got[I] <> Want[I] then
    begin
      Fail('built', What, Got[I], Want[I]);
      Exit;
    end;
end;

// DiskEditCheck's "making a disk from nothing", to the letter.
procedure BuiltDisk(const Dir, Tag: string);
const
  Order: array[0..4] of Char = ('P', 'P', 'S', 'S', 'S');
  Arena = $C5F6;
  Table = Arena + 70 * 4;
var
  D: TS950Disk;
  Why, HashBefore: string;
  Saw, Kick, Big: TNewSample;
  I, FirstRebuild, SecondRebuild: Integer;
  Lead, Kit, SawE, KkE, BigE: PDiskEntry;
  LeadRaw, KitRaw: TBytes;
  Patch, KitPatch: TS950Patch;
begin
  D := TS950Disk.Blank('BUILT');
  Patch := nil;
  KitPatch := nil;
  try
    Saw := NewSample('saw', SawWords(1223));     Saw.Rate := 40000;   // odd: last word dropped
    Kick := NewSample('kick', SawWords(6000));   Kick.Rate := 20000; Kick.LoopMode := 'O'; Kick.RootNote := 36;
    Big := NewSample('long', SawWords(140000));  Big.Rate := 20000;  // over a 128K page

    Inc(Checks); if not D.AddSample(Saw, Why) then Fail('built', Why, 0, 1);
    Inc(Checks); if not D.AddSample(Kick, Why) then Fail('built', Why, 0, 1);
    Inc(Checks); if not D.AddSample(Big, Why) then Fail('built', Why, 0, 1);

    Inc(Checks); if not D.AddProgram('lead', 2, Why) then Fail('built', Why, 0, 1);
    Inc(Checks); if not D.AddProgram('kit', 1, Why) then Fail('built', Why, 0, 1);

    // a duplicate name within a type is refused, and the disk is untouched by it
    Inc(Checks);
    HashBefore := ImageHash(D);
    if D.AddSample(Saw, Why) then Fail('built', 'a second SAW was allowed', 1, 0);
    Res('duplicate', False, Why);
    Inc(Checks); if ImageHash(D) <> HashBefore then Fail('built', 'a refused sample moved bytes', 1, 0);

    Inc(Checks);
    if Length(D.Entries) <> 5 then
    begin
      Fail('built', 'five entries', Length(D.Entries), 5);
      Exit;
    end;

    for I := 0 to 4 do
    begin
      Inc(Checks);
      if (D.Entries[I].Slot <> I) or (D.Entries[I].EntryType <> Order[I]) then
        Fail('built', 'directory order and contiguity', D.Entries[I].Slot, I);
    end;

    Lead := D.Find('LEAD', 'P');
    Kit := D.Find('KIT', 'P');
    SawE := D.Find('SAW', 'S');
    KkE := D.Find('KICK', 'S');
    BigE := D.Find('LONG', 'S');

    Inc(Checks);
    if (Lead = nil) or (Kit = nil) or (SawE = nil) or (KkE = nil) or (BigE = nil) then
    begin
      Fail('built', 'every file found by name', 0, 1);
      Exit;
    end;

    Inc(Checks); if SawE^.SampleCount <> 1222 then Fail('built', 'SAW words (odd one dropped)', SawE^.SampleCount, 1222);
    Inc(Checks); if SawE^.SampleRate <> 40000 then Fail('built', 'SAW rate', SawE^.SampleRate, 40000);
    Inc(Checks); if SawE^.LoopMode <> 'L' then Fail('built', 'SAW looped', Ord(SawE^.LoopMode), Ord('L'));
    Inc(Checks); if KkE^.LoopMode <> 'O' then Fail('built', 'KICK one-shot', Ord(KkE^.LoopMode), Ord('O'));
    Inc(Checks); if SawE^.LoopLength <> 1222 then Fail('built', 'SAW loop is the whole sample', SawE^.LoopLength, 1222);

    SameWords(D, SawE^, Saw.Words12, 'SAW audio round-trips');
    SameWords(D, KkE^, Kick.Words12, 'KICK audio round-trips');
    SameWords(D, BigE^, Big.Words12, 'LONG audio round-trips');

    Inc(Checks); if Mem(D, SawE^) <> $18000 then Fail('built', 'first sample at the RAM base', Mem(D, SawE^), $18000);
    Inc(Checks); if Mem(D, KkE^) <> $18000 + 2448 then Fail('built', 'second follows: 1222 words in sixteens', Mem(D, KkE^), $18000 + 2448);
    Inc(Checks); if Mem(D, BigE^) <> $18000 + 2448 + 12000 then Fail('built', 'third follows', Mem(D, BigE^), $18000 + 2448 + 12000);
    Inc(Checks); if Lp(D, SawE^) <> $B6F4 then Fail('built', 'first loop descriptor', Lp(D, SawE^), $B6F4);
    Inc(Checks); if Lp(D, KkE^) <> $B6F4 + 30 then Fail('built', 'a looped sample takes three', Lp(D, KkE^), $B6F4 + 30);
    Inc(Checks); if Lp(D, BigE^) <> $B6F4 + 30 + 20 then Fail('built', 'a one-shot takes two', Lp(D, BigE^), $B6F4 + 50);

    Inc(Checks); if not D.SetZoneSample(Lead^, 0, 0, 'SAW') then Fail('built', 'zone SAW', 0, 1);
    Inc(Checks); if not D.SetZoneSample(Lead^, 1, 0, 'LONG') then Fail('built', 'zone LONG', 0, 1);
    Inc(Checks); if not D.SetZoneSample(Kit^, 0, 0, 'KICK') then Fail('built', 'zone KICK', 0, 1);
    Inc(Checks); if D.SetZoneSample(Kit^, 1, 0, 'KICK') then Fail('built', 'no third keygroup to name', 1, 0);

    D.SetKeygroupParam(Kit^, 0, kpConstantPitch, 1);
    D.SetKeygroupParam(Kit^, 0, kpOneShot, 1);
    D.SetKeygroupParam(Kit^, 0, kpLowKey, 36);
    D.SetKeygroupParam(Kit^, 0, kpHighKey, 36);

    FirstRebuild := D.RebuildPointers;
    Inc(Checks);
    SecondRebuild := D.RebuildPointers;
    if SecondRebuild <> 0 then Fail('built', 'a second rebuild changes nothing', 1, 0);
    Line(Format('built rebuild %d %d', [FirstRebuild, SecondRebuild]));

    LeadRaw := D.ReadFile(Lead^);
    KitRaw := D.ReadFile(Kit^);

    Inc(Checks); if U16Of(LeadRaw, 18) <> Arena then Fail('built', 'LEAD loads at the arena', U16Of(LeadRaw, 18), Arena);
    Inc(Checks); if LeadRaw[23] <> 2 then Fail('built', 'LEAD header counts two', LeadRaw[23], 2);
    Inc(Checks); if U16Of(KitRaw, 18) <> Arena + 70 * 3 then Fail('built', 'KIT loads after the empty record', U16Of(KitRaw, 18), Arena + 210);
    Inc(Checks); if KitRaw[23] <> 1 then Fail('built', 'KIT header counts one', KitRaw[23], 1);

    Inc(Checks); if U16Of(LeadRaw, 38 + 68) <> Arena + 70 then Fail('built', 'LEAD kg0 chains to kg1', U16Of(LeadRaw, 38 + 68), Arena + 70);
    Inc(Checks); if U16Of(LeadRaw, 38 + 70 + 68) <> 0 then Fail('built', 'LEAD kg1 ends the chain', U16Of(LeadRaw, 38 + 70 + 68), 0);
    Inc(Checks); if U16Of(KitRaw, 38 + 68) <> 0 then Fail('built', 'KIT kg0 ends the chain', U16Of(KitRaw, 38 + 68), 0);

    Inc(Checks); if U16Of(LeadRaw, 38 + 40) <> Table then Fail('built', 'SAW is sample 0', U16Of(LeadRaw, 38 + 40), Table);
    Inc(Checks); if U16Of(LeadRaw, 38 + 70 + 40) <> Table + 140 then Fail('built', 'LONG is sample 2', U16Of(LeadRaw, 38 + 70 + 40), Table + 140);
    Inc(Checks); if U16Of(KitRaw, 38 + 40) <> Table + 70 then Fail('built', 'KICK is sample 1', U16Of(KitRaw, 38 + 40), Table + 70);
    Inc(Checks); if U16Of(LeadRaw, 38 + 62) <> 0 then Fail('built', 'an empty zone points nowhere', U16Of(LeadRaw, 38 + 62), 0);

    Patch := D.BuildPatch(Lead^);
    Inc(Checks);
    if (Patch = nil) or (Length(Patch.Keygroups) <> 2) or (Patch.Keygroups[0].Sound = nil)
       or (Patch.Keygroups[1].Sound = nil) then
      Fail('built', 'LEAD plays two keygroups with sounds', 0, 2);

    KitPatch := D.BuildPatch(Kit^);
    Inc(Checks);
    if (KitPatch = nil) or (Length(KitPatch.Keygroups) <> 1) or not KitPatch.Keygroups[0].ConstantPitch
       or not KitPatch.Keygroups[0].OneShot or (KitPatch.Keygroups[0].LowKey <> 36) then
      Fail('built', 'KIT is a one-shot drum on 36', 0, 1);

    LogEntries(D, 'built');
    Inc(Checks); if not Save(D, Dir + '\built_' + Tag + '.img') then Fail('built', 'could not write', 0, 1);
  finally
    ReleasePatch(KitPatch);
    ReleasePatch(Patch);
    D.Free;
  end;
end;

// DiskEditCheck's high-density disk.
procedure HdDisk(const Dir, Tag: string);
var
  D, Back: TS950Disk;
  Why: string;
  Waves: array of TSmallIntArray;
  W, Got: TSmallIntArray;
  K, I, Lowest, Highest, Added: Integer;
  S: TNewSample;
  E: PDiskEntry;
  Ok, SameW: Boolean;
begin
  D := TS950Disk.Blank('HD', True);
  Back := TS950Disk.Create;
  try
    Inc(Checks); if Length(D.Image) <> 1638400 then Fail('hd', '1600K', Length(D.Image) div 1024, 1600);
    Inc(Checks); if (not D.IsHighDensity) or (D.HeaderBlocks <> 5) then Fail('hd', 'a five-block header', D.HeaderBlocks, 5);

    Waves := nil;
    for K := 0 to 5 do
    begin
      SetLength(W, 140000);
      for I := 0 to 139999 do
        W[I] := ((I * (K + 3)) mod 4096) - 2048;
      SetLength(Waves, K + 1);
      Waves[K] := W;
      W := nil;

      S := NewSample('HD' + IntToStr(K), Waves[K]);
      S.Rate := 48000;
      Inc(Checks); if not D.AddSample(S, Why) then Fail('hd', 'sample ' + IntToStr(K) + ': ' + Why, 0, 1);
    end;
    Inc(Checks); if not D.AddProgram('HD PROG', 1, Why) then Fail('hd', Why, 0, 1);

    Lowest := 1 shl 30;
    Highest := 0;
    for I := 0 to High(D.Entries) do
    begin
      if D.Entries[I].StartBlock < Lowest then
        Lowest := D.Entries[I].StartBlock;
      if D.Entries[I].StartBlock + D.Entries[I].ChainBlocks - 1 > Highest then
        Highest := D.Entries[I].StartBlock + D.Entries[I].ChainBlocks - 1;
    end;
    Inc(Checks); if Lowest <> 5 then Fail('hd', 'file data starts at block 5', Lowest, 5);
    Inc(Checks); if Highest <= 800 then Fail('hd', 'the files reach past block 800', Highest, 801);

    Inc(Checks);
    if not Back.LoadBytes('HD', D.Image, Why) then
      Fail('hd', 'reload: ' + Why, 0, 1)
    else
    begin
      Inc(Checks); if Length(Back.Entries) <> 7 then Fail('hd', 'seven files come back', Length(Back.Entries), 7);
      for K := 0 to 5 do
      begin
        E := Back.Find('HD' + IntToStr(K), 'S');
        Inc(Checks);
        if E = nil then
        begin
          Fail('hd', 'a sample comes back by name', 0, 1);
          Continue;
        end;
        Inc(Checks); if E^.SampleRate <> 48000 then Fail('hd', '48 kHz survives', E^.SampleRate, 48000);
        Got := Back.SampleWords12(E^);
        Inc(Checks);
        SameW := Length(Got) = Length(Waves[K]);
        if SameW then
          for I := 0 to High(Got) do
            if Got[I] <> Waves[K][I] then
              SameW := False;
        if not SameW then
          Fail('hd', 'sample ' + IntToStr(K) + ' audio round-trips', Length(Got), 140000);
      end;
    end;

    // And filled to the last block: the message a full HD disk gives.
    Added := 0;
    for K := 6 to 39 do
    begin
      S := NewSample('FILL' + IntToStr(K), Waves[K mod 6]);
      S.LoopMode := 'A';
      Ok := D.AddSample(S, Why);
      if not Ok then
      begin
        Res('hd full', Ok, Why);
        Break;
      end;
      Inc(Added);
    end;
    Line(Format('hd filled with %d more', [Added]));
    LogEntries(D, 'hd');
    Inc(Checks); if not Save(D, Dir + '\hd_' + Tag + '.img') then Fail('hd', 'could not write', 0, 1);
  finally
    Back.Free;
    D.Free;
  end;
end;

// The failures, and the names, and their messages.
procedure Failures_(const Dir, Tag: string);
const
  Names: array[0..7] of string = ('', '   ', 'abcdefghijklmnop', 'a'#9'b', ' lead ', 'Mixed Case',
                                  'x'#127'y', '2 sample');
var
  D: TS950Disk;
  Why: string;
  S, Huge: TNewSample;
  One: TSmallIntArray;
  I, Added: Integer;
  P: PDiskEntry;
  Ok: Boolean;
begin
  D := TS950Disk.Blank;
  try
    SetLength(One, 1);
    One[0] := 5;
    S := NewSample('one', One);
    Ok := D.AddSample(S, Why); Res('one word', Ok, Why);
    S.Words12 := nil;
    Ok := D.AddSample(S, Why); Res('no words', Ok, Why);
    Ok := D.AddProgram('p', 0, Why); Res('programme 0', Ok, Why);
    Ok := D.AddProgram('p', 65, Why); Res('programme 65', Ok, Why);
    Ok := D.AddProgram('p64', 64, Why); Res('programme 64', Ok, Why);
    Ok := D.AddProgram('P64 ', 64, Why); Res('programme 64 again', Ok, Why);
    Ok := D.AddProgram('p1', 1, Why); Res('programme 1', Ok, Why);

    Huge := NewSample('huge', SawWords(600000));
    Ok := D.AddSample(Huge, Why); Res('huge', Ok, Why);
    LogEntries(D, 'programmes');
  finally
    D.Free;
  end;

  // a directory filled to its 64 slots
  D := TS950Disk.Blank('FULL');
  try
    Added := 0;
    for I := 0 to 69 do
    begin
      S := NewSample('s' + IntToStr(I), SawWords(2 + I));
      if not D.AddSample(S, Why) then
      begin
        Res('directory', False, Why);
        Break;
      end;
      Inc(Added);
    end;
    Line(Format('directory took %d', [Added]));
    Ok := D.AddProgram('late', 1, Why); Res('programme into a full directory', Ok, Why);
    LogEntries(D, 'full');
  finally
    D.Free;
  end;

  // 63 samples, then a programme: the slot opened in front of them
  D := TS950Disk.Blank('OPEN');
  try
    for I := 0 to 62 do
    begin
      S := NewSample('t' + IntToStr(I), SawWords(40 + I));
      case I mod 3 of
        0: S.LoopMode := 'O';
        1: S.LoopMode := 'L';
      else
        S.LoopMode := 'A';
      end;
      D.AddSample(S, Why);
    end;
    Ok := D.AddProgram('front', 2, Why); Res('programme in front', Ok, Why);
    P := D.Find('FRONT', 'P');
    if P <> nil then
    begin
      D.SetZoneSample(P^, 0, 0, 't5');
      D.SetZoneSample(P^, 1, 1, 'T62');
    end;
    Line(Format('open rebuild %d', [D.RebuildPointers]));
    LogEntries(D, 'open');
    Inc(Checks); if not Save(D, Dir + '\open_' + Tag + '.img') then Fail('open', 'could not write', 0, 1);
  finally
    D.Free;
  end;

  // a disk filled by blocks
  D := TS950Disk.Blank('BLOCKS');
  try
    Added := 0;
    for I := 0 to 39 do
    begin
      S := NewSample('big' + IntToStr(I), SawWords(100000));
      if not D.AddSample(S, Why) then
      begin
        Res('blocks', False, Why);
        Break;
      end;
      Inc(Added);
    end;
    Line(Format('blocks took %d', [Added]));
    Ok := D.AddProgram('late', 1, Why); Res('programme onto a full disk', Ok, Why);
    LogEntries(D, 'blocks');
  finally
    D.Free;
  end;

  // names
  for I := 0 to High(Names) do
    Line('normalise ''' + TS950Disk.NormaliseNameFor(Names[I]) + '''');
end;

// A disk holding what the library disks lack: blank S900 filter envelopes (every
// fresh keygroup has them), alternating, one-shot and short loops, a rate the engine
// falls back from, fine tuning, two-zone keygroups at every kind of switch.
function RichDisk: TS950Disk;
type
  TSpec = record
    Name: string;
    N, Rate, Root, Fine: Integer;
    Mode: Char;
    Loop: Integer;
  end;
const
  Specs: array[0..5] of TSpec = (
    (Name: 'alt';   N: 5000; Rate: 30000; Root: 48; Fine: 5;  Mode: 'A'; Loop: 1200),
    (Name: 'shot';  N: 3001; Rate: 44100; Root: 60; Fine: 15; Mode: 'O'; Loop: -1),
    (Name: 'short'; N: 900;  Rate: 500;   Root: 72; Fine: 0;  Mode: 'L'; Loop: 7),
    (Name: 'zero';  N: 2000; Rate: 40000; Root: 59; Fine: 8;  Mode: 'L'; Loop: 0),
    (Name: 'over';  N: 1500; Rate: 20000; Root: 61; Fine: 3;  Mode: 'A'; Loop: 99999),
    (Name: 'plain'; N: 4000; Rate: 32000; Root: 36; Fine: 0;  Mode: 'L'; Loop: -1));
  Names: array[0..5] of string = ('alt', 'shot', 'short', 'zero', 'over', 'plain');
  Switches: array[0..3] of Integer = (1, 64, 127, 128);
var
  D: TS950Disk;
  Why: string;
  I, K: Integer;
  Ns: TNewSample;
  A, B: PDiskEntry;
  Ok: Boolean;
begin
  D := TS950Disk.Blank('RICH');

  for I := 0 to High(Specs) do
  begin
    Ns := NewSample(Specs[I].Name, SawWords(Specs[I].N));
    Ns.Rate := Specs[I].Rate;
    Ns.RootNote := Specs[I].Root;
    Ns.Fine := Specs[I].Fine;
    Ns.LoopMode := Specs[I].Mode;
    Ns.LoopLength := Specs[I].Loop;
    K := 0;
    while K < Length(Ns.Words12) do
    begin
      Ns.Words12[K] := K mod 5000 - 2500;                     // and clipped
      Inc(K, 7);
    end;
    Ok := D.AddSample(Ns, Why); Res('rich sample', Ok, Why);
  end;

  Ok := D.AddProgram('prog a', 4, Why); Res('rich prog A', Ok, Why);
  Ok := D.AddProgram('prog b', 3, Why); Res('rich prog B', Ok, Why);

  A := D.Find('PROG A', 'P');
  B := D.Find('PROG B', 'P');
  if (A = nil) or (B = nil) then
  begin
    Fail('rich', 'programmes', 0, 1);
    Result := D;
    Exit;
  end;

  for K := 0 to 3 do
  begin
    D.SetZoneSample(A^, K, 0, Names[K]);
    D.SetZoneSample(A^, K, 1, Names[(K + 2) mod 6]);
    D.SetKeygroupParam(A^, K, kpVelocitySwitch, Switches[K]);
    D.SetKeygroupParam(A^, K, kpLowKey, 20 * K);
    D.SetKeygroupParam(A^, K, kpHighKey, 20 * K + 30);
    D.SetKeygroupParam(A^, K, kpZone2Transpose, K - 2);
    D.SetKeygroupParam(A^, K, kpZone1Fine, 40 * K);
  end;
  for K := 0 to 2 do
    D.SetZoneSample(B^, K, 0, Names[3 + K]);
  D.SetZoneSample(B^, 2, 1, 'plain');            // a second zone at the default switch
  D.SetKeygroupParam(B^, 0, kpVcfSustain, 50);   // one blank envelope written

  Line(Format('rich rebuild %d', [D.RebuildPointers]));
  LogEntries(D, 'rich');
  Result := D;
end;

type
  TPitchCase = record
    Fine, Transpose: Integer;
    Semitones: Double;
  end;

const
  PitchCases: array[0..6] of TPitchCase = (
    (Fine: 192; Transpose: 0; Semitones: 12), (Fine: 80; Transpose: 0; Semitones: 5),
    (Fine: 0; Transpose: 0; Semitones: 0), (Fine: 144; Transpose: -1; Semitones: -7),
    (Fine: 64; Transpose: -1; Semitones: -12), (Fine: 128; Transpose: 1; Semitones: 24),
    (Fine: 255; Transpose: -1; Semitones: -1.0 / 16));

var
  Dir, Tag, Error, Lbl: string;
  I, J, Disks: Integer;
  Paths, List: TStringList;
  Z: TDiskZone;
  Rich, Original: TS950Disk;
begin
  if ParamCount < 3 then
  begin
    WriteLn('usage: diskedit_pas <log.txt> <imagedir> <tag> [<image> ...]');
    ExitCode := 2;
    Exit;
  end;

  AssignFile(Outp, ParamStr(1));
  SetTextBuf(Outp, OutBuf, SizeOf(OutBuf));
  Rewrite(Outp);
  Dir := ParamStr(2);
  Tag := ParamStr(3);
  Checks := 0;
  Failures := 0;
  Edits := 0;

  //
  // A zone's pitch: transpose and fine as one signed 16-bit count of sixteenths of a
  // semitone.
  //
  for I := 0 to High(PitchCases) do
  begin
    Z.Init;
    Z.Fine := PitchCases[I].Fine;
    Z.Transpose := PitchCases[I].Transpose;
    Inc(Checks);
    if Z.PitchOffset <> PitchCases[I].Semitones then
      Fail('zone pitch', 'fine ' + IntToStr(PitchCases[I].Fine) + ' transpose ' + IntToStr(PitchCases[I].Transpose),
           Trunc(Z.PitchOffset * 16), Trunc(PitchCases[I].Semitones * 16));
  end;

  Line('making a disk from nothing');
  BuiltDisk(Dir, Tag);
  Line('a high-density disk');
  HdDisk(Dir, Tag);
  Line('failures');
  Failures_(Dir, Tag);

  Disks := 0;
  Rich := RichDisk;
  try
    Inc(Checks); if not Save(Rich, Dir + '\rich_' + Tag + '.img') then Fail('rich', 'could not write', 0, 1);
    EditDisk(Rich, 'RICH', Dir, Tag);
    Inc(Disks);
  finally
    Rich.Free;
  end;

  // An argument @file names a file listing images, one to a line.
  Paths := TStringList.Create;
  for I := 4 to ParamCount do
  begin
    if Copy(ParamStr(I), 1, 1) <> '@' then
    begin
      Paths.Add(ParamStr(I));
      Continue;
    end;
    List := TStringList.Create;
    try
      List.LoadFromFile(Copy(ParamStr(I), 2, MaxInt));
      for J := 0 to List.Count - 1 do
        if TrimRight(List[J]) <> '' then
          Paths.Add(TrimRight(List[J]));
    finally
      List.Free;
    end;
  end;

  for I := 0 to Paths.Count - 1 do
  begin
    Original := TS950Disk.Create;
    try
      if not Original.LoadFile(Paths[I], Error) then
      begin
        Fail(Paths[I], 'could not read', 0, 1);
        Continue;
      end;
      Lbl := ChangeFileExt(ExtractFileName(Paths[I]), '');
      EditDisk(Original, Lbl, Dir, Tag);
      Inc(Disks);
    finally
      Original.Free;
    end;
  end;

  Paths.Free;
  Line(Format('%d disks, %d edits, %d checks, %d failed', [Disks, Edits, Checks, Failures]));
  CloseFile(Outp);
  WriteLn(Format('diskedit_pas: %d disks, %d edits, %d checks, %d failed', [Disks, Edits, Checks, Failures]));
  if Failures <> 0 then
    ExitCode := 1;
end.
