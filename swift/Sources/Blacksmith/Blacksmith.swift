// The cadaclysm_blacksmith C ABI, as Swift objects: this file is the whole kernel binding.
//
//     import Blacksmith
//
//     let outline = try Profile.rect(80, 40).withHole(try Profile.circle(4))
//     let plate = try Workplane.xy().extrude(outline, 6).solid()
//     let pin = try Workplane.fromSolid(plate)
//         .faces(.max(.z)).workplane()
//         .cylinder(5, 10).solid()                   // seated over the hole, on material
//     var part = try plate.join(pin)
//     let corners = try part.edges.filter { e in   // the plate's own corners: vertical
//         guard let d = e.direction, abs(d.z) > 0.99 else { return false }   // lines
//         return try e.faces.allSatisfy { try part.faceKind($0) == "plane" }  // between planes
//     }
//     part = try part.fillet(corners, 1.0)
//     try part.step("plate.stp")
//     let mesh = try part.mesh(tolerance: 0.05)
//
// It is Python's `cadaclysm_blacksmith.py`, cased for Swift: the same types, members,
// defaults and errors. The header `cadaclysm_blacksmith.h` is imported as the Clang module
// `CCadaclysmBlacksmith`, so there are no generated bindings.
//
// Every array borrows from its solid
// ----------------------------------
// `Solid.mesh` and `Solid.edgePolylines` hand back `NativeArray` views into the library's own
// cache rather than copies. A view keeps its `Solid` alive, so it cannot outlive the solid by
// having merely dropped the last reference to it. Two things still invalidate a view:
//
// * `Solid.close()`, which frees the handle.
// * Meshing the same solid again at a *different* tolerance (`mesh`, `edgePolylines`,
//   `bounds`/`boundsAt`), which replaces the cache the earlier views point into.
//
// A view is tied to the filling of the cache it was cut from (a generation the solid
// counts), not to a tolerance: after 0.05, 0.5, 0.05 the first view's memory is gone even
// though the cache is back at its tolerance. Each filling is one `NativeMemoryOwner` the
// views share; reading an element of a stale view traps. `isValid` (or `Mesh.isStale`) asks
// first, and `copy()` gives the same type in Swift-owned memory, safe to outlive either. Strings are copied on the way out and are always safe.
//
// The chain mirrors the Rust `Workplane`
// --------------------------------------
// A build call (`cuboid`, `cylinder`, `extrude`, `revolve`, ...) makes a fresh `Solid`;
// combining two solids is explicit -- build the pin as its own solid, then
// `plate.join(pin)`. Every step throws `BuildError` at once with the library's own text.
//
// Frames
// ------
// Every call taking a frame takes a `Frame`: an origin and three unit axes, checked square
// and right-handed. `Frame.xy([0, 0, 5])` is the XY plane at z = 5, `Frame.at(point, normal)`
// the plane through a point facing a direction, and `Frame.of(solid.faceFrame(i))` a face's
// frame to read or move. An axis (`revolve`, `rotate`, `coil`) is a point and a direction,
// `(origin: SIMD3<Double>, direction: SIMD3<Double>)`.
//
// Solids from files
// -----------------
// `Solid.open("housing.step")` reads a STEP, ACIS, Rhino, BREP, IGES or IFC file's body as a
// solid through the reader module (`Cadaclysm`); `Solid.openAll` gives every body, and
// `Solid.fromNode(scene, node)` takes one node of a scene already open. The reader's brep is
// handed to this library by pointer and shared, never copied -- the solid takes a reference
// of its own, so the scene and the reader's `Brep` can go first -- and the two libraries must
// come from the same release (the call compares their `brepLayoutId()`s).
//
// `join`/`cut`/`common` default their `tolerance` to 0.05, not the tighter 1e-6 `fillet`,
// `chamfer` and `shell` use, for cost: a boolean meshes both solids at its tolerance.
//
// Points are `SIMD3<Double>` (3D) and `SIMD2<Double>` (2D, on a profile's plane) throughout;
// face and edge indices and counts are `Int`, checked into the C ABI's `uint32_t`.
// No progress callbacks: every call passes none, as every wrapper but Python does.
import CCadaclysmBlacksmith
import Cadaclysm
import Foundation

/// What the library refused, in its own words (`cadaclysm_blacksmith_last_error`).
public struct BuildError: Error, CustomStringConvertible, LocalizedError {
    /// The library's reason, or this module's where the refusal is its own.
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - The library

/// Returned by any lookup that found nothing (`CADACLYSM_BLACKSMITH_NONE`).
let none: UInt32 = .max

/// The unit codes the STEP writer takes.
private let units: [String: UInt32] = ["m": 0, "mm": 1, "in": 2]

func text(_ raw: UnsafePointer<CChar>?) -> String {
    guard let raw else { return "" }
    return String(cString: raw)
}

func lastError() -> String { text(cadaclysm_blacksmith_last_error()) }

/// The library's own reason, or `what` if it left none.
func failure(_ what: String) -> BuildError {
    let reason = lastError()
    return BuildError(reason.isEmpty ? what : reason)
}

func checked(_ handle: OpaquePointer?, _ what: String) throws -> OpaquePointer {
    guard let handle else { throw failure(what) }
    return handle
}

/// A face or edge index as the C ABI's `uint32_t`, refusing what would wrap.
func index32(_ index: Int, _ what: String) throws -> UInt32 {
    guard index >= 0, index < Int(none) else { throw BuildError("\(what): index \(index) is out of range") }
    return UInt32(index)
}

func indices32(_ indices: [Int], _ what: String) throws -> [UInt32] {
    try indices.map { try index32($0, what) }
}

/// A colour as (r, g, b) in 0..1 from `"#rgb"` or `"#rrggbb"` (the `#` optional). Shared by
/// `Profile.coloured(String)` and `Solid.coloured(String)`.
func rgb(_ colour: String) throws -> SIMD3<Double> {
    var hex = Substring(colour.trimmingCharacters(in: .whitespacesAndNewlines))
    if hex.hasPrefix("#") { hex = hex.dropFirst() }
    if hex.count == 3 || hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
        let six = hex.count == 3 ? String(hex.flatMap { [$0, $0] }) : String(hex)
        let digits = Array(six)
        let values = stride(from: 0, to: 6, by: 2).map { Double(Int(String(digits[$0...$0 + 1]), radix: 16)!) / 255 }
        return SIMD3(values[0], values[1], values[2])
    }
    throw BuildError("coloured: a colour is \"#rgb\", \"#rrggbb\" or (r, g, b) in 0..1, not '\(colour)'")
}

/// Twelve numbers, as every call taking a frame reads them.
func frameValues(_ values: [Double]) throws -> [Double] {
    guard values.count == 12 else { throw BuildError("frame: expected 12 numbers, got \(values.count)") }
    return values
}

func axisValues(_ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> [Double] {
    [axis.origin.x, axis.origin.y, axis.origin.z, axis.direction.x, axis.direction.y, axis.direction.z]
}

/// Load a license: the certificate text, or the path of a file holding it. Without this
/// call the library looks in `CADACLYSM_LICENSE`, then for `cadaclysm.lic` beside the
/// executable and in the working directory. A license that does not verify throws, and the
/// one in use (if any) stays.
public func license(_ textOrPath: String) throws {
    if !cadaclysm_blacksmith_license_set(textOrPath) { throw failure("license refused") }
}

/// One line about the license the library is running under: the license line, or, without
/// one, `"unlicensed"` (`"unlicensed -- <reason>"` when one was found but did not verify).
public func licenseInfo() -> String { text(cadaclysm_blacksmith_license_info()) }

/// How many unlicensed notices this library has printed to stderr in this process.
public func licenseNoticeCount() -> Int { Int(cadaclysm_blacksmith_license_notice_count()) }

/// When the loaded library was built, `YYYY-MM-DD`.
public func buildDate() -> String { text(cadaclysm_blacksmith_build_date()) }

/// The version of the library actually loaded, which is the one worth reporting.
public func version() -> String { text(cadaclysm_blacksmith_version()) }

/// How the loaded library lays a brep out in memory: its compiler, target and source.
/// `Solid.fromNode` works only where this equals the reader library's -- the two from the
/// same release.
public func brepLayoutId() -> String { text(cadaclysm_blacksmith_brep_layout_id()) }

/// `ap203.exp`: `CADACLYSM_SCHEMAS/ap203.exp` if set; else beside this source file; else in a
/// `schemas/` directory in any ancestor of this source file, of the executable, or of the
/// working directory, nearest first (the SDK's, beside `swift/`, or this repository's).
///
/// The file this finds is no longer needed: the kernel writes against its built-in AP203
/// when no schema is given. This stays for compatibility and the parity gates.
public func defaultSchema() throws -> String {
    var candidates: [URL] = []
    if let dir = ProcessInfo.processInfo.environment["CADACLYSM_SCHEMAS"], !dir.isEmpty {
        candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("ap203.exp"))
    }
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    candidates.append(source.appendingPathComponent("ap203.exp"))
    var roots = ancestors(source)
    if let exe = Bundle.main.executableURL { roots += ancestors(exe.deletingLastPathComponent()) }
    roots += ancestors(URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    candidates += roots.map { $0.appendingPathComponent("schemas").appendingPathComponent("ap203.exp") }
    if let found = candidates.first(where: { isFile($0.path) }) { return found.path }
    throw BuildError("ap203.exp not found (none is needed to write STEP: leave schema out for the "
        + "built-in AP203, or pass a schema name, a .exp path or EXPRESS text)")
}

private func ancestors(_ dir: URL) -> [URL] {
    var out = [dir.standardizedFileURL]
    while true {
        let parent = out[out.count - 1].deletingLastPathComponent().standardizedFileURL
        if parent.path == out[out.count - 1].path || out.count > 64 { return out }
        out.append(parent)
    }
}

private func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
}

/// `schema` as the C ABI takes it: nil (the built-in AP203); the text of the file it names,
/// when it has no newline in it and names a regular file; else the string itself (a
/// built-in schema's name or a custom schema's own EXPRESS text). NUL-terminated.
private func schemaBytes(_ schema: String?) throws -> [CChar]? {
    guard let schema else { return nil }
    if !schema.contains("\n"), isFile(schema) {
        let data = try Data(contentsOf: URL(fileURLWithPath: schema))
        return data.map { CChar(bitPattern: $0) } + [0]
    }
    return Array(schema.utf8CString)
}

