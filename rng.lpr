program rng;
{$IF defined(CPUX86) or defined(CPUX86_64)}
{$ASMMODE INTEL}
{$ENDIF}
{$mode objfpc}{$H+}{$modeswitch advancedrecords}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, CustApp, DateUtils
  {$IFDEF WINDOWS}
  , Windows
  {$ENDIF};

type
  TRandomMethod = (
    rmAuto,
    rmRDRAND,
    rmRNDR,
    rmHWRNG,
    rmDevRandom,
    rmURandom,
    rmWindowsCrypto,
    rmPascal,
    rmZeros
  );

  { TRng }
  TRng = class(TCustomApplication)
  protected
    procedure DoRun; override;
  public
    constructor Create(TheOwner: TComponent); override;
    destructor Destroy; override;
    procedure WriteHelp; virtual;
    procedure getrng;
  end;


const

//AUTO-V
  version = 'v0.1-2026/03/06r11';

{$IFDEF WINDOWS}
const
  BCRYPT_USE_SYSTEM_PREFERRED_RNG = $00000002;

function BCryptGenRandom(hAlgorithm: Pointer; pbBuffer: PByte; cbBuffer: Cardinal;
  dwFlags: Cardinal): LongInt; stdcall; external 'bcrypt.dll';
{$ENDIF}

function MethodToString(const Method: TRandomMethod): string;
begin
  case Method of
    rmAuto: Result := 'auto';
    rmRDRAND: Result := 'rdrand';
    rmRNDR: Result := 'rndr';
    rmHWRNG: Result := 'hwrng';
    rmDevRandom: Result := 'random';
    rmURandom: Result := 'urandom';
    rmWindowsCrypto: Result := 'wincrypto';
    rmPascal: Result := 'pascal';
    rmZeros: Result := 'zeros';
  else
    Result := 'unknown';
  end;
end;

function ParseRandomMethod(const S: string; out Method: TRandomMethod): Boolean;
var
  m: string;
begin
  m := LowerCase(Trim(S));
  if m = 'auto' then Method := rmAuto
  else if m = 'rdrand' then Method := rmRDRAND
  else if m = 'rndr' then Method := rmRNDR
  else if m = 'hwrng' then Method := rmHWRNG
  else if m = 'random' then Method := rmDevRandom
  else if m = 'urandom' then Method := rmURandom
  else if m = 'wincrypto' then Method := rmWindowsCrypto
  else if (m = 'pascal') or (m = 'prng') then Method := rmPascal
  else if m = 'zeros' then Method := rmZeros
  else
  begin
    Result := False;
    Exit;
  end;
  Result := True;
end;

procedure FillPascalRandom64Ptr(p: PQWord; count: NativeUInt);
var
  i: NativeUInt;
begin
  for i := 0 to count - 1 do
  begin
    p^ := (QWord(Random($FFFFFFFF)) shl 32) or QWord(Random($FFFFFFFF));
    Inc(p);
  end;
end;

function HasRDRAND: Boolean;
{$IF defined(CPUX86) or defined(CPUX86_64)}
var
  vecx: LongWord;
begin
  vecx := 0;
  asm
    mov eax, 1
    cpuid
    mov [vecx], ecx
  end;
  // Bit 30 of ECX indicates RDRAND support.
  Result := (vecx and (1 shl 30)) <> 0;
end;
{$ELSE}
begin
  Result := False;
end;
{$ENDIF}

function TryGetRDRAND32(out Value: LongWord): Boolean;
{$IF defined(CPUX86) or defined(CPUX86_64)}
var
  ok: Byte;
begin
  ok := 0;
  Value := 0;
  asm
    mov ecx, 10
  @try_rdrand:
    rdrand eax
    jc @success
    loop @try_rdrand
    jmp @fail
  @success:
    mov Value, eax
    mov ok, 1
    jmp @done
  @fail:
    mov ok, 0
  @done:
  end;
  Result := ok = 1;
end;
{$ELSE}
begin
  Value := 0;
  Result := False;
end;
{$ENDIF}

// Fill `count` 64-bit words at pointer `p` using RDRAND when available.
// If any RDRAND call fails, entries fall back to Pascal Random.
procedure FillRDRAND64Ptr(p: PQWord; count: NativeUInt; out allOk: Boolean);
var
  i: NativeUInt;
  valueOk: Byte;
  value: QWord;
  lo, hi: LongWord;
