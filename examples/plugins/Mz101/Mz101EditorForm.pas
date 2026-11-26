// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// The Mz101 panel as a form, for designing only: the counterpart of the C++ Panel
// (Source/PluginEditor.cpp), laid out as it lays itself out - the same sections, sizes,
// colours (the TJuceThemeResource "Theme") and wording.
//
// Open Mz101Design.lpi in Lazarus with the PascalJUCE design-time package installed and
// edit the panel visually. The plug-in never compiles this unit (it would pull in the
// LCL/VCL): it embeds Mz101EditorForm.lfm (Free Pascal) or Mz101EditorForm.dfm (Delphi)
// and builds the same controls from it at run time (Mz101Editor.pas, JuceLayout.pas). The
// .lfm is the one built and tested; the .dfm describes the same panel for Delphi.
unit Mz101EditorForm;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  Classes, Forms, JuceDesignControls;

type
  TMz101EditorForm = class(TForm)
    Theme: TJuceThemeResource;
    NameStrip: TJucePanel;
    Title: TJuceLabel;
    Subtitle: TJuceLabel;
    ProjectLink: TJuceLink;
    PatchBox: TJuceComboBox;
    ModulatorBox: TJucePanel;
    LfoRate: TJuceSlider;
    LfoSync: TJuceSwitch;
    LfoWave: TJuceSwitch;
    ClockSource: TJuceSwitch;
    ClockDiv: TJuceSwitch;
    VcoBox: TJucePanel;
    VcoMod: TJuceSlider;
    Range: TJuceSwitch;
    Pw: TJuceSlider;
    PwmSource: TJuceSwitch;
    MixerBox: TJucePanel;
    Pulse: TJuceSlider;
    Saw: TJuceSlider;
    Sub: TJuceSlider;
    SubType: TJuceSwitch;
    Noise: TJuceSlider;
    VcfBox: TJucePanel;
    Cutoff: TJuceSlider;
    Res: TJuceSlider;
    VcfEnv: TJuceSlider;
    VcfMod: TJuceSlider;
    VcfKybd: TJuceSlider;
    VcaBox: TJucePanel;
    VcaMode: TJuceSwitch;
    EnvBox: TJucePanel;
    Attack: TJuceSlider;
    Decay: TJuceSlider;
    Sustain: TJuceSlider;
    Release: TJuceSlider;
    EnvTrig: TJuceSwitch;
    PortamentoBox: TJucePanel;
    PortaMode: TJuceSwitch;
    PortaTime: TJuceSlider;
    BenderBox: TJucePanel;
    BendVco: TJuceSlider;
    BendVcf: TJuceSlider;
    ModDepth: TJuceSlider;
    ArpeggioBox: TJucePanel;
    ArpMode: TJuceSwitch;
    ArpHold: TJuceButton;
    SequencerBox: TJucePanel;
    SeqMode: TJuceSwitch;
    TransRest: TJuceButton;
    Legato: TJuceButton;
    StepReadout: TJuceDisplay;
    KeyBox: TJucePanel;
    Transpose: TJuceSwitch;
    MasterBox: TJucePanel;
    Tune: TJuceSlider;
    Volume: TJuceSlider;
    KeyboardBox: TJucePanel;
    Keyboard: TJuceKeyboard;
  end;

var
  Mz101EditorFormInstance: TMz101EditorForm;

implementation

{$IFDEF FPC}
  {$R *.lfm}
{$ELSE}
  {$R *.dfm}
{$ENDIF}

end.
