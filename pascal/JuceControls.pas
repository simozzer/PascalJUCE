{
  JuceControls.pas - ready-made controls for PascalJUCE editors (see JuceUI).

    TJuceKnob    rotary: vertical drag (Shift = fine), double-click = default,
                 wheel; vector style with a value arc, or a filmstrip image
    TJuceSlider  vertical or horizontal fader (classic, or a long-throw
                 hardware fader with a scale)
    TJuceSwitch  2- to 16-position lever or slide switch (choice / bool parameters)
    TJuceButton  momentary or toggle, optional LED (beside or above the caption,
                 lit by the value or by a meter)
    TJuceLed     lamp lit by a parameter, a meter value or code
    TJuceLabel   text
    TJuceLink    clickable text that opens a web page (https)
    TJuceMeter   level bar fed by TJucePlugin.SetMeter (values are linear peaks)
    TJucePanel   fill, gradient, border, title (and a header line) and/or a
                 background image
    TJuceDisplay a text readout set from code
    TJuceComboBox a drop-down of a choice parameter's choices (or its own items)
    TJuceKeyboard a piano keyboard: OnNoteOn / OnNoteOff, keys lit by code
    TJuceScope   an oscilloscope of the plug-in's output (or of what Process
                 sends with TJucePlugin.ScopeWrite), triggered so a steady
                 wave stands still

  Bound controls (ParameterId) open a host gesture for every drag, so hosts
  record one undo step per edit and automation writes correctly. A right
  click raises OnContextMenu (a hook for MIDI learn and the like).

  Every control paints only through TJuceCanvas, so a design-time package can
  draw the same controls on a TCanvas.

  Works with Delphi and Free Pascal (Delphi mode).
}
unit JuceControls;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JuceUI;