begin
  allOk := True;
  if count = 0 then Exit;
  for i := 0 to count - 1 do
  begin
    value := 0;
    valueOk := 0;
    {$IFDEF CPUX86_64}
    asm
      mov rcx, 10
    @try_rdrand64:
      rdrand rax
      jc @success64
      loop @try_rdrand64
      jmp @fail64
    @success64:
      mov value, rax
      mov valueOk, 1
      jmp @done64
    @fail64:
      mov valueOk, 0
    @done64:
    end;
    {$ELSE}
    if TryGetRDRAND32(lo) and TryGetRDRAND32(hi) then
    begin
      value := (QWord(hi) shl 32) or QWord(lo);
      valueOk := 1;
    end
    else
      valueOk := 0;
    {$ENDIF}

    if valueOk = 1 then
      p^ := value
    else
    begin
      p^ := (QWord(Random($FFFFFFFF)) shl 32) or QWord(Random($FFFFFFFF));
      allOk := False;
    end;

    Inc(p);
  end;
end;

function ReadStreamExact(Stream: TStream; Buffer: Pointer; Count: NativeUInt): Boolean;
var
  doneCount: NativeUInt;
  n: LongInt;
begin
  doneCount := 0;
  while doneCount < Count do
  begin
    n := Stream.Read((PByte(Buffer) + doneCount)^, Count - doneCount);
    if n <= 0 then
    begin
      Result := False;
      Exit;
    end;
    Inc(doneCount, NativeUInt(n));
  end;
  Result := True;
end;

{$IFDEF WINDOWS}
function FillWindowsCrypto(Buffer: Pointer; Count: NativeUInt): Boolean;
begin
  if Count = 0 then
  begin
    Result := True;
    Exit;
  end;
  Result := BCryptGenRandom(nil, PByte(Buffer), Count, BCRYPT_USE_SYSTEM_PREFERRED_RNG) = 0;
end;
{$ENDIF}

function MethodAvailable(const Method: TRandomMethod): Boolean;
begin
  case Method of
    rmAuto, rmPascal, rmZeros:
      Result := True;
    rmRDRAND:
      Result := HasRDRAND;
    rmRNDR:
      // RNDR instruction path is not implemented yet in this code.
      Result := False;
    rmHWRNG:
      {$IFDEF UNIX}
      Result := FileExists('/dev/hwrng');
      {$ELSE}
      Result := False;
      {$ENDIF}
    rmDevRandom:
      {$IFDEF UNIX}
      Result := FileExists('/dev/random');
      {$ELSE}
      Result := False;
      {$ENDIF}
    rmURandom:
      {$IFDEF UNIX}
      Result := FileExists('/dev/urandom');
      {$ELSE}
      Result := False;
      {$ENDIF}
    rmWindowsCrypto:
      {$IFDEF WINDOWS}
      Result := True;
      {$ELSE}
      Result := False;
      {$ENDIF}
  else
    Result := False;
  end;
end;

function MethodDevicePath(const Method: TRandomMethod): string;
begin
  case Method of
    rmHWRNG: Result := '/dev/hwrng';
    rmDevRandom: Result := '/dev/random';
    rmURandom: Result := '/dev/urandom';
  else
    Result := '';
  end;
end;

function SelectAutoMethod: TRandomMethod;
begin
  // Prefer CPU hardware RNG when natively available.
  if HasRDRAND then
  begin
    Result := rmRDRAND;
    Exit;
  end;

  {$IFDEF WINDOWS}
  Result := rmWindowsCrypto;
  Exit;
  {$ENDIF}

  {$IFDEF UNIX}
  // For throughput, /dev/urandom is usually faster than /dev/hwrng or /dev/random.
  if FileExists('/dev/urandom') then
    Result := rmURandom
  else if FileExists('/dev/hwrng') then
    Result := rmHWRNG
  else if FileExists('/dev/random') then
    Result := rmDevRandom
  else
    Result := rmPascal;
  {$ELSE}
  Result := rmPascal;
  {$ENDIF}
end;


function ParseSize(const s: string): QWord;
var
  numStr: string;
  mult: QWord;
  lastc: Char;
