// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// THE SYNTH TAB: sounds with no disk. The Object Pascal counterpart of
// Plugin/Source/SynthPage.h/.cpp.
//
// Three oscillators and a drum kit, each knob a number in a recipe (S950SynthPatch's TRecipe).
// Nothing here makes a sound directly: a change re-renders the recipe to a disk
// (TMz950.SetRecipe; the plug-in's housekeeping thread renders it and adopts the result),
// which the plug-in then plays like any other, which the Program tab edits, the set keeps,
// and Save disk as... writes for a real S950. That is why the envelopes, filter and LFO are
// not on this page - they are on the disk, where the Program tab already edits them, and they
// survive a re-render.
//
// Violet throughout, like Glide and Wide: none of this was on the S950.
unit Mz950SynthPage;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin, JuceUI, S950SynthPatch, Mz950Plugin, Mz950Look,
  Mz950Controls;

type
  TMzOsc = record
    Panel: TMzPanel;
    Kind: TMzCombo;
    Level, Octave, Fine, Phase, Intensity, Sweep: TMzKnob;
    LevelL, OctaveL, FineL, PhaseL, IntensityL, SweepL: TMzLabel;
  end;

  TMzSynthPage = class(TJuceControl)
  private
    FPlugin: TMz950;
    FRecipe: TRecipe;
    FShownText: string;        // the recipe as last pulled, to notice it changing under us
    FUpdating: Boolean;
    FTicks: Integer;
    // the top line
    FPresets: TMzCombo;
    FStatus, FHintLabel: TMzLabel;
    // the oscillators
    FOsc: array[0..2] of TMzOsc;
    // the drums
    FDrumPanel: TMzPanel;
    FDrumsOn: TMzToggle;
    FPads: array[0..DrumSlotCount - 1] of TMzButton;
    FDrumOn: TMzToggle;
    FTune, FDecay, FTone, FLevel: TMzKnob;
    FTuneL, FDecayL, FToneL, FLevelL: TMzLabel;
    FSelectedDrum: Integer;
    function MakeKnob(var L: TMzLabel; const Name: string; Lo, Hi, Start: Integer; const Tip: string): TMzKnob;
    function SignedText(Sender: TObject; V: Integer): string;
    function CentsText(Sender: TObject; V: Integer): string;
    procedure PresetChosen(Sender: TObject);
    procedure KindChanged(Sender: TObject);
    procedure Changed(Sender: TObject);
    procedure PadClick(Sender: TObject);
    procedure Relabel;
    procedure Pull;
    procedure Push;
    procedure UpdateStatus;
  protected
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent; APlugin: TMz950); reintroduce;
    // SynthPage::resized, in this page's own coordinates.
    procedure Layout;
    // Choose a drum to shape (its pad).
    procedure ChooseDrum(Slot: Integer);
    // The recipe from the processor (a set restored, say), into the controls.
    procedure Follow;
    property Presets: TMzCombo read FPresets;
    property DrumsSwitch: TMzToggle read FDrumsOn;
    function OscKnob(Osc, Which: Integer): TMzKnob;
    function OscKind(Osc: Integer): TMzCombo;
    function Pad(Slot: Integer): TMzButton;
  end;

implementation

uses
  Math;

function SignedInt(V: Integer): string;
begin
  if V > 0 then
    Result := '+' + IntToStr(V)
  else
    Result := IntToStr(V);
end;

constructor TMzSynthPage.Create(AOwner: TComponent; APlugin: TMz950);
var
  I, K: Integer;
  Names: array of string;
  All: TPresetArray;
