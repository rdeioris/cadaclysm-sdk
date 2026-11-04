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
// A mesh view holds its own tessellation
// ---------------------------------------
// `Solid.mesh`, `Solid.mesh64` and `Solid.edgePolylines` each mesh the solid into a held
// `Tessellation` (an opaque handle over `cadaclysm_blacksmith_tessellation`) and hand back
// `NativeArray` views into *that handle's* own memory, not into the solid's cache -- so a
// view does not need the solid to stay open, or even reachable, to keep reading. Nothing
// invalidates a view: not `Solid.close()`, and not meshing the same solid again at another
// tolerance (`mesh`, `mesh64`, `edgePolylines`, `bounds`/`boundsAt`), which still replaces the
// solid's own one-tolerance cache but never touches a `Tessellation` a view already holds --
// that memory lives exactly as long as the view does. `isValid` (or `Mesh.isStale`) is kept
// for compatibility and always reports the memory as readable now. `copy()` still gives the
// same type in Swift-owned memory, safe to outlive the view itself. Strings are copied on the
// way out and are always safe.
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
import CadaclysmView
import Foundation

/// What the library refused, in its own words (`cadaclysm_blacksmith_last_error`).
public struct BuildError: Error, CustomStringConvertible, LocalizedError {
    /// The library's reason, or this module's where the refusal is its own.
    public let message: String
    /// The ids a sketch refusal names: the constraints a new constraint, value or reference
    /// conflicts with, or the entities still using a point; empty for every other refusal.
    public let ids: [UInt32]

    public init(_ message: String, ids: [UInt32] = []) {
        self.message = message
        self.ids = ids
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

/// `failure`, for a call routed through `cadaclysm_blacksmith_tessellation`: that entry
/// point fails with a leading "tessellation:" naming itself, not the caller, so this
/// rewrites that prefix back to `what` -- the C-level name the caller reported before it
/// held a tessellation of its own -- leaving the rest of the library's message untouched.
func tessellationFailure(_ what: String) -> BuildError {
    var reason = lastError()
    let prefix = "tessellation:"
    if reason.hasPrefix(prefix) { reason = what + ":" + reason.dropFirst(prefix.count) }
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

/// Colour text -- "#rgb", "#rrggbb" or a CSS colour name -- as r, g, b in 0..1, read by the
/// library's own parser, so every wrapper takes the same forms. Shared by
/// `Profile.coloured(String)` and `Solid.coloured(String)`.
func rgb(_ colour: String) throws -> SIMD3<Double> {
    var out = [Double](repeating: 0, count: 3)
    guard cadaclysm_blacksmith_parse_colour(colour, &out) else {
        throw BuildError("coloured: a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or (r, g, b) in 0..1, not '\(colour)'")
    }
    return SIMD3(out[0], out[1], out[2])
}

/// An `SvgColour` packed through the kernel's own parser, for a kernel drawing.
func kernelPacked(_ colour: SvgColour, _ what: String) throws -> UInt32 {
    try colour.packed(what, parse: { text in
        var out = [Double](repeating: 0, count: 3)
        return cadaclysm_blacksmith_parse_colour(text, &out) ? SIMD3(out[0], out[1], out[2]) : nil
    }, fail: { BuildError($0) })
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

/// Set a kernel option, by its name, for the whole process from the next call on:
/// `"boolean.mesh_budget"`, `"boolean.finest_tolerance"`, `"profile_boolean.point_budget"`
/// or `"measure.default_accuracy"`. Throws -- and changes nothing -- for a name that is not
/// an option or a value it does not take, saying which and what it takes.
public func setOption(_ name: String, _ value: Double) throws {
    if !cadaclysm_blacksmith_option_set(name, value) { throw failure("option '\(name)' refused") }
}

/// A kernel option's value, by its name: what `setOption` last set, else its default.
/// Throws for a name that is not an option, listing the ones there are.
public func option(_ name: String) throws -> Double {
    var out: Double = 0
    guard cadaclysm_blacksmith_option_get(name, &out) else { throw failure("no option '\(name)'") }
    return out
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
/// so `options.up` falls back to `.z` rather than a scene's. Colour text in `stroke` or
/// `background` is read by the kernel's own parser; text it refuses throws.
func buildSvgOptions(_ options: SvgOptions) throws -> CadaclysmBlacksmithSvgOptions {
    let stroke = try kernelPacked(options.stroke, "svg: stroke")
    let background = try options.background.map { try kernelPacked($0, "svg: background") } ?? svgTransparent
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
    raw.stroke = stroke
    raw.background = background
    raw.flags = (options.edges ? UInt32(1) : 0) | (options.curves ? UInt32(2) : 0)
        | (options.isocurves ? UInt32(4) : 0) | (options.polylines ? UInt32(8) : 0)
        | (options.silhouettes ? UInt32(16) : 0)
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
    var cOptions = try buildSvgOptions(options)
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
    var cOptions = try buildSvgOptions(options)
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
    var cOptions = try buildSvgOptions(options)
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
    var cOptions = try buildSvgOptions(options)
    let ok = withExtendedLifetime(solids) {
        withExtendedLifetime(profiles) {
            withUnsafePointer(to: &cOptions) {
                cadaclysm_blacksmith_drawing_svg(solidHandles, solidHandles.count, profileHandles, profileHandles.count, path, $0)
            }
        }
    }
    guard ok else { throw failure("svg") }
}

// MARK: - Views into a held tessellation

/// A held tessellation: the owner of a mesh's views. Its arrays belong to it, not to the
/// solid, so it always reads and never needs the solid to stay open or reachable.
final class Tessellation: NativeMemoryOwner {
    private let handle: OpaquePointer

    init(_ solid: Solid, _ tolerance: Double, _ what: String) throws {
        guard let made = cadaclysm_blacksmith_tessellation(try solid.h(), tolerance) else { throw tessellationFailure(what) }
        handle = made
    }

    deinit { cadaclysm_blacksmith_tessellation_free(handle) }

    var nativeMemoryInvalidReason: String? { nil }

    var mesh: CadaclysmBlacksmithMesh { cadaclysm_blacksmith_tessellation_mesh(handle) }
    var mesh64: CadaclysmBlacksmithMesh64 { cadaclysm_blacksmith_tessellation_mesh64(handle) }
    var faceTriangles: CadaclysmBlacksmithFaceTriangles { cadaclysm_blacksmith_tessellation_face_triangles(handle) }
    var edgePolylines: CadaclysmBlacksmithPolylines { cadaclysm_blacksmith_tessellation_edge_polylines(handle) }
}

/// `cadaclysm_blacksmith_mesh`, `_mesh64`, `_mesh_face_triangles` and `_edge_polylines` are no
/// longer called: `Solid.mesh`, `Solid.mesh64`, `Solid.edgePolylines` and the internal
/// `faceTriangles` each hold a `Tessellation` of their own instead (see the note at the top).
/// Python's object model still names all four, and the SDK's cross-language parity check
/// still requires every binding to call each one somewhere -- named here, under a branch
/// that never runs, the same shape as Go's `legacyTessellationEntryPointsForParity` and
/// LuaJIT's `legacy_tessellation_entry_points_for_parity`. Never called from anywhere in
/// this package.
private func legacyTessellationEntryPointsForParity(_ handle: OpaquePointer?, _ tolerance: Double) {
    if handle == nil {
        _ = cadaclysm_blacksmith_mesh(handle, tolerance)
        _ = cadaclysm_blacksmith_mesh64(handle, tolerance)
        _ = cadaclysm_blacksmith_mesh_face_triangles(handle, tolerance)
        _ = cadaclysm_blacksmith_edge_polylines(handle, tolerance)
    }
}

/// A solid's triangles at one tolerance: `positions` and `normals` three floats a vertex,
/// `indices` three to a triangle -- `NativeArray` views into a held tessellation of its own,
/// which reads whatever happens to the solid: re-meshed at another tolerance, or closed.
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
    /// Always false now -- a view owns its tessellation; kept for compatibility.
    public var isStale: Bool { !positions.isValid || !indices.isValid }

    /// The same triangles in memory of our own, safe to outlive the view.
    public func copy() -> Mesh {
        Mesh(tolerance: tolerance, positions: positions.copy(), normals: normals.copy(), indices: indices.copy())
    }
}

/// `Mesh` in `double`: the same tessellation `mesh(tolerance:)` narrows -- the very same
/// index buffer, positions and normals unnarrowed, from the solid's cache at the moment this
/// is made (the same underlying mesh `mesh(tolerance:)`'s `Mesh` reads, if the cache still
/// holds this tolerance then). `NativeArray` views into a held tessellation of its own, under
/// `Mesh`'s own rule: never stale.
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
    /// Always false now -- a view owns its tessellation; kept for compatibility.
    public var isStale: Bool { !positions.isValid || !indices.isValid }

    /// The same triangles in memory of our own, safe to outlive the view.
    public func copy() -> Mesh64 {
        Mesh64(tolerance: tolerance, positions: positions.copy(), normals: normals.copy(), indices: indices.copy())
    }
}

/// A solid's feature edges as polylines at one tolerance, one run of points per edge:
/// element `i` is polyline `i`, three floats a point -- what Python's list holds at `i`.
/// Views into a held tessellation of its own, under `Mesh`'s rule.
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
    /// Always false now -- a view owns its tessellation; kept for compatibility.
    public var isStale: Bool { !offsets.isValid }

    /// The same polylines in memory of our own, safe to outlive the view.
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

    /// The perimeter of the outer loop (holes are not counted), to a relative `accuracy`; 0 or
    /// less asks for the library's default.
    public func length(_ accuracy: Double = 0) throws -> Length {
        var raw = CadaclysmBlacksmithLength()
        if !cadaclysm_blacksmith_profile_length(handle, accuracy, &raw) { throw failure("profile_length") }
        return Length(raw)
    }

    /// The point `s` along the outer loop from its start, its unit tangent, the side it lies on
    /// (`segment`) and that side's own `parameter`, to a relative `accuracy` (0 or less asks for
    /// the library's default).
    public func pointAtLength(_ s: Double, _ accuracy: Double = 0) throws -> At {
        var raw = CadaclysmBlacksmithAt()
        if !cadaclysm_blacksmith_profile_point_at_length(handle, s, accuracy, &raw) {
            throw failure("profile_point_at_length")
        }
        return At(raw)
    }

    /// The outer loop in `n` pieces of equal arc length: `n` samples from its start, the loop's
    /// start not repeated. `n` is 1 to 1,000,000.
    public func divideByCount(_ n: UInt32, _ accuracy: Double = 0) throws -> [At] {
        try samplesOf(cadaclysm_blacksmith_profile_divide_by_count(handle, n, accuracy), "profile_divide_by_count")
    }

    /// The outer loop in steps of arc length `step` from its start, keeping the short last piece.
    public func divideByLength(_ step: Double, _ accuracy: Double = 0) throws -> [At] {
        try samplesOf(cadaclysm_blacksmith_profile_divide_by_length(handle, step, accuracy), "profile_divide_by_length")
    }

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
        guard let n = UInt32(exactly: sides) else {
            throw BuildError("profile_regular_polygon: sides is out of range: \(sides)")
        }
        return try Profile(cadaclysm_blacksmith_profile_regular_polygon(centre.x, centre.y, radius, n, angle))
    }

    /// A regular polygon of `sides` sides (at least 3) whose sides touch the circle of `radius`
    /// about `centre` -- the polygon across flats, a nut's hex: its corners on the circle of
    /// `radius / cos(pi / sides)`, the first at `angle` radians from the sketch's x axis, the rest
    /// counter-clockwise, on the same rays as `regularPolygon`'s corners with the same `angle`;
    /// each side's midpoint on the circle of `radius`. A `sides` a `UInt32` cannot hold is
    /// refused before the call.
    public static func circumscribedPolygon(_ centre: SIMD2<Double>, _ radius: Double, _ sides: Int,
                                            angle: Double = 0.0) throws -> Profile {
        guard let n = UInt32(exactly: sides) else {
            throw BuildError("profile_circumscribed_polygon: sides is out of range: \(sides)")
        }
        return try Profile(cadaclysm_blacksmith_profile_circumscribed_polygon(centre.x, centre.y, radius, n, angle),
                           "profile_circumscribed_polygon")
    }

    /// A star of `points` tips (at least 3) on the circle of `outer` about `centre`, its
    /// inner corners on the circle of `inner` (positive, under `outer`), alternating: the
    /// first tip at `angle` radians from the sketch's x axis, the rest counter-clockwise.
    public static func star(_ centre: SIMD2<Double>, _ outer: Double, _ inner: Double, _ points: Int,
                            angle: Double = 0.0) throws -> Profile {
        guard let n = UInt32(exactly: points) else {
            throw BuildError("profile_star: points is out of range: \(points)")
        }
        return try Profile(cadaclysm_blacksmith_profile_star(centre.x, centre.y, outer, inner, n, angle))
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

    /// This outline turned `radians` (counter-clockwise) about `centre`.
    public func rotate(_ centre: SIMD2<Double>, _ radians: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_rotate(handle, centre.x, centre.y, radians))
    }

    /// This outline scaled by `sx`, `sy` about `centre`. An arc stays an arc where the two are
    /// equal in size, and becomes exact conics otherwise; a negative factor mirrors across that
    /// axis, and a zero one throws.
    public func scale(_ centre: SIMD2<Double>, _ sx: Double, _ sy: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_scale(handle, centre.x, centre.y, sx, sy))
    }

