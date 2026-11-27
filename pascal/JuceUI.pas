{
  JuceUI.pas - custom plug-in editors in Pascal, drawn by JUCE.

  JUCE owns the plug-in window (every host, every OS); your controls paint on
  a TJuceCanvas and react to the mouse. No LCL or VCL is involved.

    type
      TMyEditor = class(TJuceEditor)
      public
        constructor Create(APlugin: TJucePlugin); override;
      end;

    constructor TMyEditor.Create(APlugin: TJucePlugin);
    var
      Knob: TJuceKnob;
    begin
      inherited Create(APlugin);
      SetSize(300, 200);
      Knob := TJuceKnob.Create(Root);      // Root: the editor's top control
      Knob.SetBounds(20, 20, 80, 100);
      Knob.Caption := 'Cutoff';
      Knob.ParameterId := 'cutoff';        // bound when the window opens
    end;

    function TMySynth.CreateEditor: TJuceEditorBase;
    begin
      Result := TMyEditor.Create(Self);
    end;

  Rules:
    - Everything here runs on the host's message thread. The editor never
      touches DSP state: bound controls read and write parameters through the
      host (with gestures, so hosts record undo steps and automation), and
      meters read values Process publishes with TJucePlugin.SetMeter.
    - Controls are TComponents: Create(AParent) puts a control on AParent,
      which owns and frees it. Their published properties (Left, Top, Width,
      Height, Caption, ParameterId, colours as Cardinal $AARRGGBB, style enums)
      are what a form file would store.
    - A colour property of 0 (clJuceDefault) means "use the theme's colour".
    - Exceptions inside a control are contained (that control stops painting
      for that frame); nothing escapes to the host.

  Works with Delphi and Free Pascal (Delphi mode).
}
unit JuceUI;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin;

const
  clJuceDefault = TJuceColor(0); { "use the theme colour" }

