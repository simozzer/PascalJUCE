// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The plug-in's window: the Object Pascal counterpart of Plugin/Source/PluginEditor.h/.cpp
// (VirtualS950Editor), built in code on PascalJUCE's TJuceEditor. The controls are the C++'s,
// drawn as its Mz950LookAndFeel draws them (Mz950Look, Mz950Controls); the three tabs are
// their own units, as in the C++: Mz950ProgramPage (PROGRAM, what is on the disk),
// Mz950PerformPage (PERFORM, the offsets and extras), Mz950SynthPage (SYNTH, sounds with no
// disk). Colour says which kind a control is: amber on the disk, cyan an offset, violet not
// on the S950.
//
// Around the tabs, as the C++: the title and what this is, the disk's name, Load disk... and
// the programme box, gain in the corner, and along the foot what is playing, how many voices
// are sounding (and a disk recovered with bad or missing sectors), the licence notice and the
// project's page.
//
// What this adds to the C++, as the other Mz*_Pascal panels do:
//   - MIDI learn. Right-click a Perform control (or gain) for its menu - the CC it answers to
//     now, MIDI Learn (or Cancel), Forget CC, Restore default, Reset all; while it waits for
//     its CC it is outlined, LEARN along the top, and every control's hint ends with its CC as
//     it is now. (The C++ has a fixed controller table, which is the default map here.)
//   - The window scales as the other ports' do: from half to twice its size, the aspect kept,
//     a corner to drag. (The C++ window is a fixed 640 x 672.)
//
// What differs, and why:
//   - The file dialogs are the framework's (OpenFile / SaveFile, the OS's own, over the plug-in
//     window); the panel reads the chosen file itself (at most 4 MiB - an S950 .hfe is 2 MB)
//     and hands the bytes to TMz950.LoadDiskBytes. The dialog starts beside the disk already
//     open, else in the folder a disk was last chosen from - remembered for as long as the
//     plug-in is loaded, not in a settings file - else where the OS likes. The C++ also looks
//     for the installer's sound library in the registry; this port has no installer.
//   - An error (a disk that will not open, a file that cannot be written) is said in the
//     window, in amber where the disk's name is, for a few seconds: PascalJUCE has no message
//     box.
//   - No "built <date>" stamp at the foot: the reference image the panel is tested against
//     must not change with every build. The project line says the version instead.
unit Mz950Editor;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  Classes, SysUtils, JuceCanvas, JucePlugin, JuceUI, JuceControls, Mz950Params, Mz950Plugin,
  Mz950Look, Mz950Controls, Mz950ProgramPage, Mz950PerformPage, Mz950SynthPage;

const
  EditorWidth = 640;
  EditorHeight = 672;

  // The largest disk image the panel will read (an S950 .hfe is 2 008 064 bytes, an .img
  // 819 200).
  MaxDiskFileBytes = 4 * 1024 * 1024;

  // How long an error stays where the disk's name is.
  NoticeMs = 8000;

  // The right-click menu's items.
  MenuLearn = 1;
  MenuForget = 2;
  MenuRestore = 3;
  MenuResetAll = 4;

  // The version the project line names (the C++ VirtualS950's, as CMakeLists.txt says).
  Mz950Version = '0.12.2';