    /// This outline reflected across the line through `point` along `direction`; each arc's
    /// sense turns. A zero `direction` throws.
    public func mirror(_ point: SIMD2<Double>, _ direction: SIMD2<Double>) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_mirror(handle, point.x, point.y, direction.x, direction.y))
    }

    /// This outline under the 2D affine map `m`, six numbers row-major (2×3):
    /// `x' = m0·x + m1·y + m2`, `y' = m3·x + m4·y + m5`. A singular map throws.
    public func transform2d(_ m: [Double]) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_transform2d(handle, try countedValues(m, 6, "profile_transform2d")))
    }

    /// This outline coloured (r, g, b), each in 0..1: how it is drawn. The verbs that make a
    /// profile from one carry it; a solid made from it takes nothing.
    public func coloured(_ colour: SIMD3<Double>) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_coloured(handle, colour.x, colour.y, colour.z))
    }

    /// `coloured` with `"#rgb"`, `"#rrggbb"` or a CSS colour name.
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

    /// This profile with every free-form side (a Bezier, a conic, a NURBS) replaced by lines
    /// and arcs within `tolerance` of it -- what a G-code writer can say. Lines and arcs pass
    /// through as they are, every loop closes on itself exactly, holes are converted the same
    /// way. Throws for a `tolerance` not positive and finite, or a spline that does not
    /// evaluate.
    public func toArcs(_ tolerance: Double = 0.01) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_to_arcs(handle, tolerance), "profile_to_arcs")
    }

    /// This profile grown by `distance` (shrunk where it is negative), as zero or more
    /// profiles, all lines and arcs: outward corners rounded by `|distance|`, holes moving
    /// against the boundary (a hole shrinks as the profile grows). Free-form sides are fitted
    /// to `tolerance` first (`toArcs`). A shrink that eats the whole profile is an empty
    /// array. Throws for a `distance` not finite, a `tolerance` not positive and finite, a
    /// loop with no sides, or loops that cross or touch.
    public func offset(_ distance: Double, tolerance: Double = 0.01) throws -> [Profile] {
        try Profile.list(cadaclysm_blacksmith_profile_offset(handle, distance, tolerance), "profile_offset")
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
    /// own, the list freed. `fileprivate`, not `private`: `Job`'s report reader (this file's
    /// machining section) reads a `ReportItem`'s region the same way.
    fileprivate static func list(_ raw: OpaquePointer?, _ what: String) throws -> [Profile] {
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
/// reason -- a solver mesh is megabytes. It shares with a `Mesh` or `Polylines` view the one
/// property that matters most, owning what it lends rather than borrowing from the solid, so
/// meshing the solid again at another tolerance leaves it alone, and so does `Solid.close()` --
/// but **a FEM mesh is not in the solid's tessellation cache at all**, where a `Mesh` or
/// `Polylines` view still holds a `Tessellation` cut from that cache at the moment it was made.
/// The owner of every view here is **this object**, and `free()` is what ends them -- or the
/// last reference to it going.
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

    /// Every pair of triangles that pass through each other, as `(a, b)` with `a < b`, sorted:
    /// an edge of one through the other's interior. Their B-rep faces are `triangleFace[a]` and
    /// `[b]`.
    ///
    /// **Computed for every solid, open or closed.** The census `watertight`, `openEdges` and
    /// `foldedEdges` report is topological and cannot see a surface passing through itself; a
    /// mesh is ready for a volume mesher when it is `watertight` **and** this is empty -- Gmsh
    /// refuses one that crosses. A copy.
    public var crossings: [(UInt32, UInt32)] {
        get throws {
            let handle = try h()
            let count = cadaclysm_blacksmith_fem_mesh_crossing_count(handle)
            return try (0..<count).map { i in
                var a: UInt32 = 0, b: UInt32 = 0
                guard cadaclysm_blacksmith_fem_mesh_crossing(handle, i, &a, &b) else {
                    throw failure("fem mesh crossing \(i)")
                }
                return (a, b)
            }
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

    /// The trims lost by the `transform` or `convertToNurbs` call that made this solid: face
    /// boundaries kept only as a polyline lifted through the old surface, where no exact edge
    /// curve was left. Per call -- not this solid's history -- and 0 for a rigid map or a
    /// similarity, and on every solid neither call made.
    public private(set) var inexactTrims = 0

    init(_ raw: OpaquePointer?, _ what: String = "solid") throws {
        handle = try checked(raw, what)
    }

    deinit { close() }

    /// Free the solid now. Idempotent; every call on the solid throws after. A `Mesh`,
    /// `Mesh64` or `Polylines` view already handed out reads on regardless -- it holds a
    /// `Tessellation` of its own, not this handle.
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

    // MARK: Drawing

    /// Draw the solid with the view library in use (`ViewLibrary.useWgpu()` /
    /// `useTerminal()`, else CADACLYSM_VIEW, else the terminal): the wgpu library's window
    /// blocks until it is closed; any other library prints a still. `options.tolerance` nil
    /// is 0.05.
    public func show(_ options: ShowOptions = ShowOptions()) throws {
        _ = try draw(options, interactive: false)
    }

    /// Orbit the solid until its window is closed: where the camera was left, the last pick.
    @discardableResult
    public func view(_ options: ShowOptions = ShowOptions()) throws -> Camera {
        try draw(options, interactive: true)
    }

    private func draw(_ options: ShowOptions, interactive: Bool) throws -> Camera {
        defer { withExtendedLifetime(self) {} }
        return try drawObject(solid: h(), scene: nil, tolerance: options.tolerance ?? 0.05, label: "Solid",
                              defaultUp: .z, focus: nil, options: options, interactive: interactive)
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

    // MARK: Material and look defined outside the file

    /// This solid made of `material` -- a name, written to STEP as the product's
    /// `MATERIAL_DESIGNATION`. Kept by every operation as the solid's colour is: a move
    /// keeps it, a boolean's result is made of its first solid's. Writing it moves
    /// `step`'s default schema to AP242; a named schema without the entity drops it, as
    /// it drops a colour. Refused when blank.
    public func withMaterial(_ material: String) throws -> Solid {
        try Solid(cadaclysm_blacksmith_with_material(try h(), material))
    }

    /// What this solid is made of, or nil -- see `withMaterial`. Read as `name` is.
    public var material: String? {
        get throws {
            guard let raw = cadaclysm_blacksmith_solid_material(try h()) else { return nil }
            return String(cString: raw)
        }
    }

    /// This solid drawn in a style defined outside the file: `identification` the style's
    /// name in the library at `location` -- a MaterialX or MDL file and a material in it,
    /// say. Either may be nil, not both. Written to STEP as an `EXTERNALLY_DEFINED_STYLE`
    /// beside the solid's colour, which a reader without the library draws instead (AP242
    /// or AP214: the default schema moves to AP242). Kept as `withMaterial`'s material is.
    public func styled(location: String? = nil, identification: String? = nil) throws -> Solid {
        let handle = try h()
        let raw = try withOptionalCString(location) { l in
            try withOptionalCString(identification) { i in cadaclysm_blacksmith_styled(handle, l, i) }
        }
        return try Solid(raw)
    }

    /// Where this solid's outside style lives (`styled`'s `location`), or nil.
    public var styleLocation: String? {
        get throws {
            guard let raw = cadaclysm_blacksmith_solid_style_location(try h()) else { return nil }
            return String(cString: raw)
        }
    }

    /// This solid's outside style's name in its library (`styled`'s `identification`), or nil.
    public var styleIdentification: String? {
        get throws {
            guard let raw = cadaclysm_blacksmith_solid_style_identification(try h()) else { return nil }
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

    /// A right pyramid of `sides` sides (at least 3): its base the regular polygon of
    /// circumradius `r` on z=0, its first corner on +x, its tip at (0, 0, `h`).
    public static func pyramid(_ sides: Int, _ r: Double, _ h: Double) throws -> Solid {
        try Solid(cadaclysm_blacksmith_pyramid(UInt32(clamping: sides), r, h))
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

    /// Through the affine map `t`, exactly, colours and name kept. A rigid map or a similarity
    /// keeps every surface's kind; a map within 1e-6 of a similarity (a rotation written in
    /// float32 among them) is applied as the exact similarity nearest it. Any other map -- a
    /// non-uniform scale, a shear -- turns the curved surfaces into their exact NURBS and maps
    /// those. The result's `inexactTrims` counts the trims this call lost. A singular map (it
    /// flattens the solid) throws.
    public func transform(_ t: Transform) throws -> Solid { try transform(t.rows) }

    /// `transform(_:)` with the map as 16 numbers, row-major.
    public func transform(_ matrix: [Double]) throws -> Solid {
        let matrix = try countedValues(matrix, 16, "solid_transform")
        var lost: UInt32 = 0
        let out = try Solid(cadaclysm_blacksmith_solid_transform(try h(), matrix, &lost), "solid_transform")
        out.inexactTrims = Int(lost)
        return out
    }

    /// Every surface `level` selects rewritten as its exact NURBS: `"procedural"` the
    /// revolutions, extrusions and sums; `"analytic"` those and the cylinders, cones, spheres
    /// and tori; `"all"` everything, planes and edge curves too. Colours and name kept;
    /// `inexactTrims` counts the trims this call lost. Any other level throws.
    public func convertToNurbs(_ level: String = "all") throws -> Solid {
        let code: UInt32
        switch level {
        case "procedural": code = UInt32(CADACLYSM_BLACKSMITH_NURBS_PROCEDURAL)
        case "analytic": code = UInt32(CADACLYSM_BLACKSMITH_NURBS_ANALYTIC)
        case "all": code = UInt32(CADACLYSM_BLACKSMITH_NURBS_ALL)
        default: throw BuildError("convert_to_nurbs: level '\(level)' is not \"procedural\", \"analytic\" or \"all\"")
        }
        var lost: UInt32 = 0
        let out = try Solid(cadaclysm_blacksmith_solid_convert_to_nurbs(try h(), code, &lost), "solid_convert_to_nurbs")
        out.inexactTrims = Int(lost)
        return out
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

    /// This solid cut by the plane `Z = z`: its closed outlines there, in XY, nested into
    /// profiles with holes (boundaries counter-clockwise, holes clockwise), a line or a
    /// circle crossing kept exact and any other curve as lines within `tolerance`. A plane
    /// that misses the solid is an empty array. Throws for a `z` not finite, a `tolerance`
    /// not positive and finite, a face lying in the plane (section a little above or below
    /// it), or a crossing that does not close.
    public func section(_ z: Double, tolerance: Double = 0.05) throws -> [Profile] {
        try Profile.list(cadaclysm_blacksmith_solid_section(try h(), z, tolerance), "solid_section")
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
    /// rings (outer first, holes after), which may be empty for a partial overlap of curved faces whose
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
            return try intersectionOf(found)
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

    /// The solid's axis-aligned box, at the same cost whatever its size: its mesh at a
    /// thousandth of its own extent, in `Double`, so the box is inside the exact one and short
    /// of it by at most that. Worked out once per solid, apart from the tessellation `mesh`
    /// caches. `boundsAt` is the box of the mesh at a tolerance you name.
    public var bounds: (min: SIMD3<Double>, max: SIMD3<Double>) {
        get throws {
            var lo = [Double](repeating: 0, count: 3)
            var hi = [Double](repeating: 0, count: 3)
            if !cadaclysm_blacksmith_box(try h(), &lo, &hi) { throw failure("box") }
            return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
        }
    }

    /// The solid's axis-aligned bounds, over the positions of its cached tessellation at
    /// `tolerance` (the same cache `mesh` fills and reuses, so a second call at the same
    /// tolerance is free).
    public func boundsAt(_ tolerance: Double) throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = [Double](repeating: 0, count: 3)
        var hi = [Double](repeating: 0, count: 3)
        if !cadaclysm_blacksmith_bounds(try h(), tolerance, &lo, &hi) { throw failure("bounds") }
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
        return (SIMD3(lo[0], lo[1], lo[2]), SIMD3(hi[0], hi[1], hi[2]))
    }

    /// `boundsBoxAt(0.05)`.
    public var boundsBox: Box {
        get throws { try boundsBoxAt(0.05) }
    }

    /// This solid's box at `tolerance`: its boolean mesh, padded by twice that -- the broad
    /// phase's own shape, cheaper to move and test than the solid itself.
    public func boundsBoxAt(_ tolerance: Double) throws -> Box {
        var raw = CadaclysmBlacksmithBox()
        if !cadaclysm_blacksmith_solid_bounds_box(try h(), tolerance, &raw) { throw failure("bounds_box") }
        return Box(raw)
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

    /// What is wrong with this solid, as a `HealthReport`: the free edges (the sides one face
    /// bounds) and the wires they chain into, with each edge's nearest partner and the gap to it;
    /// the features below `tolerance`; the loose edges; and what sewing would join and leave.
    /// `tolerance` is the length below which a feature is small and a gap closes -- nil, or a
    /// value that is not finite and positive, takes the default (the report shows what was
    /// used). `mesh: true` also meshes the solid and reports where the mesh cracks (`cracks`);
    /// without it `cracks` is nil. Nothing moves.
    public func health(tolerance: Double? = nil, mesh: Bool = false) throws -> HealthReport {
        let h = try checked(cadaclysm_blacksmith_health(try self.h(), tolerance ?? .nan, mesh), "health")
        defer { cadaclysm_blacksmith_health_free(h) }
        var counts = [UInt32](repeating: 0, count: 18)
        var sizes = [Double](repeating: 0, count: 8)
        if !cadaclysm_blacksmith_health_summary(h, &counts, &sizes) { throw failure("health") }
        var n = Int(cadaclysm_blacksmith_health_free_edges(h, nil, nil))
        var freeIds = [UInt32](repeating: 0, count: 6 * n), freeSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_blacksmith_health_free_edges(h, &freeIds, &freeSizes) }
        n = Int(cadaclysm_blacksmith_health_wires(h, nil, nil))
        var wireRuns = [UInt32](repeating: 0, count: 3 * n), wireSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_blacksmith_health_wires(h, &wireRuns, &wireSizes) }
        n = Int(cadaclysm_blacksmith_health_small(h, nil, nil))
        var smallItems = [UInt32](repeating: 0, count: 2 * n), smallSizes = [Double](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_blacksmith_health_small(h, &smallItems, &smallSizes) }
        n = Int(cadaclysm_blacksmith_health_crack_edges(h, nil))
        var crackEdges = [UInt32](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_blacksmith_health_crack_edges(h, &crackEdges) }
        return HealthReport(counts: counts, sizes: sizes, freeIds: freeIds, freeSizes: freeSizes, wireRuns: wireRuns,
                            wireSizes: wireSizes, smallItems: smallItems, smallSizes: smallSizes, crackEdges: crackEdges)
    }

    /// This solid with its small features removed, and what was done, as a new `Solid` and a
    /// `HealReport`; this one is left as it was. The features are the ones `health` lists as
    /// small at `tolerance`: short and collapsed edges, sliver and tiny faces, small holes. Every
    /// fix is a vertex merge, and an edge it moves records how far as its `edgeTolerance`. A
    /// guard compares the result's health with this one's and refuses fixes that made it worse
    /// (`guarded`). `edges`, `faces` and `holes` switch each kind of fix; a kind switched off is
    /// refused as `"toggled"`. `tolerance` nil, or a value that is not finite and positive, takes
    /// the default (the report shows what was used).
    public func healed(tolerance: Double? = nil, edges: Bool = true, faces: Bool = true,
                       holes: Bool = true) throws -> (Solid, HealReport) {
        let flags = healFlags(edges: edges, faces: faces, holes: holes)
        let h = try checked(cadaclysm_blacksmith_healed(try self.h(), tolerance ?? .nan, flags), "healed")
        defer { cadaclysm_blacksmith_heal_free(h) }
        var counts = [UInt32](repeating: 0, count: 11)
        var sizes = [Double](repeating: 0, count: 2)
        if !cadaclysm_blacksmith_heal_summary(h, &counts, &sizes) { throw failure("healed") }
        var n = Int(cadaclysm_blacksmith_heal_fixes(h, nil, nil))
        var fixItems = [UInt32](repeating: 0, count: 2 * n), fixSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_blacksmith_heal_fixes(h, &fixItems, &fixSizes) }
        n = Int(cadaclysm_blacksmith_heal_refused(h, nil, nil))
        var refusedItems = [UInt32](repeating: 0, count: 3 * n), refusedSizes = [Double](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_blacksmith_heal_refused(h, &refusedItems, &refusedSizes) }
        let report = HealReport(counts: counts, sizes: sizes, fixItems: fixItems, fixSizes: fixSizes,
                                refusedItems: refusedItems, refusedSizes: refusedSizes)
        return (try Solid(cadaclysm_blacksmith_heal_body(h), "healed"), report)
    }

    /// How far brep edge `edge` (as a `HealFix` names one) may lie off its curve: 0 for an exact
    /// edge, the distance healing (or sewing) moved it where that is recorded, nil when no trim
    /// names the id (an edge healing removed).
    public func edgeTolerance(_ edge: Int) throws -> Double? {
        let t = cadaclysm_blacksmith_edge_tolerance(try h(), try index32(edge, "edge_tolerance"))
        if t.isNaN && !lastError().isEmpty { throw failure("edge_tolerance") }
        return t.isNaN ? nil : t
    }

    /// What this solid measures, per unit density, each figure beside a bound on its own error.
    ///
    /// `accuracy` is relative and 0 asks for the library's default. The volume-side figures mean
    /// something only where `Mass.closed`; where `accuracyMet` is false the refinement stopped early
    /// and the figures are honest but less certain, which the errors say.
    public func mass(_ accuracy: Double = 0.0) throws -> Mass {
        var raw = CadaclysmBlacksmithMassProperties()
        if !cadaclysm_blacksmith_mass_properties(try h(), accuracy, &raw) {
            throw failure("mass_properties")
        }
        return Mass(raw)
    }

    // MARK: Output

    /// The triangles at `tolerance`, as views into a held tessellation of their own: never
    /// stale, whatever happens to the solid after. `copy()` puts the same triangles in memory
    /// of Swift's own, safe to outlive the `Mesh` value itself too.
    public func mesh(tolerance: Double = 0.05) throws -> Mesh {
        let owner = try Tessellation(self, tolerance, "mesh")
        let raw = owner.mesh
        if raw.positions == nil { throw failure("mesh") }
        let floats = Int(raw.vertex_count) * 3
        return Mesh(tolerance: tolerance,
                    positions: NativeArray(owner: owner, base: raw.positions, count: floats),
                    normals: NativeArray(owner: owner, base: raw.normals, count: floats),
                    indices: NativeArray(owner: owner, base: raw.indices, count: Int(raw.index_count)))
    }

    /// `mesh(tolerance:)` in `double`: the very same index buffer, positions and normals
    /// unnarrowed -- its own held tessellation, under the same rule as `mesh(tolerance:)`:
    /// never stale.
    public func mesh64(tolerance: Double = 0.05) throws -> Mesh64 {
        let owner = try Tessellation(self, tolerance, "mesh64")
        let raw = owner.mesh64
        if raw.positions == nil { throw failure("mesh64") }
        let doubles = Int(raw.vertex_count) * 3
        return Mesh64(tolerance: tolerance,
                     positions: NativeArray(owner: owner, base: raw.positions, count: doubles),
                     normals: NativeArray(owner: owner, base: raw.normals, count: doubles),
                     indices: NativeArray(owner: owner, base: raw.indices, count: Int(raw.index_count)))
    }

    /// The feature edges as polylines at `tolerance`, one run of points per edge -- views into
    /// a held tessellation of their own, under `mesh(tolerance:)`'s rule.
    public func edgePolylines(tolerance: Double = 0.05) throws -> Polylines {
        let owner = try Tessellation(self, tolerance, "edge_polylines")
        let raw = owner.edgePolylines
        if raw.offsets == nil { throw failure("edge_polylines") }
        let count = Int(raw.polyline_count)
        return Polylines(tolerance: tolerance,
                         points: NativeArray(owner: owner, base: raw.points, count: Int(raw.point_count) * 3),
                         offsets: NativeArray(owner: owner, base: raw.offsets, count: count + 1),
                         count: count)
    }

    /// The kernel's `mesh_face_triangles`, kept for the viewer follow-up (as Go keeps it): how
    /// many triangles each face meshed to at `tolerance`, in face order, summing to `mesh`'s
    /// triangle count at the same tolerance -- copied out of a held tessellation of its own, so
    /// nothing here depends on the solid's cache surviving the call.
    func faceTriangles(tolerance: Double = 0.05) throws -> [UInt32] {
        let owner = try Tessellation(self, tolerance, "mesh_face_triangles")
        return try withExtendedLifetime(owner) { () throws -> [UInt32] in
            let raw = owner.faceTriangles
            guard let counts = raw.counts else { throw failure("mesh_face_triangles") }
            return Array(UnsafeBufferPointer(start: counts, count: Int(raw.face_count)))
        }
    }

    /// This solid meshed for a solver, as a `FemMesh`: nodes welded by bits -- two mesh points are
    /// one node only where their coordinates are the same doubles, so no tolerance ever merges two
    /// distinct points and a crack stays a crack -- triangles wound outward, and every node tagged
    /// with the lowest-dimension B-rep entity it lies on.
    ///
    /// **It is its own handle, not a view of this solid.** `Solid.mesh` hands back views into its
    /// own held tessellation; this returns a `FemMesh` that owns everything it lends the same way,
    /// so meshing the solid again at another tolerance does not stale it and neither does `close()`.
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

    /// This solid's silhouette -- where its surfaces turn away from the eye, which no edge of it lies
    /// on -- as rational cubic Béziers in `double`, from the camera `options` describes. The same
    /// `SvgOptions` that draw a picture: `view`, `azimuth`, `elevation`, `up` and `fov`, and `width`
    /// with `tolerance`, which the library reads together as the page fraction `tolerance / width`.
    /// Nothing else in them changes the curves.
    ///
    /// The library hands over an owned block; this copies it out and releases it before it returns,
    /// whichever way it returns, so there is nothing for the caller to free.
    ///
    /// A body with no silhouette (every face planar) is an empty answer (`count == 0`), not an error;
    /// a refused option or a body with no measurable geometry throws.
    public func silhouetteBeziers(_ options: SvgOptions = SvgOptions()) throws -> Beziers64 {
        let h = try h()
        var cOptions = try buildSvgOptions(options)
        var count: UInt32 = 0
        let data = withExtendedLifetime(self) {
            withUnsafePointer(to: &cOptions) { cadaclysm_blacksmith_silhouette_beziers(h, $0, &count) }
        }
        guard let data else {
            // The library clears the thread's error at entry and the empty answer sets none: a
            // reason here is this call's own refusal, none is the empty answer.
            if !lastError().isEmpty { throw failure("silhouette_beziers") }
            return Beziers64(points: [], weights: [])
        }
        defer { cadaclysm_blacksmith_silhouette_beziers_free(data, count) }
        let block = UnsafeBufferPointer(start: data, count: Int(count) * 16)
        var points: [Double] = [], weights: [Double] = []
        points.reserveCapacity(Int(count) * 12)
        weights.reserveCapacity(Int(count) * 4)
        for curve in 0..<Int(count) {
            points.append(contentsOf: block[curve * 16 ..< curve * 16 + 12])
            weights.append(contentsOf: block[curve * 16 + 12 ..< curve * 16 + 16])
        }
        return Beziers64(points: points, weights: weights)
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

    /// What the solid measures, per unit density: its area, its volume, where its mass sits and how
    /// it resists being spun about that point, each beside a bound on its own error. `accuracy` is
    /// relative; 0 asks for the default, a part in ten million.
    ///
    /// The volume, the centroid and the inertia mean something only where `closed` is 1 -- on a sheet
    /// they are zero and the area is still measured. Mass is `density * volume` and the inertia scales
    /// the same way: nothing here assumes a density of its own.
    public func mass(_ accuracy: Double = 0) throws -> CadaclysmBlacksmithMassProperties {
        var out = CadaclysmBlacksmithMassProperties()
        if !cadaclysm_blacksmith_mass_properties(try h(), accuracy, &out) {
            throw failure("mass")
        }
        return out
    }

    /// The box on this solid's principal axes: its centre, three unit axes (row `i` the direction of
    /// `half[i]`) and the half extent along each. Not minimal, and a free choice where two moments
    /// are equal (a sphere, a cube); the half extents are grown by about the tolerance the
    /// measurement settled on. `accuracy` 0 or less asks for the box's own default, `1e-5`.
    public func orientedBox(_ accuracy: Double = 0) throws -> OrientedBox {
        var raw = CadaclysmBlacksmithOrientedBox()
        if !cadaclysm_blacksmith_oriented_box(try h(), accuracy, &raw) { throw failure("oriented_box") }
        return OrientedBox(raw)
    }

    /// The length of edge `edge` (the index `edges` and `fillet` use) over its own range, to a
    /// relative `accuracy`; 0 or less asks for the library's default.
    public func edgeLength(_ edge: Int, _ accuracy: Double = 0) throws -> Length {
        var raw = CadaclysmBlacksmithLength()
        if !cadaclysm_blacksmith_edge_length(try h(), try index32(edge, "edge_length"), accuracy, &raw) {
            throw failure("edge_length")
        }
        return Length(raw)
    }

    /// The point `s` along edge `edge` from the start of its own range, its unit tangent there and
    /// the parameter it lies at, to a relative `accuracy` (0 or less asks for the library's
    /// default). `s` is within 0...the edge's length.
    public func edgePointAtLength(_ edge: Int, _ s: Double, _ accuracy: Double = 0) throws -> At {
        var raw = CadaclysmBlacksmithAt()
        if !cadaclysm_blacksmith_edge_point_at_length(try h(), try index32(edge, "edge_point_at_length"), s, accuracy, &raw) {
            throw failure("edge_point_at_length")
        }
        return At(raw)
    }

    /// Edge `edge` in `n` pieces of equal arc length: `n + 1` samples from its start to its end,
    /// or `n` from its start round to just short of it when it closes on itself. `n` is 1 to
    /// 1,000,000.
    public func edgeDivideByCount(_ edge: Int, _ n: UInt32, _ accuracy: Double = 0) throws -> [At] {
        let list = cadaclysm_blacksmith_edge_divide_by_count(try h(), try index32(edge, "edge_divide_by_count"), n, accuracy)
        return try samplesOf(list, "edge_divide_by_count")
    }

    /// Edge `edge` in steps of arc length `step`, starting at its start and keeping the short last
    /// piece; a closed edge never repeats its start.
    public func edgeDivideByLength(_ edge: Int, _ step: Double, _ accuracy: Double = 0) throws -> [At] {
        let list = cadaclysm_blacksmith_edge_divide_by_length(try h(), try index32(edge, "edge_divide_by_length"), step, accuracy)
        return try samplesOf(list, "edge_divide_by_length")
    }

    /// Where `point` is relative to this closed solid: `"inside"`, `"outside"` or `"on"` (within
    /// `tolerance` of the boundary, absolute, in model units). The body is meshed on every call;
    /// for more than a few points build a `classifier` once.
    public func contains(_ point: SIMD3<Double>, tolerance: Double = 0.05) throws -> String {
        let xyz = [point.x, point.y, point.z]
        var code: UInt32 = 0
        if !cadaclysm_blacksmith_contains(try h(), xyz, tolerance, &code) { throw failure("contains") }
        return try containment(code, "contains")
    }

    /// A reusable classifier of points against this closed solid, meshed once at `tolerance`. It
    /// keeps its own reference to the body, so it answers on after this `Solid` is closed.
    public func classifier(tolerance: Double = 0.05) throws -> Classifier {
        try Classifier(try h(), tolerance)
    }

    /// The closest points between this solid's boundary and `other`'s, to the absolute `tolerance`
    /// (positive and finite; 0.05 by default), and what each lies on.
    public func closest(_ other: Solid, tolerance: Double = 0.05) throws -> Closest {
        var raw = CadaclysmBlacksmithClosest()
        if !cadaclysm_blacksmith_closest(try h(), try other.h(), tolerance, nil, nil, &raw) {
            throw failure("closest")
        }
        return Closest(raw)
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

    /// An `RTree` over this solid's faces: one entry per face, its id the face index the other
    /// face calls take, its box holding the face (the box the boolean's broad phase pairs faces
    /// by, grown by a thousandth of the solid's extent). No faces give an empty tree. The tree is
    /// its own and outlives the solid.
    public func faceTree() throws -> RTree {
        try RTree.adopting(cadaclysm_blacksmith_solid_face_tree(try h()), "solid_face_tree")
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

    /// `coloured` with `"#rgb"`, `"#rrggbb"` (the `#` optional) or a CSS colour name.
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

    /// `edgesColoured` with `"#rgb"`, `"#rrggbb"` or a CSS colour name.
    public func edgesColoured(_ colour: String, edges: [Int]? = nil) throws -> Solid {
        try edgesColoured(try rgb(colour), edges: edges)
    }

    /// `edgesColoured` with `"#rgb"`, `"#rrggbb"` or a CSS colour name, by `Edge`.
    public func edgesColoured(_ colour: String, edges: [Edge]) throws -> Solid {
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
        // This call tessellates like every other cache reader, even to report "no paint", and
        // can still replace the solid's own one-tolerance cache -- but a `Mesh`/`Polylines`
        // view taken earlier holds a `Tessellation` of its own now, not that cache, so nothing
        // needs recording here any more: this method copies its own result out too.
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

    /// This solid split by the closed `profile` drawn on `frame`, pushed straight through it
    /// along the frame's z both ways: the bodies outside the profile first, then those inside.
    /// Where the plane lies along z does not matter.
    public func splitByProfile(_ profile: Profile, _ frame: Frame, tolerance: Double = 0.05) throws -> [Solid] {
        let all = try withExtendedLifetime(profile) {
            try Solid(cadaclysm_blacksmith_split_by_profile(try h(), profile.handle, frame.values, tolerance, nil, nil))
        }
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

    /// This solid and `other` as one body that keeps every piece -- a union that keeps the
    /// inside pieces: its regions are this solid less `other`, the two together, and `other`
    /// less this one (those that are not empty), and the walls between them are faces of both.
    /// The body is non-manifold where a wall meets the outside (edges of three or four faces),
    /// so the verbs that need a manifold solid -- the booleans, fillet, chamfer, shell, thicken,
    /// the mass -- refuse it; take its cells with `regions` and `regionSolid`.
    ///
    /// Built exactly: both solids closed, every face a plane, cylinder, cone, sphere or torus.
    /// Walls of the two lying on one another in part are a case it refuses, in words.
    public func merge(_ other: Solid, tolerance: Double = 0.05) throws -> Solid {
        try withExtendedLifetime(other) {
            try Solid(cadaclysm_blacksmith_merge(try h(), try other.h(), tolerance, nil, nil), "merge")
        }
    }

    /// The regions of space this solid's faces bound, region 0 the infinite one: two for an
    /// ordinary solid (outside, inside), one per cell for a merge's body, one more per cavity.
    /// Each lists its `sides` -- a face and `sense` +1 where the region is the side the face's
    /// normal points to, -1 the other -- and its `shells`, 1 plus one per void inside it.
    public func regions() throws -> [Region] {
        guard let list = cadaclysm_blacksmith_regions(try h()) else { throw failure("regions") }
        defer { cadaclysm_blacksmith_regions_free(list) }
        let count = cadaclysm_blacksmith_regions_count(list)
        var out: [Region] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            var raw = CadaclysmBlacksmithRegion()
            if !cadaclysm_blacksmith_regions_at(list, i, &raw) { throw failure("regions_at") }
            var sides: [FaceSide] = []
            sides.reserveCapacity(Int(raw.sides))
            for k in 0..<raw.sides {
                var side = CadaclysmBlacksmithFaceSide()
                if !cadaclysm_blacksmith_regions_side_at(list, i, k, &side) { throw failure("regions_side_at") }
                sides.append(FaceSide(face: Int(side.face), sense: Int(side.sense)))
            }
            let box = Box(SIMD3(raw.min.0, raw.min.1, raw.min.2), SIMD3(raw.max.0, raw.max.1, raw.max.2))
            out.append(Region(index: Int(i), finite: raw.finite != 0, box: box, sides: sides, shells: Int(raw.shells)))
        }
        return out
    }

    /// Finite region `region` (an index into `regions()`) as a closed solid of its own: the
    /// faces bounding it, each turned to point out of it, each keeping its colour. Region 0, the
    /// infinite one, and a region past the count are refused; so is one a `UInt32` cannot hold,
    /// before the call.
    public func regionSolid(_ region: Int) throws -> Solid {
        guard let r = UInt32(exactly: region) else { throw BuildError("region_solid: region is out of range: \(region)") }
        return try Solid(cadaclysm_blacksmith_region_solid(try h(), r), "region_solid")
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
        (0..<4).allSatisfy { (i: Int) -> Bool in
            (0..<4).allSatisfy { (j: Int) -> Bool in
                let want: Double = i == j ? 1.0 : 0.0
                return m[i][j] == want
            }
        }
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

    private init(adopting handle: OpaquePointer) { self.handle = handle }

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

    /// Declare a rigid link called `name` over `placements` -- names of placements of
    /// this assembly itself, not of assemblies placed in it. An empty name, a name
    /// already taken by a link here, no placements, a placement named twice, one this
    /// assembly does not have, or one already in another link is refused and leaves the
    /// assembly as it was. Written as an AP242 kinematic link; a mechanism anywhere in
    /// the tree makes AP242 the default schema of `stepText`.
    public func link(_ name: String, _ placements: [String]) throws {
        let handle = try h()
        try withCStrings(placements) { pointers in
            let ok = pointers.withUnsafeBufferPointer { buffer in
                cadaclysm_blacksmith_assembly_link(handle, name, buffer.baseAddress, buffer.count)
            }
            guard ok else { throw failure("assembly_link") }
        }
    }

    /// Connect this assembly's links `start` and `end`, kept in that order, as a joint
    /// called `name`. An empty name, a name taken by another joint here, a link this
    /// assembly does not have, a link joined to itself, or a (start, end) pair already
    /// joined is refused; the reverse pair is a different joint.
    public func joint(_ name: String, _ start: String, _ end: String) throws {
        let handle = try h()
        guard cadaclysm_blacksmith_assembly_joint(handle, name, start, end) else { throw failure("assembly_joint") }
    }

    /// Give joint `name` its pair: `kind` (a name of the kind table -- `revolute`,
    /// `prismatic`, `cylindrical`, `screw`, `spherical`, `spherical_with_pin`, `planar`,
    /// `universal`, `homokinetic`, `fully_constrained` or `unconstrained`), the contact
    /// frame at rest, an optional `endFrame` (the frame the pair reaches at its rest
    /// values; `frame` itself, i.e. all-zero rest values, when omitted), `ranges` (one
    /// entry per freedom of `kind`, each side `nil` for unbounded; omitted entirely for a
    /// kind that allows none), and `pitch` (required and non-zero for `screw`, refused for
    /// any other kind). Throws the kernel's own text when a rule refuses it; the assembly
    /// is then unchanged.
    public func pair(
        _ joint: String, _ kind: String, _ frame: Frame,
        endFrame: Frame? = nil, ranges: [(Double?, Double?)]? = nil, pitch: Double? = nil
    ) throws {
        let handle = try h()
        let frameVals = try frameValues(frame.values)
        let endFrameVals = try endFrame.map { try frameValues($0.values) }
        // `ranges` being non-nil -- even `[]` -- means ranges were GIVEN, and the C ABI
        // must see non-null pointers with count 0, never "no ranges" (all four null, which
        // only a nil `ranges` means). `withOptionalArray` passes `baseAddress`, which is
        // nil for an *empty* array's buffer regardless of nil-ness, so a trailing dummy
        // element is padded on whenever ranges is non-nil to keep the pointer non-null;
        // `count` below stays the real (possibly 0) freedom count, so the C ABI never
        // reads the padding.
        let lower = ranges.map { $0.map { $0.0 ?? 0.0 } + [0.0] }
        let upper = ranges.map { $0.map { $0.1 ?? 0.0 } + [0.0] }
        let hasLower = ranges.map { $0.map { $0.0 != nil } + [false] }
        let hasUpper = ranges.map { $0.map { $0.1 != nil } + [false] }
        let count = ranges?.count ?? 0
        let pitchVal = pitch ?? Double.nan

        let ok = withOptionalArray(endFrameVals) { endPtr in
            withOptionalArray(lower) { lowerPtr in
                withOptionalArray(upper) { upperPtr in
                    withOptionalArray(hasLower) { hasLowerPtr in
                        withOptionalArray(hasUpper) { hasUpperPtr in
                            cadaclysm_blacksmith_assembly_pair(
                                handle, joint, kind, frameVals, endPtr,
                                lowerPtr, upperPtr, hasLowerPtr, hasUpperPtr, count, pitchVal
                            )
                        }
                    }
                }
            }
        }
        guard ok else { throw failure("assembly_pair") }
    }

    /// `pair`, for every kind: `params` are the kind's own numbers -- `screw` `[pitch]`;
    /// `rack_and_pinion` `[pinion_radius]`; `gear` `[radius_first, radius_second, ratio]` or
    /// plus `[bevel, helical_angle]` in radians, the ratio being the second link's rotation
    /// over the first's, signed; none for any other kind. Throws the kernel's own text when
    /// a rule refuses it (a wrong count among them); the assembly is then unchanged.
    public func pairWith(
        _ joint: String, _ kind: String, _ frame: Frame,
        endFrame: Frame? = nil, ranges: [(Double?, Double?)]? = nil, params: [Double] = []
    ) throws {
        let handle = try h()
        let frameVals = try frameValues(frame.values)
        let endFrameVals = try endFrame.map { try frameValues($0.values) }
        // As in `pair`: non-nil `ranges` (even `[]`) must reach the ABI as non-null pointers.
        let lower = ranges.map { $0.map { $0.0 ?? 0.0 } + [0.0] }
        let upper = ranges.map { $0.map { $0.1 ?? 0.0 } + [0.0] }
        let hasLower = ranges.map { $0.map { $0.0 != nil } + [false] }
        let hasUpper = ranges.map { $0.map { $0.1 != nil } + [false] }
        let count = ranges?.count ?? 0
        // Padded like the ranges, so an empty `params` is still a non-null pointer; the
        // count passed is the real one.
        let paramVals = params + [0.0]

        let ok = withOptionalArray(endFrameVals) { endPtr in
            withOptionalArray(lower) { lowerPtr in
                withOptionalArray(upper) { upperPtr in
                    withOptionalArray(hasLower) { hasLowerPtr in
                        withOptionalArray(hasUpper) { hasUpperPtr in
                            cadaclysm_blacksmith_assembly_pair_with(
                                handle, joint, kind, frameVals, endPtr,
                                lowerPtr, upperPtr, hasLowerPtr, hasUpperPtr, count,
                                paramVals, params.count
                            )
                        }
                    }
                }
            }
        }
        guard ok else { throw failure("assembly_pair_with") }
    }

    /// Add a named state to this assembly: `rows` gives each joint's values, in its
    /// pair's freedom order, in the caller's order. Throws the kernel's own text when a
    /// rule refuses it; the assembly is then unchanged.
    public func state(_ name: String, _ rows: [(String, [Double])]) throws {
        let handle = try h()
        let joints = rows.map { $0.0 }
        let counts = rows.map { UInt32($0.1.count) }
        let flat = rows.flatMap { $0.1 }
        try withCStrings(joints) { pointers in
            let ok = pointers.withUnsafeBufferPointer { jointsBuf in
                withOptionalArray(counts) { countsPtr in
                    withOptionalArray(flat) { flatPtr in
                        cadaclysm_blacksmith_assembly_state(
                            handle, name, jointsBuf.baseAddress, countsPtr, flatPtr, rows.count
                        )
                    }
                }
            }
            guard ok else { throw failure("assembly_state") }
        }
    }

    /// This assembly with its mechanism posed, as a new `Assembly`: `rows` gives each joint's
    /// values, in its pair's freedom order (radians, the assembly's units) -- a joint a path
    /// of placement names then the joint's name joined by "/" (a "/" or "\" inside a name
    /// escaped with "\"). `state` is a state's path, applied first and overridden row by row;
    /// `ground` one of this assembly's own links, held fixed. A sub-assembly no row reaches is
    /// shared with this one. No rows is allowed. Throws the kernel's own text when a rule
    /// refuses it; this assembly is unchanged either way.
    public func posed(
        _ rows: [(String, [Double])] = [], state: String? = nil, ground: String? = nil
    ) throws -> Assembly {
        let handle = try h()
        let joints = rows.map { $0.0 }
        let counts = rows.map { UInt32($0.1.count) }
        let flat = rows.flatMap { $0.1 }
        let made: OpaquePointer? = try withCStrings(joints) { pointers in
            pointers.withUnsafeBufferPointer { jointsBuf in
                withOptionalArray(counts) { countsPtr in
                    withOptionalArray(flat) { flatPtr in
                        cadaclysm_blacksmith_assembly_posed(
                            handle, jointsBuf.baseAddress, countsPtr, flatPtr, rows.count, state, ground
                        )
                    }
                }
            }
        }
        guard let made else { throw failure("assembly_posed") }
        return Assembly(adopting: made)
    }

    /// The placement path of every solid under this assembly, at any depth: depth first,
    /// placements in order, names joined by "/" with a "/" or "\" inside a name escaped with
    /// "\" (as `posed`'s keys). The index `sweptClash`'s rows use.
    public func parts() throws -> [String] {
        let handle = try h()
        let count = cadaclysm_blacksmith_assembly_part_count(handle)
        var names: [String] = []
        names.reserveCapacity(Int(count))
        for i in 0..<count {
            guard let raw = cadaclysm_blacksmith_assembly_part_path(handle, i) else { throw failure("assembly_part_path") }
            defer { cadaclysm_blacksmith_string_free(raw) }
            names.append(String(cString: raw))
        }
        return names
    }

    /// Every pair of this assembly's solids (indexed as `parts()` lists them) that penetrates,
    /// touches or comes within `clearance` of the other anywhere while this assembly's own
    /// mechanism moves through `keyframes`, as `SweptClash` rows in pair order. Each keyframe is
    /// rows of a joint key and its values, as `posed`'s rows are, and every keyframe names the
    /// same joints with the same number of values each (the first fixes their order); time runs
    /// in keyframe units, keyframe `k` at time `k`. Between two keyframes each joint value moves
    /// linearly and each link is posed from those values, so a link swinging about a joint goes
    /// round its arc, not along its chord. Only this assembly's own joints move: a sub-assembly
    /// rides the link its placement is in. `ground` is one of this assembly's links held fixed
    /// (nil for its default); solids in no link stay still. Pairs on two links a joint joins are
    /// not tested unless `joined`; `allowed` pairs of part indices, flat as `(a0, b0, a1, b1,
    /// ...)`, are never tested. `tolerance` meshes the parts; `resolution` and `maxSteps` as
    /// `Collider.sweptClash`. Throws in the kernel's `swept_clash:` words: here, before the
    /// library is called, for keyframes naming different joints, a joint given twice, a joint
    /// with a different number of values than in keyframe 0, or an `allowed` of odd length.
    public func sweptClash(
        _ keyframes: [[(String, [Double])]], clearance: Double = 0, tolerance: Double = 0.05,
        resolution: Double = 1e-3, maxSteps: UInt32 = 100000, allowed: [UInt32] = [],
        ground: String? = nil, joined: Bool = false
    ) throws -> [SweptClash] {
        let handle = try h()
        let first = keyframes.first ?? []
        let keys = first.map { $0.0 }
        let counts = first.map { UInt32($0.1.count) }
        var flat = first.flatMap { $0.1 }
        for (k, row) in keyframes.enumerated().dropFirst() {
            // C takes one joint set for every keyframe: a later keyframe naming other joints is
            // refused here, in the kernel's words, before C is called
            let named = row.map { $0.0 }
            for j in keys + named {
                if !named.contains(j) { throw BuildError("swept_clash: joint '\(j)' is in keyframe 0 and not in keyframe \(k)") }
                if !keys.contains(j) { throw BuildError("swept_clash: joint '\(j)' is in keyframe \(k) and not in keyframe 0") }
            }
            for (i, j) in named.enumerated() where named.firstIndex(of: j) != i {
                throw BuildError("swept_clash: joint '\(j)' is given twice")
            }
            for (j, n) in zip(keys, counts) {
                let values = row.first(where: { $0.0 == j })?.1 ?? []   // there: the check above
                if values.count != Int(n) {
                    throw BuildError("swept_clash: joint '\(j)' has \(n) values in keyframe 0 and \(values.count) in keyframe \(k)")
                }
                flat += values
            }
        }
        if allowed.count % 2 != 0 { throw BuildError("swept_clash: allowed is \(allowed.count) numbers, not pairs") }
        let found: OpaquePointer? = withCStrings(keys) { pointers in
            pointers.withUnsafeBufferPointer { keysBuf in
                withOptionalArray(counts) { countsPtr in
                    withOptionalArray(flat) { flatPtr in
                        withOptionalArray(allowed) { allowedPtr in
                            cadaclysm_blacksmith_assembly_swept_clash(
                                handle, keysBuf.baseAddress, countsPtr, keys.count, flatPtr, UInt32(keyframes.count),
                                ground, tolerance, clearance, resolution, maxSteps, allowedPtr,
                                UInt32(allowed.count / 2), joined
                            )
                        }
                    }
                }
            }
        }
        guard let found else { throw failure("assembly_swept_clash") }
        return try sweptClashesOf(found)
    }

    /// Add a named motion sequence over this assembly's states: each segment is
    /// `(state name, parameter, interpolation)`, the interpolation one of `"undefined"`,
    /// `"discontinuous"`, `"synchronous"` or `"linear"`. `seconds` writes the parameter's
    /// unit as the second. It is closed unless the last segment is `"discontinuous"`. Throws
    /// the kernel's own text when a rule refuses it; the assembly is then unchanged.
    public func sequence(_ name: String, _ segments: [(String, Double, String)], seconds: Bool = false) throws {
        let handle = try h()
        let states = segments.map { $0.0 }
        let ts = segments.map { $0.1 }
        let words = segments.map { $0.2 }
        try withCStrings(states) { statePointers in
            try withCStrings(words) { wordPointers in
                let ok = statePointers.withUnsafeBufferPointer { statesBuf in
                    wordPointers.withUnsafeBufferPointer { wordsBuf in
                        withOptionalArray(ts) { tsPtr in
                            cadaclysm_blacksmith_assembly_sequence(
                                handle, name, statesBuf.baseAddress, tsPtr, wordsBuf.baseAddress,
                                segments.count, seconds
                            )
                        }
                    }
                }
                guard ok else { throw failure("assembly_sequence") }
            }
        }
    }

    /// Declare this assembly's base link. Throws the kernel's own text when a rule
    /// refuses it; the assembly is then unchanged.
    public func base(_ link: String) throws {
        guard cadaclysm_blacksmith_assembly_base(try h(), link) else { throw failure("assembly_base") }
    }

    /// How many freedoms a pair kind has -- see `cadaclysm_blacksmith_pair_freedom_count`.
    /// 0 for an unknown name, and for `fully_constrained`, which has none.
    public static func pairFreedomCount(_ kind: String) -> Int {
        Int(cadaclysm_blacksmith_pair_freedom_count(kind))
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

/// Runs `body` with one C string per element of `strings`, every one kept alive for the
/// whole call: `withCString`'s own scope only covers one string, so a list is built with
/// `strdup`, freed in a `defer` regardless of how `body` returns or throws.
private func withCStrings<R>(_ strings: [String], _ body: ([UnsafePointer<CChar>?]) throws -> R) rethrows -> R {
    let pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return try body(pointers.map { UnsafePointer($0) })
}

/// Runs `body` with `values` as a C array pointer, or nil when `values` is nil -- for the
/// optional `double`/`bool` arrays `Assembly.pair` and `Assembly.state` pass on.
private func withOptionalArray<T, R>(_ values: [T]?, _ body: (UnsafePointer<T>?) -> R) -> R {
    guard let values else { return body(nil) }
    return values.withUnsafeBufferPointer { body($0.baseAddress) }
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
/// What a solid measures, per unit density, each figure beside a bound on its own error.
///
/// Per unit density is the primitive: a body's weight is `density * volume` and its inertia scales
/// the same way, so `weight(_:)` is the only figure that takes one. Nothing here multiplies by a
/// density on your behalf -- an assembly of two materials would have to undo it.
///
/// `volume`, `centroid`, `inertia` and `principalMoments` mean something only where `closed`. Where
/// `accuracyMet` is false the refinement stopped before the accuracy asked for: the figures are
/// honest, they are simply less certain, and the errors say by how much.
public struct Mass: Equatable, CustomStringConvertible {
    /// Closed, so the volume-side figures mean something.
    public let closed: Bool
    /// Every face pointed inward; the figures are given as if they had not.
    public let inverted: Bool
    /// Every error came under the accuracy asked for.
    public let accuracyMet: Bool
    /// Measured on a mesh rather than exact surfaces, so the errors are the rounding floor.
    public let fromMesh: Bool
    /// The surface area.
    public let area: Double
    /// A bound on `area`'s own error.
    public let areaError: Double
    /// The volume enclosed, where `closed`.
    public let volume: Double
    /// A bound on `volume`'s own error.
    public let volumeError: Double
    /// The volume's centroid, where `closed`.
    public let centroid: SIMD3<Double>
    /// A bound on the distance from `centroid` to the true centroid.
    public let centroidError: Double
    /// Three rows of three about the centroid, products of inertia negated.
    public let inertia: [SIMD3<Double>]
    /// A bound on every entry of `inertia`.
    public let inertiaError: Double
    /// Ascending.
    public let principalMoments: SIMD3<Double>
    /// Unit, orthogonal, right-handed; row `i` belongs to moment `i`.
    public let principalAxes: [SIMD3<Double>]

    init(_ raw: CadaclysmBlacksmithMassProperties) {
        closed = raw.closed != 0
        inverted = raw.inverted != 0
        accuracyMet = raw.accuracy_met != 0
        fromMesh = raw.from_mesh != 0
        area = raw.area
        areaError = raw.area_error
        volume = raw.volume
        volumeError = raw.volume_error
        centroid = SIMD3(raw.centroid.0, raw.centroid.1, raw.centroid.2)
        centroidError = raw.centroid_error
        let i = raw.inertia
        inertia = [SIMD3(i.0, i.1, i.2), SIMD3(i.3, i.4, i.5), SIMD3(i.6, i.7, i.8)]
        inertiaError = raw.inertia_error
        principalMoments = SIMD3(raw.principal_moments.0, raw.principal_moments.1, raw.principal_moments.2)
        let a = raw.principal_axes
        principalAxes = [SIMD3(a.0, a.1, a.2), SIMD3(a.3, a.4, a.5), SIMD3(a.6, a.7, a.8)]
    }

    /// `density * volume`, in whatever units the model and the density agree on.
    public func weight(_ density: Double) -> Double { density * volume }

    public var description: String {
        closed
            ? "Mass(area: \(area), volume: \(volume), centroid: \(centroid))"
            : "Mass(open, area: \(area))"
    }
}

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

/// One free edge (a side only one face bounds) with its nearest partner: its `trim` (the face's
/// side), the `edge` it lies on (nil for a side with no edge), the `face` and free `wire` (a row
/// of `HealthReport.wires`) it is on, its nearest `partner` across the gap as a row of
/// `HealthReport.freeEdges` (nil if there is none), how many of its two ends it `sharedEnds`
/// with that partner (2 is what sewing joins), its `length` and the `gap` to the partner
/// (infinite without one).
public struct FreeEdge: Equatable {
    public let trim: Int
    public let edge: Int?
    public let face: Int
    public let wire: Int
    public let partner: Int?
    public let sharedEnds: Int
    public let length: Double
    public let gap: Double

    public init(trim: Int, edge: Int?, face: Int, wire: Int, partner: Int?, sharedEnds: Int, length: Double, gap: Double) {
        self.trim = trim
        self.edge = edge
        self.face = face
        self.wire = wire
        self.partner = partner
        self.sharedEnds = sharedEnds
        self.length = length
        self.gap = gap
    }
}

/// A chain of free edges end to end: the rows `first ..< first + count` of
/// `HealthReport.freeEdges`, whether it `closed` on itself, its total `length` and the
/// `widestGap` from any of its edges to a partner.
public struct FreeWire: Equatable {
    public let first: Int
    public let count: Int
    public let closed: Bool
    public let length: Double
    public let widestGap: Double

    public init(first: Int, count: Int, closed: Bool, length: Double, widestGap: Double) {
        self.first = first
        self.count = count
        self.closed = closed
        self.length = length
        self.widestGap = widestGap
    }
}

/// Something below the tolerance: `kind` is `"short_edge"`, `"collapsed_edge"`,
/// `"sliver_face"`, `"tiny_face"`, `"tiny_body"` or `"small_hole"`; `index` its edge, face or
/// body number (a small hole's is its loop number); `size` how small.
public struct SmallFeature: Equatable {
    public let kind: String
    public let index: Int
    public let size: Double

    public init(kind: String, index: Int, size: Double) {
        self.kind = kind
        self.index = index
        self.size = size
    }
}

/// What a mesh of the body shows (`Solid.health(mesh: true)`): whether it is `watertight`, how
/// many mesh edges are `open` (one triangle) or `folded` (more than two), how many pairs of
/// triangles cross (`crossings`), and the brep `edges` the cracks lie along. Only a closed body
/// is counted: an open one's census is empty by design.
public struct Cracks: Equatable {
    public let watertight: Bool
    public let open: Int
    public let folded: Int
    public let crossings: Int
    public let edges: [Int]

    public init(watertight: Bool, open: Int, folded: Int, crossings: Int, edges: [Int]) {
        self.watertight = watertight
        self.open = open
        self.folded = folded
        self.crossings = crossings
        self.edges = edges
    }
}

/// What is wrong with a body, as plain data (`Solid.health`): the `tolerance` and `rounding` it
/// judged at and the body's `extent` (its diagonal); the free edges, their wires, the features
/// below the tolerance; the loose edges (`worstLoose` the widest such gap); what sewing would do
/// (`sewPairs` joined, `sewRefused`, `sewWorstGap`); `worstGap`, the widest gap between a free
/// edge and its partner; and, if asked for with `mesh: true`, the mesh's `cracks`.
public struct HealthReport: Equatable {
    public let tolerance: Double
    public let rounding: Double
    public let extent: Double
    public let freeEdges: [FreeEdge]
    public let wires: [FreeWire]
    public let small: [SmallFeature]
    public let looseEdges: Int
    public let worstLoose: Double
    public let sewPairs: Int
    public let sewRefused: Int
    public let sewWorstGap: Double
    public let cracks: Cracks?
    public let worstGap: Double

    /// The free edges of wire number `wire`, in order.
    public func wireEdges(_ wire: Int) -> [FreeEdge] {
        let w = wires[wire]
        return Array(freeEdges[w.first ..< w.first + w.count])
    }

    /// The flat rows of the health C ABI, decoded index for index as cadaclysm_blacksmith.py's
    /// `_health_report`.
    init(counts: [UInt32], sizes: [Double], freeIds: [UInt32], freeSizes: [Double], wireRuns: [UInt32],
         wireSizes: [Double], smallItems: [UInt32], smallSizes: [Double], crackEdges: [UInt32]) {
        // UInt32.max is "none"; typed closures and sub-expressions keep the type checker fast.
        let index: (UInt32) -> Int? = { $0 == UInt32.max ? nil : Int($0) }
        freeEdges = (0 ..< freeIds.count / 6).map { (i: Int) -> FreeEdge in
            let ids: ArraySlice<UInt32> = freeIds[6 * i ..< 6 * i + 6]
            let at: Int = ids.startIndex
            return FreeEdge(trim: Int(ids[at]), edge: index(ids[at + 1]), face: Int(ids[at + 2]),
                            wire: Int(ids[at + 3]), partner: index(ids[at + 4]), sharedEnds: Int(ids[at + 5]),
                            length: freeSizes[2 * i], gap: freeSizes[2 * i + 1])
        }
        wires = (0 ..< wireRuns.count / 3).map { (i: Int) -> FreeWire in
            let closed: Bool = wireRuns[3 * i + 2] != 0
            return FreeWire(first: Int(wireRuns[3 * i]), count: Int(wireRuns[3 * i + 1]), closed: closed,
                            length: wireSizes[2 * i], widestGap: wireSizes[2 * i + 1])
        }
        small = (0 ..< smallSizes.count).map { i in
            SmallFeature(kind: healthKind(smallItems[2 * i]), index: Int(smallItems[2 * i + 1]), size: smallSizes[i])
        }
        cracks = counts[12] == 1
            ? Cracks(watertight: counts[13] != 0, open: Int(counts[14]), folded: Int(counts[15]),
                     crossings: Int(counts[16]), edges: crackEdges.map { Int($0) })
            : nil
        tolerance = sizes[0]
        rounding = sizes[1]
        extent = sizes[2]
        worstGap = sizes[3]
        looseEdges = Int(counts[9])
        worstLoose = sizes[4]
        sewPairs = Int(counts[10])
        sewRefused = Int(counts[11])
        sewWorstGap = sizes[5]
    }
}

/// One small feature `Solid.healed` removed: its `kind` (as `SmallFeature.kind`), its `index` in
/// the input (as `health` gave it), its `size`, and how far the vertices it merged `moved`.
public struct HealFix: Equatable {
    public let kind: String
    public let index: Int
    public let size: Double
    public let moved: Double

    public init(kind: String, index: Int, size: Double, moved: Double) {
        self.kind = kind
        self.index = index
        self.size = size
        self.moved = moved
    }
}

/// One small feature `Solid.healed` left, and why: `kind` and `index` as in `HealFix`; `why` is
/// `"would_empty_loop"`, `"closed"`, `"seam"`, `"chain"`, `"neighbours_part"`, `"uneven"`,
/// `"non_manifold"`, `"has_holes"`, `"body_guard"`, `"toggled"` or `"unsupported"`; `figure`
/// the chain's width or the neighbours' gap, else 0.
public struct HealRefusal: Equatable {
    public let kind: String
    public let index: Int
    public let why: String
    public let figure: Double

    public init(kind: String, index: Int, why: String, figure: Double) {
        self.kind = kind
        self.index = index
        self.why = why
        self.figure = figure
    }
}

/// What `Solid.healed` did, as plain data: the `tolerance` it healed at, the furthest any trim
/// the result keeps `moved`, whether the body guard refused fixes (`guarded`), the `fixes` made
/// and the features `refused`; and the body's health before and after at that tolerance -- its
/// small features, free edges, whether it is closed, and its non-manifold edges.
public struct HealReport: Equatable {
    public let tolerance: Double
    public let moved: Double
    public let guarded: Bool
    public let fixes: [HealFix]
    public let refused: [HealRefusal]
    public let smallBefore: Int
    public let smallAfter: Int
    public let freeBefore: Int
    public let freeAfter: Int
    public let closedBefore: Bool
    public let closedAfter: Bool
    public let nonmanifoldBefore: Int
    public let nonmanifoldAfter: Int

    /// The flat rows of the heal C ABI, decoded index for index as cadaclysm_blacksmith.py's `_heal_report`.
    init(counts: [UInt32], sizes: [Double], fixItems: [UInt32], fixSizes: [Double], refusedItems: [UInt32],
         refusedSizes: [Double]) {
        fixes = (0 ..< fixItems.count / 2).map { i in
            HealFix(kind: healthKind(fixItems[2 * i]), index: Int(fixItems[2 * i + 1]), size: fixSizes[2 * i],
                    moved: fixSizes[2 * i + 1])
        }
        refused = (0 ..< refusedSizes.count).map { i in
            HealRefusal(kind: healthKind(refusedItems[3 * i]), index: Int(refusedItems[3 * i + 1]),
                        why: healWhy(refusedItems[3 * i + 2]), figure: refusedSizes[i])
        }
        tolerance = sizes[0]
        moved = sizes[1]
        guarded = counts[2] != 0
        smallBefore = Int(counts[3])
        smallAfter = Int(counts[4])
        freeBefore = Int(counts[5])
        freeAfter = Int(counts[6])
        closedBefore = counts[7] != 0
        closedAfter = counts[8] != 0
        nonmanifoldBefore = Int(counts[9])
        nonmanifoldAfter = Int(counts[10])
    }
}

/// The small-feature kinds, by the C ABI's code.
let healthKinds = ["short_edge", "collapsed_edge", "sliver_face", "tiny_face", "tiny_body", "small_hole"]
/// Why healing left a feature, by the C ABI's code.
let healWhys = ["would_empty_loop", "closed", "seam", "chain", "neighbours_part", "uneven", "non_manifold",
                "has_holes", "body_guard", "toggled", "unsupported"]

private func healthKind(_ code: UInt32) -> String {
    Int(code) < healthKinds.count ? healthKinds[Int(code)] : "unknown"
}

private func healWhy(_ code: UInt32) -> String {
    Int(code) < healWhys.count ? healWhys[Int(code)] : "unknown"
}

/// `healed`'s switches as the C ABI's flag bits: 1 edges, 2 faces, 4 holes.
func healFlags(edges: Bool, faces: Bool, holes: Bool) -> UInt32 {
    (edges ? 1 : 0) | (faces ? 2 : 0) | (holes ? 4 : 0)
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

/// An intersection handle read out and freed, on every path: what `Solid.intersect` and
/// `Clash.intersect` return.
func intersectionOf(_ found: OpaquePointer) throws -> Intersection {
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
/// empty for a partial overlap of curved faces whose outlines cross.
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

// MARK: - Measure

/// A solid's box on its principal axes (`Solid.orientedBox`): `centre`, three unit `axes` (row `i`
/// the direction of `half[i]`) and the `half` extent along each.
public struct OrientedBox: Equatable, CustomStringConvertible {
    public let centre: SIMD3<Double>
    public let axes: [SIMD3<Double>]
    public let half: SIMD3<Double>

    init(_ raw: CadaclysmBlacksmithOrientedBox) {
        centre = SIMD3(raw.centre.0, raw.centre.1, raw.centre.2)
        let a = raw.axes
        axes = [SIMD3(a.0, a.1, a.2), SIMD3(a.3, a.4, a.5), SIMD3(a.6, a.7, a.8)]
        half = SIMD3(raw.half.0, raw.half.1, raw.half.2)
    }

    public var description: String { "OrientedBox(centre=\(centre), axes=\(axes), half=\(half))" }
}

/// A measured length beside the error it carries (`Solid.edgeLength`, `Profile.length`). `error`
/// is an estimate of the difference from the true length; `accuracyMet` false means the refinement
/// stopped at its depth limit, and `fromPolyline` that the curve was sampled points.
public struct Length: Equatable, CustomStringConvertible {
    public let length: Double
    public let error: Double
    public let accuracyMet: Bool
    public let fromPolyline: Bool

    init(_ raw: CadaclysmBlacksmithLength) {
        length = raw.length
        error = raw.error
        accuracyMet = raw.accuracy_met != 0
        fromPolyline = raw.from_polyline != 0
    }

    public var description: String {
        "Length(\(length), error=\(error), accuracyMet=\(accuracyMet), fromPolyline=\(fromPolyline))"
    }
}

/// A point `s` along an edge or a profile's outer loop (`Solid.edgePointAtLength`,
/// `Profile.pointAtLength`, the divides): where it is, the unit `tangent` there and the curve's
/// `parameter`. `segment` is nil on a solid's edge; on a profile it is the side the point lies on
/// (the segment count for the implicit closing side) and `parameter` that side's own. `error`
/// estimates the arc length's difference from the true one; `fromPolyline` says the curve was
/// sampled points.
public struct At: Equatable, CustomStringConvertible {
    public let point: SIMD3<Double>
    public let tangent: SIMD3<Double>
    public let parameter: Double
    public let segment: UInt32?
    public let error: Double
    public let fromPolyline: Bool

    init(_ raw: CadaclysmBlacksmithAt) {
        point = SIMD3(raw.point.0, raw.point.1, raw.point.2)
        tangent = SIMD3(raw.tangent.0, raw.tangent.1, raw.tangent.2)
        parameter = raw.parameter
        segment = raw.segment == none ? nil : raw.segment
        error = raw.error
        fromPolyline = raw.from_polyline != 0
    }

    public var description: String {
        "At(point=\(point), tangent=\(tangent), parameter=\(parameter), segment=\(segment.map { String($0) } ?? "nil"), error=\(error), fromPolyline=\(fromPolyline))"
    }
}

/// Reads and frees a divide's sample list; a failing call or read throws the library's own text.
private func samplesOf(_ list: OpaquePointer?, _ what: String) throws -> [At] {
    guard let list else { throw failure(what) }
    defer { cadaclysm_blacksmith_samples_free(list) }
    let count = cadaclysm_blacksmith_samples_count(list)
    var out: [At] = []
    out.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithAt()
        if !cadaclysm_blacksmith_samples_at(list, i, &raw) { throw failure("samples_at") }
        out.append(At(raw))
    }
    return out
}

/// The closest points between two solids' boundaries (`Solid.closest`) and what each lies on: a
/// `kind` of `"face"`, `"edge"` or `"vertex"`, its `index`, and for an edge the `Solid.edges`
/// index `fillet` takes (nil when it has none). `refined` is false for the mesh's own answer.
public struct Closest: Equatable, CustomStringConvertible {
    public let distance: Double
    public let onA: SIMD3<Double>
    public let onB: SIMD3<Double>
    public let kindA: String
    public let indexA: UInt32
    public let edgeA: UInt32?
    public let kindB: String
    public let indexB: UInt32
    public let edgeB: UInt32?
    public let refined: Bool

    init(_ raw: CadaclysmBlacksmithClosest) {
        distance = raw.distance
        onA = SIMD3(raw.on_a.0, raw.on_a.1, raw.on_a.2)
        onB = SIMD3(raw.on_b.0, raw.on_b.1, raw.on_b.2)
        kindA = text(raw.kind_a)
        indexA = raw.index_a
        edgeA = raw.edge_a == none ? nil : raw.edge_a
        kindB = text(raw.kind_b)
        indexB = raw.index_b
        edgeB = raw.edge_b == none ? nil : raw.edge_b
        refined = raw.refined != 0
    }

    public var description: String {
        "Closest(distance=\(distance), a=\(kindA) \(indexA), b=\(kindB) \(indexB), refined=\(refined))"
    }
}

/// The containment code the library answered, as the word.
func containment(_ code: UInt32, _ call: String) throws -> String {
    switch code {
    case UInt32(CADACLYSM_BLACKSMITH_OUTSIDE): return "outside"
    case UInt32(CADACLYSM_BLACKSMITH_INSIDE): return "inside"
    case UInt32(CADACLYSM_BLACKSMITH_ON): return "on"
    default: throw BuildError("\(call): the library answered \(code), not a containment code")
    }
}

/// Points classified against one closed solid, meshed once (`Solid.classifier`). It keeps its own
/// reference to the body, so it answers on after its `Solid` is closed. `close()` frees it; so
/// does `deinit`.
public final class Classifier {
    private var handle: OpaquePointer?

    init(_ solid: OpaquePointer, _ tolerance: Double) throws {
        handle = try checked(cadaclysm_blacksmith_classifier_new(solid, tolerance), "classifier_new")
    }

    deinit { close() }

    /// Free the classifier now. Idempotent.
    public func close() {
        if let handle { cadaclysm_blacksmith_classifier_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("classifier: closed") }
        return handle
    }

    /// `"inside"`, `"outside"` or `"on"`.
    public func contains(_ point: SIMD3<Double>) throws -> String {
        let xyz = [point.x, point.y, point.z]
        var code: UInt32 = 0
        if !cadaclysm_blacksmith_classifier_contains(try h(), xyz, &code) { throw failure("classifier_contains") }
        return try containment(code, "classifier_contains")
    }
}

// MARK: - Collider

/// An axis-aligned box: `lo` and `hi`, three numbers each. The broad phase's own shape
/// (`Solid.boundsBox`, `Collider`'s own boxes): cheap to move and to test against another,
/// before anything is meshed.
public struct Box: Equatable, CustomStringConvertible {
    public let lo: SIMD3<Double>
    public let hi: SIMD3<Double>

    public init(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) {
        self.lo = lo
        self.hi = hi
    }

    init(_ raw: CadaclysmBlacksmithBox) {
        lo = SIMD3(raw.lo.0, raw.lo.1, raw.lo.2)
        hi = SIMD3(raw.hi.0, raw.hi.1, raw.hi.2)
    }

    var words: CadaclysmBlacksmithBox {
        var raw = CadaclysmBlacksmithBox()
        raw.lo = (lo.x, lo.y, lo.z)
        raw.hi = (hi.x, hi.y, hi.z)
        return raw
    }

    /// This box moved by `frame` (rigid), boxed again on the world axes -- not this box's
    /// corners individually moved, which would not in general be a box at all: the
    /// *bounding* box of the moved corners.
    public func moved(_ frame: Frame) throws -> Box {
        var raw = words
        var out = CadaclysmBlacksmithBox()
        if !cadaclysm_blacksmith_box_moved(&raw, frame.values, &out) { throw failure("box_moved") }
        return Box(out)
    }

    /// Whether this box and `other` share a point (touching counts).
    public func overlaps(_ other: Box) -> Bool {
        var a = words
        var b = other.words
        return cadaclysm_blacksmith_box_overlaps(&a, &b)
    }

    public var description: String { "Box(lo=\(lo), hi=\(hi))" }
}

/// One side of one face (`Solid.regions`): `face` the face's index in the solid, `sense` +1 for
/// the side its normal points to, -1 for the other. A solid's inside is behind its faces, at -1.
public struct FaceSide: Hashable, CustomStringConvertible {
    public let face: Int
    public let sense: Int

    public init(face: Int, sense: Int) {
        self.face = face
        self.sense = sense
    }

    public var description: String { "FaceSide(face=\(face), sense=\(sense))" }
}

/// One region of space a solid's faces bound (`Solid.regions`): its `index` (0 the infinite
/// region, whose `finite` is false), the `box` round the faces bounding it, its `sides`
/// ascending by face then sense, and its `shells` -- 1, plus one per void inside it.
/// `Solid.regionSolid` takes a finite one as a solid of its own.
public struct Region: Equatable, CustomStringConvertible {
    public let index: Int
    public let finite: Bool
    public let box: Box
    public let sides: [FaceSide]
    public let shells: Int

    public init(index: Int, finite: Bool, box: Box, sides: [FaceSide], shells: Int) {
        self.index = index
        self.finite = finite
        self.box = box
        self.sides = sides
        self.shells = shells
    }

    public var description: String {
        "Region(index=\(index), finite=\(finite), box=\(box), \(sides.count) sides, shells=\(shells))"
    }
}

/// True only if box `a` at `frameA` and box `b` at `frameB` cannot touch -- a separating
/// axis among the boxes' face normals and edge-direction crosses; touching is not apart.
/// Sharper than moving each box and asking `Box.overlaps`, which boxes the *result* on the
/// world axes again and so can call two oriented boxes overlapping when they are not (two
/// unit boxes, the second turned 45 degrees about z and moved 2.3 along x: their world
/// boxes overlap, but the boxes themselves do not touch).
public func boxesApart(_ a: Box, _ frameA: Frame, _ b: Box, _ frameB: Frame) throws -> Bool {
    var ra = a.words
    var rb = b.words
    var apart = false
    if !cadaclysm_blacksmith_boxes_apart(&ra, frameA.values, &rb, frameB.values, &apart) {
        throw failure("boxes_apart")
    }
    return apart
}

/// Counts of one `Collider.check` call: the candidate pairs `considered`, how many of them
/// the world boxes and the oriented boxes cleared, how many the share left to another call,
/// how the rest were answered (`cached`, `closedForm`, `meshed`), and how many were
/// `refused`. `confirmed` is the subset of `meshed` that were thin mesh-path overlaps sent
/// to `Solid.common` itself for a final answer.
public struct ColliderStats: Equatable, CustomStringConvertible {
    public let considered: Int
    public let worldBoxes: Int
    public let orientedBoxes: Int
    public let skippedShare: Int
    public let cached: Int
    public let closedForm: Int
    public let meshed: Int
    public let refused: Int
    public let confirmed: Int

    init(_ raw: CadaclysmBlacksmithColliderStats) {
        considered = Int(raw.considered)
        worldBoxes = Int(raw.world_boxes)
        orientedBoxes = Int(raw.oriented_boxes)
        skippedShare = Int(raw.skipped_share)
        cached = Int(raw.cached)
        closedForm = Int(raw.closed_form)
        meshed = Int(raw.meshed)
        refused = Int(raw.refused)
        confirmed = Int(raw.confirmed)
    }

    public var description: String {
        "ColliderStats(considered=\(considered), worldBoxes=\(worldBoxes), orientedBoxes=\(orientedBoxes), "
            + "skippedShare=\(skippedShare), cached=\(cached), closedForm=\(closedForm), meshed=\(meshed), "
            + "refused=\(refused), confirmed=\(confirmed))"
    }
}

/// Keeps one `Collider.check` answer alive for as long as any `CollisionHit` of it is: each
/// hit holds a reference to this, and ARC frees it only once the last one lets go -- a
/// `CollisionHit` needs the handle itself back for `solid()`.
final class Collisions {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { cadaclysm_blacksmith_collisions_free(handle) }
}

/// One pair `Collider.check` found overlapping (`overlap` true), or could not decide
/// (`overlap` false; `text` says why, empty for an overlap). `positions`/`normals` are world
/// xyz triples, three per triangle (unwelded); `indices` indexes them -- all empty for a
/// refused pair. `depth` is the thinnest side of the overlap's world box, 0 for a refused
/// pair.
///
/// `solid()` rebuilds the exact overlap now, from the frames `Collider.check` found it at;
/// this keeps the collisions handle behind every hit of one `check` call alive until the
/// last of them is released, freeing it only then. Named `CollisionHit` rather than the
/// plainer `Hit`, which this module already uses for a curve-crossing result
/// (`Solid.hits`).
public final class CollisionHit: CustomStringConvertible {
    public let a: Int
    public let b: Int
    public let overlap: Bool
    /// `"overlap"` or `"refused"` -- the same answer as `overlap`.
    public let kind: String
    public let depth: Double
    public let text: String
    public let positions: [SIMD3<Double>]
    public let normals: [SIMD3<Double>]
    public let indices: [UInt32]

    private let collisions: Collisions
    private let index: UInt32

    init(_ raw: CadaclysmBlacksmithCollisionHit, _ collisions: Collisions, _ index: UInt32) {
        a = Int(raw.a)
        b = Int(raw.b)
        overlap = raw.overlap
        kind = raw.overlap ? "overlap" : "refused"
        depth = raw.depth
        text = Blacksmith.text(raw.text)
        positions = pointsAt(raw.positions, raw.vertex_count)
        normals = pointsAt(raw.normals, raw.vertex_count)
        if let at = raw.indices, raw.index_count > 0 {
            indices = Array(UnsafeBufferPointer(start: at, count: Int(raw.index_count)))
        } else {
            indices = []
        }
        self.collisions = collisions
        self.index = index
    }

    /// The exact overlap of this pair at the frames `Collider.check` found it at, as a new
    /// solid. Throws for a refused pair (`overlap` false) or a collisions handle already
    /// closed some other way.
    public func solid() throws -> Solid {
        try withExtendedLifetime(collisions) {
            try Solid(cadaclysm_blacksmith_collisions_solid(collisions.handle, index), "collisions_solid")
        }
    }

    public var description: String { "CollisionHit(a=\(a), b=\(b), overlap=\(overlap), depth=\(depth))" }
}

/// Keeps one clash call's answer alive for as long as any `Clash` of it is: each row holds a
/// reference to this, and ARC frees it only once the last one lets go -- as `Collisions` does
/// for `CollisionHit`, because `solid()` and `intersect()` need the handle itself back.
final class Clashes {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { cadaclysm_blacksmith_clashes_free(handle) }
}

/// One pair a clash call (`Collider.clash`, `clash`) found: `a`, `b` the part indices (for one
/// set or a collider `a < b`; for two sets `a` indexes the first and `b` the second), `kind` one
/// of `"penetrating"`, `"touching"` (the boundaries within the tolerance of each other),
/// `"too_close"` (apart by more than the tolerance but less than the clearance) or `"refused"`
/// (the pair could not be decided; `text` says why).
///
/// `distance` is the gap between the two boundaries (0 for a penetrating or refused pair);
/// `onA` and `onB` are world points -- the closest pair, or for a penetrating pair the centre of
/// the overlap's world box (the origin for a refused one). `kindA`, `indexA`, `edgeA` (and `B`)
/// say what each point lies on exactly as `Closest` does -- `"face"`, `"edge"` or `"vertex"`,
/// the kernel's id, and the `Solid.edges` index (nil for a face, a vertex or an edge the table
/// does not hold) -- and for a penetrating or refused pair `kindA`/`kindB` are `"none"` with
/// `index*` and `edge*` nil. `refined` is true where the distance is measured on the exact
/// surfaces. `depth` is the thinnest side of a penetrating pair's overlap box (0 otherwise).
///
/// `solid()` rebuilds a penetrating pair's shared volume now; `intersect()` where the two parts
/// cross or coincide (any pair but a refused one). Both use the placement the pair was found
/// at. Every row of one call keeps the clashes handle behind it alive, and the last one
/// released frees it.
public struct Clash: CustomStringConvertible {
    public let a: Int
    public let b: Int
    public let kind: String
    public let distance: Double
    public let onA: SIMD3<Double>
    public let onB: SIMD3<Double>
    public let kindA: String
    public let indexA: UInt32?
    public let edgeA: UInt32?
    public let kindB: String
    public let indexB: UInt32?
    public let edgeB: UInt32?
    public let refined: Bool
    public let depth: Double
    public let text: String

    private let clashes: Clashes
    private let index: UInt32

    init(_ raw: CadaclysmBlacksmithClash, _ clashes: Clashes, _ index: UInt32) {
        a = Int(raw.a)
        b = Int(raw.b)
        kind = Blacksmith.text(raw.kind)
        distance = raw.distance
        onA = SIMD3(raw.on_a.0, raw.on_a.1, raw.on_a.2)
        onB = SIMD3(raw.on_b.0, raw.on_b.1, raw.on_b.2)
        kindA = Blacksmith.text(raw.kind_a)
        kindB = Blacksmith.text(raw.kind_b)
        let noneA = kindA == "none", noneB = kindB == "none"
        indexA = noneA ? nil : raw.index_a
        edgeA = noneA || raw.edge_a == none ? nil : raw.edge_a
        indexB = noneB ? nil : raw.index_b
        edgeB = noneB || raw.edge_b == none ? nil : raw.edge_b
        refined = raw.refined != 0
        depth = raw.depth
        text = Blacksmith.text(raw.text)
        self.clashes = clashes
        self.index = index
    }

    /// The exact shared volume of this penetrating pair at the placement it was found at, as a
    /// new solid. Throws for a pair that is not penetrating.
    public func solid() throws -> Solid {
        try withExtendedLifetime(clashes) {
            try Solid(cadaclysm_blacksmith_clashes_solid(clashes.handle, index), "clashes_solid")
        }
    }

    /// Where this pair's two parts cross or coincide at the placement it was found at, as
    /// `Solid.intersect` reports it (a touching pair's shared face is an `Overlap`). Throws for a
    /// refused pair.
    public func intersect() throws -> Intersection {
        try withExtendedLifetime(clashes) {
            guard let found = cadaclysm_blacksmith_clashes_intersect(clashes.handle, index) else {
                throw failure("clashes_intersect")
            }
            return try intersectionOf(found)
        }
    }

    public var description: String { "Clash(a=\(a), b=\(b), kind=\(kind), distance=\(distance))" }
}

/// A clashes handle read out into rows, each keeping the handle alive; freed at once if empty,
/// and by the owner if reading a row fails.
func clashesOf(_ found: OpaquePointer) throws -> [Clash] {
    let count = cadaclysm_blacksmith_clashes_count(found)
    if count == 0 {
        cadaclysm_blacksmith_clashes_free(found)
        return []
    }
    let clashes = Clashes(found)
    var rows: [Clash] = []
    rows.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithClash()
        if !cadaclysm_blacksmith_clashes_at(found, i, &raw) { throw failure("clashes_at") }
        rows.append(Clash(raw, clashes, i))
    }
    return rows
}

/// One pair a swept clash call (`Collider.sweptClash`, `sweptClash`) found: `a`, `b` the part
/// indices (for one set or a collider `a < b`; for two sets `a` indexes the first and `b` the
/// second). `firstTime` is the first time the pair came within the clearance, in pose units
/// (pose `k` at time `k`; for a refused pair the time it was refused at), and `first` the `Clash`
/// there -- its kind, distance, points, features and depth, at the frames the motion places the
/// parts at that time, so `first.solid()` and `first.intersect()` rebuild the contact there.
/// `intervals` are the time ranges the pair stays in clash, ascending and disjoint (none for a
/// refused pair).
public struct SweptClash: CustomStringConvertible {
    public let a: Int
    public let b: Int
    public let firstTime: Double
    public let first: Clash
    public let intervals: [(start: Double, end: Double)]

    public var description: String {
        let spans = intervals.map { "(\($0.start), \($0.end))" }.joined(separator: ", ")
        return "SweptClash(a=\(a), b=\(b), first_time=\(firstTime), kind=\(first.kind), intervals=[\(spans)])"
    }
}

/// A swept clashes handle read out into rows and freed; each row's `first` a `Clash` of the
/// handle's first rows (`clashesOf`), which keep their own clashes handle alive.
func sweptClashesOf(_ swept: OpaquePointer) throws -> [SweptClash] {
    defer { cadaclysm_blacksmith_swept_clashes_free(swept) }
    let count = cadaclysm_blacksmith_swept_clashes_count(swept)
    if count == 0 { return [] }
    guard let found = cadaclysm_blacksmith_swept_clashes_firsts(swept) else { throw failure("swept_clashes_firsts") }
    let firsts = try clashesOf(found)
    var rows: [SweptClash] = []
    rows.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithSweptClash()
        if !cadaclysm_blacksmith_swept_clashes_at(swept, i, &raw) { throw failure("swept_clashes_at") }
        var intervals: [(start: Double, end: Double)] = []
        intervals.reserveCapacity(Int(raw.interval_count))
        var span = [0.0, 0.0]
        for k in 0..<raw.interval_count {
            if !cadaclysm_blacksmith_swept_clashes_interval(swept, i, k, &span) { throw failure("swept_clashes_interval") }
            intervals.append((start: span[0], end: span[1]))
        }
        rows.append(SweptClash(a: Int(raw.a), b: Int(raw.b), firstTime: raw.first_time, first: firsts[Int(i)],
                               intervals: intervals))
    }
    return rows
}

/// Poses flattened pose by pose, 12 numbers a frame, as the swept clash calls read them.
func poseFrames(_ poses: [[Frame]]) -> [Double] {
    var flat: [Double] = []
    flat.reserveCapacity(poses.reduce(0) { $0 + $1.count } * 12)
    for pose in poses {
        for f in pose { flat.append(contentsOf: f.values) }
    }
    return flat
}

/// Parts meshed once, asked pose after pose which of them interfere: `solids` at rest,
/// meshed at `tolerance`; `groups` one group index per solid (nil: each solid its own group
/// -- `check` then takes one frame per solid), `allowed` pairs of part indices never tested
/// (designed contacts, by part index, flat: `(a0, b0, a1, b1, ...)`). `close()` frees this
/// handle; so does `deinit`.
public final class Collider {
    private var handle: OpaquePointer?

    public init(_ solids: [Solid], tolerance: Double = 0.05, groups: [UInt32]? = nil, allowed: [UInt32] = []) throws {
        if let groups, groups.count != solids.count {
            throw BuildError(
                "Collider: groups must have one entry per solid (\(solids.count) solids, \(groups.count) groups)")
        }
        let handles: [OpaquePointer?] = try solids.map { try $0.h() }
        let allowedCount = UInt32(allowed.count / 2)
        let raw: OpaquePointer? = withExtendedLifetime(solids) {
            if let groups {
                return cadaclysm_blacksmith_collider_new(handles, UInt32(handles.count), tolerance, groups, allowed, allowedCount)
            }
            return cadaclysm_blacksmith_collider_new(handles, UInt32(handles.count), tolerance, nil, allowed, allowedCount)
        }
        handle = try checked(raw, "collider_new")
    }

    deinit { close() }

    /// Free the collider now. Idempotent.
    public func close() {
        if let handle { cadaclysm_blacksmith_collider_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("collider: closed") }
        return handle
    }

    /// How many groups this collider has -- the highest group index past `init`, plus one.
    public var groupCount: Int {
        get throws { Int(cadaclysm_blacksmith_collider_group_count(try h())) }
    }

    /// Counts of the last `check` call (all zero before the first one).
    public var stats: ColliderStats {
        get throws {
            var raw = CadaclysmBlacksmithColliderStats()
            if !cadaclysm_blacksmith_collider_stats(try h(), &raw) { throw failure("collider_stats") }
            return ColliderStats(raw)
        }
    }

    /// The pairs that interfere, or could not be decided, with each group placed at its
    /// matching frame in `frames` (one per group, in group order). `share`: `nil`, every
    /// pair past the box filters is decided now; `(k, n)`, only those whose index is `k`
    /// modulo `n` (the shares of one pose are disjoint and cover it -- split one `check`
    /// across `n` workers).
    public func check(_ frames: [Frame], share: (k: UInt32, n: UInt32)? = nil) throws -> [CollisionHit] {
        var flat: [Double] = []
        flat.reserveCapacity(frames.count * 12)
        for f in frames { flat.append(contentsOf: f.values) }
        let (shareK, shareN) = share ?? (0, 0)
        guard let found = cadaclysm_blacksmith_collider_check(try h(), flat, UInt32(frames.count), shareK, shareN) else {
            throw failure("collider_check")
        }
        let count = cadaclysm_blacksmith_collisions_count(found)
        if count == 0 {
            cadaclysm_blacksmith_collisions_free(found)
            return []
        }
        let collisions = Collisions(found)
        var hits: [CollisionHit] = []
        hits.reserveCapacity(Int(count))
        for i in 0..<count {
            var raw = CadaclysmBlacksmithCollisionHit()
            if !cadaclysm_blacksmith_collisions_hit(found, i, &raw) { throw failure("collisions_hit") }
            hits.append(CollisionHit(raw, collisions, i))
        }
        return hits
    }

    /// Every pair of parts that penetrates, touches or lies within `clearance` of the other, as
    /// `Clash` rows in pair order, with each group placed at its matching frame in `frames` (as
    /// for `check`). `clearance` is zero or more, in model units: a pair apart by more than the
    /// collider's tolerance but less than it is `"too_close"`. `share` as for `check`. The
    /// collider keeps each part's closest mesh (at a third of its tolerance) for its lifetime
    /// once a pair needed one. Throws for a negative or non-finite `clearance`, the wrong number
    /// of frames or a bad `share`.
    public func clash(_ frames: [Frame], clearance: Double = 0, share: (k: UInt32, n: UInt32)? = nil) throws -> [Clash] {
        var flat: [Double] = []
        flat.reserveCapacity(frames.count * 12)
        for f in frames { flat.append(contentsOf: f.values) }
        let (shareK, shareN) = share ?? (0, 0)
        guard let found = cadaclysm_blacksmith_collider_clash(try h(), flat, UInt32(frames.count), clearance, shareK, shareN) else {
            throw failure("collider_clash")
        }
        return try clashesOf(found)
    }

    /// Every pair of parts that penetrates, touches or comes within `clearance` of the other
    /// anywhere on the path through `poses` -- not only at the poses -- as `SweptClash` rows in
    /// pair order. `poses` is two or more poses, each the `frames` `clash` takes (one frame per
    /// group). Between two poses each group moves rigidly about the centre of its rest box: that
    /// point on the straight line between its two places, the rotation turning at a steady rate
    /// the shorter way round. Time runs in pose units, pose `k` at time `k`.
    ///
    /// No moment where the true gap is below `clearance` less the collider's tolerance (for
    /// clearance 0: no penetration deeper than the tolerance) falls between two steps.
    /// `resolution` (in (0, 1], a fraction of a segment) is how closely an interval's end is
    /// found; `maxSteps` the pose-wise tests one pair may take -- a pair that needs more is a
    /// `"refused"` row. `share` as for `check`, over the pairs whose swept boxes meet. The pose
    /// caches `check` and `clash` keep are neither read nor filled. Throws for fewer than two
    /// poses, the wrong number of frames in a pose, a bad frame, `clearance`, `resolution` or
    /// `share`, or `maxSteps` 0.
    public func sweptClash(_ poses: [[Frame]], clearance: Double = 0, resolution: Double = 1e-3, maxSteps: UInt32 = 100000,
                           share: (k: UInt32, n: UInt32)? = nil) throws -> [SweptClash] {
        let frameCount = poses.first?.count ?? 0
        if poses.contains(where: { $0.count != frameCount }) {
            // C reads every pose at one frame count: say the first pose that is off, in the
            // kernel's words
            let groups = try groupCount
            let n = poses.first(where: { $0.count != groups })?.count ?? frameCount
            throw BuildError("collider_swept_clash: \(n) frames for \(groups) groups")
        }
        let flat = poseFrames(poses)
        let (shareK, shareN) = share ?? (0, 0)
        guard let found = cadaclysm_blacksmith_collider_swept_clash(try h(), flat, UInt32(poses.count), UInt32(frameCount),
                                                                    clearance, resolution, maxSteps, shareK, shareN) else {
            throw failure("collider_swept_clash")
        }
        return try sweptClashesOf(found)
    }
}

// MARK: - RTree

/// One entry `RTree.within` or `RTree.nearest` found: its `id` and the `distance` from the point
/// to its box (0 inside it). Python's `(id, distance)`.
public struct RTreeHit: Equatable, CustomStringConvertible {
    public let id: UInt32
    public let distance: Double

    public init(id: UInt32, distance: Double) {
        self.id = id
        self.distance = distance
    }

    public var description: String { "RTreeHit(id=\(id), distance=\(distance))" }
}

/// Two entries whose boxes meet: `a` of the tree asked and `b` of the other (`RTree.overlaps`),
/// or `a <= b` (`RTree.selfOverlaps`). Python's `(a, b)`.
public struct RTreePair: Hashable, CustomStringConvertible {
    public let a: UInt32
    public let b: UInt32

    public init(a: UInt32, b: UInt32) {
        self.a = a
        self.b = b
    }

    public var description: String { "RTreePair(a=\(a), b=\(b))" }
}

/// A box as the C ABI's 6 doubles, `[minx, miny, minz, maxx, maxy, maxz]`.
private func rtreeWords(_ box: Box) -> [Double] {
    [box.lo.x, box.lo.y, box.lo.z, box.hi.x, box.hi.y, box.hi.z]
}

/// Reads and frees a query's hit list; a failing call or read throws the library's own text.
private func rtreeHits(_ list: OpaquePointer?, _ what: String) throws -> [RTreeHit] {
    guard let list else { throw failure(what) }
    defer { cadaclysm_blacksmith_rtree_hits_free(list) }
    let count = cadaclysm_blacksmith_rtree_hits_count(list)
    var out: [RTreeHit] = []
    out.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithRTreeHit()
        if !cadaclysm_blacksmith_rtree_hits_at(list, i, &raw) { throw failure("rtree_hits_at") }
        out.append(RTreeHit(id: raw.id, distance: raw.distance))
    }
    return out
}

/// Reads and frees a query's pair list, as `rtreeHits` reads hits.
private func rtreePairs(_ list: OpaquePointer?, _ what: String) throws -> [RTreePair] {
    guard let list else { throw failure(what) }
    defer { cadaclysm_blacksmith_rtree_pairs_free(list) }
    let count = cadaclysm_blacksmith_rtree_pairs_count(list)
    var out: [RTreePair] = []
    out.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithRTreePair()
        if !cadaclysm_blacksmith_rtree_pairs_at(list, i, &raw) { throw failure("rtree_pairs_at") }
        out.append(RTreePair(a: raw.a, b: raw.b))
    }
    return out
}

/// A count at the C boundary, refused by `what` past what a `uint32_t` holds.
private func rtreeCount(_ n: Int, _ what: String, _ items: String) throws -> UInt32 {
    guard let n32 = UInt32(exactly: n) else { throw BuildError("\(what): \(n) \(items) is more than 4294967295") }
    return n32
}

/// A spatial index over boxes with ids (an R*-tree): `search` a box for the entries it meets,
/// `within` / `nearest` a point for the closest, `overlaps` / `selfOverlaps` for every pair of
/// boxes that meet. Ids are the caller's own and may repeat; an entry is an id and its `Box`, and
/// the same `(id, box)` twice is two entries. Touching boxes meet. A point stands for a zero box
/// (`insert` and `remove` take either). Answers come in a fixed order: search ids ascending,
/// within / nearest by distance then id, pairs ascending. The tree changes in place; calls on one
/// tree must not overlap from two threads. `close()` frees it; so does `deinit`. Python's `RTree`.
public final class RTree: CustomStringConvertible {
    private var handle: OpaquePointer?

    /// An empty tree.
    public init() throws {
        handle = try checked(cadaclysm_blacksmith_rtree_new(), "rtree_new")
    }

    private init(adopting raw: OpaquePointer?, _ what: String) throws {
        handle = try checked(raw, what)
    }

    /// A tree over `(id, box)` entries at once, packed (sort-tile-recursive): fuller and faster
    /// to query than the same entries inserted one by one. The first entry whose box is not a box
    /// (a NaN, an infinity, `lo` above `hi`) is refused, by index.
    public static func fromBoxes(_ entries: [(UInt32, Box)]) throws -> RTree {
        let n = try rtreeCount(entries.count, "rtree_from_boxes", "entries")
        if entries.isEmpty {
            return try RTree(adopting: cadaclysm_blacksmith_rtree_from_boxes(nil, nil, 0), "rtree_from_boxes")
        }
        let ids = entries.map { $0.0 }
        let boxes = entries.flatMap { rtreeWords($0.1) }
        return try RTree(adopting: cadaclysm_blacksmith_rtree_from_boxes(ids, boxes, n), "rtree_from_boxes")
    }

    /// A tree over `points`, each a zero box whose id is its index. The first point with a NaN or
    /// infinite coordinate is refused, by index.
    public static func fromPoints(_ points: [SIMD3<Double>]) throws -> RTree {
        let n = try rtreeCount(points.count, "rtree_from_points", "points")
        if points.isEmpty {
            return try RTree(adopting: cadaclysm_blacksmith_rtree_from_points(nil, 0), "rtree_from_points")
        }
        let xyz = points.flatMap { [$0.x, $0.y, $0.z] }
        return try RTree(adopting: cadaclysm_blacksmith_rtree_from_points(xyz, n), "rtree_from_points")
    }

    /// A tree over a mesh's triangles -- RhinoCommon's `RTree.CreateMeshFaceTree`: one entry per
    /// triangle of `triangles` (three indices into `positions`), its id the triangle's index, its
    /// box its three corners' box. The first corner past the points or at a point with a NaN or
    /// infinite coordinate is refused, by triangle and point; points no triangle uses are not
    /// checked.
    public static func fromTriangles(_ positions: [SIMD3<Double>],
                                     _ triangles: [(UInt32, UInt32, UInt32)]) throws -> RTree {
        let np = try rtreeCount(positions.count, "rtree_from_triangles", "points")
        let nt = try rtreeCount(triangles.count, "rtree_from_triangles", "triangles")
        let xyz = positions.flatMap { [$0.x, $0.y, $0.z] }
        let indices = triangles.flatMap { [$0.0, $0.1, $0.2] }
        let raw = xyz.withUnsafeBufferPointer { at in
            indices.withUnsafeBufferPointer { idx in
                cadaclysm_blacksmith_rtree_from_triangles(np == 0 ? nil : at.baseAddress, np,
                                                          nt == 0 ? nil : idx.baseAddress, nt)
            }
        }
        return try RTree(adopting: raw, "rtree_from_triangles")
    }

    /// The tree `Solid.faceTree` builds, adopted.
    static func adopting(_ raw: OpaquePointer?, _ what: String) throws -> RTree {
        try RTree(adopting: raw, what)
    }

    deinit { close() }

    /// Free the tree now. Idempotent.
    public func close() {
        if let handle { cadaclysm_blacksmith_rtree_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("rtree: closed") }
        return handle
    }

    /// How many entries the tree holds.
    public var count: Int {
        get throws { Int(cadaclysm_blacksmith_rtree_count(try h())) }
    }

    /// The union of every entry's box, or nil for an empty tree.
    public var bounds: Box? {
        get throws {
            let tree = try h()
            if cadaclysm_blacksmith_rtree_count(tree) == 0 { return nil }
            var out = [Double](repeating: 0, count: 6)
            if !cadaclysm_blacksmith_rtree_bounds(tree, &out) { throw failure("rtree_bounds") }
            return Box(SIMD3(out[0], out[1], out[2]), SIMD3(out[3], out[4], out[5]))
        }
    }

    /// Add the entry `(id, box)`. A box that is not a box is refused and leaves the tree as it was.
    public func insert(_ id: UInt32, _ box: Box) throws {
        if !cadaclysm_blacksmith_rtree_insert(try h(), id, rtreeWords(box)) { throw failure("rtree_insert") }
    }

    /// Add the entry `(id, point)`, the point a zero box. A point not finite is refused and leaves
    /// the tree as it was.
    public func insert(_ id: UInt32, _ point: SIMD3<Double>) throws {
        if !cadaclysm_blacksmith_rtree_insert_point(try h(), id, [point.x, point.y, point.z]) {
            throw failure("rtree_insert_point")
        }
    }

    /// Take out one entry equal to `(id, box)` -- the box it was inserted with, compared
    /// coordinate by coordinate -- and say whether there was one: `false`, not an error, when
    /// there is none. With duplicates, one goes per call. A box that is not a box is refused.
    public func remove(_ id: UInt32, _ box: Box) throws -> Bool {
        try removeWords(id, rtreeWords(box))
    }

    /// `remove` for an entry inserted as a point (its zero box).
    public func remove(_ id: UInt32, _ point: SIMD3<Double>) throws -> Bool {
        try removeWords(id, [point.x, point.y, point.z, point.x, point.y, point.z])
    }

    private func removeWords(_ id: UInt32, _ words: [Double]) throws -> Bool {
        if cadaclysm_blacksmith_rtree_remove(try h(), id, words) { return true }
        if !lastError().isEmpty { throw failure("rtree_remove") }
        return false
    }

    /// The ids of every entry whose box meets `box` (touching counts), ascending, one per entry.
    /// A box that is not a box is refused.
    public func search(_ box: Box) throws -> [UInt32] {
        try rtreeHits(cadaclysm_blacksmith_rtree_search(try h(), rtreeWords(box)), "rtree_search").map(\.id)
    }

    /// Every entry whose box is within `r` of `point` (Euclidean, 0 inside the box; exactly `r`
    /// counts), by distance then id. A point not finite or an `r` negative or NaN is refused.
    public func within(_ point: SIMD3<Double>, _ r: Double) throws -> [RTreeHit] {
        try rtreeHits(cadaclysm_blacksmith_rtree_within(try h(), [point.x, point.y, point.z], r), "rtree_within")
    }

    /// The `k` entries whose boxes are nearest `point`, by distance then id (the smaller ids win a
    /// tie); all of them when `k` is over the count. A point not finite or a `k` above 1,000,000
    /// is refused.
    public func nearest(_ point: SIMD3<Double>, _ k: UInt32) throws -> [RTreeHit] {
        try rtreeHits(cadaclysm_blacksmith_rtree_nearest(try h(), [point.x, point.y, point.z], k), "rtree_nearest")
    }

    /// Every entry whose box the ray `origin + t * direction`, `0 <= t <= maxT`, meets, as hits
    /// whose `distance` is the `t` where the ray enters the box (0 when `origin` is inside it), by
    /// `t` then id. Touching counts. `t` is in units of `direction`'s length, which is not
    /// normalised; `maxT` defaults to infinity. An origin or direction not finite, a zero
    /// direction, or a `maxT` negative or NaN is refused.
    public func ray(_ origin: SIMD3<Double>, _ direction: SIMD3<Double>,
                    maxT: Double = .infinity) throws -> [RTreeHit] {
        try rtreeHits(cadaclysm_blacksmith_rtree_ray(try h(), [origin.x, origin.y, origin.z],
                                                     [direction.x, direction.y, direction.z], maxT), "rtree_ray")
    }

    /// Every pair `(a, b)`, `a` an entry of this tree and `b` one of `other` (which may be this
    /// tree), whose boxes are at most `slack` apart on every axis (0: touching), ascending. A
    /// `slack` negative or NaN is refused.
    public func overlaps(_ other: RTree, slack: Double = 0) throws -> [RTreePair] {
        let (a, b) = (try h(), try other.h())
        return try withExtendedLifetime(other) {
            try rtreePairs(cadaclysm_blacksmith_rtree_overlaps(a, b, slack), "rtree_overlaps")
        }
    }

    /// Every unordered pair of distinct entries at most `slack` apart, once each as `(smaller id,
    /// larger id)`, ascending -- an id paired with itself only where two entries share it. A
    /// `slack` negative or NaN is refused.
    public func selfOverlaps(slack: Double = 0) throws -> [RTreePair] {
        try rtreePairs(cadaclysm_blacksmith_rtree_self_overlaps(try h(), slack), "rtree_self_overlaps")
    }

    public var description: String {
        guard let handle else { return "RTree(closed)" }
        return "RTree(\(cadaclysm_blacksmith_rtree_count(handle)) entries)"
    }
}

/// `x` as Rust's `{}` prints an f64 -- the kernel's refusals quote numbers that way.
func rustNumber(_ x: Double) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x > 0 ? "inf" : "-inf" }
    // `description` is the shortest round-trip digits, as Rust's are; Rust lays them out without
    // an exponent.
    let sign = x.sign == .minus ? "-" : ""
    let body = abs(x).description
    let parts = body.split(separator: "e", maxSplits: 1, omittingEmptySubsequences: false)
    var shift = parts.count > 1 ? Int(parts[1])! : 0
    let mantissa = parts[0].split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
    let fraction = mantissa.count > 1 ? String(mantissa[1]) : ""
    var digits = String((String(mantissa[0]) + fraction).drop(while: { $0 == "0" }))
    shift -= fraction.count
    while digits.last == "0" {
        digits.removeLast()
        shift += 1
    }
    if digits.isEmpty { return sign + "0" }
    if shift >= 0 { return sign + digits + String(repeating: "0", count: shift) }
    let point = digits.count + shift
    if point > 0 { return sign + String(digits.prefix(point)) + "." + String(digits.dropFirst(point)) }
    return sign + "0." + String(repeating: "0", count: -point) + digits
}

/// Refuses, as the kernel's `closest_points` / `k_neighbors` do, the first hay point and then
/// the first needle that is not finite, by index.
private func finitePoints(_ call: String, _ hay: [SIMD3<Double>], _ needles: [SIMD3<Double>]) throws {
    for (name, points) in [("hay", hay), ("needle", needles)] {
        if let i = points.firstIndex(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }) {
            throw BuildError("\(call): \(name) point \(i) is not finite")
        }
    }
}

/// For each of `needles`, the indices of the `hay` points within `limit` of it, by distance then
/// index -- one `RTree` over the hay answers every needle. A `limit` negative or NaN, then the
/// first hay point and the first needle not finite, by index, are refused.
public func closestPoints(_ hay: [SIMD3<Double>], _ needles: [SIMD3<Double>], _ limit: Double) throws -> [[Int]] {
    guard limit >= 0 else { throw BuildError("closest_points: limit \(rustNumber(limit)) is not a distance") }
    try finitePoints("closest_points", hay, needles)
    let tree = try RTree.fromPoints(hay)
    defer { tree.close() }
    return try needles.map { try tree.within($0, limit).map { Int($0.id) } }
}

/// For each of `needles`, the indices of the `k` nearest `hay` points, by distance then index
/// (all of them when `k` is over the hay count). The first hay point and the first needle not
/// finite, by index, then a `k` above 1,000,000, are refused.
public func kNeighbors(_ hay: [SIMD3<Double>], _ needles: [SIMD3<Double>], _ k: UInt32) throws -> [[Int]] {
    try finitePoints("k_neighbors", hay, needles)
    guard k <= 1_000_000 else { throw BuildError("k_neighbors: k \(k) is not at most 1000000") }
    let tree = try RTree.fromPoints(hay)
    defer { tree.close() }
    return try needles.map { try tree.nearest($0, k).map { Int($0.id) } }
}

/// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
/// `others` -- that penetrates, touches or lies within `clearance` of the other, as `Clash` rows,
/// the solids as they stand. `tolerance` is the meshing tolerance, absolute (default 0.05).
/// `allowed` pairs of part indices never tested (designed contacts), flat as `Collider` takes
/// them: `(a0, b0, a1, b1, ...)`; with `others` a pair is (index in `parts`, index in `others`).
/// In a row `a` indexes `parts` and `b` indexes `others` (or `parts` again). Throws for an empty
/// `others`, an `allowed` of odd length, a negative or non-finite `clearance`, a `tolerance` not
/// positive and finite, an `allowed` index out of range or a part that is not a closed solid.
public func clash(_ parts: [Solid], _ others: [Solid]? = nil, clearance: Double = 0, tolerance: Double = 0.05,
                  allowed: [UInt32] = []) throws -> [Clash] {
    let first: [OpaquePointer?] = try parts.map { try $0.h() }
    let second: [OpaquePointer?]? = try others.map { try $0.map { try $0.h() } }
    if let second, second.isEmpty { throw BuildError("clash: an empty set") }
    if allowed.count % 2 != 0 { throw BuildError("clash: allowed is \(allowed.count) numbers, not pairs") }
    let found: OpaquePointer? = withExtendedLifetime((parts, others)) {
        if let second {
            return cadaclysm_blacksmith_clash(first, UInt32(first.count), second, UInt32(second.count),
                                              tolerance, clearance, allowed, UInt32(allowed.count / 2))
        }
        return cadaclysm_blacksmith_clash(first, UInt32(first.count), nil, 0,
                                          tolerance, clearance, allowed, UInt32(allowed.count / 2))
    }
    guard let found else { throw failure("clash") }
    return try clashesOf(found)
}

/// Every pair of `parts` -- or, with `others`, every part of `parts` against every part of
/// `others` -- that penetrates, touches or comes within `clearance` of the other anywhere on a
/// path, as `SweptClash` rows. Each part is its own group: pose `k` of `poses` is one frame per
/// part of `parts`, and pose `k` of `otherPoses` one per part of `others` (the two go together,
/// and have as many poses). The motion between poses, the guarantee, `resolution` and
/// `maxSteps` are `Collider.sweptClash`'s. `tolerance` is the meshing tolerance, absolute
/// (default 0.05). `allowed` pairs of part indices never tested, flat as `clash` takes them:
/// `(a0, b0, a1, b1, ...)`; with `others` a pair is (index in `parts`, index in `others`). In a
/// row `a` indexes `parts` and `b` indexes `others` (or `parts` again). Throws as
/// `Collider.sweptClash` does, and for `others` without `otherPoses` or the other way round,
/// pose counts that differ between the sets, a pose with the wrong number of frames, an empty
/// `others`, an `allowed` of odd length, an `allowed` index out of range or a part that is not
/// a closed solid.
public func sweptClash(_ parts: [Solid], _ poses: [[Frame]], others: [Solid]? = nil, otherPoses: [[Frame]]? = nil,
                       clearance: Double = 0, tolerance: Double = 0.05, resolution: Double = 1e-3,
                       maxSteps: UInt32 = 100000, allowed: [UInt32] = []) throws -> [SweptClash] {
    if (others == nil) != (otherPoses == nil) { throw BuildError("swept_clash: others and other_poses go together") }
    let first: [OpaquePointer?] = try parts.map { try $0.h() }
    let second: [OpaquePointer?]? = try others.map { try $0.map { try $0.h() } }
    // C reads each set's poses at its part count: the kernel's own checks, in its order
    if let otherPoses, otherPoses.count != poses.count {
        throw BuildError("swept_clash: \(poses.count) poses for set a, \(otherPoses.count) for set b")
    }
    for (name, frames, n) in [("a", poses, first.count), ("b", otherPoses ?? [], second?.count ?? 0)] {
        for (k, pose) in frames.enumerated() where pose.count != n {
            throw BuildError("swept_clash: pose \(k) of set \(name) has \(pose.count) frames for \(n) parts")
        }
    }
    if let second, second.isEmpty { throw BuildError("swept_clash: an empty set") }
    if allowed.count % 2 != 0 { throw BuildError("swept_clash: allowed is \(allowed.count) numbers, not pairs") }
    let posesA = poseFrames(poses)
    let found: OpaquePointer? = withExtendedLifetime((parts, others)) {
        if let second, let otherPoses {
            return cadaclysm_blacksmith_swept_clash(first, UInt32(first.count), posesA, second, UInt32(second.count),
                                                    poseFrames(otherPoses), UInt32(poses.count), tolerance, clearance,
                                                    resolution, maxSteps, allowed, UInt32(allowed.count / 2))
        }
        return cadaclysm_blacksmith_swept_clash(first, UInt32(first.count), posesA, nil, 0, nil, UInt32(poses.count),
                                                tolerance, clearance, resolution, maxSteps, allowed,
                                                UInt32(allowed.count / 2))
    }
    guard let found else { throw failure("swept_clash") }
    return try sweptClashesOf(found)
}

// MARK: - Wall thickness

/// One wall-thickness reading on a solid (`ThicknessGauge.thickness`, `.thicknessAt`, the free
/// `thickness`). `point` lies on face `face` of body `body` (the body's index in the gauge): at
/// vertex `vertex` of that body's measuring mesh (`ThicknessGauge.mesh`), or `vertex` nil for a
/// reading at a point. `thickness` is the nearest-opposing-wall rule (the nearest triangle that
/// faces against one of the vertex's own faces, with the vertex behind it) on the measuring
/// mesh, to `opposite` on face `oppositeFace` of body `oppositeBody`; `knife` marks a knife edge
/// (thickness 0, `opposite` == `point`). `exactOpposite` is `opposite` moved onto its exact face
/// where its foot lies within the tolerance and inside the face's trims, `exactThickness` the
/// distance to it. `sphere` is the diameter of the largest ball tangent at `point` that holds
/// none of the surfaces, nil where none under the maximum does (0 on a knife edge). Python's
/// `Thickness`.
public struct Thickness: CustomStringConvertible {
    public let body: UInt32
    public let vertex: UInt32?
    public let face: UInt32
    public let point: SIMD3<Double>
    public let thickness: Double
    public let opposite: SIMD3<Double>
    public let oppositeBody: UInt32
    public let oppositeFace: UInt32
    public let knife: Bool
    public let exactThickness: Double
    public let exactOpposite: SIMD3<Double>
    public let sphere: Double?

    init(_ raw: CadaclysmBlacksmithThickness) {
        body = raw.body
        vertex = raw.vertex == none ? nil : raw.vertex
        face = raw.face
        point = SIMD3(raw.point.0, raw.point.1, raw.point.2)
        thickness = raw.thickness
        opposite = SIMD3(raw.opposite.0, raw.opposite.1, raw.opposite.2)
        oppositeBody = raw.opposite_body
        oppositeFace = raw.opposite_face
        knife = raw.knife
        exactThickness = raw.exact_thickness
        exactOpposite = SIMD3(raw.exact_opposite.0, raw.exact_opposite.1, raw.exact_opposite.2)
        sphere = raw.sphere.isNaN ? nil : raw.sphere
    }

    public var description: String {
        "Thickness(body=\(body), vertex=\(vertex.map { String($0) } ?? "nil"), face=\(face), "
            + "thickness=\(thickness), oppositeBody=\(oppositeBody), knife=\(knife))"
    }
}

/// A face's thickness, found (`ThicknessGauge.thicknessAtFace`, `Solid.thicknessAtFace`; where
/// nothing is found those answer nil): `thickness` the median of the face's vertex readings (or
/// the reading at `at`), `min` and `max` their extremes, `uniform` whether `max - min` is within
/// the gauge's tolerance. Python's `FaceThickness`.
public struct FaceThickness: CustomStringConvertible {
    public let thickness: Double
    public let min: Double
    public let max: Double
    public let uniform: Bool

    init(_ raw: CadaclysmBlacksmithFaceThickness) {
        thickness = raw.thickness
        min = raw.min
        max = raw.max
        uniform = raw.uniform
    }

    public var description: String {
        "FaceThickness(thickness=\(thickness), min=\(min), max=\(max), uniform=\(uniform))"
    }
}

/// A body's measuring mesh (`ThicknessGauge.mesh`), copied out of the gauge: `positions` and
/// `normals` (unit, outward) one point per vertex -- a reading's `vertex` indexes them; no vertex
/// is shared between two faces -- `triangles` three vertex indices each, and `faces` the B-rep
/// face of each triangle. Python's `ThicknessMesh`.
public struct ThicknessMesh: CustomStringConvertible {
    public let positions: [SIMD3<Double>]
    public let normals: [SIMD3<Double>]
    public let triangles: [SIMD3<UInt32>]
    public let faces: [UInt32]

    public var description: String { "ThicknessMesh(vertices=\(positions.count), triangles=\(triangles.count))" }
}

/// One reading on a plain mesh (`meshThickness`): vertex `vertex` of mesh `mesh`, at `point`,
/// reads `thickness` to `opposite` on triangle `oppositeTriangle` of mesh `oppositeMesh` (both
/// indices within that mesh). `knife`: a knife edge, thickness 0 and `opposite` == `point`.
/// Python's `MeshThickness`.
public struct MeshThickness: CustomStringConvertible {
    public let mesh: UInt32
    public let vertex: UInt32
    public let thickness: Double
    public let point: SIMD3<Double>
    public let opposite: SIMD3<Double>
    public let oppositeMesh: UInt32
    public let oppositeTriangle: UInt32
    public let knife: Bool

    init(_ raw: CadaclysmBlacksmithMeshThickness) {
        mesh = raw.mesh
        vertex = raw.vertex
        thickness = raw.thickness
        point = SIMD3(raw.point.0, raw.point.1, raw.point.2)
        opposite = SIMD3(raw.opposite.0, raw.opposite.1, raw.opposite.2)
        oppositeMesh = raw.opposite_mesh
        oppositeTriangle = raw.opposite_triangle
        knife = raw.knife
    }

    public var description: String {
        "MeshThickness(mesh=\(mesh), vertex=\(vertex), thickness=\(thickness), "
            + "oppositeMesh=\(oppositeMesh), knife=\(knife))"
    }
}

/// A thicknesses handle (nil: throws `what`'s refusal) read out into rows and freed on every path.
func thicknessesOf(_ found: OpaquePointer?, _ what: String) throws -> [Thickness] {
    guard let found else { throw failure(what) }
    defer { cadaclysm_blacksmith_thicknesses_free(found) }
    let count = cadaclysm_blacksmith_thicknesses_count(found)
    var rows: [Thickness] = []
    rows.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithThickness()
        if !cadaclysm_blacksmith_thicknesses_at(found, i, &raw) { throw failure("thicknesses_at") }
        rows.append(Thickness(raw))
    }
    return rows
}

/// Wall thickness (the nearest-opposing-wall rule: each vertex reads to the nearest triangle that
/// faces against one of its own faces, with the vertex behind it) over `solids`, measured against
/// each other: each solid meshed once at `tolerance` -- absolute, in model units (default 0.01)
/// -- then asked as often as needed. A reading's `body` is the solid's index in `solids`. The
/// gauge keeps its own reference to the bodies, so it answers on after the `Solid`s are closed.
/// `close()` frees it; so does `deinit`. Throws for a `tolerance` not positive and finite.
/// Python's `ThicknessGauge`.
public final class ThicknessGauge: CustomStringConvertible {
    private var handle: OpaquePointer?

    public init(_ solids: [Solid], tolerance: Double = 0.01) throws {
        let handles: [OpaquePointer?] = try solids.map { try $0.h() }
        // The library wants a non-null array even for no bodies.
        let parts: [OpaquePointer?] = handles.isEmpty ? [nil] : handles
        let raw: OpaquePointer? = withExtendedLifetime(solids) {
            cadaclysm_blacksmith_thickness_gauge_new(parts, UInt32(handles.count), tolerance)
        }
        handle = try checked(raw, "thickness_gauge_new")
    }

    deinit { close() }

    /// Free the gauge now. Idempotent.
    public func close() {
        if let handle { cadaclysm_blacksmith_thickness_gauge_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("thickness_gauge: closed") }
        return handle
    }

    /// How many bodies the gauge measures.
    public var count: Int {
        get throws { Int(cadaclysm_blacksmith_thickness_gauge_body_count(try h())) }
    }

    /// The tolerance the gauge meshed its bodies at.
    public var tolerance: Double {
        get throws {
            let value = cadaclysm_blacksmith_thickness_gauge_tolerance(try h())
            if value.isNaN { throw failure("thickness_gauge_tolerance") }
            return value
        }
    }

    public var description: String {
        guard handle != nil, let n = try? count, let t = try? tolerance else { return "ThicknessGauge(closed)" }
        return "ThicknessGauge(bodies=\(n), tolerance=\(t))"
    }

    /// One reading per measuring-mesh vertex that has one within `maximum` (positive and finite),
    /// by body then vertex; vertices whose interior angle is under `sharpAngle` radians (zero or
    /// more) are knife edges. Throws for a bad limit.
    public func thickness(maximum: Double, sharpAngle: Double = 0) throws -> [Thickness] {
        try thicknessesOf(cadaclysm_blacksmith_thickness_gauge_measure(try h(), maximum, sharpAngle),
                          "thickness_gauge_measure")
    }

    /// The reading at `point`'s foot on face `face` of body `body` (its `vertex` nil), or nil
    /// where the foot lies off the face or the wall is thicker than `maximum`. Throws for a body
    /// or face past the end, a point not finite or a bad limit.
    public func thicknessAt(body: Int, face: Int, point: SIMD3<Double>, maximum: Double,
                            sharpAngle: Double = 0) throws -> Thickness? {
        let b = try index32(body, "thickness_gauge_at"), f = try index32(face, "thickness_gauge_at")
        let xyz = [point.x, point.y, point.z]
        let rows = try thicknessesOf(
            cadaclysm_blacksmith_thickness_gauge_at(try h(), b, f, xyz, maximum, sharpAngle), "thickness_gauge_at")
        return rows.first
    }

    /// One thickness for face `face` of body `body`: measured at `at`'s foot on the face or, with
    /// `at` nil, over the face's vertices; the other bodies are measured with it. nil where
    /// nothing is found (nothing reads under `maximum`, or `at`'s foot lies off the face).
    /// `maximum` has no default. Throws for a body or face past the end, an `at` not finite or a
    /// bad maximum.
    public func thicknessAtFace(body: Int, face: Int, at: SIMD3<Double>? = nil,
                                maximum: Double) throws -> FaceThickness? {
        let b = try index32(body, "thickness_gauge_face"), f = try index32(face, "thickness_gauge_face")
        var raw = CadaclysmBlacksmithFaceThickness()
        let gauge = try h()
        let ok: Bool
        if let at {
            ok = cadaclysm_blacksmith_thickness_gauge_face(gauge, b, f, [at.x, at.y, at.z], maximum, &raw)
        } else {
            ok = cadaclysm_blacksmith_thickness_gauge_face(gauge, b, f, nil, maximum, &raw)
        }
        if !ok { throw failure("thickness_gauge_face") }
        return raw.found ? FaceThickness(raw) : nil
    }

    /// Body `body`'s measuring mesh, copied out (it outlives the gauge). Throws for a body past
    /// the end.
    public func mesh(body: Int) throws -> ThicknessMesh {
        let b = try index32(body, "thickness_gauge_mesh")
        var raw = CadaclysmBlacksmithThicknessMesh()
        if !cadaclysm_blacksmith_thickness_gauge_mesh(try h(), b, &raw) { throw failure("thickness_gauge_mesh") }
        let t = Int(raw.triangle_count)
        var triangles: [SIMD3<UInt32>] = []
        var faces: [UInt32] = []
        if t > 0, let indices = raw.indices, let faceIds = raw.faces {
            let flat = UnsafeBufferPointer(start: indices, count: 3 * t)
            triangles = stride(from: 0, to: flat.count, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
            faces = Array(UnsafeBufferPointer(start: faceIds, count: t))
        }
        return ThicknessMesh(positions: pointsAt(raw.positions, raw.vertex_count),
                             normals: pointsAt(raw.normals, raw.vertex_count),
                             triangles: triangles, faces: faces)
    }
}

/// `ThicknessGauge(solids, tolerance:).thickness(maximum:sharpAngle:)` on a gauge used once and
/// freed: every reading within `maximum` on the solids, measured against each other.
public func thickness(_ solids: [Solid], maximum: Double, sharpAngle: Double = 0,
                      tolerance: Double = 0.01) throws -> [Thickness] {
    let gauge = try ThicknessGauge(solids, tolerance: tolerance)
    defer { gauge.close() }
    return try gauge.thickness(maximum: maximum, sharpAngle: sharpAngle)
}

/// The nearest-opposing-wall rule on plain meshes measured against each other: each mesh a
/// `(positions, triangles)` pair -- points and triples of indices into its own points. One
/// reading per vertex that has one within `maximum` (positive and finite), by mesh then vertex;
/// `sharpAngle` as for `ThicknessGauge.thickness`. Throws for a triangle past its mesh, a
/// position not finite or a bad limit. Python's `mesh_thickness`.
public func meshThickness(_ meshes: [(positions: [SIMD3<Double>], triangles: [SIMD3<UInt32>])],
                          maximum: Double, sharpAngle: Double = 0) throws -> [MeshThickness] {
    var positions: [Double] = []
    var indices: [UInt32] = []
    var vertexCounts: [UInt32] = []
    var triangleCounts: [UInt32] = []
    for (m, mesh) in meshes.enumerated() {
        for p in mesh.positions { positions.append(contentsOf: [p.x, p.y, p.z]) }
        for t in mesh.triangles { indices.append(contentsOf: [t.x, t.y, t.z]) }
        vertexCounts.append(try rtreeCount(mesh.positions.count, "mesh_thickness", "mesh \(m) positions"))
        triangleCounts.append(try rtreeCount(mesh.triangles.count, "mesh_thickness", "mesh \(m) triangles"))
    }
    let meshCount = try rtreeCount(meshes.count, "mesh_thickness", "meshes")
    guard let found = cadaclysm_blacksmith_mesh_thickness(positions, vertexCounts, indices, triangleCounts,
                                                          meshCount, maximum, sharpAngle) else {
        throw failure("mesh_thickness")
    }
    defer { cadaclysm_blacksmith_mesh_thicknesses_free(found) }
    let count = cadaclysm_blacksmith_mesh_thicknesses_count(found)
    var rows: [MeshThickness] = []
    rows.reserveCapacity(Int(count))
    for i in 0..<count {
        var raw = CadaclysmBlacksmithMeshThickness()
        if !cadaclysm_blacksmith_mesh_thicknesses_at(found, i, &raw) { throw failure("mesh_thicknesses_at") }
        rows.append(MeshThickness(raw))
    }
    return rows
}

extension Solid {
    /// One thickness for face `face` of this solid alone, on a `ThicknessGauge` meshed at
    /// `tolerance` (default 0.01), used once and freed -- build the gauge yourself to ask more
    /// than once. nil where nothing is found; see `ThicknessGauge.thicknessAtFace`.
    public func thicknessAtFace(_ face: Int, at: SIMD3<Double>? = nil, maximum: Double,
                                tolerance: Double = 0.01) throws -> FaceThickness? {
        let gauge = try ThicknessGauge([self], tolerance: tolerance)
        defer { gauge.close() }
        return try gauge.thicknessAtFace(body: 0, face: face, at: at, maximum: maximum)
    }
}

// MARK: - Interpolator

/// How an `Interpolator` reads between samples, valued as the C constants
/// (`CADACLYSM_BLACKSMITH_INTERPOLATE_*`). Python's mode names.
public enum InterpolatorMode: UInt32, CaseIterable {
    /// The sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
    case nearest = 0
    /// Straight between the two samples either side of `t`.
    case linear = 1
    /// Between the two samples either side of `t` on a cosine ease, flat at every sample.
    case cosine = 2
    /// Bourke's cubic over the four samples about `t`, through every sample.
    case cubic = 3
    /// The Catmull-Rom spline over the four samples about `t`: through every sample, C1.
    case catmullRom = 4
}

/// A list of samples read at a fractional index, as Rhino's `Interpolator`: `t = 2` is sample 2,
/// `t = 2.5` halfway between samples 2 and 3. Animation keys, a value along a pattern, a smoothed
/// profile of measurements.
///
/// Samples are numbers (`init(_:cyclic:)`, dimension 1) or equal-length rows (`init(rows:cyclic:)`
/// -- 2D, 3D or any dimension), each component read on its own; every answer is a `[Double]` of
/// `dimension` numbers. An open list clamps `t` to `[0, count - 1]` and stops on its end samples;
/// a `cyclic` one wraps `t` with period `count`. An interpolator never changes after it is made.
/// `close()` frees it; so does `deinit`. Python's `Interpolator`.
public final class Interpolator: CustomStringConvertible {
    private var handle: OpaquePointer?
    private let width: Int

    /// An interpolator over numbers: dimension 1. No samples, or one that is NaN or infinite, is
    /// refused (by index).
    public convenience init(_ samples: [Double], cyclic: Bool = false) throws {
        try self.init(flat: samples, count: samples.count, dimension: 1, cyclic: cyclic)
    }

    /// An interpolator over rows of equal length, the dimension. Rows of unequal length are
    /// refused before the call; no rows, a row of no numbers, or a number that is NaN or infinite
    /// (by index) are refused by the library.
    public convenience init(rows: [[Double]], cyclic: Bool = false) throws {
        let dimension = rows.first?.count ?? 1
        if rows.contains(where: { $0.count != dimension }) {
            let lengths = Set(rows.map(\.count)).sorted().map(String.init).joined(separator: ", ")
            throw BuildError("interpolator: samples differ in length ([\(lengths)])")
        }
        try self.init(flat: rows.flatMap { $0 }, count: rows.count, dimension: dimension, cyclic: cyclic)
    }

    private init(flat: [Double], count: Int, dimension: Int, cyclic: Bool) throws {
        let n = try rtreeCount(count, "interpolator_new", "samples")
        let d = try rtreeCount(dimension, "interpolator_new", "numbers a sample")
        width = dimension
        handle = try checked(cadaclysm_blacksmith_interpolator_new(flat, n, d, cyclic), "interpolator_new")
    }

    deinit { close() }

    /// Free the interpolator now. Idempotent; every call on it throws after.
    public func close() {
        if let handle { cadaclysm_blacksmith_interpolator_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("interpolator: closed") }
        return handle
    }

    /// How many samples.
    public var count: Int {
        get throws { Int(cadaclysm_blacksmith_interpolator_count(try h())) }
    }

    /// How many numbers a sample holds, and so every answer.
    public var dimension: Int {
        get throws { Int(cadaclysm_blacksmith_interpolator_dimension(try h())) }
    }

    /// Whether `t` wraps round the list (else it is clamped to the ends).
    public var cyclic: Bool {
        get throws { cadaclysm_blacksmith_interpolator_cyclic(try h()) }
    }

    /// The value at the fractional index `t` by `mode`, `dimension` numbers. A `t` that is NaN or
    /// infinite is refused.
    public func at(_ t: Double, _ mode: InterpolatorMode = .linear) throws -> [Double] {
        let handle = try h()
        var out = [Double](repeating: 0, count: width)
        if !cadaclysm_blacksmith_interpolator_at(handle, t, mode.rawValue, &out, UInt32(width)) {
            throw failure("interpolator_at")
        }
        return out
    }

    /// The values at every `t` of `ts` by `mode`, as `at` reads each, in one call. A value of `t`
    /// that is NaN or infinite (by its index) and more than 1,000,000 values are refused.
    public func sample(_ ts: [Double], _ mode: InterpolatorMode = .linear) throws -> [[Double]] {
        let handle = try h()
        if ts.isEmpty { return [] }
        let n = try rtreeCount(ts.count, "interpolator_sample", "values")
        var out = [Double](repeating: 0, count: ts.count * width)
        if !cadaclysm_blacksmith_interpolator_sample(handle, ts, n, mode.rawValue, &out, UInt32(clamping: out.count)) {
            throw failure("interpolator_sample")
        }
        return stride(from: 0, to: out.count, by: width).map { Array(out[$0..<$0 + width]) }
    }

    /// `at(t, .nearest)`: the sample at `floor(t + 1/2)` (a half rounds up), after the clamp or wrap.
    public func nearest(_ t: Double) throws -> [Double] { try at(t, .nearest) }

    /// `at(t, .linear)`: straight between the two samples either side of `t`.
    public func linear(_ t: Double) throws -> [Double] { try at(t, .linear) }

    /// `at(t, .cosine)`: between the two samples either side of `t` on a cosine ease.
    public func cosine(_ t: Double) throws -> [Double] { try at(t, .cosine) }

    /// `at(t, .cubic)`: Bourke's cubic over the four samples about `t`.
    public func cubic(_ t: Double) throws -> [Double] { try at(t, .cubic) }

    /// `at(t, .catmullRom)`: the Catmull-Rom spline over the four samples about `t`.
    public func catmullRom(_ t: Double) throws -> [Double] { try at(t, .catmullRom) }

    public var description: String {
        guard let handle else { return "Interpolator(closed)" }
        let cyclic = cadaclysm_blacksmith_interpolator_cyclic(handle) ? ", cyclic" : ""
        return "Interpolator(\(cadaclysm_blacksmith_interpolator_count(handle)) samples of \(width)\(cyclic))"
    }
}

// MARK: - Subd

/// One edge of a cage: a pair of vertex ids, as `Subd.creases`, `Subd.edgeLoop` and an edge
/// selection hold them (the smaller id first where the kernel returns them).
public struct SubdEdge: Equatable, CustomStringConvertible {
    public var a: UInt32
    public var b: UInt32

    public init(_ a: UInt32, _ b: UInt32) {
        self.a = a
        self.b = b
    }

    public var description: String { "SubdEdge(\(a), \(b))" }
}

/// An axis of a mirror plane (`Subd.mirrorOn`, `Subd.symmetry`).
public enum SubdAxis: Int, Equatable {
    case x = 0, y = 1, z = 2
}

/// What a selection or a pick names: cage vertices, edges or faces.
public enum SubdElements: Int, Equatable {
    case vertices = 0, edges = 1, faces = 2
}

/// Cage elements: vertex ids, edges as vertex pairs, or face ids. What `Subd.selection`
/// reads, `Subd.transform` takes and `Subd.pick` answers (one element).
public enum SubdSelection: Equatable {
    case vertices([UInt32])
    case edges([SubdEdge])
    case faces([UInt32])

    /// Which kind of element this selects.
    public var kind: SubdElements {
        switch self {
        case .vertices: return .vertices
        case .edges: return .edges
        case .faces: return .faces
        }
    }

    /// The ids as the C ABI reads them: edges flat, two vertex ids each.
    var flat: [UInt32] {
        switch self {
        case .vertices(let ids), .faces(let ids): return ids
        case .edges(let edges): return edges.flatMap { [$0.a, $0.b] }
        }
    }
}

/// The mirror plane of a mirrored half: its `axis` and how far from it a vertex counts as on
/// it (`Subd.symmetry`, `Subd.fromParts`).
public struct SubdSymmetry: Equatable {
    public var axis: SubdAxis
    public var tolerance: Double

    public init(_ axis: SubdAxis, tolerance: Double) {
        self.axis = axis
        self.tolerance = tolerance
    }
}

/// One level of a cage's smooth surface, as `Subd.smoothMesh` returns it, copied out of the
/// cage so it outlives it. `positions` and `normals` are limit positions and unit outward
/// limit normals; `indices` is three vertex ids a triangle; `triangleFace` is the face of the
/// **full** cage each triangle lies on (on a mirrored half, face `f` of the half is `f` and
/// its reflection `f + faces.count`).
public struct SubdMesh {
    public let positions: [SIMD3<Double>]
    public let normals: [SIMD3<Double>]
    public let indices: [UInt32]
    public let triangleFace: [UInt32]

    init(_ raw: CadaclysmBlacksmithSubdMesh) {
        func vectors(_ pointer: UnsafePointer<Double>?, _ count: Int) -> [SIMD3<Double>] {
            guard let pointer, count > 0 else { return [] }
            return (0..<count).map { SIMD3(pointer[3 * $0], pointer[3 * $0 + 1], pointer[3 * $0 + 2]) }
        }
        func ids(_ pointer: UnsafePointer<UInt32>?, _ count: Int) -> [UInt32] {
            guard let pointer, count > 0 else { return [] }
            return Array(UnsafeBufferPointer(start: pointer, count: count))
        }
        let n = Int(raw.vertex_count), m = Int(raw.index_count)
        positions = vectors(raw.positions, n)
        normals = vectors(raw.normals, n)
        indices = ids(raw.indices, m)
        triangleFace = ids(raw.triangle_face, m / 3)
    }
}

/// What `Subd.toSolid` did and how close it came: `regular` patches exact from their own net
/// and `refined` ones from a refined neighbourhood; the Catmull-Clark `steps` taken first (1
/// or 2); `levels`, the deepest local refinement a patch took (0 when none was refined); the
/// largest `deviation` from the limit surface, as a fraction of the cage's bounding-box
/// diagonal; the largest tangent break `g1AngleDeg` across a side that is not creased, in
/// degrees; and the world points they were measured at, `deviationAt` and `g1At`.
public struct SubdReport: Equatable {
    public let regular: UInt32
    public let refined: UInt32
    public let steps: UInt32
    public let levels: UInt32
    public let deviation: Double
    public let g1AngleDeg: Double
    public let deviationAt: SIMD3<Double>
    public let g1At: SIMD3<Double>

    init(_ raw: CadaclysmBlacksmithSubdReport) {
        regular = raw.regular
        refined = raw.refined
        steps = raw.steps
        levels = raw.levels
        deviation = raw.deviation
        g1AngleDeg = raw.g1_angle_deg
        deviationAt = SIMD3(raw.deviation_at.0, raw.deviation_at.1, raw.deviation_at.2)
        g1At = SIMD3(raw.g1_at.0, raw.g1_at.1, raw.g1_at.2)
    }
}

/// A Catmull-Clark control cage: positions, faces, creased edges, pinned vertices, an
/// optional mirror plane, and the selection of the edit that made it. Immutable: every edit
/// returns a new `Subd`, with `selection` naming what that edit touched. `toSolid` turns it
/// into an exact B-rep. `close()` frees this handle; so does `deinit`. A refusal throws
/// `BuildError` with the kernel's own words; a closed cage throws `subd: closed`.
public final class Subd {
    private var handle: OpaquePointer?

    init(_ raw: OpaquePointer?, _ what: String = "subd") throws {
        handle = try checked(raw, what)
    }

    deinit { close() }

    /// Free the cage now. Idempotent; every call on the cage throws after. A `SubdMesh`
    /// already read is a copy and reads on regardless.
    public func close() {
        if let handle { cadaclysm_blacksmith_subd_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("subd: closed") }
        return handle
    }

    // MARK: The primitives

    /// A box of `size` (x, y, z), centred on the origin, with `segments` quads along each
    /// axis (1 to 1024).
    public static func cuboid(size: SIMD3<Double> = SIMD3(2, 2, 2),
                              segments: (UInt32, UInt32, UInt32) = (1, 1, 1)) throws -> Subd {
        try Subd(cadaclysm_blacksmith_subd_cuboid(size.x, size.y, size.z, segments.0, segments.1, segments.2),
                 "subd_cuboid")
    }

    /// A cylinder along +Z: one n-gon cap per end with `sides` sides and `rings` bands of
    /// quads between them; with `creasedRims` the two rim loops are creased, so the caps stay
    /// flat. The rims are creased by default, which is what converts: an uncreased cylinder of
    /// 7 or more sides is refused by `toSolid` at the default tolerances.
    public static func cylinder(radius: Double = 1.0, height: Double = 2.0, sides: UInt32 = 8, rings: UInt32 = 1,
                                creasedRims: Bool = true) throws -> Subd {
        try Subd(cadaclysm_blacksmith_subd_cylinder(radius, height, sides, rings, creasedRims), "subd_cylinder")
    }

    /// A quad ball of `radius`: a cube grid with `segments` quads per edge (at most 1024),
    /// each vertex pushed out to the radius.
    public static func sphere(radius: Double = 1.0, segments: UInt32 = 2) throws -> Subd {
        try Subd(cadaclysm_blacksmith_subd_sphere(radius, segments), "subd_sphere")
    }

    /// A torus around +Z: `around` steps about the axis at `major`, `tube` steps round the
    /// tube of `minor`, all quads.
    public static func torus(major: Double = 3.0, minor: Double = 1.0, around: UInt32 = 12,
                             tube: UInt32 = 8) throws -> Subd {
        try Subd(cadaclysm_blacksmith_subd_torus(major, minor, around, tube), "subd_torus")
    }

    /// A cage from its parts, the lossless inverse of reading them back: `positions`, `faces`
    /// lists of vertex ids, `creases` pairs that are edges, `pins` vertex ids, and `symmetry`
    /// nil or the mirror plane of a mirrored half, as `symmetry` reports it. The new cage
    /// selects nothing.
    public static func fromParts(_ positions: [SIMD3<Double>], _ faces: [[UInt32]], creases: [SubdEdge] = [],
                                 pins: [UInt32] = [], symmetry: SubdSymmetry? = nil) throws -> Subd {
        var flat: [Double] = []
        flat.reserveCapacity(positions.count * 3)
        for p in positions { flat.append(contentsOf: [p.x, p.y, p.z]) }
        let sizes = faces.map { UInt32($0.count) }
        let loop = faces.flatMap { $0 }
        let creaseIds = creases.flatMap { [$0.a, $0.b] }
        let axis = Int32(symmetry?.axis.rawValue ?? -1)
        return try Subd(cadaclysm_blacksmith_subd_from_parts(
            flat, UInt32(positions.count), sizes, UInt32(sizes.count), loop, UInt32(loop.count),
            creaseIds, UInt32(creases.count), pins, UInt32(pins.count), axis, symmetry?.tolerance ?? 0.0),
                 "subd_from_parts")
    }

    // MARK: The parts

    /// `read` over this cage's parts while their views are alive.
    private func withParts<T>(_ read: (CadaclysmBlacksmithSubdParts) -> T) throws -> T {
        var parts = CadaclysmBlacksmithSubdParts()
        let handle = try h()
        return try withExtendedLifetime(self) {
            if !cadaclysm_blacksmith_subd_parts(handle, &parts) { throw failure("subd_parts") }
            return read(parts)
        }
    }

    private static func ids(_ pointer: UnsafePointer<UInt32>?, _ count: Int) -> [UInt32] {
        guard let pointer, count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private static func edges(_ flat: [UInt32]) -> [SubdEdge] {
        stride(from: 0, to: flat.count - 1, by: 2).map { SubdEdge(flat[$0], flat[$0 + 1]) }
    }

    /// The cage's vertices: a copy.
    public var positions: [SIMD3<Double>] {
        get throws {
            try withParts { p in
                guard let pointer = p.positions, p.vertex_count > 0 else { return [] }
                return (0..<Int(p.vertex_count)).map {
                    SIMD3(pointer[3 * $0], pointer[3 * $0 + 1], pointer[3 * $0 + 2])
                }
            }
        }
    }

    /// Each face's vertex ids, in loop order.
    public var faces: [[UInt32]] {
        get throws {
            try withParts { p in
                let sizes = Subd.ids(p.face_sizes, Int(p.face_count))
                let loop = Subd.ids(p.face_indices, Int(p.index_count))
                var faces: [[UInt32]] = []
                var at = 0
                for size in sizes {
                    faces.append(Array(loop[at..<at + Int(size)]))
                    at += Int(size)
                }
                return faces
            }
        }
    }

    /// The creased edges, each (smaller id, larger id), sorted.
    public var creases: [SubdEdge] {
        get throws {
            try withParts { p in Subd.edges(Subd.ids(p.creases, 2 * Int(p.crease_count))) }
        }
    }

    /// The pinned vertices: they refine as corners and stay put.
    public var pins: [UInt32] {
        get throws { try withParts { p in Subd.ids(p.pins, Int(p.pin_count)) } }
    }

    /// nil for an ordinary cage; for a mirrored half the plane's axis and how far from it a
    /// vertex counts as on it.
    public var symmetry: SubdSymmetry? {
        get throws {
            try withParts { p in
                guard p.symmetry_axis >= 0, let axis = SubdAxis(rawValue: Int(p.symmetry_axis)) else { return nil }
                return SubdSymmetry(axis, tolerance: p.symmetry_tolerance)
            }
        }
    }

    /// What the edit that made this cage touched; nil for a cage no edit selected (a
    /// primitive, `fromParts`, the mirror calls).
    public var selection: SubdSelection? {
        get throws {
            try withParts { p in
                switch p.selection_kind {
                case 0: return .vertices(Subd.ids(p.selection, Int(p.selection_count)))
                case 1: return .edges(Subd.edges(Subd.ids(p.selection, 2 * Int(p.selection_count))))
                case 2: return .faces(Subd.ids(p.selection, Int(p.selection_count)))
                default: return nil
                }
            }
        }
    }

    // MARK: The edits

    /// A new cage from `make` over this one's handle, kept alive for the call.
    private func edit(_ what: String, _ make: (OpaquePointer) -> OpaquePointer?) throws -> Subd {
        let handle = try h()
        return try withExtendedLifetime(self) { try Subd(make(handle), what) }
    }

    /// A new cage with the selected elements moved by `matrix`: sixteen numbers column-major
    /// (a rotation about a point is baked in by the caller). The new cage selects the same
    /// elements.
    public func transform(_ selection: SubdSelection, _ matrix: [Double]) throws -> Subd {
        guard matrix.count == 16 else {
            throw BuildError("transform: matrix must be 16 numbers (column-major), not \(matrix.count)")
        }
        let ids = selection.flat
        let count = UInt32(selection.kind == .edges ? ids.count / 2 : ids.count)
        return try edit("subd_transform") {
            cadaclysm_blacksmith_subd_transform($0, UInt32(selection.kind.rawValue), ids, count, matrix)
        }
    }

    /// A new cage with `edges` creased, or un-creased when `on` is false; it selects them.
    public func crease(_ edges: [SubdEdge], on: Bool = true) throws -> Subd {
        let flat = edges.flatMap { [$0.a, $0.b] }
        return try edit("subd_set_crease") {
            cadaclysm_blacksmith_subd_set_crease($0, flat, UInt32(edges.count), on)
        }
    }

    /// A new cage with `vertices` pinned (they refine as corners and stay put), or released
    /// when `on` is false; it selects them.
    public func pin(_ vertices: [UInt32], on: Bool = true) throws -> Subd {
        try edit("subd_set_pin") { cadaclysm_blacksmith_subd_set_pin($0, vertices, UInt32(vertices.count), on) }
    }

    /// A new cage with `faces` pushed out by `distance` along each connected region's average
    /// normal, a quad wall on each boundary edge; the moved faces keep their ids and the new
    /// cage selects them.
    public func extrude(_ faces: [UInt32], _ distance: Double) throws -> Subd {
        try edit("subd_extrude") { cadaclysm_blacksmith_subd_extrude($0, faces, UInt32(faces.count), distance) }
    }

    /// A new cage with `faces` shrunk by `amount`, in (0, 1), within their surface and a ring
    /// of quads round each region (each face, with `individual`); the new cage selects the
    /// inner faces.
    public func inset(_ faces: [UInt32], _ amount: Double, individual: Bool = false) throws -> Subd {
        try edit("subd_inset") {
            cadaclysm_blacksmith_subd_inset($0, faces, UInt32(faces.count), amount, individual)
        }
    }

    /// A new cage with `faces` subdivided once by the Catmull-Clark rules (the whole cage when
    /// none are given): each face becomes quads round a new point, and an unpicked face beside
    /// them takes the new edge points as corners. The whole cage keeps its smooth surface
    /// exactly. The new cage selects the new faces.
    public func subdivide(_ faces: [UInt32] = []) throws -> Subd {
        try edit("subd_subdivide") { cadaclysm_blacksmith_subd_subdivide($0, faces, UInt32(faces.count)) }
    }

    /// A new cage with a loop of edges cut across the ring of quads through `edge`, at
    /// `a + at * (b - a)` with `at` in (0, 1); it selects the new loop.
    public func insertLoop(_ edge: SubdEdge, at: Double = 0.5) throws -> Subd {
        try edit("subd_insert_loop") { cadaclysm_blacksmith_subd_insert_loop($0, edge.a, edge.b, at) }
    }

    /// The loop of edges through `edge`, straight across each valence-four vertex, the picked
    /// edge first, each pair smaller id first; empty when `edge` is not an edge of the cage.
    public func edgeLoop(_ edge: SubdEdge) throws -> [SubdEdge] {
        let looped = try edit("subd_edge_loop") { cadaclysm_blacksmith_subd_edge_loop($0, edge.a, edge.b) }
        defer { looped.close() }
        guard case .edges(let loop)? = try looped.selection else { return [] }
        return loop
    }

    /// The positive half of the cage across the plane perpendicular to `axis` as a mirrored
    /// cage: every later edit keeps it symmetric.
    public func mirrorOn(_ axis: SubdAxis) throws -> Subd {
        try edit("subd_mirror_on") { cadaclysm_blacksmith_subd_mirror_on($0, UInt32(axis.rawValue)) }
    }

    /// The mirror baked: the whole cage as an ordinary one, no longer mirrored.
    public func mirrorOff() throws -> Subd {
        try edit("subd_mirror_off") { cadaclysm_blacksmith_subd_mirror_off($0) }
    }

    /// The whole cage of a mirrored half -- the half's vertices first, then the reflections of
    /// those off the plane -- or a copy of an ordinary cage.
    public func full() throws -> Subd {
        try edit("subd_full") { cadaclysm_blacksmith_subd_full($0) }
    }

    // MARK: The surface

    /// The smooth surface refined `levels` times (1 to 6), as a `SubdMesh` of copies.
    public func smoothMesh(_ levels: UInt32 = 3) throws -> SubdMesh {
        var raw = CadaclysmBlacksmithSubdMesh()
        let handle = try h()
        return try withExtendedLifetime(self) {
            if !cadaclysm_blacksmith_subd_smooth_mesh(handle, levels, &raw) { throw failure("subd_smooth_mesh") }
            return SubdMesh(raw)
        }
    }

    /// The cage element of `kind` under `point`, a point on or near the smooth surface: one
    /// vertex or face id, or an edge as a pair with the smaller id first, as a one-element
    /// `SubdSelection`. nil when nothing is within 0.05 of the cage's diagonal -- not an
    /// error; a point that is not finite is refused.
    public func pick(_ point: SIMD3<Double>, _ kind: SubdElements) throws -> SubdSelection? {
        var out: [UInt32] = [0, 0]
        let handle = try h()
        let found = withExtendedLifetime(self) {
            cadaclysm_blacksmith_subd_pick(handle, [point.x, point.y, point.z], UInt32(kind.rawValue), &out)
        }
        if !found {
            if lastError().isEmpty { return nil }
            throw failure("subd_pick")
        }
        switch kind {
        case .vertices: return .vertices([out[0]])
        case .edges: return .edges([SubdEdge(out[0], out[1])])
        case .faces: return .faces([out[0]])
        }
    }

    /// The cage as an exact solid, one NURBS face per patch, and a `SubdReport` of what the
    /// conversion did. `tolerance` is the largest deviation from the limit surface as a
    /// fraction of the cage's diagonal, `g1Angle` the largest tangent break across an
    /// uncreased side in degrees, `maxLevels` the deepest local refinement (2 to 6). A
    /// `tolerance` or `g1Angle` of 0 or less, or a `maxLevels` of 0, takes the default; any
    /// other `maxLevels` outside 2 to 6 is refused. A cage that cannot be held within them is
    /// refused with the figures it measured.
    public func toSolid(tolerance: Double = 1e-4, g1Angle: Double = 0.1,
                        maxLevels: UInt32 = 6) throws -> (Solid, SubdReport) {
        var report = CadaclysmBlacksmithSubdReport()
        let handle = try h()
        let raw = withExtendedLifetime(self) {
            cadaclysm_blacksmith_subd_to_solid(handle, tolerance, g1Angle, maxLevels, &report)
        }
        return (try Solid(raw, "subd_to_solid"), SubdReport(report))
    }
}

// MARK: - Sketch

// The C ABI's codes, by position; Swift speaks the names, as Python does.
fileprivate let sketchEntityKinds = ["point", "line", "circle", "arc", "free_curve"]
let sketchConstraintKinds = [
    "coincident", "point_on_line", "point_on_circle", "horizontal", "vertical", "parallel", "perpendicular",
    "collinear", "tangent", "tangent_at_end", "concentric", "equal_length", "equal_radius", "midpoint",
    "symmetric", "fix", "distance", "point_line_distance", "line_distance", "circle_line_distance",
    "circle_distance", "horizontal_distance", "vertical_distance", "length", "angle", "radius", "diameter",
]
fileprivate let sketchSenses = ["auto", "positive", "negative"]
fileprivate let sketchEnds = ["start", "end"]
fileprivate let sketchStatuses = ["converged", "conflicting", "diverged"]
fileprivate let sketchStates = ["under", "full", "over"]

// sketch_dof_list's and sketch_dof_part_list's `which`.
fileprivate let sketchDofRedundant: UInt32 = 0
fileprivate let sketchDofConflicting: UInt32 = 1
fileprivate let sketchDofFreeEntities: UInt32 = 2
fileprivate let sketchPartConstraints: UInt32 = 0
fileprivate let sketchPartRedundant: UInt32 = 1
fileprivate let sketchPartConflicting: UInt32 = 2
fileprivate let sketchPartFreeEntities: UInt32 = 3

/// What a `Sketch.solve`, `drag`, `setValue`, `setDriving` or `updateReference` did: `status`
/// ("converged", "conflicting" or "diverged"), how many `iterations`, the largest constraint
/// residual left (`maxResidual`), and `ids`: the constraints a conflict ran into, or the worst
/// ones of a diverged solve (empty when it converged). Plain data.
public struct SolveReport: Equatable {
    public let status: String
    public let iterations: Int
    public let maxResidual: Double
    public let ids: [UInt32]

    /// Whether `status` is "converged".
    public var converged: Bool { status == "converged" }
}

/// One independent part of a diagnosed sketch: its `params` (unknowns), how many stay `free`,
/// its `state` ("under", "full" or "over"), its `constraints`, the `redundant` and `conflicting`
/// ones among them, and its `freeEntities`. Plain data.
public struct PartDof: Equatable {
    public let params: Int
    public let free: Int
    public let state: String
    public let constraints: [UInt32]
    public let redundant: [UInt32]
    public let conflicting: [UInt32]
    public let freeEntities: [UInt32]
}

/// A sketch's degrees of freedom (`Sketch.diagnose`): how many are `free`, its `state` ("under",
/// "full" or "over"), the `redundant` and `conflicting` constraint ids, the `freeEntities`
/// (entities that can still move), and the independent `parts` it splits into. Plain data.
public struct Dof: Equatable {
    public let free: Int
    public let state: String
    public let redundant: [UInt32]
    public let conflicting: [UInt32]
    public let freeEntities: [UInt32]
    public let parts: [PartDof]
}

/// A whole count the library sent as a double (a report's status and iterations, a diagnosis's
/// free, state, part count, params): the whole number it holds, or a `BuildError` naming the
/// call when it holds a fraction, NaN or anything outside 0...Int32.max -- never truncated.
func sketchWhole(_ v: Double, _ what: String) throws -> Int {
    guard v == v.rounded(.towardZero), v >= 0, v <= Double(Int32.max) else {
        throw BuildError("\(what): the library answered \(v), not a whole number in range")
    }
    return Int(v)
}

/// The point ids of a drag's `moves` in ascending order: a `Dictionary` walks its keys in no
/// order the solve may depend on.
func sketchDragIDs(_ moves: [UInt32: SIMD2<Double>]) -> [UInt32] { moves.keys.sorted() }

/// `name`'s code in `table`, or a `BuildError` naming the call and the parameter.
fileprivate func sketchCode(_ table: [String], _ name: String, _ call: String, _ param: String) throws -> UInt32 {
    if let i = table.firstIndex(of: name) { return UInt32(i) }
    let quoted = table.map { "'\($0)'" }.joined(separator: ", ")
    throw BuildError("\(call): \(param) must be one of \(quoted), not '\(name)'")
}

/// The name of `code` in `table` (NONE or out of range: the library's reason).
fileprivate func sketchNamed(_ table: [String], _ code: UInt32, _ what: String) throws -> String {
    if code == none || Int(code) >= table.count { throw failure(what) }
    return table[Int(code)]
}

/// `ids` as a pointer that is never null: an empty list goes as a valid pointer and a count of
/// 0, as Python passes one, never as the null the library reads as a refusal of its own.
fileprivate func withSketchIDs<R>(_ ids: [UInt32], _ body: (UnsafePointer<UInt32>) -> R) -> R {
    let padded = ids.isEmpty ? [0] : ids
    return padded.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// `values` as a pointer that is never null, as `withSketchIDs`.
fileprivate func withSketchDoubles<R>(_ values: [Double], _ body: (UnsafePointer<Double>) -> R) -> R {
    let padded = values.isEmpty ? [0] : values
    return padded.withUnsafeBufferPointer { body($0.baseAddress!) }
}

/// A 2D sketch of points, lines, circles, arcs and free curves held by geometric constraints
/// and dimensions, solved on request. Entities and constraints are named by `UInt32` ids.
/// Entity kinds are "point", "line", "circle", "arc" and "free_curve"; constraint kinds the
/// names of the methods that add them ("point_line_distance", ...) -- but for `radiusOf`, whose
/// kind is "radius". Senses are "auto", "positive" or "negative"; ends "start" or "end".
///
/// A refused call throws a `BuildError` with the library's text and, as its `ids`, the ids the
/// refusal names: the constraints a new constraint, value or reference conflicts with, the
/// entities still using a point (empty when it names none). The `SolveReport`s of `solve`,
/// `drag`, `setValue`, `setDriving` and `updateReference` carry a report's ids the same way.
/// `close()` frees the handle; so does `deinit`. Not safe for concurrent use.
public final class Sketch {
    private var handle: OpaquePointer?

    private init(_ raw: OpaquePointer?, _ what: String) throws {
        handle = try checked(raw, what)
    }

    /// A new, empty sketch.
    public convenience init() throws {
        try self.init(cadaclysm_blacksmith_sketch_new(), "sketch_new")
    }

    /// A sketch of `profile`'s lines, arcs and curves joined end to end, holes included; with
    /// `infer` the obvious constraints (horizontal, vertical, tangent joints, ...) too. Ends
    /// within `tolerance` count as joined.
    public static func fromProfile(_ profile: Profile, infer: Bool = true,
                                   tolerance: Double = 1e-6) throws -> Sketch {
        let raw = withExtendedLifetime(profile) {
            cadaclysm_blacksmith_sketch_from_profile(profile.handle, infer, tolerance)
        }
        return try Sketch(raw, "sketch_from_profile")
    }

    deinit { close() }

    /// Free the sketch now. Idempotent; every call on it throws after.
    public func close() {
        if let handle { cadaclysm_blacksmith_sketch_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("sketch: closed") }
        return handle
    }

    // MARK: Failures and borrowed lists

    /// A borrowed list copied out (nil: the library's reason, no ids).
    private func lent(_ p: UnsafePointer<UInt32>?, _ n: Int, _ what: String) throws -> [UInt32] {
        guard let p else { throw failure(what) }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// The ids the last call named, copied (the sketch's `report_ids`).
    private func reportIDs(_ handle: OpaquePointer) -> [UInt32] {
        var n = 0
        guard let p = cadaclysm_blacksmith_sketch_report_ids(handle, &n) else { return [] }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// A refusal that may name ids (constrain, removeEntity, setValue, setDriving,
    /// updateReference, drag): the library's reason first, then `report_ids`.
    private func refused(_ what: String) -> BuildError {
        let reason = lastError()
        let ids = handle.map { reportIDs($0) } ?? []
        return BuildError(reason.isEmpty ? what : reason, ids: ids)
    }

    /// An id the library handed back (NONE: the library's reason, no ids).
    private func id(_ got: UInt32, _ what: String) throws -> UInt32 {
        if got == none { throw failure(what) }
        return got
    }

    /// The `SolveReport` a re-solving call filled in (`done` false: refused, with ids).
    private func solved(_ handle: OpaquePointer, _ done: Bool, _ report: [Double], _ what: String) throws -> SolveReport {
        if !done { throw refused(what) }
        let ids = reportIDs(handle)
        let status = try sketchNamed(sketchStatuses, UInt32(try sketchWhole(report[0], what)), what)
        let iterations = try sketchWhole(report[1], what)
        return SolveReport(status: status, iterations: iterations, maxResidual: report[2], ids: ids)
    }

    // MARK: Entities

    /// A free point at (`x`, `y`); a coordinate that is not finite is refused.
    @discardableResult
    public func addPoint(_ x: Double, _ y: Double) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_point(handle, x, y), "sketch_add_point")
    }

    /// A line between the points `a` and `b`.
    @discardableResult
    public func addLine(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_line(handle, a, b), "sketch_add_line")
    }

    /// A circle of radius `r` about the point `centre`.
    @discardableResult
    public func addCircle(_ centre: UInt32, _ r: Double) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_circle(handle, centre, r), "sketch_add_circle")
    }

    /// A counter-clockwise arc about the point `centre` from the point `start` to the point `end`.
    @discardableResult
    public func addArc(_ centre: UInt32, _ start: UInt32, _ end: UInt32) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_arc(handle, centre, start, end), "sketch_add_arc")
    }

    /// A cubic Bezier free curve from the point `start` through the controls `c1` and `c2` to a
    /// new end point at `to`; the curve owns its control points.
    @discardableResult
    public func addBezier(_ start: UInt32, _ c1: SIMD2<Double>, _ c2: SIMD2<Double>,
                          _ to: SIMD2<Double>) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_bezier(handle, start, c1.x, c1.y, c2.x, c2.y, to.x, to.y),
                      "sketch_add_bezier")
    }

    /// A rational quadratic (conic) free curve from the point `start` with the `control` of
    /// `weight` to a new end point at `to`.
    @discardableResult
    public func addConic(_ start: UInt32, _ control: SIMD2<Double>, _ to: SIMD2<Double>,
                         weight: Double) throws -> UInt32 {
        let handle = try h()
        return try id(cadaclysm_blacksmith_sketch_add_conic(handle, start, control.x, control.y, to.x, to.y, weight),
                      "sketch_add_conic")
    }

    /// A NURBS free curve of `degree` from the point `start` through the control `points` after
    /// it, on `knots`; `weights` nil for a plain B-spline, or one per control point counting the
    /// start (`points.count + 1`) -- any other count is refused before the call.
    @discardableResult
    public func addNurbs(_ start: UInt32, points: [SIMD2<Double>], knots: [Double], degree: UInt32 = 3,
                         weights: [Double]? = nil) throws -> UInt32 {
        let handle = try h()
        let n = points.count
        // The library reads exactly n + 1 weights whatever the array holds: check here.
        if let weights, weights.count != n + 1 {
            throw BuildError("sketch_add_nurbs: \(weights.count) weights for \(n + 1) control points "
                + "(the start and \(n) given); give one per point")
        }
        var flat: [Double] = []
        flat.reserveCapacity(2 * n)
        for p in points {
            flat.append(p.x)
            flat.append(p.y)
        }
        let got = withSketchDoubles(flat) { xy in
            withSketchDoubles(knots) { k in
                if let weights {
                    return weights.withUnsafeBufferPointer { w in
                        cadaclysm_blacksmith_sketch_add_nurbs(handle, start, degree, xy, n, w.baseAddress, k, knots.count)
                    }
                }
                return cadaclysm_blacksmith_sketch_add_nurbs(handle, start, degree, xy, n, nil, k, knots.count)
            }
        }
        return try id(got, "sketch_add_nurbs")
    }

    /// The rectangle with opposite corners `a` and `b`: its four corner points, counter-clockwise
    /// from `a`, and its four sides (side `i` from corner `i`).
    @discardableResult
    public func addRect(_ a: SIMD2<Double>, _ b: SIMD2<Double>) throws -> (corners: [UInt32], sides: [UInt32]) {
        let handle = try h()
        var n = 0
        let ids = try lent(cadaclysm_blacksmith_sketch_add_rect(handle, a.x, a.y, b.x, b.y, &n), n, "sketch_add_rect")
        guard ids.count == 8 else {
            throw BuildError("sketch_add_rect: the library answered \(ids.count) ids, not 8")
        }
        return (Array(ids[0..<4]), Array(ids[4..<8]))
    }

    /// The kind of entity `id`: "point", "line", "circle", "arc" or "free_curve".
    public func kind(_ id: UInt32) throws -> String {
        let handle = try h()
        return try sketchNamed(sketchEntityKinds, cadaclysm_blacksmith_sketch_kind(handle, id), "sketch_kind")
    }

    /// The live entity ids, ascending.
    public func entities() throws -> [UInt32] {
        let handle = try h()
        var n = 0
        return try lent(cadaclysm_blacksmith_sketch_entities(handle, &n), n, "sketch_entities")
    }

    /// The position of the point `id`.
    public func point(_ id: UInt32) throws -> SIMD2<Double> {
        let handle = try h()
        var out = [Double](repeating: 0, count: 2)
        if !cadaclysm_blacksmith_sketch_point(handle, id, &out) { throw failure("sketch_point") }
        return SIMD2(out[0], out[1])
    }

    /// Move the point `id` to (`x`, `y`) without solving.
    public func setPoint(_ id: UInt32, _ x: Double, _ y: Double) throws {
        let handle = try h()
        if !cadaclysm_blacksmith_sketch_set_point(handle, id, x, y) { throw failure("sketch_set_point") }
    }

    /// The radius of the circle or arc `id` (the RADIUS constraint is `radiusOf`).
    public func radius(_ id: UInt32) throws -> Double {
        let handle = try h()
        let r = cadaclysm_blacksmith_sketch_radius(handle, id)
        if r.isNaN { throw failure("sketch_radius") }
        return r
    }

    /// Set the circle `id`'s radius to `r` without solving.
    public func setRadius(_ id: UInt32, _ r: Double) throws {
        let handle = try h()
        if !cadaclysm_blacksmith_sketch_set_radius(handle, id, r) { throw failure("sketch_set_radius") }
    }

    /// The centre point of the circle or arc `id`.
    public func centre(_ id: UInt32) throws -> UInt32 {
        let handle = try h()
        return try self.id(cadaclysm_blacksmith_sketch_centre(handle, id), "sketch_centre")
    }

    /// The points entity `id` runs between: a line's [a, b], an arc's [start, end], a free
    /// curve's [start, controls..., end].
    public func ends(_ id: UInt32) throws -> [UInt32] {
        let handle = try h()
        var n = 0
        return try lent(cadaclysm_blacksmith_sketch_ends(handle, id, &n), n, "sketch_ends")
    }

    /// Mark entity `id` as construction geometry (kept out of profiles) when `on`, or back.
    public func setConstruction(_ id: UInt32, on: Bool = true) throws {
        let handle = try h()
        if !cadaclysm_blacksmith_sketch_set_construction(handle, id, on) { throw failure("sketch_set_construction") }
    }

    /// Whether entity `id` is construction geometry (false for an unknown id, and when closed).
    public func isConstruction(_ id: UInt32) -> Bool {
        guard let handle else { return false }
        return cadaclysm_blacksmith_sketch_is_construction(handle, id)
    }

    /// Whether entity `id` is a reference copy of another sketch's (false for an unknown id,
    /// and when closed).
    public func isReference(_ id: UInt32) -> Bool {
        guard let handle else { return false }
        return cadaclysm_blacksmith_sketch_is_reference(handle, id)
    }

    /// Remove entity `id` and the constraints on it, and return the removed constraint ids.
    /// Refused for a point that lines or circles still use, with the entities holding it as the
    /// error's `ids`.
    @discardableResult
    public func removeEntity(_ id: UInt32) throws -> [UInt32] {
        let handle = try h()
        var n = 0
        guard let p = cadaclysm_blacksmith_sketch_remove_entity(handle, id, &n) else {
            throw refused("sketch_remove_entity")
        }
        return Array(UnsafeBufferPointer(start: p, count: n))
    }

    /// A fixed construction copy of `other`'s entity `entity`, kept in step by `updateReference`.
    /// `other` must be another sketch.
    @discardableResult
    public func reference(_ other: Sketch, _ entity: UInt32) throws -> UInt32 {
        let handle = try h()
        let otherHandle = try other.h()
        let got = withExtendedLifetime(other) {
            cadaclysm_blacksmith_sketch_reference(handle, otherHandle, entity)
        }
        return try id(got, "sketch_reference")
    }

    /// Refresh the reference `id` from `other` and re-solve.
    @discardableResult
    public func updateReference(_ id: UInt32, _ other: Sketch) throws -> SolveReport {
        let handle = try h()
        let otherHandle = try other.h()
        var report = [Double](repeating: 0, count: 3)
        let done = withExtendedLifetime(other) {
            cadaclysm_blacksmith_sketch_update_reference(handle, id, otherHandle, &report)
        }
        return try solved(handle, done, report, "sketch_update_reference")
    }

    // MARK: Constraints: each returns the new constraint's id

    /// Add a constraint of `kind`; geometric kinds pass Python's fillers (value 0, driving true,
    /// sense "auto", end "start").
    private func constrain(_ kind: String, _ refs: [UInt32], value: Double = 0, driving: Bool = true,
                           sense: String = "auto", end: String = "start") throws -> UInt32 {
        let handle = try h()
        let senseCode = try sketchCode(sketchSenses, sense, kind, "sense")
        let endCode = try sketchCode(sketchEnds, end, kind, "end")
        let kindCode = try sketchCode(sketchConstraintKinds, kind, "sketch_constrain", "kind")
        let got = withSketchIDs(refs) {
            cadaclysm_blacksmith_sketch_constrain(handle, kindCode, $0, refs.count, value, driving, senseCode, endCode)
        }
        if got == none { throw refused("sketch_constrain") }
        return got
    }

    /// Put the points `a` and `b` on each other.
    @discardableResult
    public func coincident(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("coincident", [a, b])
    }

    /// Put `point` on `line`.
    @discardableResult
    public func pointOnLine(_ point: UInt32, _ line: UInt32) throws -> UInt32 {
        try constrain("point_on_line", [point, line])
    }

    /// Put `point` on `circle`, a circle or an arc.
    @discardableResult
    public func pointOnCircle(_ point: UInt32, _ circle: UInt32) throws -> UInt32 {
        try constrain("point_on_circle", [point, circle])
    }

    /// Hold the points `a` and `b` level with each other.
    @discardableResult
    public func horizontal(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("horizontal", [a, b])
    }

    /// Hold the points `a` and `b` one above the other.
    @discardableResult
    public func vertical(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("vertical", [a, b])
    }

    /// Hold the lines `a` and `b` parallel.
    @discardableResult
    public func parallel(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("parallel", [a, b])
    }

    /// Hold the lines `a` and `b` square to each other.
    @discardableResult
    public func perpendicular(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("perpendicular", [a, b])
    }

    /// Hold the lines `a` and `b` on one line.
    @discardableResult
    public func collinear(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("collinear", [a, b])
    }

    /// Hold the curves `a` and `b` tangent; `sense` is "auto", "positive" or "negative".
    @discardableResult
    public func tangent(_ a: UInt32, _ b: UInt32, sense: String = "auto") throws -> UInt32 {
        try constrain("tangent", [a, b], sense: sense)
    }

    /// Hold the free curve `curve` tangent to `other` at its `end` ("start" or "end").
    @discardableResult
    public func tangentAtEnd(_ curve: UInt32, _ other: UInt32, end: String = "start") throws -> UInt32 {
        try constrain("tangent_at_end", [curve, other], end: end)
    }

    /// Hold the circles or arcs `a` and `b` on one centre.
    @discardableResult
    public func concentric(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("concentric", [a, b])
    }

    /// Hold the lines `a` and `b` the same length.
    @discardableResult
    public func equalLength(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("equal_length", [a, b])
    }

    /// Hold the circles or arcs `a` and `b` the same radius.
    @discardableResult
    public func equalRadius(_ a: UInt32, _ b: UInt32) throws -> UInt32 {
        try constrain("equal_radius", [a, b])
    }

    /// Hold `point` at the middle of `line`.
    @discardableResult
    public func midpoint(_ point: UInt32, _ line: UInt32) throws -> UInt32 {
        try constrain("midpoint", [point, line])
    }

    /// Hold the points `a` and `b` mirror images across the line `about`.
    @discardableResult
    public func symmetric(_ a: UInt32, _ b: UInt32, _ about: UInt32) throws -> UInt32 {
        try constrain("symmetric", [a, b, about])
    }

    /// Hold `entity` where it is.
    @discardableResult
    public func fix(_ entity: UInt32) throws -> UInt32 {
        try constrain("fix", [entity])
    }

    /// Dimension the points `a` and `b` `value` apart; a dimension not `driving` only reports.
    @discardableResult
    public func distance(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("distance", [a, b], value: value, driving: driving)
    }

    /// Dimension `point` `value` from `line`, on the side `sense` names.
    @discardableResult
    public func pointLineDistance(_ point: UInt32, _ line: UInt32, _ value: Double, driving: Bool = true,
                                  sense: String = "auto") throws -> UInt32 {
        try constrain("point_line_distance", [point, line], value: value, driving: driving, sense: sense)
    }

    /// Dimension the parallel lines `a` and `b` `value` apart.
    @discardableResult
    public func lineDistance(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true,
                             sense: String = "auto") throws -> UInt32 {
        try constrain("line_distance", [a, b], value: value, driving: driving, sense: sense)
    }

    /// Dimension `circle` `value` from `line`.
    @discardableResult
    public func circleLineDistance(_ circle: UInt32, _ line: UInt32, _ value: Double, driving: Bool = true,
                                   sense: String = "auto") throws -> UInt32 {
        try constrain("circle_line_distance", [circle, line], value: value, driving: driving, sense: sense)
    }

    /// Dimension the circles `a` and `b` `value` apart.
    @discardableResult
    public func circleDistance(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("circle_distance", [a, b], value: value, driving: driving)
    }

    /// Dimension the points `a` and `b` `value` apart along x.
    @discardableResult
    public func horizontalDistance(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("horizontal_distance", [a, b], value: value, driving: driving)
    }

    /// Dimension the points `a` and `b` `value` apart along y.
    @discardableResult
    public func verticalDistance(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("vertical_distance", [a, b], value: value, driving: driving)
    }

    /// Dimension `line` `value` long.
    @discardableResult
    public func length(_ line: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("length", [line], value: value, driving: driving)
    }

    /// Dimension the angle from line `a` to line `b`, in radians.
    @discardableResult
    public func angle(_ a: UInt32, _ b: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("angle", [a, b], value: value, driving: driving)
    }

    /// The RADIUS dimension (kind "radius") -- `radius(_:)` reads a radius instead.
    @discardableResult
    public func radiusOf(_ circle: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("radius", [circle], value: value, driving: driving)
    }

    /// Dimension the circle or arc `circle`'s diameter.
    @discardableResult
    public func diameter(_ circle: UInt32, _ value: Double, driving: Bool = true) throws -> UInt32 {
        try constrain("diameter", [circle], value: value, driving: driving)
    }

    // MARK: Constraint readers

    /// The live constraint ids, ascending.
    public func constraints() throws -> [UInt32] {
        let handle = try h()
        var n = 0
        return try lent(cadaclysm_blacksmith_sketch_constraints(handle, &n), n, "sketch_constraints")
    }

    /// The kind of constraint `id`, e.g. "point_line_distance".
    public func constraintKind(_ id: UInt32) throws -> String {
        let handle = try h()
        return try sketchNamed(sketchConstraintKinds, cadaclysm_blacksmith_sketch_constraint_kind(handle, id),
                               "sketch_constraint_kind")
    }

    /// The entity ids constraint `id` was made on, in the order given.
    public func constraintRefs(_ id: UInt32) throws -> [UInt32] {
        let handle = try h()
        var n = 0
        return try lent(cadaclysm_blacksmith_sketch_constraint_refs(handle, id, &n), n, "sketch_constraint_refs")
    }

    /// The value of the dimension `id`; nil for a constraint that is not a dimension. An
    /// unknown id is refused.
    public func constraintValue(_ id: UInt32) throws -> Double? {
        let handle = try h()
        let v = cadaclysm_blacksmith_sketch_constraint_value(handle, id)
        if v.isNaN {
            // NaN is both "not a dimension" (no error set) and "no such constraint" (one set).
            if !lastError().isEmpty { throw failure("sketch_constraint_value") }
            return nil
        }
        return v
    }

    /// Whether the dimension `id` drives the geometry (false for a constraint that is not a
    /// dimension). An unknown id is refused.
    public func constraintDriving(_ id: UInt32) throws -> Bool {
        let handle = try h()
        let driving = cadaclysm_blacksmith_sketch_constraint_driving(handle, id)
        // false is both "not driving" (no error set) and "no such constraint" (one set).
        if !driving && !lastError().isEmpty { throw failure("sketch_constraint_driving") }
        return driving
    }

    /// The sense of constraint `id`; "auto" for a kind without one.
    public func constraintSense(_ id: UInt32) throws -> String {
        let handle = try h()
        return try sketchNamed(sketchSenses, cadaclysm_blacksmith_sketch_constraint_sense(handle, id),
                               "sketch_constraint_sense")
    }

    /// The end ("start" or "end") of the free curve a `tangentAtEnd` constraint `id` holds;
    /// "start" for a kind without one.
    public func constraintEnd(_ id: UInt32) throws -> String {
        let handle = try h()
        return try sketchNamed(sketchEnds, cadaclysm_blacksmith_sketch_constraint_end(handle, id),
                               "sketch_constraint_end")
    }

    /// Whether the tangent constraint `id` joins two curves end to end (false otherwise, and
    /// when closed).
    public func isJointTangent(_ id: UInt32) -> Bool {
        guard let handle else { return false }
        return cadaclysm_blacksmith_sketch_is_joint_tangent(handle, id)
    }

    /// Remove the constraint `id`.
    public func remove(_ id: UInt32) throws {
        let handle = try h()
        if !cadaclysm_blacksmith_sketch_remove(handle, id) { throw failure("sketch_remove") }
    }

    /// Set the dimension `id` to `value` and re-solve.
    @discardableResult
    public func setValue(_ id: UInt32, _ value: Double) throws -> SolveReport {
        let handle = try h()
        var report = [Double](repeating: 0, count: 3)
        let done = cadaclysm_blacksmith_sketch_set_value(handle, id, value, &report)
        return try solved(handle, done, report, "sketch_set_value")
    }

    /// Make the dimension `id` drive the geometry (true) or only report it, and re-solve.
    @discardableResult
    public func setDriving(_ id: UInt32, _ driving: Bool) throws -> SolveReport {
        let handle = try h()
        var report = [Double](repeating: 0, count: 3)
        let done = cadaclysm_blacksmith_sketch_set_driving(handle, id, driving, &report)
        return try solved(handle, done, report, "sketch_set_driving")
    }

    /// What the geometry measures for the dimension `id` right now.
    public func measure(_ id: UInt32) throws -> Double {
        let handle = try h()
        let v = cadaclysm_blacksmith_sketch_measure(handle, id)
        if v.isNaN { throw failure("sketch_measure") }
        return v
    }

    // MARK: Solving and diagnosis

    /// Solve the sketch. A conflicting or diverged solve is reported, not thrown.
    @discardableResult
    public func solve() throws -> SolveReport {
        let handle = try h()
        var report = [Double](repeating: 0, count: 3)
        if !cadaclysm_blacksmith_sketch_solve(handle, &report) {
            throw failure("sketch_solve") // only a null sketch: no ids to name
        }
        return try solved(handle, true, report, "sketch_solve")
    }

    /// Drag each point in `moves` towards its target while the constraints hold, as a live
    /// gesture would. Refused for an id that is not a point.
    @discardableResult
    public func drag(_ moves: [UInt32: SIMD2<Double>]) throws -> SolveReport {
        let handle = try h()
        let points = sketchDragIDs(moves)
        var flat: [Double] = []
        for p in points {
            flat.append(moves[p]!.x)
            flat.append(moves[p]!.y)
        }
        var report = [Double](repeating: 0, count: 3)
        let done = withSketchIDs(points) { ids in
            withSketchDoubles(flat) { xy in
                cadaclysm_blacksmith_sketch_drag(handle, ids, xy, points.count, &report)
            }
        }
        return try solved(handle, done, report, "sketch_drag")
    }

    /// The sketch's degrees of freedom, whole and per independent part.
    public func diagnose() throws -> Dof {
        let handle = try h()
        var out = [Double](repeating: 0, count: 3)
        if !cadaclysm_blacksmith_sketch_diagnose(handle, &out) { throw failure("sketch_diagnose") }
        let free = try sketchWhole(out[0], "sketch_diagnose")
        let state = try sketchNamed(sketchStates, UInt32(try sketchWhole(out[1], "sketch_diagnose")), "sketch_diagnose")
        let partCount = try sketchWhole(out[2], "sketch_diagnose")
        func dofList(_ which: UInt32) throws -> [UInt32] {
            var n = 0
            return try lent(cadaclysm_blacksmith_sketch_dof_list(handle, which, &n), n, "sketch_dof_list")
        }
        let redundant = try dofList(sketchDofRedundant)
        let conflicting = try dofList(sketchDofConflicting)
        let freeEntities = try dofList(sketchDofFreeEntities)
        var parts: [PartDof] = []
        for i in 0..<partCount {
            var raw = [Double](repeating: 0, count: 3)
            if !cadaclysm_blacksmith_sketch_dof_part(handle, UInt32(i), &raw) { throw failure("sketch_dof_part") }
            let params = try sketchWhole(raw[0], "sketch_dof_part")
            let partFree = try sketchWhole(raw[1], "sketch_dof_part")
            let partState = try sketchNamed(sketchStates, UInt32(try sketchWhole(raw[2], "sketch_dof_part")),
                                            "sketch_dof_part")
            func partList(_ which: UInt32) throws -> [UInt32] {
                var n = 0
                return try lent(cadaclysm_blacksmith_sketch_dof_part_list(handle, UInt32(i), which, &n), n,
                                "sketch_dof_part_list")
            }
            parts.append(PartDof(params: params, free: partFree, state: partState,
                                 constraints: try partList(sketchPartConstraints),
                                 redundant: try partList(sketchPartRedundant),
                                 conflicting: try partList(sketchPartConflicting),
                                 freeEntities: try partList(sketchPartFreeEntities)))
        }
        return Dof(free: free, state: state, redundant: redundant, conflicting: conflicting,
                   freeEntities: freeEntities, parts: parts)
    }

    /// The closed loops as profiles (nested loops become holes; construction geometry left
    /// out); ends within `tolerance` join.
    public func profiles(tolerance: Double = 1e-6) throws -> [Profile] {
        let handle = try h()
        return try Profile.list(cadaclysm_blacksmith_sketch_profiles(handle, tolerance), "sketch_profiles")
    }

    /// The paths that do not close, as profiles; ends within `tolerance` join.
    public func openChains(tolerance: Double = 1e-6) throws -> [Profile] {
        let handle = try h()
        return try Profile.list(cadaclysm_blacksmith_sketch_open_chains(handle, tolerance), "sketch_open_chains")
    }
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

// MARK: - Machining

/// A cutter: Grbl tool `number` (1 to 255, the `T` word), `diameter` and `fluteLength` in
/// mm, `feed` and `plunge` in mm/min, `rpm` its spindle speed, ramping into its cuts at
/// `rampAngle` degrees. Immutable; a job keeps its own copy, so freeing a tool a job has
/// used changes nothing there. `deinit` frees it; there is no `close()` of its own.
public final class Tool {
    let handle: OpaquePointer

    init(_ raw: OpaquePointer?, _ what: String = "tool") throws {
        handle = try checked(raw, what)
    }

    deinit { cadaclysm_blacksmith_tool_free(handle) }

    /// `made` wrapped, then turned to `rampAngle` when it is not the library's own default --
    /// the unramped handle freed at once rather than kept around.
    private static func ramped(_ made: OpaquePointer?, rampAngle: Double, _ what: String) throws -> Tool {
        let tool = try Tool(made, what)
        guard rampAngle != 3.0 else { return tool }
        return try tool.withRampAngle(rampAngle)
    }

    /// A flat end mill: Grbl tool `number` (at least 1), `diameter` and `fluteLength` in mm,
    /// `feed` and `plunge` in mm/min, `rpm` its spindle speed. It ramps into its cuts at
    /// `rampAngle` degrees (the library's own default is 3). Throws for a `number` of 0 or
    /// above 255, a size, feed or speed not positive and finite, or a `rampAngle` outside
    /// (0, 90].
    public static func flat(_ number: Int, diameter: Double, fluteLength: Double, feed: Double, plunge: Double,
                            rpm: Double, rampAngle: Double = 3.0) throws -> Tool {
        let made = cadaclysm_blacksmith_tool_flat(UInt32(clamping: number), diameter, fluteLength, feed, plunge, rpm)
        return try ramped(made, rampAngle: rampAngle, "tool_flat")
    }

    /// A ball end mill, as `flat`, its tip a half sphere of the diameter; in 2.5D it cuts
    /// where a flat does, `bottom` being the tip.
    public static func ball(_ number: Int, diameter: Double, fluteLength: Double, feed: Double, plunge: Double,
                            rpm: Double, rampAngle: Double = 3.0) throws -> Tool {
        let made = cadaclysm_blacksmith_tool_ball(UInt32(clamping: number), diameter, fluteLength, feed, plunge, rpm)
        return try ramped(made, rampAngle: rampAngle, "tool_ball")
    }

    /// A drill: as `flat`, plunging at `feed`. A job takes it for `Job.drill` (and
    /// `Job.machine`'s drills) only.
    public static func drill(_ number: Int, diameter: Double, fluteLength: Double, feed: Double, rpm: Double) throws -> Tool {
        try Tool(cadaclysm_blacksmith_tool_drill(UInt32(clamping: number), diameter, fluteLength, feed, rpm), "tool_drill")
    }

    /// A new tool: this one, ramping into its cuts at `degrees` from the horizontal instead.
    /// Throws for an angle outside (0, 90].
    public func withRampAngle(_ degrees: Double) throws -> Tool {
        try Tool(cadaclysm_blacksmith_tool_with_ramp_angle(handle, degrees), "tool_with_ramp_angle")
    }
}

/// The block of material a job cuts, an axis-aligned box. Immutable; a job keeps its own
/// copy. `deinit` frees it; there is no `close()` of its own.
public final class Stock {
    let handle: OpaquePointer

    init(_ raw: OpaquePointer?, _ what: String = "stock") throws {
        handle = try checked(raw, what)
    }

    deinit { cadaclysm_blacksmith_stock_free(handle) }

    /// The box from `min` (x, y, z) to `max`. Throws unless every min is below its max and
    /// all six are finite.
    public static func box(min: SIMD3<Double>, max: SIMD3<Double>) throws -> Stock {
        try Stock(cadaclysm_blacksmith_stock_box(min.x, min.y, min.z, max.x, max.y, max.z), "stock_box")
    }

    /// `solid`'s bounds grown by `margin` in -X, +X, -Y, +Y and +Z; the bottom stays at the
    /// solid's lowest Z. Throws for a `margin` negative or not finite.
    public static func around(_ solid: Solid, margin: Double = 0.0) throws -> Stock {
        try Stock(cadaclysm_blacksmith_stock_around(try solid.h(), margin), "stock_around")
    }
}

/// One file a job wrote: a Grbl program (`tool` its `T` number, `name` `<job name>-T<n>`, or
/// `<job name>-<k>-T<n>` for a repeated tool) from `Job.gcode`, or one of
/// `Job.writeCamotics`'s files (`tool` 0 for the simulation copies and the project). Copied
/// out; immutable.
public struct Program: Equatable, CustomStringConvertible {
    public let tool: Int
    public let name: String
    public let text: String

    public var description: String { "Program(tool=\(tool), name=\(name), \(text.count) characters)" }
}

/// One operation of a `Job`, read back by `Job.operations`: `kind` (`"face"`, `"contour"`,
/// `"pocket"` or `"drill"`), `tool` (its Grbl `T` number) and `params`, the operation's own
/// arguments in the library's own numbers -- `side` 0 outside, 1 inside or 2 on its line;
/// `climb` and `open` 1 or 0; `points` a count; a `peck` of none reads back as `nil`. Copied
/// out; immutable.
public struct Operation: Equatable, CustomStringConvertible {
    public let kind: String
    public let tool: Int
    public let params: [String: Double?]

    public var description: String {
        let parts = params.map { k, v in v.map { "\(k): \($0)" } ?? "\(k): nil" }.sorted()
        return "Operation(kind=\(kind), tool=\(tool), params={\(parts.joined(separator: ", "))})"
    }
}

/// One thing `Job.machine` left uncut, one of `Report`'s items. Copied out; immutable.
public struct ReportItem: CustomStringConvertible {
    /// `"corner"` (material the end mill doesn't reach), `"hole"` (a round hole no drill
    /// matches or a matched drill can't make), `"slope"` (a face that is neither horizontal
    /// nor vertical, cut as steps), `"undercut"` (material under an overhang) or
    /// `"too_deep"` (a level below the end mill's flute length, cut only that far).
    public let kind: String
    /// The item's XYZ location -- a centroid for an area, the axis point at the top for a
    /// hole.
    public let at: SIMD3<Double>
    /// An area in mm^2 for `corner`/`undercut`, a diameter in mm for `hole`, and a height in
    /// mm (its Z range) for `slope` and `too_deep`.
    public let size: Double
    /// The highest Z the item stands up to.
    public let top: Double
    /// The lowest Z the item stands down to.
    public let bottom: Double
    /// One sentence naming the cause and the tool involved.
    public let reason: String
    /// The XY area the item covers.
    public let region: [Profile]

    public var description: String {
        "ReportItem(kind=\(kind), at=(\(at.x), \(at.y), \(at.z)), size=\(size), reason=\(reason), "
            + "top=\(top), bottom=\(bottom), region=\(region.count) profile(s))"
    }
}

/// What `Job.machine` could not make: `items`, in order, read once when `machine` returns,
/// and the kernel's own `text` -- one line per item, or `"nothing left uncut"`. Copied out;
/// immutable.
public struct Report: CustomStringConvertible {
    public let items: [ReportItem]
    public let text: String

    /// Whether nothing was left uncut (no items).
    public var isEmpty: Bool { items.isEmpty }

    public var description: String { text }
}

/// `side`'s library code, or the refusal for any other side -- checked here so a bad spelling never
/// reaches the library.
private func jobSide(_ side: String) throws -> UInt32 {
    switch side {
    case "outside": return 0
    case "inside": return 1
    case "on": return 2
    default: throw BuildError("side must be 'outside', 'inside' or 'on'")
    }
}

/// What the kernel says of a job name with a control character in it -- a NUL, which a C
/// string would cut the name short at, is refused with it before the library is asked, as
/// the Python SDK does for a `Job` name and a `writeCamotics` stem.
private let jobNulName = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"

/// The files of one `job_gcode`/`job_camotics` call, copied out, the list freed.
private func programs(_ raw: OpaquePointer?, _ what: String) throws -> [Program] {
    guard let raw else { throw failure(what) }
    defer { cadaclysm_blacksmith_programs_free(raw) }
    let n = cadaclysm_blacksmith_programs_count(raw)
    return (0..<n).map { i in
        Program(tool: Int(cadaclysm_blacksmith_programs_tool(raw, i)),
                name: text(cadaclysm_blacksmith_programs_name(raw, i)),
                text: text(cadaclysm_blacksmith_programs_text(raw, i)))
    }
}

/// A `job_machine` report, read field by field, the report freed.
private func readReport(_ raw: OpaquePointer?) throws -> Report {
    guard let raw else { throw failure("job_machine") }
    defer { cadaclysm_blacksmith_report_free(raw) }
    let n = cadaclysm_blacksmith_report_count(raw)
    var items: [ReportItem] = []
    items.reserveCapacity(Int(n))
    for i in 0..<n {
        var at = [Double](repeating: 0, count: 3)
        guard cadaclysm_blacksmith_report_at(raw, i, &at) else { throw failure("report_at") }
        let region = try Profile.list(cadaclysm_blacksmith_report_region(raw, i), "report_region")
        items.append(ReportItem(kind: text(cadaclysm_blacksmith_report_kind(raw, i)),
                                 at: SIMD3(at[0], at[1], at[2]),
                                 size: cadaclysm_blacksmith_report_size(raw, i),
                                 top: cadaclysm_blacksmith_report_top(raw, i),
                                 bottom: cadaclysm_blacksmith_report_bottom(raw, i),
                                 reason: text(cadaclysm_blacksmith_report_reason(raw, i)),
                                 region: region))
    }
    return Report(items: items, text: text(cadaclysm_blacksmith_report_text(raw)))
}

/// Every operation of one `job_operations` call, read field by field, the list freed.
private func readOperations(_ raw: OpaquePointer) -> [Operation] {
    defer { cadaclysm_blacksmith_operations_free(raw) }
    let n = cadaclysm_blacksmith_operations_count(raw)
    return (0..<n).map { i -> Operation in
        let paramCount = cadaclysm_blacksmith_operations_param_count(raw, i)
        var params: [String: Double?] = [:]
        for k in 0..<paramCount {
            let name = text(cadaclysm_blacksmith_operations_param_name(raw, i, k))
            let value = cadaclysm_blacksmith_operations_param_value(raw, i, k)
            params.updateValue(value.isNaN ? nil : value, forKey: name)
        }
        return Operation(kind: text(cadaclysm_blacksmith_operations_kind(raw, i)),
                          tool: Int(cadaclysm_blacksmith_operations_tool(raw, i)),
                          params: params)
    }
}

/// A machining job on a `Stock`: operations kept in the order they are added, written as one
/// Grbl 1.1 program per run of operations sharing a tool. Mutable -- each operation is added
/// in place, and a refused one leaves the job as it was. `safeZ` is the absolute Z of rapids
/// between operations and at a program's start and end, above the stock's top; `clearance`
/// is how far above an operation's top it enters and leaves its passes; `tolerance` fits
/// free-form sides and offsets; `name` names the programs (`<name>-T<n>`); `spindleDwell` is
/// how long every program waits after starting the spindle; `resolution` is the CAMotics
/// project's voxel size in mm. `close()` frees it now; `deinit` does otherwise, as `Solid`'s.
public final class Job {
    private var handle: OpaquePointer?

    /// An empty job on `stock`, rapids at `safeZ` (above the stock's top), with the
    /// library's own defaults (`clearance` 1, `tolerance` 0.01, `name` "job",
    /// `spindleDwell` 2 s, `resolution` 0.1 mm) until overridden here. Throws for a `safeZ`
    /// not above the stock's top, or a setting the job refuses.
    public init(_ stock: Stock, safeZ: Double, clearance: Double = 1.0, tolerance: Double = 0.01,
               name: String = "job", spindleDwell: Double = 2.0, resolution: Double = 0.1) throws {
        guard !name.utf8.contains(0) else { throw BuildError(jobNulName) }
        let raw = cadaclysm_blacksmith_job_new(stock.handle, safeZ)
        handle = try checked(raw, "job_new")
        guard cadaclysm_blacksmith_job_set_clearance(handle, clearance) else {
            let error = failure("job_set_clearance"); close(); throw error
        }
        guard cadaclysm_blacksmith_job_set_tolerance(handle, tolerance) else {
            let error = failure("job_set_tolerance"); close(); throw error
        }
        guard cadaclysm_blacksmith_job_set_spindle_dwell(handle, spindleDwell) else {
            let error = failure("job_set_spindle_dwell"); close(); throw error
        }
        guard cadaclysm_blacksmith_job_set_resolution(handle, resolution) else {
            let error = failure("job_set_resolution"); close(); throw error
        }
        guard cadaclysm_blacksmith_job_set_name(handle, name) else {
            let error = failure("job_set_name"); close(); throw error
        }
    }

    deinit { close() }

    /// Free the job now. Idempotent; every call on the job throws after. Lists it wrote
    /// (`operations()`, `gcode()`, `writeCamotics`, a `Report`) are independent copies and
    /// outlive it.
    public func close() {
        if let handle { cadaclysm_blacksmith_job_free(handle) }
        handle = nil
    }

    /// Whether `close()` has run.
    public var isClosed: Bool { handle == nil }

    private func h() throws -> OpaquePointer {
        guard let handle else { throw BuildError("job: closed") }
        return handle
    }

    /// Face the stock's top down to `z`, in zigzag rows along X `stepover` apart and passes
    /// at most `stepdown` deep, with `tool`. Throws for a drill, a `z` above the stock's
    /// top, a stepover past the tool's diameter, or what the job otherwise refuses.
    public func face(_ tool: Tool, z: Double, stepover: Double, stepdown: Double) throws {
        guard cadaclysm_blacksmith_job_face(try h(), tool.handle, z, stepover, stepdown) else {
            throw failure("job_face")
        }
    }

    /// Cut along `profile` from `top` to `bottom` in passes at most `stepdown` deep, with
    /// `tool`: `side` "outside" the profile, "inside" it, or "on" its line; `climb` for
    /// climb milling, else conventional; `open` to cut the outline as an open chain (only
    /// "on" its line, and with no holes). Throws for any other `side`, or what the job
    /// otherwise refuses.
    public func contour(_ tool: Tool, profile: Profile, top: Double, bottom: Double, side: String = "outside",
                        stepdown: Double = 1.0, climb: Bool = true, open: Bool = false) throws {
        let code = try jobSide(side)
        guard cadaclysm_blacksmith_job_contour(try h(), tool.handle, profile.handle, top, bottom, code, stepdown,
                                               climb, open) else {
            throw failure("job_contour")
        }
    }

    /// Clear `profile` -- its holes left standing as islands -- from `top` to `bottom`, in
    /// rings `stepover` apart (at most the tool's radius) and passes at most `stepdown`
    /// deep, with `tool`. Throws for what the job refuses; a pocket too small for the tool
    /// is refused by `gcode()`, naming the operation.
    public func pocket(_ tool: Tool, profile: Profile, top: Double, bottom: Double, stepover: Double,
                       stepdown: Double) throws {
        guard cadaclysm_blacksmith_job_pocket(try h(), tool.handle, profile.handle, top, bottom, stepover,
                                              stepdown) else {
            throw failure("job_pocket")
        }
    }

    /// A hole at each (x, y) of `points`, from `top` to `bottom` with `tool`, pecking `peck`
    /// deep at a time (retracting between pecks), or straight to depth for `nil`. Throws for
    /// what the job refuses (a tool that is not a drill, no points, ...).
    public func drill(_ tool: Tool, points: [SIMD2<Double>], top: Double, bottom: Double, peck: Double? = nil) throws {
        let flat = points.flatMap { [$0.x, $0.y] }
        guard cadaclysm_blacksmith_job_drill(try h(), tool.handle, flat, points.count, top, bottom,
                                             peck ?? .nan) else {
            throw failure("job_drill")
        }
    }

    /// Recognise `part` and append the operations that make it: faced, contoured and
    /// pocketed with `endMill`, its holes drilled with whichever of `drills` fits each -- a
    /// tool per required diameter. A `nil` element of `drills` is the library's own "null
    /// drill <i>". `stepover` and `stepdown` of `nil` are the kernel's own defaults; `skin`
    /// (at least 0) is how far above the part's lowest point the outline stops, so the part
    /// stays attached to the stock -- 0 cuts through; `peck` of `nil` is none (a drill
    /// straight to depth). Returns a `Report` of what could not be cut. Throws for what the
    /// kernel refuses (a drill as `endMill`, a null drill, ...); the job changes only on
    /// success -- a refusal leaves it exactly as it was.
    public func machine(_ part: Solid, endMill: Tool, drills: [Tool?] = [], stepover: Double? = nil,
                        stepdown: Double? = nil, skin: Double = 0.3, peck: Double? = nil) throws -> Report {
        let jh = try h()
        let ph = try part.h()
        let handles: [OpaquePointer?] = drills.map { $0?.handle }
        let raw = withExtendedLifetime(drills) {
            cadaclysm_blacksmith_job_machine(jh, ph, endMill.handle, handles, handles.count, stepover ?? .nan,
                                             stepdown ?? .nan, skin, peck ?? .nan)
        }
        return try readReport(raw)
    }

    /// `machine` with a list of end mills, for rest machining: `endMills` run biggest first,
    /// each cutting what the one before left, and the `Report` lists what none could cut.
    /// Every other argument is `machine`'s. Throws for what the kernel refuses (an empty
    /// list, a tool not smaller than the one before, two sharing a number, a drill, ...); the
    /// job changes only on success.
    public func machine(_ part: Solid, endMills: [Tool], drills: [Tool?] = [], stepover: Double? = nil,
                        stepdown: Double? = nil, skin: Double = 0.3, peck: Double? = nil) throws -> Report {
        let jh = try h()
        let ph = try part.h()
        let ends: [OpaquePointer?] = endMills.map { $0.handle }
        let handles: [OpaquePointer?] = drills.map { $0?.handle }
        let raw = withExtendedLifetime((endMills, drills)) {
            cadaclysm_blacksmith_job_machine_with(jh, ph, ends, ends.count, handles, handles.count,
                                                  stepover ?? .nan, stepdown ?? .nan, skin, peck ?? .nan)
        }
        return try readReport(raw)
    }

    /// Every operation added to this job so far, in order -- whether added by `face`,
    /// `contour`, `pocket`, `drill` or `machine`.
    public func operations() throws -> [Operation] {
        guard let raw = cadaclysm_blacksmith_job_operations(try h()) else { throw failure("job_operations") }
        return readOperations(raw)
    }

    /// The job as Grbl 1.1 programs, one per run of consecutive operations sharing a tool
    /// (T1, T2, T1 gives three), each named `<name>-T<n>` (or `<name>-<k>-T<n>` for run `k`
    /// of a tool that runs more than once); an empty array for a job with no operations.
    /// Throws for an operation whose geometry the tool cannot cut (named by its index and
    /// kind).
    public func gcode() throws -> [Program] {
        try programs(cadaclysm_blacksmith_job_gcode(try h()), "job_gcode")
    }

    /// `job_camotics(stem)`, copied out.
    private func camoticsFiles(_ stem: String) throws -> [Program] {
        try programs(cadaclysm_blacksmith_job_camotics(try h(), stem), "job_camotics")
    }

    /// A CAMotics project at `path` and its files beside it, named after the project's file
    /// stem (`out/part.camotics` writes `out/part-T1.nc`), not the job's name: each program,
    /// a simulation copy of it (`.sim.nc`, which the project lists), and the project last.
    /// Creates the directory. Returns the paths written, the project last, written here (not
    /// by the library) byte for byte, as plain UTF-8 with no byte-order mark. Throws for a
    /// path with no file stem, what `gcode()` refuses, or a file that cannot be written.
    public func writeCamotics(_ path: String) throws -> [String] {
        // the stem is read off the text first: Foundation would take a NUL into the URL, and
        // Python refuses the stem, in the kernel's words
        let tail = path.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var tailStem = tail
        if let dot = tail.lastIndex(of: "."), dot != tail.startIndex { tailStem = String(tail[..<dot]) }
        if tailStem.utf8.contains(0) { throw BuildError(jobNulName) }
        let pathURL = URL(fileURLWithPath: path)
        let stem = pathURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { throw BuildError("job_camotics: \(path) has no file stem") }
        let files = try camoticsFiles(stem)
        let dirURL = pathURL.deletingLastPathComponent()
        if !dirURL.path.isEmpty {
            do {
                try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            } catch {
                throw BuildError("job_camotics: \(path): \(error.localizedDescription)")
            }
        }
        var written: [String] = []
        written.reserveCapacity(files.count)
        for (i, file) in files.enumerated() {
            let at = (i == files.count - 1) ? pathURL : dirURL.appendingPathComponent(file.name)
            do {
                try file.text.write(to: at, atomically: false, encoding: .utf8)
            } catch {
                throw BuildError("job_camotics: \(path): \(error.localizedDescription)")
            }
            written.append(at.path)
        }
        return written
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

// MARK: - Transform

private func xyz(_ p: SIMD3<Double>) -> [Double] { [p.x, p.y, p.z] }

/// `count` numbers for `what`, refused in its name otherwise.
func countedValues(_ values: [Double], _ count: Int, _ what: String) throws -> [Double] {
    guard values.count == count else { throw BuildError("\(what): expected \(count) numbers, got \(values.count)") }
    return values
}

/// `Transform.decomposeRigid`'s split: the map is `p -> orthogonal(p) + translation`.
public struct RigidParts: Equatable {
    public let translation: SIMD3<Double>
    /// The linear part: a rotation, or a rotation and a mirror.
    public let orthogonal: Transform
}

/// `Transform.decomposeSimilarity`'s split: the map is `p -> k · orthogonal(p) + translation`.
public struct SimilarityParts: Equatable {
    public let translation: SIMD3<Double>
    /// The linear part over `k`: a rotation, or a rotation and a mirror.
    public let orthogonal: Transform
    /// The scale, positive.
    public let k: Double
}

/// `Transform.decomposeAffine`'s polar split: the linear part is
/// `rotation · axes · diag(stretch) · axesᵀ`.
public struct AffineParts: Equatable {
    public let translation: SIMD3<Double>
    /// Orthogonal, and the one carrying the mirror if the map has one.
    public let rotation: Transform
    /// A proper rotation whose columns are the stretch directions.
    public let axes: Transform
    /// The stretches, largest first.
    public let stretch: SIMD3<Double>
}

/// An affine map of space: a 4×4 matrix, row-major, its bottom row `0 0 0 1`. A value with
/// nothing to free; `a * b` (and `compose`) is `a` after `b`. The constructors and the
/// decompositions are the library's own, so every wrapper computes them alike; `point` is local
/// arithmetic. Equality is by the 16 numbers. A frame argument is a `Frame`: one within 1e-6 of
/// right-handed and orthonormal is squared up by the library.
public struct Transform: Hashable, CustomStringConvertible {
    /// How far from rigid, or from a similarity, a map may be and still be told one, by default.
    public static let mapTolerance = 1e-9

    /// The 16 numbers, row-major.
    public let rows: [Double]

    /// The map that moves nothing.
    public init() {
        rows = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    }

    /// The map 16 numbers state, row-major. Throws `BuildError` for another count, a number not
    /// finite, or a bottom row other than `0 0 0 1`.
    public init(_ rows: [Double]) throws {
        guard rows.count == 16 else { throw BuildError("Transform: a matrix is 16 numbers, got \(rows.count)") }
        guard rows.allSatisfy({ $0.isFinite }) else { throw BuildError("Transform: not finite") }
        let r = rows.map { $0 + 0.0 } // no -0.0 to print or compare
        guard r[12] == 0, r[13] == 0, r[14] == 0, r[15] == 1 else {
            throw BuildError("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)")
        }
        self.rows = r
    }

    /// The map 16 numbers state, row-major.
    public static func fromRows(_ rows: [Double]) throws -> Transform { try Transform(rows) }

    /// The map four rows of four state, checked as `fromRows` checks.
    public static func fromRows(_ rows: [[Double]]) throws -> Transform {
        guard rows.count == 4, rows.allSatisfy({ $0.count == 4 }) else {
            throw BuildError("Transform: a matrix is 16 numbers, got \(rows.reduce(0) { $0 + $1.count })")
        }
        return try Transform(rows.flatMap { $0 })
    }

    /// The map that moves nothing.
    public static var identity: Transform { Transform() }

    private static func made(_ what: String, _ call: (UnsafeMutablePointer<Double>) -> Bool) throws -> Transform {
        var out = [Double](repeating: 0, count: 16)
        guard out.withUnsafeMutableBufferPointer({ call($0.baseAddress!) }) else { throw failure(what) }
        return try Transform(out)
    }

    /// `p + v`.
    public static func translation(_ v: SIMD3<Double>) throws -> Transform {
        try made("transform_translation") { cadaclysm_blacksmith_transform_translation(xyz(v), $0) }
    }

    /// A turn of `radians` about `axis` (a point and a direction), right-handed.
    public static func rotation(_ axis: (origin: SIMD3<Double>, direction: SIMD3<Double>), _ radians: Double) throws -> Transform {
        try made("transform_rotation") { cadaclysm_blacksmith_transform_rotation(axisValues(axis), radians, $0) }
    }

    /// The reflection across `plane`, its z the normal.
    public static func mirror(_ plane: Frame) throws -> Transform { try mirror(raw: plane.values) }

    static func mirror(raw plane: [Double]) throws -> Transform {
        let plane = try frameValues(plane)
        return try made("transform_mirror") { cadaclysm_blacksmith_transform_mirror(plane, $0) }
    }

    /// A uniform scale by `k` about `centre`.
    public static func scale(_ centre: SIMD3<Double>, _ k: Double) throws -> Transform {
        try made("transform_scale") { cadaclysm_blacksmith_transform_scale(xyz(centre), k, $0) }
    }

    /// A scale by `sx`, `sy`, `sz` along `frame`'s axes, about its origin.
    public static func scaleXyz(_ frame: Frame, _ sx: Double, _ sy: Double, _ sz: Double) throws -> Transform {
        try made("transform_scale_xyz") { cadaclysm_blacksmith_transform_scale_xyz(frame.values, sx, sy, sz, $0) }
    }

    /// Every point slid along `direction` by `factor` times its height above `plane`.
    /// `direction` is normalised -- `factor` alone sets the slide -- and must lie in the plane.
    public static func shear(_ plane: Frame, _ direction: SIMD3<Double>, _ factor: Double) throws -> Transform {
        try made("transform_shear") { cadaclysm_blacksmith_transform_shear(plane.values, xyz(direction), factor, $0) }
    }

    /// The rigid map sending frame `a` onto frame `b`.
    public static func planeToPlane(_ a: Frame, _ b: Frame) throws -> Transform {
        try made("transform_plane_to_plane") { cadaclysm_blacksmith_transform_plane_to_plane(a.values, b.values, $0) }
    }

    /// Coordinates in frame `from` to coordinates in frame `to`: a change of basis.
    public static func changeBasis(_ from: Frame, _ to: Frame) throws -> Transform {
        try made("transform_change_basis") { cadaclysm_blacksmith_transform_change_basis(from.values, to.values, $0) }
    }

    /// The orthogonal projection onto `plane` -- singular by design.
    public static func planarProjection(_ plane: Frame) throws -> Transform {
        try made("transform_planar_projection") { cadaclysm_blacksmith_transform_planar_projection(plane.values, $0) }
    }

    /// The parallel projection onto `plane` along `direction`, which must not lie in it.
    public static func projectAlong(_ plane: Frame, _ direction: SIMD3<Double>) throws -> Transform {
        try made("transform_project_along") { cadaclysm_blacksmith_transform_project_along(plane.values, xyz(direction), $0) }
    }

    /// Where the map takes the point `p`.
    public func point(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let r = rows
        return SIMD3(r[0] * p.x + r[1] * p.y + r[2] * p.z + r[3],
                     r[4] * p.x + r[5] * p.y + r[6] * p.z + r[7],
                     r[8] * p.x + r[9] * p.y + r[10] * p.z + r[11])
    }

    /// This map after `other`: `a.compose(b).point(p) == a.point(b.point(p))`.
    public func compose(_ other: Transform) throws -> Transform {
        try Transform.made("transform_compose") { cadaclysm_blacksmith_transform_compose(rows, other.rows, $0) }
    }

    /// `a` after `b`, as `compose`.
    public static func * (a: Transform, b: Transform) throws -> Transform { try a.compose(b) }

    /// The map undoing this one; throws `BuildError` for a singular map.
    public func inverse() throws -> Transform {
        try Transform.made("transform_inverse") { cadaclysm_blacksmith_transform_inverse(rows, $0) }
    }

    /// Whether the linear part is orthogonal (`AᵀA = I` to `tolerance`): a rotation or a mirror.
    /// `Solid.transform` is looser: it applies a map within 1e-6 of a similarity as that
    /// similarity.
    public func isRigid(tolerance: Double = Transform.mapTolerance) throws -> Bool {
        let r = cadaclysm_blacksmith_transform_is_rigid(rows, tolerance)
        if r == none { throw failure("transform_is_rigid") }
        return r == 1
    }

    /// The scale `k` where the linear part is `k` times an orthogonal one (`AᵀA = k²I` to
    /// `tolerance`, relative to `k²`), else nil.
    public func isSimilarity(tolerance: Double = Transform.mapTolerance) throws -> Double? {
        let k = cadaclysm_blacksmith_transform_is_similarity(rows, tolerance)
        if k.isNaN { throw failure("transform_is_similarity") }
        return k > 0 ? k : nil
    }

    private static func triple(_ v: [Double], _ at: Int) -> SIMD3<Double> { SIMD3(v[at], v[at + 1], v[at + 2]) }

    private static func block(_ v: [Double], _ at: Int) throws -> Transform { try Transform(Array(v[at..<(at + 16)])) }

    /// The translation and orthogonal part of a rigid map, else nil.
    public func decomposeRigid(tolerance: Double = Transform.mapTolerance) throws -> RigidParts? {
        guard try isRigid(tolerance: tolerance) else { return nil }
        var out = [Double](repeating: 0, count: 19)
        if !cadaclysm_blacksmith_transform_decompose_rigid(rows, tolerance, &out) { throw failure("transform_decompose_rigid") }
        return RigidParts(translation: Transform.triple(out, 0), orthogonal: try Transform.block(out, 3))
    }

    /// The translation, orthogonal part and scale `k` of a similarity, else nil.
    public func decomposeSimilarity(tolerance: Double = Transform.mapTolerance) throws -> SimilarityParts? {
        guard try isSimilarity(tolerance: tolerance) != nil else { return nil }
        var out = [Double](repeating: 0, count: 20)
        if !cadaclysm_blacksmith_transform_decompose_similarity(rows, tolerance, &out) {
            throw failure("transform_decompose_similarity")
        }
        return SimilarityParts(translation: Transform.triple(out, 0), orthogonal: try Transform.block(out, 3), k: out[19])
    }

    /// The polar split of the map (see `AffineParts`): `rotation` carries the mirror, `axes` is a
    /// proper rotation whose columns are the stretch directions, the stretches come largest
    /// first. Nil for a singular map, or one stretched past 1e7:1, which has no unique split.
    public func decomposeAffine() throws -> AffineParts? {
        var out = [Double](repeating: 0, count: 38)
        if !cadaclysm_blacksmith_transform_decompose_affine(rows, &out) { return nil }
        return AffineParts(translation: Transform.triple(out, 0), rotation: try Transform.block(out, 3),
                           axes: try Transform.block(out, 19), stretch: Transform.triple(out, 35))
    }

    public var description: String { "Transform(\(rows))" }
}

// MARK: - Quaternion

/// The largest magnitude among `vs`.
private func maxAbs(_ vs: ArraySlice<Double>) -> Double { vs.reduce(0) { Swift.max($0, abs($1)) } }

/// The length of `vs`, scaled by its largest component first, as the ABI's `quaternion_from`
/// does: squaring 1e200 overflows and 1e-170 underflows.
private func scaledNorm(_ vs: ArraySlice<Double>) -> Double {
    let big = maxAbs(vs)
    if big == 0 { return 0 }
    return big * vs.reduce(0) { $0 + ($1 / big) * ($1 / big) }.squareRoot()
}

/// A rotation as `w + xi + yj + zk`. Immutable. `q` and `-q` are the same rotation; a non-unit
/// one is normalised wherever it becomes a rotation, and a zero one throws `BuildError` there.
/// `a * b` turns by `b`, then `a`. Equality is by components, so `q != -q` although the two
/// turn alike: compare their `toTransform()` rows to a tolerance to ask that.
public struct Quaternion: Hashable, CustomStringConvertible {
    public let w: Double
    public let x: Double
    public let y: Double
    public let z: Double

    /// The identity.
    public init() { (w, x, y, z) = (1, 0, 0, 0) }

    /// `w + xi + yj + zk`; throws `BuildError` for a value not finite.
    public init(_ w: Double, _ x: Double, _ y: Double, _ z: Double) throws {
        guard w.isFinite, x.isFinite, y.isFinite, z.isFinite else { throw BuildError("Quaternion: not finite") }
        (self.w, self.x, self.y, self.z) = (w + 0.0, x + 0.0, y + 0.0, z + 0.0) // no -0.0 to print or compare
    }

    private static func made(_ what: String, _ call: (UnsafeMutablePointer<Double>) -> Bool) throws -> Quaternion {
        var out = [Double](repeating: 0, count: 4)
        guard out.withUnsafeMutableBufferPointer({ call($0.baseAddress!) }) else { throw failure(what) }
        return try Quaternion(out[0], out[1], out[2], out[3])
    }

    /// A turn of `radians` about `direction`, right-handed.
    public static func fromAxisAngle(_ direction: SIMD3<Double>, _ radians: Double) throws -> Quaternion {
        try made("quaternion_from_axis_angle") { cadaclysm_blacksmith_quaternion_from_axis_angle(xyz(direction), radians, $0) }
    }

    /// The rotation in `t`'s linear part (its translation ignored); throws `BuildError` unless
    /// that is a proper rotation, orthogonal to 1e-9. Take `t.decomposeAffine()`'s rotation
    /// first for a map rounded to float32.
    public static func fromTransform(_ t: Transform) throws -> Quaternion {
        try made("quaternion_from_transform") { cadaclysm_blacksmith_quaternion_from_transform(t.rows, $0) }
    }

    /// From `a` (`s = 0`) to `b` (`s = 1`) the shorter way.
    public static func slerp(_ a: Quaternion, _ b: Quaternion, _ s: Double) throws -> Quaternion {
        try made("quaternion_slerp") { cadaclysm_blacksmith_quaternion_slerp(a.values, b.values, s, $0) }
    }

    /// This rotation as a `Transform` fixing `centre`.
    public func toTransform(_ centre: SIMD3<Double> = .zero) throws -> Transform {
        var out = [Double](repeating: 0, count: 16)
        if !cadaclysm_blacksmith_quaternion_to_transform(values, xyz(centre), &out) { throw failure("quaternion_to_transform") }
        return try Transform(out)
    }

    /// `w, x, y, z`.
    public var values: [Double] { [w, x, y, z] }

    /// Its length; 1 for a rotation as made here.
    public var length: Double { scaledNorm(values[...]) }

    /// The turn, in `[0, 2π]`.
    public var angle: Double { 2.0 * atan2(scaledNorm(values[1...]), w) }

    /// The turn's axis; nil for the identity.
    public var axis: SIMD3<Double>? {
        let big = maxAbs(values[1...])
        if big == 0 { return nil }
        let v = SIMD3(x, y, z) / big
        return v / (v * v).sum().squareRoot()
    }

    private init(finite w: Double, _ x: Double, _ y: Double, _ z: Double) {
        (self.w, self.x, self.y, self.z) = (w + 0.0, x + 0.0, y + 0.0, z + 0.0)
    }

    /// The opposite turn: `(w, -x, -y, -z)`.
    public func conjugate() -> Quaternion { Quaternion(finite: w, -x, -y, -z) }

    /// The same rotation at unit length, scaled by its largest component before the square root
    /// (as the ABI's `quaternion_from` does), so 1e200 and 1e-170 normalise.
    public func normalized() throws -> Quaternion {
        let big = maxAbs(values[...])
        if big == 0 { throw BuildError("Quaternion.normalized: the quaternion is zero") }
        let v = values.map { $0 / big }
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return try Quaternion(v[0] / n, v[1] / n, v[2] / n, v[3] / n)
    }

    /// The Hamilton product: turns by `b`, then `a`.
    public static func * (a: Quaternion, b: Quaternion) throws -> Quaternion {
        try Quaternion(a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
                       a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
                       a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                       a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
    }

    public var description: String { "Quaternion(\(w), \(x), \(y), \(z))" }
}

// MARK: - Value geometry

/// A parameter range `t0..t1`, in either order: `length` and `swapped` keep the order, the set
/// operations (`grown`, `union`, `intersect`) answer increasing. Immutable and hashable; plain
/// arithmetic here, checked against the same records as the kernel's own interval.
public struct Interval: Hashable, CustomStringConvertible {
    /// The two ends, as given.
    public let t0: Double
    public let t1: Double

    /// The range `t0..t1`; throws `BuildError` for an end that is not finite.
    public init(_ t0: Double, _ t1: Double) throws {
        guard t0.isFinite, t1.isFinite else { throw BuildError("Interval: not finite") }
        self.init(finite: t0, t1)
    }

    /// Two numbers the library or this module already holds finite.
    init(finite t0: Double, _ t1: Double) {
        self.t0 = t0 + 0.0 // no -0.0 to print or compare
        self.t1 = t1 + 0.0
    }

    /// Two numbers as an `Interval`; any other count throws.
    public static func of(_ values: [Double]) throws -> Interval {
        guard values.count == 2 else { throw BuildError("Interval: an interval is 2 numbers, got \(values.count)") }
        return try Interval(values[0], values[1])
    }

    /// `t1 - t0`: negative for a decreasing interval.
    public var length: Double { t1 - t0 }
    /// The middle, `(t0 + t1) / 2`.
    public var mid: Double { 0.5 * (t0 + t1) }
    /// The smaller end.
    public var min: Double { Swift.min(t0, t1) }
    /// The larger end.
    public var max: Double { Swift.max(t0, t1) }
    /// Whether `t0 < t1`.
    public var isIncreasing: Bool { t0 < t1 }
    /// Whether `t0 == t1`.
    public var isSingleton: Bool { t0 == t1 }

    /// The interval `t1..t0`.
    public func swapped() -> Interval { Interval(finite: t1, t0) }

    /// The increasing interval holding this one and `t`; throws for a `t` not finite.
    public func grown(_ t: Double) throws -> Interval { try Interval(Swift.min(min, t), Swift.max(max, t)) }

    /// The increasing interval holding this one and `o`.
    public func union(_ o: Interval) -> Interval { Interval(finite: Swift.min(min, o.min), Swift.max(max, o.max)) }

    /// The increasing overlap with `o`, nil where the two are apart; two that touch give a singleton.
    public func intersect(_ o: Interval) -> Interval? {
        let a = Swift.max(min, o.min), b = Swift.min(max, o.max)
        return a <= b ? Interval(finite: a, b) : nil
    }

    /// Whether `t` lies in the closed range, in either order.
    public func contains(_ t: Double) -> Bool { min <= t && t <= max }

    /// `t0 + s (t1 - t0)`: the fraction `s` of the way from `t0` (outside 0..1 extrapolates).
    public func parameterAt(_ s: Double) -> Double { t0 + s * (t1 - t0) }

    /// The fraction of the way `t` lies from `t0` toward `t1`; nil for a singleton.
    public func normalizedParameterAt(_ t: Double) -> Double? {
        let length = self.length
        return length != 0 ? (t - t0) / length : nil
    }

    public var description: String { "Interval(\(t0), \(t1))" }
}

/// The closest point of a curve value: its parameter `t`, the `point`, and `unique` -- false
/// where the answer is a fixed pick among equals (a point on a circle's axis, one equidistant
/// from an arc's two ends).
public struct CurveFoot: Hashable {
    public let t: Double
    public let point: SIMD3<Double>
    public let unique: Bool

    public init(_ t: Double, _ point: SIMD3<Double>, _ unique: Bool) {
        self.t = t
        self.point = point
        self.unique = unique
    }
}

/// The closest point of a surface value: its parameters `u`, `v`, the `point`, and `unique`
/// (false where the answer is a pick among equals, a sphere's centre).
public struct SurfaceFoot: Hashable {
    public let u: Double
    public let v: Double
    public let point: SIMD3<Double>
    public let unique: Bool

    public init(_ u: Double, _ v: Double, _ point: SIMD3<Double>, _ unique: Bool) {
        self.u = u
        self.v = v
        self.point = point
        self.unique = unique
    }
}

private func vdot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }

private func pointDistance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return vdot(d, d).squareRoot()
}

extension Frame {
    /// Twelve numbers the library handed back, already square: kept as they are.
    init(canonical values: [Double]) {
        self.values = values.map { $0 + 0.0 }
    }

    /// The same plane facing the other way: x and y swapped, z reversed.
    public func flipped() throws -> Frame { try Frame(origin, y, x, -z) }

    /// This frame turned `radians` about `axis` through its origin, right-handed
    /// (`Transform.rotation`).
    public func rotated(_ radians: Double, _ axis: SIMD3<Double>) throws -> Frame {
        let r = try Transform.rotation((origin, axis), radians).rows
        func turn(_ d: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(r[0] * d.x + r[1] * d.y + r[2] * d.z,
                  r[4] * d.x + r[5] * d.y + r[6] * d.z,
                  r[8] * d.x + r[9] * d.y + r[10] * d.z)
        }
        return try Frame(origin, turn(x), turn(y), turn(z))
    }

    /// The point `p` in this frame's coordinates.
    public func toLocal(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let d = p - origin
        return SIMD3(vdot(d, x), vdot(d, y), vdot(d, z))
    }

    /// How far `p` lies above the frame's plane, along its z: negative below.
    public func distanceTo(_ p: SIMD3<Double>) -> Double { vdot(p - origin, z) }

    /// The point `p` dropped onto the frame's plane along its z.
    public func closestPoint(_ p: SIMD3<Double>) -> SIMD3<Double> { p - distanceTo(p) * z }

    /// The least-squares plane through `points` (three or more, not all on one line) as a frame,
    /// and the largest distance any point lies off it. Fewer points, or points on one line, throw.
    public static func fit(_ points: [SIMD3<Double>]) throws -> (frame: Frame, deviation: Double) {
        let xyz = points.flatMap { [$0.x, $0.y, $0.z] }
        var out = [Double](repeating: 0, count: 12)
        var deviation = 0.0
        if !cadaclysm_blacksmith_frame_fit(xyz, points.count, &out, &deviation) { throw failure("frame_fit") }
        return (try Frame(values: out), deviation)
    }
}

/// The kinds the value arrays are tagged with (`CADACLYSM_BLACKSMITH_VALUE_*`).
private let valueLine = UInt32(CADACLYSM_BLACKSMITH_VALUE_LINE)
private let valueCircle = UInt32(CADACLYSM_BLACKSMITH_VALUE_CIRCLE)
private let valueArc = UInt32(CADACLYSM_BLACKSMITH_VALUE_ARC)
private let valueEllipse = UInt32(CADACLYSM_BLACKSMITH_VALUE_ELLIPSE)
private let valueSphere = UInt32(CADACLYSM_BLACKSMITH_VALUE_SPHERE)
private let valueCylinder = UInt32(CADACLYSM_BLACKSMITH_VALUE_CYLINDER)
private let valueCone = UInt32(CADACLYSM_BLACKSMITH_VALUE_CONE)
private let valueTorus = UInt32(CADACLYSM_BLACKSMITH_VALUE_TORUS)
private let valueCuboid = UInt32(CADACLYSM_BLACKSMITH_VALUE_CUBOID)

/// What every value type shares, for this file's helpers: its kind, its canonical array, and a
/// way back from an array the library handed over.
protocol ValueArray {
    static var kind: UInt32 { get }
    static var noun: String { get }
    var values: [Double] { get }
    init(canonical: [Double])
}

/// `values` checked and squared up by the library's `value_check`, after a count check in the
/// library's own words (`value_check: a circle is 13 numbers, got 12`).
private func checkedValues(_ kind: UInt32, _ noun: String, _ values: [Double]) throws -> [Double] {
    let n = Int(cadaclysm_blacksmith_value_size(kind))
    guard values.count == n else { throw BuildError("value_check: a \(noun) is \(n) numbers, got \(values.count)") }
    var out = [Double](repeating: 0, count: n)
    if !cadaclysm_blacksmith_value_check(kind, values, &out) { throw failure("value_check") }
    return out
}

/// `count` doubles written by `call`, or the library's refusal in `what`'s name.
private func valueOut(_ count: Int, _ what: String, _ call: (UnsafeMutablePointer<Double>) -> Bool) throws -> [Double] {
    var out = [Double](repeating: 0, count: count)
    guard out.withUnsafeMutableBufferPointer({ call($0.baseAddress!) }) else { throw failure(what) }
    return out
}

private func valueTriple(_ v: [Double], _ at: Int = 0) -> SIMD3<Double> { SIMD3(v[at], v[at + 1], v[at + 2]) }

private func valueDescription(_ name: String, _ fields: [(String, Any)]) -> String {
    "\(name)(" + fields.map { "\($0.0)=\($0.1)" }.joined(separator: ", ") + ")"
}

extension ValueArray {
    static func made(_ values: [Double]) throws -> Self { Self(canonical: try checkedValues(kind, noun, values)) }

    func valueBounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        let b = try valueOut(6, "value_bounds") { cadaclysm_blacksmith_value_bounds(Self.kind, values, $0) }
        return (valueTriple(b, 0), valueTriple(b, 3))
    }

    func valueTransform(_ t: Transform) throws -> Self {
        Self(canonical: try valueOut(values.count, "value_transform") {
            cadaclysm_blacksmith_value_transform(Self.kind, values, t.rows, $0)
        })
    }

    var valueFrame: Frame { Frame(canonical: Array(values[0..<12])) }

    // Curves.
    func curvePointAt(_ t: Double) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "curve_value_point_at") { cadaclysm_blacksmith_curve_value_point_at(Self.kind, values, t, $0) })
    }

    func curveTangentAt(_ t: Double) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "curve_value_tangent_at") { cadaclysm_blacksmith_curve_value_tangent_at(Self.kind, values, t, $0) })
    }

    func curveLength() throws -> Double {
        try valueOut(1, "curve_value_length") { cadaclysm_blacksmith_curve_value_length(Self.kind, values, $0) }[0]
    }

    func curveClosestPoint(_ p: SIMD3<Double>) throws -> CurveFoot {
        let f = try valueOut(5, "curve_value_closest_point") {
            cadaclysm_blacksmith_curve_value_closest_point(Self.kind, values, xyz(p), $0)
        }
        return CurveFoot(f[0], valueTriple(f, 1), f[4] != 0)
    }

    // Surfaces.
    func surfacePointAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "surface_value_point_at") { cadaclysm_blacksmith_surface_value_point_at(Self.kind, values, u, v, $0) })
    }

    func surfaceNormalAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "surface_value_normal_at") { cadaclysm_blacksmith_surface_value_normal_at(Self.kind, values, u, v, $0) })
    }

    func surfaceClosestPoint(_ p: SIMD3<Double>) throws -> SurfaceFoot {
        let f = try valueOut(6, "surface_value_closest_point") {
            cadaclysm_blacksmith_surface_value_closest_point(Self.kind, values, xyz(p), $0)
        }
        return SurfaceFoot(f[0], f[1], valueTriple(f, 2), f[5] != 0)
    }

    func surfaceDomain() throws -> (u: Interval, v: Interval) {
        let d = try valueOut(4, "surface_value_domain") { cadaclysm_blacksmith_surface_value_domain(Self.kind, values, $0) }
        return (Interval(finite: d[0], d[1]), Interval(finite: d[2], d[3]))
    }

    func surfaceNurbsSheet() throws -> Solid {
        try Solid(cadaclysm_blacksmith_surface_value_nurbs_sheet(Self.kind, values), "surface_value_nurbs_sheet")
    }

    // Shapes with a volume.
    func solidContains(_ p: SIMD3<Double>, _ tolerance: Double) throws -> Bool {
        let r = cadaclysm_blacksmith_solid_value_contains(Self.kind, values, xyz(p), tolerance)
        if r == none { throw failure("solid_value_contains") }
        return r == 1
    }

    func solidArea() throws -> Double {
        try valueOut(1, "solid_value_area") { cadaclysm_blacksmith_solid_value_area(Self.kind, values, $0) }[0]
    }

    func solidVolume() throws -> Double {
        try valueOut(1, "solid_value_volume") { cadaclysm_blacksmith_solid_value_volume(Self.kind, values, $0) }[0]
    }

    func solidToSolid() throws -> Solid {
        try Solid(cadaclysm_blacksmith_solid_value_to_solid(Self.kind, values), "solid_value_to_solid")
    }
}

