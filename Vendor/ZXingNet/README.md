# ZXing.Net QR decoder subset

This directory contains 50 **unmodified** decoder and support source files from
ZXing.Net 0.16.11, commit `fd58f3c4a5d80ccf45ef1237899a65b0ba5b83a0`.
The source inventory, per-file SHA-256 values and official archive digest are in
`UPSTREAM.json`. Apache-2.0 notices are retained in the source and `LICENSE`.
`NOTICE` is included with the Windows distribution. No prebuilt upstream DLL,
NuGet restore, camera integration, image codec, or runtime network request is used.

`scripts/reverse_qr.py` verifies the inventory and compiles
`DeskBridge.QrDecoder.dll` with an explicit C# compiler and .NET Framework 4.8
reference directory. The app embeds it as `DeskBridge.Reverse.QrDecoder`, checks
its generated SHA-256, and loads the bytes before using `ReverseQrReader`.
The adapter needs `System.Drawing.dll`; the decoder library needs only
`mscorlib`, `System` and `System.Core`. The library is compiled as C# 7.3; the
adapter also compiles as C# 5.

`client/windows/QrImageReader.cs` owns the local-file adapter and bounded QR
policy. It accepts still PNG, standard JPEG and BMP files up to 8 MiB and
16,000,000 pixels, with a 16,384-pixel per-side limit. It validates dimensions
before the Windows image codec, composites transparency on white, reduces the
decode buffer to at most 2,048 pixels per side, and applies EXIF orientation
1–8. It examines normal and inverted luminance. At most 24 finder patterns and
16 sampled candidates are accepted per pass; complicated images fail with crop
guidance. Multiple decoded QR symbols are rejected, including identical symbols
and mixed normal/inverted symbols. Structured append is refused.

The returned text is printable ASCII, at most 2,048 characters. It is data only:
the app's shared strict connection parser must validate the scheme, fields and
private-network address before any connection. The adapter never opens a URL,
starts a process, executes QR text, reads the clipboard, opens a camera, or
automatically scans a folder. Linked/cloud or network file paths are refused.

Portable checks (`scripts/tests/test_reverse_qr.py --dotnet <explicit SDK>`) run
the actual production decoder/header/orientation code against newly generated
Nayuki QR fixtures, including ambiguity and complexity limits. They do not run
the Windows image codec. `scripts/tests/test_reverse_qr_windows.py` separately
compiles and, on Windows, runs newly generated PNG/JPEG/BMP, transparency, EXIF,
multiple-symbol and file-release fixtures. `--compile-only` never reports a
Windows runtime pass.
