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
import Foundation
import PackageDescription

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let environment = ProcessInfo.processInfo.environment["CADACLYSM_LIB_DIR"].flatMap { $0.isEmpty ? nil : $0 }
let inRepository = FileManager.default.fileExists(atPath: here.appendingPathComponent("../../../../Cargo.toml").standardized.path)
    && !FileManager.default.fileExists(atPath: here.appendingPathComponent("../fetch.py").standardized.path)

let libDir = environment
    ?? (inRepository ? here.appendingPathComponent("../../../../target/release") : here.appendingPathComponent("../lib"))
        .standardized.path

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
    .unsafeFlags(["-L", libDir]),
    .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", libDir], .when(platforms: [.macOS, .linux])),
]
let kernelLinks: [LinkerSetting] = [
    .linkedLibrary("cadaclysm_blacksmith", .when(platforms: [.macOS, .linux])),
    .linkedLibrary("cadaclysm_blacksmith" + windowsSuffix, .when(platforms: [.windows])),
]

let package = Package(
    name: "Cadaclysm",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "Cadaclysm", targets: ["Cadaclysm"]),
        .library(name: "Blacksmith", targets: ["Blacksmith"]),
        .executable(name: "cadaclysm-smoke", targets: ["cadaclysm-smoke"]),
    ],
    targets: [
        .systemLibrary(name: "CCadaclysm", path: "Sources/CCadaclysm"),
        .systemLibrary(name: "CCadaclysmBlacksmith", path: "Sources/CCadaclysmBlacksmith"),
        .target(name: "Cadaclysm", dependencies: ["CCadaclysm"], linkerSettings: readerLinks),
        .target(name: "Blacksmith", dependencies: ["CCadaclysmBlacksmith", "Cadaclysm"],
                linkerSettings: kernelLinks),
        .executableTarget(name: "cadaclysm-smoke", dependencies: ["Cadaclysm", "Blacksmith"]),
        .testTarget(name: "CadaclysmTests", dependencies: ["Cadaclysm", "Blacksmith"]),
    ]
)
