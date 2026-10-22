# SPDX-License-Identifier: GPL-3.0-only
"""Shared build/package provenance checks. Only reads this source tree and its build artifacts."""
from pathlib import Path
import hashlib, io, json, stat, subprocess, tarfile


class BuildSnapshotError(ValueError):
    pass

REQUIRED_CHECK_STAGES = {"synthetic-checks", "synthetic-model-checks", "build-contract-checks",
                         "input-batching-checks", "control-hardening-checks", "desktop-input-backpressure-checks",
                         "video-frame-lifecycle-checks",
                         "rtsp-replay-checks", "inspect-app-entitlements", "inspect-dependencies"}


def _ordinary_file(root, path):
    relative = path.relative_to(root)
    if any((root / Path(*relative.parts[:i])).is_symlink() for i in range(1, len(relative.parts) + 1)):
        raise BuildSnapshotError("Symlink is not a build input: " + relative.as_posix())
    if not path.is_file():
        raise BuildSnapshotError("Missing build input: " + relative.as_posix())
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_snapshot(root):
    root = Path(root)
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=root).decode().split("\0")
    paths = {root / name for name in tracked if name}
    # These inputs are consumed outside the recursively scanned roots as well.
    paths.update(root / name for name in ["LICENSE", "INSTALLATION.md", "VERSION"])
    # Include new, not-yet-indexed compiler/resource inputs as well.
    for name in ["Sources", "Assets", "Vendor/Glimmer", "Vendor/QRCodegen", "Vendor/ZXingNet", "Vendor/WindowsRuntime", "host/windows", "host/macos", "host/linux", "client", "scripts", "packaging", ".github"]:
        for path in (root / name).rglob("*"):
            # Only tooling bytecode is generated bookkeeping. A cache-named directory
            # under compiler/resource roots may still contain actual shipped inputs.
            if name == "scripts" and path.parent.name == "__pycache__" and path.suffix == ".pyc":
                continue
            if path.is_symlink() or path.is_file():
                paths.add(path)
    return {p.relative_to(root).as_posix(): _ordinary_file(root, p) for p in sorted(paths)}


def tree_snapshot(root):
    root = Path(root)
    if root.is_symlink() or not root.is_dir():
        raise BuildSnapshotError("Missing or linked app bundle")
    result = {}
    for path in sorted(root.rglob("*")):
        if path.is_symlink():
            raise BuildSnapshotError("Unexpected app bundle symlink")
        if path.is_file():
            result[path.relative_to(root).as_posix()] = {
                "sha256": _ordinary_file(root, path),
                "mode": stat.S_IMODE(path.stat().st_mode),
            }
    if not result:
        raise BuildSnapshotError("Empty app bundle")
    return result


def validate_corresponding_source(root, expected, revision="HEAD"):
    # Compare the actual archive, including export-ignore/export-subst behavior.
    # No archive paths are extracted to the filesystem.
    try:
        data = subprocess.check_output(["git", "archive", "--format=tar", revision], cwd=root, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        diagnostic = error.stderr.decode("utf-8", errors="replace").strip()[:1000]
        raise BuildSnapshotError("Could not read the committed source archive; inspect the revision and rebuild: " + diagnostic) from error
    archived = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            for member in archive:
                if member.isdir():
                    continue
                if not member.isfile():
                    raise BuildSnapshotError("Unsupported corresponding-source entry: " + member.name)
                archived[member.name] = hashlib.sha256(archive.extractfile(member).read()).hexdigest()
    except tarfile.TarError as error:
        raise BuildSnapshotError("Invalid committed source archive; inspect the revision and rebuild") from error
    if expected != archived:
        missing = sorted(expected.keys() - archived.keys())
        extra = sorted(archived.keys() - expected.keys())
        changed = sorted(k for k in expected.keys() & archived.keys() if expected[k] != archived[k])
        raise BuildSnapshotError("Build inputs do not match corresponding source; commit inputs and rebuild. " +
                                 "Missing from archive: " + repr(missing) + "; extra: " + repr(extra) +
                                 "; changed: " + repr(changed))


def validate_completed_build(root, build, require_release=False):
    root, build = Path(root), Path(build)
    try:
        relative = build.relative_to(root / "evidence")
        if ".." in relative.parts or any((root / "evidence" / Path(*relative.parts[:i])).is_symlink()
                                         for i in range(len(relative.parts) + 1)):
            raise BuildSnapshotError("Build evidence must remain inside this source tree")
        completed = json.loads((build / "completed-build.json").read_text())
        invocations = json.loads((build / "build-invocations.json").read_text())
        checks = json.loads((build / "synthetic-checks.stdout").read_text())
        model_checks = json.loads((build / "synthetic-model-checks.stdout").read_text())
        expected = json.loads((build / "source-manifest.json").read_text())
        current = source_snapshot(root)
        if expected != current:
            added = sorted(current.keys() - expected.keys())
            removed = sorted(expected.keys() - current.keys())
            changed = sorted(k for k in current.keys() & expected.keys() if current[k] != expected[k])
            raise BuildSnapshotError("Source changed after build; rebuild. Added: " + repr(added) +
                                     "; removed: " + repr(removed) + "; changed: " + repr(changed))
        validate_corresponding_source(root, expected)
        labels = {r["label"] for r in invocations if r["exitCode"] == 0}
        if (completed.get("schema") != 1 or not completed.get("checksPassed") or
                completed.get("configuration") not in ["release", "debug"] or
                any(r["exitCode"] != 0 for r in invocations) or
                not REQUIRED_CHECK_STAGES <= labels or
                checks.get("status") != "passed" or model_checks.get("status") != "passed"):
            raise BuildSnapshotError("A completed build with both check suites is required")
        if require_release and completed["configuration"] != "release":
            raise BuildSnapshotError("Signed releases require an optimized release build")
        if completed.get("appManifest") != tree_snapshot(root / "dist/Knot.app"):
            raise BuildSnapshotError("App bundle changed after the successful build; rebuild")
        return completed, checks
    except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
        raise BuildSnapshotError("Incomplete or invalid build evidence; rebuild") from error
