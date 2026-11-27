// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// PcdControls - what the MzPCD panel draws beyond MzPCF's controls (PcfControls, shared):
//
//   TPcdGroupLabel   a group of knobs named over them: a faint rule across the group, broken
//                    by its name on the unit's colour (MzPcdEditor::paint's LEVELS and
//                    PATTERN PUSHES)
//
// A designed form holds a TJuceLabel as its stand-in, swapped by PcfReplaceControl when
// the panel is built (see MzPcdEditor).

unit PcdControls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, JuceCanvas, JuceUI;

type
  TPcdGroupLabel = class(TJuceControl)
  private
    FColor, FLineColor, FBoxColor: TJuceColor;
    FFontSize: Single;
    FBold: Boolean;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
  published
    // the name (the C++ draws light at 80%)
    property Color: TJuceColor read FColor write FColor;
    // the rule (light at 35%)
    property LineColor: TJuceColor read FLineColor write FLineColor;
    // behind the name: the unit's face (mixer)
    property BoxColor: TJuceColor read FBoxColor write FBoxColor;
    property FontSize: Single read FFontSize write FFontSize;
    property Bold: Boolean read FBold write FBold default True;
  end;

implementation

uses
  PcfControls;

constructor TPcdGroupLabel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 222;
  Height := 12;
  FFontSize := 9;
  FBold := True;
  FColor := PcfWithAlpha(PcfLight, 0.8);
  FLineColor := PcfWithAlpha(PcfLight, 0.35);
  FBoxColor := PcfMixer;
end;

function TPcdGroupLabel.HitTest(X, Y: Single): Boolean;
begin
  Result := False;   // painted on the editor's face in the C++: clicks pass through
end;

procedure TPcdGroupLabel.Paint(Canvas: TJuceCanvas);
var
  Style: TJuceFontStyles;
  W, X, Y: Integer;
begin
  // g.drawHorizontalLine (label.getCentreY(), left, right)
  Canvas.SetColor(FLineColor);
  Canvas.FillRect(JuceRect(0, Height div 2, Width, 1));

  // the name in a box of the unit's colour, 12 px wider than it, centred on the rule
  Style := [];
  if FBold then
    Style := [jfsBold];
  Canvas.SetFont('', FFontSize, Style);
  W := Round(Canvas.TextWidth(Caption)) + 12;
  X := (Width - W) div 2;   // withSizeKeepingCentre
  Y := 0;
  Canvas.SetColor(FBoxColor);
  Canvas.FillRect(JuceRect(X, Y, W, Height));
  Canvas.SetColor(FColor);
  Canvas.DrawText(Caption, JuceRect(X, Y, W, Height), jaCenter, jvaCenter);
end;

end.