type
  TMz950Editor = class(TJuceEditor)
  private
    FMz: TMz950;
    FBackdrop: TJuceControl;
    FGain: TMzKnob;
    FGainLabel: TMzLabel;
    FLoad: TMzButton;
    FPrograms: TMzCombo;
    FTabs: TMzTabBar;
    FProgramPage: TMzProgramPage;
    FPerformPage: TMzPerformPage;
    FSynthPage: TMzSynthPage;
    FPatchLabel, FVoicesLabel: TMzLabel;
    FLink: TJuceLink;
    FMarker: TJuceControl;
    FTicks: Integer;
    FSeenGeneration, FSeenEdits: Integer;
    FMenuIndex: Integer;            // the control the open menu is for, -1 none
    FMenuLearning: Boolean;         // it was learning when the menu opened
    FSeenLearning, FSeenVersion: Integer;
    FNotice: string;
    FNoticeUntil: Int64;
    procedure Arrange;
    procedure TabChanged(Sender: TObject);
    procedure ProgramChosen(Sender: TObject);
    procedure LoadClick(Sender: TObject);
    procedure DiskChosen(Sender: TJuceEditor; Chosen: Boolean; const Path: string);
    procedure PageNotice(Sender: TObject; const Text: string);
    procedure ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
    procedure MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
    function SpecIndexOf(Control: TJuceControl): Integer;
    function TipFor(Index: Integer): string;
    procedure UpdateLearning;
    procedure UpdateStatus;
    function PlainOf(const Id: string; Default: Single): Single;
  protected
    procedure Opened; override;
  public
    constructor Create(APlugin: TJucePlugin); override;
    // Every timer tick: MIDI learn; three times a second less often, the C++ timer's work.
    procedure Poll;
    // Put the loaded disk's programmes in the box (the C++ refreshPrograms).
    procedure RefreshPrograms;
    // 0 Program, 1 Perform, 2 Synth.
    procedure ShowTab(Tab: Integer);
    // An error, where the disk's name is, for NoticeMs.
    procedure Notice(const Text: string);
    // The control of a parameter (index in Specs), or nil.
    function SpecControl(Index: Integer): TJuceParamControl;
    function Mz: TMz950;
    property Tabs: TMzTabBar read FTabs;
    property ProgramPage: TMzProgramPage read FProgramPage;
    property PerformPage: TMzPerformPage read FPerformPage;
    property SynthPage: TMzSynthPage read FSynthPage;
    property NoticeText: string read FNotice;
  end;

implementation

uses
  Math;

var
  // Where a disk was last chosen from, shared by every window of this library while it is
  // loaded (the C++ keeps it in a settings file).
  GLastDiskFolder: string;

type
  // What the window paints itself: the background, the title and what this is, the disk's
  // name, the licence notice. Behind everything, and the mouse goes through it.
  TMzBackdrop = class(TJuceControl)
  private
    FPanel: TMz950Editor;
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
    function NeedsTimer: Boolean; override;
    procedure Tick; override;
  public
    function HitTest(X, Y: Single): Boolean; override;
  end;

  // MIDI learn's outline and LEARN, over the control that waits for its CC.
  TMzLearnMarker = class(TJuceControl)
  protected
    procedure Paint(Canvas: TJuceCanvas); override;
  public
    function HitTest(X, Y: Single): Boolean; override;
  end;

function CopyrightSign: string;
begin
  {$IFDEF FPC}
  Result := #$C2#$A9;
  {$ELSE}
  Result := #$00A9;
  {$ENDIF}
end;

{ --------------------------------------------------------------------------- TMzBackdrop }

function TMzBackdrop.HitTest(X, Y: Single): Boolean;
begin
  Result := False;
end;

function TMzBackdrop.NeedsTimer: Boolean;
begin
  Result := True;
end;

procedure TMzBackdrop.Tick;
begin
  if FPanel <> nil then
    FPanel.Poll;
end;

procedure TMzBackdrop.Paint(Canvas: TJuceCanvas);
var
  W, H: Single;
  Disk: string;
begin
  W := Width;
  H := Height;
  Canvas.SetColor(ColWindow);
  Canvas.FillAll;

  Canvas.SetColor(ColText);
  UseFont(Canvas, 24, True);
  Canvas.DrawText('Mz950', JuceRect(16, 12, W - 32, 28), jaLeft, jvaCenter);

  // The licence asks an interactive program to say so where it can be seen - and where the
  // licence and the source are, which is the project's page, the link beside it.
  Canvas.SetColor(ColFaint);
  UseFont(Canvas, 10);
  if FPanel.FLink <> nil then
    Canvas.DrawText(CopyrightSign + ' 2026 Simon Moscrop  -  AGPLv3, no warranty  -  ',
      JuceRect(16, H - 22, FPanel.FLink.Left - 16, 16), jaRight, jvaCenter);

  // What this is, and what it is not, beside the name.
  Canvas.SetColor(ColDim);
  UseFont(Canvas, 11);
  Canvas.DrawText('plays Akai S900/S950 disks  -  independent, not affiliated with Akai or inMusic',
    JuceRect(100, 22, W - 100 - 16 - 126, 16), jaLeft, jvaCenter);

  UseFont(Canvas, 12.5);
  if FPanel.FNotice <> '' then
  begin
    Canvas.SetColor(ColProgram);
    Canvas.DrawText(FPanel.FNotice, JuceRect(16, 40, W - 32 - 84, 20), jaLeft, jvaCenter);
    Exit;
  end;
  Disk := FPanel.FMz.GetDiskName;
  if Disk = '' then
  begin
    Canvas.SetColor(ColDim);
    Canvas.DrawText('no disk  -  placeholder sound', JuceRect(16, 40, W - 32, 20), jaLeft, jvaCenter);
  end
  else
  begin
    Canvas.SetColor(ColText);
    Canvas.DrawText(ExtractFileName(Disk), JuceRect(16, 40, W - 32, 20), jaLeft, jvaCenter);
  end;
