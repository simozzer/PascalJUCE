// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The Mz808 panel as a form, for designing only: the counterpart of the C++ Panel
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same columns, knobs and
// pads at the same places and sizes, its colours (the TJuceThemeResource "Theme") and
// wording. Where the C++ panel paints (the band of colour along the top, each column's
// title and coloured line, the legends, the codes and notes on the pads), the form has
// panels and labels.
//
// Open Mz808Design.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// Mz808EditorForm.lfm (Free Pascal) or Mz808EditorForm.dfm (Delphi) and builds the same
// controls from it at run time (Mz808Editor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit Mz808EditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMz808EditorForm = class(TForm)
    Band1: TJucePanel;
    Band2: TJucePanel;
    Band3: TJucePanel;
    Band4: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PatchBox: TJuceComboBox;
    ColAccent: TJucePanel;
    AccentTitle: TJuceLabel;
    AccentStrip: TJucePanel;
    Accent: TJuceKnob;
    AccentLegend: TJuceLabel;
    AccentButton: TJuceButton;
    ColBassDrum: TJucePanel;
    BassDrumTitle: TJuceLabel;
    BassDrumStrip: TJucePanel;
    BdLevel: TJuceKnob;
    BdLevelLegend: TJuceLabel;
    BdTone: TJuceKnob;
    BdToneLegend: TJuceLabel;
    BdDecay: TJuceKnob;
    BdDecayLegend: TJuceLabel;
    LedBD: TJuceLed;
    PadBD: TJuceButton;
    CodeBD: TJuceLabel;
    NoteBD: TJuceLabel;
    ColSnareDrum: TJucePanel;
    SnareDrumTitle: TJuceLabel;
    SnareDrumStrip: TJucePanel;
    SdLevel: TJuceKnob;
    SdLevelLegend: TJuceLabel;
    SdTone: TJuceKnob;
    SdToneLegend: TJuceLabel;
    SdSnappy: TJuceKnob;
    SdSnappyLegend: TJuceLabel;
    LedSD: TJuceLed;
    PadSD: TJuceButton;
    CodeSD: TJuceLabel;
    NoteSD: TJuceLabel;
    ColLowTom: TJucePanel;
    LowTomTitle1: TJuceLabel;
    LowTomTitle2: TJuceLabel;
    LowTomStrip: TJucePanel;
    LtLevel: TJuceKnob;
    LtLevelLegend: TJuceLabel;
    LtTuning: TJuceKnob;
    LtTuningLegend: TJuceLabel;
    LedLT: TJuceLed;
    PadLT: TJuceButton;
    CodeLT: TJuceLabel;
    NoteLT: TJuceLabel;
    LedLC: TJuceLed;
    PadLC: TJuceButton;
    CodeLC: TJuceLabel;
    NoteLC: TJuceLabel;
    ColMidTom: TJucePanel;
    MidTomTitle1: TJuceLabel;
    MidTomTitle2: TJuceLabel;
    MidTomStrip: TJucePanel;
    MtLevel: TJuceKnob;
    MtLevelLegend: TJuceLabel;
    MtTuning: TJuceKnob;
    MtTuningLegend: TJuceLabel;
    LedMT: TJuceLed;
    PadMT: TJuceButton;
    CodeMT: TJuceLabel;
    NoteMT: TJuceLabel;
    LedMC: TJuceLed;
    PadMC: TJuceButton;
    CodeMC: TJuceLabel;
    NoteMC: TJuceLabel;
    ColHiTom: TJucePanel;
    HiTomTitle1: TJuceLabel;
    HiTomTitle2: TJuceLabel;
    HiTomStrip: TJucePanel;
    HtLevel: TJuceKnob;
    HtLevelLegend: TJuceLabel;
    HtTuning: TJuceKnob;
    HtTuningLegend: TJuceLabel;
    LedHT: TJuceLed;
    PadHT: TJuceButton;
    CodeHT: TJuceLabel;
    NoteHT: TJuceLabel;
    LedHC: TJuceLed;
    PadHC: TJuceButton;
    CodeHC: TJuceLabel;
    NoteHC: TJuceLabel;
    ColRimShot: TJucePanel;
    RimShotTitle1: TJuceLabel;
    RimShotTitle2: TJuceLabel;
    RimShotStrip: TJucePanel;
    RsLevel: TJuceKnob;
    RsLevelLegend: TJuceLabel;
    LedRS: TJuceLed;
    PadRS: TJuceButton;
    CodeRS: TJuceLabel;
    NoteRS: TJuceLabel;
    LedCL: TJuceLed;
    PadCL: TJuceButton;
    CodeCL: TJuceLabel;
    NoteCL: TJuceLabel;
    ColHandClap: TJucePanel;
    HandClapTitle1: TJuceLabel;
    HandClapTitle2: TJuceLabel;
    HandClapStrip: TJucePanel;
    CpLevel: TJuceKnob;
    CpLevelLegend: TJuceLabel;
    LedCP: TJuceLed;
    PadCP: TJuceButton;
    CodeCP: TJuceLabel;
    NoteCP: TJuceLabel;
    LedMA: TJuceLed;
    PadMA: TJuceButton;
    CodeMA: TJuceLabel;
    NoteMA: TJuceLabel;
    ColCowBell: TJucePanel;
    CowBellTitle: TJuceLabel;
    CowBellStrip: TJucePanel;
    CbLevel: TJuceKnob;
    CbLevelLegend: TJuceLabel;
    LedCB: TJuceLed;
    PadCB: TJuceButton;
    CodeCB: TJuceLabel;
    NoteCB: TJuceLabel;
    ColCymbal: TJucePanel;
    CymbalTitle: TJuceLabel;
    CymbalStrip: TJucePanel;
    CyLevel: TJuceKnob;
    CyLevelLegend: TJuceLabel;
    CyTone: TJuceKnob;
    CyToneLegend: TJuceLabel;
    CyDecay: TJuceKnob;
    CyDecayLegend: TJuceLabel;
    LedCY: TJuceLed;
    PadCY: TJuceButton;
    CodeCY: TJuceLabel;
    NoteCY: TJuceLabel;
    ColOpenHihat: TJucePanel;
    OpenHihatTitle1: TJuceLabel;
    OpenHihatTitle2: TJuceLabel;
    OpenHihatStrip: TJucePanel;
    OhLevel: TJuceKnob;
    OhLevelLegend: TJuceLabel;
    OhDecay: TJuceKnob;
    OhDecayLegend: TJuceLabel;
    LedOH: TJuceLed;
    PadOH: TJuceButton;
    CodeOH: TJuceLabel;
    NoteOH: TJuceLabel;
    ColClosedHihat: TJucePanel;
    ClosedHihatTitle1: TJuceLabel;
    ClosedHihatTitle2: TJuceLabel;
    ClosedHihatStrip: TJucePanel;
    ChLevel: TJuceKnob;
    ChLevelLegend: TJuceLabel;
    LedCH: TJuceLed;
    PadCH: TJuceButton;
    CodeCH: TJuceLabel;
    NoteCH: TJuceLabel;
    ColMaster: TJucePanel;
    MasterTitle: TJuceLabel;
    MasterStrip: TJucePanel;
    Volume: TJuceKnob;
    VolumeLegend: TJuceLabel;
    HelpLine: TJuceLabel;
    Copyright: TJuceLabel;
    Theme: TJuceThemeResource;
  end;

var
  Mz808EditorFormInstance: TMz808EditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
