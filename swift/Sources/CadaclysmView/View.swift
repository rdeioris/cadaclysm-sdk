// CadaclysmView: draw through a view library (cadaclysm_view.h) opened at run time -- the
// terminal by default, the GPU window (cadaclysm_view, on wgpu) after
// ViewLibrary.useWgpu(), any other with ViewLibrary.use(path) or CADACLYSM_VIEW. Python's
// cadaclysm.view in Swift: View, Item, the library choice, pump. Nothing of the view is
// linked: CCadaclysmView carries view_loader.h, the table every call goes through.
//
// Errors: every failure throws a ViewError -- the library's own message ("the view library
// failed" when it left none), or this module's refusal in Python's words. A call on a closed
// View (or an Item of one) is "<cadaclysm_view_call>: the view is closed", and once the view's
// own window was closed "<cadaclysm_view_call>: the window is closed".
//
// Threads: a View belongs to the thread that made it (on macOS the main thread for a window
// of its own); another thread's call is refused, "<cadaclysm_view_call>: a view belongs to the
// thread that made it" ("close: ..." for close()). deinit destroys the view on its own
// thread; dropped on another, it is left, with what its items keep (Python's __del__).
//
// Colours: every colour argument is `any Colour` -- numbers (SIMD3<Float>, SIMD4<Float>) or
// text the view library reads itself ("#rgb", "#rrggbb", a CSS colour name), as in every
// wrapper.
//
// Lifetimes: an item shown by handle (showSolid, showScene, showNode) keeps its Solid or
// Scene alive until the item is removed or the view closed. Scene.close() first removes the
// items of this thread's views that show it; while a view of another thread still shows it
// the scene stays open (leak rather than crash). Closing a Solid yourself while it is shown is
// a use-after-free in the library. show() and view() draw in a view of their own that
// Scene.close() does not see while they run: do not close the Scene they draw (a Node's or a
// Pose's included) from another thread meanwhile.
import CCadaclysmView
import Foundation

/// What a view library refused, in its own words, or this module's refusal.
public struct ViewError: Error, CustomStringConvertible, Equatable, LocalizedError {
    /// The message.
    public let message: String
    /// An error carrying `message`.
    public init(_ message: String) { self.message = message }
    /// The message.
    public var description: String { message }
    /// The message, for `localizedDescription`.
    public var errorDescription: String? { message }
}

// ---- C text and buffers ----------------------------------------------------------------------

/// A NUL-terminated buffer as a String.
func text(_ buffer: [CChar]) -> String { buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }

/// A fixed C char array (a tuple) as a String.
func cString<T>(_ tuple: inout T) -> String {
    withUnsafePointer(to: &tuple) { $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) } }
}

/// The library's last message on this thread, or "" (the function pointer's result is an
/// optional C string).
func lastError(_ t: UnsafeMutablePointer<CvlTable>) -> String {
    t.pointee.last_error!().map { String(cString: $0) } ?? ""
}

/// The library's last message, or Python's fallback when it left none.
func libraryError(_ t: UnsafeMutablePointer<CvlTable>) -> ViewError {
    let said = lastError(t)
    return ViewError(said.isEmpty ? "the view library failed" : said)
}

/// Runs `body` with `strings` as a C array of C strings, freed after.
func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) throws -> R) rethrows -> R {
    let owned = strings.map { strdup($0) }
    defer { owned.forEach { free($0) } }
    let array: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) }
    return try array.withUnsafeBufferPointer { try body($0.baseAddress, strings.count) }
}

/// `s` as Python's repr shows it: single quotes (double ones when it holds a single quote and
/// no double one), backslash, the quote, \n, \r and \t escaped, any other control character
/// as \xNN -- the refusals' words are Python's.
func quoted(_ s: String) -> String {
    let q: Character = s.contains("'") && !s.contains("\"") ? "\"" : "'"
    var out = String(q)
    for u in s.unicodeScalars {
        switch u {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if Character(u) == q {
                out += "\\" + String(q)
            } else if u.value < 0x20 || u.value == 0x7f {
                let hex = String(u.value, radix: 16)
                out += "\\x" + (hex.count < 2 ? "0" + hex : hex)
            } else {
                out.unicodeScalars.append(u)
            }
        }
    }
    out.append(q)
    return out
}

/// The text showText and setText pass as a C string: a NUL would end it there, silently
/// (withCString cuts it) -- refused instead, in Python's words.
func checkedText(_ text: String) throws -> String {
    if text.unicodeScalars.contains("\0") {
        throw ViewError("text \(quoted(text)): a NUL character cannot be shown (the C string ends there)")
    }
    return text
}

/// One element the library reads nothing through: an empty array reaches C as a non-NULL
/// pointer with count 0 (NULL means "none" to the library), as Python's empty arrays do.
private func standIn<T>(_ zero: T) -> UnsafeMutablePointer<T> {
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1)
    p.initialize(to: zero)
    return p
}
private let standInF32 = standIn(Float(0))
private let standInU32 = standIn(UInt32(0))
private let standInF64 = standIn(Double(0))
private let standInU8 = standIn(UInt8(0))

func withFloats<R>(_ a: [Float], _ body: (UnsafePointer<Float>) -> R) -> R {
    a.withUnsafeBufferPointer { body(a.isEmpty ? UnsafePointer(standInF32) : $0.baseAddress!) }
}
func withUInt32s<R>(_ a: [UInt32], _ body: (UnsafePointer<UInt32>) -> R) -> R {
    a.withUnsafeBufferPointer { body(a.isEmpty ? UnsafePointer(standInU32) : $0.baseAddress!) }
}
func withDoubles<R>(_ a: [Double], _ body: (UnsafePointer<Double>) -> R) -> R {
    a.withUnsafeBufferPointer { body(a.isEmpty ? UnsafePointer(standInF64) : $0.baseAddress!) }
}
func withBytes<R>(_ a: [UInt8], _ body: (UnsafePointer<UInt8>) -> R) -> R {
    a.withUnsafeBufferPointer { body(a.isEmpty ? UnsafePointer(standInU8) : $0.baseAddress!) }
}
/// An optional float array as a C `const float *`: NULL for nil (an empty array is non-NULL).
func withNormals<R>(_ a: [Float]?, _ body: (UnsafePointer<Float>?) -> R) -> R {
    guard let a else { return body(nil) }
    return withFloats(a) { body($0) }
}
/// An optional colour as a C `const float *`: NULL for nil.
func withColour<R>(_ c: [Float]?, _ body: (UnsafePointer<Float>?) -> R) -> R {
    guard let c else { return body(nil) }
    return c.withUnsafeBufferPointer { body($0.baseAddress) }
}

// ---- colours ---------------------------------------------------------------------------------

/// A colour argument, as Python's Colour: three numbers in 0..1 (`SIMD3<Float>`, or a
/// `[Float]` of three), four where a call takes an alpha (`SIMD4<Float>`, a `[Float]` of four;
/// a call that takes none reads the first three), or text -- a `String`: "#rgb", "#rrggbb"
/// (the "#" optional) or one of the 148 CSS colour names, any case, read by the view
/// library's own cadaclysm_view_parse_colour, so the forms are those of every wrapper. Text
/// (or three numbers) where an alpha is taken means an alpha of 1. Text the library refuses
/// throws its message; a type of one's own conformed to this is refused.
public protocol Colour {}
extension String: Colour {}
extension SIMD3: Colour where Scalar == Float {}
extension SIMD4: Colour where Scalar == Float {}
extension Array: Colour where Element == Float {}

/// Python's _colour, as the library takes it: four floats (r, g, b, a; a call that reads
/// three reads the first three). Text goes through the library's cadaclysm_view_parse_colour
/// (alpha 1) and is refused with its message, else Python's "colour '<text>'".
func colourValues(_ t: UnsafeMutablePointer<CvlTable>, _ c: any Colour) throws -> [Float] {
    switch c {
    case let s as String:
        var rgb: [Float] = [0, 0, 0]
        let parsed = s.withCString { text in rgb.withUnsafeMutableBufferPointer { t.pointee.parse_colour!(text, $0.baseAddress) } }
        if !parsed {
            let said = lastError(t)
            throw ViewError(said.isEmpty ? "colour '\(s)'" : said)
        }
        return rgb + [1]
    case let v as SIMD3<Float>:
        return [v.x, v.y, v.z, 1]
    case let v as SIMD4<Float>:
        return [v.x, v.y, v.z, v.w]
    case let a as [Float]:
        guard a.count == 3 || a.count == 4 else { throw ViewError("colour: 3 or 4 numbers, not \(a.count)") }
        return a.count == 3 ? a + [1] : a
    default:
        throw ViewError("colour \(c): numbers (SIMD3<Float>, SIMD4<Float>) or text, not a \(type(of: c))")
    }
}

/// cvl_check_abi, which every open runs on the library's cadaclysm_view_abi_version() first:
/// for the module's own test of the refusal.
func checkABIForTest(version: UInt32, path: String) throws {
    var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
    let errCount = err.count
    if cvl_check_abi(version, path, &err, errCount) == 0 { throw ViewError(text(err)) }
}

/// `n` as the library's u32, or the refusal of more.
func count(_ n: Int, _ what: String) throws -> UInt32 {
    if UInt64(n) > UInt64(UInt32.max) { throw ViewError("\(what): \(n) is too many for the library") }
    return UInt32(n)
}

/// width x height RGBA8 in bytes, checked: no product may wrap.
func pixelBytes(_ width: UInt32, _ height: UInt32, _ what: String) throws -> Int {
    let pixels = UInt64(width) * UInt64(height)  // < 2^64
    if pixels > UInt64(Int.max) / 4 { throw ViewError("\(what): \(width) x \(height) pixels is too large") }
    return Int(pixels * 4)
}

/// cvl_find, for the module's own test of the refusal.
func findForTest(stem: String, variable: String, what: String, dirs: [String]) throws -> String {
    var out = [CChar](repeating: 0, count: Int(CVL_PATH))
    var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
    let outCount = out.count, errCount = err.count
    let found = withCStrings(dirs) { array, count in
        cvl_find(stem, variable, what, array, count, &out, outCount, &err, errCount)
    }
    if found == 0 { throw ViewError(text(err)) }
    return text(out)
}

/// Appended to a create failure that says "no display" (cvl_create_failed).
private let noDisplay: UnsafePointer<CChar> =
    UnsafePointer(strdup(" -- draw without a display with View.offscreen, or the terminal (ViewLibrary.useTerminal())")!)

// ---- the library -----------------------------------------------------------------------------

/// A loaded view library. Never unloaded.
public final class ViewLibrary {
    /// cadaclysm_view_name(): "cadaclysm-view <version>", "cadaclysm-terminal <version>", ...
    public let name: String
    /// The file it was loaded from.
    public let path: String
    let table: UnsafeMutablePointer<CvlTable>
    /// Whether this is the terminal library.
    public var isTerminal: Bool { cvl_is_terminal(table) != 0 }
    /// Whether this is the GPU window, cadaclysm_view on wgpu: the one whose show() runs a
    /// window. Any other library prints a still for show().
    public var isWgpu: Bool { cvl_is_wgpu(table) != 0 }

    private init(table: UnsafeMutablePointer<CvlTable>) {
        self.table = table
        name = cString(&table.pointee.label)
        path = cString(&table.pointee.path)
    }

    // Mutable statics and globals here (and the tests' spies) are guarded by their locks;
    // Swift 6 language mode will want them marked nonisolated(unsafe).
    private static let lock = NSLock()
    private static var loaded: [String: ViewLibrary] = [:]
    static var chosen: ViewLibrary?  // the remembered library (internal: a test resets it)

    /// Package.swift's library directory, compiled in; the search's other places (the
    /// variable, beside the reader, beside the executable, the loader's path) are the loader's.
    static var searchDirs: [String] {
        let compiled = String(cString: ccadaclysm_view_library_dir())
        return compiled.isEmpty ? [] : [compiled]
    }

    /// Opens `which` ("terminal", "wgpu", a path; nil for the default).
    static func choose(_ which: String?, remember: Bool) throws -> ViewLibrary {
        lock.lock()
        defer { lock.unlock() }
        if which == nil, let chosen { return chosen }
        let table = UnsafeMutablePointer<CvlTable>.allocate(capacity: 1)
        table.initialize(to: CvlTable())
        var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
        let errCount = err.count
        let ok = withCStrings(searchDirs) { array, count -> Int32 in
            if let which { return cvl_use(table, which, array, count, &err, errCount) }
            return cvl_default(table, array, count, &err, errCount)
        }
        if ok == 0 {
            table.deallocate()
            throw ViewError(text(err))
        }
        let key = cString(&table.pointee.path)
        let library: ViewLibrary
        if let seen = loaded[key] {
            table.deallocate()
            library = seen
        } else {
            library = ViewLibrary(table: table)
            loaded[key] = library
        }
        if remember || chosen == nil { chosen = library }
        return library
    }

    /// Draw with the bundled terminal library from now on.
    @discardableResult public static func useTerminal() throws -> ViewLibrary { try choose("terminal", remember: true) }
    /// Draw with the GPU window, cadaclysm_view on wgpu, from now on.
    @discardableResult public static func useWgpu() throws -> ViewLibrary { try choose("wgpu", remember: true) }
    /// Draw with "terminal", "wgpu" or the view library at `which` (a path) from now on.
    @discardableResult public static func use(_ which: String) throws -> ViewLibrary {
        if which.isEmpty { throw ViewError("use: \"terminal\", \"wgpu\" or a path") }
        return try choose(which, remember: true)
    }
    /// The library in use: the last use*; else CADACLYSM_VIEW ("terminal", "wgpu" or a file);
    /// else the terminal. A failure is not remembered.
    public static func current() throws -> ViewLibrary { try choose(nil, remember: false) }
}

/// A font for every view of the library in use, from TTF/OTF bytes (copied in); its id for
/// showText's `font`. 0 is the bundled font and needs no loading. Bytes that are no font are
/// refused with the library's reason.
public func loadFont(_ bytes: [UInt8]) throws -> UInt32 {
    let t = try ViewLibrary.current().table
    let id = withBytes(bytes) { t.pointee.load_font!($0, bytes.count) }
    if id == 0 { throw libraryError(t) }
    return id
}
/// loadFont from the file at `path`; a file that cannot be read is refused naming it.
public func loadFont(path: String) throws -> UInt32 {
    guard let data = FileManager.default.contents(atPath: path) else {
        throw ViewError("\(path): the font could not be read")
    }
    return try loadFont([UInt8](data))
}

// ---- values ----------------------------------------------------------------------------------

/// The colour every edge, curve or isocurve draws in (view ABI 1.23), as Python's
/// `LineColour`: `colour` (0..1 RGB), or each part's own colour where `fromPart`.
public struct LineColour: Equatable {
    public var colour: SIMD3<Float>
    public var fromPart: Bool
    public init(colour: SIMD3<Float>, fromPart: Bool) {
        self.colour = colour; self.fromPart = fromPart
    }
}

/// How every "dashed" item's hidden lines and points look, as Python's `OccludedStyle`: a
/// dash and a gap in points, the share of coverage kept (above 0, at most 1), and optionally
/// one colour (0..1 RGB).
public struct OccludedStyle: Equatable {
    public var dash: Float
    public var gap: Float
    public var dim: Float
    public var colour: SIMD3<Float>?
    public init(dash: Float = 6, gap: Float = 4, dim: Float = 0.5, colour: SIMD3<Float>? = nil) {
        self.dash = dash; self.gap = gap; self.dim = dim; self.colour = colour
    }
}

/// One clip-plane slot (`View.setClipPlane`, 1.31), as Python's `ClipPlane`: what lies on the
/// side `normal` points to is hidden. `cap` fills the cut of every body (0..1 RGB, nil: none);
/// `hatch` draws parallel lines on the cap (needs `cap`): `hatchAngle` in degrees from the
/// plane's first axis, `hatchSpacing` in the scene's units (0: automatic, a fiftieth of the
/// scene's size), `hatchWidth` in points. 1.32: `outline` draws the cut as a line (0..1 RGB,
/// nil: none), `outlineWidth` points wide (0: 1, at most 100).
public struct ClipPlane: Equatable {
    public var point: SIMD3<Double>
    public var normal: SIMD3<Double>
    public var cap: SIMD3<Float>?
    public var hatch: SIMD3<Float>?
    public var hatchAngle: Float
    public var hatchSpacing: Float
    public var hatchWidth: Float
    public var outline: SIMD3<Float>?
    public var outlineWidth: Float
    public init(point: SIMD3<Double>, normal: SIMD3<Double>, cap: SIMD3<Float>? = nil, hatch: SIMD3<Float>? = nil,
                hatchAngle: Float = 45, hatchSpacing: Float = 0, hatchWidth: Float = 1,
                outline: SIMD3<Float>? = nil, outlineWidth: Float = 1) {
        self.point = point; self.normal = normal; self.cap = cap; self.hatch = hatch
        self.hatchAngle = hatchAngle; self.hatchSpacing = hatchSpacing; self.hatchWidth = hatchWidth
        self.outline = outline; self.outlineWidth = outlineWidth
    }

    /// The library's struct (120 bytes: the loader needs 1.32).
    var raw: CadaclysmViewClipPlane {
        var raw = CadaclysmViewClipPlane()
        raw.size = UInt32(MemoryLayout<CadaclysmViewClipPlane>.size)
        raw.point = (point.x, point.y, point.z)
        raw.normal = (normal.x, normal.y, normal.z)
        if let c = cap {
            raw.cap = 1
            raw.cap_colour = (c.x, c.y, c.z)
        }
        if let h = hatch {
            raw.hatch = 1
            raw.hatch_colour = (h.x, h.y, h.z)
        }
        raw.hatch_angle = hatchAngle
        raw.hatch_spacing = hatchSpacing
        raw.hatch_width = hatchWidth
        if let o = outline {
            raw.outline = 1
            raw.outline_colour = (o.x, o.y, o.z)
        }
        raw.outline_width = outlineWidth
        return raw
    }