begin
  inherited Create(AOwner);
  FPlugin := APlugin;

  for I := 0 to 2 do
  begin
    FOsc[I].Panel := TMzPanel.Create(Self);
    FOsc[I].Panel.Title := 'OSC ' + IntToStr(I + 1);
    FOsc[I].Panel.Note := 'a layer across the keyboard';
    FOsc[I].Panel.Accent := ColExtra;
  end;
  FDrumPanel := TMzPanel.Create(Self);
  FDrumPanel.Title := 'DRUMS';
  FDrumPanel.Note := 'one-shots on General MIDI''s notes';
  FDrumPanel.Accent := ColExtra;

  // --- the top line
  FPresets := TMzCombo.Create(Self);
  FPresets.TextWhenNothingSelected := 'Start from a preset...';
  FPresets.Hint := 'A named starting point for the oscillators. It replaces the three oscillators '
    + 'and brings its own envelopes and filter to the disk for the Program tab. The '
    + 'drums, if they are on, stay exactly as they are.';
  All := S950SynthPatch.Presets;
  SetLength(Names, Length(All));
  for I := 0 to High(All) do
    Names[I] := All[I].Name;
  FPresets.SetItems(Names);
  FPresets.OnChange := PresetChosen;

  FStatus := TMzLabel.Create(Self);
  FStatus.FontSize := 11.5;
  FStatus.Color := ColDim;
  FStatus.Align := jaRight;

  FHintLabel := TMzLabel.Create(Self);
  FHintLabel.Caption := 'The oscillators are mixed into one looped sample - one keygroup, one voice a note; '
    + 'the drums are one-shots. Envelopes, filter and LFO live on the Program tab and '
    + 'survive a re-render.';
  FHintLabel.FontSize := 11;
  FHintLabel.Color := ColDim;

  // --- the oscillators
  SetLength(Names, Ord(okCount));
  for K := 0 to Ord(okCount) - 1 do
    Names[K] := OscKindName(TOscKind(K));
  for I := 0 to 2 do
    with FOsc[I] do
    begin
      Kind := TMzCombo.Create(Self);
      Kind.SetItems(Names);
      Kind.Hint := 'What this layer is drawn from. The plain shapes are summed from their '
        + 'harmonics; FM, ring and the bends are analysed into harmonics - so nothing '
        + 'here aliases, at any key.';
      Kind.OnChange := KindChanged;

      Level := MakeKnob(LevelL, 'Level', 0, 99, 99, 'How loud this oscillator is in the mix.');
      Octave := MakeKnob(OctaveL, 'Octave', -2, 2, 0, 'Transpose, in octaves.');
      Octave.OnIntText := SignedText;
      Fine := MakeKnob(FineL, 'Fine', -50, 50, 0, 'Detune, in cents. Two oscillators a few cents apart '
        + 'is the classic wide sound - the beating is drawn into the loop.');
      Fine.OnIntText := CentsText;
      Phase := MakeKnob(PhaseL, 'Phase', 0, 99, 0, 'Where in its cycle the wave starts. Layers that start '
        + 'apart do not stack into one spike at the attack.');
      Intensity := MakeKnob(IntensityL, 'Shape', 0, 99, 50, 'The wave''s own control: pulse width, FM index, '
        + 'ring amount, bend, skew - or, for a plain shape, how far it softens toward a sine.');
      Sweep := MakeKnob(SweepL, 'Sweep', 0, 99, 0, 'How much of that travels across the loop and back: pulse '
        + 'width modulation, an FM sweep, a filter-like morph - baked into the sample, the way a sampler '
        + 'has always done it. Higher notes sweep faster.');
    end;

  // --- the drums
  FDrumsOn := TMzToggle.Create(Self);
  FDrumsOn.Caption := 'Drums';
  FDrumsOn.Lit := ColExtra;
  FDrumsOn.Hint := 'Put the kit on the disk. The drums take C1 to D#2 on General MIDI''s notes - kick 36, '
    + 'snare 38, clap 39, hats 42 and 46, ride 51, toms 41, 43 and 45 - and the oscillators '
    + 'move up to start at E2, the first key above them.';
  FDrumsOn.OnChange := Changed;

  for I := 0 to DrumSlotCount - 1 do
  begin
    FPads[I] := TMzButton.Create(Self);
    FPads[I].Caption := DrumSlotName(TDrumSlot(I));
    FPads[I].Lit := ColExtra;
    FPads[I].Hint := 'Choose this drum to shape it. Its own switch is beside the knobs.';
    FPads[I].Tag := I;
    FPads[I].OnClick := PadClick;
  end;

  FDrumOn := TMzToggle.Create(Self);
  FDrumOn.Caption := 'On';
  FDrumOn.Lit := ColExtra;
  FDrumOn.Hint := 'Whether this drum is on the disk at all.';
  FDrumOn.OnChange := Changed;

  FTune := MakeKnob(FTuneL, 'Tune', -12, 12, 0, 'Semitones. A one-shot is tuned by changing its rate, '
    + 'so it gets shorter as it goes up.');
  FTune.OnIntText := SignedText;
  FDecay := MakeKnob(FDecayL, 'Decay', 0, 99, 99, 'The keygroup''s VCA decay. 99 plays the whole drum; '
    + 'lower cuts it shorter.');
  FTone := MakeKnob(FToneL, 'Tone', 0, 99, 99, 'The zone''s filter. 99 is wide open.');
  FLevel := MakeKnob(FLevelL, 'Level', -50, 50, 0, 'On top of the kit''s own balance.');
  FLevel.OnIntText := SignedText;

  FRecipe := FPlugin.GetRecipe;
  Pull;
  UpdateStatus;
