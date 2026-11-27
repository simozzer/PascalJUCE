// Mz303 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Mz303_Pascal: the Mz303 TB-303 emulation as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ on the search path) and point PASCAL_LIBRARY at the DLL.
library Mz303;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  Tb303Dsp in 'Tb303Dsp.pas',
  Tb303Settings in 'Tb303Settings.pas',
  Tb303Decimator in 'Tb303Decimator.pas',
  Tb303Vco in 'Tb303Vco.pas',
  Tb303Vcf in 'Tb303Vcf.pas',
  Tb303Envelopes in 'Tb303Envelopes.pas',
  Tb303Engine in 'Tb303Engine.pas',
  Mz303Params in 'Mz303Params.pas',
  Mz303Presets in 'Mz303Presets.pas',
  Mz303Plugin in 'Mz303Plugin.pas',
  Mz303Editor in 'Mz303Editor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMz303;
end.
