// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// THE PROGRAM TAB: what is on the disk. The Object Pascal counterpart of
// Plugin/Source/ProgramPage.h/.cpp (KeygroupStrip and ProgramPage).
//
// Every control here is an ABSOLUTE setting of one keygroup, in the panel's own units and
// ranges, read from and written to the disk image (TMz950.Get/SetKeygroupValue) - so it reads
// like the machine's front panel, is saved with the project, and goes out with the disk when
// it is saved as a file. The Perform tab's controls are offsets on top of this and never touch
// the disk; where one of them is moving a value shown here, the control says what is actually
// sounding underneath it, in cyan: "-> 52".
//
// Six small pages rather than one crowded one: envelopes, filter, LFO, velocity, tuning, and
// the keys and output a keygroup covers. Above them the keygroups over a piano keyboard, one
// bar each (overlapping ones in lanes), lit as notes arrive; and a box that names every one.
//
// What differs from the C++: Save disk as... asks through the framework's file dialog and
// writes the file here (TMz950.SaveDiskBytes); an error is said in the window (OnNotice)
// rather than in a message box, which PascalJUCE does not have.
unit Mz950ProgramPage;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin, JuceUI, S950Disk, Mz950Plugin, Mz950Look,
  Mz950Controls;

const
  // The keyboard the S950 has: C0 (24) to G8 (127).
  StripFirstKey = 24;
  StripLastKey = 127;

type
  TMzSelectEvent = procedure(Sender: TObject; Keygroup: Integer) of object;
  TMzNoticeEvent = procedure(Sender: TObject; const Text: string) of object;

  TMzKeyRange = record
    Low, High: Integer;
    Sample: string;
  end;

  // KeygroupStrip: the programme's keygroups over a piano keyboard, one bar each, clicked to
  // choose one.
  TMzKeygroupStrip = class(TJuceControl)
  private
    FRanges: array of TMzKeyRange;
    FLane: array of Integer;
    FLit: array of Boolean;
    FNotes: array of Integer;
    FHeld: array[0..127] of Boolean;
    FLanes: Integer;
    FSelected: Integer;
    FOnSelect: TMzSelectEvent;
    function BarsArea: TJuceRect;
    function KeysArea: TJuceRect;
    function WhiteCount: Integer;
    function WhiteWidth: Single;
    function KeyLeft(Note: Integer): Single;
    function KeyRight(Note: Integer): Single;
    function KeyRect(Note: Integer): TJuceRect;
    function BarFor(K: Integer): TJuceRect;
    function KeyAt(X, Y: Single): Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseMove(X, Y: Single; Shift: TJuceShiftState); override;
  public
    constructor Create(AOwner: TComponent); override;
    class function IsBlack(Note: Integer): Boolean;
    procedure SetKeygroups(const Ranges: array of TMzKeyRange);
    // The one to highlight, or -1 for all of them.
    procedure SetSelected(K: Integer);
    // Which keygroups are playing, and the key each last answered.
    procedure SetActivity(const Lit: array of Boolean; const Notes: array of Integer);
    procedure SetHeld(Note: Integer; Held: Boolean);
    function KeygroupAt(X, Y: Single): Integer;
    // The middle of a keygroup's bar, for tests and the like (local).
    function BarCentre(K: Integer; out X, Y: Single): Boolean;
    function KeygroupCount: Integer;
    function IsLit(K: Integer): Boolean;
    property OnSelect: TMzSelectEvent read FOnSelect write FOnSelect;
  end;

  // One control of the page: a knob, a switch or the output box, with its caption and the
  // cyan "sounding" readout under it.
  TMzProgramControl = class
  public
    Param: TKeygroupParam;
    Page: Integer;
    Name: string;
    TrimId: string;          // the Perform offset that moves it, or ''
    Zone2: Boolean;          // only means anything if the keygroup has a second zone
    Knob: TMzKnob;
    Toggle: TMzToggle;
    Combo: TMzCombo;
    Caption, Sounding: TMzLabel;
    Value: Integer;          // as last read, for the sounding readout
    Varies: Boolean;         // "All" shown, and the keygroups disagree
    function Main: TJuceControl;
  end;

  TMzProgramPage = class(TJuceControl)
  private
    FPlugin: TMz950;
    FCells: array of TMzProgramControl;
    FKeygroupPanel, FPagePanel: TMzPanel;
    FStrip: TMzKeygroupStrip;
    FKeygroupBox: TMzCombo;
    FPrev, FNext, FSave: TMzButton;
    FHeading, FDetail, FBlankNote, FEmptyNote: TMzLabel;
    FPages: TMzTabBar;
    FSelected: Integer;      // -1 is every keygroup at once
    FPage: Integer;
    FCount: Integer;
    FUpdating: Boolean;
    FSeenHits: array of UInt32;
    FFlashUntil: array of Int64;
    FOnNotice: TMzNoticeEvent;
    procedure Add(P: TKeygroupParam; OnPage: Integer; const AName: string; const ATrimId: string = '';
      AZone2: Boolean = False);
    procedure ControlChanged(Sender: TObject);
    function KnobText(Sender: TObject; V: Integer): string;
    procedure PageChanged(Sender: TObject);
    procedure StripSelect(Sender: TObject; Keygroup: Integer);
    procedure BoxChanged(Sender: TObject);
    procedure PrevClick(Sender: TObject);
    procedure NextClick(Sender: TObject);
    procedure SaveClick(Sender: TObject);
    procedure SaveChosen(Sender: TJuceEditor; Chosen: Boolean; const Path: string);
    procedure Write(C: TMzProgramControl; V: Integer);
    procedure FillKeygroupBox(const Ranges: array of TMzKeyRange);
    procedure Layout;
    procedure LayoutControls;
    function Shown: Integer;
    procedure Notice(const Text: string);
  protected
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent; APlugin: TMz950); reintroduce;
    destructor Destroy; override;
    // Everything re-read from the processor: a new disk, programme, or edit.
    procedure Refresh;
    // Only the "-> sounding" readouts, against the offsets as they are now. Cheap.
    procedure RefreshSounding;
    // Choose a keygroup (-1 for all of them), and a page (0 Envelopes .. 5 Keys & output).
    procedure Choose(Keygroup: Integer);
    procedure ShowPage(Page: Integer);
    function ControlFor(P: TKeygroupParam): TMzProgramControl;
    property Selected: Integer read FSelected;
    property CurrentPage: Integer read FPage;
    property Strip: TMzKeygroupStrip read FStrip;
    property KeygroupBox: TMzCombo read FKeygroupBox;
    property SaveButton: TMzButton read FSave;
    property PageTabs: TMzTabBar read FPages;
    property OnNotice: TMzNoticeEvent read FOnNotice write FOnNotice;
  end;