type
  TJuceKnobStyle = (jksVector, jksFilmstrip);

  TJuceKnob = class(TJuceParamControl)
  private
    FStyle: TJuceKnobStyle;
    FFilmstripImage: string;
    FFilmstripFrames: Integer;
    FFilmstripHorizontal: Boolean;
    FShowValue: Boolean;
    FBipolar: Boolean;
    FStartAngle, FEndAngle: Single;
    FSensitivity: Integer;
    FFineFactor: Single;
    FArcColor, FTrackColor, FBodyColor, FPointerColor, FTextColor: TJuceColor;
    FDragging, FDragFine: Boolean;
    FDragStartY, FDragStartValue, FDragValue: Single;
    FJumpToClick: Boolean;
    FValueBubble: TJuceValueBubble;
    procedure SetStyle(Value: TJuceKnobStyle);
    procedure SetShowValue(Value: Boolean);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
    function BubbleAnchor: TJuceRect; override;
  public
    constructor Create(AOwner: TComponent); override;
    { Where the knob itself is drawn (inside the caption and value text). }
    function KnobRect: TJuceRect;
    { The value a click at a local point jumps to (JumpToClick): on the ring
      of the value arc, within its sweep; -1 elsewhere. }
    function ValueAtPoint(X, Y: Single): Single;
    property Dragging: Boolean read FDragging;
  published
    property Style: TJuceKnobStyle read FStyle write SetStyle default jksVector;
    { Name given to TJuceEditor.AddImage: frames stacked vertically (or side by side). }
    property FilmstripImage: string read FFilmstripImage write FFilmstripImage;
    property FilmstripFrames: Integer read FFilmstripFrames write FFilmstripFrames default 0;
    property FilmstripHorizontal: Boolean read FFilmstripHorizontal write FFilmstripHorizontal default False;
    property ShowValue: Boolean read FShowValue write SetShowValue default True;
    { Arc from the middle (pan, detune) instead of from the minimum. }
    property Bipolar: Boolean read FBipolar write FBipolar default False;
    { Degrees from 12 o'clock, clockwise. }
    property StartAngle: Single read FStartAngle write FStartAngle;
    property EndAngle: Single read FEndAngle write FEndAngle;
    { Pixels of vertical drag for the whole range. }
    property Sensitivity: Integer read FSensitivity write FSensitivity default 200;
    { Speed factor while Shift is held. }
    property FineFactor: Single read FFineFactor write FFineFactor;
    property ArcColor: TJuceColor read FArcColor write FArcColor default 0;
    property TrackColor: TJuceColor read FTrackColor write FTrackColor default 0;
    property BodyColor: TJuceColor read FBodyColor write FBodyColor default 0;
    property PointerColor: TJuceColor read FPointerColor write FPointerColor default 0;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    { A click on the value arc's ring sets the value there, then drags from it. }
    property JumpToClick: Boolean read FJumpToClick write FJumpToClick default False;
    { The value in a bubble while dragging (and on hover). }
    property ValueBubble: TJuceValueBubble read FValueBubble write FValueBubble default jvbNone;
  end;

  { jslClassic: a groove filled up to the value and a wide thumb.
    jslFader: a long-throw fader as on hardware synths - a narrow slot, a
    scale of Ticks divisions beside it and a flat cap with a centre line. }
  TJuceSliderStyle = (jslClassic, jslFader);

  TJuceSlider = class(TJuceParamControl)
  private
    FOrientation: TJuceOrientation;
    FStyle: TJuceSliderStyle;
    FTicks, FMajorTicks: Integer;
    FShowValue: Boolean;
    FThumbColor, FTrackColor, FFillColor, FTextColor: TJuceColor;
    FDragging: Boolean;
    FDragStart, FDragStartValue, FDragValue: Single;
    FJumpToClick: Boolean;
    FValueBubble: TJuceValueBubble;
    function TrackLength: Single;
    procedure SetStyle(Value: TJuceSliderStyle);
    procedure SetTicks(Value: Integer);
    procedure SetMajorTicks(Value: Integer);
    procedure PaintFader(Canvas: TJuceCanvas);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
    function BubbleAnchor: TJuceRect; override;
  public
    constructor Create(AOwner: TComponent); override;
    { The area the thumb travels in. }
    function TrackRect: TJuceRect;
    { The thumb (fader cap) at the current value. }
    function ThumbRect: TJuceRect;
    { The value at a local point along the track (0..1). }
    function ValueAtPoint(X, Y: Single): Single;
    property Dragging: Boolean read FDragging;
  published
    property Orientation: TJuceOrientation read FOrientation write FOrientation default joVertical;
    property ShowValue: Boolean read FShowValue write FShowValue default True;
    property ThumbColor: TJuceColor read FThumbColor write FThumbColor default 0;
    property TrackColor: TJuceColor read FTrackColor write FTrackColor default 0;
    property FillColor: TJuceColor read FFillColor write FFillColor default 0;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    property Style: TJuceSliderStyle read FStyle write SetStyle default jslClassic;
    { jslFader: divisions of the scale (0..100, 0 = no scale), and every how
      many of them a long mark (0 = none). }
    property Ticks: Integer read FTicks write SetTicks default 10;
    property MajorTicks: Integer read FMajorTicks write SetMajorTicks default 5;
    { A click on the track (not on the thumb) moves the thumb there, then
      drags from it, as JUCE's sliders do; off, a click anywhere drags from
      the current value. }
    property JumpToClick: Boolean read FJumpToClick write FJumpToClick default False;
    { The value in a bubble while dragging (and on hover). }
    property ValueBubble: TJuceValueBubble read FValueBubble write FValueBubble default jvbNone;
  end;

  { jswLever: a lever in a slot, the position names beside it.
    jswSlide: a slide switch as on hardware synths - a narrow slot with a
    mark per position, a small cap, and the position names level with the
    marks (the current one lit). Drag or click to a position. }
  TJuceSwitchStyle = (jswLever, jswSlide);

  TJuceSwitch = class(TJuceParamControl)
  private
    FPositions: Integer;
    FOrientation: TJuceOrientation;
    FStyle: TJuceSwitchStyle;
    FLabels: string;
    FTextColor, FSlotColor, FLeverColor: TJuceColor;
    FDragging: Boolean;
    procedure SetPositions(Value: Integer);
    procedure SetStyle(Value: TJuceSwitchStyle);
    function LabelAt(Index: Integer): string;
    function SlotRect: TJuceRect;
    function PositionAt(X, Y: Single): Integer;
    procedure PaintSlide(Canvas: TJuceCanvas);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    function Position: Integer;
    procedure SetPosition(Index: Integer);
    { jswSlide: the travel of the cap (the first to the last position). }
    function SlideRect: TJuceRect;
  published
    { 2..16. Position 0 is at the left (horizontal) or bottom (vertical). }
    property Positions: Integer read FPositions write SetPositions default 2;
    property Orientation: TJuceOrientation read FOrientation write FOrientation default joHorizontal;
    { One label per position, separated by '|', e.g. 'Sine|Saw|Square'. }
    property Labels: string read FLabels write FLabels;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    property SlotColor: TJuceColor read FSlotColor write FSlotColor default 0;
    property LeverColor: TJuceColor read FLeverColor write FLeverColor default 0;
    property Style: TJuceSwitchStyle read FStyle write SetStyle default jswLever;
  end;

  TJuceButtonMode = (jbmMomentary, jbmToggle);
  { Where a button's LED sits: left of the caption, or above it (centred). }
  TJuceLedPosition = (jlpLeft, jlpTop);

  TJuceButton = class(TJuceParamControl)
  private
    FMode: TJuceButtonMode;
    FShowLed: Boolean;
    FLedColor, FFaceColor, FTextColor, FBorderColor: TJuceColor;
    FLedPosition: TJuceLedPosition;
    FLedMeterIndex: Integer;
    FFlat: Boolean;
    FCornerRadius: Single;
    FMeterLit: Boolean;
    FPressed: Boolean;
    FOnClick: TNotifyEvent;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent); override;
    function IsOn: Boolean;
    { Whether the LED is lit: from the meter if LedMeterIndex is set, else IsOn. }
    function LedLit: Boolean;
    property Pressed: Boolean read FPressed;
  published
    property Mode: TJuceButtonMode read FMode write FMode default jbmToggle;
    property ShowLed: Boolean read FShowLed write FShowLed default True;
    property LedColor: TJuceColor read FLedColor write FLedColor default 0;
    property FaceColor: TJuceColor read FFaceColor write FFaceColor default 0;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    property LedPosition: TJuceLedPosition read FLedPosition write FLedPosition default jlpLeft;
    { >= 0: the LED shows a meter slot (lit from 0.5) that Process publishes
      with SetMeter, instead of the button's value - e.g. a state of the
      DSP that a momentary button changes. }
    property LedMeterIndex: Integer read FLedMeterIndex write FLedMeterIndex default -1;
    { A plain face (no gradient); the border lightens under the mouse. }
    property Flat: Boolean read FFlat write FFlat default False;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor default 0;
    property CornerRadius: Single read FCornerRadius write FCornerRadius;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
  end;

  TJuceLed = class(TJuceParamControl)
  private
    FLit: Boolean;
    FMeterIndex: Integer;
    FThreshold: Single;
    FColor: TJuceColor;
    FMeterLit: Boolean;
    procedure SetLit(Value: Boolean);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent); override;
    function IsOn: Boolean;
  published
    { Lit by code; also lit if bound to a parameter >= 0.5 or a meter >= Threshold. }
    property Lit: Boolean read FLit write SetLit default False;
    property MeterIndex: Integer read FMeterIndex write FMeterIndex default -1;
    property Threshold: Single read FThreshold write FThreshold;
    property Color: TJuceColor read FColor write FColor default 0;
  end;

  TJuceLabel = class(TJuceControl)
  private
    FFontSize: Single;
    FBold: Boolean;
    FAlignment: TJuceAlign;
    FColor: TJuceColor;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
  published
    { 0 = the theme's size. }
    property FontSize: Single read FFontSize write FFontSize;
    property Bold: Boolean read FBold write FBold default False;
    property Alignment: TJuceAlign read FAlignment write FAlignment default jaCenter;
    property Color: TJuceColor read FColor write FColor default 0;
  end;

  { A clickable text, e.g. the project's web page: a click (press and release
    on it) raises OnClick and, if Url is set, asks the host to open it in the
    browser (https:// only; see TJuceEditorBase.OpenUrl). Underlined; darker
    under the mouse and while pressed, as JUCE's HyperlinkButton. }
  TJuceLink = class(TJuceLabel)
  private
    FUrl: string;
    FUnderline: Boolean;
    FPressed: Boolean;
    FOnClick: TNotifyEvent;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseEnter; override;
    procedure MouseLeave; override;
  public
    constructor Create(AOwner: TComponent); override;
    function HitTest(X, Y: Single): Boolean; override;
    { The mouse is down on it. }
    property Pressed: Boolean read FPressed;
  published
    property Url: string read FUrl write FUrl;
    property Underline: Boolean read FUnderline write FUnderline default True;
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
  end;

  TJuceMeter = class(TJuceControl)
  private
    FMeterIndex: Integer;
    FOrientation: TJuceOrientation;
    FMinDb: Single;
    FDecayDb: Single;
    FLevelDb: Single;      { what is shown }
    FPeakDb: Single;       { peak hold }
    FPeakHoldTicks: Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    constructor Create(AOwner: TComponent); override;
    { Feed a linear level directly (Tick does this from the editor's meter). }
    procedure SetLevel(Linear: Single);
    { 0..1 of the bar that is lit. }
    function Fraction: Single;
    property LevelDb: Single read FLevelDb;
  published
    property MeterIndex: Integer read FMeterIndex write FMeterIndex default 0;
    property Orientation: TJuceOrientation read FOrientation write FOrientation default joVertical;
    property MinDb: Single read FMinDb write FMinDb;
    { How fast the bar falls, in dB per tick. }
    property DecayDb: Single read FDecayDb write FDecayDb;
  end;

  TJucePanel = class(TJuceControl)
  private
    FColor, FGradientColor, FBorderColor, FTextColor: TJuceColor;
    FGradientVertical: Boolean;
    FCornerRadius, FBorderWidth: Single;
    FBackgroundImage: string;
    FHeaderHeight: Integer;
    FCaptionAlign: TJuceAlign;
    FCaptionSeparator: Boolean;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    property Color: TJuceColor read FColor write FColor default 0;
    { Non-zero: a gradient from Color to GradientColor. }
    property GradientColor: TJuceColor read FGradientColor write FGradientColor default 0;
    property GradientVertical: Boolean read FGradientVertical write FGradientVertical default True;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor default 0;
    property BorderWidth: Single read FBorderWidth write FBorderWidth;
    property CornerRadius: Single read FCornerRadius write FCornerRadius;
    { Name given to TJuceEditor.AddImage; stretched over the panel. }
    property BackgroundImage: string read FBackgroundImage write FBackgroundImage;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    { The caption's row: 0 = the classic title at the top left (4..24);
      otherwise a header of this height across the whole width. }
    property HeaderHeight: Integer read FHeaderHeight write FHeaderHeight default 0;
    property CaptionAlign: TJuceAlign read FCaptionAlign write FCaptionAlign default jaLeft;
    { A line under the caption, in the border colour. }
    property CaptionSeparator: Boolean read FCaptionSeparator write FCaptionSeparator default False;
  end;

  { A text readout - a step counter, a value, a patch number: Caption on a
    dark plate, in its own font and colour. Set Caption from code. }
  TJuceDisplay = class(TJuceControl)
  private
    FColor, FTextColor, FBorderColor: TJuceColor;
    FFontName: string;
    FFontSize, FCornerRadius, FBorderWidth: Single;
    FBold: Boolean;
    FAlignment: TJuceAlign;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    constructor Create(AOwner: TComponent); override;
  published
    { The plate; 0 = the theme's meter background. }
    property Color: TJuceColor read FColor write FColor default 0;
    { 0 = the theme's accent. }
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor default 0;
    property BorderWidth: Single read FBorderWidth write FBorderWidth;
    property CornerRadius: Single read FCornerRadius write FCornerRadius;
    { '' = the theme's font; e.g. 'Lucida Console' for a fixed-width readout. }
    property FontName: string read FFontName write FFontName;
    { 0 = the theme's size. }
    property FontSize: Single read FFontSize write FFontSize;
    property Bold: Boolean read FBold write FBold default False;
    property Alignment: TJuceAlign read FAlignment write FAlignment default jaCenter;
  end;

  { A drop-down list. Bound to a choice parameter it offers the parameter's
    choices (a patch or preset menu, a mode); unbound, the Items. A click
    opens the menu with the current choice ticked; the wheel steps. }
  TJuceComboBox = class(TJuceParamControl)
  private
    FItems: string;
    FColor, FBorderColor, FTextColor: TJuceColor;
    FFontSize, FCornerRadius: Single;
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    { The choices shown, '|' separated: the parameter's, else Items. }
    function Choices: string;
    function ChoiceCount: Integer;
    function ItemIndex: Integer;
    procedure SetItemIndex(Index: Integer);
    function Text: string;
  published
    { Choices when not bound to a choice parameter, separated by '|'. }
    property Items: string read FItems write FItems;
    property Color: TJuceColor read FColor write FColor default 0;
    property BorderColor: TJuceColor read FBorderColor write FBorderColor default 0;
    property TextColor: TJuceColor read FTextColor write FTextColor default 0;
    { 0 = the theme's size. }
    property FontSize: Single read FFontSize write FFontSize;
    property CornerRadius: Single read FCornerRadius write FCornerRadius;
  end;

  TJuceNoteEvent = procedure(Sender: TJuceControl; Note: Integer; Velocity: Single) of object;

  { A piano keyboard: click and drag to play (OnNoteOn / OnNoteOff), keys lit
    while held, by the mouse or by code (SetNoteLit, e.g. notes the host
    plays). C keys are labelled with their octave. }
  TJuceKeyboard = class(TJuceControl)
  private
    FFirstNote, FLastNote, FOctaveForMiddleC: Integer;
    FShowLabels: Boolean;
    FKeyDownColor, FHoverColor: TJuceColor;
    FLit: array[0..127] of Boolean;
    FMouseNote, FHoverNote: Integer;
    FOnNoteOn, FOnNoteOff: TJuceNoteEvent;
    procedure SetFirstNote(Value: Integer);
    procedure SetLastNote(Value: Integer);
    procedure SetHoverNote(Note: Integer);
    procedure PressNote(Note: Integer; Velocity: Single);
    procedure ReleaseNote;
    function WhiteKeyCount: Integer;
    function VelocityAt(Note: Integer; Y: Single): Single;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseMove(X, Y: Single; Shift: TJuceShiftState); override;
    procedure MouseLeave; override;
    procedure Detached; override;
  public
    constructor Create(AOwner: TComponent); override;
    class function IsBlackNote(Note: Integer): Boolean;
    { Width of a white key: the control's width over the white keys in range. }
    function KeyWidth: Single;
    { Where a key is drawn (local coordinates); W = 0 for a note out of range. }
    function KeyRect(Note: Integer): TJuceRect;
    { The note under a local point, or -1. }
    function NoteAt(X, Y: Single): Integer;
    { Light (or not) a key from code, e.g. for notes played by the host. }
    procedure SetNoteLit(Note: Integer; Lit: Boolean);
    function NoteLit(Note: Integer): Boolean;
    { Lit by code or held with the mouse. }
    function NoteDown(Note: Integer): Boolean;
    { The note the mouse holds, or -1. }
    property MouseNote: Integer read FMouseNote;
  published
    property FirstNote: Integer read FFirstNote write SetFirstNote default 48;
    property LastNote: Integer read FLastNote write SetLastNote default 72;
    { The octave number of middle C (60) in the labels: 3 gives C3, 4 gives C4. }
    property OctaveForMiddleC: Integer read FOctaveForMiddleC write FOctaveForMiddleC default 3;
    property ShowLabels: Boolean read FShowLabels write FShowLabels default True;
    { Over a held key; 0 = the theme's accent at 60%. }
    property KeyDownColor: TJuceColor read FKeyDownColor write FKeyDownColor default 0;
    { Over the key under the mouse; 0 = the theme's accent at 25%. }
    property HoverColor: TJuceColor read FHoverColor write FHoverColor default 0;
    property OnNoteOn: TJuceNoteEvent read FOnNoteOn write FOnNoteOn;
    property OnNoteOff: TJuceNoteEvent read FOnNoteOff write FOnNoteOff;
  end;

  { = JUCE_SCOPE_LEFT, JUCE_SCOPE_RIGHT, JUCE_SCOPE_MIX }
  TJuceScopeChannel = (jscLeft, jscRight, jscMix);
  { Where a sweep starts: where the signal rises (or falls) through
    TriggerLevel, so a steady wave stands still; or free-running (the newest
    samples, as for noise or a drone). }
  TJuceScopeTrigger = (jstRising, jstFalling, jstFree);

  { An oscilloscope. While it is open the plug-in's output is captured after
    each Process call and drawn TimeMs wide, refreshed on the editor's timer;
    it holds the last sweep while no audio arrives. To show another signal,
    see TJucePlugin.ScopeManual / ScopeWrite. }
  TJuceScope = class(TJuceControl)
  private
    FChannel: TJuceScopeChannel;
    FTrigger: TJuceScopeTrigger;
    FTriggerLevel, FTimeMs, FGain, FLineWidth, FCornerRadius: Single;
    FShowGrid: Boolean;
    FGridX, FGridY: Integer;
    FColor, FLineColor, FGridColor: TJuceColor;
    FFeed: TJuceEditor;       { the editor we called ScopeAttach on }
    FRead: array of Single;   { scratch for ScopeRead }
    FSweep: array of Single;  { what is drawn }
    FCount: Integer;          { samples in FSweep }
    FSpan: Integer;           { samples across the width }
    FPhase: Single;           { where the trigger fell between FSweep[0] and [1] }
    FTriggered: Boolean;
    FStamp: Integer;
    FHaveStamp: Boolean;
    procedure Refresh(Force: Boolean);
    function SampleY(V, Mid, Half: Single): Single;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
    procedure Attached; override;
    procedure Detached; override;
  public
    constructor Create(AOwner: TComponent); override;
    { Samples across the width: TimeMs at the plug-in's sample rate (48 kHz
      if unknown), 16..JUCE_SCOPE_MAX_READ div 2 - 1. }
    function SweepLength: Integer;
    { Show Span samples of Samples[0..Count-1] (the newest last), from the
      latest trigger point that leaves a whole sweep (Tick does this with
      the plug-in's feed; call it to show samples of your own). }
    procedure ShowSamples(const Samples: array of Single; Count, Span: Integer);
    { Samples in the sweep shown, and one of them (0 outside). }
    function SampleCount: Integer;
    function Sample(Index: Integer): Single;
    { The sweep shown started at a trigger point. }
    property Triggered: Boolean read FTriggered;
  published
    property Channel: TJuceScopeChannel read FChannel write FChannel default jscMix;
    property Trigger: TJuceScopeTrigger read FTrigger write FTrigger default jstRising;
    { The level the trigger looks for (full scale = 1). }
    property TriggerLevel: Single read FTriggerLevel write FTriggerLevel;
    { Milliseconds across the width (20 = one cycle of a 50 Hz wave). }
    property TimeMs: Single read FTimeMs write FTimeMs;
    { Vertical zoom: 1 = full scale fills the height. }
    property Gain: Single read FGain write FGain;
    property LineWidth: Single read FLineWidth write FLineWidth;
    property ShowGrid: Boolean read FShowGrid write FShowGrid default True;
    { Grid divisions across and down. }
    property GridX: Integer read FGridX write FGridX default 8;
    property GridY: Integer read FGridY write FGridY default 4;
    { The screen; 0 = the theme's meter background. }
    property Color: TJuceColor read FColor write FColor default 0;
    { The trace; 0 = the theme's accent. }
    property LineColor: TJuceColor read FLineColor write FLineColor default 0;
    { 0 = the theme's dim text, faint. }
    property GridColor: TJuceColor read FGridColor write FGridColor default 0;
    property CornerRadius: Single read FCornerRadius write FCornerRadius;
  end;

const
  { Every ready-made control class. The layout loader (JuceLayout) accepts
    these by class name, and the design-time packages mirror exactly these
    (tools/gen_design_props.dpr reads their published properties). }
  JuceControlClasses: array[0..12] of TJuceControlClass =
    (TJuceKnob, TJuceSlider, TJuceSwitch, TJuceButton, TJuceLed, TJuceLabel, TJuceMeter, TJucePanel,
     TJuceDisplay, TJuceComboBox, TJuceKeyboard, TJuceLink, TJuceScope);

  { A TIME control for a scope (a knob or slider not bound to a parameter):
    its 0..1 is logarithmic over this range, so short times are as easy to
    set as long ones. 170 ms is about the longest sweep at 48 kHz. }
  JuceScopeMinTimeMs = 1;
  JuceScopeMaxTimeMs = 170;

{ Registers the control classes with Classes.RegisterClasses (FindClass). }
procedure JuceRegisterControls;

{ A TIME control's 0..1 as milliseconds, and back (both clamped to the range). }
function JuceScopeTimeFromValue(Value: Single): Single;
function JuceScopeValueFromTime(Ms: Single): Single;
{ Milliseconds as a TIME control shows them: '2.5 ms', '40 ms'. }
function JuceScopeTimeText(Ms: Single): string;

implementation

uses
  Math, JucePlugin;

const
  CaptionHeight = 16;
  ValueHeight = 16;

function Clamp01(V: Single): Single;
begin
  if IsNan(V) or (V <= 0) then
    Result := 0
  else if V > 1 then
    Result := 1
  else
    Result := V;
end;


{ ---------------------------------------------------------------------------- }
{ TJuceKnob                                                                    }
{ ---------------------------------------------------------------------------- }

constructor TJuceKnob.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 72;
  Height := 96;
  FShowValue := True;
  FStartAngle := -135;
  FEndAngle := 135;
  FSensitivity := 200;
  FFineFactor := 0.1;
end;

procedure TJuceKnob.SetStyle(Value: TJuceKnobStyle);
begin
  FStyle := Value;
  Invalidate;
end;

procedure TJuceKnob.SetShowValue(Value: Boolean);
begin
  FShowValue := Value;
  Invalidate;
end;

function TJuceKnob.KnobRect: TJuceRect;
var
  Top, Bottom, Size: Single;
begin
  Top := 0;
  Bottom := Height;
  if Caption <> '' then
    Top := CaptionHeight;
  if FShowValue then
    Bottom := Bottom - ValueHeight;
  Size := Max(0, Min(Width, Bottom - Top) - 4);
  Result := JuceRect((Width - Size) / 2, Top + (Bottom - Top - Size) / 2, Size, Size);
end;

procedure TJuceKnob.Paint(Canvas: TJuceCanvas);
var
  R: TJuceRect;
  CX, CY, Radius, A0, A1, AV, AFrom, PX1, PY1, PX2, PY2, Body: Single;
  Img: TJuceImage;
  Frames, Frame: Integer;
  FW, FH: Single;
  Ed: TJuceEditor;
  Th: TJuceTheme;
begin
  Th := Theme;
  R := KnobRect;
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    Canvas.DrawText(Caption, JuceRect(0, 0, Width, CaptionHeight), jaCenter, jvaCenter);
  end;

  Img := nil;
  Ed := Editor;
  if (FStyle = jksFilmstrip) and (Ed <> nil) then
    Img := Ed.FindImage(FFilmstripImage);
  if Img <> nil then
  begin
    Frames := Max(1, FFilmstripFrames);
    Frame := Min(Frames - 1, Round(Clamp01(Value) * (Frames - 1)));
    if FFilmstripHorizontal then
    begin
      FW := Img.Width / Frames;
      FH := Img.Height;
      Canvas.DrawImage(Img, R, JuceRect(Frame * FW, 0, FW, FH), 1);
    end
    else
    begin
      FW := Img.Width;
      FH := Img.Height / Frames;
      Canvas.DrawImage(Img, R, JuceRect(0, Frame * FH, FW, FH), 1);
    end;
  end
  else if R.W > 4 then
  begin
    CX := R.X + R.W / 2;
    CY := R.Y + R.H / 2;
    Radius := R.W / 2 - 2;
    A0 := JuceDegToAngle(FStartAngle);
    A1 := JuceDegToAngle(FEndAngle);
    AV := A0 + Clamp01(Value) * (A1 - A0);

    { track and value arcs }
    Canvas.BeginPath;
    Canvas.AddArc(CX, CY, Radius, Radius, A0, A1, True);
    Canvas.SetColor(Pick(FTrackColor, Th.Track));
    Canvas.StrokePath(4, jljRound, jlcRound);
    if FBipolar then
      AFrom := (A0 + A1) / 2
    else
      AFrom := A0;
    if Abs(AV - AFrom) > 0.001 then
    begin
      Canvas.BeginPath;
      Canvas.AddArc(CX, CY, Radius, Radius, AFrom, AV, True);
      Canvas.SetColor(Pick(FArcColor, Th.Accent));
      Canvas.StrokePath(4, jljRound, jlcRound);
    end;

    { body: a soft radial highlight towards the top left }
    Body := Radius * 0.74;
    Canvas.SetRadialGradient(JuceBrighter(Pick(FBodyColor, Th.KnobBody), 0.25), CX - Body * 0.35, CY - Body * 0.35,
      JuceDarker(Pick(FBodyColor, Th.KnobBody), 0.35), CX + Body * 0.8, CY + Body * 0.8);
    Canvas.FillEllipse(JuceRect(CX - Body, CY - Body, 2 * Body, 2 * Body));
    Canvas.SetColor(JuceDarker(Pick(FBodyColor, Th.KnobBody), 0.6));
    Canvas.DrawEllipse(JuceRect(CX - Body, CY - Body, 2 * Body, 2 * Body), 1);

    { pointer }
    JucePointOnCircle(CX, CY, Body * 0.25, AV, PX1, PY1);
    JucePointOnCircle(CX, CY, Body * 0.88, AV, PX2, PY2);
    Canvas.SetColor(Pick(FPointerColor, Th.KnobPointer));
    Canvas.BeginPath;
    Canvas.MoveTo(PX1, PY1);
    Canvas.LineTo(PX2, PY2);
    Canvas.StrokePath(3, jljRound, jlcRound);
  end;

  if FShowValue then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize - 1, []);
    Canvas.SetColor(Pick(FTextColor, Th.TextDim));
    Canvas.DrawText(ValueText, JuceRect(0, Height - ValueHeight, Width, ValueHeight), jaCenter, jvaCenter);
  end;

  if not Enabled then
  begin
    Canvas.SetColor(JuceWithAlpha(Th.Background, 0.5));
    Canvas.FillRect(BoundsRect);
  end;
end;

{ How long a hover bubble stays: two seconds of editor timer ticks (JUCE's default). }
function HoverTicks(C: TJuceControl): Integer;
var
  Ed: TJuceEditor;
begin
  Ed := C.Editor;
  if (Ed <> nil) and (Ed.TimerHz > 0) then
    Result := Max(1, Min(240, Ed.TimerHz)) * 2
  else
    Result := 60;
end;

function TJuceKnob.ValueAtPoint(X, Y: Single): Single;
var
  R: TJuceRect;
  CX, CY, Radius, D, Ang, A0, A1, T: Single;
begin
  Result := -1;
  R := KnobRect;
  if (R.W <= 4) or IsNan(X) or IsNan(Y) or IsNan(FStartAngle) or IsNan(FEndAngle)
    or (Abs(FStartAngle) > 3600) or (Abs(FEndAngle) > 3600) or (FStartAngle = FEndAngle) then
    Exit;
  CX := R.X + R.W / 2;
  CY := R.Y + R.H / 2;
  Radius := R.W / 2 - 2;
  D := Sqrt(Sqr(X - CX) + Sqr(Y - CY));
  { the ring of the value arc, outside the knob's body }
  if (D < Radius * 0.74) or (D > Radius + 6) then
    Exit;
  Ang := ArcTan2(X - CX, CY - Y); { clockwise from 12 o'clock }
  A0 := JuceDegToAngle(FStartAngle);
  A1 := JuceDegToAngle(FEndAngle);
  if Abs(A1 - A0) >= 2 * Pi then
    T := (Ang - A0) / (A1 - A0)
  else
  begin
    { the angle on the sweep's side of A0, then where it falls along it }
    if A1 > A0 then
      T := (Ang - A0) / (2 * Pi)
    else
      T := (A0 - Ang) / (2 * Pi);
    T := T - Floor(T);
    T := T * 2 * Pi / Abs(A1 - A0);
    if T > 1 then
      Exit; { the gap between the ends }
  end;
  Result := Clamp01(T);
end;

function TJuceKnob.BubbleAnchor: TJuceRect;
begin
  Result := KnobRect;
end;

procedure TJuceKnob.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  V: Single;
begin
  if not (jssLeft in Shift) then
    Exit;
  BeginEdit;
  FDragging := True;
  FDragFine := jssShift in Shift;
  if FJumpToClick then
  begin
    V := ValueAtPoint(X, Y);
    if V >= 0 then
      SetValueFromUser(V);
  end;
  FDragStartY := Y;
  FDragStartValue := Value;
  FDragValue := Value;
  if FValueBubble <> jvbNone then
    ShowBubble;
end;

procedure TJuceKnob.MouseEnter;
begin
  if (FValueBubble = jvbDragAndHover) and not FDragging then
    ShowBubble(HoverTicks(Self));
end;

procedure TJuceKnob.MouseLeave;
begin
  if not FDragging then
    HideBubble;
end;

procedure TJuceKnob.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  Factor: Single;
begin
  if not FDragging then
    Exit;
  if (jssShift in Shift) <> FDragFine then
  begin
    { Shift pressed or released mid-drag: continue from here, no jump. }
    FDragFine := jssShift in Shift;
    FDragStartY := Y;
    FDragStartValue := FDragValue;
  end;
  Factor := 1 / Max(1, FSensitivity);
  if FDragFine then
    Factor := Factor * FFineFactor;
  FDragValue := Clamp01(FDragStartValue + (FDragStartY - Y) * Factor);
  SetValueFromUser(FDragValue);
end;

procedure TJuceKnob.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  EndEdit;
  if (FValueBubble = jvbDragAndHover) and Hovered then
    ShowBubble(HoverTicks(Self))
  else
    HideBubble;
end;

procedure TJuceKnob.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
begin
  ResetToDefault;
end;

function TJuceKnob.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
var
  Step: Single;
begin
  Result := True;
  if DY = 0 then
    Exit;
  Step := 0.2;
  if jssShift in Shift then
    Step := Step * FFineFactor;
  Value := Clamp01(Value + DY * Step);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceSlider                                                                  }
{ ---------------------------------------------------------------------------- }

const
  ThumbLong = 30;
  ThumbShort = 14;

  { The hardware look (jslFader, jswSlide), vertical: the caption sits on the
    bottom of a 28-pixel header, the slot starts 30 pixels down and stops 4
    from the bottom, and the cap's centre travels 9 pixels inside both ends. }
  FaderCaption = 28;
  FaderHeader = 30;
  FaderFoot = 4;
  FaderInset = 9;
  SlideWidth = 36;   { a slide switch's slot column; its names are to the right }

constructor TJuceSlider.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 48;
  Height := 160;
  FShowValue := True;
  FTicks := 10;
  FMajorTicks := 5;
end;

procedure TJuceSlider.SetStyle(Value: TJuceSliderStyle);
begin
  FStyle := Value;
  Invalidate;
end;

procedure TJuceSlider.SetTicks(Value: Integer);
begin
  FTicks := Max(0, Min(100, Value));
  Invalidate;
end;

procedure TJuceSlider.SetMajorTicks(Value: Integer);
begin
  FMajorTicks := Max(0, Min(100, Value));
  Invalidate;
end;

function TJuceSlider.TrackRect: TJuceRect;
var
  Top, Bottom: Single;
begin
  Top := 0;
  Bottom := Height;
  if FStyle = jslFader then
  begin
    if FShowValue then
      Bottom := Bottom - ValueHeight;
    if FOrientation = joVertical then
    begin
      if Caption <> '' then
        Top := FaderHeader;
      Bottom := Bottom - FaderFoot;
      Result := JuceRect(0, Top + FaderInset, Width, Max(0, Bottom - Top - 2 * FaderInset));
    end
    else
    begin
      if Caption <> '' then
        Top := CaptionHeight;
      Result := JuceRect(FaderInset, Top, Max(0, Width - 2 * FaderInset), Max(0, Bottom - Top));
    end;
    Exit;
  end;
  if Caption <> '' then
    Top := CaptionHeight;
  if FShowValue then
    Bottom := Bottom - ValueHeight;
  if FOrientation = joVertical then
    Result := JuceRect(0, Top + ThumbShort / 2 + 2, Width, Max(0, Bottom - Top - ThumbShort - 4))
  else
    Result := JuceRect(ThumbShort / 2 + 2, Top, Max(0, Width - ThumbShort - 4), Bottom - Top);
end;

function TJuceSlider.TrackLength: Single;
var
  R: TJuceRect;
begin
  R := TrackRect;
  if FOrientation = joVertical then
    Result := Max(1, R.H)
  else
    Result := Max(1, R.W);
end;

{ jslFader: scale, slot, cap (the C++ PanelLook of the Mz101 synth, made general). }
procedure TJuceSlider.PaintFader(Canvas: TJuceCanvas);
var
  R, Cap: TJuceRect;
  I: Integer;
  C, Pos, T, Len: Single;
  Major: Boolean;
  Th: TJuceTheme;
  Face: TJuceColor;
begin
  Th := Theme;
  R := TrackRect;
  Face := Pick(FThumbColor, Th.ButtonFace);
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    if FOrientation = joVertical then
      Canvas.DrawFittedText(Caption, JuceRect(0, 0, Width, FaderCaption), jaCenter, jvaBottom)
    else
      Canvas.DrawText(Caption, JuceRect(0, 0, Width, CaptionHeight), jaCenter, jvaCenter);
  end;
  if FOrientation = joVertical then
  begin
    C := Width / 2;
    Len := R.H;
    Pos := R.Y + Len * (1 - Clamp01(Value));
    if FTicks > 0 then
    begin
      Canvas.SetColor(Th.TextDim);
      for I := 0 to FTicks do
      begin
        T := R.Y + Len - Len * I / FTicks;
        Major := (FMajorTicks > 0) and (I mod FMajorTicks = 0);
        if Major then
          Canvas.FillRect(JuceRect(C - 17, T - 0.5, 8, 1))
        else
          Canvas.FillRect(JuceRect(C - 14, T - 0.5, 5, 1));
      end;
    end;
    Canvas.SetColor(Pick(FTrackColor, Th.Track));
    Canvas.FillRoundRect(JuceRect(C - 2.5, R.Y - 6, 5, Len + 12), 2);
    Cap := JuceRect(C - 11, Pos - 8, 22, 16);
    Canvas.SetLinearGradient(Face, 0, Cap.Y, JuceDarker(Face, 0.26), 0, Cap.Y + Cap.H);
    Canvas.FillRoundRect(Cap, 2.5);
    Canvas.SetColor($99000000);
    Canvas.DrawRoundRect(Cap, 2.5, 1);
    Canvas.SetColor(JuceDarker(Face, 0.85));
    Canvas.FillRect(JuceRect(Cap.X + 2, Pos - 1, Cap.W - 4, 2));
  end
  else
  begin
    C := R.Y + R.H / 2;
    Len := R.W;
    Pos := R.X + Len * Clamp01(Value);
    if FTicks > 0 then
    begin
      Canvas.SetColor(Th.TextDim);
      for I := 0 to FTicks do
      begin
        T := R.X + Len * I / FTicks;
        Major := (FMajorTicks > 0) and (I mod FMajorTicks = 0);
        if Major then
          Canvas.FillRect(JuceRect(T - 0.5, C - 17, 1, 8))
        else
          Canvas.FillRect(JuceRect(T - 0.5, C - 14, 1, 5));
      end;
    end;
    Canvas.SetColor(Pick(FTrackColor, Th.Track));
    Canvas.FillRoundRect(JuceRect(R.X - 6, C - 2.5, Len + 12, 5), 2);
    Cap := JuceRect(Pos - 8, C - 11, 16, 22);
    Canvas.SetLinearGradient(Face, Cap.X, 0, JuceDarker(Face, 0.26), Cap.X + Cap.W, 0);
    Canvas.FillRoundRect(Cap, 2.5);
    Canvas.SetColor($99000000);
    Canvas.DrawRoundRect(Cap, 2.5, 1);
    Canvas.SetColor(JuceDarker(Face, 0.85));
    Canvas.FillRect(JuceRect(Pos - 1, Cap.Y + 2, 2, Cap.H - 4));
  end;
  if FShowValue then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize - 1, []);
    Canvas.SetColor(Pick(FTextColor, Th.TextDim));
    Canvas.DrawText(ValueText, JuceRect(0, Height - ValueHeight, Width, ValueHeight), jaCenter, jvaCenter);
  end;
end;

procedure TJuceSlider.Paint(Canvas: TJuceCanvas);
var
  R, Groove, Thumb, FillR: TJuceRect;
  Pos, C: Single;
  Th: TJuceTheme;
  Face: TJuceColor;
begin
  if FStyle = jslFader then
  begin
    PaintFader(Canvas);
    Exit;
  end;
  Th := Theme;
  R := TrackRect;
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    Canvas.DrawText(Caption, JuceRect(0, 0, Width, CaptionHeight), jaCenter, jvaCenter);
  end;
  Face := Pick(FThumbColor, Th.ButtonFace);
  if FOrientation = joVertical then
  begin
    C := R.X + R.W / 2;
    Pos := R.Y + R.H * (1 - Clamp01(Value));
    Groove := JuceRect(C - 3, R.Y, 6, R.H);
    FillR := JuceRect(C - 3, Pos, 6, R.Y + R.H - Pos);
    Thumb := JuceRect(C - ThumbLong / 2, Pos - ThumbShort / 2, ThumbLong, ThumbShort);
    Canvas.SetColor(Pick(FTrackColor, Th.Track));
    Canvas.FillRoundRect(Groove, 3);
    Canvas.SetColor(Pick(FFillColor, Th.Accent));
    Canvas.FillRoundRect(FillR, 3);
    Canvas.SetLinearGradient(JuceBrighter(Face, 0.3), 0, Thumb.Y, JuceDarker(Face, 0.3), 0, Thumb.Y + Thumb.H);
    Canvas.FillRoundRect(Thumb, 3);
    Canvas.SetColor(Th.KnobPointer);
    Canvas.DrawLine(Thumb.X + 4, Pos, Thumb.X + Thumb.W - 4, Pos, 2);
  end
  else
  begin
    C := R.Y + R.H / 2;
    Pos := R.X + R.W * Clamp01(Value);
    Groove := JuceRect(R.X, C - 3, R.W, 6);
    FillR := JuceRect(R.X, C - 3, Pos - R.X, 6);
    Thumb := JuceRect(Pos - ThumbShort / 2, C - ThumbLong / 2, ThumbShort, ThumbLong);
    Canvas.SetColor(Pick(FTrackColor, Th.Track));
    Canvas.FillRoundRect(Groove, 3);
    Canvas.SetColor(Pick(FFillColor, Th.Accent));
    Canvas.FillRoundRect(FillR, 3);
    Canvas.SetLinearGradient(JuceBrighter(Face, 0.3), Thumb.X, 0, JuceDarker(Face, 0.3), Thumb.X + Thumb.W, 0);
    Canvas.FillRoundRect(Thumb, 3);
    Canvas.SetColor(Th.KnobPointer);
    Canvas.DrawLine(Pos, Thumb.Y + 4, Pos, Thumb.Y + Thumb.H - 4, 2);
  end;
  if FShowValue then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize - 1, []);
    Canvas.SetColor(Pick(FTextColor, Th.TextDim));
    Canvas.DrawText(ValueText, JuceRect(0, Height - ValueHeight, Width, ValueHeight), jaCenter, jvaCenter);
  end;
end;

function TJuceSlider.ThumbRect: TJuceRect;
var
  R: TJuceRect;
  Pos, C: Single;
begin
  R := TrackRect;
  if FOrientation = joVertical then
  begin
    C := R.X + R.W / 2;
    Pos := R.Y + R.H * (1 - Clamp01(Value));
    if FStyle = jslFader then
      Result := JuceRect(C - 11, Pos - 8, 22, 16)
    else
      Result := JuceRect(C - ThumbLong / 2, Pos - ThumbShort / 2, ThumbLong, ThumbShort);
  end
  else
  begin
    C := R.Y + R.H / 2;
    Pos := R.X + R.W * Clamp01(Value);
    if FStyle = jslFader then
      Result := JuceRect(Pos - 8, C - 11, 16, 22)
    else
      Result := JuceRect(Pos - ThumbShort / 2, C - ThumbLong / 2, ThumbShort, ThumbLong);
  end;
end;

function TJuceSlider.ValueAtPoint(X, Y: Single): Single;
var
  R: TJuceRect;
begin
  R := TrackRect;
  if FOrientation = joVertical then
    Result := Clamp01((R.Y + R.H - Y) / TrackLength)
  else
    Result := Clamp01((X - R.X) / TrackLength);
end;

function TJuceSlider.BubbleAnchor: TJuceRect;
begin
  Result := ThumbRect;
end;

procedure TJuceSlider.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  BeginEdit;
  FDragging := True;
  { on the track: the thumb jumps to the click; on the thumb it is just picked up }
  if FJumpToClick and not JuceRectContains(ThumbRect, X, Y) then
    SetValueFromUser(ValueAtPoint(X, Y));
  if FOrientation = joVertical then
    FDragStart := Y
  else
    FDragStart := X;
  FDragStartValue := Value;
  FDragValue := Value;
  if FValueBubble <> jvbNone then
    ShowBubble;
end;

procedure TJuceSlider.MouseEnter;
begin
  if (FValueBubble = jvbDragAndHover) and not FDragging then
    ShowBubble(HoverTicks(Self));
end;

procedure TJuceSlider.MouseLeave;
begin
  if not FDragging then
    HideBubble;
end;

procedure TJuceSlider.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  Delta: Single;
begin
  if not FDragging then
    Exit;
  if FOrientation = joVertical then
    Delta := FDragStart - Y
  else
    Delta := X - FDragStart;
  Delta := Delta / TrackLength;
  if jssShift in Shift then
    Delta := Delta * 0.1;
  FDragValue := Clamp01(FDragStartValue + Delta);
  SetValueFromUser(FDragValue);
end;

procedure TJuceSlider.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  EndEdit;
  if (FValueBubble = jvbDragAndHover) and Hovered then
    ShowBubble(HoverTicks(Self))
  else
    HideBubble;
end;

procedure TJuceSlider.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
begin
  ResetToDefault;
end;

function TJuceSlider.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
var
  D: Single;
begin
  Result := True;
  D := DY;
  if FOrientation = joHorizontal then
    D := DY + DX;
  if D = 0 then
    Exit;
  if jssShift in Shift then
    D := D * 0.1;
  Value := Clamp01(Value + D * 0.2);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceSwitch                                                                  }
{ ---------------------------------------------------------------------------- }

constructor TJuceSwitch.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 120;
  Height := 56;
  FPositions := 2;
  FOrientation := joHorizontal;
end;

procedure TJuceSwitch.SetPositions(Value: Integer);
begin
  FPositions := Max(2, Min(16, Value));
  Invalidate;
end;

procedure TJuceSwitch.SetStyle(Value: TJuceSwitchStyle);
begin
  FStyle := Value;
  Invalidate;
end;

function TJuceSwitch.SlideRect: TJuceRect;
var
  Top: Single;
begin
  Top := 0;
  if FOrientation = joVertical then
  begin
    if Caption <> '' then
      Top := FaderHeader;
    Result := JuceRect(0, Top + FaderInset, SlideWidth, Max(0, Height - FaderFoot - Top - 2 * FaderInset));
  end
  else
  begin
    if Caption <> '' then
      Top := CaptionHeight;
    Result := JuceRect(FaderInset + 8, Top, Max(0, Width - 2 * FaderInset - 16), 24);
  end;
end;

procedure TJuceSwitch.PaintSlide(Canvas: TJuceCanvas);
var
  R, Cap: TJuceRect;
  I, P: Integer;
  C, T, Step: Single;
  Th: TJuceTheme;
  Lev: TJuceColor;
begin
  Th := Theme;
  R := SlideRect;
  P := Position;
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    if FOrientation = joVertical then
      Canvas.DrawFittedText(Caption, JuceRect(0, 0, Width, FaderCaption), jaCenter, jvaBottom)
    else
      Canvas.DrawText(Caption, JuceRect(0, 0, Width, CaptionHeight), jaCenter, jvaCenter);
  end;
  Lev := Pick(FLeverColor, Th.ButtonFace);
  Canvas.SetFont(Th.FontName, Th.FontSize - 1, []);
  if FOrientation = joVertical then
  begin
    C := R.X + R.W / 2;
    Step := R.H / (FPositions - 1);
    { a mark per position, the slot, the names level with the marks }
    Canvas.SetColor(Th.TextDim);
    for I := 0 to FPositions - 1 do
      Canvas.FillRect(JuceRect(C - 17, R.Y + R.H - I * Step - 0.5, 8, 1));
    Canvas.SetColor(Pick(FSlotColor, Th.Track));
    Canvas.FillRoundRect(JuceRect(C - 2.5, R.Y - 6, 5, R.H + 12), 2);
    for I := 0 to FPositions - 1 do
    begin
      T := R.Y + R.H - I * Step;
      if I = P then
        Canvas.SetColor(Pick(FTextColor, Th.Text))
      else
        Canvas.SetColor(Th.TextDim);
      Canvas.DrawText(LabelAt(I), JuceRect(R.X + R.W - 4, T - 7, Max(0, Width - (R.X + R.W) + 4), 14), jaLeft, jvaCenter);
    end;
    T := R.Y + R.H - P * Step;
    Cap := JuceRect(C - 8, T - 7, 16, 14);
    Canvas.SetColor(Lev);
    Canvas.FillRoundRect(Cap, 2);
    Canvas.SetColor(JuceBrighter(Lev, 0.24));
    Canvas.DrawRoundRect(Cap, 2, 1);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    Canvas.FillRect(JuceRect(Cap.X + 3, T - 0.75, Cap.W - 6, 1.5));
  end
  else
  begin
    C := R.Y + R.H / 2;
    Step := R.W / (FPositions - 1);
    Canvas.SetColor(Th.TextDim);
    for I := 0 to FPositions - 1 do
      Canvas.FillRect(JuceRect(R.X + I * Step - 0.5, C - 17, 1, 8));
    Canvas.SetColor(Pick(FSlotColor, Th.Track));
    Canvas.FillRoundRect(JuceRect(R.X - 6, C - 2.5, R.W + 12, 5), 2);
    for I := 0 to FPositions - 1 do
    begin
      T := R.X + I * Step;
      if I = P then
        Canvas.SetColor(Pick(FTextColor, Th.Text))
      else
        Canvas.SetColor(Th.TextDim);
      Canvas.DrawText(LabelAt(I), JuceRect(T - Step / 2, R.Y + R.H, Step, Max(0, Height - (R.Y + R.H))), jaCenter, jvaTop);
    end;
    T := R.X + P * Step;
    Cap := JuceRect(T - 7, C - 8, 14, 16);
    Canvas.SetColor(Lev);
    Canvas.FillRoundRect(Cap, 2);
    Canvas.SetColor(JuceBrighter(Lev, 0.24));
    Canvas.DrawRoundRect(Cap, 2, 1);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    Canvas.FillRect(JuceRect(T - 0.75, Cap.Y + 3, 1.5, Cap.H - 6));
  end;
end;

function TJuceSwitch.LabelAt(Index: Integer): string;
var
  S: string;
  I, P: Integer;
begin
  S := FLabels;
  for I := 1 to Index do
  begin
    P := Pos('|', S);
    if P = 0 then
    begin
      S := '';
      Break;
    end;
    Delete(S, 1, P);
  end;
  P := Pos('|', S);
  if P > 0 then
    S := Copy(S, 1, P - 1);
  Result := S;
end;

function TJuceSwitch.Position: Integer;
begin
  Result := Max(0, Min(FPositions - 1, Round(Clamp01(Value) * (FPositions - 1))));
end;

procedure TJuceSwitch.SetPosition(Index: Integer);
begin
  Index := Max(0, Min(FPositions - 1, Index));
  Value := Index / (FPositions - 1);
end;

{ The lever slot; labels sit beside it (below a horizontal switch, to the
  right of a vertical one). }
function TJuceSwitch.SlotRect: TJuceRect;
var
  Top: Single;
begin
  Top := 0;
  if Caption <> '' then
    Top := CaptionHeight;
  if FOrientation = joHorizontal then
    Result := JuceRect(8, Top + 2, Width - 16, 18)
  else
    Result := JuceRect(4, Top + 4, 18, Height - Top - 8);
end;

function TJuceSwitch.PositionAt(X, Y: Single): Integer;
var
  R: TJuceRect;
  T: Single;
begin
  if FStyle = jswSlide then
  begin
    { the nearest position along the travel }
    R := SlideRect;
    if FOrientation = joHorizontal then
      T := (X - R.X) / Max(1, R.W)
    else
      T := (R.Y + R.H - Y) / Max(1, R.H);
    Result := Max(0, Min(FPositions - 1, Round(Clamp01(T) * (FPositions - 1))));
    Exit;
  end;
  R := SlotRect;
  if FOrientation = joHorizontal then
    T := (X - R.X) / Max(1, R.W)
  else
    T := 1 - (Y - R.Y) / Max(1, R.H);
  Result := Max(0, Min(FPositions - 1, Trunc(Clamp01(T) * FPositions - 1e-6)));
  if T >= 1 then
    Result := FPositions - 1;
end;

procedure TJuceSwitch.Paint(Canvas: TJuceCanvas);
var
  R, Lever, Cell: TJuceRect;
  I, P: Integer;
  Th: TJuceTheme;
  Step: Single;
  Lev: TJuceColor;
begin
  if FStyle = jswSlide then
  begin
    PaintSlide(Canvas);
    Exit;
  end;
  Th := Theme;
  R := SlotRect;
  P := Position;
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    Canvas.DrawText(Caption, JuceRect(0, 0, Width, CaptionHeight), jaCenter, jvaCenter);
  end;
  Canvas.SetColor(Pick(FSlotColor, Th.Track));
  Canvas.FillRoundRect(R, 4);
  Lev := Pick(FLeverColor, Th.Accent);
  Canvas.SetFont(Th.FontName, Th.FontSize - 1, []);
  if FOrientation = joHorizontal then
  begin
    Step := R.W / FPositions;
    Lever := JuceRect(R.X + P * Step + 2, R.Y + 2, Step - 4, R.H - 4);
    for I := 0 to FPositions - 1 do
    begin
      Cell := JuceRect(R.X + I * Step, R.Y + R.H + 2, Step, Height - (R.Y + R.H + 2));
      if I = P then
        Canvas.SetColor(Pick(FTextColor, Th.Text))
      else
        Canvas.SetColor(Th.TextDim);
      Canvas.DrawText(LabelAt(I), Cell, jaCenter, jvaTop);
    end;
  end
  else
  begin
    Step := R.H / FPositions;
    Lever := JuceRect(R.X + 2, R.Y + (FPositions - 1 - P) * Step + 2, R.W - 4, Step - 4);
    for I := 0 to FPositions - 1 do
    begin
      Cell := JuceRect(R.X + R.W + 6, R.Y + (FPositions - 1 - I) * Step, Width - (R.X + R.W + 6), Step);
      if I = P then
        Canvas.SetColor(Pick(FTextColor, Th.Text))
      else
        Canvas.SetColor(Th.TextDim);
      Canvas.DrawText(LabelAt(I), Cell, jaLeft, jvaCenter);
    end;
  end;
  Canvas.SetLinearGradient(JuceBrighter(Lev, 0.25), Lever.X, Lever.Y, JuceDarker(Lev, 0.25), Lever.X, Lever.Y + Lever.H);
  Canvas.FillRoundRect(Lever, 3);
end;

procedure TJuceSwitch.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  R: TJuceRect;
begin
  if not (jssLeft in Shift) then
    Exit;
  if FStyle = jswSlide then
  begin
    { one gesture from the click to the release, however far it slides }
    BeginEdit;
    FDragging := True;
    SetValueFromUser(PositionAt(X, Y) / (FPositions - 1));
    Exit;
  end;
  R := SlotRect;
  if JuceRectContains(R, X, Y) then
    SetPosition(PositionAt(X, Y))
  else
    SetPosition((Position + 1) mod FPositions); { a click on the labels steps through }
end;

procedure TJuceSwitch.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
begin
  if FDragging then
    SetValueFromUser(PositionAt(X, Y) / (FPositions - 1));
end;

procedure TJuceSwitch.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  if not FDragging then
    Exit;
  FDragging := False;
  EndEdit;
end;

function TJuceSwitch.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
begin
  Result := True;
  if DY > 0 then
    SetPosition(Position + 1)
  else if DY < 0 then
    SetPosition(Position - 1);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceButton                                                                  }
{ ---------------------------------------------------------------------------- }

constructor TJuceButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 72;
  Height := 28;
  FMode := jbmToggle;
  FShowLed := True;
  FLedMeterIndex := -1;
  FCornerRadius := 4;
end;

function TJuceButton.IsOn: Boolean;
begin
  Result := Value >= 0.5;
end;

function TJuceButton.LedLit: Boolean;
begin
  if FLedMeterIndex >= 0 then
    Result := FMeterLit
  else
    Result := IsOn;
end;

function TJuceButton.NeedsTimer: Boolean;
begin
  Result := FShowLed and (FLedMeterIndex >= 0);
end;

procedure TJuceButton.Tick;
var
  Ed: TJuceEditor;
  LitNow: Boolean;
begin
  Ed := Editor;
  if (Ed = nil) or (FLedMeterIndex < 0) then
    Exit;
  LitNow := Ed.Meter(FLedMeterIndex) >= 0.5;
  if LitNow <> FMeterLit then
  begin
    FMeterLit := LitNow;
    Invalidate;
  end;
end;

procedure TJuceButton.Paint(Canvas: TJuceCanvas);
var
  R, TextR: TJuceRect;
  Face, Led: TJuceColor;
  Th: TJuceTheme;
begin
  Th := Theme;
  R := JuceInset(BoundsRect, 1);
  Face := Pick(FFaceColor, Th.ButtonFace);
  if FFlat then
  begin
    if FPressed then
      Face := JuceDarker(Face, 0.45);
    Canvas.SetColor(Face);
    Canvas.FillRoundRect(R, FCornerRadius);
    if Hovered then
      Canvas.SetColor(Th.TextDim)
    else
      Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
    Canvas.DrawRoundRect(R, FCornerRadius, 1);
  end
  else
  begin
    if FPressed then
      Face := JuceDarker(Face, 0.25)
    else if Hovered then
      Face := JuceBrighter(Face, 0.08);
    Canvas.SetLinearGradient(JuceBrighter(Face, 0.15), 0, R.Y, JuceDarker(Face, 0.2), 0, R.Y + R.H);
    Canvas.FillRoundRect(R, FCornerRadius);
    Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
    Canvas.DrawRoundRect(R, FCornerRadius, 1);
  end;
  TextR := R;
  if FShowLed then
  begin
    Led := Pick(FLedColor, Th.LedOn);
    if not LedLit then
      Led := JuceDarker(Led, 0.7);
    Canvas.SetColor(Led);
    if FLedPosition = jlpTop then
      Canvas.FillEllipse(JuceRect(R.X + R.W / 2 - 3, R.Y + 4, 6, 6))
    else
    begin
      Canvas.FillEllipse(JuceRect(R.X + 7, R.Y + R.H / 2 - 4, 8, 8));
      TextR := JuceRect(R.X + 18, R.Y, Max(0, R.W - 20), R.H);
    end;
  end;
  Canvas.SetFont(Th.FontName, Th.FontSize, [jfsBold]);
  Canvas.SetColor(Pick(FTextColor, Th.Text));
  Canvas.DrawText(Caption, TextR, jaCenter, jvaCenter);
end;

procedure TJuceButton.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  FPressed := True;
  if FMode = jbmMomentary then
  begin
    BeginEdit;
    SetValueFromUser(1);
  end;
  Invalidate;
end;

procedure TJuceButton.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  Inside: Boolean;
begin
  if not FPressed then
    Exit;
  FPressed := False;
  Inside := HitTest(X, Y);
  if FMode = jbmMomentary then
  begin
    SetValueFromUser(0);
    EndEdit;
  end
  else if Inside then
  begin
    if IsOn then
      Value := 0
    else
      Value := 1;
  end;
  Invalidate;
  if Inside and Assigned(FOnClick) then
    FOnClick(Self);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceLed                                                                     }
{ ---------------------------------------------------------------------------- }

constructor TJuceLed.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 16;
  Height := 16;
  FMeterIndex := -1;
  FThreshold := 0.5;
end;

procedure TJuceLed.SetLit(Value: Boolean);
begin
  if Value = FLit then
    Exit;
  FLit := Value;
  Invalidate;
end;

function TJuceLed.IsOn: Boolean;
begin
  Result := FLit or FMeterLit or (IsBound and (Value >= 0.5));
end;

function TJuceLed.NeedsTimer: Boolean;
begin
  Result := FMeterIndex >= 0;
end;

procedure TJuceLed.Tick;
var
  Ed: TJuceEditor;
  LitNow: Boolean;
begin
  Ed := Editor;
  if (Ed = nil) or (FMeterIndex < 0) then
    Exit;
  LitNow := Ed.Meter(FMeterIndex) >= FThreshold;
  if LitNow <> FMeterLit then
  begin
    FMeterLit := LitNow;
    Invalidate;
  end;
end;

procedure TJuceLed.Paint(Canvas: TJuceCanvas);
var
  C: TJuceColor;
  D, CX, CY: Single;
begin
  C := Pick(FColor, Theme.LedOn);
  D := Min(Width, Height) - 2;
  CX := Width / 2;
  CY := Height / 2;
  if IsOn then
  begin
    Canvas.SetRadialGradient(JuceBrighter(C, 0.5), CX - D * 0.15, CY - D * 0.15, C, CX + D / 2, CY + D / 2);
  end
  else
    Canvas.SetColor(JuceDarker(C, 0.72));
  Canvas.FillEllipse(JuceRect(CX - D / 2, CY - D / 2, D, D));
  Canvas.SetColor($80000000);
  Canvas.DrawEllipse(JuceRect(CX - D / 2, CY - D / 2, D, D), 1);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceLabel                                                                   }
{ ---------------------------------------------------------------------------- }

constructor TJuceLabel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 100;
  Height := 20;
  FAlignment := jaCenter;
end;

function TJuceLabel.HitTest(X, Y: Single): Boolean;
begin
  Result := False; { clicks go through to what is underneath }
end;

procedure TJuceLabel.Paint(Canvas: TJuceCanvas);
var
  Size: Single;
  Style: TJuceFontStyles;
begin
  Size := FFontSize;
  if Size <= 0 then
    Size := Theme.FontSize;
  Style := [];
  if FBold then
    Include(Style, jfsBold);
  Canvas.SetFont(Theme.FontName, Size, Style);
  Canvas.SetColor(Pick(FColor, Theme.Text));
  Canvas.DrawText(Caption, BoundsRect, FAlignment, jvaCenter);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceLink                                                                    }
{ ---------------------------------------------------------------------------- }

constructor TJuceLink.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FUnderline := True;
end;

function TJuceLink.HitTest(X, Y: Single): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < Width) and (Y < Height);
end;

procedure TJuceLink.Paint(Canvas: TJuceCanvas);
var
  Size: Single;
  Style: TJuceFontStyles;
  C: TJuceColor;
begin
  Size := FFontSize;
  if Size <= 0 then
    Size := Theme.FontSize;
  Style := [];
  if FBold then
    Include(Style, jfsBold);
  if FUnderline then
    Include(Style, jfsUnderline);
  C := Pick(FColor, Theme.Link);
  { JUCE's HyperlinkButton: darker(0.4) under the mouse, darker(1.3) pressed }
  if not Enabled then
    C := JuceWithAlpha(C, 0.4 * (C shr 24) / 255)
  else if FPressed and Hovered then
    C := JuceDarker(C, 0.565)
  else if Hovered then
    C := JuceDarker(C, 0.286);
  Canvas.SetFont(Theme.FontName, Size, Style);
  Canvas.SetColor(C);
  Canvas.DrawText(Caption, JuceRect(1, 0, Max(0, Width - 2), Height), FAlignment, jvaCenter);
end;

procedure TJuceLink.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
  if not (jssLeft in Shift) then
    Exit;
  FPressed := True;
  Invalidate;
end;

procedure TJuceLink.MouseUp(X, Y: Single; Shift: TJuceShiftState);
var
  Ed: TJuceEditor;
begin
  if not FPressed then
    Exit;
  FPressed := False;
  Invalidate;
  if not HitTest(X, Y) then
    Exit; { released elsewhere: no click }
  Ed := Editor;
  { the host opens the page only now, while it delivers the click }
  if (Ed <> nil) and (FUrl <> '') then
    Ed.OpenUrl(FUrl);
  if Assigned(FOnClick) then
    FOnClick(Self);
end;

procedure TJuceLink.MouseEnter;
begin
  Invalidate;
end;

procedure TJuceLink.MouseLeave;
begin
  Invalidate;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceMeter                                                                   }
{ ---------------------------------------------------------------------------- }

constructor TJuceMeter.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 16;
  Height := 120;
  FMinDb := -60;
  FDecayDb := 1.5;
  FLevelDb := -1000;
  FPeakDb := -1000;
end;

function TJuceMeter.NeedsTimer: Boolean;
begin
  Result := FMeterIndex >= 0;
end;

procedure TJuceMeter.SetLevel(Linear: Single);
var
  Db: Single;
begin
  if IsNan(Linear) or (Linear <= 1.0E-6) then
    Db := -1000
  else
    Db := 20 * Log10(Min(Linear, 1000));
  if Db >= FLevelDb then
    FLevelDb := Db
  else
    FLevelDb := Max(Db, FLevelDb - FDecayDb);
  if FLevelDb >= FPeakDb then
  begin
    FPeakDb := FLevelDb;
    FPeakHoldTicks := 30;
  end
  else if FPeakHoldTicks > 0 then
    Dec(FPeakHoldTicks)
  else
    FPeakDb := Max(FLevelDb, FPeakDb - FDecayDb);
end;

function TJuceMeter.Fraction: Single;
begin
  if FMinDb >= 0 then
    Result := 0
  else
    Result := Clamp01((FLevelDb - FMinDb) / -FMinDb);
end;

procedure TJuceMeter.Tick;
var
  Ed: TJuceEditor;
  OldLevel, OldPeak: Single;
begin
  Ed := Editor;
  if (Ed = nil) or (FMeterIndex < 0) then
    Exit;
  OldLevel := FLevelDb;
  OldPeak := FPeakDb;
  SetLevel(Ed.Meter(FMeterIndex));
  if (Abs(OldLevel - FLevelDb) > 0.05) or (Abs(OldPeak - FPeakDb) > 0.05) then
    Invalidate;
end;

procedure TJuceMeter.Paint(Canvas: TJuceCanvas);
var
  R, Lit: TJuceRect;
  F, PeakF: Single;
  Th: TJuceTheme;
begin
  Th := Theme;
  R := BoundsRect;
  Canvas.SetColor(Th.MeterBack);
  Canvas.FillRoundRect(R, 2);
  R := JuceInset(R, 2);
  F := Fraction;
  if FMinDb < 0 then
    PeakF := Clamp01((FPeakDb - FMinDb) / -FMinDb)
  else
    PeakF := 0;
  Canvas.SaveState;
  try
    if FOrientation = joVertical then
    begin
      Lit := JuceRect(R.X, R.Y + R.H * (1 - F), R.W, R.H * F);
      if Canvas.ClipRect(Lit) then
      begin
        Canvas.SetLinearGradient(Th.MeterHigh, 0, R.Y, Th.MeterLow, 0, R.Y + R.H);
        Canvas.FillRect(R);
      end;
    end
    else
    begin
      Lit := JuceRect(R.X, R.Y, R.W * F, R.H);
      if Canvas.ClipRect(Lit) then
      begin
        Canvas.SetLinearGradient(Th.MeterLow, R.X, 0, Th.MeterHigh, R.X + R.W, 0);
        Canvas.FillRect(R);
      end;
    end;
  finally
    Canvas.RestoreState;
  end;
  if PeakF > 0 then
  begin
    Canvas.SetColor(Th.MeterMid);
    if FOrientation = joVertical then
      Canvas.FillRect(JuceRect(R.X, R.Y + R.H * (1 - PeakF), R.W, 2))
    else
      Canvas.FillRect(JuceRect(R.X + R.W * PeakF - 2, R.Y, 2, R.H));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJucePanel                                                                   }
{ ---------------------------------------------------------------------------- }

constructor TJucePanel.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 200;
  Height := 120;
  FGradientVertical := True;
  FCornerRadius := 6;
  FBorderWidth := 1;
end;

procedure TJucePanel.Paint(Canvas: TJuceCanvas);
var
  R: TJuceRect;
  C: TJuceColor;
  Img: TJuceImage;
  Ed: TJuceEditor;
  Th: TJuceTheme;
begin
  Th := Theme;
  R := BoundsRect;
  C := Pick(FColor, Th.Panel);
  if FGradientColor <> clJuceDefault then
  begin
    if FGradientVertical then
      Canvas.SetLinearGradient(C, 0, 0, FGradientColor, 0, R.H)
    else
      Canvas.SetLinearGradient(C, 0, 0, FGradientColor, R.W, 0);
  end
  else
    Canvas.SetColor(C);
  Canvas.FillRoundRect(R, FCornerRadius);
  Ed := Editor;
  Img := nil;
  if Ed <> nil then
    Img := Ed.FindImage(FBackgroundImage);
  if Img <> nil then
    Canvas.DrawImage(Img, R, JuceRect(0, 0, Img.Width, Img.Height), 1);
  if FBorderWidth > 0 then
  begin
    Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
    Canvas.DrawRoundRect(JuceInset(R, FBorderWidth / 2), FCornerRadius, FBorderWidth);
  end;
  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize + 1, [jfsBold]);
    Canvas.SetColor(Pick(FTextColor, Th.Text));
    if FHeaderHeight > 0 then
      Canvas.DrawText(Caption, JuceRect(0, 0, R.W, FHeaderHeight), FCaptionAlign, jvaCenter)
    else
      Canvas.DrawText(Caption, JuceRect(10, 4, Max(0, R.W - 20), 20), FCaptionAlign, jvaCenter);
  end;
  if FCaptionSeparator then
  begin
    Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
    if FHeaderHeight > 0 then
      Canvas.FillRect(JuceRect(8, FHeaderHeight - 1, Max(0, R.W - 16), 1))
    else
      Canvas.FillRect(JuceRect(8, 23, Max(0, R.W - 16), 1));
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceDisplay                                                                 }
{ ---------------------------------------------------------------------------- }

constructor TJuceDisplay.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 80;
  Height := 28;
  FCornerRadius := 3;
  FAlignment := jaCenter;
end;

procedure TJuceDisplay.Paint(Canvas: TJuceCanvas);
var
  R: TJuceRect;
  Th: TJuceTheme;
  Size: Single;
  Style: TJuceFontStyles;
  Face: string;
begin
  Th := Theme;
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, Th.MeterBack));
  Canvas.FillRoundRect(R, FCornerRadius);
  if FBorderWidth > 0 then
  begin
    Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
    Canvas.DrawRoundRect(JuceInset(R, FBorderWidth / 2), FCornerRadius, FBorderWidth);
  end;
  if Caption = '' then
    Exit;
  Size := FFontSize;
  if Size <= 0 then
    Size := Th.FontSize;
  Face := FFontName;
  if Face = '' then
    Face := Th.FontName;
  Style := [];
  if FBold then
    Include(Style, jfsBold);
  Canvas.SetFont(Face, Size, Style);
  Canvas.SetColor(Pick(FTextColor, Th.Accent));
  Canvas.DrawText(Caption, JuceInset(R, 3), FAlignment, jvaCenter);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceComboBox                                                                }
{ ---------------------------------------------------------------------------- }

function CountItems(const S: string): Integer;
var
  I: Integer;
begin
  if S = '' then
    Exit(0);
  Result := 1;
  for I := 1 to Length(S) do
    if S[I] = '|' then
      Inc(Result);
end;

function ItemOf(const S: string; Index: Integer): string;
var
  I, Start, N: Integer;
begin
  Result := '';
  N := 0;
  Start := 1;
  for I := 1 to Length(S) + 1 do
    if (I > Length(S)) or (S[I] = '|') then
    begin
      if N = Index then
        Exit(Copy(S, Start, I - Start));
      Inc(N);
      Start := I + 1;
    end;
end;

constructor TJuceComboBox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 160;
  Height := 26;
  FCornerRadius := 3;
end;

function TJuceComboBox.Choices: string;
var
  Ed: TJuceEditor;
begin
  Result := '';
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Result := Ed.ParamChoices(ParamIndex);
  if Result = '' then
    Result := FItems;
end;

function TJuceComboBox.ChoiceCount: Integer;
begin
  Result := CountItems(Choices);
end;

function TJuceComboBox.ItemIndex: Integer;
var
  N: Integer;
begin
  N := ChoiceCount;
  if N <= 1 then
    Result := 0
  else
    Result := Max(0, Min(N - 1, Round(Clamp01(Value) * (N - 1))));
end;

procedure TJuceComboBox.SetItemIndex(Index: Integer);
var
  N: Integer;
begin
  N := ChoiceCount;
  if N <= 1 then
    Value := 0
  else
    Value := Max(0, Min(N - 1, Index)) / (N - 1);
end;

function TJuceComboBox.Text: string;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Result := ValueText
  else
    Result := ItemOf(Choices, ItemIndex);
end;

procedure TJuceComboBox.Paint(Canvas: TJuceCanvas);
var
  R: TJuceRect;
  Th: TJuceTheme;
  Size, CY, AX: Single;
  Txt: TJuceColor;
begin
  Th := Theme;
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, Th.Panel));
  Canvas.FillRoundRect(R, FCornerRadius);
  Canvas.SetColor(Pick(FBorderColor, Th.PanelBorder));
  Canvas.DrawRoundRect(JuceInset(R, 0.5), FCornerRadius, 1);
  Size := FFontSize;
  if Size <= 0 then
    Size := Th.FontSize;
  Txt := Pick(FTextColor, Th.Text);
  Canvas.SetFont(Th.FontName, Size, []);
  Canvas.SetColor(Txt);
  Canvas.DrawText(Text, JuceRect(6, 0, Max(0, R.W - 36), R.H), jaLeft, jvaCenter);
  { the arrow }
  CY := R.H / 2;
  AX := R.W - 30;
  Canvas.SetColor(JuceWithAlpha(Txt, 0.9));
  Canvas.BeginPath;
  Canvas.MoveTo(AX + 3, CY - 2);
  Canvas.LineTo(AX + 10, CY + 3);
  Canvas.LineTo(AX + 17, CY - 2);
  Canvas.StrokePath(2, jljMiter, jlcButt);
end;

procedure TJuceComboBox.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  Ed: TJuceEditor;
  MenuItems: array of TJuceMenuItem;
  S: string;
  I, N, Current: Integer;
begin
  if not (jssLeft in Shift) then
    Exit;
  Ed := Editor;
  if Ed = nil then
    Exit;
  S := Choices;
  N := CountItems(S);
  if N = 0 then
    Exit;
  Current := ItemIndex;
  SetLength(MenuItems, N);
  for I := 0 to N - 1 do
  begin
    MenuItems[I] := JuceMenuItem(I + 1, ItemOf(S, I));
    if I = Current then
      MenuItems[I].Flags := JCP_MENU_TICKED;
  end;
  Ed.PopupMenu(MenuItems, AbsoluteX, AbsoluteY + Height, MenuChosen);
end;

procedure TJuceComboBox.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
begin
  if ItemId > 0 then
    SetItemIndex(ItemId - 1);
end;

function TJuceComboBox.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
begin
  Result := True;
  if DY > 0 then
    SetItemIndex(ItemIndex - 1)  { up: the item above }
  else if DY < 0 then
    SetItemIndex(ItemIndex + 1);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceKeyboard                                                                }
{ ---------------------------------------------------------------------------- }

const
  BlackKeyWidth = 0.7;   { of a white key }
  BlackKeyLength = 0.7;  { of the keyboard's height }
  { Where each key of an octave starts, in white keys from C (as JUCE's MidiKeyboardComponent). }
  KeyOffsets: array[0..11] of Single = (0, 1 - BlackKeyWidth * 0.6, 1, 2 - BlackKeyWidth * 0.4, 2, 3,
    4 - BlackKeyWidth * 0.7, 4, 5 - BlackKeyWidth * 0.5, 5, 6 - BlackKeyWidth * 0.3, 6);

constructor TJuceKeyboard.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 300;
  Height := 80;
  FFirstNote := 48;
  FLastNote := 72;
  FOctaveForMiddleC := 3;
  FShowLabels := True;
  FMouseNote := -1;
  FHoverNote := -1;
end;

class function TJuceKeyboard.IsBlackNote(Note: Integer): Boolean;
begin
  Result := (((Note mod 12) + 12) mod 12) in [1, 3, 6, 8, 10];
end;

procedure TJuceKeyboard.SetFirstNote(Value: Integer);
begin
  FFirstNote := Max(0, Min(127, Value));
  Invalidate;
end;

procedure TJuceKeyboard.SetLastNote(Value: Integer);
begin
  FLastNote := Max(0, Min(127, Value));
  Invalidate;
end;

function TJuceKeyboard.WhiteKeyCount: Integer;
var
  N: Integer;
begin
  Result := 0;
  for N := FFirstNote to FLastNote do
    if not IsBlackNote(N) then
      Inc(Result);
end;

function TJuceKeyboard.KeyWidth: Single;
begin
  Result := Width / Max(1, WhiteKeyCount);
end;

function TJuceKeyboard.KeyRect(Note: Integer): TJuceRect;

  function StartOf(N: Integer): Single;
  begin
    Result := ((N div 12) * 7 + KeyOffsets[N mod 12]) * KeyWidth;
  end;

begin
  if (Note < FFirstNote) or (Note > FLastNote) or (Note < 0) or (Note > 127) then
    Exit(JuceRect(0, 0, 0, 0));
  if IsBlackNote(Note) then
    Result := JuceRect(StartOf(Note) - StartOf(FFirstNote), 0, KeyWidth * BlackKeyWidth, Height * BlackKeyLength)
  else
    Result := JuceRect(StartOf(Note) - StartOf(FFirstNote), 0, KeyWidth, Height);
end;

function TJuceKeyboard.NoteAt(X, Y: Single): Integer;
var
  N: Integer;
begin
  Result := -1;
  if (Y < 0) or (Y >= Height) then
    Exit;
  { black keys lie over the white ones }
  for N := FFirstNote to FLastNote do
    if IsBlackNote(N) and JuceRectContains(KeyRect(N), X, Y) then
      Exit(N);
  for N := FFirstNote to FLastNote do
    if not IsBlackNote(N) and JuceRectContains(KeyRect(N), X, Y) then
      Exit(N);
end;

procedure TJuceKeyboard.SetNoteLit(Note: Integer; Lit: Boolean);
begin
  if (Note < 0) or (Note > 127) or (FLit[Note] = Lit) then
    Exit;
  FLit[Note] := Lit;
  Invalidate;
end;

function TJuceKeyboard.NoteLit(Note: Integer): Boolean;
begin
  Result := (Note >= 0) and (Note <= 127) and FLit[Note];
end;

function TJuceKeyboard.NoteDown(Note: Integer): Boolean;
begin
  Result := NoteLit(Note) or ((Note = FMouseNote) and (Note >= 0));
end;

procedure TJuceKeyboard.Paint(Canvas: TJuceCanvas);
var
  N, Oct: Integer;
  R: TJuceRect;
  Th: TJuceTheme;
  Down, Over, Key: TJuceColor;
  Inner, KbW: Single;

  { an opaque colour with a translucent one on top }
  function OverlaidWith(Base, Top: TJuceColor): TJuceColor;
  begin
    Result := JuceBlend(Base, Top or $FF000000, (Top shr 24) / 255);
  end;

begin
  Th := Theme;
  Down := Pick(FKeyDownColor, JuceWithAlpha(Th.Accent, 0.6));
  Over := Pick(FHoverColor, JuceWithAlpha(Th.Accent, 0.25));
  Canvas.SetColor($FFFFFFFF);
  Canvas.FillAll;
  KbW := 0;
  { white keys: the overlays, the C labels, the lines between keys }
  for N := FFirstNote to FLastNote do
  begin
    if IsBlackNote(N) then
      Continue;
    R := KeyRect(N);
    KbW := R.X + R.W;
    if NoteDown(N) then
    begin
      Canvas.SetColor(Down);
      Canvas.FillRect(R);
    end;
    if N = FHoverNote then
    begin
      Canvas.SetColor(Over);
      Canvas.FillRect(R);
    end;
    if FShowLabels and (N mod 12 = 0) then
    begin
      Oct := N div 12 + FOctaveForMiddleC - 5;
      Canvas.SetFont(Th.FontName, Min(12, KeyWidth * 0.9), []);
      Canvas.SetColor($FF000000);
      Canvas.DrawText('C' + IntToStr(Oct), JuceRect(R.X + 1, R.Y, Max(0, R.W - 1), Max(0, R.H - 2)), jaCenter, jvaBottom);
    end;
    Canvas.SetColor($66000000);
    Canvas.FillRect(JuceRect(R.X, R.Y, 1, R.H));
    if N = FLastNote then
      Canvas.FillRect(JuceRect(R.X + R.W, R.Y, 1, R.H));
  end;
  { black keys }
  for N := FFirstNote to FLastNote do
  begin
    if not IsBlackNote(N) then
      Continue;
    R := KeyRect(N);
    Key := $FF000000;
    if NoteDown(N) then
      Key := OverlaidWith(Key, Down);
    if N = FHoverNote then
      Key := OverlaidWith(Key, Over);
    Canvas.SetColor(Key);
    Canvas.FillRect(R);
    if NoteDown(N) then
    begin
      Canvas.SetColor($FF000000);
      Canvas.DrawRect(R, 1);
    end
    else
    begin
      { the lit top of the key, as JUCE draws it (Colour::brighter) }
      Canvas.SetColor(JuceBrighter(Key, 0.2857));
      Inner := R.W / 8;
      Canvas.FillRect(JuceRect(R.X + Inner, R.Y, R.W - 2 * Inner, R.H * 7 / 8));
    end;
  end;
  { a shadow along the top and a line along the bottom }
  Canvas.SetLinearGradient($4C000000, 0, 0, $00000000, 0, 5);
  Canvas.FillRect(JuceRect(0, 0, KbW, 5));
  Canvas.SetColor($66000000);
  Canvas.FillRect(JuceRect(0, Height - 1, KbW, 1));
end;

function TJuceKeyboard.VelocityAt(Note: Integer; Y: Single): Single;
var
  R: TJuceRect;
begin
  { as JUCE's keyboard: the further down the key, the harder }
  R := KeyRect(Note);
  if R.H <= 0 then
    Result := 1
  else
    Result := Max(0.01, Min(1, Y / R.H));
end;

procedure TJuceKeyboard.PressNote(Note: Integer; Velocity: Single);
begin
  if Note = FMouseNote then
    Exit;
  ReleaseNote;
  if Note < 0 then
    Exit;
  FMouseNote := Note;
  Invalidate;
  if Assigned(FOnNoteOn) then
    FOnNoteOn(Self, Note, Velocity);
end;

procedure TJuceKeyboard.ReleaseNote;
var
  N: Integer;
begin
  N := FMouseNote;
  if N < 0 then
    Exit;
  FMouseNote := -1;
  Invalidate;
  if Assigned(FOnNoteOff) then
    FOnNoteOff(Self, N, 0);
end;

procedure TJuceKeyboard.SetHoverNote(Note: Integer);
begin
  if Note = FHoverNote then
    Exit;
  FHoverNote := Note;
  Invalidate;
end;

procedure TJuceKeyboard.MouseDown(X, Y: Single; Shift: TJuceShiftState);
var
  N: Integer;
begin
  if not (jssLeft in Shift) then
    Exit;
  N := NoteAt(X, Y);
  SetHoverNote(N);
  if N >= 0 then
    PressNote(N, VelocityAt(N, Y));
end;

procedure TJuceKeyboard.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
var
  N: Integer;
begin
  { a glissando: the held note follows the mouse; off the keys, none }
  N := NoteAt(X, Y);
  SetHoverNote(N);
  if N <> FMouseNote then
  begin
    if N < 0 then
      ReleaseNote
    else
      PressNote(N, VelocityAt(N, Y));
  end;
end;

procedure TJuceKeyboard.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
  ReleaseNote;
  { pressed without the mouse having moved over it first (a touch screen): no MouseLeave
    will come to clear the hover mark, so clear it now }
  if not Hovered then
    SetHoverNote(-1);
end;

procedure TJuceKeyboard.MouseMove(X, Y: Single; Shift: TJuceShiftState);
begin
  SetHoverNote(NoteAt(X, Y));
end;

procedure TJuceKeyboard.MouseLeave;
begin
  SetHoverNote(-1);
end;

procedure TJuceKeyboard.Detached;
begin
  { never leave a note hanging when the window closes }
  ReleaseNote;
  FHoverNote := -1;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceScope                                                                   }
{ ---------------------------------------------------------------------------- }

function JuceScopeTimeFromValue(Value: Single): Single;
begin
  if IsNan(Value) or (Value <= 0) then
    Value := 0
  else if Value > 1 then
    Value := 1;
  Result := JuceScopeMinTimeMs * Exp(Value * Ln(JuceScopeMaxTimeMs / JuceScopeMinTimeMs));
end;

function JuceScopeValueFromTime(Ms: Single): Single;
begin
  if IsNan(Ms) or (Ms <= JuceScopeMinTimeMs) then
    Result := 0
  else if Ms >= JuceScopeMaxTimeMs then
    Result := 1
  else
    Result := Ln(Ms / JuceScopeMinTimeMs) / Ln(JuceScopeMaxTimeMs / JuceScopeMinTimeMs);
end;

function JuceScopeTimeText(Ms: Single): string;
begin
  if IsNan(Ms) then
    Ms := 0;
  if Ms < 9.95 then
    Result := FormatFloat('0.0', Ms) + ' ms'
  else
    Result := FormatFloat('0', Ms) + ' ms';
end;

{ A sample fit to draw and to compare: NaN and infinities are silence, and
  the rest is kept within +-1000 so the arithmetic below cannot overflow. }
function ScopeClean(V: Single): Single;
begin
  if IsNan(V) or IsInfinite(V) then
    Result := 0
  else if V > 1000 then
    Result := 1000
  else if V < -1000 then
    Result := -1000
  else
    Result := V;
end;

constructor TJuceScope.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Width := 240;
  Height := 120;
  FChannel := jscMix;
  FTrigger := jstRising;
  FTimeMs := 20;
  FGain := 1;
  FLineWidth := 1.5;
  FCornerRadius := 3;
  FShowGrid := True;
  FGridX := 8;
  FGridY := 4;
end;

function TJuceScope.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TJuceScope.Attached;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed <> nil) and (FFeed = nil) then
  begin
    Ed.ScopeAttach;
    FFeed := Ed;
  end;
  Refresh(True); { the designer attaches before each paint: this shows its sample wave }
end;

procedure TJuceScope.Detached;
begin
  if FFeed <> nil then
  begin
    FFeed.ScopeDetach;
    FFeed := nil;
  end;
  FHaveStamp := False;
end;

function TJuceScope.SweepLength: Integer;
var
  Ed: TJuceEditor;
  Rate, Ms: Double;
begin
  Rate := 0;
  Ed := Editor;
  if Ed <> nil then
    Rate := Ed.ScopeSampleRate;
  if IsNan(Rate) or (Rate < 1000) or (Rate > 1.0E6) then
    Rate := 48000;
  Ms := FTimeMs;
  if IsNan(Ms) or (Ms <= 0) then
    Ms := 20
  else if Ms > 10000 then
    Ms := 10000;
  Result := EnsureRange(Round(Ms * Rate / 1000), 16, JUCE_SCOPE_MAX_READ div 2 - 1);
end;

procedure TJuceScope.Refresh(Force: Boolean);
var
  Ed: TJuceEditor;
  Span, Total, Got, Stamp: Integer;
begin
  Ed := Editor;
  if Ed = nil then
    Exit;
  Span := SweepLength;
  Total := Min(2 * Span + 2, JUCE_SCOPE_MAX_READ); { a sweep, and as much again to find a trigger in }
  if Length(FRead) < Total then
    SetLength(FRead, Total);
  Got := Ed.ScopeRead(Ord(FChannel), FRead, Total, Stamp);
  if Got <= 0 then
    Exit;
  if not Force and FHaveStamp and (Stamp = FStamp) then
    Exit; { no new audio: hold the last sweep }
  FStamp := Stamp;
  FHaveStamp := True;
  ShowSamples(FRead, Got, Span);
  Invalidate;
end;

procedure TJuceScope.Tick;
begin
  Refresh(False);
end;

procedure TJuceScope.ShowSamples(const Samples: array of Single; Count, Span: Integer);
var
  I, Start, N: Integer;
  Level, A, B: Single;
begin
  Count := Min(Count, Length(Samples));
  FTriggered := False;
  FPhase := 0;
  if (Count < 2) or (Span < 1) then
  begin
    FCount := 0;
    FSpan := 0;
    Exit;
  end;
  Span := Min(Span, Count - 1);
  { free-running, or no trigger point found: the newest Span samples }
  Start := Count - Span;
  N := Span;
  Level := ScopeClean(FTriggerLevel);
  if FTrigger <> jstFree then
    { the latest crossing that still leaves Span samples after it }
    for I := Count - Span downto 1 do
    begin
      A := ScopeClean(Samples[I - 1]);
      B := ScopeClean(Samples[I]);
      if ((FTrigger = jstRising) and (A < Level) and (B >= Level))
        or ((FTrigger = jstFalling) and (A > Level) and (B <= Level)) then
      begin
        Start := I - 1;
        N := Span + 1;
        FPhase := (Level - A) / (B - A); { between the two: no jitter from whole-sample steps }
        FTriggered := True;
        Break;
      end;
    end;
  if Length(FSweep) < N then
    SetLength(FSweep, N);
  for I := 0 to N - 1 do
    FSweep[I] := ScopeClean(Samples[Start + I]);
  FCount := N;
  FSpan := Span;
end;

function TJuceScope.SampleCount: Integer;
begin
  Result := FCount;
end;

function TJuceScope.Sample(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < FCount) then
    Result := FSweep[Index]
  else
    Result := 0;
end;

function TJuceScope.SampleY(V, Mid, Half: Single): Single;
var
  G: Single;
begin
  G := FGain;
  if IsNan(G) or (G <= 0) then
    G := 1
  else if G > 1000 then
    G := 1000;
  V := V * G;
  if V > 1.1 then { a little past the edge, so a clipped wave shows as clipped }
    V := 1.1
  else if V < -1.1 then
    V := -1.1;
  Result := Mid - V * Half;
end;

procedure TJuceScope.Paint(Canvas: TJuceCanvas);
var
  Th: TJuceTheme;
  R, Plot: TJuceRect;
  Grid: TJuceColor;
  I, Cols, C, K, K0, K1: Integer;
  X, Mid, Half, Lo, Hi, Thick: Single;
begin
  Th := Theme;
  R := BoundsRect;
  Canvas.SetColor(Pick(FColor, Th.MeterBack));
  Canvas.FillRoundRect(R, FCornerRadius);
  Plot := JuceInset(R, 2);
  if (Plot.W <= 0) or (Plot.H <= 0) then
    Exit;
  Thick := FLineWidth;
  if IsNan(Thick) or (Thick < 0.5) then
    Thick := 0.5
  else if Thick > 8 then
    Thick := 8;
  Mid := Plot.Y + Plot.H / 2;
  Half := Max(Plot.H / 2 - Thick / 2, 1);

  if FShowGrid then
  begin
    Grid := Pick(FGridColor, JuceWithAlpha(Th.TextDim, 0.2));
    Canvas.SetColor(Grid);
    if (FGridX > 1) and (FGridX <= 100) then
      for I := 1 to FGridX - 1 do
      begin
        X := Plot.X + Plot.W * I / FGridX;
        Canvas.DrawLine(X, Plot.Y, X, Plot.Y + Plot.H, 1);
      end;
    if (FGridY > 1) and (FGridY <= 100) then
      for I := 1 to FGridY - 1 do
        Canvas.DrawLine(Plot.X, Plot.Y + Plot.H * I / FGridY, Plot.X + Plot.W, Plot.Y + Plot.H * I / FGridY, 1);
    Canvas.DrawLine(Plot.X, Mid, Plot.X + Plot.W, Mid, 1); { the zero line, a shade brighter }
  end;

  Canvas.SaveState;
  try
    if Canvas.ClipRect(Plot) then
    begin
      Canvas.SetColor(Pick(FLineColor, Th.Accent));
      Canvas.BeginPath;
      if (FCount < 2) or (FSpan <= 0) then
      begin
        Canvas.MoveTo(Plot.X, Mid); { nothing yet: silence }
        Canvas.LineTo(Plot.X + Plot.W, Mid);
      end
      else if FCount > 2 * Plot.W then
      begin
        { more samples than pixels: each column from its lowest to its highest }
        Cols := Max(1, Trunc(Plot.W));
        for C := 0 to Cols - 1 do
        begin
          K0 := EnsureRange(Trunc(C * FSpan / Cols + FPhase), 0, FCount - 1);
          K1 := EnsureRange(Trunc((C + 1) * FSpan / Cols + FPhase), K0 + 1, FCount);
          Lo := FSweep[K0];
          Hi := Lo;
          for K := K0 + 1 to K1 - 1 do
            if FSweep[K] < Lo then
              Lo := FSweep[K]
            else if FSweep[K] > Hi then
              Hi := FSweep[K];
          X := Plot.X + (C + 0.5) * Plot.W / Cols;
          if C = 0 then
            Canvas.MoveTo(X, SampleY(Hi, Mid, Half))
          else
            Canvas.LineTo(X, SampleY(Hi, Mid, Half));
          Canvas.LineTo(X, SampleY(Lo, Mid, Half));
        end;
      end
      else
        for K := 0 to FCount - 1 do
        begin
          X := Plot.X + (K - FPhase) * Plot.W / FSpan;
          if K = 0 then
            Canvas.MoveTo(X, SampleY(FSweep[K], Mid, Half))
          else
            Canvas.LineTo(X, SampleY(FSweep[K], Mid, Half));
        end;
      Canvas.StrokePath(Thick, jljRound, jlcRound);
    end;
  finally
    Canvas.RestoreState;
  end;

  if Caption <> '' then
  begin
    Canvas.SetFont(Th.FontName, Th.FontSize, []);
    Canvas.SetColor(Th.TextDim);
    Canvas.DrawText(Caption, JuceInset(R, 4), jaLeft, jvaTop);
  end;
end;

procedure JuceRegisterControls;
var
  I: Integer;
begin
  for I := Low(JuceControlClasses) to High(JuceControlClasses) do
    RegisterClass(JuceControlClasses[I]);
end;

end.
