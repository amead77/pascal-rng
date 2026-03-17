### rng.lpr

This program can be compiled with Freepascal/Lazarus on Linux or Windows, maybe even Mac.

## Purpose is to create a file of a specified size, or fill the whole disk if wanted.

I originally created it to test out the RDRAND instruction in modern CPUs.
Because I wanted to wipe a disk before gifting it away, I decided to expand the scope of this to do it.

# Note, it does not delete any files. Deleting the data is your responsibility (format), this is to make data unrecoverable by overwriting all free space.

Anyway, after messing with the program a bit, I decided to make a repo and let AI add extra functionality, while also improving my code.
I wrote the initial program in Pascal, because I wanted to use assembly, but at the same time, did not want the bullsh!t that comes with writing in pure asm. As an older person who started with Pascal in the 90s, I decided inline asm for the RDRAND part, and pascal for the bulk.

Below is a snippet from the help output, it explains more than I wish to type today.


```
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
```