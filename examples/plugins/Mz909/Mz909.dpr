// Mz909 - an emulation of the TR-909 Rhythm Composer
// Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Mz909_Pascal: the Mz909 TR-909 emulation as a PascalJUCE plug-in library.
// Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin), or build this library
// in Delphi (Win64, pascal/ on the search path) and point PASCAL_LIBRARY at the DLL.
library Mz909;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  JucePlugin,
  Tr909Dsp in 'Tr909Dsp.pas',
  Tr909Settings in 'Tr909Settings.pas',
  Tr909Trigger in 'Tr909Trigger.pas',
  Tr909Vco in 'Tr909Vco.pas',
  Tr909Rom in 'Tr909Rom.pas',
  Tr909RomProfiles in 'Tr909RomProfiles.pas',
  Tr909Roms in 'Tr909Roms.pas',
  Tr909BassDrum in 'Tr909BassDrum.pas',
  Tr909SnareDrum in 'Tr909SnareDrum.pas',
  Tr909Toms in 'Tr909Toms.pas',
  Tr909RimShot in 'Tr909RimShot.pas',
  Tr909HandClap in 'Tr909HandClap.pas',
  Tr909HiHat in 'Tr909HiHat.pas',
  Tr909Cymbal in 'Tr909Cymbal.pas',
  Tr909Engine in 'Tr909Engine.pas',
  Mz909Params in 'Mz909Params.pas',
  Mz909Presets in 'Mz909Presets.pas',
  Mz909Plugin in 'Mz909Plugin.pas',
  Mz909Editor in 'Mz909Editor.pas';

exports
  pascaljuce_plugin_entry;

begin
  RegisterMz909;
end.
