unit TinySynthEditor;

{$MODE DELPHI}

interface

uses
  JucePlugin, JuceUI;

type
  TTinySynthEditor = class(TJuceEditor)
  public
    constructor Create(APlugin: TJucePlugin); override;
  end;

implementation

uses
  JuceControls, JuceLayout;

{$R TinySynthForm.lfm}   // the form file only: not the form unit

constructor TTinySynthEditor.Create(APlugin: TJucePlugin);
begin
  inherited Create(APlugin);
  JuceLoadLayoutResource(Self, 'TTinySynthForm');   // size, colours, every control
  SetScalable(0.75, 2.0, True);                     // resizable from 75% to 200%
end;

end.
