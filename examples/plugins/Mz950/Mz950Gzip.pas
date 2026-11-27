// Mz950 - Created by Simon Moscrop
// Free software under the GNU AGPL v3; see LICENSE.
//
// gzip (RFC 1952), for the disk image the plug-in keeps in a host's project - what the C++
// does with juce::GZIPCompressorOutputStream and GZIPDecompressorInputStream.
//
// COMPRESSING is zlib's deflate, raw (windowBits -15): Free Pascal's paszlib (zdeflate),
// Delphi's System.ZLib. The gzip wrapper round it - the header, the CRC-32, the length - is
// written here, the same code for both compilers, and what comes out is decoded again before
// it is returned: if it does not give back the input exactly, the data is written as stored
// (uncompressed) deflate blocks instead, which cannot go wrong.
//
// DECOMPRESSING is done here, not by zlib: a small inflater after Mark Adler's puff.c
// (RFC 1951, bit for bit, every code checked as it is built). Two reasons. The data is a
// project file, so nothing in it is trusted - a single gzip member and nothing after it,
// every header field inside the data, Huffman tables that are complete and not
// over-subscribed, no distance reaching before the start, the output never past MaxSize
// whatever the data claims (a gzip bomb stops there), and the CRC-32 and the length in the
// trailer both matching what came out. And paszlib's inflate (FPC 3.2.2) mis-decodes some
// streams its own deflate writes at levels 8 and 9 - 32K too much output - which the system
// gzip decodes correctly. Anything wrong is False; nothing raises out of here.

unit Mz950Gzip;

{$IFDEF FPC}
  {$MODE DELPHI}
{$ENDIF}

interface

uses
  SysUtils;

const
  // An 800K or 1600K S950 image is at most 1,638,400 bytes.
  GzipDefaultMaxOutput = 2 * 1024 * 1024;

// Data as one gzip member, at zlib's Level (0..9). False only if it could not be made.
function GzipCompress(const Data: TBytes; out Gz: TBytes; Level: Integer = 9): Boolean;

// Count bytes from Start of Src, one gzip member exactly, into Data - at most MaxSize bytes.
// False (Data nil) if they are anything else.
function GzipDecompress(const Src: TBytes; Start, Count, MaxSize: Integer; out Data: TBytes): Boolean; overload;
function GzipDecompress(const Src: TBytes; MaxSize: Integer; out Data: TBytes): Boolean; overload;

// The raw deflate stream from Src[At], to at most Stop, into at most MaxSize bytes; Used is
// how many bytes of Src it took. False if it is not a whole, valid stream.
function InflateRaw(const Src: TBytes; At, Stop, MaxSize: Integer; out Data: TBytes; out Used: Integer): Boolean;

// The CRC-32 gzip uses (the zlib one), continued from Crc (0 to start).
function GzipCrc32(Crc: Cardinal; P: PByte; Len: Integer): Cardinal;

implementation

uses
{$IFDEF FPC}
  zbase, zdeflate;
{$ELSE}
  System.ZLib;
{$ENDIF}

const
  FlagHcrc     = $02;
  FlagExtra    = $04;
  FlagName     = $08;
  FlagComment  = $10;
  FlagReserved = $E0;
  HeaderSize   = 10;

var
  CrcTable: array[0..255] of Cardinal;

procedure MakeCrcTable;
var
  N, K: Integer;
  C: Cardinal;
begin
  for N := 0 to 255 do
  begin
    C := Cardinal(N);
    for K := 0 to 7 do
      if (C and 1) <> 0 then
        C := $EDB88320 xor (C shr 1)
      else
        C := C shr 1;
    CrcTable[N] := C;
  end;
end;

function GzipCrc32(Crc: Cardinal; P: PByte; Len: Integer): Cardinal;
var
  I: Integer;
begin
  Result := Crc xor $FFFFFFFF;
  for I := 0 to Len - 1 do
  begin
    Result := CrcTable[(Result xor P^) and $FF] xor (Result shr 8);
    Inc(P);
  end;
  Result := Result xor $FFFFFFFF;
end;

