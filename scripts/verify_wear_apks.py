#!/usr/bin/env python3
"""Reject companion APK pairs that Wear Data Layer cannot authenticate together."""

import argparse
from pathlib import Path
import re
import subprocess


def one_apk(directory: Path) -> Path:
    apks = sorted(directory.rglob("*.apk"))
    if len(apks) != 1:
        raise ValueError(f"Expected one APK in {directory}, found {apks}")
    return apks[0]


def inspect(apk: Path, tools: Path) -> tuple[str, str, str, str]:
    verified = subprocess.run(
        [str(tools / "apksigner"), "verify", "--print-certs", str(apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    certificates = re.findall(r"certificate SHA-256 digest:\s*([a-fA-F0-9]{64})", verified)
    if len(certificates) != 1:
        raise ValueError(f"Expected one signing certificate for {apk}: {verified}")
    badging = subprocess.run(
        [str(tools / "aapt"), "dump", "badging", str(apk)],
        check=True, capture_output=True, text=True,
    ).stdout
    package = re.search(
        r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging
    )
    if package is None:
        raise ValueError(f"Could not read package metadata for {apk}")
    result = (*package.groups(), certificates[0].lower())
    print(f"{apk}: package={result[0]}, version={result[2]} ({result[1]}), SHA-256={result[3]}")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--phone-dir", type=Path, default=Path("app/build/outputs/apk"))
    parser.add_argument("--watch-dir", type=Path, default=Path("wear/build/outputs/apk"))
    parser.add_argument("--build-tools-dir", type=Path, required=True)
    args = parser.parse_args()
    try:
        phone = inspect(one_apk(args.phone_dir), args.build_tools_dir)
        watch = inspect(one_apk(args.watch_dir), args.build_tools_dir)
        if phone != watch:
            raise ValueError("Phone and watch package, version or signing certificate differs")
    except subprocess.CalledProcessError as error:
        raise SystemExit(f"APK tool failed: {error.stdout}\n{error.stderr}") from error
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print("Verified matching, validly signed phone and Wear OS APKs")


if __name__ == "__main__":
    main()