/// One STEP file's text, each solid its own body. `schema` is one of four things: nil (the
/// kernel's built-in AP203); the path of a schema file (no newline in it, naming an existing
/// file), read and sent as EXPRESS text; the bare name of a built-in schema
/// (case-insensitive, e.g. `"AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"` -- an unknown
/// name throws); or a custom schema's own EXPRESS text. `unit` is `"mm"`, `"m"` or `"in"`.
public func writeStepText(_ solids: [Solid], schema: String? = nil, unit: String = "mm") throws -> String {
    guard let code = units[unit] else { throw BuildError("unit must be one of ['in', 'm', 'mm']") }
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    let schemaText = try schemaBytes(schema)
    let raw: UnsafeMutablePointer<CChar>? = withExtendedLifetime(solids) {
        if let schemaText {
            return schemaText.withUnsafeBufferPointer {
                cadaclysm_blacksmith_step(handles, handles.count, $0.baseAddress, code)
            }
        }
        return cadaclysm_blacksmith_step(handles, handles.count, nil, code)
    }
    guard let raw else { throw failure("step") }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// One STEP file (AP203 unless `schema` names another), each solid its own body, written
/// to `path` as UTF-8. `schema` and `unit` as `writeStepText` takes them.
public func writeStep(_ path: String, _ solids: [Solid], schema: String? = nil, unit: String = "mm") throws {
    let text = try writeStepText(solids, schema: schema, unit: unit)
    try text.write(toFile: path, atomically: true, encoding: .utf8)
}

/// One ACIS SAT file's text, each solid its own body: the analytic surfaces as their own
/// records, splines and swept surfaces as exact NURBS, in the layout Rhino's own exporter
/// writes. `unit` is `"mm"`, `"m"` or `"in"` and goes into the header as millimetres per unit.
public func writeSatText(_ solids: [Solid], unit: String = "mm") throws -> String {
    guard let code = units[unit] else { throw BuildError("unit must be one of ['in', 'm', 'mm']") }
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    let raw: UnsafeMutablePointer<CChar>? = withExtendedLifetime(solids) {
        cadaclysm_blacksmith_sat_text(handles, handles.count, code)
    }
    guard let raw else { throw failure("sat_text") }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// `writeSatText` written to `path` by the library itself, which names the file in its
/// refusal when it cannot.
public func writeSat(_ path: String, _ solids: [Solid], unit: String = "mm") throws {
    guard let code = units[unit] else { throw BuildError("unit must be one of ['in', 'm', 'mm']") }
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    let ok = withExtendedLifetime(solids) {
        cadaclysm_blacksmith_sat(handles, handles.count, path, code)
    }
    guard ok else { throw failure("sat") }
}

/// One OCCT `.brep` file's text, each solid its own solid under one compound (one solid is
/// the file's root): the exact surfaces and curves, with a curve in each face's own
/// parameters for every edge, so OCCT's `BRepTools::Read` gives a shape
/// `BRepCheck_Analyzer` finds valid. No unit is declared -- a `.brep` carries none -- so
/// the numbers are the numbers.
public func writeBrepText(_ solids: [Solid]) throws -> String {
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    let raw: UnsafeMutablePointer<CChar>? = withExtendedLifetime(solids) {
        cadaclysm_blacksmith_brep_text(handles, handles.count)
    }
    guard let raw else { throw failure("brep_text") }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// `writeBrepText` written to `path` by the library itself.
public func writeBrep(_ path: String, _ solids: [Solid]) throws {
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    let ok = withExtendedLifetime(solids) { cadaclysm_blacksmith_brep(handles, handles.count, path) }
    guard ok else { throw failure("brep") }
}

// MARK: - SVG

/// `options` packed into a `CadaclysmBlacksmithSvgOptions` -- as `Cadaclysm`'s own reader-side
/// packing, but with no scene to default `up` from: a solid carries no convention of its own,
/// so `options.up` falls back to `.z` rather than a scene's.
func buildSvgOptions(_ options: SvgOptions) -> CadaclysmBlacksmithSvgOptions {
    var raw = CadaclysmBlacksmithSvgOptions()
    cadaclysm_blacksmith_svg_options_init(&raw)
    let (baseAzimuth, baseElevation) = options.view.angles
    raw.up = (options.up ?? .z) == .y ? 1 : 0
    raw.azimuth = options.azimuth ?? baseAzimuth
    raw.elevation = options.elevation ?? baseElevation
    raw.fov = options.fov
    raw.width = options.width
    raw.height = options.height
    raw.margin = options.margin
    raw.tolerance = options.tolerance
    raw.stroke_width = options.strokeWidth
    raw.stroke = options.stroke
    raw.background = options.background ?? svgTransparent
    raw.flags = (options.edges ? UInt32(1) : 0) | (options.curves ? UInt32(2) : 0)
        | (options.isocurves ? UInt32(4) : 0) | (options.polylines ? UInt32(8) : 0)
    return raw
}

/// Several solids' wireframe as one SVG's text, each its own `<g>` -- see `Cadaclysm.SvgOptions`.
/// Keeps calling the solids-only pair rather than the widened `writeSvgText(_:_:options:)`
/// below with an empty profile list: this package's own coverage test
/// (`cadaclysm-capi/tests/bindings.rs`) reads an entry point as declared only where it is
/// actually called, so `cadaclysm_blacksmith_svg_text` needs a real call of its own here --
/// unlike Python and Node, which declare every entry point in a table independent of
/// whether it is still called. The two pairs refuse in identical words either way.
public func writeSvgText(_ solids: [Solid], options: SvgOptions = SvgOptions()) throws -> String {
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    var cOptions = buildSvgOptions(options)
    let raw: UnsafeMutablePointer<CChar>? = withExtendedLifetime(solids) {
        withUnsafePointer(to: &cOptions) { cadaclysm_blacksmith_svg_text(handles, handles.count, $0) }
    }
    guard let raw else { throw failure("svg_text") }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// `writeSvgText` written to `path` by the library itself. Kept calling the solids-only
/// pair, for the same reason `writeSvgText` above does -- see its comment.
public func writeSvg(_ path: String, _ solids: [Solid], options: SvgOptions = SvgOptions()) throws {
    let handles: [OpaquePointer?] = try solids.map { try $0.h() }
    var cOptions = buildSvgOptions(options)
    let ok = withExtendedLifetime(solids) {
        withUnsafePointer(to: &cOptions) { cadaclysm_blacksmith_svg(handles, handles.count, path, $0) }
    }
    guard ok else { throw failure("svg") }
}

/// Several solids' and profiles' wireframe as one SVG's text: a `<g id="solid-N">` per
/// solid then a `<g id="profile-N">` per profile, on one page, each its own colour where
/// it carries one and the options' `stroke` otherwise. Either list may be empty; both
/// empty is refused. See `Cadaclysm.SvgOptions`.
public func writeSvgText(_ solids: [Solid], _ profiles: [Profile], options: SvgOptions = SvgOptions()) throws -> String {
    let solidHandles: [OpaquePointer?] = try solids.map { try $0.h() }
    let profileHandles: [OpaquePointer?] = profiles.map { $0.handle }
    var cOptions = buildSvgOptions(options)
    let raw: UnsafeMutablePointer<CChar>? = withExtendedLifetime(solids) {
        withExtendedLifetime(profiles) {
            withUnsafePointer(to: &cOptions) {
                cadaclysm_blacksmith_drawing_svg_text(solidHandles, solidHandles.count, profileHandles, profileHandles.count, $0)
            }
        }
    }
    guard let raw else { throw failure("svg_text") }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// `writeSvgText(_:_:options:)` written to `path` by the library itself.
public func writeSvg(_ path: String, _ solids: [Solid], _ profiles: [Profile], options: SvgOptions = SvgOptions()) throws {
    let solidHandles: [OpaquePointer?] = try solids.map { try $0.h() }
    let profileHandles: [OpaquePointer?] = profiles.map { $0.handle }
    var cOptions = buildSvgOptions(options)
    let ok = withExtendedLifetime(solids) {
        withExtendedLifetime(profiles) {
            withUnsafePointer(to: &cOptions) {
                cadaclysm_blacksmith_drawing_svg(solidHandles, solidHandles.count, profileHandles, profileHandles.count, path, $0)
            }
        }
    }
    guard ok else { throw failure("svg") }
}

// MARK: - Views into a solid's cache

/// The owner of every view cut from one filling of a solid's tessellation cache: it holds the
/// solid, so a view keeps it alive, and gives the memory back -- every read of a view then
/// traps -- once the solid is closed or its cache is filled again at another tolerance.
final class CacheFilling: NativeMemoryOwner {
    let solid: Solid
    let generation: Int

    init(_ solid: Solid, _ generation: Int) {
        self.solid = solid
        self.generation = generation
    }

    var nativeMemoryInvalidReason: String? {
        if solid.isClosed { return "the solid is closed" }
        if !solid.cacheHolds(generation) {
            return "the solid was meshed again at another tolerance (now \(solid.cacheTolerance.map { "\($0)" } ?? "none"))"
        }
        return nil
    }
}

/// A solid's triangles at one tolerance: `positions` and `normals` three floats a vertex,
/// `indices` three to a triangle -- `NativeArray` views into the solid's cache, which keep the
/// solid alive and trap when read after it is closed or meshed again at another tolerance.
public struct Mesh {
    /// The tolerance this was meshed at.
    public let tolerance: Double
    /// Vertex positions, three floats each.
    public let positions: NativeArray<Float>
    /// Vertex normals, three floats each, unit, outward.
    public let normals: NativeArray<Float>
    /// Three indices into `positions` per triangle.
    public let indices: NativeArray<UInt32>

    /// How many vertices.
    public var vertexCount: Int { positions.count / 3 }
    /// How many indices, three to a triangle.
    public var indexCount: Int { indices.count }
    /// `indexCount / 3`.
    public var triangleCount: Int { indices.count / 3 }
    /// Whether the solid has closed or replaced the cache this reads since: every read traps
    /// then. Never after `copy()`.
    public var isStale: Bool { !positions.isValid || !indices.isValid }

    /// The same triangles in memory of our own, safe to outlive the solid.
    public func copy() -> Mesh {
        Mesh(tolerance: tolerance, positions: positions.copy(), normals: normals.copy(), indices: indices.copy())
    }
}

/// `Mesh` in `double`: the same tessellation `mesh(tolerance:)` narrows -- the very same
/// index buffer, positions and normals unnarrowed. `NativeArray` views into the solid's
/// cache, under `Mesh`'s own rule: valid until the solid is closed or meshed again at
/// another tolerance (the same cache, so meshing through either view refills it).
public struct Mesh64 {
    /// The tolerance this was meshed at.
    public let tolerance: Double
    /// Vertex positions, three doubles each.
    public let positions: NativeArray<Double>
    /// Vertex normals, three doubles each, unit, outward.
    public let normals: NativeArray<Double>
    /// Three indices into `positions` per triangle -- the same buffer `mesh(tolerance:)`'s
    /// `indices` view is cut from.
    public let indices: NativeArray<UInt32>

    /// How many vertices.
    public var vertexCount: Int { positions.count / 3 }
    /// How many indices, three to a triangle.
    public var indexCount: Int { indices.count }
    /// `indexCount / 3`.
    public var triangleCount: Int { indices.count / 3 }
    /// Whether the solid has closed or replaced the cache this reads since: every read traps
    /// then. Never after `copy()`.
    public var isStale: Bool { !positions.isValid || !indices.isValid }

    /// The same triangles in memory of our own, safe to outlive the solid.
    public func copy() -> Mesh64 {
        Mesh64(tolerance: tolerance, positions: positions.copy(), normals: normals.copy(), indices: indices.copy())
    }
}

/// A solid's feature edges as polylines at one tolerance, one run of points per edge:
/// element `i` is polyline `i`, three floats a point -- what Python's list holds at `i`.
/// Views into the solid's cache, under `Mesh`'s rule.
public struct Polylines: RandomAccessCollection {
    /// The tolerance these were meshed at.
    public let tolerance: Double
    /// Every polyline's points end to end, three floats each.
    public let points: NativeArray<Float>
    /// `count + 1` point offsets; polyline `i` is points `offsets[i] ..< offsets[i + 1]`.
    public let offsets: NativeArray<UInt32>
    /// How many polylines.
    public let count: Int

    public var startIndex: Int { 0 }
    public var endIndex: Int { count }

    /// Polyline `i`'s points, three floats each: a view under the same owner as `points`.
    public subscript(position: Int) -> NativeArray<Float> {
        precondition(position >= 0 && position < count, "Polylines: index \(position) out of range 0..<\(count)")
        let from = Int(offsets[position]) * 3
        let length = Int(offsets[position + 1]) * 3 - from
        // The pointer outlives the closure legitimately: the new view holds the same owner,
        // and checks it before every read, as `points` does.
        return points.withUnsafeBufferPointer { run in
            NativeArray(owner: points.owner, base: run.baseAddress.map { $0 + from }, count: length)
        }
    }

    /// How many points, across every polyline.
    public var pointCount: Int { points.count / 3 }
    /// Whether the solid has closed or replaced the cache this reads since.
    public var isStale: Bool { !offsets.isValid }

    /// The same polylines in memory of our own, safe to outlive the solid.
    public func copy() -> Polylines {
        Polylines(tolerance: tolerance, points: points.copy(), offsets: offsets.copy(), count: count)
    }
}

// MARK: - Profiles

/// A closed outline with holes, in its own x/y -- what gets extruded, revolved, lofted or
/// swept. Immutable; every method returns a new one.
public final class Profile {
    let handle: OpaquePointer

    init(_ raw: OpaquePointer?, _ what: String = "profile") throws {
        handle = try checked(raw, what)
    }

    deinit { cadaclysm_blacksmith_profile_free(handle) }

    /// A `w` x `h` rectangle centred on the origin.
    public static func rect(_ w: Double, _ h: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_rect(w, h))
    }

    /// A circle of radius `r` about the origin.
    public static func circle(_ r: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_circle(r))
    }

    /// A slot (stadium) `length` long overall with end radius `r`, centred on `centre` and
    /// running along x. `length` must exceed `2 * r`.
    public static func slot(_ centre: SIMD2<Double>, _ length: Double, _ r: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_slot(centre.x, centre.y, length, r))
    }

    /// A closed polygon through `points`, in order, its side back to the first point a
    /// segment of its own. At least three points.
    public static func polygon(_ points: [SIMD2<Double>]) throws -> Profile {
        let flat = points.flatMap { [$0.x, $0.y] }
        return try Profile(cadaclysm_blacksmith_profile_polygon(flat, points.count))
    }

    /// A regular polygon of `sides` sides (at least 3) on the circle of `radius` about
    /// `centre`, its first corner at `angle` radians from the sketch's x axis, the rest
    /// counter-clockwise.
    public static func regularPolygon(_ centre: SIMD2<Double>, _ radius: Double, _ sides: Int,
                                      angle: Double = 0.0) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_regular_polygon(centre.x, centre.y, radius,
                                                                 UInt32(clamping: sides), angle))
    }

    /// A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its
    /// inner corners on the circle of `inner` (positive, under `outer`), alternating: the
    /// first tip at `angle` radians from the sketch's x axis, the rest counter-clockwise.
    public static func star(_ centre: SIMD2<Double>, _ outer: Double, _ inner: Double, _ points: Int,
                            angle: Double = 0.0) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_star(centre.x, centre.y, outer, inner,
                                                      UInt32(clamping: points), angle))
    }

    /// A spline of `degree` through the control polygon `points` (`weights` one per point, or
    /// nil). Open, it starts on the first point and ends on the last -- an open chain;
    /// `closed`, it is periodic, smooth through its own start -- a closed profile. The degree
    /// is lowered to fit the points. Throws for a degree of zero, too few points (two open,
    /// three closed), or a weight not positive.
    public static func spline(_ points: [SIMD2<Double>], degree: Int = 3, weights: [Double]? = nil,
                              closed: Bool = false) throws -> Profile {
        let flat = points.flatMap { [$0.x, $0.y] }
        let d = UInt32(clamping: degree)
        // The library reads exactly one weight per point, whatever the array holds.
        if let weights, weights.count != points.count {
            throw BuildError("spline: \(weights.count) weights for \(points.count) points; give one per point")
        }
        guard let weights else {
            return try Profile(cadaclysm_blacksmith_profile_spline(flat, points.count, d, nil, closed))
        }
        return try Profile(cadaclysm_blacksmith_profile_spline(flat, points.count, d, weights, closed))
    }

    /// Start drawing an outline segment by segment at `start`; see `Path`.
    public static func path(_ start: SIMD2<Double>) throws -> Path {
        try Path(start)
    }

    /// Start drawing on the arc of the parabola with `vertex`, axis direction `axis` and
    /// focal length `focal`, over the across-axis coordinates `from...to`: the path begins
    /// at the arc's first point and holds the arc -- a reflector from rim to rim,
    /// `Profile.parabola(vertex: [0, 0], axis: [0, 1], focal: 20, from: -50, to: 50)` a
    /// dish 100 wide opening up.
    public static func parabola(vertex: SIMD2<Double>, axis: SIMD2<Double>, focal: Double,
                                from: Double, to: Double) throws -> Path {
        try Path(parabola: cadaclysm_blacksmith_path_parabola(vertex.x, vertex.y, axis.x, axis.y, focal, from, to))
    }

    /// Open profiles joined end to end into one -- the forge's merge. The pieces (paths ended
    /// open) may come in any order and either way round: each next one is the first of the
    /// rest with an end within `tolerance` of either end of the chain so far, reversed where
    /// that makes it meet. Every segment is kept exactly. Closed where the chain's two ends
    /// meet, otherwise an open chain. Throws for no pieces, a piece empty, with holes or
    /// closed on its own, or one that meets none of the others, named by its index.
    public static func chain(_ pieces: [Profile], tolerance: Double = 1e-6) throws -> Profile {
        let handles: [OpaquePointer?] = pieces.map { $0.handle }
        return try withExtendedLifetime(pieces) {
            try Profile(cadaclysm_blacksmith_profile_chain(handles, handles.count, tolerance))
        }
    }

    /// Closed loops, in any order, as one profile: the loop enclosing the most area is the
    /// boundary and every other a hole in it, in the order given. Each loop is a closed
    /// profile with no holes of its own, wound either way. Throws, naming loops by their
    /// index, for a loop that is open, empty or of no area, loops that cross or touch, a hole
    /// outside the boundary, or one inside another hole.
    public static func fromLoops(_ loops: [Profile]) throws -> Profile {
        let handles: [OpaquePointer?] = loops.map { $0.handle }
        return try withExtendedLifetime(loops) {
            try Profile(cadaclysm_blacksmith_profile_from_loops(handles, handles.count))
        }
    }

    /// This profile closed -- the forge's sketch "close": where its last segment stops short
    /// of its start (a path ended open), a straight segment back to it; where it already
    /// comes back to within 1e-9 of its extent, its last segment made to land on the start
    /// exactly. A closed profile comes back as it is. Holes are closed the same way.
    public func closeLoop() throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_close_loop(handle))
    }

    /// This curve cut where the `cutters` cross, touch or run along it -- the sketch trim's
    /// pieces: in order along the curve from its start, each an open profile of portions of
    /// this one's own segments (a line's stretch a line, an arc's an arc, a spline's the same
    /// spline over part of its domain). One piece, this curve, where nothing cuts it; a closed
    /// curve's piece round its start is one piece. Cuts closer than `tolerance` to each other
    /// fold onto one.
    public func pieces(_ cutters: [Profile], tolerance: Double = 1e-6) throws -> [Profile] {
        let handles: [OpaquePointer?] = cutters.map { $0.handle }
        return try withExtendedLifetime(cutters) {
            let n = cadaclysm_blacksmith_profile_piece_count(handle, handles, handles.count, tolerance)
            if n == 0 { throw failure("profile_piece_count") }
            return try (0..<n).map { try Profile(cadaclysm_blacksmith_profile_piece(handle, handles, handles.count, $0, tolerance)) }
        }
    }

    /// This curve with piece `piece` of `pieces` taken away -- the sketch trim: what is left,
    /// as open profiles. One for a closed curve (its other pieces run together from where the
    /// removed one ended), the stretches before and after for an open one, none where the
    /// piece was the whole curve. Throws for a piece the curve does not have.
    public func trim(_ cutters: [Profile], piece: UInt32, tolerance: Double = 1e-6) throws -> [Profile] {
        let handles: [OpaquePointer?] = cutters.map { $0.handle }
        return try withExtendedLifetime(cutters) {
            let n = cadaclysm_blacksmith_profile_trim_count(handle, handles, handles.count, piece, tolerance)
            if n == 0 && !lastError().isEmpty { throw failure("profile_trim_count") }
            return try (0..<n).map { try Profile(cadaclysm_blacksmith_profile_trim_chain(handle, handles, handles.count, piece, $0, tolerance)) }
        }
    }

    /// This outline with `hole` cut out of it.
    public func withHole(_ hole: Profile) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_with_hole(handle, hole.handle))
    }

    /// This outline moved by (`dx`, `dy`).
    public func translate(_ dx: Double, _ dy: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_translate_profile(handle, dx, dy))
    }

    /// This outline coloured (r, g, b), each in 0..1: how it is drawn. The verbs that make a
    /// profile from one carry it; a solid made from it takes nothing.
    public func coloured(_ colour: SIMD3<Double>) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_coloured(handle, colour.x, colour.y, colour.z))
    }

    /// `coloured` with `"#rgb"` or `"#rrggbb"`.
    public func coloured(_ colour: String) throws -> Profile { try coloured(try rgb(colour)) }

    /// The outline's colour, (r, g, b) in 0..1, or nil.
    public var colour: SIMD3<Double>? {
        get throws {
            var out = [Double](repeating: 0, count: 3)
            if cadaclysm_blacksmith_profile_colour(handle, &out) { return SIMD3(out[0], out[1], out[2]) }
            if !lastError().isEmpty { throw failure("profile_colour") }
            return nil
        }
    }

    /// Where this profile's curves cross, touch or run along `other`'s, both read in one
    /// plane, as `Hit` values ordered along this profile. Points closer than `tolerance`
    /// merge; two curves within `tolerance` of each other for longer than it are one run
    /// when they part only where one ends or the stretch is flat -- one curve following the
    /// other, offset within `tolerance` or tilted by under about half of it, even where it
    /// leaves mid-both; a tangency or a shallow crossing is one point. A loop that stops
    /// short of its start is an open chain.
    public func hits(_ other: Profile, tolerance: Double = 1e-6) throws -> [Hit] {
        guard let found = cadaclysm_blacksmith_profile_hits(handle, other.handle, tolerance) else {
            throw failure("profile_hits")
        }
        defer { cadaclysm_blacksmith_hits_free(found) }
        let n = cadaclysm_blacksmith_hit_count(found)
        var out: [Hit] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            var raw = CadaclysmBlacksmithHit()
            if !cadaclysm_blacksmith_hit(found, i, &raw) { throw failure("hit") }
            out.append(Hit(raw))
        }
        return out
    }

    /// The region this profile and `other` share, both read in one plane, as zero or more
    /// profiles -- each boundary counter-clockwise, each hole clockwise, arcs and splines
    /// kept exact. Both must be closed and simple. No shared area is an empty array. Throws
    /// for a `tolerance` not positive and finite, or a profile open or crossing itself.
    public func common(_ other: Profile, tolerance: Double = 1e-6) throws -> [Profile] {
        try Profile.list(cadaclysm_blacksmith_profile_common(handle, other.handle, tolerance), "profile_common")
    }

    /// `text` set in a font, one profile per closed shape -- a letter with its counters as
    /// holes (`o` one, `8` two; `i` is two profiles) -- on the sketch plane, the baseline
    /// along x from the origin, each outline counter-clockwise and its holes clockwise, a
    /// curved side the font's own cubic Bezier kept exactly: an extruded `O` has curved
    /// walls. `size` is roughly the height of a capital. `font` is a family, optionally with
    /// a style (`"Liberation Sans:style=Bold"`), a font file's path, or empty for the bundled
    /// Liberation Sans Regular -- which also serves when the family is not found;
    /// `fontBytes` a font file's bytes, used instead of `font` when given. `halign` is
    /// "left", "center" or "right"; `valign` "baseline", "bottom", "center" or "top";
    /// `spacing` multiplies the gap between glyphs; `direction` "ltr" or "rtl". Empty text
    /// is an empty array. Throws for a size or spacing not positive and finite, an alignment
    /// or direction not one of those words, font bytes that are not a font.
    public static func text(_ text: String, size: Double = 10, font: String = "", halign: String = "left",
                            valign: String = "baseline", spacing: Double = 1, direction: String = "ltr",
                            fontBytes: [UInt8]? = nil) throws -> [Profile] {
        let raw: OpaquePointer?
        if let fontBytes {
            raw = fontBytes.withUnsafeBufferPointer { bytes in
                cadaclysm_blacksmith_profile_text(text, size, font, bytes.baseAddress, bytes.count, halign, valign, spacing, direction)
            }
        } else {
            raw = cadaclysm_blacksmith_profile_text(text, size, font, nil, 0, halign, valign, spacing, direction)
        }
        return try Profile.list(raw, "profile_text")
    }

    /// The profiles of a list the library handed back (nil: throw), each a handle of its
    /// own, the list freed.
    private static func list(_ raw: OpaquePointer?, _ what: String) throws -> [Profile] {
        guard let list = raw else {
            throw failure(what)
        }
        defer { cadaclysm_blacksmith_profile_list_free(list) }
        let n = cadaclysm_blacksmith_profile_list_count(list)
        return try (0..<n).map { try Profile(cadaclysm_blacksmith_profile_list_get(list, $0)) }
    }

    /// This profile with its corners rounded by `radius`: where two straight segments meet,
    /// both are cut back and an exact arc tangent to both put between them. A corner next to
    /// an arc or a spline is left as it is. `corners` nil rounds every such corner, the
    /// holes' too; a list picks corners of the boundary alone -- corner `k` is where segment
    /// `k` ends. `open` reads the profile as an open chain (from `Path.endOpen`): its two
    /// ends stay square. Throws naming the corner or segment the radius does not fit.
    public func round(_ radius: Double, corners: [Int]? = nil, open isOpen: Bool = false) throws -> Profile {
        guard let corners else {
            return try Profile(cadaclysm_blacksmith_profile_round(handle, radius, nil, 0, isOpen))
        }
        let picked = try indices32(corners, "round")
        return try Profile(cadaclysm_blacksmith_profile_round(handle, radius, picked, picked.count, isOpen))
    }

    /// The kernel's `profile_polylines`, kept for the viewer follow-up (as Go keeps it): the
    /// outline then each hole as polylines at z = 0 within `tolerance`, one run of x, y, z
    /// floats per loop, copied out -- the library's arrays belong to the profile and go stale
    /// when it is asked again at another tolerance.
    func outlineRuns(tolerance: Double) throws -> [[Float]] {
        try withExtendedLifetime(self) { () throws -> [[Float]] in
            let raw = cadaclysm_blacksmith_profile_polylines(handle, tolerance)
            guard let offsets = raw.offsets else { throw failure("profile_polylines") }
            return (0..<Int(raw.polyline_count)).map { (i: Int) -> [Float] in
                let from = Int(offsets[i]) * 3, to = Int(offsets[i + 1]) * 3
                guard let points = raw.points, to > from else { return [] }
                return Array(UnsafeBufferPointer(start: points + from, count: to - from))
            }
        }
    }

    /// This profile's own loops as SVG text, from directly above by default -- a sketch lies
    /// in z = 0, so its own plane already is the page, unlike a solid's `Solid.svgText`
    /// (`.iso`), which has no plane of its own to prefer. Passing `options` at all -- even one
    /// left at its own defaults -- opts out of the top default and uses `view` as given, the
    /// same way a caller of `SvgOptions` controls a solid's. See `writeSvgText(_:_:options:)`.
    public func svgText(_ options: SvgOptions = SvgOptions(view: .top)) throws -> String {
        try writeSvgText([], [self], options: options)
    }

    /// `svgText` written to `path` by the library itself; see `svgText` for the top default.
    public func svg(_ path: String, options: SvgOptions = SvgOptions(view: .top)) throws {
        try writeSvg(path, [], [self], options: options)
    }
}

