{
  JuceTypes.pas - types shared by the PascalJUCE units (no DLL imports here,
  so plugin libraries can use it without depending on juce_c_audio).
}
unit JuceTypes;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

type
  { A channel is a pointer to Single samples; a device or plugin passes an
    array of channel pointers. Index as Channels^[Channel]^[Sample]. }
  { Bounds match the C API's per-channel limit (2^29 - 1 samples); larger
    would exceed Delphi's 2 GB limit on a static type. }
  TJuceSampleArray  = array[0..$1FFFFFFE] of Single;
  PJuceSampleArray  = ^TJuceSampleArray;
  TJuceChannelArray = array[0..1023] of PJuceSampleArray;
  PJuceChannelArray = ^TJuceChannelArray;

  TJuceSingleArray = array[0..$FFFFFF] of Single;
  PJuceSingleArray = ^TJuceSingleArray;

implementation

end.