    /// A library's answer.
    init(_ raw: CadaclysmViewClipPlane) {
        self.init(point: SIMD3(raw.point.0, raw.point.1, raw.point.2),
                  normal: SIMD3(raw.normal.0, raw.normal.1, raw.normal.2))
        if raw.cap != 0 { cap = SIMD3(raw.cap_colour.0, raw.cap_colour.1, raw.cap_colour.2) }
        if raw.hatch != 0 {
            hatch = SIMD3(raw.hatch_colour.0, raw.hatch_colour.1, raw.hatch_colour.2)
            hatchAngle = raw.hatch_angle
            hatchSpacing = raw.hatch_spacing
            hatchWidth = raw.hatch_width
        }
        if raw.outline != 0 {
            outline = SIMD3(raw.outline_colour.0, raw.outline_colour.1, raw.outline_colour.2)
            outlineWidth = raw.outline_width
        }
    }
}

/// How a clip set's planes combine (`View.setClipMode`, 1.32), the `CADACLYSM_VIEW_CLIP_*`
/// modes as raw values: `intersection` (the default) draws where every plane keeps, `cutaway`
/// hides only where every plane hides (two planes cut a quarter away). `inherit` is a
/// viewport's: no set of its own, the view-wide one.
public enum ClipMode: UInt32, CaseIterable, Sendable { case intersection = 0, cutaway = 1, inherit = 2 }

/// A points item's marker (`Item.setPointStyle`, 1.28): the `CADACLYSM_VIEW_POINT_*` shapes
/// as raw values.
public enum PointShape: UInt32, CaseIterable, Sendable { case disc = 0, ring = 1, square = 2, diamond = 3 }

/// One point's state (`Item.setPointStates`, 1.28): the `CADACLYSM_VIEW_POINT_STATE_*` codes
/// as raw values.
public enum PointState: UInt8, CaseIterable, Sendable { case normal = 0, hover = 1, selected = 2, first = 3 }

/// A glyph's kind (`View.showGlyphs`, 1.29): the `CADACLYSM_VIEW_GLYPH_*` kinds as raw values.
public enum GlyphKind: UInt32, CaseIterable, Sendable {
    case arrow = 0, tick, cross, square, triangle, parallel, perpendicular, coincident, tangent, fixed, horizontal, vertical
}

/// What is under a pixel: the item, the scene node (or a solid's 0) and the face; `clicks` 2
/// for a double click's pick, else 1; `point` where the ray met the model, in the coordinates
/// the items were shown in -- nil where the library read no depth (no hit, a machining stock,
/// the terminal library). `overlay` (1.24): the item is an overlay -- it was over the pixel,
/// so nothing of the scene beneath it was picked (`face` a text overlay's line, else 0).
/// `viewportLabel` (1.28): the viewport whose label (`View.setViewportLabel`) was over the
/// pixel -- `item` is then 0 -- else nil. `segment` and `distancePx` (1.30): a line, curve,
/// point or glyph within the pick aperture (`View.setPickAperture`) answers how many pixels it
/// lay from the cursor, and a wire its piece -- a lines item's segment, a curves item's Bezier,
/// a kernel solid's or read scene's kernel edge index; nil (and 0) for a face, a label or an
/// overlay, nil for a point or glyph (whose index is `node`).
public struct ViewPick: Equatable {
    public let item: UInt32, node: UInt32, face: UInt32
    public let clicks: UInt32
    public let point: SIMD3<Float>?
    public let overlay: Bool
    public let viewportLabel: Int?
    public let segment: UInt32?
    public let distancePx: Float
    init(item: UInt32, node: UInt32, face: UInt32, clicks: UInt32, point: SIMD3<Float>?, overlay: Bool,
         viewportLabel: Int? = nil, segment: UInt32? = nil, distancePx: Float = 0) {
        self.item = item; self.node = node; self.face = face; self.clicks = clicks; self.point = point
        self.overlay = overlay; self.viewportLabel = viewportLabel; self.segment = segment; self.distancePx = distancePx
    }
}

/// A raw pick for the library to fill: its size set, `viewport_label` -1 (no label hit) and
/// `segment` UINT32_MAX (1.30: no segment), so a library that writes neither answers none.
func rawPick() -> CadaclysmViewPick {
    var p = CadaclysmViewPick()
    p.size = UInt32(MemoryLayout<CadaclysmViewPick>.size)
    p.viewport_label = -1
    p.segment = UInt32.max
    return p
}

/// Whether a library's pick answer hit anything: an item, or a viewport's label.
func pickHit(_ p: CadaclysmViewPick) -> Bool { p.item != 0 || p.viewport_label >= 0 }

/// A library's pick answer as a ViewPick.
func pickOf(_ p: CadaclysmViewPick) -> ViewPick {
    ViewPick(item: p.item, node: p.node, face: p.face, clicks: p.clicks,
             point: p.has_point != 0 ? SIMD3(p.point.0, p.point.1, p.point.2) : nil, overlay: p.overlay != 0,
             viewportLabel: p.viewport_label >= 0 ? Int(p.viewport_label) : nil,
             segment: p.segment == UInt32.max ? nil : p.segment, distancePx: p.distance_px)
}

/// An input event's pick (`CadaclysmViewEventPick`, the 1.26 layout, which has no label) as
/// `pickOf` reads a pick, with the event's own `pick_viewport_label` as `label` and its 1.30
/// `pick_segment` and `pick_distance_px`.
func pickOf(_ p: CadaclysmViewEventPick, label: Int32, segment: UInt32 = UInt32.max, distancePx: Float = 0) -> ViewPick {
    ViewPick(item: p.item, node: p.node, face: p.face, clicks: p.clicks,
             point: p.has_point != 0 ? SIMD3(p.point.0, p.point.1, p.point.2) : nil, overlay: p.overlay != 0,
             viewportLabel: label >= 0 ? Int(label) : nil,
             segment: segment == UInt32.max ? nil : segment, distancePx: distancePx)
}

/// What a snap may land on, and what it landed on: Python's names, the `CADACLYSM_VIEW_SNAP_*`
/// bits as raw values. `centre` is a circular edge's centre. 1.30 added `end` (a lines or
/// curves item's piece ends), `intersection` (where two edges cross), `point` (an item's
/// `setSnapPoints`) and `alignment` (the guides through recent point snaps).
public enum SnapKind: UInt32, CaseIterable, Sendable {
    case vertex = 1, midpoint = 2, centre = 4, quadrant = 8, edge = 16, face = 32, grid = 64, plane = 128
    case end = 256, intersection = 512, point = 1024, alignment = 2048

    /// The kinds a view starts with (`CADACLYSM_VIEW_SNAP_DEFAULT`, 1.30): the 1.22 eight and
    /// `point`; `end`, `intersection` and `alignment` are opt-in.
    public static let defaultKinds: Set<SnapKind> = [.vertex, .midpoint, .centre, .quadrant, .edge, .face, .grid, .plane, .point]
}

/// What a snap found, as Python's `Snap`: its `kind`, the `point` snapped to, in world
/// coordinates, the item, node and face it lies on, its `edge` (nil for a face, grid or plane
/// snap), the edge's unit `tangent` there, a circular edge's `axis` and `radius` (zeros
/// otherwise), how many pixels the cursor was from it, and `clicks`: 0 for `snap` and a hover,
/// 1 for a click's snap, 2 for a double click's. 1.30: `label`, a `point` snap's label, else the
/// kind's lowercase name; `lockedAngle`, in degrees in 0..<360, where the angle lock
/// (`View.setSnapBase`) turned the answer, else nil; `guides`, 0 to 2 world segments: the
/// alignment guides from their trail points, or the lock's ray from its base.
public struct ViewSnap: Equatable {
    public let kind: SnapKind
    public let point: SIMD3<Double>
    public let item: UInt32, node: UInt32, face: UInt32
    public let edge: UInt32?
    public let tangent: SIMD3<Float>, axis: SIMD3<Float>
    public let radius: Double
    public let distancePx: Float
    public let clicks: UInt32
    public let label: String
    public let lockedAngle: Float?
    public let guides: [SnapGuide]
    init(kind: SnapKind, point: SIMD3<Double>, item: UInt32, node: UInt32, face: UInt32, edge: UInt32?,
         tangent: SIMD3<Float>, axis: SIMD3<Float>, radius: Double, distancePx: Float, clicks: UInt32,
         label: String = "", lockedAngle: Float? = nil, guides: [SnapGuide] = []) {
        self.kind = kind; self.point = point; self.item = item; self.node = node; self.face = face; self.edge = edge
        self.tangent = tangent; self.axis = axis; self.radius = radius; self.distancePx = distancePx; self.clicks = clicks
        self.label = label; self.lockedAngle = lockedAngle; self.guides = guides
    }
}

/// One snap guide (1.30): a world segment `from` a trail point (or the lock's base) `to` the
/// snapped point, three numbers each.
public struct SnapGuide: Equatable, Sendable {
    public let from: [Double]
    public let to: [Double]
    public init(from: [Double], to: [Double]) { self.from = from; self.to = to }
}

/// A library's snap answer as a ViewSnap; nil for kind 0 (nothing snapped).
func snapOf(_ s: CadaclysmViewSnap) -> ViewSnap? {
    guard let kind = SnapKind(rawValue: s.kind) else { return nil }
    let label = withUnsafeBytes(of: s.label) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let g = withUnsafeBytes(of: s.guides) { Array($0.bindMemory(to: Double.self)) }
    let guides = (0..<Int(min(s.guide_count, 2))).map { i in SnapGuide(from: Array(g[6 * i ..< 6 * i + 3]), to: Array(g[6 * i + 3 ..< 6 * i + 6])) }
    return ViewSnap(kind: kind, point: SIMD3(s.point.0, s.point.1, s.point.2), item: s.item, node: s.node, face: s.face,
                    edge: s.edge == UInt32.max ? nil : s.edge, tangent: SIMD3(s.tangent.0, s.tangent.1, s.tangent.2),
                    axis: SIMD3(s.axis.0, s.axis.1, s.axis.2), radius: s.radius, distancePx: s.distance_px,
                    clicks: s.clicks, label: label, lockedAngle: s.locked != 0 ? s.locked_angle : nil, guides: guides)
}

/// An input event's snap as `snapOf` reads a snap: the frozen 1.22 head
/// (`CadaclysmViewEventSnap`) with the event's own 1.30 `snap_*` tail.
func snapOf(_ e: CadaclysmViewInputEvent) -> ViewSnap? {
    var s = CadaclysmViewSnap()
    s.size = UInt32(MemoryLayout<CadaclysmViewSnap>.size)
    s.kind = e.snap.kind; s.point = e.snap.point; s.item = e.snap.item; s.node = e.snap.node; s.face = e.snap.face
    s.edge = e.snap.edge; s.tangent = e.snap.tangent; s.axis = e.snap.axis; s.radius = e.snap.radius
    s.distance_px = e.snap.distance_px; s.clicks = e.snap.clicks
    s.label = e.snap_label; s.locked = e.snap_locked; s.locked_angle = e.snap_locked_angle
    s.guide_count = e.snap_guide_count; s.guides = e.snap_guides
    return snapOf(s)
}

/// What a `RectHit` is (`CADACLYSM_VIEW_HIT_*`, 1.30): a face (numbered as a pick numbers it),
/// a node of an item with no face ranges, a lines item's segment or a curves item's Bezier, a
/// kernel solid's or read scene's edge (its kernel edge index), a point's or glyph's index.
public enum HitKind: UInt32, CaseIterable, Sendable { case face = 1, node, segment, edge, point }

/// One thing in a rectangle (`View.pickRect`, 1.30): its item, what it is and its index.
public struct RectHit: Equatable, Sendable {
    public let item: UInt32
    public let kind: HitKind
    public let index: UInt32
}

/// Where run()/view() left the camera (azimuth and elevation as ShowOptions takes them), and
/// what was last clicked (nil: nothing).
public struct Camera {
    public let eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>
    public let orthographic: Bool
    public let azimuth: Double, elevation: Double
    public let pick: ViewPick?
}

/// RGBA8, rows from the top.
public struct ViewImage {
    public let width: UInt32, height: UInt32
    public let rgba: [UInt8]
}

/// show()/view()'s keywords, as Python's: `view` front, back, left, right, top, bottom or iso
/// ("": iso); `azimuth`/`elevation` over it; `zoom` a multiple of the fit (0: the fit); `up`
/// (nil: the scene's own up axis, z for a solid); `edges`; the window's `width`/`height` (0:
/// the library's); `hint`, the terminal's graphics protocol for this draw; `title` ("": the
/// scene's file name, "Solid" for a solid); a solid's `tolerance` (nil: 0.05; refused for a
/// Scene, Node or Pose, which is drawn at the tolerance it was read with).
public struct ShowOptions {
    public var view: String
    public var azimuth: Double?
    public var elevation: Double?
    public var zoom: Double
    public var up: View.UpAxis?
    public var edges: Bool
    public var width: UInt32
    public var height: UInt32
    public var hint: String
    public var title: String
    public var tolerance: Double?
    public init(view: String = "", azimuth: Double? = nil, elevation: Double? = nil, zoom: Double = 0,
                up: View.UpAxis? = nil, edges: Bool = true, width: UInt32 = 0, height: UInt32 = 0,
                hint: String = "", title: String = "", tolerance: Double? = nil) {
        self.view = view; self.azimuth = azimuth; self.elevation = elevation; self.zoom = zoom; self.up = up
        self.edges = edges; self.width = width; self.height = height; self.hint = hint; self.title = title
        self.tolerance = tolerance
    }
}

func camera(_ c: CadaclysmViewCamera, _ p: CadaclysmViewPick, yUp: Bool) -> Camera {
    var cam = c
    var az = 0.0, el = 0.0
    cvl_angles(&cam, yUp ? 1 : 0, &az, &el)
    return Camera(eye: SIMD3(c.eye.0, c.eye.1, c.eye.2), target: SIMD3(c.target.0, c.target.1, c.target.2),
                  up: SIMD3(c.up.0, c.up.1, c.up.2), orthographic: c.orthographic != 0, azimuth: az, elevation: el,
                  pick: pickHit(p) ? pickOf(p) : nil)
}

/// Python's refusal of a tolerance for a document: "<Scene|Node|Pose>.<show|view> takes no
/// tolerance: ...".
package func refuseTolerance(_ kind: String, _ options: ShowOptions, interactive: Bool) throws {
    if options.tolerance == nil { return }
    throw ViewError("\(kind).\(interactive ? "view" : "show") takes no tolerance: a document is drawn at the tolerance it was read with")
}

/// The flow under Solid/Scene/Node/Pose show() and view(): a fresh view, the object by
/// handle, `transforms` (a Pose's, flattened: sixteen doubles a node) posing a scene, `focus`
/// narrowing a scene to one node (its siblings along the path hidden, it framed), then the
/// wgpu library runs its window for both modes and any other prints a still for show()
/// (`interactive` false) and runs for view(). cvl_draw_object flushes C stdio first (Swift's
/// print is stdio's). The view is destroyed before this returns.
package func drawObject(solid: OpaquePointer?, scene: OpaquePointer?, tolerance: Double, label: String,
                        defaultUp: View.UpAxis, focus: (node: UInt32, hide: [UInt32])?, options o: ShowOptions,
                        interactive: Bool, transforms: [Double]? = nil) throws -> Camera {
    let up = o.up ?? defaultUp
    let hide = focus?.hide ?? []
    let hideCount = try count(hide.count, "hide")
    let posedCount = try count((transforms?.count ?? 0) / 16, "node_transforms")
    let library = try ViewLibrary.current()
    var cam = CadaclysmViewCamera()
    cam.size = UInt32(MemoryLayout<CadaclysmViewCamera>.size)
    var pick = rawPick()
    var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
    let errCount = err.count
    let title = o.title.isEmpty ? label : o.title
    let ok = o.view.withCString { viewName in
        title.withCString { titleText in
            o.hint.withCString { hintText in
                withUInt32s(hide) { hidden in withDoubles(transforms ?? []) { moves -> Int32 in
                    var show = CvlShow()
                    show.view = o.view.isEmpty ? nil : viewName
                    show.title = titleText
                    show.hint = o.hint.isEmpty ? nil : hintText
                    show.width = o.width
                    show.height = o.height
                    show.y_up = up == .y ? 1 : 0
                    show.azimuth = o.azimuth ?? .nan
                    show.elevation = o.elevation ?? .nan
                    show.zoom = o.zoom
                    show.edges = o.edges ? 1 : 0
                    show.no_display = noDisplay
                    return cvl_draw_object(library.table, interactive ? 1 : 0, "iso", solid, tolerance, scene,
                                           transforms == nil ? nil : moves, posedCount, hidden, hideCount,
                                           focus?.node ?? CVL_NO_NODE, &show, &cam, &pick, &err, errCount)
                } }
            }
        }
    }
    if ok == 0 { throw ViewError(text(err)) }
    return camera(cam, pick, yUp: up == .y)
}

// ---- items -----------------------------------------------------------------------------------

/// One thing shown in a View. It keeps its view alive. (Not final: `Machining` is one.)
public class Item {
    /// The item's id, as a pick reports it.
    public let id: UInt32
    /// The view it is shown in.
    public let view: View
    init(view: View, id: UInt32) { self.view = view; self.id = id }

