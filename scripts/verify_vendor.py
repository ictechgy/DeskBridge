#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify unchanged vendor blobs against pinned Git objects; never use network."""
from pathlib import Path
import hashlib, json, shutil, subprocess, sys, tempfile
root = Path(__file__).resolve().parent.parent
vendor = root / "Vendor/Glimmer"
manifest = json.loads((vendor / "UPSTREAM.json").read_text())
allowed = set(manifest["modifiedFiles"])
matched, changed = [], []
def blob(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()
for record in manifest["originalBlobs"]:
    path = record["path"]
    data = (vendor / path).read_bytes()
    actual = blob(data)
    if actual == record["gitBlobSha"]: matched.append(path)
    elif path in allowed: changed.append(path)
    else: raise SystemExit("Unexpected vendor change: " + path)
for record in manifest["additionalBlobs"]:
    if blob((vendor / record["path"]).read_bytes()) != record["sha"]:
        raise SystemExit("Unexpected license/provenance change: " + record["path"])
    matched.append(record["path"])
expected = {r["path"] for r in manifest["originalBlobs"]} | set(manifest["newFiles"])
actual = {p.relative_to(vendor).as_posix() for p in vendor.rglob("*.swift")}
if actual != {p for p in expected if p.endswith(".swift")}:
    raise SystemExit("Unexpected vendor Swift file set")
subprocess.run(["git", "apply", "--reverse", "--unidiff-zero", "--check", "DeskBridge.patch"], cwd=vendor, check=True)
with tempfile.TemporaryDirectory(prefix="deskbridge-upstream-verification-") as temporary:
    original = Path(temporary)
    for name in allowed | set(manifest["newFiles"]):
        target = original / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(vendor / name, target)
    subprocess.run(["git", "apply", "--reverse", "--unidiff-zero", str(vendor / "DeskBridge.patch")], cwd=original, check=True)
    for record in manifest["originalBlobs"]:
        if record["path"] in allowed and blob((original / record["path"]).read_bytes()) != record["gitBlobSha"]:
            raise SystemExit("Patch does not reconstruct pinned upstream blob: " + record["path"])
    if any((original / name).exists() for name in manifest["newFiles"]):
        raise SystemExit("Patch does not account for every new vendor file")
print(json.dumps({"status": "passed", "upstream": manifest["upstreamCommit"],
                  "unchangedBlobs": len(matched), "modifiedBlobs": sorted(changed),
                  "newFiles": manifest["newFiles"]}, indent=2))