const
  // The pages.
  PageEnvelopes = 0;
  PageFilter = 1;
  PageLfo = 2;
  PageVelocity = 3;
  PageTuning = 4;
  PageKeys = 5;
  PageCount = 6;

// The Studio's names: middle C, note 60, is C3.
function NoteName(Note: Integer): string;

// How a value reads under its knob (ProgramPage.cpp's describe).
function DescribeKeygroupValue(P: TKeygroupParam; V: Integer): string;

// The arrow of the sounding readout, in the string type the plug-in uses.
function ArrowSign: string;

// Milliseconds, for the lights.
function Milliseconds: Int64;

implementation

uses
  Math;

const
  // the strip's height, top to bottom: the keygroup bars, the keys, the octave names
  LabelH = 14.0;
  KeysH = 44.0;
  BarsGap = 4.0;
  BlackFrac = 0.6;     // a black key's width, of a white key's
  BlackLen = 0.62;     // and its length, of the keyboard's height

  WhiteKey = TJuceColor($FFC9CED6);
  BlackKey = TJuceColor($FF15171B);
  HeldDot = TJuceColor($FF3B82F6);     // blue: a key held over MIDI
  LaneBack = TJuceColor($FF17191D);

  FlashMs = 180;

function Milliseconds: Int64;
begin
  {$IFDEF FPC}
  Result := GetTickCount64;
  {$ELSE}
  Result := TThread.GetTickCount64;
  {$ENDIF}
end;

function ArrowSign: string;
begin
  {$IFDEF FPC}
  Result := #$E2#$86#$92;
  {$ELSE}
  Result := #$2192;
  {$ENDIF}
end;

function NoteName(Note: Integer): string;
const
  Names: array[0..11] of string = ('C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B');
var
  Octave: Integer;
begin
  // C++ integer division (towards zero), as the C++ does it
  if Note >= 0 then
    Octave := Note div 12 - 2
  else
    Octave := -((-Note) div 12) - 2;
  Result := Names[((Note mod 12) + 12) mod 12] + IntToStr(Octave);
end;

function Plus(V: Integer): string;
begin
  if V > 0 then
    Result := '+'
  else
    Result := '';
end;

function DescribeKeygroupValue(P: TKeygroupParam; V: Integer): string;
var
  S: string;
begin
  case P of
    kpHighKey, kpLowKey:
      Result := NoteName(V) + ' (' + IntToStr(V) + ')';
    kpVelocitySwitch:
      if V >= 128 then
        Result := 'off'
      else
        Result := IntToStr(V);
    // Transpose and fine are the high and low bytes of one signed count of sixteenths of a
    // semitone, so each knob says what it is worth - in the C++'s words.
    kpZone1Fine, kpZone2Fine:
      begin
        Str((V / 16.0):0:2, S);
        Result := IntToStr(V) + ' (+' + S + ' st)';
      end;
    kpZone1Transpose, kpZone2Transpose:
      Result := Plus(V) + IntToStr(V) + ' (' + Plus(V) + IntToStr(V * 16) + ' st)';
  else
    if KeygroupParamInfo(P).Kind = pkSigned then
      Result := Plus(V) + IntToStr(V)
    else
      Result := IntToStr(V);
  end;
end;

{ ------------------------------------------------------------------- TMzKeygroupStrip }

constructor TMzKeygroupStrip.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLanes := 1;
  FSelected := -1;
end;

class function TMzKeygroupStrip.IsBlack(Note: Integer): Boolean;
begin
  case ((Note mod 12) + 12) mod 12 of
    1, 3, 6, 8, 10: Result := True;
  else
    Result := False;
  end;
end;

procedure TMzKeygroupStrip.SetKeygroups(const Ranges: array of TMzKeyRange);
var
  I, J, L: Integer;
  Clash: Boolean;
begin
  SetLength(FRanges, Length(Ranges));
  for I := 0 to High(Ranges) do
    FRanges[I] := Ranges[I];

  // Lanes, greedily: each keygroup in the first lane where it overlaps nothing already there.
  SetLength(FLane, Length(FRanges));
  FLanes := 1;
  for I := 0 to High(FRanges) do
  begin
    L := 0;
    while True do
    begin
      Clash := False;
      for J := 0 to I - 1 do
        if (FLane[J] = L) and (FRanges[J].Low <= FRanges[I].High) and (FRanges[I].Low <= FRanges[J].High) then
          Clash := True;
      if not Clash then
      begin
        FLane[I] := L;
        FLanes := Max(FLanes, L + 1);
        Break;
      end;
      Inc(L);
    end;
  end;
  if Length(FLit) <> Length(FRanges) then
  begin
    SetLength(FLit, Length(FRanges));
    SetLength(FNotes, Length(FRanges));
    for I := 0 to High(FLit) do
    begin
      FLit[I] := False;
      FNotes[I] := -1;
    end;
  end;
  Invalidate;
end;

procedure TMzKeygroupStrip.SetSelected(K: Integer);
begin
  if K <> FSelected then
  begin
    FSelected := K;
    Invalidate;
  end;
end;

procedure TMzKeygroupStrip.SetActivity(const Lit: array of Boolean; const Notes: array of Integer);
var
  I: Integer;
  Moved: Boolean;
begin
  Moved := (Length(Lit) <> Length(FLit)) or (Length(Notes) <> Length(FNotes));
  if not Moved then
    for I := 0 to High(Lit) do
      if (Lit[I] <> FLit[I]) or (Notes[I] <> FNotes[I]) then
        Moved := True;
  if not Moved then
    Exit;      // nothing moved: no repaint
  SetLength(FLit, Length(Lit));
  SetLength(FNotes, Length(Notes));
  for I := 0 to High(Lit) do
    FLit[I] := Lit[I];
  for I := 0 to High(Notes) do
    FNotes[I] := Notes[I];
  Invalidate;
end;

procedure TMzKeygroupStrip.SetHeld(Note: Integer; Held: Boolean);
begin
  if (Note < 0) or (Note > 127) or (FHeld[Note] = Held) then
    Exit;
  FHeld[Note] := Held;
  Invalidate;
end;

function TMzKeygroupStrip.KeygroupCount: Integer;
begin
  Result := Length(FRanges);
end;

function TMzKeygroupStrip.IsLit(K: Integer): Boolean;
begin
  Result := (K >= 0) and (K < Length(FLit)) and FLit[K];
end;

function TMzKeygroupStrip.BarsArea: TJuceRect;
begin
  Result := JuceRect(2, 2, Width - 4, Max(0, Height - (LabelH + KeysH + BarsGap) - 4));
end;

