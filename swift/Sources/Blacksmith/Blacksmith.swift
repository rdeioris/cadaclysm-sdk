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

    /// This outline with `hole` cut out of it.
    public func withHole(_ hole: Profile) throws -> Profile {
        try Profile(cadaclysm_blacksmith_profile_with_hole(handle, hole.handle))
    }

    /// This outline moved by (`dx`, `dy`).
    public func translate(_ dx: Double, _ dy: Double) throws -> Profile {
        try Profile(cadaclysm_blacksmith_translate_profile(handle, dx, dy))
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

    /// A circle of `radius` swept along `path`, square to its start -- Fusion's Pipe: a rod,
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
    /// join leaves where the two meet in a plane or on one cylinder (`mergeFlush`), as Fusion
    /// does -- off by default, so face and edge numbers stay as they were. `tolerance` is the
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

    /// This solid as STEP text (AP203 unless `schema` names another); see `writeStepText`.
    public func stepText(schema: String? = nil, unit: String = "mm") throws -> String {
        try writeStepText([self], schema: schema, unit: unit)
    }

    /// This solid written as a STEP file (AP203 unless `schema` names another); see
    /// `writeStep`.
    public func step(_ path: String, schema: String? = nil, unit: String = "mm") throws {
        try writeStep(path, [self], schema: schema, unit: unit)
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

    private func rgb(_ colour: String) throws -> SIMD3<Double> {
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
                found.append(Edge(Int(i), text(raw.kind), faces, segments))
            }
            return found
        }
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

    /// Face `face` pushed out by `distance` along its outward normal (pulled in, negative) the
    /// way Fusion and Rhino extrude a face: the prism over it joined on (cut out), and the
    /// flush faces merged -- a box's top raised is one taller box of six faces. A face on a
    /// cylinder, a cone, a sphere or a torus moves out along its normal instead, the surface a
    /// step out -- a boss fatter, a bore narrower, a dome fuller -- with the flat faces beside
    /// it carried along; any other curved face is refused. `tolerance` as `join`'s.
    public func pushPull(_ face: Int, _ distance: Double, tolerance: Double = 0.05) throws -> Solid {
        try Solid(cadaclysm_blacksmith_push_pull(try h(), try index32(face, "push_pull"), distance, tolerance, nil, nil))
    }

    /// Faces `faces` pushed out by `distance` together -- Fusion's press-pull on a selection:
    /// each by `pushPull`'s rule for it, one after another, each found again after the pushes
    /// before it renumbered the faces. A box's top and a side pushed 5 is the box 5 taller and
    /// 5 wider; a face on the same curved surface as one before it, and joined to it, moved
    /// with that one and is not pushed twice. No faces is refused.
    public func pushPull(_ faces: [Int], _ distance: Double, tolerance: Double = 0.05) throws -> Solid {
        let which = try indices32(faces, "push_pull")
        return try Solid(cadaclysm_blacksmith_push_pull_faces(try h(), which, which.count, distance, tolerance, nil, nil))
    }

    /// The round `face` belongs to -- a fillet's bands, balls and rim bands joined to that face
    /// -- made again at `radius`, as Fusion's press-pull on a fillet face: taken back to the
    /// sharp edges it replaced, and those rounded again. Rounds of straight edges between
    /// planes and of circular rims beside a plane.
    public func refillet(_ face: Int, _ radius: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_refillet(try h(), try index32(face, "refillet"), radius, tolerance))
    }

    /// The round `face` belongs to taken off, the faces beside it sharp again -- Fusion's
    /// delete of a fillet face. The same rounds as `refillet`.
    public func unfillet(_ face: Int) throws -> Solid {
        try Solid(cadaclysm_blacksmith_unfillet(try h(), try index32(face, "unfillet")))
    }

    /// The chamfer `face` belongs to -- its bevels, flat or round a rim, and the corner
    /// triangles joined to that face -- cut again at `distance`, as Fusion's press-pull on a
    /// chamfer face: taken back to the sharp edges it cut, and those bevelled again.
    public func rechamfer(_ face: Int, _ distance: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_rechamfer(try h(), try index32(face, "rechamfer"), distance, tolerance))
    }

    /// The chamfer `face` belongs to taken off, the faces beside it sharp again -- Fusion's
    /// delete of a chamfer face. The same chamfers as `rechamfer`.
    public func unchamfer(_ face: Int) throws -> Solid {
        try Solid(cadaclysm_blacksmith_unchamfer(try h(), try index32(face, "unchamfer")))
    }

    /// This sheet made a solid `thickness` thick -- Fusion's Thicken: its faces, their twins
    /// moved `thickness` along the faces' normals (against them for a negative thickness),
    /// and a wall round every open edge. A closed sheet thickens to a hollow.
    public func thicken(_ thickness: Double, tolerance: Double = 1e-6) throws -> Solid {
        try Solid(cadaclysm_blacksmith_thicken(try h(), thickness, tolerance, nil, nil))
    }

    /// This solid split by `tool` into bodies -- Fusion's Split Body: a closed `tool` gives the
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

/// One edge of a solid, as plain data: its index (what `Solid.fillet` takes), the curve
/// kind, the faces meeting on it, and its segments' ends.
public struct Edge: CustomStringConvertible {
    /// Its index -- what `Solid.fillet` and `Solid.chamfer` take.
    public let index: Int
    /// The curve: `"line"`, `"circle"`, `"ellipse"`, `"nurbs"` or `"other"`.
    public let kind: String
    /// The faces meeting on it, as face indices.
    public let faces: [Int]
    /// The two ends of each piece of the edge.
    public let segments: [(start: SIMD3<Double>, end: SIMD3<Double>)]

    public init(_ index: Int, _ kind: String, _ faces: [Int], _ segments: [(start: SIMD3<Double>, end: SIMD3<Double>)]) {
        self.index = index
        self.kind = kind
        self.faces = faces
        self.segments = segments
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

    /// The plane midway between the planes of frames a and b: halfway between parallel planes, on a's axes; for planes that meet, the plane bisecting them through the line they meet on, its x along that line -- Fusion's midplane.
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
