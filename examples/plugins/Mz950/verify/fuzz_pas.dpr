// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Hostile input for S950Disk and S950Hfe: thousands of random and mutated images fed to
// LoadBytes, and on every one that loads, everything a caller can do with it - every entry
// read, every keygroup parsed, every setting read and some written, every sample decoded,
// every programme built into a patch (and rebuilt with the first as `reuse`, and both
// released), and on a copy the writing half. Nothing may raise: built with -Cr -Co -Ct -CR,
// a range error or an overflow is an exception here, and is counted. The heap tracer (-gh)
// reports what was not freed.
//
//     fuzz_pas <casedir> <cases> <seed> <image> [<image> ...]     (or @listfile)
//
// Every case that is cheap enough to dump is also written to <casedir> (case_NNNNN.bin,
// and their names to <casedir>\list.txt), for disk_cpp and disk_pas to dump and compare -
// which holds the C++ to the same inputs.
program fuzz_pas;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  SysUtils, Classes, S950Patch, S950Hfe, S950Disk;

type
  TBytesArray = array of TBytes;

const
  Sig: AnsiString = 'HXCPICFE';

var
  RngState: UInt64;
  Raised, Loaded, Refused, Ops, Saved, Patches, Sounds, Writes: Int64;
  KindCount: array[0..11] of Integer;
  KindTime: array[0..11] of Double;
  CaseStart: TDateTime;

{$Q-}{$R-}
function Next: UInt64;
begin
  RngState := RngState xor (RngState shl 13);
  RngState := RngState xor (RngState shr 7);
  RngState := RngState xor (RngState shl 17);
  Result := RngState;
end;
{$Q+}{$R+}

function Rand(N: Integer): Integer;
begin
  if N <= 0 then
    Result := 0
  else
    Result := Integer(Next mod UInt64(N));
end;

function Chance(Percent: Integer): Boolean;
begin
  Result := Rand(100) < Percent;
end;

function ReadAll(const Path: string): TBytes;
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

procedure WriteAll(const Path: string; const B: TBytes);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(B) > 0 then
      F.WriteBuffer(B[0], Length(B));
  finally
    F.Free;
  end;
end;

procedure Put16(var B: TBytes; At, V: Integer);
begin
  if (At >= 0) and (At + 1 < Length(B)) then
  begin
    B[At] := V and $FF;
    B[At + 1] := (V shr 8) and $FF;
  end;
end;

procedure Put32(var B: TBytes; At: Integer; V: Int64);
var
  I: Integer;
begin
  if (At >= 0) and (At + 3 < Length(B)) then
    for I := 0 to 3 do
      B[At + I] := (V shr (8 * I)) and $FF;
end;

function RandomU32: Int64;
begin
  case Rand(6) of
    0: Result := 0;
    1: Result := $FFFFFFFF;
    2: Result := Rand(100);
    3: Result := Rand(200000);
    4: Result := $7FFFFFFF + Rand(3);
  else
    Result := Int64(Next and $FFFFFFFF);
  end;
end;

procedure FlipBits(var B: TBytes; Count, From, Span: Integer);
var
  I, At: Integer;
begin
  if Length(B) = 0 then
    Exit;
  for I := 1 to Count do
  begin
    At := From + Rand(Span);
    if (At >= 0) and (At < Length(B)) then
      B[At] := B[At] xor (1 shl Rand(8));
  end;
end;

procedure RandomBytes(var B: TBytes; From, Count: Integer);
var
  I: Integer;
begin
  for I := From to From + Count - 1 do
    if (I >= 0) and (I < Length(B)) then
      B[I] := Next and $FF;
end;