/// An edge's curve as a value (`Curve.value`): a line, a circle, an arc or an ellipse.
public enum CurveValue: Hashable {
    case line(Line)
    case circle(Circle)
    case arc(Arc)
    case ellipse(Ellipse)
}

/// The segment from `start` to `end`, as a value; its parameter runs 0..1. Immutable, with
/// nothing to free, equal and hashed by its numbers; the maths is the library's own.
public struct Line: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueLine
    static let noun = "line"
    /// The 6 numbers: `start`, then `end`.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The segment from `start` to `end`; ends that coincide throw.
    public init(_ start: SIMD3<Double>, _ end: SIMD3<Double>) throws { self = try .made(xyz(start) + xyz(end)) }
    /// The value 6 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The two ends.
    public var start: SIMD3<Double> { valueTriple(values, 0) }
    public var end: SIMD3<Double> { valueTriple(values, 3) }

    /// The point the fraction `t` of the way from `start` to `end`.
    public func pointAt(_ t: Double) throws -> SIMD3<Double> { try curvePointAt(t) }
    /// The unit tangent at `t`.
    public func tangentAt(_ t: Double) throws -> SIMD3<Double> { try curveTangentAt(t) }
    /// The length.
    public func length() throws -> Double { try curveLength() }
    /// The `CurveFoot` nearest `p`.
    public func closestPoint(_ p: SIMD3<Double>) throws -> CurveFoot { try curveClosestPoint(p) }
    /// How far `p` lies from the curve.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This line under `t`: any map that keeps its ends apart.
    public func transform(_ t: Transform) throws -> Line { try valueTransform(t) }

    public var description: String { valueDescription("Line", [("start", start), ("end", end)]) }
}

