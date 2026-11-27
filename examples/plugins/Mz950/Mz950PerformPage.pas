// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// THE PERFORM TAB: offsets and extras on top of the programme, played live and from MIDI CCs,
// never written to the disk. The Object Pascal counterpart of the Perform half of
// Plugin/Source/PluginEditor.cpp (its knobs, panels and EnvelopeEditor).
//
// Three rows of panels:
//   row 1   FILTER | VELOCITY | LFO           the offsets, cyan
//   row 2   GLIDE & POLYPHONY | WIDE          the extras, violet
//   row 3   VCA ENVELOPE | VCF ENVELOPE       the offsets again, as shapes
//
// Every control is bound to its plug-in parameter (the C++'s APVTS attachments), so the host
// records one gesture per drag and automation moves them; the editor adds MIDI learn to each
// (Mz950Editor). The knobs that are offsets read zero until turned and double-click back to
// it, because zero is "play what is on the floppy".
//
// THE ENVELOPE EDITOR (the C++'s EnvelopeEditor): an ADSR drawn as its own shape, with the
// corners dragged. The parameters behind it are trims - they shift every keygroup at once - so
// what is drawn is the RESULT for one representative keygroup (TMz950.GetEnvelope): its own
// values with the trim added. Dragging moves the trim by however much that keygroup would have
// to move. The horizontal axis is the panel's 0..99 for each stage, not seconds, and every
// stage keeps a sliver of width (MinStage) so a stage of zero can still be grabbed.
unit Mz950PerformPage;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin, JuceUI, Mz950Params, Mz950Plugin, Mz950Look,
  Mz950Controls;

type
  TMzCorner = (ecNone, ecAttack, ecDecay, ecRelease);

  TMzEnvelopeEditor = class(TJuceControl)
  private
    FPlugin: TMz950;
    FFilter: Boolean;
    FBase: TEnvelopeShape;        // the keygroup's own values
    FIndex: array[0..3] of Integer;   // the four trims' parameter indices (A, D, S, R), -1 unknown
    FDragging, FHovering: TMzCorner;
    FGestureOpen: Boolean;
    function Trim(Stage: Integer): Double;
    procedure Shown(out A, D, S, R: Double);
    procedure CornerPoints(out PX, PY: array of Single);
    function Inner: TJuceRect;
    function CornerAt(X, Y: Single): TMzCorner;
    procedure Drags(C: TMzCorner; out AlongX, UpY: Integer);
    procedure TrimTo(Stage, KeygroupValue: Integer; Value: Double);
    procedure Gesture(Stage: Integer; Starting: Boolean);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseMove(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseLeave; override;
    procedure Attached; override;
    procedure Detached; override;
    procedure ParameterChanged(Index: Integer; Normalised: Single); override;
  public
    constructor Create(AOwner: TComponent; APlugin: TMz950; AFilter: Boolean); reintroduce;
    // The programme can change under this window: read the representative keygroup again.
    procedure Poll;
    // Where a corner is drawn (local), for tests: 0 attack, 1 decay, 2 release.
    procedure CornerAtIndex(I: Integer; out X, Y: Single);
  end;

  TMzPerformPage = class(TJuceControl)
  private
    FPlugin: TMz950;
    FTicks: Integer;
    FHeading: TMzLabel;
    FFilterPanel, FLfoPanel, FVelocityPanel, FVcaPanel, FVcfPanel, FGlidePanel, FWidePanel: TMzPanel;
    FKnobs: array of TMzKnob;           // the offsets (and Res, LFO filter), in the C++'s order
    FKnobLabels: array of TMzLabel;
    FKnobGroups: array of string;
    FLfoShape: TMzCombo;
    FLfoShapeLabel: TMzLabel;
    FLfoSync: TMzToggle;
    FLfoDivision: TMzKnob;
    FGlide: TMzToggle;
    FGlideTime: TMzKnob;
    FGlideTimeLabel: TMzLabel;
    FVoices: TMzKnob;
    FVoicesLabel: TMzLabel;
    FWide, FOffset: TMzToggle;
    FWideDetune, FWideSpread: TMzKnob;
    FWideDetuneLabel, FWideSpreadLabel: TMzLabel;
    FVcaEnvelope, FVcfEnvelope: TMzEnvelopeEditor;
    // by parameter index: the control, its caption, and the C++'s tooltip
    FByParam: array[0..NumParams - 1] of TJuceParamControl;
    FCaptionOf: array[0..NumParams - 1] of TMzLabel;
    FTipOf: array[0..NumParams - 1] of string;
    procedure AddKnob(const Id, Name, Group: string; Cc: Integer);
    procedure Register(Index: Integer; C: TJuceParamControl; L: TMzLabel; const Tip: string);
    function MakeExtraKnob(const Id: string; TextBox: Integer; Reset: Single; const Tip: string;
      var L: TMzLabel; const Name: string): TMzKnob;
  protected
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent; APlugin: TMz950); reintroduce;
    procedure Layout;
    // The Rate knob, or the sync division knob in its place, as LFO Sync says.
    procedure ShowLfoSync;
    // The bound control of a parameter (nil if not on this page), its caption and its tip.
    function ControlOf(Index: Integer): TJuceParamControl;
    function CaptionOf(Index: Integer): TMzLabel;
    function TipOf(Index: Integer): string;
    property VcaEnvelope: TMzEnvelopeEditor read FVcaEnvelope;
    property VcfEnvelope: TMzEnvelopeEditor read FVcfEnvelope;
  end;