end;

{ ------------------------------------------------------------------------ TMzLearnMarker }

function TMzLearnMarker.HitTest(X, Y: Single): Boolean;
begin
  Result := False;
end;

procedure TMzLearnMarker.Paint(Canvas: TJuceCanvas);
begin
  Canvas.SetColor(ColNeutral);
  Canvas.DrawRoundRect(JuceInset(BoundsRect, 1), 4, 2);
  Canvas.SetFont(FontFace, 9, [jfsBold]);
  Canvas.DrawText('LEARN', JuceRect(0, 1, Width, 11), jaCenter, jvaCenter);
end;

{ -------------------------------------------------------------------------- TMz950Editor }

constructor TMz950Editor.Create(APlugin: TJucePlugin);
var
  I: Integer;
  C: TJuceParamControl;
begin
  inherited Create(APlugin);
  FMz := APlugin as TMz950;
  FMenuIndex := -1;
  FSeenLearning := -2;
  FSeenVersion := -1;
  FSeenGeneration := -1;
  FSeenEdits := -1;

  // The C++ Mz950LookAndFeel's colours for what the wrapper draws: tooltips and menus.
  Theme.Background := ColWindow;
  Theme.Panel := ColPanel;
  Theme.PanelBorder := ColPanelEdge;
  Theme.Text := ColText;
  Theme.TextDim := ColDim;
  Theme.Accent := ColPerform;
  Theme.FontName := FontFace;
  Theme.FontSize := 12.5;
  Theme.TooltipBackground := ColRaised;
  Theme.TooltipText := ColText;
  Theme.TooltipBorder := ColRaisedEdge;
  Theme.MenuBackground := ColRaised;
  Theme.MenuText := ColText;
  Theme.MenuHighlight := JuceWithAlpha(ColPerform, 0.25);
  Theme.MenuHighlightText := ColText;
  Theme.MenuHeader := ColDim;
  Theme.MenuFontSize := 13;
  Theme.Link := ColLink;

  SetSize(EditorWidth, EditorHeight);

  FBackdrop := TMzBackdrop.Create(Root);
  TMzBackdrop(FBackdrop).FPanel := Self;

  FGain := TMzKnob.Create(Root);
  FGain.ParameterId := 'gain';
  FGain.Accent := ColNeutral;
  FGain.TextBoxWidth := 46;
  FGainLabel := TMzLabel.Create(Root);
  FGainLabel.StyleCaption('Gain');

  FLoad := TMzButton.Create(Root);
  FLoad.Caption := 'Load disk...';
  FLoad.OnClick := LoadClick;

  FPrograms := TMzCombo.Create(Root);
  FPrograms.TextWhenNoChoices := 'no disk loaded';
  FPrograms.OnChange := ProgramChosen;

  FPatchLabel := TMzLabel.Create(Root);
  FPatchLabel.FontSize := 12;
  FPatchLabel.Bold := True;

  FVoicesLabel := TMzLabel.Create(Root);
  FVoicesLabel.FontSize := 11.5;
  FVoicesLabel.Color := ColDim;

  // This version, and where to find the next: the project's page, beside the licence notice.
  FLink := TJuceLink.Create(Root);
  FLink.Caption := 'Mz950_Pascal ' + Mz950Version + '  -  github.com/simozzer/Mz950';
  FLink.Url := 'https://github.com/simozzer/Mz950';
  FLink.FontSize := 10.5;
  FLink.Alignment := jaLeft;
  FLink.Hint := 'The project''s page: the latest version and what''s new in it, the source, '
    + 'and where to report a problem. Opens in your browser.';

  // --- the three tabs, each in the colour its controls wear
  FTabs := TMzTabBar.Create(Root);
  FTabs.AddTab('Program', ColProgram);
  FTabs.AddTab('Perform', ColPerform);
  FTabs.AddTab('Synth', ColExtra);       // violet: not on the S950
  FTabs.OnChange := TabChanged;

  FProgramPage := TMzProgramPage.Create(Root, FMz);
  FProgramPage.OnNotice := PageNotice;
  FPerformPage := TMzPerformPage.Create(Root, FMz);
  FSynthPage := TMzSynthPage.Create(Root, FMz);

  Arrange;

  // Every bound control has the MIDI learn menu.
  for I := 0 to NumParams - 1 do
  begin
    C := SpecControl(I);
    if C <> nil then
      C.OnContextMenu := ControlMenu;
  end;

  // On top of everything, hidden until a control learns.
  FMarker := TMzLearnMarker.Create(Root);
  FMarker.Visible := False;

  // Whatever the processor is already holding - this window may well not be the first.
  RefreshPrograms;
  FTabs.SetIndex(Max(0, Min(EditorTabCount - 1, FMz.EditorTab)), False);
  ShowTab(FTabs.Index);

  // The C++ window's size; scaled from half to twice it, the aspect kept, a corner to drag.
  SetScalable(0.5, 2.0, True);
