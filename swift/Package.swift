// swift-tools-version:5.9
//
// cadaclysm for Swift: the CAD readers (`Cadaclysm`, over cadaclysm_capi) and the
// blacksmith B-rep kernel (`Blacksmith`, over cadaclysm_blacksmith), with the same object
// model as the Python, C#, Go, Java and Node.js wrappers.
//
//   swift build
//   swift run cadaclysm-smoke [model] [license]
//   swift test
//
// Drawing: import CadaclysmView (README, "Drawing").
//
// The libraries are linked when the package is built, so this manifest has to find them:
//
//   1. CADACLYSM_LIB_DIR, when set;
//   2. in an SDK checkout (fetch.py beside this package's directory), ../lib -- where
//      `python fetch.py` puts them;
//   3. in the cadaclysm repository, its target/release -- after
//      `cargo build --release -p cadaclysm-capi -p cadaclysm-blacksmith-capi`.
//
// The choice is made from the layout, never from whether the libraries are there yet:
// SwiftPM caches this manifest's result until its text or the environment changes, so a
// build run before the libraries were fetched would otherwise stay pointed at the wrong
// place after they were. On macOS and Linux the directory is also written into the
// executables' rpath; on Windows it has to be on PATH when a program runs.
//
// iOS (the cadaclysm repository only, for the Metal viewer's iOS app): the reader comes as
// CadaclysmCapi.xcframework, a dynamic framework per slice, which
// scripts/build-render-metal-xcframework.sh copies into Frameworks/ here (git-ignored). The
// binary target is declared only when it is there (SwiftPM refuses a missing one on every
// platform) and linked on iOS only; every other platform keeps the -L route below. The
// kernel has no iOS build.
import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment["CADACLYSM_LIB_DIR"].flatMap { $0.isEmpty ? nil : $0 }
let inRepository = FileManager.default.fileExists(atPath: here.appendingPathComponent("../../../../Cargo.toml").standardized.path)
    && !FileManager.default.fileExists(atPath: here.appendingPathComponent("../fetch.py").standardized.path)

let libDir = environment
    ?? (inRepository ? here.appendingPathComponent("../../../../target/release") : here.appendingPathComponent("../lib"))
        .standardized.path
// The view library's search names this directory too (CCadaclysmView compiles it in as a C
// string, so forward slashes only). A directory with a space or a quote in it is left out:
// Xcode passes a define through GCC_PREPROCESSOR_DEFINITIONS, which splits on spaces and
// mangles quotes -- the view library is then found beside the reader or the executable, by
// CADACLYSM_VIEW_LIBRARY / CADACLYSM_TERMINAL_LIBRARY, or on the loader's path instead.
let viewDir = libDir.replacingOccurrences(of: "\\", with: "/")
let viewDirSettings: [CSetting] = viewDir.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" })
    ? [] : [.define("CVL_SWIFT_LIBRARY_DIR", to: "\"\(viewDir)\"")]

// Windows: a cargo target/ holds cadaclysm_capi.dll.lib (the import library) beside
// cadaclysm_capi.lib, which there is the STATIC library; an SDK's lib/ holds only the
// import library, renamed cadaclysm_capi.lib. The layout says which; a directory named by
// CADACLYSM_LIB_DIR is asked, being one the caller has already filled.
let cargoTarget = environment.map { FileManager.default.fileExists(atPath: $0 + "/cadaclysm_capi.dll.lib") } ?? inRepository
let windowsSuffix = cargoTarget ? ".dll" : ""

// The search path and rpath go on the reader alone: the kernel depends on it, so anything
// linking the kernel links through the reader too, and a second copy of the flags makes
// the macOS linker warn about a duplicate -rpath.
let readerLinks: [LinkerSetting] = [
    .linkedLibrary("cadaclysm_capi", .when(platforms: [.macOS, .linux])),
    .linkedLibrary("cadaclysm_capi" + windowsSuffix, .when(platforms: [.windows])),
    .unsafeFlags(["-L", libDir], .when(platforms: [.macOS, .linux, .windows])),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", libDir], .when(platforms: [.macOS, .linux])),
]
let kernelLinks: [LinkerSetting] = [
    .linkedLibrary("cadaclysm_blacksmith", .when(platforms: [.macOS, .linux])),
    .linkedLibrary("cadaclysm_blacksmith" + windowsSuffix, .when(platforms: [.windows])),
]

let readerFramework = "Frameworks/CadaclysmCapi.xcframework"
let haveReaderFramework = FileManager.default.fileExists(atPath: here.appendingPathComponent(readerFramework).path)

let package = Package(
    name: "Cadaclysm",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Cadaclysm", targets: ["Cadaclysm"]),
        .library(name: "Blacksmith", targets: ["Blacksmith"]),
        .library(name: "CadaclysmView", targets: ["CadaclysmView"]),
        .executable(name: "cadaclysm-smoke", targets: ["cadaclysm-smoke"]),
    ],
    targets: [
        .systemLibrary(name: "CCadaclysm", path: "Sources/CCadaclysm"),
        .systemLibrary(name: "CCadaclysmBlacksmith", path: "Sources/CCadaclysmBlacksmith"),
        // The view library is opened at run time (the library choice demands it): a C
        // target holds the table (view_loader.h, a copy kept by bindings.rs), and links
        // nothing of the view -- only libdl and libm on Linux (dlopen; the camera's atan2,
        // asin, hypot, log).
        .target(name: "CCadaclysmView", path: "Sources/CCadaclysmView",
                cSettings: viewDirSettings,
                linkerSettings: [.linkedLibrary("dl", .when(platforms: [.linux])),
                                 .linkedLibrary("m", .when(platforms: [.linux]))]),
        .target(name: "CadaclysmView", dependencies: ["CCadaclysmView"]),
        .target(name: "Cadaclysm",
                dependencies: ["CCadaclysm", "CadaclysmView"]
                    + (haveReaderFramework ? [.target(name: "CadaclysmCapi", condition: .when(platforms: [.iOS]))] : []),
                linkerSettings: readerLinks),
        .target(name: "Blacksmith", dependencies: ["CCadaclysmBlacksmith", "Cadaclysm", "CadaclysmView"],
                linkerSettings: kernelLinks),
        .executableTarget(name: "cadaclysm-smoke", dependencies: ["Cadaclysm", "Blacksmith"]),
        .testTarget(name: "CadaclysmTests", dependencies: ["Cadaclysm", "Blacksmith", "CadaclysmView"]),
    ] + (haveReaderFramework ? [.binaryTarget(name: "CadaclysmCapi", path: readerFramework)] : [])
)