implementation

uses
  Math;

const
  // The shape's own colours. The graph is an OFFSET control, so it draws in cyan.
  EnvBack = TJuceColor($FF17191D);
  EnvGrid = TJuceColor($FF2B2F36);
  EnvLine = ColPerform;
  EnvHandle = ColText;
  EnvFaint = ColDim;
  EnvText = TJuceColor($FFD6DDE8);

  // How much of the width each stage may take; the sustain gets a fixed plateau.
  StageWidth = 0.26;
  HoldWidth = 0.16;
  HandleSize = 7.0;
  // The shortest a stage is ever DRAWN, as a fraction of its own width.
  MinStage = 0.18;

  StageNames: array[0..3] of string = ('Attack', 'Decay', 'Sustain', 'Release');

{ ------------------------------------------------------------------ TMzEnvelopeEditor }

constructor TMzEnvelopeEditor.Create(AOwner: TComponent; APlugin: TMz950; AFilter: Boolean);
var
  I: Integer;
begin
  inherited Create(AOwner);
  FPlugin := APlugin;
  FFilter := AFilter;
  FDragging := ecNone;
  FHovering := ecNone;
  for I := 0 to 3 do
    FIndex[I] := -1;
  FBase := FPlugin.GetEnvelope(FFilter);
end;

procedure TMzEnvelopeEditor.Attached;
var
  Ed: TJuceEditor;
  I: Integer;
  Prefix: string;
begin
  inherited Attached;
  Ed := Editor;
  if FFilter then Prefix := 'vcf' else Prefix := 'vca';
  for I := 0 to 3 do
    if Ed <> nil then
      FIndex[I] := Ed.FindParameter(Prefix + StageNames[I])
    else
      FIndex[I] := -1;
end;

procedure TMzEnvelopeEditor.Detached;
begin
  // never leave a gesture open
  if FGestureOpen then
    MouseUp(0, 0, []);
  inherited Detached;
end;

procedure TMzEnvelopeEditor.ParameterChanged(Index: Integer; Normalised: Single);
var
  I: Integer;
begin
  for I := 0 to 3 do
    if (Index >= 0) and (Index = FIndex[I]) then
      Invalidate;
end;

procedure TMzEnvelopeEditor.Poll;
var
  Now_: TEnvelopeShape;
begin
  Now_ := FPlugin.GetEnvelope(FFilter);
  if (Now_.Attack <> FBase.Attack) or (Now_.Decay <> FBase.Decay) or (Now_.Sustain <> FBase.Sustain)
    or (Now_.Release <> FBase.Release) or (Now_.Written <> FBase.Written)
    or (Now_.HasRelease <> FBase.HasRelease) then
  begin
    FBase := Now_;
    Invalidate;
  end;
end;

function TMzEnvelopeEditor.Trim(Stage: Integer): Double;
var
  Ed: TJuceEditor;
begin
  Result := 0;
  Ed := Editor;
  if (Ed <> nil) and (FIndex[Stage] >= 0) then
    Result := Ed.ParamToPlain(FIndex[Stage], Ed.ParamNormalised(FIndex[Stage]));
end;

function Clip99(V: Double): Double;
begin
  Result := Max(0.0, Min(99.0, V));
end;

// The stage values as they will actually sound - the keygroup's own plus the trim.
procedure TMzEnvelopeEditor.Shown(out A, D, S, R: Double);
begin
  A := Clip99(FBase.Attack + Trim(0));
  D := Clip99(FBase.Decay + Trim(1));
  S := Clip99(FBase.Sustain + Trim(2));
  if FBase.HasRelease then
    R := Clip99(FBase.Release + Trim(3))
  else
    R := 0;
end;

function TMzEnvelopeEditor.Inner: TJuceRect;
begin
  Result := JuceInset(BoundsRect, HandleSize + 2);
end;

// The corners: 0 attack, 1 decay (and sustain), 2 release, 3 where the plateau ends.
procedure TMzEnvelopeEditor.CornerPoints(out PX, PY: array of Single);
var
  R: TJuceRect;
  A, D, S, Rel, XAttack, XDecay, XHold, XRelease, YSustain: Double;

  function Along(Stored: Double): Double;
  begin
    Result := R.W * StageWidth * Max(MinStage, Stored / 99.0);
  end;

begin
  R := Inner;
  Shown(A, D, S, Rel);
  XAttack := R.X + Along(A);
  XDecay := XAttack + Along(D);
  // With no release stage there is nothing after the sustain, so the plateau runs to the edge.
  if FBase.HasRelease then
  begin
    XHold := XDecay + R.W * HoldWidth;
    XRelease := XHold + Along(Rel);
  end
  else
  begin
    XHold := R.X + R.W;
    XRelease := XHold;
  end;
  YSustain := R.Y + R.H - R.H * (S / 99.0);
  PX[0] := XAttack;  PY[0] := R.Y;
  PX[1] := XDecay;   PY[1] := YSustain;
  PX[2] := XRelease;
  if FBase.HasRelease then PY[2] := R.Y + R.H else PY[2] := YSustain;
  PX[3] := XHold;    PY[3] := YSustain;