    func ok(_ call: String, _ f: (UnsafeMutablePointer<CvlTable>, OpaquePointer) -> Bool) throws {
        try view.ok(call, f)
    }
    /// Takes the item out of the view and lets go of what it showed.
    public func remove() throws {
        try ok("cadaclysm_view_remove") { t, v in t.pointee.remove!(v, id) }
        view.forget(id)
    }
    /// Paints the whole item: numbers or text (see Colour).
    public func setColour(_ rgb: any Colour) throws {
        let c = try view.paint("cadaclysm_view_set_colour", rgb)
        try ok("cadaclysm_view_set_colour") { t, v in withColour(c) { t.pointee.set_colour!(v, id, $0) } }
    }
    /// A column-major 4x4 (sixteen numbers), kept across uploads; nil takes it back.
    public func setPlacement(_ m: [Double]?) throws {
        if let m, m.count != 16 { throw ViewError("16 numbers, not \(m.count)") }
        try ok("cadaclysm_view_set_placement") { t, v in
            guard let m else { return t.pointee.set_placement!(v, id, nil) }
            return withDoubles(m) { t.pointee.set_placement!(v, id, $0) }
        }
    }
    /// Paints `faces` (the item's pick numbering), one colour each (see Colour; the alpha is
    /// not drawn); both empty: every face its own colour again.
    public func setFaceColours(_ faces: [UInt32], _ rgba: [any Colour]) throws {
        guard faces.count == rgba.count else {
            throw ViewError("\(4 * UInt64(faces.count)) numbers (rgba, 4 a face), not \(4 * UInt64(rgba.count))")
        }
        let n = try count(faces.count, "face_colours")
        if let no = view.refusal("cadaclysm_view_set_face_colours") { throw no }
        let flat = try rgba.flatMap { try colourValues(view.library.table, $0) }
        try ok("cadaclysm_view_set_face_colours") { t, v in
            withUInt32s(faces) { f in withFloats(flat) { c in t.pointee.set_face_colours!(v, id, f, c, n) } }
        }
    }
    /// A text item's string replaced, nothing else changed ("\n" starts a line). A NUL in it
    /// is refused before the library is called; an item that is not text, by the library.
    public func setText(_ text: String) throws {
        let s = try checkedText(text)
        try ok("cadaclysm_view_set_text") { t, v in s.withCString { t.pointee.set_text!(v, id, $0) } }
    }
    /// Fits the camera to this item.
    public func frame() throws { try ok("cadaclysm_view_frame") { t, v in t.pointee.frame!(v, id) } }
    /// Draws the item's triangles through whatever is in front of them.
    public func setXray(_ on: Bool) throws { try ok("cadaclysm_view_set_xray") { t, v in t.pointee.set_xray!(v, id, on) } }
    /// How the item's lines and points draw where a surface hides them.
    public enum Occluded: UInt32, Sendable { case off = 0, solid = 1, dashed = 2 }
    /// Sets how the item's lines and points draw where a surface hides them: not drawn (`off`, the
    /// default), drawn through (`solid`) or dashed and dimmed (`dashed`).
    public func setOccluded(_ mode: Occluded) throws { try ok("cadaclysm_view_set_occluded") { t, v in t.pointee.set_occluded!(v, id, mode.rawValue) } }
    /// Draws the item's lines in its own dash (1.28): `dash` points on, `gap` off; `dash` 0 is
    /// solid (the default). Refused for an overlay, a negative or non-finite length, one past
    /// 511.5, or a dash with no gap.
    public func setLineStyle(dash: Float = 0, gap: Float = 0) throws {
        try ok("cadaclysm_view_set_line_style") { t, v in t.pointee.set_line_style!(v, id, dash, gap) }
    }
    /// A points item's marker (1.28): `shape`, filled or `hollow`. Refused for an item that is
    /// not points.
    public func setPointStyle(_ shape: PointShape = .disc, hollow: Bool = false) throws {
        try ok("cadaclysm_view_set_point_style") { t, v in t.pointee.set_point_style!(v, id, shape.rawValue, hollow) }
    }
    /// A points item's per-point states (1.28), one a point in the order shown: hover and
    /// selected draw in their colour (`View.setPointStateColours`), first draws a ring round
    /// the point. Refused for an item that is not points or a count that is not its points'.
    public func setPointStates(_ states: [PointState]) throws {
        let codes = states.map(\.rawValue)
        try ok("cadaclysm_view_set_point_states") { t, v in
            withBytes(codes) { t.pointee.set_point_states!(v, id, $0, codes.count) }  // empty: non-NULL, count 0
        }
    }
    /// Draws the item after every other, through whatever is in front of it (1.28); false
    /// takes it back. Refused for an overlay, text, an image, a machining stock, or a body
    /// shown with exact surfaces (a `showCurves` item is accepted since 1.29: its exact edges
    /// draw on top).
    public func setOnTop(_ on: Bool = true) throws {
        try ok("cadaclysm_view_set_on_top") { t, v in t.pointee.set_on_top!(v, id, on) }
    }
    /// The points it snaps to as `SnapKind.point` (1.30), three numbers each, in the coordinates
    /// it was shown in, moving with its node 0; `label` (at most 31 bytes of UTF-8) is what the
    /// snap answers, nil (or "") answering "point". An empty array clears them. Any item that
    /// snaps takes them; text, glyph, image and machining items are refused, as are a label past
    /// 31 bytes and a value that is not finite. A count not in threes and a label holding a NUL
    /// are refused here, before the call.
    public func setSnapPoints(_ xyz: [Double], label: String? = nil) throws {
        if xyz.count % 3 != 0 { throw ViewError("set_snap_points: three numbers a point, not \(xyz.count)") }
        if let label, label.unicodeScalars.contains("\0") {
            throw ViewError("snap point label \(quoted(label)): a NUL character cannot be shown (the C string ends there)")
        }
        let points = xyz.map { Float($0) }
        try ok("cadaclysm_view_set_snap_points") { t, v in
            points.withUnsafeBufferPointer { p in
                let at = points.isEmpty ? nil : p.baseAddress  // none: NULL with a count of 0
                guard let label else { return t.pointee.set_snap_points!(v, id, at, points.count / 3, nil) }
                return label.withCString { t.pointee.set_snap_points!(v, id, at, points.count / 3, $0) }
            }
        }
    }
    /// Replaces a `showLines` item's segments under the same id (1.29), six floats (two points)
    /// each; colour, layer, dash, placement and on top kept, the camera not re-framed. An empty
    /// array empties it. Refused for an item that is not a lines item, or a value not finite.
    public func setLines(_ segments: [Float]) throws {
        if segments.count % 6 != 0 { throw ViewError("set_lines: two points a segment (6 numbers), not \(segments.count)") }
        try ok("cadaclysm_view_set_lines") { t, v in
            withFloats(segments) { t.pointee.set_lines!(v, id, $0, segments.count / 6) }  // empty: non-NULL, count 0
        }
    }
    /// Replaces a `showCurves` item's Beziers under the same id (1.29), sixteen floats (four
    /// x, y, z, w control points) each. Refused for an item that is not a curves item, a value
    /// not finite or a weight not positive.
    public func setCurves(_ beziers: [Float]) throws {
        if beziers.count % 16 != 0 {
            throw ViewError("set_curves takes four x, y, z, w control points (16 numbers) a curve, not \(beziers.count)")
        }
        try ok("cadaclysm_view_set_curves") { t, v in
            withFloats(beziers) { t.pointee.set_curves!(v, id, $0, beziers.count / 16) }
        }
    }
    /// Replaces a `showPoints` item's positions under the same id (1.29), three floats each. A
    /// new count keeps the states, node colours, highlights and hidden flags by index, the new
    /// points normal. Refused for an item that is not a points item.
    public func setPoints(_ positions: [Float]) throws {
        if positions.count % 3 != 0 { throw ViewError("set_points: three numbers a point, not \(positions.count)") }
        try ok("cadaclysm_view_set_points") { t, v in
            withFloats(positions) { t.pointee.set_points!(v, id, $0, positions.count / 3) }
        }
    }
    /// Moves a `showMesh` item's vertices (shown without edges) under the same id (1.29):
    /// `positions`, three floats a vertex, as many vertices as it was shown with, in the same
    /// order; `normals` (nil: recomputed) one a vertex. Colour, paint, look and placement kept.
    /// Refused for another count, or an item shown with edges.
    public func setMeshPositions(_ positions: [Float], normals: [Float]? = nil) throws {
        if positions.count % 3 != 0 { throw ViewError("set_mesh_positions: three numbers a vertex, not \(positions.count)") }
        if let normals, normals.count != positions.count {
            throw ViewError("set_mesh_positions: \(normals.count) normal numbers for \(positions.count) position numbers")
        }
        try ok("cadaclysm_view_set_mesh_positions") { t, v in
            withFloats(positions) { p in
                withNormals(normals) { t.pointee.set_mesh_positions!(v, id, p, $0, positions.count / 3) }
            }
        }
    }
    /// An item's finish under the lighting.
    public enum Finish: UInt32, Sendable { case gloss = 0, satin = 1, matte = 2 }
    /// Sets the item's finish: `gloss` (an item shows with this until it is set) -- under the
    /// showroom lighting a clear coat mirroring the room, silver at a grazing angle -- `satin` (a
    /// weaker, blurred coat) or `matte` (no mirror, a faint sheen: rubber, cloth). Uploads the scene
    /// again, as a show does: set it as each item is shown rather than over a finished scene item by
    /// item.
    public func setFinish(_ finish: Finish) throws { try ok("cadaclysm_view_set_finish") { t, v in t.pointee.set_finish!(v, id, finish.rawValue) } }
    /// Draws the item's edges in `rgb` (see Colour), over the view's `setEdgeColour`, the item's
    /// colour and a solid's own edge paint; nil takes the view's colour again.
    public func setEdgeColour(_ rgb: (any Colour)?) throws { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_EDGES), rgb) }
    /// Draws the item's curves in `rgb`, over the view's `setCurveColour` and the item's colour;
    /// nil takes the view's colour again.
    public func setCurveColour(_ rgb: (any Colour)?) throws { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_CURVES), rgb) }
    /// Draws the item's isocurves in `rgb`, over the view's `setIsocurveColour` and the item's
    /// colour; nil takes the view's colour again.
    public func setIsocurveColour(_ rgb: (any Colour)?) throws { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_ISOCURVES), rgb) }
    private func lineColour(_ layer: UInt32, _ rgb: (any Colour)?) throws {
        let c = try view.paint("cadaclysm_view_set_item_line_colour", rgb)
        try ok("cadaclysm_view_set_item_line_colour") { t, v in withColour(c) { t.pointee.set_item_line_colour!(v, id, layer, $0) } }
    }
    /// Puts the item on user layer `layer`, 0...31 (every item starts on 0): it draws while the
    /// layer is on (`View.userLayer`) and in the viewports whose `layerMask` has its bit. A
    /// layer past 31 is refused.
    public func setUserLayer(_ layer: UInt32) throws {
        try ok("cadaclysm_view_set_item_layer") { t, v in t.pointee.set_item_layer!(v, id, layer) }
    }
    /// Shows or hides a scene node (the reader's index) and its subtree.
    public func setNodeVisible(_ node: UInt32, _ on: Bool) throws {
        try ok("cadaclysm_view_set_node_visible") { t, v in t.pointee.set_node_visible!(v, id, node, on) }
    }
    /// Colours a node's subtree (see Colour; the alpha is not drawn); nil: the node's own colour.
    public func setNodeColour(_ node: UInt32, _ rgba: (any Colour)?) throws {
        let c = try view.paint("cadaclysm_view_set_node_color", rgba)
        try ok("cadaclysm_view_set_node_color") { t, v in withColour(c) { t.pointee.set_node_color!(v, id, node, $0) } }
    }
    /// Tints a node's subtree toward rgba's colour by its alpha (see Colour; text: alpha 1);
    /// nil clears.
    public func setNodeHighlight(_ node: UInt32, _ rgba: (any Colour)?) throws {
        let c = try view.paint("cadaclysm_view_set_node_highlight", rgba)
        try ok("cadaclysm_view_set_node_highlight") { t, v in withColour(c) { t.pointee.set_node_highlight!(v, id, node, $0) } }
    }
    /// Shows or hides the whole item (1.27): a hidden item draws nothing, is never picked or
    /// snapped, and is left out of the fit; it shows only when its layer is on too.
    public func setVisible(_ visible: Bool) throws {
        try ok("cadaclysm_view_set_item_visible") { t, v in t.pointee.set_item_visible!(v, id, visible) }
    }
    /// Draws these nodes of the item x-ray (1.27), replacing the ones ghosted before; nil (or an
    /// empty list) clears. A node the item does not have is refused in the library's words.
    public func setNodeGhosts(_ nodes: [UInt32]?) throws {
        guard let nodes else {
            return try ok("cadaclysm_view_set_node_ghosts") { t, v in t.pointee.set_node_ghosts!(v, id, nil, 0) }
        }
        let n = try count(nodes.count, "node_ghosts")
        try ok("cadaclysm_view_set_node_ghosts") { t, v in withUInt32s(nodes) { t.pointee.set_node_ghosts!(v, id, $0, n) } }
    }
    /// Fits the camera to one node of a scene item.
    public func frameNode(_ node: UInt32) throws {
        try ok("cadaclysm_view_frame_node") { t, v in t.pointee.frame_node!(v, id, node) }
    }
    /// Poses a shown scene: one column-major 4x4 (sixteen doubles) per scene node, in index
    /// order (`Pose.rawTransform`'s layout), drawn in place of each node's rest transform; nil
    /// restores the rest pose. An empty list reaches the library, which refuses it.
    public func setNodeTransforms(_ transforms: [[Double]]?) throws {
        guard let transforms else {
            return try ok("cadaclysm_view_set_node_transforms") { t, v in t.pointee.set_node_transforms!(v, id, nil, 0) }
        }
        for (k, m) in transforms.enumerated() where m.count != 16 {
            throw ViewError("transform \(k): 16 numbers, not \(m.count)")
        }
        let n = try count(transforms.count, "node_transforms")
        let flat = transforms.flatMap { $0 }
        try ok("cadaclysm_view_set_node_transforms") { t, v in withDoubles(flat) { t.pointee.set_node_transforms!(v, id, $0, n) } }
    }
}

// ---- animations (1.27) -------------------------------------------------------------------------

/// One binding of a kernel animation to a shown item: the animation's `target` name drives the
/// item (`node` nil) or one node of it and its subtree, by the reader's index.
public struct AnimationBinding: Equatable {
    public let target: String
    public let item: UInt32
    public let node: UInt32?
    public init(target: String, item: UInt32, node: UInt32? = nil) {
        self.target = target; self.item = item; self.node = node
    }
    public init(target: String, item: Item, node: UInt32? = nil) {
        self.init(target: target, item: item.id, node: node)
    }
}

// ---- machining ---------------------------------------------------------------------------------

/// A tool as the machining view takes it: `shape` is "flat", "ball", "drill", "vbit" or
/// "bullnose"; `fluteLength`, `angle` (a V-bit's) and `cornerRadius` (a bull-nose's) are 0 when
/// not given.
public struct MachiningTool: Sendable {
    public var number: UInt32
    public var shape: String
    public var diameter: Double
    public var fluteLength: Double
    public var angle: Double
    public var cornerRadius: Double
    public init(number: UInt32, shape: String, diameter: Double, fluteLength: Double = 0, angle: Double = 0,
                cornerRadius: Double = 0) {
        self.number = number; self.shape = shape; self.diameter = diameter
        self.fluteLength = fluteLength; self.angle = angle; self.cornerRadius = cornerRadius
    }
}
/// One program of a job: its tool and its G-code.
public struct MachiningProgram: Sendable {
    public var tool: MachiningTool
    public var gcode: String
    public init(tool: MachiningTool, gcode: String) { self.tool = tool; self.gcode = gcode }
}
/// The blank's lowest and highest corners, mm.
public struct MachiningStock: Sendable {
    public var min: SIMD3<Double>
    public var max: SIMD3<Double>
    public init(min: SIMD3<Double>, max: SIMD3<Double>) { self.min = min; self.max = max }
}
/// The part a job is cut to, for colouring by deviation: `positions` three floats a vertex,
/// `indices` three a triangle.
public struct MachiningPart: Sendable {
    public var positions: [Float]
    public var indices: [UInt32]
    public init(positions: [Float], indices: [UInt32]) { self.positions = positions; self.indices = indices }
}
/// Absent (nil): the library's own default (the cell by the tools, tolerance 0.05, skin 0.3,
/// rapidRate 5000 mm/min).
public struct MachiningOptions: Sendable {
    public var cell: Double?
    public var tolerance: Double?
    public var skin: Double?
    public var rapidRate: Double?
    public init(cell: Double? = nil, tolerance: Double? = nil, skin: Double? = nil, rapidRate: Double? = nil) {
        self.cell = cell; self.tolerance = tolerance; self.skin = skin; self.rapidRate = rapidRate
    }
}
/// What a view has drawn (`View.stats()`, view ABI 1.25): the frames drawn so far -- each frame
/// drawn to the window, and each `image()` rendered; a pump or draw that owes nothing adds none --
/// and the last frame's CPU time, GPU time (-1: not measurable), triangles and draw calls.
public struct ViewStats: Equatable {
    public var framesDrawn: UInt64
    public var lastFrameMs: Float
    /// -1: unknown (no timestamps on the device, the terminal).
    public var lastGpuMs: Float
    public var triangles: UInt64
    public var drawCalls: UInt32
}

// ---- input events (view ABI 1.26) --------------------------------------------------------

/// What a pointer event came from (`CADACLYSM_VIEW_POINTER_*`).
public enum PointerKind: UInt32, CaseIterable, Sendable {
    case mouse = 0, touch = 1, pen = 2
}

/// The keys held during a pointer, wheel or key event (`CADACLYSM_VIEW_MOD_*`).
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let shift = Modifiers(rawValue: UInt32(CADACLYSM_VIEW_MOD_SHIFT))
    public static let ctrl = Modifiers(rawValue: UInt32(CADACLYSM_VIEW_MOD_CTRL))
    public static let alt = Modifiers(rawValue: UInt32(CADACLYSM_VIEW_MOD_ALT))
    public static let meta = Modifiers(rawValue: UInt32(CADACLYSM_VIEW_MOD_META))
}

