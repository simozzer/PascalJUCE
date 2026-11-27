// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Mz950_Pascal: the VirtualS950 Akai S950 sampler (Mz950) as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ on the search path) and point PASCAL_LIBRARY at the DLL.
library Mz950;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  S950Math in 'S950Math.pas',
  S950Patch in 'S950Patch.pas',
  S950Cal in 'S950Cal.pas',
  S950Filter in 'S950Filter.pas',
  S950Voice in 'S950Voice.pas',
  S950Engine in 'S950Engine.pas',
  S950Hfe in 'S950Hfe.pas',
  S950Disk in 'S950Disk.pas',
  S950Synth in 'S950Synth.pas',
  S950SynthPatch in 'S950SynthPatch.pas',
  Mz950Params in 'Mz950Params.pas',
  Mz950Gzip in 'Mz950Gzip.pas',
  Mz950Plugin in 'Mz950Plugin.pas'
  {$IFNDEF MZ950_NO_EDITOR},
  Mz950Look in 'Mz950Look.pas',
  Mz950Controls in 'Mz950Controls.pas',
  Mz950ProgramPage in 'Mz950ProgramPage.pas',
  Mz950PerformPage in 'Mz950PerformPage.pas',
  Mz950SynthPage in 'Mz950SynthPage.pas',
  Mz950Editor in 'Mz950Editor.pas'{$ENDIF};

exports
  pascaljuce_plugin_entry;

begin
  RegisterMz950;
end.