/// An outline drawn a segment at a time -- lines, arcs, Beziers, NURBS -- then closed into a
/// `Profile` by `end()`, which consumes the builder (as `endOpen()` does). Every step returns
/// the path itself, so the calls chain.
public final class Path {
    private var handle: OpaquePointer?

    /// Start an outline at `start`.
    public init(_ start: SIMD2<Double>) throws {
        handle = try checked(cadaclysm_blacksmith_path_begin(start.x, start.y), "path_begin")
    }

    /// Wraps the handle `path_parabola` returned, or throws its refusal.
    init(parabola raw: OpaquePointer?) throws {
        handle = try checked(raw, "path_parabola")
    }

    deinit {
        if let handle { cadaclysm_blacksmith_path_free(handle) }
    }

    private func live() throws -> OpaquePointer {
        guard let handle else { throw BuildError("path: already ended") }
        return handle
    }

    private func step(_ ok: Bool, _ what: String) throws -> Path {
        if !ok { throw failure(what) }
        return self
    }

    /// A straight segment to (`x`, `y`).
    @discardableResult
    public func lineTo(_ x: Double, _ y: Double) throws -> Path {
        try step(cadaclysm_blacksmith_path_line_to(try live(), x, y), "path_line_to")
    }

    /// A circular arc to (`x`, `y`) about `centre`, counter-clockwise unless `ccw` is false.
    @discardableResult
    public func arcTo(_ x: Double, _ y: Double, _ centre: SIMD2<Double>, ccw: Bool = true) throws -> Path {
        try step(cadaclysm_blacksmith_path_arc_to(try live(), x, y, centre.x, centre.y, ccw), "path_arc_to")
    }

    /// A cubic Bezier through control points `c1`, `c2` to `to`.
    @discardableResult
    public func bezierTo(_ c1: SIMD2<Double>, _ c2: SIMD2<Double>, _ to: SIMD2<Double>) throws -> Path {
        try step(cadaclysm_blacksmith_path_bezier_to(try live(), c1.x, c1.y, c2.x, c2.y, to.x, to.y), "path_bezier_to")
    }

    /// A conic arc to (`x`, `y`) through the control point `control` with middle weight
    /// `weight`: under 1 an elliptical arc, 1 a parabola, over 1 a hyperbola -- the rational
    /// quadratic Bezier, kept exact.
    @discardableResult
    public func conicTo(_ x: Double, _ y: Double, control: SIMD2<Double>, weight: Double) throws -> Path {
        try step(cadaclysm_blacksmith_path_conic_to(try live(), x, y, control.x, control.y, weight), "path_conic_to")
    }

    /// A parabolic arc to (`x`, `y`) whose end tangents meet at `control`: `conicTo` with
    /// weight 1.
    @discardableResult
    public func parabolaTo(_ x: Double, _ y: Double, control: SIMD2<Double>) throws -> Path {
        try conicTo(x, y, control: control, weight: 1.0)
    }

    /// A hyperbolic arc to (`x`, `y`) through `control` with middle `weight` over 1.
    @discardableResult
    public func hyperbolaTo(_ x: Double, _ y: Double, control: SIMD2<Double>, weight: Double) throws -> Path {
        let h = try live()
        if !(weight > 1.0) {
            throw BuildError("hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)")
        }
        return try step(cadaclysm_blacksmith_path_conic_to(h, x, y, control.x, control.y, weight), "path_conic_to")
    }

    /// The parabolic arc to (`x`, `y`) with `vertex`: its axis and focal length solved from
    /// the two ends. Throws when no parabola with that vertex passes through both.
    @discardableResult
    public func parabolaByVertex(_ x: Double, _ y: Double, vertex: SIMD2<Double>) throws -> Path {
        try step(cadaclysm_blacksmith_path_parabola_by_vertex(try live(), x, y, vertex.x, vertex.y), "path_parabola_by_vertex")
    }

    /// The parabolic arc to (`x`, `y`) with `focus`: of the two through the ends, the one
    /// whose vertex lies between the ends' projections, then the one whose arc cups the
    /// focus (the focus between the arc and its chord), then the more symmetric; with the
    /// focus beyond the chord that is the arch over the ends, not the shallow dish -- draw
    /// that one with `Profile.parabola`.
    @discardableResult
    public func parabolaByFocus(_ x: Double, _ y: Double, focus: SIMD2<Double>) throws -> Path {
        try step(cadaclysm_blacksmith_path_parabola_by_focus(try live(), x, y, focus.x, focus.y), "path_parabola_by_focus")
    }

    /// A NURBS segment. `control`: every control point after the current one, the endpoint
    /// last; `knots`: the full repeated knot vector; `weights`: one per control point
    /// *including* the current one, or nil for a non-rational curve.
    @discardableResult
    public func nurbsTo(_ control: [SIMD2<Double>], _ knots: [Double], _ degree: Int,
                        weights: [Double]? = nil) throws -> Path {
        let h = try live()
        let flat = control.flatMap { [$0.x, $0.y] }
        let d = UInt32(clamping: degree)
        // The library reads one weight per control point plus the current point's.
        if let weights, weights.count != control.count + 1 {
            throw BuildError("nurbs_to: \(weights.count) weights for \(control.count + 1) control points "
                             + "(the current point and \(control.count) given); give one per point")
        }
        let ok: Bool
        if let weights {
            ok = cadaclysm_blacksmith_path_nurbs_to(h, flat, control.count, weights, knots, knots.count, d)
        } else {
            ok = cadaclysm_blacksmith_path_nurbs_to(h, flat, control.count, nil, knots, knots.count, d)
        }
        return try step(ok, "path_nurbs_to")
    }

    /// The path as it stands, without closing it: an open chain for `Solid.extrudeOpen`,
    /// `Solid.sweepOpen` or `Solid.loftOpen` (a closed sweep closes it with a straight side).
    /// Consumes the builder as `end` does.
    public func endOpen() throws -> Profile {
        let h = try live()
        handle = nil   // consumed whether or not the call succeeds
        return try Profile(cadaclysm_blacksmith_path_end_open(h))
    }

    /// Close the outline back to its start and return the `Profile`, consuming the builder
    /// whether or not it succeeds. Throws unless the last segment ends at the start.
    public func end() throws -> Profile {
        let h = try live()
        handle = nil   // consumed whether or not the call succeeds
        return try Profile(cadaclysm_blacksmith_path_end(h))
    }
}

/// A 3D path a profile is carried along -- lines and arcs, a point at a time -- for
/// `Solid.sweep`, `Solid.sweepOpen` and `Solid.pipe`. Those only *borrow* it, so one path can
/// be swept many times, open or closed. Free it with `close()` (or let `deinit` do it).
public final class SweepPath {
    private var handle: OpaquePointer?

    /// Start a path at the 3D point `at`.
    public init(_ at: SIMD3<Double>) throws {
        handle = try checked(cadaclysm_blacksmith_sweep_path_begin(at.x, at.y, at.z), "sweep_path_begin")
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { close() }

    /// Start a path at a 3D point: `SweepPath(point)`.
    public static func at(_ point: SIMD3<Double>) throws -> SweepPath {
        try SweepPath(point)
    }

    /// The path the 2D chain `curve` (usually `Path.endOpen()`) draws on `frame`: a line a
    /// straight piece, an arc a circular one, and a Bezier or spline fitted with biarcs --
    /// arcs tangent to each other and to the curve -- until each stays within `tolerance` of
    /// it, so the path is tangent throughout and every wall swept along it exact. `open`
    /// false closes the path back to its start along the side a profile leaves implicit.
    public static func along(_ curve: Profile, _ frame: Frame, tolerance: Double = 0.05,
                             open isOpen: Bool = true) throws -> SweepPath {
        let raw = cadaclysm_blacksmith_sweep_path_along(curve.handle, frame.values, tolerance, isOpen)
        return SweepPath(handle: try checked(raw, "sweep_path_along"))
    }

    func live() throws -> OpaquePointer {
        guard let handle else { throw BuildError("sweep_path: closed") }
        return handle
    }

    private func step(_ ok: Bool, _ what: String) throws -> SweepPath {
        if !ok { throw failure(what) }
        return self
    }

    /// A straight piece to the 3D point `point`.
    @discardableResult
    public func lineTo(_ point: SIMD3<Double>) throws -> SweepPath {
        try step(cadaclysm_blacksmith_sweep_path_line_to(try live(), point.x, point.y, point.z), "sweep_path_line_to")
    }

    /// Turn `angle` radians about the axis through `centre` with direction `axis` (need not
    /// be unit); `angle` must be in `(0, 2 pi]`.
    @discardableResult
    public func arc(_ centre: SIMD3<Double>, _ axis: SIMD3<Double>, _ angle: Double) throws -> SweepPath {
        let ok = cadaclysm_blacksmith_sweep_path_arc(try live(), centre.x, centre.y, centre.z,
                                                     axis.x, axis.y, axis.z, angle)
        return try step(ok, "sweep_path_arc")
    }

    /// Free the path. Idempotent; sweeping a closed path throws.
    public func close() {
        if let handle { cadaclysm_blacksmith_sweep_path_free(handle) }
        handle = nil
    }
}

/// A plane a sweep starts or ends on, read as a height over the sketch plane at each point:
/// `at + grad · p`. Flat (`grad` zero) for `extrude`'s own caps; sloped for a mitre. A bare
/// number literal is a flat one: `Solid.extrudeBetween(p, f, 0, Slant(6, grad: [0.25, 0]))`.
public struct Slant: Equatable, CustomStringConvertible, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral {
    /// The height at the sketch origin.
    public var at: Double
    /// The slope in x and y.
    public var grad: SIMD2<Double>

    /// The plane at height `at` over the sketch origin, sloping by `grad`.
    public init(_ at: Double, grad: SIMD2<Double> = .zero) {
        self.at = at
        self.grad = grad
    }

    public init(floatLiteral value: Double) { self.init(value) }
    public init(integerLiteral value: Int) { self.init(Double(value)) }

    /// A flat plane at height `at`.
    public static func flat(_ at: Double) -> Slant { Slant(at) }

    /// The plane through `point` square to `normal`, read as heights over `frame`. Throws
    /// when the plane holds the sweep direction itself (`normal` square to `frame`'s z), so
    /// no height is on it.
    public static func ofPlane(_ frame: Frame, _ point: SIMD3<Double>, _ normal: SIMD3<Double>) throws -> Slant {
        var out = [Double](repeating: 0, count: 3)
        let p = [point.x, point.y, point.z]
        let n = [normal.x, normal.y, normal.z]
        if !cadaclysm_blacksmith_slant_of_plane(frame.values, p, n, &out) { throw failure("slant_of_plane") }
        return Slant(out[0], grad: SIMD2(out[1], out[2]))
    }

    var raw: [Double] { [at, grad.x, grad.y] }

    public var description: String { "Slant(\(at), (\(grad.x), \(grad.y)))" }
}

// MARK: - The FEM surface mesh

/// One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks. The
/// numbers are copied out; `nodes` and `runs` are `NativeArray` views borrowed from the `FemMesh`,
/// as its own arrays are, and go with it.
///
/// `nodes` are this mesh's node indices in order along the edge, its end vertices included; a
/// closed edge repeats no node. **`runs` says where the chain breaks**: read
/// `nodes[runs[i] ..< runs[i + 1]]` (the last run to the end) as one polyline and join nothing
/// across a boundary -- the two ends either side of one are two points of the edge with no mesh
/// edge between them. `[0]` is the ordinary answer, and reading `nodes` as one polyline without
/// looking here jumps the gap silently.
///
/// `faces` is `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of each `UInt32.max`
/// (the ABI's NONE) where there is none -- an open body's rim, or both ends at one vertex.
/// **`0` is a real face and a real vertex, not a sentinel.** Which end comes first is the first
/// trim's direction and means nothing else: the pair bounds the edge, it does not orient it.
public struct FemEdge {
    /// The **body's own** edge id -- not this mesh's edge index. `FemMesh.edges` is a densely
    /// renumbered subset of the solid's edges, ascending by id, with every edge collapsed to a
    /// point left out. Everything else here that names an edge means the *index* -- a
    /// `FemMesh.nodeKind` of 1 read through `FemMesh.nodeEntity`, the third number of a census
    /// row, and the `edge_<i>` physical group of `FemMesh.mshText()` -- and this is the one way
    /// back from any of them to the solid's own topology.
    public let id: UInt32
    /// The edge's nodes in order along it, its end vertices included.
    public let nodes: NativeArray<UInt32>
    /// Where each connected run of `nodes` begins; `[0]` for one chain along the whole edge.
    public let runs: NativeArray<UInt32>
    /// `(face_a, face_b)`, the second `UInt32.max` on an open body's rim.
    public let faces: (UInt32, UInt32)
    /// `(end_a, end_b)`, the second `UInt32.max` where both ends are one vertex.
    public let ends: (UInt32, UInt32)
    /// The nodes make one loop. Never true where there is more than one run.
    public let closed: Bool
    /// Bounded twice by one face: a closed surface's seam, not a real boundary. Both `faces` are
    /// then that same face.
    public let seam: Bool

    init(_ raw: CadaclysmBlacksmithFemEdge, _ owner: FemMesh) {
        id = raw.id
        nodes = NativeArray(owner: owner, base: raw.nodes, count: Int(raw.node_count))
        runs = NativeArray(owner: owner, base: raw.runs, count: Int(raw.run_count))
        faces = (raw.face_a, raw.face_b)
        ends = (raw.end_a, raw.end_b)
        closed = raw.closed
        seam = raw.seam
    }
}

extension FemEdge: CustomStringConvertible {
    public var description: String {
        "FemEdge(id=\(id), nodes=\(nodes.count), runs=\(runs.count), faces=\(faces), ends=\(ends), "
            + "closed=\(closed), seam=\(seam))"
    }
}

/// One B-rep vertex of a FEM mesh: the node the mesh put there, if any, and where the topology
/// says it is, if that is known. Plain data, all of it copied out.
public struct FemVertex: Equatable, CustomStringConvertible {
    /// The mesh node at this vertex, or `UInt32.max` (the ABI's NONE) where the mesh has none
    /// there. **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex
    /// wherever two trims meet, and a pole's polyline runs give a sphere 48 of them where the
    /// mesh has 2 points, so a caller walking these skips the sentinel rather than treating it as
    /// a gap.
    public let node: UInt32
    /// Where the vertex is, in the same space and under the same placement as `FemMesh.nodes`.
    /// **Meaningless unless `hasPosition`**: it is all zeros then, a point no geometry has and one
    /// a solver would read as a node at the origin.
    public let point: SIMD3<Double>
    /// `point` was read and placed. False where every trim meeting at this vertex is a curve with
    /// no geometry to read an end off -- reported as this flag rather than as a plausible-looking
    /// `(0, 0, 0)`.
    public let hasPosition: Bool

    init(_ raw: CadaclysmBlacksmithFemVertex) {
        node = raw.node
        point = SIMD3(raw.point.0, raw.point.1, raw.point.2)
        hasPosition = raw.has_position
    }

    public var description: String {
        "FemVertex(node=\(node), point=\(point), hasPosition=\(hasPosition))"
    }
}

/// One solid meshed for a solver: nodes welded by bits, triangles wound outward, every node tagged
/// with the lowest-dimension B-rep entity it lies on, and every crack reported rather than closed.
/// What `Solid.femMesh` returns, and **owned by you**: `free()` it, or let the last reference to
/// it go.
///
/// **A handle rather than a snapshot, and it owns everything it lends.** The five flat arrays are
/// `NativeArray` views into the library's own memory, as `Solid.mesh`'s are and for the same
/// reason -- a solver mesh is megabytes -- but with one difference that matters: **a FEM mesh is
/// not in the solid's tessellation cache**, so meshing the solid again at another tolerance
/// (which stales every `Mesh` and `Polylines` view) leaves it alone, and neither does
/// `Solid.close()`. The owner of every view here is **this object**, and `free()` is what ends
/// them -- or the last reference to it going.
///
/// So a view cannot outlive the memory it reads: it holds this object, which keeps the handle
/// alive, and it checks the owner before every element it hands over -- a read after `free()` traps
/// rather than touching freed memory, and it traps on the **read**, not only when the array is
/// asked for (measured, in a release build). Asking for a view after `free()` traps there and then,
/// as reading any property of a closed `Solid` does. `copy()` on anything that must outlive the
/// mesh anyway, or `Array(view)`.
public final class FemMesh: NativeMemoryOwner {
    private var handle: OpaquePointer?
    /// Read once, when the handle is made: every pointer in the view is built with the handle and
    /// never moves (nothing in this ABI is built lazily), so asking again per accessor would be
    /// one C call for the same answer.
    private let raw: CadaclysmBlacksmithFemMeshView

    init(_ made: OpaquePointer?) throws {
        let handle = try checked(made, "fem_mesh")
        var view = CadaclysmBlacksmithFemMeshView()
        guard cadaclysm_blacksmith_fem_mesh_view(handle, &view) else {
            let reason = failure("fem mesh view")
            cadaclysm_blacksmith_fem_mesh_free(handle)
            throw reason
        }
        self.handle = handle
        raw = view
    }

    deinit { free() }

    /// "the FEM mesh is freed" once `free()` has run, else nil: what the views this mesh lent
    /// check before every read.
    public var nativeMemoryInvalidReason: String? { handle == nil ? "the FEM mesh is freed" : nil }

    /// Whether `free()` has run.
    public var freed: Bool { handle == nil }

    /// Give the mesh back, and with it every view taken from it -- the same word `Solid.close()`
    /// uses for a solid, and the same word the reader library's FEM mesh uses, so one FEM mesh is
    /// released the same way on both sides of the ABI. Idempotent; the last reference going does
    /// the same. The `.msh` texts already handed over are **not** freed with it: each is a
    /// `String` of the caller's own.
    public func free() {
        guard let handle = handle else { return }
        self.handle = nil
        cadaclysm_blacksmith_fem_mesh_free(handle)
    }

    private func h(_ member: String = #function) throws -> OpaquePointer {
        guard let handle = handle else { throw BuildError("FemMesh.\(member): the FEM mesh is freed") }
        return handle
    }

    /// A view of this mesh's own memory. Asked for after `free()` it **traps**, as reading any
    /// property of a closed `Solid` does in this wrapper and for the same reason: the alternative
    /// is handing back a pointer into freed memory. A view taken while the mesh was alive traps
    /// too, on the read rather than here -- `NativeArray` asks its owner before every element.
    private func view<Element>(_ base: UnsafePointer<Element>?, _ count: Int,
                               _ member: String = #function) -> NativeArray<Element> {
        guard handle != nil else { preconditionFailure("FemMesh.\(member): the FEM mesh is freed") }
        return NativeArray(owner: self, base: base, count: count)
    }

    // -- the flat arrays, borrowed from this handle

    /// Every node's position, three doubles each: placed by `Solid.femMesh`'s placement, in the
    /// solid's own coordinates otherwise. Every node is used by at least one triangle.
    public var nodes: NativeArray<Double> { view(raw.nodes, Int(raw.node_count) * 3) }

    /// Three node indices a triangle, wound outward -- a mirroring placement is wound back.
    public var triangles: NativeArray<UInt32> { view(raw.triangles, Int(raw.triangle_count) * 3) }

