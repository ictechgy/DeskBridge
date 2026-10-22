#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Optimized, offline benchmarks of production source slices with new synthetic data."""
import argparse
import datetime
import hashlib
import json
import platform
import statistics
import subprocess
import tempfile
import math
import difflib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
ENGINE = ROOT / "Vendor/Glimmer/GlimmerEngine"
CONTRACT = json.loads((HERE / "contract.json").read_text())
HARNESS_FILES = [HERE / name for name in ("SFTPBenchmark.swift", "InputBenchmark.swift", "run.py", "contract.json",
    "synthetic-desktop.html", "New-BenchmarkFixture.ps1", "README.ko.md", "test_timeout_evidence.py")]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(argv, *, cwd=ROOT, timeout=600):
    return subprocess.run(argv, cwd=cwd, check=True, text=True, capture_output=True, timeout=timeout)


def recorded_command(argv, *, cwd, output, label, record, timeout=600):
    """Preserve partial timeout output as well as ordinary nonzero exit evidence."""
    import time
    start = time.monotonic()
    try:
        result = command(argv, cwd=cwd, timeout=timeout)
        record["exitCode"] = result.returncode
        stdout, stderr = result.stdout, result.stderr
    except subprocess.CalledProcessError as error:
        record["exitCode"] = error.returncode
        stdout, stderr = error.stdout or "", error.stderr or ""
        raise
    except subprocess.TimeoutExpired as error:
        record.update(exitCode=124, timedOut=True, timeoutSeconds=timeout)
        stdout, stderr = error.stdout or b"", error.stderr or b""
        raise
    finally:
        record["elapsedSeconds"] = time.monotonic() - start
        if "stdout" in locals():
            (output / (label + ".stdout")).write_bytes(stdout if isinstance(stdout, bytes) else stdout.encode())
            (output / (label + ".stderr")).write_bytes(stderr if isinstance(stderr, bytes) else stderr.encode())