procedure PutLE32(var B: TBytes; At: Integer; V: Cardinal);
begin
  B[At] := V and $FF;
  B[At + 1] := (V shr 8) and $FF;
  B[At + 2] := (V shr 16) and $FF;
  B[At + 3] := (V shr 24) and $FF;
end;

function GetLE32(const B: TBytes; At: Integer): Cardinal;
begin
  Result := Cardinal(B[At]) or (Cardinal(B[At + 1]) shl 8) or (Cardinal(B[At + 2]) shl 16)
    or (Cardinal(B[At + 3]) shl 24);
end;

// ------------------------------------------------------------------- the inflater

const
  MaxBits  = 15;
  MaxLCodes = 286;
  MaxDCodes = 30;
  MaxCodes = MaxLCodes + MaxDCodes;
  FixLCodes = 288;

  LBase: array[0..28] of Integer = (3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258);
  LExt: array[0..28] of Integer = (0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0);
  DBase: array[0..29] of Integer = (1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577);
  DExt: array[0..29] of Integer = (0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13);
  CodeOrder: array[0..18] of Integer = (16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15);

type
  EInflate = class(Exception);

  THuffman = record
    Count: array[0..MaxBits] of Integer;      // codes of each length
    Symbol: array[0..FixLCodes - 1] of Integer;
  end;

  TInflater = record
    Src: TBytes;
    InPos, InStop: Integer;
    BitBuf: Cardinal;
    BitCnt: Integer;
    Out_: TBytes;
    OutCnt, MaxOut: Integer;
    function Bits(Need: Integer): Integer;
    procedure Put(B: Byte);
    procedure Stored;
    function Decode(const H: THuffman): Integer;
    procedure Codes(const LenCode, DistCode: THuffman);
    procedure Fixed;
    procedure Dynamic;
  end;

procedure Fail;
begin
  raise EInflate.Create('bad deflate data');
end;

// Builds a canonical code from the lengths; < 0 over-subscribed, > 0 incomplete, 0 complete.
function Construct(var H: THuffman; const Length_: array of Integer; First, N: Integer): Integer;
var
  Sym, Len, Left: Integer;
  Offs: array[0..MaxBits] of Integer;
begin
  for Len := 0 to MaxBits do
    H.Count[Len] := 0;
  for Sym := 0 to N - 1 do
    Inc(H.Count[Length_[First + Sym]]);
  if H.Count[0] = N then
  begin
    Result := 0;                                 // no codes: complete, but decoding fails
    Exit;
  end;
  Left := 1;
  for Len := 1 to MaxBits do
  begin
    Left := Left shl 1;
    Dec(Left, H.Count[Len]);
    if Left < 0 then
    begin
      Result := Left;
      Exit;
    end;
  end;
  Offs[1] := 0;
  for Len := 1 to MaxBits - 1 do
    Offs[Len + 1] := Offs[Len] + H.Count[Len];
  for Sym := 0 to N - 1 do
    if Length_[First + Sym] <> 0 then
    begin
      H.Symbol[Offs[Length_[First + Sym]]] := Sym;
      Inc(Offs[Length_[First + Sym]]);
    end;
  Result := Left;
end;

function TInflater.Bits(Need: Integer): Integer;
var
  Val: Cardinal;
begin
  Val := BitBuf;
  while BitCnt < Need do
  begin
    if InPos >= InStop then
      Fail;                                      // ran out of input
    Val := Val or (Cardinal(Src[InPos]) shl BitCnt);
    Inc(InPos);
    Inc(BitCnt, 8);
  end;
  BitBuf := Val shr Need;
  Dec(BitCnt, Need);
  Result := Integer(Val and ((Cardinal(1) shl Need) - 1));
end;

procedure TInflater.Put(B: Byte);
var
  Room: Integer;
begin
  if OutCnt >= MaxOut then
    Fail;                                        // more than anyone saved: a bomb
  if OutCnt >= Length(Out_) then
  begin
    Room := Length(Out_) * 2;
    if Room < 65536 then Room := 65536;
    if Room > MaxOut then Room := MaxOut;
    SetLength(Out_, Room);
  end;
  Out_[OutCnt] := B;
  Inc(OutCnt);
end;

procedure TInflater.Stored;
var
  Len, NLen: Integer;