end;

function TMzSynthPage.MakeKnob(var L: TMzLabel; const Name: string; Lo, Hi, Start: Integer;
  const Tip: string): TMzKnob;
begin
  Result := TMzKnob.Create(Self);
  Result.SetRange(Lo, Hi);
  Result.TextBoxWidth := 56;
  Result.SetIntValue(Start);
  Result.SetDoubleClickReset(Start);
  Result.Hint := Tip;
  Result.Accent := ColExtra;
  Result.OnChange := Changed;
  L := TMzLabel.Create(Self);
  L.StyleCaption(Name);
  L.Hint := Tip;
end;

function TMzSynthPage.SignedText(Sender: TObject; V: Integer): string;
begin
  Result := SignedInt(V);
end;

function TMzSynthPage.CentsText(Sender: TObject; V: Integer): string;
begin
  Result := SignedInt(V) + ' ct';
end;

function TMzSynthPage.OscKnob(Osc, Which: Integer): TMzKnob;
begin
  Result := nil;
  if (Osc < 0) or (Osc > 2) then
    Exit;
  case Which of
    0: Result := FOsc[Osc].Level;
    1: Result := FOsc[Osc].Octave;
    2: Result := FOsc[Osc].Fine;
    3: Result := FOsc[Osc].Phase;
    4: Result := FOsc[Osc].Intensity;
    5: Result := FOsc[Osc].Sweep;
  end;
end;

function TMzSynthPage.OscKind(Osc: Integer): TMzCombo;
begin
  if (Osc >= 0) and (Osc <= 2) then
    Result := FOsc[Osc].Kind
  else
    Result := nil;
end;

function TMzSynthPage.Pad(Slot: Integer): TMzButton;
begin
  if (Slot >= 0) and (Slot < DrumSlotCount) then
    Result := FPads[Slot]
  else
    Result := nil;
end;

procedure TMzSynthPage.PresetChosen(Sender: TObject);
var
  Chosen, I: Integer;
  Next: TRecipe;
  All: TPresetArray;
begin
  Chosen := FPresets.ItemIndex;
  All := S950SynthPatch.Presets;
  if (Chosen < 0) or (Chosen > High(All)) then
    Exit;
  Next := All[Chosen].Recipe;
  // A preset is a sound for the keyboard; the kit is the kit. Drums that are on stay on, with
  // every setting they had, whichever preset the keyboard goes to.
  if FRecipe.DrumsOn then
  begin
    Next.DrumsOn := True;
    for I := 0 to DrumSlotCount - 1 do
      Next.Drums[I] := FRecipe.Drums[I];
  end;
  FRecipe := Next;
  FPresets.SetItemIndex(-1);
  Pull;
  Push;
end;

procedure TMzSynthPage.KindChanged(Sender: TObject);
begin
  Relabel;
  Push;
end;

procedure TMzSynthPage.Changed(Sender: TObject);
begin
  Push;
end;

procedure TMzSynthPage.PadClick(Sender: TObject);
begin
  ChooseDrum(TComponent(Sender).Tag);
end;

procedure TMzSynthPage.ChooseDrum(Slot: Integer);
begin
  FSelectedDrum := Max(0, Min(DrumSlotCount - 1, Slot));
  Pull;
end;

// The two shaping knobs mean different things per kind; say which, and dim the ones a kind
// has no use for.
procedure TMzSynthPage.Relabel;
var
  I: Integer;
  K: TOscKind;
  L: TOscKindLabels;
  On_: Boolean;
begin
  for I := 0 to 2 do
    with FOsc[I] do
    begin
      K := TOscKind(Max(0, Kind.ItemIndex));
      L := OscKindLabels(K);
      On_ := K <> okOff;
      if L.HasIntensity then IntensityL.Caption := UpperCase(L.Intensity) else IntensityL.Caption := 'SHAPE';
      if L.HasSweep then SweepL.Caption := UpperCase(L.Sweep) else SweepL.Caption := 'SWEEP';
      Intensity.Enabled := On_ and L.HasIntensity;
      Sweep.Enabled := On_ and L.HasSweep;
      Level.Enabled := On_;
      Octave.Enabled := On_;
      Fine.Enabled := On_;
      Phase.Enabled := On_;
    end;