/// A pointer press, move or release: where (physical pixels from the window's top left), the
/// `button` (0 left, 1 middle, 2 right), the kind of pointer and its id, the keys held.
public struct PointerInput: Equatable, Sendable {
    public let x: Float, y: Float
    public let button: UInt32
    public let pointer: PointerKind
    public let pointerID: UInt32
    public let modifiers: Modifiers
}

/// A wheel turn at (x, y): `wheelY` as a DOM deltaY (negative forward), the keys held.
public struct WheelInput: Equatable, Sendable {
    public let x: Float, y: Float
    public let wheelY: Float
    public let modifiers: Modifiers
}

/// A key pressed or released: `key` the DOM code ("KeyR", "Digit1", "Space", "Escape",
/// "ArrowUp"...), `isRepeat` for a held key's repeat, the keys held.
public struct KeyInput: Equatable, Sendable {
    public let key: String
    public let isRepeat: Bool
    public let modifiers: Modifiers
}

/// An input event the view's own window handled (`View.nextEvent()`, view ABI 1.26): what
/// happened, `timeMs` on the library's clock, and `dropped`, the events a full queue dropped
/// before this one.
public struct ViewInputEvent {
    /// What happened.
    public enum Kind {
        case pointerDown(PointerInput)
        case pointerMove(PointerInput)
        case pointerUp(PointerInput)
        case wheel(WheelInput)
        case keyDown(KeyInput)
        case keyUp(KeyInput)
        /// The window's new size in physical pixels.
        case resize(width: UInt32, height: UInt32)
        /// A click's answer, as `lastPick` also gives it; nil for a click on nothing.
        case pick(ViewPick?)
        /// A hover's or click's snap with snapping on; nil where nothing snapped.
        case snap(ViewSnap?)
        /// The window closed, on this camera (as `run()` returns it, with no pick).
        case close(Camera)
        /// A draw moved the timeline's clock (1.27): `timeMs` is the stamp, nothing else rides.
        case timeline
        /// A kind this module does not know (a later 1.x library's).
        case other(UInt32)
    }
    public let kind: Kind
    public let timeMs: Double
    public let dropped: UInt32
}

/// A library's input event as a ViewInputEvent.
func inputEventOf(_ e: CadaclysmViewInputEvent, yUp: Bool) -> ViewInputEvent {
    let mods = Modifiers(rawValue: e.modifiers)
    let pointer = PointerInput(x: e.x, y: e.y, button: e.button, pointer: PointerKind(rawValue: e.pointer) ?? .mouse,
                               pointerID: e.pointer_id, modifiers: mods)
    // The key is NUL-terminated; read at most its 32 bytes all the same.
    let key = withUnsafeBytes(of: e.key) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    let typed = KeyInput(key: key, isRepeat: e.`repeat` != 0, modifiers: mods)
    let kind: ViewInputEvent.Kind
    switch Int(e.kind) {
    case Int(CADACLYSM_VIEW_INPUT_EVENT_POINTER_DOWN): kind = .pointerDown(pointer)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_POINTER_MOVE): kind = .pointerMove(pointer)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_POINTER_UP): kind = .pointerUp(pointer)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_WHEEL): kind = .wheel(WheelInput(x: e.x, y: e.y, wheelY: e.wheel_y, modifiers: mods))
    case Int(CADACLYSM_VIEW_INPUT_EVENT_KEY_DOWN): kind = .keyDown(typed)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_KEY_UP): kind = .keyUp(typed)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_RESIZE): kind = .resize(width: e.width, height: e.height)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_PICK):
        kind = .pick(e.pick.item != 0 || e.pick_viewport_label >= 0
            ? pickOf(e.pick, label: e.pick_viewport_label, segment: e.pick_segment, distancePx: e.pick_distance_px) : nil)
    case Int(CADACLYSM_VIEW_INPUT_EVENT_SNAP): kind = .snap(snapOf(e))
    case Int(CADACLYSM_VIEW_INPUT_EVENT_CLOSE): kind = .close(camera(e.camera, rawPick(), yUp: yUp))
    case Int(CADACLYSM_VIEW_INPUT_EVENT_TIMELINE): kind = .timeline
    default: kind = .other(e.kind)
    }
    return ViewInputEvent(kind: kind, timeMs: e.time_ms, dropped: e.dropped)
}

/// A machining's facts: `moves` in the job, `move` done as of the last draw, the heights'
/// grid (`nx`, `ny`, `cell` mm, `min` the corner of cell (0, 0)) and the `cycleTime` in seconds.
public struct MachiningInfo {
    public var moves: UInt32, move: UInt32, nx: UInt32, ny: UInt32
    public var cell: Float
    public var min: (Float, Float)
    public var cycleTime: Double
}

/// A CAM job shown in a `View` (`View.showMachining`): the stock is this item; the view's
/// timeline plays it. Every `Item` member works on it too; `remove()` takes the job and its
/// track away.
public final class Machining: Item {
    /// Jump the timeline to the end of move `move` (0: the untouched stock).
    public func seekMove(_ move: UInt32) throws {
        try ok("cadaclysm_view_machining_seek") { t, v in t.pointee.machining_seek!(v, id, move) }
    }
    /// "height", "tool" or "deviation" (needs a part).
    public func setColourBy(_ mode: String) throws {
        let modes: [String: UInt32] = ["height": UInt32(CADACLYSM_VIEW_COLOUR_BY_HEIGHT),
                                       "tool": UInt32(CADACLYSM_VIEW_COLOUR_BY_TOOL),
                                       "deviation": UInt32(CADACLYSM_VIEW_COLOUR_BY_DEVIATION)]
        guard let m = modes[mode] else { throw ViewError("mode '\(mode)': one of height, tool, deviation") }
        try ok("cadaclysm_view_machining_colour_by") { t, v in t.pointee.machining_colour_by!(v, id, m) }
    }
    /// The toolpath and the tool, on or off.
    public func setOverlays(path: Bool = true, tool: Bool = true) throws {
        try ok("cadaclysm_view_machining_overlays") { t, v in t.pointee.machining_overlays!(v, id, path, tool) }
    }
    /// `moves`, `move` (done, as of the last draw), the heights' grid and the cycle time.
    public func info() throws -> MachiningInfo {
        var out = CadaclysmViewMachiningInfo()
        out.size = UInt32(MemoryLayout<CadaclysmViewMachiningInfo>.size)
        try ok("cadaclysm_view_machining_info") { t, v in t.pointee.machining_info!(v, id, &out) }
        return MachiningInfo(moves: out.moves, move: out.move, nx: out.nx, ny: out.ny, cell: out.cell,
                             min: (out.min.0, out.min.1), cycleTime: out.cycle_time)
    }
    /// The stock's heights now, nx * ny floats, row y then x; waits for the GPU.
    public func heights() throws -> [Float] {
        let i = try info()
        var z = [Float](repeating: 0, count: Int(i.nx) * Int(i.ny))
        let n = z.count
        var none: Float = 0  // never NULL, even for an empty grid
        try withUnsafeMutablePointer(to: &none) { stand in
            try z.withUnsafeMutableBufferPointer { b in
                let at = b.baseAddress ?? stand
                try ok("cadaclysm_view_machining_heights") { t, v in t.pointee.machining_heights!(v, id, at, n) }
            }
        }
        return z
    }
}

// ---- overlays (view ABI 1.24) ------------------------------------------------------------

/// Where an overlay hangs in the window (view ABI 1.24): a corner, the middle of an edge, or
/// the centre -- the `CADACLYSM_VIEW_ALIGN_*` codes as raw values. An overlay's offset is
/// measured inward from it: x away from the left edge for the left column and from the right
/// edge for the right one (rightward for the middle column); y down from the top edge for the
/// top row and up from the bottom edge for the bottom one (upward for the middle row). So
/// (`.topRight`, 10, 10) is 10 pixels in from the right and from the top.
public enum Anchor: UInt32, CaseIterable, Sendable {
    case topLeft = 0, top = 1, topRight = 2, left = 3, centre = 4, right = 5, bottomLeft = 6, bottom = 7, bottomRight = 8
}

/// How `View.showOverlay` draws a shape. A profile is a sketch, so it draws as its outline by
/// default. `stroke`: where set, its colour (see Colour; four numbers for an alpha), or "none"
/// for no stroke; nil, the profile's own colour (`Profile.coloured`), else white;
/// `strokeWidth` pixels wide. `fill`: only where set, its colour, or "none" for no fill -- a
/// panel needs one. Fill only is a `fill` and `stroke: "none"`; neither a fill nor a stroke is
/// refused. `order`: lower draws first, equal orders in show order (shapes, text and images
/// share it).
public struct OverlayStyle {
    public var fill: (any Colour)?
    public var stroke: (any Colour)?
    public var strokeWidth: Float
    public var order: Int32
    public init(fill: (any Colour)? = nil, stroke: (any Colour)? = nil, strokeWidth: Float = 1, order: Int32 = 0) {
        self.fill = fill
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.order = order
    }
}

/// An overlay shown (view ABI 1.24): a shape, text or an image hung from an anchor of the
/// window, drawn over everything, untouched by the camera. Every `Item` member works on it too
/// (`remove`, `userLayer`, and `setText` on text).
public final class Overlay: Item {
    /// The anchor it hangs from now.
    public private(set) var anchor: Anchor
    init(view: View, id: UInt32, anchor: Anchor) {
        self.anchor = anchor
        super.init(view: view, id: id)
    }
    /// Moved to `x`, `y` pixels inward from its anchor (cadaclysm_view_move_overlay): cheap,
    /// for a HUD element that moves every frame.
    public func moveTo(x: Float, y: Float) throws { try moveTo(anchor, x: x, y: y) }
    /// Hung from `anchor` instead, `x`, `y` pixels inward from it.
    public func moveTo(_ anchor: Anchor, x: Float, y: Float) throws {
        try ok("cadaclysm_view_move_overlay") { t, v in t.pointee.move_overlay!(v, id, anchor.rawValue, x, y) }
        self.anchor = anchor
    }
}

// ---- views -----------------------------------------------------------------------------------

/// One view: a window of its own, an offscreen one, or one in a host's window.
public final class View {
    /// Which axis is up.
    public enum UpAxis: Sendable { case z, y }
    /// How a left drag moves the camera (see `navigation`).
    public enum Navigation: Sendable { case orbit, fly }

    /// A host's native window: `kind` a `CADACLYSM_VIEW_WINDOW_*` value, the handle, an
    /// X11/XCB id, the display, and its client size in physical pixels.
    public struct Window {
        public var kind: UInt32, handle: UnsafeMutableRawPointer?, id: UInt64, display: UnsafeMutableRawPointer?
        public var width: UInt32, height: UInt32
        public init(kind: UInt32, handle: UnsafeMutableRawPointer?, id: UInt64 = 0, display: UnsafeMutableRawPointer? = nil,
                    width: UInt32, height: UInt32) {
            self.kind = kind; self.handle = handle; self.id = id; self.display = display; self.width = width; self.height = height
        }
    }

    /// One pane of `viewports`: its rectangle (x, y, width, height in physical pixels from the
    /// top left), its camera's column-major view and projection, the eye, a
    /// `CADACLYSM_VIEW_GRID_*` grid, and the user layers drawn in it (`layerMask`: bit n for
    /// layer n, see `Item.userLayer`; every layer by default).
    public struct Viewport {
        public var rect: SIMD4<UInt32>
        public var view: [Float], projection: [Float]
        public var eye: SIMD3<Float>
        public var grid: UInt32
        public var layerMask: UInt32
        public init(rect: SIMD4<UInt32>, view: [Float], projection: [Float], eye: SIMD3<Float>, grid: UInt32 = 0,
                    layerMask: UInt32 = 0xFFFF_FFFF) {
            self.rect = rect; self.view = view; self.projection = projection; self.eye = eye; self.grid = grid
            self.layerMask = layerMask
        }
    }

    /// The view library it draws with.
    public let library: ViewLibrary
    // handle, windowClosed and owners are read across threads (pump's count, releaseShown)
    // under View.lock; only the view's own thread writes them, under it too.
    var handle: OpaquePointer?
    let thread: UInt64  // the OS thread that made it
    let ownWindow: Bool  // a window of its own
    let pumped: Bool  // a window of its own on the wgpu library: pump reaches it
    let yUp: Bool
    var windowClosed = false  // that window was closed (its button, Escape, the end of run)
    var drawn: Int32 = 0  // drawn once: pick draws a never-drawn view first
    var owners: [UInt32: AnyObject] = [:]  // what each item keeps alive

    /// Recursive: what a view lets go of (the last reference to a Scene) closes it, and that
    /// close comes back here.
    static let lock = NSRecursiveLock()
    private static var registry: [Weak] = []
    private static var leaked: [[UInt32: AnyObject]] = []
    private struct Weak { weak var view: View? }

    private init(window: UnsafePointer<CadaclysmViewWindow>?, title: String?, width: UInt32, height: UInt32,
                 triangles: Bool, up: UpAxis, offscreen: Bool) throws {
        library = try ViewLibrary.current()
        let made = cvl_create(library.table, window, title, width, height, triangles ? 1 : 0, up == .y ? 1 : 0, offscreen ? 1 : 0)
        guard let made else {
            var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
            let errCount = err.count
            _ = cvl_create_failed(library.table, noDisplay, &err, errCount)
            throw ViewError(text(err))
        }
        handle = made
        thread = ccadaclysm_view_thread()
        ownWindow = window == nil && !offscreen
        pumped = ownWindow && cvl_is_wgpu(library.table) != 0
        yUp = up == .y
        View.lock.lock()
        View.registry.removeAll { $0.view == nil }
        View.registry.append(Weak(view: self))
        View.lock.unlock()
    }

    /// A window of its own (the terminal: drawn in the terminal).
    public convenience init(title: String? = nil, width: UInt32 = 0, height: UInt32 = 0, triangles: Bool = false,
                            up: UpAxis = .z) throws {
        try self.init(window: nil, title: title, width: width, height: height, triangles: triangles, up: up, offscreen: false)
    }
    /// No window and no display: a GPU adapter is enough. 0 x 0 is 1280 x 800. The terminal
    /// library refuses it.
    public static func offscreen(width: UInt32, height: UInt32, triangles: Bool = false, up: UpAxis = .z) throws -> View {
        try View(window: nil, title: nil, width: width == 0 ? 1280 : width, height: height == 0 ? 800 : height,
                 triangles: triangles, up: up, offscreen: true)
    }
    /// In a host's window; the host forwards input, resize and draw.
    public static func inWindow(_ w: Window, triangles: Bool = false, up: UpAxis = .z) throws -> View {
        if w.width == 0 || w.height == 0 {
            throw ViewError("a host's window needs a width and a height: its client size in physical pixels")
        }
        var raw = CadaclysmViewWindow()
        raw.size = UInt32(MemoryLayout<CadaclysmViewWindow>.size)
        raw.kind = w.kind
        raw.window = w.handle
        raw.window_id = w.id
        raw.display = w.display
        raw.width = w.width
        raw.height = w.height
        return try View(window: &raw, title: nil, width: w.width, height: w.height, triangles: triangles, up: up, offscreen: false)
    }

    deinit {
        // Another thread's view cannot be destroyed from here: it is left, as Python's
        // __del__ leaves it -- and so is what its items keep, which it may still read.
        if ccadaclysm_view_thread() == thread {
            destroy()
        } else if handle != nil && !owners.isEmpty {
            View.lock.lock()
            View.leaked.append(owners)
            View.lock.unlock()
        }
    }

    /// Destroys the view and its window, then lets go of what its items kept. Idempotent.
    /// Refused on another thread than the one that made it, which then changes nothing.
    public func close() throws {
        View.lock.lock()
        let open = handle != nil
        View.lock.unlock()
        if !open { return }
        if ccadaclysm_view_thread() != thread { throw ViewError("close: a view belongs to the thread that made it") }
        destroy()
    }

    /// The C view first, then what the items kept (C11) -- outside the lock.
    func destroy() {
        View.lock.lock()
        let h = handle
        handle = nil
        let dropped = owners
        owners = [:]
        View.lock.unlock()
        if let h { library.table.pointee.destroy!(h) }
        withExtendedLifetime(dropped) {}
    }

    /// Destroyed (close()), or its window closed (run() ended, Escape, its close button).
    public var isClosed: Bool {
        View.lock.lock()
        defer { View.lock.unlock() }
        return handle == nil || windowClosed
    }

    /// Python's _call: another thread's view, a closed view, a closed window, each refused
    /// with the C call's name.
    func refusal(_ call: String) -> ViewError? {
        if ccadaclysm_view_thread() != thread { return ViewError("\(call): a view belongs to the thread that made it") }
        if handle == nil { return ViewError("\(call): the view is closed") }
        if windowClosed { return ViewError("\(call): the window is closed") }
        return nil
    }
    /// The colour of `call`: its refusal first (another thread, a closed view or window), then
    /// the colour's (colourValues); nil for none.
    func paint(_ call: String, _ c: (any Colour)?) throws -> [Float]? {
        if let no = refusal(call) { throw no }
        guard let c else { return nil }
        return try colourValues(library.table, c)
    }
    func live(_ call: String) throws -> (UnsafeMutablePointer<CvlTable>, OpaquePointer) {
        if let no = refusal(call) { throw no }
        return (library.table, handle!)
    }
    func markClosed() {
        View.lock.lock()
        windowClosed = true
        View.lock.unlock()
    }
    func ok(_ call: String, _ f: (UnsafeMutablePointer<CvlTable>, OpaquePointer) -> Bool) throws {
        let (t, v) = try live(call)
        if !f(t, v) { throw libraryError(t) }
    }
    /// A void call: refused when the library left a message (Python's _void).
    private func act(_ call: String, _ f: (UnsafeMutablePointer<CvlTable>, OpaquePointer) -> Void) throws {
        let (t, v) = try live(call)
        f(t, v)
        if !lastError(t).isEmpty { throw libraryError(t) }
    }
    private func add(_ call: String, owner: AnyObject?, _ f: (UnsafeMutablePointer<CvlTable>, OpaquePointer) -> UInt32) throws -> Item {
        try add(call, owner: owner, make: { Item(view: $0, id: $1) }, f)
    }
    /// `add` wrapping the id as `make` says (a subclass of Item).
    private func add<T: Item>(_ call: String, owner: AnyObject?, make: (View, UInt32) -> T,
                              _ f: (UnsafeMutablePointer<CvlTable>, OpaquePointer) -> UInt32) throws -> T {
        let (t, v) = try live(call)
        let id = f(t, v)
        if id == 0 { throw libraryError(t) }
        keep(id, owner)
        return make(self, id)
    }
    /// What item `id` keeps; a value it replaces (a library that hands an id out again) is let
    /// go of after the unlock.
    private func keep(_ id: UInt32, _ owner: AnyObject?) {
        View.lock.lock()
        let old = owner.map { owners.updateValue($0, forKey: id) } ?? owners.removeValue(forKey: id)
        View.lock.unlock()
        withExtendedLifetime(old) {}
    }
    /// Drops what item `id` kept, after the unlock.
    func forget(_ id: UInt32) {
        View.lock.lock()
        let dropped = owners.removeValue(forKey: id)
        View.lock.unlock()
        withExtendedLifetime(dropped) {}
    }