begin
  BitBuf := 0;                                   // to a byte boundary
  BitCnt := 0;
  if InPos + 4 > InStop then
    Fail;
  Len := Src[InPos] or (Src[InPos + 1] shl 8);
  NLen := Src[InPos + 2] or (Src[InPos + 3] shl 8);
  Inc(InPos, 4);
  if Len <> (not NLen and $FFFF) then
    Fail;
  if InPos + Len > InStop then
    Fail;
  while Len > 0 do
  begin
    Put(Src[InPos]);
    Inc(InPos);
    Dec(Len);
  end;
end;

function TInflater.Decode(const H: THuffman): Integer;
var
  Code, First, Count, Index, Len: Integer;
begin
  Code := 0;
  First := 0;
  Index := 0;
  for Len := 1 to MaxBits do
  begin
    Code := Code or Bits(1);
    Count := H.Count[Len];
    if Code - Count < First then
    begin
      Result := H.Symbol[Index + (Code - First)];
      Exit;
    end;
    Inc(Index, Count);
    Inc(First, Count);
    First := First shl 1;
    Code := Code shl 1;
  end;
  Fail;                                          // ran out of codes
  Result := -1;
end;

procedure TInflater.Codes(const LenCode, DistCode: THuffman);
var
  Symbol, Len, Dist: Integer;
begin
  repeat
    Symbol := Decode(LenCode);
    if Symbol < 256 then
      Put(Symbol)
    else if Symbol > 256 then
    begin
      Dec(Symbol, 257);
      if Symbol >= 29 then
        Fail;
      Len := LBase[Symbol] + Bits(LExt[Symbol]);
      Symbol := Decode(DistCode);
      if (Symbol < 0) or (Symbol >= 30) then
        Fail;
      Dist := DBase[Symbol] + Bits(DExt[Symbol]);
      if Dist > OutCnt then
        Fail;                                    // before the start
      while Len > 0 do
      begin
        Put(Out_[OutCnt - Dist]);
        Dec(Len);
      end;
    end;
  until Symbol = 256;
end;

procedure TInflater.Fixed;
var
  LenCode, DistCode: THuffman;
  Lengths: array[0..FixLCodes - 1] of Integer;
  Sym: Integer;
begin
  for Sym := 0 to 143 do Lengths[Sym] := 8;
  for Sym := 144 to 255 do Lengths[Sym] := 9;
  for Sym := 256 to 279 do Lengths[Sym] := 7;
  for Sym := 280 to FixLCodes - 1 do Lengths[Sym] := 8;
  Construct(LenCode, Lengths, 0, FixLCodes);
  for Sym := 0 to MaxDCodes - 1 do Lengths[Sym] := 5;
  Construct(DistCode, Lengths, 0, MaxDCodes);
  Codes(LenCode, DistCode);
end;

procedure TInflater.Dynamic;
var
  NLen, NDist, NCode, Index, Err, Symbol, Len, Count: Integer;
  Lengths: array[0..MaxCodes - 1] of Integer;
  LenCode, DistCode: THuffman;
begin
  NLen := Bits(5) + 257;
  NDist := Bits(5) + 1;
  NCode := Bits(4) + 4;
  if (NLen > MaxLCodes) or (NDist > MaxDCodes) then
    Fail;
  for Index := 0 to 18 do
    Lengths[CodeOrder[Index]] := 0;
  for Index := 0 to NCode - 1 do
    Lengths[CodeOrder[Index]] := Bits(3);
  Err := Construct(LenCode, Lengths, 0, 19);
  if Err <> 0 then
    Fail;                                        // the code-length code must be complete

  Index := 0;
  while Index < NLen + NDist do
  begin
    Symbol := Decode(LenCode);
    if Symbol < 16 then
    begin
      Lengths[Index] := Symbol;
      Inc(Index);
    end
    else
    begin
      Len := 0;
      if Symbol = 16 then
      begin
        if Index = 0 then
          Fail;                                  // nothing to repeat
        Len := Lengths[Index - 1];
        Count := 3 + Bits(2);
      end
      else if Symbol = 17 then
        Count := 3 + Bits(3)
      else
        Count := 11 + Bits(7);
      if Index + Count > NLen + NDist then
        Fail;
      while Count > 0 do
      begin
        Lengths[Index] := Len;
        Inc(Index);
        Dec(Count);
      end;
    end;
  end;
  if Lengths[256] = 0 then
    Fail;                                        // no end-of-block code

  Err := Construct(LenCode, Lengths, 0, NLen);
  if (Err < 0) or ((Err > 0) and (NLen - LenCode.Count[0] <> 1)) then
    Fail;                                        // incomplete only for a single code
  Err := Construct(DistCode, Lengths, NLen, NDist);
  if (Err < 0) or ((Err > 0) and (NDist - DistCode.Count[0] <> 1)) then
    Fail;
  Codes(LenCode, DistCode);
