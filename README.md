# cadaclysm SDK

Wrappers, headers and samples for [cadaclysm](https://cadaclysm.blitter.studio),
the CAD import and modelling library: STEP, IGES, IFC, Rhino 3dm, ACIS SAT,
OCCT .brep and OpenSCAD in; meshes, LODs and exact B-rep out; an exact
modelling kernel (`cadaclysm_blacksmith`) beside it.

Everything in this repository is Apache-2.0. The libraries themselves are
proprietary, owned by Blitter S.r.l. and Roberto De Ioris, attached to each
[release](../../releases) under [EULA.md](EULA.md):
no license is needed to try it -- unlicensed, everything works and a notice
is printed on every open and export; per-seat licenses (developers) and
per-server licenses (machines processing files unattended for others) at
<https://cadaclysm.blitter.studio/license>.

## Install

    python fetch.py            # the latest release's archive for this machine -> lib/ and include/
    python fetch.py v0.4.4     # a specific one

or download an archive from the releases page and unpack its `lib/` and
`include/` here.

For Python there is a shorter way: `pip install cadaclysm` installs both
Python modules together with the libraries of one release -- no `fetch.py`, no
`lib/` (see [python/](python/README.md)).

For Rust too: `cargo add cadaclysm-sdk` (from v0.4.3) downloads this platform's
libraries for the crate's own release when it builds, checks them against the
release's `SHA256SUMS` and puts them beside your binaries -- no `fetch.py`, no
`lib/` (see [rust/](rust/README.md); `default-features = false` turns it off).
Every type and call is on the [Rust API page](https://cadaclysm.blitter.studio/docs/rust.html):

```rust
fn main() -> cadaclysm_sdk::Result<()> {
    let scene = cadaclysm_sdk::open("samples/cube.scad")?;
    for node in scene.walk().filter(|node| node.can_mesh()) {
        println!("{}: {} triangles", node.label(), node.mesh().triangle_count());
    }
    Ok(())
}
```

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
Apple Silicon in one file) and Linux x64/arm64 (glibc 2.17+). The binaries
are **not code-signed** yet (each release's notes say so per archive). On macOS, a library downloaded by a
browser is quarantined and `dlopen` refuses to load it; either fetch with
`fetch.py` (which does not set the quarantine attribute) or clear it
yourself: `xattr -d com.apple.quarantine lib/*.dylib`.

## The license file

No license is needed to try it: unlicensed, everything works, and a notice
is printed to stderr on every open and every export. A license file removes
it. Put it where the libraries look: the `CADACLYSM_LICENSE` environment
variable (the file's path, or its text), or `cadaclysm.lic` beside your
executable or in the working directory, or pass it from code (`license()` in
Python, Node.js, Swift and LuaJIT, `Cadaclysm.License` in C#, `cadaclysm.License` in Go,
`Cad.license` in Java, `cadaclysm_sdk::license` in Rust). The kernel library
keeps its own license state: from code, license it with its own call beside
the reader's (`cadaclysm_blacksmith.license()`, `Blacksmith.License`,
`blacksmith.License`, `Blacksmith.license`, `cadaclysm_sdk::blacksmith::license`,
`require("cadaclysm_blacksmith").license()` in LuaJIT).

    python fetch.py --license KEY

writes it here: the key is the one in your purchase email, and this drops
`cadaclysm.lic` beside `fetch.py` for the searches above to find. Re-run it
whenever the license changes -- a renewal, a seat added through the customer
portal -- to pick up the new file the same way.

## Languages

| | binding | sample | coverage |
|---|---|---|---|
| Python | [python/](python/); [API docs](https://cadaclysm.blitter.studio/docs/python.html) | `python -c "import cadaclysm as c; print(c.open('samples/cube.scad').bounds)"` | the reference set, both libraries |
| C# | [csharp/](csharp/); [API docs](https://cadaclysm.blitter.studio/docs/csharp.html) | `dotnet run --project csharp/smoke -- samples/cube.scad` | Python's set, both libraries |
| Go | [go/](go/); [API docs](https://cadaclysm.blitter.studio/docs/go.html) | `go run -C go ./cmd/smoke "$PWD/samples/cube.scad"` | Python's set, both libraries |
| Java | [java/](java/); [API docs](https://cadaclysm.blitter.studio/docs/java.html) | `javac --release 22 -d java/classes java/*.java && java --enable-native-access=ALL-UNNAMED -cp java/classes Smoke samples/cube.scad` | Python's set, both libraries |
| Node.js | [node/](node/); [API docs](https://cadaclysm.blitter.studio/docs/node.html) | `npm install` in `node/`, then `node node/smoke.js samples/cube.scad path/to/cadaclysm.lic` | Python's set, both libraries |
| Rust | [rust/](rust/) -- also on crates.io, `cargo add cadaclysm-sdk`; [API docs](https://cadaclysm.blitter.studio/docs/rust.html) | `cargo run --manifest-path rust/Cargo.toml --example smoke -- samples/cube.scad`, or `--example tree` to print a file's tree | Python's set, both libraries |
| Swift | [swift/](swift/) -- a Swift package, from v0.4.4; [API docs](https://cadaclysm.blitter.studio/docs/swift.html) | `swift run --package-path swift cadaclysm-smoke samples/cube.scad` | Python's set, both libraries |
| LuaJIT | [luajit/](luajit/) -- for LÖVE, LÖVR or a plain `luajit`, from v0.4.5; [API docs](https://cadaclysm.blitter.studio/docs/luajit.html), [LÖVE and LÖVR](https://cadaclysm.blitter.studio/engines/love.html) | `luajit luajit/smoke/main.lua samples/cube.scad` | Python's set, both libraries |
| C / C++ | [include/](include/); [API docs](https://cadaclysm.blitter.studio/docs/c.html) | the headers are the reference | 100% |

The Go sample's loader must find the library at run time: put the library
directory on `PATH` (Windows), `LD_LIBRARY_PATH` (Linux) or
`DYLD_LIBRARY_PATH` (macOS) -- see [go/README.md](go/README.md). The Swift
package links `lib/` when it is built and writes it into the executable's rpath
on macOS and Linux; on Windows `lib` goes on `PATH` -- see
[swift/README.md](swift/README.md). The LuaJIT modules load the libraries
through the FFI, nothing compiled: from `CADACLYSM_LIBRARY` /
`CADACLYSM_BLACKSMITH_LIBRARY`, beside the Lua files, beside a fused LÖVE game's
executable, or `lib/` in any parent -- see [luajit/README.md](luajit/README.md).

Every binding follows the Python modules' object model over both libraries,
with each language's own spelling; its API docs page lists every type and call
and marks the few it does not have yet. The headers are the reference for the
whole C API, and each release's notes carry the exact counts. Contributions welcome: a pull request here is ported
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