function TMzKeygroupStrip.KeysArea: TJuceRect;
begin
  Result := JuceRect(2, Height - LabelH - KeysH, Width - 4, KeysH);
end;

function TMzKeygroupStrip.WhiteCount: Integer;
var
  K: Integer;
begin
  Result := 0;
  for K := StripFirstKey to StripLastKey do
    if not IsBlack(K) then
      Inc(Result);
end;

function TMzKeygroupStrip.WhiteWidth: Single;
begin
  Result := KeysArea.W / WhiteCount;
end;

function Clip(V, Lo, Hi: Integer): Integer;
begin
  Result := Max(Lo, Min(Hi, V));
end;

function TMzKeygroupStrip.KeyLeft(Note: Integer): Single;
var
  K, WhitesBefore: Integer;
  WW, X0: Single;
begin
  Note := Clip(Note, StripFirstKey, StripLastKey);
  WhitesBefore := 0;
  for K := StripFirstKey to Note - 1 do
    if not IsBlack(K) then
      Inc(WhitesBefore);
  WW := WhiteWidth;
  X0 := KeysArea.X;
  if IsBlack(Note) then
    Result := X0 + WhitesBefore * WW - WW * BlackFrac * 0.5
  else
    Result := X0 + WhitesBefore * WW;
end;

function TMzKeygroupStrip.KeyRight(Note: Integer): Single;
begin
  if IsBlack(Clip(Note, StripFirstKey, StripLastKey)) then
    Result := KeyLeft(Note) + WhiteWidth * BlackFrac
  else
    Result := KeyLeft(Note) + WhiteWidth;
end;

function TMzKeygroupStrip.KeyRect(Note: Integer): TJuceRect;
var
  A: TJuceRect;
  L, R: Single;
begin
  A := KeysArea;
  L := KeyLeft(Note);
  R := KeyRight(Note);
  if IsBlack(Note) then
    Result := JuceRect(L, A.Y, R - L, A.H * BlackLen)
  else
    Result := JuceRect(L, A.Y, R - L, A.H);
end;

function TMzKeygroupStrip.BarFor(K: Integer): TJuceRect;
var
  Area: TJuceRect;
  LaneH, L, R: Single;
  Lo, Hi: Integer;
begin
  Area := BarsArea;
  LaneH := Area.H / FLanes;
  Lo := Clip(Min(FRanges[K].Low, FRanges[K].High), StripFirstKey, StripLastKey);
  Hi := Clip(Max(FRanges[K].Low, FRanges[K].High), StripFirstKey, StripLastKey);
  L := KeyLeft(Lo);
  R := KeyRight(Hi);
  Result := JuceRect(L, Area.Y + FLane[K] * LaneH, R - L, LaneH - 2);
end;

function TMzKeygroupStrip.BarCentre(K: Integer; out X, Y: Single): Boolean;
var
  B: TJuceRect;
begin
  Result := (K >= 0) and (K < Length(FRanges));
  X := 0;
  Y := 0;
  if Result then
  begin
    B := BarFor(K);
    X := B.X + B.W / 2;
    Y := B.Y + B.H / 2;
  end;
end;

function TMzKeygroupStrip.KeyAt(X, Y: Single): Integer;
var
  N: Integer;
begin
  Result := -1;
  if not JuceRectContains(KeysArea, X, Y) then
    Exit;
  // black keys lie on top, so they are asked first
  for N := StripFirstKey to StripLastKey do
    if IsBlack(N) and JuceRectContains(KeyRect(N), X, Y) then
      Exit(N);
  for N := StripFirstKey to StripLastKey do
    if (not IsBlack(N)) and JuceRectContains(KeyRect(N), X, Y) then
      Exit(N);
end;

function TMzKeygroupStrip.KeygroupAt(X, Y: Single): Integer;
var
  K, Key: Integer;

  function Covers(I: Integer): Boolean;
  begin
    Result := (Key >= Min(FRanges[I].Low, FRanges[I].High)) and (Key <= Max(FRanges[I].Low, FRanges[I].High));
  end;

begin
  for K := 0 to High(FRanges) do
    if JuceRectContains(BarFor(K), X, Y) then
      Exit(K);

  // On the keys: the keygroup that plays that key - the one being edited if it does,
  // otherwise the first that does.
  Result := -1;
  Key := KeyAt(X, Y);
  if Key < 0 then
    Exit;
  if (FSelected >= 0) and (FSelected < Length(FRanges)) and Covers(FSelected) then
    Exit(FSelected);
  for K := 0 to High(FRanges) do
    if Covers(K) then
      Exit(K);
end;

procedure TMzKeygroupStrip.Paint(Canvas: TJuceCanvas);
var
  Bars, Keys, R, Bar: TJuceRect;
  N, K, Note: Integer;
  S, DotR, CX, CY, X: Single;
  On_, Playing: Boolean;
  Hue: TJuceColor;

  function ShadeOf(Note: Integer): Single;
  var
    I: Integer;
  begin
    Result := 0;
    for I := 0 to High(FRanges) do
    begin
      if (Note < Min(FRanges[I].Low, FRanges[I].High)) or (Note > Max(FRanges[I].Low, FRanges[I].High)) then
        Continue;
      if (FSelected < 0) or (FSelected = I) then
        Result := Max(Result, 1.0)
      else
        Result := Max(Result, 0.28);
    end;
  end;