/// The circle of `radius` about the frame's origin in its x-y plane, counter-clockwise about its
/// z from its x, as a value.
public struct Circle: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueCircle
    static let noun = "circle"
    /// The 13 numbers: the frame's 12, then the radius.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The circle of `radius` on `frame`; a radius not positive throws.
    public init(_ frame: Frame, _ radius: Double) throws { self = try .made(frame.values + [radius]) }
    /// The value 13 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The circle through `a`, `b` and `c`: its x toward `a`, turning `a`, `b`, `c`
    /// counter-clockwise. Three points on one line throw.
    public static func through(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) throws -> Circle {
        Circle(canonical: try valueOut(13, "circle_through") { cadaclysm_blacksmith_circle_through(xyz(a), xyz(b), xyz(c), $0) })
    }

    /// The frame the circle lies on.
    public var frame: Frame { valueFrame }
    /// The radius.
    public var radius: Double { values[12] }

    /// The point at the angle `t` from the frame's x toward its y.
    public func pointAt(_ t: Double) throws -> SIMD3<Double> { try curvePointAt(t) }
    /// The unit tangent at `t`.
    public func tangentAt(_ t: Double) throws -> SIMD3<Double> { try curveTangentAt(t) }
    /// The length.
    public func length() throws -> Double { try curveLength() }
    /// The `CurveFoot` nearest `p`; not `unique` on the axis.
    public func closestPoint(_ p: SIMD3<Double>) throws -> CurveFoot { try curveClosestPoint(p) }
    /// How far `p` lies from the curve.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This circle under a similarity `t` (`Ellipse.fromCircle` first for any other map).
    public func transform(_ t: Transform) throws -> Circle { try valueTransform(t) }

    public var description: String { valueDescription("Circle", [("frame", frame), ("radius", radius)]) }
}

