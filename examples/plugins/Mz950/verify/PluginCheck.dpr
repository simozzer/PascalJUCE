// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Checks of the plug-in layer (Mz950Plugin), through the library's real entry point with a
// fake host: the parameter declarations and their text, MIDI through Process against the
// engine driven directly as the C++ processBlock drives it (bit for bit), the CC table and
// MIDI learn, the host's programs (and their snapshot read from other threads), the patch
// reaching the engine with no editor open, keygroup edits, the synth render thread and its
// drop rule, saving a disk, the saved state (a real disk, round trip, then 20000 hostile
// states), and every panel call hammered from one thread while another runs Process and a
// third reads the program list.
//
// Build with run-time checks: fpc -Mdelphi -Cr -Co -Ct -CR -gl -gh (see build_verify.cmd).
// The disks are read from %VS950_SRC%\disks (default %USERPROFILE%\src\VirtualS950\disks).
program PluginCheck;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$MINFPCONSTPREC 64}
{$ENDIF}
{$APPTYPE CONSOLE}

uses
  {$IFDEF UNIX} cthreads, {$ENDIF}
  Classes, SysUtils, Math, JuceTypes, JucePlugin,
  S950Math, S950Cal, S950Patch, S950Voice, S950Engine, S950Disk, S950SynthPatch,
  Mz950Params, Mz950Gzip, Mz950Plugin;

const
  Rate = 48000.0;
  BlockSize = 256;
  MaxEvents = 64;

type
  TFakeHost = record
    Params: array[0..NumParams - 1] of Single;     // what the host delivers to Process
    Requested: array[0..NumParams - 1] of Single;  // the latest SetParameter, not delivered yet
    Dirty: array[0..NumParams - 1] of Boolean;
    SetCalls: Integer;
    GestureDepth: Integer;
    ProgramsChangedCalls: Integer;
  end;
  PFakeHost = ^TFakeHost;

  TMidi = record
    Pos: Integer;
    Bytes: array[0..2] of Byte;
    Size: Integer;
  end;

  TInstance = record
    Host: TFakeHost;
    Api: TJcpHostApi;
    VT: TJcpPluginVTable;
    Inst: Pointer;
    P: TMz950;
    L, R: array[0..BlockSize - 1] of Single;
    Transport: TJuceTransport;
  end;
  PInstance = ^TInstance;

  // The engine driven directly, as VirtualS950Processor::processBlock drives it.
  TRef = record
    Engine: TS950Engine;
    P: array[0..NumParams - 1] of Single;        // the APVTS raw values
    GlidePosted, VoicesPosted, WidePosted: Integer;
    L, R: array[0..BlockSize - 1] of Single;
  end;

var
  Failures: Integer = 0;
  Factory: TJcpPluginFactory;
  Events: array[0..MaxEvents - 1] of TMidi;
  NumEvents: Integer;
  DisksDir, OutDir: string;
  BassImage, DrumsImage, PianoImage: TBytes;
  Seed: UInt32 = 2463534242;
  Diag: string;

procedure Check(Ok: Boolean; const What, Detail: string);
const
  Verdict: array[Boolean] of string = ('FAIL', 'ok  ');
begin
  Writeln(Format('  %s  %-62s %s', [Verdict[Ok], What, Detail]));
  if not Ok then
    Inc(Failures);
end;

function NextRandom: UInt32;
begin
  Seed := Seed xor (Seed shl 13);
  Seed := Seed xor (Seed shr 17);
  Seed := Seed xor (Seed shl 5);
  Result := Seed;
end;

function RandomInt(N: Integer): Integer;
begin
  if N <= 0 then Result := 0 else Result := Integer(NextRandom mod UInt32(N));
end;

{ ---- the fake host ---- }

procedure HSetParam(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
  InterlockedIncrement(PFakeHost(H)^.SetCalls);
  if (Index >= 0) and (Index < NumParams) then
  begin
    PFakeHost(H)^.Requested[Index] := Value;
    PFakeHost(H)^.Dirty[Index] := True;
  end;
end;

function HGetParam(H: PJcpHost; Index: Int32): Single; cdecl;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := PFakeHost(H)^.Params[Index]
  else
    Result := 0;
end;

procedure HBegin(H: PJcpHost; Index: Int32); cdecl;
begin
  InterlockedIncrement(PFakeHost(H)^.GestureDepth);
end;

procedure HEnd(H: PJcpHost; Index: Int32); cdecl;
begin
  InterlockedDecrement(PFakeHost(H)^.GestureDepth);
end;

function HGetSampleRate(H: PJcpHost): Double; cdecl;
begin
  Result := Rate;
end;

procedure HLog(H: PJcpHost; Msg: PAnsiChar); cdecl;
begin
end;

procedure HSetMeter(H: PJcpHost; Index: Int32; Value: Single); cdecl;
begin
end;

procedure HProgramsChanged(H: PJcpHost); cdecl;
begin
  InterlockedIncrement(PFakeHost(H)^.ProgramsChangedCalls);
end;

// What the wrapper does on its message thread: the latest value of each parameter set.
procedure Deliver(I: PInstance);
var
  K: Integer;
begin
  for K := 0 to NumParams - 1 do
    if I^.Host.Dirty[K] then
    begin
      I^.Host.Params[K] := I^.Host.Requested[K];
      I^.Host.Dirty[K] := False;
    end;
end;

function NewInstance: PInstance;
var
  K: Integer;
begin
  New(Result);
  FillChar(Result^, SizeOf(TInstance), 0);
  for K := 0 to NumParams - 1 do
    Result^.Host.Params[K] := DefaultValue(K);
  with Result^.Api do
  begin
    StructSize := SizeOf(TJcpHostApi);
    AbiVersion := JCP_ABI_VERSION;
    SetParameter := HSetParam;
    GetParameter := HGetParam;
    Log := HLog;
    GetSampleRate := HGetSampleRate;
    BeginParameterGesture := HBegin;
    EndParameterGesture := HEnd;
    SetMeter := HSetMeter;
    ProgramsChanged := HProgramsChanged;
  end;
  Result^.VT.StructSize := SizeOf(TJcpPluginVTable);
  Result^.Transport.StructSize := SizeOf(TJuceTransport);
  Result^.Transport.Bpm := 120;
  Result^.Transport.TimeSigNumerator := 4;
  Result^.Transport.TimeSigDenominator := 4;
  Result^.Inst := Factory.Create(@Result^.Api, @Result^.Host, @Result^.VT);
  Result^.P := TMz950(Result^.Inst);
  Result^.VT.Prepare(Result^.Inst, Rate, BlockSize);
end;

procedure FreeInstance(var I: PInstance);
begin
  if I = nil then Exit;
  I^.VT.Destroy(I^.Inst);
  Dispose(I);
  I := nil;
end;

procedure Midi(Pos: Integer; B0, B1, B2: Byte);
begin
  if NumEvents >= MaxEvents then Exit;
  Events[NumEvents].Pos := Pos;
  Events[NumEvents].Bytes[0] := B0;
  Events[NumEvents].Bytes[1] := B1;
  Events[NumEvents].Bytes[2] := B2;
  Events[NumEvents].Size := 3;
  Inc(NumEvents);
end;

procedure Midi2(Pos: Integer; B0, B1: Byte);
begin
  Midi(Pos, B0, B1, 0);
  Events[NumEvents - 1].Size := 2;
end;

procedure ProcessInst(I: PInstance; N: Integer);
var
  Ctx: TJuceProcessContext;
  Channels: array[0..1] of PJuceSampleArray;
  Ev: array[0..MaxEvents - 1] of TJuceMidiEvent;
  K: Integer;
begin
  for K := 0 to NumEvents - 1 do
  begin
    Ev[K].Data := @Events[K].Bytes[0];
    Ev[K].Size := Events[K].Size;
    Ev[K].SamplePosition := Events[K].Pos;
  end;
  Channels[0] := @I^.L;
  Channels[1] := @I^.R;
  FillChar(Ctx, SizeOf(Ctx), 0);
  Ctx.StructSize := SizeOf(Ctx);
  Ctx.NumSamples := N;
  Ctx.Channels := @Channels;
  Ctx.MidiEvents := @Ev;
  Ctx.Parameters := @I^.Host.Params;
  Ctx.Transport := @I^.Transport;
  Ctx.NumChannels := 2;
  Ctx.NumOutputChannels := 2;
  Ctx.NumMidiEvents := NumEvents;
  Ctx.NumParameters := NumParams;
  Ctx.MidiEventSize := SizeOf(TJuceMidiEvent);
  I^.VT.Process(I^.Inst, @Ctx);
end;

// One block of silence through an instance, its MIDI cleared.
procedure Idle(I: PInstance; Blocks: Integer = 1);
var
  K: Integer;
begin
  NumEvents := 0;
  for K := 1 to Blocks do
    ProcessInst(I, BlockSize);
end;

// The host keeps processing while the housekeeping thread pays the patch owed (the engine
// takes a patch only in a block, and the plug-in hands one over only two blocks after the
// last). No PanelTick: the housekeeping thread alone.
function WaitUntilPaid(I: PInstance; TimeoutMs: Integer): Boolean;
var
  T: QWord;
begin
  T := GetTickCount64;
  repeat
    Result := not I^.P.PatchOwed;
    if Result then Exit;
    Idle(I);
    Sleep(1);
  until GetTickCount64 - T > QWord(TimeoutMs);
end;

// Process blocks and tick until the patch the panel holds is the engine's: until nothing is
// owed, then the block that takes what was handed over and one more.
procedure Settle(I: PInstance);
var
  K: Integer;
begin
  K := 0;
  repeat
    Idle(I);
    I^.P.PanelTick;
    Inc(K);
  until not I^.P.PatchOwed or (K > 1000);
  if K > 1000 then
    Check(False, 'Settle: the patch was never paid', '');
  Idle(I, 2);
end;

function ReadFileBytes(const Path: string): TBytes;
var
  F: TFileStream;
begin
  Result := nil;
  F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, F.Size);
    if F.Size > 0 then
      F.ReadBuffer(Result[0], F.Size);
  finally
    F.Free;
  end;
end;

function SameBytes(const A, B: TBytes): Boolean;
begin
  Result := (Length(A) = Length(B)) and ((Length(A) = 0) or CompareMem(@A[0], @B[0], Length(A)));
end;

function ImageOf(const HfeName: string): TBytes;
var
  D: TS950Disk;
  E: string;
begin
  Result := nil;
  D := TS950Disk.Create;
  try
    if D.LoadFile(DisksDir + HfeName, E) then
      Result := Copy(D.Image)
    else
      Writeln('  cannot read ', DisksDir + HfeName, ': ', E);
  finally
    D.Free;
  end;
end;

function DiskFrom(const Image: TBytes): TS950Disk;
var
  E: string;
begin
  Result := TS950Disk.Create;
  if not Result.LoadBytes('ref', Image, E) then
    FreeAndNil(Result);
end;

function NthProgram(D: TS950Disk; Index: Integer; out E: TDiskEntry): Boolean;
var
  K, Seen: Integer;