begin
  Bars := BarsArea;
  Keys := KeysArea;

  // --- the lane background, with a faint line up from every C so bars read against keys
  Canvas.SetColor(LaneBack);
  Canvas.FillRoundRect(JuceRect(Bars.X - 2, Bars.Y - 2, Bars.W + 4, Bars.H + 4), 4);
  N := StripFirstKey;
  while N <= StripLastKey do
  begin
    Canvas.SetColor(JuceWithAlpha($FFFFFFFF, 0.06));
    VLine(Canvas, Trunc(KeyLeft(N)), Bars.Y, Bars.Y + Bars.H);
    Inc(N, 12);
  end;

  // --- the keyboard: the selected keygroup's keys shaded fully (every keygroup's, with
  // "All keygroups"), the other keygroups' faintly, keys nobody plays left bare
  for N := StripFirstKey to StripLastKey do
  begin
    if IsBlack(N) then
      Continue;
    R := KeyRect(N);
    S := ShadeOf(N);
    if S > 0 then
      Canvas.SetColor(JuceBlend(WhiteKey, ColProgram, 0.62 * S))
    else
      Canvas.SetColor(JDarker(WhiteKey, 0.25));
    Canvas.FillRect(JuceRect(R.X + 0.5, R.Y, R.W - 1, R.H));
  end;
  Canvas.SetColor(ColWindow);
  for N := StripFirstKey to StripLastKey do
    if not IsBlack(N) then
      VLine(Canvas, Trunc(KeyLeft(N)), Keys.Y, Keys.Y + Keys.H);
  for N := StripFirstKey to StripLastKey do
  begin
    if not IsBlack(N) then
      Continue;
    R := KeyRect(N);
    S := ShadeOf(N);
    if S > 0 then
      Canvas.SetColor(JuceBlend(BlackKey, JDarker(ColProgram, 0.35), 0.75 * S))
    else
      Canvas.SetColor(BlackKey);
    Canvas.FillRoundRect(JuceRect(R.X, R.Y - 2, R.W, R.H + 2), 1.5);
  end;

  // --- a blue dot on every key held over MIDI, low on the key where a finger would be
  DotR := Max(2.0, Min(4.0, WhiteWidth * 0.32));
  for N := StripFirstKey to StripLastKey do
  begin
    if not FHeld[N] then
      Continue;
    R := KeyRect(N);
    CX := R.X + R.W / 2;
    CY := R.Y + R.H - DotR - 3;
    Canvas.SetColor(HeldDot);
    Canvas.FillEllipse(JuceRect(CX - DotR, CY - DotR, DotR * 2, DotR * 2));
    if IsBlack(N) then
      Canvas.SetColor(JuceWithAlpha($FFFFFFFF, 0.8))
    else
      Canvas.SetColor(JuceWithAlpha(ColWindow, 0.7));
    Canvas.DrawEllipse(JuceRect(CX - DotR, CY - DotR, DotR * 2, DotR * 2), 1);
  end;

  // --- every C named under the keys
  UseFont(Canvas, 10);
  Canvas.SetColor(ColDim);
  N := StripFirstKey;
  while N <= StripLastKey do
  begin
    Canvas.DrawText(NoteName(N), JuceRect(KeyLeft(N), Height - LabelH, 30, LabelH), jaLeft, jvaCenter);
    Inc(N, 12);
  end;

  // --- the keygroup bars: an outline with a see-through fill, the edited keygroup's in amber,
  // the others' in grey; playing, fuller and brighter, with a light rim and a marker at the key
  for K := 0 to High(FRanges) do
  begin
    Bar := BarFor(K);
    On_ := (FSelected < 0) or (FSelected = K);
    Playing := (K < Length(FLit)) and FLit[K];
    if On_ then
      Hue := ColProgram
    else
      Hue := ColDim;
    if Playing then
      Canvas.SetColor(JuceWithAlpha(Hue, 0.55))
    else if FSelected = K then
      Canvas.SetColor(JuceWithAlpha(Hue, 0.32))
    else
      Canvas.SetColor(JuceWithAlpha(Hue, 0.16));
    Canvas.FillRoundRect(Bar, 3);
    if On_ then
      Canvas.SetColor(Hue)
    else
      Canvas.SetColor(JuceWithAlpha(Hue, 0.6));
    if FSelected = K then
      Canvas.DrawRoundRect(JuceInset(Bar, 0.5), 3, 2)
    else
      Canvas.DrawRoundRect(JuceInset(Bar, 0.5), 3, 1);

    if Playing then
    begin
      Canvas.SetColor(ColText);
      Canvas.DrawRoundRect(JuceInset(Bar, 1), 3, 2);
      if K < Length(FNotes) then
        Note := FNotes[K]
      else
        Note := -1;
      if (Note >= StripFirstKey) and (Note <= StripLastKey) then
      begin
        X := (KeyLeft(Note) + KeyRight(Note)) * 0.5;
        Canvas.FillRect(JuceRect(X - 1, Bar.Y + 3, 2, Bar.H - 6));
      end;
    end;

    if On_ then
      Canvas.SetColor(ColText)
    else
      Canvas.SetColor(ColDim);
    UseFont(Canvas, 11, True);
    if Bar.W > 14 then
      Canvas.DrawText(IntToStr(K + 1), Bar, jaCenter, jvaCenter);
  end;
end;

procedure TMzKeygroupStrip.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  K: Integer;
begin
  if not (jssLeft in Shift) then
    Exit;
  K := KeygroupAt(X, Y);
  if (K >= 0) and Assigned(FOnSelect) then
    FOnSelect(Self, K);
end;

procedure TMzKeygroupStrip.MouseMove(X, Y: Single; Shift: TJuceShiftState);
var
  K, Key: Integer;
  KeyText, Sample: string;
begin
  K := KeygroupAt(X, Y);
  Key := KeyAt(X, Y);
  // over a key, its name first - and "no keygroup" if nothing plays it
  if Key >= 0 then
    KeyText := NoteName(Key) + ' (' + IntToStr(Key) + ')   -   '
  else
    KeyText := '';
  if K < 0 then
  begin
    if Key >= 0 then
      Hint := KeyText + 'no keygroup plays this key'
    else
      Hint := 'The programme''s keygroups across the keyboard. Click one to edit it.';
    Exit;
  end;
  if FRanges[K].Sample <> '' then
    Sample := '   -   ' + FRanges[K].Sample
  else
    Sample := '';
  Hint := KeyText + 'Keygroup ' + IntToStr(K + 1) + ': ' + NoteName(FRanges[K].Low) + ' to '
    + NoteName(FRanges[K].High) + Sample;
end;

{ ------------------------------------------------------------------ TMzProgramControl }

function TMzProgramControl.Main: TJuceControl;
begin
  if Knob <> nil then
    Result := Knob
  else if Toggle <> nil then
    Result := Toggle
  else
    Result := Combo;
end;

{ --------------------------------------------------------------------- TMzProgramPage }

constructor TMzProgramPage.Create(AOwner: TComponent; APlugin: TMz950);
const
  PageNames: array[0..PageCount - 1] of string =
    ('Envelopes', 'Filter', 'LFO', 'Velocity', 'Tuning', 'Keys & output');
var
  I: Integer;
