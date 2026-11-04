// The cadaclysm C ABI, as Swift objects: this file is the whole reader binding.
//
//     import Cadaclysm
//
//     let scene = try Cadaclysm.open("part.stp")
//     print(scene.version, scene.schema, scene.metresPerUnit)
//     for node in scene.walk() {
//         print(String(repeating: "  ", count: node.depth), node.label, node.kind)
//     }
//
// It imports the published header as the Clang module `CCadaclysm` -- no generated
// bindings -- and follows `cadaclysm.py` member for member: Python's names in lowerCamelCase,
// the same arguments and defaults, the same things left nil, the same failures thrown as a
// `CadaclysmError` carrying the library's own reason.
//
// Everything borrows from the scene. Names, ids and attribute text are copied into Swift
// strings on the way out and outlive anything. Mesh, polyline and surface arrays are
// `NativeArray` views straight over the library's memory -- a large assembly is tens of
// millions of triangles, most of them uploaded to a GPU and dropped -- and each view keeps
// its `Scene` alive, so it cannot dangle by the scene merely being dropped. An explicit
// `Scene.close()` still gives the memory back: a view read after that traps rather than
// reading freed memory. Call `Mesh.copy()` (or `Array(view)`) for arrays that must outlive
// the scene.
//
// A closed scene refuses. A member that throws anyway (`Scene.query`, `Scene.save`,
// `Node.saveMesh`) throws "<file>: the scene is closed"; a property or method with no error
// to throw traps with "<Type>.<member>: the scene is closed", a use-after-close being a
// programmer error, as Go panics.
//
// `cadaclysm_last_error` is thread-local; every failing call and the read of its reason
// happen together on the calling thread.
import CCadaclysm
import CadaclysmView
import Foundation

/// The ABI's "no such node" (`CADACLYSM_NONE`). Swift hands back nil instead.
private let noneIndex = UInt32.max

// ---- errors -------------------------------------------------------------------------------

/// A call into the library failed, carrying what it said about it.
public struct CadaclysmError: Error, CustomStringConvertible, LocalizedError {
    /// The library's own reason (or this wrapper's, where the library was never asked).
    public let message: String

    /// An error carrying `message`.
    public init(_ message: String) { self.message = message }

    /// The message.
    public var description: String { message }

    /// The message, for `localizedDescription`.
    public var errorDescription: String? { message }
}

/// A borrowed `char *` as a `String`; null and empty both come back as "".
private func borrowed(_ raw: UnsafePointer<CChar>?) -> String {
    guard let raw = raw else { return "" }
    return String(cString: raw)
}

/// The library's reason for the last failure on this thread, or "".
private func lastError() -> String { borrowed(cadaclysm_last_error()) }

private func lastErrorOr(_ fallback: String) -> String {
    let reason = lastError()
    return reason.isEmpty ? fallback : reason
}

/// The last component of a path, as Python's `Path.name`: either separator counts.
private func baseName(_ path: String) -> String {
    let parts = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
    return parts.last.map(String.init) ?? path
}

private func isDirectory(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
}

private func isFile(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && !directory.boolValue
}

// ---- conventions and value kinds ------------------------------------------------------------

/// The coordinate space to open a file into -- `CadaclysmConvention`, packed with this
/// module's two flags.
///
/// The library converts on the way out, so nothing here rotates anything: a caller names the
/// space it draws in and reads geometry already in it. Combine a preset with a flag with `|`:
/// `.unreal | .fileUnits`.
public struct Convention: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    /// The packed value: a preset in the low byte, the flags above it.
    public let rawValue: UInt32

    /// A convention from its packed value.
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    /// The file's own axes and its own units.
    public static let native = Convention(rawValue: 0)
    /// Z up, left-handed, centimetres.
    public static let unreal = Convention(rawValue: 1)
    /// Y up, left-handed, metres.
    public static let unity = Convention(rawValue: 2)
    /// Y up, right-handed, metres -- glTF, three.js, Bevy, wgpu.
    public static let yUp = Convention(rawValue: 3)
    /// Z up, right-handed, metres: `native`'s axes at Blender's unit.
    public static let blender = Convention(rawValue: 4)

    /// Combine with a preset to keep its axes but the file's own units.
    public static let fileUnits = Convention(rawValue: 0x100)
    /// Combine with a preset to ask for world-scale texture coordinates in `Mesh.uvs`. Off by
    /// default: eight bytes a vertex nobody asked for. Even with it, `Mesh.uvs` is nil for a
    /// node whose reader produces none.
    public static let uvWorld = Convention(rawValue: 0x200)

    private static let flags = fileUnits.rawValue | uvWorld.rawValue

    /// A preset and flags together.
    public static func | (lhs: Convention, rhs: Convention) -> Convention {
        Convention(rawValue: lhs.rawValue | rhs.rawValue)
    }

    private static let names: [(String, Convention)] = [
        ("native", .native), ("unreal", .unreal), ("unity", .unity), ("y-up", .yUp), ("blender", .blender),
    ]

    /// A convention from a name a user typed: `"unreal"`, or `"unreal+file-units"` to keep the
    /// file's own units under the preset's axes. Throws naming what is accepted, since an
    /// unrecognised name silently read as `native` would look like success and draw the wrong
    /// space.
    public static func parse(_ text: String) throws -> Convention {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = lowered.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let preset = parts[0]
        guard var packed = names.first(where: { $0.0 == preset })?.1 else {
            throw CadaclysmError("no convention called '\(preset)': native, unreal, unity, y-up or blender")
        }
        for flag in parts.dropFirst() where !flag.isEmpty {
            guard flag == "file-units" else {
                throw CadaclysmError("no convention flag called '\(flag)': file-units")
            }
            packed = packed | .fileUnits
        }
        return packed
    }

    /// The preset's name, then `+file-units` / `+uv-world` for the flags.
    public var description: String {
        let preset = rawValue & ~Convention.flags
        var out = Convention.names.first(where: { $0.1.rawValue == preset })?.0 ?? "convention \(preset)"
        if rawValue & Convention.fileUnits.rawValue != 0 { out += "+file-units" }
        if rawValue & Convention.uvWorld.rawValue != 0 { out += "+uv-world" }
        return out
    }
}

/// Which kind of value an attribute holds. One-based, zero meaning it had none -- as the
/// header's `CadaclysmValueKind`.
public enum ValueKind: Int, Sendable {
    /// The attribute had no value.
    case none = 0
    /// Text.
    case text = 1
    /// A signed integer.
    case integer = 2
    /// A real number.
    case real = 3
    /// True or false.
    case boolean = 4
    /// A list; the flat C struct cannot hold its elements, so the value is a `[a, b, c]`
    /// rendering of them.
    case list = 5
    /// Another entity, by the id the file gave it (`#4`) -- its own kind so a consumer can
    /// follow it rather than show it as prose.
    case reference = 6
}

// ---- module functions -------------------------------------------------------------------------

/// The version of the library actually linked, which is the one worth reporting.
public func version() -> String { borrowed(cadaclysm_version()) }

/// When the linked library was built, `YYYY-MM-DD`; a paid licence covers every build dated on
/// or before its expiry.
public func buildDate() -> String { borrowed(cadaclysm_build_date()) }

/// Load a licence: the certificate text, or the path of a file holding it.
///
/// Without this the library looks in `CADACLYSM_LICENSE`, then for `cadaclysm.lic` beside the
/// running executable and in the working directory. Throws with the library's reason when the
/// text does not verify; the previous licence, if any, stays in use.
public func license(_ textOrPath: String) throws {
    if !cadaclysm_license_set(textOrPath) {
        throw CadaclysmError(lastErrorOr("license refused"))
    }
}

/// One line about the licence in use -- `customer=… expiry=… entitlements=…` -- or
/// `unlicensed` (`unlicensed -- <reason>` when one was found but did not verify). Never empty.
public func licenseInfo() -> String {
    let info = borrowed(cadaclysm_license_info())
    return info.isEmpty ? "unlicensed" : info
}

/// How many unlicensed notices the library has printed to stderr in this process: an
/// application with no console to watch can poll this and show its own banner.
public func licenseNoticeCount() -> Int { Int(clamping: cadaclysm_license_notice_count()) }

/// How many coarser levels `Node.meshLod` offers above the mesh itself (level 0).
public func lodLevels() -> Int { Int(cadaclysm_lod_levels()) }

/// One format `Node.saveMesh` writes: its name, the extension it writes (not always the
/// same word: `stl-ascii` writes a `.stl`), and a label for a menu (`STL (binary)`).
public struct MeshFormat: Hashable, Sendable {
    /// The name `Node.saveMesh` takes.
    public let name: String
    /// The file extension it writes, without the dot.
    public let `extension`: String
    /// What to show in a save menu.
    public let label: String

    /// A format from its name, extension and label.
    public init(name: String, extension: String, label: String) {
        self.name = name
        self.extension = `extension`
        self.label = label
    }
}

/// Every format `Node.saveMesh` writes. Build a menu from this rather than hard-coding it, and
/// a format added to the library turns up without a code change.
public func meshFormats() -> [MeshFormat] {
    (0..<cadaclysm_mesh_format_count()).map {
        MeshFormat(name: borrowed(cadaclysm_mesh_format($0)), extension: borrowed(cadaclysm_mesh_format_extension($0)),
                   label: borrowed(cadaclysm_mesh_format_label($0)))
    }
}

/// One format this build reads: its name and the extensions its files take.
public struct Format: Hashable, Sendable {
    public let name: String
    public let extensions: [String]

    public init(name: String, extensions: [String]) {
        self.name = name
        self.extensions = extensions
    }
}

/// Every format this build reads, for an open dialog's filter. The library hands the
/// extensions over semicolon-separated; they are split here.
public func formats() -> [Format] {
    (0..<cadaclysm_format_count()).map {
        Format(name: borrowed(cadaclysm_format_name($0)),
               extensions: borrowed(cadaclysm_format_extensions($0)).split(separator: ";").map(String.init))
    }
}

/// Ask the user for a file through the platform's own open dialog, filtered to what this build
/// can read. Nil when they cancel or no dialog is available (on Linux, neither an XDG portal nor
/// `zenity`). Blocks until the user acts; on macOS call it from the main thread.
public func pickFile() -> String? {
    guard let raw = cadaclysm_pick_file(nil) else { return nil }
    // Borrowed only until the next picker call on this thread: copied here.
    return String(cString: raw)
}

/// Ask the user where to save, through the platform's own dialog, with `suggestedName`
/// prefilled. Nil when they cancel or no dialog is available. Blocks; on macOS call it from
/// the main thread.
public func pickSave(suggestedName: String? = nil) -> String? {
    let raw = suggestedName.map { name in name.withCString { cadaclysm_pick_save(nil, $0) } } ?? cadaclysm_pick_save(nil, nil)
    guard let raw = raw else { return nil }
    return String(cString: raw)
}

/// The schema a STEP or IFC file says it speaks (its `FILE_SCHEMA` line), read from the first
/// few kilobytes -- cheap even on a very large file. Empty when it names none; throws when the
/// file cannot be read.
public func declaredSchema(_ model: String) throws -> String {
    guard let handle = FileHandle(forReadingAtPath: model) else {
        throw CadaclysmError("\(model): no such file")
    }
    defer { try? handle.close() }
    let head: Data
    do {
        head = try handle.read(upToCount: 8192) ?? Data()
    } catch {
        throw CadaclysmError("\(model): \(error.localizedDescription)")
    }
    // Latin-1, as Python reads it: every byte is the code point of the same value.
    let latin1 = String(decoding: head.map { UInt16($0) }, as: UTF16.self)
    let pattern = try! NSRegularExpression(pattern: #"FILE_SCHEMA\s*\(\s*\(\s*'([^']+)'"#,
                                           options: .caseInsensitive)
    let whole = NSRange(latin1.startIndex..., in: latin1)
    guard let found = pattern.firstMatch(in: latin1, range: whole),
          let range = Range(found.range(at: 1), in: latin1) else { return "" }
    return String(latin1[range])
}

/// A schema name reduced to its letters and digits, upper-cased.
private func plain(_ name: String) -> String {
    String(name.uppercased().filter { $0.isLetter || $0.isNumber })
}

/// `schema` resolved against `model` to one chosen `.exp`, or a list of fallbacks to try in
/// turn.
///
/// A file is taken as given. A directory is matched against what the model says it speaks;
/// where the declared name resembles no filename the whole directory comes back as fallbacks
/// -- AP203 calls itself CONFIG_CONTROL_DESIGN. `open` does this itself; this is for a caller
/// that wants to report the choice.
public func resolveSchema(_ model: String, schema: String?) throws -> (chosen: String?, fallbacks: [String]) {
    guard let schema = schema else { return (nil, []) }
    if isFile(schema) { return (schema, []) }
    guard isDirectory(schema) else {
        throw CadaclysmError("schema \(schema) is neither a file nor a directory")
    }
    let separator = schema.hasSuffix("/") || schema.hasSuffix("\\") ? "" : "/"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: schema)) ?? []
    let available = names.filter { $0.hasSuffix(".exp") }.sorted().map { schema + separator + $0 }
    guard !available.isEmpty else { throw CadaclysmError("no .exp schemas in \(schema)") }

    let stem = { (exp: String) in plain(String(baseName(exp).dropLast(4))) }
    let declared = plain((try? declaredSchema(model)) ?? "")
    let matches = available.filter { exp in
        !declared.isEmpty && (declared.hasPrefix(stem(exp)) || stem(exp).hasPrefix(declared))
    }
    // The longest name that still matches is the most specific one.
    if let best = matches.max(by: { stem($0).count < stem($1).count }) {
        return (best, [])
    }
    return (nil, available)
}

/// `CadaclysmOpenOptions` for these arguments, alive for the duration of `body`.
private func withOptions<R>(_ convention: Convention, schema: String?, colors: Bool,
                            _ body: (UnsafePointer<CadaclysmOpenOptions>) -> R) -> R {
    var options = CadaclysmOpenOptions()
    cadaclysm_open_options_init(&options)
    let packed = convention.rawValue
    options.convention = packed & ~(Convention.fileUnits.rawValue | Convention.uvWorld.rawValue)
    options.file_units = packed & Convention.fileUnits.rawValue != 0
    options.uvs = packed & Convention.uvWorld.rawValue != 0
        ? UInt32(CADACLYSM_UV_WORLD_SCALE.rawValue) : UInt32(CADACLYSM_UV_NONE.rawValue)
    options.colors = colors ? UInt32(CADACLYSM_COLORS_PER_FACE.rawValue) : UInt32(CADACLYSM_COLORS_NONE.rawValue)
    guard let schema = schema else {
        return withUnsafePointer(to: &options) { body($0) }
    }
    return schema.withCString { path in
        let list: [UnsafePointer<CChar>?] = [path]
        return list.withUnsafeBufferPointer { entries in
            options.schemas = entries.baseAddress
            options.schema_count = 1
            return withUnsafePointer(to: &options) { body($0) }
        }
    }
}

/// Open a CAD file and read its tree; the geometry is built lazily, node by node.
///
/// `schema` names an extra EXPRESS schema (`.exp`, or a directory of them matched against what
/// the file says it speaks); every schema the library ships is built in, so a STEP or IFC file
/// opens with nil. `convention` is the space to read into, optionally with `.fileUnits` and
/// `.uvWorld`. `colors` asks for per-vertex colours on bodies the file painted in more than one
/// colour. A `.zip` opens its first readable member; `Scene.sourceName` says which.
///
/// Throws `CadaclysmError` carrying the library's reason; never returns a dead scene.
public func open(_ path: String, schema: String? = nil, convention: Convention = .native,
                 colors: Bool = false) throws -> Scene {
    guard FileManager.default.fileExists(atPath: path) else {
        throw CadaclysmError("\(path): no such file")
    }
    let name = baseName(path)

    // A directory goes over whole: the library keys each schema under the name the schema
    // itself declares, which is the only authority on the matter.
    if let schema = schema, isDirectory(schema) {
        if let handle = withOptions(convention, schema: schema, colors: colors, { cadaclysm_open(path, $0) }) {
            return Scene(handle: handle, path: path, schemaPath: schema, convention: convention)
        }
        throw CadaclysmError("\(name): \(lastError())")
    }

    let (chosen, fallbacks) = try resolveSchema(path, schema: schema)
    let candidates: [String?] = chosen != nil || fallbacks.isEmpty ? [chosen] : fallbacks
    for candidate in candidates {
        if let handle = withOptions(convention, schema: candidate, colors: colors, { cadaclysm_open(path, $0) }) {
            return Scene(handle: handle, path: path, schemaPath: candidate, convention: convention)
        }
    }
    throw CadaclysmError("\(name): \(lastError())")
}

/// Open a CAD file already in bytes -- a download, a database blob, an archive member.
///
/// `format` names the kind as an extension would: `"step"`, `"ifc"`, `"igs"`, `"3dm"`,
/// `"brep"`, `"scad"` (a leading dot is fine). `schema` must be a file path here, there being no
/// file to read a `FILE_SCHEMA` line from; `name` stands as the scene's `path`. The bytes are
/// copied; `data` can be reused as soon as this returns. Otherwise as `open`.
public func openMemory(_ data: Data, format: String, schema: String? = nil, name: String = "<memory>",
                       convention: Convention = .native, colors: Bool = false) throws -> Scene {
    let handle = data.withUnsafeBytes { bytes in
        withOptions(convention, schema: schema, colors: colors) { options in
            cadaclysm_open_memory(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, format, options)
        }
    }
    guard let handle = handle else { throw CadaclysmError("\(name): \(lastError())") }
    return Scene(handle: handle, path: name, schemaPath: schema, convention: convention)
}

/// `openMemory` over a byte array.
public func openMemory(_ bytes: [UInt8], format: String, schema: String? = nil, name: String = "<memory>",
                       convention: Convention = .native, colors: Bool = false) throws -> Scene {
    try openMemory(Data(bytes), format: format, schema: schema, name: name, convention: convention, colors: colors)
}

// ---- views over library memory ------------------------------------------------------------------

/// Something that lends out memory a `NativeArray` views, and can take it back.
public protocol NativeMemoryOwner: AnyObject {
    /// Nil while the memory may be read; otherwise why not ("the scene is closed").
    var nativeMemoryInvalidReason: String? { get }
}

/// Memory of Swift's own, what `copy()` hands back: always readable, freed with the last view.
final class OwnedBuffer<Element>: NativeMemoryOwner {
    let pointer: UnsafeMutablePointer<Element>
    let count: Int

    init(copying source: UnsafeBufferPointer<Element>) {
        count = source.count
        pointer = .allocate(capacity: Swift.max(count, 1))
        if let base = source.baseAddress { pointer.initialize(from: base, count: count) }
    }

    deinit {
        pointer.deinitialize(count: count)
        pointer.deallocate()
    }

    var nativeMemoryInvalidReason: String? { nil }
}

/// What a `Mesh64`'s arrays name as their owner: the scene, and the scene's forget count when
/// the mesh was lent. `Scene.forgetMeshes()` frees the document's own mesh those arrays view, so
/// a forget since then invalidates them as a close does, and a read traps rather than reading
/// freed memory.
final class LentMesh: NativeMemoryOwner {
    let scene: Scene
    let forgets: Int

    init(_ scene: Scene) {
        self.scene = scene
        forgets = scene.forgets
    }

    var nativeMemoryInvalidReason: String? {
        if let closed = scene.nativeMemoryInvalidReason { return closed }
        return scene.forgets == forgets ? nil
            : "stale view: the scene has forgotten its meshes since, freeing the document's own mesh this lends (ask the node again)"
    }
}

/// A read-only array over memory the library owns, kept alive by holding its owner.
///
/// Element access checks the owner first and traps once it has given the memory back (the
/// scene was closed), rather than reading freed memory. `Array(view)` or `copy()` makes one of
/// your own.
public struct NativeArray<Element>: RandomAccessCollection {
    /// What lent the memory, held for as long as this view is.
    public let owner: any NativeMemoryOwner
    private let base: UnsafePointer<Element>?
    /// How many elements.
    public let count: Int

    /// A view of `count` elements at `base`, lent by `owner`. A null `base` is an empty view.
    public init(owner: any NativeMemoryOwner, base: UnsafePointer<Element>?, count: Int) {
        self.owner = owner
        self.base = count > 0 ? base : nil
        self.count = base == nil ? 0 : Swift.max(count, 0)
    }

    /// Whether the elements may be read: false once the owner has given the memory back, when
    /// every read traps.
    public var isValid: Bool { owner.nativeMemoryInvalidReason == nil }