end;

procedure TMzEnvelopeEditor.CornerAtIndex(I: Integer; out X, Y: Single);
var
  PX, PY: array[0..3] of Single;
begin
  CornerPoints(PX, PY);
  I := Max(0, Min(3, I));
  X := PX[I];
  Y := PY[I];
end;

// Which stages a corner drags: sideways, then up and down (-1 for none). Sustain has no
// handle of its own: it is the height of the decay corner.
procedure TMzEnvelopeEditor.Drags(C: TMzCorner; out AlongX, UpY: Integer);
begin
  AlongX := -1;
  UpY := -1;
  case C of
    ecAttack: AlongX := 0;
    ecDecay:
      begin
        AlongX := 1;
        UpY := 2;
      end;
    ecRelease: AlongX := 3;
  end;
end;

// The NEAREST corner within reach, not the first one found.
function TMzEnvelopeEditor.CornerAt(X, Y: Single): TMzCorner;
var
  PX, PY: array[0..3] of Single;
  I: Integer;
  Nearest, D: Single;
begin
  CornerPoints(PX, PY);
  Result := ecNone;
  Nearest := HandleSize * 2.2;
  for I := 0 to 2 do
  begin
    if (I = 2) and not FBase.HasRelease then
      Continue;
    D := Sqrt(Sqr(X - PX[I]) + Sqr(Y - PY[I]));
    if D <= Nearest then
    begin
      Nearest := D;
      Result := TMzCorner(I + 1);
    end;
  end;
end;

procedure TMzEnvelopeEditor.Paint(Canvas: TJuceCanvas);
var
  R, Chip: TJuceRect;
  PX, PY: array[0..3] of Single;
  I: Integer;
  Lit: Boolean;
  Size, Wide: Single;
  A, D, S, Rel: Double;
  Text: string;
begin
  Canvas.SetColor(EnvBack);
  Canvas.FillRoundRect(BoundsRect, 3);

  CornerPoints(PX, PY);
  R := Inner;

  // a floor and a ceiling to read the shape against
  Canvas.SetColor(EnvGrid);
  HLine(Canvas, Trunc(R.Y), R.X, R.X + R.W);
  HLine(Canvas, Trunc(R.Y + R.H), R.X, R.X + R.W);

  // the area under the shape, then the shape
  Canvas.SetColor(JuceWithAlpha(EnvLine, 0.14));
  Canvas.BeginPath;
  Canvas.MoveTo(R.X, R.Y + R.H);
  Canvas.LineTo(PX[0], PY[0]);
  Canvas.LineTo(PX[1], PY[1]);
  Canvas.LineTo(PX[3], PY[3]);
  Canvas.LineTo(PX[2], PY[2]);
  Canvas.LineTo(PX[2], R.Y + R.H);
  Canvas.LineTo(R.X, R.Y + R.H);
  Canvas.ClosePath;
  Canvas.FillPath;

  Canvas.SetColor(EnvLine);
  Canvas.BeginPath;
  Canvas.MoveTo(R.X, R.Y + R.H);           // up the attack
  Canvas.LineTo(PX[0], PY[0]);             // down the decay to the sustain
  Canvas.LineTo(PX[1], PY[1]);             // along the sustain
  Canvas.LineTo(PX[3], PY[3]);             // and away
  Canvas.LineTo(PX[2], PY[2]);
  Canvas.StrokePath(2, jljMiter, jlcButt);

  for I := 0 to 2 do
  begin
    if (I = 2) and not FBase.HasRelease then
      Continue;
    Lit := (FDragging = TMzCorner(I + 1)) or ((FDragging = ecNone) and (FHovering = TMzCorner(I + 1)));
    if Lit then Size := HandleSize * 1.25 else Size := HandleSize;
    Canvas.SetColor(EnvHandle);
    Canvas.FillRect(JuceRect(PX[I] - Size / 2, PY[I] - Size / 2, Size, Size));
    if Lit then
    begin
      Canvas.SetColor($FFFFFFFF);
      Canvas.DrawRect(JuceRect(PX[I] - Size / 2, PY[I] - Size / 2, Size, Size), 1);
    end;
  end;

  // An S900 programme never wrote its four filter bytes: still shown and editable, starting
  // from a flat envelope, and it says the shape came from nowhere.
  if not FBase.Written then
  begin
    Canvas.SetColor(EnvFaint);
    UseFont(Canvas, 11);
    Canvas.DrawText('none on the disk - dial in an amount', JuceRect(R.X, R.Y + R.H - 16, R.W, 16), jaRight, jvaCenter);
  end;

  // What the corners read, on a chip of its own at the top right.
  Shown(A, D, S, Rel);
  Text := 'A ' + IntToStr(Round(A)) + '   D ' + IntToStr(Round(D)) + '   S ' + IntToStr(Round(S));
  if FBase.HasRelease then
    Text := Text + '   R ' + IntToStr(Round(Rel));
  UseFont(Canvas, 11.5, True);
  Wide := Round(Canvas.TextWidth(Text));
  Chip := JuceRect(Width - Wide - 20, 5, Wide + 14, 18);
  Canvas.SetColor(JuceWithAlpha(EnvBack, 0.92));
  Canvas.FillRoundRect(Chip, 3);
  Canvas.SetColor(EnvGrid);
  Canvas.DrawRoundRect(Chip, 3, 1);
  Canvas.SetColor(EnvText);
  Canvas.DrawText(Text, Chip, jaCenter, jvaCenter);
