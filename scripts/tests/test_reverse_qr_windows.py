#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile/run fresh native Windows QR image fixtures; --compile-only is honest.

No existing image, clipboard, camera, host, UI or network is accessed. On a
non-Windows build machine, only compilation is available and never claims a
native image-codec runtime pass.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from reverse_qr import compile_decoder
from reverse_client import generate_qr_loader
from build_snapshot import source_snapshot


def run(compiler, references, dotnet=None, compile_only=False):
    if os.name != "nt" and not compile_only:
        raise ValueError("Windows QR image-codec execution requires Windows; use --compile-only here")
    snapshot = source_snapshot(ROOT)
    refs = [Path(references) / (name + ".dll") for name in ("mscorlib", "System", "System.Core", "System.Drawing")]
    if any(not p.is_file() for p in refs):
        raise ValueError("Supply .NET Framework 4.8 reference assemblies")
    harness = Path(__file__).with_suffix(".cs")
    sources = [*sorted((ROOT / "Vendor/QRCodegen").glob("*.cs")), ROOT / "client/windows/QrImageReader.cs", harness]
    with tempfile.TemporaryDirectory(prefix="deskbridge-reverse-qr-native-build-") as temporary:
        temporary = Path(temporary)
        run_directory = temporary / "run"
        run_directory.mkdir()
        output = run_directory / "Checks.exe"
        env = dict(os.environ, DOTNET_CLI_HOME=str(temporary / "cli"), DOTNET_NOLOGO="1", DOTNET_CLI_TELEMETRY_OPTOUT="1")
        prefix = [str(dotnet),str(compiler)] if dotnet else [str(compiler)]
        decoder = temporary / "compile" / "DeskBridge.QrDecoder.dll"
        decoder_record = compile_decoder(ROOT, prefix, references, decoder)
        loader = temporary / "ReverseQrLibrary.cs"
        generate_qr_loader(decoder_record["sha256"], loader)
        argv = prefix + [
            "-nologo", "-target:exe", "-platform:anycpu", "-langversion:7.3", "-optimize+", "-deterministic+",
            "-nostdlib+", "-out:" + str(output), *["-r:" + str(p) for p in refs], "-r:" + str(decoder),
            "-resource:" + str(decoder) + "," + decoder_record["resourceName"], *map(str,sources), str(loader)]
        result = subprocess.run(argv,cwd=temporary,env=env,capture_output=True)
        if result.returncode:
            raise RuntimeError(result.stdout.decode(errors="replace")+result.stderr.decode(errors="replace"))
        if (run_directory / decoder.name).exists():
            raise ValueError("Native QR fixture must not have an adjacent decoder DLL")
        record={"status":"COMPILED_ONLY", "compilerExitCode":0,"windowsImageCodecTested":False,
                "upstreamCommit":decoder_record["upstreamCommit"],"fixtureSha256":hashlib.sha256(harness.read_bytes()).hexdigest(),
                "separatelyCompiledEmbeddedDecoder":True,"embeddedDecoderBindingTested":False,
                "embeddedDecoderSha256":decoder_record["sha256"],"noAdjacentDecoder":True,
                "loaderSha256":hashlib.sha256(loader.read_bytes()).hexdigest(), "decoder":decoder_record,
                "compilerArgv":argv,"compilerStdout":result.stdout.decode(errors="replace"),
                "compilerStderr":result.stderr.decode(errors="replace")}
        if not compile_only:
            execute=subprocess.run([str(output)],cwd=run_directory,env=env,capture_output=True,timeout=60)
            if execute.returncode:
                raise RuntimeError(execute.stdout.decode(errors="replace")+execute.stderr.decode(errors="replace"))
            executed = json.loads(execute.stdout.decode())
            if executed.get("embeddedDecoderBindingTested") is not True or executed.get("embeddedDecoderSha256") != decoder_record["sha256"]:
                raise ValueError("Windows QR fixture did not execute the exact embedded decoder binding")
            record.update(executed)
    if source_snapshot(ROOT) != snapshot:
        raise ValueError("Source changed during native Windows QR fixture checks; rerun")
    return record


if __name__ == "__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compiler",required=True)
    parser.add_argument("--references",required=True)
    parser.add_argument("--dotnet")
    parser.add_argument("--compile-only",action="store_true")
    args=parser.parse_args()
    print(json.dumps(run(args.compiler,args.references,args.dotnet,args.compile_only),indent=2))