    /// Zero.
    public var startIndex: Int { 0 }
    /// `count`.
    public var endIndex: Int { count }

    @inline(__always)
    private func checkOwner() {
        if let reason = owner.nativeMemoryInvalidReason {
            preconditionFailure("NativeArray: \(reason)")
        }
    }

    /// The element at `position`; traps once the owner has given the memory back.
    public subscript(position: Int) -> Element {
        checkOwner()
        precondition(position >= 0 && position < count, "NativeArray: index \(position) out of range 0..<\(count)")
        return base.unsafelyUnwrapped[position]
    }

    /// Calls `body` with the elements in place, the owner kept alive throughout.
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R {
        checkOwner()
        return try withExtendedLifetime(owner) { try body(UnsafeBufferPointer(start: base, count: count)) }
    }

    /// The contiguous elements, so `Array(view)` copies in one go.
    public func withContiguousStorageIfAvailable<R>(_ body: (UnsafeBufferPointer<Element>) throws -> R) rethrows -> R? {
        try withUnsafeBufferPointer(body)
    }

    /// The same elements in memory of Swift's own, safe to outlive the scene.
    public func copy() -> NativeArray<Element> {
        withUnsafeBufferPointer { elements in
            let buffer = OwnedBuffer(copying: elements)
            return NativeArray(owner: buffer, base: UnsafePointer(buffer.pointer), count: elements.count)
        }
    }
}

// ---- values --------------------------------------------------------------------------------------

/// An axis-aligned box, or all zeros where there was nothing to bound.
public struct Bounds: Hashable, Sendable, CustomStringConvertible {
    /// The low corner.
    public let min: SIMD3<Double>
    /// The high corner.
    public let max: SIMD3<Double>

    /// A box from its corners.
    public init(min: SIMD3<Double>, max: SIMD3<Double>) {
        self.min = min
        self.max = max
    }

    init(_ raw: CadaclysmBounds) {
        min = SIMD3(Double(raw.min.0), Double(raw.min.1), Double(raw.min.2))
        max = SIMD3(Double(raw.max.0), Double(raw.max.1), Double(raw.max.2))
    }

    /// `CadaclysmBounds` in `double`: the same corners, unnarrowed rather than widened from
    /// `float` -- exact far from the origin, where the `float` box is not.
    init(_ raw: CadaclysmBounds64) {
        min = SIMD3(raw.min.0, raw.min.1, raw.min.2)
        max = SIMD3(raw.max.0, raw.max.1, raw.max.2)
    }

    /// Whether this is the all-zero box the ABI uses for "nothing here".
    public var isEmpty: Bool { min == .zero && max == .zero }

    /// The extent along each axis.
    public var size: SIMD3<Double> { max - min }

    /// The midpoint.
    public var centre: SIMD3<Double> { (min + max) / 2 }

    /// `Bounds(min: …, max: …)`.
    public var description: String { "Bounds(min: \(min), max: \(max))" }
}

/// An attribute's value, in Swift's own type for its kind. `.text` carries TEXT, LIST (as
/// `[a, b, c]`) and REFERENCE (the id the file gave) alike; `Attribute.kind` tells them apart.
public enum AttributeValue: Hashable, Sendable {
    /// Text, a list's rendering, or a reference's id.
    case text(String)
    /// A signed integer.
    case integer(Int64)
    /// A real number.
    case real(Double)
    /// True or false.
    case boolean(Bool)
}

/// A real written the way cadaclysm's Rust `Display` writes it: the shortest digits that
/// round-trip, never in exponent notation, no trailing `.0`; `inf`, `-inf`, `NaN`.
private func decimalText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value > 0 ? "inf" : "-inf" }
    var shortest = "\(value)"   // the shortest round-trip digits, possibly with an exponent
    var sign = ""
    if shortest.hasPrefix("-") {
        sign = "-"
        shortest.removeFirst()
    }
    let parts = shortest.split(separator: "e", omittingEmptySubsequences: false)
    let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    let whole = String(mantissa[0])
    var digits = whole + (mantissa.count > 1 ? String(mantissa[1]) : "")
    var point = whole.count + exponent
    while digits.count > Swift.max(point, 1), digits.hasSuffix("0") { digits.removeLast() }
    while digits.count > 1, digits.hasPrefix("0") {
        digits.removeFirst()
        point -= 1
    }
    if digits == "0" { return sign + "0" }
    if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
    if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) }
    let split = digits.index(digits.startIndex, offsetBy: point)
    return sign + digits[..<split] + "." + digits[split...]
}

/// One thing the file said about a node.
public struct Attribute: Hashable, Sendable, CustomStringConvertible {
    /// What the file called it.
    public let name: String
    /// Which kind of value it holds: tells a reference from prose, or a number to total.
    public let kind: ValueKind
    /// The value in Swift's own type for `kind`, or nil for `.none`.
    public let value: AttributeValue?

    /// An attribute from its parts.
    public init(name: String, kind: ValueKind, value: AttributeValue?) {
        self.name = name
        self.kind = kind
        self.value = value
    }

    /// A `CadaclysmAttribute`, or nil for the all-zero one past the end. The kind picks exactly
    /// one field to read; the others are zero, so reading the wrong one is silent.
    init?(_ raw: CadaclysmAttribute) {
        guard let rawName = raw.name else { return nil }
        let kind = ValueKind(rawValue: Int(raw.kind.rawValue)) ?? ValueKind.none
        switch kind {
        case .text, .list, .reference: value = .text(borrowed(raw.text))
        case .integer: value = .integer(raw.integer)
        case .real: value = .real(raw.real)
        case .boolean: value = .boolean(raw.boolean)
        case .none: value = nil
        }
        name = String(cString: rawName)
        self.kind = kind
    }

    /// The value rendered for display, identically in every wrapper: `true`/`false`, reals in
    /// their shortest exact form without an exponent, lists as `[a, b, c]`.
    public var text: String {
        switch value {
        case nil: return ""
        case .text(let text)?: return text
        case .integer(let integer)?: return String(integer)
        case .real(let real)?: return decimalText(real)
        case .boolean(let boolean)?: return boolean ? "true" : "false"
        }
    }

    /// Python's truth test of the value, which `Node.locked` reads.
    var truthy: Bool {
        switch value {
        case nil: return false
        case .text(let text)?: return !text.isEmpty
        case .integer(let integer)?: return integer != 0
        case .real(let real)?: return real != 0
        case .boolean(let boolean)?: return boolean
        }
    }

    /// `Attribute(name: kind = text)`.
    public var description: String { "Attribute(\(name): \(kind) = \(text))" }
}

/// Whether a body's faces make a manifold -- every edge bordered by one face or two, the faces
/// round every vertex one fan -- told from its topology rather than a mesh: what
/// `Brep.manifold` returns.
public struct Manifold: Hashable, Sendable, CustomStringConvertible {
    /// How many faces.
    public let faces: Int
    /// How many distinct edges; one shared by two faces counts once.
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

    /// The eight counts `cadaclysm_brep_manifold` (and the kernel's twin) write, in order.
    public init(_ row: [UInt32]) {
        precondition(row.count >= 8, "Manifold: needs eight counts, got \(row.count)")
        faces = Int(row[0])
        edges = Int(row[1])
        vertices = Int(row[2])
        boundaryEdges = Int(row[3])
        nonManifoldEdges = Int(row[4])
        nonManifoldVertices = Int(row[5])
        isManifold = row[6] != 0
        isClosed = row[7] != 0
    }

    /// Every count, labelled.
    public var description: String {
        "Manifold(faces: \(faces), edges: \(edges), vertices: \(vertices), boundaryEdges: \(boundaryEdges), "
            + "nonManifoldEdges: \(nonManifoldEdges), nonManifoldVertices: \(nonManifoldVertices), "
            + "isManifold: \(isManifold), isClosed: \(isClosed))"
    }
}

/// What `Brep.sewed` did, as plain data: the edges it joined (`pairs`), the free edges before and
/// after, how many groups of free edges between the same two vertices it left free (`refused`:
/// too far apart for the tolerance, or more than two), the widest gap it sewed, and the two
/// tolerances it used.
public struct SewReport: Hashable, Sendable {
    public let pairs: UInt32
    public let freeBefore: UInt32
    public let freeAfter: UInt32
    public let refused: UInt32
    public let worstGap: Double
    public let tolerance: Double
    public let vertex: Double

    /// The four counts and three gaps `cadaclysm_brep_sew` writes, in order.
    public init(counts: [UInt32], gaps: [Double]) {
        precondition(counts.count >= 4 && gaps.count >= 3, "SewReport: needs four counts and three gaps")
        pairs = counts[0]
        freeBefore = counts[1]
        freeAfter = counts[2]
        refused = counts[3]
        worstGap = gaps[0]
        tolerance = gaps[1]
        vertex = gaps[2]
    }
}

/// One free edge (a side only one face bounds) with its nearest partner: its `trim` (the face's
/// side), the `edge` it lies on (nil for a side with no edge), the `face` and free `wire` (a row
/// of `HealthReport.wires`) it is on, its nearest `partner` across the gap as a row of
/// `HealthReport.freeEdges` (nil if there is none), how many of its two ends it `sharedEnds`
/// with that partner (2 is what `Brep.sewed` joins), its `length` and the `gap` to the partner
/// (infinite without one).
public struct FreeEdge: Hashable, Sendable {
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
public struct FreeWire: Hashable, Sendable {
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
public struct SmallFeature: Hashable, Sendable {
    public let kind: String
    public let index: Int
    public let size: Double

    public init(kind: String, index: Int, size: Double) {
        self.kind = kind
        self.index = index
        self.size = size
    }
}

/// What a mesh of the body shows (`Brep.health(mesh: true)`): whether it is `watertight`, how
/// many mesh edges are `open` (one triangle) or `folded` (more than two), how many pairs of
/// triangles cross (`crossings`), and the brep `edges` the cracks lie along. Only a closed body
/// is counted: an open one's census is empty by design.
public struct Cracks: Hashable, Sendable {
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

/// What is wrong with a body, as plain data (`Brep.health`): the `tolerance` and `rounding` it
/// judged at and the body's `extent` (its diagonal); the free edges, their wires, the features
/// below the tolerance; the loose edges (`worstLoose` the widest such gap); what sewing would do
/// (`sewPairs` joined, `sewRefused`, `sewWorstGap`); `worstGap`, the widest gap between a free
/// edge and its partner; and, if asked for with `mesh: true`, the mesh's `cracks`.
public struct HealthReport: Hashable, Sendable {
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

    /// The flat rows of the health C ABI, decoded index for index as cadaclysm.py's
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

/// One small feature `Brep.healed` removed: its `kind` (as `SmallFeature.kind`), its `index` in
/// the input (as `health` gave it), its `size`, and how far the vertices it merged `moved`.
public struct HealFix: Hashable, Sendable {
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

/// One small feature `Brep.healed` left, and why: `kind` and `index` as in `HealFix`; `why` is
/// `"would_empty_loop"`, `"closed"`, `"seam"`, `"chain"`, `"neighbours_part"`, `"uneven"`,
/// `"non_manifold"`, `"has_holes"`, `"body_guard"`, `"toggled"` or `"unsupported"`; `figure`
/// the chain's width or the neighbours' gap, else 0.
public struct HealRefusal: Hashable, Sendable {
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

/// What `Brep.healed` did, as plain data: the `tolerance` it healed at, the furthest any trim
/// the result keeps `moved`, whether the body guard refused fixes (`guarded`), the `fixes` made
/// and the features `refused`; and the body's health before and after at that tolerance -- its
/// small features, free edges, whether it is closed, and its non-manifold edges.
public struct HealReport: Hashable, Sendable {
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

    /// The flat rows of the heal C ABI, decoded index for index as cadaclysm.py's `_heal_report`.
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

/// A node's triangles, in the node's own frame: what `Node.mesh` returns.
///
/// The arrays are read-only views into the scene's memory, not copies -- see the top of this
/// file. `copy()` makes arrays of your own.
public struct Mesh: CustomStringConvertible {
    /// Three floats a vertex.
    public let positions: NativeArray<Float>
    /// Three floats a vertex, or nil for a mesh that carries none.
    public let normals: NativeArray<Float>?
    /// Two floats a vertex, or nil: only readers asked for world-scale UVs (or a file that
    /// stores them) fill them. One unit of u or v is one world unit -- a tiling material, not a
    /// lightmap.
    public let uvs: NativeArray<Float>?
    /// Four floats (RGBA) a vertex, or nil -- the common case. Only a body painted in several
    /// colours, opened with `colors: true`, carries them.
    public let colors: NativeArray<Float>?
    /// Three vertex indices a triangle.
    public let indices: NativeArray<UInt32>
    /// How many vertices.
    public let vertexCount: Int
    /// How many indices: three a triangle.
    public let indexCount: Int

    /// How many triangles.
    public var triangleCount: Int { indexCount / 3 }

    /// Whether there are no triangles -- a structure node, or one drawn only as curves.
    public var isEmpty: Bool { indexCount == 0 || positions.isEmpty }

    /// The same arrays in memory of your own, safe to keep after `Scene.close()`. Deliberately
    /// visible: on a large model this is where the gigabytes go.
    public func copy() -> Mesh {
        Mesh(positions: positions.copy(), normals: normals?.copy(), uvs: uvs?.copy(),
             colors: colors?.copy(), indices: indices.copy(), vertexCount: vertexCount, indexCount: indexCount)
    }

    /// `Mesh(vertices: …, triangles: …)`.
    public var description: String { "Mesh(vertices: \(vertexCount), triangles: \(triangleCount))" }
}

/// `Mesh` in `double`: the document's own mesh, **lent as it is**, where `Node.mesh` hands a
/// `Float` copy of it -- the same triangles and indices, `Node.mesh`'s positions being
/// exactly these narrowed. For a caller that uses the mesh as geometry (an exporter, a
/// measurement, a solver) and wants the file's own coordinates, which `Float` cannot hold
/// far from the origin. Colours stay `Float` (RGBA in 0...1 needs no more).
///
/// Views into the scene, under the rule at the top of this file -- **except that a forget
/// drops these views and not `Mesh`'s.** See the note on `Node.mesh64`.
public struct Mesh64: CustomStringConvertible {
    /// Three doubles a vertex.
    public let positions: NativeArray<Double>
    /// Three doubles a vertex, or nil for a mesh that carries none.
    public let normals: NativeArray<Double>?
    /// Two doubles a vertex, or nil: see `Mesh.uvs`.
    public let uvs: NativeArray<Double>?
    /// Four floats (RGBA) a vertex, or nil -- as `Mesh.colors`.
    public let colors: NativeArray<Float>?
    /// Three vertex indices a triangle.
    public let indices: NativeArray<UInt32>
    /// How many vertices.
    public let vertexCount: Int
    /// How many indices: three a triangle.
    public let indexCount: Int

    /// How many triangles.
    public var triangleCount: Int { indexCount / 3 }

    /// Whether there are no triangles.
    public var isEmpty: Bool { indexCount == 0 || positions.isEmpty }

    /// The same arrays in memory of your own, safe to keep after `Scene.close()` -- or after
    /// `Scene.forgetMeshes()`, which these views do not otherwise survive.
    public func copy() -> Mesh64 {
        Mesh64(positions: positions.copy(), normals: normals?.copy(), uvs: uvs?.copy(),
              colors: colors?.copy(), indices: indices.copy(), vertexCount: vertexCount, indexCount: indexCount)
    }

    /// `Mesh64(vertices: …, triangles: …)`.
    public var description: String { "Mesh64(vertices: \(vertexCount), triangles: \(triangleCount))" }
}

/// Edges or curves already flattened to points, in the node's own frame: what `Node.edges`,
/// `Node.curves` and `Node.isocurves` return. Views into the scene, like `Mesh`.
public struct Polylines: CustomStringConvertible {
    /// Three floats a point, the runs end to end.
    public let positions: NativeArray<Float>
    /// How many points each run has, in order.
    public let counts: NativeArray<UInt32>
    /// How many runs.
    public let polylineCount: Int
    /// How many points in all.
    public let vertexCount: Int

    /// Whether there are no runs.
    public var isEmpty: Bool { polylineCount == 0 || positions.isEmpty }

    /// Index pairs into the points, two per line segment -- what `GL_LINES` and every
    /// pair-taking API want. A run of n points is n - 1 segments; a one-point run is none.
    /// Indices rather than points, so a caller can transform the points once and expand after.
    public func segmentIndices() -> [Int] {
        var out: [Int] = []
        var start = 0
        counts.withUnsafeBufferPointer { runs in
            out.reserveCapacity(Swift.max(0, (vertexCount - runs.count) * 2))
            for run in runs {
                let n = Int(run)
                if n >= 2 {
                    for i in 0..<(n - 1) {
                        out.append(start + i)
                        out.append(start + i + 1)
                    }
                }
                start += n
            }
        }
        return out
    }

    /// The segment endpoints themselves, three floats each, two points per segment.
    public func segments() -> [Float] {
        let pairs = segmentIndices()
        return positions.withUnsafeBufferPointer { points in
            var out: [Float] = []
            out.reserveCapacity(pairs.count * 3)
            for i in pairs {
                out.append(points[i * 3])
                out.append(points[i * 3 + 1])
                out.append(points[i * 3 + 2])
            }
            return out
        }
    }

    /// `Polylines(polylines: …, vertices: …)`.
    public var description: String { "Polylines(polylines: \(polylineCount), vertices: \(vertexCount))" }
}

/// Edges, curves or isocurves as cubic Bézier curves -- exact where the file's curves were,
/// where `Polylines` are their chords: what `Node.edgeBeziers`, `Node.curveBeziers` and
/// `Node.isocurveBeziers` return. Views into the scene, like `Mesh`.
public struct Beziers: CustomStringConvertible {
    /// `count * 12` floats: four control points a curve, three floats each.
    public let points: NativeArray<Float>
    /// `count * 4` floats: a weight per control point, all ones for a polynomial curve, and
    /// the weights that make a circular arc exact for a rational one.
    public let weights: NativeArray<Float>
    /// How many curves.
    public let count: Int

    /// Whether there are no curves.
    public var isEmpty: Bool { count == 0 || points.isEmpty }

    /// The same arrays in memory of your own, safe to keep after `Scene.close()`.
    public func copy() -> Beziers { Beziers(points: points.copy(), weights: weights.copy(), count: count) }

    public var description: String { "Beziers(count: \(count))" }
}

/// `Beziers` in `double`: the same segments, unnarrowed -- `Beziers`'s points and weights are
/// exactly these narrowed. Views into the scene, like `Beziers` -- curves are not part of the
/// mesh cache, so unlike `Mesh64` these are unaffected by `Scene.forgetMeshes()` and stay
/// good until the scene closes.
public struct Beziers64: CustomStringConvertible {
    /// `count * 12` doubles: four control points a curve, three doubles each.
    public let points: NativeArray<Double>
    /// `count * 4` doubles: a weight per control point.
    public let weights: NativeArray<Double>
    /// How many curves.
    public let count: Int

    /// Whether there are no curves.
    public var isEmpty: Bool { count == 0 || points.isEmpty }

    /// The same arrays in memory of your own, safe to keep after `Scene.close()`.
    public func copy() -> Beziers64 { Beziers64(points: points.copy(), weights: weights.copy(), count: count) }

    public var description: String { "Beziers64(count: \(count))" }
}

// In an extension so the struct keeps its memberwise initialiser, which the node's own views use.
extension Beziers64 {
    /// Curves from `count * 12` coordinates (four control points a curve, x y z each) and `count * 4`
    /// weights, copied into memory of Swift's own -- how a result the library lent or handed over
    /// in a buffer of its own (`Blacksmith.Solid.silhouetteBeziers`) becomes one a caller keeps.
    public init(points: [Double], weights: [Double]) {
        precondition(points.count == weights.count * 3 && weights.count % 4 == 0,
                     "Beziers64: \(points.count) coordinates and \(weights.count) weights are not four points and four weights a curve")
        let ownedPoints = points.withUnsafeBufferPointer { OwnedBuffer(copying: $0) }
        let ownedWeights = weights.withUnsafeBufferPointer { OwnedBuffer(copying: $0) }
        self.points = NativeArray(owner: ownedPoints, base: UnsafePointer(ownedPoints.pointer), count: points.count)
        self.weights = NativeArray(owner: ownedWeights, base: UnsafePointer(ownedWeights.pointer), count: weights.count)
        count = weights.count / 4
    }
}

/// What a node turned out to be for a physics engine: a box, sphere, capsule or cylinder where
/// one fits within `error`, else a convex hull. `frame` (16 numbers, column-major) and
/// `halfExtent` are always the true oriented box. Plain data, copied out of the scene.
public struct Collision: Hashable, Sendable {
    public let shape: Int
    public let confidence: Int
    public let axis: Int
    public let frame: [Double]
    public let halfExtent: SIMD3<Double>
    public let radius: Double
    public let height: Double
    public let error: Double
    public let hullVertexCount: Int
    public let hullIndexCount: Int

