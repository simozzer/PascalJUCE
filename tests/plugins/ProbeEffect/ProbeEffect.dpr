library ProbeEffect;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

uses
  JucePlugin,
  ProbeEffectUnit in 'ProbeEffectUnit.pas';

exports
  pascaljuce_plugin_entry;

begin
  ParamGain     := JuceAddFloatParameter('gain', 'Gain', 0, 2, 1);
  ParamThrow    := JuceAddBoolParameter('throw', 'Throw', False);
  ParamLatency  := JuceAddIntParameter('latency', 'Latency', 0, 4096, 0, 'samples');
  ParamRestored := JuceAddFloatParameter('restored', 'Restored', 0, 1000000, 0, '', 1, False);
  JuceRegisterPlugin(TProbeEffect, jkEffect);
end.
