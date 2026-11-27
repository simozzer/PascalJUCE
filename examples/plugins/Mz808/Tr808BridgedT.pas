// Mz808 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Source/TR808/BridgedT.h.

unit Tr808BridgedT;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  Tr808Dsp;

type
  //
  // The 808's drum oscillator. A bridged-T network in an op-amp's feedback path is a band
  // pass with a high Q; kicked by a pulse it rings as a decaying, nearly-sine wave at its
  // centre. The bass drum, snare, toms, congas, rim shot and claves are all built from one or
  // two of these, with nothing but the kick to start them - which is why a fast repeat adds
  // to a ring still going rather than restarting it, and the 808 has no machine-gun effect.
  //
  // Modelled as the band pass it is: centre f, and a Q that sets how long it rings. An
  // amplitude time constant tau needs Q = pi f tau.
  //
  TBridgedT = record
  private
    FF, FK: Single;
  public
    Svf: TSvf;
    procedure Init;
    procedure Prepare(SampleRate: Single); inline;
    // centre in hertz, ring time constant in seconds
    procedure SetTo(Hz, TauSeconds: Single);
    // with the centre moved, for this sample - a pitch sweep
    function Process(X, Hz: Single): Single; overload;
    function Process(X: Single): Single; overload; inline;
    function Damping: Single; inline;
    function Centre: Single; inline;
    function Energy: Single; inline;
    procedure Reset; inline;
  end;

implementation

{ TBridgedT }

procedure TBridgedT.Init;
begin
  Svf.Init;
  FF := 100;
  FK := 0.01;
end;

procedure TBridgedT.Prepare(SampleRate: Single);
begin
  Svf.Prepare(SampleRate);
end;

procedure TBridgedT.SetTo(Hz, TauSeconds: Single);
begin
  FF := Hz;
  FK := 1 / (PiF * Hz * TauSeconds);
  Svf.Setup(FF, 1 / FK);
end;

function TBridgedT.Process(X, Hz: Single): Single;
begin
  Svf.Tune(Hz, FK);
  Result := Svf.Process(X);
end;

function TBridgedT.Process(X: Single): Single;
begin
  Result := Svf.Process(X);
end;

function TBridgedT.Damping: Single;
begin
  Result := FK;
end;

function TBridgedT.Centre: Single;
begin
  Result := FF;
end;

function TBridgedT.Energy: Single;
begin
  Result := Svf.Energy;
end;

procedure TBridgedT.Reset;
begin
  Svf.Reset;
end;

end.