    /// `none`, `box`, `sphere`, `capsule`, `cylinder` or `hull`.
    public var shapeName: String {
        let names = ["none", "box", "sphere", "capsule", "cylinder", "hull"]
        return shape < names.count ? names[shape] : String(shape)
    }

    init(_ raw: CadaclysmCollision) {
        shape = Int(raw.shape)
        confidence = Int(raw.confidence)
        axis = Int(raw.axis)
        frame = withUnsafeBytes(of: raw.frame) { Array($0.bindMemory(to: Double.self)) }
        halfExtent = SIMD3(raw.half_extent.0, raw.half_extent.1, raw.half_extent.2)
        radius = raw.radius
        height = raw.height
        error = raw.error
        hullVertexCount = Int(raw.hull_vertex_count)
        hullIndexCount = Int(raw.hull_index_count)
    }
}

/// A node's convex hull for a physics engine, as triangles. Views into the scene, like `Mesh`.
public struct CollisionHull: CustomStringConvertible {
    /// Three floats a vertex.
    public let positions: NativeArray<Float>
    /// Three vertex indices a triangle.
    public let indices: NativeArray<UInt32>
    public let vertexCount: Int
    public let indexCount: Int

    public var isEmpty: Bool { vertexCount == 0 || positions.isEmpty }

    public var description: String { "CollisionHull(vertices: \(vertexCount), triangles: \(indexCount / 3))" }
}

/// One trimmed face: the surface itself, plus the loops that cut it.
///
/// `kind` is 0 plane, 1 cylinder, 2 cone, 3 sphere, 4 torus, 5 revolution, 6 extrusion,
/// 7 NURBS, 8 sum. `origin`, `ax`, `ay`, `az` are its frame, `scalars` its kind-dependent sizes
/// and `domain` its `(u min, v min, u max, v max)`. The arrays are views into the scene; see
/// `CadaclysmFace` in the header for the whole story.
public struct Face: CustomStringConvertible {
    /// The surface kind, 0 plane … 8 sum.
    public let kind: Int
    /// Whether the surface normal points into the solid, so a caller flips it.
    public let reversed: Bool
    /// A revolution whose u is the profile and v the spin, rather than the other way.
    public let transposed: Bool
    /// The frame's origin.
    public let origin: SIMD3<Float>
    /// The frame's x axis.
    public let ax: SIMD3<Float>
    /// The frame's y axis.
    public let ay: SIMD3<Float>
    /// The frame's z axis.
    public let az: SIMD3<Float>
    /// `(u min, v min, u max, v max)`: the window the trims occupy.
    public let domain: SIMD4<Float>
    /// The kind-dependent sizes (radius, angle…).
    public let scalars: SIMD4<Float>
    /// The trim loops, each (u, v) pairs flat and closing implicitly; the first is the outer.
    public let loops: [NativeArray<Float>]
    /// A swept surface's profile, `(x, y, z, parameter)` samples flat; empty for a quadric.
    public let profile: NativeArray<Float>
    /// A sum surface's second curve, as `profile`; empty for every other kind.
    public let profile2: NativeArray<Float>
    /// A NURBS surface's packed net and knots; empty for every other kind.
    public let nurbs: NativeArray<Float>

    private static let names = ["plane", "cylinder", "cone", "sphere", "torus", "revolution",
                                "extrusion", "nurbs", "sum"]

    /// `Face(<kind>, <n> loops)`.
    public var description: String {
        let name = kind >= 0 && kind < Face.names.count ? Face.names[kind] : String(kind)
        return "Face(\(name), \(loops.count) loops)"
    }
}

/// A node's faces as exact surfaces and trims: what `Node.surfaces` returns, a collection of
/// `Face`. In the file's own frame; `Scene.surfaceMatrix` brings it into the scene's.
public struct Surfaces: RandomAccessCollection, CustomStringConvertible {
    /// The faces, one per trimmed face of the body.
    public let faces: [Face]

    /// Zero.
    public var startIndex: Int { 0 }
    /// The face count.
    public var endIndex: Int { faces.count }
    /// The face at `position`.
    public subscript(position: Int) -> Face { faces[position] }

    /// `Surfaces(<n> faces)`.
    public var description: String { "Surfaces(\(faces.count) faces)" }
}

/// Four rows of four from sixteen column-major values.
private func rowMajor(_ columnMajor: [Double]) -> [[Double]] {
    (0..<4).map { row in (0..<4).map { column in columnMajor[column * 4 + row] } }
}

// ---- placements -------------------------------------------------------------------------------

/// One drawing of one node's geometry, at one place: what `Scene.placements` lists.
///
/// A node is not a drawing. A block's members draw once per placement of it, not once on their
/// own account, so iterate placements to draw and nodes to build a tree. Two drawings of one
/// shape name the same geometry node, and so the same arrays -- upload once, draw twice.
public struct Placement: Hashable, CustomStringConvertible {
    /// The scene it belongs to.
    public let scene: Scene
    /// Its index in `Scene.placements`.
    public let index: Int

    /// The placement `index` of `scene`.
    public init(_ scene: Scene, _ index: Int) {
        precondition(index >= 0 && index <= Int(UInt32.max), "Placement: index \(index) out of range")
        self.scene = scene
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }

    /// The node whose mesh, edges and curves this draws.
    public var geometry: Node {
        Node(scene, Int(cadaclysm_placement_geometry(scene.live("Placement"), raw)))
    }

    /// What a click on this drawing selects: the placement's own node rather than the shared
    /// shape, which would light up every copy.
    public var select: Node {
        Node(scene, Int(cadaclysm_placement_select(scene.live("Placement"), raw)))
    }

    /// Where to draw it: four rows of four doubles (`transform[row][column]`), already composed
    /// through every frame from the root. The offset is column 3 of rows 0 to 2.
    public var transform: [[Double]] { rowMajor(rawTransform) }

    /// The same matrix as sixteen doubles in the ABI's column-major order, ready for a GPU.
    public var rawTransform: [Double] {
        var out = [Double](repeating: 0, count: 16)
        cadaclysm_placement_transform(scene.live("Placement"), raw, &out)
        return out
    }

    /// Same scene, same index.
    public static func == (lhs: Placement, rhs: Placement) -> Bool {
        lhs.scene === rhs.scene && lhs.index == rhs.index
    }

    /// Hashes the scene's identity and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scene))
        hasher.combine(index)
    }

    /// `Placement(index: …)`.
    public var description: String { "Placement(index: \(index))" }
}

// ---- links and joints --------------------------------------------------------------------------

/// A rigid body of the file's mechanism: the nodes that move together when a joint moves it.
/// From `Scene.links`; borrows from the scene like `Node`.
public struct Link: Hashable, CustomStringConvertible {
    /// The scene it belongs to.
    public let scene: Scene
    /// Its index in `Scene.links`.
    public let index: Int

    /// The link `index` of `scene`.
    public init(_ scene: Scene, _ index: Int) {
        precondition(index >= 0 && index <= Int(UInt32.max), "Link: index \(index) out of range")
        self.scene = scene
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }

    /// The link's name as the file gives it.
    public var name: String { borrowed(cadaclysm_link_name(scene.live("Link"), raw)) }

    /// The topmost node of each subtree this link moves, in node order: moving these moves
    /// everything under them.
    public var nodes: [Node] {
        let handle = scene.live("Link")
        return (0..<cadaclysm_link_node_count(handle, raw)).map {
            Node(scene, Int(cadaclysm_link_node(handle, raw, $0)))
        }
    }

    /// Same scene, same index.
    public static func == (lhs: Link, rhs: Link) -> Bool {
        lhs.scene === rhs.scene && lhs.index == rhs.index
    }

    /// Hashes the scene's identity and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scene))
        hasher.combine(index)
    }

    /// `Link(index: …)`.
    public var description: String { "Link(index: \(index))" }
}

/// A connection between two links of the file's mechanism, and, when the file names one, the
/// kinematic pair saying how it moves. From `Scene.joints`.
public struct Joint: Hashable, CustomStringConvertible {
    /// The scene it belongs to.
    public let scene: Scene
    /// Its index in `Scene.joints`.
    public let index: Int

    /// The joint `index` of `scene`.
    public init(_ scene: Scene, _ index: Int) {
        precondition(index >= 0 && index <= Int(UInt32.max), "Joint: index \(index) out of range")
        self.scene = scene
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }

    /// The joint's name as the file gives it.
    public var name: String { borrowed(cadaclysm_joint_name(scene.live("Joint"), raw)) }

    /// The link this joint starts at, in the file's order -- not a parent: a mechanism may be
    /// a network with loops.
    public var start: Link { Link(scene, Int(cadaclysm_joint_start(scene.live("Joint"), raw))) }

    /// The link this joint ends at.
    public var end: Link { Link(scene, Int(cadaclysm_joint_end(scene.live("Joint"), raw))) }

    /// How this joint moves: the kinematic pair naming it, or nil when the file gives it none.
    public var pair: Pair? {
        let kind = cadaclysm_joint_pair_kind(scene.live("Joint"), raw)
        guard let kind = PairKind(rawValue: kind) else { return nil }
        return Pair(scene, raw, kind)
    }

    /// Same scene, same index.
    public static func == (lhs: Joint, rhs: Joint) -> Bool {
        lhs.scene === rhs.scene && lhs.index == rhs.index
    }

    /// Hashes the scene's identity and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scene))
        hasher.combine(index)
    }

    /// `Joint(index: …)`.
    public var description: String { "Joint(index: \(index))" }
}

// ---- pairs, freedoms and states ----------------------------------------------------------

/// Which kind of relative motion a `Pair` allows -- `CadaclysmPairKind`.
public enum PairKind: Int32, Sendable {
    case revolute = 0
    case prismatic = 1
    case cylindrical = 2
    case spherical = 3
    case sphericalWithPin = 4
    case planar = 5
    case universal = 6
    case homokinetic = 7
    case screw = 8
    case fullyConstrained = 9
    case unconstrained = 10
    case lowOrder = 11
    case other = 12
}

/// Which motion a `Freedom` is -- `CadaclysmMotion`.
public enum Motion: UInt32, Sendable {
    case rotation = 0
    case translation = 1
}

/// Which contact-frame axis a `Freedom` is about or along -- `CadaclysmFreedomAxis`.
public enum FreedomAxis: UInt32, Sendable {
    case x = 0
    case y = 1
    case z = 2
}

/// One degree of freedom of a `Pair`: which motion, about or along which contact-frame axis,
/// and its optional range. From `Pair.freedoms()`.
public struct Freedom: Hashable, Sendable {
    public let motion: Motion
    public let axis: FreedomAxis
    /// Radians, or the scene's length unit; nil when unbounded.
    public let lower: Double?
    /// Radians, or the scene's length unit; nil when unbounded.
    public let upper: Double?

    fileprivate init(_ raw: CadaclysmFreedom) {
        motion = Motion(rawValue: raw.motion) ?? .rotation
        axis = FreedomAxis(rawValue: raw.axis) ?? .x
        lower = raw.has_lower ? raw.lower : nil
        upper = raw.has_upper ? raw.upper : nil
    }
}

/// A kinematic pair: the kind of relative motion a joint allows between its two links --
/// `Joint.pair`.
public struct Pair {
    private let scene: Scene
    private let joint: UInt32
    /// One of thirteen kinds.
    public let kind: PairKind

    fileprivate init(_ scene: Scene, _ joint: UInt32, _ kind: PairKind) {
        self.scene = scene
        self.joint = joint
        self.kind = kind
    }

    /// The pair's entity type name (`"GEAR_PAIR"`), for `.other`; nil otherwise.
    public var typeName: String? {
        guard let raw = cadaclysm_joint_pair_type(scene.live("Pair"), joint) else { return nil }
        return String(cString: raw)
    }

    /// The kind by name, finer than `kind`: the same thirteen names, and `"gear"` and
    /// `"rack_and_pinion"` for the two coupled pairs `kind` reads as `.other`.
    public var kindName: String {
        if let raw = cadaclysm_joint_pair_kind_name(scene.live("Pair"), joint) {
            return String(cString: raw)
        }
        switch kind {
        case .revolute: return "revolute"
        case .prismatic: return "prismatic"
        case .cylindrical: return "cylindrical"
        case .spherical: return "spherical"
        case .sphericalWithPin: return "spherical_with_pin"
        case .planar: return "planar"
        case .universal: return "universal"
        case .homokinetic: return "homokinetic"
        case .screw: return "screw"
        case .fullyConstrained: return "fully_constrained"
        case .unconstrained: return "unconstrained"
        case .lowOrder: return "low_order"
        case .other: return "other"
        }
    }

    /// The pair's own numbers, in the order `Assembly.pairWith` takes them: `"screw"`
    /// `[pitch]`, `"rack_and_pinion"` `[pinionRadius]`, `"gear"` `[radiusFirst, radiusSecond,
    /// ratio, bevel, helicalAngle]` (always five, the ratio the second link's rotation over
    /// the first's); `[]` for every other kind.
    public var parameters: [Double] {
        let handle = scene.live("Pair")
        let count = cadaclysm_joint_pair_parameters(handle, joint, nil, 0)
        if count == 0 { return [] }
        var out = [Double](repeating: 0, count: Int(count))
        let written = cadaclysm_joint_pair_parameters(handle, joint, &out, count)
        return Array(out.prefix(Int(min(written, count))))
    }

    /// Its pitch -- length per revolution, in the scene's units -- for `.screw`; nil otherwise.
    public var pitch: Double? {
        let raw = cadaclysm_joint_pair_pitch(scene.live("Pair"), joint)
        return raw.isNaN ? nil : raw
    }

    /// Both contact frames as sixteen column-major doubles each -- `Node.rawTransform`'s layout.
    private var rawFrames: ([Double], [Double]) {
        var start = [Double](repeating: 0, count: 16)
        var end = [Double](repeating: 0, count: 16)
        cadaclysm_joint_pair_frames(scene.live("Pair"), joint, &start, &end)
        return (start, end)
    }

    /// The pair's contact frame fixed in its joint's `start` link, in world coordinates at the
    /// file's rest pose, as sixteen column-major doubles -- `Node.rawTransform`'s layout.
    public var rawFrameStart: [Double] { rawFrames.0 }

    /// The pair's contact frame fixed in its joint's `end` link, as sixteen column-major
    /// doubles.
    public var rawFrameEnd: [Double] { rawFrames.1 }

    /// `rawFrameStart` as rows, like `Node.transform`.
    public var frameStart: [[Double]] { rowMajor(rawFrameStart) }

    /// `rawFrameEnd` as rows, like `Node.transform`.
    public var frameEnd: [[Double]] { rowMajor(rawFrameEnd) }

    /// Its degrees of freedom, in the reader's per-kind order. A `State`'s values compose in
    /// this order.
    public func freedoms() -> [Freedom] {
        let handle = scene.live("Pair")
        let count = cadaclysm_joint_freedom_count(handle, joint)
        var out: [Freedom] = []
        out.reserveCapacity(Int(count))
        for i in 0..<count {
            var raw = CadaclysmFreedom()
            if cadaclysm_joint_freedom(handle, joint, i, &raw) {
                out.append(Freedom(raw))
            }
        }
        return out
    }
}

/// One row of a `State`: the joint it sets, and one value per freedom of its pair, in the
/// pair's freedom order.
public struct StateValue {
    public let joint: Joint?
    public let values: [Double]

    /// A row naming `joint` and its values, for `Scene.pose`'s `values` argument.
    public init(joint: Joint?, values: [Double]) {
        self.joint = joint
        self.values = values
    }
}

/// A named pose of the file's mechanism: a `MECHANISM_STATE_REPRESENTATION`. From
/// `Scene.states`.
public struct State {
    public let index: Int
    public let name: String
    /// One row per joint this state sets, in file order.
    public let values: [StateValue]
}

private func readState(_ scene: Scene, _ index: UInt32) -> State {
    let handle = scene.live("State")
    let name = borrowed(cadaclysm_state_name(handle, index))
    let rowCount = cadaclysm_state_value_count(handle, index)
    var rows: [StateValue] = []
    rows.reserveCapacity(Int(rowCount))
    for row in 0..<rowCount {
        var jointIndex: UInt32 = noneIndex
        let n = cadaclysm_state_value(handle, index, row, &jointIndex, nil, 0)
        var values = [Double](repeating: 0, count: Int(n))
        cadaclysm_state_value(handle, index, row, &jointIndex, &values, n)
        let joint = jointIndex == noneIndex ? nil : Joint(scene, Int(jointIndex))
        rows.append(StateValue(joint: joint, values: values))
    }
    return State(index: Int(index), name: name, values: rows)
}

/// One stop of a `MotionSequence`: the state it reaches, at which parameter, and how the motion
/// leaves it.
public struct Segment {
    public let state: State
    public let t: Double
    /// `"undefined"`, `"discontinuous"`, `"synchronous"` or `"linear"`.
    public let interpolation: String
}

/// The lower-case word for a `CadaclysmInterpolation` code.
private func interpolationWord(_ code: UInt32) -> String {
    switch code {
    case 1: return "discontinuous"
    case 2: return "synchronous"
    case 3: return "linear"
    default: return "undefined"
    }
}

/// A named motion over the file's states: an `INTERPOLATED_CONFIGURATION_SEQUENCE`. From
/// `Scene.sequences`.
public struct MotionSequence {
    public let index: Int
    public let name: String
    /// Whether it returns to its first segment (its last segment is not discontinuous).
    public let closed: Bool
    /// Seconds per unit of the parameter, or nil where the file states no time unit (read
    /// the parameter as seconds).
    public let secondsPerUnit: Double?
    /// At least two, in parameter order.
    public let segments: [Segment]
    private let scene: Scene

    fileprivate init(scene: Scene, index: Int, name: String, closed: Bool, secondsPerUnit: Double?, segments: [Segment]) {
        self.scene = scene
        self.index = index
        self.name = name
        self.closed = closed
        self.secondsPerUnit = secondsPerUnit
        self.segments = segments
    }

    /// The parameter of the first segment.
    public var start: Double { segments.first?.t ?? 0 }

    /// The parameter of the last segment.
    public var end: Double { segments.last?.t ?? 0 }