type
  TJuceShiftKey = (jssShift, jssCtrl, jssAlt, jssCmd, jssLeft, jssRight, jssMiddle, jssPopup);
  TJuceShiftState = set of TJuceShiftKey;
  TJuceOrientation = (joVertical, joHorizontal);

  { Colours and fonts shared by an editor's controls. }
  TJuceTheme = class(TPersistent)
  private
    FBackground, FPanel, FPanelBorder, FText, FTextDim, FAccent, FTrack: TJuceColor;
    FKnobBody, FKnobPointer, FButtonFace, FLedOn, FLedOff: TJuceColor;
    FMeterLow, FMeterMid, FMeterHigh, FMeterBack: TJuceColor;
    FFontName: string;
    FFontSize: Single;
    FTooltipBackground, FTooltipText, FTooltipBorder: TJuceColor;
    FMenuBackground, FMenuText, FMenuHighlight, FMenuHighlightText, FMenuHeader: TJuceColor;
    FBubbleBackground, FBubbleText, FBubbleBorder, FLink: TJuceColor;
    FTooltipFontSize, FMenuFontSize, FBubbleFontSize: Single;
  public
    constructor Create;
    procedure Assign(Source: TPersistent); override;
  published
    property Background: TJuceColor read FBackground write FBackground;
    property Panel: TJuceColor read FPanel write FPanel;
    property PanelBorder: TJuceColor read FPanelBorder write FPanelBorder;
    property Text: TJuceColor read FText write FText;
    property TextDim: TJuceColor read FTextDim write FTextDim;
    property Accent: TJuceColor read FAccent write FAccent;
    property Track: TJuceColor read FTrack write FTrack;
    property KnobBody: TJuceColor read FKnobBody write FKnobBody;
    property KnobPointer: TJuceColor read FKnobPointer write FKnobPointer;
    property ButtonFace: TJuceColor read FButtonFace write FButtonFace;
    property LedOn: TJuceColor read FLedOn write FLedOn;
    property LedOff: TJuceColor read FLedOff write FLedOff;
    property MeterLow: TJuceColor read FMeterLow write FMeterLow;
    property MeterMid: TJuceColor read FMeterMid write FMeterMid;
    property MeterHigh: TJuceColor read FMeterHigh write FMeterHigh;
    property MeterBack: TJuceColor read FMeterBack write FMeterBack;
    property FontName: string read FFontName write FFontName;
    property FontSize: Single read FFontSize write FFontSize;
    { The wrapper's tooltip and popup-menu windows (0 = JUCE's own colour or
      size; the font is FontName). Applied when the editor opens, before
      every menu, and by TJuceEditor.ThemeChanged. }
    property TooltipBackground: TJuceColor read FTooltipBackground write FTooltipBackground;
    property TooltipText: TJuceColor read FTooltipText write FTooltipText;
    property TooltipBorder: TJuceColor read FTooltipBorder write FTooltipBorder;
    property TooltipFontSize: Single read FTooltipFontSize write FTooltipFontSize;
    property MenuBackground: TJuceColor read FMenuBackground write FMenuBackground;
    property MenuText: TJuceColor read FMenuText write FMenuText;
    property MenuHighlight: TJuceColor read FMenuHighlight write FMenuHighlight;
    property MenuHighlightText: TJuceColor read FMenuHighlightText write FMenuHighlightText;
    property MenuHeader: TJuceColor read FMenuHeader write FMenuHeader;
    property MenuFontSize: Single read FMenuFontSize write FMenuFontSize;
    { The value bubble of knobs and faders (0 = the tooltip's colour, else
      Panel / Text / PanelBorder; size 0 = FontSize + 2). }
    property BubbleBackground: TJuceColor read FBubbleBackground write FBubbleBackground;
    property BubbleText: TJuceColor read FBubbleText write FBubbleText;
    property BubbleBorder: TJuceColor read FBubbleBorder write FBubbleBorder;
    property BubbleFontSize: Single read FBubbleFontSize write FBubbleFontSize;
    { Links (TJuceLink). }
    property Link: TJuceColor read FLink write FLink;
  end;

  TJuceEditor = class;
  TJuceControl = class;

  TJuceParamControl = class;

  TJuceContextMenuEvent = procedure(Sender: TJuceControl; X, Y: Single; var Handled: Boolean) of object;
  { A control's value as text (ValueText, the value bubble): change Text,
    which holds the plug-in's own text with units. }
  TJuceValueTextEvent = procedure(Sender: TJuceParamControl; Normalised: Single; var Text: string) of object;
  { When a knob or fader shows its value in a bubble: never, while it is
    dragged, or also for a while when the mouse is over it. }
  TJuceValueBubble = (jvbNone, jvbDrag, jvbDragAndHover);
  TJuceMenuResultEvent = procedure(Sender: TJuceEditor; MenuId, ItemId: Integer) of object;

  { Base of every control. Coordinates of mouse methods are local (0,0 is the
    control's top left). }
  TJuceControl = class(TComponent)
  private
    FParent: TJuceControl;
    FControls: TList;
    FLeft, FTop, FWidth, FHeight: Integer;
    FVisible, FEnabled: Boolean;
    FHint, FCaption: string;
    FHovered: Boolean;
    FOnContextMenu: TJuceContextMenuEvent;
    procedure SetParent(Value: TJuceControl);
    procedure SetLeft(Value: Integer);
    procedure SetTop(Value: Integer);
    procedure SetWidth(Value: Integer);
    procedure SetHeight(Value: Integer);
    procedure SetVisible(Value: Boolean);
    procedure SetEnabled(Value: Boolean);
    procedure SetCaption(const Value: string);
    procedure SetHint(const Value: string);
    function GetControl(Index: Integer): TJuceControl;
    function GetControlCount: Integer;
  protected
    procedure Paint(Canvas: TJuceCanvas); virtual;
    procedure MouseDown(X, Y: Single; Shift: TJuceShiftState); virtual;
    procedure MouseDrag(X, Y: Single; Shift: TJuceShiftState); virtual;
    procedure MouseUp(X, Y: Single; Shift: TJuceShiftState); virtual;
    procedure MouseMove(X, Y: Single; Shift: TJuceShiftState); virtual;
    procedure MouseEnter; virtual;
    procedure MouseLeave; virtual;
    procedure MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState); virtual;
    { True if handled; otherwise the parent gets it. DY > 0 = wheel up. }
    function MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean; virtual;
    { Right click (or the platform's context-menu click). Fires OnContextMenu. }
    procedure ContextMenu(X, Y: Single); virtual;
    { The control became part of an open editor (bind parameters here). }
    procedure Attached; virtual;
    { The editor is closing, or the control is leaving it (end gestures here). }
    procedure Detached; virtual;
    { Editor timer tick, if NeedsTimer. }
    procedure Tick; virtual;
    function NeedsTimer: Boolean; virtual;
    procedure ParameterChanged(Index: Integer; Normalised: Single); virtual;
    function Theme: TJuceTheme;
    { Theme colour if C is clJuceDefault. }
    function Pick(C, ThemeColor: TJuceColor): TJuceColor;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
    function BoundsRect: TJuceRect;   { local: 0, 0, Width, Height }
    { The editor this control is in, or nil. }
    function Editor: TJuceEditor;
    procedure Invalidate;
    { Local point inside this control? Override for round controls. }
    function HitTest(X, Y: Single): Boolean; virtual;
    { The deepest visible control under a local point (Self if no child), or nil. }
    function ControlAt(X, Y: Single): TJuceControl;
    function AbsoluteX: Single;
    function AbsoluteY: Single;
    { This control only (no children); exceptions are contained. Used by
      PaintAll and by the design-time controls. }
    procedure PaintControl(Canvas: TJuceCanvas);
    { The control called AName (case-insensitive) in this control's subtree,
      itself excluded, or nil. Names come from a loaded layout (JuceLayout)
      or from setting Name in code. }
    function FindControl(const AName: string): TJuceControl;
    { Every editor event below this control, recursively. }
    procedure PaintAll(Canvas: TJuceCanvas);
    procedure AttachAll;
    procedure DetachAll;
    procedure TickAll;
    procedure ParameterChangedAll(Index: Integer; Normalised: Single);
    function AnyNeedsTimer: Boolean;
    property Parent: TJuceControl read FParent write SetParent;
    property ControlCount: Integer read GetControlCount;
    property Controls[Index: Integer]: TJuceControl read GetControl;
    property Hovered: Boolean read FHovered;
  published
    property Left: Integer read FLeft write SetLeft;
    property Top: Integer read FTop write SetTop;
    property Width: Integer read FWidth write SetWidth;
    property Height: Integer read FHeight write SetHeight;
    property Visible: Boolean read FVisible write SetVisible default True;
    property Enabled: Boolean read FEnabled write SetEnabled default True;
    property Hint: string read FHint write SetHint;        { tooltip }
    property Caption: string read FCaption write SetCaption;
    property OnContextMenu: TJuceContextMenuEvent read FOnContextMenu write FOnContextMenu;
  end;
  TJuceControlClass = class of TJuceControl;

  { A control with a value 0..1, optionally bound to a plug-in parameter by
    its id. Unbound controls keep their own value (OnChange tells you). }
  TJuceParamControl = class(TJuceControl)
  private
    FParameterId: string;
    FParamIndex: Integer;
    FValue: Single;
    FDefaultValue: Single;
    FGestureOpen: Boolean;
    FValueSet: Boolean;  { the value has been set (until then an unbound control shows DefaultValue) }
    FOnChange: TNotifyEvent;
    FOnValueText: TJuceValueTextEvent;
    procedure SetParameterId(const Value: string);
    procedure SetValue(Value: Single);
    procedure SetDefaultValue(Value: Single);
  protected
    { The value bubble (see TJuceEditor.ShowValueBubble), pointing at
      BubbleAnchor, with ValueText; HideAfterTicks > 0 hides it after that
      many editor timer ticks. It follows the value while shown. }
    procedure ShowBubble(HideAfterTicks: Integer = 0);
    procedure HideBubble;
    function BubbleShown: Boolean;
    { What the bubble points at, in local coordinates (default: the whole control). }
    function BubbleAnchor: TJuceRect; virtual;
    procedure Attached; override;
    procedure Detached; override;
    procedure ParameterChanged(Index: Integer; Normalised: Single); override;
    { A user edit: open a gesture, change the value (as often as you like),
      close it. The host records one undo step. }
    procedure BeginEdit;
    procedure SetValueFromUser(Value: Single);
    procedure EndEdit;
    { BeginEdit + SetValueFromUser(DefaultValue) + EndEdit. }
    procedure ResetToDefault;
    procedure DoChange; virtual;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    function IsBound: Boolean;
    { The value as the plug-in shows it (ParameterToText), with units, then
      OnValueText. }
    function ValueText: string;
    { The same for any value. }
    function ValueTextFor(Normalised: Single): string; virtual;
    property ParamIndex: Integer read FParamIndex;
    property GestureOpen: Boolean read FGestureOpen;
    { Setting it from code acts like a user edit (the host is told). }
    property Value: Single read FValue write SetValue;
  published
    property ParameterId: string read FParameterId write SetParameterId;
    { For unbound controls, which also start at it; bound ones use the parameter's default. }
    property DefaultValue: Single read FDefaultValue write SetDefaultValue;
    property OnChange: TNotifyEvent read FOnChange write FOnChange;
    { Your own value text, e.g. a rate shown as a note length while synced. }
    property OnValueText: TJuceValueTextEvent read FOnValueText write FOnValueText;
  end;

  { The editor's top control: fills the window with the theme background. }
  TJuceRootControl = class(TJuceControl)
  private
    FEditor: TJuceEditor;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  end;

  { A canvas on the wrapper's drawing API (valid during one paint). }
  TJuceHostCanvas = class(TJuceCanvas)
  private
    FApi: PJcpEditorApi;
    FEditor: PJcpEditor;
    FG: PJcpGraphics;
    FFontName: UTF8String;
    FFontHeight: Single;
    FFontStyle: Int32;
  public
    constructor Create(AApi: PJcpEditorApi; AEditor: PJcpEditor; AGraphics: PJcpGraphics);
    procedure SetColor(Color: TJuceColor); override;
    procedure SetLinearGradient(Color1: TJuceColor; X1, Y1: Single; Color2: TJuceColor; X2, Y2: Single); override;
    procedure SetRadialGradient(Color1: TJuceColor; CX, CY: Single; Color2: TJuceColor; EdgeX, EdgeY: Single); override;
    procedure FillAll; override;
    procedure FillRect(const R: TJuceRect); override;
    procedure DrawRect(const R: TJuceRect; Thickness: Single); override;
    procedure FillRoundRect(const R: TJuceRect; Radius: Single); override;
    procedure DrawRoundRect(const R: TJuceRect; Radius, Thickness: Single); override;
    procedure FillEllipse(const R: TJuceRect); override;
    procedure DrawEllipse(const R: TJuceRect; Thickness: Single); override;
    procedure DrawLine(X1, Y1, X2, Y2, Thickness: Single); override;
    procedure BeginPath; override;
    procedure MoveTo(X, Y: Single); override;
    procedure LineTo(X, Y: Single); override;
    procedure QuadTo(CX, CY, X, Y: Single); override;
    procedure CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single); override;
    procedure AddArc(CX, CY, RX, RY, FromAngle, ToAngle: Single; StartNewSubPath: Boolean); override;
    procedure ClosePath; override;
    procedure FillPath; override;
    procedure StrokePath(Thickness: Single; Join: TJuceLineJoin; Cap: TJuceLineCap); override;
    procedure SetFont(const Name: string; Height: Single; Style: TJuceFontStyles); override;
    procedure DrawText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); override;
    procedure DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign); override;
    function TextWidth(const Text: string): Single; override;
    procedure DrawImage(Image: TJuceImage; const Dest, Source: TJuceRect; Opacity: Single); override;
    procedure SaveState; override;
    procedure RestoreState; override;
    function ClipRect(const R: TJuceRect): Boolean; override;
    procedure Translate(DX, DY: Single); override;
  end;

  { An image owned by an editor (a wrapper image handle). }
  TJuceHostImage = class(TJuceImage)
  private
    FHandle: Integer;
    FWidth, FHeight: Integer;
  public
    function Width: Integer; override;
    function Height: Integer; override;
    property Handle: Integer read FHandle;
  end;

  { Root of a custom editor: derive from this, build controls on Root in the
    constructor. }
  TJuceEditor = class(TJuceEditorBase)
  private
    FRoot: TJuceRootControl;
    FTheme: TJuceTheme;
    FCapture, FHover: TJuceControl;
    FImages: TStringList;      { name -> TJuceHostImage }
    FTimerHz: Integer;
    FTimerRunning: Boolean;
    FNextMenuId: Integer;
    FMenuId: Integer;
    FOnMenuResult: TJuceMenuResultEvent;
    FDestroying: Boolean;
    { the value bubble (editor coordinates) }
    FBubbleOwner: TJuceControl;
    FBubbleText: string;
    FBubbleAnchor, FBubbleRect: TJuceRect;
    FBubbleBelow: Boolean;
    FBubbleTicks: Integer;
    { meters predicted by the editor until Process has run (PredictMeter) }
    FPredicted: array[0..JCP_MAX_METERS - 1] of record
      Active: Boolean;
      Value: Single;
      Stamp: Integer;
    end;
    procedure SetHover(Control: TJuceControl);
    function Shift(Modifiers: Integer): TJuceShiftState;
    function ProcessStamp: Integer;
    procedure PlaceBubble;
    procedure PaintBubble(Canvas: TJuceCanvas);
    procedure InvalidateBubble;
  protected
    procedure Paint(G: PJcpGraphics); override;
    procedure MouseEvent(const E: TJcpMouseEvent); override;
    procedure TimerTick; override;
    procedure ParameterChanged(Index: Integer; Normalised: Single); override;
    procedure Resized; override;
    procedure PopupResult(MenuId, ItemId: Integer); override;
    procedure Opened; override;
    { The theme's tooltip and menu look to the wrapper (SetLook). }
    procedure ApplyLook; virtual;
  public
    { Turn encoded image bytes into an image the canvas can draw (nil if they
      are not a usable image), and release one. The default uses the
      wrapper; a design-time editor decodes the bytes itself. }
    function CreateCanvasImage(const Data: TBytes): TJuceImage; virtual;
    procedure FreeCanvasImage(Image: TJuceImage); virtual;
    constructor Create(APlugin: TJucePlugin); override;
    destructor Destroy; override;
    { Paint the whole editor on any canvas (the wrapper's, a test's, a design-time one). }
    procedure PaintTo(Canvas: TJuceCanvas);
    { Register a PNG/JPEG under a name controls can refer to (FilmstripImage,
      BackgroundImage). False if the bytes are not a usable image. }
    function AddImage(const Name: string; const Data: TBytes): Boolean;
    function FindImage(const Name: string): TJuceImage;
    function ImageCount: Integer;
    { Root.FindControl: a control by name, or nil. }
    function FindControl(const AName: string): TJuceControl;
    { A popup menu at editor coordinates; Handler gets the chosen id (0 =
      dismissed). Returns the menu id, or 0 if it could not be shown. }
    function PopupMenu(const Items: array of TJuceMenuItem; X, Y: Single; Handler: TJuceMenuResultEvent): Integer;
    { Called by controls that are being freed. }
    procedure ControlGone(Control: TJuceControl);
    { Shows the hint of the control under the mouse (or its nearest parent
      with one) again; setting a control's Hint does this for you. }
    procedure RefreshTooltip;
    { Start the tick if a control needs it (meters); called on open and when controls are added. }
    procedure UpdateTimer;
    { Scale the editor: its current size becomes the design size (see
      TJuceEditorBase.SetDesignSize). Call in the constructor, after the
      size is set (e.g. after JuceLoadLayoutResource). }
    function SetScalable(MinScale, MaxScale: Single; CornerResizer: Boolean = True): Boolean;
    { The theme's tooltip and menu colours and fonts to the wrapper, and a
      repaint: call after changing Theme once the editor is open. }
    procedure ThemeChanged;
    { The value bubble: Text in a small box pointing at Anchor (editor
      coordinates), above it or below, drawn over every control. One at a
      time: a new owner replaces the old. HideAfterTicks > 0: hidden after
      that many timer ticks. }
    procedure ShowValueBubble(Owner: TJuceControl; const Text: string; const Anchor: TJuceRect;
      HideAfterTicks: Integer = 0);
    { Hides the bubble if Owner shows it (nil: whoever does). }
    procedure HideValueBubble(Owner: TJuceControl);
    function ValueBubbleOwner: TJuceControl;
    function ValueBubbleText: string;
    { Where the bubble is drawn (editor coordinates; W = 0 if none). }
    function ValueBubbleRect: TJuceRect;
    { Show Value for a meter slot until Process next publishes its meters:
      for a change that starts in the editor (a button the DSP reacts to, a
      key) so that the panel follows at once, also while the host is not
      processing audio. Meter returns it until then. }
    procedure PredictMeter(Index: Integer; Value: Single);
    function Meter(Index: Integer): Single; override;
    property Root: TJuceRootControl read FRoot;
    property Theme: TJuceTheme read FTheme;
    property Captured: TJuceControl read FCapture;
    property HoverControl: TJuceControl read FHover;
    { Editor timer rate for controls that need one (default 30 Hz). }
    property TimerHz: Integer read FTimerHz write FTimerHz;
  end;

function JuceMenuItem(Id: Integer; const Text: string; Flags: Integer = 0): TJuceMenuItem;
{ The theme new editors start with. }
function JuceDefaultTheme: TJuceTheme;

implementation

uses
  Math;

var
  GDefaultTheme: TJuceTheme;

function JuceMenuItem(Id: Integer; const Text: string; Flags: Integer): TJuceMenuItem;
begin
  Result.Id := Id;
  Result.Text := Text;
  Result.Flags := Flags;
end;

function JuceDefaultTheme: TJuceTheme;
begin
  if GDefaultTheme = nil then
    GDefaultTheme := TJuceTheme.Create;
  Result := GDefaultTheme;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceTheme                                                                   }
{ ---------------------------------------------------------------------------- }

constructor TJuceTheme.Create;
begin
  inherited Create;
  FBackground := $FF1E2024;
  FPanel := $FF2A2D33;
  FPanelBorder := $FF3C4049;
  FText := $FFE6E8EC;
  FTextDim := $FF9AA0AA;
  FAccent := $FFF0A030;
  FTrack := $FF15171A;
  FKnobBody := $FF4A4F59;
  FKnobPointer := $FFF4F5F7;
  FButtonFace := $FF3A3E46;
  FLedOn := $FFFF4A3A;
  FLedOff := $FF4A2420;
  FMeterLow := $FF3FCB6A;
  FMeterMid := $FFE8C840;
  FMeterHigh := $FFF04A3A;
  FMeterBack := $FF111215;
  FFontName := '';
  FFontSize := 13;
  FLink := $FF6AB0FF;
end;

procedure TJuceTheme.Assign(Source: TPersistent);
var
  S: TJuceTheme;
begin
  if Source is TJuceTheme then
  begin
    S := TJuceTheme(Source);
    FBackground := S.FBackground;
    FPanel := S.FPanel;
    FPanelBorder := S.FPanelBorder;
    FText := S.FText;
    FTextDim := S.FTextDim;
    FAccent := S.FAccent;
    FTrack := S.FTrack;
    FKnobBody := S.FKnobBody;
    FKnobPointer := S.FKnobPointer;
    FButtonFace := S.FButtonFace;
    FLedOn := S.FLedOn;
    FLedOff := S.FLedOff;
    FMeterLow := S.FMeterLow;
    FMeterMid := S.FMeterMid;
    FMeterHigh := S.FMeterHigh;
    FMeterBack := S.FMeterBack;
    FFontName := S.FFontName;
    FFontSize := S.FFontSize;
    FTooltipBackground := S.FTooltipBackground;
    FTooltipText := S.FTooltipText;
    FTooltipBorder := S.FTooltipBorder;
    FTooltipFontSize := S.FTooltipFontSize;
    FMenuBackground := S.FMenuBackground;
    FMenuText := S.FMenuText;
    FMenuHighlight := S.FMenuHighlight;
    FMenuHighlightText := S.FMenuHighlightText;
    FMenuHeader := S.FMenuHeader;
    FMenuFontSize := S.FMenuFontSize;
    FBubbleBackground := S.FBubbleBackground;
    FBubbleText := S.FBubbleText;
    FBubbleBorder := S.FBubbleBorder;
    FBubbleFontSize := S.FBubbleFontSize;
    FLink := S.FLink;
  end
  else
    inherited Assign(Source);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceControl                                                                 }
{ ---------------------------------------------------------------------------- }

constructor TJuceControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FControls := TList.Create;
  FVisible := True;
  FEnabled := True;
  FWidth := 40;
  FHeight := 40;
  if AOwner is TJuceControl then
    SetParent(TJuceControl(AOwner));
end;

destructor TJuceControl.Destroy;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if Ed <> nil then
  begin
    Detached;
    Ed.ControlGone(Self);
  end;
  { Children first (each removes itself from FControls). }
  while FControls.Count > 0 do
    TJuceControl(FControls[FControls.Count - 1]).Free;
  SetParent(nil);
  inherited Destroy;
  FControls.Free;
end;

procedure TJuceControl.SetParent(Value: TJuceControl);
var
  P: TJuceControl;
  Ed: TJuceEditor;
begin
  if Value = FParent then
    Exit;
  { never into our own subtree }
  P := Value;
  while P <> nil do
  begin
    if P = Self then
      raise EArgumentException.Create('TJuceControl.Parent: a control cannot be its own descendant');
    P := P.FParent;
  end;
  Ed := Editor;
  if (Ed <> nil) and (FParent <> nil) then
  begin
    Invalidate;
    DetachAll;
    Ed.ControlGone(Self);
  end;
  if FParent <> nil then
    FParent.FControls.Remove(Self);
  FParent := Value;
  if FParent <> nil then
  begin
    FParent.FControls.Add(Self);
    Ed := Editor;
    if (Ed <> nil) and Ed.IsOpen then
    begin
      AttachAll;
      Ed.UpdateTimer;
      Invalidate;
    end;
  end;
end;

procedure TJuceControl.SetLeft(Value: Integer);
begin
  SetBounds(Value, FTop, FWidth, FHeight);
end;

procedure TJuceControl.SetTop(Value: Integer);
begin
  SetBounds(FLeft, Value, FWidth, FHeight);
end;

procedure TJuceControl.SetWidth(Value: Integer);
begin
  SetBounds(FLeft, FTop, Value, FHeight);
end;

procedure TJuceControl.SetHeight(Value: Integer);
begin
  SetBounds(FLeft, FTop, FWidth, Value);
end;

procedure TJuceControl.SetBounds(ALeft, ATop, AWidth, AHeight: Integer);
begin
  AWidth := Max(0, Min(AWidth, 65536));
  AHeight := Max(0, Min(AHeight, 65536));
  ALeft := Max(-65536, Min(ALeft, 65536));
  ATop := Max(-65536, Min(ATop, 65536));
  if (ALeft = FLeft) and (ATop = FTop) and (AWidth = FWidth) and (AHeight = FHeight) then
    Exit;
  Invalidate;
  FLeft := ALeft;
  FTop := ATop;
  FWidth := AWidth;
  FHeight := AHeight;
  Invalidate;
end;

function TJuceControl.BoundsRect: TJuceRect;
begin
  Result := JuceRect(0, 0, FWidth, FHeight);
end;

procedure TJuceControl.SetVisible(Value: Boolean);
begin
  if Value = FVisible then
    Exit;
  FVisible := Value;
  if FParent <> nil then
    FParent.Invalidate;
end;

procedure TJuceControl.SetEnabled(Value: Boolean);
begin
  if Value = FEnabled then
    Exit;
  FEnabled := Value;
  Invalidate;
end;

procedure TJuceControl.SetCaption(const Value: string);
begin
  if Value = FCaption then
    Exit;
  FCaption := Value;
  Invalidate;
end;

procedure TJuceControl.SetHint(const Value: string);
var
  Ed: TJuceEditor;
begin
  if Value = FHint then
    Exit;
  FHint := Value;
  { the tooltip of the control under the mouse follows at once }
  Ed := Editor;
  if (Ed <> nil) and Ed.IsOpen and (Ed.FHover <> nil) then
    Ed.RefreshTooltip;
end;

function TJuceControl.GetControl(Index: Integer): TJuceControl;
begin
  Result := TJuceControl(FControls[Index]);
end;

function TJuceControl.GetControlCount: Integer;
begin
  Result := FControls.Count;
end;

function TJuceControl.Editor: TJuceEditor;
var
  P: TJuceControl;
begin
  P := Self;
  while P.FParent <> nil do
    P := P.FParent;
  if P is TJuceRootControl then
    Result := TJuceRootControl(P).FEditor
  else
    Result := nil;
end;

function TJuceControl.Theme: TJuceTheme;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if Ed <> nil then
    Result := Ed.Theme
  else
    Result := JuceDefaultTheme;
end;

function TJuceControl.Pick(C, ThemeColor: TJuceColor): TJuceColor;
begin
  if C = clJuceDefault then
    Result := ThemeColor
  else
    Result := C;
end;

function TJuceControl.AbsoluteX: Single;
var
  P: TJuceControl;
begin
  Result := 0;
  P := Self;
  while P <> nil do
  begin
    Result := Result + P.FLeft;
    P := P.FParent;
  end;
end;

function TJuceControl.AbsoluteY: Single;
var
  P: TJuceControl;
begin
  Result := 0;
  P := Self;
  while P <> nil do
  begin
    Result := Result + P.FTop;
    P := P.FParent;
  end;
end;

procedure TJuceControl.Invalidate;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if (Ed <> nil) and Ed.IsOpen and FVisible then
    Ed.Repaint(AbsoluteX, AbsoluteY, FWidth, FHeight);
end;

function TJuceControl.HitTest(X, Y: Single): Boolean;
begin
  Result := (X >= 0) and (Y >= 0) and (X < FWidth) and (Y < FHeight);
end;

function TJuceControl.ControlAt(X, Y: Single): TJuceControl;
var
  I: Integer;
  C: TJuceControl;
begin
  Result := nil;
  if not FVisible or not HitTest(X, Y) then
    Exit;
  for I := FControls.Count - 1 downto 0 do { topmost first }
  begin
    C := TJuceControl(FControls[I]);
    Result := C.ControlAt(X - C.FLeft, Y - C.FTop);
    if Result <> nil then
      Exit;
  end;
  Result := Self;
end;

procedure TJuceControl.Paint(Canvas: TJuceCanvas);
begin
end;

procedure TJuceControl.PaintControl(Canvas: TJuceCanvas);
begin
  try
    Paint(Canvas);
  except
    { one broken control must not stop the rest from drawing }
  end;
end;

function TJuceControl.FindControl(const AName: string): TJuceControl;
var
  I: Integer;
  C: TJuceControl;
begin
  Result := nil;
  if AName = '' then
    Exit;
  for I := 0 to FControls.Count - 1 do
  begin
    C := TJuceControl(FControls[I]);
    if SameText(C.Name, AName) then
      Exit(C);
  end;
  for I := 0 to FControls.Count - 1 do
  begin
    Result := TJuceControl(FControls[I]).FindControl(AName);
    if Result <> nil then
      Exit;
  end;
end;

procedure TJuceControl.PaintAll(Canvas: TJuceCanvas);
var
  I: Integer;
begin
  if not FVisible or (FWidth <= 0) or (FHeight <= 0) then
    Exit;
  Canvas.SaveState;
  try
    Canvas.Translate(FLeft, FTop);
    if Canvas.ClipRect(BoundsRect) then
    begin
      PaintControl(Canvas);
      I := 0;
      while I < FControls.Count do { re-read: a handler may have freed a sibling }
      begin
        TJuceControl(FControls[I]).PaintAll(Canvas);
        Inc(I);
      end;
    end;
  finally
    Canvas.RestoreState;
  end;
end;

procedure TJuceControl.MouseDown(X, Y: Single; Shift: TJuceShiftState);
begin
end;

procedure TJuceControl.MouseDrag(X, Y: Single; Shift: TJuceShiftState);
begin
end;

procedure TJuceControl.MouseUp(X, Y: Single; Shift: TJuceShiftState);
begin
end;

procedure TJuceControl.MouseMove(X, Y: Single; Shift: TJuceShiftState);
begin
end;

procedure TJuceControl.MouseEnter;
begin
end;

procedure TJuceControl.MouseLeave;
begin
end;

procedure TJuceControl.MouseDoubleClick(X, Y: Single; Shift: TJuceShiftState);
begin
end;

function TJuceControl.MouseWheel(X, Y, DX, DY: Single; Shift: TJuceShiftState): Boolean;
begin
  Result := False;
end;

procedure TJuceControl.ContextMenu(X, Y: Single);
var
  Handled: Boolean;
begin
  Handled := False;
  if Assigned(FOnContextMenu) then
    FOnContextMenu(Self, X, Y, Handled);
end;

procedure TJuceControl.Attached;
begin
end;

procedure TJuceControl.Detached;
begin
end;

procedure TJuceControl.Tick;
begin
end;

function TJuceControl.NeedsTimer: Boolean;
begin
  Result := False;
end;

procedure TJuceControl.ParameterChanged(Index: Integer; Normalised: Single);
begin
end;

procedure TJuceControl.AttachAll;
var
  I: Integer;
begin
  Attached;
  I := 0;
  while I < FControls.Count do { re-read: a handler may have freed a sibling }
  begin
    TJuceControl(FControls[I]).AttachAll;
    Inc(I);
  end;
end;

procedure TJuceControl.DetachAll;
var
  I: Integer;
begin
  I := 0;
  while I < FControls.Count do { re-read: a handler may have freed a sibling }
  begin
    TJuceControl(FControls[I]).DetachAll;
    Inc(I);
  end;
  Detached;
end;

procedure TJuceControl.TickAll;
var
  I: Integer;
begin
  if NeedsTimer then
    Tick;
  I := 0;
  while I < FControls.Count do { re-read: a handler may have freed a sibling }
  begin
    TJuceControl(FControls[I]).TickAll;
    Inc(I);
  end;
end;

procedure TJuceControl.ParameterChangedAll(Index: Integer; Normalised: Single);
var
  I: Integer;
begin
  ParameterChanged(Index, Normalised);
  I := 0;
  while I < FControls.Count do { re-read: a handler may have freed a sibling }
  begin
    TJuceControl(FControls[I]).ParameterChangedAll(Index, Normalised);
    Inc(I);
  end;
end;

function TJuceControl.AnyNeedsTimer: Boolean;
var
  I: Integer;
begin
  Result := NeedsTimer;
  I := 0;
  while not Result and (I < FControls.Count) do
  begin
    Result := TJuceControl(FControls[I]).AnyNeedsTimer;
    Inc(I);
  end;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceParamControl                                                            }
{ ---------------------------------------------------------------------------- }

constructor TJuceParamControl.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FParamIndex := -1;
end;

destructor TJuceParamControl.Destroy;
begin
  EndEdit; { never leave a gesture open }
  inherited Destroy;
end;

function TJuceParamControl.IsBound: Boolean;
begin
  Result := FParamIndex >= 0;
end;

procedure TJuceParamControl.SetParameterId(const Value: string);
var
  Ed: TJuceEditor;
begin
  if Value = FParameterId then
    Exit;
  EndEdit;
  FParameterId := Value;
  FParamIndex := -1;
  Ed := Editor;
  if (Ed <> nil) and Ed.IsOpen then
    Attached;
end;

procedure TJuceParamControl.Attached;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  FParamIndex := -1;
  if (Ed = nil) or (FParameterId = '') then
    Exit;
  FParamIndex := Ed.FindParameter(FParameterId);
  if FParamIndex >= 0 then
  begin
    FValue := Ed.ParamNormalised(FParamIndex);
    FValueSet := True;
    FDefaultValue := Ed.ParamDefault(FParamIndex);
    Invalidate;
  end;
end;

procedure TJuceParamControl.Detached;
begin
  EndEdit;
  HideBubble;
end;

procedure TJuceParamControl.ParameterChanged(Index: Integer; Normalised: Single);
begin
  if (Index <> FParamIndex) or (FParamIndex < 0) then
    Exit;
  if Normalised <> FValue then
  begin
    FValue := Normalised;
    FValueSet := True;
    Invalidate;
    if BubbleShown then
      ShowBubble(Editor.FBubbleTicks);
  end;
end;

function TJuceParamControl.BubbleAnchor: TJuceRect;
begin
  Result := BoundsRect;
end;

procedure TJuceParamControl.ShowBubble(HideAfterTicks: Integer);
var
  Ed: TJuceEditor;
  A: TJuceRect;
begin
  Ed := Editor;
  if Ed = nil then
    Exit;
  A := BubbleAnchor;
  A.X := A.X + AbsoluteX;
  A.Y := A.Y + AbsoluteY;
  Ed.ShowValueBubble(Self, ValueText, A, HideAfterTicks);
end;

procedure TJuceParamControl.HideBubble;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  if Ed <> nil then
    Ed.HideValueBubble(Self);
end;

function TJuceParamControl.BubbleShown: Boolean;
var
  Ed: TJuceEditor;
begin
  Ed := Editor;
  Result := (Ed <> nil) and (Ed.FBubbleOwner = Self);
end;

procedure TJuceParamControl.BeginEdit;
var
  Ed: TJuceEditor;
begin
  if FGestureOpen then
    Exit;
  FGestureOpen := True;
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Ed.BeginGesture(FParamIndex);
end;

procedure TJuceParamControl.EndEdit;
var
  Ed: TJuceEditor;
begin
  if not FGestureOpen then
    Exit;
  FGestureOpen := False;
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Ed.EndGesture(FParamIndex);
end;

procedure TJuceParamControl.SetDefaultValue(Value: Single);
begin
  FDefaultValue := Value;
  if not FValueSet then { an unbound control starts at its default (a bound one takes the parameter's value) }
  begin
    if IsNan(Value) or (Value <= 0) then
      FValue := 0
    else if Value > 1 then
      FValue := 1
    else
      FValue := Value;
    Invalidate;
  end;
end;

procedure TJuceParamControl.SetValueFromUser(Value: Single);
var
  Ed: TJuceEditor;
begin
  FValueSet := True;
  if IsNan(Value) or (Value <= 0) then
    Value := 0
  else if Value > 1 then
    Value := 1;
  if Value = FValue then
    Exit;
  FValue := Value;
  Ed := Editor;
  if (Ed <> nil) and IsBound then
    Ed.SetParamNormalised(FParamIndex, Value);
  Invalidate;
  if BubbleShown then
    ShowBubble(Ed.FBubbleTicks);
  DoChange;
end;

procedure TJuceParamControl.SetValue(Value: Single);
var
  WasOpen: Boolean;
begin
  WasOpen := FGestureOpen;
  BeginEdit;
  SetValueFromUser(Value);
  if not WasOpen then
    EndEdit;
end;

procedure TJuceParamControl.ResetToDefault;
begin
  SetValue(FDefaultValue);
end;

procedure TJuceParamControl.DoChange;
begin
  if Assigned(FOnChange) then
    FOnChange(Self);
end;

function TJuceParamControl.ValueText: string;
begin
  Result := ValueTextFor(FValue);
end;

function TJuceParamControl.ValueTextFor(Normalised: Single): string;
var
  Ed: TJuceEditor;
  Units: string;
begin
  Ed := Editor;
  if (Ed <> nil) and IsBound then
  begin
    Result := Ed.ParamText(FParamIndex, Normalised);
    Units := Ed.ParamUnits(FParamIndex);
    if (Result <> '') and (Units <> '') then
      Result := Result + ' ' + Units;
  end
  else
    Result := FormatFloat('0.00', Normalised);
  if Assigned(FOnValueText) then
    FOnValueText(Self, Normalised, Result);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceRootControl                                                             }
{ ---------------------------------------------------------------------------- }

procedure TJuceRootControl.Paint(Canvas: TJuceCanvas);
begin
  Canvas.SetColor(Theme.Background);
  Canvas.FillAll;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceHostCanvas                                                              }
{ ---------------------------------------------------------------------------- }

constructor TJuceHostCanvas.Create(AApi: PJcpEditorApi; AEditor: PJcpEditor; AGraphics: PJcpGraphics);
begin
  inherited Create;
  FApi := AApi;
  FEditor := AEditor;
  FG := AGraphics;
  FFontHeight := 14;
end;

procedure TJuceHostCanvas.SetColor(Color: TJuceColor);
begin
  FApi^.SetColour(FG, Color);
end;

procedure TJuceHostCanvas.SetLinearGradient(Color1: TJuceColor; X1, Y1: Single; Color2: TJuceColor; X2, Y2: Single);
begin
  FApi^.SetGradient(FG, Color1, X1, Y1, Color2, X2, Y2, 0);
end;

procedure TJuceHostCanvas.SetRadialGradient(Color1: TJuceColor; CX, CY: Single; Color2: TJuceColor; EdgeX, EdgeY: Single);
begin
  FApi^.SetGradient(FG, Color1, CX, CY, Color2, EdgeX, EdgeY, 1);
end;

procedure TJuceHostCanvas.FillAll;
begin
  FApi^.FillAll(FG);
end;

procedure TJuceHostCanvas.FillRect(const R: TJuceRect);
begin
  FApi^.FillRect(FG, R.X, R.Y, R.W, R.H);
end;

procedure TJuceHostCanvas.DrawRect(const R: TJuceRect; Thickness: Single);
begin
  FApi^.DrawRect(FG, R.X, R.Y, R.W, R.H, Thickness);
end;

procedure TJuceHostCanvas.FillRoundRect(const R: TJuceRect; Radius: Single);
begin
  FApi^.FillRoundedRect(FG, R.X, R.Y, R.W, R.H, Radius);
end;

procedure TJuceHostCanvas.DrawRoundRect(const R: TJuceRect; Radius, Thickness: Single);
begin
  FApi^.DrawRoundedRect(FG, R.X, R.Y, R.W, R.H, Radius, Thickness);
end;

procedure TJuceHostCanvas.FillEllipse(const R: TJuceRect);
begin
  FApi^.FillEllipse(FG, R.X, R.Y, R.W, R.H);
end;

procedure TJuceHostCanvas.DrawEllipse(const R: TJuceRect; Thickness: Single);
begin
  FApi^.DrawEllipse(FG, R.X, R.Y, R.W, R.H, Thickness);
end;

procedure TJuceHostCanvas.DrawLine(X1, Y1, X2, Y2, Thickness: Single);
begin
  FApi^.DrawLine(FG, X1, Y1, X2, Y2, Thickness);
end;

procedure TJuceHostCanvas.BeginPath;
begin
  FApi^.PathBegin(FG);
end;

procedure TJuceHostCanvas.MoveTo(X, Y: Single);
begin
  FApi^.PathMoveTo(FG, X, Y);
end;

procedure TJuceHostCanvas.LineTo(X, Y: Single);
begin
  FApi^.PathLineTo(FG, X, Y);
end;

procedure TJuceHostCanvas.QuadTo(CX, CY, X, Y: Single);
begin
  FApi^.PathQuadTo(FG, CX, CY, X, Y);
end;

procedure TJuceHostCanvas.CubicTo(C1X, C1Y, C2X, C2Y, X, Y: Single);
begin
  FApi^.PathCubicTo(FG, C1X, C1Y, C2X, C2Y, X, Y);
end;

procedure TJuceHostCanvas.AddArc(CX, CY, RX, RY, FromAngle, ToAngle: Single; StartNewSubPath: Boolean);
begin
  FApi^.PathArc(FG, CX, CY, RX, RY, FromAngle, ToAngle, Ord(StartNewSubPath));
end;

procedure TJuceHostCanvas.ClosePath;
begin
  FApi^.PathClose(FG);
end;

procedure TJuceHostCanvas.FillPath;
begin
  FApi^.FillPath(FG);
end;

procedure TJuceHostCanvas.StrokePath(Thickness: Single; Join: TJuceLineJoin; Cap: TJuceLineCap);
begin
  FApi^.StrokePath(FG, Thickness, Ord(Join), Ord(Cap));
end;

function FontFlags(Style: TJuceFontStyles): Int32;
begin
  Result := 0;
  if jfsBold in Style then Result := Result or JCP_FONT_BOLD;
  if jfsItalic in Style then Result := Result or JCP_FONT_ITALIC;
  if jfsUnderline in Style then Result := Result or JCP_FONT_UNDERLINE;
end;

procedure TJuceHostCanvas.SetFont(const Name: string; Height: Single; Style: TJuceFontStyles);
begin
  FFontName := JuceUtf8(Name);
  FFontHeight := Height;
  FFontStyle := FontFlags(Style);
  FApi^.SetFont(FG, PAnsiChar(FFontName), Height, FFontStyle);
end;

procedure TJuceHostCanvas.DrawText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign);
const
  H: array[TJuceAlign] of Int32 = (JCP_JUSTIFY_LEFT, JCP_JUSTIFY_HCENTRE, JCP_JUSTIFY_RIGHT);
  V: array[TJuceVAlign] of Int32 = (JCP_JUSTIFY_TOP, JCP_JUSTIFY_VCENTRE, JCP_JUSTIFY_BOTTOM);
var
  U: UTF8String;
begin
  U := JuceUtf8(Text);
  FApi^.DrawText(FG, PAnsiChar(U), R.X, R.Y, R.W, R.H, H[Align] or V[VAlign], JCP_TEXT_ELLIPSIS);
end;

procedure TJuceHostCanvas.DrawFittedText(const Text: string; const R: TJuceRect; Align: TJuceAlign; VAlign: TJuceVAlign);
const
  H: array[TJuceAlign] of Int32 = (JCP_JUSTIFY_LEFT, JCP_JUSTIFY_HCENTRE, JCP_JUSTIFY_RIGHT);
  V: array[TJuceVAlign] of Int32 = (JCP_JUSTIFY_TOP, JCP_JUSTIFY_VCENTRE, JCP_JUSTIFY_BOTTOM);
var
  U: UTF8String;
begin
  U := JuceUtf8(Text);
  FApi^.DrawText(FG, PAnsiChar(U), R.X, R.Y, R.W, R.H, H[Align] or V[VAlign], JCP_TEXT_FIT);
end;

function TJuceHostCanvas.TextWidth(const Text: string): Single;
var
  U: UTF8String;
begin
  U := JuceUtf8(Text);
  Result := FApi^.GetTextWidth(FEditor, PAnsiChar(U), PAnsiChar(FFontName), FFontHeight, FFontStyle);
end;

procedure TJuceHostCanvas.DrawImage(Image: TJuceImage; const Dest, Source: TJuceRect; Opacity: Single);
begin
  if Image is TJuceHostImage then
    FApi^.DrawImage(FG, TJuceHostImage(Image).FHandle, Dest.X, Dest.Y, Dest.W, Dest.H,
      Source.X, Source.Y, Source.W, Source.H, Opacity);
end;

procedure TJuceHostCanvas.SaveState;
begin
  FApi^.SaveState(FG);
end;

procedure TJuceHostCanvas.RestoreState;
begin
  FApi^.RestoreState(FG);
end;

function TJuceHostCanvas.ClipRect(const R: TJuceRect): Boolean;
begin
  Result := FApi^.ClipRect(FG, R.X, R.Y, R.W, R.H) <> 0;
end;

procedure TJuceHostCanvas.Translate(DX, DY: Single);
begin
  FApi^.Translate(FG, DX, DY);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceHostImage                                                               }
{ ---------------------------------------------------------------------------- }

function TJuceHostImage.Width: Integer;
begin
  Result := FWidth;
end;

function TJuceHostImage.Height: Integer;
begin
  Result := FHeight;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceEditor                                                                  }
{ ---------------------------------------------------------------------------- }