// A sample header's fields, any of them, anything.
procedure MangleSampleHeader(var B: TBytes; H: Integer);
begin
  if Chance(60) then Put32(B, H + $10, RandomU32);              // count
  if Chance(40) then Put16(B, H + $14, Rand(65536));             // rate
  if Chance(40) then Put16(B, H + $16, Rand(65536));             // tuning
  if Chance(30) then Put16(B, H + $18, Rand(65536));             // loudness
  if Chance(60) then
    case Rand(5) of
      0: B[H + $1A] := Ord('O');
      1: B[H + $1A] := Ord('L');
      2: B[H + $1A] := Ord('A');
    else
      B[H + $1A] := Rand(256);
    end;
  if Chance(70) then Put32(B, H + $1C, RandomU32);              // end
  if Chance(70) then Put32(B, H + $20, RandomU32);              // start
  if Chance(70) then Put32(B, H + $24, RandomU32);              // length
  if Chance(30) then Put16(B, H + $28, Rand(65536));
  if Chance(30) then B[H + $2B] := Rand(256);
  if Chance(30) then RandomBytes(B, H + $36, 3);
end;

// A directory and allocation table of nothing but trouble, over random blocks.
function RandomDirectory(const Samples: TBytesArray): TBytes;
var
  Blocks, Entries, I, O, Slot, Len, Start, B, T, K, Kg, Z: Integer;
  Types: string;
begin
  if Chance(25) then
    Blocks := 1600
  else
    Blocks := 800;
  SetLength(Result, Blocks * 1024);
  FillChar(Result[0], Length(Result), 0);

  Types := 'PSDOPSPS';
  Entries := 1 + Rand(64);
  for I := 0 to Entries - 1 do
  begin
    if Chance(70) then
      Slot := I
    else
      Slot := Rand(64);
    O := Slot * 24;
    RandomBytes(Result, O, 16);
    for K := 0 to 9 do
      if Chance(80) then
        Result[O + K] := 32 + Rand(95);
    if Chance(5) then
      Result[O] := 0;
    if Chance(90) then
      Result[O + 16] := Ord(Types[1 + Rand(Length(Types))])
    else
      Result[O + 16] := Rand(256);
    case Rand(6) of
      0: Len := Rand($1000000);
      1: Len := 38 + 70 * (1 + Rand(64));
      2: Len := 38 + 70 * (1 + Rand(400));
      3: Len := Rand(100);
      4: Len := $FFFFFF;
    else
      Len := 60 + Rand(200000);
    end;
    Result[O + 17] := Len and $FF;
    Result[O + 18] := (Len shr 8) and $FF;
    Result[O + 19] := (Len shr 16) and $FF;
    if Chance(90) then
      Start := Rand(Blocks)
    else
      Start := Rand(65536);
    Put16(Result, O + 20, Start);
    if Chance(20) then
      RandomBytes(Result, O + 22, 2);
  end;

  // The allocation table: ends, chains, cycles, self-loops, nonsense.
  for B := 0 to Blocks - 1 do
    case Rand(8) of
      0: Put16(Result, $600 + 2 * B, 0);
      1: Put16(Result, $600 + 2 * B, $8000);
      2: Put16(Result, $600 + 2 * B, B);
      3: Put16(Result, $600 + 2 * B, Rand(Blocks));
      4: Put16(Result, $600 + 2 * B, Rand(65536));
    else
      Put16(Result, $600 + 2 * B, B + 1);
    end;

  // Block contents: random, or real sample data, or programme-looking records.
  for B := 4 to Blocks - 1 do
  begin
    T := Rand(10);
    if T < 3 then
      RandomBytes(Result, B * 1024, 1024)
    else if (T < 6) and (Length(Samples) > 0) then
    begin
      K := Rand(Length(Samples));
      if Length(Samples[K]) >= 1024 then
        Move(Samples[K][Rand(Length(Samples[K]) div 1024) * 1024], Result[B * 1024], 1024);
    end
    else if T < 8 then
    begin
      // keygroup-ish: plausible zone names and pointers
      for Kg := 0 to 13 do
      begin
        O := B * 1024 + Kg * 70;
        if O + 70 > Length(Result) then
          Break;
        RandomBytes(Result, O, 70);
        for Z := 0 to 1 do
        begin
          if Chance(50) then
            Move(Result[Rand(Entries) * 24], Result[O + 24 + 22 * Z], 10);
          if Chance(30) then
            Put16(Result, O + 40 + 22 * Z, 0);
          if Chance(20) then
            FillChar(Result[O + 34], 4, $20);
        end;
      end;
    end;
  end;

  // Sample headers where the entries start.
  for I := 0 to 63 do
  begin
    O := I * 24;
    if Result[O + 16] = Ord('S') then
    begin
      Start := Result[O + 20] or (Result[O + 21] shl 8);
      if Start < Blocks then
        MangleSampleHeader(Result, Start * 1024);
    end;
  end;
