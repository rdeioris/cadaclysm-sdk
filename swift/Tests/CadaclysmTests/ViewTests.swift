// The view through CadaclysmView: a missing library refused with the contract's message,
// the terminal's stills and refusals, and an offscreen view -- a solid by handle (kept alive
// by its item), image() inside its silhouette, pick, save, a real pose and the rest pose, a
// nested node and a root drawing less than their scene, Scene.close() releasing its items,
// another thread's calls refused, colour text drawing its numbers' pixels and refused text
// refused in the library's words, the loader's ABI 1.11, text (labels shown, changed, picked
// by line, coloured on their box; fonts loaded; refusals) -- and the wgpu library's table
// rigged: show()/view()'s title and up axis, run()'s camera, pump's waits and count, input,
// void-call refusals; ABI 1.8's pick (clicks, point), set_double_click_frames, focus and
// navigation, rigged and on the GPU (a double click through input). The
// GPU half skips without cadaclysm_view or an adapter unless CADACLYSM_REQUIRE_WGPU is set.
@testable import CadaclysmView
@testable import Blacksmith
import CCadaclysmView
@testable import Cadaclysm
import Foundation
import XCTest

// ---- the wgpu library's table, rigged (C function pointers capture nothing: globals) ---------
// (Swift 6 language mode will want these globals marked nonisolated(unsafe).)

private func cstr(_ s: String) -> UnsafePointer<CChar> { UnsafePointer(strdup(s)!) }

private var spyRealCreate = CvlTable().create
private var spyTitle = ""
private var spyYUp: UInt32 = 9
private var spyRuns = 0
private var spyEye: (Float, Float, Float) = (10, 0, 0)
private var spyUp: (Float, Float, Float) = (0, 0, 1)
private var spySaid: UnsafePointer<CChar>? = nil
private var spyPumpMs: [UInt32] = []
private var spyPumpAnswers: [UInt32] = []
private var spyInputAnswer: UInt32 = 0
private var spyCreateFails = false
private var spyRealNodeVisible = CvlTable().set_node_visible
private var spyHidden: [UInt32] = []
private var spyRealFrameNode = CvlTable().frame_node
private var spyFramed: [UInt32] = []
private var spyRealNodeTransforms = CvlTable().set_node_transforms
private var spyPosed: [UInt32] = []
private let pumpBroke = cstr("pump broke")
private var spyRealDestroy = CvlTable().destroy
private weak var spyWatched: AnyObject?
private var spyAliveAtDestroy: [Bool] = []

private func rig(_ t: UnsafeMutablePointer<CvlTable>) {
    spyRealCreate = t.pointee.create
    // A window of its own made offscreen (no window opens in a test), its title and up kept.
    t.pointee.create = { window, o in
        if spyCreateFails { return nil }
        spyTitle = o!.pointee.title.map { String(cString: $0) } ?? ""
        spyYUp = o!.pointee.y_up
        var copy = o!.pointee
        copy.offscreen = 1
        if copy.width == 0 || copy.height == 0 { copy.width = 64; copy.height = 48 }
        return spyRealCreate!(window, &copy)
    }
    // The window "closed" at once: the camera on spyEye, looking at the origin.
    t.pointee.run = { _, camera, pick in
        spyRuns += 1
        camera!.pointee.eye = spyEye
        camera!.pointee.target = (0, 0, 0)
        camera!.pointee.up = spyUp
        camera!.pointee.orthographic = 0
        pick!.pointee.item = 0
        return true
    }
    t.pointee.last_error = { spySaid }
    // pump: each call's wait, the answers in call order (0: a failure saying "pump broke";
    // past the list: open).
    t.pointee.pump = { _, ms in
        let call = spyPumpMs.count
        spyPumpMs.append(ms)
        let answer = call < spyPumpAnswers.count ? spyPumpAnswers[call] : UInt32(CADACLYSM_VIEW_OPEN)
        spySaid = answer == 0 ? pumpBroke : nil
        return answer
    }
    t.pointee.input = { _, _ in spyInputAnswer }
    spyRealNodeVisible = t.pointee.set_node_visible
    t.pointee.set_node_visible = { v, item, node, on in
        if !on { spyHidden.append(node) }
        return spyRealNodeVisible!(v, item, node, on)
    }
    spyRealFrameNode = t.pointee.frame_node
    t.pointee.frame_node = { v, item, node in
        spyFramed.append(node)
        return spyRealFrameNode!(v, item, node)
    }
    spyRealNodeTransforms = t.pointee.set_node_transforms
    t.pointee.set_node_transforms = { v, item, m, n in
        spyPosed.append(m == nil ? UInt32.max : n)
        return spyRealNodeTransforms!(v, item, m, n)
    }
}

// ---- view ABI 1.11, rigged: what show_points hands the library -------------------------------

private var spyPoints: [Float] = []
private var spyPointsRgb: [Float]? = nil
private var spyPointsSize: Float = 0
private var spyPointsCalls = 0

private func rigPoints(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.show_points = { _, p, n, rgb, size in
        spyPointsCalls += 1
        spyPoints = (0..<Int(n) * 3).map { p![$0] }
        spyPointsRgb = rgb.map { [$0[0], $0[1], $0[2]] }
        spyPointsSize = size
        return 17
    }
}

// ---- view ABI 1.8, rigged: the pick's clicks and point, set_double_click_frames, focus, navigation

private var spyPicked = CadaclysmViewPick()
// pick_result answers spyPicked while spyLanded, else false (spySaid says why).
private var spyLanded = true
private var spyCalls: [String] = []
private var spyNavigation: UInt32 = 0
private let focusNotFinite = cstr("cadaclysm_view_focus: the point is not finite")

private func rig17(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.last_error = { spySaid }
    t.pointee.request_pick_in = { _, _, _, _ in }
    // spyPicked, up to the caller's size as the library writes it.
    t.pointee.pick_result = { _, out in
        if !spyLanded { return false }
        var answer = spyPicked
        answer.size = out!.pointee.size
        out!.pointee = answer
        return true
    }
    // The window "closed" at once, spyPicked picked.
    t.pointee.run = { _, camera, pick in
        camera!.pointee.eye = (10, 0, 0)
        camera!.pointee.target = (0, 0, 0)
        camera!.pointee.up = (0, 0, 1)
        camera!.pointee.orthographic = 0
        pick!.pointee = spyPicked
        return true
    }
    t.pointee.set_double_click_frames = { _, on in spyCalls.append(on ? "frames on" : "frames off") }
    // A point that is not finite is refused, as the library does.
    t.pointee.focus = { _, p in
        let x = p![0], y = p![1], z = p![2]
        spyCalls.append("focus \(x) \(y) \(z)")
        if !(x.isFinite && y.isFinite && z.isFinite) {
            spySaid = focusNotFinite
            return false
        }
        spySaid = nil
        return true
    }
    t.pointee.navigation = { _ in
        spyCalls.append("navigation")
        return spyNavigation
    }
}

// ---- helpers ---------------------------------------------------------------------------------

/// The first samples/ directory above this file holding mechanism-solid.stp (the repository's
/// or the SDK's), or the repository's place for it when none does.
private let samples: URL = {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        let candidate = dir.appendingPathComponent("samples")
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("mechanism-solid.stp").path) {
            return candidate
        }
        dir = dir.deletingLastPathComponent()
    }
    return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../../samples").standardized
}()

private func message(_ body: () throws -> Void) -> String {
    do { try body() } catch { return "\(error)" }
    return "<accepted>"
}

private func pixel(_ i: ViewImage, _ x: Int, _ y: Int) -> [UInt8] {
    let at = (y * Int(i.width) + x) * 4
    return Array(i.rgba[at..<at + 4])
}

/// How many pixels differ between two frames of the same size.
private func changed(_ a: ViewImage, _ b: ViewImage) -> Int {
    guard a.rgba.count == b.rgba.count else { return Int.max }
    var n = 0
    for i in stride(from: 0, to: a.rgba.count, by: 4) where a.rgba[i..<i + 4] != b.rgba[i..<i + 4] { n += 1 }
    return n
}