    /// Which face each triangle lies on, one per triangle: the same faces `Solid.faceKind` names.
    public var triangleFace: NativeArray<UInt32> { view(raw.triangle_face, Int(raw.triangle_count)) }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per node: the
    /// lowest-dimension entity it lies on, which is the `.msh` format's own classification rule.
    /// `nodeEntity` says which entity of that kind.
    public var nodeKind: NativeArray<UInt32> { view(raw.node_kind, Int(raw.node_count)) }

    /// Which vertex, edge or face each node lies on, read by the matching `nodeKind`: an index
    /// into `vertices`, into `edges`, or into the solid's faces.
    public var nodeEntity: NativeArray<UInt32> { view(raw.node_entity, Int(raw.node_count)) }

    // -- the topology

    /// The solid's faces; `triangleFace` and a `nodeKind` of `2` index them.
    public var faceCount: UInt32 { raw.face_count }

    /// One `FemEdge` per B-rep edge, in the order a `nodeKind` of `1` indexes them. **This list's
    /// own numbering, not the solid's**: each `FemEdge.id` carries the solid's own edge id.
    public var edges: [FemEdge] {
        get throws {
            let handle = try h()
            return try (0..<raw.edge_count).map { i in
                var out = CadaclysmBlacksmithFemEdge()
                guard cadaclysm_blacksmith_fem_mesh_edge(handle, i, &out) else {
                    throw failure("fem mesh edge \(i)")
                }
                return FemEdge(out, self)
            }
        }
    }

    /// One `FemVertex` per B-rep vertex, in the order a `nodeKind` of `0` indexes them.
    public var vertices: [FemVertex] {
        get throws {
            let handle = try h()
            return try (0..<raw.vertex_count).map { i in
                var out = CadaclysmBlacksmithFemVertex()
                guard cadaclysm_blacksmith_fem_mesh_vertex(handle, i, &out) else {
                    throw failure("fem mesh vertex \(i)")
                }
                return FemVertex(out)
            }
        }
    }

    // -- the crack census

    /// Every crack, as `(a, b, brepEdge)`: a directed mesh edge `(a, b)` with no `(b, a)`, and the
    /// B-rep edge both nodes lie on or `UInt32.max` where they share none.
    ///
    /// **Empty unless the solid's topology is closed**, whose mesh is otherwise not asked about at
    /// all: such a body reports `watertight` false with this and `foldedEdges` both empty, and
    /// *that trio together* says "not asked", not "nothing found". An open sheet's rim is not a
    /// crack.
    public var openEdges: [(UInt32, UInt32, UInt32)] {
        get throws { try census({ cadaclysm_blacksmith_fem_mesh_open_edge($0, $1, $2, $3, $4) }, raw.open_edge_count, "open edge") }
    }

    /// Every fold, as `openEdges` reports a crack: a directed mesh edge used by more than one
    /// triangle.
    ///
    /// **A body can be folded without being open** -- a solid no thicker than a line leaves no
    /// hole for an open edge to find -- and the closure census's own known-bad bodies are folds
    /// rather than open cracks. A caller that checks `openEdges` alone calls such a body sound.
    /// Empty under the same rule.
    public var foldedEdges: [(UInt32, UInt32, UInt32)] {
        get throws { try census({ cadaclysm_blacksmith_fem_mesh_folded_edge($0, $1, $2, $3, $4) }, raw.folded_edge_count, "folded edge") }
    }

    /// One flattened census, row by row: the shape `openEdges` and `foldedEdges` share, so the two
    /// cannot drift.
    ///
    /// Both call sites wrap the C function in a closure rather than passing it by value. That
    /// is not style: `cadaclysm-capi/tests/bindings.rs`'s parity gate reads a wrapper's calls as
    /// `cadaclysm_blacksmith_...(`, so a bare function reference is a use the gate cannot see --
    /// measured, when the FEM names came off `PARITY_PENDING_KERNEL` and Swift alone was
    /// reported as lacking these two.
    private func census(_ call: (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?,
                                UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Bool,
                        _ count: UInt32, _ what: String) throws -> [(UInt32, UInt32, UInt32)] {
        let handle = try h()
        return try (0..<count).map { i in
            var a: UInt32 = 0, b: UInt32 = 0, edge: UInt32 = 0
            guard call(handle, i, &a, &b, &edge) else { throw failure("fem mesh \(what) \(i)") }
            return (a, b, edge)
        }
    }

    // -- the summary

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none used
    /// twice -- and so does the topology behind it. **False for every solid whose topology is not
    /// closed**, whose mesh is then not asked about; read `openEdges` for what an empty census
    /// beside a false here does and does not mean.
    public var watertight: Bool { raw.watertight }

    /// Always false here: this library has no mesh-only path, so every FEM mesh comes off exact
    /// geometry. The reader's `cadaclysm_node_fem_mesh` sets it for a node with no brep.
    public var fromMesh: Bool { raw.from_mesh }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a solid that
    /// meshed to no triangles is a refusal, not a mesh.
    public var minAngle: Double { raw.min_angle }

    /// The triangle with that angle, as an index into `triangles` (three entries each).
    public var worstTriangle: UInt32 { raw.worst_triangle }

    /// The longest triangle edge, placed. **The figure to check against `Solid.femMesh`'s
    /// `maxSize`, and the only one that says what the mesh actually is**: `maxSize` bounds the
    /// boundary segments and merely *targets* the interior -- measured at 1.03x `maxSize` on a
    /// face whose parameters run unevenly -- and one small enough beside the body to reach the
    /// mesher's own piece and station ceilings is not honoured at all. A caller that asked for an
    /// element size reads this to find out whether it got one.
    public var longestEdge: Double { raw.longest_edge }

    // -- out

    /// The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a volume
    /// where the body closes, and a physical group naming each.
    ///
    /// **On this side of the ABI the library's text is owned**, and this wrapper releases it with
    /// `cadaclysm_blacksmith_string_free` as it does every other text this library hands over --
    /// so two asks are two independent texts, and one stays good after `free()`. The reader
    /// library's `Cadaclysm.FemMesh.mshText()` is the other way round: a slot borrowed from its
    /// handle, which must **not** be freed. A reader porting one side's reasoning onto the other
    /// leaks or double-frees.
    ///
    /// **Prints the unlicensed notice**, as `saveMsh` does and as this library's other writers do
    /// -- and unlike `Solid.femMesh`, which does not: this library notices on its writers where
    /// the reader library notices in its constructor and on neither `.msh` call.
    ///
    /// Throws for a mesh the writer refuses, naming the field it cannot honour, and for a freed
    /// handle.
    public func mshText() throws -> String {
        guard let raw = cadaclysm_blacksmith_fem_mesh_msh_text(try h()) else { throw failure("fem_mesh_msh_text") }
        defer { cadaclysm_blacksmith_string_free(raw) }
        return String(cString: raw)
    }

    /// `mshText()` written to `path` by the library itself: the same bytes from the same writer,
    /// straight to the file rather than through a string. Throws for a mesh the writer refuses or
    /// a file it cannot write. Prints the unlicensed notice, as `mshText()` does.
    public func saveMsh(_ path: String) throws {
        guard cadaclysm_blacksmith_fem_mesh_save_msh(try h(), path) else { throw failure("fem_mesh_save_msh") }
    }
}

extension FemMesh: CustomStringConvertible {
    public var description: String {
        freed ? "FemMesh(freed)"
            : "FemMesh(nodes=\(raw.node_count), triangles=\(raw.triangle_count), "
                + "watertight=\(raw.watertight), fromMesh=\(raw.from_mesh))"
    }
}

// MARK: - Solids

/// An exact B-rep solid (or open sheet): planes, cylinders, cones, spheres, tori and NURBS,
/// trimmed and joined, never approximated by triangles. Immutable; every operation returns a
/// new one. `close()` frees it now; `deinit` does otherwise.
public final class Solid {
    private var handle: OpaquePointer?

    /// The tolerance the library's tessellation cache was last filled at (nil before any of
    /// `mesh`, `edgePolylines` and `boundsAt` ran), and how many times it has been filled. A
    /// view checks the filling it was cut from, never the tolerance.
    private(set) var cacheTolerance: Double?
    private var cacheGeneration = 0

    init(_ raw: OpaquePointer?, _ what: String = "solid") throws {
        handle = try checked(raw, what)
    }

    deinit { close() }

    /// Free the solid now. Idempotent; every view still held traps on its next read, and
    /// every call on the solid throws.
    public func close() {
        if let handle { cadaclysm_blacksmith_solid_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("solid: closed") }
        return handle
    }

    /// Record that a call just tessellated at `tolerance`: a new filling if it differs from
    /// the one the cache held. Returns the generation a view made now belongs to.
    private func filled(_ tolerance: Double) -> Int {
        if cacheTolerance != tolerance {
            cacheTolerance = tolerance
            cacheGeneration += 1
        }
        return cacheGeneration
    }

    /// Whether a view cut from filling `generation` may still read.
    func cacheHolds(_ generation: Int) -> Bool {
        handle != nil && cacheGeneration == generation
    }

    // MARK: Naming

    /// This solid, named `name`. The name rides through an operation with exactly one
    /// source solid (`place`, `translate`, `coloured`, `fillet`, ...) and is dropped by
    /// one with two or more (`join`, `cut`, `common`, ...) and by a fresh primitive or
    /// sweep -- see `name`. It is what `Assembly.place` defaults a placement's own name
    /// to, and the product name a lone named solid gets when written to STEP (`step`/
    /// `stepText`). Refused for an empty name.
    public func named(_ name: String) throws -> Solid {
        try Solid(cadaclysm_blacksmith_named(try h(), name))
    }

    /// This solid's name, or nil if it has none -- what `named` set, kept or dropped by
    /// whatever built this solid. The C function's pointer is borrowed and null for both
    /// "no name" and a failure, so this reads it directly and never calls `text()`, which
    /// would map null to `""` and erase the "no name" case.
    public var name: String? {
        get throws {
            guard let raw = cadaclysm_blacksmith_solid_name(try h()) else { return nil }
            return String(cString: raw)
        }
    }

    // MARK: Primitives

    /// A box `x` x `y` x `z`, centred on the origin.
    public static func cuboid(_ x: Double, _ y: Double, _ z: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_cuboid(x, y, z))
    }

    /// A cylinder of radius `r`, from z = 0 to `h`.
    public static func cylinder(_ r: Double, _ h: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_cylinder(r, h))
    }