end;

procedure TMzEnvelopeEditor.MouseMove(X, Y: Single; Shift: TJuceShiftState);
var
  Was: TMzCorner;
begin
  Was := FHovering;
  FHovering := CornerAt(X, Y);
  if FHovering <> Was then
    Invalidate;
end;

procedure TMzEnvelopeEditor.MouseLeave;
begin
  if FHovering <> ecNone then
  begin
    FHovering := ecNone;
    Invalidate;
  end;
end;

procedure TMzEnvelopeEditor.Gesture(Stage: Integer; Starting: Boolean);
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed = nil) or (Stage < 0) or (FIndex[Stage] < 0) then
    Exit;
  if Starting then
    Ed.BeginGesture(FIndex[Stage])
  else
    Ed.EndGesture(FIndex[Stage]);
end;

procedure TMzEnvelopeEditor.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  AX, UY: Integer;
begin
  if not (jssLeft in Shift) then
    Exit;
  FDragging := CornerAt(X, Y);
  if FDragging = ecNone then
    Exit;
  // One gesture for the whole drag, so a host records it as one move.
  FGestureOpen := True;
  Drags(FDragging, AX, UY);
  Gesture(AX, True);
  Gesture(UY, True);
  Invalidate;
end;

procedure TMzEnvelopeEditor.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  R: TJuceRect;
  PX, PY: array[0..3] of Single;
  PerStage, From: Single;
  AX, UY, Which: Integer;
begin
  if FDragging = ecNone then
    Exit;
  R := Inner;
  if (R.W <= 0) or (R.H <= 0) then
    Exit;
  CornerPoints(PX, PY);
  PerStage := R.W * StageWidth;
  Drags(FDragging, AX, UY);
  // Each corner measures from where the one before it ended, so dragging decay does not fight
  // attack - which is what makes the shape feel jointed rather than elastic.
  if AX >= 0 then
  begin
    case FDragging of
      ecAttack:
        begin
          From := R.X;
          Which := FBase.Attack;
        end;
      ecDecay:
        begin
          From := PX[0];
          Which := FBase.Decay;
        end;
    else
      From := PX[3];
      Which := FBase.Release;
    end;
    TrimTo(AX, Which, (X - From) / PerStage * 99.0);
  end;
  if UY >= 0 then
    TrimTo(UY, FBase.Sustain, (R.Y + R.H - Y) / R.H * 99.0);
  Invalidate;
end;

procedure TMzEnvelopeEditor.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  AX, UY: Integer;
begin
  if not FGestureOpen then
  begin
    FDragging := ecNone;
    Exit;
  end;
  Drags(FDragging, AX, UY);
  Gesture(AX, False);
  Gesture(UY, False);
  FGestureOpen := False;
  FDragging := ecNone;
  Invalidate;
end;

// Double-click a corner to put its stage back to whatever the disk says.
procedure TMzEnvelopeEditor.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
var
  C: TMzCorner;
  AX, UY: Integer;
  Ed: TJuceEditor;

  procedure Zero(Stage: Integer);
  begin
    if (Stage < 0) or (FIndex[Stage] < 0) then
      Exit;
    Ed.BeginGesture(FIndex[Stage]);
    Ed.SetParamNormalised(FIndex[Stage], Ed.ParamFromPlain(FIndex[Stage], 0));
    Ed.EndGesture(FIndex[Stage]);
  end;

begin
  Ed := Editor;
  C := CornerAt(X, Y);
  if (C = ecNone) or (Ed = nil) then
    Exit;
  Drags(C, AX, UY);
  Zero(AX);
  Zero(UY);
  Invalidate;
end;

// Move one stage so the representative keygroup lands on Value, by trimming: what goes in is
// the distance from where the programme already is.
procedure TMzEnvelopeEditor.TrimTo(Stage, KeygroupValue: Integer; Value: Double);
var
  Ed: TJuceEditor;
  Wanted, T: Double;
begin
  Ed := Editor;
  if (Ed = nil) or (Stage < 0) or (FIndex[Stage] < 0) then
    Exit;
  Wanted := Clip99(Value);
  T := Max(-99.0, Min(99.0, Wanted - KeygroupValue));
  Ed.SetParamNormalised(FIndex[Stage], Ed.ParamFromPlain(FIndex[Stage], T));
end;

{ --------------------------------------------------------------------- TMzPerformPage }