end;

function TMz950Editor.Mz: TMz950;
begin
  Result := FMz;
end;

procedure TMz950Editor.Opened;
begin
  inherited Opened;
  Arrange;
  FTicks := 0;
  Poll;
  FProgramPage.Refresh;
  FPerformPage.ShowLfoSync;
end;

// The C++ resized, at the design size (the wrapper scales the drawing).
procedure TMz950Editor.Arrange;
var
  W, H: Integer;
begin
  W := EditorWidth;
  H := EditorHeight;
  FBackdrop.SetBounds(0, 0, W, H);
  // the foot: the project's link at the right, the licence notice painted to its left
  FLink.SetBounds(W - 16 - 240, H - 22, 240, 16);

  // the header: gain in its corner on the right, level with the disk row; the disk row and
  // the three tabs to its left
  FGainLabel.SetBounds(W - 16 - 68, 16 + 106 - 14, 68, 14);
  FGain.SetBounds(W - 16 - 68, 16 + 26, 68, 106 - 14 - 26 - 2);
  FLoad.SetBounds(16, 60, 104, 26);
  FPrograms.SetBounds(16 + 104 + 8, 60, W - 32 - 68 - 16 - 104 - 8, 26);
  FTabs.SetBounds(16, 94, W - 32 - 68 - 16, 28);

  // the status line above the licence line
  FPatchLabel.SetBounds(16, H - 16 - 14 - 20, (W - 32) div 3, 20);
  FVoicesLabel.SetBounds(16 + (W - 32) div 3, H - 16 - 14 - 20, W - 32 - (W - 32) div 3, 20);

  // the pages, between the tabs and the status line
  FProgramPage.SetBounds(16, 132, W - 32, H - 16 - 14 - 20 - 14 - 132);
  FPerformPage.SetBounds(16, 132, W - 32, H - 16 - 14 - 20 - 14 - 132);
  FSynthPage.SetBounds(16, 132, W - 32, H - 16 - 14 - 20 - 14 - 132);
  FProgramPage.ShowPage(FProgramPage.CurrentPage);
  FPerformPage.Layout;
  FSynthPage.Layout;
end;

function TMz950Editor.SpecControl(Index: Integer): TJuceParamControl;
begin
  if Index = PGain then
    Result := FGain
  else if FPerformPage <> nil then
    Result := FPerformPage.ControlOf(Index)
  else
    Result := nil;
end;

function TMz950Editor.SpecIndexOf(Control: TJuceControl): Integer;
var
  I: Integer;