    /// A cone of base radius `r` and height `h`, apex up.
    public static func cone(_ r: Double, _ h: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_cone(r, h))
    }

    /// A sphere of radius `r` about the origin.
    public static func sphere(_ r: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_sphere(r))
    }

    /// A torus about the z axis: `major` to the tube's centre, `minor` the tube's radius.
    public static func torus(_ major: Double, _ minor: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_torus(major, minor))
    }

    /// A box whose top face is `topX` long instead of `x`: a ramp.
    public static func wedge(_ x: Double, _ y: Double, _ z: Double, _ topX: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_wedge(x, y, z, topX))
    }

    // MARK: From a profile

    /// `profile` on `frame`, extruded `height` along the frame's z.
    public static func extrude(_ profile: Profile, _ frame: Frame, _ height: Double) throws -> Solid {
        try extrude(profile, raw: frame.values, height)
    }

    static func extrude(_ profile: Profile, raw frame: [Double], _ height: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude(profile.handle, try frameValues(frame), height))
    }

    /// The walls only, no caps: an open sheet. Takes an open `Path.endOpen` chain as well as
    /// a closed profile.
    public static func extrudeOpen(_ profile: Profile, _ frame: Frame, _ height: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_open(profile.handle, frame.values, height))
    }

    /// `extrude` with a draft: the walls lean out by `taper` radians as they rise (in, when
    /// negative), every wall exact -- a plane off a line, a cone off an arc. A taper of zero
    /// is `extrude`.
    public static func extrudeTapered(_ profile: Profile, _ frame: Frame, _ height: Double,
                                      _ taper: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_tapered(profile.handle, frame.values, height, taper))
    }

    /// The tapered walls without caps.
    public static func extrudeOpenTapered(_ profile: Profile, _ frame: Frame, _ height: Double,
                                          _ taper: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_open_tapered(profile.handle, frame.values, height, taper))
    }

    /// `extrude` between two planes instead of two heights: `bottom` and `top` are each a
    /// `Slant` (a number literal is a flat one). The walls run from where `bottom` cuts them
    /// to where `top` does, the caps lying on those planes. With both flat this *is*
    /// `extrude`; with a slope it is the mitred end of a sweep's straight piece. Throws where
    /// the top plane comes down to or through the bottom across the profile.
    public static func extrudeBetween(_ profile: Profile, _ frame: Frame, _ bottom: Slant,
                                      _ top: Slant) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_between(profile.handle, frame.values, bottom.raw, top.raw))
    }

    /// `extrudeBetween` without the caps: an open sheet of walls from `bottom` to `top`.
    public static func extrudeOpenBetween(_ profile: Profile, _ frame: Frame, _ bottom: Slant,
                                          _ top: Slant) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_open_between(profile.handle, frame.values, bottom.raw, top.raw))
    }

    /// The solid between `a` on `frameA` and `b` on `frameB`: ruled walls between matching
    /// sides (the profiles must have the same number of sides, and no holes), capped by the
    /// two profiles.
    public static func loft(_ a: Profile, _ frameA: Frame, _ b: Profile, _ frameB: Frame) throws -> Solid {
        try Solid(cadaclysm_blacksmith_loft(a.handle, frameA.values, b.handle, frameB.values))
    }

    /// `loft` without the caps: the sheet ruled between the two curves.
    public static func loftOpen(_ a: Profile, _ frameA: Frame, _ b: Profile, _ frameB: Frame) throws -> Solid {
        try Solid(cadaclysm_blacksmith_loft_open(a.handle, frameA.values, b.handle, frameB.values))
    }

    /// The solid smooth through every section -- a profile on its frame, in order: each
    /// wall interpolates its side across all the profiles (cubic through four or more,
    /// quadratic through three, `loft` through two), capped by the first and the last.
    public static func loftThrough(_ sections: [(Profile, Frame)]) throws -> Solid {
        let handles: [OpaquePointer?] = sections.map { $0.0.handle }
        let frames: [Double] = sections.flatMap { $0.1.values }
        return try withExtendedLifetime(sections) {
            try Solid(cadaclysm_blacksmith_loft_through(handles, frames, handles.count))
        }
    }

    /// `loftThrough` without the caps: the sheet through the curves.
    public static func loftThroughOpen(_ sections: [(Profile, Frame)]) throws -> Solid {
        let handles: [OpaquePointer?] = sections.map { $0.0.handle }
        let frames: [Double] = sections.flatMap { $0.1.values }
        return try withExtendedLifetime(sections) {
            try Solid(cadaclysm_blacksmith_loft_through_open(handles, frames, handles.count))
        }
    }

    /// `profile` swung `angle` radians about `axis` (a point and a direction). Its x is read
    /// as the radius and its y as the height along the axis, so it must lie to one side.
    public static func revolve(_ profile: Profile, _ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>),
                               _ angle: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_revolve(profile.handle, axisValues(axis), angle))
    }

    /// The revolved surface of an open profile: a sheet.
    public static func revolveOpen(_ profile: Profile, _ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>),
                                   _ angle: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_revolve_open(profile.handle, axisValues(axis), angle))
    }

    /// `profile`, drawn on `frame`, swung `angle` radians about the axis through the sketch
    /// points `a` and `b` -- the profile and its axis drawn together, as a sketch draws them,
    /// where `revolve` reads the profile as (radius, height). The profile may lie on either
    /// side of the axis and touch it, not cross it; the sweep starts where the profile is
    /// drawn and turns right-handed about `b - a`.
    public static func revolveInPlane(_ profile: Profile, _ frame: Frame, _ a: SIMD2<Double>,
                                      _ b: SIMD2<Double>, _ angle: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_revolve_in_plane(profile.handle, frame.values, [a.x, a.y, b.x, b.y], angle))
    }

    /// `revolveInPlane` for a curve: its segments swung into a sheet, no caps.
    public static func revolveOpenInPlane(_ profile: Profile, _ frame: Frame, _ a: SIMD2<Double>,
                                          _ b: SIMD2<Double>, _ angle: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_revolve_open_in_plane(profile.handle, frame.values,
                                                             [a.x, a.y, b.x, b.y], angle))
    }

    /// `profile` coiled about `axis` (a point and a direction): read as `revolve` reads it --
    /// x the distance from the axis, y along it -- and turned `turns` times while climbing
    /// `pitch` along the axis each turn: a spring, a thread. The walls follow the helix to a
    /// few millionths of the radius; the two ends are the profile itself, flat. From a full
    /// turn up the pitch must be taller than the profile.
    public static func coil(_ profile: Profile, _ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>),
                            _ pitch: Double, _ turns: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_coil(profile.handle, axisValues(axis), pitch, turns))
    }

    /// `profile`, drawn on `frame`, carried along `path` into a closed solid: a straight piece
    /// is an extrusion, a circular piece a revolution about the arc's axis, so nothing is
    /// approximated -- a circle along an arc is an exact torus wall. `path` is only borrowed.
    public static func sweep(_ profile: Profile, _ frame: Frame, _ path: SweepPath) throws -> Solid {
        try Solid(cadaclysm_blacksmith_sweep(profile.handle, frame.values, try path.live()))
    }

    /// `sweep` for a curve rather than a face: one wall per segment per piece, no caps -- an
    /// open sheet, as `extrudeOpen` is to `extrude`.
    public static func sweepOpen(_ profile: Profile, _ frame: Frame, _ path: SweepPath) throws -> Solid {
        try Solid(cadaclysm_blacksmith_sweep_open(profile.handle, frame.values, try path.live()))
    }

    /// A circle of `radius` swept along `path`, square to its start: a rod,
    /// or with a positive `thickness` a tube whose walls are that thick. `path` is only
    /// borrowed, as by `sweep`.
    public static func pipe(_ path: SweepPath, _ radius: Double, thickness: Double = 0.0) throws -> Solid {
        try Solid(cadaclysm_blacksmith_pipe(try path.live(), radius, thickness))
    }

    /// Every face of this sheet pushed `height` along its own normal, walled and closed: the
    /// sheet as a solid of that thickness.
    public func extrudeFaces(_ height: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_extrude_faces(try h(), height))
    }

    /// The flat sheet `profile` bounds on `frame`: one planar face, each hole a hole through
    /// it, its normal `frame`'s z (however the profile winds), every edge the exact line, arc
    /// or spline its segment is. An open sheet -- raise it with `extrudeFaces`, cut it with
    /// `trim` or `splitSheet`.
    public static func face(_ profile: Profile, _ frame: Frame) throws -> Solid {
        try face(profile, raw: frame.values)
    }

    static func face(_ profile: Profile, raw frame: [Double]) throws -> Solid {
        try Solid(cadaclysm_blacksmith_face(profile.handle, try frameValues(frame)))
    }

    // MARK: Faces and sheets

    /// Face `face` alone, as an open sheet: its surface, its loops and the exact curves on its
    /// edges, the rest of the solid left behind (`part.faceSheet(top).extrudeFaces(5)` is the
    /// prism over the top face).
    public func faceSheet(_ face: Int) throws -> Solid {
        try Solid(cadaclysm_blacksmith_face_sheet(try h(), try index32(face, "face_sheet")))
    }

    /// This solid without the faces at `faces` (repeats allowed): the rest keep their
    /// surfaces, loops and curves, in their order, so an index into the result is this one's
    /// with the dropped ones closed up. An open sheet unless nothing was dropped.
    public func dropFaces(_ faces: [Int]) throws -> Solid {
        let which = try indices32(faces, "drop_faces")
        return try Solid(cadaclysm_blacksmith_drop_faces(try h(), which, which.count))
    }

    // MARK: Placing

    /// This solid, built about the origin, moved onto `frame`: its origin to the frame's
    /// origin, its axes to the frame's.
    public func place(_ frame: Frame) throws -> Solid {
        try place(raw: frame.values)
    }

    func place(raw frame: [Double]) throws -> Solid {
        try Solid(cadaclysm_blacksmith_place(try h(), try frameValues(frame)))
    }

    /// Moved by (`dx`, `dy`, `dz`).
    public func translate(_ dx: Double, _ dy: Double, _ dz: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_translate(try h(), dx, dy, dz))
    }

    /// This solid scaled by `factor` about the origin: every length times `factor`, exactly.
    public func scaled(_ factor: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_scaled(try h(), factor))
    }

    /// Turned `radians` about `axis` (a point and a direction).
    public func rotate(_ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>), _ radians: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_rotate(try h(), axisValues(axis), radians))
    }

    /// Reflected across `plane`: a frame whose z is the mirror plane's normal.
    public func mirror(_ plane: Frame) throws -> Solid {
        try Solid(cadaclysm_blacksmith_mirror(try h(), plane.values))
    }

    // MARK: Booleans

    /// `f` over this solid's handle and `other`'s, its flush faces merged when `merge` (the
    /// unmerged one freed).
    private func combine(_ other: Solid, merge: Bool,
                         _ f: (OpaquePointer, OpaquePointer) -> OpaquePointer?) throws -> Solid {
        let out = try withExtendedLifetime(other) { try Solid(f(try h(), try other.h())) }
        guard merge else { return out }
        defer { out.close() }
        return try out.mergeFlush()
    }

    /// This solid and `other` as one, as an exact B-rep. `merge` merges the flush faces the
    /// join leaves where the two meet in a plane or on one cylinder (`mergeFlush`), off by default, so face and edge numbers stay as they were. `tolerance` is the
    /// mesh tolerance the boolean decides at; a tighter one is as correct, only slower.
    public func join(_ other: Solid, tolerance: Double = 0.05, merge: Bool = false) throws -> Solid {
        try combine(other, merge: merge) { cadaclysm_blacksmith_join($0, $1, tolerance, nil, nil) }
    }

    /// This solid with `other` removed; `merge` as `join`'s.
    public func cut(_ other: Solid, tolerance: Double = 0.05, merge: Bool = false) throws -> Solid {
        try combine(other, merge: merge) { cadaclysm_blacksmith_cut($0, $1, tolerance, nil, nil) }
    }

    /// What this solid and `other` share; `merge` as `join`'s.
    public func common(_ other: Solid, tolerance: Double = 0.05, merge: Bool = false) throws -> Solid {
        try combine(other, merge: merge) { cadaclysm_blacksmith_common($0, $1, tolerance, nil, nil) }
    }

    /// This solid (a sheet or a solid) cut along the closed `tool`'s boundary and the pieces
    /// on one side thrown away: `keep` `"outside"` keeps what lies outside the tool -- a hole
    /// punched through the sheet -- and `"inside"` what lies within it. `splitSheet` then
    /// `dropFaces` of the other side, in one call; the kept pieces come out in this solid's
    /// face order.
    public func trim(_ tool: Solid, keep: String = "outside", tolerance: Double = 0.05) throws -> Solid {
        guard keep == "outside" || keep == "inside" else {
            throw BuildError("trim: keep must be 'outside' or 'inside', not '\(keep)'")
        }
        return try withExtendedLifetime(tool) {
            try Solid(cadaclysm_blacksmith_trim(try h(), try tool.h(), keep == "inside", tolerance, nil, nil))
        }
    }

    /// This solid (a sheet or a solid) cut along `tool`'s boundary, nothing removed: every
    /// face comes back in its pieces outside `tool` and its pieces inside, in this solid's
    /// face order, each face's outside pieces first. `tool` must be a closed solid. Keep or
    /// discard pieces with `dropFaces`; `trim` is the split with one side dropped.
    public func splitSheet(_ tool: Solid, tolerance: Double = 0.05) throws -> Solid {
        try combine(tool, merge: false) { cadaclysm_blacksmith_split_sheet($0, $1, tolerance, nil, nil) }
    }

    /// Where this solid's faces cross or coincide with `other`'s, at `tolerance`, as an
    /// `Intersection`: `chains` along the curves the faces meet on and `overlaps` where a
    /// face pair coincides. Neither solid is changed; either may be an open sheet. No
    /// crossing is an empty result, never an error.
    ///
    /// Each `Chain`'s points are within `tolerance` of both faces' exact surfaces; there is
    /// one chain per face pair per branch -- chains are not joined across a face boundary or
    /// a closed curve's seam, so join them by matching ends. A chain's `curve` is its exact
    /// curve where the kernel found one every point lies within `tolerance` of, else nil;
    /// `tangent` is set where the surfaces are near-tangent along the chain or the snap did
    /// not settle (the points are then the best estimate) -- a closed chain that does not go
    /// once round its own curve (a sliver where two surfaces barely cross) has no curve,
    /// `tangent` still true. An `Overlap` is a coincident face pair with the shared region's
    /// rings (outer first, holes after), which may be empty for a partial overlap whose
    /// outlines cross. Known limit: a crossing narrower than `tolerance` -- two surfaces
    /// passing within it without their meshes crossing -- can be missed; near-tangent contact
    /// is where this bites.
    ///
    /// Throws for a `tolerance` not positive and finite, a solid with no faces, or one that
    /// meshes to nothing.
    public func intersect(_ other: Solid, tolerance: Double = 0.05) throws -> Intersection {
        try withExtendedLifetime(other) {
            guard let found = cadaclysm_blacksmith_intersect(try h(), try other.h(), tolerance, nil, nil) else {
                throw failure("intersect")
            }
            defer { cadaclysm_blacksmith_intersection_free(found) }
            var chains: [Chain] = []
            for i in 0..<cadaclysm_blacksmith_intersection_chain_count(found) {
                var raw = CadaclysmBlacksmithChain()
                if !cadaclysm_blacksmith_intersection_chain(found, i, &raw) { throw failure("intersection_chain") }
                var curve: Curve? = nil
                if raw.has_curve {
                    var rawCurve = CadaclysmBlacksmithCurve()
                    if !cadaclysm_blacksmith_intersection_curve(found, i, &rawCurve) { throw failure("intersection_curve") }
                    curve = Curve(rawCurve)
                }
                chains.append(Chain(raw, curve))
            }
            var overlaps: [Overlap] = []
            for i in 0..<cadaclysm_blacksmith_intersection_overlap_count(found) {
                var raw = CadaclysmBlacksmithOverlap()
                if !cadaclysm_blacksmith_intersection_overlap(found, i, &raw) { throw failure("intersection_overlap") }
                overlaps.append(Overlap(raw))
            }
            return Intersection(chains: chains, overlaps: overlaps)
        }
    }

    /// Where `profile`, placed on `frame`, pierces this solid's faces, and the pieces its
    /// loops cut into, as a `SolidHits`. Neither is changed.
    ///
    /// A point hit lies within `tolerance` of the segment's exact curve and of the face's
    /// exact surface, inside the face's trim; its profile spot (`aStart`: loop, segment, t)
    /// and face spot (`bStart`: face, u, v) evaluate to the point within `tolerance`; `touch`
    /// where the curve's tangent lies within 1e-3 (sine) of the surface's tangent plane there
    /// (a graze), false at a crossing. A run is a stretch of one segment lying within
    /// `tolerance` of one face and inside it, longer than `tolerance`. Hits within `tolerance`
    /// of each other merge (a hit at a segment join reported once, as `(k, t = 1)`; a
    /// closed loop's closing join reads `(0, 0)`). Every
    /// point is in world space (the frame applied).
    ///
    /// Pieces only for a closed body -- an open body has none -- in loop order, covering
    /// every loop exactly; a piece's spots read a segment join as the next segment's start
    /// `(k + 1, 0)`, and an open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts
    /// is one closed piece. `inside` by the piece middle's winding number over the body's
    /// mesh; a piece lying on the surface is inside. Known limit: a segment passing within
    /// `tolerance` of a face without crossing its mesh can be missed (near-tangent grazes).
    ///
    /// Throws for a `tolerance` not positive and finite, a solid with no faces or that meshes
    /// to nothing, a profile with no segments, or a free-form segment that is not an
    /// evaluable NURBS curve.
    public func hits(_ profile: Profile, _ frame: Frame, tolerance: Double = 0.05) throws -> SolidHits {
        try withExtendedLifetime(profile) {
            guard let found = cadaclysm_blacksmith_solid_profile_hits(try h(), profile.handle, frame.values, tolerance, nil, nil) else {
                throw failure("solid_profile_hits")
            }
            defer { cadaclysm_blacksmith_hits_free(found) }
            var hits: [Hit] = []
            for i in 0..<cadaclysm_blacksmith_hit_count(found) {
                var raw = CadaclysmBlacksmithHit()
                if !cadaclysm_blacksmith_hit(found, i, &raw) { throw failure("hit") }
                hits.append(Hit(raw))
            }
            var pieces: [Piece] = []
            for i in 0..<cadaclysm_blacksmith_hits_piece_count(found) {
                var inside = false
                var start = CadaclysmBlacksmithSpot(), end = CadaclysmBlacksmithSpot()
                if !cadaclysm_blacksmith_hits_piece(found, i, &inside, &start, &end) { throw failure("hits_piece") }
                let own = try Profile(cadaclysm_blacksmith_hits_piece_profile(found, i), "hits_piece_profile")
                pieces.append(Piece(inside: inside, start: Spot(start), end: Spot(end), profile: own))
            }
            return SolidHits(hits: hits, pieces: pieces)
        }
    }

    // MARK: Asking

    /// How many faces, in the solid's own order; a face index runs to this.
    public var faces: Int {
        get throws {
            let n = cadaclysm_blacksmith_face_count(try h())
            if n == 0 && !lastError().isEmpty { throw failure("face_count") }
            return Int(n)
        }
    }

    /// A face's surface: `"plane"`, `"cylinder"`, `"cone"`, `"sphere"`, `"torus"`, `"nurbs"`,
    /// `"revolution"`, `"extrusion"` or `"other"`.
    public func faceKind(_ face: Int) throws -> String {
        guard let raw = cadaclysm_blacksmith_face_kind(try h(), try index32(face, "face_kind")) else {
            throw failure("face_kind")
        }
        return text(raw)
    }

    /// `boundsAt(0.05)` -- the bounds of the tessellation at tolerance 0.05.
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        get throws { try boundsAt(0.05) }
    }

    /// The solid's axis-aligned bounds, over the positions of its cached tessellation at
    /// `tolerance` (the same cache `mesh` fills and reuses, so a second call at the same
    /// tolerance is free).
    public func boundsAt(_ tolerance: Double) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = [Double](repeating: 0, count: 3)
        var hi = [Double](repeating: 0, count: 3)
        if !cadaclysm_blacksmith_bounds(try h(), tolerance, &lo, &hi) { throw failure("bounds") }
        _ = filled(tolerance)
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    /// `boundsAt64(0.05)`.
    public var bounds64: (min: SIMD3<Double>, max: SIMD3<Double>) {
        get throws { try boundsAt64(0.05) }
    }

    /// `boundsAt(tolerance)` from the same tessellation's own unnarrowed positions -- exact
    /// far from the origin, where `boundsAt`'s widened `Float` is not. The same cache
    /// `boundsAt` and `mesh(tolerance:)` fill and reuse, so a second call at the same
    /// tolerance (through either the `float` or the `double` side) is free.
    public func boundsAt64(_ tolerance: Double) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = [Double](repeating: 0, count: 3)
        var hi = [Double](repeating: 0, count: 3)
        if !cadaclysm_blacksmith_bounds64(try h(), tolerance, &lo, &hi) { throw failure("bounds64") }
        _ = filled(tolerance)
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    /// How many edges of the mesh at `tolerance` are bound by anything other than exactly two
    /// triangles -- zero for a closed solid. A seam two solids share along a line does *not*
    /// count; a genuine hole or a fold does.
    public func leakedEdges(tolerance: Double = 0.05) throws -> Int {
        let n = cadaclysm_blacksmith_leaked_edges(try h(), tolerance)
        if n == none { throw failure("leaked_edges") }
        return Int(n)
    }

    /// How many edges of the mesh at `tolerance` have directed triangle uses that do not
    /// cancel out -- zero for a closed, consistently oriented solid. Unlike `leakedEdges`
    /// this catches a fold (two triangles running the same way), and a shared seam pairs off.
    public func unpairedEdges(tolerance: Double = 0.05) throws -> Int {
        let n = cadaclysm_blacksmith_unpaired_edges(try h(), tolerance)
        if n == none { throw failure("unpaired_edges") }
        return Int(n)
    }

    /// `leakedEdges(tolerance:) == 0`.
    public func isWatertight(tolerance: Double = 0.05) throws -> Bool {
        try leakedEdges(tolerance: tolerance) == 0
    }

    /// Whether the faces make a manifold -- every edge bordered by one face or two, the faces
    /// round every vertex one fan -- and whether it is closed. Read off the solid's topology,
    /// not a mesh, so it takes no tolerance; whether the faces all face out is
    /// `unpairedEdges`'s question.
    public var manifold: Manifold {
        get throws {
            var row = [UInt32](repeating: 0, count: 8)
            if !cadaclysm_blacksmith_manifold(try h(), &row) { throw failure("manifold") }
            return Manifold(row)
        }
    }

    // MARK: Output

    /// The triangles at `tolerance`, as views into the solid's cache: valid until the solid
    /// is closed or meshed again at a different tolerance; `copy()` what must outlive either.
    public func mesh(tolerance: Double = 0.05) throws -> Mesh {
        let raw = cadaclysm_blacksmith_mesh(try h(), tolerance)
        if raw.positions == nil { throw failure("mesh") }
        let owner = CacheFilling(self, filled(tolerance))
        let floats = Int(raw.vertex_count) * 3
        return Mesh(tolerance: tolerance,
                    positions: NativeArray(owner: owner, base: raw.positions, count: floats),
                    normals: NativeArray(owner: owner, base: raw.normals, count: floats),
                    indices: NativeArray(owner: owner, base: raw.indices, count: Int(raw.index_count)))
    }

    /// `mesh(tolerance:)` in `double`: the very same index buffer, positions and normals
    /// unnarrowed -- from the same cache, under the same rule as `mesh(tolerance:)`: valid
    /// until the solid is closed or meshed again at another tolerance; `copy()` what must
    /// outlive either.
    public func mesh64(tolerance: Double = 0.05) throws -> Mesh64 {
        let raw = cadaclysm_blacksmith_mesh64(try h(), tolerance)
        if raw.positions == nil { throw failure("mesh64") }
        let owner = CacheFilling(self, filled(tolerance))
        let doubles = Int(raw.vertex_count) * 3
        return Mesh64(tolerance: tolerance,
                     positions: NativeArray(owner: owner, base: raw.positions, count: doubles),
                     normals: NativeArray(owner: owner, base: raw.normals, count: doubles),
                     indices: NativeArray(owner: owner, base: raw.indices, count: Int(raw.index_count)))
    }

    /// The feature edges as polylines at `tolerance`, one run of points per edge -- views into
    /// the same cache as `mesh`, under the same rule.
    public func edgePolylines(tolerance: Double = 0.05) throws -> Polylines {
        let raw = cadaclysm_blacksmith_edge_polylines(try h(), tolerance)
        if raw.offsets == nil { throw failure("edge_polylines") }
        let owner = CacheFilling(self, filled(tolerance))
        let count = Int(raw.polyline_count)
        return Polylines(tolerance: tolerance,
                         points: NativeArray(owner: owner, base: raw.points, count: Int(raw.point_count) * 3),
                         offsets: NativeArray(owner: owner, base: raw.offsets, count: count + 1),
                         count: count)
    }

    /// The kernel's `mesh_face_triangles`, kept for the viewer follow-up (as Go keeps it): how
    /// many triangles each face meshed to at `tolerance`, in face order, summing to `mesh`'s
    /// triangle count at the same tolerance -- copied out of the solid's cache.
    func faceTriangles(tolerance: Double = 0.05) throws -> [UInt32] {
        try withExtendedLifetime(self) { () throws -> [UInt32] in
            let raw = cadaclysm_blacksmith_mesh_face_triangles(try h(), tolerance)
            guard let counts = raw.counts else { throw failure("mesh_face_triangles") }
            return Array(UnsafeBufferPointer(start: counts, count: Int(raw.face_count)))
        }
    }

    /// This solid meshed for a solver, as a `FemMesh`: nodes welded by bits -- two mesh points are
    /// one node only where their coordinates are the same doubles, so no tolerance ever merges two
    /// distinct points and a crack stays a crack -- triangles wound outward, and every node tagged
    /// with the lowest-dimension B-rep entity it lies on.
    ///
    /// **It is its own handle, not a view of this solid.** `Solid.mesh` fills the solid's
    /// tessellation cache and lends views into that filling; this returns a `FemMesh` that owns
    /// everything it lends, so meshing the solid again at another tolerance does not stale it and
    /// neither does `close()`.
    ///
    /// `tolerance` is the chordal tolerance in model units, finite and above zero, and **it alone
    /// governs how closely the mesh follows the geometry**. `maxSize` is a size ceiling, finite and
    /// zero or more, `0` being no ceiling (curvature alone): **it bounds the boundary and targets
    /// the interior**, which is not a longest-element-edge guarantee -- it adds boundary nodes
    /// without refining boundary geometry, and `FemMesh.longestEdge` is what the mesh actually came
    /// to, the figure a solver caller checks.
    ///
    /// **Neither is checked here**: both go through as given and the library refuses what it
    /// cannot honour, in its own words. This side has no mesh-only path, so every solid goes
    /// through the options -- where the reader's `Node.femMesh` on a body with no brep reads
    /// neither, and a wrapper that validated either field would be wrong there. `0.01` and `0.0`
    /// are `FemOptions::default()`'s own figures, restated here so the signature says what a
    /// caller gets; the library's struct is still filled by `cadaclysm_blacksmith_fem_options_init`
    /// first, so a field added to it later defaults without this code being touched.
    ///
    /// **`0.01`, not `Solid.mesh`'s `0.05`.** The render mesher's default and the solver mesher's
    /// are different figures, and the two methods sit next to each other, so copying the neighbour
    /// gives a caller a mesh five times coarser than the same call in every other wrapper. Pinned
    /// by `testFemMeshDefaultsAreTheLibrarysOwn`.
    ///
    /// `placement` is a `Frame` -- **twelve** numbers: origin, x, y, z, as every frame argument
    /// here -- and nil for the identity; it is applied in `Double` throughout. This is the one
    /// frame argument in this library that may be left out, a solid meshed in its own coordinates
    /// being the common case. The reader library's `Node.femMesh` takes **sixteen**, column-major,
    /// so a caller moving between the two reformats the placement; a `Frame` checks its own axes
    /// when it is built, so the confusion cannot arise as a length here.
    ///
    /// **A cracked body is not a failure**: it comes back with `FemMesh.watertight` false and its
    /// cracks in `FemMesh.openEdges` / `FemMesh.foldedEdges`, folded edges as prominent as open
    /// ones, and nothing is welded shut to make it look sound. Throws for a tolerance or `maxSize`
    /// the mesher refuses, a placement not finite or not invertible, a closed solid this library
    /// cannot mesh, and a solid that meshes to no triangles at all.
    ///
    /// **No unlicensed notice here**: `FemMesh.mshText()` and `FemMesh.saveMsh` print it, this
    /// library noticing on its writers rather than on its builders -- where the reader library
    /// notices in its own constructor and on neither `.msh` call.
    public func femMesh(tolerance: Double = 0.01, maxSize: Double = 0.0,
                        placement: Frame? = nil) throws -> FemMesh {
        var options = CadaclysmBlacksmithFemOptions()
        // `init` writes `sizeof(CadaclysmBlacksmithFemOptions)` bytes as the *library* knows that
        // type, into the struct this package's own copy of the header declares -- the two are the
        // same declaration, the header being imported rather than transcribed. `size` is then set
        // to this header's sizeof, which is what the growth rule asks of a caller.
        cadaclysm_blacksmith_fem_options_init(&options)
        options.size = MemoryLayout<CadaclysmBlacksmithFemOptions>.size
        options.tolerance = tolerance
        options.max_size = maxSize
        let handle = try h()
        // nil, never an empty array: the ABI reads null as the identity and refuses a
        // zero-length frame as twelve numbers it did not get.
        return try withUnsafePointer(to: &options) { opts in
            try FemMesh(placement.map { frame in
                frame.values.withUnsafeBufferPointer {
                    cadaclysm_blacksmith_fem_mesh(handle, $0.baseAddress, opts, nil, nil)
                }
            } ?? cadaclysm_blacksmith_fem_mesh(handle, nil, opts, nil, nil))
        }
    }

    /// This solid as STEP text (AP203 unless `schema` names another); see `writeStepText`.
    public func stepText(schema: String? = nil, unit: String = "mm") throws -> String {
        try writeStepText([self], schema: schema, unit: unit)
    }

    /// This solid written as a STEP file (AP203 unless `schema` names another); see
    /// `writeStep`.
    public func step(_ path: String, schema: String? = nil, unit: String = "mm") throws {
        try writeStep(path, [self], schema: schema, unit: unit)
    }

    /// This solid as ACIS SAT text; see `writeSatText`.
    public func satText(unit: String = "mm") throws -> String {
        try writeSatText([self], unit: unit)
    }

    /// This solid written as an ACIS SAT file by the library itself; see `writeSat`.
    public func sat(_ path: String, unit: String = "mm") throws {
        try writeSat(path, [self], unit: unit)
    }

    /// This solid as OCCT `.brep` text; see `writeBrepText`.
    public func brepText() throws -> String {
        try writeBrepText([self])
    }

    /// This solid written as a `.brep` file, by the library itself; see `writeBrep`.
    public func brep(_ path: String) throws {
        try writeBrep(path, [self])
    }

    /// This solid's wireframe as SVG text, from the camera `options` describes -- the library's
    /// own camera, not a viewer. See `writeSvgText`.
    public func svgText(_ options: SvgOptions = SvgOptions()) throws -> String {
        try writeSvgText([self], options: options)
    }

    /// This solid written to an SVG file at `path`, by the library itself.
    public func svg(_ path: String, options: SvgOptions = SvgOptions()) throws {
        try writeSvg(path, [self], options: options)
    }

    // MARK: Selecting

    /// The index of the face `selector` picks; throws when none does.
    public func selectFace(_ selector: Selector) throws -> Int {
        let h = try h()
        let index = try index32(selector.index, "select_face")
        let i: UInt32
        if let v = selector.direction {
            i = cadaclysm_blacksmith_select_face(h, selector.kind, [v.x, v.y, v.z], index)
        } else {
            i = cadaclysm_blacksmith_select_face(h, selector.kind, nil, index)
        }
        if i == none { throw failure("select_face") }
        return Int(i)
    }

    /// Twelve numbers: origin, x, y, z of the workplane on `face` -- its centre, world X laid
    /// onto it (world Y on a face facing close to X) and its outward normal, as `Frame.at`
    /// lays them. `Frame.of` reads them as a `Frame`.
    public func faceFrame(_ face: Int) throws -> [Double] {
        var out = [Double](repeating: 0, count: 12)
        if !cadaclysm_blacksmith_face_frame(try h(), try index32(face, "face_frame"), &out) {
            throw failure("face_frame")
        }
        return out
    }

    /// Face `face` by what it is, eight numbers: the surface's kind (plane 0, cylinder 1, cone 2,
    /// sphere 3, torus 4, NURBS 5, revolution 6, extrusion 7, sum 8), a point on the surface at
    /// the face's middle (x y z), the outward normal there (x y z), and the face's extent -- what
    /// a feature made on the face keeps, to find the face again with `findFace` when the solid
    /// has been rebuilt with its faces moved, split or renumbered. Take it before any move you
    /// apply to the solid, and look it up on the unmoved one.
    public func faceRef(_ face: Int) throws -> [Double] {
        var out = [Double](repeating: 0, count: 8)
        if !cadaclysm_blacksmith_face_ref(try h(), try index32(face, "face_ref"), &out) {
            throw failure("face_ref")
        }
        return out
    }

    /// The face `faceRef` (from `faceRef`) refers to: among the faces of that kind whose surface
    /// passes through the point, facing the same way, the one the point lies in -- or, where it
    /// lies in none, the one whose boundary comes nearest. `hint` is the index the face had,
    /// preferred among faces that fit equally well; `tolerance` how far the point may sit off a
    /// surface to still be on it. Nil where the face is gone.
    public func findFace(_ faceRef: [Double], hint: Int? = nil, tolerance: Double = 1e-3) throws -> Int? {
        if faceRef.count != 8 { throw BuildError("find_face: a face reference is eight numbers") }
        let found = cadaclysm_blacksmith_find_face(try h(), faceRef, Int32(hint.map { max($0, -1) } ?? -1), tolerance)
        if found == -2 { throw failure("find_face") }
        return found < 0 ? nil : Int(found)
    }

    // MARK: Colour

    /// This solid coloured (r, g, b), each in 0..1 -- or with `face` (an index, as
    /// `selectFace` returns) just that face, whose colour then wins over the solid's. What is
    /// made from a coloured solid inherits: a move keeps every colour; a boolean, fillet,
    /// chamfer or shell gives each face the colour of the face it lies on (a cut's bore the
    /// tool's), and a new face the solid's.
    public func coloured(_ colour: SIMD3<Double>, face: Int? = nil) throws -> Solid {
        let which = try faceOrNone(face, "coloured")
        return try Solid(cadaclysm_blacksmith_coloured(try h(), which, colour.x, colour.y, colour.z))
    }

    /// `coloured` with `"#rgb"` or `"#rrggbb"` (the `#` optional).
    public func coloured(_ colour: String, face: Int? = nil) throws -> Solid {
        try coloured(try rgb(colour), face: face)
    }

    /// The solid's own colour, (r, g, b) in 0..1, or nil.
    public var colour: SIMD3<Double>? {
        get throws { try colourOf(none) }
    }

    /// `face`'s colour as drawn -- its own, else the solid's -- or nil.
    public func faceColour(_ face: Int) throws -> SIMD3<Double>? {
        try colourOf(try faceOrNone(face, "colour"))
    }

    private func faceOrNone(_ face: Int?, _ what: String) throws -> UInt32 {
        guard let face else { return none }
        // A negative index would wrap to NONE, the whole solid.
        guard face >= 0, face < Int(none) else {
            throw BuildError("\(what): face \(face) is not one of the solid's \(try faces)")
        }
        return UInt32(face)
    }

    private func colourOf(_ face: UInt32) throws -> SIMD3<Double>? {
        var out = [Double](repeating: 0, count: 3)
        if cadaclysm_blacksmith_colour(try h(), face, &out) { return SIMD3(out[0], out[1], out[2]) }
        if !lastError().isEmpty { throw failure("colour") }
        return nil
    }

    /// This solid with its edges coloured (r, g, b): every edge, or with `edges` (by index,
    /// as `fillet` takes them) just those, whose colour then wins over the all-edges one; an
    /// empty list colours none. Inherited as face colours are.
    public func edgesColoured(_ colour: SIMD3<Double>, edges: [Int]? = nil) throws -> Solid {
        guard let edges else {
            return try Solid(cadaclysm_blacksmith_edges_coloured(try h(), nil, 0, colour.x, colour.y, colour.z))
        }
        let which = try indices32(edges, "edges_coloured")
        return try which.withUnsafeBufferPointer { buffer in
            // An empty list: a non-null pointer with count 0 colours none, as the C ABI reads it.
            try Solid(cadaclysm_blacksmith_edges_coloured(try h(), buffer.baseAddress ?? UnsafePointer(bitPattern: 8)!, which.count, colour.x, colour.y, colour.z))
        }
    }

    /// `edgesColoured` by `Edge`.
    public func edgesColoured(_ colour: SIMD3<Double>, edges: [Edge]) throws -> Solid {
        try edgesColoured(colour, edges: edges.map { $0.index })
    }

    /// `edgesColoured` with `"#rgb"` or `"#rrggbb"`.
    public func edgesColoured(_ colour: String, edges: [Int]? = nil) throws -> Solid {
        try edgesColoured(try rgb(colour), edges: edges)
    }

    /// Edge `edge`'s colour as drawn -- its own, else the solid's edge colour -- or nil.
    public func edgeColour(_ edge: Int) throws -> SIMD3<Double>? {
        let h = try h()
        // `UInt32(edge)` below traps on a negative Int rather than throwing, so a negative or
        // absurdly large index is caught here first -- with the same "not one of the solid's
        // N" wording `faceOrNone` uses -- before it ever reaches that conversion.
        guard edge >= 0, edge < Int(none) else {
            throw BuildError("edge_colour: edge \(edge) is not one of the solid's \(cadaclysm_blacksmith_edge_count(h))")
        }
        var out = [Double](repeating: 0, count: 3)
        if cadaclysm_blacksmith_edge_colour(h, UInt32(edge), &out) { return SIMD3(out[0], out[1], out[2]) }
        if !lastError().isEmpty { throw failure("edge_colour") }
        return nil
    }

    /// A colour per polyline of `edgePolylines` at the same tolerance, as drawn -- nil for a
    /// polyline on no coloured edge -- and empty where the solid has no edge paint at all.
    /// Copied out.
    public func edgePolylineColours(tolerance: Double = 0.05) throws -> [SIMD3<Double>?] {
        let raw = cadaclysm_blacksmith_edge_polyline_colours(try h(), tolerance)
        if raw.rgb == nil, !lastError().isEmpty { throw failure("edge_polyline_colours") }
        // This call tessellates like every other cache reader, even to report "no paint": it
        // can replace the cache a view taken earlier is still borrowing, so it must bump the
        // generation those views check, even though this method copies its own result out and
        // keeps nothing borrowed itself.
        _ = filled(tolerance)
        guard let rgb = raw.rgb else { return [] }
        let values = UnsafeBufferPointer(start: rgb, count: 3 * Int(raw.count))
        return (0..<Int(raw.count)).map { i in values[3 * i] < 0 ? nil : SIMD3(values[3 * i], values[3 * i + 1], values[3 * i + 2]) }
    }

    // MARK: Edges and finishing

    /// The edges a fillet indexes, as `Edge` records (copied; safe to keep).
    public var edges: [Edge] {
        get throws {
            let h = try h()
            let n = cadaclysm_blacksmith_edge_count(h)
            if n == 0 && !lastError().isEmpty { throw failure("edge_count") }
            var found: [Edge] = []
            found.reserveCapacity(Int(n))
            for i in 0..<n {
                var raw = CadaclysmBlacksmithEdge()
                if !cadaclysm_blacksmith_edge(h, i, &raw) { throw failure("edge") }
                let faces = raw.faces == nil ? [] : (0..<Int(raw.face_count)).map { Int(raw.faces[$0]) }
                var segments: [(start: SIMD3<Double>, end: SIMD3<Double>)] = []
                if let s = raw.segments {
                    for k in 0..<Int(raw.segment_count) {
                        let o = 6 * k
                        segments.append((SIMD3(s[o], s[o + 1], s[o + 2]), SIMD3(s[o + 3], s[o + 4], s[o + 5])))
                    }
                }
                found.append(Edge(Int(i), text(raw.kind), faces, segments, try Solid.edgeCurve(h, i)))
            }
            return found
        }
    }

    /// Edge `i`'s exact curve copied out, or nil for an edge with none (the library's
    /// "has no exact curve"); any other refusal throws.
    private static func edgeCurve(_ h: OpaquePointer, _ i: UInt32) throws -> Curve? {
        var raw = CadaclysmBlacksmithCurve()
        if cadaclysm_blacksmith_edge_curve(h, i, &raw) { return Curve(raw) }
        if lastError().contains("has no exact curve") { return nil }
        throw failure("edge_curve")
    }

    /// Round `edges` with `radius`. Exact: the blend faces are cylinders, tori and NURBS, and
    /// the neighbours are trimmed back onto them.
    public func fillet(_ edges: [Edge], _ radius: Double, tolerance: Double = 1e-6) throws -> Solid {
        try fillet(edges.map { $0.index }, radius, tolerance: tolerance)
    }

    /// `fillet` by edge index.
    public func fillet(_ edges: [Int], _ radius: Double, tolerance: Double = 1e-6) throws -> Solid {
        let which = try indices32(edges, "fillet")
        return try Solid(cadaclysm_blacksmith_fillet(try h(), which, which.count, radius, tolerance, nil, nil))
    }

    /// `fillet` with a flat bevel: each edge cut back `distance` along both its faces.
    public func chamfer(_ edges: [Edge], _ distance: Double, tolerance: Double = 1e-6) throws -> Solid {
        try chamfer(edges.map { $0.index }, distance, tolerance: tolerance)
    }

    /// `chamfer` by edge index.
    public func chamfer(_ edges: [Int], _ distance: Double, tolerance: Double = 1e-6) throws -> Solid {
        let which = try indices32(edges, "chamfer")
        return try Solid(cadaclysm_blacksmith_chamfer(try h(), which, which.count, distance, tolerance))
    }

    /// Face `face` pushed out by `distance` along its outward normal (pulled in, negative) as a face extrude does it: the prism over it joined on (cut out), and the
    /// flush faces merged -- a box's top raised is one taller box of six faces. A face on a
    /// cylinder, a cone, a sphere or a torus moves out along its normal instead, the surface a
    /// step out -- a boss fatter, a bore narrower, a dome fuller -- with the flat faces beside
    /// it carried along; any other curved face is refused. `tolerance` as `join`'s.
    public func pushPull(_ face: Int, _ distance: Double, tolerance: Double = 0.05) throws -> Solid {
        try Solid(cadaclysm_blacksmith_push_pull(try h(), try index32(face, "push_pull"), distance, tolerance, nil, nil))
    }

    /// Faces `faces` pushed out by `distance` together -- a press-pull on a selection:
    /// each by `pushPull`'s rule for it, one after another, each found again after the pushes
    /// before it renumbered the faces. A box's top and a side pushed 5 is the box 5 taller and
    /// 5 wider; a face on the same curved surface as one before it, and joined to it, moved
    /// with that one and is not pushed twice. No faces is refused.
    public func pushPull(_ faces: [Int], _ distance: Double, tolerance: Double = 0.05) throws -> Solid {
        let which = try indices32(faces, "push_pull")
        return try Solid(cadaclysm_blacksmith_push_pull_faces(try h(), which, which.count, distance, tolerance, nil, nil))
    }

    /// The round `face` belongs to -- a fillet's bands, balls and rim bands joined to that face
    /// -- made again at `radius`, as a press-pull on a fillet face: taken back to the
    /// sharp edges it replaced, and those rounded again. Rounds of straight edges between
    /// planes and of circular rims beside a plane.
    public func refillet(_ face: Int, _ radius: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_refillet(try h(), try index32(face, "refillet"), radius, tolerance))
    }

    /// The round `face` belongs to taken off, the faces beside it sharp again -- the delete of a fillet face. The same rounds as `refillet`.
    public func unfillet(_ face: Int) throws -> Solid {
        try Solid(cadaclysm_blacksmith_unfillet(try h(), try index32(face, "unfillet")))
    }

    /// The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner
    /// triangles joined to that face -- cut again at `distance`, as a press-pull on a
    /// chamfer face: taken back to the sharp edges it cut, and those bevelled again.
    public func rechamfer(_ face: Int, _ distance: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_rechamfer(try h(), try index32(face, "rechamfer"), distance, tolerance))
    }

    /// The chamfer `face` belongs to taken off, the faces beside it sharp again -- the delete of a chamfer face. The same chamfers as `rechamfer`.
    public func unchamfer(_ face: Int) throws -> Solid {
        try Solid(cadaclysm_blacksmith_unchamfer(try h(), try index32(face, "unchamfer")))
    }

    /// This sheet made a solid `thickness` thick: its faces, their twins
    /// moved `thickness` along the faces' normals (against them for a negative thickness),
    /// and a wall round every open edge. A closed sheet thickens to a hollow.
    public func thicken(_ thickness: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_thicken(try h(), thickness, tolerance, nil, nil))
    }

    /// This solid split by `tool` into bodies: a closed `tool` gives the
    /// parts outside it, then the parts inside; a flat sheet (a `face`) splits by the whole
    /// plane it lies on. Each connected part is a body of its own, so a U cut across both arms
    /// is three. The new faces are pieces of the tool's; colours carry over.
    public func split(_ tool: Solid, tolerance: Double = 0.05) throws -> [Solid] {
        let all = try withExtendedLifetime(tool) {
            try Solid(cadaclysm_blacksmith_split(try h(), try tool.h(), tolerance, nil, nil))
        }
        defer { all.close() }
        return try all.lumps()
    }

    /// This solid split by the plane through `plane`'s origin, square to its z: the bodies in
    /// front of it (on z's side) first, then those behind.
    public func splitByPlane(_ plane: Frame, tolerance: Double = 0.05) throws -> [Solid] {
        let all = try Solid(cadaclysm_blacksmith_split_by_plane(try h(), plane.values, tolerance, nil, nil))
        defer { all.close() }
        return try all.lumps()
    }

    /// This solid's connected bodies, each a solid of its own -- faces sharing an edge are one
    /// body -- in the order of their first faces. One body comes back as itself.
    public func lumps() throws -> [Solid] {
        let h = try h()
        let n = cadaclysm_blacksmith_lump_count(h)
        if n == 0 { throw failure("lump_count") }
        return try (0..<n).map { try Solid(cadaclysm_blacksmith_lump(h, $0)) }
    }

    /// This solid with its flush faces merged: flat faces on one plane, facing one way and
    /// meeting, made one face, and the vertices left mid-way along a straight edge taken out
    /// -- the seams a `join` leaves where two parts are flush.
    public func mergeFlush() throws -> Solid {
        try Solid(cadaclysm_blacksmith_merge_flush(try h()))
    }

    /// Hollow the solid to walls `thickness` thick -- inward for a positive thickness, outward
    /// for a negative one. The faces at `open` are removed so the hollow is reachable.
    public func shell(_ thickness: Double, open openFaces: [Int] = [], tolerance: Double = 1e-6) throws -> Solid {
        let which = try indices32(openFaces, "shell")
        return try Solid(cadaclysm_blacksmith_shell(try h(), thickness, which, which.count, tolerance, nil, nil))
    }

    // MARK: - Files (needs the reader)

    /// The body `node` of a reader `Scene` draws, as a solid -- **sharing the reader's brep,
    /// not copying it**. The scene can be closed before the solid is: the brep lives on.
    ///
    /// `placed` puts it where the node's `transform` does, which is where its mesh draws; a
    /// node at the identity (a part file's one body) stays shared, a moved one is a moved copy.
    /// `placed: false` keeps the node's own frame. In the file's own units and axes either
    /// way, so `placed` needs the scene opened `.native` unless the node is at the identity. A
    /// block member is drawn once per placement of its block: iterate `scene.placements` for
    /// those, or use `openAll`.
    ///
    /// The reader library must come from the same release as this one's: the brep is handed
    /// across by pointer, and the two libraries' layouts (`brepLayoutId()`) are compared first.
    public static func fromNode(_ scene: Scene, _ node: Node, placed: Bool = true) throws -> Solid {
        let label = !node.name.isEmpty ? node.name : !node.kind.isEmpty ? node.kind : "?"
        let what = "from_node: node \(node.index) (\(label))"
        guard let solid = try fromBrep(node) else {
            throw BuildError("\(what) has no brep: only a B-rep body has one (STEP, ACIS, Rhino, BREP (.brep), "
                + "IGES, IFC), not a mesh, a curve or a CSG body")
        }
        if !placed { return solid }
        let transform = node.transform
        if scene.convention != .native && !isIdentity(transform) {
            throw BuildError("from_node: placed=True needs the scene opened with Convention.NATIVE -- the brep is in "
                + "the file's own axes and the node's transform is not; open .native, or pass placed: false")
        }
        return try solid.placed(transform, "from_node")
    }

    /// `fromNode` by the node's index in `scene`.
    public static func fromNode(_ scene: Scene, _ node: Int, placed: Bool = true) throws -> Solid {
        let count = scene.nodes.count
        guard node >= 0, node < count else {
            throw BuildError("from_node: no node \(node) -- the scene has \(count)")
        }
        return try fromNode(scene, Node(scene, node), placed: placed)
    }

    /// The body a CAD file holds, as a solid: a STEP (AP203/214/242), ACIS `.sat`, Rhino
    /// `.3dm`, BREP (`.brep`), IGES or IFC file, read where it draws, in the file's own units
    /// and axes. A file drawing several bodies needs `body` (0-based, in drawing order) or
    /// `openAll`.
    ///
    /// What such a solid can do is what its geometry allows: fillet and chamfer want line and
    /// circle edges; booleans take any surface, but the new edges they trace on a free-form
    /// (NURBS) face are not always writable back to STEP; and every verb meshes its operands
    /// first, so its cost grows with the body's face count. Reads through the reader library
    /// (`Cadaclysm.open`), handing each body across as `fromNode` does.
    public static func open(_ path: String, body: Int? = nil) throws -> Solid {
        let solids = try openAll(path)
        let name = URL(fileURLWithPath: path).lastPathComponent
        if body == nil && solids.count == 1 { return solids[0] }
        guard let body else {
            solids.forEach { $0.close() }
            throw BuildError("open: \(name) holds \(solids.count) bodies: pass body: (0 to \(solids.count - 1)), "
                + "or use Solid.openAll")
        }
        guard body >= 0, body < solids.count else {
            solids.forEach { $0.close() }
            throw BuildError("open: \(name) has no body \(body): it holds \(solids.count)")
        }
        for (i, solid) in solids.enumerated() where i != body { solid.close() }
        return solids[body]
    }

    /// Every body a CAD file draws, as solids placed where it draws them: one per placement,
    /// so a part placed twice is two solids. A placement that scales or shears is refused (a
    /// brep cannot follow it exactly). See `open`.
    public static func openAll(_ path: String) throws -> [Solid] {
        let scene: Scene
        do {
            scene = try Cadaclysm.open(path)
        } catch let error as CadaclysmError {
            throw BuildError("open: \(error.message)")
        }
        defer { scene.close() }
        var solids: [Solid] = []
        do {
            for placement in scene.placements {
                let node = placement.geometry
                let label = !node.name.isEmpty ? node.name : !node.kind.isEmpty ? node.kind : "\(node.index)"
                if let solid = try fromBrep(node) {
                    solids.append(try solid.placed(placement.transform, "open: \(label)"))
                }
            }
        } catch {
            solids.forEach { $0.close() }
            throw error
        }
        if solids.isEmpty {
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            throw BuildError("open: the .\(ext) file draws no B-rep body -- only a STEP, ACIS, Rhino, BREP (.brep), "
                + "IGES or IFC body can be a solid, not a mesh, a curve or a CSG body")
        }
        return solids
    }

    /// The node's brep as a solid, shared: the reader's reference handed across and given
    /// straight back, the solid holding one of its own. Nil where the node has no brep.
    private static func fromBrep(_ node: Node) throws -> Solid? {
        guard let brep = node.brep else { return nil }
        defer { brep.release() }
        return try Solid(cadaclysm_blacksmith_from_brep(brep.pointer, Brep.layoutId()))
    }

    private static func isIdentity(_ m: [[Double]]) -> Bool {
        (0..<4).allSatisfy { i in (0..<4).allSatisfy { j in m[i][j] == (i == j ? 1.0 : 0.0) } }
    }

    /// This solid moved by a 4x4 row-major placement: itself at the identity, a moved copy for
    /// a rigid move (a mirror included; this one freed), refused for a scale or shear, which a
    /// brep cannot follow exactly (a cylinder's radius is a number, not a point).
    private func placed(_ m: [[Double]], _ what: String) throws -> Solid {
        if Solid.isIdentity(m) { return self }
        // The axes' Gram matrix against the identity, as numpy's allclose (atol 1e-9, rtol
        // 1e-5) reads it in Python's `_placed`.
        for a in 0..<3 {
            for b in 0..<3 {
                let dot = m[0][a] * m[0][b] + m[1][a] * m[1][b] + m[2][a] * m[2][b]
                let want = a == b ? 1.0 : 0.0
                if abs(dot - want) > 1e-9 + 1e-5 * want {
                    throw BuildError("\(what): the placement scales or shears, which a brep cannot follow")
                }
            }
        }
        defer { close() }
        // Unchecked, as twelve numbers: a mirror is a left-handed frame, which `Frame` refuses.
        return try place(raw: [m[0][3], m[1][3], m[2][3], m[0][0], m[1][0], m[2][0],
                               m[0][1], m[1][1], m[2][1], m[0][2], m[1][2], m[2][2]])
    }

    /// This solid as a reader `Scene`, through STEP text and `Cadaclysm.openMemory` -- the door
    /// to the reader's tree, meshes and glTF/OBJ export. `schema` as `stepText` takes it; the
    /// reader is given the schema's **path** only when it names an existing file, since it
    /// carries every built-in schema itself and there is no file here to read a `FILE_SCHEMA`
    /// line out of.
    public func toScene(schema: String? = nil) throws -> Scene {
        let schemaPath = schema.flatMap { !$0.contains("\n") && isFile($0) ? $0 : nil }
        let text = try stepText(schema: schema)
        return try Cadaclysm.openMemory(Data(text.utf8), format: "stp", schema: schemaPath)
    }
}

