#!/usr/bin/env python3
"""Fetch the release archive for this machine into lib/ and include/.

    python fetch.py            # latest
    python fetch.py v0.1.0     # a given tag

Verifies the archive against the release's SHA256SUMS, unpacks lib/ and
include/ beside this file, and prints the versions so a mismatch is visible.
"""
import hashlib
import io
import json
import platform
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO = "rdeioris/cadaclysm-sdk"
HERE = Path(__file__).resolve().parent


def target() -> str:
    system, machine = platform.system(), platform.machine().lower()
    if system == "Windows":
        return "windows-x64"
    if system == "Darwin":
        return "macos-universal"
    return "linux-arm64" if machine in ("aarch64", "arm64") else "linux-x64"


def get(url: str) -> bytes:
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cadaclysm-fetch"})) as r:
        return r.read()


def fetch(url: str, what: str):
    try:
        return get(url)
    except urllib.error.HTTPError as e:
        print(f"{what}: HTTP {e.code} fetching {url}", file=sys.stderr)
        return None
    except urllib.error.URLError as e:
        print(f"{what}: {e.reason} fetching {url}", file=sys.stderr)
        return None


def main() -> int:
    tag = sys.argv[1] if len(sys.argv) > 1 else "latest"
    api = f"https://api.github.com/repos/{REPO}/releases/{'latest' if tag == 'latest' else 'tags/' + tag}"
    try:
        release = json.loads(get(api))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("no release found", file=sys.stderr)
            return 1
        raise
    assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
    want = [n for n in assets if n.startswith("cadaclysm-") and f"-{target()}." in n]
    if not want:
        print(f"release {release['tag_name']} has no archive for {target()}", file=sys.stderr)
        return 1
    name = want[0]
    data = fetch(assets[name], name)
    if data is None:
        return 1
    sums_bytes = fetch(assets["SHA256SUMS"], "SHA256SUMS")
    if sums_bytes is None:
        return 1
    sums = sums_bytes.decode()
    expected = next(line.split()[0] for line in sums.splitlines() if line.endswith(name))
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        print(f"{name}: sha256 {actual} != {expected}", file=sys.stderr)
        return 1
    top = name.replace(".tar.gz", "").replace(".zip", "")
    members = []
    build = "(no BUILD in archive)"
    if name.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for m in zf.namelist():
                rel = m[len(top) + 1:]
                if rel.startswith(("lib/", "include/")) and not m.endswith("/"):
                    (HERE / rel).parent.mkdir(parents=True, exist_ok=True)
                    (HERE / rel).write_bytes(zf.read(m))
                    members.append(rel)
                if rel == "BUILD":
                    build = zf.read(m).decode().strip()
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as tf:
            for m in tf.getmembers():
                rel = m.name[len(top) + 1:]
                if rel.startswith(("lib/", "include/")) and m.isfile():
                    (HERE / rel).parent.mkdir(parents=True, exist_ok=True)
                    (HERE / rel).write_bytes(tf.extractfile(m).read())
                    members.append(rel)
                if rel == "BUILD":
                    build = tf.extractfile(m).read().decode().strip()
    print(f"{release['tag_name']}: {name} verified; {build}")
    for rel in members:
        print("  ", rel)
    sys.path.insert(0, str(HERE / "python"))
    import cadaclysm  # noqa: E402
    print(f"library reports version {cadaclysm.version()} built {cadaclysm.build_date()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