begin
  for I := 0 to NumParams - 1 do
    if (Control <> nil) and (SpecControl(I) = Control) then
      Exit(I);
  Result := -1;
end;

procedure TMz950Editor.TabChanged(Sender: TObject);
begin
  ShowTab(FTabs.Index);
end;

procedure TMz950Editor.ShowTab(Tab: Integer);
begin
  Tab := Max(0, Min(EditorTabCount - 1, Tab));
  FMz.EditorTab := Tab;
  FTabs.SetIndex(Tab, False);
  FProgramPage.Visible := Tab = 0;
  FPerformPage.Visible := Tab = 1;
  FSynthPage.Visible := Tab = 2;
  FPerformPage.ShowLfoSync;     // the Rate knob or the division knob, whichever sync says
  if Tab = 0 then
    FProgramPage.Refresh;
  // the learn outline belongs to a control that may just have been hidden
  FSeenLearning := -2;
  UpdateLearning;
  Root.Invalidate;
end;

procedure TMz950Editor.RefreshPrograms;
var
  Names: TArray<string>;
  Chosen: Integer;
begin
  // Filling the box must not look like someone choosing from it: SetItems and SetItemIndex
  // never call OnChange.
  Names := FMz.GetProgramNames;
  FPrograms.SetItems(Names);
  Chosen := FMz.GetSelectedProgram;
  if (Chosen >= 0) and (Chosen < Length(Names)) then
    FPrograms.SetItemIndex(Chosen)
  else
    FPrograms.SetItemIndex(-1);
end;

procedure TMz950Editor.ProgramChosen(Sender: TObject);
begin
  FMz.SelectProgramFromPanel(FPrograms.ItemIndex);
end;

procedure TMz950Editor.Notice(const Text: string);
begin
  FNotice := Text;
  FNoticeUntil := Milliseconds + NoticeMs;
  FBackdrop.Invalidate;
end;

procedure TMz950Editor.PageNotice(Sender: TObject; const Text: string);
begin
  Notice(Text);
end;

// Somewhere useful to start: beside the disk this instance already has open, else wherever a
// disk was last chosen from, else the OS's choice.
procedure TMz950Editor.LoadClick(Sender: TObject);
var
  Start, OpenNow: string;
begin
  Start := '';
  OpenNow := FMz.GetDiskPath;
  if OpenNow <> '' then
  begin
    Start := ExtractFileDir(OpenNow);
    if (Start <> '') and not DirectoryExists(Start) then
      Start := '';
  end;
  if (Start = '') and (GLastDiskFolder <> '') and DirectoryExists(GLastDiskFolder) then
    Start := GLastDiskFolder;
  OpenFile('Open an Akai S900/S950 disk image', '*.hfe;*.img', Start, DiskChosen);
end;

procedure TMz950Editor.DiskChosen(Sender: TJuceEditor; Chosen: Boolean; const Path: string);
var
  S: TFileStream;
  Bytes: TBytes;
  Size: Int64;
  Err: string;
begin
  if (not Chosen) or (Path = '') then
    Exit;
  // Remembered before the load is attempted: a file that turns out not to be a disk is still
  // where the person was looking.
  if DirectoryExists(ExtractFileDir(Path)) then
    GLastDiskFolder := ExtractFileDir(Path);

  // The file is untrusted: no more than an image could be, then the disk reader checks it.
  Bytes := nil;
  try
    S := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      Size := S.Size;
      if Size > MaxDiskFileBytes then
      begin
        Notice('Could not open that disk: it is too big to be an S900/S950 disk image');
        Exit;
      end;
      SetLength(Bytes, Size);
      if Size > 0 then
        S.ReadBuffer(Bytes[0], Size);
    finally
      S.Free;
    end;
  except
    on E: Exception do
    begin
      Notice('Could not open that disk: ' + E.Message);
      Exit;
    end;
  end;

  if not FMz.LoadDiskBytes(Path, Path, Bytes, Err) then
  begin
    Notice('Could not open that disk: ' + Err);
    Exit;
  end;
  FNotice := '';
  RefreshPrograms;
  FProgramPage.Refresh;
  FBackdrop.Invalidate;
end;