// MARK: - Assemblies

/// A mutable tree of placements: a name, and zero or more solids or other assemblies
/// placed in it at a frame. `place` returns the placement's name so a caller can keep
/// it. Unlike `Solid`, placing shares rather than copies -- placing one assembly under
/// another does not snapshot it, so a later placement on the shared one shows up
/// wherever it already sits (see `place(_:_:name:)`'s own note on cycles). `close()`
/// frees this handle; it does **not** free what was placed in it if that is still
/// reachable from somewhere else.
public final class Assembly {
    private var handle: OpaquePointer?

    /// A new, empty assembly called `name`. Refused for an empty name.
    public init(_ name: String) throws {
        handle = try checked(cadaclysm_blacksmith_assembly_new(name), "assembly_new")
    }

    deinit { close() }

    /// Free the assembly now. Idempotent; every call on it afterwards throws.
    public func close() {
        if let handle { cadaclysm_blacksmith_assembly_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("assembly: closed") }
        return handle
    }

    /// This assembly's own name, given when it was made.
    public var name: String { get throws { text(cadaclysm_blacksmith_assembly_name(try h())) } }

    /// Place `solid` at `frame` (must be right-handed and orthonormal) in this assembly,
    /// called `name` -- or, with `name` nil, `solid`'s own name (`Solid.name`, `"part"`
    /// for an unnamed one), numbered past any already taken here (`"bolt"`, `"bolt 2"`,
    /// ...). An explicit `name` already taken here is refused. Returns the placement's
    /// name.
    @discardableResult
    public func place(_ solid: Solid, _ frame: Frame, name: String? = nil) throws -> String {
        try place(solid, raw: frame.values, name: name)
    }

