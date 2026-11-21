{
  PascalSynth - plugin library for the PascalJUCE wrapper.
  Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build
  this library in Delphi (Win64) and point PASCAL_LIBRARY at the DLL.
}
library PascalSynth;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

uses
  JucePlugin,
  SimpleSynth in 'SimpleSynth.pas';

exports
  pascaljuce_plugin_entry;

begin
  ParamWave    := JuceAddChoiceParameter('wave', 'Waveform', ['Sine', 'Saw', 'Square'], 1);
  ParamAttack  := JuceAddFloatParameter('attack', 'Attack', 1, 2000, 10, 'ms');
  ParamRelease := JuceAddFloatParameter('release', 'Release', 1, 2000, 300, 'ms');
  ParamGain    := JuceAddFloatParameter('gain', 'Gain', 0, 1, 0.7);
  JuceRegisterPlugin(TSimpleSynth, jkInstrument);
end.