begin
  inherited Create(AOwner);
  FPlugin := APlugin;
  FSelected := 0;
  FPage := PageEnvelopes;

  // The panels first, so they are behind everything added after them. Amber throughout:
  // everything on this page is what is on the disk.
  FKeygroupPanel := TMzPanel.Create(Self);
  FKeygroupPanel.Title := 'KEYGROUPS';
  FKeygroupPanel.Note := 'choose one above, or click a bar or a key';
  FKeygroupPanel.Accent := ColProgram;
  FPagePanel := TMzPanel.Create(Self);
  FPagePanel.Accent := ColProgram;

  // --- envelopes: the amplitude one, then the filter one on a row of its own
  Add(kpVcaAttack, PageEnvelopes, 'VCA Attack', 'vcaAttack');
  Add(kpVcaDecay, PageEnvelopes, 'VCA Decay', 'vcaDecay');
  Add(kpVcaSustain, PageEnvelopes, 'VCA Sustain', 'vcaSustain');
  Add(kpVcaRelease, PageEnvelopes, 'VCA Release', 'vcaRelease');
  Add(kpVcfAttack, PageEnvelopes, 'VCF Attack', 'vcfAttack');
  Add(kpVcfDecay, PageEnvelopes, 'VCF Decay', 'vcfDecay');
  Add(kpVcfSustain, PageEnvelopes, 'VCF Sustain', 'vcfSustain');
  Add(kpVcfRelease, PageEnvelopes, 'VCF Release', 'vcfRelease');

  // --- filter. "Soft" and "hard" are the two zones: the sample under the velocity switch
  // and the one above it.
  Add(kpZone1Filter, PageFilter, 'Soft filter', 'vcfCutoff');
  Add(kpZone2Filter, PageFilter, 'Hard filter', 'vcfCutoff', True);
  Add(kpVcfAmount, PageFilter, 'VCF amount', 'vcfAmount');
  Add(kpKeyToFilter, PageFilter, 'Key track');
  Add(kpVelToFilter, PageFilter, 'Vel > filter', 'velToFilter');

  // --- LFO
  Add(kpLfoRate, PageLfo, 'Rate', 'lfoRate');
  Add(kpLfoDepth, PageLfo, 'Depth', 'lfoDepth');
  Add(kpLfoDelay, PageLfo, 'Delay', 'lfoDelay');
  Add(kpLfoModwheel, PageLfo, 'Mod wheel');
  Add(kpLfoAftertouch, PageLfo, 'Aftertouch');
  Add(kpLfoDesync, PageLfo, 'Desync');

  // --- velocity and loudness
  Add(kpVelToLoudness, PageVelocity, 'Vel > level', 'velToLoudness');
  Add(kpVelToAttack, PageVelocity, 'Vel > attack');
  Add(kpVelToRelease, PageVelocity, 'Vel > release');
  Add(kpVelocityReleaseOn, PageVelocity, 'Release on');
  Add(kpVelocitySwitch, PageVelocity, 'Vel switch');
  Add(kpZone1Loudness, PageVelocity, 'Soft level');
  Add(kpZone2Loudness, PageVelocity, 'Hard level', '', True);

  // --- tuning, and warp, which is a pitch bend at the strike
  Add(kpZone1Transpose, PageTuning, 'Soft transp');
  Add(kpZone1Fine, PageTuning, 'Soft fine');
  Add(kpZone2Transpose, PageTuning, 'Hard transp', '', True);
  Add(kpZone2Fine, PageTuning, 'Hard fine', '', True);
  Add(kpConstantPitch, PageTuning, 'Const pitch');
  Add(kpWarpDepth, PageTuning, 'Warp depth');
  Add(kpWarpVelocity, PageTuning, 'Warp vel');
  Add(kpWarpTime, PageTuning, 'Warp time');

  // --- which keys, and where it comes out
  Add(kpLowKey, PageKeys, 'Low key');
  Add(kpHighKey, PageKeys, 'High key');
  Add(kpOutputPort, PageKeys, 'Output');
  Add(kpOneShot, PageKeys, 'One shot');

  FPages := TMzTabBar.Create(Self);
  for I := 0 to PageCount - 1 do
    FPages.AddTab(PageNames[I], ColProgram);
  FPages.SetIndex(0, False);
  FPages.OnChange := PageChanged;

  FStrip := TMzKeygroupStrip.Create(Self);
  FStrip.OnSelect := StripSelect;
  FStrip.Hint := 'The programme''s keygroups across the keyboard. Click one to edit it.';

  FKeygroupBox := TMzCombo.Create(Self);
  FKeygroupBox.Hint := 'Which keygroup the controls below edit. "All keygroups" edits every '
    + 'one at once: a control then shows keygroup 1''s value, marked * where '
    + 'the others differ, and moving it sets them all to the same value.';
  FKeygroupBox.OnChange := BoxChanged;

  // Step through the keygroups; from "All", the first step lands on the first or the last.
  FPrev := TMzButton.Create(Self);
  FPrev.Caption := '<';
  FPrev.Hint := 'The keygroup before this one';
  FPrev.OnClick := PrevClick;
  FNext := TMzButton.Create(Self);
  FNext.Caption := '>';
  FNext.Hint := 'The keygroup after this one';
  FNext.OnClick := NextClick;

  FSave := TMzButton.Create(Self);
  FSave.Caption := 'Save disk as...';
  FSave.Lit := ColProgram;
  FSave.Hint := 'Write the disk, with every edit, as a plain .img - which the Studio, '
    + 'this plugin, and a Gotek or HxC floppy emulator all open. Edits are '
    + 'saved with the Live set anyway; this is for taking them elsewhere.';
  FSave.OnClick := SaveClick;

  FHeading := TMzLabel.Create(Self);
  FHeading.Caption := 'What is on the disk: absolute settings, in the S950''s own units, saved '
    + 'with the set and written into the disk.';
  FHeading.FontSize := 11.5;
  FHeading.Color := ColDim;

  FDetail := TMzLabel.Create(Self);
  FDetail.FontSize := 12.5;

  FBlankNote := TMzLabel.Create(Self);
  FBlankNote.Caption := 'This keygroup has no filter envelope on the disk (an S900 programme). '
    + 'Moving a VCF stage, or the amount, writes a flat one to start from.';
  FBlankNote.FontSize := 11.5;
  FBlankNote.Color := ColDim;
  FBlankNote.Visible := False;

  FEmptyNote := TMzLabel.Create(Self);
  FEmptyNote.Caption := 'Load a disk to edit its programmes. The placeholder saw is not on a '
    + 'disk, so there is nothing here to change.';
  FEmptyNote.Align := jaCenter;
  FEmptyNote.FontSize := 12.5;
  FEmptyNote.Color := ColDim;
  FEmptyNote.Visible := False;
end;

destructor TMzProgramPage.Destroy;
var
  I: Integer;
begin
  inherited Destroy;      // the controls (children) first
  for I := 0 to High(FCells) do
    FCells[I].Free;
end;

procedure TMzProgramPage.Notice(const Text: string);
begin
  if Assigned(FOnNotice) then
    FOnNotice(Self, Text);
end;

procedure TMzProgramPage.Add(P: TKeygroupParam; OnPage: Integer; const AName: string;
  const ATrimId: string; AZone2: Boolean);
var
  C: TMzProgramControl;
  Info: TKeygroupParamInfo;
  Tip: string;
  N, M: Integer;
  Ports: array[0..10] of string;
