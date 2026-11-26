unit TinySynthForm;

{ The Tiny Synth panel, for designing only (open TinySynthDesign.lpi).
  The plug-in never uses this unit: it embeds TinySynthForm.lfm. }

{$mode delphi}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, JuceDesignControls;

type
  TTinySynthForm = class(TForm)
    MainPanel: TJucePanel;
    Wave: TJuceSwitch;
    Cutoff: TJuceKnob;
    Resonance: TJuceKnob;
    Attack: TJuceKnob;
    Release: TJuceKnob;
    Volume: TJuceKnob;
    OutMeter: TJuceMeter;
  end;

var
  TinySynthForm: TTinySynthForm;

implementation

{$R *.lfm}

end.