/// The part of a circle over `angle` (increasing, by at most a full turn), as a value.
public struct Arc: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueArc
    static let noun = "arc"
    /// The 15 numbers: the frame's 12, the radius, then the angle's two ends.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The arc of `radius` on `frame` over `angle`.
    public init(_ frame: Frame, _ radius: Double, _ angle: Interval) throws {
        self = try .made(frame.values + [radius, angle.t0, angle.t1])
    }
    /// The arc of `radius` on `frame` over the angles `angle.0` to `angle.1`.
    public init(_ frame: Frame, _ radius: Double, _ angle: (Double, Double)) throws {
        try self.init(frame, radius, try Interval(angle.0, angle.1))
    }
    /// The value 15 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The arc from `a` through `b` to `c`. Three points on one line throw.
    public static func through(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) throws -> Arc {
        Arc(canonical: try valueOut(15, "arc_through") { cadaclysm_blacksmith_arc_through(xyz(a), xyz(b), xyz(c), $0) })
    }

    /// The arc leaving `a` along `tangent` and ending at `c`. A zero tangent, or a `c` on the
    /// tangent's line, throws.
    public static func fromStartTangentEnd(_ a: SIMD3<Double>, _ tangent: SIMD3<Double>, _ c: SIMD3<Double>) throws -> Arc {
        Arc(canonical: try valueOut(15, "arc_from_start_tangent_end") {
            cadaclysm_blacksmith_arc_from_start_tangent_end(xyz(a), xyz(tangent), xyz(c), $0)
        })
    }

    /// The frame the arc's circle lies on.
    public var frame: Frame { valueFrame }
    /// The radius.
    public var radius: Double { values[12] }
    /// The angle range.
    public var angle: Interval { Interval(finite: values[13], values[14]) }
    /// The points at the start, the end and halfway along.
    public var start: SIMD3<Double> { get throws { try pointAt(values[13]) } }
    public var end: SIMD3<Double> { get throws { try pointAt(values[14]) } }
    public var mid: SIMD3<Double> { get throws { try pointAt(0.5 * (values[13] + values[14])) } }

    /// The point at the angle `t` from the frame's x toward its y.
    public func pointAt(_ t: Double) throws -> SIMD3<Double> { try curvePointAt(t) }
    /// The unit tangent at `t`.
    public func tangentAt(_ t: Double) throws -> SIMD3<Double> { try curveTangentAt(t) }
    /// The length.
    public func length() throws -> Double { try curveLength() }
    /// The `CurveFoot` nearest `p`; not `unique` where the arc's two ends are equally near.
    public func closestPoint(_ p: SIMD3<Double>) throws -> CurveFoot { try curveClosestPoint(p) }
    /// How far `p` lies from the curve.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This arc under a similarity `t`.
    public func transform(_ t: Transform) throws -> Arc { try valueTransform(t) }

    public var description: String { valueDescription("Arc", [("frame", frame), ("radius", radius), ("angle", angle)]) }
}