begin
  Result := False;
  Seen := 0;
  for K := 0 to High(D.Entries) do
    if D.Entries[K].EntryType = 'P' then
    begin
      if Seen = Index then
      begin
        E := D.Entries[K];
        Result := True;
        Exit;
      end;
      Inc(Seen);
    end;
end;

function NamesOf(D: TS950Disk): TArray<string>;
var
  K, N: Integer;
begin
  N := 0;
  SetLength(Result, Length(D.Entries));
  for K := 0 to High(D.Entries) do
    if D.Entries[K].EntryType = 'P' then
    begin
      Result[N] := D.Entries[K].Name;
      Inc(N);
    end;
  SetLength(Result, N);
end;

{ ---- the reference: the C++ processBlock ---- }

function P_(const Id: string): Integer;
begin
  Result := IndexOfId(Id);
  if Result < 0 then
  begin
    Writeln('no parameter ', Id);
    Halt(2);
  end;
end;

// applyController: jlimit (0, 1, value / 127) through the parameter's NormalisableRange.
function RefController(Index, V: Integer): Single;
var
  N, P, Span, X: Single;
begin
  N := V;
  N := N / 127;
  if N < 0 then N := 0;
  if N > 1 then N := 1;
  with Specs[Index] do
  begin
    P := N;
    if (Skew <> 1) and (P > 0) then
      P := ExpD(LogD(P) / Skew);
    Span := Hi - Lo;
    X := Lo + Span * P;
    if Kind <> mkFloat then
      X := Lo + FloorD(X - Lo + 0.5);
    if X < Lo then X := Lo;
    if X > Hi then X := Hi;
  end;
  Result := X;
end;

const
  // trimControls, as the C++ constructor fills it
  RefTrimCc: array[0..19] of Integer = (74, 70, 73, 75, 79, 72, 102, 103, 104, 105, 76, 77, 78, 109, 112, 71, 113, 114, 115, 116);
  RefTrimId: array[0..19] of string = ('vcfCutoff', 'vcfAmount', 'vcaAttack', 'vcaDecay', 'vcaSustain', 'vcaRelease',
    'vcfAttack', 'vcfDecay', 'vcfSustain', 'vcfRelease', 'lfoRate', 'lfoDepth', 'lfoDelay',
    'velToFilter', 'velToLoudness', 'resonance', 'lfoShape', 'lfoToFilter', 'lfoSync', 'lfoSyncDiv');

procedure RefInit(var R: TRef);
var
  K: Integer;
begin
  R.Engine := TS950Engine.Create(Rate);
  for K := 0 to NumParams - 1 do
    R.P[K] := Specs[K].Def;
  R.GlidePosted := -1;
  R.VoicesPosted := -1;
  R.WidePosted := -1;
end;

procedure RefStoreTrim(E: TS950Engine; const Id: string; V: Single);
begin
  with E.Trims do
    if Id = 'vcfCutoff' then Cutoff.Store(V)
    else if Id = 'vcfAmount' then Amount.Store(V)
    else if Id = 'vcaAttack' then VcaAttack.Store(V)
    else if Id = 'vcaDecay' then VcaDecay.Store(V)
    else if Id = 'vcaSustain' then VcaSustain.Store(V)
    else if Id = 'vcaRelease' then VcaRelease.Store(V)
    else if Id = 'vcfAttack' then VcfAttack.Store(V)
    else if Id = 'vcfDecay' then VcfDecay.Store(V)
    else if Id = 'vcfSustain' then VcfSustain.Store(V)
    else if Id = 'vcfRelease' then VcfRelease.Store(V)
    else if Id = 'lfoRate' then LfoRate.Store(V)
    else if Id = 'lfoDepth' then LfoDepth.Store(V)
    else if Id = 'lfoDelay' then LfoDelay.Store(V)
    else if Id = 'velToFilter' then VelToFilter.Store(V)
    else if Id = 'velToLoudness' then VelToLoudness.Store(V)
    else if Id = 'resonance' then Resonance.Store(V)
    else if Id = 'lfoShape' then LfoShape.Store(V)
    else if Id = 'lfoToFilter' then LfoToFilter.Store(V)
    else if Id = 'lfoSync' then LfoSync.Store(V)
    else if Id = 'lfoSyncDiv' then LfoSyncDiv.Store(V);
end;

procedure RefProcess(var R: TRef; N: Integer; const T: TJuceTransport);
var
  K, J, St, D1, D2, At, Wanted, Notes: Integer;
  E: TS950Engine;
  On_: Boolean;
begin
  E := R.Engine;
  E.Gain.Store(R.P[P_('gain')]);
  E.BendRange.Store(R.P[P_('bendRange')]);
  if R.P[P_('glide')] >= 0.5 then Wanted := 1 else Wanted := 0;
  if Wanted <> R.GlidePosted then begin E.Glide(Wanted <> 0, 0); R.GlidePosted := Wanted; end;
  Wanted := Round(R.P[P_('voices')]);
  if Wanted <> R.VoicesPosted then begin E.SetVoiceLimit(Wanted, 0); R.VoicesPosted := Wanted; end;
  if R.P[P_('wide')] >= 0.5 then Wanted := 1 else Wanted := 0;
  if Wanted <> R.WidePosted then begin E.Wide(Wanted <> 0, 0); R.WidePosted := Wanted; end;

  for K := 0 to NumEvents - 1 do
  begin
    St := Events[K].Bytes[0] and $F0;
    D1 := Events[K].Bytes[1];
    D2 := Events[K].Bytes[2];
    At := Events[K].Pos;
    if (St = $90) and (D2 > 0) then E.NoteOn(D1, D2, At)
    else if (St = $80) or (St = $90) then E.NoteOff(D1, At)
    else if (St = $B0) and (D1 = 1) then E.Modwheel(D2, At)
    else if St = $E0 then E.PitchBend(D1 or (D2 shl 7), At)
    else if St = $D0 then E.Aftertouch(D1, At)
    else if (St = $B0) and ((D1 = 123) or (D1 = 120)) then E.AllNotesOff(At)
    else if (St = $B0) and (D1 = 65) then
    begin
      On_ := D2 >= 64;
      E.Glide(On_, At);
      R.GlidePosted := Ord(On_);
      R.P[P_('glide')] := Ord(On_);
    end
    else if (St = $B0) and (D1 = 5) then R.P[P_('glideTime')] := RefController(P_('glideTime'), D2)
    else if (St = $B0) and (D1 = 106) then
    begin
      Notes := 1 + D2 * EnginePolyphony div 128;
      E.SetVoiceLimit(Notes, At);
      R.VoicesPosted := Notes;
      R.P[P_('voices')] := Notes;
    end
    else if (St = $B0) and (D1 = 107) then
    begin
      On_ := D2 >= 64;
      E.Wide(On_, At);
      R.WidePosted := Ord(On_);
      R.P[P_('wide')] := Ord(On_);
    end
    else if (St = $B0) and (D1 = 108) then R.P[P_('wideDetune')] := RefController(P_('wideDetune'), D2)
    else if (St = $B0) and (D1 = 110) then R.P[P_('wideSpread')] := RefController(P_('wideSpread'), D2)
    else if (St = $B0) and (D1 = 111) then R.P[P_('wideOffset')] := Ord(D2 >= 64)
    else if St = $B0 then
      for J := 0 to 19 do
        if RefTrimCc[J] = D1 then
        begin
          R.P[P_(RefTrimId[J])] := RefController(P_(RefTrimId[J]), D2);
          Break;
        end;
  end;

  for J := 0 to 19 do
    RefStoreTrim(E, RefTrimId[J], R.P[P_(RefTrimId[J])]);
  E.GlideSeconds.Store(R.P[P_('glideTime')] / 1000.0);
  E.WideCents.Store(R.P[P_('wideDetune')]);
  E.WideSpread.Store(R.P[P_('wideSpread')] / 100.0);
  E.WideOffset.Store(R.P[P_('wideOffset')] >= 0.5);
  if T.HasInfo <> 0 then
    E.SetTransport(T.Bpm, T.PpqPosition, T.IsPlaying <> 0, T.TimeSigNumerator * 4.0 / T.TimeSigDenominator);
  E.Render(@R.L[0], @R.R[0], N);
end;

{ ---- parameters ---- }

type
  TExpected = record
    Id, Name: string;
    Kind: TJuceParameterKind;
    Lo, Hi, Def: Single;
  end;

