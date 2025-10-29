program get_disk_size;

{$mode objfpc}{$H+}

uses
  SysUtils,
  {$IFDEF MSWINDOWS}
  Windows
  {$ELSE}
  Unix, BaseUnix, Linux
  {$ENDIF};

function GetDiskSize(const ADrive: string): Int64;
  {$IFDEF MSWINDOWS}
  var
    FreeBytesAvailable, TotalNumberOfBytes, TotalNumberOfFreeBytes: ULARGE_INTEGER;
  {$ELSE}
  var
    Stat: TStatFS;
    totals : Int64;
  {$ENDIF}

begin
  {$IFDEF MSWINDOWS}
  if GetDiskFreeSpaceEx(PChar(ADrive), FreeBytesAvailable, TotalNumberOfBytes, @TotalNumberOfFreeBytes) then
    Result := Int64(TotalNumberOfBytes)
  else
    Result := -1;
  {$ELSE}
  if fpStatFS(PChar(ADrive), @Stat) = 0 then
  begin
    totals := Int64(Stat.bsize) * Int64(Stat.blocks);
    Result := totals;
  end
  else
    Result := -1;
  {$ENDIF}
end;

var
  DiskPath: string;
  Size: Int64;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' <path>');
    Halt(1);
  end;
  
  DiskPath := ParamStr(1);
  Size := GetDiskSize(DiskPath);
  
  if Size >= 0 then
    WriteLn('Disk size at ', DiskPath, ': ', Size, ' bytes')
  else
    WriteLn('Error getting disk size for ', DiskPath);
end.

