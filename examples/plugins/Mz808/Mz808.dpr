// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Mz808_Pascal: the Mz808 TR-808 emulation as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ on the search path) and point PASCAL_LIBRARY at the DLL.
library Mz808;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  Tr808Dsp in 'Tr808Dsp.pas',
  Tr808Settings in 'Tr808Settings.pas',
  Tr808Trigger in 'Tr808Trigger.pas',
  Tr808BridgedT in 'Tr808BridgedT.pas',
  Tr808BassDrum in 'Tr808BassDrum.pas',
  Tr808SnareDrum in 'Tr808SnareDrum.pas',
  Tr808Toms in 'Tr808Toms.pas',
  Tr808RimShot in 'Tr808RimShot.pas',
  Tr808HandClap in 'Tr808HandClap.pas',
  Tr808Metal in 'Tr808Metal.pas',
  Tr808Cowbell in 'Tr808Cowbell.pas',
  Tr808Cymbal in 'Tr808Cymbal.pas',
  Tr808HiHat in 'Tr808HiHat.pas',
  Tr808Engine in 'Tr808Engine.pas',
  Mz808Params in 'Mz808Params.pas',
  Mz808Presets in 'Mz808Presets.pas',
  Mz808Plugin in 'Mz808Plugin.pas',
  Mz808Editor in 'Mz808Editor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMz808;
end.