constructor TMzPerformPage.Create(AOwner: TComponent; APlugin: TMz950);
begin
  inherited Create(AOwner);
  FPlugin := APlugin;

  // The panels go in first, so they sit BEHIND the controls laid out on top of them. Cyan
  // for the offsets, violet for the extras, with the controller numbers in each corner.
  FFilterPanel := TMzPanel.Create(Self);
  FFilterPanel.Title := 'FILTER';
  FFilterPanel.Note := 'CC 74, 71';
  FLfoPanel := TMzPanel.Create(Self);
  FLfoPanel.Title := 'LFO';
  FLfoPanel.Note := 'CC 113, 76 78 77 114';
  FVelocityPanel := TMzPanel.Create(Self);
  FVelocityPanel.Title := 'VELOCITY';
  FVelocityPanel.Note := 'offsets  -  CC 109 112';
  FVcaPanel := TMzPanel.Create(Self);
  FVcaPanel.Title := 'VCA ENVELOPE';
  FVcaPanel.Note := 'offsets  -  CC 73 75 79 72';
  FVcfPanel := TMzPanel.Create(Self);
  FVcfPanel.Title := 'VCF ENVELOPE';
  FVcfPanel.Note := 'offsets  -  CC 102-105, 70';
  FGlidePanel := TMzPanel.Create(Self);
  FGlidePanel.Title := 'GLIDE & POLYPHONY';
  FGlidePanel.Note := 'not on the S950  -  CC 65 5 106';
  FGlidePanel.Accent := ColExtra;
  FWidePanel := TMzPanel.Create(Self);
  FWidePanel.Title := 'WIDE';
  FWidePanel.Note := 'not on the S950  -  CC 107 108 110 111';
  FWidePanel.Accent := ColExtra;

  // The player's controls. Filter belongs to the SAMPLES, not to the envelope, so it gets its
  // own panel, with Res beside it; the LFO's four after its Shape box; velocity's two.
  AddKnob('vcfCutoff', 'Filter', 'SAMPLE', 74);
  AddKnob('resonance', 'Res', 'SAMPLE', 71);
  AddKnob('vcfAmount', 'Amnt', 'VCF', 70);
  AddKnob('lfoRate', 'Rate', 'LFO', 76);
  AddKnob('lfoDelay', 'Delay', 'LFO', 78);
  AddKnob('lfoDepth', 'Pitch', 'LFO', 77);
  AddKnob('lfoToFilter', 'Filter', 'LFO', 114);
  AddKnob('velToFilter', 'Freq', 'VELOCITY', 109);
  AddKnob('velToLoudness', 'Loudness', 'VELOCITY', 112);

  // The LFO's shape: a box rather than a knob, being four names rather than a value, and
  // outlined violet like the other additions - only Sine is the S950's own.
  FLfoShape := TMzCombo.Create(Self);
  FLfoShape.ParameterId := 'lfoShape';
  FLfoShape.Outline := ColExtra;
  FLfoShapeLabel := TMzLabel.Create(Self);
  FLfoShapeLabel.StyleCaption('Shape');
  Register(PLfoShape, FLfoShape, FLfoShapeLabel,
    'LFO shape. Sine is the S950''s own LFO; saw, square and sample & hold '
    + 'are additions. S&H steps to a new random pitch every cycle, at Rate. '
    + 'A performance setting, never written to the disk. MIDI CC 113.');

  // Tempo sync. Violet, an addition: the S950's LFO knows nothing of tempo.
  FLfoSync := TMzToggle.Create(Self);
  FLfoSync.Caption := 'Sync';
  FLfoSync.Lit := ColExtra;
  FLfoSync.ParameterId := 'lfoSync';
  Register(PLfoSync, FLfoSync, nil,
    'Tempo sync: the LFO runs at a division of the host''s tempo, set '
    + 'by the knob that replaces Rate. With the transport playing it '
    + 'is locked to the grid, so Square and S&H step on the beat and S&H '
    + 'draws the same steps at the same bar every time. Every note rides '
    + 'the one LFO while it is on. Stopped, or in the standalone, it runs '
    + 'at the tempo (120 with no host). MIDI CC 115.');

  FLfoDivision := TMzKnob.Create(Self);
  FLfoDivision.ParameterId := 'lfoSyncDiv';
  FLfoDivision.Accent := ColExtra;
  FLfoDivision.TextBoxWidth := 46;
  FLfoDivision.Visible := False;
  Register(PLfoSyncDiv, FLfoDivision, nil,
    'The LFO''s cycle while synced, from four bars to a sixty-fourth: '
    + '. is dotted, T is a triplet. Bars follow the host''s time signature. '
    + 'MIDI CC 116.');

  // Glide. Not a machine feature, and its panel's note is where that gets said once.
  FGlide := TMzToggle.Create(Self);
  FGlide.Caption := 'Glide';
  FGlide.Lit := ColExtra;
  FGlide.ParameterId := 'glide';
  Register(PGlide, FGlide, nil,
    'Portamento: each note slides in from the last note played in the same keygroup. '
    + 'Crossing into another keygroup does not glide. An addition - the S950 has no '
    + 'glide. MIDI CC 65 switches it (64 and up is on), CC 5 sets the time.');

  FGlideTime := MakeExtraKnob('glideTime', 56, 120,
    'How long a glide takes, whatever the interval. MIDI CC 5: 0 is no glide, 127 is three seconds.',
    FGlideTimeLabel, 'Time');

  FVoices := MakeExtraKnob('voices', 46, 8,
    'Polyphony: the most notes that can sound at once, 1 to 8 - '
    + 'a limit, not a unison stack. At 1 (mono) no chords; a key struck '
    + 'while another is held moves the note there without restarting '
    + 'it, gliding if glide is on, and letting go goes back to the key '
    + 'still held. MIDI CC 106: 0-15 is mono, 112-127 all eight.',
    FVoicesLabel, 'Poly');

  // --- wide
  FWide := TMzToggle.Create(Self);
  FWide.Caption := 'Wide';
  FWide.Lit := ColExtra;
  FWide.ParameterId := 'wide';
  Register(PWide, FWide, nil,
    'Wide: every note as two voices, one detuned flat and leaning left, '
    + 'one sharp by the same amount and leaning right. At most four notes '
    + '- the S950''s eight voices, two to a note. An addition: the S950 '
    + 'has no such thing. MIDI CC 107 (64 and up is on).');

  FOffset := TMzToggle.Create(Self);
  FOffset.Caption := 'Offset';
  FOffset.Lit := ColExtra;
  FOffset.ParameterId := 'wideOffset';
  Register(PWideOffset, FOffset, nil,
    'Start the sharp half 7 ms into the sample, so the pair is not in '
    + 'phase at the attack and does not flange. Off keeps the sharpest '
    + 'attack. MIDI CC 111.');

  FWideDetune := MakeExtraKnob('wideDetune', 56, 10,
    'How far each half is pulled off the note, in cents, one flat and one '
    + 'sharp. 5-15 is a chorus; 25 and up goes sour. MIDI CC 108.',
    FWideDetuneLabel, 'Detune');
  FWideSpread := MakeExtraKnob('wideSpread', 56, 70,
    'How far apart the halves sit in stereo: 0 both centred, 100 hard left '
    + 'and right. As loud either way. MIDI CC 110.',
    FWideSpreadLabel, 'Spread');

  // The two envelopes as shapes rather than as eight knobs.
  FVcaEnvelope := TMzEnvelopeEditor.Create(Self, FPlugin, False);
  FVcaEnvelope.Hint := 'The amplitude envelope, across every keygroup in the programme. '
    + 'Drag the corners; double-click one to put that stage back to what '
    + 'the disk says. MIDI CC 73 attack, 75 decay, 79 sustain, 72 release.';
  FVcfEnvelope := TMzEnvelopeEditor.Create(Self, FPlugin, True);
  FVcfEnvelope.Hint := 'The filter envelope, across every keygroup in the programme. '
    + 'Drag the corners; double-click one to put that stage back to what '
    + 'the disk says. MIDI CC 102 attack, 103 decay, 104 sustain, 105 release.';

  FHeading := TMzLabel.Create(Self);
  FHeading.Caption := 'Offsets and extras on top of the programme, played live and from '
    + 'MIDI CCs. Never written to the disk.';
  FHeading.FontSize := 11.5;
  FHeading.Color := ColDim;