end;

// A real image with its directory or its allocation table damaged.
procedure DamageDirectory(var B: TBytes);
var
  I, N, O, Blocks, Len, Block: Integer;
begin
  Blocks := Length(B) div 1024;
  N := 1 + Rand(8);
  for I := 1 to N do
  begin
    O := Rand(64) * 24;
    case Rand(7) of
      0: begin Len := Rand($1000000); B[O + 17] := Len and $FF; B[O + 18] := (Len shr 8) and $FF; B[O + 19] := Len shr 16; end;
      1: begin Len := 38 + 70 * Rand(300); B[O + 17] := Len and $FF; B[O + 18] := (Len shr 8) and $FF; B[O + 19] := Len shr 16; end;
      2: Put16(B, O + 20, Rand(Blocks + 10));
      3: B[O + 16] := Ord('P');
      4: B[O + 16] := Ord('S');
      5: B[O] := 0;
    else
      RandomBytes(B, O, 24);
    end;
  end;
  N := Rand(40);
  for I := 1 to N do
  begin
    Block := Rand(Blocks);
    case Rand(4) of
      0: Put16(B, $600 + 2 * Block, Block);                    // a block that loops on itself
      1: Put16(B, $600 + 2 * Block, Rand(Blocks));             // a cycle, likely
      2: Put16(B, $600 + 2 * Block, 0);
    else
      Put16(B, $600 + 2 * Block, Rand(65536));
    end;
  end;
end;

procedure DamageSampleHeaders(var B: TBytes);
var
  I, O, Start: Integer;
begin
  for I := 0 to 63 do
  begin
    O := I * 24;
    if (B[O] <> 0) and (B[O + 16] = Ord('S')) and Chance(70) then
    begin
      Start := B[O + 20] or (B[O + 21] shl 8);
      if Start * 1024 + 60 <= Length(B) then
        MangleSampleHeader(B, Start * 1024);
    end;
  end;
end;

// An HFE whose header and track table are garbage.
procedure DamageHfeHeader(var B: TBytes; Big: Boolean);
var
  I, N: Integer;
begin
  if Length(B) < 1024 then
    Exit;
  if Big then
  begin
    // 255 x 255 tracks, with the track table out of reach: every track reads empty, and
    // what is left is the image the header asks for - 255 x 255 x 5 sectors, 333 MB (in the
    // C++ too) - which loadBytes then refuses. (A track table in reach makes it decode the
    // same cells once for every side, which takes minutes, not a bound worth a fuzz case.)
    B[9] := 255;
    B[10] := 255;
    Put16(B, 18, 65535);
    Exit;
  end
  else
  begin
    if Chance(50) then B[9] := Rand(256);
    if Chance(50) then B[10] := 1 + Rand(4);
    if Chance(20) then B[10] := Rand(256) div 32;
  end;
  if Chance(40) then Put16(B, 18, Rand(65536));                 // the track table, anywhere
  if Chance(20) then Put16(B, 18, Rand(8));
  N := Rand(200);
  for I := 1 to N do
    Put16(B, 512 + Rand(1024), Rand(65536));                     // track offsets and lengths
end;

function TotalKeygroups(D: TS950Disk): Int64;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(D.Entries) do
    Inc(Result, TS950Disk.KeygroupCount(D.Entries[I]));
end;

