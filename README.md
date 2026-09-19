# cadaclysm SDK

Wrappers, headers and samples for [cadaclysm](https://cadaclysm.blitter.studio),
the CAD import and modelling library: STEP, IGES, IFC, Rhino 3dm, ACIS SAT,
BREP and OpenSCAD in; meshes, LODs and exact B-rep out; an exact
modelling kernel (`cadaclysm_blacksmith`) beside it.

Everything in this repository is Apache-2.0. The libraries themselves are
proprietary, attached to each [release](../../releases) under [EULA.md](EULA.md):
no license is needed to try it -- unlicensed, everything works and a notice
is printed on every open and export; per-seat licenses (developers) and
per-server licenses (machines processing files unattended for others) at
<https://cadaclysm.blitter.studio/license>.

## Install

    python fetch.py            # the latest release's archive for this machine -> lib/ and include/
    python fetch.py v0.2.0     # a specific one

or download an archive from the releases page and unpack its `lib/` and
`include/` here.

For Python there is a shorter way: `pip install cadaclysm` installs both
Python modules together with the libraries of one release -- no `fetch.py`, no
`lib/` (see [python/](python/README.md)).

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
Python and Node.js, `Scene.LicenseSet` in C#, `cadaclysm.LicenseSet` in Go,
`Cad.licenseSet` in Java).

    python fetch.py --license KEY

writes it here: the key is the one in your purchase email, and this drops
`cadaclysm.lic` beside `fetch.py` for the searches above to find. Re-run it
whenever the license changes -- a renewal, a seat added through the customer
portal -- to pick up the new file the same way.

## Languages

| | binding | sample | coverage |
|---|---|---|---|
| Python | [python/](python/) | `python -c "import cadaclysm as c; print(c.open('samples/cube.scad').bounds)"` | see the release notes |
| C# | [csharp/](csharp/) | `dotnet run --project csharp/smoke -- samples/cube.scad` | Python's set, both libraries |
| Go | [go/](go/) | `go run -C go ./cmd/smoke "$PWD/samples/cube.scad"` | Python's set, both libraries |
| Java | [java/](java/) | `javac --release 22 -d java/classes java/*.java && java --enable-native-access=ALL-UNNAMED -cp java/classes Smoke samples/cube.scad` | Python's set, both libraries |
| Node.js | [node/](node/) | `npm install` in `node/`, then `node node/smoke.js samples/cube.scad path/to/cadaclysm.lic` | see the release notes |
| C / C++ | [include/](include/) | the headers are the reference | 100% |

The Go sample's loader must find the library at run time: put the library
directory on `PATH` (Windows), `LD_LIBRARY_PATH` (Linux) or
`DYLD_LIBRARY_PATH` (macOS) -- see [go/README.md](go/README.md).

The C#, Go, Java and Node.js bindings cover the viewer subset of the C API
today; the header is the reference for the rest, and each release's notes
carry the exact counts. Contributions welcome: a pull request here is ported
back into the library's repository, which is where these files are
maintained.

## In a web page (WebAssembly)

The readers and the mesher -- and, in the Web Pro build, the kernel -- also
ship as WebAssembly for embedding in a website, one package per web license:
`cadaclysm-<version>-web-reader.zip` and `cadaclysm-<version>-web-pro.zip` on
each release (from v0.3.0).

    python fetch.py --license KEY --web   # the license, then the package it covers, into web/
    python fetch.py --web pro             # a given one: reader or pro

Each holds the module (`pkg/`: an ES module with typings, `load()` and
`license()`), the WebGL2 viewer this project's site uses (`viewer/`) and an
example page and worker (`example/`); serve `web/` and open `/example/`. A web
license names the websites it covers, and the module holds to them -- on
another host it runs as if unlicensed, with a notice in the browser console;
`localhost` always passes. Documentation:
<https://cadaclysm.blitter.studio/docs/web.html>

## Versions

The tag here, the archive's `BUILD` line and `cadaclysm_version()` in the
library are the same string; `fetch.py` prints all three.