begin
  Result := 0;
  if s = '' then Exit;
  numStr := s;
  mult := 1;
  if Length(s) > 0 then
  begin
    lastc := UpCase(s[Length(s)]);
    if lastc in ['K','M','G','T'] then
    begin
      numStr := Copy(s,1,Length(s)-1);
      case lastc of
        'K': mult := 1024;
        'M': mult := 1024*1024;
        'G': mult := 1024*1024*1024;
        'T': mult := 1024*1024*1024*1024;
      end;
    end;
  end;
  try
    Result := QWord(StrToInt64(numStr)) * mult;
  except
    Result := 0;
  end;
end;

// Format bytes into the requested unit (b, kb, mb, gb, tb). Uses 1024 base.
// Basic version without time units
function FormatBytes(const Bytes: QWord; const Units: string): string;
var
  f: Double;
  u: string;
begin
  u := LowerCase(Units);
  if u = 'b' then
    f := Bytes
  else if u = 'kb' then
    f := Bytes / 1024.0
  else if u = 'mb' then
    f := Bytes / (1024.0 * 1024.0)
  else if u = 'gb' then
    f := Bytes / (1024.0 * 1024.0 * 1024.0)
  else if u = 'tb' then
    f := Bytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)
  else
  begin
    // default to MB
    f := Bytes / (1024.0 * 1024.0);
    u := 'mb';
  end;

  // Format with appropriate precision
  if u = 'b' then
    Result := FormatFloat('#,##0', f)
  else
    Result := FormatFloat('#,##0.00', f);
  Result := Result + ' ' + UpperCase(u);
end;

// Format bytes with time units for rates (e.g., MB/s, GB/h)
function FormatBytesPerTime(const Bytes: QWord; const Units: string; const TimeUnit: string): string;
var
  f: Double;
  u, t: string;
begin
  u := LowerCase(Units);
  if u = 'b' then
    f := Bytes
  else if u = 'kb' then
    f := Bytes / 1024.0
  else if u = 'mb' then
    f := Bytes / (1024.0 * 1024.0)
  else if u = 'gb' then
    f := Bytes / (1024.0 * 1024.0 * 1024.0)
  else if u = 'tb' then
    f := Bytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)
  else
  begin
    // default to MB
    f := Bytes / (1024.0 * 1024.0);
    u := 'mb';
  end;

  // Apply time unit conversion
  t := LowerCase(TimeUnit);
  if t = 'm' then
    f := f * 60.0  // convert to per minute
  else if t = 'h' then
    f := f * 3600.0  // convert to per hour
  else
    t := 's';

  // Format with appropriate precision
  if u = 'b' then
    Result := FormatFloat('#,##0', f)
  else
    Result := FormatFloat('#,##0.00', f);
  
  // Add units with time unit
  Result := Result + ' ' + UpperCase(u);
  Result := Result + '/' + t;
end;


function CreateRandomFile(const FileName: string; const SizeBytes: QWord; const DryRun: Boolean;
  const Verbose: Boolean; const Units: string; const TimeUnits: string; const Quiet: Boolean;
  const BlockSizeOverride: QWord; const RequestedMethod: TRandomMethod;
  out EffectiveMethod: TRandomMethod): QWord;
const
  DefaultBlockSize = 256 shl 20; // 256 MiB - larger blocks reduce syscalls and improve NVMe throughput
var
  Stream: TFileStream;
  SourceStream: TFileStream;
  BlockSize: NativeUInt;
  WordsInBlock: NativeUInt;
  Buf: array of QWord;
  BytesWritten: QWord;
  ToWrite: QWord;
  rdrandOk: Boolean;
  effVerbose: Boolean;
  lastPercent: Integer;
  percent: Integer;
  nextPrintAt: QWord;
  startTime: TDateTime;
  elapsedSec: Double;
  speedBps: Double;
  sourcePath: string;
