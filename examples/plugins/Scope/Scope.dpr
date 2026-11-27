{
  Scope - an oscilloscope effect for the PascalJUCE wrapper.
  SPDX-License-Identifier: MIT-0 (an example: copy it freely, no notice needed).

  Put it on a track: the audio passes through unchanged, and the window
  shows it as one trace (left and right mixed), with TIME (1 to 170 ms) and
  a trigger. It has no parameters: TIME and the trigger change the view,
  not the sound, so they are saved with the project but not automated.
  Build: see CMakeLists.txt in this folder (pascaljuce_add_plugin).
}
library Scope;

{$IFDEF FPC}
  {$MODE DELPHI}
  {$CODEPAGE UTF8} { string literals in this file are UTF-8 }
{$ENDIF}

uses
  JucePlugin,
  ScopePlugin in 'ScopePlugin.pas',
  ScopeEditor in 'ScopeEditor.pas';

exports
  pascaljuce_plugin_entry;

begin
  JuceRegisterPlugin(TScopePlugin, jkEffect);
end.
