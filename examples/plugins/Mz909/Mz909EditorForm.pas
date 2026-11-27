// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The Mz909 panel as a form, for designing only: the counterpart of the C++ Panel
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same columns, sizes,
// colours (the TJuceThemeResource "Theme") and wording. Each column is a panel holding its
// title, its coloured line, its knobs with their legends beneath, and its pads (a light,
// then the key, with the sound's code and MIDI note on it).
//
// Open Mz909Design.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually (or this unit in Delphi, with the PascalJUCE design package).
// The plug-in never compiles this unit (it would pull in the LCL/VCL): it embeds
// Mz909EditorForm.lfm (Free Pascal) or Mz909EditorForm.dfm (Delphi) and builds the same
// controls from it at run time (Mz909Editor.pas, JuceLayout.pas). The .lfm is the one
// built and tested; the .dfm describes the same panel for Delphi.
unit Mz909EditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMz909EditorForm = class(TForm)
    BandLeft: TJucePanel;
    BandRight: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PatchBox: TJuceComboBox;
    AccentColumn: TJucePanel;
    AccentTitle: TJuceLabel;
    AccentLine: TJucePanel;
    Accent: TJuceKnob;
    AccentLegend: TJuceLabel;
    AccentButton: TJuceButton;
    BassDrumColumn: TJucePanel;
    BassDrumTitle: TJuceLabel;
    BassDrumLine: TJucePanel;
    BdLevel: TJuceKnob;
    BdLevelLegend: TJuceLabel;
    BdTune: TJuceKnob;
    BdTuneLegend: TJuceLabel;
    BdAttack: TJuceKnob;
    BdAttackLegend: TJuceLabel;
    BdDecay: TJuceKnob;
    BdDecayLegend: TJuceLabel;
    LedBD: TJuceLed;
    PadBD: TJuceButton;
    CodeBD: TJuceLabel;
    NoteBD: TJuceLabel;
    SnareDrumColumn: TJucePanel;
    SnareDrumTitle: TJuceLabel;
    SnareDrumLine: TJucePanel;
    SdLevel: TJuceKnob;
    SdLevelLegend: TJuceLabel;
    SdTune: TJuceKnob;
    SdTuneLegend: TJuceLabel;
    SdTone: TJuceKnob;
    SdToneLegend: TJuceLabel;
    SdSnappy: TJuceKnob;
    SdSnappyLegend: TJuceLabel;
    LedSD: TJuceLed;
    PadSD: TJuceButton;
    CodeSD: TJuceLabel;
    NoteSD: TJuceLabel;
    LowTomColumn: TJucePanel;
    LowTomTitle: TJuceLabel;
    LowTomLine: TJucePanel;
    LtLevel: TJuceKnob;
    LtLevelLegend: TJuceLabel;
    LtTune: TJuceKnob;
    LtTuneLegend: TJuceLabel;
    LtDecay: TJuceKnob;
    LtDecayLegend: TJuceLabel;
    LedLT: TJuceLed;
    PadLT: TJuceButton;
    CodeLT: TJuceLabel;
    NoteLT: TJuceLabel;
    MidTomColumn: TJucePanel;
    MidTomTitle: TJuceLabel;
    MidTomLine: TJucePanel;
    MtLevel: TJuceKnob;
    MtLevelLegend: TJuceLabel;
    MtTune: TJuceKnob;
    MtTuneLegend: TJuceLabel;
    MtDecay: TJuceKnob;
    MtDecayLegend: TJuceLabel;
    LedMT: TJuceLed;
    PadMT: TJuceButton;
    CodeMT: TJuceLabel;
    NoteMT: TJuceLabel;
    HiTomColumn: TJucePanel;
    HiTomTitle: TJuceLabel;
    HiTomLine: TJucePanel;
    HtLevel: TJuceKnob;
    HtLevelLegend: TJuceLabel;
    HtTune: TJuceKnob;
    HtTuneLegend: TJuceLabel;
    HtDecay: TJuceKnob;
    HtDecayLegend: TJuceLabel;
    LedHT: TJuceLed;
    PadHT: TJuceButton;
    CodeHT: TJuceLabel;
    NoteHT: TJuceLabel;
    RimShotColumn: TJucePanel;
    RimShotTitle: TJuceLabel;
    RimShotLine: TJucePanel;
    RsLevel: TJuceKnob;
    RsLevelLegend: TJuceLabel;
    LedRS: TJuceLed;
    PadRS: TJuceButton;
    CodeRS: TJuceLabel;
    NoteRS: TJuceLabel;
    HandClapColumn: TJucePanel;
    HandClapTitle: TJuceLabel;
    HandClapLine: TJucePanel;
    CpLevel: TJuceKnob;
    CpLevelLegend: TJuceLabel;
    LedCP: TJuceLed;
    PadCP: TJuceButton;
    CodeCP: TJuceLabel;
    NoteCP: TJuceLabel;
    HiHatColumn: TJucePanel;
    HiHatTitle: TJuceLabel;
    HiHatLine: TJucePanel;
    HhLevel: TJuceKnob;
    HhLevelLegend: TJuceLabel;
    ChDecay: TJuceKnob;
    ChDecayLegend: TJuceLabel;
    OhDecay: TJuceKnob;
    OhDecayLegend: TJuceLabel;
    LedCH: TJuceLed;
    PadCH: TJuceButton;
    CodeCH: TJuceLabel;
    NoteCH: TJuceLabel;
    LedOH: TJuceLed;
    PadOH: TJuceButton;
    CodeOH: TJuceLabel;
    NoteOH: TJuceLabel;
    CrashColumn: TJucePanel;
    CrashTitle: TJuceLabel;
    CrashLine: TJucePanel;
    CrLevel: TJuceKnob;
    CrLevelLegend: TJuceLabel;
    CrTune: TJuceKnob;
    CrTuneLegend: TJuceLabel;
    LedCC: TJuceLed;
    PadCC: TJuceButton;
    CodeCC: TJuceLabel;
    NoteCC: TJuceLabel;
    RideColumn: TJucePanel;
    RideTitle: TJuceLabel;
    RideLine: TJucePanel;
    RdLevel: TJuceKnob;
    RdLevelLegend: TJuceLabel;
    RdTune: TJuceKnob;
    RdTuneLegend: TJuceLabel;
    LedRC: TJuceLed;
    PadRC: TJuceButton;
    CodeRC: TJuceLabel;
    NoteRC: TJuceLabel;
    MasterColumn: TJucePanel;
    MasterTitle: TJuceLabel;
    MasterLine: TJucePanel;
    Volume: TJuceKnob;
    VolumeLegend: TJuceLabel;
    Footer: TJuceLabel;
    Copyright: TJuceLabel;
    Theme: TJuceThemeResource;
  end;

var
  Mz909EditorFormInstance: TMz909EditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
