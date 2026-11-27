{
  JucePlugin.pas - write VST3 / AU / LV2 / Standalone plug-ins in Pascal.

  Your plug-in is a Pascal *library* that:
    1. declares its parameters (JuceAddFloatParameter, ...),
    2. registers a TJucePlugin subclass and its kind (JuceRegisterPlugin),
    3. exports pascaljuce_plugin_entry.

    library MySynth;
    uses JucePlugin, MySynthUnit;
    exports pascaljuce_plugin_entry;
    begin
      ParamGain := JuceAddFloatParameter('gain', 'Gain', 0, 1, 0.8);
      JuceRegisterPlugin(TMySynth, jkInstrument);
    end.

  Declaration mistakes (duplicate ids, bad ranges, ...) do not raise - that
  would crash inside the host's DLL loader. They are recorded and reported
  by the wrapper ("refused to load: ..."), shown in the plug-in window and
  the host's log. JuceDeclarationError returns the first one.

  Threading: Process runs on the host's audio thread - no allocation, locks,
  file I/O or UI there. Everything else runs on a non-real-time thread.
  LoadState/SaveState never run concurrently with Process. Exceptions are
  caught at the boundary; an exception in Process silences that block.

  Security: LoadState data comes from project files and MIDI comes from
  devices and hosts: validate sizes and ranges before using them.

  Works with Delphi (Win64) and Free Pascal (Delphi mode is set below).
}
unit JucePlugin;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$PACKRECORDS C}
  {$PACKENUM 4}
{$ELSE}
  {$ALIGN 8}
  {$MINENUMSIZE 4}
{$ENDIF}

interface

uses
{$IFDEF FPC}{$IFDEF UNIX}
  cthreads, { hosts call in from many threads: FPC needs a thread manager }
{$ENDIF}{$ENDIF}
  SysUtils, JuceTypes;

const
  JCP_ABI_VERSION = 2;

  JCP_PARAM_FLAG_AUTOMATABLE = 1;

  { Custom editors: see juce_c_plugin.h }
  JCP_EDITOR_MIN_SIZE = 16;
  JCP_EDITOR_MAX_SIZE = 4096;
  JCP_MAX_METERS = 64;

  { Oscilloscope feed (TJucePlugin.ScopeWrite, TJuceEditorBase.ScopeRead):
    samples kept per channel, and the most one ScopeRead returns. }
  JUCE_SCOPE_CAPACITY = 32768;
  JUCE_SCOPE_MAX_READ = JUCE_SCOPE_CAPACITY div 2;
  { ScopeRead channels }
  JUCE_SCOPE_LEFT = 0;
  JUCE_SCOPE_RIGHT = 1;
  JUCE_SCOPE_MIX = 2;   { (left + right) / 2 }

  JCP_MOUSE_MOVE = 0;
  JCP_MOUSE_DOWN = 1;
  JCP_MOUSE_DRAG = 2;
  JCP_MOUSE_UP = 3;
  JCP_MOUSE_ENTER = 4;
  JCP_MOUSE_EXIT = 5;
  JCP_MOUSE_DOUBLE_CLICK = 6;
  JCP_MOUSE_WHEEL = 7;

  JCP_MOD_SHIFT = 1;
  JCP_MOD_CTRL = 2;
  JCP_MOD_ALT = 4;
  JCP_MOD_CMD = 8;
  JCP_MOD_LEFT = 16;
  JCP_MOD_RIGHT = 32;
  JCP_MOD_MIDDLE = 64;
  JCP_MOD_POPUP = 128;

  JCP_MENU_DISABLED = 1;
  JCP_MENU_TICKED = 2;
  JCP_MENU_SEPARATOR = 4;
  JCP_MENU_HEADER = 8;

  JCP_FONT_BOLD = 1;
  JCP_FONT_ITALIC = 2;
  JCP_FONT_UNDERLINE = 4;

  JCP_JUSTIFY_LEFT = 1;
  JCP_JUSTIFY_RIGHT = 2;
  JCP_JUSTIFY_HCENTRE = 4;
  JCP_JUSTIFY_TOP = 8;
  JCP_JUSTIFY_BOTTOM = 16;
  JCP_JUSTIFY_VCENTRE = 32;

  { draw_text: text wider than its rectangle }
  JCP_TEXT_CLIP = 0;
  JCP_TEXT_ELLIPSIS = 1;
  JCP_TEXT_FIT = 2;   { squeezed sideways to 70% at most, then shortened }

  { set_design_size }
  JCP_SCALE_CORNER_RESIZER = 1;
  JCP_EDITOR_MIN_SCALE = 0.25;
  JCP_EDITOR_MAX_SCALE = 4.0;
  { open_url }
  JCP_MAX_URL = 2048;

  { choose_file }
  JCP_FILE_OPEN = 0;
  JCP_FILE_SAVE = 1;
  JCP_MAX_FILE_PATTERNS = 256;
  JCP_MAX_PATH = 4096;

  { host programs }
  JCP_MAX_PROGRAMS = 1024;
  JCP_MAX_PROGRAM_NAME = 256;