begin
  Result := 0;
  EffectiveMethod := RequestedMethod;
  SourceStream := nil;

  if EffectiveMethod = rmAuto then
    EffectiveMethod := SelectAutoMethod;

  if not MethodAvailable(EffectiveMethod) then
  begin
    if not Quiet then
      WriteLn('Requested method "', MethodToString(EffectiveMethod), '" unavailable. Falling back to auto.');
    EffectiveMethod := SelectAutoMethod;
  end;

  // Dry-run: just report and return
  if DryRun then
  begin
    if not Quiet then
      WriteLn('Method: ', MethodToString(EffectiveMethod));
    if SizeBytes = 0 then
      WriteLn('Dry-run: would create ', FileName, ' and write until disk is full.')
    else
      WriteLn('Dry-run: would create ', FileName, ' and write ', SizeBytes, ' bytes.');
    Exit;
  end;

  // determine block size: use override if provided, otherwise default. Ensure multiple of 8.
  if (BlockSizeOverride > 0) then
    BlockSize := NativeUInt(((BlockSizeOverride + 7) div 8) * 8)
  else if (SizeBytes <> 0) and (DefaultBlockSize > SizeBytes) then
    BlockSize := NativeUInt(((SizeBytes + 7) div 8) * 8)
  else
    BlockSize := DefaultBlockSize;

  WordsInBlock := BlockSize div SizeOf(QWord);
  SetLength(Buf, WordsInBlock);

  sourcePath := MethodDevicePath(EffectiveMethod);
  if sourcePath <> '' then
    SourceStream := TFileStream.Create(sourcePath, fmOpenRead or fmShareDenyNone);

  Stream := TFileStream.Create(FileName, fmCreate);
  try
    BytesWritten := 0;
    lastPercent := -1;
    nextPrintAt := 64 * 1024 * 1024; // print every 64 MiB for unknown size
    startTime := Now;

    // Loop until we've written SizeBytes (if >0) or until an IO error occurs when SizeBytes=0
    while (SizeBytes = 0) or (BytesWritten < SizeBytes) do
    begin
      if SizeBytes = 0 then
        ToWrite := BlockSize
      else
      begin
        ToWrite := SizeBytes - BytesWritten;
        if ToWrite >= BlockSize then ToWrite := BlockSize;
      end;

      if WordsInBlock > 0 then
      begin
        case EffectiveMethod of
          rmZeros:
          begin
            // For zero-filled mode, reuse the same zeroed block.
            if BytesWritten = 0 then
              FillChar(Buf[0], WordsInBlock * SizeOf(QWord), 0);
          end;
          rmRDRAND:
            FillRDRAND64Ptr(@Buf[0], WordsInBlock, rdrandOk);
          rmPascal, rmRNDR:
            FillPascalRandom64Ptr(@Buf[0], WordsInBlock);
          rmHWRNG, rmDevRandom, rmURandom:
          begin
            if (SourceStream = nil) or
               (not ReadStreamExact(SourceStream, @Buf[0], WordsInBlock * SizeOf(QWord))) then
              raise Exception.Create('Failed reading from random source: ' + sourcePath);
          end;
          rmWindowsCrypto:
          begin
            {$IFDEF WINDOWS}
            if not FillWindowsCrypto(@Buf[0], WordsInBlock * SizeOf(QWord)) then
              raise Exception.Create('Windows crypto RNG call failed.');
            {$ELSE}
            raise Exception.Create('Windows crypto RNG requested on non-Windows platform.');
            {$ENDIF}
          end;
          rmAuto:
            FillPascalRandom64Ptr(@Buf[0], WordsInBlock);
        end;
      end;

      // perform write; if disk full / IO error occurs we'll catch and break
      try
        Stream.WriteBuffer(Buf[0], ToWrite);
      except
        on E: Exception do
        begin
          WriteLn('Write error (likely disk full): ', E.ClassName, ' - ', E.Message);
          Break;
        end;
      end;

      Inc(BytesWritten, ToWrite);

      // progress reporting
      // effective verbosity: verbose flag and not quiet
      effVerbose := Verbose and (not Quiet);
      if effVerbose then
      begin
        elapsedSec := (MilliSecondsBetween(Now, startTime)) / 1000.0;
        speedBps := 0;
        if elapsedSec > 0 then
          speedBps := BytesWritten / elapsedSec;

        if SizeBytes > 0 then
        begin
          percent := Integer((BytesWritten * 100) div SizeBytes);
          if percent <> lastPercent then
          begin
            lastPercent := percent;
            Write(Format(#13'Progress: %3d%% (%s / %s) %s/s', [
              percent,
              FormatBytes(BytesWritten, Units),
              FormatBytes(SizeBytes, Units),
              FormatBytesPerTime(Round(speedBps), Units, TimeUnits)
            ]));
          end;
        end
        else if BytesWritten >= nextPrintAt then
        begin
          Write(Format(#13'Written %s (%s/s)', [
            FormatBytes(BytesWritten, Units),
            FormatBytesPerTime(Round(speedBps), Units, TimeUnits)
          ]));
          Inc(nextPrintAt, 64 * 1024 * 1024);
        end;
      end;
    end;

    // final progress
    if (Verbose and (not Quiet)) then
    begin
      elapsedSec := (MilliSecondsBetween(Now, startTime)) / 1000.0;
      if elapsedSec > 0 then
        speedBps := BytesWritten / elapsedSec
      else
        speedBps := 0;
      WriteLn;  // newline after progress line
      WriteLn('Finished writing. Total: ', FormatBytes(BytesWritten, Units), ' Elapsed sec: ', FormatFloat('0.0', elapsedSec), ' Speed: ', FormatBytesPerTime(Round(speedBps), Units, TimeUnits));
    end;

    Result := BytesWritten;
  finally
    Stream.Free;
    if Assigned(SourceStream) then
      SourceStream.Free;
  end;
