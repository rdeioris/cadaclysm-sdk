# cadaclysm SDK

Wrappers, headers and samples for [cadaclysm](https://cadaclysm.blitter.studio),
the CAD import and modelling library: STEP, IGES, JT, ACIS SAT, Parasolid,
Rhino 3dm, IFC and more in; meshes, LODs and exact B-rep out; an exact
modelling kernel (`cadaclysm_blacksmith`) beside it.

Everything in this repository is Apache-2.0. The libraries themselves are
proprietary, attached to each [release](../../releases) under [EULA.md](EULA.md):
no license is needed to try it -- unlicensed, everything works and a notice
is printed on every open and export; per-seat licenses at
<https://cadaclysm.blitter.studio/license>.

## Install

    python fetch.py            # the latest release's archive for this machine -> lib/ and include/
    python fetch.py v0.1.0     # a specific one

or download an archive from the releases page and unpack its `lib/` and
`include/` here.

### Same release, please

The wrappers here read structs the library fills in, not the other way
round: `cadaclysm_open_options_init` writes the library's whole options
struct, and a wrapper compiled against an older or newer layout will
misread it. Keep the wrapper files and the `lib/` beside them from the same
release -- `fetch.py` and each release's archive already guarantee this;
copying a newer library in beside older wrapper files (or vice versa) is
unsupported.

### Platforms and signing

Prebuilt libraries cover Windows x64, macOS 11+ (universal, Intel and
Apple Silicon in one file) and Linux x64/arm64 (glibc 2.17+). The 0.1.x
binaries are **not code-signed**. On macOS, a library downloaded by a
browser is quarantined and `dlopen` refuses to load it; either fetch with
`fetch.py` (which does not set the quarantine attribute) or clear it
yourself: `xattr -d com.apple.quarantine lib/*.dylib`. The EULA shipped
today is an interim text until the reviewed one lands.

## The license file

No license is needed to try it: unlicensed, everything works, and a notice
is printed to stderr on every open and every export. A license file removes
it. Put it where the libraries look: the `CADACLYSM_LICENSE` environment
variable (the file's path, or its text), or `cadaclysm.lic` beside your
executable or in the working directory, or pass it from code (`license()` in
Python, `Scene.LicenseSet` in C#, `cadaclysm.LicenseSet` in Go,
`Cad.licenseSet` in Java).

## Languages

| | binding | sample | coverage |
|---|---|---|---|
| Python | [python/](python/) | `python -c "import cadaclysm as c; print(c.open('samples/cube.scad').bounds)"` | see the release notes |
| C# | [csharp/](csharp/) | `dotnet run --project csharp/smoke -- samples/cube.scad` | see the release notes |
| Go | [go/](go/) | `go run -C go ./cmd/smoke "$PWD/samples/cube.scad"` | see the release notes |
| Java | [java/](java/) | `javac --release 22 -d java/classes java/*.java && java --enable-native-access=ALL-UNNAMED -cp java/classes Smoke samples/cube.scad` | see the release notes |
| C / C++ | [include/](include/) | the headers are the reference | 100% |

The Go sample's loader must find the library at run time: put the library
directory on `PATH` (Windows), `LD_LIBRARY_PATH` (Linux) or
`DYLD_LIBRARY_PATH` (macOS) -- see [go/README.md](go/README.md).

The C#, Go and Java bindings cover the viewer subset of the C API today;
the header is the reference for the rest, and each release's notes carry the
exact counts. Contributions welcome: a pull request here is ported back
into the library's repository, which is where these files are maintained.

## Versions

The tag here, the archive's `BUILD` line and `cadaclysm_version()` in the
library are the same string; `fetch.py` prints all three.
