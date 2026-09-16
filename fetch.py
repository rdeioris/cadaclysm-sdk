#!/usr/bin/env python3
"""Fetch the release archive for this machine into lib/ and include/, or
refresh the license file from the store.

    python fetch.py                        # latest release
    python fetch.py v0.1.0                 # a given tag
    python fetch.py --license KEY          # write cadaclysm.lic from the store
    python fetch.py v0.1.0 --license KEY   # both, release first
    python fetch.py --license KEY --store https://your-worker.workers.dev

Verifies the archive against the release's SHA256SUMS, unpacks lib/ and
include/ beside this file, and prints the versions so a mismatch is visible.
"""
import argparse
import hashlib
import io
import json
import os
import platform
import sys
import tarfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO = "rdeioris/cadaclysm-sdk"
HERE = Path(__file__).resolve().parent

# The store worker (name `cadaclysm-store` in the store's wrangler.toml), as
# deployed on 2026-09-16; `--store` overrides it.
STORE_URL = "https://cadaclysm-store.billowing-snow-c12e.workers.dev"


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


def fetch_license(key: str, store: str) -> int:
    """`GET <store>/license/<key>`, write the body to `cadaclysm.lic`, and report it.

    The key is the whole secret -- an unknown, malformed or lapsed one all read
    back as a 404, and this prints the same `no such license` for all of them
    rather than guessing which.
    """
    url = f"{store}/license/{key}"
    try:
        data = get(url)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("no such license", file=sys.stderr)
        elif e.code == 429:
            print("too many requests -- try again in an hour", file=sys.stderr)
        else:
            print(f"HTTP {e.code} fetching {url}", file=sys.stderr)
        return 1
    except urllib.error.URLError as e:
        print(f"{e.reason} fetching {url}", file=sys.stderr)
        return 1
    license_path = HERE / "cadaclysm.lic"
    license_path.write_bytes(data)
    if (HERE / "lib").exists():
        # Only worth loading the library if fetch.py has already put one here;
        # otherwise the file is written and the load is deferred to whenever
        # the libraries do turn up.
        sys.path.insert(0, str(HERE / "python"))
        os.environ["CADACLYSM_LICENSE"] = str(license_path.resolve())
        import cadaclysm  # noqa: E402

        print(cadaclysm.license_info())
    else:
        print("wrote cadaclysm.lic (run python fetch.py to get the libraries, then it is picked up)")
    return 0


def fetch_release(tag: str) -> int:
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
    try:
        expected = next(line.split()[0] for line in sums.splitlines() if line.endswith(name))
    except StopIteration:
        print(f"SHA256SUMS has no entry for {name}", file=sys.stderr)
        return 1
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
                    # Overwrites the tracked headers by design: the archive's include/
                    # is the one that matches lib/, and a checkout must not drift from it.
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


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch the release archive for this machine, or refresh the license file from the store."
    )
    parser.add_argument("tag", nargs="?", default=None, help="a release tag (default: latest)")
    parser.add_argument("--license", metavar="KEY", help="write cadaclysm.lic from the store's copy of this key")
    parser.add_argument("--store", default=STORE_URL, help="the store's base URL (default: %(default)s)")
    args = parser.parse_args()

    # A bare `--license` refreshes the file only -- it does not also imply
    # "latest", which would silently re-pull the release on every renewal. A
    # tag alongside `--license` does both, release first, so the library that
    # loads to print `license_info()` is the one just fetched.
    if args.license is None or args.tag is not None:
        result = fetch_release(args.tag or "latest")
        if result != 0:
            return result
    if args.license is not None:
        return fetch_license(args.license, args.store)
    return 0


if __name__ == "__main__":
    sys.exit(main())
