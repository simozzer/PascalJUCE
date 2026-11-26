library TinySynth;

{$MODE DELPHI}

uses
  JucePlugin,     // keep this first
  TinySynthDsp;

exports
  pascaljuce_plugin_entry;

begin
  ParamWave      := JuceAddChoiceParameter('wave', 'Waveform', ['Saw', 'Square'], 0);
  ParamCutoff    := JuceAddFloatParameter('cutoff', 'Cutoff', 0, 100, 60);
  ParamResonance := JuceAddFloatParameter('resonance', 'Resonance', 0, 100, 20, '%');
  ParamAttack    := JuceAddFloatParameter('attack', 'Attack', 1, 2000, 5, 'ms');
  ParamRelease   := JuceAddFloatParameter('release', 'Release', 1, 3000, 300, 'ms');
  ParamVolume    := JuceAddFloatParameter('volume', 'Volume', -48, 0, -12, 'dB');
  JuceRegisterPlugin(TTinySynth, jkInstrument);
end.
