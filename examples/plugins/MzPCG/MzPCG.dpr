// MzPCG - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// MzPCG_Pascal: the MzPCG pattern-controlled gain as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/, ../MzPCF/PCF and PCG/ on the search path) and point
// PASCAL_LIBRARY at the DLL.
library MzPCG;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  PcfMath in '../MzPCF/PCF/PcfMath.pas',
  PcfPatterns in '../MzPCF/PCF/PcfPatterns.pas',
  PcfStepClock in '../MzPCF/PCF/PcfStepClock.pas',
  PcfControls in '../MzPCF/PCF/PcfControls.pas',
  PcgEngine in 'PCG/PcgEngine.pas',
  PcgControls in 'PCG/PcgControls.pas',
  MzPcgParams in 'MzPcgParams.pas',
  MzPcgPlugin in 'MzPcgPlugin.pas',
  MzPcgEditor in 'MzPcgEditor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMzPcg;
end.