def summarize(directory):
    summary = {"scope": "LOCAL_SYNTHETIC_ONLY", "competitorMeasurements": False, "sftp": [], "input": [], "limitations": {}}
    if (directory / "sftp.json").exists():
        report = json.loads((directory / "sftp.json").read_text())
        summary["limitations"]["sftp"] = report["limitations"]
        cells = {}
        for row in report["rows"]:
            key = row["direction"], row["bytes"], row["injectedReplyDelayMs"]
            cells.setdefault(key, []).append(row)
        for (direction, size, delay), rows in sorted(cells.items()):
            speeds = [r["goodputMiBps"] for r in rows]
            summary["sftp"].append({"direction": direction, "MiB": size / 1048576, "injectedReplyDelayMs": delay,
                "n": len(rows), "medianMiBps": statistics.median(speeds), "minMiBps": min(speeds), "maxMiBps": max(speeds),
                "maxOutstanding": max(r["maxOutstanding"] for r in rows),
                "medianObservedReplyDelayMs": statistics.median(r["meanObservedReplyDelayMs"] for r in rows),
                "timerCalibration": "HIGH_HOST_TIMER_SLACK" if any(r["meanObservedReplyDelayMs"] > delay + CONTRACT["sftp"]["referenceTimerSlackMs"] for r in rows) else "OBSERVED_DELAY_RECORDED",
                "interpretation": "MEMORY_AND_LOCAL_IO_NOT_NETWORK_THROUGHPUT" if delay == 0 else "SERIAL_SYNTHETIC_DELAY_SENSITIVITY_NOT_NETWORK_RTT",
                "requestCounts": sorted({r["requests"] for r in rows})})
        summary["sftpSafety"] = {k: v for k, v in report["safety"].items() if k != "cancelToCompletionMs"}
        summary["sftpSafety"]["inMemoryCancelToCompletionMsSingleSample"] = report["safety"]["cancelToCompletionMs"]
    if (directory / "input.json").exists():
        report = json.loads((directory / "input.json").read_text())
        summary["limitations"]["input"] = report["limitations"] + ["No backpressure exercised", "NativeBackend instance storage is inert test support, not the app object"]
        summary["backpressureExercised"] = report["backpressureExercised"]
        for row in report["rows"]:
            samples = sorted(row["oldestPendingToSyntheticAcceptanceMs"])
            latest = sorted(row["latestEventToSyntheticAcceptanceMs"])
            intervals = sorted(row["producerInterArrivalMs"])
            late = max(row["producerLatenessMs"], default=0)
            summary["input"].append({"profile": row["profile"], "repetition": row["repetition"], "nPackets": len(samples),
                "submitted": row["submitted"], "merged": row["mergedMotionEvents"],
                "medianOldestPendingMs": statistics.median(samples),
                "medianLatestEventMs": statistics.median(latest),
                "p95LatestEventMs": latest[max(0, (95 * len(latest) + 99) // 100 - 1)] if len(latest) >= 100 else None,
                "p95OldestPendingMs": samples[max(0, (95 * len(samples) + 99) // 100 - 1)] if len(samples) >= 100 else None,
                "maxOldestPendingMs": max(samples), "producerLatenessMaxMs": max(row["producerLatenessMs"], default=None)})
            summary["input"][-1].update(targetIntervalNs=row["intervalNs"],
                producerInterArrivalMedianMs=statistics.median(intervals),
                producerInterArrivalP95Ms=intervals[max(0, (95 * len(intervals) + 99) // 100 - 1)],
                scheduleFidelity="BURST_NO_TARGET_GRID" if row["intervalNs"] == 0 else
                    ("TARGET_GRID_WITH_LATE_EVENTS" if late > row["intervalNs"] / 1e6 * 0.2 else "WITHIN20PERCENT_TARGET_LATENESS"))
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    return summary


def validate_results(directory, suite, repetitions):
    """Fail the run on missing cells, non-finite timings or incomplete safety evidence."""
    def require(value, message):
        if not value:
            raise ValueError(message)
    if suite in ("all", "sftp"):
        report = json.loads((directory / "sftp.json").read_text())
        require(report["scope"] == "SYNTHETIC_IN_MEMORY_NO_SSH_NO_NETWORK", "SFTP scope changed")
        spec = CONTRACT["sftp"]
        require(report["warmupRunsExcluded"] == spec["warmupsExcluded"], "SFTP warmup contract drift")
        cells = {(direction, size * 1048576, delay, repeat) for direction in spec["directions"]
            for size in spec["sizesMiB"] for delay in spec["injectedReplyDelayMs"] for repeat in range(1, repetitions + 1)}
        seen = set()
        for row in report["rows"]:
            key = row["direction"], row["bytes"], row["injectedReplyDelayMs"], row["repetition"]
            require(key in cells and key not in seen, "unexpected/duplicate SFTP cell")
            seen.add(key)
            require(row["integrity"] == row["progress"] == "PASS", "SFTP safety failure")
            require(len(row["sha256"]) == 64 and all(c in "0123456789abcdef" for c in row["sha256"]), "invalid digest")
            require(all(math.isfinite(row[k]) and row[k] > 0 for k in ("wallSeconds", "goodputMiBps")), "invalid transfer timing")
            require(row["dataRequests"] == (row["bytes"] + spec["chunkBytes"] - 1) // spec["chunkBytes"] and row["requests"] > row["dataRequests"] and row["maxOutstanding"] == spec["maximumOutstandingRequests"], "missing request accounting/serial contract")
            require(math.isclose(row["goodputMiBps"], row["bytes"] / 1048576 / row["wallSeconds"], rel_tol=1e-9), "incorrect goodput")
            require(math.isfinite(row["meanObservedReplyDelayMs"]) and row["meanObservedReplyDelayMs"] >= row["injectedReplyDelayMs"], "delay calibration invalid")
        require(seen == cells, "missing SFTP cells")
        require(all(report["safety"][k] == "PASS" for k in ("localDownloadNoOverwrite", "cancel", "partialCleanup")), "incomplete safety gates")
        require(report["safety"]["remoteUploadCollisionCases"] == "NOT_EXERCISED", "unsupported remote collision claim")
        require(report["safety"]["cancelWitness"] == "HELD_READ_RECEIVE_WITH_EXISTING_PARTIAL", "missing held receive/partial witness")
        require(report["safety"]["cancelCompletionBudgetMs"] == spec["cancelCompletionBudgetMs"] and
            0 <= report["safety"]["cancelToCompletionMs"] < spec["cancelCompletionBudgetMs"], "cancellation budget failed")
    if suite in ("all", "input"):
        report = json.loads((directory / "input.json").read_text())
        require(report["scope"] == "PRODUCTION_INPUT_SLICE_SYNTHETIC_ACCEPTANCE_NO_NETWORK", "input scope changed")
        spec = CONTRACT["input"]
        require(report["backpressureExercised"] is False and spec["backpressureExercised"] is False, "unsupported backpressure model")
        require(report["backendInstance"] == "INERT_TEST_STORAGE_WITH_PRODUCTION_INPUT_EXTENSION", "unsupported app-instance claim")
        require(report["warmupRunsExcluded"] == spec["warmupsExcluded"], "input warmup contract drift")
        profiles = {p["name"]: p for p in spec["profiles"]}
        counts = {name: p["submitted"] for name, p in profiles.items()}
        cells = {(profile, repeat) for profile in counts for repeat in range(1, repetitions + 1)}
        seen = set()
        for row in report["rows"]:
            key = row["profile"], row["repetition"]
            require(key in cells and key not in seen, "unexpected/duplicate input cell")
            seen.add(key)
            n = row["acceptedIncludingBarrier"]
            require(row["submitted"] == counts[row["profile"]] and row["failures"] == row["duplicates"] == 0, "input safety failure")
            require(1 <= n <= row["submitted"] + 1 and row["mergedMotionEvents"] == row["submitted"] + 1 - n, "incorrect merging accounting")
            require(row["profile"] != "keyboard-100Hz" or n == counts[row["profile"]] + 1, "keyboard packet missing")
            require(row["barrierOrdering"] == "PASS" and row["intervalNs"] == profiles[row["profile"]]["intervalNs"], "barrier/interval contract failed")
            require(row["producerJitterNs"] == profiles[row["profile"]]["producerJitterNs"], "producer jitter contract drift")
            for name in ("latestEventToSyntheticAcceptanceMs", "oldestPendingToSyntheticAcceptanceMs"):
                require(len(row[name]) == n and all(math.isfinite(x) and x >= 0 for x in row[name]), "invalid input samples")
            require(all(old >= latest for old, latest in zip(row["oldestPendingToSyntheticAcceptanceMs"], row["latestEventToSyntheticAcceptanceMs"])), "oldest/latest samples reversed")
            require(len(row["producerLatenessMs"]) == (0 if row["intervalNs"] == 0 else row["submitted"]) and
                all(math.isfinite(x) and x >= 0 for x in row["producerLatenessMs"]), "invalid producer timing")
            require(len(row["producerInterArrivalMs"]) == row["submitted"] - 1 and all(math.isfinite(x) and x >= 0 for x in row["producerInterArrivalMs"]), "invalid inter-arrival timing")
        require(seen == cells, "missing input cells")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True, help="New report directory; existing paths are refused")
    parser.add_argument("--suite", choices=["all", "sftp", "input"], default="all")
    parser.add_argument("--repetitions", type=int, default=CONTRACT["sftp"]["defaultRepetitions"], choices=range(1, 11))
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "RUNNING").write_text("Incomplete run. Only COMPLETE_SYNTHETIC_ONLY provenance with matching hashes is usable.\n")
    info = {"schemaVersion": 1, "status": "RUNNING", "startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "sourceHead": command(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "gitStatus": command(["git", "status", "--short"]).stdout,
        "sourceSnapshot": "WORKING_TREE_BYTES_COPIED_BEFORE_COMPILATION",
        "trackedDiffSHA256": hashlib.sha256(command(["git", "diff", "--no-ext-diff", "HEAD"]).stdout.encode()).hexdigest(),
        "environment": {"os": platform.mac_ver()[0], "architecture": platform.machine(),
            "swift": command(["/usr/bin/swiftc", "--version"]).stdout.strip(), "python": platform.python_version()},
        "repetitions": args.repetitions, "suite": args.suite, "optimization": "-O", "sourcesSHA256": {}, "commands": [],
        "exclusions": ["Windows host", "Moonlight/Cyberduck/CRD/RustDesk measurements", "real network/SSH", "video/audio/IME/Space", "security superiority"],
        "harnessSHA256": {str(p.relative_to(ROOT)): digest(p) for p in HARNESS_FILES}}
    patch = "".join(line for p in sorted(HARNESS_FILES) for line in difflib.unified_diff(
        [], p.read_text().splitlines(True), fromfile="/dev/null", tofile="b/" + str(p.relative_to(ROOT))))
    info["toolingPatchSHA256"] = hashlib.sha256(patch.encode()).hexdigest()
    info["baselineHead"] = CONTRACT["baselineHead"]
    info["sourceHeadMatchesBaseline"] = info["sourceHead"] == info["baselineHead"]
    info["completionMeaning"] = "Execution/contract validation only; not source approval, baseline equivalence, product or competitor validation"
    provenance = output / "provenance.json"
    provenance.write_text(json.dumps(info, indent=2) + "\n")
    try:
        with tempfile.TemporaryDirectory(prefix="deskbridge-benchmark-", dir="/tmp") as temporary:
            fixture = Path(temporary)
            info["fixtureDirectory"] = str(fixture)
            def execute(label, argv):
                record = {"label": label, "argv": [str(x) for x in argv], "cwd": str(fixture)}
                info["commands"].append(record)
                provenance.write_text(json.dumps(info, indent=2) + "\n")
                recorded_command(record["argv"], cwd=fixture, output=output, label=label, record=record)
            def compile_slice(label, sources, extra=()):
                frozen = []
                for index, source in enumerate(sources):
                    # Generated inert support is hashed separately under its logical name.
                    key = str(source.relative_to(ROOT)) if source.is_relative_to(ROOT) else source.name
                    data = source.read_bytes()
                    info["sourcesSHA256"][key] = hashlib.sha256(data).hexdigest()
                    copy = fixture / (str(index) + "-" + source.name)
                    copy.write_bytes(data); frozen.append(copy)
                executable = fixture / label
                execute("compile-" + label, ["/usr/bin/swiftc", "-O", "-swift-version", "6", "-parse-as-library",
                    "-module-cache-path", fixture / "module-cache", *extra, *frozen, "-o", executable])
                return executable
            if args.suite in ("all", "sftp"):
                sources = [ROOT / ("Sources/DeskBridgeCore/" + name + ".swift") for name in
                    ["SFTPClient", "SFTPCodec", "SFTPTransport", "SFTPPipeFramer", "SFTPSSHDiagnostics"]]
                executable = compile_slice("sftp-benchmark", [*sources, HERE / "SFTPBenchmark.swift"])
                local = fixture / "sftp-files"; local.mkdir()
                execute("run-sftp", [executable, local, output / "sftp.json", str(args.repetitions)])
            if args.suite in ("all", "input"):
                # Reuse existing inert test dependencies. Marker drift fails closed, never rewrites production code.
                checks = ROOT / "Sources/DeskBridgeChecks/InputBatcherSyntheticChecks.swift"
                text = checks.read_text(); marker = "// Inert dependencies for this isolated production-source slice."
                if text.count(marker) != 1 or not text.rstrip().endswith("#endif"):
                    raise RuntimeError("Input fixture support boundary changed; update benchmark adapter explicitly")
                support = fixture / "InertInputSupport.swift"
                support.write_text("import Foundation\n" + text.split(marker, 1)[1].rsplit("#endif", 1)[0].split("\n", 1)[1])
                info["sourcesSHA256"][str(checks.relative_to(ROOT))] = digest(checks)
                sources = [ENGINE / name for name in ["Network/InputBatcher.swift", "Network/InputSendThread.swift",
                    "Session/NativeBackend+Input.swift", "Protocol/InputEncoder.swift", "Protocol/EnetWire.swift",
                    "Protocol/StreamingBackend+Values.swift", "Input/DesktopInputWire.swift"]]
                executable = compile_slice("input-benchmark", [*sources, support, HERE / "InputBenchmark.swift"], ["-package-name", "Glimmer"])
                execute("run-input", [executable, output / "input.json", str(args.repetitions)])
        for logical, expected in info["harnessSHA256"].items():
            if digest(ROOT / logical) != expected:
                raise RuntimeError("Harness changed during the run; repeat on a stable snapshot")
        for logical, expected in info["sourcesSHA256"].items():
            if logical != "InertInputSupport.swift" and digest(ROOT / logical) != expected:
                raise RuntimeError("Production/fixture source changed during the run; repeat on a stable snapshot")
        validate_results(output, args.suite, args.repetitions)
        summary = summarize(output)
        info["status"] = "COMPLETE_SYNTHETIC_ONLY"
        info["fixtureRemoved"] = not fixture.exists()
        info["resultSHA256"] = {p.name: digest(p) for p in output.glob("*.json") if p != provenance}
        print(json.dumps(summary, indent=2))
    except BaseException as error:
        info["status"] = "FAILED"; info["failureType"] = type(error).__name__
        info.pop("resultSHA256", None)
        (output / "FAILED").write_text("Incomplete/invalid run. Raw JSON is diagnostic only; see provenance.json.\n")
        raise
    finally:
        if "fixture" in locals():
            info["fixtureRemoved"] = not fixture.exists()
        info["endedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        provenance.write_text(json.dumps(info, indent=2) + "\n")
        (output / "RUNNING").unlink(missing_ok=True)


if __name__ == "__main__":
    main()
