#!/usr/bin/env python3
"""Fetch the release archive for this machine into lib/ and include/, or
the WebAssembly package into web/, or refresh the license file from the store.

    python fetch.py                        # latest release
    python fetch.py v0.1.0                 # a given tag
    python fetch.py --flavour reader       # a smaller flavour: kernel-reader, kernel or reader
    python fetch.py --license KEY          # write cadaclysm.lic from the store
    python fetch.py v0.1.0 --license KEY   # both, release first
    python fetch.py --license KEY --store https://your-worker.workers.dev
    python fetch.py --web                  # the WebAssembly package, every build, into web/
    python fetch.py --web v0.14.2          # a given release's
    python fetch.py --license KEY --web    # the license, then the package

--flavour needs a library to fetch: it is refused with --web, and with --license
without a tag (`latest` is a tag here).

Verifies the archive against the release's SHA256SUMS, unpacks lib/ and
include/ (or the package, into web/) beside this file, and prints the
versions so a mismatch is visible.
"""
import argparse
import hashlib
import importlib
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
    # Only worth loading the library if fetch.py has already put one here;
    # otherwise the file is written and the load is deferred to whenever
    # the libraries do turn up.
    os.environ["CADACLYSM_LICENSE"] = str(license_path.resolve())
    library = library_module(HERE / "lib")
    if library is not None:
        # One license covers the whole library, so either module reads it back.
        print(library.license_info())
    else:
        print("wrote cadaclysm.lic (run python fetch.py to get the libraries, then it is picked up)")
    return 0


def release_of(tag: str):
    """The release's JSON from the GitHub API, or None (said why) when there is none."""
    api = f"https://api.github.com/repos/{REPO}/releases/{'latest' if tag == 'latest' else 'tags/' + tag}"
    try:
        return json.loads(get(api))
    except urllib.error.HTTPError as e:
        if e.code == 404:
            print("no release found", file=sys.stderr)
            return None
        raise


def verified(release, name: str):
    """The asset `name` of `release`, checked against the release's SHA256SUMS, or None."""
    assets = {a["name"]: a["browser_download_url"] for a in release["assets"]}
    data = fetch(assets[name], name)
    if data is None:
        return None
    sums_bytes = fetch(assets["SHA256SUMS"], "SHA256SUMS")
    if sums_bytes is None:
        return None
    sums = sums_bytes.decode()
    try:
        expected = next(line.split()[0] for line in sums.splitlines() if line.endswith(name))
    except StopIteration:
        print(f"SHA256SUMS has no entry for {name}", file=sys.stderr)
        return None
    actual = hashlib.sha256(data).hexdigest()
    if actual != expected:
        print(f"{name}: sha256 {actual} != {expected}", file=sys.stderr)
        return None
    return data


#: The flavours of the library, an archive each from v0.14.2; `full` is the default, and the
#: only one before.
FLAVOURS = ("full", "kernel-reader", "kernel", "reader")
#: Every library a fetch may have left in lib/: the four flavours, the two separate libraries
#: of the releases before them, and the two view libraries.
LIBRARY_STEMS = ("cadaclysm", "cadaclysm_kernel_reader", "cadaclysm_kernel", "cadaclysm_reader",
                 "cadaclysm_capi", "cadaclysm_blacksmith", "cadaclysm_terminal", "cadaclysm_view")


def native_asset(names, leg: str, flavour: str = "full"):
    """`flavour`'s archive for `leg` among a release's asset names --
    `cadaclysm-<v>-<leg>.<ext>` for the full flavour, `cadaclysm-<v>-<leg>-<flavour>.<ext>`
    for the others -- or None."""
    tail = f"-{leg}" if flavour == "full" else f"-{leg}-{flavour}"
    for name in names:
        if name.startswith("cadaclysm-") and (name.endswith(tail + ".zip") or name.endswith(tail + ".tar.gz")):
            return name
    return None


def clear_libraries(lib: Path) -> list:
    """Remove every library an earlier fetch left in `lib`, so the flavour unpacked next is the
    only one the wrappers find; anything else in lib/ stays. Returns the names removed."""
    names = set()
    for stem in LIBRARY_STEMS:
        names |= {f"{stem}.dll", f"{stem}.lib", f"lib{stem}.so", f"lib{stem}.dylib"}
    removed = []
    if lib.is_dir():
        for path in sorted(lib.iterdir()):
            if path.is_file() and path.name in names:
                path.unlink()
                removed.append(path.name)
    return removed


#: The libraries the reader module (`cadaclysm`) loads, and those only the kernel module
#: (`cadaclysm_blacksmith`) does: the kernel flavour, and the separate kernel library of the
#: releases before the flavours, have no node API.
READER_STEMS = ("cadaclysm", "cadaclysm_kernel_reader", "cadaclysm_reader", "cadaclysm_capi")
KERNEL_ONLY_STEMS = ("cadaclysm_kernel", "cadaclysm_blacksmith")


def library_module(lib: Path):
    """The Python module that can load the library in `lib` -- `cadaclysm`, or
    `cadaclysm_blacksmith` when lib/ holds only a library without the node API (the kernel
    flavour) -- imported from python/ beside this file; None when lib/ holds no library."""
    def holds(stems):
        return any((lib / name).is_file() for stem in stems
                   for name in (f"{stem}.dll", f"lib{stem}.so", f"lib{stem}.dylib"))
    if holds(READER_STEMS):
        module = "cadaclysm"
    elif holds(KERNEL_ONLY_STEMS):
        module = "cadaclysm_blacksmith"
    else:
        return None
    if str(HERE / "python") not in sys.path:
        sys.path.insert(0, str(HERE / "python"))
    return importlib.import_module(module)