/// A leaf below a root, with geometry: the node every node test draws.
private func nestedLeaf(_ scene: Scene) -> Node? {
    scene.nodes.first { $0.parent != nil && $0.children.isEmpty && $0.canMesh }
}

/// Runs `body` on a thread of its own and waits for it.
private func onAnotherThread(_ body: @escaping () -> Void) {
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        body()
        done.signal()
    }
    thread.start()
    done.wait()
}

final class ViewTests: XCTestCase {
    private var required: Bool { !(ProcessInfo.processInfo.environment["CADACLYSM_REQUIRE_WGPU"] ?? "").isEmpty }

    private func skipOrFail(_ error: Error) throws -> Never {
        if required { XCTFail("CADACLYSM_REQUIRE_WGPU is set, but: \(error)") }
        throw XCTSkip("no GPU view here: \(error)")
    }

    /// The wgpu library chosen and an offscreen view of it, or a skip (a failure when required).
    private func offscreen(_ width: UInt32 = 320, _ height: UInt32 = 240) throws -> View {
        do { try ViewLibrary.useWgpu() } catch { try skipOrFail(error) }
        do { return try View.offscreen(width: width, height: height) } catch { try skipOrFail(error) }
    }

    private func sample(_ name: String) throws -> String {
        let path = samples.appendingPathComponent(name).path
        if !FileManager.default.fileExists(atPath: path) {
            if !(ProcessInfo.processInfo.environment["CADACLYSM_SAMPLES_OPTIONAL"] ?? "").isEmpty {
                throw XCTSkip("\(path) is missing")
            }
            XCTFail("\(path) is missing (scripts/link-samples.py in a worktree)")
            throw XCTSkip("no sample")
        }
        return path
    }

    func testTheLodStructIsTwelveBytes() {
        XCTAssertEqual(MemoryLayout<CadaclysmViewLod>.size, 12)
        XCTAssertEqual(MemoryLayout<CadaclysmViewLod>.offset(of: \CadaclysmViewLod.min_triangles), 4)
        XCTAssertEqual(MemoryLayout<CadaclysmViewLod>.offset(of: \CadaclysmViewLod.motion), 8)
        XCTAssertEqual(CADACLYSM_VIEW_LOD_DETAILED, 0)
        XCTAssertEqual(CADACLYSM_VIEW_LOD_SMOOTH, 1)
    }

    func testTheTerminalLoadsAndRefusesAnOffscreenView() throws {
        let terminal: ViewLibrary
        do { terminal = try ViewLibrary.useTerminal() } catch {
            if ProcessInfo.processInfo.environment["CADACLYSM_REQUIRE_TERMINAL"] == "1" {
                XCTFail("CADACLYSM_REQUIRE_TERMINAL=1, but: \(error)")
            }
            throw XCTSkip("no terminal library here: \(error)")
        }
        XCTAssertTrue(terminal.isTerminal, terminal.name)
        XCTAssertFalse(terminal.isWgpu, terminal.name)
        XCTAssertThrowsError(try View.offscreen(width: 64, height: 64))
        XCTAssertEqual(message { try ViewLibrary.use("") }, "use: \"terminal\", \"wgpu\" or a path")
    }