end;

function InflateRaw(const Src: TBytes; At, Stop, MaxSize: Integer; out Data: TBytes; out Used: Integer): Boolean;
var
  S: TInflater;
  Last, Kind: Integer;
begin
  Data := nil;
  Used := 0;
  Result := False;
  if (At < 0) or (Stop > Length(Src)) or (At >= Stop) or (MaxSize < 0) then
    Exit;
  try
    S.Src := Src;
    S.InPos := At;
    S.InStop := Stop;
    S.BitBuf := 0;
    S.BitCnt := 0;
    S.Out_ := nil;
    S.OutCnt := 0;
    S.MaxOut := MaxSize;
    repeat
      Last := S.Bits(1);
      Kind := S.Bits(2);
      case Kind of
        0: S.Stored;
        1: S.Fixed;
        2: S.Dynamic;
      else
        Fail;
      end;
    until Last = 1;
    SetLength(S.Out_, S.OutCnt);
    Data := S.Out_;
    Used := S.InPos - At;
    Result := True;
  except
    Data := nil;
    Used := 0;
    Result := False;
  end;
end;

// ------------------------------------------------------------------------ gzip

// Stored blocks: the deflate stream that cannot go wrong.
function StoredStream(const Data: TBytes): TBytes;
var
  P, Q, N: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Data) + 5 * (Length(Data) div 65535 + 1));
  P := 0;
  Q := 0;
  repeat
    N := Length(Data) - P;
    if N > 65535 then N := 65535;
    if P + N = Length(Data) then Result[Q] := 1 else Result[Q] := 0;
    Result[Q + 1] := N and $FF;
    Result[Q + 2] := N shr 8;
    Result[Q + 3] := (not N) and $FF;
    Result[Q + 4] := ((not N) shr 8) and $FF;
    Inc(Q, 5);
    if N > 0 then
      Move(Data[P], Result[Q], N);
    Inc(P, N);
    Inc(Q, N);
  until P >= Length(Data);
  SetLength(Result, Q);
end;

// zlib's deflate, raw. False if zlib fails.
function ZDeflateRaw(const Data: TBytes; Level: Integer; out Stream: TBytes): Boolean;
var
  Z: z_stream;
  Bound: Integer;
  Dummy: Byte;
begin
  Stream := nil;
  Result := False;
  Bound := Length(Data) + Length(Data) div 1000 + 1024;
  SetLength(Stream, Bound);
  FillChar(Z, SizeOf(Z), 0);
  if deflateInit2(Z, Level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY) <> Z_OK then
    Exit;
  try
    Dummy := 0;
    if Length(Data) > 0 then
      Z.next_in := @Data[0]
    else
      Z.next_in := @Dummy;                   // paszlib refuses a nil next_in
    Z.avail_in := Length(Data);
    Z.next_out := @Stream[0];
    Z.avail_out := Bound;
    if deflate(Z, Z_FINISH) <> Z_STREAM_END then
      Exit;
    SetLength(Stream, Bound - Integer(Z.avail_out));
    Result := True;
  finally
    deflateEnd(Z);
    if not Result then
      Stream := nil;
  end;
end;

function GzipCompress(const Data: TBytes; out Gz: TBytes; Level: Integer): Boolean;
var
  Stream, Back: TBytes;
  Used: Integer;
  Good: Boolean;
