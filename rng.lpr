program rng;
{$ASMMODE INTEL}
{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Classes, SysUtils, CustApp, DateUtils;

type
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

function HasRDRAND: Boolean;
var
  vecx: LongWord;
begin
  vecx := 0;
  writeln('Checking for RDRAND support...');
  asm
    mov eax, 1
    cpuid
    mov [vecx], ecx
  end;
  // Bit 30 of ECX indicates RDRAND support
  Result := (vecx and (1 shl 30)) <> 0;
  writeln('end rdran check');
end;

// Fill `count` 64-bit words at pointer `p` using RDRAND. Returns True if all
// values were produced by RDRAND; otherwise some entries fall back to Pascal
// Random and the function returns False.
procedure FillRDRAND64Ptr(p: PQWord; count: NativeUInt; out allOk: Boolean);
var
  i: NativeUInt;
  valueOk: Byte;
  value: QWord;
begin
  allOk := True;
  if count = 0 then Exit;
  for i := 0 to count - 1 do
  begin
    value := 0;
    valueOk := 0;
    {$IFDEF CPUX86_64}
    asm
      mov rcx, 10           // try up to 10 times
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
    // 32-bit fallback: use two 32-bit GetRDRAND calls
    value := (QWord(GetRDRAND) shl 32) or QWord(GetRDRAND);
    if value <> 0 then valueOk := 1 else valueOk := 0;
    {$ENDIF}

    if valueOk = 1 then
      p^ := value
    else
    begin
      // fallback to Pascal PRNG
      p^ := (QWord(Random($FFFFFFFF)) shl 32) or QWord(Random($FFFFFFFF));
      allOk := False;
    end;

    Inc(p);
  end;
end;

function GetRDRAND: LongWord;
var
  ok: Byte;
  value: LongWord;
begin
  ok := 0;
  value := 0;
  asm
    mov ecx, 10           // try up to 10 times
  @try_rdrand:
    rdrand eax
    jc @success
    loop @try_rdrand
    jmp @fail
  @success:
    mov value, eax
    mov ok, 1
    jmp @done
  @fail:
    mov ok, 0
  @done:
  end;
  if ok = 1 then
    Result := value
  else
    Result := 0;
end;

function GetRDRAND64: QWord;
var
  val: QWord;
  okAll: Boolean;
begin
  FillRDRAND64Ptr(@val, 1, okAll);
  if okAll then
    Result := val
  else
    Result := 0;
end;

function CreateRandomFile(const FileName: string; const SizeBytes: QWord; const DryRun: Boolean; const Verbose: Boolean): QWord;
const
  DefaultBlockSize = 16 shl 20; // 16 MiB
var
  Stream: TFileStream;
  BlockSize: NativeUInt;
  WordsInBlock: NativeUInt;
  Buf: array of QWord;
  BytesWritten: QWord;
  ToWrite: QWord;
  i: NativeUInt;
  // v removed; use bulk rdrand fill
  rdrandOk: Boolean;
  lastPercent: Integer;
  percent: Integer;
  nextPrintAt: QWord;
  startTime, lastTime: TDateTime;
  elapsedSec: Double;
  speedBps: Double;
begin
  Result := 0;

  // Dry-run: just report and return
  if DryRun then
  begin
    if SizeBytes = 0 then
      WriteLn('Dry-run: would create ', FileName, ' and write until disk is full.')
    else
      WriteLn('Dry-run: would create ', FileName, ' and write ', SizeBytes, ' bytes.');
    Exit;
  end;

  // ensure block size is multiple of 8 and not larger than requested size (if provided)
  if (SizeBytes <> 0) and (DefaultBlockSize > SizeBytes) then
    BlockSize := ((SizeBytes + 7) div 8) * 8
  else
    BlockSize := DefaultBlockSize;

  WordsInBlock := BlockSize div SizeOf(QWord);
  SetLength(Buf, WordsInBlock);

  Stream := TFileStream.Create(FileName, fmCreate);
  try
    BytesWritten := 0;
    lastPercent := -1;
    nextPrintAt := 64 * 1024 * 1024; // print every 64 MiB for unknown size
    startTime := Now;
    lastTime := startTime;

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

      // fill buffer with rdrand values in bulk
      if (ToWrite div SizeOf(QWord)) > 0 then
      begin
        FillRDRAND64Ptr(@Buf[0], ToWrite div SizeOf(QWord), rdrandOk);
        // FillRDRAND64Ptr already falls back to Pascal Random for failed entries
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
      if Verbose then
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
            Write(Format(#13'Progress: %3d%% (%d / %d bytes) %s/s', [
              percent, 
              BytesWritten, 
              SizeBytes, 
              FormatFloat('#,##0', speedBps)
            ]));
          end;
        end
        else if BytesWritten >= nextPrintAt then
        begin
          Write(Format(#13'Written %d bytes (%s/s)', [
            BytesWritten,
            FormatFloat('#,##0', speedBps)
          ]));
          Inc(nextPrintAt, 64 * 1024 * 1024);
        end;
      end;
    end;

    // final progress
    if Verbose then
    begin
      elapsedSec := (MilliSecondsBetween(Now, startTime)) / 1000.0;
      if elapsedSec > 0 then
        speedBps := BytesWritten / elapsedSec
      else
        speedBps := 0;
      WriteLn;  // newline after progress line
      WriteLn('Finished writing. Total bytes: ', BytesWritten, ' Elapsed sec: ', FormatFloat('0.0', elapsedSec), ' Speed bytes/s: ', FormatFloat('#,##0', speedBps));
    end;

    Result := BytesWritten;
  finally
    Stream.Free;
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

  DryRun := HasOption('n') or HasOption('dry-run');
  Verbose := HasOption('v') or HasOption('verbose');

  // If verbose or dry-run, show planned action
  if DryRun or Verbose then
  begin
    if SizeBytes = 0 then
      WriteLn('Planned: create file ', OutFileName, ' and fill disk until full')
    else
      WriteLn('Planned: create file ', OutFileName, ' with size ', SizeBytes, ' bytes');
    if DryRun then
    begin
      WriteLn('Dry-run: no file will be created.');
      Terminate;
      Exit;
    end;
  end;

  // Create the requested file (SizeBytes=0 => fill until disk full)
  try
    written := CreateRandomFile(OutFileName, SizeBytes, DryRun, Verbose);
    if written > 0 then
      WriteLn('Created ', OutFileName, ' (', written, ' bytes)')
    else if (not DryRun) and Verbose then
      WriteLn('No bytes written (check permissions or disk space).');
  except
    on E: Exception do
      WriteLn('Error while creating file: ', E.Message);
  end;

  // stop program loop
  Terminate;
end;

procedure TRng.getrng;
var xx : integer;
begin
  if HasRDRAND then begin
    writeln('RDRAND is supported');
    for xx:=0 to 1000 do
    begin
      writeln(getrdrand);
    end;
  end else begin
    writeln('RDRAND is not supported on this CPU');
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
  WriteLn('Usage: ', ExeName, ' [options] [filename]');
  WriteLn('Options:');
  WriteLn('  -h, --help           Show this help');
  WriteLn('  -o, --outfile=FILE   Output file (default: rdrand.bin)');
  WriteLn('  -s, --size=SIZE      Size to write (default: fill disk)');
  WriteLn('                       Size can use K, M, G, T suffixes');
  WriteLn('  -n, --dry-run        Show what would be done');
  WriteLn('  -v, --verbose        Show progress and speed');
  WriteLn;
  WriteLn('Example:');
  WriteLn('  ', ExeName, ' -s 100M output.bin    Create 100 MiB file');
  WriteLn('  ', ExeName, ' --verbose data.bin    Fill disk with random data');
end;

var
  Application: TRng;
begin
  Application:=TRng.Create(nil);
  Application.Title:='rng';
  Application.Run;
  Application.Free;
end.