end;

procedure TMzSynthPage.Pull;
var
  I: Integer;
  Ds: TDrumSettings;
begin
  FUpdating := True;
  try
    for I := 0 to 2 do
      with FOsc[I] do
      begin
        Kind.SetItemIndex(Ord(FRecipe.Osc[I].Kind));
        Level.SetIntValue(FRecipe.Osc[I].Level);
        Octave.SetIntValue(FRecipe.Osc[I].Octave);
        Fine.SetIntValue(FRecipe.Osc[I].Fine);
        Phase.SetIntValue(FRecipe.Osc[I].Phase);
        Intensity.SetIntValue(FRecipe.Osc[I].Intensity);
        Sweep.SetIntValue(FRecipe.Osc[I].Sweep);
      end;
    Relabel;

    FDrumsOn.SetChecked(FRecipe.DrumsOn);
    for I := 0 to DrumSlotCount - 1 do
    begin
      FPads[I].IsOn := I = FSelectedDrum;
      if FRecipe.Drums[I].On_ then
        FPads[I].TextOff := ColText
      else
        FPads[I].TextOff := ColFaint;
      FPads[I].Enabled := FRecipe.DrumsOn;
      FPads[I].Invalidate;
    end;

    Ds := FRecipe.Drums[FSelectedDrum];
    FDrumOn.SetChecked(Ds.On_);
    FTune.SetIntValue(Ds.Tune);
    FDecay.SetIntValue(Ds.Decay);
    FTone.SetIntValue(Ds.Tone);
    FLevel.SetIntValue(Ds.Level);
    FTune.Enabled := FRecipe.DrumsOn and Ds.On_;
    FDecay.Enabled := FRecipe.DrumsOn and Ds.On_;
    FTone.Enabled := FRecipe.DrumsOn and Ds.On_;
    FLevel.Enabled := FRecipe.DrumsOn and Ds.On_;
    FDrumOn.Enabled := FRecipe.DrumsOn;

    FShownText := ToText(FRecipe);
  finally
    FUpdating := False;
  end;
  Invalidate;
end;

procedure TMzSynthPage.Push;
var
  I: Integer;
begin
  if FUpdating then
    Exit;
  for I := 0 to 2 do
    with FOsc[I] do
    begin
      FRecipe.Osc[I].Kind := TOscKind(Max(0, Kind.ItemIndex));
      FRecipe.Osc[I].Level := Level.IntValue;
      FRecipe.Osc[I].Octave := Octave.IntValue;
      FRecipe.Osc[I].Fine := Fine.IntValue;
      FRecipe.Osc[I].Phase := Phase.IntValue;
      FRecipe.Osc[I].Intensity := Intensity.IntValue;
      FRecipe.Osc[I].Sweep := Sweep.IntValue;
    end;
  FRecipe.DrumsOn := FDrumsOn.IsOn;
  with FRecipe.Drums[FSelectedDrum] do
  begin
    On_ := FDrumOn.IsOn;
    Tune := FTune.IntValue;
    Decay := FDecay.IntValue;
    Tone := FTone.IntValue;
    Level := FLevel.IntValue;
  end;
  FShownText := ToText(FRecipe);
  FPlugin.SetRecipe(FRecipe);
  Pull;                     // the pads and the enables follow
  UpdateStatus;
end;

procedure TMzSynthPage.Follow;
var
  Now_: string;
begin
  // The recipe can change under this page - a set restored by the host - so follow it.
  Now_ := ToText(FPlugin.GetRecipe);
  if (Now_ <> FShownText) and not FPlugin.IsRendering then
  begin
    FRecipe := FPlugin.GetRecipe;
    Pull;
  end;
end;

procedure TMzSynthPage.UpdateStatus;
var
  S: string;
begin
  if FPlugin.IsRendering then
    S := 'rendering...'
  else if FPlugin.GetRenderError <> '' then
    S := FPlugin.GetRenderError
  else if FPlugin.DiskIsSynth then
    S := 'on the disk: ' + FPlugin.GetDiskName + '   -   edit it on the Program tab, or Save disk as...'
  else
    S := 'turn a knob, or pick a preset, and this becomes the loaded disk';
  if S <> FStatus.Caption then
    FStatus.Caption := S;