begin
  C := TMzProgramControl.Create;
  C.Param := P;
  C.Page := OnPage;
  C.Name := AName;
  C.TrimId := ATrimId;
  C.Zone2 := AZone2;
  N := Length(FCells);
  SetLength(FCells, N + 1);
  FCells[N] := C;

  Info := KeygroupParamInfo(P);
  Tip := Info.Name + ', as stored in the keygroup: ' + IntToStr(Info.Lo) + ' to ' + IntToStr(Info.Hi) + '.';
  if ATrimId <> '' then
    Tip := Tip + ' The matching Perform offset adds to it while you play; what sounds shows beside it in blue.';

  if Info.Kind = pkBit then
  begin
    C.Toggle := TMzToggle.Create(Self);
    C.Toggle.Caption := 'On';
    C.Toggle.Hint := Tip;
    C.Toggle.Lit := ColProgram;
    C.Toggle.Tag := N;
    C.Toggle.OnChange := ControlChanged;
    C.Toggle.Visible := False;
  end
  else if Info.Kind = pkPort then
  begin
    C.Combo := TMzCombo.Create(Self);
    Ports[0] := 'ALL';
    for M := 1 to 8 do
      Ports[M] := 'MONO ' + IntToStr(M);
    Ports[9] := 'LEFT';
    Ports[10] := 'RIGHT';
    C.Combo.SetItems(Ports);
    C.Combo.Hint := Tip;
    C.Combo.Tag := N;
    C.Combo.OnChange := ControlChanged;
    C.Combo.Visible := False;
  end
  else
  begin
    C.Knob := TMzKnob.Create(Self);
    C.Knob.SetRange(Info.Lo, Info.Hi);
    C.Knob.TextBoxWidth := 74;
    C.Knob.Accent := ColProgram;
    C.Knob.Hint := Tip;
    C.Knob.Tag := N;
    C.Knob.OnIntText := KnobText;
    C.Knob.OnChange := ControlChanged;
    C.Knob.Visible := False;
  end;

  C.Caption := TMzLabel.Create(Self);
  C.Caption.StyleCaption(AName);
  C.Caption.Hint := Tip;
  C.Caption.Visible := False;

  C.Sounding := TMzLabel.Create(Self);
  C.Sounding.Align := jaCenter;
  C.Sounding.FontSize := 11;
  C.Sounding.Bold := True;
  C.Sounding.Color := ColPerform;      // cyan: the Perform offsets showing through
  C.Sounding.Hint := 'What is actually sounding: this setting plus the Perform offset.';
  C.Sounding.Visible := False;
end;

function TMzProgramPage.ControlFor(P: TKeygroupParam): TMzProgramControl;
var
  I: Integer;
begin
  for I := 0 to High(FCells) do
    if FCells[I].Param = P then
      Exit(FCells[I]);
  Result := nil;
end;

function TMzProgramPage.KnobText(Sender: TObject; V: Integer): string;
var
  T: Integer;
begin
  T := TComponent(Sender).Tag;
  if (T >= 0) and (T <= High(FCells)) then
    Result := DescribeKeygroupValue(FCells[T].Param, V)
  else
    Result := IntToStr(V);
end;

procedure TMzProgramPage.ControlChanged(Sender: TObject);
var
  T: Integer;
  C: TMzProgramControl;
begin
  if FUpdating then
    Exit;
  T := TComponent(Sender).Tag;
  if (T < 0) or (T > High(FCells)) then
    Exit;
  C := FCells[T];
  if C.Knob <> nil then
    Write(C, C.Knob.IntValue)
  else if C.Toggle <> nil then
  begin
    if C.Toggle.IsOn then Write(C, 1) else Write(C, 0);
  end
  else if C.Combo <> nil then
    Write(C, C.Combo.ItemIndex);
end;

procedure TMzProgramPage.Write(C: TMzProgramControl; V: Integer);
begin
  if FUpdating then
    Exit;
  FPlugin.SetKeygroupValue(FSelected, C.Param, V);
  // Read straight back, so the control and its readouts never show a moment of the old value.
  Refresh;
end;

procedure TMzProgramPage.PageChanged(Sender: TObject);
begin
  ShowPage(FPages.Index);
end;

procedure TMzProgramPage.StripSelect(Sender: TObject; Keygroup: Integer);
begin
  Choose(Keygroup);
end;

procedure TMzProgramPage.BoxChanged(Sender: TObject);
var
  I: Integer;
begin
  if FUpdating then
    Exit;
  I := FKeygroupBox.ItemIndex;
  if I = 0 then
    Choose(-1)
  else if I > 0 then
    Choose(I - 1);
end;

procedure TMzProgramPage.PrevClick(Sender: TObject);
begin
  if FCount <= 0 then
    Exit;
  if FSelected <= 0 then
    Choose(FCount - 1)
  else
    Choose(FSelected - 1);
end;

procedure TMzProgramPage.NextClick(Sender: TObject);
begin
  if FCount <= 0 then
    Exit;
  if (FSelected < 0) or (FSelected >= FCount - 1) then
    Choose(0)
  else
    Choose(FSelected + 1);
end;

procedure TMzProgramPage.Choose(Keygroup: Integer);
begin
  if Keygroup < -1 then
    Keygroup := -1;
  FSelected := Keygroup;
  Refresh;
end;

procedure TMzProgramPage.ShowPage(Page: Integer);
begin
  FPage := Max(0, Min(PageCount - 1, Page));
  FPages.SetIndex(FPage, False);
  Layout;
  Refresh;
end;

function TMzProgramPage.Shown: Integer;
begin
  if FSelected >= 0 then
    Result := FSelected
  else
    Result := 0;
end;

// The C++ saveDisk: start beside the disk, named after it, "-edited.img".
procedure TMzProgramPage.SaveClick(Sender: TObject);
var
  Ed: TJuceEditor;
  Name, Folder, DiskPath: string;
begin
  Ed := Editor;
  if Ed = nil then
    Exit;
  DiskPath := FPlugin.GetDiskPath;
  if FPlugin.GetDiskName <> '' then
    Name := ChangeFileExt(ExtractFileName(FPlugin.GetDiskName), '')
  else
    Name := 'disk';
  Folder := '';
  if (DiskPath <> '') and FileExists(DiskPath) then
    Folder := ExtractFilePath(DiskPath);
  if Folder <> '' then
    Ed.SaveFile('Save the disk, with its edits, as an image', '*.img',
      IncludeTrailingPathDelimiter(Folder) + Name + '-edited.img', SaveChosen)
  else
    Ed.SaveFile('Save the disk, with its edits, as an image', '*.img', '', SaveChosen);
end;

procedure TMzProgramPage.SaveChosen(Sender: TJuceEditor; Chosen: Boolean; const Path: string);
var
  F: string;
  Image: TBytes;
  S: TFileStream;