constructor TJuceEditor.Create(APlugin: TJucePlugin);
begin
  inherited Create(APlugin);
  FTheme := TJuceTheme.Create;
  FTheme.Assign(JuceDefaultTheme);
  FImages := TStringList.Create;
  FImages.CaseSensitive := False;
  FTimerHz := 30;
  FNextMenuId := 1;
  FRoot := TJuceRootControl.Create(nil);
  FRoot.FEditor := Self;
  FRoot.SetBounds(0, 0, Width, Height);
end;

destructor TJuceEditor.Destroy;
var
  I: Integer;
begin
  FDestroying := True;
  if FRoot <> nil then
    FRoot.DetachAll; { closes any gesture still open }
  FCapture := nil;
  FHover := nil;
  FRoot.Free;
  FRoot := nil;
  if FImages <> nil then
    for I := 0 to FImages.Count - 1 do
      FreeCanvasImage(TJuceImage(FImages.Objects[I]));
  FImages.Free;
  FTheme.Free;
  inherited Destroy;
end;

procedure TJuceEditor.Opened;
begin
  FRoot.SetBounds(0, 0, Width, Height);
  FRoot.AttachAll;
  ApplyLook;
  UpdateTimer;
end;

procedure TJuceEditor.ApplyLook;
var
  L: TJcpEditorLook;
  F: UTF8String;

  function Size(V: Single): Single;
  begin
    if IsNan(V) or IsInfinite(V) or (V <= 0) then
      Result := 0
    else
      Result := V;
  end;