end;

procedure TMzPerformPage.Register(Index: Integer; C: TJuceParamControl; L: TMzLabel; const Tip: string);
begin
  if (Index < 0) or (Index >= NumParams) then
    Exit;
  FByParam[Index] := C;
  FCaptionOf[Index] := L;
  FTipOf[Index] := Tip;
  C.Hint := Tip;
  if L <> nil then
    L.Hint := Tip;
end;

function TMzPerformPage.MakeExtraKnob(const Id: string; TextBox: Integer; Reset: Single;
  const Tip: string; var L: TMzLabel; const Name: string): TMzKnob;
begin
  Result := TMzKnob.Create(Self);
  Result.ParameterId := Id;
  Result.Accent := ColExtra;
  Result.TextBoxWidth := TextBox;
  Result.SetDoubleClickReset(Reset);
  L := TMzLabel.Create(Self);
  L.StyleCaption(Name);
  Register(IndexOfId(Id), Result, L, Tip);
end;

procedure TMzPerformPage.AddKnob(const Id, Name, Group: string; Cc: Integer);
var
  K: TMzKnob;
  L: TMzLabel;
  N: Integer;
  Addition: Boolean;
  LfoNote, Tip: string;
begin
  Addition := (Id = 'resonance') or (Id = 'lfoToFilter');

  // What each LFO knob does past the S950's own range, said where the hand is.
  if Id = 'lfoRate' then
    LfoNote := ' In octaves, so every notch is the same musical step: down six'
      + ' (x1/64, a half-minute sweep) or up eight (x256), into the audio'
      + ' range, where Square or S&H buzzes and screams. 0.02-500 Hz.'
  else if Id = 'lfoDepth' then
    LfoNote := ' Adds only. The S950''s scale to +50 (76 cents); past that it'
      + ' grows to a whole octave at +99, which is not the machine''s.'
  else if Id = 'lfoDelay' then
    LfoNote := ' Both ways: below zero it shortens the programme''s fade-in,'
      + ' to none at all at -99, so short notes get the LFO too.'
  else
    LfoNote := '';

  if Id = 'resonance' then
    Tip := 'Filter resonance: a peak at the cutoff, and past about 92% the filter '
      + 'sings on its own - a sine at the cutoff, following Filter, the envelope '
      + 'and velocity. An addition - the S950''s filter has no resonance, so 0 '
      + 'plays the programme exactly as the machine would. MIDI CC 71.'
  else if Id = 'lfoToFilter' then
    Tip := 'LFO filter depth: moves the cutoff with the LFO''s rate, shape and '
      + 'delay, up to three octaves either way. Square or S&H here is the '
      + 'classic stepped filter. An addition - the S950''s LFO reaches only the '
      + 'pitch - and independent of Pitch. MIDI CC 114.'
  else
  begin
    Tip := Group + ' ' + Name + ', offset from what the disk says, across every keygroup in the programme. '
      + 'Zero plays it as written. MIDI CC ' + IntToStr(Cc) + '.' + LfoNote;
    if Group = 'VELOCITY' then
      Tip := Tip + ' Adds only. Loudness reaches the next note you play rather'
        + ' than one already sounding, because how hard a key was'
        + ' struck is settled when it goes down.';
  end;

  K := TMzKnob.Create(Self);
  K.ParameterId := Id;
  K.TextBoxWidth := 46;
  K.SetDoubleClickReset(0);
  if Addition then
    K.Accent := ColExtra       // violet: not the machine's
  else
    K.Accent := ColPerform;    // cyan: an offset

  L := TMzLabel.Create(Self);
  L.StyleCaption(Name);

  N := Length(FKnobs);
  SetLength(FKnobs, N + 1);
  SetLength(FKnobLabels, N + 1);
  SetLength(FKnobGroups, N + 1);
  FKnobs[N] := K;
  FKnobLabels[N] := L;
  FKnobGroups[N] := Group;
  Register(IndexOfId(Id), K, L, Tip);
