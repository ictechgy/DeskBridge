#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline build/check path. Does not disable a sandbox or launch the GUI/network."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, plistlib, shutil, subprocess, sys
from build_snapshot import source_snapshot, tree_snapshot
ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--skip-checks", action="store_true")
parser.add_argument("--configuration", choices=["release", "debug"], default="release")
args = parser.parse_args()
BUILD = ROOT / "build" / args.configuration
LIB = BUILD / "lib"
CACHE = BUILD / "module-cache"
EVIDENCE = ROOT / "evidence" / ("build-" + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
for p in [BUILD, LIB, CACHE, EVIDENCE]: p.mkdir(parents=True, exist_ok=True)
env = dict(os.environ)
env["CLANG_MODULE_CACHE_PATH"] = str(CACHE)
env["SWIFTPM_MODULECACHE_OVERRIDE"] = str(CACHE)
sdk = subprocess.check_output(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
common = ["-swift-version", "6", "-target", "arm64-apple-macosx26.0", "-sdk", sdk, "-module-cache-path", str(CACHE)]
common += ["-O"] if args.configuration == "release" else ["-Onone", "-g", "-D", "DEBUG"]
records = []
snapshot = source_snapshot(ROOT)
(EVIDENCE / "source-manifest.json").write_text(json.dumps(snapshot, indent=2))
def run(label, argv):
    start = datetime.datetime.now(datetime.timezone.utc).isoformat()
    print(label, flush=True)
    p = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True)
    (EVIDENCE / (label + ".stdout")).write_bytes(p.stdout)
    (EVIDENCE / (label + ".stderr")).write_bytes(p.stderr)
    record = dict(label=label, argv=argv, cwd=str(ROOT), startUTC=start,
                  endUTC=datetime.datetime.now(datetime.timezone.utc).isoformat(), exitCode=p.returncode)
    records.append(record)
    (EVIDENCE / "build-invocations.json").write_text(json.dumps(records, indent=2))
    (ROOT / "evidence/latest-build.json").write_text(json.dumps({"directory": str(EVIDENCE.relative_to(ROOT)), "lastStage": label, "exitCode": p.returncode}, indent=2))
    if p.returncode:
        sys.stderr.write(p.stderr.decode(errors="replace")[-12000:])
        sys.stdout.write(p.stdout.decode(errors="replace")[-4000:])
        raise SystemExit(p.returncode)
    return p.stdout
def compile_module(name, folder, package):
    sources = sorted(folder.rglob("*.swift"))
    signature = hashlib.sha256(json.dumps(common).encode())
    signature.update(b"static-private-archives-v1")
    for source in sources:
        signature.update(str(source.relative_to(ROOT)).encode()); signature.update(source.read_bytes())
    digest = signature.hexdigest()
    stamp = LIB / (name + ".hash")
    library = LIB / ("lib" + name + ".a")
    module = LIB / (name + ".swiftmodule")
    if stamp.exists() and stamp.read_text() == digest and library.exists() and module.exists():
        print(name + ": unchanged module", flush=True); return
    rsp = BUILD / (name + ".sources")
    rsp.write_text("".join(json.dumps(str(s)) + "\n" for s in sources))
    argv = ["/usr/bin/swiftc", "-parse-as-library", "-emit-library", "-static", "-emit-module",
            "-module-name", name, "-package-name", package, "-D", "SWIFT_PACKAGE",
            *common, "@" + str(rsp), "-emit-module-path", str(module), "-o", str(library)]
    run("compile-" + name, argv); stamp.write_text(digest)
run("verify-vendor", ["/usr/bin/python3", str(ROOT / "scripts/verify_vendor.py")])
if not args.skip_checks:
    run("build-contract-checks", [sys.executable, str(ROOT / "scripts/tests/test_build_snapshot.py")])
    run("input-batching-checks", [sys.executable, str(ROOT / "scripts/tests/test_input_batching.py")])
    run("control-hardening-checks", [sys.executable, str(ROOT / "scripts/tests/test_control_hardening.py")])
    run("desktop-input-backpressure-checks", [sys.executable, str(ROOT / "scripts/tests/test_desktop_input_backpressure.py")])
    run("video-frame-lifecycle-checks", [sys.executable, str(ROOT / "scripts/tests/test_video_frame_lifecycle.py")])
    run("rtsp-replay-checks", [sys.executable, str(ROOT / "scripts/tests/test_rtsp_replay.py")])
compile_module("GlimmerEngine", ROOT / "Vendor/Glimmer/GlimmerEngine", "Glimmer")
compile_module("DeskBridgeCore", ROOT / "Sources/DeskBridgeCore", "DeskBridge")
app = ROOT / "dist/DeskBridge.app"
if app.exists(): shutil.rmtree(app)
macos = app / "Contents/MacOS"
frameworks = app / "Contents/Frameworks"
resources = app / "Contents/Resources"
if frameworks.exists(): shutil.rmtree(frameworks)
for p in [macos, frameworks, resources]: p.mkdir(parents=True, exist_ok=True)
app_sources = sorted((ROOT / "Sources/DeskBridgeApp").rglob("*.swift"))
run("compile-DeskBridge", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeApp",
    "-package-name", "DeskBridge", *common, "-I", str(LIB), "-L", str(LIB),
    str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
    *map(str, app_sources), "-o", str(macos / "DeskBridge")])
