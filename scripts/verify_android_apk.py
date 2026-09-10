#!/usr/bin/env python3
"""Inspect a release APK without installing it or running its native code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import zipfile

MACHINES = {"armeabi-v7a": (1, 40), "arm64-v8a": (2, 183)}
REQUIRED = {"libapp.so", "libflutter.so", "libwatchit_core.so", "libmpv.so"}


def inspect_native(apk, expected):
    if not expected or set(expected) - MACHINES.keys() or len(set(expected)) != len(expected):
        raise ValueError("Unsupported or duplicate expected ABI")
    found = {}
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate ZIP members")
        for item in archive.infolist():
            if not item.filename.startswith("lib/") or item.is_dir():
                continue
            parts = item.filename.split("/")
            if len(parts) != 3 or parts[1] not in expected or not parts[2].endswith(".so"):
                raise ValueError(f"Unexpected native member: {item.filename}")
            with archive.open(item) as stream:
                header = stream.read(64)
            elf_class, machine = MACHINES[parts[1]]
            if (len(header) < 52 or header[:4] != b"\x7fELF" or
                    header[4] != elf_class or header[5] != 1 or
                    struct.unpack_from("<H", header, 18)[0] != machine or
                    struct.unpack_from("<H", header, 16)[0] != 3):
                raise ValueError(f"Wrong ELF architecture/type: {item.filename}")
            found.setdefault(parts[1], {})[parts[2]] = item.file_size
    if set(found) != set(expected):
        raise ValueError("APK ABI set differs from the build selection")
    for abi, libs in found.items():
        if REQUIRED - libs.keys():
            raise ValueError(f"{abi} is missing {sorted(REQUIRED - libs.keys())}")
    return found


def run(*args):
    return subprocess.run(args, check=True, text=True, capture_output=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--abis", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--aapt2", required=True)
    parser.add_argument("--apksigner", required=True)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    native = inspect_native(args.apk, args.abis.split(","))
    badging = run(args.aapt2, "dump", "badging", str(args.apk))
    package = re.search(r"^package: name='([^']+)'", badging, re.M)
    sdk = re.search(r"^sdkVersion:'(\d+)'", badging, re.M)
    if not package or package[1] != args.package:
        raise ValueError("Manifest package does not match the requested build")
    if not sdk or int(sdk[1]) != 24:
        raise ValueError("Expected the pinned minimum Android API 24")
    if "leanback-launchable-activity:" not in badging:
        raise ValueError("Missing TV launcher entry")
    signature = run(args.apksigner, "verify", "--verbose", "--print-certs", str(args.apk))
    certs = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-fA-F]{64})$", signature, re.M)
    if not certs:
        raise ValueError("No verified signer certificate reported")
    with args.apk.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    receipt = {
        "artifact": args.apk.name, "bytes": args.apk.stat().st_size,
        "sha256": digest, "package": package[1], "min_sdk": int(sdk[1]),
        "native_libraries": native, "signer_certificate_sha256": certs,
        "signature_verification": signature, "manifest_badging": badging,
        "hardware_test": "NOT RUN", "signer_ownership": "NOT ATTESTED",
    }
    if args.source:
        receipt["source_commit"] = run("git", "-C", str(args.source), "rev-parse", "HEAD")
        receipt["source_dirty"] = bool(run("git", "-C", str(args.source), "status", "--porcelain"))
        receipt["flutter"] = json.loads(run("flutter", "--version", "--machine"))
        receipt["rustc"] = run("rustc", "--version")
        receipt["cargo_ndk"] = run("cargo", "ndk", "--version")
        ndk = Path(os.environ["ANDROID_NDK_HOME"]) / "source.properties"
        receipt["ndk_source_properties"] = ndk.read_text().strip()
        receipt["android_build_tools"] = (Path(args.aapt2).parent / "source.properties").read_text().strip()
        receipt["gradle_wrapper"] = (args.source / "app/android/gradle/wrapper/gradle-wrapper.properties").read_text().strip()
        java = subprocess.run(["java", "-version"], check=True, text=True, capture_output=True)
        receipt["java"] = (java.stdout + java.stderr).strip()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=args.output.parent, delete=False) as tmp:
        json.dump(receipt, tmp, indent=2)
        tmp.write("\n")
        temporary = Path(tmp.name)
    temporary.replace(args.output)
    print(f"APK structure/signature verified: {args.apk.name}; hardware test not run")


if __name__ == "__main__":
    main()