/// The ellipse of radius `r1` along the frame's x and `r2` along its y, as a value.
public struct Ellipse: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueEllipse
    static let noun = "ellipse"
    /// The 14 numbers: the frame's 12, then `r1` and `r2`.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The ellipse of radii `r1` and `r2` on `frame`.
    public init(_ frame: Frame, _ r1: Double, _ r2: Double) throws { self = try .made(frame.values + [r1, r2]) }
    /// The value 14 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// `circle` as an ellipse of two equal radii, to map by a non-uniform scale or a shear.
    public static func fromCircle(_ circle: Circle) throws -> Ellipse {
        Ellipse(canonical: try valueOut(14, "ellipse_from_circle") { cadaclysm_blacksmith_ellipse_from_circle(circle.values, $0) })
    }

    /// The frame the ellipse lies on.
    public var frame: Frame { valueFrame }
    /// The radii along the frame's x and y.
    public var r1: Double { values[12] }
    public var r2: Double { values[13] }

    /// The point at the eccentric angle `t`.
    public func pointAt(_ t: Double) throws -> SIMD3<Double> { try curvePointAt(t) }
    /// The unit tangent at `t`.
    public func tangentAt(_ t: Double) throws -> SIMD3<Double> { try curveTangentAt(t) }
    /// The perimeter, in closed form.
    public func length() throws -> Double { try curveLength() }
    /// The `CurveFoot` nearest `p`.
    public func closestPoint(_ p: SIMD3<Double>) throws -> CurveFoot { try curveClosestPoint(p) }
    /// How far `p` lies from the curve.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This ellipse under any map that keeps it an ellipse.
    public func transform(_ t: Transform) throws -> Ellipse { try valueTransform(t) }

    public var description: String { valueDescription("Ellipse", [("frame", frame), ("r1", r1), ("r2", r2)]) }
}