    /// The mechanism posed at parameter `t` (the file's own parameter; see `secondsPerUnit`),
    /// with `ground` held fixed as `Scene.pose` does. Throws `CadaclysmError` for a `t` that
    /// is not finite, carrying `cadaclysm_last_error`'s text unchanged.
    public func pose(_ t: Double, ground: Link? = nil) throws -> Pose {
        let handle = try scene.liveOrThrow()
        let groundIndex = ground.map { UInt32($0.index) } ?? noneIndex
        guard let ptr = cadaclysm_pose_sequence(handle, UInt32(index), t, groundIndex) else {
            throw CadaclysmError(lastErrorOr("pose"))
        }
        return copyPose(scene, ptr)
    }
}

private func readSequence(_ scene: Scene, _ index: UInt32) -> MotionSequence {
    let handle = scene.live("Sequence")
    let name = borrowed(cadaclysm_sequence_name(handle, index))
    let closed = cadaclysm_sequence_closed(handle, index)
    let perUnit = cadaclysm_sequence_seconds_per_unit(handle, index)
    var segments: [Segment] = []
    for i in 0..<cadaclysm_sequence_segment_count(handle, index) {
        var state: UInt32 = 0
        var t = 0.0
        var interpolation: UInt32 = 0
        if cadaclysm_sequence_segment(handle, index, i, &state, &t, &interpolation) {
            segments.append(Segment(state: readState(scene, state), t: t, interpolation: interpolationWord(interpolation)))
        }
    }
    return MotionSequence(scene: scene, index: Int(index), name: name, closed: closed,
                    secondsPerUnit: perUnit > 0 ? perUnit : nil, segments: segments)
}

// ---- work schedules ------------------------------------------------------------------------------

/// The words of the C enums, indexed by their values.
private let scheduleKindWords = ["planned", "actual", "baseline", "notdefined", "other"]
private let taskKindWords = [
    "attendance", "construction", "demolition", "dismantle", "disposal", "installation",
    "logistic", "maintenance", "move", "operation", "removal", "renovation", "notdefined", "other",
]
private let linkKindWords = ["finish_start", "start_start", "finish_finish", "start_finish", "notdefined", "other"]
private let phaseWords = ["unbuilt", "building", "built", "demolishing", "demolished"]

private func word(_ words: [String], _ code: UInt32, fallback: Int) -> String {
    Int(code) < words.count ? words[Int(code)] : words[fallback]
}

/// What one element is doing on a date: `WorkSchedule.at`'s rows.
public struct ElementState {
    /// The element.
    public let node: Node
    /// `"unbuilt"`, `"building"`, `"built"`, `"demolishing"` or `"demolished"`.
    public let phase: String
    /// 0...1 through the window that governs the phase.
    public let progress: Double
    /// Seconds late (positive) or early (negative) against the schedule, or nil where there is
    /// none to give.
    public let variance: Double?
}

/// Every date pair a task gives, each seconds since 1970-01-01T00:00 (`Date(timeIntervalSince1970:)`
/// reads them) or nil where the file gives none; `duration` is in seconds.
public struct TaskTime {
    public let scheduleStart: Double?
    public let scheduleFinish: Double?
    public let earlyStart: Double?
    public let earlyFinish: Double?
    public let lateStart: Double?
    public let lateFinish: Double?
    public let actualStart: Double?
    public let actualFinish: Double?
    public let duration: Double?
}

/// A sequence between two tasks of one schedule. From `WorkSchedule.links`.
public struct TaskLink {
    /// The predecessor.
    public let from: ScheduleTask
    /// The successor.
    public let to: ScheduleTask
    /// `"finish_start"`, `"start_start"`, `"finish_finish"`, `"start_finish"`, `"notdefined"` or `"other"`.
    public let kind: String
    /// The text of a user-defined kind (`kind == "other"`); `""` otherwise.
    public let kindName: String
    /// The time lag in seconds, or nil where the file gives none.
    public let lag: Double?
}

/// One task of a `WorkSchedule`, from `WorkSchedule.tasks`. (`Task` is the concurrency type in
/// Swift, so this is `ScheduleTask`.) Borrows from the scene like `Node`.
public struct ScheduleTask: Hashable, CustomStringConvertible {
    /// The schedule it belongs to.
    public let schedule: WorkSchedule
    /// Its index in `WorkSchedule.tasks`.
    public let index: Int

    fileprivate init(_ schedule: WorkSchedule, _ index: Int) {
        self.schedule = schedule
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }
    private var scheduleRaw: UInt32 { UInt32(schedule.index) }
    private func live(_ member: String = #function) -> OpaquePointer { schedule.scene.live("ScheduleTask", member) }

    /// Its name.
    public var name: String { borrowed(cadaclysm_task_name(live(), scheduleRaw, raw)) }

    /// Its identification, `""` where none.
    public var identification: String { borrowed(cadaclysm_task_identification(live(), scheduleRaw, raw)) }

    /// `"attendance"`, `"construction"`, `"demolition"`, `"dismantle"`, `"disposal"`,
    /// `"installation"`, `"logistic"`, `"maintenance"`, `"move"`, `"operation"`, `"removal"`,
    /// `"renovation"`, `"notdefined"` or `"other"`.
    public var kind: String { word(taskKindWords, cadaclysm_task_kind(live(), scheduleRaw, raw), fallback: 12) }

    /// The text of a user-defined kind (`kind == "other"`); `""` otherwise.
    public var kindName: String { borrowed(cadaclysm_task_kind_name(live(), scheduleRaw, raw)) }

    /// Its status as the file writes it, `""` where none.
    public var status: String { borrowed(cadaclysm_task_status(live(), scheduleRaw, raw)) }

    /// Whether it is a milestone.
    public var milestone: Bool { cadaclysm_task_milestone(live(), scheduleRaw, raw) }

    /// The summary task nesting it, nil at the top.
    public var parent: ScheduleTask? {
        var out: UInt32 = 0
        return cadaclysm_task_parent(live(), scheduleRaw, raw, &out) ? ScheduleTask(schedule, Int(out)) : nil
    }

    /// Every date pair it gives.
    public var time: TaskTime {
        var t = CadaclysmTaskTime()
        _ = cadaclysm_task_time(live(), scheduleRaw, raw, &t)
        return TaskTime(
            scheduleStart: t.has_schedule_start ? t.schedule_start : nil,
            scheduleFinish: t.has_schedule_finish ? t.schedule_finish : nil,
            earlyStart: t.has_early_start ? t.early_start : nil,
            earlyFinish: t.has_early_finish ? t.early_finish : nil,
            lateStart: t.has_late_start ? t.late_start : nil,
            lateFinish: t.has_late_finish ? t.late_finish : nil,
            actualStart: t.has_actual_start ? t.actual_start : nil,
            actualFinish: t.has_actual_finish ? t.actual_finish : nil,
            duration: t.has_duration ? t.duration : nil)
    }

    /// The nodes it builds or removes.
    public var nodes: [Node] {
        let handle = live()
        let count = cadaclysm_task_node_count(handle, scheduleRaw, raw)
        var out = [UInt32](repeating: 0, count: Int(count))
        _ = cadaclysm_task_nodes(handle, scheduleRaw, raw, &out, count)
        return out.map { Node(schedule.scene, Int($0)) }
    }

    /// Same schedule, same index.
    public static func == (lhs: ScheduleTask, rhs: ScheduleTask) -> Bool {
        lhs.schedule == rhs.schedule && lhs.index == rhs.index
    }

    /// Hashes the schedule and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(schedule)
        hasher.combine(index)
    }

    /// `ScheduleTask(index: …)`.
    public var description: String { "ScheduleTask(index: \(index))" }
}

/// A building's programme: an `IfcWorkSchedule` and the tasks it controls. From
/// `Scene.schedules`. Borrows from the scene like `Node`.
///
/// `at` says what each element it names is doing on a date. Dates are seconds since
/// 1970-01-01T00:00, no zone: `Date(timeIntervalSince1970: seconds)`, formatted in UTC.
public struct WorkSchedule: Hashable, CustomStringConvertible {
    /// The scene it belongs to.
    public let scene: Scene
    /// Its index in `Scene.schedules`.
    public let index: Int

    fileprivate init(_ scene: Scene, _ index: Int) {
        self.scene = scene
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }

    /// Its name, else its identification, else `schedule #k` (k from 1, in file order).
    public var name: String { borrowed(cadaclysm_schedule_name(scene.live("WorkSchedule"), raw)) }

    /// Its identification, `""` where none.
    public var identification: String { borrowed(cadaclysm_schedule_identification(scene.live("WorkSchedule"), raw)) }

    /// `"planned"`, `"actual"`, `"baseline"`, `"notdefined"` or `"other"`.
    public var kind: String { word(scheduleKindWords, cadaclysm_schedule_kind(scene.live("WorkSchedule"), raw), fallback: 3) }

    /// The text of a user-defined kind (`kind == "other"`); `""` otherwise.
    public var kindName: String { borrowed(cadaclysm_schedule_kind_name(scene.live("WorkSchedule"), raw)) }

    /// The schedule's start, or nil where the file gives none.
    public var start: Double? {
        var out = 0.0
        return cadaclysm_schedule_start(scene.live("WorkSchedule"), raw, &out) ? out : nil
    }

    /// The schedule's finish, or nil where the file gives none.
    public var finish: Double? {
        var out = 0.0
        return cadaclysm_schedule_finish(scene.live("WorkSchedule"), raw, &out) ? out : nil
    }

    /// Its tasks, in file order.
    public var tasks: [ScheduleTask] {
        let handle = scene.live("WorkSchedule")
        return (0..<Int(cadaclysm_task_count(handle, raw))).map { ScheduleTask(self, $0) }
    }

    /// Its task links (`IfcRelSequence`), in file order.
    public var links: [TaskLink] {
        let handle = scene.live("WorkSchedule")
        let tasks = self.tasks
        var out: [TaskLink] = []
        for i in 0..<cadaclysm_task_link_count(handle, raw) {
            var from: UInt32 = 0, to: UInt32 = 0, kind: UInt32 = 0
            var lag = 0.0
            var hasLag = false
            guard cadaclysm_task_link(handle, raw, i, &from, &to, &kind, &lag, &hasLag) else { continue }
            out.append(TaskLink(
                from: tasks[Int(from)], to: tasks[Int(to)], kind: word(linkKindWords, kind, fallback: 4),
                kindName: borrowed(cadaclysm_task_link_kind_name(handle, raw, i)),
                lag: hasLag ? lag : nil))
        }
        return out
    }

    /// What each element this schedule names is doing on `date` (seconds since
    /// 1970-01-01T00:00), in node order; elements no task names are not listed. `dates` is
    /// `"scheduled"` or `"actual"` -- which of a task's dates to play. Throws `CadaclysmError`
    /// for any other `dates` and for a `date` that is not finite.
    public func at(_ date: Double, dates: String = "scheduled") throws -> [ElementState] {
        let which: UInt32
        switch dates {
        case "scheduled": which = 0
        case "actual": which = 1
        default: throw CadaclysmError("dates must be 'scheduled' or 'actual'")
        }
        let handle = try scene.liveOrThrow()
        let count = cadaclysm_schedule_at(handle, raw, date, which, nil, 0)
        if count < 0 { throw CadaclysmError(lastErrorOr("at")) }
        var rows = [CadaclysmElementState](repeating: CadaclysmElementState(), count: Int(count))
        let filled = cadaclysm_schedule_at(handle, raw, date, which, &rows, UInt32(count))
        if filled < 0 { throw CadaclysmError(lastErrorOr("at")) }
        return rows.prefix(Int(filled)).map {
            ElementState(node: Node(scene, Int($0.node)), phase: word(phaseWords, $0.phase, fallback: 0),
                         progress: $0.progress, variance: $0.has_variance ? $0.variance : nil)
        }
    }

    /// Same scene, same index.
    public static func == (lhs: WorkSchedule, rhs: WorkSchedule) -> Bool {
        lhs.scene === rhs.scene && lhs.index == rhs.index
    }

    /// Hashes the scene's identity and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scene))
        hasher.combine(index)
    }

    /// `WorkSchedule(index: …)`.
    public var description: String { "WorkSchedule(index: \(index))" }
}

/// A posed mechanism: `Scene.pose` or `Scene.poseState`'s answer. The document itself is
/// unchanged.
///
/// Copied eagerly out of the C handle at construction time (`copyPose`), so a `Pose` holds
/// no C pointer and outlives the call that made it -- closing the scene does not
/// invalidate it.
public struct Pose {
    /// The link held fixed.
    public let ground: Link
    /// Joints that close a loop and were not honoured, in file order.
    public let unsolved: [Joint]
    /// `(joint, freedom index, value)` for every given value outside its freedom's range.
    public let outOfRange: [(joint: Joint, freedom: Int, value: Double)]
    /// What the couplings (gear, rack and pinion, a loop-closing screw) could not solve, or
    /// found disagreeing, in file order, in the kernel's words:
    /// `coupling 'mesh': both 'a' and 'b' are given and disagree by 0.1`.
    public let diagnostics: [String]
    private let transforms: [[Double]]

    fileprivate init(ground: Link, unsolved: [Joint],
                     outOfRange: [(joint: Joint, freedom: Int, value: Double)], transforms: [[Double]],
                     diagnostics: [String] = []) {
        self.ground = ground
        self.unsolved = unsolved
        self.outOfRange = outOfRange
        self.diagnostics = diagnostics
        self.transforms = transforms
    }

    /// `node`'s posed transform, as four rows of four doubles -- the same type
    /// `Node.transform` returns.
    public func transform(_ node: Node) -> [[Double]] { rowMajor(rawTransform(node)) }

    /// The same matrix in the ABI's own column-major order, as sixteen doubles, exactly as
    /// `Node.rawTransform` lays them out.
    public func rawTransform(_ node: Node) -> [Double] { transforms[node.index] }

    /// Draw this pose's scene, as `Scene.show` does, with every node at its posed transform
    /// (`cadaclysm_view_set_node_transforms`), as Python's `Pose.show`. The wgpu library's
    /// window blocks until it is closed; any other library prints a still.
    public func show(_ options: ShowOptions = ShowOptions()) throws {
        _ = try ground.scene.draw(options, interactive: false, transforms: transforms.flatMap { $0 }, kind: "Pose")
    }

    /// Orbit the posed scene until its window is closed: where the camera was left, the last pick.
    @discardableResult
    public func view(_ options: ShowOptions = ShowOptions()) throws -> Camera {
        try ground.scene.draw(options, interactive: true, transforms: transforms.flatMap { $0 }, kind: "Pose")
    }
}

/// Reads everything out of a `CadaclysmPose*` into a `Pose`, then frees it (ruling 2 of the
/// posing plan: wrappers copy eagerly, never holding the C pointer). `defer` runs the free
/// even if copying throws partway through.
private func copyPose(_ scene: Scene, _ posePtr: OpaquePointer) -> Pose {
    defer { cadaclysm_pose_free(posePtr) }
    let ground = Link(scene, Int(cadaclysm_pose_ground(posePtr)))
    let nodeCount = cadaclysm_pose_node_count(posePtr)
    var transforms: [[Double]] = []
    transforms.reserveCapacity(Int(nodeCount))
    for node in 0..<nodeCount {
        var raw = [Double](repeating: 0, count: 16)
        cadaclysm_pose_node_transform(posePtr, node, &raw)
        transforms.append(raw)
    }
    var unsolved: [Joint] = []
    let unsolvedCount = cadaclysm_pose_unsolved_count(posePtr)
    for i in 0..<unsolvedCount {
        let joint = cadaclysm_pose_unsolved(posePtr, i)
        if joint != noneIndex { unsolved.append(Joint(scene, Int(joint))) }
    }
    var outOfRange: [(joint: Joint, freedom: Int, value: Double)] = []
    let outOfRangeCount = cadaclysm_pose_out_of_range_count(posePtr)
    for i in 0..<outOfRangeCount {
        var joint: UInt32 = 0
        var freedom: UInt32 = 0
        var value: Double = 0
        if cadaclysm_pose_out_of_range(posePtr, i, &joint, &freedom, &value) {
            outOfRange.append((Joint(scene, Int(joint)), Int(freedom), value))
        }
    }
    var diagnostics: [String] = []
    let diagnosticCount = cadaclysm_pose_diagnostic_count(posePtr)
    for i in 0..<diagnosticCount {
        if let raw = cadaclysm_pose_diagnostic(posePtr, i) { diagnostics.append(String(cString: raw)) }
    }
    return Pose(ground: ground, unsolved: unsolved, outOfRange: outOfRange, transforms: transforms,
                diagnostics: diagnostics)
}

// ---- breps ------------------------------------------------------------------------------------

/// A body's exact B-rep -- the trimmed surfaces its mesh is cut from -- shared with the scene
/// rather than copied, and held by this object until `release()` or `deinit`.
///
/// It is what `Node.brep` hands the kernel's `Solid.fromNode`, which operates on it without a
/// copy, and it can say whether it is a `Manifold`. The brep itself outlives a closed scene. In
/// the node's own frame and the file's own units and axes, whatever the convention; the kernel
/// library must come from the same release as the reader.
public final class Brep {
    // No reference to the scene: the brep is counted by the library and outlives
    // `cadaclysm_close`, so holding the scene would only keep the whole document open.
    private var handle: OpaquePointer?

    init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { release() }

    /// Whether `release()` has run.
    public var released: Bool { handle == nil }

    /// The brep's C pointer, which the kernel's wrapper hands across. Traps once released.
    public var pointer: UnsafeRawPointer {
        guard let handle = handle else { preconditionFailure("Brep.pointer: the brep is released") }
        return UnsafeRawPointer(handle)
    }

    /// How this library lays a brep out in memory: its compiler, target and source. The kernel
    /// shares a brep only with a reader whose id equals its own.
    public static func layoutId() -> String { borrowed(cadaclysm_brep_layout_id()) }

    /// Whether its faces make a manifold, and whether it is closed -- read off the topology the
    /// file wrote, not a mesh. Throws once released, or with the library's reason.
    public var manifold: Manifold {
        get throws {
            guard let handle = handle else { throw CadaclysmError("brep: released") }
            var row = [UInt32](repeating: 0, count: 8)
            guard cadaclysm_brep_manifold(handle, &row) else {
                throw CadaclysmError(lastErrorOr("manifold"))
            }
            return Manifold(row)
        }
    }

    /// This brep with its free edges sewn, and what was sewn, as a new `Brep` and a `SewReport`;
    /// this one is left as it was. Two free edges become one shared edge where both their ends
    /// coincide within `vertex` -- by default the rounding `manifold` merges vertices at -- and
    /// their curves lie within `tolerance` of each other, by default `vertex` too, so only edges
    /// that are one curve written twice are joined. A larger `tolerance` also joins two curves
    /// between the same two vertices that part by up to it; `vertex` is what decides which edges
    /// are candidates at all, and raising it is what could close a slot. Nothing moves. Throws
    /// once released, or with the library's reason.
    public func sewed(tolerance: Double? = nil, vertex: Double? = nil) throws -> (Brep, SewReport) {
        guard let handle = handle else { throw CadaclysmError("brep: released") }
        var counts = [UInt32](repeating: 0, count: 4)
        var gaps = [Double](repeating: 0, count: 3)
        guard let sewn = cadaclysm_brep_sew(handle, tolerance ?? .nan, vertex ?? .nan, &counts, &gaps) else {
            throw CadaclysmError(lastErrorOr("sew"))
        }
        return (Brep(handle: sewn), SewReport(counts: counts, gaps: gaps))
    }

    /// What is wrong with this brep, as a `HealthReport`: the free edges (the sides one face
    /// bounds) and the wires they chain into, with each edge's nearest partner and the gap to it;
    /// the features below `tolerance`; the loose edges; and what `sewed` would join and leave.
    /// `tolerance` is the length below which a feature is small and a gap closes -- nil, or a
    /// value that is not finite and positive, takes the default (the report shows what was
    /// used). `mesh: true` also meshes the brep and reports where the mesh cracks (`cracks`);
    /// without it `cracks` is nil. Nothing moves. Throws once released, or with the library's
    /// reason.
    public func health(tolerance: Double? = nil, mesh: Bool = false) throws -> HealthReport {
        guard let handle = handle else { throw CadaclysmError("brep: released") }
        guard let h = cadaclysm_brep_health(handle, tolerance ?? .nan, mesh) else {
            throw CadaclysmError(lastErrorOr("health"))
        }
        defer { cadaclysm_brep_health_free(h) }
        var counts = [UInt32](repeating: 0, count: 18)
        var sizes = [Double](repeating: 0, count: 8)
        guard cadaclysm_brep_health_summary(h, &counts, &sizes) else { throw CadaclysmError(lastErrorOr("health")) }
        var n = Int(cadaclysm_brep_health_free_edges(h, nil, nil))
        var freeIds = [UInt32](repeating: 0, count: 6 * n), freeSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_brep_health_free_edges(h, &freeIds, &freeSizes) }
        n = Int(cadaclysm_brep_health_wires(h, nil, nil))
        var wireRuns = [UInt32](repeating: 0, count: 3 * n), wireSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_brep_health_wires(h, &wireRuns, &wireSizes) }
        n = Int(cadaclysm_brep_health_small(h, nil, nil))
        var smallItems = [UInt32](repeating: 0, count: 2 * n), smallSizes = [Double](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_brep_health_small(h, &smallItems, &smallSizes) }
        n = Int(cadaclysm_brep_health_crack_edges(h, nil))
        var crackEdges = [UInt32](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_brep_health_crack_edges(h, &crackEdges) }
        return HealthReport(counts: counts, sizes: sizes, freeIds: freeIds, freeSizes: freeSizes, wireRuns: wireRuns,
                            wireSizes: wireSizes, smallItems: smallItems, smallSizes: smallSizes, crackEdges: crackEdges)
    }

