#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline packaging. Only explicit release mode calls Apple's notarization service."""
from pathlib import Path
import argparse, datetime, gzip, hashlib, io, json, os, plistlib, re, shutil, subprocess, tarfile, tempfile, zipfile
from build_snapshot import BuildSnapshotError, source_snapshot, tree_snapshot, validate_completed_build, validate_corresponding_source
from windows_resources import NativePE, validate_bootstrap
from windows_check_record import validate_windows_check_record
from linux_check_record import validate_linux_check_record, validate_payload_sources
from test_linux_host import archive_inventory

ROOT = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("--mode", choices=["preview", "release"], default="preview")
parser.add_argument("--mac-format", choices=["dmg", "zip", "both"], default="both")
parser.add_argument("--identity", default=os.environ.get("MACOS_SIGNING_IDENTITY"))
parser.add_argument("--notary-profile", default=os.environ.get("MACOS_NOTARY_PROFILE"))
parser.add_argument("--windows-launcher", type=Path, help="Include an exact-source single-file Windows helper built by build_windows_launcher.py")
parser.add_argument("--linux-package", type=Path, help="Include an exact-source checked Linux host Debian package")
args = parser.parse_args()
version = (ROOT / "VERSION").read_text().strip()
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[a-zA-Z0-9.]+)?", version):
    raise SystemExit("Invalid VERSION")
if args.mode == "release" and (not args.identity or not args.identity.startswith("Developer ID Application:") or not args.notary_profile):
    raise SystemExit("Release requires Developer ID Application identity and a preconfigured notary profile.")
if subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT):
    raise SystemExit("Commit the exact source before packaging; the corresponding source archive must match.")
head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
latest = json.loads((ROOT / "evidence/latest-build.json").read_text())
build = ROOT / latest["directory"]
if latest["lastStage"] != "inspect-dependencies":
    raise SystemExit("A complete successful build with checks is required.")
try:
    completed, checks = validate_completed_build(ROOT, build, require_release=args.mode == "release")
except (BuildSnapshotError, ValueError) as error:
    raise SystemExit(str(error))
stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
# Each invocation owns a fresh directory, so old versions/signing modes cannot mix with this set.
output = ROOT / "dist/release" / (version + "-" + args.mode + "-" + stamp + "-" + head[:12])
output.mkdir(parents=True, exist_ok=False)
(ROOT / "evidence/latest-package.json").unlink(missing_ok=True)
evidence = ROOT / "evidence" / ("package-" + stamp); evidence.mkdir()
records = []
launcher_record = None
if args.windows_launcher:
    launcher_record = json.loads(args.windows_launcher.with_suffix('.build.json').read_text())
    if (launcher_record.get('schema') != 1 or launcher_record.get('version') != version or
            launcher_record.get('sourceManifest') != source_snapshot(ROOT) or
            launcher_record.get('compilerExitCode') != 0 or
            launcher_record.get('nativeCompilerExitCode') != 0 or
            launcher_record.get('nativeCLRHeaderAbsent') is not True or
            hashlib.sha256(args.windows_launcher.read_bytes()).hexdigest() != launcher_record.get('sha256')):
        raise SystemExit('Windows helper differs from its successful exact-source build; rebuild before packaging')
    native_bytes = args.windows_launcher.read_bytes()
    managed_bytes = NativePE(native_bytes).resource(10, 101)
    validate_bootstrap(native_bytes, managed_bytes)
    if hashlib.sha256(managed_bytes).hexdigest() != launcher_record.get('managedSha256'):
        raise SystemExit('Windows managed payload differs from the native build manifest')
    try:
        validate_windows_check_record(json.loads(args.windows_launcher.with_suffix('.checks.json').read_text()), launcher_record)
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
if args.linux_package:
    linux_record = json.loads(args.linux_package.with_suffix('.build.json').read_text())
    linux_data = args.linux_package.read_bytes()
    if (linux_record.get('schema') != 1 or linux_record.get('version') != version or
        linux_record.get('sourceManifest') != source_snapshot(ROOT) or linux_record.get('sha256') != hashlib.sha256(linux_data).hexdigest() or
        archive_inventory(linux_data) != linux_record.get('inventory')):
        raise SystemExit('Linux host differs from its exact-source build; rebuild')
    validate_payload_sources(linux_record, archive_inventory(linux_data))
    validate_linux_check_record(json.loads(args.linux_package.with_suffix('.checks.json').read_text()), linux_record)
def run(label, argv):
    print(label, flush=True)
    result = subprocess.run(argv, cwd=ROOT, capture_output=True)
    (evidence / (label + ".stdout")).write_bytes(result.stdout)
    (evidence / (label + ".stderr")).write_bytes(result.stderr)
    records.append({"label": label, "argv": argv, "exitCode": result.returncode})
    (evidence / "invocations.json").write_text(json.dumps(records, indent=2))
    if result.returncode:
        raise SystemExit(label + " failed: " + result.stderr.decode(errors="replace")[-2000:])
    return result.stdout
