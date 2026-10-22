#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run the actual vendored QR decoder on fresh synthetic fixtures, without GUI.

Portable checks use the exact production luminance/header/orientation code. They
do not prove Windows GDI+ image-codec or file-picker behaviour on macOS/Linux.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import xml.sax.saxutils

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from reverse_qr import verify_sources


def run(dotnet):
    sources, provenance = verify_sources(ROOT)
    harness = Path(__file__).with_suffix(".cs")
    app = ROOT / "client/windows/QrImageReader.cs"
    generator = sorted((ROOT / "Vendor/QRCodegen").glob("*.cs"))
    included = [*sources, *generator, app, harness]
    with tempfile.TemporaryDirectory(prefix="deskbridge-reverse-qr-checks-") as temporary:
        temporary = Path(temporary)
        # Only fresh test data and tool outputs enter this directory.
        project = temporary / "Checks.csproj"
        project.write_text('<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup>'
                           '<OutputType>Exe</OutputType><TargetFramework>net8.0</TargetFramework>'
                           '<EnableDefaultCompileItems>false</EnableDefaultCompileItems>'
                           '<DefineConstants>REVERSE_QR_PORTABLE</DefineConstants>'
                           '<LangVersion>7.3</LangVersion><Nullable>disable</Nullable>'
                           '<UseSharedCompilation>false</UseSharedCompilation>'
                           '</PropertyGroup><ItemGroup>' +
                           ''.join('<Compile Include="' + xml.sax.saxutils.escape(str(p), {'"': '&quot;'}) + '" />' for p in included) +
                           '</ItemGroup></Project>')
        config = temporary / "NuGet.Config"
        config.write_text('<configuration><packageSources><clear /></packageSources></configuration>')
        env = dict(os.environ, DOTNET_CLI_HOME=str(temporary / "cli"), DOTNET_NOLOGO="1",
                   DOTNET_CLI_TELEMETRY_OPTOUT="1", DOTNET_SKIP_FIRST_TIME_EXPERIENCE="1")
        restore = subprocess.run([str(dotnet), "restore", str(project), "--configfile", str(config)], cwd=temporary, env=env, capture_output=True)
        if restore.returncode:
            raise RuntimeError(restore.stdout.decode(errors="replace") + restore.stderr.decode(errors="replace"))
        build = subprocess.run([str(dotnet), "build", str(project), "--no-restore", "-c", "Release", "--nologo"], cwd=temporary, env=env, capture_output=True)
        if build.returncode:
            raise RuntimeError(build.stdout.decode(errors="replace") + build.stderr.decode(errors="replace"))
        execute = subprocess.run([str(dotnet), str(temporary / "bin/Release/net8.0/Checks.dll")], cwd=temporary, env=env, capture_output=True, timeout=60)
        if execute.returncode:
            raise RuntimeError(execute.stdout.decode(errors="replace") + execute.stderr.decode(errors="replace"))
        record = json.loads(execute.stdout.decode())
        record.update({"upstreamCommit": provenance["commit"], "sourceFiles": len(sources),
                       "fixtureSha256": hashlib.sha256(harness.read_bytes()).hexdigest(),
                       "productionAdapterSha256": hashlib.sha256(app.read_bytes()).hexdigest(),
                       "windowsNativeFileAndImagePathTested": False, "freshSyntheticOnly": True})
        return record


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dotnet", required=True, help="Explicit .NET 8 SDK executable; no download or install")
    args = parser.parse_args()
    print(json.dumps(run(args.dotnet), indent=2))