    /// This brep with its small features removed, and what was done, as a new `Brep` and a
    /// `HealReport`; this one is left as it was. The features are the ones `health` lists as
    /// small at `tolerance`: short and collapsed edges, sliver and tiny faces, small holes. Every
    /// fix is a vertex merge, and an edge it moves records how far as its `edgeTolerance`. A
    /// guard compares the result's health with this one's and refuses fixes that made it worse
    /// (`guarded`). `edges`, `faces` and `holes` switch each kind of fix; a kind switched off is
    /// refused as `"toggled"`. `tolerance` nil, or a value that is not finite and positive, takes
    /// the default (the report shows what was used). Throws once released, or with the library's
    /// reason.
    public func healed(tolerance: Double? = nil, edges: Bool = true, faces: Bool = true,
                       holes: Bool = true) throws -> (Brep, HealReport) {
        guard let handle = handle else { throw CadaclysmError("brep: released") }
        guard let h = cadaclysm_brep_healed(handle, tolerance ?? .nan, healFlags(edges: edges, faces: faces, holes: holes)) else {
            throw CadaclysmError(lastErrorOr("healed"))
        }
        defer { cadaclysm_brep_heal_free(h) }
        var counts = [UInt32](repeating: 0, count: 11)
        var sizes = [Double](repeating: 0, count: 2)
        guard cadaclysm_brep_heal_summary(h, &counts, &sizes) else { throw CadaclysmError(lastErrorOr("healed")) }
        var n = Int(cadaclysm_brep_heal_fixes(h, nil, nil))
        var fixItems = [UInt32](repeating: 0, count: 2 * n), fixSizes = [Double](repeating: 0, count: 2 * n)
        if n > 0 { _ = cadaclysm_brep_heal_fixes(h, &fixItems, &fixSizes) }
        n = Int(cadaclysm_brep_heal_refused(h, nil, nil))
        var refusedItems = [UInt32](repeating: 0, count: 3 * n), refusedSizes = [Double](repeating: 0, count: n)
        if n > 0 { _ = cadaclysm_brep_heal_refused(h, &refusedItems, &refusedSizes) }
        let report = HealReport(counts: counts, sizes: sizes, fixItems: fixItems, fixSizes: fixSizes,
                                refusedItems: refusedItems, refusedSizes: refusedSizes)
        guard let body = cadaclysm_brep_heal_body(h) else { throw CadaclysmError(lastErrorOr("healed")) }
        return (Brep(handle: body), report)
    }

    /// How far brep edge `edge` (as a `HealFix` names one) may lie off its curve: 0 for an exact
    /// edge, the distance healing (or sewing) moved it where that is recorded, nil when no trim
    /// names the id (an edge healing removed). Throws once released, or for an id that is not a
    /// `UInt32`.
    public func edgeTolerance(_ edge: Int) throws -> Double? {
        guard let handle = handle else { throw CadaclysmError("brep: released") }
        guard let id = UInt32(exactly: edge) else { throw CadaclysmError("edge_tolerance: edge \(edge) is out of range") }
        let t = cadaclysm_brep_edge_tolerance(handle, id)
        return t.isNaN ? nil : t
    }

    /// Give the reference back now. Idempotent; `deinit` does it otherwise.
    public func release() {
        guard let handle = handle else { return }
        self.handle = nil
        cadaclysm_brep_release(handle)
    }
}

/// One meshlet, copied out: the arrays are yours.
public struct Meshlet: Sendable {
    public let index: Int
    /// 0 for a leaf over the mesh itself, higher for a simplified level above it.
    public let level: Int
    public let group: Int
    /// How far this meshlet's level moved the surface; zero at level 0.
    public let error: Float
    /// Three floats a vertex.
    public let positions: [Float]
    /// Three floats a vertex; zeros where the mesh had none.
    public let normals: [Float]
    /// Three a triangle, into this meshlet's own vertices.
    public let indices: [UInt32]
    /// The finer meshlets below this one, for a levelled build.
    public let children: [UInt32]

    public var vertexCount: Int { positions.count / 3 }
    public var triangleCount: Int { indices.count / 3 }
}

/// A mesh split into meshlets, optionally with coarser levels above them, for a mesh-shader or
/// meshlet-based renderer. Built from any mesh and owned by you: `free()` it, or let it go.
public final class Meshlets {
    private var handle: OpaquePointer?

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { free() }

    /// Split `positions` (three floats a vertex), `normals` (the same, or nil) and `indices`
    /// (three a triangle) into meshlets of at most `maxTriangles` and `maxVertices` each -- the
    /// consumer's own limits, with no default: Nanite takes 128/256, a mesh-shader pipeline
    /// 124/64. `levels` above 0 groups and simplifies each level into the next until one
    /// meshlet is left. Throws `CadaclysmError` with the library's reason on failure.
    public static func build(positions: [Float], normals: [Float]?, indices: [UInt32],
                             maxTriangles: Int, maxVertices: Int, levels: Int = 0) throws -> Meshlets {
        guard maxTriangles > 0, maxVertices > 0 else { throw CadaclysmError("meshlets: maxTriangles and maxVertices are required") }
        guard positions.count % 3 == 0, indices.count % 3 == 0 else {
            throw CadaclysmError("meshlets: positions must hold three floats a vertex and indices three a triangle")
        }
        if let normals = normals, normals.count != positions.count {
            throw CadaclysmError("meshlets: normals must hold one per vertex, three floats each")
        }
        let built: OpaquePointer? = positions.withUnsafeBufferPointer { p in
            indices.withUnsafeBufferPointer { i in
                if let normals = normals {
                    return normals.withUnsafeBufferPointer { n in
                        cadaclysm_meshlets_build(p.baseAddress, n.baseAddress, positions.count / 3, i.baseAddress, indices.count,
                                                 UInt32(maxTriangles), UInt32(maxVertices), Int32(levels))
                    }
                }
                return cadaclysm_meshlets_build(p.baseAddress, nil, positions.count / 3, i.baseAddress, indices.count,
                                                UInt32(maxTriangles), UInt32(maxVertices), Int32(levels))
            }
        }
        guard let built = built else {
            let reason = lastError()
            throw CadaclysmError(reason.isEmpty ? "meshlets: build failed" : reason)
        }
        return Meshlets(handle: built)
    }

    private func live() -> OpaquePointer {
        guard let handle = handle else { preconditionFailure("Meshlets: freed") }
        return handle
    }

    /// Whether `free()` has run.
    public var freed: Bool { handle == nil }

    /// Give the meshlets back. Idempotent.
    public func free() {
        guard let handle = handle else { return }
        self.handle = nil
        cadaclysm_meshlets_free(handle)
    }

    /// How many meshlets, every level counted.
    public var count: Int { Int(cadaclysm_meshlets_count(live())) }

    public func triangleCount(_ i: Int) -> Int { Int(cadaclysm_meshlet_triangle_count(live(), UInt32(i))) }
    public func vertexCount(_ i: Int) -> Int { Int(cadaclysm_meshlet_vertex_count(live(), UInt32(i))) }
    /// 0 for a leaf over the mesh itself, higher for a simplified level above it.
    public func level(_ i: Int) -> Int { Int(cadaclysm_meshlet_level(live(), UInt32(i))) }
    public func group(_ i: Int) -> Int { Int(cadaclysm_meshlet_group(live(), UInt32(i))) }
    /// How far this meshlet's level moved the surface; zero at level 0.
    public func error(_ i: Int) -> Float { cadaclysm_meshlet_error(live(), UInt32(i)) }
    public func childCount(_ i: Int) -> Int { Int(cadaclysm_meshlet_child_count(live(), UInt32(i))) }

    /// One meshlet's arrays and numbers, copied out.
    public func meshlet(_ i: Int) -> Meshlet {
        let h = live()
        let idx = UInt32(i)
        let vertices = Int(cadaclysm_meshlet_vertex_count(h, idx))
        let triangles = Int(cadaclysm_meshlet_triangle_count(h, idx))
        let kids = Int(cadaclysm_meshlet_child_count(h, idx))
        var positions = [Float](repeating: 0, count: vertices * 3)
        var normals = [Float](repeating: 0, count: vertices * 3)
        var indices = [UInt32](repeating: 0, count: triangles * 3)
        var children = [UInt32](repeating: 0, count: kids)
        positions.withUnsafeMutableBufferPointer { cadaclysm_meshlet_positions(h, idx, $0.baseAddress) }
        normals.withUnsafeMutableBufferPointer { cadaclysm_meshlet_normals(h, idx, $0.baseAddress) }
        indices.withUnsafeMutableBufferPointer { cadaclysm_meshlet_indices(h, idx, $0.baseAddress) }
        children.withUnsafeMutableBufferPointer { cadaclysm_meshlet_children(h, idx, $0.baseAddress) }
        return Meshlet(index: i, level: Int(cadaclysm_meshlet_level(h, idx)), group: Int(cadaclysm_meshlet_group(h, idx)),
                       error: cadaclysm_meshlet_error(h, idx), positions: positions, normals: normals, indices: indices, children: children)
    }
}

// ---- the FEM surface mesh ------------------------------------------------------------------------

/// One B-rep edge of a FEM mesh: the chain of nodes along it, and where that chain breaks. The
/// numbers are copied out; `nodes` and `runs` are `NativeArray` views borrowed from the `FemMesh`,
/// as its own arrays are, and go with it.
///
/// `nodes` are this mesh's node indices in order along the edge, its end vertices included; a
/// closed edge repeats no node. **`runs` says where the chain breaks**: read
/// `nodes[runs[i] ..< runs[i + 1]]` (the last run to the end) as one polyline and join nothing
/// across a boundary -- the two ends either side of one are two points of the edge with no mesh
/// edge between them, a crack along the edge or a stretch of it the mesher sampled on one face
/// only. `[0]` is the ordinary answer, and reading `nodes` as one polyline without looking here
/// jumps the gap silently.
///
/// `faces` is `(face_a, face_b)` and `ends` is `(end_a, end_b)`, the second of each `UInt32.max`
/// (the ABI's NONE) where there is none -- an open body's rim, or both ends at one vertex (a
/// closed edge, a circle's rim, a full-turn seam). **`0` is a real face and a real vertex, not a
/// sentinel.** Which end comes first is the first trim's direction and means nothing else: the
/// pair bounds the edge, it does not orient it.
public struct FemEdge {
    /// The **body's own** edge id -- not this mesh's edge index, and on a read body rarely equal
    /// to it. `FemMesh.edges` is a densely renumbered subset of the body's edges, ascending by
    /// id, with every edge collapsed to a point left out, so edge 0 of a STEP body's mesh
    /// routinely reports an id in the hundreds. Everything else here that names an edge means the
    /// *index* -- a `FemMesh.nodeKind` of 1 read through `FemMesh.nodeEntity`, the third number
    /// of a census row, and the `edge_<i>` physical group of `FemMesh.mshText()` -- and this is
    /// the one way back from any of them to the topology the file wrote.
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

    init(_ raw: CadaclysmFemEdge, _ owner: FemMesh) {
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
    /// there.
    ///
    /// **A sentinel here is ordinary, not a fault**: the analysis rebuilds a vertex wherever two
    /// trims meet, and a pole's polyline runs give a sphere 48 of them where the mesh has 2
    /// points, so a caller walking these skips the sentinel rather than treating it as a gap.
    public let node: UInt32
    /// Where the vertex is, in the same space and under the same placement as `FemMesh.nodes` --
    /// the file's own vertex rather than a mesh node, so the two can differ by the reader's
    /// rounding. **Meaningless unless `hasPosition`**: it is all zeros then, a point no geometry
    /// has and one a solver would read as a node at the origin.
    public let point: SIMD3<Double>
    /// `point` was read and placed. False where every trim meeting at this vertex is a curve with
    /// no geometry to read an end off -- reported as this flag rather than as a plausible-looking
    /// `(0, 0, 0)`.
    public let hasPosition: Bool

    init(_ raw: CadaclysmFemVertex) {
        node = raw.node
        point = SIMD3(raw.point.0, raw.point.1, raw.point.2)
        hasPosition = raw.has_position
    }

    public var description: String {
        "FemVertex(node=\(node), point=\(point), hasPosition=\(hasPosition))"
    }
}

/// One body meshed for a solver: nodes welded by bits, triangles wound outward, every node tagged
/// with the lowest-dimension B-rep entity it lies on, and every crack reported rather than
/// closed. What `Node.femMesh` returns, and **owned by you**: `free()` it, or let the last
/// reference to it go.
///
/// **A handle rather than a snapshot, and it owns everything it lends.** The five flat arrays are
/// `NativeArray` views into the library's own memory, as `Node.mesh`'s are and for the same
/// reason -- a solver mesh is megabytes, and copying it to hand it over would cost that twice --
/// but the owner of every one of them is **this object** rather than the `Scene`:
/// `Scene.close()` neither frees a FEM mesh nor stales one, meshing the body again does not
/// either, and a FEM mesh outlives the scene it was built through. Only `free()` ends its views,
/// or the last reference to it going.
///
/// So a view **cannot** outlive the memory it reads: it holds this object, which keeps the handle
/// alive, and it checks the owner before every element it hands over -- a read after `free()` traps
/// rather than touching freed memory, and it traps on the **read**, not only when the array is
/// asked for (measured, in a release build). Asking for a view after `free()` traps there and
/// then, as reading any property of a closed `Scene` does. That is what most of the other wrappers
/// cannot do: their view is the platform's own array type with nowhere to hold a reference back to
/// the handle, so a collector can free it under a live view. `copy()` on anything that must
/// outlive the mesh anyway, or `Array(view)`.
public final class FemMesh: NativeMemoryOwner {
    private var handle: OpaquePointer?
    /// Read once, when the handle is made: every pointer in the view is built with the handle and
    /// never moves (nothing in this ABI is built lazily), so asking again per accessor would be
    /// one C call for the same answer.
    private let raw: CadaclysmFemMeshView