if not args.skip_checks:
    checks = sorted((ROOT / "Sources/DeskBridgeChecks").glob("*.swift"))
    run("compile-checks", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeChecks",
        "-package-name", "DeskBridge", *common, "-I", str(LIB), "-L", str(LIB),
        str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
        *map(str, checks), "-o", str(BUILD / "DeskBridgeChecks")])
    model_sources = [s for s in app_sources if s.name != "DeskBridgeApp.swift"]
    model_sources += sorted((ROOT / "Sources/DeskBridgeAppChecks").glob("*.swift"))
    run("compile-model-checks", ["/usr/bin/swiftc", "-parse-as-library", "-module-name", "DeskBridgeAppChecks",
        "-package-name", "DeskBridge", *common, "-I", str(LIB), "-L", str(LIB),
        str(LIB / "libGlimmerEngine.a"), str(LIB / "libDeskBridgeCore.a"),
        *map(str, model_sources), "-o", str(BUILD / "DeskBridgeAppChecks")])
info = {
    "CFBundleExecutable": "DeskBridge", "CFBundleIdentifier": "org.deskbridge.app",
    "CFBundleName": "DeskBridge", "CFBundleDisplayName": "DeskBridge",
    "CFBundleIconFile": "AppIcon",
    "CFBundleVersion": "14", "CFBundleShortVersionString": (ROOT / "VERSION").read_text().strip().split("-")[0],
    "DeskBridgeVersion": (ROOT / "VERSION").read_text().strip(),
    "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "26.0",
    "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    "NSLocalNetworkUsageDescription": "같은 Wi-Fi의 Sunshine PC를 찾고 선택한 Windows PC의 화면·파일 또는 Linux PC의 화면에 연결합니다.",
    "NSBonjourServices": ["_nvstream._tcp", "_nvstream-tcp._tcp"],
    "NSCameraUsageDescription": "선택한 Windows 또는 Linux PC의 연결 QR을 스캔합니다. 이미지를 저장하거나 전송하지 않습니다.",
    "NSScreenCaptureUsageDescription": "직접 시작한 이 Mac 공유에서 화면을 선택한 Windows 기기에 전송합니다.",
    "NSAudioCaptureUsageDescription": "직접 시작한 이 Mac 공유에서 시스템 오디오를 선택한 Windows 기기에 전송합니다.",
    "NSMicrophoneUsageDescription": "이 Mac 공유의 Sunshine 설정에서 직접 선택한 오디오 입력을 전송할 때 사용합니다.",
    "CFBundleURLTypes": [{"CFBundleURLName": "DeskBridge connection", "CFBundleURLSchemes": ["deskbridge"], "CFBundleTypeRole": "Viewer"}],
    "NSHumanReadableCopyright": "GPLv3. DeskBridge contributors; Glimmer/ugfugl.io; Moonlight contributors.",
}
with (app / "Contents/Info.plist").open("wb") as handle: plistlib.dump(info, handle)
shutil.copy2(ROOT / "LICENSE", resources / "LICENSE")
shutil.copy2(ROOT / "LICENSE", resources / "LICENSE.txt")
shutil.copy2(ROOT / "Assets/Brand/AppIcon.icns", resources / "AppIcon.icns")
shutil.copy2(ROOT / "Assets/Brand/nearby-panes.png", resources / "BrandMark.png")
shutil.copy2(ROOT / "Vendor/Glimmer/CREDITS.md", resources / "GLIMMER_CREDITS.md")
shutil.copy2(ROOT / "Vendor/QRCodegen/NOTICE", resources / "QR_CODEGEN_LICENSE.txt")
if (ROOT / "host/windows/README.md").exists():
    shutil.copy2(ROOT / "host/windows/README.md", resources / "WINDOWS_SETUP.md")
if (ROOT / "host/macos/README.md").exists():
    shutil.copy2(ROOT / "host/macos/README.md", resources / "MACOS_HOST_SETUP.md")
if (ROOT / "host/windows").exists():
    shutil.copytree(ROOT / "host/windows", resources / "WindowsSetup", dirs_exist_ok=True, ignore=shutil.ignore_patterns("tests"))
if not args.skip_checks:
    # Exercise the same static dependency linkage/hardened signing policy, without App.main/UI.
    runtime = BUILD / "runtime-check/Contents"
    (runtime / "MacOS").mkdir(parents=True, exist_ok=True)
    if (runtime / "Frameworks").exists(): shutil.rmtree(runtime / "Frameworks")
    checker = runtime / "MacOS/DeskBridgeChecks"
    shutil.copy2(BUILD / "DeskBridgeChecks", checker)
    run("sign-runtime-check", ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(checker)])
    run("synthetic-checks", [str(checker)])
    model_checker = runtime / "MacOS/DeskBridgeAppChecks"
    shutil.copy2(BUILD / "DeskBridgeAppChecks", model_checker)
    run("sign-model-check", ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", str(model_checker)])
    run("synthetic-model-checks", [str(model_checker)])
run("sign-app", ["/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime",
    "--entitlements", str(ROOT / "packaging/macos/DeskBridge.entitlements"), str(app)])
run("verify-app", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
entitlements = run("inspect-app-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
if plistlib.loads(entitlements) != {"com.apple.security.device.camera": True}:
    raise SystemExit("The signed app must contain exactly the camera permission entitlement.")
dependencies = run("inspect-dependencies", ["/usr/bin/otool", "-L", str(macos / "DeskBridge")]).decode('utf-8').splitlines()[1:]
if not dependencies or any(not line.strip().startswith(("/System/Library/", "/usr/lib/")) for line in dependencies):
    raise SystemExit("Unexpected non-system dynamic dependency in the Mac executable")
if source_snapshot(ROOT) != snapshot:
    raise SystemExit("Source changed during build; rebuild this snapshot before delivery.")
(EVIDENCE / "completed-build.json").write_text(json.dumps({
    "schema": 1, "configuration": args.configuration, "checksPassed": not args.skip_checks,
    "appManifest": tree_snapshot(app),
}, indent=2))
print("Built " + str(app), flush=True)
print("GUI/capture host not launched. Windows, Mac host permissions, IME, Space and network acceptance remain manual.", flush=True)