end;

function TMzSynthPage.NeedsTimer: Boolean;
begin
  Result := True;
end;

// The C++ page's 10 Hz timer: every third tick of the editor's 30.
procedure TMzSynthPage.Tick;
begin
  Inc(FTicks);
  if FTicks mod 3 <> 0 then
    Exit;
  Follow;
  UpdateStatus;
end;

procedure TMzSynthPage.Layout;
const
  Gap = 10;
  Headroom = PanelHeaderHeight + 8;
var
  W, H, Y, FixedH, CellH, Third, I, X, IX, IY, IW, KW, PadW, N, CellW: Integer;

  procedure PlaceKnob(CX, CY, CW, CHt: Integer; K: TMzKnob; L: TMzLabel);
  begin
    L.SetBounds(CX, CY + CHt - 13, CW, 13);
    K.SetBounds(CX + 1, CY + 1, CW - 2, CHt - 13 - 2);
  end;

  // knobIn: a cell's middle, at most 68 wide
  procedure PlaceDrumKnob(Index: Integer; K: TMzKnob; L: TMzLabel);
  var
    CX, KW2: Integer;
  begin
    CX := IX + Index * CellW;
    KW2 := Min(CellW, 68);
    PlaceKnob(CX + (CellW - KW2) div 2, IY, KW2, CellH, K, L);
  end;

begin
  W := Width;
  H := Height;
  FPresets.SetBounds(0, 0, 220, 26);
  FStatus.SetBounds(232, 0, Max(0, W - 232), 26);
  FHintLabel.SetBounds(0, 32, W, 16);
  Y := 56;

  // Three rows of knobs - two in each oscillator and one for the drums - sharing whatever
  // height the page has, at least 76 and at most 96.
  FixedH := (Headroom + 26 + 6) + Gap + (Headroom + 28 + 8);
  CellH := Max(76, Min(96, (H - Y - FixedH) div 3));

  // --- three oscillators side by side, each a box over two rows of three knobs
  Third := (W - 2 * Gap) div 3;
  for I := 0 to 2 do
    with FOsc[I] do
    begin
      X := I * (Third + Gap);
      Panel.SetBounds(X, Y, Third, Headroom + 26 + 6 + 2 * CellH);
      IX := Panel.ContentLeft;
      IY := Panel.ContentTop;
      IW := Panel.ContentWidth;
      Kind.SetBounds(IX, IY, IW, 26);
      Inc(IY, 26 + 6);
      KW := IW div 3;
      PlaceKnob(IX, IY, KW, CellH, Level, LevelL);
      PlaceKnob(IX + KW, IY, KW, CellH, Octave, OctaveL);
      PlaceKnob(IX + 2 * KW, IY, IW - 2 * KW, CellH, Fine, FineL);
      PlaceKnob(IX, IY + CellH, KW, CellH, Phase, PhaseL);
      PlaceKnob(IX + KW, IY + CellH, KW, CellH, Intensity, IntensityL);
      PlaceKnob(IX + 2 * KW, IY + CellH, IW - 2 * KW, CellH, Sweep, SweepL);
    end;

  // --- the drums: the switch and the pads on one line, the chosen drum's knobs under
  Y := Y + Headroom + 26 + 6 + 2 * CellH + Gap;
  FDrumPanel.SetBounds(0, Y, W, Headroom + 28 + 8 + CellH);
  IX := FDrumPanel.ContentLeft;
  IY := FDrumPanel.ContentTop;
  IW := FDrumPanel.ContentWidth;
  FDrumsOn.SetBounds(IX, IY, 84, 28);
  X := IX + 84 + 8;
  PadW := Min(74, (IX + IW - X - 8 * 4) div 9);
  for I := 0 to DrumSlotCount - 1 do
  begin
    FPads[I].SetBounds(X, IY + 2, PadW, 24);
    Inc(X, PadW + 4);
  end;

  // the chosen drum's switch and four knobs, spread evenly across the panel
  IY := IY + 28 + 8;
  N := 5;
  CellW := IW div N;
  FDrumOn.SetBounds(IX + (CellW - 70) div 2, IY + (CellH - 24) div 2, 70, 24);
  PlaceDrumKnob(1, FTune, FTuneL);
  PlaceDrumKnob(2, FDecay, FDecayL);
  PlaceDrumKnob(3, FTone, FToneL);
  PlaceDrumKnob(4, FLevel, FLevelL);
end;

end.
