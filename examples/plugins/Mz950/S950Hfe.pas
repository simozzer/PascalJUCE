// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// Object Pascal port of Plugin/Source/S950/Hfe.h and Hfe.cpp.
//
// Every index into the raw file is guarded exactly where the C++ guards it, and the C++
// guards all of them: a garbage track table reads as no track, a track that runs off the
// end of the file is cut short, and a sector's last field wraps round to the start of
// its track. The one cost a hostile header can impose is size: the image is
// tracks x sides x 10 sectors, so a header claiming 255 x 255 makes a 650 MB image (and the
// C++ makes the same), which loadBytes then refuses as not 800K or 1600K.

unit S950Hfe;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ELSE}
  {$EXCESSPRECISION OFF}
{$ENDIF}

interface

uses
  SysUtils;

//
// Decoder for HxC/Gotek .hfe images (HXCPICFE rev 0).
//
// An .img is the 800K of sectors a disk holds. An .hfe is a recording of the magnetic
// flux a floppy controller would see reading it - the raw MFM cells, both sides
// interleaved in 256-byte chunks - so getting sectors out of one means doing what the
// controller does: find the sync marks, pull the bits apart from the clock they are
// woven into, and check the CRCs.
//
// That is worth the trouble because it is the format real disks get archived in. The
// library this was written against is entirely .hfe.
//
// A straight port of AkaiS950List/Hfe.cs, which is the one part of this project that
// was worked out against a specification rather than measured off the machine.
//

// True if these bytes start with the HXCPICFE signature.
function HfeLooksLikeHfe(const Raw: TBytes): Boolean;

//
// Decode every track and lay the sectors out linearly, exactly as a plain image
// holds them: LBA = (cyl * sides + head) * 5 + (sec - 1), 1024 bytes each.
//
// `badCrc` counts sectors that were readable but failed their check, and `missing`
// counts sectors no good copy was found for. Both are worth showing rather than
// hiding: an archived floppy is thirty years old, and a disk that reads with three
// bad sectors is a different thing from one that reads cleanly.
//
function HfeExtract(const Raw: TBytes; out BadCrc, Missing: Integer): TBytes;

implementation

type
  TSector = record
    Cyl, Head, Sec, SizeCode: Integer;
    Data: TBytes;
    IdCrcOk, DataCrcOk: Boolean;
  end;

  TSectorArray = array of TSector;
  TSectorTracks = array of TSectorArray;
  TBoolArray = array of Boolean;

function U16(const B: TBytes; At: Int64): Integer;
begin
  if At + 1 >= Length(B) then
  begin
    Result := 0;
    Exit;
  end;
  Result := B[At] or (B[At + 1] shl 8);
end;

// One side's cell bytes, pulled out of the interleaved track blocks.
function SideCells(const Img: TBytes; Track, Side: Integer): TBytes;
var
  Lut, TOff, Pos, Src: Int64;
  TLen, Half, W, Chunk: Integer;
begin
  Result := nil;

  Lut := Int64(U16(Img, 18)) * 512;
  if Lut + Int64(Track) * 4 + 3 >= Length(Img) then
    Exit;

  TOff := Int64(U16(Img, Lut + Int64(Track) * 4)) * 512;
  TLen := U16(Img, Lut + Int64(Track) * 4 + 2);
  Half := TLen div 2;

  if Half <= 0 then
    Exit;

  SetLength(Result, Half);
  FillChar(Result[0], Half, 0);

  W := 0;
  Pos := TOff;

  while W < Half do
  begin
    Chunk := 256;
    if Half - W < Chunk then
      Chunk := Half - W;
    if Side = 0 then
      Src := Pos
    else
      Src := Pos + 256;

    if Src + Chunk > Length(Img) then
      Break;

    Move(Img[Src], Result[W], Chunk);
    Inc(W, Chunk);
    Inc(Pos, 512);
  end;
end;

// One byte per MFM cell; HFE stores the first cell in bit 0.
function Unpack(const Cells: TBytes): TBytes;
var
  I, B: Integer;
  C: Byte;
begin
  Result := nil;
  SetLength(Result, Length(Cells) * 8);

  for I := 0 to High(Cells) do
  begin
    C := Cells[I];
    for B := 0 to 7 do
      Result[I * 8 + B] := (C shr B) and 1;
  end;
