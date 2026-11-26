// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Mz101 Pascal: the Mz101 SH-101 emulation as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ on the search path) and point PASCAL_LIBRARY at the DLL.
library Mz101;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  Sh101Dsp in 'Sh101Dsp.pas',
  Sh101Settings in 'Sh101Settings.pas',
  Sh101Sync in 'Sh101Sync.pas',
  Sh101Decimator in 'Sh101Decimator.pas',
  Sh101Envelope in 'Sh101Envelope.pas',
  Sh101Lfo in 'Sh101Lfo.pas',
  Sh101Vcf in 'Sh101Vcf.pas',
  Sh101Vco in 'Sh101Vco.pas',
  Sh101Engine in 'Sh101Engine.pas',
  Mz101Params in 'Mz101Params.pas',
  Mz101Presets in 'Mz101Presets.pas',
  Mz101Plugin in 'Mz101Plugin.pas',
  Mz101Editor in 'Mz101Editor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMz101;
end.
