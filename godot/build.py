"""Build the Godot extension and put it, with the cadaclysm library, where the addon
loads them from: project/addons/cadaclysm/bin/<platform>/ (windows-x64,
linux-x64, linux-arm64 or macos-universal, as the release names them).

    python build.py [--release] [--libs DIR] [--test [FILTER]]

--libs names the directory holding the library's full flavour, cadaclysm (an SDK's
lib/, say). Without it: CADACLYSM_LIBRARY (the library or its directory), then the
repository's target/flavours/host and target/release (scripts/build-flavour.py full).
--test then runs the tests headless; GODOT names the Godot executable.
CARGO_TARGET_DIR is honoured, as cargo honours it.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PROJECT = HERE / "project"


def platform_dir() -> str:
    """This machine's folder under bin/, named as the release's legs are."""
    if sys.platform == "win32":
        return "windows-x64"
    if sys.platform == "darwin":
        return "macos-universal"
    return "linux-arm64" if platform.machine().lower() in ("aarch64", "arm64") else "linux-x64"


BIN = PROJECT / "addons" / "cadaclysm" / "bin" / platform_dir()
ROOT = HERE.parents[3] if (HERE.parents[3] / "crates" / "cadaclysm-capi").is_dir() else None


def library(stem: str) -> str:
    if sys.platform == "win32":
        return f"{stem}.dll"
    if sys.platform == "darwin":
        return f"lib{stem}.dylib"
    return f"lib{stem}.so"


def find_lib(given: Path | None) -> Path:
    """The library to stage: the full flavour, from --libs, CADACLYSM_LIBRARY (the file or
    its directory) or this repository's own builds of it."""
    name = library("cadaclysm")
    candidates = []
    if given:
        candidates.append(given / name)
    if os.environ.get("CADACLYSM_LIBRARY"):
        p = Path(os.environ["CADACLYSM_LIBRARY"])
        candidates.append(p / name if p.is_dir() else p)
    if ROOT:
        candidates += [ROOT / "target" / "flavours" / "host" / name, ROOT / "target" / "release" / name]
    for c in candidates:
        if c.is_file():
            return c
    sys.exit(f"{name} not found; looked in:\n  " + "\n  ".join(map(str, candidates))
             + "\nPass --libs DIR, or build it: python scripts/build-flavour.py full")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--release", action="store_true")
    ap.add_argument("--libs", type=Path)
    ap.add_argument("--test", nargs="?", const="", default=None, metavar="FILTER")
    args = ap.parse_args()

    profile = "release" if args.release else "debug"
    cmd = ["cargo", "build", "--manifest-path", str(HERE / "Cargo.toml")] + (["--release"] if args.release else [])
    subprocess.run(cmd, check=True)
    target = Path(os.environ.get("CARGO_TARGET_DIR") or HERE / "target")
    BIN.mkdir(parents=True, exist_ok=True)
    built = target / profile / library("cadaclysm_godot")
    shutil.copy2(built, BIN / built.name)
    src = find_lib(args.libs)
    if src.resolve() != (BIN / src.name).resolve():
        shutil.copy2(src, BIN / src.name)
    # What a build before the single library staged here: the extension would pass it over.
    for old in ("cadaclysm_capi", "cadaclysm_blacksmith"):
        (BIN / library(old)).unlink(missing_ok=True)
    print("staged", ", ".join(sorted(p.name for p in BIN.iterdir())))

    if args.test is not None:
        godot = os.environ.get("GODOT")
        if not godot:
            sys.exit("set GODOT to the Godot executable (the _console one on Windows)")
        # Register the extension and import the project's CAD files, as opening it in
        # the editor would (the importer's tests load what this writes). A fresh project
        # takes two passes: the first only finds the extension, the second imports with it.
        fresh = not (PROJECT / ".godot" / "extension_list.cfg").exists()
        for _ in range(2 if fresh else 1):
            subprocess.run([godot, "--headless", "--path", str(PROJECT), "--import"], check=False,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run = [godot, "--headless", "--path", str(PROJECT), "--script", "res://test/run.gd"]
        if args.test:
            run += ["--", args.test]
        return subprocess.run(run).returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