begin
  FillChar(L, SizeOf(L), 0);
  L.StructSize := SizeOf(L);
  L.TooltipBackground := FTheme.TooltipBackground;
  L.TooltipText := FTheme.TooltipText;
  L.TooltipOutline := FTheme.TooltipBorder;
  L.MenuBackground := FTheme.MenuBackground;
  L.MenuText := FTheme.MenuText;
  L.MenuHighlight := FTheme.MenuHighlight;
  L.MenuHighlightText := FTheme.MenuHighlightText;
  L.MenuHeaderText := FTheme.MenuHeader;
  L.TooltipFontHeight := Size(FTheme.TooltipFontSize);
  L.MenuFontHeight := Size(FTheme.MenuFontSize);
  F := JuceUtf8(FTheme.FontName);
  if Length(F) > 256 then
    F := ''; { the wrapper would refuse the whole look: keep the colours, default font }
  L.FontName := PAnsiChar(F);
  SetLook(@L);
end;

procedure TJuceEditor.ThemeChanged;
begin
  ApplyLook;
  Repaint;
end;

function TJuceEditor.SetScalable(MinScale, MaxScale: Single; CornerResizer: Boolean): Boolean;
begin
  Result := SetDesignSize(Width, Height, MinScale, MaxScale, CornerResizer);
  FRoot.SetBounds(0, 0, Width, Height);