// Everything read-only a caller can do, and a few writes, on one loaded disk.
procedure Exercise(D: TS950Disk; Heavy: Boolean);
var
  E, Kg, N, P, O, I, Ks: Integer;
  Raw: TBytes;
  Words: TSmallIntArray;
  Groups: TDiskKeygroupArray;
  At: NativeInt;
  Patch, Again: TS950Patch;
  Which: array[0..7] of Integer;
  W: TS950Disk;
  S: TNewSample;
  Why: string;
  Pe: PDiskEntry;
begin
  for E := 0 to High(D.Entries) do
  begin
    Raw := D.ReadFile(D.Entries[E]);
    Words := D.SampleWords12(D.Entries[E]);
    Groups := D.Keygroups(D.Entries[E]);
    N := TS950Disk.KeygroupCount(D.Entries[E]);
    D.Find(D.Entries[E].Name, D.Entries[E].EntryType);
    D.SampleIndex(D.Entries[E].Name);
    D.Entries[E].Seconds;
    Inc(Ops, 6);

    Which[0] := -1; Which[1] := 0; Which[2] := 1; Which[3] := N div 2;
    Which[4] := N - 1; Which[5] := N; Which[6] := N + 1; Which[7] := Rand(N + 2);
    for Ks := 0 to 7 do
    begin
      Kg := Which[Ks];
      for P := 0 to KeygroupParamCount - 1 do
        D.GetKeygroupParam(D.Entries[E], Kg, TKeygroupParam(P));
      D.VcfBlank(D.Entries[E], Kg);
      for O := -1 to 70 do
        if (O < 2) or (O > 67) or Chance(10) then
          D.KeygroupByteAt(D.Entries[E], Kg, O, At);
      Inc(Ops, KeygroupParamCount + 1);
    end;

    Patch := D.BuildPatch(D.Entries[E]);
    if Patch <> nil then
    begin
      Inc(Patches);
      Inc(Sounds, Length(Patch.Keygroups));
      Again := D.BuildPatch(D.Entries[E], Patch);
      ReleasePatch(Again);
    end;
    ReleasePatch(Patch);
    Inc(Ops, 2);

    for I := 1 to 3 do
    begin
      D.SetKeygroupParam(D.Entries[E], Rand(N + 3) - 1, TKeygroupParam(Rand(KeygroupParamCount)),
                         Rand(601) - 300);
      Inc(Ops);
    end;
  end;

  for I := -2 to 66 do
    D.EntryInSlot(I);

  // The writing half, on a copy, where it is cheap enough to finish.
  if Heavy then
  begin
    W := TS950Disk.Create;
    try
      W.Assign(D);
      W.RebuildPointers;
      S.Init;
      S.Name := 'fz' + IntToStr(Rand(1000));
      SetLength(S.Words12, Rand(5000));
      for I := 0 to High(S.Words12) do
        S.Words12[I] := Rand(8192) - 4096;
      case Rand(3) of
        0: S.LoopMode := 'O';
        1: S.LoopMode := 'A';
      end;
      S.LoopLength := Rand(6000) - 1;
      W.AddSample(S, Why);
      W.AddProgram('fz prog', 1 + Rand(4), Why);
      Pe := W.Find('FZ PROG', 'P');
      if Pe <> nil then
      begin
        W.SetZoneSample(Pe^, Rand(5) - 1, Rand(3) - 1, S.Name);
        W.SetKeygroupParam(Pe^, 0, kpVcfAttack, Rand(200) - 50);
      end;
      W.RebuildPointers;
      Inc(Writes);
    finally
      W.Free;
    end;
  end;
end;

var
  CaseDir, Why: string;
  Cases, Seed, I, J, Kind, SaveEvery: Integer;
  Images, Hfes, SampleBlocks: TBytesArray;
  Paths: TStringList;
  B: TBytes;
  D: TS950Disk;
  List: TStringList;
  Ok, Heavy: Boolean;
  Name: string;
  Started: TDateTime;
  Arg: string;