const
  // describeParameters, read off the C++ source
  Expected: array[0..28] of TExpected = (
    (Id: 'gain'; Name: 'Gain'; Kind: jpkFloat; Lo: 0; Hi: 2; Def: 0.7),
    (Id: 'bendRange'; Name: 'Bend Range'; Kind: jpkInt; Lo: 1; Hi: 12; Def: 2),
    (Id: 'vcfCutoff'; Name: 'VCF Filter'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcfAmount'; Name: 'VCF Amnt'; Kind: jpkFloat; Lo: -50; Hi: 50; Def: 0),
    (Id: 'vcaAttack'; Name: 'VCA Attack'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcaDecay'; Name: 'VCA Decay'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcaSustain'; Name: 'VCA Sustain'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcaRelease'; Name: 'VCA Release'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcfAttack'; Name: 'VCF Attack'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcfDecay'; Name: 'VCF Decay'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcfSustain'; Name: 'VCF Sustain'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'vcfRelease'; Name: 'VCF Release'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'lfoRate'; Name: 'LFO Rate'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'lfoDepth'; Name: 'LFO Pitch Depth'; Kind: jpkFloat; Lo: 0; Hi: 99; Def: 0),
    (Id: 'lfoDelay'; Name: 'LFO Delay'; Kind: jpkFloat; Lo: -99; Hi: 99; Def: 0),
    (Id: 'lfoToFilter'; Name: 'LFO Filter Depth'; Kind: jpkFloat; Lo: 0; Hi: 99; Def: 0),
    (Id: 'lfoSync'; Name: 'LFO Sync'; Kind: jpkBool; Lo: 0; Hi: 1; Def: 0),
    (Id: 'lfoSyncDiv'; Name: 'LFO Sync Division'; Kind: jpkChoice; Lo: 0; Hi: 14; Def: 8),
    (Id: 'lfoShape'; Name: 'LFO Shape'; Kind: jpkChoice; Lo: 0; Hi: 3; Def: 0),
    (Id: 'velToFilter'; Name: 'Vel Freq'; Kind: jpkFloat; Lo: 0; Hi: 99; Def: 0),
    (Id: 'velToLoudness'; Name: 'Vel Loudness'; Kind: jpkFloat; Lo: 0; Hi: 99; Def: 0),
    (Id: 'resonance'; Name: 'VCF Resonance'; Kind: jpkFloat; Lo: 0; Hi: 100; Def: 0),
    (Id: 'glide'; Name: 'Glide'; Kind: jpkBool; Lo: 0; Hi: 1; Def: 0),
    (Id: 'glideTime'; Name: 'Glide Time'; Kind: jpkFloat; Lo: 0; Hi: 3000; Def: 120),
    (Id: 'voices'; Name: 'Polyphony'; Kind: jpkInt; Lo: 1; Hi: 8; Def: 8),
    (Id: 'wide'; Name: 'Wide'; Kind: jpkBool; Lo: 0; Hi: 1; Def: 0),
    (Id: 'wideDetune'; Name: 'Wide Detune'; Kind: jpkFloat; Lo: 0; Hi: 50; Def: 10),
    (Id: 'wideSpread'; Name: 'Wide Spread'; Kind: jpkFloat; Lo: 0; Hi: 100; Def: 70),
    (Id: 'wideOffset'; Name: 'Wide Offset'; Kind: jpkBool; Lo: 0; Hi: 1; Def: 1)
  );

function TextOf(I: PInstance; Index: Integer; V: Single; out Text: string): Boolean;
var
  Buf: array[0..127] of AnsiChar;
begin
  Result := I^.VT.GetParameterText(I^.Inst, Index, V, @Buf[0], Length(Buf)) = 1;
  if Result then Text := string(UTF8String(PAnsiChar(@Buf[0]))) else Text := '';
end;

procedure DeclarationChecks;
var
  Info: TJcpParameterInfo;
  K, Bad: Integer;
  I: PInstance;
  T, All: string;
  Ok: Boolean;

  procedure Expect(Index: Integer; V: Single; const Want: string);
  begin
    if not TextOf(I, Index, V, T) or (T <> Want) then
    begin
      Ok := False;
      All := All + Format(' [%s %g: "%s" want "%s"]', [Specs[Index].Id, V, T, Want]);
    end;
  end;

begin
  Writeln;
  Writeln('parameters');
  Check(JuceDeclarationError = '', 'declarations are valid', JuceDeclarationError);
  Check(Factory.GetParameterCount = 29, 'parameter count: 29, as describeParameters', IntToStr(Factory.GetParameterCount));
  Bad := 0;
  for K := 0 to 28 do
  begin
    FillChar(Info, SizeOf(Info), 0);
    Info.StructSize := SizeOf(Info);
    Factory.GetParameterInfo(K, @Info);
    if (string(Info.Id) <> Expected[K].Id) or (string(Info.Name) <> Expected[K].Name)
      or (Info.Kind <> Ord(Expected[K].Kind)) or (Info.MinValue <> Expected[K].Lo)
      or (Info.MaxValue <> Expected[K].Hi) or (Abs(Info.DefaultValue - Expected[K].Def) > 1e-6) then
    begin
      Writeln('    mismatch at ', K, ': ', Info.Id);
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, 'ids, names, kinds, ranges, defaults, in the C++ order', Format('%d mismatches', [Bad]));
  Check((JuceParameterChoices(PLfoShape) = 'Sine|Saw|Square|S&H')
    and (Pos('4 bars|2 bars|1 bar|1/2|1/4.|1/4|1/4T|1/8.|1/8|1/8T|1/16.|1/16|1/16T|1/32|1/64', JuceParameterChoices(PLfoSyncDiv)) = 1),
    'choices: the four shapes, the fifteen divisions', JuceParameterChoices(PLfoShape));

  I := NewInstance;
  Ok := True;
  All := '';
  Expect(PGain, 0.7, '0.70');
  Expect(PBendRange, 1, '1 semitone');
  Expect(PBendRange, 7, '7 semitones');
  Expect(PVcfCutoff, 12.4, '+12');
  Expect(PVcfCutoff, -40, '-40');
  Expect(PVcfCutoff, 0, '+0');
  Expect(PLfoDepth, 40, '+40');
  Expect(PLfoRate, 0, #$C3#$97'1.00');
  Expect(PLfoRate, 99, #$C3#$97'256');
  Expect(PLfoRate, -99, #$C3#$97'0.02');
  Expect(PLfoRate, 49.5, #$C3#$97'16');
  Expect(PResonance, 50, '50%');
  Expect(PGlideTime, 0, 'no glide');
  Expect(PGlideTime, 120, '120 ms');
  Expect(PGlideTime, 1500, '1.50 s');
  Expect(PVoices, 1, 'mono');
  Expect(PVoices, 8, '8');
  Expect(PWideDetune, 10, #$C2#$B1'10.0 ct');
  Expect(PWideSpread, 70, '70%');
  Check(Ok, 'value text as the C++ lambdas', All);
  Check(not TextOf(I, PGlide, 1, T) and not TextOf(I, PLfoShape, 2, T), 'switches and choices read as the host shows them', '');
  Check(Abs(I^.VT.GetTailSeconds(I^.Inst) - EnvSeconds(99)) < 1e-12, 'tail: the longest release', FloatToStr(I^.VT.GetTailSeconds(I^.Inst)));
  FreeInstance(I);
end;

{ ---- MIDI: the plug-in against the engine driven directly ---- }

procedure AudioChecks;
var
  I: PInstance;
  R: TRef;
  Block, K, J, N, Count, Note: Integer;
  Pos: array[0..7] of Integer;
  Diff, Peak: Double;
  Ccs: array[0..27] of Integer;
  Patch: TS950Patch;
  Disk: TS950Disk;
  E: TDiskEntry;
  Pass: Integer;

  procedure Sort(var A: array of Integer; Count: Integer);
  var X, Y, T: Integer;
  begin
    for X := 1 to Count - 1 do
      for Y := X downto 1 do
        if A[Y] < A[Y - 1] then begin T := A[Y]; A[Y] := A[Y - 1]; A[Y - 1] := T; end;
  end;

begin
  Writeln;
  Writeln('MIDI through Process against the engine driven as processBlock drives it');
  for J := 0 to 19 do Ccs[J] := RefTrimCc[J];
  Ccs[20] := 65; Ccs[21] := 5; Ccs[22] := 106; Ccs[23] := 107; Ccs[24] := 108; Ccs[25] := 110; Ccs[26] := 111; Ccs[27] := 1;

  for Pass := 0 to 1 do
  begin
    I := NewInstance;
    RefInit(R);
    if Pass = 0 then
    begin
      Patch := MakePlaceholderPatch;
      R.Engine.SetPatch(Patch);
      ReleasePatch(Patch);
    end
    else
    begin
      // a real disk, programme 1 (the plug-in builds the same patch from the same bytes)
      I^.P.LoadDiskBytes('BASS', '', BassImage, Diag);
      I^.P.SelectProgramFromPanel(4);
      Deliver(I);
      Settle(I);
      I^.VT.Prepare(I^.Inst, Rate, BlockSize);   // a fresh engine with that patch, as the reference's
      Disk := DiskFrom(BassImage);
      NthProgram(Disk, 4, E);
      Patch := Disk.BuildPatch(E, nil);
      R.Engine.SetPatch(Patch);
      ReleasePatch(Patch);
      Disk.Free;
    end;

    Peak := 0;
    Diff := 0;
    Seed := 12345 + Pass;
    for Block := 0 to 799 do
    begin
      NumEvents := 0;
      Count := RandomInt(6);
      for K := 0 to Count - 1 do Pos[K] := RandomInt(BlockSize);
      Sort(Pos, Count);
      for K := 0 to Count - 1 do
      begin
        Note := 36 + RandomInt(48);
        case RandomInt(12) of
          0..3: Midi(Pos[K], $90 + RandomInt(16), Note, 1 + RandomInt(127));
          4, 5: Midi(Pos[K], $80, Note, 64);
          6: Midi(Pos[K], $90, Note, 0);
          7, 8: Midi(Pos[K], $B0, Ccs[RandomInt(28)], RandomInt(128));
          9: Midi(Pos[K], $E0, RandomInt(128), RandomInt(128));
          10: Midi2(Pos[K], $D0, RandomInt(128));
          11: if RandomInt(8) = 0 then Midi(Pos[K], $B0, 120 + 3 * RandomInt(2), 0) else Midi(Pos[K], $B0, 1, RandomInt(128));
        end;
      end;
      // the host's own moves (automation), on both
      if RandomInt(20) = 0 then
      begin
        J := RandomInt(NumParams);
        if Specs[J].Kind = mkFloat then
          R.P[J] := Specs[J].Lo + (Specs[J].Hi - Specs[J].Lo) * (RandomInt(1000) / 1000.0)
        else
          R.P[J] := Specs[J].Lo + RandomInt(Round(Specs[J].Hi - Specs[J].Lo) + 1);
        I^.Host.Params[J] := R.P[J];
        I^.Host.Dirty[J] := False;
      end;
      // the transport: playing in 3/4 from block 200
      if Block >= 200 then
      begin
        I^.Transport.HasInfo := 1;
        I^.Transport.IsPlaying := Ord(Block < 600);
        I^.Transport.Bpm := 128;
        I^.Transport.TimeSigNumerator := 3;
        I^.Transport.TimeSigDenominator := 4;
        I^.Transport.PpqPosition := (Block - 200) * BlockSize / Rate * 128 / 60;
      end;
      ProcessInst(I, BlockSize);
      RefProcess(R, BlockSize, I^.Transport);
      for N := 0 to BlockSize - 1 do
      begin
        Diff := Max(Diff, Abs(I^.L[N] - R.L[N]));
        Diff := Max(Diff, Abs(I^.R[N] - R.R[N]));
        Peak := Max(Peak, Abs(R.L[N]));
      end;
      // the host catches up with the plug-in's own SetParameter now and then
      if Block mod 3 = 2 then
        Deliver(I);
    end;
    if Pass = 0 then
      Check((Diff = 0) and (Peak > 0.01), '800 blocks of notes, CCs, bend, pressure, automation: placeholder', Format('max diff %g, peak %.3f', [Diff, Peak]))
    else
      Check((Diff = 0) and (Peak > 0.01), '... and a programme off BASS.hfe, transport playing in 3/4', Format('max diff %g, peak %.3f', [Diff, Peak]));
    Check(I^.P.ProcessErrors = 0, 'no exceptions in Process', '');
    R.Engine.Free;
    FreeInstance(I);
  end;

  // A block of no samples keeps its MIDI for the next one.
  I := NewInstance;
  NumEvents := 0;
  Midi(0, $90, 60, 100);
  ProcessInst(I, 0);
  Idle(I);
  Check(I^.P.GetActiveVoices = 1, 'a note in a block of no samples plays in the next', IntToStr(I^.P.GetActiveVoices));
  Check(I^.P.IsNoteHeld(60) and not I^.P.IsNoteHeld(61), 'the held-key bits', '');
  NumEvents := 0;
  Midi(10, $B0, 123, 0);
  ProcessInst(I, BlockSize);
  Check(not I^.P.IsNoteHeld(60), 'all notes off clears them', '');
  FreeInstance(I);
end;

{ ---- the CC table and MIDI learn ---- }

procedure CcChecks;
var
  I: PInstance;
  J, Bad, Idx: Integer;
  Got: Single;
  Detail: string;

  function Send(Cc, V: Integer; Index: Integer): Single;
  begin
    I^.Host.Dirty[Index] := False;
    NumEvents := 0;
    Midi(0, $B0, Cc, V);
    ProcessInst(I, BlockSize);
    NumEvents := 0;
    if I^.Host.Dirty[Index] then Result := I^.Host.Requested[Index] else Result := I^.Host.Params[Index];
    Deliver(I);
  end;

begin
  Writeln;
  Writeln('the CC table and MIDI learn');
  I := NewInstance;
  Bad := 0;
  Detail := '';
  for J := 0 to 19 do
  begin
    Idx := IndexOfId(RefTrimId[J]);
    if I^.P.CcFor(Idx) <> RefTrimCc[J] then begin Inc(Bad); Detail := Detail + ' ' + RefTrimId[J]; end;
  end;
  if (I^.P.CcFor(PGlide) <> 65) or (I^.P.CcFor(PGlideTime) <> 5) or (I^.P.CcFor(PVoices) <> 106)
    or (I^.P.CcFor(PWide) <> 107) or (I^.P.CcFor(PWideDetune) <> 108) or (I^.P.CcFor(PWideSpread) <> 110)
    or (I^.P.CcFor(PWideOffset) <> 111) or (I^.P.CcFor(PGain) <> -1) or (I^.P.CcFor(PBendRange) <> -1) then
    Inc(Bad);
  Check(Bad = 0, 'the default map is the C++''s trimControls and its special cases', Detail);

  Bad := 0;
  Detail := '';
  for J := 0 to 19 do
  begin
    Idx := IndexOfId(RefTrimId[J]);
    Got := Send(RefTrimCc[J], 127, Idx);
    if Got <> RefController(Idx, 127) then begin Inc(Bad); Detail := Detail + ' ' + RefTrimId[J]; end;
    Got := Send(RefTrimCc[J], 0, Idx);
    if Got <> RefController(Idx, 0) then Inc(Bad);
    Got := Send(RefTrimCc[J], 64, Idx);
    if Got <> RefController(Idx, 64) then Inc(Bad);
  end;
  Check(Bad = 0, 'each trim''s CC sets it as applyController does (0, 64, 127)', Detail);
  Check((Send(74, 127, PVcfCutoff) = 99) and (Send(74, 0, PVcfCutoff) = -99), 'CC 74: VCF Filter -99..+99', '');
  Check((Send(113, 0, PLfoShape) = 0) and (Send(113, 127, PLfoShape) = 3) and (Send(116, 127, PLfoSyncDiv) = 14),
    'CC 113 / 116: the shape and the division', '');
  Check((Send(115, 64, PLfoSync) = 1) and (Send(115, 63, PLfoSync) = 0), 'CC 115: sync on from 64', '');
  Check((Send(106, 0, PVoices) = 1) and (Send(106, 15, PVoices) = 1) and (Send(106, 16, PVoices) = 2)
    and (Send(106, 64, PVoices) = 5) and (Send(106, 127, PVoices) = 8), 'CC 106: eight bands of sixteen', '');
  Check((Send(65, 64, PGlide) = 1) and (Send(65, 63, PGlide) = 0), 'CC 65: glide on from 64', '');
  Got := Send(5, 64, PGlideTime);
  Check((Send(5, 127, PGlideTime) = 3000) and (Send(5, 0, PGlideTime) = 0) and (Abs(Got - 3000 * Power(64 / 127, 2.5)) < 0.5),
    'CC 5: glide time on the C++''s skewed range', Format('64 -> %.1f ms', [Got]));
  Check((Send(107, 127, PWide) = 1) and (Send(111, 0, PWideOffset) = 0) and (Send(108, 127, PWideDetune) = 50)
    and (Send(110, 127, PWideSpread) = 100), 'CC 107, 108, 110, 111: wide', '');
  I^.Host.SetCalls := 0;
  NumEvents := 0;
  Midi(0, $B0, 20, 100);
  Midi(1, $B0, 1, 100);
  Midi(2, $B0, 64, 127);
  ProcessInst(I, BlockSize);
  Check(I^.Host.SetCalls = 0, 'an unmapped CC, the mod wheel and the sustain pedal move no parameter', IntToStr(I^.Host.SetCalls));

  // learn
  I^.P.Learn(PGain);
  Check(I^.P.LearningIndex = PGain, 'learning waits for a CC', '');
  NumEvents := 0;
  Midi(0, $B0, 1, 100);          // the mod wheel is not learnable
  ProcessInst(I, BlockSize);
  Check(I^.P.LearningIndex = PGain, 'the mod wheel is not taken', '');
  I^.Host.SetCalls := 0;
  NumEvents := 0;
  Midi(0, $B0, 20, 100);
  ProcessInst(I, BlockSize);
  Check((I^.P.CcFor(PGain) = 20) and (I^.P.LearningIndex = -1) and (I^.Host.SetCalls = 0), 'CC 20 is taken by Gain, and does nothing else', '');
  Check(Send(20, 127, PGain) = 2, 'and then moves it (0..2)', '');
  I^.P.Learn(PVcfCutoff);
  NumEvents := 0;
  Midi(0, $B0, 73, 0);
  ProcessInst(I, BlockSize);
  Check((I^.P.CcFor(PVcfCutoff) = 73) and (I^.P.CcFor(PVcaAttack) = -1), 'a learned CC leaves its old owner', '');
  I^.P.RestoreDefaultCc(PVcaAttack);
  Check((I^.P.CcFor(PVcaAttack) = 73) and (I^.P.CcFor(PVcfCutoff) = -1), 'restoring a default takes it back', '');
  I^.P.ResetAllCcs;
  Check((I^.P.CcFor(PVcfCutoff) = 74) and (I^.P.CcFor(PGain) = -1), 'reset: the C++ table again', '');
  Check(I^.P.ProcessErrors = 0, 'no exceptions in Process', '');
  FreeInstance(I);
end;

{ ---- the host's programs ---- }

type
  TReader = class(TThread)
  protected
    procedure Execute; override;
  public
    P: TMz950;
    Valid: TStringList;
    Reads, Bad: Integer;
  end;

procedure TReader.Execute;
var
  S: string;
  K, C: Integer;
begin
  K := 0;
  while not Terminated do
  begin
    if P.ProgramCount <> 64 then Inc(Bad);
    S := P.ProgramName(K mod 64);
    if (Valid <> nil) and (Valid.IndexOf(S) < 0) then Inc(Bad);
    if (Valid = nil) and ((S = '') or (Length(S) > 300)) then Inc(Bad);
    C := P.CurrentProgram;
    if (C < 0) or (C >= 64) then Inc(Bad);
    Inc(K);
    Inc(Reads);
  end;
end;

procedure ProgramChecks;
var
  I: PInstance;
  Names, Bass, Drums, Piano: TArray<string>;
  K, Calls, Bad: Integer;
  Disk: TS950Disk;
  Readers: array[0..2] of TReader;
  Valid: TStringList;
  T: QWord;
  Ok: Boolean;
  Buf: array[0..300] of AnsiChar;
begin
  Writeln;
  Writeln('the host''s programs');
  I := NewInstance;
  Ok := (I^.P.ProgramCount = 64) and (I^.P.ProgramName(0) = 'Placeholder saw') and (I^.P.ProgramName(1) = '- no disk -')
    and (I^.P.ProgramName(63) = '- no disk -') and (I^.P.ProgramName(64) = '') and (I^.P.ProgramName(-1) = '')
    and (I^.P.CurrentProgram = 0);
  Check(Ok, 'no disk: 64 slots, the placeholder in the first', I^.P.ProgramName(0));

  Disk := DiskFrom(BassImage); Bass := NamesOf(Disk); Disk.Free;
  Disk := DiskFrom(DrumsImage); Drums := NamesOf(Disk); Disk.Free;
  Disk := DiskFrom(PianoImage); Piano := NamesOf(Disk); Disk.Free;

  Calls := I^.Host.ProgramsChangedCalls;
  Check(I^.P.LoadDiskBytes('BASS.hfe', 'C:\disks\BASS.hfe', BassImage, Diag), 'LoadDiskBytes: BASS', Diag);
  Check(I^.Host.ProgramsChangedCalls > Calls, 'the host is told the list changed', '');
  Names := I^.P.GetProgramNames;
  Bad := 0;
  for K := 0 to 63 do
    if (K < Length(Bass)) and (I^.P.ProgramName(K) <> Bass[K]) then Inc(Bad)
    else if (K >= Length(Bass)) and (I^.P.ProgramName(K) <> '-') then Inc(Bad);
  Check((Length(Names) = 24) and (Bad = 0), 'the 24 programmes on their slots, "-" past them', Format('%d bad', [Bad]));
  Check((I^.P.GetDiskName = 'BASS.hfe') and (I^.P.GetDiskPath = 'C:\disks\BASS.hfe') and (I^.P.GetSelectedProgram = 0),
    'its name, its path, programme 0', I^.P.GetDiskName);
  Check(I^.VT.GetProgramName(I^.Inst, 3, @Buf[0], Length(Buf)) = 1, 'through the ABI', string(PAnsiChar(@Buf[0])));
  Check(string(PAnsiChar(@Buf[0])) = Bass[3], '... the same name', '');

  Calls := I^.Host.ProgramsChangedCalls;
  I^.VT.SetCurrentProgram(I^.Inst, 7);
  Check((I^.P.CurrentProgram = 7) and (I^.P.GetSelectedProgram = 7) and (I^.P.GetPatchName = Bass[7]),
    'the host selects programme 7', I^.P.GetPatchName);
  Check(I^.Host.ProgramsChangedCalls = Calls, '... and is not told back what it chose', '');
  I^.VT.SetCurrentProgram(I^.Inst, 40);
  T := GetTickCount64;
  while (I^.Host.ProgramsChangedCalls = Calls) and (GetTickCount64 - T < 1000) do Sleep(2);
  Check((I^.P.GetSelectedProgram = 7) and (I^.Host.ProgramsChangedCalls = Calls + 1),
    'an empty slot: nothing changes, and the housekeeper puts the host back', '');
  Calls := I^.Host.ProgramsChangedCalls;
  I^.P.SelectProgramFromPanel(3);
  Check((I^.P.CurrentProgram = 3) and (I^.Host.ProgramsChangedCalls = Calls + 1), 'the panel selects 3: the host is told', '');
  I^.P.SelectProgramFromPanel(99);
  Check(I^.P.GetSelectedProgram = 3, 'out of range does nothing', '');

  // the snapshot, read from three threads while the list changes under them
  Valid := TStringList.Create;
  Valid.Sorted := True;
  Valid.Duplicates := dupIgnore;
  Valid.CaseSensitive := True;
  for K := 0 to High(Drums) do Valid.Add(Drums[K]);
  for K := 0 to High(Piano) do Valid.Add(Piano[K]);
  for K := 0 to High(Bass) do Valid.Add(Bass[K]);
  Valid.Add('-');
  Valid.Add('- no disk -');
  Valid.Add('Placeholder saw');
  for K := 0 to 2 do
  begin
    Readers[K] := TReader.Create(True);
    Readers[K].P := I^.P;
    Readers[K].Valid := Valid;
    Readers[K].Start;
  end;
  T := GetTickCount64;
  K := 0;
  while GetTickCount64 - T < 1500 do
  begin
    case K mod 4 of
      0: I^.P.LoadDiskBytes('DRUMS', '', DrumsImage, Diag);
      1: I^.P.SelectProgram(RandomInt(3));               // the host's (no Process runs here)
      2: I^.P.LoadDiskBytes('PIANO', '', PianoImage, Diag);
      3: I^.P.SelectProgramFromPanel(RandomInt(4));
    end;
    I^.P.PanelTick;
    Inc(K);
  end;
  Bad := 0;
  Calls := 0;
  for K := 0 to 2 do
  begin
    Readers[K].Terminate;
    Readers[K].WaitFor;
    Inc(Bad, Readers[K].Bad);
    Inc(Calls, Readers[K].Reads);
    Readers[K].Free;
  end;
  Valid.Free;
  Check(Bad = 0, 'three threads reading the list while disks change: every name valid', Format('%d reads, %d bad', [Calls, Bad]));
  FreeInstance(I);
end;

{ ---- the patch reaches the engine with no editor ---- }

function SoundingName(I: PInstance): string;
var
  K: Integer;
  V: PS950Voice;
begin
  Result := '';
  for K := 0 to EnginePolyphony - 1 do
  begin
    V := I^.P.Engine.GetVoice(K);
    if V^.IsActive and (V^.GetSound <> nil) then
    begin
      Result := V^.GetSound.Name;
      Exit;
    end;
  end;
end;

function FirstSampleFor(D: TS950Disk; Prog, Note: Integer): string;
var
  E: TDiskEntry;
  P: TS950Patch;
  M: TKeygroupMatches;
begin
  Result := '';
  if not NthProgram(D, Prog, E) then Exit;
  P := D.BuildPatch(E, nil);
  if P = nil then Exit;
  P.Matching(Note, 100, M);
  if (M.Count > 0) and (M.Items[0]^.Sound <> nil) then
    Result := M.Items[0]^.Sound.Name;
  ReleasePatch(P);
end;

procedure HousekeepingChecks;
var
  I: PInstance;
  D: TS950Disk;
  B, X, Progs: Integer;
  Want, Other: string;
  Owed: Boolean;
begin
  Writeln;
  Writeln('the patch reaches the engine with no editor open (the housekeeping thread)');
  D := DiskFrom(BassImage);
  Progs := Length(NamesOf(D));
  B := -1;
  X := 0;
  for B := 1 to Progs - 1 do
  begin
    for X := 36 to 72 do
    begin
      Want := FirstSampleFor(D, B, X);
      Other := FirstSampleFor(D, 0, X);
      if (Want <> '') and (Other <> '') and (Want <> Other) then Break;
    end;
    if (Want <> '') and (Other <> '') and (Want <> Other) then Break;
  end;
  D.Free;

  I := NewInstance;
  Check(I^.P.HousekeeperRunning, 'Prepare starts the housekeeping thread', '');
  // Prepare gave the engine the placeholder, and Process has not taken it: both refused.
  I^.P.LoadDiskBytes('BASS', '', BassImage, Diag);
  I^.P.SelectProgramFromPanel(B);
  Owed := I^.P.PatchOwed;
  Check(Owed, 'programme ' + IntToStr(B) + ' chosen before the engine took the last patch: owed', '');
  Idle(I);                                // takes the placeholder
  Check(WaitUntilPaid(I, 2000), 'paid by the housekeeping thread alone (no PanelTick)', '');
  Idle(I);                                // takes programme B, handed over by now
  NumEvents := 0;
  Midi(0, $90, X, 100);
  ProcessInst(I, BlockSize);
  NumEvents := 0;
  Check(SoundingName(I) = Want, Format('note %d plays programme %d''s sample', [X, B]), SoundingName(I) + ' / ' + Want + ' (programme 0: ' + Other + ')');
  FreeInstance(I);
end;

{ ---- keygroup edits ---- }

procedure EditChecks;
var
  I1, I2: PInstance;
  D: TS950Disk;
  E: TDiskEntry;
  Before, After: TBytes;
  Info: TKeygroupParamInfo;
  At: NativeInt;
  K, Diffs, Rev, N, Note, Count: Integer;
  SoundBefore: TS950Sound;
  Diff, Same: Double;
  Ok: Boolean;
  V: PS950Voice;

  function TheVoice(I: PInstance): PS950Voice;
  var J: Integer;
  begin
    Result := nil;
    for J := 0 to EnginePolyphony - 1 do
      if I^.P.Engine.GetVoice(J)^.IsActive then
      begin
        Result := I^.P.Engine.GetVoice(J);
        Exit;
      end;
  end;

begin
  Writeln;
  Writeln('keygroup edits through the plug-in');
  I1 := NewInstance;
  I2 := NewInstance;
  I1^.P.LoadDiskBytes('PIANO', '', PianoImage, Diag);
  I2^.P.LoadDiskBytes('PIANO', '', PianoImage, Diag);
  Deliver(I1);
  Deliver(I2);
  Settle(I1);
  Settle(I2);
  Count := I2^.P.GetKeygroupCount;
  Check(Count = 9, 'GRAND PNO: 9 keygroups', IntToStr(Count));

  Before := I2^.P.SaveDiskBytes;
  Rev := I2^.P.GetEditRevision;
  D := DiskFrom(PianoImage);
  NthProgram(D, 0, E);
  I2^.P.SetKeygroupValue(2, kpVcaAttack, 40);
  After := I2^.P.SaveDiskBytes;
  Info := KeygroupParamInfo(kpVcaAttack);
  D.KeygroupByteAt(E, 2, Info.Offset, At);
  Diffs := 0;
  for K := 0 to High(Before) do
    if Before[K] <> After[K] then Inc(Diffs);
  Check((I2^.P.GetKeygroupValue(2, kpVcaAttack) = 40) and (Diffs = 1) and (After[At] = 40),
    'one setting: one byte of the image, where it belongs', Format('%d bytes changed', [Diffs]));
  Check(I2^.P.GetEditRevision = Rev + 1, 'the edit revision moves', '');
  I2^.P.SetKeygroupValue(-1, kpVcaRelease, 33);
  Ok := True;
  for K := 0 to Count - 1 do
    if I2^.P.GetKeygroupValue(K, kpVcaRelease) <> 33 then Ok := False;
  Check(Ok, 'keygroup -1: every keygroup at once', '');
  I2^.P.SetKeygroupValue(2, kpVcaAttack, D.GetKeygroupParam(E, 2, kpVcaAttack));
  for K := 0 to Count - 1 do
    I2^.P.SetKeygroupValue(K, kpVcaRelease, D.GetKeygroupParam(E, K, kpVcaRelease));
  Check(SameBytes(I2^.P.SaveDiskBytes, Before), 'set back, the image is the original again', '');
  Check(I2^.P.GetZoneSample(0, 1) <> '', 'a zone''s sample', I2^.P.GetZoneSample(0, 1));
  Check((I2^.P.GetKeygroupValue(99, kpVcaAttack) = 0) and (I2^.P.GetZoneSample(99, 1) = ''), 'a keygroup that is not there reads as nothing', '');
  D.Free;

  // A held note follows an edit, on the same sample, without restarting.
  Settle(I1);
  Settle(I2);
  I1^.VT.Prepare(I1^.Inst, Rate, BlockSize);
  I2^.VT.Prepare(I2^.Inst, Rate, BlockSize);
  Note := 60;
  NumEvents := 0;
  Midi(0, $90, Note, 100);
  ProcessInst(I1, BlockSize);
  ProcessInst(I2, BlockSize);
  NumEvents := 0;
  Same := 0;
  for N := 1 to 10 do
  begin
    ProcessInst(I1, BlockSize);
    ProcessInst(I2, BlockSize);
    for K := 0 to BlockSize - 1 do Same := Max(Same, Abs(I1^.L[K] - I2^.L[K]));
  end;
  V := TheVoice(I2);
  SoundBefore := nil;
  if V <> nil then SoundBefore := V^.GetSound;
  for K := 0 to Count - 1 do
    I2^.P.SetKeygroupValue(K, kpZone1Filter, 5);
  Diff := 0;
  for N := 1 to 20 do
  begin
    ProcessInst(I1, BlockSize);
    ProcessInst(I2, BlockSize);
    I2^.P.PanelTick;
    for K := 0 to BlockSize - 1 do Diff := Max(Diff, Abs(I1^.L[K] - I2^.L[K]));
  end;
  V := TheVoice(I2);
  Check((Same = 0) and (V <> nil) and (V^.GetSound = SoundBefore) and (I2^.P.GetActiveVoices = 1) and (Diff > 1e-3),
    'a held note follows a filter edit on its own sample, not restarted', Format('diff %.4f', [Diff]));
  Check((I1^.P.ProcessErrors = 0) and (I2^.P.ProcessErrors = 0), 'no exceptions in Process', '');
  FreeInstance(I1);
  FreeInstance(I2);
end;

{ ---- the synth ---- }

function WaitRenderDone(I: PInstance; TimeoutMs: Integer): Boolean;
var
  T: QWord;
begin
  T := GetTickCount64;
  // due, running, then adopted
  repeat
    Sleep(5);
    Result := not I^.P.IsRendering;
    if Result then
    begin
      Sleep(150);                      // past the debounce of anything still wanted
      Result := not I^.P.IsRendering;
      if Result then Exit;
    end;
  until GetTickCount64 - T > QWord(TimeoutMs);
end;

function WaitRendering(I: PInstance; TimeoutMs: Integer): Boolean;
var
  T: QWord;
begin
  T := GetTickCount64;
  repeat
    Result := I^.P.IsRendering;
    if Result then Exit;
    Sleep(1);
  until GetTickCount64 - T > QWord(TimeoutMs);
end;

procedure SynthChecks;
var
  I: PInstance;
  R1, R2: TRecipe;
  Gen, Calls, Attempt: Integer;
  Cache: TWaveCache;
  D1, D2: TS950Disk;
  Err: string;
  WasRendering, Dropped: Boolean;
  Bass: TArray<string>;
  D: TS950Disk;
begin
  Writeln;
  Writeln('the synth render thread');
  R1 := Presets[9].Recipe;              // drums and a saw: a slow first render
  R2 := R1;
  R2.Osc[0].Level := 60;
  R2.Osc[0].Fine := 7;

  I := NewInstance;
  Gen := I^.P.GetDiskGeneration;
  Calls := I^.Host.ProgramsChangedCalls;
  I^.P.SetRecipe(R1);
  Check(not I^.P.IsRendering, 'SetRecipe: not at once (100 ms debounce)', '');
  Check(WaitRendering(I, 2000), 'the housekeeping thread starts the render', '');
  I^.P.SetRecipe(R2);
  WasRendering := I^.P.IsRendering;
  Check(WaitRenderDone(I, 10000), 'it finishes, and the one asked for meanwhile after it', '');
  Check(I^.P.DiskIsSynth and (I^.P.GetSelectedProgram = 0) and (Length(I^.P.GetProgramNames) > 0)
    and (I^.P.GetDiskGeneration > Gen) and (I^.Host.ProgramsChangedCalls > Calls) and (I^.P.GetRenderError = ''),
    'the rendered disk is adopted: programme 0, a new generation, the host told', I^.P.GetRenderError);
  // the same as rendering the two in turn directly
  Cache := TWaveCache.Create;
  D1 := TS950Disk.Create;
  D2 := TS950Disk.Create;
  Err := '';
  Render(R1, Cache, nil, D1, Err);
  Render(R2, Cache, D1, D2, Err);
  Check(WasRendering and SameBytes(I^.P.SaveDiskBytes, D2.Image), 'a knob turned mid-render renders once more: the disk is R2''s, kept from R1''s', Err);
  Check(ToText(I^.P.GetRecipe) = ToText(R2), 'the recipe is the newest', '');
  D1.Free;
  D2.Free;
  Cache.Free;
  FreeInstance(I);

  // A disk loaded while a render runs wins: the render's result is dropped.
  D := DiskFrom(BassImage);
  Bass := NamesOf(D);
  D.Free;
  Dropped := False;
  for Attempt := 1 to 5 do
  begin
    I := NewInstance;                    // a fresh wave cache: the render takes a while
    I^.P.SetRecipe(R1);
    if WaitRendering(I, 2000) then
    begin
      I^.P.LoadDiskBytes('BASS.hfe', '', BassImage, Diag);
      WasRendering := I^.P.IsRendering;
      WaitRenderDone(I, 10000);
      if WasRendering then
      begin
        Check(not I^.P.DiskIsSynth and (I^.P.GetDiskName = 'BASS.hfe') and (Length(I^.P.GetProgramNames) = Length(Bass)),
          'a disk loaded mid-render stays; the render is dropped', Format('attempt %d', [Attempt]));
        Dropped := True;
      end;
    end;
    FreeInstance(I);
    if Dropped then Break;
  end;
  Check(Dropped, 'the drop rule was exercised', '');

  // Destroyed while rendering: joined, nothing leaks.
  I := NewInstance;
  I^.P.SetRecipe(R1);
  WaitRendering(I, 2000);
  FreeInstance(I);
  Check(True, 'an instance destroyed mid-render joins the thread', '');
end;

{ ---- saving a disk ---- }

procedure SaveDiskChecks;
var
  I, J: PInstance;
  Path: string;
  Bytes: TBytes;
begin
  Writeln;
  Writeln('saving the disk');
  I := NewInstance;
  Check(not I^.P.SaveDiskAs(OutDir + 'none.img', Diag) and (Diag = 'no disk is loaded') and (I^.P.SaveDiskBytes = nil),
    'no disk: nothing to save', Diag);
  I^.P.LoadDiskBytes('DRUMS', '', DrumsImage, Diag);
  I^.P.SetKeygroupValue(0, kpVcaDecay, 12);
  Path := OutDir + 'saved.img';
  Check(I^.P.SaveDiskAs(Path, Diag), 'SaveDiskAs', Diag);
  Bytes := ReadFileBytes(Path);
  Check(SameBytes(Bytes, I^.P.SaveDiskBytes) and (Length(Bytes) = 819200), 'the file is the image, edit and all', IntToStr(Length(Bytes)));
  J := NewInstance;
  Check(J^.P.LoadDisk(Path, Diag) and SameBytes(J^.P.SaveDiskBytes, Bytes) and (J^.P.GetKeygroupValue(0, kpVcaDecay) = 12)
    and (J^.P.GetDiskPath = Path), 'LoadDisk reads it back the same', Diag);
  Check(not J^.P.LoadDisk(OutDir + 'no such file.img', Diag) and (Diag <> '') and (J^.P.GetDiskPath = Path),
    'a missing file: an error, the disk there is kept', Diag);
  Check(not I^.P.SaveDiskAs(OutDir + 'no such dir\x.img', Diag) and (Diag <> ''), 'an unwritable path: an error', Diag);
  FreeInstance(I);
  FreeInstance(J);
end;

{ ---- gzip ---- }

procedure GzipChecks;
const
  Sizes: array[0..6] of Integer = (0, 1, 100, 70000, 819200, 1638400, 2097152);
var
  K, J, Bad, Accepted, Kind: Integer;
  D, G, O: TBytes;
begin
  Writeln;
  Writeln('gzip (the disk in the state)');
  Bad := 0;
  for Kind := 0 to 2 do
    for K := 0 to High(Sizes) do
    begin
      SetLength(D, Sizes[K]);
      for J := 0 to High(D) do
        case Kind of
          0: D[J] := 0;                                  // a blank disk: as compressible as it gets
          1: D[J] := NextRandom and $FF;                 // nothing to compress
        else
          if J mod 4096 < 100 then D[J] := NextRandom and $FF else D[J] := J and 3;
        end;
      if not GzipCompress(D, G) or not GzipDecompress(G, GzipDefaultMaxOutput, O) or not SameBytes(D, O) then
      begin
        Writeln('    round trip failed: kind ', Kind, ', ', Sizes[K], ' bytes');
        Inc(Bad);
      end;
    end;
  Check(Bad = 0, 'round trips up to 2 MiB: zeros, noise, mixed', Format('%d failed', [Bad]));
  SetLength(D, 5000);
  for J := 0 to High(D) do D[J] := J mod 7;
  GzipCompress(D, G);
  Accepted := 0;
  for J := 0 to Length(G) - 1 do
    if GzipDecompress(G, 0, J, GzipDefaultMaxOutput, O) then Inc(Accepted);
  Check(Accepted = 0, 'every truncation refused', Format('%d of %d accepted', [Accepted, Length(G)]));
  SetLength(D, GzipDefaultMaxOutput + 1);
  FillChar(D[0], Length(D), 0);
  GzipCompress(D, G);
  Check(not GzipDecompress(G, GzipDefaultMaxOutput, O) and (O = nil), 'one byte past the cap: refused', Format('%d bytes packed', [Length(G)]));
  SetLength(D, 0);
  GzipCompress(D, G);
  SetLength(G, Length(G) + 1);
  Check(not GzipDecompress(G, GzipDefaultMaxOutput, O), 'a byte after the member: refused', '');
  // the inflater on its own: mutated streams, never an exception, never past the cap
  SetLength(D, 20000);
  for J := 0 to High(D) do if J mod 300 < 40 then D[J] := NextRandom and $FF else D[J] := J mod 5;
  GzipCompress(D, G);
  Bad := 0;
  Accepted := 0;
  for K := 1 to 20000 do
  begin
    O := Copy(G, 10, Length(G) - 18);
    for J := 0 to RandomInt(4) do O[RandomInt(Length(O))] := NextRandom and $FF;
    try
      if InflateRaw(O, 0, Length(O), 30000, D, J) then
      begin
        Inc(Accepted);
        if (Length(D) > 30000) or (J > Length(O)) then Inc(Bad);
      end;
    except
      Inc(Bad);
    end;
  end;
  Check(Bad = 0, '20000 mutated deflate streams: no exception, never past the cap', Format('%d decoded to something', [Accepted]));
end;

{ ---- the state ---- }

type
  TSection = record
    Tag: AnsiString;
    Payload: TBytes;
  end;

function SplitState(const S: TBytes; out Secs: TArray<TSection>): Boolean;
var
  P, Len, N: Integer;
begin
  Secs := nil;
  Result := False;
  P := 5;
  N := 0;
  while P + 8 <= Length(S) do
  begin
    Len := S[P + 4] or (S[P + 5] shl 8) or (S[P + 6] shl 16) or (S[P + 7] shl 24);
    SetLength(Secs, N + 1);
    SetLength(Secs[N].Tag, 4);
    Move(S[P], Secs[N].Tag[1], 4);
    Secs[N].Payload := Copy(S, P + 8, Len);
    Inc(P, 8 + Len);
    Inc(N);
  end;
  Result := P = Length(S);
end;

function JoinState(const Secs: array of TSection; Version: Byte = 1): TBytes;
var
  K, P, L: Integer;
begin
  L := 5;
  for K := 0 to High(Secs) do Inc(L, 8 + Length(Secs[K].Payload));
  SetLength(Result, L);
  Result[0] := Ord('M'); Result[1] := Ord('z'); Result[2] := Ord('9'); Result[3] := Ord('5'); Result[4] := Version;
  P := 5;
  for K := 0 to High(Secs) do
  begin
    Move(Secs[K].Tag[1], Result[P], 4);
    L := Length(Secs[K].Payload);
    Result[P + 4] := L and $FF; Result[P + 5] := (L shr 8) and $FF; Result[P + 6] := (L shr 16) and $FF; Result[P + 7] := (L shr 24) and $FF;
    if L > 0 then Move(Secs[K].Payload[0], Result[P + 8], L);
    Inc(P, 8 + L);
  end;
end;

function Section(const ATag: AnsiString; const Payload: TBytes): TSection;
begin
  Result.Tag := ATag;
  Result.Payload := Payload;
end;

function WithSection(const S: TBytes; const ATag: AnsiString; const Payload: TBytes): TBytes;
var
  Secs: TArray<TSection>;
  K: Integer;
begin
  SplitState(S, Secs);
  for K := 0 to High(Secs) do
    if Secs[K].Tag = ATag then
      Secs[K].Payload := Payload;
  Result := JoinState(Secs);
end;

function ProgPayload(Index: Integer; const Name: string): TBytes;
var
  U: UTF8String;
begin
  U := UTF8String(Name);
  SetLength(Result, 4 + Length(U));
  Result[0] := Index and $FF; Result[1] := (Index shr 8) and $FF; Result[2] := (Index shr 16) and $FF; Result[3] := (Index shr 24) and $FF;
  if Length(U) > 0 then Move(U[1], Result[4], Length(U));
end;

var
  Captured: TBytes;

procedure StateWriter(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;
begin
  SetLength(Captured, Size);
  if Size > 0 then Move(Data^, Captured[0], Size);
end;

// What a plug-in in any state must still be.
function Sane(I: PInstance; out Why: string): Boolean;
var
  Names: TArray<string>;
  K, J, C, Sel: Integer;
  Used: array[0..127] of Boolean;
begin
  Result := False;
  Names := I^.P.GetProgramNames;
  Sel := I^.P.GetSelectedProgram;
  if (Sel < -1) or (Sel >= Length(Names)) then begin Why := 'selection'; Exit; end;
  if (I^.P.CurrentProgram < 0) or (I^.P.CurrentProgram >= 64) then begin Why := 'current'; Exit; end;
  for K := 0 to Min(63, High(Names)) do
    if I^.P.ProgramName(K) <> Names[K] then begin Why := 'snapshot'; Exit; end;
  if (Length(Names) = 0) and (I^.P.ProgramName(0) <> 'Placeholder saw') then begin Why := 'placeholder'; Exit; end;
  if (I^.P.EditorTab < 0) or (I^.P.EditorTab > 2) then begin Why := 'tab'; Exit; end;
  FillChar(Used, SizeOf(Used), 0);
  for J := 0 to NumParams - 1 do
  begin
    C := I^.P.CcFor(J);
    if C = -1 then Continue;
    if not Learnable(C) or Used[C] then begin Why := 'map'; Exit; end;
    Used[C] := True;
  end;
  Why := '';
  Result := True;
end;

procedure StateChecks;
var
  I1, I2: PInstance;
  Saved, NoDisk, SynthState, Data, Bomb, Zeros, Junk, Packed_: TBytes;
  Names: TArray<string>;
  K, Run, Exceptions, Bad, N, Rejected: Integer;
  Diff: Double;
  Why: string;
  Secs: TArray<TSection>;
  Many: array of TSection;
  Ok: Boolean;
  T: QWord;
  R1: TRecipe;

  procedure Load(I: PInstance; const D: TBytes);
  begin
    try
      I^.P.LoadState(D);
    except
      Inc(Exceptions);
    end;
  end;

  function Unchanged(I: PInstance): Boolean;
  begin
    Result := (I^.P.GetDiskName = 'BASS.hfe') and (I^.P.GetSelectedProgram = 5) and (I^.P.CcFor(PGain) = 20);
  end;

begin
  Writeln;
  Writeln('the saved state');
  Exceptions := 0;
  I1 := NewInstance;
  I1^.P.LoadDiskBytes('BASS.hfe', 'C:\disks\BASS.hfe', BassImage, Diag);
  I1^.P.SelectProgramFromPanel(5);
  I1^.P.SetKeygroupValue(0, kpVcaRelease, 77);
  I1^.P.Learn(PGain);
  NumEvents := 0;
  Midi(0, $B0, 20, 1);
  ProcessInst(I1, BlockSize);
  NumEvents := 0;
  I1^.P.ForgetCc(PWideSpread);
  I1^.P.EditorTab := 2;
  T := GetTickCount64;
  Saved := I1^.P.SaveState;
  Check((Length(Saved) > 1000) and (Length(Saved) < 600000), 'saved: the disk gzipped and the rest', Format('%d bytes in %d ms', [Length(Saved), GetTickCount64 - T]));
  T := GetTickCount64;
  Data := I1^.P.SaveState;
  Check(SameBytes(Data, Saved), 'saved again (the gzip kept): the same bytes', Format('%d ms', [GetTickCount64 - T]));
  Ok := SplitState(Saved, Secs);
  Check(Ok and (Length(Secs) = 7), 'seven sections, to the end exactly', IntToStr(Length(Secs)));

  I2 := NewInstance;
  Load(I2, Saved);
  Names := I2^.P.GetProgramNames;
  Ok := (Length(Names) = 24) and (I2^.P.GetSelectedProgram = 5) and (I2^.P.CurrentProgram = 5)
    and (I2^.P.GetDiskName = 'BASS.hfe') and (I2^.P.GetDiskPath = 'C:\disks\BASS.hfe')
    and SameBytes(I2^.P.SaveDiskBytes, I1^.P.SaveDiskBytes) and (I2^.P.GetKeygroupValue(0, kpVcaRelease) = 77)
    and (I2^.P.EditorTab = 2) and not I2^.P.DiskIsSynth;
  Check(Ok, 'a new instance: the disk with its edit, programme 5, the path, the tab', I2^.P.GetPatchName);
  Ok := True;
  for K := 0 to NumParams - 1 do
    if I2^.P.CcFor(K) <> I1^.P.CcFor(K) then Ok := False;
  Check(Ok and (I2^.P.CcFor(PGain) = 20) and (I2^.P.CcFor(PWideSpread) = -1), 'the CC map', '');

  // the same sound from both
  Deliver(I1);
  I1^.VT.Prepare(I1^.Inst, Rate, BlockSize);
  I2^.VT.Prepare(I2^.Inst, Rate, BlockSize);
  Diff := 0;
  Seed := 777;
  for N := 0 to 199 do
  begin
    NumEvents := 0;
    if N mod 10 = 0 then Midi(RandomInt(BlockSize), $90, 30 + RandomInt(40), 1 + RandomInt(127));
    if N mod 10 = 5 then Midi(RandomInt(BlockSize), $B0, 123, 0);
    ProcessInst(I1, BlockSize);
    ProcessInst(I2, BlockSize);
    for K := 0 to BlockSize - 1 do
      Diff := Max(Diff, Max(Abs(I1^.L[K] - I2^.L[K]), Abs(I1^.R[K] - I2^.R[K])));
  end;
  NumEvents := 0;
  Check(Diff = 0, 'identical audio from the original and the restored', Format('max diff %g', [Diff]));

  // through the ABI
  Captured := nil;
  I1^.VT.GetState(I1^.Inst, StateWriter, nil);
  Check(SameBytes(Captured, Saved), 'GetState through the ABI: the same bytes', '');
  FreeInstance(I2);
  I2 := NewInstance;
  I2^.VT.SetState(I2^.Inst, @Captured[0], Length(Captured));
  Check(I2^.P.GetSelectedProgram = 5, 'SetState through the ABI', '');

  // the programme: by name first, the index if the name is gone
  Names := I1^.P.GetProgramNames;
  Load(I2, WithSection(Saved, 'PROG', ProgPayload(2, Names[7])));
  Check(I2^.P.GetSelectedProgram = 7, 'by name before the index', IntToStr(I2^.P.GetSelectedProgram));
  Load(I2, WithSection(Saved, 'PROG', ProgPayload(3, 'NO SUCH')));
  Check(I2^.P.GetSelectedProgram = 3, 'the index when the name is not on the disk', IntToStr(I2^.P.GetSelectedProgram));
  Load(I2, WithSection(Saved, 'PROG', ProgPayload(40, 'NO SUCH')));
  Check(I2^.P.GetSelectedProgram = 0, 'neither: the first programme', IntToStr(I2^.P.GetSelectedProgram));

  // a state with no disk is the placeholder; an empty one the default CCs
  FreeInstance(I1);
  I1 := NewInstance;
  NoDisk := I1^.P.SaveState;
  Load(I2, NoDisk);
  Check((Length(I2^.P.GetProgramNames) = 0) and (I2^.P.ProgramName(0) = 'Placeholder saw') and (I2^.P.GetPatchName = 'Placeholder saw')
    and (I2^.P.CcFor(PGain) = -1), 'a state with no disk: the placeholder again', '');
  I2^.P.Learn(PGain);
  I2^.P.LoadState(nil);
  Check((I2^.P.LearningIndex = -1) and (I2^.P.CcFor(PGain) = -1) and (I2^.P.CcFor(PVcfCutoff) = 74), 'an empty state: the default CC map', '');

  // a synth disk: the recipe and the flag come back
  R1 := Presets[3].Recipe;
  I1^.P.SetRecipe(R1);
  WaitRendering(I1, 2000);
  WaitRenderDone(I1, 10000);
  SynthState := I1^.P.SaveState;
  Load(I2, SynthState);
  Check(I2^.P.DiskIsSynth and (ToText(I2^.P.GetRecipe) = ToText(R1)) and SameBytes(I2^.P.SaveDiskBytes, I1^.P.SaveDiskBytes)
    and not I2^.P.IsRendering, 'a synth disk: its recipe and its flag, and no re-render', '');
  FreeInstance(I1);

  // crafted damage: none of it changes anything
  Load(I2, Saved);
  Check(Unchanged(I2), 'back to BASS, programme 5', '');
  Rejected := 0;
  Data := Copy(Saved); Data[4] := 2; Load(I2, Data); if Unchanged(I2) then Inc(Rejected);        // a later version
  Data := Copy(Saved); Data[0] := Ord('X'); Load(I2, Data); if Unchanged(I2) then Inc(Rejected); // magic
  Data := Copy(Saved); SetLength(Data, Length(Data) - 1); Load(I2, Data); if Unchanged(I2) then Inc(Rejected);  // truncated
  Data := Copy(Saved); SetLength(Data, Length(Data) + 1); Load(I2, Data); if Unchanged(I2) then Inc(Rejected);  // a trailing byte
  Data := Copy(Saved); Data[9] := $FF; Data[10] := $FF; Data[11] := $FF; Data[12] := $FF; Load(I2, Data); if Unchanged(I2) then Inc(Rejected); // huge length
  // a gzip bomb: 3 MiB of zeros in a few kilobytes
  SetLength(Zeros, 3 * 1024 * 1024);
  FillChar(Zeros[0], Length(Zeros), 0);
  GzipCompress(Zeros, Bomb, 9);
  Data := WithSection(Saved, 'DISK', Bomb); Load(I2, Data); if Unchanged(I2) then Inc(Rejected);
  // a corrupt gzip: one byte of the deflate stream, the CRC, the length
  SplitState(Saved, Secs);
  Packed_ := Copy(Secs[0].Payload);
  Packed_[Length(Packed_) div 2] := Packed_[Length(Packed_) div 2] xor $5A;
  Load(I2, WithSection(Saved, 'DISK', Packed_)); if Unchanged(I2) then Inc(Rejected);
  Packed_ := Copy(Secs[0].Payload);
  Packed_[Length(Packed_) - 6] := Packed_[Length(Packed_) - 6] xor 1;
  Load(I2, WithSection(Saved, 'DISK', Packed_)); if Unchanged(I2) then Inc(Rejected);
  Packed_ := Copy(Secs[0].Payload);
  Packed_[Length(Packed_) - 2] := Packed_[Length(Packed_) - 2] xor 1;
  Load(I2, WithSection(Saved, 'DISK', Packed_)); if Unchanged(I2) then Inc(Rejected);
  Packed_ := Copy(Secs[0].Payload, 0, Length(Secs[0].Payload) div 2);
  Load(I2, WithSection(Saved, 'DISK', Packed_)); if Unchanged(I2) then Inc(Rejected);
  // a section twice; too many; a name with no disk; text that is not UTF-8; a bad tab
  SetLength(Many, Length(Secs) + 1);
  for K := 0 to High(Secs) do Many[K] := Secs[K];
  Many[High(Many)] := Section('ETAB', TBytes.Create(1));
  Load(I2, JoinState(Many)); if Unchanged(I2) then Inc(Rejected);
  SetLength(Many, Length(Secs) + 40);
  for K := Length(Secs) to High(Many) do Many[K] := Section('XXXX', nil);
  Load(I2, JoinState(Many)); if Unchanged(I2) then Inc(Rejected);
  Load(I2, JoinState([Section('NAME', TBytes.Create(65, 66))])); if Unchanged(I2) then Inc(Rejected);
  Load(I2, WithSection(Saved, 'PATH', TBytes.Create($C3, $28))); if Unchanged(I2) then Inc(Rejected);
  Load(I2, WithSection(Saved, 'ETAB', TBytes.Create(7))); if Unchanged(I2) then Inc(Rejected);
  Load(I2, WithSection(Saved, 'PROG', ProgPayload(-5, ''))); if Unchanged(I2) then Inc(Rejected);
  Load(I2, WithSection(Saved, 'SYNT', TBytes.Create(2))); if Unchanged(I2) then Inc(Rejected);
  Check((Rejected = 17) and (Exceptions = 0), 'damaged states (version, magic, lengths, gzip bomb and corruption, sections, text) change nothing',
    Format('%d of 17 refused', [Rejected]));
  // well-formed, but the disk is not a disk: the rest is taken, the disk kept
  SetLength(Junk, 819200);
  for K := 0 to High(Junk) do Junk[K] := NextRandom and $FF;
  GzipCompress(Junk, Packed_, 1);
  Load(I2, WithSection(Saved, 'DISK', Packed_));
  Check((I2^.P.GetDiskName = 'BASS.hfe') and Sane(I2, Why), 'a gzip of noise where the disk was: the disk there is stays', Why);
  // an unknown section is skipped
  SetLength(Many, Length(Secs) + 1);
  for K := 0 to High(Secs) do Many[K] := Secs[K];
  Many[High(Many)] := Section('NEW!', TBytes.Create(1, 2, 3));
  Load(I2, JoinState(Many));
  Check(Unchanged(I2) and (I2^.P.EditorTab = 2), 'a section from a later build is skipped', '');

  // 20000 random and mutated states
  Bad := 0;
  Seed := 2463534242;
  T := GetTickCount64;
  for Run := 0 to 19999 do
  begin
    case Run mod 32 of
      0:        begin Data := Copy(Saved); for K := 0 to RandomInt(4) do Data[RandomInt(Length(Data))] := NextRandom and $FF; end;
      1:        begin Data := Copy(Saved); SetLength(Data, RandomInt(Length(Data))); end;
      2..9:     begin Data := Copy(NoDisk); for K := 0 to RandomInt(4) do Data[RandomInt(Length(Data))] := NextRandom and $FF;
                  if RandomInt(4) = 0 then SetLength(Data, RandomInt(Length(Data) + 8)); end;
      10..15:   begin
                  // sections of known tags with random lengths and contents
                  SetLength(Many, 1 + RandomInt(6));
                  for K := 0 to High(Many) do
                  begin
                    case RandomInt(8) of
                      0: Many[K].Tag := 'DISK'; 1: Many[K].Tag := 'NAME'; 2: Many[K].Tag := 'PATH'; 3: Many[K].Tag := 'PROG';
                      4: Many[K].Tag := 'SYNT'; 5: Many[K].Tag := 'CCMP'; 6: Many[K].Tag := 'ETAB';
                    else Many[K].Tag := 'ZZZZ';
                    end;
                    SetLength(Many[K].Payload, RandomInt(40));
                    for N := 0 to High(Many[K].Payload) do Many[K].Payload[N] := NextRandom and $FF;
                    if (Many[K].Tag = 'DISK') and (RandomInt(2) = 0) then
                    begin
                      SetLength(Zeros, RandomInt(5000));
                      for N := 0 to High(Zeros) do Zeros[N] := RandomInt(3);
                      GzipCompress(Zeros, Many[K].Payload, 6);
                      if RandomInt(2) = 0 then Many[K].Payload[RandomInt(Length(Many[K].Payload))] := NextRandom and $FF;
                    end;
                  end;
                  Data := JoinState(Many);
                  if RandomInt(3) = 0 then
                    for K := 0 to RandomInt(3) do Data[5 + RandomInt(Length(Data) - 5)] := NextRandom and $FF;
                end;
      16..23:   begin SetLength(Data, RandomInt(400)); for K := 0 to High(Data) do Data[K] := NextRandom and $FF;
                  if (Length(Data) >= 5) and (RandomInt(2) = 0) then begin Data[0] := Ord('M'); Data[1] := Ord('z'); Data[2] := Ord('9'); Data[3] := Ord('5'); Data[4] := 1; end; end;
      24..27:   begin Data := Copy(NoDisk); SetLength(Data, RandomInt(Length(Data))); end;
    else
      begin
        // the CC map's payload, mutated
        SplitState(NoDisk, Secs);
        for K := 0 to High(Secs) do
          if Secs[K].Tag = 'CCMP' then
          begin
            for N := 0 to RandomInt(4) do
              Secs[K].Payload[RandomInt(Length(Secs[K].Payload))] := NextRandom and $FF;
            if RandomInt(3) = 0 then SetLength(Secs[K].Payload, RandomInt(Length(Secs[K].Payload) + 3));
          end;
        Data := JoinState(Secs);
      end;
    end;
    Load(I2, Data);
    if not Sane(I2, Why) then
    begin
      if Bad < 5 then Writeln('    run ', Run, ': ', Why);
      Inc(Bad);
    end;
    if Run mod 64 = 0 then
    begin
      Idle(I2);
      I2^.P.PanelTick;
    end;
  end;
  Check((Exceptions = 0) and (Bad = 0) and (I2^.P.ProcessErrors = 0), '20000 random and mutated states: never raised, always sane',
    Format('%d exceptions, %d broken, %d Process errors, %d s', [Exceptions, Bad, I2^.P.ProcessErrors, (GetTickCount64 - T) div 1000]));
  FreeInstance(I2);
end;

{ ---- everything at once ---- }

type
  TAudioThread = class(TThread)
  protected
    procedure Execute; override;
  public
    I: PInstance;
    Blocks: Integer;
  end;

procedure TAudioThread.Execute;
var
  Ctx: TJuceProcessContext;
  Channels: array[0..1] of PJuceSampleArray;
  Ev: array[0..1] of TJuceMidiEvent;
  Msg: array[0..1, 0..2] of Byte;
  S: UInt32;
begin
  S := 99;
  Channels[0] := @I^.L;
  Channels[1] := @I^.R;
  while not Terminated do
  begin
    S := S xor (S shl 13); S := S xor (S shr 17); S := S xor (S shl 5);
    Msg[0, 0] := $90; Msg[0, 1] := 36 + S mod 48; Msg[0, 2] := 1 + (S shr 8) mod 127;
    Msg[1, 0] := $80; Msg[1, 1] := 36 + (S shr 16) mod 48; Msg[1, 2] := 0;
    Ev[0].Data := @Msg[0, 0]; Ev[0].Size := 3; Ev[0].SamplePosition := 3;
    Ev[1].Data := @Msg[1, 0]; Ev[1].Size := 3; Ev[1].SamplePosition := 100;
    FillChar(Ctx, SizeOf(Ctx), 0);
    Ctx.StructSize := SizeOf(Ctx);
    Ctx.NumSamples := BlockSize;
    Ctx.Channels := @Channels;
    Ctx.MidiEvents := @Ev;
    Ctx.Parameters := @I^.Host.Params;
    Ctx.Transport := @I^.Transport;
    Ctx.NumChannels := 2;
    Ctx.NumOutputChannels := 2;
    if Blocks mod 4 = 0 then Ctx.NumMidiEvents := 2 else Ctx.NumMidiEvents := 0;
    Ctx.NumParameters := NumParams;
    Ctx.MidiEventSize := SizeOf(TJuceMidiEvent);
    I^.VT.Process(I^.Inst, @Ctx);
    Inc(Blocks);
  end;
end;

procedure HammerChecks;
var
  I: PInstance;
  A: TAudioThread;
  Readers: array[0..1] of TReader;
  T: QWord;
  K, Ops, Bad, Reads: Integer;
  R: TRecipe;
  Env: TEnvelopeShape;
  Act: TKeygroupActivity;
  Kg: Integer;
begin
  Writeln;
  Writeln('the panel hammered while Process runs and the program list is read');
  I := NewInstance;
  A := TAudioThread.Create(True);
  A.I := I;
  A.Start;
  for K := 0 to 1 do
  begin
    Readers[K] := TReader.Create(True);
    Readers[K].P := I^.P;
    Readers[K].Valid := nil;
    Readers[K].Start;
  end;
  T := GetTickCount64;
  Ops := 0;
  R := Presets[1].Recipe;
  while GetTickCount64 - T < 3000 do
  begin
    case RandomInt(10) of
      0: I^.P.LoadDiskBytes('BASS', '', BassImage, Diag);
      1: I^.P.LoadDiskBytes('DRUMS', '', DrumsImage, Diag);
      2, 3: I^.P.SelectProgramFromPanel(RandomInt(24));
      4, 5:
        begin
          Kg := RandomInt(I^.P.GetKeygroupCount + 1) - 1;
          I^.P.SetKeygroupValue(Kg, TKeygroupParam(RandomInt(KeygroupParamCount)), RandomInt(120) - 10);
        end;
      6: if RandomInt(10) = 0 then
         begin
           R.Osc[0].Level := RandomInt(100);
           I^.P.SetRecipe(R);
         end;
      7: I^.P.PanelTick;
      8: begin Env := I^.P.GetEnvelope(RandomInt(2) = 0); Act := I^.P.GetKeygroupActivity(RandomInt(64)); I^.P.GetActiveVoices; end;
      9: begin I^.P.GetZoneSample(RandomInt(4), 1 + RandomInt(2)); I^.P.GetProgramNames; I^.P.IsNoteHeld(RandomInt(128)); end;
    end;
    Inc(Ops);
  end;
  A.Terminate;
  A.WaitFor;
  Bad := 0;
  Reads := 0;
  for K := 0 to 1 do
  begin
    Readers[K].Terminate;
    Readers[K].WaitFor;
    Inc(Bad, Readers[K].Bad);
    Inc(Reads, Readers[K].Reads);
    Readers[K].Free;
  end;
  Check((I^.P.ProcessErrors = 0) and (A.Blocks > 1000) and (Bad = 0),
    '3 s: panel calls, Process and program reads at once', Format('%d panel calls, %d blocks, %d reads, %d bad, %d errors',
      [Ops, A.Blocks, Reads, Bad, I^.P.ProcessErrors]));
  A.Free;
  WaitRenderDone(I, 10000);
  Check(not I^.P.IsRendering and Sane(I, Diag), 'afterwards: sane, nothing rendering', Diag);
  FreeInstance(I);
end;

var
  Src: string;
begin
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide, exOverflow, exUnderflow, exPrecision]);
  Writeln('Mz950_Pascal plug-in check');

  Src := GetEnvironmentVariable('VS950_SRC');
  if Src = '' then
    Src := GetEnvironmentVariable('USERPROFILE') + '\src\VirtualS950';
  DisksDir := IncludeTrailingPathDelimiter(Src) + 'disks\';
  OutDir := IncludeTrailingPathDelimiter(GetEnvironmentVariable('TEMP')) + 'mz950-verify\plugin\';
  ForceDirectories(OutDir);
  BassImage := ImageOf('BASS.hfe');
  DrumsImage := ImageOf('DRUMS.hfe');
  PianoImage := ImageOf('PIANO.hfe');
  if (BassImage = nil) or (DrumsImage = nil) or (PianoImage = nil) then
  begin
    Writeln('the disks are needed: ', DisksDir);
    Halt(1);
  end;

  RegisterMz950;
  FillChar(Factory, SizeOf(Factory), 0);
  Factory.StructSize := SizeOf(Factory);
  if pascaljuce_plugin_entry(JCP_ABI_VERSION, @Factory) <> 0 then
  begin
    Writeln('entry point refused: ', JuceDeclarationError);
    Halt(1);
  end;

  DeclarationChecks;
  AudioChecks;
  CcChecks;
  ProgramChecks;
  HousekeepingChecks;
  EditChecks;
  SynthChecks;
  SaveDiskChecks;
  GzipChecks;
  StateChecks;
  HammerChecks;

  Writeln;
  if Failures = 0 then
    Writeln('all checks passed')
  else
    Writeln(Failures, ' FAILED');
  if Failures <> 0 then
    ExitCode := 1;
end.