    /// The handle a `cadaclysm_node_fem_mesh` call returned, with its view read once -- or the
    /// library's own reason, the handle given back first.
    init(handle: OpaquePointer) throws {
        var view = CadaclysmFemMeshView()
        guard cadaclysm_fem_mesh_view(handle, &view) else {
            let reason = lastErrorOr("fem mesh view")
            cadaclysm_fem_mesh_free(handle)
            throw CadaclysmError(reason)
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

    /// Give the mesh back, and with it every view taken from it. Idempotent; the last reference
    /// going does the same.
    public func free() {
        guard let handle = handle else { return }
        self.handle = nil
        cadaclysm_fem_mesh_free(handle)
    }

    /// The handle, or the error a throwing member reports for a freed mesh.
    private func live(_ member: String = #function) throws -> OpaquePointer {
        guard let handle = handle else { throw CadaclysmError("FemMesh.\(member): the FEM mesh is freed") }
        return handle
    }

    /// A view of this mesh's own memory. Asked for after `free()` it **traps**, as reading any
    /// property of a closed `Scene` or a freed `Meshlets` does in this wrapper and for the same
    /// reason: the alternative is handing back a pointer into freed memory. A view taken while the
    /// mesh was alive traps too, on the read rather than here -- `NativeArray` asks its owner
    /// before every element.
    private func view<Element>(_ base: UnsafePointer<Element>?, _ count: Int,
                               _ member: String = #function) -> NativeArray<Element> {
        guard handle != nil else { preconditionFailure("FemMesh.\(member): the FEM mesh is freed") }
        return NativeArray(owner: self, base: base, count: count)
    }

    // -- the flat arrays, borrowed from this handle

    /// Every node's position, three doubles each -- placed, and in the space `Node.femMesh` and
    /// `fromMesh` describe. Every node is used by at least one triangle.
    public var nodes: NativeArray<Double> { view(raw.nodes, Int(raw.node_count) * 3) }

    /// Three node indices a triangle, wound outward -- a mirroring placement is wound back.
    public var triangles: NativeArray<UInt32> { view(raw.triangles, Int(raw.triangle_count) * 3) }

    /// Which B-rep face each triangle lies on, one per triangle, into the body's `faceCount`
    /// faces.
    public var triangleFace: NativeArray<UInt32> { view(raw.triangle_face, Int(raw.triangle_count)) }

    /// What each node lies on -- `0` a B-rep vertex, `1` an edge, `2` a face -- one per node: the
    /// lowest-dimension entity it lies on, which is the `.msh` format's own classification rule.
    /// `nodeEntity` says which entity of that kind.
    public var nodeKind: NativeArray<UInt32> { view(raw.node_kind, Int(raw.node_count)) }

    /// Which vertex, edge or face each node lies on, read by the matching `nodeKind`: an index
    /// into `vertices`, into `edges`, or into the body's faces.
    public var nodeEntity: NativeArray<UInt32> { view(raw.node_entity, Int(raw.node_count)) }

    // -- the topology

    /// The body's faces; `triangleFace` and a `nodeKind` of `2` index them. **The same faces
    /// `Node.surfaces` hands over**, in the same order, so a caller reads a triangle's surface
    /// and its trims from there.
    public var faceCount: UInt32 { raw.face_count }

    /// One `FemEdge` per B-rep edge, in the order a `nodeKind` of `1` indexes them. Empty for a
    /// `fromMesh` body, which has no B-rep edges at all.
    ///
    /// **This list's own numbering, not the body's**: each `FemEdge.id` carries the body's own
    /// edge id.
    public var edges: [FemEdge] {
        get throws {
            let handle = try live()
            return try (0..<raw.edge_count).map { i in
                var out = CadaclysmFemEdge()
                guard cadaclysm_fem_mesh_edge(handle, i, &out) else {
                    throw CadaclysmError(lastErrorOr("fem mesh edge \(i)"))
                }
                return FemEdge(out, self)
            }
        }
    }

    /// One `FemVertex` per B-rep vertex, in the order a `nodeKind` of `0` indexes them. Empty for
    /// a `fromMesh` body.
    public var vertices: [FemVertex] {
        get throws {
            let handle = try live()
            return try (0..<raw.vertex_count).map { i in
                var out = CadaclysmFemVertex()
                guard cadaclysm_fem_mesh_vertex(handle, i, &out) else {
                    throw CadaclysmError(lastErrorOr("fem mesh vertex \(i)"))
                }
                return FemVertex(out)
            }
        }
    }

    // -- the crack census

    /// Every crack, as `(a, b, brepEdge)`: a directed mesh edge `(a, b)` with no `(b, a)`, and
    /// the B-rep edge both nodes lie on or `UInt32.max` where they share none.
    ///
    /// **Empty unless the body's topology is closed -- for a B-rep body**, whose mesh is
    /// otherwise not asked about at all: such a body reports `watertight` false with this and
    /// `foldedEdges` both empty, and *that trio together* says "not asked", not "nothing found".
    ///
    /// **A `fromMesh` body is the other case, and the opposite one.** A bare mesh carries no
    /// topology to say whether it ought to close, so its census always runs over the welded
    /// triangles, and an empty one there really does mean "nothing found".
    public var openEdges: [(UInt32, UInt32, UInt32)] {
        get throws { try census({ cadaclysm_fem_mesh_open_edge($0, $1, $2, $3, $4) }, raw.open_edge_count, "open edge") }
    }

    /// Every fold, as `openEdges` reports a crack: a directed mesh edge used by more than one
    /// triangle.
    ///
    /// **A body can be folded without being open** -- a solid no thicker than a line leaves no
    /// hole for an open edge to find -- and the closure census's own known-bad bodies are folds
    /// rather than open cracks. A caller that checks `openEdges` alone calls such a body sound.
    /// Empty under the same rule.
    public var foldedEdges: [(UInt32, UInt32, UInt32)] {
        get throws { try census({ cadaclysm_fem_mesh_folded_edge($0, $1, $2, $3, $4) }, raw.folded_edge_count, "folded edge") }
    }

    /// One flattened census, row by row: the shape `openEdges` and `foldedEdges` share, so the
    /// two cannot drift.
    ///
    /// Both call sites wrap the C function in a closure rather than passing it by value. That
    /// is not style: `cadaclysm-capi/tests/bindings.rs`'s parity gate reads a wrapper's calls as
    /// `cadaclysm_...(`, so a bare function reference is a use the gate cannot see -- measured,
    /// when the FEM names came off `PARITY_PENDING_READER` and Swift alone was reported as
    /// lacking these two.
    private func census(_ call: (OpaquePointer?, UInt32, UnsafeMutablePointer<UInt32>?,
                                UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Bool,
                        _ count: UInt32, _ what: String) throws -> [(UInt32, UInt32, UInt32)] {
        let handle = try live()
        return try (0..<count).map { i in
            var a: UInt32 = 0, b: UInt32 = 0, edge: UInt32 = 0
            guard call(handle, i, &a, &b, &edge) else {
                throw CadaclysmError(lastErrorOr("fem mesh \(what) \(i)"))
            }
            return (a, b, edge)
        }
    }

    /// Every pair of triangles that pass through each other, as `(a, b)` with `a < b`, sorted:
    /// an edge of one through the other's interior. Their B-rep faces are `triangleFace[a]` and
    /// `[b]`.
    ///
    /// **Computed for every body, open or closed.** The census `watertight`, `openEdges` and
    /// `foldedEdges` report is topological and cannot see a surface passing through itself; a
    /// mesh is ready for a volume mesher when it is `watertight` **and** this is empty -- Gmsh
    /// refuses one that crosses. A copy.
    public var crossings: [(UInt32, UInt32)] {
        get throws {
            let handle = try live()
            let count = cadaclysm_fem_mesh_crossing_count(handle)
            return try (0..<count).map { i in
                var a: UInt32 = 0, b: UInt32 = 0
                guard cadaclysm_fem_mesh_crossing(handle, i, &a, &b) else {
                    throw CadaclysmError(lastErrorOr("fem mesh crossing \(i)"))
                }
                return (a, b)
            }
        }
    }

    // -- the summary

    /// The welded mesh closes -- every directed mesh edge paired with its reverse and none used
    /// twice -- and, for a B-rep body, so does the topology behind it. **False for every B-rep
    /// body whose topology is not closed**, whose mesh is then not asked about; read `openEdges`
    /// for what an empty census beside a false here does and does not mean.
    ///
    /// A `fromMesh` body has no topology to ask of, so this says only that its triangles close: a
    /// closed render mesh reports true with nothing exact behind it at all.
    public var watertight: Bool { raw.watertight }

    /// This came from the scene's own mesh rather than from a brep: one face, every node on face
    /// `0`, no edges and no vertices.
    ///
    /// **It is also which space the mesh is in.** A B-rep body's FEM mesh is in the file's own
    /// units and axes, whatever `Convention` the scene was opened with, because it is taken off
    /// the brep -- and a brep is in the file's own space for the reason `Brep` gives. A node with
    /// no brep falls back to the scene's mesh, which **is** converted, so that one comes back in
    /// the scene's convention, wound counter-clockwise about the outward normal even where the
    /// convention winds the other way. Under a non-native convention those are two different
    /// spaces.
    ///
    /// **And it is which contract the census is reporting under**: read `openEdges`.
    public var fromMesh: Bool { raw.from_mesh }

    /// The smallest interior angle of any triangle, in degrees. There is always one: a body that
    /// meshed to no triangles is a refusal, not a mesh.
    public var minAngle: Double { raw.min_angle }

    /// The triangle with that angle, as an index into `triangles` (three entries each).
    public var worstTriangle: UInt32 { raw.worst_triangle }

    /// The longest triangle edge, placed. **The figure to check against `Node.femMesh`'s
    /// `maxSize`, and the only one that says what the mesh actually is**: `maxSize` bounds the
    /// boundary segments and merely *targets* the interior -- measured at 1.03x `maxSize` on a
    /// face whose parameters run unevenly -- and one small enough beside the body to reach the
    /// mesher's own piece and station ceilings is not honoured at all. A caller that asked for an
    /// element size reads this to find out whether it got one.
    public var longestEdge: Double { raw.longest_edge }

    // -- out

    /// The mesh as Gmsh 4.1 ASCII `.msh` text: an entity per B-rep vertex, edge and face, a
    /// volume where the body closes, and a physical group naming each.
    ///
    /// **On this side of the ABI the library's text is borrowed** -- a slot on this handle,
    /// replaced by the next call on it and gone when the mesh is freed. It is copied into a
    /// `String` here, so what comes back is the caller's own and outlives the handle; nothing has
    /// to be freed. The kernel library's `Blacksmith.FemMesh.mshText()` is the other way round:
    /// an owned string, released by that wrapper with `cadaclysm_blacksmith_string_free`. A
    /// reader porting one side's reasoning onto the other leaks or double-frees.
    ///
    /// **No unlicensed notice is printed here.** `Node.femMesh` gave it once when the mesh was
    /// built, and this ABI deliberately does not repeat it on either `.msh` call -- where the
    /// kernel library notices on both of its writers and *not* on its builder. Each matches its
    /// own siblings.
    ///
    /// Throws for a mesh the writer refuses, naming the field it cannot honour, and for a freed
    /// handle.
    public func mshText() throws -> String {
        guard let text = cadaclysm_fem_mesh_msh_text(try live()) else {
            throw CadaclysmError(lastErrorOr("msh text"))
        }
        // Copied, not freed: the pointer is the handle's own slot.
        return String(cString: text)
    }

    /// `mshText()` written to `path` by the library itself: the same bytes from the same writer,
    /// straight to the file rather than through the borrowed slot, so a text asked of this handle
    /// on another thread cannot be freed under the write.
    ///
    /// Throws for a mesh the writer refuses or a file it cannot write, naming the path. No notice
    /// here either; see `mshText()`.
    public func saveMsh(_ path: String) throws {
        guard cadaclysm_fem_mesh_save_msh(try live(), path) else {
            throw CadaclysmError(lastErrorOr("could not write \(path)"))
        }
    }
}

extension FemMesh: CustomStringConvertible {
    public var description: String {
        freed ? "FemMesh(freed)"
            : "FemMesh(nodes=\(raw.node_count), triangles=\(raw.triangle_count), "
                + "watertight=\(raw.watertight), fromMesh=\(raw.from_mesh))"
    }
}

// ---- nodes --------------------------------------------------------------------------------------

/// One node of the document: an assembly, a part, a body, a layer, a placement.
///
/// A handle rather than a snapshot: every property asks the scene when read, so nothing goes
/// stale and nothing is built that is never looked at. Names and attributes are cheap; `bounds`
/// and `mesh` build the geometry. Equal when it is the same index of the same scene.
public struct Node: Hashable, CustomStringConvertible {
    /// The scene it belongs to.
    public let scene: Scene
    /// Its index in the scene, stable while the scene is open.
    public let index: Int

    /// The node `index` of `scene`, as `Scene.query` names them.
    public init(_ scene: Scene, _ index: Int) {
        precondition(index >= 0 && index <= Int(UInt32.max), "Node: index \(index) out of range")
        self.scene = scene
        self.index = index
    }

    private var raw: UInt32 { UInt32(index) }

    private func live(_ member: String = #function) -> OpaquePointer { scene.live("Node", member) }

    private func node(_ index: UInt32) -> Node? { index == noneIndex ? nil : Node(scene, Int(index)) }

    /// The name the file gave it, or empty.
    public var name: String { borrowed(cadaclysm_node_name(live(), raw)) }

    /// What the file calls it: a STEP `#N`, an IFC GlobalId, a Rhino object id.
    public var id: String { borrowed(cadaclysm_node_id(live(), raw)) }

    /// Its type in the file: an IFC class, an openNURBS class, a STEP shape kind.
    public var kind: String { borrowed(cadaclysm_node_kind(live(), raw)) }

    /// Whether the file says to show it when opened: its own switch, not inherited; true where
    /// the format has no such switch.
    public var visible: Bool { cadaclysm_node_visible(live(), raw) }

    /// `visible` with every ancestor consulted: a layer switched off hides what hangs under it.
    public var visibleNow: Bool {
        var node: Node? = self
        while let current = node {
            if !current.visible { return false }
            node = current.parent
        }
        return true
    }

    /// Whether the file says it cannot be selected or edited (Rhino's lock, own or by layer).
    /// A locked node is still drawn; formats without the idea answer false.
    public var locked: Bool {
        attributes.first(where: { $0.name == "Locked" })?.truthy ?? false
    }

    /// Something to put in a tree row: the name, else the kind, else `#index`.
    public var label: String {
        let name = self.name
        if !name.isEmpty { return name }
        let kind = self.kind
        return kind.isEmpty ? "#\(index)" : kind
    }

    /// How far down the tree it sits; a root is zero.
    public var depth: Int { Int(cadaclysm_node_depth(live(), raw)) }

    /// What its geometry was before it was triangles -- `brep`, `mesh`, `csg` -- or empty for a
    /// node that draws nothing.
    public var generator: String { borrowed(cadaclysm_node_generator(live(), raw)) }

    /// The node containing this one, or nil for a root.
    public var parent: Node? { node(cadaclysm_node_parent(live(), raw)) }

    /// The nodes directly under this one.
    public var children: [Node] {
        let handle = live()
        return (0..<cadaclysm_node_child_count(handle, raw)).map {
            Node(scene, Int(cadaclysm_node_child(handle, raw, $0)))
        }
    }

    /// The node whose geometry this one places, or nil: a part placed seventy times is one mesh
    /// and seventy transforms, and this is how a caller knows to upload it once.
    public var instanceOf: Node? { node(cadaclysm_node_instance_of(live(), raw)) }

    /// What a click on this node's geometry should select -- usually itself; an IFC
    /// representation under its product points back at the product.
    public var selectAs: Node { node(cadaclysm_node_select_as(live(), raw)) ?? self }

    /// Everything the file said about the node.
    public var attributes: [Attribute] {
        let handle = live()
        return (0..<cadaclysm_node_attribute_count(handle, raw)).compactMap {
            Attribute(cadaclysm_node_attribute(handle, raw, $0))
        }
    }

    /// Whether the node has geometry of its own to draw. Builds nothing; most nodes are
    /// structure and answer false.
    public var canMesh: Bool { cadaclysm_node_can_mesh(live(), raw) }

    /// Draw the scene with every node outside this one hidden, this one framed (Python's
    /// `Node.show`). The wgpu library's window blocks until it is closed; any other library
    /// prints a still.
    public func show(_ options: ShowOptions = ShowOptions()) throws {
        _ = try scene.liveOrThrow()  // a closed scene throws here, before the path is read
        _ = try scene.draw(options, interactive: false, focus: (UInt32(index), siblingsAlongPath), kind: "Node")
    }

    /// Orbit this node until its window is closed: where the camera was left, the last pick.
    @discardableResult
    public func view(_ options: ShowOptions = ShowOptions()) throws -> Camera {
        _ = try scene.liveOrThrow()
        return try scene.draw(options, interactive: true, focus: (UInt32(index), siblingsAlongPath), kind: "Node")
    }

    /// Node focus, as every wrapper does it: every root but this node's own, then at each
    /// level down to this node every child but the next one on the path. Nothing on the path
    /// is hidden, so nothing has to be shown again.
    var siblingsAlongPath: [UInt32] {
        var path = [self]  // this node .. its root
        while let up = path.last?.parent { path.append(up) }
        var hide = scene.roots.filter { $0.index != path.last!.index }.map { UInt32($0.index) }
        for level in stride(from: path.count - 1, to: 0, by: -1) {
            let keep = path[level - 1].index
            hide += path[level].children.filter { $0.index != keep }.map { UInt32($0.index) }
        }
        return hide
    }

    /// Write this node's own mesh -- where it is defined, without its placement -- in one of
    /// `meshFormats()`. Throws for a node that draws nothing or an unknown format; ask
    /// `canMesh` first to grey out a menu entry. For the whole model see `Scene.save`.
    public func saveMesh(_ path: String, format: String = "stl") throws {
        let handle = try scene.liveOrThrow()
        if !cadaclysm_node_save_mesh(handle, raw, path, format) {
            throw CadaclysmError(lastErrorOr("could not write \(path)"))
        }
    }

    /// The colour the file gave it as RGBA in 0–1, or nil -- most STEP files carry none, and the
    /// caller's default is the right answer.
    public var colour: SIMD4<Float>? {
        var rgba = [Float](repeating: 0, count: 4)
        guard cadaclysm_node_color(live(), raw, &rgba) else { return nil }
        return SIMD4(rgba[0], rgba[1], rgba[2], rgba[3])
    }

    /// Where the node's geometry sits: four rows of four doubles (`transform[row][column]`),
    /// composed through every frame above it. Doubles while the mesh is floats, so a model at
    /// survey coordinates keeps its millimetres.
    public var transform: [[Double]] { rowMajor(rawTransform) }

    /// The same matrix as sixteen doubles in the ABI's column-major order, ready for a GPU.
    public var rawTransform: [Double] {
        var out = [Double](repeating: 0, count: 16)
        cadaclysm_node_transform(live(), raw, &out)
        return out
    }

    /// The extent of the node's geometry in that geometry's own frame. Builds the geometry if
    /// needed; carry it through `transform` for world coordinates.
    public var bounds: Bounds { Bounds(cadaclysm_node_bounds(live(), raw)) }

    /// `bounds` in `double`, exact far from the origin where `bounds`'s `Float` cannot be.
    public var bounds64: Bounds { Bounds(cadaclysm_node_bounds64(live(), raw)) }

    private func mesh(_ got: CadaclysmMesh) -> Mesh {
        let n = Int(got.vertex_count)
        return Mesh(positions: NativeArray(owner: scene, base: got.positions, count: n * 3),
                    normals: got.normals.map { NativeArray(owner: scene, base: $0, count: n * 3) },
                    uvs: got.uvs.map { NativeArray(owner: scene, base: $0, count: n * 2) },
                    colors: got.colors.map { NativeArray(owner: scene, base: $0, count: n * 4) },
                    indices: NativeArray(owner: scene, base: got.indices, count: Int(got.index_count)),
                    vertexCount: n, indexCount: Int(got.index_count))
    }

    /// Its triangles in their own frame, built now if they have not been. A node that
    /// instances another hands back the instanced node's arrays -- the same memory for every
    /// placement. Views into the scene.
    public var mesh: Mesh { mesh(cadaclysm_node_mesh(live(), raw)) }

    /// Its triangles at a coarser level of detail: 0 is `mesh` itself, 1 up to `lodLevels()`
    /// each about a quarter of the triangles of the one before, and past that empty. Every
    /// level shares the level-0 vertices -- the same positions and `vertexCount`, only the
    /// indices differ -- so upload the vertices once and switch level by drawing a different
    /// index range.
    public func meshLod(_ level: Int) -> Mesh { mesh(cadaclysm_node_mesh_lod(live(), raw, UInt32(level))) }

    private func mesh64(_ got: CadaclysmMesh64) -> Mesh64 {
        let n = Int(got.vertex_count)
        let lent = LentMesh(scene)
        return Mesh64(positions: NativeArray(owner: lent, base: got.positions, count: n * 3),
                     normals: got.normals.map { NativeArray(owner: lent, base: $0, count: n * 3) },
                     uvs: got.uvs.map { NativeArray(owner: lent, base: $0, count: n * 2) },
                     colors: got.colors.map { NativeArray(owner: lent, base: $0, count: n * 4) },
                     indices: NativeArray(owner: lent, base: got.indices, count: Int(got.index_count)),
                     vertexCount: n, indexCount: Int(got.index_count))
    }

    /// `mesh` in `double`: the document's own mesh, lent as it is, where `mesh` hands back a
    /// `Float` copy -- the same triangles and indices, `mesh`'s positions being exactly these
    /// narrowed. For a caller that uses the mesh as geometry (an exporter, a measurement, a
    /// solver) and wants the file's own coordinates, which `Float` cannot hold far from the
    /// origin. Colours stay `Float`, RGBA in 0...1 needing no more.
    ///
    /// **A forget drops it, unlike `mesh`.** `Scene.forgetMeshes()` frees the document's mesh
    /// these arrays view; `mesh`'s arrays survive a forget, being a separate copy the library
    /// keeps. A `Mesh64`'s `NativeArray`s carry the scene's forget count as well as the check
    /// that the scene is open, so a read after `forgetMeshes()` traps (and `isValid` turns
    /// false) rather than reading freed memory: ask for `mesh64` again rather than reuse one
    /// held from before the forget.
    public var mesh64: Mesh64 { mesh64(cadaclysm_node_mesh64(live(), raw)) }

    /// How far `meshLod(level)` moved the surface, in the scene's units -- what to pick a
    /// level by. Zero at level 0.
    public func lodError(_ level: Int) -> Float { cadaclysm_node_lod_error(live(), raw, UInt32(level)) }

    /// This node's body meshed for a solver, as a `FemMesh`: nodes welded by bits -- two mesh
    /// points are one node only where their coordinates are the same doubles, so no tolerance
    /// ever merges two distinct points and a crack stays a crack -- triangles wound outward, and
    /// every node tagged with the lowest-dimension B-rep entity it lies on.
    ///
    /// `tolerance` is the chordal tolerance in model units, finite and above zero, and **it alone
    /// governs how closely the mesh follows the geometry**. `maxSize` is a size ceiling, finite
    /// and zero or more, `0` being no ceiling (curvature alone): **it bounds the boundary and
    /// targets the interior**, which is not a longest-element-edge guarantee -- it adds boundary
    /// nodes without refining boundary geometry, and `FemMesh.longestEdge` is what the mesh
    /// actually came to, the figure a solver caller checks.
    ///
    /// **Neither is checked here.** On the mesh-only path below the library reads no options at
    /// all: a `tolerance` of 0, -1 or NaN and a `maxSize` of -1 or NaN all come back as a mesh,
    /// while the B-rep path refuses each in its own words. A wrapper that validated either field
    /// would pass every test written against the B-rep path and be wrong; both go through as
    /// given. `0.01` and `0.0` are `FemOptions::default()`'s own figures, restated here so the
    /// signature says what a caller gets -- the library's struct is still filled by
    /// `cadaclysm_fem_options_init` first, so a field added to it later defaults without this
    /// code being touched.
    ///
    /// `placement` is **sixteen** numbers, column-major, as `boundsPlaced` takes them (nil for
    /// the identity), applied in `Double` throughout. The kernel library's `Solid.femMesh` takes
    /// **twelve** instead -- a `Frame`: origin, x, y, z -- so a caller moving between the two
    /// reformats the placement. The length is the one thing this wrapper checks itself, because
    /// the ABI is handed a bare pointer and cannot.
    ///
    /// **The space is the body's, not the scene's, for a B-rep -- and the scene's for a mesh**,
    /// which `FemMesh.fromMesh` is the flag for; read it there, because under a non-native
    /// convention the two are different spaces. Meshed in the part's own frame, following the hop
    /// from an instance to the shape it draws that `mesh` follows, so a node instanced six times
    /// meshes once.
    ///
    /// **A cracked body is not a failure**: it comes back with `FemMesh.watertight` false and its
    /// cracks in `FemMesh.openEdges` / `FemMesh.foldedEdges`, folded edges as prominent as open
    /// ones, and nothing is welded shut to make it look sound. Throws for a tolerance or size the
    /// mesher refuses, a placement that is not sixteen finite and invertible numbers, a node with
    /// neither a brep nor a mesh (an assembly, a storey, a layer, an empty definition, a curve),
    /// and a body that meshes to no triangles at all.
    ///
    /// Prints the unlicensed notice once, here, and not again on either of `FemMesh`'s `.msh`
    /// calls.
    public func femMesh(tolerance: Double = 0.01, maxSize: Double = 0.0,
                        placement: [Double]? = nil) throws -> FemMesh {
        if let placement = placement, placement.count != 16 {
            throw CadaclysmError("femMesh: a placement is 16 numbers, not \(placement.count)")
        }
        var options = CadaclysmFemOptions()
        // `init` writes `sizeof(CadaclysmFemOptions)` bytes as the *library* knows that type,
        // into the struct this package's own copy of the header declares -- the two are the same
        // declaration, the header being imported rather than transcribed. `size` is then set to
        // this header's sizeof, which is what the growth rule asks of a caller.
        cadaclysm_fem_options_init(&options)
        options.size = MemoryLayout<CadaclysmFemOptions>.size
        options.tolerance = tolerance
        options.max_size = maxSize
        let handle = try withUnsafePointer(to: &options) { opts -> OpaquePointer in
            let made: OpaquePointer? = placement.map { matrix in
                matrix.withUnsafeBufferPointer { cadaclysm_node_fem_mesh(live(), raw, $0.baseAddress, opts) }
            } ?? cadaclysm_node_fem_mesh(live(), raw, nil, opts)
            guard let made = made else { throw CadaclysmError(lastErrorOr("fem_mesh")) }
            return made
        }
        return try FemMesh(handle: handle)
    }

    /// Its faces as exact surfaces plus the trim loops that cut them, each in the surface's own
    /// (u, v). Nothing is meshed for it. Empty where the reader has no parametric description.
    /// In the file's frame -- see `Scene.surfaceMatrix`.
    public var surfaces: Surfaces {
        let got = cadaclysm_node_surfaces(live(), raw)
        guard got.face_count > 0, let faces = got.faces else { return Surfaces(faces: []) }
        let scene = self.scene
        func slice(_ base: UnsafePointer<Float>?, _ start: UInt32, _ count: UInt32, _ stride: Int) -> NativeArray<Float> {
            NativeArray(owner: scene, base: base.map { $0 + Int(start) * stride }, count: Int(count) * stride)
        }
        let out = (0..<Int(got.face_count)).map { i -> Face in
            let f = faces[i]
            let loops = (0..<Int(f.loop_count)).map { k -> NativeArray<Float> in
                let entry = got.loops.unsafelyUnwrapped + (Int(f.loop_start) + k) * 2
                return slice(got.points, entry[0], entry[1], 2)
            }
            return Face(kind: Int(f.kind), reversed: f.reversed != 0, transposed: f.transposed != 0,
                        origin: SIMD3(f.origin.0, f.origin.1, f.origin.2),
                        ax: SIMD3(f.ax.0, f.ax.1, f.ax.2),
                        ay: SIMD3(f.ay.0, f.ay.1, f.ay.2),
                        az: SIMD3(f.az.0, f.az.1, f.az.2),
                        domain: SIMD4(f.domain.0, f.domain.1, f.domain.2, f.domain.3),
                        scalars: SIMD4(f.scalars.0, f.scalars.1, f.scalars.2, f.scalars.3),
                        loops: loops,
                        profile: slice(got.profiles, f.profile_start, f.profile_count, 4),
                        profile2: slice(got.profiles, f.profile2_start, f.profile2_count, 4),
                        nurbs: slice(got.nurbs, f.nurbs_start, f.nurbs_count, 1))
        }
        return Surfaces(faces: out)
    }

    /// Its exact B-rep, for the kernel's `Solid.fromNode` -- or nil where it has none (a mesh,
    /// a curve, a CSG body, a JT or OpenSCAD part). Shared with the scene, not copied.
    public var brep: Brep? {
        guard let handle = cadaclysm_node_brep(live(), raw) else { return nil }
        return Brep(handle: handle)
    }

    private func polylines(_ got: CadaclysmPolylines) -> Polylines {
        Polylines(positions: NativeArray(owner: scene, base: got.positions, count: Int(got.vertex_count) * 3),
                  counts: NativeArray(owner: scene, base: got.counts, count: Int(got.polyline_count)),
                  polylineCount: Int(got.polyline_count), vertexCount: Int(got.vertex_count))
    }

    /// Its feature edges as polylines, for an outline overlay. Builds the geometry if needed.
    public var edges: Polylines { polylines(cadaclysm_node_edges(live(), raw)) }

    private func colours(_ got: CadaclysmEdgeColors) -> [SIMD4<Float>?] {
        guard let rgba = got.rgba, got.count > 0 else { return [] }
        let buffer = UnsafeBufferPointer(start: rgba, count: Int(got.count) * 4)
        return (0..<Int(got.count)).map { i -> SIMD4<Float>? in
            let w = buffer[4 * i + 3]
            guard w >= 0 else { return nil }
            return SIMD4(buffer[4 * i], buffer[4 * i + 1], buffer[4 * i + 2], w)
        }
    }

    /// One RGBA per polyline of `edges`, nil for an edge the file does not style; empty when
    /// nothing is styled.
    public var edgeColours: [SIMD4<Float>?] { colours(cadaclysm_node_edge_colors(live(), raw)) }

    /// Its free curves as polylines; a 2D drawing is all of these.
    public var curves: Polylines { polylines(cadaclysm_node_curves(live(), raw)) }

    /// Lines ruled across its surfaces, so a curved face reads as curved in a wireframe. A flat
    /// face yields its outline, so these can overlap `edges`.
    public var isocurves: Polylines { polylines(cadaclysm_node_isocurves(live(), raw)) }

    private func beziers(_ got: CadaclysmBeziers) -> Beziers {
        let n = Int(got.count)
        return Beziers(points: NativeArray(owner: scene, base: got.points, count: n * 12),
                       weights: NativeArray(owner: scene, base: got.weights, count: n * 4), count: n)
    }

    /// Its feature edges as cubic Bézier curves -- exact where the file's curves were, where
    /// `edges` are their chords. Builds the geometry if needed.
    public var edgeBeziers: Beziers { beziers(cadaclysm_node_edge_beziers(live(), raw)) }

    /// Its free curves as cubic Béziers; see `edgeBeziers`.
    public var curveBeziers: Beziers { beziers(cadaclysm_node_curve_beziers(live(), raw)) }

    /// Its isocurves as cubic Béziers; see `edgeBeziers`.
    public var isocurveBeziers: Beziers { beziers(cadaclysm_node_isocurve_beziers(live(), raw)) }

    private func beziers64(_ got: CadaclysmBeziers64) -> Beziers64 {
        let n = Int(got.count)
        return Beziers64(points: NativeArray(owner: scene, base: got.points, count: n * 12),
                         weights: NativeArray(owner: scene, base: got.weights, count: n * 4), count: n)
    }

    /// `edgeBeziers` in `double`: the same segments, unnarrowed.
    public var edgeBeziers64: Beziers64 { beziers64(cadaclysm_node_edge_beziers64(live(), raw)) }

    /// This node's silhouette -- where its surfaces turn away from the eye, which no edge of it lies
    /// on -- as rational cubic Béziers in `double`, from the camera `options` describes. The same
    /// `SvgOptions` that draw a picture: `view`, `azimuth`, `elevation`, `up` and `fov`, and `width`
    /// with `tolerance`, which the library reads together as the page fraction `tolerance / width`.
    /// Nothing else in them changes the curves.
    ///
    /// Unlike `edgeBeziers64` this is a copy. The library keeps one silhouette slot per scene and the
    /// next silhouette call on that scene, for any node, replaces it, so the views `edgeBeziers64`
    /// would give change under a caller who asked twice; this copies out of the slot before it
    /// returns. Calls sharing a scene across threads must serialise their silhouette calls, as the
    /// library documents.
    ///
    /// A body with no silhouette (every face planar) is an empty answer (`count == 0`), not an error;
    /// a refused option, a body with no measurable geometry or a node holding no shape of its own
    /// throws.
    public func silhouetteBeziers(_ options: SvgOptions = SvgOptions()) throws -> Beziers64 {
        let handle = try scene.liveOrThrow()
        var cOptions = try buildSvgOptions(options, defaultUp: scene.defaultUp)
        let got = withUnsafePointer(to: &cOptions) { cadaclysm_node_silhouette_beziers(handle, raw, $0) }
        if got.count == 0 || got.points == nil {
            // The library clears the thread's error at entry and the empty answer sets none: a
            // reason here is this call's own refusal, none is the empty answer.
            let reason = lastError()
            if !reason.isEmpty { throw CadaclysmError(reason) }
            return Beziers64(points: [], weights: [])
        }
        return beziers64(got).copy()
    }

    /// `curveBeziers` in `double`; see `edgeBeziers64`.
    public var curveBeziers64: Beziers64 { beziers64(cadaclysm_node_curve_beziers64(live(), raw)) }

    /// `isocurveBeziers` in `double`; see `edgeBeziers64`.
    public var isocurveBeziers64: Beziers64 { beziers64(cadaclysm_node_isocurve_beziers64(live(), raw)) }

    /// The collision body for what this node draws, building its mesh if it is not built.
    /// `hullBudget` is the most triangles a hull may have; 0 asks for the Unity limit (255) and
    /// is not clamped to it. Nil for a node that draws nothing. Cached per node and budget.
    public func collision(hullBudget: Int = 0) -> Collision? {
        var raw = CadaclysmCollision()
        raw.size = UInt32(MemoryLayout<CadaclysmCollision>.size)
        guard cadaclysm_node_collision(live(), self.raw, UInt32(hullBudget), &raw) else { return nil }
        return Collision(raw)
    }

    /// The convex hull `collision` counted, as triangles. Empty for a node that draws nothing.
    /// A view into the scene, good until it closes or this node is asked for a different
    /// `hullBudget`, which refits and frees it.
    public func collisionHull(hullBudget: Int = 0) -> CollisionHull {
        let got = cadaclysm_node_collision_hull(live(), raw, UInt32(hullBudget))
        return CollisionHull(positions: NativeArray(owner: scene, base: got.positions, count: Int(got.vertex_count) * 3),
                             indices: NativeArray(owner: scene, base: got.indices, count: Int(got.index_count)),
                             vertexCount: Int(got.vertex_count), indexCount: Int(got.index_count))
    }

    // -- the surface path: for a renderer drawing exact surfaces, never triangles --

    /// The box of what this node draws under `placement` (16 numbers, column-major, as
    /// `Placement.rawTransform`; nil for the identity), for a part drawn from its surfaces:
    /// tighter than placing the corners of `bounds`. All zeros for a part with no surfaces.
    public func boundsPlaced(_ placement: [Double]? = nil) throws -> Bounds {
        if let placement = placement, placement.count != 16 {
            throw CadaclysmError("boundsPlaced: a placement is 16 numbers, not \(placement.count)")
        }
        if let placement = placement {
            return placement.withUnsafeBufferPointer { Bounds(cadaclysm_node_bounds_placed(live(), raw, $0.baseAddress)) }
        }
        return Bounds(cadaclysm_node_bounds_placed(live(), raw, nil))
    }

    /// `boundsPlaced` in `double`, exact far from the origin where `boundsPlaced`'s `Float`
    /// cannot be.
    public func boundsPlaced64(_ placement: [Double]? = nil) throws -> Bounds {
        if let placement = placement, placement.count != 16 {
            throw CadaclysmError("boundsPlaced64: a placement is 16 numbers, not \(placement.count)")
        }
        if let placement = placement {
            return placement.withUnsafeBufferPointer { Bounds(cadaclysm_node_bounds_placed64(live(), raw, $0.baseAddress)) }
        }
        return Bounds(cadaclysm_node_bounds_placed64(live(), raw, nil))
    }

    /// Whether its mesh has been built and is held -- by `Scene.realizeAll()`, by an ask for
    /// it, or by anything else that needed it.
    public var isMeshed: Bool { cadaclysm_node_is_meshed(live(), raw) }

    /// Its face boundaries taken from its trimmed surfaces -- the outline that costs no
    /// tessellation, where `edges` meshes the part. In the surfaces' own frame (see
    /// `Scene.surfaceMatrix`); empty without surfaces.
    public var surfaceEdges: Polylines { polylines(cadaclysm_node_surface_edges(live(), raw)) }

    /// Its edges as the exact curves, where the reader has them without meshing -- a Rhino
    /// extrusion's rims are its profile -- and empty everywhere else, so a caller drawing from
    /// surfaces tries this before `surfaceEdges`, whose trims are thinned to the mesh
    /// tolerance. The same segments as `edgeBeziers`, in the same space: not the surfaces'
    /// frame, so no `Scene.surfaceMatrix`.
    public var surfaceEdgeBeziers: Beziers { beziers(cadaclysm_node_surface_edge_beziers(live(), raw)) }

    /// `edgeColours` for `surfaceEdges`.
    public var surfaceEdgeColours: [SIMD4<Float>?] { colours(cadaclysm_node_surface_edge_colors(live(), raw)) }

    /// Its isocurves taken from its trimmed surfaces and clipped to the trims, without meshing;
    /// a flat face gets none. In the surfaces' frame; empty without surfaces.
    public var surfaceIsocurves: Polylines { polylines(cadaclysm_node_surface_isocurves(live(), raw)) }

    /// Where the segment `from`..`to` first meets this part's surfaces, or nil where it meets
    /// none. Exact, and in the surfaces' own frame: carry a ray from the scene's space through
    /// the inverse of `Scene.surfaceMatrix` first.
    public func surfacePick(from: SIMD3<Double>, to: SIMD3<Double>) -> SIMD3<Double>? {
        var a = [from.x, from.y, from.z], b = [to.x, to.y, to.z], hit = [0.0, 0.0, 0.0]
        let ok = cadaclysm_node_surface_pick(live(), raw, &a, &b, &hit)
        return ok ? SIMD3(hit[0], hit[1], hit[2]) : nil
    }

    /// A coarse mesh over its surfaces for what needs triangles and not a picture (ray tracing,
    /// distance fields): each face gridded `cells` by `cells`, never welded, built once per part
    /// at the first size asked. Empty without surfaces or for zero cells.
    public func surfaceProxyMesh(cells: Int) -> Mesh { mesh(cadaclysm_node_surface_proxy_mesh(live(), raw, UInt32(cells))) }

    /// About how many triangles `mesh` would give, without building it; -1 where the reader
    /// cannot say without doing the work. Treat -1 as unknown, never as zero.
    public var triangleEstimate: Int { Int(cadaclysm_node_triangle_estimate(live(), raw)) }

    /// This node and every node under it, parents before children.
    public func walk() -> [Node] {
        var out: [Node] = []
        var stack = [self]
        while let node = stack.popLast() {
            out.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        return out
    }

    /// Same scene, same index.
    public static func == (lhs: Node, rhs: Node) -> Bool {
        lhs.scene === rhs.scene && lhs.index == rhs.index
    }

    /// Hashes the scene's identity and the index.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(scene))
        hasher.combine(index)
    }

    /// `<Node index label>`.
    public var description: String {
        scene.closed ? "<Node \(index) (scene closed)>" : "<Node \(index) \(label)>"
    }

    /// This node's own wireframe as SVG text, in its own frame -- `Scene.svgText`'s single-node
    /// form: one `<g id="node-<index>">`, no placement, from the camera `options` describes.
    /// Borrowed by the library: copied out before this returns, and replaced by the scene's
    /// next `svgText` or `svg` call.
    public func svgText(_ options: SvgOptions = SvgOptions()) throws -> String {
        let handle = try scene.liveOrThrow()
        var cOptions = try buildSvgOptions(options, defaultUp: scene.defaultUp)
        guard let ptr = withUnsafePointer(to: &cOptions, { cadaclysm_node_svg_text(handle, raw, $0) }) else {
            throw CadaclysmError(lastErrorOr("svg"))
        }
        return borrowed(ptr)
    }

    /// `svgText` written to `path` by the library itself.
    public func svg(_ path: String, options: SvgOptions = SvgOptions()) throws {
        let handle = try scene.liveOrThrow()
        var cOptions = try buildSvgOptions(options, defaultUp: scene.defaultUp)
        guard withUnsafePointer(to: &cOptions, { cadaclysm_node_svg(handle, raw, path, $0) }) else {
            throw CadaclysmError(lastErrorOr("could not write \(path)"))
        }
    }
}

// ---- svg ------------------------------------------------------------------------------------

/// Which axis is up -- `CadaclysmSvgOptions.up`. `nil` in `SvgOptions.up` keeps the scene's own
/// convention: `.y` for `.unity`/`.yUp`, `.z` otherwise -- and always `.z` for a solid, which
/// carries no convention of its own.
public enum Up: Sendable, Equatable {
    /// Y is up.
    case y
    /// Z is up.
    case z
}

/// One of the seven camera angles `SvgOptions.view` understands -- the same table
/// `cadaclysm_view.VIEWS` gives Python's `show()` and `svg()` both. Degrees (azimuth,
/// elevation): see `angles`.
public enum SvgView: Sendable {
    /// (-90, 0) -- looking from -Y.
    case front
    /// (90, 0) -- looking from +Y.
    case back
    /// (180, 0) -- looking from -X.
    case left
    /// (0, 0) -- looking from +X.
    case right
    /// (-90, 90) -- looking straight down.
    case top
    /// (-90, -90) -- looking straight up.
    case bottom
    /// (-50, 28) -- the viewer's own default angle.
    case iso

    /// This view's (azimuth, elevation) in degrees.
    public var angles: (Double, Double) {
        switch self {
        case .front: return (-90, 0)
        case .back: return (90, 0)
        case .left: return (180, 0)
        case .right: return (0, 0)
        case .top: return (-90, 90)
        case .bottom: return (-90, -90)
        case .iso: return (-50, 28)
        }
    }
}

/// `CadaclysmSvgOptions.background`'s "none" value -- `CADACLYSM_SVG_TRANSPARENT`, the same on
/// both headers. Shared with `Blacksmith`'s own packing.
public let svgTransparent: UInt32 = 0xFFFF_FFFF

private let svgEdgesFlag: UInt32 = 1
private let svgCurvesFlag: UInt32 = 2
private let svgIsocurvesFlag: UInt32 = 4
private let svgPolylinesFlag: UInt32 = 8
private let svgSilhouettesFlag: UInt32 = 16

/// A colour as the ABI's packed `0xRRGGBB`, from `"#rgb"`, `"#rrggbb"` or a CSS colour name --
/// for a host that wants the number itself (`SvgOptions.stroke`/`SvgOptions.background` take
/// the text directly). Read by the library's own parser, so every wrapper takes the same forms.
/// Takes no numeric triple of its own, so its refusal lists only the text forms.
public func packed(_ colour: String) throws -> UInt32 {
    var out = [Double](repeating: 0, count: 3)
    guard cadaclysm_parse_colour(colour, &out) else {
        throw CadaclysmError("colour: a colour is \"#rgb\", \"#rrggbb\" or a CSS colour name, not '\(colour)'")
    }
    return (UInt32((out[0] * 255).rounded()) << 16) | (UInt32((out[1] * 255).rounded()) << 8) | UInt32((out[2] * 255).rounded())
}

/// A colour `SvgOptions.stroke`/`SvgOptions.background` take: colour text -- `"#rgb"`,
/// `"#rrggbb"` or a CSS colour name, any case -- or a packed `0xRRGGBB`. A literal of either
/// kind is one already (`stroke: "navy"`, `background: 0x000080`); a value in a variable is
/// `SvgColour(text)` or `SvgColour(packed)`. Text is read when the drawing is made, by the
/// library whose drawing it is -- the reader's parser for a scene, the kernel's for a solid --
/// and text it refuses, or a number past `0xFFFFFF`, throws naming the field.
public struct SvgColour: Sendable, Equatable, ExpressibleByIntegerLiteral, ExpressibleByStringLiteral {
    /// The colour text given, or `nil` for a number.
    public let text: String?
    /// The packed number given; `0` for text.
    public let number: UInt32

    /// A packed `0xRRGGBB`.
    public init(_ packed: UInt32) { text = nil; number = packed }
    /// Colour text: `"#rgb"`, `"#rrggbb"` or a CSS colour name.
    public init(_ text: String) { self.text = text; number = 0 }
    public init(integerLiteral value: UInt32) { self.init(value) }
    public init(stringLiteral value: String) { self.init(value) }

    /// `0xRRGGBB`: a number range-checked, text through `parse` (`nil` where it refuses);
    /// `fail` builds the error naming `what`.
    package func packed(_ what: String, parse: (String) -> SIMD3<Double>?, fail: (String) -> Error) throws -> UInt32 {
        guard let text else {
            guard number <= 0xFF_FFFF else {
                throw fail("\(what): a packed colour is 0x000000..0xFFFFFF, not 0x\(String(number, radix: 16, uppercase: true))")
            }
            return number
        }
        guard let c = parse(text) else {
            throw fail("\(what): a colour is \"#rgb\", \"#rrggbb\", a CSS colour name or 0xRRGGBB, not '\(text)'")
        }
        return (UInt32((c.x * 255).rounded()) << 16) | (UInt32((c.y * 255).rounded()) << 8) | UInt32((c.z * 255).rounded())
    }
}

/// `colour` packed through the reader's own parser.
func readerPacked(_ colour: SvgColour, _ what: String) throws -> UInt32 {
    try colour.packed(what, parse: { text in
        var out = [Double](repeating: 0, count: 3)
        return cadaclysm_parse_colour(text, &out) ? SIMD3(out[0], out[1], out[2]) : nil
    }, fail: { CadaclysmError($0) })
}

/// How an SVG drawing is made -- the camera in the viewer's words, the page, the pen and which
/// line sets. Mirrors `CadaclysmSvgOptions`; `SvgOptions()` is the defaults
/// `cadaclysm_svg_options_init` fills. `view` supplies `azimuth`/`elevation` unless they are set
/// directly; `up` falls back to the scene's own convention (a solid falls back to `.z`,
/// carrying no convention of its own). Passed to `Scene.svgText`, `Scene.svg`, `Node.svgText`,
/// `Node.svg` and, over the kernel, `Blacksmith.Solid.svgText`/`Blacksmith.Solid.svg`. A
/// refused option (an out-of-range `fov`, say) throws a `CadaclysmError` worded by the library
/// itself.
public struct SvgOptions: Sendable {
    /// front back left right top bottom iso -- fills `azimuth`/`elevation` unless they are set
    /// directly. Default `.iso`.
    public var view: SvgView
    /// Degrees about the up axis from +X, overriding `view`'s: -90 looks from -Y, the front.
    /// `nil` keeps `view`'s own.
    public var azimuth: Double?
    /// Degrees above the horizon, overriding `view`'s. `nil` keeps `view`'s own.
    public var elevation: Double?
    /// `nil` keeps the scene's own convention -- `.y` for `.unity`/`.yUp`, `.z` otherwise (and
    /// always `.z` over the kernel, a solid carrying no convention of its own).
    public var up: Up?
    /// Vertical field of view in degrees; 0 (the default) is orthographic.
    public var fov: Double
    /// The page's viewBox width, page units; 0 is 1000.
    public var width: Double
    /// The page's viewBox height, page units; 0 is 1000.
    public var height: Double
    /// Fraction of the content's extent left each side. Default 0.05.
    public var margin: Double
    /// How far a written curve may stray, in page units. Default 0.1.
    public var tolerance: Double
    /// The pen colour: `"#rgb"`, `"#rrggbb"`, a CSS colour name or a packed `0xRRGGBB` (an
    /// `SvgColour`), e.g. `stroke: "navy"`. Default black.
    public var stroke: SvgColour
    /// The pen's width, page units. Default 1.
    public var strokeWidth: Double
    /// `"#rgb"`, `"#rrggbb"`, a CSS colour name or a packed `0xRRGGBB` (an `SvgColour`), e.g.
    /// `background: "navy"`, or `nil` (the default) for no `<rect>` behind the drawing -- the
    /// page left to whatever the viewer composites it onto.
    public var background: SvgColour?
    /// Each shape's feature edges -- the exact curves the flattened polylines are drawn from.
    /// Default `true`.
    public var edges: Bool
    /// Each shape's free curves -- the ones that are not the edge of any face (ignored over the
    /// kernel, a solid having none of its own). Default `false`.
    public var curves: Bool
    /// Each shape's isocurves -- the constant-parameter lines across a curved face (ignored
    /// over the kernel too). Default `false`.
    public var isocurves: Bool
    /// Write every line as straight segments within `tolerance`, instead of being fitted back
    /// to cubic Béziers. Default `false`.
    public var polylines: Bool
    /// Also draw where each body's surfaces turn away from the eye -- the outline a sphere has
    /// no edge for. One group per body, after that body's lines. Default `true`.
    ///
    /// On by default because a line set alone cannot draw every body: a sphere's and a torus's
    /// only curves are the seams where their one face meets itself, which are not edges of the
    /// body and are never drawn, so without it those two draw a blank page. A line set in its
    /// own right -- set it with `edges: false` for the outline alone, or clear it for the lines
    /// alone. Only naming nothing at all is refused.
    public var silhouettes: Bool

    /// The defaults `cadaclysm_svg_options_init` fills: the viewer's iso, orthographic, a
    /// 1000-square page, black edges one unit wide on nothing, and each body's outline beside
    /// them.
    public init(view: SvgView = .iso, azimuth: Double? = nil, elevation: Double? = nil, up: Up? = nil,
                fov: Double = 0, width: Double = 1000, height: Double = 1000, margin: Double = 0.05,
                tolerance: Double = 0.1, stroke: SvgColour = 0x00_0000, strokeWidth: Double = 1,
                background: SvgColour? = nil, edges: Bool = true, curves: Bool = false,
                isocurves: Bool = false, polylines: Bool = false, silhouettes: Bool = true) {
        self.view = view
        self.azimuth = azimuth
        self.elevation = elevation
        self.up = up
        self.fov = fov
        self.width = width
        self.height = height
        self.margin = margin
        self.tolerance = tolerance
        self.stroke = stroke
        self.strokeWidth = strokeWidth
        self.background = background
        self.edges = edges
        self.curves = curves
        self.isocurves = isocurves
        self.polylines = polylines
        self.silhouettes = silhouettes
    }
}

/// `options` packed into a `CadaclysmSvgOptions`: `view` fills `azimuth`/`elevation` unless
/// they are set directly, `up` falls back to `defaultUp`. `cadaclysm_svg_options_init` fills
/// the struct first -- `size` included -- so a field this wrapper never sets still carries the
/// library's own default rather than a zeroed struct's. Throws where `stroke` or `background`
/// is colour text the library refuses.
func buildSvgOptions(_ options: SvgOptions, defaultUp: Up) throws -> CadaclysmSvgOptions {
    let stroke = try readerPacked(options.stroke, "svg: stroke")
    let background = try options.background.map { try readerPacked($0, "svg: background") } ?? svgTransparent
    var raw = CadaclysmSvgOptions()
    cadaclysm_svg_options_init(&raw)
    let (baseAzimuth, baseElevation) = options.view.angles
    raw.up = (options.up ?? defaultUp) == .y ? 1 : 0
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
    raw.flags = (options.edges ? svgEdgesFlag : 0) | (options.curves ? svgCurvesFlag : 0)
        | (options.isocurves ? svgIsocurvesFlag : 0) | (options.polylines ? svgPolylinesFlag : 0)
        | (options.silhouettes ? svgSilhouettesFlag : 0)
    return raw
}

// ---- the scene ----------------------------------------------------------------------------------

/// An open document: what `open` and `openMemory` return. Close it when done, or let `deinit`.
///
/// Everything it hands back borrows from it: node handles, meshes, polylines, surfaces.
public final class Scene: NativeMemoryOwner, CustomStringConvertible {
    private var handle: OpaquePointer?
    /// The file it was read from, or the name given to `openMemory`.
    public let path: String
    /// The `.exp` actually used, or nil -- worth reporting when a directory was passed.
    public let schemaPath: String?
    /// The convention it was opened with, flags included. Nothing the library hands back says
    /// what space it is in, and every array out of this scene is in this one.
    public let convention: Convention

    init(handle: OpaquePointer, path: String, schemaPath: String?, convention: Convention) {
        self.handle = handle
        self.path = path
        self.schemaPath = schemaPath
        self.convention = convention
    }

    deinit { close() }

    /// The handle, trapping on a closed scene with the member that asked.
    func live(_ type: String = "Scene", _ member: String = #function) -> OpaquePointer {
        guard let handle = handle else { preconditionFailure("\(type).\(member): the scene is closed") }
        return handle
    }

    /// The handle, or the error a throwing member reports for a closed scene.
    func liveOrThrow() throws -> OpaquePointer {
        guard let handle = handle else { throw CadaclysmError("\(baseName(path)): the scene is closed") }
        return handle
    }

    /// "the scene is closed" once closed, else nil: what the views this scene lent check.
    public var nativeMemoryInvalidReason: String? { handle == nil ? "the scene is closed" : nil }

    /// Whether `close()` has run.
    public var closed: Bool { handle == nil }

    /// The `CadaclysmScene*`, for native libraries that take it (cadaclysm_render_add_scene).
    /// Borrowed: valid while this Scene is open; nil once closed.
    public var unsafeHandle: OpaquePointer? { handle }

    /// Give the document back. Idempotent. Every view still held traps when read afterwards.
    /// The items of this thread's CadaclysmView views that show it are removed first; while a
    /// view of another thread still shows it, it stays open (that view cannot be called from
    /// here) -- close it again once that thread has closed its view.
    public func close() {
        guard let handle = handle else { return }
        guard releaseShown(self) else { return }
        self.handle = nil
        cadaclysm_close(handle)
    }

    /// The version of the library that read it.
    public var version: String { Cadaclysm.version() }

    /// The schema the file named, or empty for a format that names none.
    public var schema: String { borrowed(cadaclysm_schema(live())) }

    /// The schema that actually read it: a release candidate reads under the finished schema of
    /// the same version where that is built in, an unknown one under the schema that defines
    /// its entity types.
    public var schemaRead: String { borrowed(cadaclysm_schema_read(live())) }

    /// Whether something other than the file's own schema read it -- `schema` and `schemaRead`
    /// differ, compared on the bare names (a formal identifier in braces is not a difference).
    public var substituted: Bool {
        let read = schemaRead
        if read.isEmpty { return false }
        func bare(_ entry: Substring) -> String {
            let head = entry.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false)[0]
            return head.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        }
        let target = bare(Substring(read))
        return !schema.split(separator: ",", omittingEmptySubsequences: false).contains { bare($0) == target }
    }

    /// What one length unit in the file is worth in metres; 1 where the file did not say.
    public var metresPerUnit: Double { cadaclysm_metres_per_unit(live()) }

    /// Everything the model covers, in world coordinates -- the one figure not in a node's own
    /// frame. This meshes the whole model; to frame a view quickly use the built nodes' bounds.
    public var bounds: Bounds { Bounds(cadaclysm_bounds(live())) }

    /// `bounds` in `double`: the same union box, unnarrowed. This meshes all of it, exactly
    /// as `bounds` does.
    public var bounds64: Bounds { Bounds(cadaclysm_bounds64(live())) }

    /// What the file held that the reader could not build, one line each.
    public var diagnostics: [String] {
        let handle = live()
        return (0..<cadaclysm_diagnostic_count(handle)).map { borrowed(cadaclysm_diagnostic(handle, $0)) }
    }

    /// What the reader built but the geometry stage could not finish -- a face that would
    /// not trim, a surface that would not mesh. `diagnostics` is what the file held that
    /// could not be read; this is what the geometry did.
    public var geometryDiagnostics: [String] {
        let handle = live()
        return (0..<cadaclysm_geometry_diagnostic_count(handle)).map { borrowed(cadaclysm_geometry_diagnostic(handle, $0)) }
    }

    /// Every rigid body of the file's mechanism. Empty for a file that records no mechanism.
    public var links: [Link] {
        (0..<Int(cadaclysm_link_count(live()))).map { Link(self, $0) }
    }

    /// Every connection between two links of the file's mechanism. Empty for a file that
    /// records no mechanism.
    public var joints: [Joint] {
        (0..<Int(cadaclysm_joint_count(live()))).map { Joint(self, $0) }
    }

    /// The file's named mechanism states, e.g. STEP's `MECHANISM_STATE_REPRESENTATION`. Empty
    /// for a file that records none.
    public var states: [State] {
        let handle = live()
        return (0..<cadaclysm_state_count(handle)).map { readState(self, $0) }
    }

    /// The file's motion sequences -- `INTERPOLATED_CONFIGURATION_SEQUENCE`, each a named walk
    /// through its states. Empty for a file that records none.
    public var sequences: [MotionSequence] {
        let handle = live()
        return (0..<cadaclysm_sequence_count(handle)).map { readSequence(self, $0) }
    }

    /// The file's work schedules -- `IfcWorkSchedule`, each a programme of tasks. Empty for a
    /// file that records none.
    public var schedules: [WorkSchedule] {
        let handle = live()
        return (0..<Int(cadaclysm_schedule_count(handle))).map { WorkSchedule(self, $0) }
    }

    /// The link the file declares as the mechanism's base, or nil when it declares none
    /// (the default ground is then the link on the most joints; see `pose`).
    public var base: Link? {
        let index = cadaclysm_kinematics_base(live())
        return index == noneIndex ? nil : Link(self, Int(index))
    }

    /// The mechanism posed by `values`: one `(joint, values)` row per joint to set --
    /// exactly `State.values`' row type, so `pose(state.values)` poses like
    /// `poseState(state)` -- with `ground` (a `Link`, or nil for the default ground) held
    /// fixed. Values outside a freedom's range are used as given and reported in the
    /// answer's `outOfRange`.
    ///
    /// Throws `CadaclysmError` on a bad row (a joint given twice, one with the wrong
    /// number of values, ...) or a file with no mechanism, carrying
    /// `cadaclysm_last_error`'s text unchanged.
    public func pose(_ values: [StateValue] = [], ground: Link? = nil) throws -> Pose {
        let handle = try liveOrThrow()
        var rows: [(UInt32, [Double])] = []
        rows.reserveCapacity(values.count)
        for row in values {
            guard let joint = row.joint else {
                throw CadaclysmError("pose: a row names no joint")
            }
            rows.append((UInt32(joint.index), row.values))
        }
        let joints = rows.map { $0.0 }
        let counts = rows.map { UInt32($0.1.count) }
        let flat = rows.flatMap { $0.1 }
        let groundIndex = ground.map { UInt32($0.index) } ?? noneIndex
        let ptr: OpaquePointer? = joints.withUnsafeBufferPointer { j in
            counts.withUnsafeBufferPointer { c in
                flat.withUnsafeBufferPointer { v in
                    cadaclysm_pose(handle, j.baseAddress, c.baseAddress, v.baseAddress, UInt32(rows.count), groundIndex)
                }
            }
        }
        guard let ptr = ptr else { throw CadaclysmError(lastErrorOr("pose")) }
        return copyPose(self, ptr)
    }

    /// The mechanism posed by `state`'s values, with `ground` held fixed as `pose` does.
    /// Throws `CadaclysmError` as `pose` does.
    public func poseState(_ state: State, ground: Link? = nil) throws -> Pose {
        let handle = try liveOrThrow()
        let groundIndex = ground.map { UInt32($0.index) } ?? noneIndex
        guard let ptr = cadaclysm_pose_state(handle, UInt32(state.index), groundIndex) else {
            throw CadaclysmError(lastErrorOr("pose"))
        }
        return copyPose(self, ptr)
    }

    /// The archive member this was read from, or nil for a plain file.
    public var sourceName: String? {
        guard let raw = cadaclysm_source_name(live()) else { return nil }
        return String(cString: raw)
    }

    /// Every node, in index order -- structure as well as geometry. To draw, iterate
    /// `placements` instead.
    public var nodes: [Node] {
        (0..<Int(cadaclysm_node_count(live()))).map { Node(self, $0) }
    }

    /// The nodes nothing else contains: where a tree view starts.
    public var roots: [Node] {
        let handle = live()
        return (0..<cadaclysm_root_count(handle)).compactMap {
            let index = cadaclysm_root(handle, $0)
            return index == noneIndex ? nil : Node(self, Int(index))
        }
    }

    /// Every node reachable from the roots, parents before children.
    public func walk() -> [Node] { roots.flatMap { $0.walk() } }

    /// The indices of the nodes a filter matches, in document order -- `Node(scene, i)` makes
    /// one a node. The filter is one boolean expression,
    /// `class == ON_Brep and within(name == Walls)`. A filter that does not parse throws with
    /// the parser's message and position; one that matches nothing is an empty result.
    public func query(_ filter: String) throws -> [Int] {
        let handle = try liveOrThrow()
        let total = cadaclysm_query(handle, filter, nil, 0)
        if total == 0 {
            let reason = lastError()
            if !reason.isEmpty { throw CadaclysmError("\(baseName(path)): \(reason)") }
            return []
        }
        var out = [UInt32](repeating: 0, count: Int(total))
        let written = cadaclysm_query(handle, filter, &out, total)
        return out.prefix(Int(Swift.min(written, total))).map { Int($0) }
    }

    /// What the document draws, and where: iterate this to draw, and the nodes to build a tree.
    public var placements: [Placement] {
        (0..<Int(cadaclysm_placement_count(live()))).map { Placement(self, $0) }
    }

    /// Build every mesh now, across all cores, and return how many were built. Watch it from
    /// another thread with `realized` and `realizeTotal`; stop it with `cancel()`.
    public func realizeAll() -> Int { Int(cadaclysm_realize_all(live())) }

    /// `realizeAll()`, leaving alone every node that carries surfaces when `skipSurfaced` is
    /// true: a renderer drawing those from their surfaces never pays for their triangles.
    /// Returns how many were built.
    public func realizeMeshes(skipSurfaced: Bool = true) -> Int { Int(cadaclysm_realize_meshes(live(), skipSurfaced ? 1 : 0)) }

    /// How many nodes `realizeAll()` has finished. Safe to read from another thread.
    public var realized: Int { Int(cadaclysm_realized(live())) }

    /// How many it will build in all; zero until it starts.
    public var realizeTotal: Int { Int(cadaclysm_realize_total(live())) }

    /// Ask a running `realizeAll()` to stop. One-way for the life of the scene: later calls
    /// return at once, and meshes are still built one node at a time on request.
    public func cancel() { cadaclysm_cancel(live()) }

    /// Drop every mesh the scene has built; the next ask rebuilds. What it frees is the
    /// document's own mesh: the `Mesh64`s handed out before it view that, so this counts the
    /// forget and their arrays trap afterwards rather than read freed memory. `Mesh`,
    /// `Polylines` and the Béziers are the library's own caches, which a forget does not touch
    /// and which stay good until the scene closes.
    public func forgetMeshes() {
        cadaclysm_forget_meshes(live())
        forgets += 1
    }

    /// How many times `forgetMeshes()` has run. Only `Mesh64` stamps itself with this (through
    /// `LentMesh`): it lends the document's own mesh, which a forget frees, where the float mesh
    /// and the line views are the library's own caches and outlive one.
    private(set) var forgets = 0

    /// Write the whole scene: `glb` (binary glTF), `gltf` (text glTF, one file) or `obj` (every
    /// placement baked to its own named object, a `.mtl` beside it when anything has a colour).
    /// In the scene's convention (`.yUp` for the space glTF specifies). Throws on any other
    /// format or a failed write.
    public func save(_ path: String, format: String = "glb") throws {
        let handle = try liveOrThrow()
        if !cadaclysm_scene_save(handle, path, format) {
            throw CadaclysmError(lastErrorOr("could not write \(path)"))
        }
    }

    /// `Up.y` or `Up.z`: which axis is up by default, from `convention` -- `.unity` and `.yUp`
    /// give `.y`, every other convention `.z`. What `SvgOptions.up` falls back to when left
    /// `nil`. `.fileUnits` and `.uvWorld` are masked out first, since they OR into the packed
    /// convention this scene carries.
    var defaultUp: Up {
        let base = Convention(rawValue: convention.rawValue & ~(Convention.fileUnits.rawValue | Convention.uvWorld.rawValue))
        return base == .unity || base == .yUp ? .y : .z
    }

    /// Draw every visible placement with the view library in use (`ViewLibrary.useWgpu()` /
    /// `useTerminal()`, else CADACLYSM_VIEW, else the terminal): the wgpu library's window
    /// blocks until it is closed; any other library prints a still. Up defaults from the
    /// convention; the title is the file's name.
    public func show(_ options: ShowOptions = ShowOptions()) throws { _ = try draw(options, interactive: false) }

    /// Orbit the scene until its window is closed: where the camera was left, the last pick.
    @discardableResult
    public func view(_ options: ShowOptions = ShowOptions()) throws -> Camera { try draw(options, interactive: true) }

    /// Scene, Node and Pose show()/view(): this scene by handle, posed by `transforms` or
    /// narrowed to `focus`. A document is drawn at the tolerance it was read with.
    func draw(_ options: ShowOptions, interactive: Bool, focus: (node: UInt32, hide: [UInt32])? = nil,
              transforms: [Double]? = nil, kind: String = "Scene") throws -> Camera {
        let handle = try liveOrThrow()
        try refuseTolerance(kind, options, interactive: interactive)
        defer { withExtendedLifetime(self) {} }
        return try drawObject(solid: nil, scene: handle, tolerance: 0, label: baseName(path),
                              defaultUp: defaultUp == .y ? .y : .z, focus: focus, options: options,
                              interactive: interactive, transforms: transforms)
    }

    /// Every visible placement's wireframe as SVG text, from the camera `options` describes --
    /// the library's own camera, not a viewer. See `SvgOptions`. Borrowed by the library:
    /// copied out before this returns, and replaced by this scene's next `svgText` or `svg`
    /// call.
    public func svgText(_ options: SvgOptions = SvgOptions()) throws -> String {
        let handle = try liveOrThrow()
        var cOptions = try buildSvgOptions(options, defaultUp: defaultUp)
        guard let ptr = withUnsafePointer(to: &cOptions, { cadaclysm_scene_svg_text(handle, $0) }) else {
            throw CadaclysmError(lastErrorOr("svg"))
        }
        return borrowed(ptr)
    }

    /// `svgText` written to `path` by the library itself.
    public func svg(_ path: String, options: SvgOptions = SvgOptions()) throws {
        let handle = try liveOrThrow()
        var cOptions = try buildSvgOptions(options, defaultUp: defaultUp)
        guard withUnsafePointer(to: &cOptions, { cadaclysm_scene_svg(handle, path, $0) }) else {
            throw CadaclysmError(lastErrorOr("could not write \(path)"))
        }
    }

    /// The 4x4 that puts `Node.surfaces` in the space everything else is already in, as four
    /// rows of four (`[row][column]`). Identity for a document opened native at its own units.
    public var surfaceMatrix: [[Double]] {
        var out = [Float](repeating: 0, count: 16)
        cadaclysm_surface_matrix(live(), &out)
        return rowMajor(out.map { Double($0) })
    }

    /// `<Scene name (n nodes)>`.
    public var description: String {
        let state = closed ? "closed" : "\(cadaclysm_node_count(live())) nodes"
        return "<Scene \(baseName(path)) (\(state))>"
    }
}
