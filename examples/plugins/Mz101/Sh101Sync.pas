// Mz101 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/SH101/Sync.h.

unit Sh101Sync;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

//
// The note lengths the modulator can lock to with SYNC on HOST, slowest first, so the RATE
// slider still runs slow at the bottom and fast at the top. Lengths are in quarter notes.
//
type
  TSyncDivision = record
    Name: string;
    Quarters: Double;
  end;

const
  NumSyncDivisions = 16;

  SyncDivisions: array[0..NumSyncDivisions - 1] of TSyncDivision = (
    (Name: '4 bars'; Quarters: 16.0),   (Name: '2 bars'; Quarters: 8.0),
    (Name: '1 bar';  Quarters: 4.0),    (Name: '1/2.';   Quarters: 3.0),
    (Name: '1/2';    Quarters: 2.0),    (Name: '1/4.';   Quarters: 1.5),
    (Name: '1/2T';   Quarters: 4.0 / 3), (Name: '1/4';   Quarters: 1.0),
    (Name: '1/8.';   Quarters: 0.75),   (Name: '1/4T';   Quarters: 2.0 / 3),
    (Name: '1/8';    Quarters: 0.5),    (Name: '1/16.';  Quarters: 0.375),
    (Name: '1/8T';   Quarters: 1.0 / 3), (Name: '1/16';  Quarters: 0.25),
    (Name: '1/16T';  Quarters: 1.0 / 6), (Name: '1/32';  Quarters: 0.125)
  );

// The RATE slider, 0..10, as an index into SyncDivisions - equal slices of its travel.
function SyncDivisionIndex(Rate: Single): Integer;

implementation

uses
  Sh101Dsp;

function SyncDivisionIndex(Rate: Single): Integer;
var
  I: Integer;
begin
  I := LRound(Rate / 10 * (NumSyncDivisions - 1));
  if I < 0 then
    I := 0;
  if I > NumSyncDivisions - 1 then
    I := NumSyncDivisions - 1;
  Result := I;
end;

end.