end;

//
// In MFM the cells alternate clock, data, so the data bits sit at odd offsets.
//
// The modulo is not caution: a sector's last field can run off the end of the track
// and wrap round to its start, which is what the physical disk does too.
//
function ReadByte(const Bits: TBytes; GroupStart: Int64): Integer;
var
  N: Int64;
  I: Integer;
begin
  Result := 0;
  N := Length(Bits);
  if N = 0 then
    Exit;

  for I := 0 to 7 do
    Result := (Result shl 1) or Bits[(GroupStart + 2 * I + 1) mod N];
end;

// CRC-16/CCITT, as the floppy format uses it - one byte of it.
function Crc16Byte(Crc: Integer; D: Byte): Integer;
var
  B: Integer;
begin
  Crc := (Crc xor (D shl 8)) and $FFFF;

  for B := 0 to 7 do
    if (Crc and $8000) <> 0 then
      Crc := ((Crc shl 1) xor $1021) and $FFFF
    else
      Crc := (Crc shl 1) and $FFFF;

  Result := Crc;
end;

// CRC-16/CCITT, as the floppy format uses it.
function Crc16(const D: TBytes; Len: Integer; Crc: Integer): Integer;
var
  I: Integer;
begin
  for I := 0 to Len - 1 do
    Crc := Crc16Byte(Crc, D[I]);
  Result := Crc;
end;

function DecodeTrack(const Cells: TBytes): TSectorArray;
var
  Bits, Data: TBytes;
  N, P, G, LastSync: Int64;
  Sr, Run, Count, Mark, Cs, C, I: Integer;
  Id: array[0..3] of Byte;
  Sz: Integer;
  HavePending: Boolean;
  Pending: TSector;
  Found: TSectorArray;

  procedure Push(const S: TSector);
  begin
    if Count = Length(Found) then
      SetLength(Found, Count * 2 + 16);
    Found[Count] := S;
    Inc(Count);
  end;

  procedure ResetPending;
  begin
    Pending.Cyl := 0;
    Pending.Head := 0;
    Pending.Sec := 0;
    Pending.SizeCode := 0;
    Pending.Data := nil;
    Pending.IdCrcOk := False;
    Pending.DataCrcOk := False;
  end;

begin
  Result := nil;
  Found := nil;
  Count := 0;
  if Length(Cells) = 0 then
    Exit;

  Bits := Unpack(Cells);
  N := Length(Bits);

  // The C++ keeps a 32-bit shift register and looks only at its low 16 bits; this keeps
  // just those 16, which every comparison sees the same.
  Sr := 0;
  LastSync := -100;
  Run := 0;

  HavePending := False;
  ResetPending;

  P := 0;
  while P < N do
  begin
    Sr := ((Sr shl 1) or Bits[P]) and $FFFF;

    // A1 written with a missing clock bit - the mark that says a field follows.
    if Sr <> $4489 then
    begin
      Inc(P);
      Continue;
    end;

    if P - LastSync = 16 then
      Inc(Run)
    else
      Run := 1;
    LastSync := P;
    if Run < 3 then
    begin
      Inc(P);
      Continue;
    end;

    G := P + 1;
    Mark := ReadByte(Bits, G);
    Inc(G, 16);

    if Mark = $FE then                                    // ID address mark
    begin
      for I := 0 to 3 do
      begin
        Id[I] := ReadByte(Bits, G);
        Inc(G, 16);
      end;

      Cs := ReadByte(Bits, G) shl 8;
      Inc(G, 16);
      Cs := Cs or ReadByte(Bits, G);
      Inc(G, 16);

      C := Crc16Byte(Crc16Byte(Crc16Byte($FFFF, $A1), $A1), $A1);
      C := Crc16Byte(C, Mark);
      for I := 0 to 3 do
        C := Crc16Byte(C, Id[I]);

      ResetPending;
      Pending.Cyl := Id[0];
      Pending.Head := Id[1];
      Pending.Sec := Id[2];
      Pending.SizeCode := Id[3];
      Pending.IdCrcOk := C = Cs;
      HavePending := True;
    end
    else if ((Mark = $FB) or (Mark = $F8)) and HavePending then   // data mark
    begin
      Sz := 128 shl (Pending.SizeCode and 7);

      SetLength(Data, Sz);
      for I := 0 to Sz - 1 do
      begin
        Data[I] := ReadByte(Bits, G);
        Inc(G, 16);
      end;

      Cs := ReadByte(Bits, G) shl 8;
      Inc(G, 16);
      Cs := Cs or ReadByte(Bits, G);
      Inc(G, 16);

      C := Crc16Byte(Crc16Byte(Crc16Byte($FFFF, $A1), $A1), $A1);
      C := Crc16Byte(C, Mark);
      C := Crc16(Data, Sz, C);

      Pending.Data := Data;
      Data := nil;
      Pending.DataCrcOk := C = Cs;

      Push(Pending);
      ResetPending;
      HavePending := False;
    end;

    Inc(P);
  end;

  SetLength(Found, Count);
  Result := Found;