    func testAMissingLibraryIsRefusedWithTheContractsMessage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try findForTest(stem: "cadaclysm_view_absent", variable: "CADACLYSM_VIEW_ABSENT_LIBRARY",
                                             what: "terminal", dirs: [dir.path])) { error in
            let m = "\(error)"
            XCTAssertTrue(m.hasPrefix("no view library: the terminal library was not found (searched: "), m)
            XCTAssertTrue(m.hasSuffix("-- reinstall cadaclysm, set CADACLYSM_VIEW_ABSENT_LIBRARY to the library, or set CADACLYSM_VIEW"), m)
        }
        // The library directory Package.swift compiled in is a directory (a path with
        // backslashes, made into C escapes, would not be).
        for compiled in ViewLibrary.searchDirs {
            XCTAssertEqual(cvl_kind(compiled), 2, "CVL_SWIFT_LIBRARY_DIR names no directory: \(compiled)")
        }
    }

    func testTheTerminalDrawsStills() throws {
        do { try ViewLibrary.useTerminal() } catch {
            if ProcessInfo.processInfo.environment["CADACLYSM_REQUIRE_TERMINAL"] == "1" {
                XCTFail("CADACLYSM_REQUIRE_TERMINAL=1, but: \(error)")
            }
            throw XCTSkip("no terminal library here: \(error)")
        }
        let small = ShowOptions(width: 16, height: 8)
        var tolerant = small
        tolerant.tolerance = 0.1
        let cube = try Solid.cuboid(5, 5, 5)
        try cube.show(small)
        try cube.show(tolerant)  // a solid takes a tolerance
        var sideways = small
        sideways.view = "sideways"
        XCTAssertTrue(message { try cube.show(sideways) }.hasPrefix("view 'sideways': one of front"))
        let gone = try Solid.cuboid(1, 1, 1)
        gone.close()
        XCTAssertEqual(message { try gone.show(small) }, "solid: closed")

        let scene = try Cadaclysm.open(try sample("mechanism-solid.stp"))
        defer { scene.close() }
        try scene.show(small)
        XCTAssertEqual(message { try scene.show(tolerant) },
                       "Scene.show takes no tolerance: a document is drawn at the tolerance it was read with")
        XCTAssertTrue(message { _ = try scene.view(tolerant) }.hasPrefix("Scene.view takes no tolerance"))
        let leaf = try XCTUnwrap(nestedLeaf(scene), "mechanism-solid.stp has no leaf below a root with geometry")
        try leaf.show(small)
        XCTAssertTrue(message { _ = try leaf.view(tolerant) }.hasPrefix("Node.view takes no tolerance"))
        let state = try XCTUnwrap(scene.states.first, "mechanism-solid.stp records no state")
        let pose = try scene.poseState(state)
        try pose.show(small)
        XCTAssertTrue(message { try pose.show(tolerant) }.hasPrefix("Pose.show takes no tolerance"))

        let closed = try Cadaclysm.open(try sample("mechanism-solid.stp"))
        let leafOfClosed = try XCTUnwrap(nestedLeaf(closed))
        closed.close()
        XCTAssertEqual(message { try closed.show(small) }, "mechanism-solid.stp: the scene is closed")
        XCTAssertEqual(message { try leafOfClosed.show(small) }, "mechanism-solid.stp: the scene is closed")
    }

    func testPumpWithNoWindowWaits() throws {
        let start = Date()
        XCTAssertEqual(try View.pump(timeout: -1), 0)
        XCTAssertEqual(try View.pump(timeout: .nan), 0)
        XCTAssertEqual(try View.pump(timeout: 0.05), 0)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.04, "pump with no window did not wait")
    }

    func testOffscreenSolidByHandle() throws {
        let view = try offscreen()
        try view.standard("front")
        XCTAssertEqual(message { try view.standard("sideways") }, "standard view 'sideways': one of top, front, right, iso")
        let empty = try view.image()
        XCTAssertEqual(empty.width, 320)
        XCTAssertEqual(empty.height, 240)
        _ = try view.needsDraw()
        // The solid's last reference is the item's: it lives on while shown.
        weak var kept: Solid?
        var item: Item?
        do {
            let sphere = try Solid.sphere(10)
            kept = sphere
            item = try view.showSolid(sphere, rgb: SIMD3<Float>(0.9, 0.2, 0.1))
        }
        XCTAssertNotNil(kept, "the item let go of the solid it shows")
        let gone = try Solid.cuboid(1, 1, 1)
        gone.close()
        XCTAssertEqual(message { try view.showSolid(gone) }, "solid: closed")
        try view.frame()
        let drawn = try view.image()
        XCTAssertNotEqual(pixel(drawn, 160, 120), pixel(empty, 160, 120), "nothing drawn at the centre")
        XCTAssertEqual(pixel(drawn, 1, 1), pixel(empty, 1, 1), "a corner outside the sphere changed")
        let pick = try view.pick(x: 160, y: 120)
        XCTAssertEqual(pick?.item, item?.id)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try view.save(png.path)
        let bytes = try Data(contentsOf: png)
        try? FileManager.default.removeItem(at: png)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        // Master's three: levels on and off, the wake answer; node transforms refused on a solid.
        try view.lod("smooth")
        _ = try view.wakeMs()
        try view.lod(nil)
        XCTAssertTrue(message { try view.lod("sharp") }.contains("one of detailed, smooth"))
        XCTAssertFalse(message { try item?.nodeTransforms([]) } == "<accepted>", "node transforms on a solid were accepted")
        // 1.9's lighting: the headlight by default, studio set and read back, another name
        // refused before C (the lighting unchanged), and the headlight again.
        XCTAssertEqual(try view.lighting, "headlight")
        try view.setLighting("studio")
        XCTAssertEqual(try view.lighting, "studio")
        XCTAssertEqual(message { try view.setLighting("noon") }, "lighting 'noon': 'headlight' or 'studio'")
        XCTAssertEqual(try view.lighting, "studio")
        try view.setLighting("headlight")
        XCTAssertEqual(try view.lighting, "headlight")

        // Every buffer is length-checked before C, in Python's words.
        XCTAssertEqual(message { _ = try view.showLines([Float](repeating: 0, count: 7)) },
                       "segments is two points a segment (6 numbers), not 7")
        XCTAssertEqual(message { _ = try view.showMesh(positions: [0, 0, 0], indices: [0, 0, 0], normals: [Float](repeating: 0, count: 6)) },
                       "a mesh has 1 positions but 2 normals")
        XCTAssertEqual(message { _ = try view.showMesh(positions: [Float](repeating: 0, count: 9), indices: [0, 1, 2], edges: [0, 0, 0, 0, 0]) },
                       "edges is two points a segment (6 numbers), not 5")
        XCTAssertEqual(message { _ = try view.showMesh(positions: [0, 0, 0, 0], indices: [0]) }, "positions is three numbers a point, not 4")
        XCTAssertTrue(message { _ = try view.showCurves([Float](repeating: 0, count: 15)) }.hasPrefix("show_curves takes"))
        let corners = [Float](repeating: 0, count: 12)
        XCTAssertEqual(message { _ = try view.showImage(corners: corners, rgba: [UInt8](repeating: 0, count: 15), width: 2, height: 2) },
                       "show_image: 2 x 2 pixels need 16 bytes (rgba), not 15")
        XCTAssertTrue(message { _ = try view.showImage(corners: corners, rgba: [0, 0, 0, 0], width: .max, height: .max) }.contains("too large"))
        XCTAssertEqual(message { _ = try view.showImage(corners: [0], rgba: [0, 0, 0, 0], width: 1, height: 1) }, "12 numbers, not 1")
        XCTAssertEqual(message { try item?.placement([1, 0]) }, "16 numbers, not 2")
        XCTAssertEqual(message { try item?.nodeTransforms([[1]]) }, "transform 0: 16 numbers, not 1")
        XCTAssertEqual(message { try item?.faceColours([1, 2], [SIMD4<Float>(1, 0, 0, 1)]) }, "8 numbers (rgba, 4 a face), not 4")
        // An empty list clears: it reaches the library as an empty array, not "none".
        try item?.faceColours([], [])
        // Empty lines and curves are accepted (a non-NULL empty array); a mesh and an image draw.
        try view.showLines([]).remove()
        try view.showCurves([]).remove()
        try view.showMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1, 2], rgb: SIMD3<Float>(0, 1, 0)).remove()
        try view.showImage(corners: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0], rgba: [255, 0, 0, 255], width: 1, height: 1).remove()
        // Two points on the real library: an item.
        let twoPoints = try view.showPoints([0, 0, 0, 1, 1, 1], rgb: "red")
        XCTAssertNotEqual(twoPoints.id, 0, "two points: no item")
        try twoPoints.remove()
        try item?.placement([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        try item?.placement(nil)
        // A host's event on a view that is not a window of its own leaves it open.
        _ = try view.input(kind: UInt32(CADACLYSM_VIEW_EVENT_KEY), key: "Escape")
        XCTAssertFalse(view.isClosed, "Escape closed an offscreen view")

        try item?.remove()
        XCTAssertNil(kept, "a removed item still holds its solid")
        XCTAssertEqual(pixel(try view.image(), 160, 120), pixel(empty, 160, 120), "a removed item is still drawn")
        let solid = try Solid.cuboid(1, 1, 1)
        let late = try view.showSolid(solid)
        try view.close()
        try view.close()  // idempotent
        XCTAssertTrue(view.isClosed)
        XCTAssertEqual(message { _ = try view.showLines([0, 0, 0, 1, 1, 1]) }, "cadaclysm_view_show_lines: the view is closed")
        XCTAssertEqual(message { try late.colour(SIMD3<Float>(1, 0, 0)) }, "cadaclysm_view_set_colour: the view is closed")
        XCTAssertEqual(message { _ = try view.needsDraw() }, "cadaclysm_view_needs_draw: the view is closed")
        XCTAssertEqual(message { _ = try view.input(kind: 1) }, "cadaclysm_view_input: the view is closed")
    }

    func testAPoseDrawsAndTheRestPoseReturns() throws {
        let mechanism = try sample("mechanism-solid.stp")
        let view = try offscreen()
        defer { try? view.close() }
        let blank = try view.image()
        let scene = try Cadaclysm.open(mechanism)
        defer { scene.close() }
        let shown = try view.showScene(scene)
        try view.standard("iso")
        try view.frame()
        let rest = try view.image()
        XCTAssertGreaterThan(changed(rest, blank), 0, "the scene drew nothing")
        let state = try XCTUnwrap(scene.states.first, "mechanism-solid.stp records no state")
        let pose = try scene.poseState(state)
        try shown.nodeTransforms(scene.nodes.map { pose.rawTransform($0) })
        XCTAssertGreaterThan(changed(rest, try view.image()), 0, "the pose moved nothing on screen")
        try shown.nodeTransforms(nil)
        let back = changed(rest, try view.image())
        XCTAssertLessThan(back, 320 * 240 / 1000, "nil did not put the rest pose back: \(back) pixels")
        let none = message { try shown.nodeTransforms([]) }
        XCTAssertTrue(none.contains("0 transforms were given"), "an empty transform list: \(none)")
        try shown.remove()
    }

    func testANodeAndARootDrawLessThanTheirScene() throws {
        let mechanism = try sample("mechanism-solid.stp")
        let view = try offscreen()
        defer { try? view.close() }
        let blank = try view.image()
        let scene = try Cadaclysm.open(mechanism)
        defer { scene.close() }
        let whole = try view.showScene(scene)
        try view.standard("iso")
        try view.frame()
        let wholeImage = try view.image()
        try whole.remove()

        // A nested node: its scene with the siblings along its path hidden.
        let leaf = try XCTUnwrap(nestedLeaf(scene), "mechanism-solid.stp has no leaf below a root with geometry")
        var chain: [Node] = []
        var at: Node? = leaf
        while let n = at { chain.insert(n, at: 0); at = n.parent }
        var expected = Set<UInt32>()
        var level = scene.roots
        for on in chain {
            for other in level where other.index != on.index { expected.insert(UInt32(other.index)) }
            level = on.children
        }
        XCTAssertFalse(expected.isEmpty, "the leaf has no sibling anywhere on its path: the hiding would prove nothing")
        let hidden = leaf.siblingsAlongPath
        XCTAssertEqual(Set(hidden), expected)
        XCTAssertEqual(hidden.count, expected.count)
        let one = try view.showNode(leaf)
        try view.standard("iso")
        try view.frame()
        let alone = try view.image()
        XCTAssertGreaterThan(changed(alone, blank), 0, "the node drew nothing")
        XCTAssertLessThan(changed(alone, blank), changed(wholeImage, blank), "the siblings still draw: the node is as much as the scene")
        try one.remove()

        // Two roots, written by the kernel: a root's sibling is the other root, and it draws
        // less than both.
        let two = FileManager.default.temporaryDirectory.appendingPathComponent("view-two-\(UUID().uuidString).stp")
        defer { try? FileManager.default.removeItem(at: two) }
        try writeStep(two.path, [try Solid.cuboid(1, 1, 1), try Solid.cuboid(2, 2, 2).translate(5, 0, 0)])
        let doc = try Cadaclysm.open(two.path)
        defer { doc.close() }
        let roots = doc.roots
        XCTAssertEqual(roots.count, 2, "\(roots.count) roots")
        guard roots.count == 2 else { return }
        XCTAssertEqual(roots[0].siblingsAlongPath, [UInt32(roots[1].index)])
        let both = try view.showScene(doc)
        try view.standard("iso")
        try view.frame()
        let bothImage = try view.image()
        try both.remove()
        let first = try view.showNode(roots[0])
        let firstImage = try view.image()  // the same camera as both
        XCTAssertGreaterThan(changed(firstImage, blank), 0, "a root drew nothing")
        XCTAssertLessThan(changed(firstImage, blank), changed(bothImage, blank), "a root drew as much as both")
        try first.remove()
    }

    func testClosingASceneReleasesItsItems() throws {
        let mechanism = try sample("mechanism-solid.stp")
        let view = try offscreen(64, 64)
        defer { try? view.close() }

        // A Scene item keeps the scene alive after the Scene is gone; removing it lets go.
        weak var kept: Scene?
        var item: Item?
        do {
            let doc = try Cadaclysm.open(mechanism)
            kept = doc
            item = try view.showScene(doc)
        }
        XCTAssertNotNil(kept, "the item let go of the scene it shows")
        try item?.remove()
        XCTAssertNil(kept, "a removed item still holds its scene")

        // Scene.close() removes the items of this thread's views that show it, first.
        let doc = try Cadaclysm.open(mechanism)
        let all = try view.showScene(doc)
        let part = try view.showNode(try XCTUnwrap(nestedLeaf(doc)))
        doc.close()
        XCTAssertTrue(doc.closed, "the scene stayed open")
        try view.draw()
        XCTAssertNotEqual(message { try all.colour(SIMD3<Float>(1, 0, 0)) }, "<accepted>", "an item of a closed scene is still shown")
        XCTAssertNotEqual(message { try part.colour(SIMD3<Float>(1, 0, 0)) }, "<accepted>", "a node item of a closed scene is still shown")
        XCTAssertEqual(message { _ = try view.showScene(doc) }, "mechanism-solid.stp: the scene is closed")

        // ... and stays open while a view of another thread shows it.
        let third = try Cadaclysm.open(mechanism)
        let shown = DispatchSemaphore(value: 0), closing = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        final class Said: @unchecked Sendable { var text = "" }  // written before `done`, read after
        let failed = Said()
        let other = Thread {
            do {
                let theirs = try View.offscreen(width: 48, height: 48)
                _ = try theirs.showScene(third)
                shown.signal()
                closing.wait()
                try theirs.draw()  // reads the scene: it must still be open
            } catch {
                failed.text = "\(error)"
                shown.signal()
                closing.wait()
            }  // the view is destroyed here, on its own thread
            done.signal()
        }
        other.start()
        shown.wait()
        third.close()
        XCTAssertFalse(third.closed, "the scene was closed under another thread's view")
        closing.signal()
        done.wait()
        XCTAssertEqual(failed.text, "", "the other thread")
        third.close()
        XCTAssertTrue(third.closed, "the scene would not close once the other view was gone")
    }

    func testAViewBelongsToTheThreadThatMadeIt() throws {
        let view = try offscreen(32, 32)
        var drewThere = "", closedThere = ""
        onAnotherThread {
            drewThere = message { try view.draw() }
            closedThere = message { try view.close() }
        }
        XCTAssertEqual(drewThere, "cadaclysm_view_draw: a view belongs to the thread that made it")
        XCTAssertEqual(closedThere, "close: a view belongs to the thread that made it")
        try view.draw()  // still working after another thread's refused calls

        // A view dropped on another thread than its own is left -- and so is what its items
        // keep, which the left view may still read.
        weak var left: Solid?
        var theirs: View?
        onAnotherThread {
            if let v = try? View.offscreen(width: 16, height: 16), let s = try? Solid.cuboid(1, 1, 1) {
                left = s
                if (try? v.showSolid(s)) != nil { theirs = v }
            }
        }
        XCTAssertNotNil(theirs, "a view made and shown on another thread")
        theirs = nil
        XCTAssertNotNil(left, "a view dropped off its thread let go of what its items keep")
        try view.close()
    }

    func testTheWgpuTableRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyCreateFails = false }
        rig(t)

        // A void call that left a last error refused with it; a silent refusal in Python's words.
        spySaid = cstr("boom from the library")
        XCTAssertEqual(message { try view.orbit(1, 1) }, "boom from the library")
        XCTAssertEqual(message { try view.pan(1, 1) }, "boom from the library")
        XCTAssertEqual(message { try view.zoom(1) }, "boom from the library")
        XCTAssertEqual(message { try view.look(1, 1) }, "boom from the library")
        XCTAssertEqual(message { try view.dolly(1) }, "boom from the library")
        XCTAssertEqual(message { try view.orthographic(false) }, "boom from the library")
        XCTAssertEqual(message { try view.background(SIMD3<Float>(0, 0, 0)) }, "boom from the library")
        spySaid = nil
        try view.orbit(0, 0)
        let realFrame = t.pointee.frame
        t.pointee.frame = { _, _ in false }
        XCTAssertEqual(message { try view.frame() }, "the view library failed")
        t.pointee.frame = realFrame

        // A failed create: the library's bare message, the hint where it says "no display".
        spyCreateFails = true
        spySaid = cstr("no display: none here")
        let hint = " -- draw without a display with View.offscreen, or the terminal (ViewLibrary.useTerminal())"
        XCTAssertEqual(message { _ = try View() }, "no display: none here" + hint)
        XCTAssertEqual(message { try Solid.cuboid(1, 1, 1).show() }, "no display: none here" + hint)
        spySaid = nil
        XCTAssertEqual(message { _ = try View() }, "the view library failed")
        spyCreateFails = false

        // Windows of their own (forced offscreen): pump's waits, its failures and its count; input.
        do {
            let a = try View(), b = try View()
            spyPumpMs = []
            spyPumpAnswers = [0, UInt32(CADACLYSM_VIEW_CLOSED)]
            XCTAssertEqual(message { _ = try View.pump(timeout: 1) }, "pump broke")
            XCTAssertEqual(spyPumpMs, [1000, 0], "every window pumped, the wait on the first")
            // A pump that reached neither window would make the waits below real sleeps.
            guard spyPumpMs == [1000, 0] else { return XCTFail("pump did not reach both windows: \(spyPumpMs)") }
            XCTAssertTrue(b.isClosed, "CLOSED did not close the second")
            XCTAssertFalse(a.isClosed, "the failure closed the first")
            spyPumpAnswers = []
            // With no window of this thread's own pump would sleep the wait: not with these.
            for (wait, expected) in [(-1.0, UInt32(0)), (1e12, UInt32.max), (Double.nan, UInt32(0))] where !a.isClosed {
                spyPumpMs = []
                XCTAssertEqual(try View.pump(timeout: wait), 1, "the failed window is still open and counted")
                XCTAssertEqual(spyPumpMs, [expected], "pump(\(wait))")
            }
            spyInputAnswer = 0
            spySaid = cstr("input broke")
            XCTAssertEqual(message { _ = try a.input(kind: UInt32(CADACLYSM_VIEW_EVENT_KEY), key: "Escape") }, "input broke")
            spySaid = nil
            spyInputAnswer = UInt32(CADACLYSM_VIEW_INPUT_CLOSE)
            XCTAssertEqual(try a.input(kind: UInt32(CADACLYSM_VIEW_EVENT_KEY), key: "Escape"), UInt32(CADACLYSM_VIEW_INPUT_CLOSE))
            XCTAssertTrue(a.isClosed, "Escape did not close a window of its own")
            XCTAssertEqual(message { try a.draw() }, "cadaclysm_view_draw: the window is closed")
            try a.close()
            try b.close()
        }

        // show() on the wgpu library runs its window: a solid titled "Solid", Z up; view()
        // answers the camera it was left at.
        let cube = try Solid.cuboid(5, 5, 5)
        spyRuns = 0
        try cube.show()
        XCTAssertEqual(spyRuns, 1)
        XCTAssertEqual(spyTitle, "Solid")
        XCTAssertEqual(spyYUp, 0)
        let camera = try cube.view()
        XCTAssertEqual(camera.eye.x, 10)
        XCTAssertEqual(camera.azimuth, 0, accuracy: 1e-9)
        XCTAssertEqual(camera.elevation, 0, accuracy: 1e-9)
        XCTAssertNil(camera.pick)

        // run() reads the camera in the view's own up axis: an eye on +Y is the horizon Z up
        // and the pole Y up.
        spyEye = (0, 10, 0)
        spyUp = (0, 0, -1)
        for up in [View.UpAxis.z, .y] {
            let own = try View.offscreen(width: 32, height: 32, up: up)
            let c = try own.run()
            XCTAssertEqual(c.elevation, up == .y ? 90 : 0, accuracy: 1e-6, "run, \(up)")
            XCTAssertTrue(own.isClosed)
            XCTAssertEqual(message { try own.draw() }, "cadaclysm_view_draw: the window is closed")
            try own.close()
        }
        spyEye = (10, 0, 0)
        spyUp = (0, 0, 1)

        // A scene, a node and a pose: the scene's file name, the scene's own up axis; the
        // node's siblings hidden and the node framed; the pose's transforms, one per node.
        let mechanism = try sample("mechanism-solid.stp")
        let scene = try Cadaclysm.open(mechanism)
        let upright = try Cadaclysm.open(mechanism, convention: .yUp)
        defer { scene.close(); upright.close() }
        try scene.show()
        XCTAssertEqual(spyTitle, "mechanism-solid.stp")
        XCTAssertEqual(spyYUp, 0)
        try scene.show(ShowOptions(title: "mine"))
        XCTAssertEqual(spyTitle, "mine")
        try upright.show()
        XCTAssertEqual(spyYUp, 1, "the scene's own up axis (Y) was not passed through")
        try upright.show(ShowOptions(up: .z))
        XCTAssertEqual(spyYUp, 0, "an explicit up did not win")
        let leaf = try XCTUnwrap(nestedLeaf(upright))
        spyTitle = ""
        spyHidden = []
        spyFramed = []
        try leaf.show()
        XCTAssertEqual(spyYUp, 1)
        XCTAssertEqual(spyTitle, "mechanism-solid.stp")
        XCTAssertEqual(spyHidden, leaf.siblingsAlongPath, "the node's siblings were not hidden")
        XCTAssertEqual(spyFramed, [UInt32(leaf.index)], "the node was not framed")
        let state = try XCTUnwrap(upright.states.first)
        let pose = try upright.poseState(state)
        spyTitle = ""
        spyPosed = []
        try pose.show()
        XCTAssertEqual(spyYUp, 1)
        XCTAssertEqual(spyTitle, "mechanism-solid.stp")
        XCTAssertEqual(spyPosed, [UInt32(upright.nodes.count)], "the pose's transforms did not reach the view")
        spyPosed = []
        try upright.show()
        XCTAssertEqual(spyPosed, [], "a scene's show posed it")
    }

    /// C11: close() destroys the C view first, then lets go of what its items kept -- the
    /// library may read a shown solid until its view is gone.
    func testCloseDestroysTheViewBeforeDroppingItsItems() throws {
        let view = try offscreen(32, 32)
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved }
        spyRealDestroy = t.pointee.destroy
        spyAliveAtDestroy = []
        t.pointee.destroy = { v in
            spyAliveAtDestroy.append(spyWatched != nil)
            spyRealDestroy!(v)
        }
        do {
            let solid = try Solid.cuboid(1, 1, 1)
            spyWatched = solid
            _ = try view.showSolid(solid)
        }
        XCTAssertNotNil(spyWatched, "the item let go of its solid")
        try view.close()
        XCTAssertEqual(spyAliveAtDestroy, [true], "the solid was let go of before the view was destroyed")
        XCTAssertNil(spyWatched, "close() kept the solid")
    }

    /// Scene.close() on a scene shown by a view of this thread whose window the user closed:
    /// that view is destroyed (the destroy it owed anyway), not called.
    func testClosingASceneDestroysAClosedWindowsView() throws {
        let mechanism = try sample("mechanism-solid.stp")
        let probe = try offscreen(32, 32)
        let t = probe.library.table
        let saved = t.pointee
        defer { t.pointee = saved; try? probe.close() }
        rig(t)
        let own = try View()
        let doc = try Cadaclysm.open(mechanism)
        _ = try own.showScene(doc)
        try own.run()  // the window "closed" at once
        XCTAssertTrue(own.isClosed)
        XCTAssertNotNil(own.handle, "run() destroyed the view")
        doc.close()
        XCTAssertTrue(doc.closed, "the scene stayed open")
        XCTAssertNil(own.handle, "the closed window's view was not destroyed")
        XCTAssertTrue(own.owners.isEmpty, "the destroyed view still keeps the scene")
    }

    /// current() with nothing chosen opens the default (CADACLYSM_VIEW, else the terminal)
    /// and remembers it: a later CADACLYSM_VIEW does not change the library in use.
    func testCurrentRemembersTheFirstDefault() throws {
        var old = [CChar](repeating: 0, count: Int(CVL_PATH))
        let oldCount = old.count
        let had = cvl_getenv("CADACLYSM_VIEW", &old, oldCount) != 0
        let remembered = ViewLibrary.chosen
        defer {
            ViewLibrary.chosen = remembered
            if had { cvl_setenv("CADACLYSM_VIEW", old) } else { cvl_setenv("CADACLYSM_VIEW", nil) }
        }
        cvl_setenv("CADACLYSM_VIEW", nil)
        ViewLibrary.chosen = nil
        let first: ViewLibrary
        do { first = try ViewLibrary.current() } catch {
            if ProcessInfo.processInfo.environment["CADACLYSM_REQUIRE_TERMINAL"] == "1" {
                XCTFail("CADACLYSM_REQUIRE_TERMINAL=1, but: \(error)")
            }
            throw XCTSkip("no terminal library here: \(error)")
        }
        XCTAssertTrue(first.isTerminal, first.name)
        XCTAssertTrue(ViewLibrary.chosen === first, "the first default was not remembered")
        cvl_setenv("CADACLYSM_VIEW", "wgpu")
        XCTAssertTrue(try ViewLibrary.current() === first, "a later CADACLYSM_VIEW changed the remembered library")
    }

    /// The loader binds 70 calls of cadaclysm_view.h 1.11 (all but 1.7's machining and timeline
    /// calls): a 1.10 library (no show_points) is refused before any call is bound, in Python's
    /// words; 1.11 and later 1.x are taken.
    func testTheLoaderNeedsViewABI111() throws {
        try checkABIForTest(version: 0x1000B, path: "lib")
        try checkABIForTest(version: 0x1000C, path: "lib")
        XCTAssertEqual(message { try checkABIForTest(version: 0x1000A, path: "lib") },
                       "lib: view ABI 1.10, this SDK needs 1.11 or a later 1.x")
        XCTAssertEqual(message { try checkABIForTest(version: 0x2000B, path: "lib") },
                       "lib: view ABI 2.11, this SDK needs 1.11 or a later 1.x")
    }

    /// show_points (view ABI 1.11), through the table rigged: the points, their count, the colour
    /// and the size reach the library as given and an item comes back; no colour and no size are
    /// rgb NULL and 8; four numbers and a two-number colour are refused before the library.
    func testShowPointsReachesTheContractAndReturnsAnItem() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spyPointsCalls = 0 }
        rigPoints(t)
        spyPointsCalls = 0

        let item = try view.showPoints([0, 0, 0, 1, 2, 3], rgb: "red", sizePx: 12)
        XCTAssertEqual(item.id, 17)
        XCTAssertEqual(spyPointsCalls, 1)
        XCTAssertEqual(spyPoints, [0, 0, 0, 1, 2, 3])
        XCTAssertEqual(spyPointsRgb, [1, 0, 0], "red did not reach the library as (1, 0, 0)")
        XCTAssertEqual(spyPointsSize, 12)

        let plain = try view.showPoints([1, 2, 3])
        XCTAssertEqual(plain.id, 17)
        XCTAssertEqual(spyPointsCalls, 2)
        XCTAssertEqual(spyPoints, [1, 2, 3])
        XCTAssertNil(spyPointsRgb, "no colour did not reach the library as NULL")
        XCTAssertEqual(spyPointsSize, 8)

        XCTAssertEqual(message { _ = try view.showPoints([1, 2, 3, 4]) }, "show_points: three numbers a point, not 4")
        XCTAssertEqual(message { _ = try view.showPoints([1, 2, 3], rgb: [Float]([1, 0])) }, "colour: 3 or 4 numbers, not 2")
        XCTAssertEqual(spyPointsCalls, 2, "a refused show_points reached the library")
    }

    /// One picture of everything that takes a colour, each given as text or as the numbers the
    /// text names (in the forms the module took before colour text, so those keep compiling):
    /// the background, a mesh, a solid and its face colours, an item recoloured, lines, curves;
    /// with a scene, a node's colour and highlight.
    private func coloursDrawn(text: Bool, scene: Scene?) throws -> ViewImage {
        let view = try offscreen(160, 120)
        func pick(_ words: String, _ numbers: any Colour) -> any Colour { text ? words : numbers }
        try view.layer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        if text { try view.background("#ff0") } else { try view.background(SIMD3<Float>(1, 1, 0)) }
        let square: [Float] = [-4, -1, 0, -2, -1, 0, -2, 1, 0, -4, 1, 0]
        let triangles: [UInt32] = [0, 1, 2, 0, 2, 3]
        _ = try view.showMesh(positions: square, indices: triangles, rgb: pick("Red", SIMD3<Float>(1, 0, 0)))
        var lifted = square
        for i in stride(from: 1, to: lifted.count, by: 3) { lifted[i] += 2.5 }
        try view.showMesh(positions: lifted, indices: triangles).colour(pick("#00f", SIMD3<Float>(0, 0, 1)))
        let cube = try Solid.cuboid(2, 2, 2)
        let solid = try view.showSolid(cube, rgb: pick("LIME", SIMD3<Float>(0, 1, 0)))
        if text {
            try solid.faceColours([0, 1], ["00ff80", "black"])
        } else {
            try solid.faceColours([0, 1], [SIMD4<Float>(0, 1, 128 / 255, 1), SIMD4<Float>(0, 0, 0, 1)])
        }
        _ = try view.showLines([3, 0, 0, 5, 2, 2], rgb: pick("#ffffff", SIMD3<Float>(1, 1, 1)))
        _ = try view.showCurves([3, -2, 0, 1, 4, -1, 0, 1, 5, -2, 1, 1, 6, -1, 0, 1],
                                rgb: pick("purple", SIMD3<Float>(128 / 255, 0, 128 / 255)))
        if let scene {
            let whole = try view.showScene(scene)
            try whole.nodeColour(0, pick("white", SIMD4<Float>(1, 1, 1, 1)))
            try whole.nodeHighlight(0, pick("#f00", SIMD4<Float>(1, 0, 0, 1)))
        }
        try view.standard("iso")
        try view.frame()
        defer { try? view.close() }
        return try view.image()
    }

    /// Colour text, read by the library's cadaclysm_view_parse_colour, draws the pixels its
    /// numbers draw in every call that takes a colour.
    func testColourTextDrawsItsNumbers() throws {
        let scene = try Cadaclysm.open(try sample("mechanism-solid.stp"))
        defer { scene.close() }
        for with in [nil, scene] as [Scene?] {
            let numbers = try coloursDrawn(text: false, scene: with), text = try coloursDrawn(text: true, scene: with)
            XCTAssertFalse(numbers.rgba.isEmpty)
            XCTAssertEqual(changed(numbers, text), 0, "colour text drew pixels unlike its numbers (with a scene: \(with != nil))")
        }
    }

    /// Text the library refuses throws its message, and nothing reaches the view.
    func testRefusedColourTextIsTheLibrarysMessage() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let square = try view.showMesh(positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], indices: [0, 1, 2, 0, 2, 3],
                                       rgb: "gray")
        try view.standard("top")
        try view.frame()
        let before = try view.image()
        for bad in ["blurple", "transparent", "rgb(1, 2, 3)", "#f00a", ""] {
            XCTAssertEqual(message { try square.colour(bad) },
                           "cadaclysm_view_parse_colour: colour: \"#rgb\", \"#rrggbb\" or a CSS colour name, not '\(bad)'")
        }
        let cube = try Solid.cuboid(1, 1, 1)
        let refusals: [(String, () throws -> Void)] = [
            ("background", { try view.background("nope") }),
            ("showLines", { _ = try view.showLines([0, 0, 0, 1, 1, 1], rgb: "nope") }),
            ("showCurves", { _ = try view.showCurves([Float](repeating: 0, count: 16), rgb: "nope") }),
            ("showMesh", { _ = try view.showMesh(positions: [Float](repeating: 0, count: 9), indices: [0, 1, 2], rgb: "nope") }),
            ("showSolid", { _ = try view.showSolid(cube, rgb: "nope") }),
            ("faceColours", { try square.faceColours([0], ["nope"]) }),
            ("nodeColour", { try square.nodeColour(0, "nope") }),
            ("nodeHighlight", { try square.nodeHighlight(0, "nope") }),
        ]
        for (what, call) in refusals {
            XCTAssertTrue(message(call).hasSuffix("not 'nope'"), "\(what): \(message(call))")
        }
        // Not a colour the module reads: refused in its own words.
        XCTAssertEqual(message { try square.colour([Float](repeating: 0, count: 2)) }, "colour: 3 or 4 numbers, not 2")
        XCTAssertEqual(changed(before, try view.image()), 0, "a refused colour reached the view")
    }

    /// The spec's wrapper case on the real library (Python's
    /// test_text_shows_changes_and_picks_its_line_on_the_real_library): a label shown, setText
    /// giving it a second line, a pick answering the item and the line hit as its face; the
    /// bundled font's own bytes load; the text layer hides text; refusals in Python's words or
    /// the library's, a NUL refused before the call.
    func testTextShowsChangesAndPicksItsLine() throws {
        let view = try offscreen(96, 96)
        defer { try? view.close() }
        try view.layer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        let origin = SIMD3<Float>(0, 0, 0)
        let twenty: Float = 20
        let blank = try view.image()
        // Top left at the anchor, the picture's centre (48, 48): line 0 runs y 48..68, line 1 68..88.
        let item = try view.showText("one", at: origin, size: twenty, colour: "red", align: "top-left", onTop: true)
        XCTAssertEqual(try view.pick(x: 52, y: 58).map { [$0.item, $0.node, $0.face, $0.clicks] }, [item.id, 0, 0, 1])
        XCTAssertNil(try view.pick(x: 52, y: 78), "one line: nothing below it")
        let oneLine = try view.image()
        XCTAssertGreaterThan(changed(oneLine, blank), 0, "the label drew nothing")
        try item.setText("one\ntwo")
        XCTAssertEqual(try view.pick(x: 52, y: 78).map { [$0.item, $0.node, $0.face, $0.clicks] }, [item.id, 0, 1, 1],
                       "the second line, after setText")
        let twoLines = try view.image()
        XCTAssertGreaterThan(changed(oneLine, twoLines), 0, "setText changed nothing on screen")

        // The text layer: off, the picture is the blank one; on, the text again.
        try view.layer(UInt32(CADACLYSM_VIEW_LAYER_TEXT), false)
        XCTAssertEqual(changed(try view.image(), blank), 0, "the text layer off still draws text")
        try view.layer(UInt32(CADACLYSM_VIEW_LAYER_TEXT), true)
        XCTAssertEqual(changed(try view.image(), twoLines), 0, "the text layer on did not draw the text again")

        // The bundled font's own bytes, from the repository (an SDK layout has no crates/).
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var fontFile: String?
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("crates/cadaclysm-text/fonts/LiberationSans-Regular.ttf").path
            if FileManager.default.fileExists(atPath: candidate) { fontFile = candidate; break }
            dir = dir.deletingLastPathComponent()
        }
        if let fontFile {
            let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: fontFile)))
            let font = try loadFont(bytes)
            XCTAssertGreaterThanOrEqual(font, 1)
            XCTAssertGreaterThanOrEqual(try loadFont(path: fontFile), 1)
            let other = try view.showText("HHH", at: origin, size: twenty, colour: "red", onTop: true, font: font)
            XCTAssertGreaterThan(other.id, item.id)
            try other.remove()
        }
        // A font id never loaded reaches the library, which refuses it.
        let unknownFont: UInt32 = 999_999
        XCTAssertTrue(message { _ = try view.showText("x", at: origin, font: unknownFont) }.contains("font"),
                      "an unknown font: \(message { _ = try view.showText("x", at: origin, font: unknownFont) })")
        let garbage = message { _ = try loadFont([1, 2, 3, 4, 5, 6, 7, 8]) }
        XCTAssertFalse(garbage == "<accepted>" || garbage.isEmpty || garbage == "the view library failed",
                       "garbage font bytes: \(garbage)")
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-font-\(UUID().uuidString).ttf").path
        XCTAssertEqual(message { _ = try loadFont(path: missing) }, "\(missing): the font could not be read")

        // Refusals: Python's words before the library, the library's own after.
        XCTAssertEqual(message { _ = try view.showText("x", at: origin, mode: "screen") }, "mode 'screen': one of label, world")
        XCTAssertEqual(message { _ = try view.showText("x", at: origin, align: "middle") },
                       "align 'middle': one of top-left, top, top-right, left, centre, center, right, bottom-left, bottom, bottom-right")
        XCTAssertEqual(message { _ = try view.showText("a\0b", at: origin) },
                       "text 'a\\x00b': a NUL character cannot be shown (the C string ends there)")
        XCTAssertEqual(message { try item.setText("cut\0short") },
                       "text 'cut\\x00short': a NUL character cannot be shown (the C string ends there)")
        XCTAssertEqual(try view.pick(x: 52, y: 78)?.face, 1, "a refused setText changed the text")
        let zero: Float = 0
        let flat = message { _ = try view.showText("x", at: origin, size: zero) }
        XCTAssertTrue(flat.contains("height"), "size 0: \(flat)")
        XCTAssertEqual(message { try view.close(); _ = try view.showText("x", at: origin) },
                       "cadaclysm_view_show_text: the view is closed")
        XCTAssertEqual(message { _ = try view.showText("x", at: origin, colour: "nope") }, "cadaclysm_view_show_text: the view is closed",
                       "the view is refused before the colour")
        XCTAssertEqual(message { try item.setText("x") }, "cadaclysm_view_set_text: the view is closed")
        XCTAssertEqual(message { _ = try view.showText("x", at: origin, mode: "screen") }, "mode 'screen': one of label, world",
                       "the mode is refused before the view")
    }

    /// Lime glyphs on a red box draw both colours (a swapped rgb / box_rgba draws them the other
    /// way round); a box of four numbers keeps its alpha (0: no box), of three is opaque.
    func testALabelDrawsItsColourOnItsBox() throws {
        let size: Float = 24
        let origin = SIMD3<Float>(0, 0, 0)
        func counts(_ box: (any Colour)?) throws -> (red: Int, lime: Int) {
            let view = try offscreen(64, 64)
            defer { try? view.close() }
            try view.layer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
            try view.background("black")
            _ = try view.showText("HH", at: origin, size: size, colour: "lime", align: "centre", box: box, onTop: true)
            let img = try view.image()
            var red = 0, lime = 0
            for i in stride(from: 0, to: img.rgba.count, by: 4) {
                let r = img.rgba[i], g = img.rgba[i + 1], b = img.rgba[i + 2]
                if r > 200 && g < 60 && b < 60 { red += 1 }
                if g > 200 && r < 60 && b < 60 { lime += 1 }
            }
            return (red, lime)
        }
        let boxed = try counts("red")
        XCTAssertGreaterThan(boxed.lime, 20, "the glyphs are not drawn lime: \(boxed)")
        XCTAssertGreaterThan(boxed.red, 50, "the box is not drawn red: \(boxed)")
        XCTAssertGreaterThan(boxed.red, boxed.lime, "the box is smaller than the glyphs: \(boxed)")
        let three = try counts(SIMD3<Float>(1, 0, 0))
        XCTAssertGreaterThan(three.red, 50, "a box of three numbers is not opaque: \(three)")
        let clear = try counts(SIMD4<Float>(1, 0, 0, 0))
        XCTAssertEqual(clear.red, 0, "a box of alpha 0 drew: \(clear)")
        XCTAssertGreaterThan(clear.lime, 20, "\(clear)")
        let none = try counts(nil)
        XCTAssertEqual(none.red, 0, "no box drew red: \(none)")
    }

    // ---- view ABI 1.8: the pick's clicks and point, the double-click opt-in, focus, navigation

    /// A pick and run's pick carry clicks, and the point only where the library set one;
    /// setDoubleClickFrames, focus and navigation reach the library with their arguments.
    func testThePicksClicksAndPointAndThe17CallsRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyPicked = CadaclysmViewPick(); spyNavigation = 0; spyLanded = true }
        rig17(t)

        spyPicked = CadaclysmViewPick()
        spyPicked.item = 3
        spyPicked.node = 4
        spyPicked.face = 5
        spyPicked.clicks = 2
        spyPicked.has_point = 1
        spyPicked.point = (1.5, -2, 0.25)
        let where17 = SIMD3<Float>(1.5, -2, 0.25)
        let hit = try XCTUnwrap(try view.pick(x: 1, y: 1))
        XCTAssertEqual([hit.item, hit.node, hit.face, hit.clicks], [3, 4, 5, 2], "a double click's hit")
        XCTAssertEqual(hit.point, where17, "the point it hit")
        spyPicked.clicks = 1
        spyPicked.has_point = 0
        let flat = try XCTUnwrap(try view.pick(x: 1, y: 1))
        XCTAssertEqual(flat.clicks, 1, "a click's hit")
        XCTAssertNil(flat.point, "has_point 0: the point bytes mean nothing")
        spyPicked.clicks = 2
        spyPicked.has_point = 1
        let landed = try view.lastPick()
        XCTAssertTrue(landed.landed)
        XCTAssertEqual(landed.pick?.point, where17, "the landed answer's point")
        XCTAssertEqual(landed.pick?.clicks, 2, "the landed answer's clicks")
        spyLanded = false
        spySaid = cstr("cadaclysm_view_pick_result: no pick result")
        XCTAssertFalse(try view.lastPick().landed, "nothing landed yet")
        spySaid = nil
        XCTAssertFalse(try view.lastPick().landed, "nothing landed, nothing said")
        spySaid = cstr("boom from pick_result")
        XCTAssertEqual(message { _ = try view.lastPick() }, "boom from pick_result", "the library's refusal")
        spySaid = nil
        spyLanded = true
        spyPicked.item = 0
        let miss = try view.lastPick()
        XCTAssertTrue(miss.landed, "a click on nothing landed")
        XCTAssertNil(miss.pick, "a click on nothing")
        spyPicked.item = 7
        spyPicked.has_point = 0
        let own = try View.offscreen(width: 32, height: 32)
        let camera = try own.run()
        try own.close()
        let picked = try XCTUnwrap(camera.pick, "run's pick")
        XCTAssertEqual([picked.item, picked.clicks], [7, 2])
        XCTAssertNil(picked.point, "run's pick: no point without has_point")

        spyCalls = []
        try view.setDoubleClickFrames(true)
        try view.setDoubleClickFrames(false)
        try view.focus(SIMD3<Float>(1, -2, 3.5))
        XCTAssertEqual(try view.navigation, .orbit)
        spyNavigation = UInt32(CADACLYSM_VIEW_NAVIGATION_FLY)
        XCTAssertEqual(try view.navigation, .fly)
        XCTAssertEqual(spyCalls, ["frames on", "frames off", "focus 1.0 -2.0 3.5", "navigation", "navigation"])
        let nan = Float.nan
        XCTAssertEqual(message { try view.focus(SIMD3<Float>(nan, 0, 0)) }, "cadaclysm_view_focus: the point is not finite")
        spySaid = nil
        try view.close()
        XCTAssertEqual(message { try view.focus(SIMD3<Float>(0, 0, 0)) }, "cadaclysm_view_focus: the view is closed")
        XCTAssertEqual(message { _ = try view.navigation }, "cadaclysm_view_navigation: the view is closed")
        XCTAssertEqual(message { try view.setDoubleClickFrames(true) },
                       "cadaclysm_view_set_double_click_frames: the view is closed")
    }

    /// A red square seen from the top, zoomed out so a framing visibly changes the picture.
    private func framedSquare() throws -> (View, UInt32) {
        let view = try offscreen(64, 48)
        try view.layer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        let square: [Float] = [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0]
        let triangles: [UInt32] = [0, 1, 2, 0, 2, 3]
        let item = try view.showMesh(positions: square, indices: triangles, rgb: SIMD3<Float>(1, 0, 0))
        try view.standard("top")
        try view.frame()
        try view.zoom(-3)
        try view.draw()
        return (view, item.id)
    }

    /// Down, up, down, up of the left button at one pixel within the double-click time.
    private func doubleClick(_ view: View, _ x: Float, _ y: Float) throws {
        let down = UInt32(CADACLYSM_VIEW_EVENT_DOWN), up = UInt32(CADACLYSM_VIEW_EVENT_UP)
        let kinds: [UInt32] = [down, up, down, up]
        let times: [Double] = [1000, 1010, 1060, 1070]
        for i in 0..<4 {
            _ = try view.input(kind: kinds[i], x: x, y: y, button: UInt32(CADACLYSM_VIEW_BUTTON_LEFT),
                               pointer: UInt32(CADACLYSM_VIEW_POINTER_MOUSE), timeMS: times[i])
        }
    }

    /// The answer an input asked for, read through lastPick as the view's draws land it (ten
    /// seconds of wall time, 10 ms a draw, as Python's pick waits).
    private func land(_ view: View) throws -> ViewPick? {
        let end = Date().addingTimeInterval(10)
        while Date() < end {
            try view.draw()
            let answer = try view.lastPick()
            if answer.landed { return answer.pick }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("the pick never landed")
        return nil
    }

    /// A double click through input answers clicks 2 with the point hit, and leaves the picture.
    func testADoubleClickAnswersClicks2AndLeavesThePicture() throws {
        let (view, id) = try framedSquare()
        defer { try? view.close() }
        let before = try view.image()
        XCTAssertFalse(try view.lastPick().landed, "nothing clicked yet")
        try doubleClick(view, 32, 24)
        let hit = try XCTUnwrap(try land(view), "the double click hit nothing")
        XCTAssertEqual([hit.item, hit.clicks], [id, 2], "a double click's answer")
        let point = try XCTUnwrap(hit.point, "a hit with no point")
        XCTAssertLessThan(abs(point.z), 1e-3, "the square's z: \(point)")
        XCTAssertLessThan(abs(point.x), 0.2, "the square's centre: \(point)")
        XCTAssertEqual(changed(before, try view.image()), 0, "a double click moved the picture by default")
        XCTAssertFalse(try view.lastPick().landed, "each answer is read once")
        // One click on the background, well after: landed, with nothing hit.
        for (kind, at) in [(UInt32(CADACLYSM_VIEW_EVENT_DOWN), 5000.0), (UInt32(CADACLYSM_VIEW_EVENT_UP), 5010.0)] {
            _ = try view.input(kind: kind, x: 1, y: 1, button: UInt32(CADACLYSM_VIEW_BUTTON_LEFT),
                               pointer: UInt32(CADACLYSM_VIEW_POINTER_MOUSE), timeMS: at)
        }
        let end = Date().addingTimeInterval(10)
        var miss: (landed: Bool, pick: ViewPick?) = (false, nil)
        while !miss.landed && Date() < end {
            try view.draw()
            miss = try view.lastPick()
            if !miss.landed { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertTrue(miss.landed, "the background click's pick never landed")
        XCTAssertNil(miss.pick, "a click on the background hit something")
    }

    /// setDoubleClickFrames(true) makes the same double click frame what it hit.
    func testOptedInADoubleClickFrames() throws {
        let (view, _) = try framedSquare()
        defer { try? view.close() }
        let before = try view.image()
        try view.setDoubleClickFrames(true)
        try doubleClick(view, 32, 24)
        XCTAssertEqual(try land(view)?.clicks, 2, "opted in: still a pick of clicks 2")
        XCTAssertGreaterThan(changed(before, try view.image()), 0, "opted in, the double click did not frame what it hit")
    }

    /// navigation is .fly after a fly key (and after it is let go), Tab toggles it, focus leaves it.
    func testNavigationFliesAfterAFlyKeyUntilTabOrFocus() throws {
        let (view, _) = try framedSquare()
        defer { try? view.close() }
        let keyKind = UInt32(CADACLYSM_VIEW_EVENT_KEY)
        func key(_ k: String) throws {
            _ = try view.input(kind: keyKind, key: k, keyDown: true)
            _ = try view.input(kind: keyKind, key: k, keyDown: false)
        }
        XCTAssertEqual(try view.navigation, .orbit, "a new view")
        try key("KeyW")
        XCTAssertEqual(try view.navigation, .fly, "after KeyW, let go")
        try key("Tab")
        XCTAssertEqual(try view.navigation, .orbit, "after Tab")
        try key("KeyW")
        try view.focus(SIMD3<Float>(1, 2, 3))
        XCTAssertEqual(try view.navigation, .orbit, "focus leaves fly mode")
    }

    /// focus moves the orbit point -- the centre then looks at it -- and focus back restores the
    /// picture; a point not finite is the library's refusal.
    func testFocusMovesTheOrbitPoint() throws {
        let (view, _) = try framedSquare()
        defer { try? view.close() }
        let before = try view.image()
        let centre = try XCTUnwrap(try view.pick(x: 32, y: 24)?.point, "the centre hit nothing")
        XCTAssertLessThan(abs(centre.x), 0.2, "the centre looks at the middle of the square: \(centre)")
        try view.focus(SIMD3<Float>(0.5, 0, 0))
        let moved = try XCTUnwrap(try view.pick(x: 32, y: 24)?.point, "the centre hit nothing after focus")
        XCTAssertLessThan(abs(moved.x - 0.5), 0.1, "the centre now looks at x = 0.5: \(moved)")
        XCTAssertGreaterThan(changed(before, try view.image()), 0, "focus did not move the picture")
        try view.focus(SIMD3<Float>(0, 0, 0))
        XCTAssertEqual(changed(before, try view.image()), 0, "focus back did not restore the picture")
        let infinite = Float.infinity
        XCTAssertTrue(message { try view.focus(SIMD3<Float>(infinite, 0, 0)) }.hasPrefix("cadaclysm_view_focus"),
                      message { try view.focus(SIMD3<Float>(infinite, 0, 0)) })
    }
}