end;

procedure TRng.DoRun;
var
  ErrorMsg: String;
  OutFileName: string;
  SizeBytes: QWord;
  DryRun: Boolean;
  Verbose: Boolean;
  written: QWord;
  UnitsStr: string;
  TimeUnitStr: string;
  s_timestr: string;
  Quiet: Boolean;
  Benchmark: Boolean;
  RequestedMethod: TRandomMethod;
  EffectiveMethod: TRandomMethod;
  MethodStr: string;
  BlockSizeOverride: QWord;
  VerboseForCall: Boolean;
  okMethod: Boolean;
begin
  // Show help by default if no parameters
  if (ParamCount = 0) or HasOption('h', 'help') then
  begin
    WriteHelp;
    Terminate;
    Exit;
  end;

  // Get options using built-in parser
  OutFileName := GetOptionValue('o', 'outfile');
  if OutFileName = '' then
  begin
    // Check for positional argument
    if ParamCount > 0 then
      OutFileName := ParamStr(ParamCount)
    else
      OutFileName := 'rdrand.bin';
  end;

  // Parse size if provided
  SizeBytes := 0; // 0 => fill until disk full
  if HasOption('s', 'size') then
    SizeBytes := ParseSize(GetOptionValue('s', 'size'));

  DryRun := HasOption('n', 'dry-run');
  Verbose := HasOption('v', 'verbose');
  Quiet := HasOption('q', 'quiet');
  // benchmark mode (suppress progress, keep final summary unless quiet)
  Benchmark := HasOption('b', 'benchmark');

  RequestedMethod := rmAuto;
  MethodStr := GetOptionValue('m', 'method');
  if MethodStr <> '' then
  begin
    okMethod := ParseRandomMethod(MethodStr, RequestedMethod);
    if not okMethod then
    begin
      WriteLn('Invalid --method value: ', MethodStr);
      WriteLn('Valid methods: auto, rdrand, rndr, hwrng, random, urandom, wincrypto, pascal, zeros');
      Terminate;
      Exit;
    end;
  end;

  if HasOption('z', 'use-zeros') then
    RequestedMethod := rmZeros;

  // units: b, kb, mb, gb, tb (default mb)
  UnitsStr := GetOptionValue('u', 'units');
  if UnitsStr = '' then UnitsStr := 'mb';

  // time units for rates: s, m, h (default s)
  TimeUnitStr := GetOptionValue('t', 'time-units');
  s_timestr := LowerCase(TimeUnitStr);
  case s_timestr of
    's': TimeUnitStr := 's';
    'm': TimeUnitStr := 'm';
    'h': TimeUnitStr := 'h';
  else
    TimeUnitStr := 's';
  end;


  //if (not (s_timestr[1] in ['s', 'm', 'h'])) then