end;

function HfeLooksLikeHfe(const Raw: TBytes): Boolean;
const
  Sig: array[0..7] of Byte = (Ord('H'), Ord('X'), Ord('C'), Ord('P'), Ord('I'), Ord('C'),
                              Ord('F'), Ord('E'));
var
  I: Integer;
begin
  Result := False;
  if Length(Raw) <= 8 then
    Exit;
  for I := 0 to 7 do
    if Raw[I] <> Sig[I] then
      Exit;
  Result := True;
end;

function HfeExtract(const Raw: TBytes; out BadCrc, Missing: Integer): TBytes;
const
  Ssz = 1024;
var
  Tracks, Sides, Highest, Spt, T, S, I, Take: Integer;
  Decoded: TSectorTracks;
  Sectors, Lba: Int64;
  Got: TBoolArray;
begin
  Result := nil;
  BadCrc := 0;
  Missing := 0;

  if Length(Raw) < 12 then
    Exit;

  Tracks := Raw[9];
  Sides := Raw[10];

  if (Tracks <= 0) or (Sides <= 0) then
    Exit;

  //
  // Five sectors a track on a double-density disk (800K) and ten on a high-density one
  // (1600K) - the S950 formats both. The disk says which: decode every track first and
  // see how high the sector numbers go, rather than trusting the header's bit rate.
  //
  SetLength(Decoded, Tracks * Sides);
  Highest := 0;

  for T := 0 to Tracks - 1 do
    for S := 0 to Sides - 1 do
    begin
      Decoded[T * Sides + S] := DecodeTrack(SideCells(Raw, T, S));
      for I := 0 to High(Decoded[T * Sides + S]) do
        with Decoded[T * Sides + S][I] do
          if (Length(Data) <> 0) and (Sec >= 1) and (Sec <= 10) then
            if Sec > Highest then
              Highest := Sec;
    end;

  if Highest > 5 then
    Spt := 10
  else
    Spt := 5;
  Sectors := Int64(Tracks) * Sides * Spt;

  SetLength(Result, Sectors * Ssz);
  FillChar(Result[0], Sectors * Ssz, 0);
  SetLength(Got, Sectors);
  FillChar(Got[0], Sectors, 0);

  for T := 0 to Tracks - 1 do
  begin
    for S := 0 to Sides - 1 do
    begin
      for I := 0 to High(Decoded[T * Sides + S]) do
      begin
        with Decoded[T * Sides + S][I] do
        begin
          if Length(Data) = 0 then
            Continue;
          if (Sec < 1) or (Sec > Spt) then
            Continue;
          if (Cyl >= Tracks) or (Head >= Sides) then
            Continue;

          Lba := (Int64(Cyl) * Sides + Head) * Spt + (Sec - 1);

          if (Lba < 0) or (Lba >= Sectors) then
            Continue;
          if Got[Lba] then
            Continue;                                     // keep the first good copy

          if (not DataCrcOk) or (not IdCrcOk) then
            Inc(BadCrc);

          Take := Ssz;
          if Length(Data) < Take then
            Take := Length(Data);
          Move(Data[0], Result[Lba * Ssz], Take);

          Got[Lba] := True;
        end;
      end;
    end;
  end;

  for I := 0 to High(Got) do
    if not Got[I] then
      Inc(Missing);
end;

end.
