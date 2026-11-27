// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcgControls - the one control of the MzPCG panel that MzPCF's PcfControls has no match
// for: the C++ panel's GainDisplay (Source/PluginEditor.cpp). Everything else on the panel
// - the faces, knobs, the pattern number, the MODE and RATE pads - is MzPCF's, as the C++
// MzPCG draws them with the same Look. Depends on the framework's UI units, the PCF's
// controls and patterns, and the engine (PcgEngine) - not on the plug-in.

unit PcgControls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, JuceCanvas, JuceUI, PcgEngine;

type
  //
  // What the gain does over the pattern's sixteen steps: each step's level as a bar, and
  // over them the gain the engine makes of them with the knobs as they are - worked out by
  // playing the engine itself (PcgGainCurve), whenever a knob moves. The step playing is
  // lit, and a meter at the side shows the gain as it is.
  //
  // Show gives it the settings, the step and the gain; on the editor's timer it asks for
  // them with OnFollow (the editor reads the parameters and the plug-in's meters there, as
  // the C++ editor's timerCallback does).
  //
  TPcgGainDisplay = class(TJuceControl)
  private
    FSettings: TPcgSettings;
    FSimulated: Boolean;
    FStep: Integer;
    FGain: Single;
    FCurve: TPcgCurve;
    FColor, FTextColor, FBorderColor, FCurveColor: TJuceColor;
    FOnFollow: TNotifyEvent;
    FSimulations: Integer;
    procedure Simulate;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent); override;
    // The C++ show(): the curve worked out again when a setting it depends on moves (not
    // MIX or LEVEL); a repaint when anything shown changes (the gain by more than 0.002).
    procedure Show(const S: TPcgSettings; AStep: Integer; AGain: Single);
    property Settings: TPcgSettings read FSettings;
    property Step: Integer read FStep;
    property Gain: Single read FGain;
    property Curve: TPcgCurve read FCurve;
    // how many times the curve has been worked out (for the checks)
    property Simulations: Integer read FSimulations;
    property OnFollow: TNotifyEvent read FOnFollow write FOnFollow;
  published
    // the plate
    property Color: TJuceColor read FColor write FColor;
    // the bars and the meter (ledRed)
    property TextColor: TJuceColor read FTextColor write FTextColor;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor;
    // the gain's line (the pointer's orange)
    property CurveColor: TJuceColor read FCurveColor write FCurveColor;
  end;

implementation

uses
  Math, PcfControls;

function Clamp01(V: Single): Single;
begin
  // juce::jlimit(0.0f, 1.0f, v); NaN as 0, where the C++ would draw it as it is
  if not (V > 0) then
    Result := 0
  else if V > 1 then
    Result := 1
  else
    Result := V;
end;

constructor TPcgGainDisplay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 230;
  Height := 66;
  FSettings := TPcgSettings.Defaults;
  FStep := -1;
  FGain := 1;
end;

function TPcgGainDisplay.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TPcgGainDisplay.Tick;
begin
  if Assigned(FOnFollow) then
    FOnFollow(Self);
end;

procedure TPcgGainDisplay.Show(const S: TPcgSettings; AStep: Integer; AGain: Single);
var
  Changed: Boolean;
begin
  Changed := not FSimulated or (S.Pattern <> FSettings.Pattern) or (S.Mode <> FSettings.Mode)
    or (S.Rate <> FSettings.Rate) or (S.Depth <> FSettings.Depth) or (S.Attack <> FSettings.Attack)
    or (S.Hold <> FSettings.Hold) or (S.Decay <> FSettings.Decay);
  FSettings := S;
  if Changed then
    Simulate;
  if Changed or (AStep <> FStep) or (Abs(AGain - FGain) > 0.002) then
  begin
    FStep := AStep;
    FGain := AGain;
    Invalidate;
  end;
end;

procedure TPcgGainDisplay.Simulate;
begin
  FCurve := PcgGainCurve(FSettings);
  FSimulated := True;
  Inc(FSimulations);
end;

procedure TPcgGainDisplay.Paint(Canvas: TJuceCanvas);
var
  R, Inner, Meter: TJuceRect;
  W, Level, H, X, Y, M: Single;
  S, I, Points, K: Integer;
  Bar: TJuceColor;
begin
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, PcfDisplay));
  Canvas.FillRoundRect(R, 2);
  Canvas.SetColor(Pick(FBorderColor, $FF000000));
  Canvas.DrawRoundRect(JuceInset(R, 0.5), 2, 1);

  // inside by 5; the meter 8 wide at the right, 5 from the bars
  Inner := JuceInset(R, 5);
  Meter := JuceRect(Inner.X + Inner.W - 8, Inner.Y, 8, Inner.H);
  Inner.W := Max(0, Inner.W - 13);

  // the steps' levels
  Bar := Pick(FTextColor, PcfLedRed);
  W := Inner.W / PcgStepCount;
  for S := 0 to PcgStepCount - 1 do
  begin
    Level := PcgLevel(FSettings.Pattern, S);
    H := Max(1.5, Inner.H * Level);
    if S = FStep then
      Canvas.SetColor(PcfWithAlpha(Bar, 0.6))
    else if S mod 4 = 0 then
      Canvas.SetColor(PcfWithAlpha(Bar, 0.28))
    else
      Canvas.SetColor(PcfWithAlpha(Bar, 0.18));
    Canvas.FillRect(JuceRect(Inner.X + W * S + 1, Inner.Y + Inner.H - H, W - 2, H));
  end;

  // the gain they make
  if Length(FCurve) > 0 then
  begin
    Points := Max(2, Trunc(Inner.W));
    Canvas.BeginPath;
    for I := 0 to Points - 1 do
    begin
      K := Trunc(I / (Points - 1) * (Length(FCurve) - 1));
      X := Inner.X + I;
      Y := Inner.Y + Inner.H - Inner.H * Clamp01(FCurve[K]);
      if I = 0 then
        Canvas.MoveTo(X, Y)
      else
        Canvas.LineTo(X, Y);
    end;
    Canvas.SetColor(Pick(FCurveColor, PcfPointer));
    Canvas.StrokePath(1.8, jljMiter, jlcButt);
  end;

  // the gain now
  Canvas.SetColor($FF000000);
  Canvas.FillRect(Meter);
  M := Meter.H * Clamp01(FGain);
  Canvas.SetColor(Bar);
  Canvas.FillRect(JuceRect(Meter.X, Meter.Y + Meter.H - M, Meter.W, M));
end;

end.
