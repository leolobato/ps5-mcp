#!/usr/bin/env python3
"""Install checksum-pinned SDK and Remote Play sources under .deps/."""
import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
import zipfile
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent


def fetch_archive(entry, downloads):
    """Reuse only checksum-verified downloads; never silently replace corrupt cache."""
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / entry.get("filename", Path(urlparse(entry["url"]).path).name)
    if not archive.exists():
        partial = archive.with_suffix(archive.suffix + ".partial")
        subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(partial), entry["url"]], check=True)
        partial.replace(archive)
    with archive.open("rb") as source:
        actual = hashlib.file_digest(source, "sha256").hexdigest()
    if actual != entry["sha256"]:
        raise SystemExit(f"Dependency checksum mismatch: {archive}; remove it and retry")
    return archive


def extract_archive(archive, destination):
    destination.mkdir(parents=True, exist_ok=True)
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as source:
            for info in source.infolist():
                if not (destination / info.filename).resolve().is_relative_to(destination.resolve()):
                    raise ValueError(f"Unsafe archive path: {info.filename}")
            source.extractall(destination)
            for info in source.infolist():
                permissions = info.external_attr >> 16
                if permissions:
                    (destination / info.filename).chmod(permissions & 0o777)
    else:
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")


def prepare_source(entry, downloads, destination):
    marker = destination / ".ps5mcp-sha256"
    if destination.exists():
        if not marker.exists() or marker.read_text().strip() != entry["sha256"]:
            raise SystemExit(f"Unmanaged/different dependency at {destination}; move it aside and retry")
        # Verify the cached archive again, even when extraction already exists.
        fetch_archive(entry, downloads)
        return destination
    archive = fetch_archive(entry, downloads)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as staging:
        extracted = Path(staging) / "extracted"
        extract_archive(archive, extracted)
        source = extracted / entry["source_dir"] if entry.get("source_dir") else extracted
        shutil.move(str(source), destination)
    marker.write_text(entry["sha256"] + "\n")
    return destination


def verify_checkout(checkout, revision):
    actual = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=checkout, text=True).strip()
    if actual != revision:
        raise SystemExit(f"Dependency revision mismatch: {actual}; expected {revision}")
    result = subprocess.run(["git", "diff", "--quiet", "--ignore-submodules=none", "HEAD"],
                            cwd=checkout, check=False)
    if result.returncode:
        raise SystemExit(f"Dependency checkout modified: {checkout}; restore it before building")


def prepare_remoteplay(root=ROOT):
    lock = json.loads((root / "toolchain.lock.json").read_text())["remoteplay"]
    subprocess.run(["git", "submodule", "update", "--init", "third-party/chiaki-ng"], cwd=root, check=True)
    chiaki = root / "third-party/chiaki-ng"
    subprocess.run(["git", "submodule", "update", "--init", *lock["submodules"]], cwd=chiaki, check=True)
    verify_checkout(chiaki, lock["chiaki_revision"])
    sources = root / ".deps/remoteplay/sources"
    for name, entry in lock["sources"].items():
        prepare_source(entry, root / ".deps/downloads", sources / name)
    print(f"Remote Play sources verified: {sources}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remoteplay-only", action="store_true", help="prepare Remote Play sources without SDK")
    args = parser.parse_args()
    if args.remoteplay_only:
        prepare_remoteplay()
        return
    lock = json.loads((ROOT / "toolchain.lock.json").read_text())
    sdk = lock["ps5_payload_sdk"]
    deps = ROOT / ".deps"
    downloads = deps / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / f"ps5-payload-sdk-{sdk['version']}.zip"
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        subprocess.run(["curl", "-fL", "--retry", "3", "-o", str(partial), sdk["url"]], check=True)
        partial.replace(archive)
    actual = hashlib.sha256(archive.read_bytes()).hexdigest()
    if actual != sdk["sha256"]:
        raise SystemExit(f"SDK checksum mismatch: {archive}; remove it and retry")
    destination = deps / "ps5-payload-sdk"
    marker = destination / ".ps5mcp-sha256"
    if destination.exists():
        if not marker.exists() or marker.read_text().strip() != actual:
            raise SystemExit(f"Unmanaged/different SDK at {destination}; move it aside and retry")
    else:
        with tempfile.TemporaryDirectory(dir=deps) as staging:
            # ditto/unzip preserves SDK wrapper executable bits and symlinks.
            subprocess.run(["unzip", "-q", str(archive), "-d", staging], check=True)
            shutil.move(str(Path(staging) / "ps5-payload-sdk"), destination)
        marker.write_text(actual + "\n")
    print(f"SDK {sdk['version']} verified: {destination}")
    prepare_remoteplay()
    print("Next: make check")


if __name__ == "__main__":
    main()
