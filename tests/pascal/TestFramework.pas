{
  TestFramework - a minimal, dependency-free test harness that behaves the
  same under Free Pascal and Delphi (FPCUnit/DUnitX would split the two).

    Suite('Audio buffers');
    Check(A.NumChannels = 2, 'two channels');
    CheckEquals(1.0, Value, 1e-6, 'gain applied');
    CheckRaises(EJuceError, DoBadThing, 'bad thing raises');
    Halt(TestSummary);
}
unit TestFramework;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  SysUtils;

type
  TTestProc = procedure of object;
  TTestProcPlain = procedure;

procedure Suite(const Name: string);
procedure Check(Condition: Boolean; const What: string);
procedure CheckEquals(Expected, Actual: Int64; const What: string); overload;
procedure CheckEquals(Expected, Actual: Double; Tolerance: Double; const What: string); overload;
procedure CheckEquals(const Expected, Actual: string; const What: string); overload;
procedure CheckRaises(ExceptionClass: ExceptClass; Proc: TTestProc; const What: string); overload;
procedure CheckRaises(ExceptionClass: ExceptClass; Proc: TTestProcPlain; const What: string); overload;
procedure Skip(const What, Reason: string);
{ Prints totals; returns the process exit code (0 = all passed). }
function TestSummary: Integer;

var
  { Set by CheckRaises: message of the exception that was raised. }
  LastExceptionMessage: string;

implementation

var
  Passed, Failed, Skipped: Integer;
  CurrentSuite: string;

procedure Suite(const Name: string);
begin
  CurrentSuite := Name;
  WriteLn(Name);
end;

procedure Check(Condition: Boolean; const What: string);
begin
  if Condition then
  begin
    Inc(Passed);
    WriteLn('  ok    ', What);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', What, '   [', CurrentSuite, ']');
  end;
end;

procedure CheckEquals(Expected, Actual: Int64; const What: string);
begin
  if Expected = Actual then
    Check(True, What)
  else
    Check(False, Format('%s (expected %d, got %d)', [What, Expected, Actual]));
end;

procedure CheckEquals(Expected, Actual: Double; Tolerance: Double; const What: string);
begin
  if Abs(Expected - Actual) <= Tolerance then
    Check(True, What)
  else
    Check(False, Format('%s (expected %g, got %g)', [What, Expected, Actual]));
end;

procedure CheckEquals(const Expected, Actual: string; const What: string);
begin
  if Expected = Actual then
    Check(True, What)
  else
    Check(False, Format('%s (expected "%s", got "%s")', [What, Expected, Actual]));
end;

procedure CheckRaisesImpl(ExceptionClass: ExceptClass; Method: TTestProc; Plain: TTestProcPlain;
  const What: string);
var
  Raised: TClass;
begin
  Raised := nil;
  LastExceptionMessage := '';
  try
    if Assigned(Method) then
      Method
    else
      Plain;
  except
    on E: Exception do
    begin
      Raised := E.ClassType;
      LastExceptionMessage := E.Message;
    end;
  end;

  if Raised = nil then
    Check(False, What + ' (nothing raised)')
  else if not Raised.InheritsFrom(ExceptionClass) then
    Check(False, Format('%s (raised %s, expected %s)', [What, Raised.ClassName, ExceptionClass.ClassName]))
  else
    Check(True, What);
end;

procedure CheckRaises(ExceptionClass: ExceptClass; Proc: TTestProc; const What: string);
begin
  CheckRaisesImpl(ExceptionClass, Proc, nil, What);
end;

procedure CheckRaises(ExceptionClass: ExceptClass; Proc: TTestProcPlain; const What: string);
begin
  CheckRaisesImpl(ExceptionClass, nil, Proc, What);
end;

procedure Skip(const What, Reason: string);
begin
  Inc(Skipped);
  WriteLn('  skip  ', What, ' (', Reason, ')');
end;

function TestSummary: Integer;
begin
  WriteLn;
  WriteLn(Format('%d passed, %d failed, %d skipped', [Passed, Failed, Skipped]));
  if Failed = 0 then
    Result := 0
  else
    Result := 1;
end;

end.