function TMz950Editor.PlainOf(const Id: string; Default: Single): Single;
var
  I: Integer;
begin
  I := FindParameter(Id);
  if I >= 0 then
    Result := ParamToPlain(I, ParamNormalised(I))
  else
    Result := Default;
end;

// The status line: what is playing, voices sounding and how many NOTES may (the Polyphony
// control, capped at four when wide is on), and a disk recovered with bad or missing sectors.
procedure TMz950Editor.UpdateStatus;
var
  Voices, Notes, Bad, Missing: Integer;
  Wide: Boolean;
  State: string;
begin
  FPatchLabel.Caption := FMz.GetPatchName;
  Voices := FMz.GetActiveVoices;
  Wide := PlainOf('wide', 0) >= 0.5;
  Notes := Round(PlainOf('voices', 8));
  if Wide then
    Notes := Min(Notes, 4);
  State := IntToStr(Voices) + ' of 8 voices   -   up to ' + IntToStr(Notes);
  if Notes = 1 then
    State := State + ' note (mono)'
  else
    State := State + ' notes';
  if Wide then
    State := State + ', wide';
  Bad := FMz.GetBadSectors;
  Missing := FMz.GetMissingSectors;
  if (Bad > 0) or (Missing > 0) then
    State := State + '   -   recovered with ' + IntToStr(Bad) + ' bad and ' + IntToStr(Missing)
      + ' missing sectors';
  FVoicesLabel.Caption := State;
end;

procedure TMz950Editor.Poll;
var
  Generation, Edits: Integer;
begin
  if FMz = nil then
    Exit;
  UpdateLearning;
  Inc(FTicks);
  if (FTicks mod 3) <> 1 then
    Exit;

  // Follow the processor if it changed underneath us: the host's program chooser, a MIDI
  // program change, a saved set restored, a synth render adopted.
  Generation := FMz.GetDiskGeneration;
  if Generation <> FSeenGeneration then
  begin
    FSeenGeneration := Generation;
    RefreshPrograms;
    FProgramPage.Refresh;
    FBackdrop.Invalidate;
  end;

  // The Program tab re-reads the disk only when something changed it; the cyan "sounding"
  // readouts follow the Perform offsets every time.
  Edits := FMz.GetEditRevision;
  if FProgramPage.Visible then
  begin
    if Edits <> FSeenEdits then
      FProgramPage.Refresh
    else
      FProgramPage.RefreshSounding;
  end;
  FSeenEdits := Edits;

  if (FNotice <> '') and (Milliseconds > FNoticeUntil) then
  begin
    FNotice := '';
    FBackdrop.Invalidate;
  end;

  UpdateStatus;
end;

// The MIDI part of a control's hint, as the other ports say it.
function MidiText(Index, Cc: Integer; Learning: Boolean): string;
var
  Def: Integer;
begin
  Def := Specs[Index].Cc;
  if Learning then
    Result := 'MIDI LEARN: move a knob on your controller. Right-click to cancel.'
  else if Cc < 0 then
  begin
    if Def >= 0 then
      Result := 'No MIDI CC (default ' + IntToStr(Def) + '). Right-click to learn one.'
    else
      Result := 'No MIDI CC. Right-click to learn one.';
  end
  else if Cc <> Def then
  begin
    if Def >= 0 then
      Result := 'MIDI CC ' + IntToStr(Cc) + ', learned (default ' + IntToStr(Def) + '). Right-click to change.'
    else
      Result := 'MIDI CC ' + IntToStr(Cc) + ', learned. Right-click to change.';
  end
  else
    Result := 'MIDI CC ' + IntToStr(Cc) + '. Right-click to learn another.';
end;

function TMz950Editor.TipFor(Index: Integer): string;
begin
  if Index = PGain then
    Result := 'Gain: the level of everything the plug-in plays.'
  else
    Result := FPerformPage.TipOf(Index);
end;

// A control learning, or a CC changing (which may come from the audio thread): the hints say
// so, and the outline moves.
procedure TMz950Editor.UpdateLearning;
var
  L, V, I: Integer;
  T: TJuceParamControl;
  Cap: TMzLabel;
  Hint_: string;
  X1, Y1, X2, Y2: Single;