//    TimeUnitStr := 's';

  // block size override: -B/--block-size
  BlockSizeOverride := 0;
  if GetOptionValue('B', 'block-size') <> '' then
    BlockSizeOverride := ParseSize(GetOptionValue('B', 'block-size'));

  // If verbose or dry-run, show planned action
  if DryRun or Verbose then
  begin
    if SizeBytes = 0 then
      WriteLn('Planned: create file ', OutFileName, ' and fill disk until full')
    else
      WriteLn('Planned: create file ', OutFileName, ' with size ', FormatBytes(SizeBytes, UnitsStr));
    WriteLn('Requested method: ', MethodToString(RequestedMethod));
    if BlockSizeOverride > 0 then
      WriteLn('Block size override: ', FormatBytes(BlockSizeOverride, UnitsStr));
    if Benchmark then
      WriteLn('Benchmark mode: suppressing progress updates, final summary only');
    if DryRun then
    begin
      WriteLn('Dry-run: no file will be created.');
      Terminate;
      Exit;
    end;
  end;

  // Create the requested file (SizeBytes=0 => fill until disk full)
  try
    VerboseForCall := Verbose and (not Benchmark);
    written := CreateRandomFile(
      OutFileName, SizeBytes, DryRun, VerboseForCall, UnitsStr, TimeUnitStr,
      Quiet, BlockSizeOverride, RequestedMethod, EffectiveMethod
    );
    if (not Quiet) then
    begin
      if Verbose then
        WriteLn('Effective method: ', MethodToString(EffectiveMethod));
      if written > 0 then
        WriteLn('Created ', OutFileName, ' (', FormatBytes(written, UnitsStr), ')')
      else if (not DryRun) and Verbose then
        WriteLn('No bytes written (check permissions or disk space).');
    end;
  except
    on E: Exception do
      WriteLn('Error while creating file: ', E.Message);
  end;

  // stop program loop
  Terminate;
end;

procedure TRng.getrng;
var
  xx: integer;
  v: LongWord;
begin
  if HasRDRAND then
  begin
    WriteLn('RDRAND is supported');
    for xx := 0 to 1000 do
    begin
      if TryGetRDRAND32(v) then
        WriteLn(v)
      else
      begin
        WriteLn('RDRAND read failed');
        Break;
      end;
    end;
  end
  else
  begin
    WriteLn('RDRAND is not supported on this CPU');
  end;
end;

constructor TRng.Create(TheOwner: TComponent);
begin
  inherited Create(TheOwner);
  StopOnException:=True;
end;

destructor TRng.Destroy;
begin
  inherited Destroy;
end;

procedure TRng.WriteHelp;
begin
  WriteLn('rng - Create file filled with selectable random source'); WriteLn('Version: ', version);
  WriteLn('Usage: ', ExeName, ' [options]');
  WriteLn('Options:');
  WriteLn('  -h, --help              Show this help');
  WriteLn('  -o, --outfile=FILE      Output file (default: rdrand.bin)');
  WriteLn('  -s, --size=SIZE         Size to write (default: fill disk)');
  WriteLn('                          Size can use K, M, G, T suffixes');
  WriteLn('  -m, --method=NAME       Random source: auto, rdrand, rndr, hwrng, random, urandom, wincrypto, pascal, zeros');
  WriteLn('  -z, --use-zeros         Shortcut for --method=zeros');
  WriteLn('  -n, --dry-run           Show what would be done without creating file');
  WriteLn('  -v, --verbose           Show progress and speed');
  WriteLn('  -q, --quiet             Silence all output (overrides verbose/benchmark)');
  WriteLn('  -b, --benchmark         Run without progress updates (final summary only)');
  WriteLn('  -B, --block-size=SZ     Block size to use for writes (e.g. 64M, 256M). Default 256M');
  WriteLn('  -u, --units=UNIT        Units for output: b, kb, mb, gb, tb (default: mb)');
  WriteLn('  -t, --time-units=U      Time units for rates: s, m, h (default: s)');
  WriteLn;
  WriteLn('Examples:');
  WriteLn('  ', ExeName, ' -o output.bin -s 100M -m auto     Fastest available source for this platform');
  WriteLn('  ', ExeName, ' -o output.bin -s 1G -m urandom    Force /dev/urandom on Linux');
  WriteLn('  ', ExeName, ' -o out.bin -s 1G -B 512M -z       Fill 1GB with zeros in 512M blocks');
end;

var
  Application: TRng;
begin
  Application:=TRng.Create(nil);
  Application.Title:='rng';
  Application.Run;
  Application.Free;
end.