/// The sphere of `radius` about the frame's origin, as a value: `u` the longitude from the
/// frame's x, `v` the latitude toward its z.
public struct Sphere: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueSphere
    static let noun = "sphere"
    /// The 13 numbers: the frame's 12, then the radius.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The sphere of `radius` about `frame`'s origin.
    public init(_ frame: Frame, _ radius: Double) throws { self = try .made(frame.values + [radius]) }
    /// The value 13 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The frame the sphere is placed on.
    public var frame: Frame { valueFrame }
    /// The radius.
    public var radius: Double { values[12] }

    /// The point at `(u, v)`.
    public func pointAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfacePointAt(u, v) }
    /// The outward unit normal at `(u, v)`.
    public func normalAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfaceNormalAt(u, v) }
    /// The `SurfaceFoot` nearest `p`; not `unique` at the centre.
    public func closestPoint(_ p: SIMD3<Double>) throws -> SurfaceFoot { try surfaceClosestPoint(p) }
    /// How far `p` lies from the surface.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The `u` and `v` ranges.
    public func domain() throws -> (u: Interval, v: Interval) { try surfaceDomain() }
    /// The surface alone, as an open sheet on its exact NURBS form.
    public func toNurbsSheet() throws -> Solid { try surfaceNurbsSheet() }
    /// Whether `p` lies inside the closed shape or within `tolerance` of it.
    public func contains(_ p: SIMD3<Double>, tolerance: Double = 1e-9) throws -> Bool { try solidContains(p, tolerance) }
    /// The boundary's area.
    public func area() throws -> Double { try solidArea() }
    /// The volume enclosed.
    public func volume() throws -> Double { try solidVolume() }
    /// The shape as a closed exact B-rep solid.
    public func toSolid() throws -> Solid { try solidToSolid() }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This sphere under a similarity `t`.
    public func transform(_ t: Transform) throws -> Sphere { try valueTransform(t) }

    public var description: String { valueDescription("Sphere", [("frame", frame), ("radius", radius)]) }
}