end;

function TJuceEditor.ProcessStamp: Integer;
begin
  if Plugin <> nil then
    Result := Plugin.ProcessCount
  else
    Result := 0;
end;

procedure TJuceEditor.PredictMeter(Index: Integer; Value: Single);
begin
  if (Index < 0) or (Index >= JCP_MAX_METERS) or IsNan(Value) or IsInfinite(Value) then
    Exit;
  FPredicted[Index].Active := True;
  FPredicted[Index].Value := Value;
  FPredicted[Index].Stamp := ProcessStamp;
end;

function TJuceEditor.Meter(Index: Integer): Single;
var
  D: Int64;
begin
  if (Index >= 0) and (Index < JCP_MAX_METERS) and FPredicted[Index].Active then
  begin
    { Process takes the editor's input at the top of a block and publishes
      its meters at the end: two block ends after the prediction, the
      meters are certainly the DSP's answer to it. }
    D := Int64(ProcessStamp) - Int64(FPredicted[Index].Stamp);
    if (D >= 0) and (D < 2) then
      Exit(FPredicted[Index].Value);
    FPredicted[Index].Active := False;
  end;
  Result := inherited Meter(Index);
end;

{ The value bubble }

const
  BubbleArrow = 6;   { the arrow's length }

function TJuceEditor.ValueBubbleOwner: TJuceControl;
begin
  Result := FBubbleOwner;
end;

function TJuceEditor.ValueBubbleText: string;
begin
  if FBubbleOwner <> nil then
    Result := FBubbleText
  else
    Result := '';
end;

function TJuceEditor.ValueBubbleRect: TJuceRect;
begin
  if FBubbleOwner <> nil then
    Result := FBubbleRect
  else
    Result := JuceRect(0, 0, 0, 0);
end;

function BubbleFontSize(Theme: TJuceTheme): Single;
begin
  Result := Theme.BubbleFontSize;
  if IsNan(Result) or (Result <= 0) or (Result > 200) then
    Result := Theme.FontSize + 2;
  if IsNan(Result) or (Result < 6) then
    Result := 6;
end;

procedure TJuceEditor.PlaceBubble;
var
  Size, W, H, X, Y: Single;
  function Sane(V: Single): Single;
  begin
    if IsNan(V) then
      Result := 0
    else
      Result := Max(-65536, Min(V, 65536));
  end;

begin
  FBubbleAnchor := JuceRect(Sane(FBubbleAnchor.X), Sane(FBubbleAnchor.Y), Max(0, Sane(FBubbleAnchor.W)),
    Max(0, Sane(FBubbleAnchor.H)));
  Size := BubbleFontSize(FTheme);
  W := TextWidth(FBubbleText, FTheme.FontName, Size, JCP_FONT_BOLD);
  if IsNan(W) or (W <= 0) then
    W := Length(FBubbleText) * Size * 0.6; { no wrapper (design time, tests): an estimate }
  W := Min(Max(W + 16, 24), Max(24, Width - 4));
  H := Size + 10;
  { above or below the anchor, wherever there is more room (as JUCE's bubbles) }
  FBubbleBelow := (Height - (FBubbleAnchor.Y + FBubbleAnchor.H)) > FBubbleAnchor.Y;
  X := FBubbleAnchor.X + FBubbleAnchor.W / 2 - W / 2;
  X := Max(2, Min(X, Width - W - 2));
  if FBubbleBelow then
    Y := FBubbleAnchor.Y + FBubbleAnchor.H + BubbleArrow + 1
  else
    Y := FBubbleAnchor.Y - BubbleArrow - 1 - H;
  FBubbleRect := JuceRect(Round(X), Round(Y), Round(W), Round(H));
end;

procedure TJuceEditor.InvalidateBubble;
begin
  if (FBubbleOwner <> nil) and IsOpen and not FDestroying then
    Repaint(FBubbleRect.X - 4, FBubbleRect.Y - BubbleArrow - 4, FBubbleRect.W + 8, FBubbleRect.H + 2 * BubbleArrow + 8);
end;

procedure TJuceEditor.ShowValueBubble(Owner: TJuceControl; const Text: string; const Anchor: TJuceRect;
  HideAfterTicks: Integer);
begin
  if (Owner = nil) or FDestroying then
    Exit;
  InvalidateBubble;
  FBubbleOwner := Owner;
  FBubbleText := Text;
  FBubbleAnchor := Anchor;
  FBubbleTicks := Max(0, HideAfterTicks);
  PlaceBubble;
  InvalidateBubble;
  if FBubbleTicks > 0 then
    UpdateTimer;
end;

procedure TJuceEditor.HideValueBubble(Owner: TJuceControl);
begin
  if (FBubbleOwner = nil) or ((Owner <> nil) and (Owner <> FBubbleOwner)) then
    Exit;
  InvalidateBubble;
  FBubbleOwner := nil;
  FBubbleTicks := 0;
  UpdateTimer;
end;

procedure TJuceEditor.PaintBubble(Canvas: TJuceCanvas);
var
  R: TJuceRect;
  Bg, Fg, Bd: TJuceColor;
  TipX, TipY, Rad, A, Edge: Single;
begin
  if (FBubbleOwner = nil) or (FBubbleRect.W <= 0) then
    Exit;
  Bg := FTheme.BubbleBackground;
  if Bg = clJuceDefault then
    Bg := FTheme.TooltipBackground;
  if Bg = clJuceDefault then
    Bg := FTheme.Panel;
  Fg := FTheme.BubbleText;
  if Fg = clJuceDefault then
    Fg := FTheme.TooltipText;
  if Fg = clJuceDefault then
    Fg := FTheme.Text;
  Bd := FTheme.BubbleBorder;
  if Bd = clJuceDefault then
    Bd := FTheme.TooltipBorder;
  if Bd = clJuceDefault then
    Bd := FTheme.PanelBorder;
  R := FBubbleRect;
  Rad := Min(5, R.H / 3);
  A := 5;
  { a soft shadow, as JUCE's bubbles have }
  Canvas.SetColor($1C000000);
  Canvas.FillRoundRect(JuceInset(R, -3), Rad + 3);
  Canvas.FillRoundRect(JuceInset(R, -2), Rad + 2);
  Canvas.FillRoundRect(JuceInset(R, -1), Rad + 1);
  TipX := Max(R.X + Rad + A, Min(FBubbleAnchor.X + FBubbleAnchor.W / 2, R.X + R.W - Rad - A));
  { a rounded box with an arrow towards the anchor, clockwise from the top left }
  Canvas.BeginPath;
  Canvas.MoveTo(R.X + Rad, R.Y);
  if FBubbleBelow then
  begin
    TipY := R.Y - BubbleArrow;
    Canvas.LineTo(TipX - A, R.Y);
    Canvas.LineTo(TipX, TipY);
    Canvas.LineTo(TipX + A, R.Y);
  end;
  Canvas.LineTo(R.X + R.W - Rad, R.Y);
  Canvas.AddArc(R.X + R.W - Rad, R.Y + Rad, Rad, Rad, 0, Pi / 2, False);
  Canvas.LineTo(R.X + R.W, R.Y + R.H - Rad);
  Canvas.AddArc(R.X + R.W - Rad, R.Y + R.H - Rad, Rad, Rad, Pi / 2, Pi, False);
  Edge := R.Y + R.H;
  if not FBubbleBelow then
  begin
    TipY := Edge + BubbleArrow;
    Canvas.LineTo(TipX + A, Edge);
    Canvas.LineTo(TipX, TipY);
    Canvas.LineTo(TipX - A, Edge);
  end;
  Canvas.LineTo(R.X + Rad, Edge);
  Canvas.AddArc(R.X + Rad, R.Y + R.H - Rad, Rad, Rad, Pi, 3 * Pi / 2, False);
  Canvas.LineTo(R.X, R.Y + Rad);
  Canvas.AddArc(R.X + Rad, R.Y + Rad, Rad, Rad, 3 * Pi / 2, 2 * Pi, False);
  Canvas.ClosePath;
  Canvas.SetColor(Bg);
  Canvas.FillPath;
  Canvas.SetColor(Bd);
  Canvas.StrokePath(1, jljMiter, jlcButt);
  Canvas.SetFont(FTheme.FontName, BubbleFontSize(FTheme), [jfsBold]);
  Canvas.SetColor(Fg);
  Canvas.DrawText(FBubbleText, R, jaCenter, jvaCenter);
end;

procedure TJuceEditor.UpdateTimer;
begin
  if not IsOpen or FDestroying then
    Exit;
  if FRoot.AnyNeedsTimer or (FBubbleTicks > 0) then
  begin
    if not FTimerRunning then
    begin
      StartTimer(FTimerHz);
      FTimerRunning := True;
    end;
  end
  else if FTimerRunning then
  begin
    StopTimer;
    FTimerRunning := False;
  end;
end;

procedure TJuceEditor.Resized;
begin
  FRoot.SetBounds(0, 0, Width, Height);
  Repaint;
end;

procedure TJuceEditor.PaintTo(Canvas: TJuceCanvas);
begin
  FRoot.PaintAll(Canvas);
  PaintBubble(Canvas); { over every control }
end;

procedure TJuceEditor.Paint(G: PJcpGraphics);
var
  Canvas: TJuceHostCanvas;
begin
  Canvas := TJuceHostCanvas.Create(Api, Handle, G);
  try
    PaintTo(Canvas);
  finally
    Canvas.Free;
  end;
end;

function TJuceEditor.Shift(Modifiers: Integer): TJuceShiftState;
begin
  Result := [];
  if Modifiers and JCP_MOD_SHIFT <> 0 then Include(Result, jssShift);
  if Modifiers and JCP_MOD_CTRL <> 0 then Include(Result, jssCtrl);
  if Modifiers and JCP_MOD_ALT <> 0 then Include(Result, jssAlt);
  if Modifiers and JCP_MOD_CMD <> 0 then Include(Result, jssCmd);
  if Modifiers and JCP_MOD_LEFT <> 0 then Include(Result, jssLeft);
  if Modifiers and JCP_MOD_RIGHT <> 0 then Include(Result, jssRight);
  if Modifiers and JCP_MOD_MIDDLE <> 0 then Include(Result, jssMiddle);
  if Modifiers and JCP_MOD_POPUP <> 0 then Include(Result, jssPopup);
end;

procedure TJuceEditor.SetHover(Control: TJuceControl);
begin
  if Control = FHover then
    Exit;
  if FHover <> nil then
  begin
    FHover.FHovered := False;
    FHover.MouseLeave;
  end;
  FHover := Control;
  if FHover <> nil then
  begin
    FHover.FHovered := True;
    FHover.MouseEnter;
  end;
  RefreshTooltip;
end;

procedure TJuceEditor.RefreshTooltip;
var
  P: TJuceControl;
  Tip: string;
begin
  Tip := '';
  P := FHover;
  while (P <> nil) and (Tip = '') do
  begin
    Tip := P.Hint;
    P := P.FParent;
  end;
  SetTooltip(Tip);
end;

procedure TJuceEditor.MouseEvent(const E: TJcpMouseEvent);
var
  S: TJuceShiftState;
  Hit, C, Parent: TJuceControl;
begin
  S := Shift(E.Modifiers);
  case E.Kind of
    JCP_MOUSE_MOVE, JCP_MOUSE_ENTER:
      begin
        Hit := FRoot.ControlAt(E.X, E.Y);
        if (Hit <> nil) and not Hit.Enabled then
          Hit := nil;
        SetHover(Hit);
        if (FHover <> nil) and (E.Kind = JCP_MOUSE_MOVE) then
          FHover.MouseMove(E.X - FHover.AbsoluteX, E.Y - FHover.AbsoluteY, S);
      end;
    JCP_MOUSE_EXIT:
      SetHover(nil);
    JCP_MOUSE_DOWN:
      begin
        Hit := FRoot.ControlAt(E.X, E.Y);
        if (Hit = nil) or not Hit.Enabled then
          Exit;
        if jssPopup in S then
          Hit.ContextMenu(E.X - Hit.AbsoluteX, E.Y - Hit.AbsoluteY)
        else
        begin
          FCapture := Hit;
          Hit.MouseDown(E.X - Hit.AbsoluteX, E.Y - Hit.AbsoluteY, S);
        end;
      end;
    JCP_MOUSE_DRAG:
      if FCapture <> nil then
        FCapture.MouseDrag(E.X - FCapture.AbsoluteX, E.Y - FCapture.AbsoluteY, S);
    JCP_MOUSE_UP:
      if FCapture <> nil then
      begin
        C := FCapture;
        FCapture := nil;
        C.MouseUp(E.X - C.AbsoluteX, E.Y - C.AbsoluteY, S);
      end;
    JCP_MOUSE_DOUBLE_CLICK:
      begin
        Hit := FRoot.ControlAt(E.X, E.Y);
        if (Hit <> nil) and Hit.Enabled and not (jssPopup in S) then
          Hit.MouseDoubleClick(E.X - Hit.AbsoluteX, E.Y - Hit.AbsoluteY, S);
      end;
    JCP_MOUSE_WHEEL:
      begin
        C := FRoot.ControlAt(E.X, E.Y);
        while C <> nil do
        begin
          Parent := C.FParent; { read before the handler runs }
          if C.Enabled and C.MouseWheel(E.X - C.AbsoluteX, E.Y - C.AbsoluteY, E.WheelDX, E.WheelDY, S) then
            Break;
          C := Parent;
        end;
      end;
  end;
end;

procedure TJuceEditor.ControlGone(Control: TJuceControl);
var
  P: TJuceControl;
begin
  { A menu answer must not go to a handler on a freed control (the menu id
    stays pending, so the answer is consumed and dropped). }
  if Assigned(FOnMenuResult) and (TMethod(FOnMenuResult).Data = Pointer(Control)) then
    FOnMenuResult := nil;
  { Forget the control (and anything below it) if we were tracking it. }
  P := FCapture;
  while P <> nil do
  begin
    if P = Control then
    begin
      FCapture := nil;
      Break;
    end;
    P := P.FParent;
  end;
  P := FHover;
  while P <> nil do
  begin
    if P = Control then
    begin
      FHover := nil;
      Break;
    end;
    P := P.FParent;
  end;
  P := FBubbleOwner;
  while P <> nil do
  begin
    if P = Control then
    begin
      FBubbleOwner := nil;
      FBubbleTicks := 0;
      Break;
    end;
    P := P.FParent;
  end;
end;

procedure TJuceEditor.TimerTick;
begin
  FRoot.TickAll;
  if FBubbleTicks > 0 then
  begin
    Dec(FBubbleTicks);
    if FBubbleTicks = 0 then
      HideValueBubble(nil);
  end;
end;

procedure TJuceEditor.ParameterChanged(Index: Integer; Normalised: Single);
begin
  FRoot.ParameterChangedAll(Index, Normalised);
end;

function TJuceEditor.PopupMenu(const Items: array of TJuceMenuItem; X, Y: Single; Handler: TJuceMenuResultEvent): Integer;
var
  Id: Integer;
begin
  Result := 0;
  if FMenuId <> 0 then
    Exit; { one at a time }
  Id := FNextMenuId;
  if FNextMenuId < High(Integer) then
    Inc(FNextMenuId)
  else
    FNextMenuId := 1;
  ApplyLook; { the theme may have changed since the editor opened }
  if ShowPopupMenu(Id, Items, X, Y) then
  begin
    FMenuId := Id;
    FOnMenuResult := Handler;
    Result := Id;
  end;
end;

procedure TJuceEditor.PopupResult(MenuId, ItemId: Integer);
var
  Handler: TJuceMenuResultEvent;
begin
  if (MenuId = 0) or (MenuId <> FMenuId) then
    Exit;
  Handler := FOnMenuResult;
  FMenuId := 0;
  FOnMenuResult := nil;
  if Assigned(Handler) then
    Handler(Self, MenuId, ItemId);
end;

function TJuceEditor.CreateCanvasImage(const Data: TBytes): TJuceImage;
var
  H, W, Ht: Integer;
  Img: TJuceHostImage;
begin
  Result := nil;
  H := CreateImage(Data);
  if H = 0 then
    Exit;
  if not ImageSize(H, W, Ht) then
  begin
    DestroyImage(H);
    Exit;
  end;
  Img := TJuceHostImage.Create;
  Img.FHandle := H;
  Img.FWidth := W;
  Img.FHeight := Ht;
  Result := Img;
end;

procedure TJuceEditor.FreeCanvasImage(Image: TJuceImage);
begin
  if Image is TJuceHostImage then
    DestroyImage(TJuceHostImage(Image).FHandle);
  Image.Free;
end;

function TJuceEditor.AddImage(const Name: string; const Data: TBytes): Boolean;
var
  I: Integer;
  Img: TJuceImage;
begin
  Result := False;
  Img := CreateCanvasImage(Data);
  if Img = nil then
    Exit;
  I := FImages.IndexOf(Name);
  if I >= 0 then
  begin
    FreeCanvasImage(TJuceImage(FImages.Objects[I]));
    FImages.Delete(I);
  end;
  FImages.AddObject(Name, Img);
  Repaint;
  Result := True;
end;

function TJuceEditor.ImageCount: Integer;
begin
  Result := FImages.Count;
end;

function TJuceEditor.FindControl(const AName: string): TJuceControl;
begin
  Result := FRoot.FindControl(AName);
end;

function TJuceEditor.FindImage(const Name: string): TJuceImage;
var
  I: Integer;
begin
  Result := nil;
  if Name = '' then
    Exit;
  I := FImages.IndexOf(Name);
  if I >= 0 then
    Result := TJuceImage(FImages.Objects[I]);
end;

initialization

finalization
  GDefaultTheme.Free;
  GDefaultTheme := nil;

end.
