// MzPCD - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// MzPCD_Pascal: the MzPCD pattern-controlled distortion as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/, PCD/ and ../MzPCF/PCF/ on the search path) and point
// PASCAL_LIBRARY at the DLL.
library MzPCD;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  PcfMath in '../MzPCF/PCF/PcfMath.pas',
  PcfPatterns in '../MzPCF/PCF/PcfPatterns.pas',
  PcfStepClock in '../MzPCF/PCF/PcfStepClock.pas',
  PcfEnvelope in '../MzPCF/PCF/PcfEnvelope.pas',
  PcfControls in '../MzPCF/PCF/PcfControls.pas',
  PcdMath in 'PCD/PcdMath.pas',
  PcdRebirthDist in 'PCD/PcdRebirthDist.pas',
  PcdOversampler in 'PCD/PcdOversampler.pas',
  PcdEngine in 'PCD/PcdEngine.pas',
  PcdControls in 'PCD/PcdControls.pas',
  MzPcdParams in 'MzPcdParams.pas',
  MzPcdPlugin in 'MzPcdPlugin.pas',
  MzPcdEditor in 'MzPcdEditor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMzPcd;
end.
