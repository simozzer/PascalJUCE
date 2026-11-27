// MzPCF - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// MzPCF_Pascal: the MzPCF pattern-controlled filter as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ and PCF/ on the search path) and point PASCAL_LIBRARY at the DLL.
library MzPCF;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  PcfMath in 'PCF/PcfMath.pas',
  PcfPatterns in 'PCF/PcfPatterns.pas',
  PcfStepClock in 'PCF/PcfStepClock.pas',
  PcfEnvelope in 'PCF/PcfEnvelope.pas',
  PcfEngine in 'PCF/PcfEngine.pas',
  PcfControls in 'PCF/PcfControls.pas',
  MzPcfParams in 'MzPcfParams.pas',
  MzPcfPlugin in 'MzPcfPlugin.pas',
  MzPcfEditor in 'MzPcfEditor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMzPcf;
end.