    // -- showing: each returns the Item

    /// A shown solid's material (`CADACLYSM_VIEW_MATERIAL_*`, view ABI 1.21): `default` the
    /// headlight every other item is drawn with.
    public enum Material: UInt32, Sendable {
        case `default` = 0, plastic = 1, metal = 2, matte = 3, paint = 4, brushed = 5, glass = 6
    }

    /// The by-handle shows Blacksmith and Cadaclysm build on (View+Solid.swift,
    /// View+Scene.swift): `owner` is what the item keeps alive. A solid with a `material`, an
    /// `opacity` or `faces` (1.21) goes through show_solid_faces, else show_solid.
    package func showHandle(solid: OpaquePointer?, scene: OpaquePointer?, tolerance: Double, rgb: (any Colour)?,
                            owner: AnyObject?, material: Material? = nil, opacity: Float? = nil,
                            faces: [UInt32]? = nil) throws -> Item {
        if let solid {
            if material == nil && opacity == nil && faces == nil {
                let c = try paint("cadaclysm_view_show_solid", rgb)
                return try add("cadaclysm_view_show_solid", owner: owner) { t, v in
                    withColour(c) { t.pointee.show_solid!(v, solid, tolerance, $0) }
                }
            }
            let c = try paint("cadaclysm_view_show_solid_faces", rgb)
            let look = (material ?? .default).rawValue, alpha = opacity ?? 1
            return try add("cadaclysm_view_show_solid_faces", owner: owner) { t, v in
                withColour(c) { rgb in
                    guard let faces else { return t.pointee.show_solid_faces!(v, solid, tolerance, rgb, look, alpha, nil, 0) }
                    return withUInt32s(faces) { t.pointee.show_solid_faces!(v, solid, tolerance, rgb, look, alpha, $0, UInt32(faces.count)) }
                }
            }
        }
        return try add("cadaclysm_view_show", owner: owner) { t, v in t.pointee.show!(v, scene) }
    }

    /// Plain triangles: `positions` three floats a point, `indices` three a triangle,
    /// `normals` (nil or empty: none) one a position, `edges` (nil or empty: none) two points a
    /// segment; `rgb` a Colour, nil the library's default. Copied before this returns.
    public func showMesh(positions: [Float], indices: [UInt32], normals: [Float]? = nil, edges: [Float]? = nil,
                         rgb: (any Colour)? = nil) throws -> Item {
        let normals = normals ?? [], edges = edges ?? []
        if positions.count % 3 != 0 { throw ViewError("positions is three numbers a point, not \(positions.count)") }
        if !normals.isEmpty && normals.count != positions.count {
            throw ViewError("a mesh has \(positions.count / 3) positions but \(normals.count / 3) normals")
        }
        if edges.count % 6 != 0 { throw ViewError("edges is two points a segment (6 numbers), not \(edges.count)") }
        let vertices = try count(positions.count / 3, "show_mesh positions")
        let indexCount = try count(indices.count, "show_mesh indices")
        let edgeCount = try count(edges.count / 6, "show_mesh edges")
        let c = try paint("cadaclysm_view_show_mesh", rgb)
        return try add("cadaclysm_view_show_mesh", owner: nil) { t, v in
            withFloats(positions) { pp in withUInt32s(indices) { ip in withFloats(normals) { np in withFloats(edges) { ep in
                withColour(c) { cp -> UInt32 in
                    var m = CadaclysmViewMesh()
                    m.size = UInt32(MemoryLayout<CadaclysmViewMesh>.size)
                    m.positions = pp
                    m.vertex_count = vertices
                    m.normals = normals.isEmpty ? nil : np
                    m.indices = ip
                    m.index_count = indexCount
                    m.edges = edges.isEmpty ? nil : ep
                    m.edge_count = edgeCount
                    m.rgb = cp
                    return t.pointee.show_mesh!(v, &m)
                }
            } } } }
        }
    }
    /// Segments, six floats (two points) each; `rgb` a Colour, nil the default.
    public func showLines(_ segments: [Float], rgb: (any Colour)? = nil) throws -> Item {
        if segments.count % 6 != 0 { throw ViewError("segments is two points a segment (6 numbers), not \(segments.count)") }
        let n = try count(segments.count / 6, "show_lines")
        let c = try paint("cadaclysm_view_show_lines", rgb)
        return try add("cadaclysm_view_show_lines", owner: nil) { t, v in
            withFloats(segments) { s in withColour(c) { t.pointee.show_lines!(v, s, n, $0) } }
        }
    }
    /// Points, three floats each: a disc `sizePx` device pixels across (1 to 64) at each, in
    /// `rgb` (a Colour, nil the edge colour), as one item. A point does not pick; the item is
    /// framed by its points' box. The library refuses a value that is not finite and a size out
    /// of range; the terminal library refuses points (it has no way to draw a dot).
    public func showPoints(_ positions: [Float], rgb: (any Colour)? = nil, sizePx: Float = 8) throws -> Item {
        if positions.count % 3 != 0 { throw ViewError("show_points: three numbers a point, not \(positions.count)") }
        let n = try count(positions.count / 3, "show_points")
        let c = try paint("cadaclysm_view_show_points", rgb)
        return try add("cadaclysm_view_show_points", owner: nil) { t, v in
            withFloats(positions) { p in withColour(c) { t.pointee.show_points!(v, p, n, $0, sizePx) } }
        }
    }
    /// Drafting symbols of one `kind` at `at` (three floats each), as one item (1.29): `sizePt`
    /// points across (1 to 128; device pixels at the host's screen density, which hosts that set one scale) at any zoom, in `colour` (nil: the
    /// edge colour), turned to `dir` (three floats a glyph, as projected on the screen; nil:
    /// all unturned; an arrow points along it). Glyph `i` picks as the item and node `i`. The
    /// terminal library and the render view library draw no glyphs and refuse it.
    public func showGlyphs(_ at: [Float], kind: GlyphKind, sizePt: Float = 12, colour: (any Colour)? = nil,
                           dir: [Float]? = nil) throws -> Item {
        if at.count % 3 != 0 { throw ViewError("show_glyphs: three numbers a glyph, not \(at.count)") }
        if let dir, dir.count != at.count {
            throw ViewError("show_glyphs: dir is three numbers a glyph (\(at.count / 3) glyphs), not \(dir.count)")
        }
        let c = try paint("cadaclysm_view_show_glyphs", colour)
        return try add("cadaclysm_view_show_glyphs", owner: nil) { t, v in
            withFloats(at) { a in
                withNormals(dir) { d in
                    withColour(c) { t.pointee.show_glyphs!(v, a, d, at.count / 3, kind.rawValue, sizePt, $0) }
                }
            }
        }
    }
    /// A CAM job on a stock, paused at its start, as Python's `View.show_machining`: `programs`
    /// in run order, `stock` its corners, `part` (nil: none) to colour by deviation, `options`
    /// where the library's defaults are not wanted. Play it with `play()`. A shape that is none
    /// of "flat", "ball", "drill", "vbit" or "bullnose", a number that is not finite, a NUL in
    /// a program's G-code, a part that is not whole triangles of x y z triples or an index past
    /// its vertices is refused before the library is called.
    public func showMachining(_ programs: [MachiningProgram], stock: MachiningStock, part: MachiningPart? = nil,
                              options: MachiningOptions = MachiningOptions()) throws -> Machining {
        let programCount = try count(programs.count, "show_machining")
        var shapes: [UInt32] = []
        for program in programs {
            let tool = program.tool
            let shape: Int32
            switch tool.shape {
            case "flat": shape = CADACLYSM_VIEW_TOOL_FLAT
            case "ball": shape = CADACLYSM_VIEW_TOOL_BALL
            case "drill": shape = CADACLYSM_VIEW_TOOL_DRILL
            case "vbit": shape = CADACLYSM_VIEW_TOOL_VBIT
            case "bullnose": shape = CADACLYSM_VIEW_TOOL_BULLNOSE
            default: throw ViewError("shape \(quoted(tool.shape)): one of flat, ball, drill, vbit, bullnose")
            }
            shapes.append(UInt32(shape))
            guard tool.diameter.isFinite, tool.fluteLength.isFinite, tool.angle.isFinite, tool.cornerRadius.isFinite else {
                throw ViewError("tool: diameter, flute_length, angle and corner_radius are finite numbers")
            }
            if program.gcode.unicodeScalars.contains("\0") {
                throw ViewError("gcode: a NUL character cannot be sent (the C string ends there)")
            }
        }
        guard (0..<3).allSatisfy({ stock.min[$0].isFinite && stock.max[$0].isFinite }) else {
            throw ViewError("stock: min and max are finite numbers")
        }
        var vertexCount: UInt32 = 0, indexCount: UInt32 = 0
        if let part {
            if part.positions.contains(where: { !$0.isFinite }) { throw ViewError("part positions: finite numbers") }
            if part.positions.count % 3 != 0 {
                throw ViewError("part positions: \(part.positions.count) numbers is not a whole number of x y z triples")
            }
            if part.indices.count % 3 != 0 {
                throw ViewError("part indices: \(part.indices.count) is not a whole number of triangles")
            }
            let vertices = part.positions.count / 3
            if let top = part.indices.max(), Int(top) >= vertices {
                throw ViewError("part indices: \(top) is past the last of \(vertices) vertices")
            }
            vertexCount = try count(vertices, "show_machining part")
            indexCount = try count(part.indices.count, "show_machining part")
        }
        for value in [options.cell, options.tolerance, options.skin, options.rapidRate] {
            if let value, !value.isFinite {
                throw ViewError("show_machining options: cell, tolerance, skin and rapid_rate are finite numbers")
            }
        }
        // The programs' array and each G-code are C memory for the call, freed after it.
        let slots = max(programs.count, 1)
        let raw = UnsafeMutablePointer<CadaclysmViewProgram>.allocate(capacity: slots)
        raw.initialize(repeating: CadaclysmViewProgram(), count: slots)
        defer {
            for k in 0..<programs.count { free(UnsafeMutableRawPointer(mutating: raw[k].gcode)) }
            raw.deallocate()
        }
        for (k, program) in programs.enumerated() {
            let tool = program.tool
            raw[k].size = UInt32(MemoryLayout<CadaclysmViewProgram>.size)
            raw[k].tool_number = tool.number
            raw[k].tool_shape = shapes[k]
            raw[k].tool_diameter = tool.diameter
            raw[k].tool_flute_length = tool.fluteLength
            raw[k].tool_angle = tool.angle
            raw[k].tool_corner_radius = tool.cornerRadius
            guard let gcode = strdup(program.gcode) else {  // the defer frees the copies made so far
                throw ViewError("program \(k): out of memory copying its G-code")
            }
            raw[k].gcode = UnsafePointer(gcode)
        }
        var m = CadaclysmViewMachining()
        m.size = UInt32(MemoryLayout<CadaclysmViewMachining>.size)
        m.program_count = programCount
        m.programs = UnsafePointer(raw)
        m.stock_min = (stock.min.x, stock.min.y, stock.min.z)
        m.stock_max = (stock.max.x, stock.max.y, stock.max.z)
        m.part_vertex_count = vertexCount
        m.part_index_count = indexCount
        m.cell = options.cell ?? 0
        m.tolerance = options.tolerance ?? 0
        m.rapid_rate = options.rapidRate ?? 0
        if let skin = options.skin {
            m.skin = skin
            m.skin_set = 1
        }
        func show(_ positions: UnsafePointer<Float>?, _ indices: UnsafePointer<UInt32>?) throws -> Machining {
            m.part_positions = positions
            m.part_indices = indices
            return try add("cadaclysm_view_show_machining", owner: nil, make: { Machining(view: $0, id: $1) }) { t, v in
                t.pointee.show_machining!(v, &m)
            }
        }
        guard let part else { return try show(nil, nil) }
        let shown = withFloats(part.positions) { p in
            withUInt32s(part.indices) { i in Result { try show(p, i) } }
        }
        return try shown.get()
    }

    /// Rational cubics, sixteen floats each (four x, y, z, w control points); `rgb` a Colour,
    /// nil the default.
    public func showCurves(_ beziers: [Float], rgb: (any Colour)? = nil) throws -> Item {
        if beziers.count % 16 != 0 {
            throw ViewError("show_curves takes four x, y, z, w control points (16 numbers) a curve, not \(beziers.count)")
        }
        let n = try count(beziers.count / 16, "show_curves")
        let c = try paint("cadaclysm_view_show_curves", rgb)
        return try add("cadaclysm_view_show_curves", owner: nil) { t, v in
            withFloats(beziers) { b in withColour(c) { t.pointee.show_curves!(v, b, n, $0) } }
        }
    }
    /// An RGBA8 picture of width x height pixels (exactly width * height * 4 bytes, rows from
    /// the top) on the quad `corners` (twelve numbers): bottom-left, bottom-right, top-right,
    /// top-left.
    public func showImage(corners: [Float], rgba: [UInt8], width: UInt32, height: UInt32, opacity: Float = 1) throws -> Item {
        if corners.count != 12 { throw ViewError("12 numbers, not \(corners.count)") }
        let need = try pixelBytes(width, height, "show_image")
        if rgba.count != need {
            throw ViewError("show_image: \(width) x \(height) pixels need \(need) bytes (rgba), not \(rgba.count)")
        }
        return try add("cadaclysm_view_show_image", owner: nil) { t, v in
            withBytes(rgba) { px -> UInt32 in
                var image = CadaclysmViewImage()
                image.size = UInt32(MemoryLayout<CadaclysmViewImage>.size)
                withUnsafeMutableBytes(of: &image.corners) { _ = $0.bindMemory(to: Float.self).update(from: corners) }
                image.rgba = px
                image.width = width
                image.height = height
                image.opacity = opacity
                return t.pointee.show_image!(v, &image)
            }
        }
    }