type
  TJucePluginKind = (jkInstrument, jkEffect, jkMidiEffect);   { = JCP_KIND_* }
  TJuceParameterKind = (jpkFloat, jpkInt, jpkBool, jpkChoice); { = JCP_PARAM_* }

  { --- C ABI records (mirror plugin/include/juce_c_plugin.h) --- }

  TJcpParameterInfo = record
    StructSize: Int32;
    Kind: Int32;
    Id: PAnsiChar;
    Name: PAnsiChar;
    LabelText: PAnsiChar;
    Choices: PAnsiChar;
    MinValue: Single;
    MaxValue: Single;
    DefaultValue: Single;
    Step: Single;
    Flags: Int32;
    VersionHint: Int32;
  end;
  PJcpParameterInfo = ^TJcpParameterInfo;

  TJuceMidiEvent = record
    Data: PByte;            { one complete message; valid only during Process }
    Size: Int32;
    SamplePosition: Int32;
  end;
  PJuceMidiEvent = ^TJuceMidiEvent;
  TJuceMidiEventArray = array[0..$FFFFF] of TJuceMidiEvent;
  PJuceMidiEventArray = ^TJuceMidiEventArray;

  TJuceTransport = record
    StructSize: Int32;
    HasInfo: Int32;          { 0 = host supplied no position (defaults used) }
    Bpm: Double;
    PpqPosition: Double;
    PpqBarStart: Double;
    TimeInSamples: Int64;
    TimeInSeconds: Double;
    IsPlaying: Int32;
    IsRecording: Int32;
    IsLooping: Int32;
    TimeSigNumerator: Int32;
    TimeSigDenominator: Int32;
    Reserved: Int32;
  end;
  PJuceTransport = ^TJuceTransport;

  { Everything Process needs for one block. Audio is processed in place:
    inputs (effects) arrive in Channels and outputs are written there too. }
  TJuceProcessContext = record
    StructSize: Int32;
    NumSamples: Int32;
    Channels: PJuceChannelArray;       { Channels^[0..NumChannels-1]^[0..NumSamples-1] }
    MidiEvents: PJuceMidiEventArray;   { prefer MidiEvent(I) }
    Parameters: PJuceSingleArray;      { prefer Param(I) }
    Transport: PJuceTransport;
    NumChannels: Int32;
    NumInputChannels: Int32;
    NumOutputChannels: Int32;
    NumMidiEvents: Int32;
    NumParameters: Int32;
    MidiEventSize: Int32;
    MidiEventsDropped: Int32;          { events beyond the per-block limit (16384) }
    IsNonRealtime: Int32;              { 1 while the host renders offline }
    { Bounds-checked accessors }
    function Param(Index: Integer): Single;              { 0 if out of range }
    function Channel(Index: Integer): PJuceSampleArray;  { nil if out of range }
    function MidiEvent(Index: Integer): PJuceMidiEvent;  { nil if out of range }
  end;
  PJuceProcessContext = ^TJuceProcessContext;

  PJcpHost = Pointer;

  TJcpAddMidiOutput = procedure(Host: PJcpHost; Data: PByte; Size, SamplePosition: Int32); cdecl;
  TJcpSetParameter = procedure(Host: PJcpHost; Index: Int32; Value: Single); cdecl;
  TJcpGetParameter = function(Host: PJcpHost; Index: Int32): Single; cdecl;
  TJcpSetLatency = procedure(Host: PJcpHost; Samples: Int32); cdecl;
  TJcpLog = procedure(Host: PJcpHost; Message: PAnsiChar); cdecl;
  TJcpGetSampleRate = function(Host: PJcpHost): Double; cdecl;
  TJcpGesture = procedure(Host: PJcpHost; Index: Int32); cdecl;
  TJcpHostExtension = function(Host: PJcpHost; Id: PAnsiChar): Pointer; cdecl;

  TJcpSetMeter = procedure(Host: PJcpHost; Index: Int32; Value: Single); cdecl;

  TJcpHostApi = record
    StructSize: Int32;
    AbiVersion: Int32;
    AddMidiOutput: TJcpAddMidiOutput;
    SetParameter: TJcpSetParameter;
    GetParameter: TJcpGetParameter;
    SetLatencySamples: TJcpSetLatency;
    Log: TJcpLog;
    GetSampleRate: TJcpGetSampleRate;
    BeginParameterGesture: TJcpGesture;
    EndParameterGesture: TJcpGesture;
    GetExtension: TJcpHostExtension;
    SetMeter: TJcpSetMeter;           { custom editors; absent in older wrappers }
    ProgramsChanged: procedure(Host: PJcpHost); cdecl;  { host programs; absent in older wrappers }
  end;
  PJcpHostApi = ^TJcpHostApi;

  { --- Custom editors (see "Custom editors" in juce_c_plugin.h) --- }

  PJcpEditor = Pointer;    { the wrapper's handle for one open editor }
  PJcpGraphics = Pointer;  { a drawing context: valid only inside Paint }

  TJcpMouseEvent = record
    StructSize: Int32;
    Kind: Int32;            { JCP_MOUSE_* }
    X, Y: Single;
    Modifiers: Int32;       { JCP_MOD_* }
    ClickCount: Int32;
    WheelDX, WheelDY: Single;
  end;
  PJcpMouseEvent = ^TJcpMouseEvent;

  TJcpMenuItem = record
    Id: Int32;
    Flags: Int32;           { JCP_MENU_* }
    Text: PAnsiChar;
  end;
  PJcpMenuItem = ^TJcpMenuItem;

  TJcpEditorVTable = record
    StructSize: Int32;
    Reserved: Int32;
    Destroy: procedure(Ed: Pointer); cdecl;
    Paint: procedure(Ed: Pointer; G: PJcpGraphics); cdecl;
    Mouse: procedure(Ed: Pointer; Event: PJcpMouseEvent); cdecl;
    Timer: procedure(Ed: Pointer); cdecl;
    ParameterChanged: procedure(Ed: Pointer; Index: Int32; Normalised: Single); cdecl;
    Resized: procedure(Ed: Pointer; Width, Height: Int32); cdecl;
    PopupResult: procedure(Ed: Pointer; MenuId, ItemId: Int32); cdecl;
    FileChosen: procedure(Ed: Pointer; RequestId: Int32; Path: PAnsiChar); cdecl;  { newer wrappers }
  end;
  PJcpEditorVTable = ^TJcpEditorVTable;

  { Tooltip and popup-menu look (set_look). Colours $AARRGGBB, 0 = JUCE's. }
  TJcpEditorLook = record
    StructSize: Int32;
    Reserved: Int32;
    TooltipBackground, TooltipText, TooltipOutline: Cardinal;
    MenuBackground, MenuText, MenuHighlight, MenuHighlightText, MenuHeaderText: Cardinal;
    TooltipFontHeight, MenuFontHeight: Single;  { 0 = JUCE's }
    FontName: PAnsiChar;                         { nil or '' = the default }
  end;
  PJcpEditorLook = ^TJcpEditorLook;

  TJcpEditorApi = record
    StructSize: Int32;
    Reserved: Int32;
    { window }
    Repaint: procedure(E: PJcpEditor; X, Y, W, H: Single); cdecl;
    SetSize: procedure(E: PJcpEditor; Width, Height: Int32); cdecl;
    SetResizeLimits: procedure(E: PJcpEditor; MinW, MinH, MaxW, MaxH: Int32); cdecl;
    StartTimer: procedure(E: PJcpEditor; Hz: Int32); cdecl;
    StopTimer: procedure(E: PJcpEditor); cdecl;
    SetTooltip: procedure(E: PJcpEditor; Text: PAnsiChar); cdecl;
    ShowPopupMenu: function(E: PJcpEditor; Items: PJcpMenuItem; Count, ItemSize, MenuId: Int32; X, Y: Single): Int32; cdecl;
    { parameters }
    GetParameterCount: function(E: PJcpEditor): Int32; cdecl;
    FindParameter: function(E: PJcpEditor; Id: PAnsiChar): Int32; cdecl;
    GetParameterNormalised: function(E: PJcpEditor; Index: Int32): Single; cdecl;
    GetParameterDefault: function(E: PJcpEditor; Index: Int32): Single; cdecl;
    NormalisedToPlain: function(E: PJcpEditor; Index: Int32; Normalised: Single): Single; cdecl;
    PlainToNormalised: function(E: PJcpEditor; Index: Int32; Plain: Single): Single; cdecl;
    GetParameterText: function(E: PJcpEditor; Index: Int32; Normalised: Single; Buffer: PAnsiChar; Size: Int32): Int32; cdecl;
    BeginGesture: procedure(E: PJcpEditor; Index: Int32); cdecl;
    SetParameterNormalised: procedure(E: PJcpEditor; Index: Int32; Normalised: Single); cdecl;
    EndGesture: procedure(E: PJcpEditor; Index: Int32); cdecl;
    GetMeter: function(E: PJcpEditor; Index: Int32): Single; cdecl;
    { images }
    CreateImage: function(E: PJcpEditor; Data: Pointer; Size: Int32): Int32; cdecl;
    DestroyImage: procedure(E: PJcpEditor; Image: Int32); cdecl;
    GetImageSize: function(E: PJcpEditor; Image: Int32; var Width, Height: Int32): Int32; cdecl;
    GetTextWidth: function(E: PJcpEditor; Text, FontName: PAnsiChar; Height: Single; Style: Int32): Single; cdecl;
    { drawing (only with the PJcpGraphics passed to Paint) }
    SetColour: procedure(G: PJcpGraphics; Argb: Cardinal); cdecl;
    SetGradient: procedure(G: PJcpGraphics; Argb1: Cardinal; X1, Y1: Single; Argb2: Cardinal; X2, Y2: Single;
      Radial: Int32); cdecl;
    FillAll: procedure(G: PJcpGraphics); cdecl;
    FillRect: procedure(G: PJcpGraphics; X, Y, W, H: Single); cdecl;
    DrawRect: procedure(G: PJcpGraphics; X, Y, W, H, Thickness: Single); cdecl;
    FillRoundedRect: procedure(G: PJcpGraphics; X, Y, W, H, Radius: Single); cdecl;
    DrawRoundedRect: procedure(G: PJcpGraphics; X, Y, W, H, Radius, Thickness: Single); cdecl;
    FillEllipse: procedure(G: PJcpGraphics; X, Y, W, H: Single); cdecl;
    DrawEllipse: procedure(G: PJcpGraphics; X, Y, W, H, Thickness: Single); cdecl;
    DrawLine: procedure(G: PJcpGraphics; X1, Y1, X2, Y2, Thickness: Single); cdecl;
    PathBegin: procedure(G: PJcpGraphics); cdecl;
    PathMoveTo: procedure(G: PJcpGraphics; X, Y: Single); cdecl;
    PathLineTo: procedure(G: PJcpGraphics; X, Y: Single); cdecl;
    PathQuadTo: procedure(G: PJcpGraphics; CX, CY, X, Y: Single); cdecl;
    PathCubicTo: procedure(G: PJcpGraphics; C1X, C1Y, C2X, C2Y, X, Y: Single); cdecl;
    PathArc: procedure(G: PJcpGraphics; CX, CY, RX, RY, FromRadians, ToRadians: Single; StartNewSubPath: Int32); cdecl;
    PathClose: procedure(G: PJcpGraphics); cdecl;
    FillPath: procedure(G: PJcpGraphics); cdecl;
    StrokePath: procedure(G: PJcpGraphics; Thickness: Single; Join, Cap: Int32); cdecl;
    SetFont: procedure(G: PJcpGraphics; Name: PAnsiChar; Height: Single; Style: Int32); cdecl;
    DrawText: procedure(G: PJcpGraphics; Text: PAnsiChar; X, Y, W, H: Single; Justification, Ellipsis: Int32); cdecl;
    DrawImage: procedure(G: PJcpGraphics; Image: Int32; DX, DY, DW, DH, SX, SY, SW, SH, Opacity: Single); cdecl;
    SaveState: procedure(G: PJcpGraphics); cdecl;
    RestoreState: procedure(G: PJcpGraphics); cdecl;
    ClipRect: function(G: PJcpGraphics; X, Y, W, H: Single): Int32; cdecl;
    Translate: procedure(G: PJcpGraphics; DX, DY: Single); cdecl;
    { added later: present only if StructSize covers them }
    SetDesignSize: procedure(E: PJcpEditor; Width, Height: Int32; MinScale, MaxScale: Single; Flags: Int32); cdecl;
    GetScale: function(E: PJcpEditor): Single; cdecl;
    OpenUrl: function(E: PJcpEditor; Url: PAnsiChar): Int32; cdecl;
    SetLook: procedure(E: PJcpEditor; Look: PJcpEditorLook); cdecl;
    ChooseFile: function(E: PJcpEditor; RequestId, Mode: Int32; Title, Patterns, Initial: PAnsiChar): Int32; cdecl;
  end;
  PJcpEditorApi = ^TJcpEditorApi;

  TJcpStateWriter = procedure(Writer: Pointer; Data: Pointer; Size: Int32); cdecl;

  TJcpPluginVTable = record
    StructSize: Int32;
    Reserved: Int32;
    Destroy: procedure(Inst: Pointer); cdecl;
    Prepare: procedure(Inst: Pointer; SampleRate: Double; MaxBlockSize: Int32); cdecl;
    Release: procedure(Inst: Pointer); cdecl;
    Reset: procedure(Inst: Pointer); cdecl;
    Process: procedure(Inst: Pointer; Context: PJuceProcessContext); cdecl;
    GetState: procedure(Inst: Pointer; Write: TJcpStateWriter; Writer: Pointer); cdecl;
    SetState: procedure(Inst: Pointer; Data: Pointer; Size: Int32); cdecl;
    GetTailSeconds: function(Inst: Pointer): Double; cdecl;
    GetParameterText: function(Inst: Pointer; Index: Int32; Value: Single; Buffer: PAnsiChar;
      BufferSize: Int32): Int32; cdecl;
    GetExtension: function(Inst: Pointer; Id: PAnsiChar): Pointer; cdecl;
    CreateEditor: function(Inst: Pointer; Api: PJcpEditorApi; Editor: PJcpEditor; VTable: PJcpEditorVTable;
      var Width, Height: Int32): Pointer; cdecl;
    { host programs (newer wrappers) }
    GetProgramCount: function(Inst: Pointer): Int32; cdecl;
    GetCurrentProgram: function(Inst: Pointer): Int32; cdecl;
    SetCurrentProgram: procedure(Inst: Pointer; Index: Int32); cdecl;
    GetProgramName: function(Inst: Pointer; Index: Int32; Buffer: PAnsiChar; BufferSize: Int32): Int32; cdecl;
  end;
  PJcpPluginVTable = ^TJcpPluginVTable;

  TJcpPluginFactory = record
    StructSize: Int32;
    AbiVersion: Int32;
    Kind: Int32;
    Reserved: Int32;
    GetParameterCount: function: Int32; cdecl;
    GetParameterInfo: function(Index: Int32; Info: PJcpParameterInfo): Int32; cdecl;
    Create: function(Api: PJcpHostApi; Host: PJcpHost; VTable: PJcpPluginVTable): Pointer; cdecl;
    ErrorMessage: PAnsiChar;
  end;
  PJcpPluginFactory = ^TJcpPluginFactory;

  { --- Base class: subclass this --- }

  TJucePlugin = class;

  { One popup-menu entry (see TJuceEditorBase.ShowPopupMenu). }
  TJuceMenuItem = record
    Id: Integer;      { > 0; 0 is reserved for "dismissed" }
    Flags: Integer;   { JCP_MENU_* }
    Text: string;
  end;

  { The plug-in's own editor, as the wrapper sees it: one per open window,
    created by TJucePlugin.CreateEditor on the host's message thread. Every
    method here runs on that thread. JuceUI.TJuceEditor (controls, painting,
    mouse handling) builds on this; derive from that, not from this, unless you
    want to talk to the C API yourself. }
  {$M+} { RTTI: layouts bind events to published methods of your editor (JuceLayout) }
  TJuceEditorBase = class
  private
    FPlugin: TJucePlugin;
    FApi: PJcpEditorApi;
    FHandle: PJcpEditor;
    FWidth, FHeight: Integer;
    FOpen: Boolean;
    FScaled: Boolean;
  protected
    { The wrapper's editor API has this function (a field of EditorApiProbe). }
    function ApiHas(Field: Pointer): Boolean;
    { Callbacks from the wrapper (exceptions are caught at the boundary). }
    procedure Paint(G: PJcpGraphics); virtual;
    procedure MouseEvent(const E: TJcpMouseEvent); virtual;
    procedure TimerTick; virtual;
    procedure ParameterChanged(Index: Integer; Normalised: Single); virtual;
    procedure Resized; virtual;
    procedure PopupResult(MenuId, ItemId: Integer); virtual;
    { Answer to ChooseFile: Chosen and the full Path, or not Chosen (Path '')
      if the user cancelled. }
    procedure FileChosen(RequestId: Integer; Chosen: Boolean; const Path: string); virtual;
    { After the constructor, before the window is shown: host services work. }
    procedure Opened; virtual;
  public
    { Host services (Api, Handle) are already usable in the constructor. }
    constructor Create(APlugin: TJucePlugin); virtual;

    { Window }
    procedure Repaint; overload;
    procedure Repaint(X, Y, W, H: Single); overload;
    { 16..4096 pixels. }
    procedure SetSize(AWidth, AHeight: Integer);
    { Lets the host resize the window within these limits (MaxW = 0: fixed
      size). Ends scaling (SetDesignSize). }
    procedure SetResizeLimits(MinW, MinH, MaxW, MaxH: Integer);
    { A scaled editor: lay out and draw at AWidth x AHeight (the design size,
      which Width and Height keep); the wrapper scales the drawing to the
      window, which the host and the user may resize with its aspect ratio
      kept, from MinScale to MaxScale times the design size (0.25..4).
      Mouse coordinates, Repaint and menus stay in design units. The scale
      is remembered for the plug-in instance and saved with its state.
      CornerResizer adds JUCE's resize handle in the bottom right corner.
      False (and just SetSize) if the wrapper is too old to scale. }
    function SetDesignSize(AWidth, AHeight: Integer; MinScale, MaxScale: Single;
      CornerResizer: Boolean = True): Boolean;
    { Window pixels per design unit (1 when not scaled). }
    function Scale: Single;
    { Asks the OS to open a web page in the default browser - only while
      answering a click (a mouse press or release handler, or a popup-menu
      answer), once per click. https:// only, a DNS host name, plain
      printable ASCII (see open_url in juce_c_plugin.h). False if refused. }
    function OpenUrl(const Url: string): Boolean;
    { The look of this editor's tooltips and popup menus (nil: JUCE's). }
    procedure SetLook(Look: PJcpEditorLook);
    procedure StartTimer(Hz: Integer);
    procedure StopTimer;
    procedure SetTooltip(const Text: string);
    { Shows a menu at (X, Y) and returns at once; the choice arrives in
      PopupResult(MenuId, item id or 0). False if it could not be shown (for
      example while another menu of this editor is open). }
    function ShowPopupMenu(MenuId: Integer; const Items: array of TJuceMenuItem; X, Y: Single): Boolean;
    { The OS's file dialog: open an existing file (Save False) or name one to
      write (Save True; the user confirms replacing one). Only while answering
      a click (as OpenUrl), one dialog at a time. Returns at once; the answer
      arrives in FileChosen(RequestId, ...). Patterns: '*.hfe;*.img' (letters,
      digits and * ? . ; _ - only; '' = any file). Initial: a folder or a file
      to start at ('' = the OS's choice). False if refused or the wrapper is
      too old. The library reads or writes the file itself. }
    function ChooseFile(RequestId: Integer; Save: Boolean; const Title, Patterns, Initial: string): Boolean;

    { Parameters, by index (declaration order). Values are normalised 0..1.
      Virtual so that a design-time editor (see packages/) can answer from a
      parameter list file instead of a running plug-in. }
    function ParameterCount: Integer; virtual;
    function FindParameter(const Id: string): Integer; virtual;   { -1 if unknown }
    function ParamNormalised(Index: Integer): Single; virtual;
    function ParamDefault(Index: Integer): Single; virtual;
    function ParamToPlain(Index: Integer; Normalised: Single): Single; virtual;
    function ParamFromPlain(Index: Integer; Plain: Single): Single; virtual;
    { Display text (TJucePlugin.ParameterToText if it gives one), no units. }
    function ParamText(Index: Integer; Normalised: Single): string; virtual;
    { Units as declared ('ms', 'dB', ...). }
    function ParamUnits(Index: Integer): string; virtual;
    { A choice parameter's choices, '|' separated, in order ('' for other kinds). }
    function ParamChoices(Index: Integer): string; virtual;
    procedure BeginGesture(Index: Integer);
    procedure SetParamNormalised(Index: Integer; Normalised: Single);
    procedure EndGesture(Index: Integer);
    { A value published from Process with TJucePlugin.SetMeter. }
    function Meter(Index: Integer): Single; virtual;
    { Oscilloscope feed (see TJucePlugin.ScopeWrite). Each open scope calls
      ScopeAttach once and ScopeDetach once: while any is attached, the
      plug-in's output is captured. ScopeRead copies the newest Count samples
      (at most JUCE_SCOPE_MAX_READ) of a JUCE_SCOPE_* channel, oldest first,
      into Dest and returns how many it copied: 0 with no plug-in or before
      the first ScopeAttach, silence until audio arrives. Stamp changes
      whenever new audio has arrived. ScopeRead and ScopeSampleRate
      are virtual so that the designer can show a sample wave. }
    procedure ScopeAttach;
    procedure ScopeDetach;
    function ScopeRead(Channel: Integer; var Dest: array of Single; Count: Integer;
      out Stamp: Integer): Integer; virtual;
    function ScopeSampleRate: Double; virtual;

    { Images: PNG or JPEG bytes; returns a handle > 0 or 0. Freed with the editor.
      (JuceUI.TJuceEditor.AddImage is the usual way in.) }
    function CreateImage(Data: Pointer; Size: Integer): Integer; overload;
    function CreateImage(const Data: TBytes): Integer; overload;
    procedure DestroyImage(Image: Integer);
    function ImageSize(Image: Integer; out W, H: Integer): Boolean;
    function TextWidth(const Text, FontName: string; Height: Single; Style: Integer): Single;

    property Plugin: TJucePlugin read FPlugin;
    property Api: PJcpEditorApi read FApi;
    property Handle: PJcpEditor read FHandle;
    property Width: Integer read FWidth;
    property Height: Integer read FHeight;
    { True between Opened and destruction. }
    property IsOpen: Boolean read FOpen;
    { SetDesignSize is in force. }
    property Scaled: Boolean read FScaled;
  end;
  {$M-}

  TJucePlugin = class
  private
    FHostApi: PJcpHostApi;
    FHost: PJcpHost;
    FSampleRate: Double;
    FMaxBlockSize: Integer;
    FProcessErrors: Integer;
    FProcessCount: Integer;
    { oscilloscope ring: JUCE_SCOPE_CAPACITY left samples, then as many right;
      allocated by the first ScopeAttach, freed with the plug-in }
    FScopeBuf: PSingle;
    FScopeWritten: Integer;  { samples written, modulo 2^30 (interlocked) }
    FScopeUsers: Integer;    { attached scopes (interlocked) }
    FScopeManual: Boolean;
    function HostHas(Field: Pointer): Boolean;
    function GetProcessCount: Integer;
    procedure ScopeCapture(const Ctx: TJuceProcessContext);
  public
    { Runs on the host's main thread. Allocate here or in Prepare. }
    constructor Create; virtual;
    destructor Destroy; override;
    { Called before playback starts, and whenever rate/block size change.
      AMaxBlockSize is the host's expected maximum; always honour
      Ctx.NumSamples in Process. }
    procedure Prepare(ASampleRate: Double; AMaxBlockSize: Integer); virtual;
    procedure Release; virtual;
    { Host asks to silence voices/tails (e.g. on transport jump). Some hosts
      call this on the audio thread, between Process calls: keep it
      real-time safe (no allocation, locks or I/O). }
    procedure Reset; virtual;
    { The audio callback. Must be real-time safe. }
    procedure Process(const Ctx: TJuceProcessContext); virtual; abstract;
    { Extra state beyond parameters (which are saved automatically). Data
      passed to LoadState is untrusted: it comes from a project file. It is
      empty if the saved state had no custom data. }
    function SaveState: TBytes; virtual;
    procedure LoadState(const Data: TBytes); virtual;
    function TailSeconds: Double; virtual;
    { Optional display text for a parameter value (e.g. '-6.0 dB'). Return
      False to use the default. May run on any host thread, concurrently with
      Process and LoadState: read only immutable data, keep it quick. }
    function ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean; virtual;
    { Your own editor (see JuceUI): return a new TJuceEditor subclass, or nil
      (the default) for the host's generic editor. Message thread. The editor
      must not touch DSP state: it reads parameters through its host services
      and meters published with SetMeter. }
    function CreateEditor: TJuceEditorBase; virtual;
    { Your own programs (presets, or the programmes of a loaded sound bank),
      offered to the host as the plug-in's programs, so its program selector
      changes them. ProgramCount 0 (the default): the host sees one program,
      "Default". ProgramCount, CurrentProgram and ProgramName may run on any
      thread, concurrently with Process: keep them quick and lock-free (read
      what the message thread published). SelectProgram (Index in range) runs
      on a non-real-time thread, never concurrently with Process. Call
      ProgramsChanged when the list or the current program changes. }
    function ProgramCount: Integer; virtual;
    function CurrentProgram: Integer; virtual;
    procedure SelectProgram(Index: Integer); virtual;
    function ProgramName(Index: Integer): string; virtual;

    { Host services }
    { Process only: emit one complete MIDI message (needs KIND midi_effect or
      MIDI_OUTPUT ON). Invalid messages are dropped. }
    procedure SendMidi(const Data: array of Byte; SamplePosition: Integer);
    { Change a parameter and tell the host (e.g. from a custom editor). Wrap
      continuous changes (a drag) in BeginGesture / EndGesture. Not from the
      audio thread. }
    procedure SetParameter(Index: Integer; Value: Single);
    procedure BeginGesture(Index: Integer);
    procedure EndGesture(Index: Integer);
    function GetParameter(Index: Integer): Single;
    procedure SetLatencySamples(Samples: Integer);
    { Any thread, real-time safe: publish a value (e.g. an output peak) for the
      editor to show. Index 0..JCP_MAX_METERS - 1. }
    procedure SetMeter(Index: Integer; Value: Single);
    { The program list or the current program changed: the host is told (from
      its message thread). Any thread but the audio thread. }
    procedure ProgramsChanged;
    { Oscilloscope feed (JuceControls.TJuceScope). While a scope is open, the
      outputs are captured after every Process call, so a scope shows the
      plug-in's output with no code of yours. To show something else (one
      oscillator, the signal before the filter), set ScopeManual in the
      constructor and call ScopeWrite from Process. Audio thread only (one
      writer), real-time safe; Right = nil writes Left to both channels.
      Does nothing while no scope is open (see ScopeActive). }
    procedure ScopeWrite(Left, Right: PJuceSampleArray; Count: Integer);
    { A scope is open: worth preparing samples for ScopeWrite. }
    function ScopeActive: Boolean;
    { Not real-time safe. }
    procedure Log(const Msg: string);

    property SampleRate: Double read FSampleRate;
    property MaxBlockSize: Integer read FMaxBlockSize;
    { Exceptions caught in Process so far. }
    property ProcessErrors: Integer read FProcessErrors;
    { True: the outputs are not captured for scopes; Process calls ScopeWrite. }
    property ScopeManual: Boolean read FScopeManual write FScopeManual;
    { Process calls so far (wraps around; compare for change only). Any
      thread: the editor uses it to tell whether the meters have been
      published since it last looked (see TJuceEditor.PredictMeter). }
    property ProcessCount: Integer read GetProcessCount;
  end;
  TJucePluginClass = class of TJucePlugin;

{ Parameter declarations - call from the library's begin..end block, before
  JuceRegisterPlugin. Each returns the parameter's index (its slot in
  TJuceProcessContext.Parameters), or -1 if the declaration is invalid.
  Ids: 1-128 characters of A-Z a-z 0-9 _ - . ; unique; never change them once
  you ship (hosts save them). VersionHint: the plug-in release (>= 1) in which
  the parameter was added - required by AU when you add parameters later. }
function JuceAddFloatParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Single;
  const Units: string = ''; Step: Single = 0; Automatable: Boolean = True;
  VersionHint: Integer = 1): Integer;
function JuceAddIntParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Integer;
  const Units: string = ''; Automatable: Boolean = True; VersionHint: Integer = 1): Integer;
function JuceAddBoolParameter(const Id, Name: string; DefaultValue: Boolean;
  Automatable: Boolean = True; VersionHint: Integer = 1): Integer;
function JuceAddChoiceParameter(const Id, Name: string; const Choices: array of string;
  DefaultIndex: Integer = 0; Automatable: Boolean = True; VersionHint: Integer = 1): Integer;

{ Kind must match KIND in pascaljuce_add_plugin. }
procedure JuceRegisterPlugin(PluginClass: TJucePluginClass; Kind: TJucePluginKind = jkInstrument);

{ First declaration error, or '' if all declarations are valid. }
function JuceDeclarationError: string;

{ What was declared for a parameter (False for an invalid index). }
function JuceParameterInfo(Index: Integer; out Id, Name, Units: string): Boolean;
function JuceParameterCount: Integer;
{ A choice parameter's choices, '|' separated ('' for other kinds or an invalid index). }
function JuceParameterChoices(Index: Integer): string;

{ S as UTF-8 for the wrapper; invalid bytes become '?'. }
function JuceUtf8(const S: string): UTF8String;

{ Export this from your library: exports pascaljuce_plugin_entry; }
function pascaljuce_plugin_entry(HostAbiVersion: Int32; Factory: PJcpPluginFactory): Int32; cdecl;

implementation

uses
  Math;

type
  TParamDecl = record
    Id, Name, Units, Choices: UTF8String;
    Kind: TJuceParameterKind;
    Automatable: Boolean;
    VersionHint: Integer;
    MinValue, MaxValue, DefaultValue, Step: Single;
  end;

var
  GParams: array of TParamDecl;
  GPluginClass: TJucePluginClass;
  GPluginKind: TJucePluginKind = jkInstrument;
  GDeclError: UTF8String;
  GEntryError: UTF8String;
  { Layout probes for "does the other side's struct have this field?" }
  ApiProbe: TJcpHostApi;
  EditorApiProbe: TJcpEditorApi;

threadvar
  { Handed to TJucePlugin.Create, so the constructor can use host services. }
  GCreatingApi: PJcpHostApi;
  GCreatingHost: PJcpHost;
  { ...and to TJuceEditorBase.Create. }
  GCreatingEditorApi: PJcpEditorApi;
  GCreatingEditorHandle: PJcpEditor;

{ ---------------------------------------------------------------------------- }

{ Text for the host must be valid UTF-8, or the wrapper blanks it. Pascal can
  produce invalid bytes without meaning to: a locale separator read as a single
  ANSI byte (fr-FR thousands separator $A0), or Copy() splitting a character.
  Invalid bytes become '?'. }
function Utf8(const S: string): UTF8String;
var
  I, N, Need, K: Integer;
  C: Byte;
  CodePoint: Cardinal;
begin
  Result := UTF8String(S);
  N := Length(Result);
  I := 1;
  while I <= N do
  begin
    C := Ord(Result[I]);
    if C < $80 then
    begin
      Inc(I);
      Continue;
    end;
    if (C >= $C2) and (C <= $DF) then Need := 1
    else if (C >= $E0) and (C <= $EF) then Need := 2
    else if (C >= $F0) and (C <= $F4) then Need := 3
    else Need := -1;
    if (Need > 0) and (I + Need <= N) then
    begin
      CodePoint := C and ($3F shr Need);
      for K := 1 to Need do
        if (Ord(Result[I + K]) and $C0) = $80 then
          CodePoint := (CodePoint shl 6) or (Ord(Result[I + K]) and $3F)
        else
          Need := -1;
      { reject overlong forms, surrogates and values above U+10FFFF }
      if (Need = 2) and ((CodePoint < $800) or ((CodePoint >= $D800) and (CodePoint <= $DFFF))) then Need := -1;
      if (Need = 3) and ((CodePoint < $10000) or (CodePoint > $10FFFF)) then Need := -1;
    end
    else
      Need := -1;
    if Need < 0 then
    begin
      Result[I] := '?';
      Inc(I);
    end
    else
      Inc(I, Need + 1);
  end;
end;

{ Byte offset just past a pointer-sized field: StructSize >= this => present. }
function FieldEnd(Base, Field: Pointer): Integer;
begin
  Result := Integer(PAnsiChar(Field) - PAnsiChar(Base)) + SizeOf(Pointer);
end;

function Fits(StructSize: Int32; Base, Field: Pointer): Boolean;
begin
  Result := StructSize >= FieldEnd(Base, Field);
end;

procedure DeclError(const Msg: string);
begin
  if GDeclError = '' then
    GDeclError := Utf8(Msg);
end;

function JuceDeclarationError: string;
begin
  Result := string(GDeclError);
end;

function JuceUtf8(const S: string): UTF8String;
begin
  Result := Utf8(S);
end;

function JuceParameterCount: Integer;
begin
  Result := Length(GParams);
end;

function JuceParameterInfo(Index: Integer; out Id, Name, Units: string): Boolean;
begin
  Result := (Index >= 0) and (Index <= High(GParams));
  if Result then
  begin
    Id := string(GParams[Index].Id);
    Name := string(GParams[Index].Name);
    Units := string(GParams[Index].Units);
  end
  else
  begin
    Id := '';
    Name := '';
    Units := '';
  end;
end;

function JuceParameterChoices(Index: Integer): string;
begin
  Result := '';
  if (Index >= 0) and (Index <= High(GParams)) and (GParams[Index].Kind = jpkChoice) then
    Result := string(GParams[Index].Choices);
end;

function ValidId(const Id: string): Boolean;
var
  I: Integer;
  C: Char;
begin
  Result := (Length(Id) >= 1) and (Length(Id) <= 128);
  for I := 1 to Length(Id) do
  begin
    C := Id[I];
    if not (((C >= 'A') and (C <= 'Z')) or ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9'))
      or (C = '_') or (C = '-') or (C = '.')) then
      Result := False;
  end;
end;

function IsFinite(V: Single): Boolean;
var
  Bits: Cardinal;
begin
  { Bit test, not an FP compare: comparing a NaN traps when FP exceptions are
    unmasked, and declarations must never raise. Exponent all ones = Inf/NaN. }
  Move(V, Bits, SizeOf(Bits));
  Result := (Bits and $7F800000) <> $7F800000;
end;

function AddParamChecked(const Id, Name: string; Kind: TJuceParameterKind; MinValue, MaxValue,
  DefaultValue, Step: Single; const Units, Choices: string; Automatable: Boolean;
  VersionHint: Integer): Integer;
var
  I: Integer;
  Problem: string;
begin
  Result := -1;
  Problem := '';
  if not ValidId(Id) then
    Problem := 'id must be 1-128 characters of A-Z a-z 0-9 _ - .'
  else if not (IsFinite(MinValue) and IsFinite(MaxValue) and IsFinite(DefaultValue) and IsFinite(Step)) then
    Problem := 'range values must be finite'
  else if (Kind in [jpkFloat, jpkInt]) and not (MinValue < MaxValue) then
    Problem := 'min must be less than max'
  else if (Kind in [jpkFloat, jpkInt]) and ((DefaultValue < MinValue) or (DefaultValue > MaxValue)) then
    Problem := 'default must lie within min..max'
  else if Step < 0 then
    Problem := 'step must be >= 0'
  else if (Kind = jpkChoice) and (MaxValue < 1) then
    Problem := 'a choice needs at least 2 options'
  else if (Kind = jpkChoice) and ((DefaultValue < 0) or (DefaultValue > MaxValue)) then
    Problem := 'default choice index out of range'
  else if VersionHint < 1 then
    Problem := 'version hint must be >= 1';
  for I := 0 to High(GParams) do
    if (Problem = '') and (GParams[I].Id = Utf8(Id)) then
      Problem := 'duplicate id';
  if (Problem = '') and (Length(GParams) >= 4096) then
    Problem := 'too many parameters (4096 max)';

  if Problem <> '' then
  begin
    DeclError(Format('parameter "%s": %s', [Id, Problem]));
    Exit;
  end;

  Result := Length(GParams);
  SetLength(GParams, Result + 1);
  GParams[Result].Id := Utf8(Id);
  GParams[Result].Name := Utf8(Name);
  GParams[Result].Units := Utf8(Units);
  GParams[Result].Choices := Utf8(Choices);
  GParams[Result].Kind := Kind;
  GParams[Result].Automatable := Automatable;
  GParams[Result].VersionHint := VersionHint;
  GParams[Result].MinValue := MinValue;
  GParams[Result].MaxValue := MaxValue;
  GParams[Result].DefaultValue := DefaultValue;
  GParams[Result].Step := Step;
end;

{ Declarations run in the library's start-up code: nothing may raise there. }
function AddParam(const Id, Name: string; Kind: TJuceParameterKind; MinValue, MaxValue,
  DefaultValue, Step: Single; const Units, Choices: string; Automatable: Boolean;
  VersionHint: Integer): Integer;
begin
  try
    Result := AddParamChecked(Id, Name, Kind, MinValue, MaxValue, DefaultValue, Step, Units, Choices,
      Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

function JuceAddFloatParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Single;
  const Units: string; Step: Single; Automatable: Boolean; VersionHint: Integer): Integer;
begin
  Result := AddParam(Id, Name, jpkFloat, MinValue, MaxValue, DefaultValue, Step, Units, '',
    Automatable, VersionHint);
end;

function JuceAddIntParameter(const Id, Name: string; MinValue, MaxValue, DefaultValue: Integer;
  const Units: string; Automatable: Boolean; VersionHint: Integer): Integer;
begin
  try { the Integer-to-Single conversions happen here, outside AddParam's guard }
    Result := AddParam(Id, Name, jpkInt, MinValue, MaxValue, DefaultValue, 1, Units, '',
      Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

function JuceAddBoolParameter(const Id, Name: string; DefaultValue: Boolean; Automatable: Boolean;
  VersionHint: Integer): Integer;
begin
  Result := AddParam(Id, Name, jpkBool, 0, 1, Ord(DefaultValue), 1, '', '', Automatable, VersionHint);
end;

function JuceAddChoiceParameter(const Id, Name: string; const Choices: array of string;
  DefaultIndex: Integer; Automatable: Boolean; VersionHint: Integer): Integer;
var
  Joined: string;
  I: Integer;
begin
  try
  Joined := '';
  for I := 0 to High(Choices) do
  begin
    if (Choices[I] = '') or (Pos('|', Choices[I]) > 0) then
    begin
      DeclError(Format('parameter "%s": choice names must be non-empty and must not contain "|"', [Id]));
      Exit(-1);
    end;
    if I > 0 then
      Joined := Joined + '|';
    Joined := Joined + Choices[I];
  end;
  Result := AddParam(Id, Name, jpkChoice, 0, High(Choices), DefaultIndex, 1, '', Joined,
    Automatable, VersionHint);
  except
    on E: Exception do
    begin
      DeclError('parameter "' + Id + '": ' + E.Message);
      Result := -1;
    end;
  end;
end;

procedure JuceRegisterPlugin(PluginClass: TJucePluginClass; Kind: TJucePluginKind);
begin
  GPluginClass := PluginClass;
  GPluginKind := Kind;
end;

{ ---------------------------------------------------------------------------- }
{ TJuceProcessContext                                                          }
{ ---------------------------------------------------------------------------- }

function TJuceProcessContext.Param(Index: Integer): Single;
begin
  if (Index >= 0) and (Index < NumParameters) and (Parameters <> nil) then
    Result := Parameters^[Index]
  else
    Result := 0;
end;

function TJuceProcessContext.Channel(Index: Integer): PJuceSampleArray;
begin
  if (Index >= 0) and (Index < NumChannels) and (Index <= High(TJuceChannelArray)) and (Channels <> nil) then
    Result := Channels^[Index]
  else
    Result := nil;
end;

function TJuceProcessContext.MidiEvent(Index: Integer): PJuceMidiEvent;
begin
  if (Index >= 0) and (Index < NumMidiEvents) and (MidiEvents <> nil) and (MidiEventSize >= SizeOf(TJuceMidiEvent)) then
    Result := PJuceMidiEvent(PAnsiChar(MidiEvents) + NativeInt(Index) * MidiEventSize)
  else
    Result := nil;
end;

{ ---------------------------------------------------------------------------- }
{ TJucePlugin                                                                  }
{ ---------------------------------------------------------------------------- }

{ Interlocked access to the fields shared with the audio thread: full
  barriers, so samples written before AtomicStore are seen after AtomicLoad. }
function AtomicLoad(var Target: Integer): Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(Target, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(Target, 0, 0);
  {$ENDIF}
end;

procedure AtomicStore(var Target: Integer; Value: Integer);
begin
  {$IFDEF FPC}
  InterlockedExchange(Target, Value);
  {$ELSE}
  AtomicExchange(Target, Value);
  {$ENDIF}
end;

const
  ScopeMask = JUCE_SCOPE_CAPACITY - 1;
  ScopeWrap = $3FFFFFFF;                  { stamps run modulo 2^30: never overflow }
  ScopeChunk = JUCE_SCOPE_CAPACITY div 4; { samples published at a time }

constructor TJucePlugin.Create;
begin
  inherited Create;
  FHostApi := GCreatingApi;
  FHost := GCreatingHost;
end;

destructor TJucePlugin.Destroy;
begin
  if FScopeBuf <> nil then
    FreeMem(FScopeBuf);
  FScopeBuf := nil;
  inherited Destroy;
end;

function TJucePlugin.ScopeActive: Boolean;
begin
  Result := AtomicLoad(FScopeUsers) > 0;
end;

procedure TJucePlugin.ScopeWrite(Left, Right: PJuceSampleArray; Count: Integer);
var
  Buf: PJuceSampleArray;
  W, Done, N, I, P: Integer;
begin
  if (Left = nil) or (Count <= 0) or not ScopeActive then
    Exit;
  Buf := PJuceSampleArray(FScopeBuf); { set before the first ScopeAttach published FScopeUsers }
  if Buf = nil then
    Exit;
  if Right = nil then
    Right := Left;
  W := FScopeWritten; { this thread is the only writer }
  Done := 0;
  if Count > JUCE_SCOPE_CAPACITY then
    Done := Count - JUCE_SCOPE_CAPACITY; { only the newest fit }
  while Done < Count do
  begin
    N := Min(Count - Done, ScopeChunk);
    for I := 0 to N - 1 do
    begin
      P := (W + I) and ScopeMask;
      Buf^[P] := Left^[Done + I];
      Buf^[JUCE_SCOPE_CAPACITY + P] := Right^[Done + I];
    end;
    W := (W + N) and ScopeWrap;
    AtomicStore(FScopeWritten, W); { publishes the samples just written }
    Inc(Done, N);
  end;
end;

procedure TJucePlugin.ScopeCapture(const Ctx: TJuceProcessContext);
var
  Right: PJuceSampleArray;
begin
  if Ctx.NumOutputChannels <= 0 then
    Exit;
  Right := nil;
  if Ctx.NumOutputChannels > 1 then
    Right := Ctx.Channel(1);
  ScopeWrite(Ctx.Channel(0), Right, Min(Ctx.NumSamples, High(TJuceSampleArray) + 1));
end;

{ True if the wrapper's host API is big enough to contain Field (a field of
  ApiProbe) and the function is present. }
function TJucePlugin.GetProcessCount: Integer;
begin
  {$IFDEF FPC}
  Result := InterlockedCompareExchange(FProcessCount, 0, 0);
  {$ELSE}
  Result := AtomicCmpExchange(FProcessCount, 0, 0);
  {$ENDIF}
end;

function TJucePlugin.HostHas(Field: Pointer): Boolean;
begin
  Result := (FHostApi <> nil) and (FHostApi^.StructSize >= FieldEnd(@ApiProbe, Field))
    and (PPointer(PAnsiChar(FHostApi) + (PAnsiChar(Field) - PAnsiChar(@ApiProbe)))^ <> nil);
end;

procedure TJucePlugin.Prepare(ASampleRate: Double; AMaxBlockSize: Integer);
begin
end;

procedure TJucePlugin.Release;
begin
end;

procedure TJucePlugin.Reset;
begin
end;

function TJucePlugin.SaveState: TBytes;
begin
  Result := nil;
end;

procedure TJucePlugin.LoadState(const Data: TBytes);
begin
end;

function TJucePlugin.TailSeconds: Double;
begin
  Result := 0;
end;

function TJucePlugin.ParameterToText(Index: Integer; Value: Single; out Text: string): Boolean;
begin
  Text := '';
  Result := False;
end;

procedure TJucePlugin.SendMidi(const Data: array of Byte; SamplePosition: Integer);
begin
  if (Length(Data) > 0) and HostHas(@@ApiProbe.AddMidiOutput) then
    FHostApi^.AddMidiOutput(FHost, @Data[0], Length(Data), SamplePosition);
end;

procedure TJucePlugin.SetParameter(Index: Integer; Value: Single);
begin
  if HostHas(@@ApiProbe.SetParameter) then
    FHostApi^.SetParameter(FHost, Index, Value);
end;

procedure TJucePlugin.BeginGesture(Index: Integer);
begin
  if HostHas(@@ApiProbe.BeginParameterGesture) then
    FHostApi^.BeginParameterGesture(FHost, Index);
end;

procedure TJucePlugin.EndGesture(Index: Integer);
begin
  if HostHas(@@ApiProbe.EndParameterGesture) then
    FHostApi^.EndParameterGesture(FHost, Index);
end;

function TJucePlugin.GetParameter(Index: Integer): Single;
begin
  if HostHas(@@ApiProbe.GetParameter) then
    Result := FHostApi^.GetParameter(FHost, Index)
  else
    Result := 0;
end;

procedure TJucePlugin.SetLatencySamples(Samples: Integer);
begin
  if HostHas(@@ApiProbe.SetLatencySamples) then
    FHostApi^.SetLatencySamples(FHost, Samples);
end;

procedure TJucePlugin.Log(const Msg: string);
var
  U: UTF8String;
begin
  if HostHas(@@ApiProbe.Log) then
  begin
    U := Utf8(Msg);
    FHostApi^.Log(FHost, PAnsiChar(U));
  end;
end;

procedure TJucePlugin.SetMeter(Index: Integer; Value: Single);
begin
  if HostHas(@@ApiProbe.SetMeter) then
    FHostApi^.SetMeter(FHost, Index, Value);
end;

function TJucePlugin.CreateEditor: TJuceEditorBase;
begin
  Result := nil;
end;

function TJucePlugin.ProgramCount: Integer;
begin
  Result := 0;
end;

function TJucePlugin.CurrentProgram: Integer;
begin
  Result := 0;
end;

procedure TJucePlugin.SelectProgram(Index: Integer);
begin
end;

function TJucePlugin.ProgramName(Index: Integer): string;
begin
  Result := '';
end;

procedure TJucePlugin.ProgramsChanged;
begin
  if HostHas(@@ApiProbe.ProgramsChanged) then
    FHostApi^.ProgramsChanged(FHost);
end;

{ ---------------------------------------------------------------------------- }
{ TJuceEditorBase                                                              }
{ ---------------------------------------------------------------------------- }

constructor TJuceEditorBase.Create(APlugin: TJucePlugin);
begin
  inherited Create;
  FPlugin := APlugin;
  FApi := GCreatingEditorApi;
  FHandle := GCreatingEditorHandle;
  FWidth := 400;
  FHeight := 300;
end;

procedure TJuceEditorBase.Paint(G: PJcpGraphics);
begin
end;

procedure TJuceEditorBase.MouseEvent(const E: TJcpMouseEvent);
begin
end;

procedure TJuceEditorBase.TimerTick;
begin
end;

procedure TJuceEditorBase.ParameterChanged(Index: Integer; Normalised: Single);
begin
end;

procedure TJuceEditorBase.Resized;
begin
end;

procedure TJuceEditorBase.PopupResult(MenuId, ItemId: Integer);
begin
end;

procedure TJuceEditorBase.Opened;
begin
end;

procedure TJuceEditorBase.Repaint;
begin
  if FApi <> nil then
    FApi^.Repaint(FHandle, 0, 0, 0, 0);
end;

procedure TJuceEditorBase.Repaint(X, Y, W, H: Single);
begin
  if (FApi <> nil) and (W > 0) and (H > 0) then
    FApi^.Repaint(FHandle, X, Y, W, H);
end;

procedure TJuceEditorBase.SetSize(AWidth, AHeight: Integer);
begin
  FWidth := EnsureRange(AWidth, JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE);
  FHeight := EnsureRange(AHeight, JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE);
  if FApi <> nil then
    FApi^.SetSize(FHandle, FWidth, FHeight);
end;

procedure TJuceEditorBase.SetResizeLimits(MinW, MinH, MaxW, MaxH: Integer);
begin
  FScaled := False;
  if FApi <> nil then
    FApi^.SetResizeLimits(FHandle, MinW, MinH, MaxW, MaxH);
end;

function TJuceEditorBase.ApiHas(Field: Pointer): Boolean;
begin
  Result := (FApi <> nil) and (FApi^.StructSize >= FieldEnd(@EditorApiProbe, Field))
    and (PPointer(PAnsiChar(FApi) + (PAnsiChar(Field) - PAnsiChar(@EditorApiProbe)))^ <> nil);
end;

function TJuceEditorBase.SetDesignSize(AWidth, AHeight: Integer; MinScale, MaxScale: Single;
  CornerResizer: Boolean): Boolean;
begin
  Result := False;
  if IsNan(MinScale) or IsNan(MaxScale) or IsInfinite(MinScale) or IsInfinite(MaxScale) then
    Exit;
  FWidth := EnsureRange(AWidth, JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE);
  FHeight := EnsureRange(AHeight, JCP_EDITOR_MIN_SIZE, JCP_EDITOR_MAX_SIZE);
  if not ApiHas(@@EditorApiProbe.SetDesignSize) then
  begin
    SetSize(FWidth, FHeight);
    Exit;
  end;
  FScaled := True;
  FApi^.SetDesignSize(FHandle, FWidth, FHeight, MinScale, MaxScale, Ord(CornerResizer) * JCP_SCALE_CORNER_RESIZER);
  Result := True;
end;

function TJuceEditorBase.Scale: Single;
begin
  Result := 1;
  if ApiHas(@@EditorApiProbe.GetScale) then
  begin
    Result := FApi^.GetScale(FHandle);
    if IsNan(Result) or (Result <= 0) then
      Result := 1;
  end;
end;

function TJuceEditorBase.OpenUrl(const Url: string): Boolean;
var
  U: UTF8String;
begin
  Result := False;
  if (Url = '') or not ApiHas(@@EditorApiProbe.OpenUrl) then
    Exit;
  U := Utf8(Url);
  Result := FApi^.OpenUrl(FHandle, PAnsiChar(U)) <> 0;
end;

procedure TJuceEditorBase.SetLook(Look: PJcpEditorLook);
begin
  if ApiHas(@@EditorApiProbe.SetLook) then
    FApi^.SetLook(FHandle, Look);
end;

function TJuceEditorBase.ChooseFile(RequestId: Integer; Save: Boolean; const Title, Patterns, Initial: string): Boolean;
var
  T, P, I: UTF8String;
  Mode: Int32;
begin
  Result := False;
  if not ApiHas(@@EditorApiProbe.ChooseFile) then
    Exit;
  T := Utf8(Title);
  P := Utf8(Patterns);
  I := Utf8(Initial);
  if Save then
    Mode := JCP_FILE_SAVE
  else
    Mode := JCP_FILE_OPEN;
  Result := FApi^.ChooseFile(FHandle, RequestId, Mode, PAnsiChar(T), PAnsiChar(P), PAnsiChar(I)) <> 0;
end;

procedure TJuceEditorBase.FileChosen(RequestId: Integer; Chosen: Boolean; const Path: string);
begin
end;

procedure TJuceEditorBase.StartTimer(Hz: Integer);
begin
  if FApi <> nil then
    FApi^.StartTimer(FHandle, Hz);
end;

procedure TJuceEditorBase.StopTimer;
begin
  if FApi <> nil then
    FApi^.StopTimer(FHandle);
end;

procedure TJuceEditorBase.SetTooltip(const Text: string);
var
  U: UTF8String;
begin
  if FApi <> nil then
  begin
    U := Utf8(Text);
    FApi^.SetTooltip(FHandle, PAnsiChar(U));
  end;
end;

function TJuceEditorBase.ShowPopupMenu(MenuId: Integer; const Items: array of TJuceMenuItem; X, Y: Single): Boolean;
var
  Texts: array of UTF8String;
  Raw: array of TJcpMenuItem;
  I: Integer;
begin
  Result := False;
  if (FApi = nil) or (Length(Items) = 0) then
    Exit;
  SetLength(Texts, Length(Items));
  SetLength(Raw, Length(Items));
  for I := 0 to High(Items) do
  begin
    Texts[I] := Utf8(Items[I].Text);
    Raw[I].Id := Items[I].Id;
    Raw[I].Flags := Items[I].Flags;
    Raw[I].Text := PAnsiChar(Texts[I]);
  end;
  Result := FApi^.ShowPopupMenu(FHandle, @Raw[0], Length(Raw), SizeOf(TJcpMenuItem), MenuId, X, Y) <> 0;
end;

function TJuceEditorBase.ParameterCount: Integer;
begin
  if FApi <> nil then
    Result := FApi^.GetParameterCount(FHandle)
  else
    Result := 0;
end;

function TJuceEditorBase.FindParameter(const Id: string): Integer;
var
  U: UTF8String;
begin
  Result := -1;
  if (FApi = nil) or (Id = '') then
    Exit;
  U := Utf8(Id);
  Result := FApi^.FindParameter(FHandle, PAnsiChar(U));
end;

function TJuceEditorBase.ParamNormalised(Index: Integer): Single;
begin
  if FApi <> nil then
    Result := FApi^.GetParameterNormalised(FHandle, Index)
  else
    Result := 0;
end;

function TJuceEditorBase.ParamDefault(Index: Integer): Single;
begin
  if FApi <> nil then
    Result := FApi^.GetParameterDefault(FHandle, Index)
  else
    Result := 0;
end;

function TJuceEditorBase.ParamToPlain(Index: Integer; Normalised: Single): Single;
begin
  if FApi <> nil then
    Result := FApi^.NormalisedToPlain(FHandle, Index, Normalised)
  else
    Result := 0;
end;

function TJuceEditorBase.ParamFromPlain(Index: Integer; Plain: Single): Single;
begin
  if FApi <> nil then
    Result := FApi^.PlainToNormalised(FHandle, Index, Plain)
  else
    Result := 0;
end;

function TJuceEditorBase.ParamText(Index: Integer; Normalised: Single): string;
var
  Buffer: array[0..511] of AnsiChar;
  N: Integer;
  U: UTF8String;
begin
  Result := '';
  if FApi = nil then
    Exit;
  Buffer[0] := #0;
  N := FApi^.GetParameterText(FHandle, Index, Normalised, @Buffer[0], SizeOf(Buffer));
  if (N > 0) and (N < SizeOf(Buffer)) then
  begin
    SetString(U, PAnsiChar(@Buffer[0]), N);
    Result := string(U);
  end;
end;

function TJuceEditorBase.ParamUnits(Index: Integer): string;
var
  Id, Name: string;
begin
  JuceParameterInfo(Index, Id, Name, Result);
end;

function TJuceEditorBase.ParamChoices(Index: Integer): string;
begin
  Result := JuceParameterChoices(Index);
end;

procedure TJuceEditorBase.BeginGesture(Index: Integer);
begin
  if FApi <> nil then
    FApi^.BeginGesture(FHandle, Index);
end;

procedure TJuceEditorBase.SetParamNormalised(Index: Integer; Normalised: Single);
begin
  if FApi <> nil then
    FApi^.SetParameterNormalised(FHandle, Index, Normalised);
end;

procedure TJuceEditorBase.EndGesture(Index: Integer);
begin
  if FApi <> nil then
    FApi^.EndGesture(FHandle, Index);
end;

function TJuceEditorBase.Meter(Index: Integer): Single;
begin
  if FApi <> nil then
    Result := FApi^.GetMeter(FHandle, Index)
  else
    Result := 0;
end;

procedure TJuceEditorBase.ScopeAttach;
begin
  if FPlugin = nil then
    Exit;
  if FPlugin.FScopeBuf = nil then { message thread, and no scope yet: the audio thread doesn't look }
    FPlugin.FScopeBuf := AllocMem(2 * JUCE_SCOPE_CAPACITY * SizeOf(Single));
  {$IFDEF FPC}
  InterlockedIncrement(FPlugin.FScopeUsers);
  {$ELSE}
  AtomicIncrement(FPlugin.FScopeUsers);
  {$ENDIF}
end;

procedure TJuceEditorBase.ScopeDetach;
begin
  if (FPlugin = nil) or (AtomicLoad(FPlugin.FScopeUsers) <= 0) then
    Exit;
  {$IFDEF FPC}
  InterlockedDecrement(FPlugin.FScopeUsers);
  {$ELSE}
  AtomicDecrement(FPlugin.FScopeUsers);
  {$ENDIF}
end;

function TJuceEditorBase.ScopeRead(Channel: Integer; var Dest: array of Single; Count: Integer;
  out Stamp: Integer): Integer;
var
  Buf: PJuceSampleArray;
  W1, W2, Start, I, K, Attempt: Integer;
begin
  Result := 0;
  Stamp := 0;
  if (FPlugin = nil) or (FPlugin.FScopeBuf = nil) then
    Exit;
  Count := Min(Count, Min(Length(Dest), JUCE_SCOPE_MAX_READ));
  if Count <= 0 then
    Exit;
  Buf := PJuceSampleArray(FPlugin.FScopeBuf);
  for Attempt := 1 to 3 do
  begin
    W1 := AtomicLoad(FPlugin.FScopeWritten);
    Stamp := W1;
    Start := W1 - Count;
    for I := 0 to Count - 1 do
    begin
      K := (Start + I) and ScopeMask;
      case Channel of
        JUCE_SCOPE_RIGHT: Dest[I] := Buf^[JUCE_SCOPE_CAPACITY + K];
        JUCE_SCOPE_MIX: Dest[I] := 0.5 * (Buf^[K] + Buf^[JUCE_SCOPE_CAPACITY + K]);
      else
        Dest[I] := Buf^[K];
      end;
    end;
    { The writer may be filling up to one chunk past what it has published:
      the copy is whole if none of that wrapped round onto what was read. }
    W2 := AtomicLoad(FPlugin.FScopeWritten);
    if ((W2 - W1) and ScopeWrap) + ScopeChunk + Count <= JUCE_SCOPE_CAPACITY then
      Exit(Count);
  end;
end;

function TJuceEditorBase.ScopeSampleRate: Double;
begin
  if FPlugin <> nil then
    Result := FPlugin.SampleRate
  else
    Result := 0;
end;

function TJuceEditorBase.CreateImage(Data: Pointer; Size: Integer): Integer;
begin
  if (FApi <> nil) and (Data <> nil) and (Size > 0) then
    Result := FApi^.CreateImage(FHandle, Data, Size)
  else
    Result := 0;
end;

function TJuceEditorBase.CreateImage(const Data: TBytes): Integer;
begin
  if Length(Data) > 0 then
    Result := CreateImage(@Data[0], Length(Data))
  else
    Result := 0;
end;

procedure TJuceEditorBase.DestroyImage(Image: Integer);
begin
  if FApi <> nil then
    FApi^.DestroyImage(FHandle, Image);
end;

function TJuceEditorBase.ImageSize(Image: Integer; out W, H: Integer): Boolean;
var
  W32, H32: Int32;
begin
  W32 := 0;
  H32 := 0;
  Result := (FApi <> nil) and (FApi^.GetImageSize(FHandle, Image, W32, H32) <> 0);
  W := W32;
  H := H32;
end;

function TJuceEditorBase.TextWidth(const Text, FontName: string; Height: Single; Style: Integer): Single;
var
  U, F: UTF8String;
begin
  Result := 0;
  if FApi = nil then
    Exit;
  U := Utf8(Text);
  F := Utf8(FontName);
  Result := FApi^.GetTextWidth(FHandle, PAnsiChar(U), PAnsiChar(F), Height, Style);
end;

{ ---------------------------------------------------------------------------- }
{ C trampolines - every one catches all exceptions                             }
{ ---------------------------------------------------------------------------- }

procedure VDestroy(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Free;
  except
  end;
end;

procedure VPrepare(Inst: Pointer; SampleRate: Double; MaxBlockSize: Int32); cdecl;
var
  P: TJucePlugin;
begin
  P := TJucePlugin(Inst);
  try
    P.FSampleRate := SampleRate;
    P.FMaxBlockSize := MaxBlockSize;
    P.Prepare(SampleRate, MaxBlockSize);
  except
  end;
end;

procedure VRelease(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Release;
  except
  end;
end;

procedure VReset(Inst: Pointer); cdecl;
begin
  try
    TJucePlugin(Inst).Reset;
  except
  end;
end;

procedure SilenceOutputs(const Ctx: TJuceProcessContext);
var
  Ch, I: Integer;
  Buf: PJuceSampleArray;
begin
  { Runs inside an except handler: must not raise itself, even with -Cr. }
  try
    for Ch := 0 to Min(Ctx.NumChannels, (High(TJuceChannelArray) + 1)) - 1 do
    begin
      Buf := Ctx.Channel(Ch);
      if Buf <> nil then
        for I := 0 to Min(Ctx.NumSamples, (High(TJuceSampleArray) + 1)) - 1 do
          Buf^[I] := 0;
    end;
  except
  end;
end;

procedure VProcess(Inst: Pointer; Context: PJuceProcessContext); cdecl;
var
  P: TJucePlugin;
begin
  { A context from a different wrapper version that lacks fields we read is
    skipped rather than read past its end. }
  if (Context = nil) or (Context^.StructSize < SizeOf(TJuceProcessContext))
    or ((Context^.Transport <> nil) and (Context^.Transport^.StructSize < SizeOf(TJuceTransport))) then
    Exit;
  P := TJucePlugin(Inst);
  try
    P.Process(Context^);
  except
    if P.FProcessErrors < High(Integer) then // saturate: -Co must not raise here
      Inc(P.FProcessErrors);
    SilenceOutputs(Context^);
  end;
  { the output, for open scopes (a pointer check and an interlocked read when none is) }
  if not P.FScopeManual then
    try
      P.ScopeCapture(Context^);
    except
    end;
  { after Process has published its meters (interlocked: wraps, never raises) }
  {$IFDEF FPC}
  InterlockedIncrement(P.FProcessCount);
  {$ELSE}
  AtomicIncrement(P.FProcessCount);
  {$ENDIF}
end;

procedure VGetState(Inst: Pointer; Write: TJcpStateWriter; Writer: Pointer); cdecl;
var
  Data: TBytes;
begin
  try
    Data := TJucePlugin(Inst).SaveState;
    { The ABI length is Int32: a 2 GB+ state is dropped, never cut short (the
      wrapper also refuses custom state above 64 MB). }
    if (Length(Data) > 0) and (Length(Data) <= High(Int32)) then
      Write(Writer, @Data[0], Length(Data));
  except
  end;
end;

procedure VSetState(Inst: Pointer; Data: Pointer; Size: Int32); cdecl;
var
  Bytes: TBytes;
begin
  try
    Bytes := nil;
    if (Size > 0) and (Data <> nil) then
    begin
      SetLength(Bytes, Size);
      Move(Data^, Bytes[0], Size);
    end;
    TJucePlugin(Inst).LoadState(Bytes);
  except
  end;
end;

function VGetTailSeconds(Inst: Pointer): Double; cdecl;
begin
  try
    Result := TJucePlugin(Inst).TailSeconds;
  except
    Result := 0;
  end;
end;

function VGetParameterText(Inst: Pointer; Index: Int32; Value: Single; Buffer: PAnsiChar;
  BufferSize: Int32): Int32; cdecl;
var
  Text: string;
  U: UTF8String;
  N: Integer;
begin
  Result := 0;
  try
    if (Buffer = nil) or (BufferSize <= 1) then { no room for any text: let the host use its own }
      Exit;
    if not TJucePlugin(Inst).ParameterToText(Index, Value, Text) then
      Exit;
    U := Utf8(Text);
    N := Length(U);
    if N > BufferSize - 1 then
    begin
      N := BufferSize - 1;
      while (N > 0) and ((Ord(U[N + 1]) and $C0) = $80) do { don't split a UTF-8 sequence }
        Dec(N);
    end;
    if N > 0 then
      Move(PAnsiChar(U)^, Buffer^, N);
    Buffer[N] := #0;
    Result := 1;
  except
    Result := 0;
  end;
end;

function VGetProgramCount(Inst: Pointer): Int32; cdecl;
begin
  try
    Result := TJucePlugin(Inst).ProgramCount;
    if Result < 0 then
      Result := 0;
  except
    Result := 0;
  end;
end;

function VGetCurrentProgram(Inst: Pointer): Int32; cdecl;
begin
  try
    Result := TJucePlugin(Inst).CurrentProgram;
  except
    Result := 0;
  end;
end;

procedure VSetCurrentProgram(Inst: Pointer; Index: Int32); cdecl;
begin
  try
    if (Index >= 0) and (Index < TJucePlugin(Inst).ProgramCount) then
      TJucePlugin(Inst).SelectProgram(Index);
  except
  end;
end;

function VGetProgramName(Inst: Pointer; Index: Int32; Buffer: PAnsiChar; BufferSize: Int32): Int32; cdecl;
var
  U: UTF8String;
  N: Integer;
begin
  Result := 0;
  try
    if (Buffer = nil) or (BufferSize <= 1) then
      Exit;
    U := Utf8(TJucePlugin(Inst).ProgramName(Index));
    N := Length(U);
    if N > BufferSize - 1 then
    begin
      N := BufferSize - 1;
      while (N > 0) and ((Ord(U[N + 1]) and $C0) = $80) do { don't split a UTF-8 sequence }
        Dec(N);
    end;
    if N > 0 then
      Move(PAnsiChar(U)^, Buffer^, N);
    Buffer[N] := #0;
    Result := 1;
  except
    Result := 0;
  end;
end;

function VGetExtension(Inst: Pointer; Id: PAnsiChar): Pointer; cdecl;
begin
  Result := nil;
end;

{ Editor trampolines: message thread; every one catches all exceptions. }

procedure EDestroy(Ed: Pointer); cdecl;
begin
  try
    TJuceEditorBase(Ed).FOpen := False;
    TJuceEditorBase(Ed).Free;
  except
  end;
end;

procedure EPaint(Ed: Pointer; G: PJcpGraphics); cdecl;
begin
  try
    TJuceEditorBase(Ed).Paint(G);
  except
  end;
end;

procedure EMouse(Ed: Pointer; Event: PJcpMouseEvent); cdecl;
begin
  if (Event = nil) or (Event^.StructSize < SizeOf(TJcpMouseEvent)) then
    Exit;
  try
    TJuceEditorBase(Ed).MouseEvent(Event^);
  except
  end;
end;

procedure ETimer(Ed: Pointer); cdecl;
begin
  try
    TJuceEditorBase(Ed).TimerTick;
  except
  end;
end;

procedure EParameterChanged(Ed: Pointer; Index: Int32; Normalised: Single); cdecl;
begin
  try
    TJuceEditorBase(Ed).ParameterChanged(Index, Normalised);
  except
  end;
end;

procedure EResized(Ed: Pointer; Width, Height: Int32); cdecl;
begin
  try
    TJuceEditorBase(Ed).FWidth := Width;
    TJuceEditorBase(Ed).FHeight := Height;
    TJuceEditorBase(Ed).Resized;
  except
  end;
end;

procedure EPopupResult(Ed: Pointer; MenuId, ItemId: Int32); cdecl;
begin
  try
    TJuceEditorBase(Ed).PopupResult(MenuId, ItemId);
  except
  end;
end;

procedure EFileChosen(Ed: Pointer; RequestId: Int32; Path: PAnsiChar); cdecl;
var
  U: UTF8String;
begin
  try
    if Path = nil then
      TJuceEditorBase(Ed).FileChosen(RequestId, False, '')
    else
    begin
      U := Path;
      TJuceEditorBase(Ed).FileChosen(RequestId, True, string(U));
    end;
  except
  end;
end;

function VCreateEditor(Inst: Pointer; Api: PJcpEditorApi; Editor: PJcpEditor; VTable: PJcpEditorVTable;
  var Width, Height: Int32): Pointer; cdecl;
var
  Ed: TJuceEditorBase;
begin
  Result := nil;
  { This library needs the editor API up to Translate; later functions (SetDesignSize, OpenUrl, ...) are
    used only if the wrapper has them (TJuceEditorBase.ApiHas). }
  if (Api = nil) or not Fits(Api^.StructSize, Api, @@Api^.Translate) or (VTable = nil)
    or not Fits(VTable^.StructSize, VTable, @@VTable^.Destroy) then
    Exit;
  Ed := nil;
  try
    GCreatingEditorApi := Api;
    GCreatingEditorHandle := Editor;
    try
      Ed := TJucePlugin(Inst).CreateEditor;
    finally
      GCreatingEditorApi := nil;
      GCreatingEditorHandle := nil;
    end;
    if Ed = nil then
      Exit; { the generic editor }
    Ed.FApi := Api; { also if a constructor forgot inherited Create }
    Ed.FHandle := Editor;
    if Ed.FPlugin = nil then
      Ed.FPlugin := TJucePlugin(Inst);
    Ed.FOpen := True;
    Ed.Opened;
    Width := Ed.FWidth;
    Height := Ed.FHeight;
    VTable^.Destroy := EDestroy;
    if Fits(VTable^.StructSize, VTable, @@VTable^.Paint) then VTable^.Paint := EPaint;
    if Fits(VTable^.StructSize, VTable, @@VTable^.Mouse) then VTable^.Mouse := EMouse;
    if Fits(VTable^.StructSize, VTable, @@VTable^.Timer) then VTable^.Timer := ETimer;
    if Fits(VTable^.StructSize, VTable, @@VTable^.ParameterChanged) then VTable^.ParameterChanged := EParameterChanged;
    if Fits(VTable^.StructSize, VTable, @@VTable^.Resized) then VTable^.Resized := EResized;
    if Fits(VTable^.StructSize, VTable, @@VTable^.PopupResult) then VTable^.PopupResult := EPopupResult;
    if Fits(VTable^.StructSize, VTable, @@VTable^.FileChosen) then VTable^.FileChosen := EFileChosen;
    Result := Ed;
  except
    try
      Ed.Free;
    except
    end;
    Result := nil;
  end;
end;

function FGetParameterCount: Int32; cdecl;
begin
  Result := Length(GParams);
end;

function FGetParameterInfo(Index: Int32; Info: PJcpParameterInfo): Int32; cdecl;
begin
  Result := 1;
  { The wrapper's struct must hold every field this library writes. }
  if (Info = nil) or (Index < 0) or (Index > High(GParams)) or (Info^.StructSize < SizeOf(TJcpParameterInfo)) then
    Exit;
  Info^.Kind := Ord(GParams[Index].Kind);
  Info^.Id := PAnsiChar(GParams[Index].Id);
  Info^.Name := PAnsiChar(GParams[Index].Name);
  Info^.LabelText := PAnsiChar(GParams[Index].Units);
  Info^.Choices := PAnsiChar(GParams[Index].Choices);
  Info^.MinValue := GParams[Index].MinValue;
  Info^.MaxValue := GParams[Index].MaxValue;
  Info^.DefaultValue := GParams[Index].DefaultValue;
  Info^.Step := GParams[Index].Step;
  if GParams[Index].Automatable then
    Info^.Flags := JCP_PARAM_FLAG_AUTOMATABLE
  else
    Info^.Flags := 0;
  Info^.VersionHint := GParams[Index].VersionHint;
  Result := 0;
end;

function FCreate(Api: PJcpHostApi; Host: PJcpHost; VTable: PJcpPluginVTable): Pointer; cdecl;
var
  Plugin: TJucePlugin;
begin
  Result := nil;
  if (GPluginClass = nil) or (VTable = nil) or (Api = nil) or (Api^.StructSize < 8) or (Api^.AbiVersion <> JCP_ABI_VERSION)
    or not Fits(VTable^.StructSize, VTable, @@VTable^.Process) then
    Exit;
  try
    GCreatingApi := Api;
    GCreatingHost := Host;
    try
      Plugin := GPluginClass.Create;
    finally
      GCreatingApi := nil;
      GCreatingHost := nil;
    end;
    { Also when a subclass constructor forgot to call inherited Create. }
    Plugin.FHostApi := Api;
    Plugin.FHost := Host;

    { Fill only what the wrapper's vtable has room for. }
    VTable^.Destroy := VDestroy;
    VTable^.Prepare := VPrepare;
    VTable^.Release := VRelease;
    VTable^.Reset := VReset;
    VTable^.Process := VProcess;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetState) then VTable^.GetState := VGetState;
    if Fits(VTable^.StructSize, VTable, @@VTable^.SetState) then VTable^.SetState := VSetState;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetTailSeconds) then VTable^.GetTailSeconds := VGetTailSeconds;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetParameterText) then VTable^.GetParameterText := VGetParameterText;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetExtension) then VTable^.GetExtension := VGetExtension;
    if Fits(VTable^.StructSize, VTable, @@VTable^.CreateEditor) then VTable^.CreateEditor := VCreateEditor;
    if Fits(VTable^.StructSize, VTable, @@VTable^.GetProgramName) then
    begin
      VTable^.GetProgramCount := VGetProgramCount;
      VTable^.GetCurrentProgram := VGetCurrentProgram;
      VTable^.SetCurrentProgram := VSetCurrentProgram;
      VTable^.GetProgramName := VGetProgramName;
    end;
    Result := Plugin;
  except
    Result := nil;
  end;
end;

function pascaljuce_plugin_entry(HostAbiVersion: Int32; Factory: PJcpPluginFactory): Int32; cdecl;
var
  Problem: string;
begin
  Result := 1;
  if (Factory = nil) or (Factory^.StructSize < 8) then
    Exit;
  try
    Problem := '';
    if HostAbiVersion <> JCP_ABI_VERSION then
      Problem := Format('wrapper ABI %d, library ABI %d (rebuild the plug-in)', [HostAbiVersion, JCP_ABI_VERSION])
    else if GDeclError <> '' then
      Problem := string(GDeclError)
    else if GPluginClass = nil then
      Problem := 'JuceRegisterPlugin was not called in the library''s begin..end block'
    else if not Fits(Factory^.StructSize, Factory, @@Factory^.Create) then
      Problem := 'wrapper factory struct too small';

    Factory^.AbiVersion := JCP_ABI_VERSION;
    if Problem <> '' then
    begin
      GEntryError := Utf8(Problem);
      if Fits(Factory^.StructSize, Factory, @Factory^.ErrorMessage) then
        Factory^.ErrorMessage := PAnsiChar(GEntryError);
      Exit;
    end;

    Factory^.Kind := Ord(GPluginKind);
    Factory^.GetParameterCount := FGetParameterCount;
    Factory^.GetParameterInfo := FGetParameterInfo;
    Factory^.Create := FCreate;
    Result := 0;
  except
    Result := 1;
  end;
end;

initialization
  { Hosts call us from their own threads. }
  IsMultiThread := True;
{$IFDEF FPC}
{$IFNDEF PASCALJUCE_DESIGN} { not in the Lazarus IDE (pascaljuce_lcl.lpk defines it): the LCL does this itself }
  { In -Mdelphi, string is an AnsiString in DefaultSystemCodePage. Make that
    UTF-8 for this library (its RTL is its own, so the host is unaffected):
    parameter names, units and Log text then reach the host unchanged, with
    -FcUTF8 or CODEPAGE UTF8 sources, whatever the Windows ANSI code page. }
  DefaultSystemCodePage := CP_UTF8;
  { ...and file names the RTL returns (FindFirst, GetCurrentDir, ...). }
  SetMultiByteRTLFileSystemCodePage(CP_UTF8);
  { Separators are read from Windows as single ANSI bytes (fr-FR uses $A0);
    under UTF-8 those would be invalid text. }
  if Ord(DefaultFormatSettings.ThousandSeparator) >= $80 then DefaultFormatSettings.ThousandSeparator := ' ';
  if Ord(DefaultFormatSettings.DecimalSeparator) >= $80 then DefaultFormatSettings.DecimalSeparator := '.';
  if Ord(DefaultFormatSettings.DateSeparator) >= $80 then DefaultFormatSettings.DateSeparator := '/';
  if Ord(DefaultFormatSettings.TimeSeparator) >= $80 then DefaultFormatSettings.TimeSeparator := ':';
  if Ord(DefaultFormatSettings.ListSeparator) >= $80 then DefaultFormatSettings.ListSeparator := ',';
{$ENDIF}
{$ENDIF}
{$IFNDEF FPC}
  { Delphi DLLs otherwise reset FPU state to Delphi's defaults, which unmask
    exceptions hosts don't expect. Make Delphi's defaults all-masked.
    (FPC libraries adopt the host's settings; the wrapper also masks and
    restores FP state around every call.) }
  if not ModuleIsPackage then { a plug-in library, not the design package inside the IDE }
  begin
    Default8087CW := $133F;
  {$IFDEF CPUX64}
    DefaultMXCSR := $1F80;
  {$ENDIF}
  end;
{$ENDIF}

end.