suffix = "-preview" if args.mode == "preview" else ""
name = "DeskBridge-" + version
generated = []
with tempfile.TemporaryDirectory(prefix="deskbridge-package-") as temporary:
    stage = Path(temporary) / "DeskBridge"; stage.mkdir()
    app = stage / "DeskBridge.app"
    shutil.copytree(ROOT / "dist/DeskBridge.app", app)
    # Recheck the copied payload before signing to bind this package to the successful build.
    if tree_snapshot(app) != completed["appManifest"]:
        raise SystemExit("App changed while staging; rebuild before packaging")
    if args.mode == "release":
        run("sign-app-release", ["/usr/bin/codesign", "--force", "--options", "runtime", "--timestamp", "--sign", args.identity,
            "--entitlements", str(ROOT / "packaging/macos/DeskBridge.entitlements"), str(app)])
        notarize_zip = Path(temporary) / "notarize.zip"
        run("notary-app-zip", ["/usr/bin/ditto", "-c", "-k", "--keepParent", str(app), str(notarize_zip)])
        run("notarize-app", ["/usr/bin/xcrun", "notarytool", "submit", str(notarize_zip), "--keychain-profile", args.notary_profile, "--wait"])
        run("staple-app", ["/usr/bin/xcrun", "stapler", "staple", str(app)])
        run("validate-app-ticket", ["/usr/bin/xcrun", "stapler", "validate", str(app)])
    run("verify-staged-app", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    entitlements = run("inspect-staged-entitlements", ["/usr/bin/codesign", "--display", "--entitlements", "-", "--xml", str(app)])
    if plistlib.loads(entitlements) != {"com.apple.security.device.camera": True}:
        raise SystemExit("The packaged app must contain exactly the camera permission entitlement.")
    (stage / "Applications").symlink_to("/Applications", target_is_directory=True)
    shutil.copy2(ROOT / "LICENSE", stage / "LICENSE")
    (stage / "INSTALL.txt").write_text("DeskBridge.app을 Applications 폴더로 드래그하세요.\nApple Silicon / macOS 26+\n" +
        ("Developer ID 서명 및 Apple 공증 패키지입니다.\n" if args.mode == "release" else "개발 프리뷰: 로컬 ad-hoc 서명이며 Apple 공증이 없습니다.\n") +
        "Windows 설정과 대응 소스는 함께 제공하는 INSTALLATION.md와 source.tar.gz를 확인하세요.\n")
    if args.mac_format in ["zip", "both"]:
        mac_zip = output / (name + "-macos-arm64" + suffix + ".zip")
        run("mac-zip", ["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(stage), str(mac_zip)])
        generated.append(mac_zip)
    if args.mac_format in ["dmg", "both"]:
        image = output / (name + "-macos-arm64" + suffix + ".dmg")
        run("create-dmg", ["/usr/bin/hdiutil", "create", "-volname", "DeskBridge", "-srcfolder", str(stage), "-format", "UDZO", "-ov", str(image)])
        run("verify-dmg", ["/usr/bin/hdiutil", "verify", str(image)])
        generated.append(image)
        if args.mode == "release":
            run("sign-dmg", ["/usr/bin/codesign", "--force", "--timestamp", "--sign", args.identity, str(image)])
            run("notarize-dmg", ["/usr/bin/xcrun", "notarytool", "submit", str(image), "--keychain-profile", args.notary_profile, "--wait"])
            run("staple-dmg", ["/usr/bin/xcrun", "stapler", "staple", str(image)])
            run("validate-dmg-ticket", ["/usr/bin/xcrun", "stapler", "validate", str(image)])
    portable = output / (name + "-windows-x64-portable-preview.zip")
    with zipfile.ZipFile(portable, "w", zipfile.ZIP_DEFLATED) as archive:
        for file in sorted((ROOT / "host/windows").iterdir()):
            if file.is_file(): archive.write(file, "DeskBridge-Windows-Setup/" + file.name)
        archive.write(ROOT / "LICENSE", "DeskBridge-Windows-Setup/LICENSE")
        archive.write(ROOT / "INSTALLATION.md", "DeskBridge-Windows-Setup/INSTALLATION.md")
        archive.write(ROOT / "Vendor/QRCodegen/NOTICE", "DeskBridge-Windows-Setup/QRCodegen-LICENSE")
        archive.write(ROOT / "Vendor/ZXingNet/LICENSE", "DeskBridge-Windows-Setup/QRDecoder-LICENSE.txt")
        archive.write(ROOT / "Vendor/ZXingNet/NOTICE", "DeskBridge-Windows-Setup/QRDecoder-NOTICE.txt")
        for relative in ("MoonlightDependency.json", "MoonlightFiles.json", "Moonlight-LICENSE.txt", "Moonlight-NOTICE.txt", "README.ko.md"):
            archive.write(ROOT / "client/windows" / relative, "DeskBridge-Windows-Setup/ReverseClient/" + relative)
        archive.writestr("DeskBridge-Windows-Setup/ReverseClient/START.txt", "Windows에서 Mac을 열려면 함께 제공한 quick-setup EXE를 실행하고 Mac 열기를 선택하세요. 이 고급 스크립트 ZIP은 기존 Windows 공유 설정용이며 Windows 클라이언트 실행 파일을 대신하지 않습니다.\n")
        if args.windows_launcher:
            qr_library = args.windows_launcher.with_name('DeskBridge-QR.dll')
            if hashlib.sha256(qr_library.read_bytes()).hexdigest() != launcher_record.get('qrLibrarySha256'):
                raise SystemExit('QR helper changed after launcher build')
            archive.write(qr_library, 'DeskBridge-Windows-Setup/DeskBridge-QR.dll')
    generated.append(portable)
    if args.windows_launcher:
        launcher = output / (name + '-windows-x64-quick-setup-preview.exe')
        shutil.copy2(args.windows_launcher, launcher)
        if hashlib.sha256(launcher.read_bytes()).hexdigest() != launcher_record['sha256']:
            raise SystemExit('Windows helper changed during packaging')
        generated.append(launcher)
    if args.linux_package:
        linux_output = output / (name + '-ubuntu24.04-amd64-preview.deb')
        shutil.copy2(args.linux_package, linux_output)
        if hashlib.sha256(linux_output.read_bytes()).hexdigest() != linux_record['sha256']:
            raise SystemExit('Linux package changed during packaging')
        generated.append(linux_output)
        shutil.copy2(ROOT / 'host/linux/README.md', output / 'LINUX-INSTALLATION.md')
        generated.append(output / 'LINUX-INSTALLATION.md')
    source = run("corresponding-source", ["git", "archive", "--format=tar", "--prefix=DeskBridge-source/", head])
    source_path = output / (name + "-source.tar.gz")
    with gzip.open(source_path, "wb") as handle: handle.write(source)
    generated.append(source_path)
    shutil.copy2(ROOT / "INSTALLATION.md", output / "INSTALLATION.md")
    shutil.copy2(ROOT / "Vendor/WindowsRuntime/NOTICE", output / "WindowsRuntime-NOTICE.txt")
    shutil.copy2(ROOT / "client/windows/Moonlight-NOTICE.txt", output / "Moonlight-NOTICE.txt")
    shutil.copy2(ROOT / "client/windows/Moonlight-LICENSE.txt", output / "Moonlight-LICENSE.txt")
    shutil.copy2(ROOT / "Vendor/ZXingNet/NOTICE", output / "QRDecoder-NOTICE.txt")
    shutil.copy2(ROOT / "Vendor/ZXingNet/LICENSE", output / "QRDecoder-LICENSE.txt")
generated.append(output / "INSTALLATION.md")
generated.append(output / "WindowsRuntime-NOTICE.txt")
generated += [output / name for name in ("Moonlight-NOTICE.txt", "Moonlight-LICENSE.txt", "QRDecoder-NOTICE.txt", "QRDecoder-LICENSE.txt")]
if (source_snapshot(ROOT) != json.loads((build / "source-manifest.json").read_text()) or
        subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip() != head or
        subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT)):
    raise SystemExit("Source changed during packaging; discard these outputs and rebuild")
try:
    validate_corresponding_source(ROOT, source_snapshot(ROOT), head)
except BuildSnapshotError as error:
    raise SystemExit("Source archive changed during packaging; discard these outputs and rebuild: " + str(error))
# Hash only this invocation's outputs, never stale files from a prior signing mode/version.
artifacts = sorted(generated)
hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in artifacts}
(output / "SHA256SUMS").write_text("".join(digest + "  " + filename + "\n" for filename, digest in sorted(hashes.items())))
manifest = {"head": head, "version": version, "mode": args.mode, "output": str(output.relative_to(ROOT)), "configuration": completed["configuration"],
            "checks": checks, "sha256": hashes,
            "macNotarized": args.mode == "release", "linuxHostBuiltHere": bool(args.linux_package), "linuxDesktopRuntimeTested": False, "windowsExeBuiltHere": bool(args.windows_launcher),
            "windowsInstallerBuiltHere": False, "windowsHelperRuntimeTested": False,
            "windowsCompiler": "Pinned Zig native bootstrap + explicit Roslyn / Framework 4.8 references" if args.windows_launcher else "GitHub Actions Windows job / pinned Inno Setup", "guiLaunched": False}
(evidence / "manifest.json").write_text(json.dumps(manifest, indent=2))
(ROOT / "evidence/latest-package.json").write_text(json.dumps({"directory": str(evidence.relative_to(ROOT)), **manifest}, indent=2))
print(json.dumps({"output": str(output), "head": head, "artifacts": list(hashes)}, indent=2))