/// The capped cylinder of `radius` about the frame's z over `height` (increasing, along z), as
/// a value: `u` the angle from the frame's x, `v` the height.
public struct Cylinder: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueCylinder
    static let noun = "cylinder"
    /// The 15 numbers: the frame's 12, the radius, then the height's two ends.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The cylinder of `radius` about `frame`'s z over `height`.
    public init(_ frame: Frame, _ radius: Double, _ height: Interval) throws {
        self = try .made(frame.values + [radius, height.t0, height.t1])
    }
    /// The cylinder of `radius` about `frame`'s z from `height.0` to `height.1`.
    public init(_ frame: Frame, _ radius: Double, _ height: (Double, Double)) throws {
        try self.init(frame, radius, try Interval(height.0, height.1))
    }
    /// The value 15 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The frame the cylinder is placed on.
    public var frame: Frame { valueFrame }
    /// The radius.
    public var radius: Double { values[12] }
    /// The range along the frame's z.
    public var height: Interval { Interval(finite: values[13], values[14]) }

    /// The point at `(u, v)`.
    public func pointAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfacePointAt(u, v) }
    /// The outward unit normal at `(u, v)`.
    public func normalAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfaceNormalAt(u, v) }
    /// The `SurfaceFoot` nearest `p` on the side.
    public func closestPoint(_ p: SIMD3<Double>) throws -> SurfaceFoot { try surfaceClosestPoint(p) }
    /// How far `p` lies from the surface.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The `u` and `v` ranges.
    public func domain() throws -> (u: Interval, v: Interval) { try surfaceDomain() }
    /// The surface alone, as an open sheet on its exact NURBS form.
    public func toNurbsSheet() throws -> Solid { try surfaceNurbsSheet() }
    /// Whether `p` lies inside the closed shape or within `tolerance` of it.
    public func contains(_ p: SIMD3<Double>, tolerance: Double = 1e-9) throws -> Bool { try solidContains(p, tolerance) }
    /// The boundary's area, the caps included.
    public func area() throws -> Double { try solidArea() }
    /// The volume enclosed.
    public func volume() throws -> Double { try solidVolume() }
    /// The shape as a closed exact B-rep solid.
    public func toSolid() throws -> Solid { try solidToSolid() }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This cylinder under a similarity `t`.
    public func transform(_ t: Transform) throws -> Cylinder { try valueTransform(t) }

    public var description: String { valueDescription("Cylinder", [("frame", frame), ("radius", radius), ("height", height)]) }
}

/// The capped cone of base `radius` on the frame's x-y plane, its apex `height` up its z, as a
/// value: `u` the angle from the frame's x, `v` the height.
public struct Cone: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueCone
    static let noun = "cone"
    /// The 14 numbers: the frame's 12, the radius, then the height.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The cone of base `radius` on `frame`, its apex `height` up its z.
    public init(_ frame: Frame, _ radius: Double, _ height: Double) throws { self = try .made(frame.values + [radius, height]) }
    /// The value 14 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The frame the cone is placed on.
    public var frame: Frame { valueFrame }
    /// The base radius.
    public var radius: Double { values[12] }
    /// How far up the frame's z the apex lies.
    public var height: Double { values[13] }

    /// The point at `(u, v)`.
    public func pointAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfacePointAt(u, v) }
    /// The outward unit normal at `(u, v)`.
    public func normalAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfaceNormalAt(u, v) }
    /// The `SurfaceFoot` nearest `p` on the side.
    public func closestPoint(_ p: SIMD3<Double>) throws -> SurfaceFoot { try surfaceClosestPoint(p) }
    /// How far `p` lies from the surface.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The `u` and `v` ranges.
    public func domain() throws -> (u: Interval, v: Interval) { try surfaceDomain() }
    /// The surface alone, as an open sheet on its exact NURBS form.
    public func toNurbsSheet() throws -> Solid { try surfaceNurbsSheet() }
    /// Whether `p` lies inside the closed shape or within `tolerance` of it.
    public func contains(_ p: SIMD3<Double>, tolerance: Double = 1e-9) throws -> Bool { try solidContains(p, tolerance) }
    /// The boundary's area, the base included.
    public func area() throws -> Double { try solidArea() }
    /// The volume enclosed.
    public func volume() throws -> Double { try solidVolume() }
    /// The shape as a closed exact B-rep solid.
    public func toSolid() throws -> Solid { try solidToSolid() }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This cone under a similarity `t`.
    public func transform(_ t: Transform) throws -> Cone { try valueTransform(t) }

    public var description: String { valueDescription("Cone", [("frame", frame), ("radius", radius), ("height", height)]) }
}

/// The torus of `major` radius about the frame's z and `minor` radius about that circle, as a
/// value: `u` the angle about the z from the frame's x, `v` the angle about the tube.
public struct Torus: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueTorus
    static let noun = "torus"
    /// The 14 numbers: the frame's 12, then `major` and `minor`.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The torus of `major` and `minor` radii on `frame`.
    public init(_ frame: Frame, _ major: Double, _ minor: Double) throws { self = try .made(frame.values + [major, minor]) }
    /// The value 14 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The frame the torus is placed on.
    public var frame: Frame { valueFrame }
    /// The radius of the tube's centre circle, and the tube's own.
    public var major: Double { values[12] }
    public var minor: Double { values[13] }

    /// The point at `(u, v)`.
    public func pointAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfacePointAt(u, v) }
    /// The outward unit normal at `(u, v)`.
    public func normalAt(_ u: Double, _ v: Double) throws -> SIMD3<Double> { try surfaceNormalAt(u, v) }
    /// The `SurfaceFoot` nearest `p`.
    public func closestPoint(_ p: SIMD3<Double>) throws -> SurfaceFoot { try surfaceClosestPoint(p) }
    /// How far `p` lies from the surface.
    public func distanceTo(_ p: SIMD3<Double>) throws -> Double { pointDistance(try closestPoint(p).point, p) }
    /// The `u` and `v` ranges.
    public func domain() throws -> (u: Interval, v: Interval) { try surfaceDomain() }
    /// The surface alone, as an open sheet on its exact NURBS form.
    public func toNurbsSheet() throws -> Solid { try surfaceNurbsSheet() }
    /// Whether `p` lies inside the closed shape or within `tolerance` of it.
    public func contains(_ p: SIMD3<Double>, tolerance: Double = 1e-9) throws -> Bool { try solidContains(p, tolerance) }
    /// The boundary's area.
    public func area() throws -> Double { try solidArea() }
    /// The volume enclosed.
    public func volume() throws -> Double { try solidVolume() }
    /// The shape as a closed exact B-rep solid.
    public func toSolid() throws -> Solid { try solidToSolid() }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This torus under a similarity `t`.
    public func transform(_ t: Transform) throws -> Torus { try valueTransform(t) }

    public var description: String { valueDescription("Torus", [("frame", frame), ("major", major), ("minor", minor)]) }
}

/// The box over `x`, `y`, `z` (increasing) along its frame's axes, as a value: an oriented
/// bounding box, a region to test points against, a block to make a solid of.
public struct Cuboid: Hashable, CustomStringConvertible, ValueArray {
    static let kind = valueCuboid
    static let noun = "cuboid"
    /// The 18 numbers: the frame's 12, then `x`, `y` and `z`'s ends.
    public let values: [Double]
    init(canonical: [Double]) { values = canonical }

    /// The box over `x`, `y`, `z` along `frame`'s axes.
    public init(_ frame: Frame, _ x: Interval, _ y: Interval, _ z: Interval) throws {
        self = try .made(frame.values + [x.t0, x.t1, y.t0, y.t1, z.t0, z.t1])
    }
    /// The box over the pairs `x`, `y`, `z` along `frame`'s axes.
    public init(_ frame: Frame, _ x: (Double, Double), _ y: (Double, Double), _ z: (Double, Double)) throws {
        try self.init(frame, try Interval(x.0, x.1), try Interval(y.0, y.1), try Interval(z.0, z.1))
    }
    /// The value 18 numbers state, checked by the library.
    public init(values: [Double]) throws { self = try .made(values) }

    /// The world-aligned box from `min` to `max`; an empty or flat one throws.
    public static func fromBounds(_ min: SIMD3<Double>, _ max: SIMD3<Double>) throws -> Cuboid {
        Cuboid(canonical: try valueOut(18, "cuboid_from_bounds") { cadaclysm_blacksmith_cuboid_from_bounds(xyz(min), xyz(max), $0) })
    }

    /// The tightest box holding `points`, aligned to `frame`. No points, or points flat along
    /// one of the frame's axes, throw.
    public static func around(_ frame: Frame, _ points: [SIMD3<Double>]) throws -> Cuboid {
        let flat = points.flatMap { [$0.x, $0.y, $0.z] }
        return Cuboid(canonical: try valueOut(18, "cuboid_around") {
            cadaclysm_blacksmith_cuboid_around(frame.values, flat, points.count, $0)
        })
    }

    /// The frame the box is placed on.
    public var frame: Frame { valueFrame }
    /// The three ranges along the frame's axes.
    public var x: Interval { Interval(finite: values[12], values[13]) }
    public var y: Interval { Interval(finite: values[14], values[15]) }
    public var z: Interval { Interval(finite: values[16], values[17]) }

    /// The eight corners: the `z0` face counter-clockwise about the frame's z from `(x0, y0)`,
    /// then the `z1` face in the same order.
    public func corners() throws -> [SIMD3<Double>] {
        let c = try valueOut(24, "cuboid_corners") { cadaclysm_blacksmith_cuboid_corners(values, $0) }
        return stride(from: 0, to: 24, by: 3).map { valueTriple(c, $0) }
    }

    /// The point the fractions `sx`, `sy`, `sz` of the way along each range.
    public func pointAt(_ sx: Double, _ sy: Double, _ sz: Double) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "cuboid_point_at") { cadaclysm_blacksmith_cuboid_point_at(values, sx, sy, sz, $0) })
    }

    /// The closest point of the solid box to `p`: `p` itself where it lies inside.
    public func closestPoint(_ p: SIMD3<Double>) throws -> SIMD3<Double> {
        valueTriple(try valueOut(3, "cuboid_closest_point") { cadaclysm_blacksmith_cuboid_closest_point(values, xyz(p), $0) })
    }

    /// Whether `p` lies inside the box or within `tolerance` of it.
    public func contains(_ p: SIMD3<Double>, tolerance: Double = 1e-9) throws -> Bool { try solidContains(p, tolerance) }
    /// The boundary's area.
    public func area() throws -> Double { try solidArea() }
    /// The volume enclosed.
    public func volume() throws -> Double { try solidVolume() }
    /// The box as a closed exact B-rep solid.
    public func toSolid() throws -> Solid { try solidToSolid() }
    /// The exact world box, `(min, max)`.
    public func bounds() throws -> (min: SIMD3<Double>, max: SIMD3<Double>) { try valueBounds() }
    /// This box under a similarity `t`.
    public func transform(_ t: Transform) throws -> Cuboid { try valueTransform(t) }

    public var description: String { valueDescription("Cuboid", [("frame", frame), ("x", x), ("y", y), ("z", z)]) }
}

extension Curve {
    /// This curve as a value: a line a `Line` from `origin` to `origin + x`; a circle a `Circle`
    /// over a full turn, else the `Arc` over `t0..t1`; an ellipse its whole `Ellipse` (the range
    /// stays here); any other kind nil.
    public var value: CurveValue? {
        get throws {
            let frame = Frame(canonical: xyz(origin) + xyz(x) + xyz(y) + xyz(z))
            switch kind {
            case "line": return .line(try Line(origin, origin + x))
            case "circle":
                if t1 - t0 >= 2 * Double.pi - 1e-12 { return .circle(try Circle(frame, radius)) }
                return .arc(try Arc(frame, radius, try Interval(t0, t1)))
            case "ellipse": return .ellipse(try Ellipse(frame, radius, radius2))
            default: return nil
            }
        }
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