begin
  L := FMz.LearningIndex;
  V := FMz.MidiMapVersion;
  if (L = FSeenLearning) and (V = FSeenVersion) then
    Exit;
  FSeenLearning := L;
  FSeenVersion := V;
  for I := 0 to NumParams - 1 do
  begin
    T := SpecControl(I);
    if T = nil then
      Continue;
    Hint_ := TipFor(I) + #10 + MidiText(I, FMz.CcFor(I), L = I);
    T.Hint := Hint_;
    if I = PGain then
      Cap := FGainLabel
    else
      Cap := FPerformPage.CaptionOf(I);
    if Cap <> nil then
      Cap.Hint := Hint_;
  end;

  T := SpecControl(L);
  if (T <> nil) and T.Visible and ((L = PGain) or FPerformPage.Visible) then
  begin
    X1 := T.AbsoluteX;
    Y1 := T.AbsoluteY;
    X2 := X1 + T.Width;
    Y2 := Y1 + T.Height;
    if L = PGain then
      Cap := FGainLabel
    else
      Cap := FPerformPage.CaptionOf(L);
    if Cap <> nil then
    begin
      X1 := Min(X1, Cap.AbsoluteX);
      X2 := Max(X2, Cap.AbsoluteX + Cap.Width);
      Y2 := Max(Y2, Cap.AbsoluteY + Cap.Height);
    end;
    FMarker.SetBounds(Round(X1) - 4, Round(Y1) - 12, Round(X2 - X1) + 8, Round(Y2 - Y1) + 15);
    FMarker.Visible := True;
    FMarker.Invalidate;
  end
  else
    FMarker.Visible := False;
end;

procedure TMz950Editor.ControlMenu(Sender: TJuceControl; X, Y: Single; var Handled: Boolean);
var
  I, Cc, Def: Integer;
  Head, LearnText, RestoreText: string;
  ForgetFlags, RestoreFlags: Integer;
begin
  I := SpecIndexOf(Sender);
  if I < 0 then
    Exit;
  Handled := True;
  Cc := FMz.CcFor(I);
  Def := Specs[I].Cc;
  FMenuLearning := FMz.LearningIndex = I;
  if Cc >= 0 then
    Head := Specs[I].Name + '  -  CC ' + IntToStr(Cc)
  else
    Head := Specs[I].Name + '  -  no CC';
  if FMenuLearning then
    LearnText := 'Cancel MIDI Learn'
  else
    LearnText := 'MIDI Learn';
  ForgetFlags := 0;
  if Cc < 0 then
    ForgetFlags := JCP_MENU_DISABLED;
  RestoreFlags := 0;
  if Cc = Def then
    RestoreFlags := JCP_MENU_DISABLED;
  if Def >= 0 then
    RestoreText := 'Restore default (CC ' + IntToStr(Def) + ')'
  else
    RestoreText := 'Restore default (no CC)';
  if PopupMenu([JuceMenuItem(100, Head, JCP_MENU_HEADER),
                JuceMenuItem(MenuLearn, LearnText),
                JuceMenuItem(MenuForget, 'Forget CC', ForgetFlags),
                JuceMenuItem(MenuRestore, RestoreText, RestoreFlags),
                JuceMenuItem(101, '', JCP_MENU_SEPARATOR),
                JuceMenuItem(MenuResetAll, 'Reset all CCs to defaults')],
               Sender.AbsoluteX + X, Sender.AbsoluteY + Y, MenuChosen) <> 0 then
    FMenuIndex := I;
end;

procedure TMz950Editor.MenuChosen(Sender: TJuceEditor; MenuId, ItemId: Integer);
var
  I: Integer;
begin
  I := FMenuIndex;
  FMenuIndex := -1;
  if I < 0 then
    Exit;
  case ItemId of
    MenuLearn:
      if FMenuLearning then
        FMz.Learn(-1)
      else
        FMz.Learn(I);
    MenuForget:
      FMz.ForgetCc(I);
    MenuRestore:
      FMz.RestoreDefaultCc(I);
    MenuResetAll:
      FMz.ResetAllCcs;
  end;
  UpdateLearning;
end;

end.