    /// As `place(_:_:name:)`, but placing another assembly, `assembly`, rather than a
    /// solid -- sharing it, not copying it, so a later placement on `assembly` (through
    /// this assembly or another) shows up wherever it is placed. Placing `assembly` as
    /// this assembly itself, or anywhere above this assembly in the tree already, is
    /// refused, naming the cycle, since writing that out would never terminate.
    @discardableResult
    public func place(_ assembly: Assembly, _ frame: Frame, name: String? = nil) throws -> String {
        try place(assembly, raw: frame.values, name: name)
    }

    /// `place(_:_:name:)` with a raw, unchecked twelve-number frame: a placement's
    /// mirror is a left-handed frame, which `Frame`'s own initialiser refuses and the
    /// kernel takes -- the same unchecked route `Solid.place(raw:)` uses for the same
    /// fact, so a mirrored frame reaches the library's own check rather than `Frame`'s.
    @discardableResult
    func place(_ solid: Solid, raw frame: [Double], name: String? = nil) throws -> String {
        let raw = try withOptionalCString(name) { cname in
            cadaclysm_blacksmith_assembly_place_solid(try h(), try solid.h(), try frameValues(frame), cname)
        }
        return try placeResult(raw, "assembly_place_solid")
    }

    @discardableResult
    func place(_ assembly: Assembly, raw frame: [Double], name: String? = nil) throws -> String {
        let raw = try withOptionalCString(name) { cname in
            cadaclysm_blacksmith_assembly_place_assembly(try h(), try assembly.h(), try frameValues(frame), cname)
        }
        return try placeResult(raw, "assembly_place_assembly")
    }

    /// This assembly, and everything placed under it, as one STEP file: this assembly
    /// the root product, each sub-assembly and each distinct part written once, each
    /// placement an occurrence named as it was placed. `schema` and `unit` as
    /// `Solid.stepText`. Refused if this assembly, or a sub-assembly reachable from it,
    /// places nothing -- a reader would never show it.
    public func stepText(schema: String? = nil, unit: String = "mm") throws -> String {
        guard let code = units[unit] else { throw BuildError("unit must be one of ['in', 'm', 'mm']") }
        let handle = try h()
        let schemaText = try schemaBytes(schema)
        let raw: UnsafeMutablePointer<CChar>?
        if let schemaText {
            raw = schemaText.withUnsafeBufferPointer {
                cadaclysm_blacksmith_assembly_step(handle, $0.baseAddress, code)
            }
        } else {
            raw = cadaclysm_blacksmith_assembly_step(handle, nil, code)
        }
        guard let raw else { throw failure("assembly_step") }
        defer { cadaclysm_blacksmith_string_free(raw) }
        return String(cString: raw)
    }

    /// This assembly written to a STEP file at `path`.
    public func step(_ path: String, schema: String? = nil, unit: String = "mm") throws {
        let text = try stepText(schema: schema, unit: unit)
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// This assembly as a reader `Scene`, through STEP text -- see `Solid.toScene`.
    public func toScene(schema: String? = nil) throws -> Scene {
        let schemaPath = schema.flatMap { !$0.contains("\n") && isFile($0) ? $0 : nil }
        let text = try stepText(schema: schema)
        return try Cadaclysm.openMemory(Data(text.utf8), format: "stp", schema: schemaPath)
    }
}

/// The owned text `Assembly.place` returns -- the placement's name -- read out and
/// freed; throws on a refusal.
private func placeResult(_ raw: UnsafeMutablePointer<CChar>?, _ what: String) throws -> String {
    guard let raw else { throw failure(what) }
    defer { cadaclysm_blacksmith_string_free(raw) }
    return String(cString: raw)
}

/// Runs `body` with `text` as a NUL-terminated C string, or nil where `text` is nil.
private func withOptionalCString<R>(_ text: String?, _ body: (UnsafePointer<CChar>?) throws -> R) throws -> R {
    guard let text else { return try body(nil) }
    return try text.withCString { try body($0) }
}

/// The three world axes `Selector.max` and `Selector.min` take.
public enum Axis: Int {
    case x = 0
    case y = 1
    case z = 2
}

/// Which face: furthest along an axis, furthest against it, by outward normal, or by index
/// -- `Selector::Max/Min/Normal/Index` in the crate. Used by `Workplane.faces` and
/// `Solid.selectFace`.
public struct Selector {
    let kind: UInt32
    let direction: SIMD3<Double>?
    let index: Int

    private init(_ kind: UInt32, _ direction: SIMD3<Double>?, _ index: Int) {
        self.kind = kind
        self.direction = direction
        self.index = index
    }

    /// The face furthest along `axis`.
    public static func max(_ axis: Axis) -> Selector { Selector(0, nil, axis.rawValue) }

    /// The face furthest against `axis`.
    public static func min(_ axis: Axis) -> Selector { Selector(1, nil, axis.rawValue) }

    /// The face whose outward normal is nearest `direction` (need not be unit).
    public static func normal(_ direction: SIMD3<Double>) -> Selector { Selector(2, direction, 0) }

    /// The face with index `i`.
    public static func index(_ i: Int) -> Selector { Selector(3, nil, i) }
}

/// One edge's, or one intersection chain's, exact curve as plain data copied out
/// (`Edge.curve`, `Chain.curve`): `kind` is `"line"`, `"circle"`, `"ellipse"` or `"nurbs"`.
///
/// `t0..t1` is the edge's parameter range on its own curve: a line's fraction (0..1 over
/// `origin -> origin + x`, where `x` is the full `to - from`, NOT unit -- so
/// `point(t) = origin + x*t`); a circle's or ellipse's angle in radians about `origin` in
/// the `x, y` plane (`point(t) = origin + x*radius*cos(t) + y*radius2*sin(t)`,
/// `radius2 = radius` for a circle); a NURBS's knot parameter
/// (`knots[degree] <= t0 < t1 <= knots[n]`). Frame vectors `x, y, z` are unit for conics;
/// for a line `x` is the direction with length = the line's length and `y, z` are zero.
///
/// For a NURBS the frame is zero and so are the radii; for a conic or a line `degree` is 0
/// and `knots`, `poles` are empty. `knots.count == poles.count + degree + 1`; `weights` is
/// one per pole, or nil for a non-rational (plain B-spline) curve, a conic or a line.
public struct Curve: Equatable, CustomStringConvertible {
    public let kind: String
    public let origin: SIMD3<Double>
    public let x: SIMD3<Double>
    public let y: SIMD3<Double>
    public let z: SIMD3<Double>
    public let radius: Double
    public let radius2: Double
    public let t0: Double
    public let t1: Double
    public let degree: Int
    /// The knot vector.
    public let knots: [Double]
    /// The control points.
    public let poles: [SIMD3<Double>]
    /// One weight per pole, or nil for a non-rational curve.
    public let weights: [Double]?

    init(_ raw: CadaclysmBlacksmithCurve) {
        let p = { (q: CadaclysmBlacksmithPoint) in SIMD3(q.x, q.y, q.z) }
        let doubles = { (at: UnsafePointer<Double>?, n: Int) -> [Double] in
            guard let at, n > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: at, count: n))
        }
        kind = text(raw.kind)
        origin = p(raw.origin)
        x = p(raw.x)
        y = p(raw.y)
        z = p(raw.z)
        radius = raw.radius
        radius2 = raw.radius2
        t0 = raw.t0
        t1 = raw.t1
        degree = Int(raw.degree)
        knots = doubles(raw.knots, Int(raw.knot_count))
        let flat = doubles(raw.poles, 3 * Int(raw.pole_count))
        poles = stride(from: 0, to: flat.count, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
        weights = raw.weights == nil ? nil : doubles(raw.weights, Int(raw.pole_count))
    }

    public var description: String {
        kind == "nurbs"
            ? "Curve('nurbs', degree=\(degree), poles=\(poles.count), rational=\(weights != nil), t0=\(t0), t1=\(t1))"
            : "Curve('\(kind)', origin=(\(origin.x), \(origin.y), \(origin.z)), radius=\(radius), t0=\(t0), t1=\(t1))"
    }
}

/// One edge of a solid, as plain data: its index (what `Solid.fillet` takes), the curve
/// kind, the faces meeting on it, its segments' ends, and its exact `Curve`.
public struct Edge: CustomStringConvertible {
    /// Its index -- what `Solid.fillet` and `Solid.chamfer` take.
    public let index: Int
    /// The curve: `"line"`, `"circle"`, `"ellipse"`, `"parabola"`, `"hyperbola"`, `"nurbs"` or `"other"`.
    public let kind: String
    /// The faces meeting on it, as face indices.
    public let faces: [Int]
    /// The two ends of each piece of the edge.
    public let segments: [(start: SIMD3<Double>, end: SIMD3<Double>)]
    /// The edge's exact curve, or nil for an edge with none (kind `"other"`).
    public let curve: Curve?

    public init(_ index: Int, _ kind: String, _ faces: [Int], _ segments: [(start: SIMD3<Double>, end: SIMD3<Double>)], _ curve: Curve? = nil) {
        self.index = index
        self.kind = kind
        self.faces = faces
        self.segments = segments
        self.curve = curve
    }

    /// Whether the edge is straight.
    public var isLine: Bool { kind == "line" }

    /// Unit direction of a line edge (from its first segment), else nil.
    public var direction: SIMD3<Double>? {
        guard isLine, let first = segments.first else { return nil }
        let d = first.end - first.start
        let n = (d * d).sum().squareRoot()
        return n > 0 ? d / n : nil
    }

    public var description: String {
        "Edge(\(index), '\(kind)', faces=(\(faces.map(String.init).joined(separator: ", "))))"
    }
}

/// Whether a solid's faces make a manifold, as plain data (`Solid.manifold`): its faces,
/// edges and vertices; the edges one face borders (a sheet's rim), the edges three or more
/// do, and the vertices whose faces make more than one fan (two solids touching at a
/// corner); `isManifold` where there are none of the last two, and `isClosed` where there is
/// no boundary edge either -- it encloses a solid.
public struct Manifold: Equatable, CustomStringConvertible {
    /// How many faces.
    public let faces: Int
    /// How many distinct edges: one shared by two faces counts once.
    public let edges: Int
    /// How many distinct vertices.
    public let vertices: Int
    /// Edges only one face borders: a sheet's rim, a hole in a shell.
    public let boundaryEdges: Int
    /// Edges three or more faces border: a fin, or two solids meeting along a line.
    public let nonManifoldEdges: Int
    /// Vertices whose faces make more than one fan: two solids touching at a corner.
    public let nonManifoldVertices: Int
    /// No non-manifold edge or vertex: a manifold, possibly with a boundary.
    public let isManifold: Bool
    /// A manifold with no boundary edge either: it encloses a solid.
    public let isClosed: Bool