begin
  if (not Chosen) or (Path = '') then
    Exit;
  F := Path;
  if not SameText(ExtractFileExt(F), '.img') then
    F := ChangeFileExt(F, '.img');
  Image := FPlugin.SaveDiskBytes;
  if Length(Image) = 0 then
  begin
    Notice('Could not save the disk: no disk is loaded');
    Exit;
  end;
  try
    S := TFileStream.Create(F, fmCreate);
    try
      S.WriteBuffer(Image[0], Length(Image));
    finally
      S.Free;
    end;
  except
    on E: Exception do
      Notice('Could not save the disk: ' + E.Message);
  end;
end;

procedure TMzProgramPage.FillKeygroupBox(const Ranges: array of TMzKeyRange);
var
  Items: array of string;
  K: Integer;
  Keys, Sample: string;
begin
  SetLength(Items, Length(Ranges) + 1);
  Items[0] := 'All ' + IntToStr(FCount) + ' keygroups';
  for K := 0 to High(Ranges) do
  begin
    if Ranges[K].Low = Ranges[K].High then
      Keys := NoteName(Ranges[K].Low)
    else
      Keys := NoteName(Ranges[K].Low) + ' - ' + NoteName(Ranges[K].High);
    if Ranges[K].Sample <> '' then
      Sample := '   ' + Ranges[K].Sample
    else
      Sample := '';
    Items[K + 1] := IntToStr(K + 1) + '   ' + Keys + Sample;
  end;
  FKeygroupBox.SetItems(Items);
  if FSelected < 0 then
    FKeygroupBox.SetItemIndex(0)
  else
    FKeygroupBox.SetItemIndex(FSelected + 1);
end;

procedure TMzProgramPage.Refresh;
var
  HaveDisk, HasHard, OnPage, Usable: Boolean;
  Ranges: array of TMzKeyRange;
  K, I, Other: Integer;
  Soft, Hard, Text: string;
  C: TMzProgramControl;
begin
  FCount := FPlugin.GetKeygroupCount;
  HaveDisk := FCount > 0;
  FEmptyNote.Visible := not HaveDisk;

  FStrip.Visible := HaveDisk;
  FKeygroupBox.Visible := HaveDisk;
  FPrev.Visible := HaveDisk;
  FNext.Visible := HaveDisk;
  FSave.Visible := HaveDisk;
  FHeading.Visible := HaveDisk;
  FDetail.Visible := HaveDisk;
  FPages.Visible := HaveDisk;
  FKeygroupPanel.Visible := HaveDisk;
  FPagePanel.Visible := HaveDisk;

  if not HaveDisk then
  begin
    FBlankNote.Visible := False;
    for I := 0 to High(FCells) do
    begin
      FCells[I].Main.Visible := False;
      FCells[I].Caption.Visible := False;
      FCells[I].Sounding.Visible := False;
    end;
    Exit;
  end;

  if FSelected >= FCount then
    FSelected := 0;

  // --- the strip
  SetLength(Ranges, FCount);
  for K := 0 to FCount - 1 do
  begin
    Soft := FPlugin.GetZoneSample(K, 1);
    Hard := FPlugin.GetZoneSample(K, 2);
    Ranges[K].Low := FPlugin.GetKeygroupValue(K, kpLowKey);
    Ranges[K].High := FPlugin.GetKeygroupValue(K, kpHighKey);
    if (Hard <> '') and (Hard <> Soft) then
      Ranges[K].Sample := Soft + ' / ' + Hard
    else
      Ranges[K].Sample := Soft;
  end;
  FStrip.SetKeygroups(Ranges);
  FStrip.SetSelected(FSelected);

  FUpdating := True;
  try
    FillKeygroupBox(Ranges);

    // --- the line beside it: what the choice means, since the box already says which it is
    K := Shown;
    HasHard := FPlugin.GetZoneSample(K, 2) <> '';
    if FSelected < 0 then
      FDetail.Caption := 'a change sets all ' + IntToStr(FCount) + ' to the same value'
    else
    begin
      Soft := FPlugin.GetZoneSample(K, 1);
      Hard := FPlugin.GetZoneSample(K, 2);
      if Soft = '' then Soft := '-';
      if Hard = '' then Hard := '-';
      FDetail.Caption := 'soft: ' + Soft + '   hard: ' + Hard;
    end;

    FBlankNote.Visible := (FPage = PageEnvelopes) and FPlugin.IsVcfBlank(K) and (FSelected >= 0);

    // --- every control on the page
    for I := 0 to High(FCells) do
    begin
      C := FCells[I];
      OnPage := C.Page = FPage;
      C.Value := FPlugin.GetKeygroupValue(K, C.Param);
      C.Varies := False;
      if FSelected < 0 then
        for Other := 1 to FCount - 1 do
          if FPlugin.GetKeygroupValue(Other, C.Param) <> C.Value then
          begin
            C.Varies := True;
            Break;
          end;

      // A second-zone control on a keygroup with no second zone has nothing to act on.
      Usable := (not C.Zone2) or HasHard or (FSelected < 0);

      Text := UpperCase(C.Name);
      if C.Varies then
        Text := Text + ' *';
      C.Caption.Caption := Text;
      C.Caption.Visible := OnPage;
      C.Caption.Enabled := Usable;
      C.Sounding.Visible := OnPage;

      if C.Knob <> nil then
      begin
        C.Knob.SetIntValue(C.Value);
        C.Knob.Enabled := Usable;
        C.Knob.Visible := OnPage;
        C.Knob.Invalidate;
      end;
      if C.Toggle <> nil then
      begin
        C.Toggle.SetChecked(C.Value <> 0);
        C.Toggle.Visible := OnPage;
      end;
      if C.Combo <> nil then
      begin
        C.Combo.SetItemIndex(C.Value);
        C.Combo.Visible := OnPage;
      end;
    end;
  finally
    FUpdating := False;
  end;

  RefreshSounding;
  Invalidate;
end;

procedure TMzProgramPage.RefreshSounding;
var
  Ed: TJuceEditor;
  I, Idx, By, Lo, Hi, Now_: Integer;
  C: TMzProgramControl;
begin
  Ed := Editor;
  for I := 0 to High(FCells) do
  begin
    C := FCells[I];
    By := 0;
    if (C.TrimId <> '') and (Ed <> nil) then
    begin
      Idx := Ed.FindParameter(C.TrimId);
      if Idx >= 0 then
        By := Round(Ed.ParamToPlain(Idx, Ed.ParamNormalised(Idx)));
    end;
    if By = 0 then
    begin
      C.Sounding.Caption := '';
      Continue;
    end;
    if C.Param = kpVcfAmount then
    begin
      Lo := -50;
      Hi := 50;
    end
    else
    begin
      Lo := 0;
      Hi := 99;
    end;
    Now_ := Max(Lo, Min(Hi, C.Value + By));
    C.Sounding.Caption := ArrowSign + ' ' + DescribeKeygroupValue(C.Param, Now_);
  end;