end;

function TMzPerformPage.ControlOf(Index: Integer): TJuceParamControl;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := FByParam[Index]
  else
    Result := nil;
end;

function TMzPerformPage.CaptionOf(Index: Integer): TMzLabel;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := FCaptionOf[Index]
  else
    Result := nil;
end;

function TMzPerformPage.TipOf(Index: Integer): string;
begin
  if (Index >= 0) and (Index < NumParams) then
    Result := FTipOf[Index]
  else
    Result := '';
end;

procedure TMzPerformPage.ShowLfoSync;
var
  Ed: TJuceEditor;
  Idx, I: Integer;
  On_: Boolean;
begin
  Ed := Editor;
  On_ := False;
  if Ed <> nil then
  begin
    Idx := Ed.FindParameter('lfoSync');
    On_ := (Idx >= 0) and (Ed.ParamNormalised(Idx) >= 0.5);
  end;
  for I := 0 to High(FKnobs) do
    if FKnobs[I].ParameterId = 'lfoRate' then
      FKnobs[I].Visible := not On_;
  FLfoDivision.Visible := On_;
end;

function TMzPerformPage.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TMzPerformPage.Tick;
begin
  if not Visible then
    Exit;
  Inc(FTicks);
  // the C++ envelopes look again at 20 Hz; sync can be switched by automation or CC 115
  if FTicks mod 2 = 0 then
  begin
    FVcaEnvelope.Poll;
    FVcfEnvelope.Poll;
  end;
  ShowLfoSync;
end;

// The C++ resized's Perform part, in this page's coordinates.
procedure TMzPerformPage.Layout;
const
  CellW = 68;
  CellH = 80;
  Gap = 10;
  Headroom = PanelHeaderHeight + 8;
var
  W, H, Y, Half, LeftW, I, N, AX, AW, CX: Integer;
  Mine: array of Integer;

  // a knob and its caption in one cell, the caption under the value
  procedure PlaceKnob(X, Y, W, H: Integer; K: TMzKnob; L: TMzLabel);
  var
    KW: Integer;
  begin
    KW := Min(W, CellW);
    X := X + (W - KW) div 2;
    L.SetBounds(X, Y + H - 13, KW, 13);
    K.SetBounds(X + 1, Y + 1, KW - 2, H - 13 - 2);
  end;

  // cell i of n equal cells across an area
  procedure Cell(AX, AW, I, N: Integer; out X, W: Integer);
  begin
    X := AX + AW * I div N;
    W := AW div N;
  end;

  procedure PlaceGroup(P: TMzPanel; const Group: string);
  var
    J, K, X, CW: Integer;
  begin
    Mine := nil;
    for J := 0 to High(FKnobs) do
      if FKnobGroups[J] = Group then
      begin
        K := Length(Mine);
        SetLength(Mine, K + 1);
        Mine[K] := J;
      end;
    for J := 0 to High(Mine) do
    begin
      Cell(P.ContentLeft, P.ContentWidth, J, Length(Mine), X, CW);
      PlaceKnob(X, P.ContentTop, CW, P.ContentHeight, FKnobs[Mine[J]], FKnobLabels[Mine[J]]);
    end;
  end;

  procedure PlaceSwitch(P: TMzPanel; I, N, MaxW: Integer; T: TMzToggle);
  var
    X, CW, SW: Integer;
  begin
    Cell(P.ContentLeft, P.ContentWidth, I, N, X, CW);
    SW := Min(CW, MaxW);
    T.SetBounds(X + (CW - SW) div 2, P.ContentTop + (P.ContentHeight - 24) div 2, SW, 24);
  end;

  procedure PlaceIn(P: TMzPanel; I, N: Integer; K: TMzKnob; L: TMzLabel);
  var
    X, CW: Integer;
  begin
    Cell(P.ContentLeft, P.ContentWidth, I, N, X, CW);
    PlaceKnob(X, P.ContentTop, CW, P.ContentHeight, K, L);
  end;