    init(_ row: [UInt32]) {
        faces = Int(row[0])
        edges = Int(row[1])
        vertices = Int(row[2])
        boundaryEdges = Int(row[3])
        nonManifoldEdges = Int(row[4])
        nonManifoldVertices = Int(row[5])
        isManifold = row[6] != 0
        isClosed = row[7] != 0
    }

    public var description: String {
        "Manifold(faces=\(faces), edges=\(edges), vertices=\(vertices), boundary_edges=\(boundaryEdges), "
            + "non_manifold_edges=\(nonManifoldEdges), non_manifold_vertices=\(nonManifoldVertices), "
            + "is_manifold=\(isManifold), is_closed=\(isClosed))"
    }
}

/// Where a hit lands on one side: a profile's `loopIndex` (0 the boundary or the open chain,
/// then the holes in the order they were added), `segment`, and `t` from 0 to 1 along it,
/// with `face` NONE (`UInt32.max`) -- or a solid's `face` at (`u`, `v`), with the loop and
/// segment NONE.
public struct Spot: Equatable, CustomStringConvertible {
    /// The loop: 0 the boundary or the open chain, then the holes in the order they were added.
    public let loopIndex: UInt32
    /// The segment of that loop, in drawing order.
    public let segment: UInt32
    /// How far along the segment, 0 at its start to 1 at its end.
    public let t: Double
    /// The face, on a solid; NONE on a profile.
    public let face: UInt32
    /// The face's first surface parameter; 0 on a profile.
    public let u: Double
    /// The face's second surface parameter; 0 on a profile.
    public let v: Double

    init(_ raw: CadaclysmBlacksmithSpot) {
        loopIndex = raw.loop_index
        segment = raw.segment
        t = raw.t
        face = raw.face
        u = raw.u
        v = raw.v
    }

    public var description: String {
        "Spot(loop_index=\(loopIndex), segment=\(segment), t=\(t), face=\(face), u=\(u), v=\(v))"
    }
}

/// `count` xyz triples at `at`, copied out as points.
func pointsAt(_ at: UnsafePointer<Double>?, _ count: UInt32) -> [SIMD3<Double>] {
    guard let at, count > 0 else { return [] }
    let flat = UnsafeBufferPointer(start: at, count: 3 * Int(count))
    return stride(from: 0, to: flat.count, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
}

/// What `Solid.hits` found, copied out: `hits` (ordered along the profile; `aStart`/`aEnd`
/// on the profile, `bStart`/`bEnd` on the solid's faces: a `face` at (`u`, `v`)) and
/// `pieces` (empty for an open body).
public struct SolidHits: CustomStringConvertible {
    public let hits: [Hit]
    public let pieces: [Piece]

    public var description: String { "SolidHits(hits=\(hits.count), pieces=\(pieces.count))" }
}

/// One stretch of a profile loop between two cuts (`SolidHits.pieces`): `inside` (by its
/// middle's winding number over the body; a piece lying on the surface is inside),
/// `start`/`end` (profile spots -- a segment join reads as the next segment's start
/// `(k + 1, 0)`, an open chain runs from `(0, 0)` to `(n - 1, 1)`; a loop no hit cuts is one
/// closed piece) and `profile`, the piece's own open chain (what `SweepPath.along` with
/// `open` sweeps).
public struct Piece: CustomStringConvertible {
    public let inside: Bool
    public let start: Spot
    public let end: Spot
    public let profile: Profile

    public var description: String { "Piece(inside=\(inside), start=\(start), end=\(end))" }
}

/// What `Solid.intersect` found, copied out: `chains` (one per face pair per branch) and
/// `overlaps` (one per coincident face pair). Both empty where the solids do not meet.
public struct Intersection: Equatable, CustomStringConvertible {
    public let chains: [Chain]
    public let overlaps: [Overlap]

    public var description: String { "Intersection(chains=\(chains.count), overlaps=\(overlaps.count))" }
}

/// One branch of one face pair's crossing (`Intersection.chains`): `points` in walk order
/// (a closed chain does not repeat its first point), `closed`, the faces (`faceA` in the
/// first solid, `faceB` in the second), `tangent` (the surfaces near-tangent along it, or
/// the snap unsettled -- the points their best estimate) and `curve`, its exact curve over
/// the chain's own `t0..t1`, or nil where the kernel found none. A chain may stop at a face
/// boundary or a closed curve's seam and continue as another: join chains by matching ends.
public struct Chain: Equatable, CustomStringConvertible {
    public let points: [SIMD3<Double>]
    public let closed: Bool
    public let faceA: Int
    public let faceB: Int
    public let tangent: Bool
    public let curve: Curve?

    init(_ raw: CadaclysmBlacksmithChain, _ curve: Curve?) {
        points = pointsAt(raw.points, raw.point_count)
        closed = raw.closed
        faceA = Int(raw.face_a)
        faceB = Int(raw.face_b)
        tangent = raw.tangent
        self.curve = curve
    }

    public var description: String {
        "Chain(points=\(points.count), closed=\(closed), faces=(\(faceA), \(faceB)), tangent=\(tangent), curve=\(curve.map { $0.description } ?? "nil"))"
    }
}

/// A face of the first solid and a face of the second that coincide
/// (`Intersection.overlaps`): the faces (`faceA`, `faceB`) and `loops`, the shared region's
/// rings (outer first, holes after; each ring closed without repeating its first point) --
/// empty for a partial overlap whose outlines cross.
public struct Overlap: Equatable, CustomStringConvertible {
    public let faceA: Int
    public let faceB: Int
    public let loops: [[SIMD3<Double>]]

    init(_ raw: CadaclysmBlacksmithOverlap) {
        faceA = Int(raw.face_a)
        faceB = Int(raw.face_b)
        let points = pointsAt(raw.points, raw.point_count)
        var starts: [Int] = []
        if let at = raw.loop_offsets, raw.loop_count > 0 {
            starts = UnsafeBufferPointer(start: at, count: Int(raw.loop_count)).map { Int($0) }
        }
        loops = starts.indices.map { r in
            Array(points[starts[r]..<(r + 1 < starts.count ? starts[r + 1] : Int(raw.point_count))])
        }
    }

    public var description: String { "Overlap(faces=(\(faceA), \(faceB)), loops=\(loops.count))" }
}

/// One place two curves meet, copied out (`Profile.hits`). A point (`run` false): `start`
/// equals `end`, and `touch` is true where the curves are tangent rather than crossing. A run
/// (`run` true): they coincide from `start` to `end`. `aStart`/`aEnd` are where on the first
/// curve, `bStart`/`bEnd` where on the second. A point at the join of two segments is
/// reported once, on either: as segment k at `t` 1 or as segment k + 1 at `t` 0.
public struct Hit: Equatable, CustomStringConvertible {
    /// Whether the curves coincide along a stretch rather than meeting at a point.
    public let run: Bool
    /// For a point: the curves are tangent there rather than crossing.
    public let touch: Bool
    /// Where it starts (`z` is 0 for two profiles).
    public let start: SIMD3<Double>
    /// Where it ends: `start` again for a point.
    public let end: SIMD3<Double>
    /// Where it starts on the first curve.
    public let aStart: Spot
    /// Where it ends on the first curve.
    public let aEnd: Spot
    /// Where it starts on the second curve.
    public let bStart: Spot
    /// Where it ends on the second curve.
    public let bEnd: Spot

    init(_ raw: CadaclysmBlacksmithHit) {
        run = raw.run
        touch = raw.touch
        start = SIMD3(raw.start.x, raw.start.y, raw.start.z)
        end = SIMD3(raw.end.x, raw.end.y, raw.end.z)
        aStart = Spot(raw.a_start)
        aEnd = Spot(raw.a_end)
        bStart = Spot(raw.b_start)
        bEnd = Spot(raw.b_end)
    }

    public var description: String {
        "Hit(run=\(run), touch=\(touch), start=(\(start.x), \(start.y), \(start.z)), "
            + "end=(\(end.x), \(end.y), \(end.z)))"
    }
}

// MARK: - Frames

private let xyValues: [Double] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
private let xzValues: [Double] = [0, 0, 0, 1, 0, 0, 0, 0, 1, 0, -1, 0]
private let yzValues: [Double] = [0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0]

/// How far from square a frame's axes may be (the cosine between two of them).
private let square = 1e-6

private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
    SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
}

private func unit(_ v: SIMD3<Double>, _ what: String) throws -> SIMD3<Double> {
    let n = dot(v, v).squareRoot()
    guard n > 1e-12, n < .infinity else { throw BuildError("\(what) has no direction") }
    return v / n
}

/// An origin and three unit axes, square to each other and right-handed (z = x × y): the
/// plane a profile is drawn on (its x/y) and the direction it is built along (its z). Every
/// call taking a frame takes one. Immutable. The constructor normalises the axes and throws
/// `BuildError` when they are not square or not right-handed.
public struct Frame: Hashable, CustomStringConvertible {
    /// The twelve numbers every call taking a frame reads: origin, x, y, z.
    public let values: [Double]

    /// The frame with these axes, normalised; throws when they are not square to each other
    /// (a cosine over 1e-6) or not right-handed.
    public init(_ origin: SIMD3<Double>, _ x: SIMD3<Double>, _ y: SIMD3<Double>, _ z: SIMD3<Double>) throws {
        guard origin.x.isFinite, origin.y.isFinite, origin.z.isFinite else {
            throw BuildError("Frame: origin must be three finite numbers")
        }
        let x = try unit(x, "Frame: x"), y = try unit(y, "Frame: y"), z = try unit(z, "Frame: z")
        if Swift.max(abs(dot(x, y)), abs(dot(y, z)), abs(dot(z, x))) > square {
            throw BuildError("Frame: the axes are not square to each other")
        }
        if dot(cross(x, y), z) < 0 {
            throw BuildError("Frame: the axes are left-handed (z must be x × y)")
        }
        // + 0.0: no -0.0 to print or compare
        values = [origin.x, origin.y, origin.z, x.x, x.y, x.z, y.x, y.y, y.z, z.x, z.y, z.z].map { $0 + 0.0 }
    }

    /// Twelve numbers -- what `Solid.faceFrame` and `Workplane.frame` hand back -- checked as
    /// the constructor checks.
    public init(values: [Double]) throws {
        let v = try frameValues(values)
        try self.init(SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]), SIMD3(v[9], v[10], v[11]))
    }

    /// Twelve numbers as a checked frame, to read its axes or move it: `Frame(values:)`.
    public static func of(_ values: [Double]) throws -> Frame {
        try Frame(values: values)
    }

    /// The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line.
    public static func midplane(_ a: Frame, _ b: Frame) throws -> Frame {
        var out = [Double](repeating: 0, count: 12)
        if !cadaclysm_blacksmith_frame_midplane(a.values, b.values, &out) { throw failure("frame_midplane") }
        return try Frame(values: out)
    }

    /// The plane through three points: its origin p, its x towards q, its z the normal they turn about counter-clockwise. Throws for three points on one line.
    public static func through(_ p: SIMD3<Double>, _ q: SIMD3<Double>, _ r: SIMD3<Double>) throws -> Frame {
        var out = [Double](repeating: 0, count: 12)
        if !cadaclysm_blacksmith_frame_through([p.x, p.y, p.z], [q.x, q.y, q.z], [r.x, r.y, r.z], &out) { throw failure("frame_through") }
        return try Frame(values: out)
    }

    private static func world(_ v: [Double], _ origin: SIMD3<Double>) throws -> Frame {
        try Frame(origin, SIMD3(v[3], v[4], v[5]), SIMD3(v[6], v[7], v[8]), SIMD3(v[9], v[10], v[11]))
    }

    /// The world XY plane through `origin`: z up, as `Workplane.xy`.
    public static func xy(_ origin: SIMD3<Double> = .zero) throws -> Frame { try world(xyValues, origin) }

    /// The world XZ plane through `origin`: x along X, y along Z, so z is -Y, as `Workplane.xz`.
    public static func xz(_ origin: SIMD3<Double> = .zero) throws -> Frame { try world(xzValues, origin) }

    /// The world YZ plane through `origin`: x along Y, y along Z, so z is +X, as `Workplane.yz`.
    public static func yz(_ origin: SIMD3<Double> = .zero) throws -> Frame { try world(yzValues, origin) }

    /// The plane through `origin` square to `normal` (the frame's z; it need not be unit). Its
    /// x axis is `x` laid onto that plane; with none, world X laid onto it, or world Y when
    /// the normal is within about 25° of X -- the axes `Solid.faceFrame` gives a face facing
    /// `normal`. So a normal along +Z, -Y or +X gives exactly `xy`, `xz` or `yz`. A zero
    /// normal, or an `x` along the normal, throws.
    public static func at(_ origin: SIMD3<Double>, _ normal: SIMD3<Double>, x: SIMD3<Double>? = nil) throws -> Frame {
        let z = try unit(normal, "Frame.at: normal")
        let hint = try unit(x ?? (abs(z.x) <= 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)), "Frame.at: x")
        let d = dot(hint, z)
        if abs(d) > 1 - square { throw BuildError("Frame.at: x lies along the normal") }
        let ax = try unit(hint - d * z, "Frame.at: x")
        return try Frame(origin, ax, cross(z, ax), z)
    }

    /// The origin.
    public var origin: SIMD3<Double> { SIMD3(values[0], values[1], values[2]) }
    /// The x axis, unit.
    public var x: SIMD3<Double> { SIMD3(values[3], values[4], values[5]) }
    /// The y axis, unit.
    public var y: SIMD3<Double> { SIMD3(values[6], values[7], values[8]) }
    /// The z axis, unit: the direction a profile on this frame is built along.
    public var z: SIMD3<Double> { SIMD3(values[9], values[10], values[11]) }

    /// This frame moved by (`dx`, `dy`, `dz`) in world coordinates.
    public func translate(_ dx: Double, _ dy: Double, _ dz: Double) throws -> Frame {
        try Frame(origin + SIMD3(dx, dy, dz), x, y, z)
    }

    /// This frame moved `distance` along its own z.
    public func offset(_ distance: Double) throws -> Frame {
        let d = distance * z
        return try translate(d.x, d.y, d.z)
    }

    public var description: String {
        func t(_ v: SIMD3<Double>) -> String { "(\(v.x), \(v.y), \(v.z))" }
        return "Frame(origin=\(t(origin)), x=\(t(x)), y=\(t(y)), z=\(t(z)))"
    }
}

// MARK: - Workplane

/// The fluent chain, mirroring the Rust `Workplane`: a frame, the solid built so far, and the
/// face last picked. A build call *replaces* the solid (as `Workplane::set_brep` does);
/// combine solids explicitly with `Solid.join`. Every step throws `BuildError` at once rather
/// than latching it, and returns the workplane itself, so the calls chain.
public final class Workplane {
    /// Twelve numbers: origin, x, y, z -- the plane the next build call sketches on. Settable,
    /// as Python's is; a build call refuses anything but twelve numbers.
    public var frame: [Double]
    private var current: Solid?
    private var selected: Int?

    /// A chain on `frame`, holding `solid` if given -- what `on` and `fromSolid` build.
    public init(_ frame: Frame, solid: Solid? = nil) {
        self.frame = frame.values
        current = solid
    }

    private init(values: [Double], solid: Solid?) {
        frame = values
        current = solid
    }

    /// Start on the XY plane at the origin (Z up).
    public static func xy() -> Workplane { Workplane(values: xyValues, solid: nil) }

    /// Start on the XZ plane at the origin (z along -Y).
    public static func xz() -> Workplane { Workplane(values: xzValues, solid: nil) }

    /// Start on the YZ plane at the origin (z along +X).
    public static func yz() -> Workplane { Workplane(values: yzValues, solid: nil) }

    /// Start on any frame.
    public static func on(_ frame: Frame) -> Workplane { Workplane(values: frame.values, solid: nil) }

    /// Start from an existing solid, on the XY plane -- the usual way to pick one of its faces
    /// and build on it.
    public static func fromSolid(_ solid: Solid) -> Workplane { Workplane(values: xyValues, solid: solid) }

    private func set(_ solid: Solid) -> Workplane {
        current = solid
        selected = nil
        return self
    }

    /// A box `x` x `y` x `z` on the current frame; replaces the solid.
    @discardableResult
    public func cuboid(_ x: Double, _ y: Double, _ z: Double) throws -> Workplane {
        let raw = try Solid.cuboid(x, y, z)
        defer { raw.close() }
        return set(try raw.place(raw: frame))
    }

    /// A cylinder of radius `r` and height `h` standing on the current frame; replaces the
    /// solid.
    @discardableResult
    public func cylinder(_ r: Double, _ h: Double) throws -> Workplane {
        let raw = try Solid.cylinder(r, h)
        defer { raw.close() }
        return set(try raw.place(raw: frame))
    }

    /// `profile` extruded `height` along the frame's z; replaces the solid.
    @discardableResult
    public func extrude(_ profile: Profile, _ height: Double) throws -> Workplane {
        set(try Solid.extrude(profile, raw: frame, height))
    }

    /// The flat sheet `profile` bounds on this workplane's frame -- `Solid.face`; replaces the
    /// solid.
    @discardableResult
    public func face(_ profile: Profile) throws -> Workplane {
        set(try Solid.face(profile, raw: frame))
    }

    /// `profile` revolved `angle` radians about this workplane's own y axis through its
    /// origin, as the Rust chain; replaces the solid.
    @discardableResult
    public func revolve(_ profile: Profile, _ angle: Double) throws -> Workplane {
        let f = try frameValues(frame)
        return set(try Solid.revolve(profile, (SIMD3(f[0], f[1], f[2]), SIMD3(f[6], f[7], f[8])), angle))
    }

    /// Slide the current solid. Unlike a build call this keeps `faces`'s selection: a rigid
    /// translation carries every face along at the same index. (Rust's is a silent no-op on an
    /// empty workplane; this throws, like every other step.)
    @discardableResult
    public func translate(_ dx: Double, _ dy: Double, _ dz: Double) throws -> Workplane {
        guard let current else { throw BuildError("translate: the workplane holds no solid (BuildError::Empty)") }
        self.current = try current.translate(dx, dy, dz)
        return self
    }

    /// Pick a face of the current solid with a `Selector`.
    @discardableResult
    public func faces(_ selector: Selector) throws -> Workplane {
        guard let current else { throw BuildError("faces: the workplane holds no solid (BuildError::Empty)") }
        selected = try current.selectFace(selector)
        return self
    }

    /// Adopt the frame on the face last picked (outward normal as z), so the next step builds
    /// on it; a no-op if none is picked.
    @discardableResult
    public func workplane() throws -> Workplane {
        if let current, let selected { frame = try current.faceFrame(selected) }
        return self
    }

    /// The solid built so far. On an empty chain it throws.
    public func solid() throws -> Solid {
        guard let current else { throw BuildError("solid: nothing was built (BuildError::Empty)") }
        return current
    }
}