begin
  Gz := nil;
  Result := False;
  if (Level < 0) or (Level > 9) then
    Level := 9;
  try
    Good := False;
    try
      Good := ZDeflateRaw(Data, Level, Stream);
    except
      Good := False;
    end;
    // what zlib wrote must decode to the input exactly, or it is not kept
    if Good then
      Good := InflateRaw(Stream, 0, Length(Stream), Length(Data), Back, Used)
        and (Used = Length(Stream)) and (Length(Back) = Length(Data))
        and ((Length(Data) = 0) or CompareMem(@Back[0], @Data[0], Length(Data)));
    if not Good then
      Stream := StoredStream(Data);

    SetLength(Gz, HeaderSize + Length(Stream) + 8);
    // ID1 ID2 CM FLG MTIME(4) XFL OS: no name, no time, "unknown" OS
    Gz[0] := $1F;
    Gz[1] := $8B;
    Gz[2] := 8;
    Gz[3] := 0;
    PutLE32(Gz, 4, 0);
    Gz[8] := 0;
    Gz[9] := 255;
    if Length(Stream) > 0 then
      Move(Stream[0], Gz[HeaderSize], Length(Stream));
    PutLE32(Gz, HeaderSize + Length(Stream), GzipCrc32(0, PByte(Pointer(Data)), Length(Data)));
    PutLE32(Gz, HeaderSize + Length(Stream) + 4, Cardinal(Length(Data)));
    Result := True;
  except
    Gz := nil;
    Result := False;
  end;
end;

function GzipDecompress(const Src: TBytes; Start, Count, MaxSize: Integer; out Data: TBytes): Boolean;
var
  P, Stop, Len, Used: Integer;
  Flags: Byte;
  HeaderCrc: Cardinal;
  Out_: TBytes;
begin
  Data := nil;
  Result := False;
  try
    if (Start < 0) or (Count < 0) or (Start > Length(Src)) or (Count > Length(Src) - Start) then
      Exit;
    Stop := Start + Count;
    // header (10) + the smallest deflate stream (2) + trailer (8)
    if Count < 20 then
      Exit;
    if (Src[Start] <> $1F) or (Src[Start + 1] <> $8B) or (Src[Start + 2] <> 8) then
      Exit;
    Flags := Src[Start + 3];
    if (Flags and FlagReserved) <> 0 then
      Exit;
    P := Start + HeaderSize;
    if (Flags and FlagExtra) <> 0 then
    begin
      if P + 2 > Stop then Exit;
      Len := Src[P] or (Src[P + 1] shl 8);
      Inc(P, 2);
      if Len > Stop - P then Exit;
      Inc(P, Len);
    end;
    if (Flags and FlagName) <> 0 then
    begin
      while (P < Stop) and (Src[P] <> 0) do Inc(P);
      if P >= Stop then Exit;
      Inc(P);
    end;
    if (Flags and FlagComment) <> 0 then
    begin
      while (P < Stop) and (Src[P] <> 0) do Inc(P);
      if P >= Stop then Exit;
      Inc(P);
    end;
    if (Flags and FlagHcrc) <> 0 then
    begin
      if P + 2 > Stop then Exit;
      HeaderCrc := GzipCrc32(0, @Src[Start], P - Start) and $FFFF;
      if HeaderCrc <> Cardinal(Src[P] or (Src[P + 1] shl 8)) then Exit;
      Inc(P, 2);
    end;
    // the trailer is the last eight bytes; the deflate stream must end exactly before it
    if Stop - P < 8 + 2 then
      Exit;
    if not InflateRaw(Src, P, Stop - 8, MaxSize, Out_, Used) then
      Exit;
    if Used <> (Stop - 8) - P then
      Exit;                                     // something between the stream and the trailer
    if GetLE32(Src, Stop - 8) <> GzipCrc32(0, PByte(Pointer(Out_)), Length(Out_)) then
      Exit;
    if GetLE32(Src, Stop - 4) <> Cardinal(Length(Out_)) then
      Exit;
    Data := Out_;
    Result := True;
  except
    Data := nil;
    Result := False;
  end;
end;

function GzipDecompress(const Src: TBytes; MaxSize: Integer; out Data: TBytes): Boolean;
begin
  Result := GzipDecompress(Src, 0, Length(Src), MaxSize, Data);
end;

initialization
  MakeCrcTable;
end.