def fetch_release(tag: str, flavour: str = "full") -> int:
    release = release_of(tag)
    if release is None:
        return 1
    name = native_asset([a["name"] for a in release["assets"]], target(), flavour)
    if name is None:
        print(f"release {release['tag_name']} has no {flavour} archive for {target()}"
              + ("" if flavour == "full" else " (the flavours ship from v0.14.2)"), file=sys.stderr)
        return 1
    data = verified(release, name)
    if data is None:
        return 1
    removed = clear_libraries(HERE / "lib")
    if removed:
        print(f"removed from lib/: {', '.join(removed)}")
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
    library = library_module(HERE / "lib")
    if library is None:
        print(f"{name} put no library in lib/", file=sys.stderr)
        return 1
    # Wrappers from before 0.14.2 have no flavour(): say so, never fail on it.
    flavour_of = getattr(library, "flavour", lambda: "unknown")()
    print(f"library reports version {library.version()} built {library.build_date()}, the {flavour_of} flavour")
    return 0


def web_asset(names):
    """The web package among a release's asset names: `cadaclysm-<v>-web.zip`, or, in a
    release before 0.14.2, its `-web-pro.zip`, which held every build."""
    for suffix in ("-web.zip", "-web-pro.zip"):
        for name in names:
            if name.startswith("cadaclysm-") and name.endswith(suffix):
                return name
    return None


def fetch_web(tag: str) -> int:
    """The WebAssembly package into web/: every build, the kernel's included -- a web
    license covers all of it, and unlicensed it runs everything with a console notice."""
    license_path = HERE / "cadaclysm.lic"
    release = release_of(tag)
    if release is None:
        return 1
    name = web_asset([a["name"] for a in release["assets"]])
    if name is None:
        print(f"release {release['tag_name']} has no web package (the WebAssembly builds ship from v0.3.0)", file=sys.stderr)
        return 1
    data = verified(release, name)
    if data is None:
        return 1
    top = name[: -len(".zip")]
    out = HERE / "web"
    build = "(no BUILD in archive)"
    with zipfile.ZipFile(io.BytesIO(data)) as zf:
        for m in zf.namelist():
            rel = m[len(top) + 1:]
            if not rel or m.endswith("/"):
                continue
            (out / rel).parent.mkdir(parents=True, exist_ok=True)
            (out / rel).write_bytes(zf.read(m))
            if rel == "BUILD":
                build = zf.read(m).decode().strip()
    print(f"{release['tag_name']}: {name} verified; {build}")
    print(f"   unpacked into {out}")
    if license_path.is_file():
        # The example page loads ../cadaclysm.lic, i.e. web/cadaclysm.lic.
        (out / "cadaclysm.lic").write_bytes(license_path.read_bytes())
        print(f"   copied {license_path.name} into web/ (the example page loads it)")
    print(f"   try it: python -m http.server 8000 --directory {out}  then open http://localhost:8000/example/")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Fetch the release archive for this machine, or refresh the license file from the store."
    )
    parser.add_argument("tag", nargs="?", default=None, help="a release tag (default: latest)")
    parser.add_argument("--license", metavar="KEY", help="write cadaclysm.lic from the store's copy of this key")
    parser.add_argument("--store", default=STORE_URL, help="the store's base URL (default: %(default)s)")
    parser.add_argument("--flavour", choices=FLAVOURS, default=None,
                        help="which flavour of the library to fetch (default: full)")
    parser.add_argument("--web", action="store_true",
                        help="fetch the WebAssembly package (every build) into web/ instead of the libraries")
    args = parser.parse_args()
    # --flavour picks a library archive; where none is fetched it would be dropped unseen.
    if args.flavour is not None and args.web:
        parser.error("--flavour picks the library's archive; --web fetches the WebAssembly package, "
                     "which holds every build: drop one of them")
    if args.flavour is not None and args.license is not None and args.tag is None:
        parser.error("--license alone only writes the licence file and fetches no library: give a tag "
                     f"to fetch the {args.flavour} flavour as well (python fetch.py latest --flavour "
                     f"{args.flavour} --license KEY)")
    args.flavour = args.flavour or "full"

    if args.web:
        # `--web reader` and `--web pro` named one of two packages until 0.14.2; argparse now
        # reads the word as the tag. One package holds every build: say so, fetch the latest.
        if args.tag in ("auto", "reader", "pro"):
            print(f"fetch.py: --web takes no package name any more ({args.tag!r} ignored): one package holds every build",
                  file=sys.stderr)
            args.tag = None
        if args.license is not None:
            result = fetch_license(args.license, args.store)
            if result != 0:
                return result
        return fetch_web(args.tag or "latest")

    # A bare `--license` refreshes the file only -- it does not also imply
    # "latest", which would silently re-pull the release on every renewal. A
    # tag alongside `--license` does both, release first, so the library that
    # loads to print `license_info()` is the one just fetched.
    if args.license is None or args.tag is not None:
        result = fetch_release(args.tag or "latest", args.flavour)
        if result != 0:
            return result
    if args.license is not None:
        return fetch_license(args.license, args.store)
    return 0


if __name__ == "__main__":
    sys.exit(main())