begin
  W := Width;
  H := Height;
  FHeading.SetBounds(0, 0, W, 16);
  Y := 16 + 8;
  Half := (W - Gap) div 2;

  // --- row 1: FILTER and VELOCITY on the left, the LFO on the right
  LeftW := (Half - Gap) div 2;
  FFilterPanel.SetBounds(0, Y, LeftW, CellH + Headroom);
  FVelocityPanel.SetBounds(LeftW + Gap, Y, Half - LeftW - Gap, CellH + Headroom);
  FLfoPanel.SetBounds(Half + Gap, Y, W - Half - Gap, CellH + Headroom);
  PlaceGroup(FFilterPanel, 'SAMPLE');
  PlaceGroup(FVelocityPanel, 'VELOCITY');

  // the LFO's shape, wide enough to read "Square", with the Sync switch under it; then its
  // four knobs in even cells
  AX := FLfoPanel.ContentLeft;
  AW := FLfoPanel.ContentWidth;
  FLfoShapeLabel.SetBounds(AX, FLfoPanel.ContentTop + FLfoPanel.ContentHeight - 13, 80, 13);
  CX := AX + (80 - 76) div 2;
  I := FLfoPanel.ContentTop + (FLfoPanel.ContentHeight - 13 - (24 + 6 + 22)) div 2;
  FLfoShape.SetBounds(CX, I, 76, 24);
  FLfoSync.SetBounds(CX, I + 24 + 6, 76, 22);
  N := 0;
  for I := 0 to High(FKnobs) do
    if FKnobGroups[I] = 'LFO' then
    begin
      PlaceKnob(AX + 80 + (AW - 80) * N div 4, FLfoPanel.ContentTop, (AW - 80) div 4,
        FLfoPanel.ContentHeight, FKnobs[I], FKnobLabels[I]);
      // the division knob sits exactly where Rate does, and shows in its place
      if FKnobs[I].ParameterId = 'lfoRate' then
        FLfoDivision.SetBounds(FKnobs[I].Left, FKnobs[I].Top, FKnobs[I].Width, FKnobs[I].Height);
      Inc(N);
    end;

  // --- row 2: the extras, violet
  Y := Y + CellH + Headroom + Gap;
  FGlidePanel.SetBounds(0, Y, Half, CellH + Headroom);
  FWidePanel.SetBounds(Half + Gap, Y, W - Half - Gap, CellH + Headroom);
  PlaceSwitch(FGlidePanel, 0, 3, 76, FGlide);
  PlaceIn(FGlidePanel, 1, 3, FGlideTime, FGlideTimeLabel);
  PlaceIn(FGlidePanel, 2, 3, FVoices, FVoicesLabel);
  PlaceSwitch(FWidePanel, 0, 4, 76, FWide);
  PlaceIn(FWidePanel, 1, 4, FWideDetune, FWideDetuneLabel);
  PlaceIn(FWidePanel, 2, 4, FWideSpread, FWideSpreadLabel);
  PlaceSwitch(FWidePanel, 3, 4, 112, FOffset);

  // --- row 3: the two envelopes as shapes, the filter's with its Amount beside it; the row
  // takes what is left
  Y := Y + CellH + Headroom + Gap;
  FVcaPanel.SetBounds(0, Y, Half, Max(0, H - Y));
  FVcfPanel.SetBounds(Half + Gap, Y, W - Half - Gap, Max(0, H - Y));
  FVcaEnvelope.SetBounds(FVcaPanel.ContentLeft, FVcaPanel.ContentTop, FVcaPanel.ContentWidth,
    FVcaPanel.ContentHeight);
  AX := FVcfPanel.ContentLeft;
  AW := FVcfPanel.ContentWidth;
  FVcfEnvelope.SetBounds(AX, FVcfPanel.ContentTop, Max(0, AW - CellW - 6), FVcfPanel.ContentHeight);
  // the Amount knob halfway down beside its envelope, not stuck to the top
  for I := 0 to High(FKnobs) do
    if FKnobGroups[I] = 'VCF' then
      PlaceKnob(AX + AW - CellW, FVcfPanel.ContentTop + (FVcfPanel.ContentHeight - CellH) div 2, CellW, CellH,
        FKnobs[I], FKnobLabels[I]);
end;

end.