    /// showText's modes and alignments, in Python's order (its refusals list them).
    private static let textModes: [(String, UInt32)] = [("label", UInt32(CADACLYSM_VIEW_TEXT_LABEL)),
                                                         ("world", UInt32(CADACLYSM_VIEW_TEXT_WORLD))]
    private static let alignments: [(String, UInt32)] = [
        ("top-left", UInt32(CADACLYSM_VIEW_ALIGN_TOP_LEFT)), ("top", UInt32(CADACLYSM_VIEW_ALIGN_TOP)),
        ("top-right", UInt32(CADACLYSM_VIEW_ALIGN_TOP_RIGHT)), ("left", UInt32(CADACLYSM_VIEW_ALIGN_LEFT)),
        ("centre", UInt32(CADACLYSM_VIEW_ALIGN_CENTRE)), ("center", UInt32(CADACLYSM_VIEW_ALIGN_CENTRE)),
        ("right", UInt32(CADACLYSM_VIEW_ALIGN_RIGHT)), ("bottom-left", UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT)),
        ("bottom", UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM)), ("bottom-right", UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT)),
    ]

    /// Text in the scene, at the point `at` ("\n" starts a line). `mode` "label" (the default)
    /// is a screen label: `size` its height in pixels, always facing the viewer, placed by
    /// `align` (which corner or edge of the text sits on the point: top-left, top, top-right,
    /// left, centre or center, right, bottom-left, bottom, bottom-right) and nudged by `offset`
    /// pixels, right and up. "world" is a quad in the scene: `size` the height in model units,
    /// laid along `right` and `up` (nil: x and y), so it turns and shrinks with the camera.
    /// `colour` is the glyphs' (see Colour; an alpha is not drawn). `box`, `padding` and
    /// `onTop` are a label's alone: `box` an optional backing rectangle (see Colour; text or
    /// three numbers: alpha 1) `padding` pixels larger than the text, `onTop` drawing the label
    /// even where its point is hidden. `font` is a loadFont id (0 the bundled font).
    /// Item.setText changes the string later. A pick on a label answers the line hit as its
    /// face. A NUL in `text` is refused before the library is called.
    public func showText(_ text: String, at: SIMD3<Float>, mode: String = "label", size: Float = 12,
                         colour: any Colour = "white", align: String = "bottom-left",
                         offset: SIMD2<Float> = SIMD2<Float>(0, 0), box: (any Colour)? = nil, padding: Float = 4,
                         onTop: Bool = false, font: UInt32 = 0, right: SIMD3<Float>? = nil,
                         up: SIMD3<Float>? = nil) throws -> Item {
        guard let modeValue = View.textModes.first(where: { $0.0 == mode })?.1 else {
            throw ViewError("mode \(quoted(mode)): one of \(View.textModes.map { $0.0 }.joined(separator: ", "))")
        }
        guard let alignValue = View.alignments.first(where: { $0.0 == align })?.1 else {
            throw ViewError("align \(quoted(align)): one of \(View.alignments.map { $0.0 }.joined(separator: ", "))")
        }
        let s = try checkedText(text)
        let rgb = try paint("cadaclysm_view_show_text", colour)!
        let rgba = try box.map { try colourValues(library.table, $0) }
        return try add("cadaclysm_view_show_text", owner: nil) { t, v in
            s.withCString { chars -> UInt32 in
                var x = CadaclysmViewText()
                x.size = UInt32(MemoryLayout<CadaclysmViewText>.size)
                x.text = chars
                x.mode = modeValue
                x.at = (at.x, at.y, at.z)
                if let right { x.right = (right.x, right.y, right.z) }
                if let up { x.up = (up.x, up.y, up.z) }
                x.height = size
                x.rgb = (rgb[0], rgb[1], rgb[2])
                x.align = alignValue
                x.offset = (offset.x, offset.y)
                if let rgba { x.box_rgba = (rgba[0], rgba[1], rgba[2], rgba[3]) }
                x.box_padding = padding
                x.on_top = onTop ? 1 : 0
                x.font = font
                return t.pointee.show_text!(v, &x)
            }
        }
    }

    // -- overlays (1.24): a HUD over the whole window

    /// Rational cubic Beziers, sixteen floats each (x, y, z, w per control point, z not read:
    /// a profile's `beziers()`), in pixels (y up), as one overlay hung `x`, `y` pixels inward
    /// from `anchor`: loops split where a curve does not start where the last ended, closed
    /// where one ends where it started; stroked white unless `style` says otherwise, closed
    /// loops filled together by the even-odd rule only where it gives a fill. Drawn after
    /// everything else, never moved by the camera,
    /// kept in place as the window resizes; a click on it picks it (`ViewPick.overlay`) and
    /// nothing beneath. `showOverlay(_:anchor:x:y:style:)` takes a Profile (Blacksmith).
    public func showOverlay(curves beziers: [Float], anchor: Anchor, x: Float, y: Float,
                            style: OverlayStyle = OverlayStyle()) throws -> Overlay {
        try showOverlayCurves(beziers, own: nil, anchor: anchor, x: x, y: y, style: style)
    }
    /// `showOverlay(curves:)` with the profile's own colour, `own` (r, g, b, a), for the stroke
    /// rule: what Blacksmith's `showOverlay` of a Profile builds on.
    package func showOverlayCurves(_ beziers: [Float], own: [Float]?, anchor: Anchor, x: Float, y: Float,
                                   style: OverlayStyle) throws -> Overlay {
        if beziers.isEmpty || beziers.count % 16 != 0 {
            throw ViewError("show_overlay: 16 numbers a curve, at least one, not \(beziers.count)")
        }
        let n = try count(beziers.count / 16, "show_overlay")
        if let no = refusal("cadaclysm_view_show_overlay") { throw no }
        func isNone(_ c: (any Colour)?) -> Bool {
            (c as? String)?.trimmingCharacters(in: .whitespaces).lowercased() == "none"
        }
        var stroke: [Float]?
        if isNone(style.stroke) {
            stroke = nil
        } else if let given = style.stroke {
            stroke = try colourValues(library.table, given)
        } else {
            stroke = own ?? [1, 1, 1, 1]
        }
        var fill: [Float]?
        if let given = style.fill, !isNone(given) {
            fill = try colourValues(library.table, given)
        }
        if fill == nil && stroke == nil { throw ViewError("show_overlay: neither a fill nor a stroke") }
        return try add("cadaclysm_view_show_overlay", owner: nil, make: { Overlay(view: $0, id: $1, anchor: anchor) }) { t, v in
            withFloats(beziers) { b -> UInt32 in
                var o = CadaclysmViewOverlay()
                o.size = UInt32(MemoryLayout<CadaclysmViewOverlay>.size)
                o.anchor = anchor.rawValue
                o.beziers = b
                o.curve_count = n
                o.order = style.order
                o.offset = (x, y)
                if let fill { o.has_fill = 1; o.fill_rgba = (fill[0], fill[1], fill[2], fill.count > 3 ? fill[3] : 1) }
                if let stroke { o.has_stroke = 1; o.stroke_rgba = (stroke[0], stroke[1], stroke[2], stroke.count > 3 ? stroke[3] : 1) }
                o.stroke_width = style.strokeWidth
                return t.pointee.show_overlay!(v, &o)
            }
        }
    }
    /// Text over the window: its box hangs from `anchor` by the same point (its top-right
    /// corner for `.topRight`), `x`, `y` pixels inward -- the box's padding included where it
    /// has one. `size`, `colour`, `box`, `padding` and `font` as `showText`'s, in pixels;
    /// `order` its place among the overlays. `Item.setText` changes it cheaply (a frame counter).
    public func showOverlayText(_ text: String, anchor: Anchor, x: Float, y: Float, size: Float = 12,
                                colour: any Colour = "white", box: (any Colour)? = nil, padding: Float = 4,
                                font: UInt32 = 0, order: Int32 = 0) throws -> Overlay {
        let s = try checkedText(text)
        let rgb = try paint("cadaclysm_view_show_text", colour)!
        let rgba = try box.map { try colourValues(library.table, $0) }
        return try add("cadaclysm_view_show_text", owner: nil, make: { Overlay(view: $0, id: $1, anchor: anchor) }) { t, v in
            s.withCString { chars -> UInt32 in
                var x_ = CadaclysmViewText()
                x_.size = UInt32(MemoryLayout<CadaclysmViewText>.size)
                x_.text = chars
                x_.mode = UInt32(CADACLYSM_VIEW_TEXT_SCREEN)
                x_.height = size
                x_.rgb = (rgb[0], rgb[1], rgb[2])
                x_.align = anchor.rawValue
                x_.offset = (x, y)
                if let rgba { x_.box_rgba = (rgba[0], rgba[1], rgba[2], rgba[3]) }
                x_.box_padding = padding
                x_.on_top = 1
                x_.font = font
                x_.order = order
                return t.pointee.show_text!(v, &x_)
            }
        }
    }
    /// An image over the window: `rgba` (width x height x 4 bytes, rows from the top, straight
    /// alpha), its box hanging from `anchor` by the same point, `x`, `y` pixels inward, drawn
    /// `drawWidth` x `drawHeight` pixels (0: its own size) at `opacity` (above 0, at most 1).
    public func showOverlayImage(_ rgba: [UInt8], width: UInt32, height: UInt32, anchor: Anchor, x: Float, y: Float,
                                 drawWidth: Float = 0, drawHeight: Float = 0, opacity: Float = 1,
                                 order: Int32 = 0) throws -> Overlay {
        let need = try pixelBytes(width, height, "show_overlay_image")
        if rgba.count != need {
            throw ViewError("show_overlay_image: \(width) x \(height) pixels need \(need) bytes (w * h * 4), not \(rgba.count)")
        }
        if !(opacity > 0) {
            throw ViewError("show_overlay_image: opacity \(opacity): more than 0, at most 1 (0 would be the library's 1)")
        }
        return try add("cadaclysm_view_show_overlay_image", owner: nil, make: { Overlay(view: $0, id: $1, anchor: anchor) }) { t, v in
            withBytes(rgba) { px -> UInt32 in
                var image = CadaclysmViewOverlayImage()
                image.size = UInt32(MemoryLayout<CadaclysmViewOverlayImage>.size)
                image.anchor = anchor.rawValue
                image.rgba = px
                image.width = width
                image.height = height
                image.offset = (x, y)
                image.extent = (drawWidth, drawHeight)
                image.opacity = opacity
                image.order = order
                return t.pointee.show_overlay_image!(v, &image)
            }
        }
    }

    // -- the camera

    /// Turns the camera by a drag of dx, dy pixels.
    public func orbit(_ dx: Float, _ dy: Float) throws { try act("cadaclysm_view_orbit") { t, v in t.pointee.orbit!(v, dx, dy) } }
    /// Moves the camera by a drag of dx, dy pixels.
    public func pan(_ dx: Float, _ dy: Float) throws { try act("cadaclysm_view_pan") { t, v in t.pointee.pan!(v, dx, dy) } }
    /// Moves the camera by wheel steps.
    public func zoom(_ steps: Float) throws { try act("cadaclysm_view_zoom") { t, v in t.pointee.zoom!(v, steps) } }
    /// Turns the camera about its eye.
    public func look(_ dx: Float, _ dy: Float) throws { try act("cadaclysm_view_look") { t, v in t.pointee.look!(v, dx, dy) } }
    /// Moves the eye toward the target by `ratio`.
    public func dolly(_ ratio: Float) throws { try act("cadaclysm_view_dolly") { t, v in t.pointee.dolly!(v, ratio) } }
    /// Switches the projection.
    public func setOrthographic(_ on: Bool) throws {
        try act("cadaclysm_view_set_orthographic") { t, v in t.pointee.set_orthographic!(v, on) }
    }
    /// The clear colour, linear 0..1: numbers or text (see Colour).
    public func setBackground(_ rgb: any Colour) throws {
        let c = try paint("cadaclysm_view_set_background", rgb)
        try act("cadaclysm_view_set_background") { t, v in withColour(c) { t.pointee.set_background!(v, $0) } }
    }
    /// "top", "front", "right" or "iso".
    public func standard(_ name: String) throws {
        let which: [String: UInt32] = ["top": UInt32(CADACLYSM_VIEW_STANDARD_TOP), "front": UInt32(CADACLYSM_VIEW_STANDARD_FRONT),
                                       "right": UInt32(CADACLYSM_VIEW_STANDARD_RIGHT), "iso": UInt32(CADACLYSM_VIEW_STANDARD_ISO)]
        guard let w = which[name] else { throw ViewError("standard view '\(name)': one of top, front, right, iso") }
        try ok("cadaclysm_view_standard") { t, v in t.pointee.standard!(v, w) }
    }
    /// Fits the camera to everything shown.
    public func frame() throws { try ok("cadaclysm_view_frame") { t, v in t.pointee.frame!(v, 0) } }
    /// Whether a double click frames what it hit (off by default: it is a pick answered with
    /// `clicks` 2 and the camera stays). Applies where the view takes the pick itself (its own
    /// window, pump, run).
    public func setDoubleClickFrames(_ on: Bool) throws {
        try act("cadaclysm_view_set_double_click_frames") { t, v in t.pointee.set_double_click_frames!(v, on) }
    }
    /// Moves the orbit point to `point` (as a pick's `point`): the eye keeps its direction and
    /// distance from it, so the camera moves sideways and does not turn. Leaves fly mode. A
    /// point not finite, or one while viewports are set, is the library's refusal.
    public func focus(_ point: SIMD3<Float>) throws {
        var xyz = [point.x, point.y, point.z]
        try ok("cadaclysm_view_focus") { t, v in t.pointee.focus!(v, &xyz) }
    }
    /// How a left drag moves the camera: `.orbit` (about the target) or `.fly` (the view turns
    /// about the eye). A fly key (W, A, S, D, E, Q) sent through input enters fly mode and it
    /// stays after the key is let go; Tab toggles it; frame(), standard() and focus() leave it.
    public var navigation: Navigation {
        get throws {
            let (t, v) = try live("cadaclysm_view_navigation")
            return t.pointee.navigation!(v) == UInt32(CADACLYSM_VIEW_NAVIGATION_FLY) ? .fly : .orbit
        }
    }
    /// Panes of their own cameras; empty: the one camera again.
    public func setViewports(_ list: [Viewport]) throws {
        let n = try count(list.count, "viewports")
        var raw: [CadaclysmViewViewport] = []
        for p in list {
            if p.view.count != 16 { throw ViewError("16 numbers, not \(p.view.count)") }
            if p.projection.count != 16 { throw ViewError("16 numbers, not \(p.projection.count)") }
            var r = CadaclysmViewViewport()
            r.size = UInt32(MemoryLayout<CadaclysmViewViewport>.size)
            r.rect = (p.rect.x, p.rect.y, p.rect.z, p.rect.w)
            withUnsafeMutableBytes(of: &r.view) { _ = $0.bindMemory(to: Float.self).update(from: p.view) }
            withUnsafeMutableBytes(of: &r.projection) { _ = $0.bindMemory(to: Float.self).update(from: p.projection) }
            r.eye = (p.eye.x, p.eye.y, p.eye.z)
            r.grid = p.grid
            r.layer_mask = p.layerMask
            raw.append(r)
        }
        try ok("cadaclysm_view_set_viewports") { t, v in
            raw.withUnsafeBufferPointer { t.pointee.set_viewports!(v, raw.isEmpty ? nil : $0.baseAddress, n) }  // NULL, 0: none
        }
    }
    /// Exact surfaces (false) or triangles (true).
    public func setSurfaces(triangles: Bool) throws {
        try ok("cadaclysm_view_set_surfaces") { t, v in t.pointee.set_surfaces!(v, triangles ? 1 : 0) }
    }
    /// How plain parts are lit, as Python's `View.lighting`: "headlight" (the default) --
    /// whatever faces the camera is bright -- or "studio", a key light fixed above the scene
    /// with an ambient and a camera fill. Another name is refused before the library is called.
    public func setLighting(_ name: String) throws {
        guard name == "headlight" || name == "studio" else {
            throw ViewError("lighting '\(name)': 'headlight' or 'studio'")
        }
        let which = UInt32(name == "studio" ? CADACLYSM_VIEW_LIGHTING_STUDIO : CADACLYSM_VIEW_LIGHTING_HEADLIGHT)
        try ok("cadaclysm_view_set_lighting") { t, v in t.pointee.set_lighting!(v, which) }
    }
    /// The lighting in use: "headlight" or "studio".
    public var lighting: String {
        get throws {
            let (t, v) = try live("cadaclysm_view_lighting")
            return t.pointee.lighting!(v) == UInt32(CADACLYSM_VIEW_LIGHTING_STUDIO) ? "studio" : "headlight"
        }
    }
    // -- the timeline (CAM jobs shown with showMachining play on it)

    /// Plays the timeline at `speed` times real time; it stops at its end unless `setLoop()` is on
    /// (`play` at the end starts again from 0). A speed that is not finite is refused.
    public func play(speed: Double = 1) throws {
        guard speed.isFinite else { throw ViewError("play speed: a finite number") }
        try ok("cadaclysm_view_timeline_play") { t, v in t.pointee.timeline_play!(v, speed) }
    }
    public func pause() throws { try ok("cadaclysm_view_timeline_pause") { t, v in t.pointee.timeline_pause!(v) } }
    /// Sets the clock, clamped to [0, duration].
    public func seek(_ seconds: Double) throws {
        guard seconds.isFinite else { throw ViewError("seek seconds: a finite number") }
        try ok("cadaclysm_view_timeline_seek") { t, v in t.pointee.timeline_seek!(v, seconds) }
    }
    public func setLoop(_ on: Bool = true) throws {
        try ok("cadaclysm_view_timeline_set_loop") { t, v in t.pointee.timeline_set_loop!(v, on) }
    }
    /// Plays a kernel animation on the timeline (1.27) -- `animation` is the handle
    /// `View+Solid.swift`'s `playAnimation` passes (nil is the library's "animation is null"
    /// refusal) -- bound as `bindings` say; the view plays its own copy. The new track's id.
    package func playAnimationHandle(_ animation: OpaquePointer?, _ bindings: [AnimationBinding]) throws -> UInt32 {
        let call = "cadaclysm_view_play_animation"
        if let no = refusal(call) { throw no }
        var targets: [UnsafeMutablePointer<CChar>?] = []
        defer { targets.forEach { free($0) } }
        var raw: [CadaclysmViewAnimationBinding] = []
        for (k, b) in bindings.enumerated() {
            if b.target.unicodeScalars.contains("\0") {
                throw ViewError("binding \(k): target \(quoted(b.target)) holds a NUL character")
            }
            let c = strdup(b.target)
            targets.append(c)
            raw.append(CadaclysmViewAnimationBinding(target: UnsafePointer(c), item: b.item,
                                                      node: b.node ?? UInt32(CADACLYSM_VIEW_ALL_NODES)))
        }
        let n = try count(raw.count, "play_animation")
        let (t, v) = (library.table, handle!)
        let id = raw.withUnsafeBufferPointer { t.pointee.play_animation!(v, animation, raw.isEmpty ? nil : $0.baseAddress, n) }
        if id == 0 { throw libraryError(t) }
        return id
    }
    /// Takes an animation track off the timeline (1.27), putting back what it drove. A track
    /// no animation played is refused: "timeline_remove: no track N".
    public func removeTrack(_ track: UInt32) throws {
        try ok("cadaclysm_view_timeline_remove") { t, v in t.pointee.timeline_remove!(v, track) }
    }
    /// The clock, seconds.
    public var time: Double {
        get throws {
            let (t, v) = try live("cadaclysm_view_timeline_time")
            return t.pointee.timeline_time!(v)
        }
    }
    /// The timeline's length, seconds.
    public var duration: Double {
        get throws {
            let (t, v) = try live("cadaclysm_view_timeline_duration")
            return t.pointee.timeline_duration!(v)
        }
    }
    public var playing: Bool {
        get throws {
            let (t, v) = try live("cadaclysm_view_timeline_playing")
            return t.pointee.timeline_playing!(v)
        }
    }
    /// One line per track at the clock's time, e.g. "move 370 of 638 - T1 flat 6 mm"; none when
    /// nothing is on the timeline. Asks the length, then fills a buffer for it (asking again
    /// when the line grew between the two calls, as Python does).
    public func status() throws -> [String] {
        let (t, v) = try live("cadaclysm_view_timeline_status")
        var n = t.pointee.timeline_status!(v, nil, 0)
        while n > 0 {
            var buffer = [CChar](repeating: 0, count: n + 1)
            let room = buffer.count
            let got = buffer.withUnsafeMutableBufferPointer { t.pointee.timeline_status!(v, $0.baseAddress, room) }
            if got < room {
                if got == 0 { return [] }
                let line = String(decoding: buffer[0..<got].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                return line.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }
            n = got
        }
        return []
    }
    /// Switches a `CADACLYSM_VIEW_LAYER_*` layer (`CADACLYSM_VIEW_LAYER_TEXT`: every text item).
    public func setLayer(_ which: UInt32, _ on: Bool) throws {
        try ok("cadaclysm_view_set_layer") { t, v in t.pointee.set_layer!(v, which, on) }
    }
    /// Switches user layer `layer`, 0...31, on or off in every viewport (all start on); see
    /// `Item.userLayer`. A layer past 31 is refused.
    public func setUserLayer(_ layer: UInt32, _ on: Bool) throws {
        try ok("cadaclysm_view_set_user_layer") { t, v in t.pointee.set_user_layer!(v, layer, on) }
    }
    /// Levels of detail, as Python's `View.lod`: parts of `minTriangles` or more (0: the
    /// library's default, 2,048) get coarser levels, and a moving frame draws as `motion`
    /// says -- "detailed" or "smooth" (see wakeMs); nil turns them off (the default).
    public func setLod(_ motion: String? = "detailed", minTriangles: UInt32 = 0) throws {
        guard let motion else { return try ok("cadaclysm_view_set_lod") { t, v in t.pointee.set_lod!(v, nil) } }
        guard motion == "detailed" || motion == "smooth" else {
            throw ViewError("motion '\(motion)': one of detailed, smooth or none")
        }
        var lod = CadaclysmViewLod()
        lod.size = UInt32(MemoryLayout<CadaclysmViewLod>.size)
        lod.min_triangles = minTriangles
        lod.motion = UInt32(motion == "smooth" ? CADACLYSM_VIEW_LOD_SMOOTH : CADACLYSM_VIEW_LOD_DETAILED)
        try ok("cadaclysm_view_set_lod") { t, v in t.pointee.set_lod!(v, &lod) }
    }
    /// The colour every edge draws in: `rgb` (see Colour), or with `fromPart` each part's own
    /// colour, brightened so an edge reads over its faces. An item's `setEdgeColour` draws over it.
    public func setEdgeColour(_ rgb: any Colour, fromPart: Bool = false) throws {
        try setLineColour(UInt32(CADACLYSM_VIEW_LAYER_EDGES), rgb, fromPart)
    }
    /// The edges' colour in use.
    public func edgeColour() throws -> LineColour { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_EDGES)) }
    /// The colour every curve (a curves or lines item's) draws in: `rgb`, or with `fromPart` each
    /// part's own colour -- the default.
    public func setCurveColour(_ rgb: any Colour, fromPart: Bool = false) throws {
        try setLineColour(UInt32(CADACLYSM_VIEW_LAYER_CURVES), rgb, fromPart)
    }
    /// The curves' colour in use.
    public func curveColour() throws -> LineColour { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_CURVES)) }
    /// The colour every isocurve draws in: `rgb`, or with `fromPart` each part's own colour.
    public func setIsocurveColour(_ rgb: any Colour, fromPart: Bool = false) throws {
        try setLineColour(UInt32(CADACLYSM_VIEW_LAYER_ISOCURVES), rgb, fromPart)
    }
    /// The isocurves' colour in use.
    public func isocurveColour() throws -> LineColour { try lineColour(UInt32(CADACLYSM_VIEW_LAYER_ISOCURVES)) }
    private func setLineColour(_ layer: UInt32, _ rgb: any Colour, _ fromPart: Bool) throws {
        let c = try paint("cadaclysm_view_set_line_colour", rgb)
        try ok("cadaclysm_view_set_line_colour") { t, v in withColour(c) { t.pointee.set_line_colour!(v, layer, $0, fromPart ? 1 : 0) } }
    }
    private func lineColour(_ layer: UInt32) throws -> LineColour {
        var rgb: [Float] = [0, 0, 0]
        var fromPart: UInt32 = 0
        try ok("cadaclysm_view_line_colour") { t, v in
            rgb.withUnsafeMutableBufferPointer { t.pointee.line_colour!(v, layer, $0.baseAddress, &fromPart) }
        }
        return LineColour(colour: SIMD3<Float>(rgb[0], rgb[1], rgb[2]), fromPart: fromPart != 0)
    }
    /// The view-wide occluded style; nil sets the default back. "solid" and "off" items never use it.
    public func setOccludedStyle(_ style: OccludedStyle?) throws {
        guard let style else { return try ok("cadaclysm_view_set_occluded_style") { t, v in t.pointee.set_occluded_style!(v, nil) } }
        var raw = CadaclysmViewOccludedStyle()
        raw.size = UInt32(MemoryLayout<CadaclysmViewOccludedStyle>.size)
        raw.dash = style.dash
        raw.gap = style.gap
        raw.dim = style.dim
        if let c = style.colour {
            raw.has_colour = 1
            raw.colour = (c.x, c.y, c.z)
        }
        try ok("cadaclysm_view_set_occluded_style") { t, v in t.pointee.set_occluded_style!(v, &raw) }
    }
    /// The colours hover, selected and first points draw in (1.28, `Item.setPointStates`):
    /// numbers or text each (see Colour); nil restores that state's default (hover #9CD3FF,
    /// selected and first #378ADD). A colour not finite is the library's refusal, and changes none.
    public func setPointStateColours(hover: (any Colour)? = nil, selected: (any Colour)? = nil,
                                     first: (any Colour)? = nil) throws {
        let call = "cadaclysm_view_set_point_state_colours"
        let h = try paint(call, hover), s = try paint(call, selected), f = try paint(call, first)
        try act(call) { t, v in
            withColour(h) { h in withColour(s) { s in withColour(f) { f in t.pointee.set_point_state_colours!(v, h, s, f) } } }
        }
    }
    /// Names viewport `viewport` (1.28): `text` top left inside it at 12 points in `colour`
    /// (numbers or text, see Colour; nil: white); nil text clears it. Kept across `setViewportRects`,
    /// and across `setViewports` while the index survives. A pick on it answers
    /// `viewportLabel`. A NUL in the text is refused before the library is called; no such
    /// viewport, by the library.
    public func setViewportLabel(_ viewport: UInt32, text: String?, colour: (any Colour)? = nil) throws {
        let call = "cadaclysm_view_set_viewport_label"
        let s = try text.map(checkedText)
        let c = try paint(call, colour)
        try ok(call) { t, v in
            withColour(c) { c in
                guard let s else { return t.pointee.set_viewport_label!(v, viewport, nil, c) }
                return s.withCString { t.pointee.set_viewport_label!(v, viewport, $0, c) }
            }
        }
    }
    /// Frames viewport `viewport` in `colour` (1.28, numbers or text, see Colour), one point wide
    /// inside its edge; nil clears it. Never picked. No such viewport is the library's refusal.
    public func setViewportBorder(_ viewport: UInt32, colour: (any Colour)?) throws {
        let call = "cadaclysm_view_set_viewport_border"
        let c = try paint(call, colour)
        try ok(call) { t, v in withColour(c) { t.pointee.set_viewport_border!(v, viewport, $0) } }
    }
    /// The view's occluded style, the defaults as their values.
    public func occludedStyle() throws -> OccludedStyle {
        var raw = CadaclysmViewOccludedStyle()
        raw.size = UInt32(MemoryLayout<CadaclysmViewOccludedStyle>.size)
        try ok("cadaclysm_view_occluded_style") { t, v in t.pointee.occluded_style!(v, &raw) }
        let colour = raw.has_colour != 0 ? SIMD3<Float>(raw.colour.0, raw.colour.1, raw.colour.2) : nil
        return OccludedStyle(dash: raw.dash, gap: raw.gap, dim: raw.dim, colour: colour)
    }
    /// The number of clip-plane slots (`CADACLYSM_VIEW_CLIP_PLANES`, 1.31).
    public static let clipPlanes = UInt32(CADACLYSM_VIEW_CLIP_PLANES)
    /// Sets clip-plane slot `slot` (0..<`View.clipPlanes`): a point is drawn only where every
    /// set plane keeps it. Refused, changing nothing, for a slot past the last, a zero or
    /// non-finite normal, a colour outside 0..1, a hatch without a cap, or a bad angle, spacing
    /// or width. The terminal library draws no clip planes and refuses one.
    public func setClipPlane(_ slot: UInt32, _ plane: ClipPlane) throws {
        var raw = plane.raw
        try ok("cadaclysm_view_set_clip_plane") { t, v in t.pointee.set_clip_plane!(v, slot, &raw) }
    }
    /// `setClipPlane` with the defaults as parameter defaults: no cap, no hatch, angle 45,
    /// spacing 0 (automatic), width 1; no outline, outline width 1.
    public func setClipPlane(_ slot: UInt32, point: SIMD3<Double>, normal: SIMD3<Double>, cap: SIMD3<Float>? = nil,
                             hatch: SIMD3<Float>? = nil, hatchAngle: Float = 45, hatchSpacing: Float = 0,
                             hatchWidth: Float = 1, outline: SIMD3<Float>? = nil, outlineWidth: Float = 1) throws {
        try setClipPlane(slot, ClipPlane(point: point, normal: normal, cap: cap, hatch: hatch,
                                         hatchAngle: hatchAngle, hatchSpacing: hatchSpacing, hatchWidth: hatchWidth,
                                         outline: outline, outlineWidth: outlineWidth))
    }
    /// Empties clip-plane slot `slot`; an empty slot stays empty.
    public func clearClipPlane(_ slot: UInt32) throws {
        try ok("cadaclysm_view_set_clip_plane") { t, v in t.pointee.set_clip_plane!(v, slot, nil) }
    }
    /// Clip-plane slot `slot`, nil where it is empty: as set, but with the normal of unit length
    /// and a zero width as 1; without a hatch (outline), its fields are the defaults (45, 0, 1;
    /// 1). A slot past the last is refused.
    public func clipPlane(_ slot: UInt32) throws -> ClipPlane? {
        let (t, v) = try live("cadaclysm_view_clip_plane")
        var raw = CadaclysmViewClipPlane()
        raw.size = UInt32(MemoryLayout<CadaclysmViewClipPlane>.size)
        if !t.pointee.clip_plane!(v, slot, &raw) {
            if slot >= View.clipPlanes { throw libraryError(t) }
            return nil  // an empty slot
        }
        return ClipPlane(raw)
    }
    /// The number of viewports that may have a clip set of their own
    /// (`CADACLYSM_VIEW_CLIP_VIEWPORTS`, 1.32).
    public static let clipViewports = UInt32(CADACLYSM_VIEW_CLIP_VIEWPORTS)
    /// How the view-wide planes combine (1.32): `.intersection` (the default) or `.cutaway`.
    /// `.inherit` is a viewport's, refused here. The terminal library takes `.intersection` and
    /// refuses `.cutaway`.
    public func setClipMode(_ mode: ClipMode) throws {
        try ok("cadaclysm_view_set_clip_mode") { t, v in t.pointee.set_clip_mode!(v, mode.rawValue) }
    }
    /// How the view-wide planes combine (1.32).
    public func clipMode() throws -> ClipMode {
        let (t, v) = try live("cadaclysm_view_clip_mode")
        return ClipMode(rawValue: t.pointee.clip_mode!(v)) ?? .intersection
    }
    /// Turns material textures on or off (1.33; on by default): off, a textured part draws its
    /// base colour factor alone. The terminal and render-view libraries accept it and draw
    /// colours either way.
    public func setTextures(_ on: Bool) throws {
        try ok("cadaclysm_view_set_textures") { t, v in t.pointee.set_textures!(v, on) }
    }
    /// Whether material textures are drawn (1.33).
    public func textures() throws -> Bool {
        let (t, v) = try live("cadaclysm_view_textures")
        return t.pointee.textures!(v)
    }
    /// Sets slot `slot` of viewport `viewport`'s own clip set (1.32), as `setClipPlane` sets the
    /// view-wide one, in that viewport only: the first gives the viewport a set of its own
    /// (every other slot empty, mode `.intersection`), which it draws, picks and snaps with
    /// instead of the view-wide set. With no viewports set, viewport 0 is the window. A viewport
    /// past the last (or past `View.clipViewports` - 1) is refused, as is what `setClipPlane`
    /// refuses.
    public func setViewportClipPlane(_ viewport: UInt32, _ slot: UInt32, _ plane: ClipPlane) throws {
        var raw = plane.raw
        try ok("cadaclysm_view_set_viewport_clip_plane") { t, v in
            t.pointee.set_viewport_clip_plane!(v, viewport, slot, &raw)
        }
    }
    /// `setViewportClipPlane` with `setClipPlane`'s parameter defaults.
    public func setViewportClipPlane(_ viewport: UInt32, _ slot: UInt32, point: SIMD3<Double>, normal: SIMD3<Double>,
                                     cap: SIMD3<Float>? = nil, hatch: SIMD3<Float>? = nil, hatchAngle: Float = 45,
                                     hatchSpacing: Float = 0, hatchWidth: Float = 1, outline: SIMD3<Float>? = nil,
                                     outlineWidth: Float = 1) throws {
        try setViewportClipPlane(viewport, slot, ClipPlane(point: point, normal: normal, cap: cap, hatch: hatch,
                                                           hatchAngle: hatchAngle, hatchSpacing: hatchSpacing,
                                                           hatchWidth: hatchWidth, outline: outline,
                                                           outlineWidth: outlineWidth))
    }
    /// Empties slot `slot` of viewport `viewport`'s own set (1.32); the set stays the
    /// viewport's (`setViewportClipMode(viewport, .inherit)` drops it).
    public func clearViewportClipPlane(_ viewport: UInt32, _ slot: UInt32) throws {
        try ok("cadaclysm_view_set_viewport_clip_plane") { t, v in
            t.pointee.set_viewport_clip_plane!(v, viewport, slot, nil)
        }
    }
    /// Slot `slot` of viewport `viewport`'s own set (1.32), as `clipPlane` answers the
    /// view-wide one; nil where the slot is empty or the viewport has no set of its own (it
    /// draws with the view-wide planes). A slot past the last is refused.
    public func viewportClipPlane(_ viewport: UInt32, _ slot: UInt32) throws -> ClipPlane? {
        let (t, v) = try live("cadaclysm_view_viewport_clip_plane")
        var raw = CadaclysmViewClipPlane()
        raw.size = UInt32(MemoryLayout<CadaclysmViewClipPlane>.size)
        if !t.pointee.viewport_clip_plane!(v, viewport, slot, &raw) {
            if slot >= View.clipPlanes { throw libraryError(t) }
            return nil  // an empty slot, or no set of its own
        }
        return ClipPlane(raw)
    }
    /// Viewport `viewport`'s clip mode (1.32): `.intersection` or `.cutaway` sets its own set's
    /// mode, giving it a set of its own if it had none (with no planes: that viewport is then
    /// not clipped while the others are); `.inherit` drops its set, back to the view-wide one.
    public func setViewportClipMode(_ viewport: UInt32, _ mode: ClipMode) throws {
        try ok("cadaclysm_view_set_viewport_clip_mode") { t, v in
            t.pointee.set_viewport_clip_mode!(v, viewport, mode.rawValue)
        }
    }
    /// Viewport `viewport`'s clip mode (1.32): its own set's, or `.inherit` where it has none
    /// (and for a viewport past the last).
    public func viewportClipMode(_ viewport: UInt32) throws -> ClipMode {
        let (t, v) = try live("cadaclysm_view_viewport_clip_mode")
        return ClipMode(rawValue: t.pointee.viewport_clip_mode!(v, viewport)) ?? .inherit
    }
    /// Milliseconds until `needsDraw` turns true by itself (a resting frame refining the
    /// picture); 0 when one is owed now, nil when none is coming.
    public func wakeMs() throws -> UInt32? {
        let (t, v) = try live("cadaclysm_view_wake_ms")
        let ms = t.pointee.wake_ms!(v)
        return ms == UInt32.max ? nil : ms
    }

    // -- the rest

    /// What is under (x, y) of a viewport, nil for nothing. As Python's pick: a view never
    /// drawn is drawn first; the library's own error, or "pick: the answer never landed (...)".
    public func pick(x: UInt32, y: UInt32, viewport: UInt32 = 0) throws -> ViewPick? {
        let (t, v) = try live(drawn != 0 ? "cadaclysm_view_request_pick_in" : "cadaclysm_view_draw")
        var raw = rawPick()
        var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
        let errCount = err.count
        var once = drawn
        let found = cvl_pick(t, v, &once, viewport, x, y, &raw, &err, errCount)
        drawn = once
        if found == 0 { throw ViewError(text(err)) }
        return pickHit(raw) ? pickOf(raw) : nil
    }
    /// The newest pick answer that has landed, without asking or waiting -- Python's
    /// last_pick: a click or tap in the view's own window (pump lands them as it draws), a
    /// double click's (`clicks` 2), or one an `input` asked for, landed by the draws after it.
    /// `landed` false while none has; landed with `pick` nil for a click on nothing. Each
    /// answer is read once, and a newer one replaces one not read yet. A failure other than
    /// "no answer yet" is the library's own message.
    public func lastPick() throws -> (landed: Bool, pick: ViewPick?) {
        let (t, v) = try live("cadaclysm_view_pick_result")
        var raw = rawPick()
        if t.pointee.pick_result!(v, &raw) { return (true, pickHit(raw) ? pickOf(raw) : nil) }
        let said = lastError(t)
        if !said.isEmpty && !said.hasSuffix("no pick result") { throw ViewError(said) }
        return (false, nil)
    }
    /// What a snap may land on: the default kinds (`SnapKind.defaultKinds`, the default), every
    /// kind (`Set(SnapKind.allCases)`), some, or nil (or none) to switch snapping off, as a view
    /// starts. `aperturePx` is how far from the cursor a point kind may lie (0: the library's
    /// default, 10 points); `marker` whether the view draws the marker at the snap. Once on, a
    /// mouse hovering over a view in its own window snaps, and so does a click (`lastSnap` reads
    /// them); `snap` asks one at any pixel. Where kinds compete, a corner beats the face it sits on.
    public func setSnap(_ kinds: Set<SnapKind>? = SnapKind.defaultKinds, aperturePx: Float = 0, marker: Bool = true) throws {
        var raw = CadaclysmViewSnapSettings()
        raw.size = UInt32(MemoryLayout<CadaclysmViewSnapSettings>.size)
        raw.kinds = (kinds ?? []).reduce(0) { $0 | $1.rawValue }
        raw.aperture_px = aperturePx
        raw.marker = marker ? 1 : 0
        try ok("cadaclysm_view_set_snap") { t, v in t.pointee.set_snap!(v, &raw) }
    }
    /// The snap under (x, y) of a viewport, nil where nothing in the kinds `setSnap` chose lies
    /// there -- always, while snapping is off. As Python's snap: a view never drawn is drawn
    /// first, then frames until the answer lands; the library's own error, or "snap: the answer
    /// never landed (...)".
    public func snap(x: UInt32, y: UInt32, viewport: UInt32 = 0) throws -> ViewSnap? {
        let (t, v) = try live(drawn != 0 ? "cadaclysm_view_request_snap_in" : "cadaclysm_view_draw")
        var raw = CadaclysmViewSnap()
        var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
        let errCount = err.count
        var once = drawn
        let found = cvl_snap(t, v, &once, viewport, x, y, &raw, &err, errCount)
        drawn = once
        if found == 0 { throw ViewError(text(err)) }
        return snapOf(raw)
    }
    /// The newest snap answer that has landed, without asking or waiting -- Python's
    /// last_snap: a hover or click in the view's own window (pump lands them as it draws), or
    /// one an `input` asked for. `landed` false while none has; landed with `snap` nil for one
    /// that found nothing. Each answer is read once; a hover's never replaces a click's not read
    /// yet. A failure other than "no answer yet" is the library's own message.
    public func lastSnap() throws -> (landed: Bool, snap: ViewSnap?) {
        let (t, v) = try live("cadaclysm_view_snap_result")
        var raw = CadaclysmViewSnap()
        raw.size = UInt32(MemoryLayout<CadaclysmViewSnap>.size)
        if t.pointee.snap_result!(v, &raw) { return (true, snapOf(raw)) }
        let said = lastError(t)
        if !said.isEmpty && !said.hasSuffix("no snap result") { throw ViewError(said) }
        return (false, nil)
    }
    /// The angle lock (1.30): snaps that land on no point kind are turned about `point` (world,
    /// three numbers) onto the nearest multiple of `stepDeg` (above 0, at most 180), in the
    /// work plane's directions or the plane facing the eye; the answer is `plane` with its
    /// `lockedAngle` and one guide from the base. nil clears it (`stepDeg` then ignored). A point
    /// other than three numbers is refused here; one not finite, or a step out of range, by the
    /// library.
    public func setSnapBase(_ point: [Double]?, stepDeg: Float = 15) throws {
        if let point, point.count != 3 { throw ViewError("set_snap_base: the base is 3 numbers, not \(point.count)") }
        let xyz = point.map { $0.map { Float($0) } }
        try ok("cadaclysm_view_set_snap_base") { t, v in
            guard let xyz else { return t.pointee.set_snap_base!(v, nil, stepDeg) }  // NULL clears, never zeros
            return xyz.withUnsafeBufferPointer { t.pointee.set_snap_base!(v, $0.baseAddress, stepDeg) }
        }
    }
    /// How far a pick reaches for lines, points and glyphs (1.30), in points times the screen
    /// density: 0 restores the default, 4; others clamp to 1..32. A negative size or one that
    /// is not finite is refused. Faces are always the pixel under the cursor.
    public func setPickAperture(_ points: Float) throws {
        try ok("cadaclysm_view_set_pick_aperture") { t, v in t.pointee.set_pick_aperture!(v, points) }
    }
    /// What lies in a rectangle of `viewport` (1.30): `x`, `y`, `w`, `h` in device pixels from
    /// its top left (a negative `w` or `h` flips it). With `crossing`, everything with a visible
    /// part inside; else what lies wholly inside and is visible somewhere. Hidden things come
    /// only drawn x-ray or on top; text, images, overlays, viewport labels, machining stocks and
    /// isocurves are left out. Sorted by item, kind, index. CPU only: it draws nothing. A
    /// rectangle that is not finite and an unknown viewport are the library's refusals; a kind
    /// this module does not know (a later library's) is refused, not guessed.
    public func pickRect(x: Float, y: Float, w: Float, h: Float, crossing: Bool = true, viewport: UInt32 = 0) throws -> [RectHit] {
        let (t, v) = try live("cadaclysm_view_pick_rect")
        var out = [CadaclysmViewRectHit](repeating: CadaclysmViewRectHit(), count: 64)
        while true {
            let total = out.withUnsafeMutableBufferPointer { t.pointee.pick_rect!(v, viewport, x, y, w, h, crossing, $0.baseAddress, $0.count) }
            if total == 0 && !lastError(t).isEmpty { throw libraryError(t) }
            if total <= out.count {
                out.removeLast(out.count - total)
                break
            }
            // More than the buffer held: ask again with room for them all, never a cut list.
            out = [CadaclysmViewRectHit](repeating: CadaclysmViewRectHit(), count: total)
        }
        return try out.map { h in
            guard let kind = HitKind(rawValue: h.kind) else {
                throw ViewError("cadaclysm_view_pick_rect: the library answered hit kind \(h.kind), not a CADACLYSM_VIEW_HIT_* kind")
            }
            return RectHit(item: h.item, kind: kind, index: h.index)
        }
    }
    /// Hides the snap marker and drops any snap asked or answered and not yet read.
    public func clearSnap() throws {
        try act("cadaclysm_view_clear_snap") { t, v in t.pointee.clear_snap!(v) }
    }
    /// The plane `grid` and `plane` snaps land on, in place of the ground grid: through
    /// `origin`, its grid lines along `xAxis` and across it, `step` apart (0: the ground grid's
    /// spacing). The axes need not be unit length, but must not be parallel. nil as `origin`
    /// puts the ground grid back.
    public func setWorkPlane(origin: SIMD3<Double>?, xAxis: SIMD3<Double> = SIMD3(1, 0, 0),
                             normal: SIMD3<Double> = SIMD3(0, 0, 1), step: Double = 0) throws {
        guard let origin else {
            return try ok("cadaclysm_view_clear_work_plane") { t, v in t.pointee.clear_work_plane!(v) }
        }
        let o = [origin.x, origin.y, origin.z], x = [xAxis.x, xAxis.y, xAxis.z], n = [normal.x, normal.y, normal.z]
        try ok("cadaclysm_view_set_work_plane") { t, v in t.pointee.set_work_plane!(v, o, x, n, step) }
    }
    /// Draws one frame.
    public func draw() throws {
        try ok("cadaclysm_view_draw") { t, v in t.pointee.draw!(v) }
        drawn = 1
    }
    /// The oldest input event the view's own window handled and has not handed out yet,
    /// without waiting; nil while there is none. The window still orbits, zooms and closes on
    /// its own -- the events report what it handled, they do not stop it. A view in a host's
    /// window, or offscreen, queues nothing. Still read after the window closed. A failure
    /// other than "no event" is the library's own message.
    public func nextEvent() throws -> ViewInputEvent? {
        if ccadaclysm_view_thread() != thread { throw ViewError("cadaclysm_view_next_event: a view belongs to the thread that made it") }
        guard let v = handle else { throw ViewError("cadaclysm_view_next_event: the view is closed") }
        let t = library.table
        var raw = CadaclysmViewInputEvent()
        raw.size = UInt32(MemoryLayout<CadaclysmViewInputEvent>.size)
        raw.pick_viewport_label = -1  // no label hit, until the library says otherwise
        raw.pick_segment = UInt32.max  // 1.30: no segment, likewise
        if t.pointee.next_event!(v, &raw) { return inputEventOf(raw, yUp: yUp) }
        let said = lastError(t)
        if !said.isEmpty && !said.hasSuffix("no event") { throw ViewError(said) }
        return nil
    }
    /// Every event waiting now, oldest first (`nextEvent` until nil): read between pumps.
    public func events() throws -> [ViewInputEvent] {
        var all: [ViewInputEvent] = []
        while let e = try nextEvent() { all.append(e) }
        return all
    }
    /// Closes the view's own window as its close button does: `isClosed` turns true, a
    /// `.close` event is queued, a loop around `pump` ends; the view lives on until close().
    /// Nothing for a window already closed. A view in a host's window or offscreen has none:
    /// the library refuses it.
    public func closeWindow() throws {
        if ccadaclysm_view_thread() == thread && handle != nil && windowClosed { return }
        try ok("cadaclysm_view_close") { t, v in t.pointee.close!(v) }
        markClosed()
    }
    /// run() with each input event handed to `onEvent` on this thread as the window handles
    /// it, between pumps -- it may change the scene or the camera. Returning false closes the
    /// window and ends the run; true goes on. The `.close` event is handed over last, whatever
    /// closed the window. The camera the window closed on, with the last pick: the answer the
    /// last click left for `lastPick`, else the last `.pick` event's.
    @discardableResult public func run(_ onEvent: (ViewInputEvent) throws -> Bool) throws -> Camera {
        let (t, v) = try live("cadaclysm_view_pump")
        let open = UInt32(CADACLYSM_VIEW_OPEN), closed = UInt32(CADACLYSM_VIEW_CLOSED)
        var picked: ViewPick? = nil
        var closing: Camera? = nil
        var stopping = false
        while closing == nil {
            var state = closed
            if !windowClosed {
                state = t.pointee.pump!(v, 16)
                if state != open && state != closed { throw libraryError(t) }
            }
            while let e = try nextEvent() {
                if case .pick(let p) = e.kind { picked = p }
                if case .close(let c) = e.kind {
                    closing = c
                    if !stopping { _ = try onEvent(e) }
                    break
                }
                if !stopping, try !onEvent(e) {
                    stopping = true
                    try closeWindow()
                }
            }
            if state == closed && closing == nil { throw ViewError("run: the window closed with no close event") }
        }
        var out = rawPick()
        if t.pointee.pick_result!(v, &out) { picked = pickHit(out) ? pickOf(out) : nil }
        markClosed()
        let c = closing!
        return Camera(eye: c.eye, target: c.target, up: c.up, orthographic: c.orthographic, azimuth: c.azimuth,
                      elevation: c.elevation, pick: picked)
    }
    /// Blocks until the window is closed: the camera it was left at (read in this view's up
    /// axis) and the last pick. The window is then closed (as Python's run): every call but
    /// close() refuses.
    @discardableResult public func run() throws -> Camera {
        let (t, v) = try live("cadaclysm_view_run")
        var cam = CadaclysmViewCamera()
        cam.size = UInt32(MemoryLayout<CadaclysmViewCamera>.size)
        var pick = rawPick()
        if !t.pointee.run!(v, &cam, &pick) { throw libraryError(t) }
        markClosed()
        return camera(cam, pick, yUp: yUp)
    }
    /// What image() reads, in physical pixels.
    public func size() throws -> (width: UInt32, height: UInt32) {
        var width: UInt32 = 0, height: UInt32 = 0
        try ok("cadaclysm_view_size") { t, v in t.pointee.size!(v, &width, &height) }
        return (width, height)
    }
    /// One frame at the view's current size, read back.
    public func image() throws -> ViewImage {
        let (width, height) = try size()
        var pixels = [UInt8](repeating: 0, count: try pixelBytes(width, height, "image"))
        let (t, v) = try live("cadaclysm_view_image")
        let done = pixels.withUnsafeMutableBufferPointer { t.pointee.image!(v, $0.isEmpty ? standInU8 : $0.baseAddress, $0.count) }
        if !done { throw libraryError(t) }
        return ViewImage(width: width, height: height, rgba: pixels)
    }
    /// The frame as a PNG.
    public func save(_ path: String) throws {
        let picture = try image()
        var err = [CChar](repeating: 0, count: Int(CVL_ERROR))
        let errCount = err.count
        let written = withBytes(picture.rgba) { cvl_write_png(path, $0, picture.width, picture.height, &err, errCount) }
        if written == 0 { throw ViewError(text(err)) }
    }
    /// A host's event (`CadaclysmViewEvent`'s fields, `kind` a `CADACLYSM_VIEW_EVENT_*`): the
    /// `CADACLYSM_VIEW_INPUT_*` bits. On a window of the view's own the close bit (Escape)
    /// closes it, as the user closing it does; close() still owes the destroy.
    public func input(kind: UInt32, x: Float = 0, y: Float = 0, button: UInt32 = 0, pointerID: UInt32 = 0,
                      pointer: UInt32 = 0, shift: Bool = false, wheelY: Float = 0, key: String? = nil,
                      keyDown: Bool = true, timeMS: Double = 0) throws -> UInt32 {
        let (t, v) = try live("cadaclysm_view_input")
        var e = CadaclysmViewEvent()
        e.size = UInt32(MemoryLayout<CadaclysmViewEvent>.size)
        e.kind = kind; e.pointer_id = pointerID; e.pointer = pointer; e.button = button; e.shift = shift ? 1 : 0
        e.x = x; e.y = y; e.wheel_y = wheelY; e.key_down = keyDown ? 1 : 0; e.time_ms = timeMS
        let bits: UInt32
        if let key { bits = key.withCString { k in e.key = k; return t.pointee.input!(v, &e) } }
        else { bits = t.pointee.input!(v, &e) }
        if bits == 0 && !lastError(t).isEmpty { throw libraryError(t) }
        if bits & UInt32(CADACLYSM_VIEW_INPUT_CLOSE) != 0 && ownWindow { markClosed() }
        return bits
    }
    /// Sets the view's size in physical pixels.
    public func resize(width: UInt32, height: UInt32) throws {
        try ok("cadaclysm_view_resize") { t, v in t.pointee.resize!(v, width, height) }
    }
    /// Whether the view owes a frame.
    public func needsDraw() throws -> Bool {
        let (t, v) = try live("cadaclysm_view_needs_draw")
        return t.pointee.needs_draw!(v)
    }
    /// What the view has drawn (cadaclysm_view_stats, 1.25): an FPS counter read from it stays
    /// right while the scene is still.
    public func stats() throws -> ViewStats {
        var out = CadaclysmViewStats()
        out.size = UInt32(MemoryLayout<CadaclysmViewStats>.size)
        try ok("cadaclysm_view_stats") { t, v in t.pointee.stats!(v, &out) }
        return ViewStats(framesDrawn: out.frames_drawn, lastFrameMs: out.last_frame_ms, lastGpuMs: out.last_gpu_ms,
                         triangles: out.triangles, drawCalls: out.draw_calls)
    }

    // -- pump and release

    /// Handles the events of every open window of this thread's own (on the wgpu library),
    /// draws what is owed, waits at most `timeout` seconds (negative or NaN: none; capped at
    /// 2^32-1 ms): the number of such windows of every thread still open -- for a program's
    /// own loop. With none of this thread's own it just waits `timeout`, so a loop around it
    /// does not spin. A window whose pump failed stays open; every window is pumped before
    /// the first failure is thrown.
    @discardableResult public static func pump(timeout: Double = 0) throws -> Int {
        let ms: UInt32 = timeout > 0 ? (timeout * 1000 >= 4294967295 ? UInt32.max : UInt32(timeout * 1000)) : 0
        let me = ccadaclysm_view_thread()
        lock.lock()
        let alive = registry.compactMap { $0.view }.filter { $0.pumped && $0.handle != nil && !$0.windowClosed && $0.thread == me }
        lock.unlock()
        var first: ViewError?
        if alive.isEmpty {
            if ms > 0 { cvl_sleep_ms(ms) }
        } else {
            for (i, view) in alive.enumerated() {
                let t = view.library.table
                let got = t.pointee.pump!(view.handle!, i == 0 ? ms : 0)
                if got == UInt32(CADACLYSM_VIEW_CLOSED) { view.markClosed() }
                else if got != UInt32(CADACLYSM_VIEW_OPEN) && first == nil { first = libraryError(t) }
            }
        }
        if let first { throw first }
        lock.lock()
        defer { lock.unlock() }
        return registry.reduce(0) { n, w in
            guard let v = w.view else { return n }
            return v.pumped && v.handle != nil && !v.windowClosed ? n + 1 : n
        }
    }

    /// Scene.close()'s hook: removes every item showing `owner` from this thread's views -- a
    /// view whose window the user closed is destroyed, the destroy it owed anyway -- before
    /// `owner`'s handle is freed. False when a view of another thread still shows it: that
    /// view cannot be called from here, so the caller keeps `owner` open (Python refuses; a
    /// leak rather than a crash).
    package static func releaseShown(_ owner: AnyObject) -> Bool {
        let target = ObjectIdentifier(owner)
        let me = ccadaclysm_view_thread()
        var mine: [(View, [UInt32])] = []
        var foreign = 0
        lock.lock()
        for w in registry {
            guard let v = w.view, v.handle != nil else { continue }
            let ids = v.owners.filter { ObjectIdentifier($0.value) == target }.map { $0.key }
            if ids.isEmpty { continue }
            if v.thread != me { foreign += 1 } else { mine.append((v, ids)) }
        }
        lock.unlock()
        for (v, ids) in mine {
            if v.windowClosed {
                v.destroy()
                continue
            }
            for id in ids {
                if let h = v.handle { _ = v.library.table.pointee.remove!(h, id) }
                v.forget(id)
            }
        }
        return foreign == 0
    }
}

/// Scene.close()'s hook (see `View.releaseShown`).
package func releaseShown(_ owner: AnyObject) -> Bool { View.releaseShown(owner) }
