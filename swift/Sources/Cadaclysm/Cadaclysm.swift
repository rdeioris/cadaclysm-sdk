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

/// One format `Node.saveMesh` writes: its name and the extension it writes, which are not
/// always the same word (`stl-ascii` writes a `.stl`).
public struct MeshFormat: Hashable, Sendable {
    /// The name `Node.saveMesh` takes.
    public let name: String
    /// The file extension it writes, without the dot.
    public let `extension`: String

    /// A format from its name and extension.
    public init(name: String, extension: String) {
        self.name = name
        self.extension = `extension`
    }
}

/// Every format `Node.saveMesh` writes. Build a menu from this rather than hard-coding it, and
/// a format added to the library turns up without a code change.
public func meshFormats() -> [MeshFormat] {
    (0..<cadaclysm_mesh_format_count()).map {
        MeshFormat(name: borrowed(cadaclysm_mesh_format($0)), extension: borrowed(cadaclysm_mesh_format_extension($0)))
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

    /// Give the reference back now. Idempotent; `deinit` does it otherwise.
    public func release() {
        guard let handle = handle else { return }
        self.handle = nil
        cadaclysm_brep_release(handle)
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

    /// Its triangles in their own frame, built now if they have not been. A node that
    /// instances another hands back the instanced node's arrays -- the same memory for every
    /// placement. Views into the scene.
    public var mesh: Mesh {
        let got = cadaclysm_node_mesh(live(), raw)
        let n = Int(got.vertex_count)
        return Mesh(positions: NativeArray(owner: scene, base: got.positions, count: n * 3),
                    normals: got.normals.map { NativeArray(owner: scene, base: $0, count: n * 3) },
                    uvs: got.uvs.map { NativeArray(owner: scene, base: $0, count: n * 2) },
                    colors: got.colors.map { NativeArray(owner: scene, base: $0, count: n * 4) },
                    indices: NativeArray(owner: scene, base: got.indices, count: Int(got.index_count)),
                    vertexCount: n, indexCount: Int(got.index_count))
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

    /// Its free curves as polylines; a 2D drawing is all of these.
    public var curves: Polylines { polylines(cadaclysm_node_curves(live(), raw)) }

    /// Lines ruled across its surfaces, so a curved face reads as curved in a wireframe. A flat
    /// face yields its outline, so these can overlap `edges`.
    public var isocurves: Polylines { polylines(cadaclysm_node_isocurves(live(), raw)) }

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

    /// Give the document back. Idempotent. Every view still held traps when read afterwards.
    public func close() {
        guard let handle = handle else { return }
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

    /// What the file held that the reader could not build, one line each.
    public var diagnostics: [String] {
        let handle = live()
        return (0..<cadaclysm_diagnostic_count(handle)).map { borrowed(cadaclysm_diagnostic(handle, $0)) }
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

    /// How many nodes `realizeAll()` has finished. Safe to read from another thread.
    public var realized: Int { Int(cadaclysm_realized(live())) }

    /// How many it will build in all; zero until it starts.
    public var realizeTotal: Int { Int(cadaclysm_realize_total(live())) }

    /// Ask a running `realizeAll()` to stop. One-way for the life of the scene: later calls
    /// return at once, and meshes are still built one node at a time on request.
    public func cancel() { cadaclysm_cancel(live()) }

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