begin
  if ParamCount < 4 then
  begin
    WriteLn('usage: fuzz_pas <casedir> <cases> <seed> <image> [<image> ...]');
    ExitCode := 2;
    Exit;
  end;

  CaseDir := ParamStr(1);
  Cases := StrToInt(ParamStr(2));
  Seed := StrToInt(ParamStr(3));
  RngState := UInt64(Seed) * 2654435761 + 88172645463325252;
  Started := Now;

  // The real disks: each as the .hfe it came in and as the image decoded from it.
  Paths := TStringList.Create;
  try
    for I := 4 to ParamCount do
    begin
      Arg := ParamStr(I);
      if Copy(Arg, 1, 1) = '@' then
      begin
        List := TStringList.Create;
        try
          List.LoadFromFile(Copy(Arg, 2, MaxInt));
          for J := 0 to List.Count - 1 do
            if TrimRight(List[J]) <> '' then
              Paths.Add(TrimRight(List[J]));
        finally
          List.Free;
        end;
      end
      else
        Paths.Add(Arg);
    end;

    Images := nil;
    Hfes := nil;
    SampleBlocks := nil;
    for I := 0 to Paths.Count - 1 do
    begin
      B := ReadAll(Paths[I]);
      D := TS950Disk.Create;
      try
        if D.LoadBytes(Paths[I], B, Why) then
        begin
          SetLength(Images, Length(Images) + 1);
          Images[High(Images)] := Copy(D.Image);
          if D.WasHfe then
          begin
            SetLength(Hfes, Length(Hfes) + 1);
            Hfes[High(Hfes)] := B;
          end;
          for J := 0 to High(D.Entries) do
            if D.Entries[J].EntryType = 'S' then
            begin
              SetLength(SampleBlocks, Length(SampleBlocks) + 1);
              SampleBlocks[High(SampleBlocks)] := D.ReadFile(D.Entries[J]);
            end;
        end;
      finally
        D.Free;
      end;
    end;
  finally
    Paths.Free;
  end;

  if Length(Images) = 0 then
  begin
    WriteLn('fuzz_pas: no images to start from');
    ExitCode := 2;
    Exit;
  end;

  List := TStringList.Create;
  D := TS950Disk.Create;
  try
    SaveEvery := Cases div 300;
    if SaveEvery < 1 then
      SaveEvery := 1;

    for I := 0 to Cases - 1 do
    begin
      // What kind of trouble.
      Kind := Rand(12);
      if (Kind in [8, 9]) and (Length(Hfes) = 0) then
        Kind := 1;
      // An HFE decode is the slow case: keep them to about one in eight.
      if (Kind in [8, 9]) and Chance(50) then
        Kind := 1;
      if (I = Cases div 2) and (Length(Hfes) > 0) then
        Kind := 9;                                              // the 255 x 255 header, once
      Inc(KindCount[Kind]);

      case Kind of
        0: begin                                                // random bytes, any length
             case Rand(4) of
               0: SetLength(B, Rand(64));
               1: SetLength(B, Rand(5000));
               2: SetLength(B, 819200);
             else
               SetLength(B, 1638400);
             end;
             RandomBytes(B, 0, Length(B));
             if Chance(30) and (Length(B) >= 12) then
               Move(Sig[1], B[0], 8);
           end;
        1: begin                                                // a real image, bits flipped
             B := Copy(Images[Rand(Length(Images))]);
             FlipBits(B, 1 + Rand(2000), 0, Length(B));
           end;
        2: begin                                                // the header blocks, flipped
             B := Copy(Images[Rand(Length(Images))]);
             FlipBits(B, 1 + Rand(300), 0, 4096);
           end;
        3: begin                                                // a real image, a wrong size
             B := Copy(Images[Rand(Length(Images))]);
             SetLength(B, Rand(Length(B) + 2048));
           end;
        4: B := RandomDirectory(SampleBlocks);                  // a directory made of trouble
        5: begin
             B := RandomDirectory(SampleBlocks);
             FlipBits(B, Rand(100), 0, 4096);
           end;
        6: begin                                                // sample headers, any values
             B := Copy(Images[Rand(Length(Images))]);
             DamageSampleHeaders(B);
           end;
        7: begin                                                // the directory and the FAT
             B := Copy(Images[Rand(Length(Images))]);
             DamageDirectory(B);
             if Chance(50) then
               DamageSampleHeaders(B);
           end;
        8: begin                                                // an .hfe, flux flipped
             B := Copy(Hfes[Rand(Length(Hfes))]);
             case Rand(3) of
               0: FlipBits(B, 1 + Rand(50), 1024, Length(B) - 1024);
               1: FlipBits(B, 1 + Rand(3000), 1024, Length(B) - 1024);
             else
               SetLength(B, Rand(Length(B)));                   // truncated
             end;
           end;
        9: begin                                                // an .hfe header of garbage
             B := Copy(Hfes[Rand(Length(Hfes))]);
             DamageHfeHeader(B, I = Cases div 2);               // once: 255 tracks x 255 sides
           end;
        10: begin                                               // tiny and empty
              case Rand(5) of
                0: B := nil;
                1: begin SetLength(B, 8); Move(Sig[1], B[0], 8); end;
                2: begin SetLength(B, 9 + Rand(4)); RandomBytes(B, 0, Length(B)); Move(Sig[1], B[0], 8); end;
                3: begin SetLength(B, 12 + Rand(600)); FillChar(B[0], Length(B), 0); Move(Sig[1], B[0], 8); B[9] := Rand(4); B[10] := Rand(3); end;
              else
                begin SetLength(B, 819200); FillChar(B[0], Length(B), 0); end;
              end;
            end;
      else
        begin                                                   // an image of one byte value
          if Chance(50) then
            SetLength(B, 819200)
          else
            SetLength(B, 1638400);
          FillChar(B[0], Length(B), Rand(256));
        end;
      end;

      CaseStart := Now;
      Ok := False;
      Heavy := False;
      try
        Ok := D.LoadBytes('case', B, Why);
        if Ok then
        begin
          Inc(Loaded);
          // The writing half's arena vote is entries x keygroups x entries name
          // comparisons; past a few thousand keygroups it is slow (in the C++ too), so the
          // fuzz writes only where it is quick.
          Heavy := TotalKeygroups(D) <= 3000;
          Exercise(D, Heavy);
        end
        else
          Inc(Refused);
      except
        on X: Exception do
        begin
          Inc(Raised);
          WriteLn(Format('  case %d (kind %d) raised %s: %s', [I, Kind, X.ClassName, X.Message]));
          Name := CaseDir + '\raised_' + IntToStr(I) + '.bin';
          WriteAll(Name, B);
        end;
      end;

      KindTime[Kind] := KindTime[Kind] + (Now - CaseStart) * 86400;

      // A sample of the cases for the C++ to read too - those it can dump quickly.
      if ((I mod SaveEvery = 0) or (I = Cases div 2)) and ((not Ok) or Heavy) and (Length(B) <= 4000000) then
      begin
        Name := Format('%s\case_%.5d.bin', [CaseDir, I]);
        WriteAll(Name, B);
        List.Add(Name);
        Inc(Saved);
      end;
    end;

    List.SaveToFile(CaseDir + '\list.txt');
  finally
    D.Free;
    List.Free;
  end;

  Write('  kinds:');
  for I := 0 to High(KindCount) do
    Write(' ', KindCount[I], '/', Round(KindTime[I]), 's');
  WriteLn;
  WriteLn(Format('fuzz_pas: %d cases (%d loaded, %d refused), %d patches, %d patch entries, %d writes, %d operations, %d saved for the C++, %d raised, %.1f s',
                 [Cases, Loaded, Refused, Patches, Sounds, Writes, Ops, Saved, Raised, (Now - Started) * 86400]));
  if Raised <> 0 then
    ExitCode := 1;
end.