end;

// Lighting the strip as notes play: a keygroup stays lit while a voice plays it, and for a
// moment after its hit count moved - so a hit too short to be caught sounding still shows.
function TMzProgramPage.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TMzProgramPage.Tick;
var
  K, N: Integer;
  Now_: Int64;
  A: TKeygroupActivity;
  Lit: array of Boolean;
  Notes: array of Integer;
begin
  if (not Visible) or (FCount <= 0) then
    Exit;
  Now_ := Milliseconds;
  if Length(FSeenHits) <> FCount then
  begin
    // A new programme: start from its counts, or every keygroup would flash at once.
    SetLength(FSeenHits, FCount);
    SetLength(FFlashUntil, FCount);
    for K := 0 to FCount - 1 do
    begin
      FSeenHits[K] := FPlugin.GetKeygroupActivity(K).Hits;
      FFlashUntil[K] := 0;
    end;
  end;
  SetLength(Lit, FCount);
  SetLength(Notes, FCount);
  for K := 0 to FCount - 1 do
  begin
    A := FPlugin.GetKeygroupActivity(K);
    if A.Hits <> FSeenHits[K] then
    begin
      FSeenHits[K] := A.Hits;
      FFlashUntil[K] := Now_ + FlashMs;
    end;
    Lit[K] := A.Sounding or (Now_ < FFlashUntil[K]);
    Notes[K] := A.LastNote;
  end;
  FStrip.SetActivity(Lit, Notes);
  // the keys held over MIDI, for the dots on the keyboard
  for N := 0 to 127 do
    FStrip.SetHeld(N, FPlugin.IsNoteHeld(N));
end;

// ProgramPage::resized, in this page's own coordinates.
procedure TMzProgramPage.Layout;
var
  W, H, Y, X, AX, AW: Integer;
begin
  W := Width;
  H := Height;
  FEmptyNote.SetBounds(0, 0, W, H);
  FHeading.SetBounds(0, 0, W, 16);
  Y := 16 + 8;

  // the keygroups panel: the strip across the keyboard, and above it the buttons and the
  // line that says which keygroup is being edited
  FKeygroupPanel.SetBounds(0, Y, W, PanelHeaderHeight + 28 + 6 + 112 + 8);
  AX := FKeygroupPanel.ContentLeft;
  AW := FKeygroupPanel.ContentWidth;
  Y := FKeygroupPanel.ContentTop;
  // < [ keygroup box ] >   what it means            Save disk as...
  FSave.SetBounds(AX + AW - 112, Y, 112, 26);
  X := AX;
  FPrev.SetBounds(X, Y, 26, 26);
  Inc(X, 26 + 4);
  FKeygroupBox.SetBounds(X, Y, 230, 26);
  Inc(X, 230 + 4);
  FNext.SetBounds(X, Y, 26, 26);
  Inc(X, 26 + 10);
  FDetail.SetBounds(X, Y, Max(0, AX + AW - 112 - 8 - X), 26);
  FStrip.SetBounds(AX, Y + 26 + 6, AW, 112);

  // the settings panel, with the six pages as tabs along its top edge - the tab bar IS its
  // header, which is why this panel has no title of its own
  Y := FKeygroupPanel.Top + FKeygroupPanel.Height + 10;
  FPagePanel.SetBounds(0, Y, W, Max(0, H - Y));
  FPages.SetBounds(PanelPad, Y + 4, W - 2 * PanelPad, 28);
  FBlankNote.SetBounds(PanelPad, H - 4 - 32, W - 2 * PanelPad, 32);
  LayoutControls;
end;

// The page's controls in rows of cells, placed as one block centred in the panel both ways.
// Two deliberate breaks: the filter envelope under the amplitude one, and Warp under the two
// zones' tuning.
procedure TMzProgramPage.LayoutControls;
const
  CellW = 72;
  CellH = 92;
  ColGap = 14;
  RowGap = 10;
var
  RX, RY, RW, RH, PerRow, I, Row, Col, Columns, Rows, BlockW, BlockH, Left0, Y, X: Integer;
  RowOf, ColOf: array of Integer;
  C: TMzProgramControl;
  NewRow: Boolean;
begin
  RX := PanelPad;
  RY := FPagePanel.Top + 4 + 28 + 12;
  RW := Width - 2 * PanelPad;
  RH := Max(0, FPagePanel.Top + FPagePanel.Height - 4 - 32 - RY);
  PerRow := Max(1, (RW + ColGap) div (CellW + ColGap));

  SetLength(RowOf, Length(FCells));
  SetLength(ColOf, Length(FCells));
  Row := 0;
  Col := 0;
  Columns := 0;
  for I := 0 to High(FCells) do
  begin
    RowOf[I] := -1;
    C := FCells[I];
    if C.Page <> FPage then
      Continue;
    NewRow := (C.Param = kpVcfAttack) or (C.Param = kpWarpDepth) or (Col >= PerRow);
    if NewRow and (Col > 0) then
    begin
      Inc(Row);
      Col := 0;
    end;
    RowOf[I] := Row;
    ColOf[I] := Col;
    Inc(Col);
    Columns := Max(Columns, Col);
  end;
  if Columns = 0 then
    Exit;
  Rows := Row + 1;

  BlockW := Columns * CellW + (Columns - 1) * ColGap;
  BlockH := Rows * CellH + (Rows - 1) * RowGap;
  Left0 := RX + Max(0, (RW - BlockW) div 2);
  for I := 0 to High(FCells) do
  begin
    if RowOf[I] < 0 then
      Continue;
    C := FCells[I];
    X := Left0 + ColOf[I] * (CellW + ColGap);
    Y := RY + Max(0, (RH - BlockH) div 2) + RowOf[I] * (CellH + RowGap);
    C.Sounding.SetBounds(X, Y + CellH - 14, CellW, 14);
    C.Caption.SetBounds(X, Y + CellH - 28, CellW, 14);
    if C.Knob <> nil then
      C.Knob.SetBounds(X + 2, Y + 2, CellW - 4, CellH - 28 - 4);
    if C.Toggle <> nil then
      C.Toggle.SetBounds(X + (CellW - 70) div 2, Y + (CellH - 28 - 24) div 2, 70, 24);
    if C.Combo <> nil then
      C.Combo.SetBounds(X + (CellW - 72) div 2, Y + (CellH - 28 - 26) div 2, 72, 26);
  end;
end;

end.
