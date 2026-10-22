#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify and compile the pinned, portable Windows QR decoder; no downloads.

The Windows app embeds the resulting DeskBridge.QrDecoder.dll and resolves that
exact assembly from its own verified resource before calling ReverseQrReader.
"""
from pathlib import Path
import hashlib
import json
import subprocess

ASSEMBLY_NAME = "DeskBridge.QrDecoder"
RESOURCE_NAME = "DeskBridge.Reverse.QrDecoder"
LIBRARY_NAME = "DeskBridge.QrDecoder.dll"
UPSTREAM_COMMIT = "fd58f3c4a5d80ccf45ef1237899a65b0ba5b83a0"


def verify_sources(root):
    vendor = Path(root) / "Vendor/ZXingNet"
    provenance = json.loads((vendor / "UPSTREAM.json").read_text())
    if provenance.get("commit") != UPSTREAM_COMMIT or provenance.get("version") != "0.16.11" or provenance.get("modifiedFiles") != []:
        raise ValueError("Unexpected ZXing.Net QR decoder provenance")
    entries = provenance["files"]
    expected_sources = {name for name in entries if name.endswith(".cs")}
    actual_sources = {p.relative_to(vendor).as_posix() for p in (vendor / "Source").rglob("*.cs")}
    if actual_sources != expected_sources or len(actual_sources) != 50:
        raise ValueError("Unexpected or missing QR decoder source")
    for name, digest in entries.items():
        relative = Path(name)
        if relative.is_absolute() or ".." in relative.parts or name not in expected_sources | {"LICENSE"}:
            raise ValueError("Unexpected QR decoder source inventory")
        if hashlib.sha256((vendor / relative).read_bytes()).hexdigest() != digest:
            raise ValueError("QR decoder differs from pinned source: " + name)
    for name in ("NOTICE", "LICENSE"):
        if not (vendor / name).is_file():
            raise ValueError("Missing QR decoder notice: " + name)
    return [vendor / name for name in sorted(expected_sources)], provenance


def compile_decoder(root, compiler_prefix, references, output):
    """Compile with explicit csc argv prefix and .NET Framework 4.8 refs directory.

    Example prefix: [dotnet, sdk/Roslyn/bincore/csc.dll]. The caller must embed
    RESOURCE_NAME, include NOTICE and LICENSE, and reference the returned DLL
    while compiling client/windows/QrImageReader.cs (with System.Drawing.dll).
    """
    root, references, output = Path(root), Path(references), Path(output)
    sources, provenance = verify_sources(root)
    refs = [references / (name + ".dll") for name in ("mscorlib", "System", "System.Core")]
    if any(not p.is_file() for p in refs):
        raise ValueError("Supply .NET Framework 4.8 reference assemblies for QR decoding")
    if output.name != LIBRARY_NAME:
        raise ValueError("QR decoder output must be " + LIBRARY_NAME)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    argv = [*map(str, compiler_prefix), "-nologo", "-target:library", "-platform:anycpu",
            "-langversion:7.3", "-optimize+", "-deterministic+", "-nostdlib+",
            "-out:" + str(output), *["-r:" + str(p) for p in refs], *map(str, sources)]
    result = subprocess.run(argv, cwd=root, capture_output=True)
    if result.returncode:
        output.unlink(missing_ok=True)
        raise RuntimeError(result.stdout.decode(errors="replace") + result.stderr.decode(errors="replace"))
    return {"assemblyName": ASSEMBLY_NAME, "resourceName": RESOURCE_NAME,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
            "upstreamCommit": provenance["commit"], "sourceSha256": provenance["files"],
            "compilerArgv": argv, "compilerExitCode": result.returncode,
            "stdout": result.stdout.decode(errors="replace"),
            "stderr": result.stderr.decode(errors="replace"),
            "windowsImageCodecRuntimeTested": False}
