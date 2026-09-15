# cadaclysm SDK

Wrappers, headers and samples for [cadaclysm](https://cadaclysm.blitter.studio),
the CAD import and modelling library: STEP, IGES, JT, ACIS SAT, Parasolid,
Rhino 3dm, IFC and more in; meshes, LODs and exact B-rep out; an exact
modelling kernel (`cadaclysm_blacksmith`) beside it.

Everything in this repository is Apache-2.0. The libraries themselves are
proprietary, attached to each [release](../../releases) under [EULA.md](EULA.md),
and need a license: free 30-day trials at
<https://cadaclysm.blitter.studio/license>.

## Install

    python fetch.py            # the latest release's archive for this machine -> lib/ and include/
    python fetch.py v0.1.0     # a specific one

or download an archive from the releases page and unpack its `lib/` and
`include/` here.

## The license file

Put it where the libraries look: the `CADACLYSM_LICENSE` environment variable
(the file's path, or its text), or `cadaclysm.lic` beside your executable or
in the working directory, or pass it from code (`license()` in Python,
`Scene.LicenseSet` in C#, `cadaclysm.LicenseSet` in Go, `Cad.licenseSet` in
Java).

## Languages

| | binding | sample | coverage |
|---|---|---|---|
| Python | [python/](python/) | `python -c "import cadaclysm as c; print(c.open('samples/cube.scad').bounds)"` | see the release notes |
| C# | [csharp/](csharp/) | `dotnet run --project csharp/smoke -- samples/cube.scad` | see the release notes |
| Go | [go/](go/) | `go run ./go/cmd/smoke samples/cube.scad` | see the release notes |
| Java | [java/](java/) | `javac --release 22 -d classes java/*.java && java -cp classes Smoke samples/cube.scad` | see the release notes |
| C / C++ | [include/](include/) | the headers are the reference | 100% |

The C#, Go and Java bindings cover the viewer subset of the C API today;
the header is the reference for the rest, and each release's notes carry the
exact counts. Contributions welcome: a pull request here is ported back
into the library's repository, which is where these files are maintained.

## Versions

The tag here, the archive's `BUILD` line and `cadaclysm_version()` in the
library are the same string; `fetch.py` prints all three.
