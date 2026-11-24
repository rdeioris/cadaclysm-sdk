// The view through CadaclysmView: a missing library refused with the contract's message,
// the terminal's stills and refusals, and an offscreen view -- a solid by handle (kept alive
// by its item), image() inside its silhouette, pick, save, a real pose and the rest pose, a
// nested node and a root drawing less than their scene, Scene.close() releasing its items,
// another thread's calls refused, colour text drawing its numbers' pixels and refused text
// refused in the library's words, the loader's ABI 1.29, text (labels shown, changed, picked
// by line, coloured on their box; fonts loaded; refusals) -- and the wgpu library's table
// rigged: show()/view()'s title and up axis, run()'s camera, pump's waits and count, input,
// void-call refusals; ABI 1.8's pick (clicks, point), set_double_click_frames, focus and
// navigation, rigged and on the GPU (a double click through input); 1.22's snapping (rigged, and the square's corner on the GPU); 1.26's input events (rigged:
// nextEvent, closeWindow, run(onEvent); and on the GPU under the testing hook); 1.28's drafting
// styles (on the GPU, and the pick's viewport label rigged). The
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
private var spyAnimation: [String] = []
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
        spyLabelsIn.append(pick!.pointee.viewport_label)
        pick!.pointee.item = 0
        pick!.pointee.viewport_label = -1
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

/// A pick of nothing, as a library writes one: `viewport_label` -1 (1.28: no label hit) and
/// `segment` UINT32_MAX (1.30: no segment).
private func noPick() -> CadaclysmViewPick {
    var p = CadaclysmViewPick()
    p.viewport_label = -1
    p.segment = UInt32.max
    return p
}
private var spyPicked = noPick()
// The viewport_label each pick buffer handed to pick_result or run held on the way in.
private var spyLabelsIn: [Int32] = []
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
        spyLabelsIn.append(out!.pointee.viewport_label)
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
        spyLabelsIn.append(pick!.pointee.viewport_label)
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

// ---- view ABI 1.22, rigged: what set_snap, request_snap_in and the work plane calls are handed

private var spySnapSettings = CadaclysmViewSnapSettings()
private var spySnap = CadaclysmViewSnap()
// snap_result answers spySnap while spySnapLanded, else false (spySaid says why).
private var spySnapLanded = true
private var spySnapCalls: [String] = []

private func rigSnap(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.last_error = { spySaid }
    t.pointee.set_snap = { _, s in
        spySnapSettings = s!.pointee
        return true
    }
    t.pointee.request_snap_in = { _, viewport, x, y in spySnapCalls.append("snap \(viewport) \(x) \(y)") }
    // spySnap, up to the caller's size as the library writes it.
    t.pointee.snap_result = { _, out in
        if !spySnapLanded { return false }
        var answer = spySnap
        answer.size = out!.pointee.size
        out!.pointee = answer
        return true
    }
    t.pointee.clear_snap = { _ in spySnapCalls.append("clear snap") }
    t.pointee.set_work_plane = { _, o, x, n, step in
        spySnapCalls.append("work plane \(o![0]) \(o![1]) \(o![2]), \(x![0]) \(x![1]) \(x![2]), \(n![0]) \(n![1]) \(n![2]), \(step)")
        return true
    }
    t.pointee.clear_work_plane = { _ in
        spySnapCalls.append("ground plane")
        return true
    }
}

// ---- view ABI 1.30, rigged: what the picking and snapping calls are handed ------------------

private var spyP3: [String] = []
// The segment each pick buffer held on the way into a pick_result that leaves the tail alone.
private var spySegmentsIn: [UInt32] = []
// pick_rect answers how many these are and writes at most its capacity of them.
private var spyRectHits: [CadaclysmViewRectHit] = []

private func rigP3(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.set_snap_base = { _, p, step in
        spyP3.append(p == nil ? "base nil \(step)" : "base \(p![0]) \(p![1]) \(p![2]) \(step)")
        return true
    }
    t.pointee.set_snap_points = { _, _, xyz, count, label in
        let points = xyz.map { p in "\((0..<count * 3).map { p[$0] })" } ?? "nil"
        spyP3.append("points \(count) \(points) \(label.map { String(cString: $0) } ?? "nil")")
        return true
    }
    t.pointee.set_pick_aperture = { _, pt in
        spyP3.append("aperture \(pt)")
        return true
    }
    t.pointee.pick_rect = { _, viewport, x, y, w, h, crossing, out, capacity in
        spyP3.append("rect \(viewport) \(x) \(y) \(w) \(h) \(crossing) cap=\(capacity)")
        if spySaid != nil { return 0 }
        for i in 0..<min(capacity, spyRectHits.count) { out![i] = spyRectHits[i] }
        return spyRectHits.count
    }
}

/// The message of a refusal that is a ViewError; any other error, or none, says so instead.
private func refused(_ body: () throws -> Void) -> String {
    do { try body() } catch let e as ViewError { return "\(e)" } catch { return "not a ViewError: \(error)" }
    return "<accepted>"
}

// ---- view ABI 1.26, rigged: the event queue, close and the pump run(onEvent) drives ----------

// next_event pops spyEvents (empty: false, "no event"); close queues a CLOSE on (1, 2, 3); a pump
// answering CLOSED (spyPumpAnswers, past the list: open) queues a CLOSE on spyEye first;
// pick_result answers spyPicked while spyLanded.
private var spyEvents: [CadaclysmViewInputEvent] = []
private var spyEventSizes: [UInt32] = []
// The pick_segment each next_event buffer held on the way in (1.30).
private var spyEventSegmentsIn: [UInt32] = []
private var spyClosedWindows = 0
private let noEvent = cstr("cadaclysm_view_next_event: no event")
private let noPickResult = cstr("cadaclysm_view_pick_result: no pick result")

/// A raw event of `kind` -- a number the test writes out from the header, never the module's.
private func rawEvent(_ kind: UInt32, _ fill: (inout CadaclysmViewInputEvent) -> Void = { _ in }) -> CadaclysmViewInputEvent {
    var e = CadaclysmViewInputEvent()
    e.kind = kind
    e.pick_viewport_label = -1  // 1.28: no label hit, as a library writes it
    e.pick_segment = UInt32.max  // 1.30: no segment, likewise
    fill(&e)
    return e
}

private func setKey(_ e: inout CadaclysmViewInputEvent, _ key: String) {
    withUnsafeMutableBytes(of: &e.key) { b in for (i, c) in key.utf8.enumerated() { b[i] = c } }
}

private func closeEvent(_ eye: (Float, Float, Float)) -> CadaclysmViewInputEvent {
    rawEvent(10) { e in
        e.camera.eye = eye
        e.camera.target = (0, 0, 0)
        e.camera.up = (0, 0, 1)
    }
}

private func rigEvents(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.last_error = { spySaid }
    t.pointee.next_event = { _, out in
        spyEventSizes.append(out!.pointee.size)
        spyEventSegmentsIn.append(out!.pointee.pick_segment)
        if spyEvents.isEmpty {
            spySaid = noEvent
            return false
        }
        var e = spyEvents.removeFirst()
        e.size = out!.pointee.size
        out!.pointee = e
        spySaid = nil
        return true
    }
    t.pointee.close = { _ in
        spyClosedWindows += 1
        spyEvents.append(closeEvent((1, 2, 3)))
        return true
    }
    t.pointee.pump = { _, ms in
        let call = spyPumpMs.count
        spyPumpMs.append(ms)
        let answer = call < spyPumpAnswers.count ? spyPumpAnswers[call] : UInt32(CADACLYSM_VIEW_OPEN)
        if answer == UInt32(CADACLYSM_VIEW_CLOSED) { spyEvents.append(closeEvent(spyEye)) }
        return answer
    }
    t.pointee.pick_result = { _, out in
        spyLabelsIn.append(out!.pointee.viewport_label)
        if !spyLanded {
            spySaid = noPickResult
            return false
        }
        var answer = spyPicked
        answer.size = out!.pointee.size
        out!.pointee = answer
        return true
    }
}

// ---- view ABI 1.7, rigged: the machining and timeline calls ----------------------------------

/// What show_machining was handed, copied while the pointers were live.
private struct SpyProgram: Equatable {
    var size: UInt32, number: UInt32, shape: UInt32
    var diameter: Double, flute: Double, angle: Double, corner: Double
    var gcode: String
}
private var spyShows = 0
private var spyMachiningSize: UInt32 = 0
private var spyPrograms: [SpyProgram] = []
private var spyStockMin: [Double] = []
private var spyStockMax: [Double] = []
private var spyPartPositions: [Float]? = nil
private var spyPartIndices: [UInt32]? = nil
private var spyPartCounts: [UInt32] = []
private var spyOptions: [Double] = []  // cell, tolerance, skin, rapid_rate
private var spySkinSet: UInt32 = 9
// Every other call logs one line here.
private var spyMachLog: [String] = []
private var spyInfoAnswer = CadaclysmViewMachiningInfo()
private var spyInfoSize: UInt32 = 0
private var spyHeightsCapacity = 0
private var spyHeightsNull = true
private var spyHeightsAnswer: [Float] = []
private var spyTime = 0.0
private var spyDuration = 0.0
private var spyPlaying = false
private var spyStatusAnswers: [String] = []
private var spyStatusCalls = 0
private let spyNoDeviation = cstr("cadaclysm_view_machining_colour_by: deviation needs a part")
private var spyColourRefused = false

private func rigMachining(_ t: UnsafeMutablePointer<CvlTable>) {
    t.pointee.last_error = { spySaid }
    t.pointee.show_machining = { _, m in
        spyShows += 1
        let m = m!.pointee
        spyMachiningSize = m.size
        spyPrograms = (0..<Int(m.program_count)).map { k in
            let p = m.programs![k]
            return SpyProgram(size: p.size, number: p.tool_number, shape: p.tool_shape, diameter: p.tool_diameter,
                              flute: p.tool_flute_length, angle: p.tool_angle, corner: p.tool_corner_radius,
                              gcode: String(cString: p.gcode!))
        }
        spyStockMin = [m.stock_min.0, m.stock_min.1, m.stock_min.2]
        spyStockMax = [m.stock_max.0, m.stock_max.1, m.stock_max.2]
        spyPartPositions = m.part_positions.map { p in (0..<Int(m.part_vertex_count) * 3).map { p[$0] } }
        spyPartIndices = m.part_indices.map { p in (0..<Int(m.part_index_count)).map { p[$0] } }
        spyPartCounts = [m.part_vertex_count, m.part_index_count]
        spyOptions = [m.cell, m.tolerance, m.skin, m.rapid_rate]
        spySkinSet = m.skin_set
        return 17
    }
    t.pointee.machining_seek = { _, item, to in spyMachLog.append("seek \(item) \(to)"); return true }
    t.pointee.machining_colour_by = { _, item, mode in
        spyMachLog.append("colour \(item) \(mode)")
        if spyColourRefused {
            spySaid = spyNoDeviation
            return false
        }
        return true
    }
    t.pointee.machining_overlays = { _, item, path, tool in spyMachLog.append("overlays \(item) \(path) \(tool)"); return true }
    t.pointee.machining_info = { _, item, out in
        spyMachLog.append("info \(item)")
        spyInfoSize = out!.pointee.size
        var answer = spyInfoAnswer
        answer.size = out!.pointee.size
        out!.pointee = answer
        return true
    }
    t.pointee.machining_heights = { _, item, heights, capacity in
        spyMachLog.append("heights \(item)")
        spyHeightsCapacity = capacity
        spyHeightsNull = heights == nil
        if let heights { for (k, z) in spyHeightsAnswer.prefix(capacity).enumerated() { heights[k] = z } }
        return true
    }
    t.pointee.timeline_play = { _, speed in spyMachLog.append("play \(speed)"); return true }
    t.pointee.timeline_pause = { _ in spyMachLog.append("pause"); return true }
    t.pointee.timeline_seek = { _, seconds in spyMachLog.append("seekTime \(seconds)"); return true }
    t.pointee.timeline_set_loop = { _, on in spyMachLog.append("loop \(on)"); return true }
    t.pointee.timeline_time = { _ in spyTime }
    t.pointee.timeline_duration = { _ in spyDuration }
    t.pointee.timeline_playing = { _ in spyPlaying }
    // The current answer's length always; its bytes (cut to the room, NUL-ended) when there is
    // room to put them. The next call answers the next text (the last one repeats).
    t.pointee.timeline_status = { _, text, capacity in
        let answer = Array(spyStatusAnswers[min(spyStatusCalls, spyStatusAnswers.count - 1)].utf8)
        spyStatusCalls += 1
        if let text, capacity > 0 {
            let n = min(answer.count, capacity - 1)
            for k in 0..<n { text[k] = CChar(bitPattern: answer[k]) }
            text[n] = 0
        }
        return answer.count
    }
}

private func resetMachiningSpies() {
    spyShows = 0
    spyMachLog = []
    spyStatusAnswers = [""]
    spyStatusCalls = 0
    spyColourRefused = false
    spySaid = nil
    spyHeightsAnswer = []
    spyHeightsCapacity = -1
    spyHeightsNull = true
    spyInfoSize = 0
    spyInfoAnswer = CadaclysmViewMachiningInfo()
}

/// The plate of web/test/fixtures/machining-plate/job.json: found by walking up from this file.
private struct PlateJob {
    var directory: URL
    var programs: [MachiningProgram]
    var options: MachiningOptions
}
private let boxStock = MachiningStock(min: SIMD3(-42, -27, 0), max: SIMD3(42, 27, 14))

private func plateFixture() -> URL? {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<10 {
        let candidate = dir.appendingPathComponent("web/test/fixtures/machining-plate")
        if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("job.json").path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

/// web/test/machining-selftest.js's rule, as Python's `_compare_at_walls` and Java's: a cell off
/// the oracle's by more than 2e-3 fails, unless it is a wall (the oracle's 3x3 neighbourhood
/// spans more than 0.5 mm) and one of the neighbours is within 2e-3 of it -- excused.
private func compareAtWalls(_ gpu: [Float], _ oracle: [Float], nx: Int, ny: Int) -> (failed: Int, excused: Int, walls: Int) {
    var failed = 0, excused = 0, walls = 0
    for j in 0..<ny {
        for i in 0..<nx {
            var lo = Float.infinity, hi = -Float.infinity
            for b in max(0, j - 1)..<min(ny, j + 2) {
                for a in max(0, i - 1)..<min(nx, i + 2) {
                    lo = min(lo, oracle[b * nx + a])
                    hi = max(hi, oracle[b * nx + a])
                }
            }
            let wall = hi - lo > 0.5
            if wall { walls += 1 }
            let g = gpu[j * nx + i]
            if abs(Double(g - oracle[j * nx + i])) <= 2e-3 { continue }
            var near = false
            if wall {
                for b in max(0, j - 1)..<min(ny, j + 2) {
                    for a in max(0, i - 1)..<min(nx, i + 2) where abs(Double(oracle[b * nx + a] - g)) <= 2e-3 { near = true }
                }
            }
            if near { excused += 1 } else { failed += 1 }
        }
    }
    return (failed, excused, walls)
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

    func testTheSnapStructsAreTheHeaders() {
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnapSettings>.size, 16)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnapSettings>.offset(of: \CadaclysmViewSnapSettings.aperture_px), 8)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.size, 232)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.point), 8)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.item), 32)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.edge), 44)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.tangent), 48)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.axis), 60)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.radius), 72)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.clicks), 84)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.label), 88)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.locked), 120)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.locked_angle), 124)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.guide_count), 128)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.offset(of: \CadaclysmViewSnap.guides), 136)
        XCTAssertEqual(MemoryLayout<CadaclysmViewEventSnap>.size, 88)
        XCTAssertEqual(SnapKind.allCases.map(\.rawValue),
                       [CADACLYSM_VIEW_SNAP_VERTEX, CADACLYSM_VIEW_SNAP_MIDPOINT, CADACLYSM_VIEW_SNAP_CENTRE,
                        CADACLYSM_VIEW_SNAP_QUADRANT, CADACLYSM_VIEW_SNAP_EDGE, CADACLYSM_VIEW_SNAP_FACE,
                        CADACLYSM_VIEW_SNAP_GRID, CADACLYSM_VIEW_SNAP_PLANE, CADACLYSM_VIEW_SNAP_END,
                        CADACLYSM_VIEW_SNAP_INTERSECTION, CADACLYSM_VIEW_SNAP_POINT, CADACLYSM_VIEW_SNAP_ALIGNMENT].map { UInt32($0) })
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
        // 1.21: a material, an opacity and two faces alone (a trim's ghost); a face the cube does
        // not have is refused, named.
        let cube = try Solid.cuboid(1, 1, 1)
        let ghost = try view.showSolid(cube, material: .glass, opacity: 0.5, faces: [0, 1])
        try ghost.remove()
        XCTAssertTrue(message { try view.showSolid(cube, faces: [99]) }.contains("face 99 is not one of the solid's 6 faces"))
        try view.frame()
        let drawn = try view.image()
        XCTAssertNotEqual(pixel(drawn, 160, 120), pixel(empty, 160, 120), "nothing drawn at the centre")
        XCTAssertEqual(pixel(drawn, 1, 1), pixel(empty, 1, 1), "a corner outside the sphere changed")
        let pick = try view.pick(x: 160, y: 120)
        XCTAssertEqual(pick?.item, item?.id)
        // 1.16's user layers: the sphere on layer 3, the layer off (the centre no longer the
        // sphere's) and on again (the sphere's again); layer 32 refused, for an item and the view.
        if let item {
            try item.setUserLayer(3)
            try view.setUserLayer(3, false)
            XCTAssertNotEqual(pixel(try view.image(), 160, 120), pixel(drawn, 160, 120), "an item on a layer switched off drew")
            try view.setUserLayer(3, true)
            XCTAssertEqual(pixel(try view.image(), 160, 120), pixel(drawn, 160, 120), "an item on a layer switched on again did not draw")
            XCTAssertTrue(message { try item.setUserLayer(32) }.contains("past 31"), message { try item.setUserLayer(32) })
            XCTAssertTrue(message { try view.setUserLayer(32, false) }.contains("past 31"), message { try view.setUserLayer(32, false) })
            try item.setUserLayer(0)
        }
        XCTAssertEqual(View.Viewport(rect: SIMD4(0, 0, 1, 1), view: [], projection: [], eye: SIMD3(0, 0, 0)).layerMask, 0xFFFF_FFFF)
        let png = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try view.save(png.path)
        let bytes = try Data(contentsOf: png)
        try? FileManager.default.removeItem(at: png)
        XCTAssertEqual(Array(bytes.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])

        // Master's three: levels on and off, the wake answer; node transforms refused on a solid.
        try view.setLod("smooth")
        _ = try view.wakeMs()
        try view.setLod(nil)
        XCTAssertTrue(message { try view.setLod("sharp") }.contains("one of detailed, smooth"))
        XCTAssertFalse(message { try item?.setNodeTransforms([]) } == "<accepted>", "node transforms on a solid were accepted")
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
        XCTAssertEqual(message { try item?.setPlacement([1, 0]) }, "16 numbers, not 2")
        XCTAssertEqual(message { try item?.setNodeTransforms([[1]]) }, "transform 0: 16 numbers, not 1")
        XCTAssertEqual(message { try item?.setFaceColours([1, 2], [SIMD4<Float>(1, 0, 0, 1)]) }, "8 numbers (rgba, 4 a face), not 4")
        // An empty list clears: it reaches the library as an empty array, not "none".
        try item?.setFaceColours([], [])
        // Empty lines and curves are accepted (a non-NULL empty array); a mesh and an image draw.
        try view.showLines([]).remove()
        try view.showCurves([]).remove()
        try view.showMesh(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1, 2], rgb: SIMD3<Float>(0, 1, 0)).remove()
        try view.showImage(corners: [0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0], rgba: [255, 0, 0, 255], width: 1, height: 1).remove()
        // Two points on the real library: an item.
        let twoPoints = try view.showPoints([0, 0, 0, 1, 1, 1], rgb: "red")
        XCTAssertNotEqual(twoPoints.id, 0, "two points: no item")
        try twoPoints.remove()
        try item?.setPlacement([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        try item?.setPlacement(nil)
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
        XCTAssertEqual(message { try late.setColour(SIMD3<Float>(1, 0, 0)) }, "cadaclysm_view_set_colour: the view is closed")
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
        try shown.setNodeTransforms(scene.nodes.map { pose.rawTransform($0) })
        XCTAssertGreaterThan(changed(rest, try view.image()), 0, "the pose moved nothing on screen")
        try shown.setNodeTransforms(nil)
        let back = changed(rest, try view.image())
        XCTAssertLessThan(back, 320 * 240 / 1000, "nil did not put the rest pose back: \(back) pixels")
        let none = message { try shown.setNodeTransforms([]) }
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
        XCTAssertNotEqual(message { try all.setColour(SIMD3<Float>(1, 0, 0)) }, "<accepted>", "an item of a closed scene is still shown")
        XCTAssertNotEqual(message { try part.setColour(SIMD3<Float>(1, 0, 0)) }, "<accepted>", "a node item of a closed scene is still shown")
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
        XCTAssertEqual(message { try view.setOrthographic(false) }, "boom from the library")
        XCTAssertEqual(message { try view.setBackground(SIMD3<Float>(0, 0, 0)) }, "boom from the library")
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
        spyLabelsIn = []
        try cube.show()
        XCTAssertEqual(spyRuns, 1)
        XCTAssertEqual(spyLabelsIn, [-1], "show()'s pick buffer reaches run with viewport_label -1")
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

    /// 1.20's occluded style: set and read back with a colour, nil restores the defaults.
    func testOccludedStyleRoundTrips() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        XCTAssertEqual(try view.occludedStyle(), OccludedStyle())
        try view.setOccludedStyle(OccludedStyle(dash: 10, gap: 5, dim: 0.25, colour: SIMD3(0.5, 0.5, 0.5)))
        XCTAssertEqual(try view.occludedStyle(), OccludedStyle(dash: 10, gap: 5, dim: 0.25, colour: SIMD3(0.5, 0.5, 0.5)))
        XCTAssertFalse(message { try view.setOccludedStyle(OccludedStyle(dash: -1)) }.isEmpty)
        XCTAssertEqual(try view.occludedStyle().dash, 10, "a refused style changed the view")
        try view.setOccludedStyle(nil)
        XCTAssertEqual(try view.occludedStyle(), OccludedStyle())
    }

    /// 1.31's clip planes: a capped, hatched plane read back with its normal made unit length,
    /// a plain one with the defaults, a refusal that changes nothing, a clear.
    func testClipPlanesRoundTrip() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        XCTAssertEqual(View.clipPlanes, 6)
        XCTAssertNil(try view.clipPlane(0), "a new view's slot 0")
        try view.setClipPlane(0, point: SIMD3(1, 2, 3), normal: SIMD3(0, 0, 2), cap: SIMD3(1, 0, 0),
                              hatch: SIMD3(0, 0, 0), hatchAngle: 30, hatchSpacing: 0.5, hatchWidth: 2)
        XCTAssertEqual(try view.clipPlane(0),
                       ClipPlane(point: SIMD3(1, 2, 3), normal: SIMD3(0, 0, 1), cap: SIMD3(1, 0, 0),
                                 hatch: SIMD3(0, 0, 0), hatchAngle: 30, hatchSpacing: 0.5, hatchWidth: 2))
        let plain = ClipPlane(point: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0))
        try view.setClipPlane(5, plain)
        XCTAssertEqual(try view.clipPlane(5), plain, "the defaults")
        let refused = message { try view.setClipPlane(5, point: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0), hatch: SIMD3(0, 0, 0)) }
        XCTAssertTrue(refused.contains("cadaclysm_view_set_clip_plane") && refused.contains("hatch"), refused)
        XCTAssertEqual(try view.clipPlane(5), plain, "a refused plane changed slot 5")
        XCTAssertTrue(message { try view.setClipPlane(6, plain) }.contains("slot 6"))
        XCTAssertNotEqual(message { _ = try view.clipPlane(6) }, "<accepted>")
        try view.clearClipPlane(0)
        XCTAssertNil(try view.clipPlane(0), "a cleared slot 0")
        try view.clearClipPlane(0)
    }

    /// 1.32's clip sets: an outlined plane read back (width 0 as 1), an outline width above 100
    /// refused, the mode pair (mode 2 refused view-wide), viewport 0's own plane round trip, and
    /// inherit dropping it.
    func testClipSetsRoundTrip() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        XCTAssertEqual(View.clipViewports, 8)
        XCTAssertEqual(ClipMode.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(MemoryLayout<CadaclysmViewClipPlane>.size, 120)
        try view.setClipPlane(0, point: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1), cap: SIMD3(0.5, 0.5, 0.5),
                              outline: SIMD3(1, 0, 0), outlineWidth: 0)
        XCTAssertEqual(try view.clipPlane(0),
                       ClipPlane(point: SIMD3(0, 0, 1), normal: SIMD3(0, 0, 1), cap: SIMD3(0.5, 0.5, 0.5),
                                 outline: SIMD3(1, 0, 0), outlineWidth: 1))
        let plain = ClipPlane(point: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0))
        try view.setClipPlane(1, plain)
        XCTAssertEqual(try view.clipPlane(1), plain, "no outline")
        XCTAssertEqual(message { try view.setClipPlane(2, point: SIMD3(0, 0, 0), normal: SIMD3(1, 0, 0),
                                                       outline: SIMD3(0, 0, 0), outlineWidth: 200) },
                       "cadaclysm_view_set_clip_plane: outline width 200 is above 100 points")
        XCTAssertEqual(try view.clipMode(), .intersection)
        try view.setClipMode(.cutaway)
        XCTAssertEqual(try view.clipMode(), .cutaway)
        XCTAssertEqual(message { try view.setClipMode(.inherit) },
                       "cadaclysm_view_set_clip_mode: mode 2 (inherit) is a viewport's")
        XCTAssertEqual(try view.clipMode(), .cutaway, "a refused mode changed the mode")
        try view.setClipMode(.intersection)
        // Viewport 0 (the window: no viewports set) given a plane of its own.
        XCTAssertEqual(try view.viewportClipMode(0), .inherit)
        XCTAssertNil(try view.viewportClipPlane(0, 0), "viewport 0 with no set of its own")
        try view.setViewportClipPlane(0, 4, point: SIMD3(0, 0, 0), normal: SIMD3(0, 3, 0), cap: SIMD3(0, 0, 1),
                                      outline: SIMD3(1, 1, 1), outlineWidth: 2)
        XCTAssertEqual(try view.viewportClipPlane(0, 4),
                       ClipPlane(point: SIMD3(0, 0, 0), normal: SIMD3(0, 1, 0), cap: SIMD3(0, 0, 1),
                                 outline: SIMD3(1, 1, 1), outlineWidth: 2))
        XCTAssertNil(try view.viewportClipPlane(0, 0), "viewport 0's empty slot 0")
        XCTAssertEqual(try view.viewportClipMode(0), .intersection)
        try view.setViewportClipMode(0, .cutaway)
        XCTAssertEqual(try view.viewportClipMode(0), .cutaway)
        XCTAssertEqual(message { try view.setViewportClipPlane(1, 0, plain) },
                       "cadaclysm_view_set_viewport_clip_plane: no viewport 1 (there are 1)")
        XCTAssertNotEqual(message { _ = try view.viewportClipPlane(0, 6) }, "<accepted>")
        try view.clearViewportClipPlane(0, 4)
        XCTAssertNil(try view.viewportClipPlane(0, 4), "viewport 0's cleared slot 4")
        XCTAssertEqual(try view.viewportClipMode(0), .cutaway, "clearing a plane dropped the set")
        try view.setViewportClipPlane(0, 4, plain)
        try view.setViewportClipMode(0, .inherit)
        XCTAssertEqual(try view.viewportClipMode(0), .inherit)
        XCTAssertNil(try view.viewportClipPlane(0, 4), "viewport 0's slot 4 after inherit")
    }

    /// 1.23's line colours: a view-wide colour read back, a segment's own curve colour drawn
    /// and cleared with nil.
    func testLineColoursDrawAndClear() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        XCTAssertTrue(try view.curveColour().fromPart, "curves follow their part by default")
        try view.setIsocurveColour("#00ff00", fromPart: true)
        XCTAssertEqual(try view.isocurveColour(), LineColour(colour: SIMD3(0, 1, 0), fromPart: true))
        try view.setEdgeColour("#202020")
        XCTAssertFalse(try view.edgeColour().fromPart)
        let line = try view.showLines([-0.8, 0, 0, 0.8, 0, 0], rgb: "red")
        try view.standard("top")
        try line.frame()
        func greens() throws -> Int {
            let px = try view.image().rgba
            var n = 0
            for k in stride(from: 0, to: px.count, by: 4) where px[k + 1] > 150 && px[k] < 100 && px[k + 2] < 100 { n += 1 }
            return n
        }
        XCTAssertEqual(try greens(), 0, "red first")
        try line.setCurveColour("lime")
        XCTAssertGreaterThan(try greens(), 0, "the segment green")
        try line.setCurveColour(nil)
        XCTAssertEqual(try greens(), 0, "nil: the view's colour again")
    }

    /// The loader binds 136 calls of cadaclysm_view.h 1.33 (all but 1.14's analysis calls,
    /// 1.19's KMS pair and 1.12's texture targets): a 1.32 library (no textures switch) is
    /// refused before any call is bound, in Python's words; 1.33 and later 1.x are taken.
    func testTheLoaderNeedsViewABI133() throws {
        try checkABIForTest(version: 0x10021, path: "lib")
        try checkABIForTest(version: 0x10022, path: "lib")
        XCTAssertEqual(message { try checkABIForTest(version: 0x10020, path: "lib") },
                       "lib: view ABI 1.32, this SDK needs 1.33 or a later 1.x")
        XCTAssertEqual(message { try checkABIForTest(version: 0x10019, path: "lib") },
                       "lib: view ABI 1.25, this SDK needs 1.33 or a later 1.x")
        XCTAssertEqual(message { try checkABIForTest(version: 0x20021, path: "lib") },
                       "lib: view ABI 2.33, this SDK needs 1.33 or a later 1.x")
    }

    /// 1.33's textures switch on wgpu offscreen: on by default, off once set off, on again.
    func testTexturesDefaultOnAndReadBackOff() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        XCTAssertTrue(try view.textures(), "on by default")
        try view.setTextures(false)
        XCTAssertFalse(try view.textures(), "off once set off")
        try view.setTextures(true)
        XCTAssertTrue(try view.textures(), "on again")
    }

    /// 1.25's stats on wgpu offscreen: the struct's layout; an offscreen view's frames are its
    /// images, each counted once with its CPU time, triangles and draw calls.
    func testStatsCountTheFramesDrawn() throws {
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.size, 40)
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.offset(of: \CadaclysmViewStats.frames_drawn), 8)
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.offset(of: \CadaclysmViewStats.last_frame_ms), 16)
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.offset(of: \CadaclysmViewStats.last_gpu_ms), 20)
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.offset(of: \CadaclysmViewStats.triangles), 24)
        XCTAssertEqual(MemoryLayout<CadaclysmViewStats>.offset(of: \CadaclysmViewStats.draw_calls), 32)
        let sv = try offscreen(64, 48)
        defer { try? sv.close() }
        var s = try sv.stats()
        XCTAssertEqual(s.framesDrawn, 0)
        XCTAssertEqual(s.triangles, 0)
        _ = try sv.showSolid(try Solid.cuboid(20, 20, 20), tolerance: 0.05, rgb: "#808080")
        try sv.draw()
        XCTAssertEqual(try sv.stats().framesDrawn, 0, "an offscreen draw renders nothing")
        _ = try sv.image()
        s = try sv.stats()
        XCTAssertEqual(s.framesDrawn, 1)
        XCTAssertGreaterThan(s.lastFrameMs, 0)
        XCTAssertGreaterThanOrEqual(s.triangles, 12)
        XCTAssertGreaterThanOrEqual(s.drawCalls, 1)
        XCTAssertTrue(s.lastGpuMs == -1 || (s.lastGpuMs >= 0 && s.lastGpuMs < 1000), "the GPU time: \(s.lastGpuMs)")
        _ = try sv.image()
        XCTAssertEqual(try sv.stats().framesDrawn, 2, "each image counts")
    }

    /// The anchors are the header's ALIGN codes, in its order.
    func testTheAnchorsAreTheHeadersAlignCodes() {
        let header: [UInt32] = [UInt32(CADACLYSM_VIEW_ALIGN_TOP_LEFT), UInt32(CADACLYSM_VIEW_ALIGN_TOP),
                                UInt32(CADACLYSM_VIEW_ALIGN_TOP_RIGHT), UInt32(CADACLYSM_VIEW_ALIGN_LEFT),
                                UInt32(CADACLYSM_VIEW_ALIGN_CENTRE), UInt32(CADACLYSM_VIEW_ALIGN_RIGHT),
                                UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM_LEFT), UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM),
                                UInt32(CADACLYSM_VIEW_ALIGN_BOTTOM_RIGHT)]
        let ours: [Anchor] = [.topLeft, .top, .topRight, .left, .centre, .right, .bottomLeft, .bottom, .bottomRight]
        XCTAssertEqual(ours.map { $0.rawValue }, header)
        XCTAssertEqual(MemoryLayout<CadaclysmViewPick>.size, 52)
        XCTAssertEqual(MemoryLayout<CadaclysmViewOverlay>.size, 80)
        XCTAssertEqual(MemoryLayout<CadaclysmViewOverlayImage>.size, 48)
    }

    /// 1.24's overlays on wgpu offscreen: a holed panel at the centre (its hole picks the part
    /// beneath), a stroked crosshair, text at the top right, an image moved from the bottom left
    /// to the bottom right, order, an outline, a removed overlay, and the refusals.
    func testOverlaysDrawPickAndMove() throws {
        let ov = try offscreen(200, 120)
        defer { try? ov.close() }
        try ov.setBackground("black")
        let under = try ov.showSolid(try Solid.cuboid(80, 80, 20), tolerance: 0.05, rgb: "#808080")
        try ov.standard("top")
        try ov.frame()
        func px(_ img: ViewImage, _ x: Int, _ y: Int) -> [Int] {
            let i = (y * Int(img.width) + x) * 4
            return [Int(img.rgba[i]), Int(img.rgba[i + 1]), Int(img.rgba[i + 2])]
        }
        func isAt(_ img: ViewImage, _ x: Int, _ y: Int, _ r: Int, _ g: Int, _ b: Int) -> Bool {
            let p = px(img, x, y)
            return abs(p[0] - r) < 40 && abs(p[1] - g) < 40 && abs(p[2] - b) < 40
        }
        // A rounded panel with a round hole, filled red (an outline by default), at the window's centre.
        let shape = try Profile.rect(60, 40).round(6).withHole(try Profile.circle(8)).coloured("red")
        let panel = try ov.showOverlay(shape, anchor: .centre, x: 0, y: 0, style: OverlayStyle(fill: "red"))
        var img = try ov.image()
        XCTAssertTrue(isAt(img, 120, 60, 255, 0, 0), "the panel red right of its hole: \(px(img, 120, 60))")
        XCTAssertFalse(isAt(img, 100, 60, 255, 0, 0), "the hole is filled")
        let onPanel = try ov.pick(x: 120, y: 60)
        XCTAssertTrue(onPanel?.overlay == true && onPanel?.point == nil && onPanel?.item == panel.id, "a pick on the panel: \(String(describing: onPanel))")
        let inHole = try ov.pick(x: 100, y: 60)
        XCTAssertTrue(inHole?.overlay == false && inHole?.item == under.id, "a pick in the hole reaches the part: \(String(describing: inHole))")
        // A stroked crosshair of two open profiles, 20 px in from the top left.
        let across = try Profile.polyline([SIMD2(-8, 0), SIMD2(8, 0)])
        let down = try Profile.polyline([SIMD2(0, -8), SIMD2(0, 8)])
        let cross = try ov.showOverlay([across, down], anchor: .topLeft, x: 20, y: 20, style: OverlayStyle(stroke: "lime", strokeWidth: 2))
        img = try ov.image()
        XCTAssertTrue(isAt(img, 20, 20, 0, 255, 0) && isAt(img, 26, 20, 0, 255, 0) && isAt(img, 20, 14, 0, 255, 0),
                      "the crosshair's arms: \(px(img, 20, 20)) \(px(img, 26, 20)) \(px(img, 20, 14))")
        XCTAssertFalse(isAt(img, 25, 25, 0, 255, 0), "between the arms")
        let c = try ov.pick(x: 26, y: 21)
        XCTAssertTrue(c?.overlay == true && c?.item == cross.id, "a pick on the crosshair")
        // Text at the top right, its box's corner 4 px in; setText changes it.
        let fps = try ov.showOverlayText("FPS 60", anchor: .topRight, x: 4, y: 4, size: 14, colour: "white", box: "blue")
        img = try ov.image()
        XCTAssertTrue(isAt(img, 194, 6, 0, 0, 255) && !isAt(img, 197, 2, 0, 0, 255),
                      "the text's box hangs from the top-right corner: \(px(img, 194, 6)) \(px(img, 197, 2))")
        try fps.setText("FPS 120")
        let tp = try ov.pick(x: 194, y: 6)
        XCTAssertTrue(tp?.overlay == true && tp?.item == fps.id, "a pick on the text")
        // An image, 2 x 2 yellow pixels drawn 10 x 10, at the bottom left; moved to the bottom right.
        let yellow = [UInt8]([255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255, 255, 255, 0, 255])
        let pic = try ov.showOverlayImage(yellow, width: 2, height: 2, anchor: .bottomLeft, x: 4, y: 4, drawWidth: 10, drawHeight: 10)
        img = try ov.image()
        XCTAssertTrue(isAt(img, 8, 110, 255, 255, 0), "the image at the bottom left: \(px(img, 8, 110))")
        try pic.moveTo(.bottomRight, x: 4, y: 4)
        img = try ov.image()
        XCTAssertTrue(pic.anchor == .bottomRight && isAt(img, 190, 110, 255, 255, 0) && !isAt(img, 8, 110, 255, 255, 0),
                      "moved to the bottom right: \(px(img, 190, 110)) \(px(img, 8, 110))")
        try pic.moveTo(x: 6, y: 6)
        img = try ov.image()
        XCTAssertTrue(isAt(img, 188, 108, 255, 255, 0), "moved, the anchor kept: \(px(img, 188, 108))")
        // Order: a green square of order 1 shown first stays over a later blue one of order 0.
        let sq = try Profile.rect(20, 20)
        try ov.showOverlay(sq, anchor: .bottomLeft, x: 60, y: 30, style: OverlayStyle(fill: "lime", order: 1))
        try ov.showOverlay(sq, anchor: .bottomLeft, x: 65, y: 30, style: OverlayStyle(fill: "blue"))
        img = try ov.image()
        XCTAssertTrue(isAt(img, 63, 90, 0, 255, 0), "order 1 over order 0: \(px(img, 63, 90))")
        // An outline only: "none" fills nothing.
        let outline = try ov.showOverlay(sq, anchor: .top, x: 0, y: 30, style: OverlayStyle(fill: "none", stroke: "white", strokeWidth: 2))
        img = try ov.image()
        XCTAssertTrue(isAt(img, 110, 30, 255, 255, 255) && !isAt(img, 100, 30, 255, 255, 255),
                      "an outline, its inside not filled: \(px(img, 110, 30)) \(px(img, 100, 30))")
        // Removed: gone, and the part is picked there again.
        try panel.remove()
        img = try ov.image()
        XCTAssertFalse(isAt(img, 120, 60, 255, 0, 0), "a removed overlay draws")
        XCTAssertEqual(try ov.pick(x: 120, y: 60)?.overlay, false, "a removed overlay is picked")
        try outline.remove()
        XCTAssertTrue(message { _ = try ov.showOverlay(curves: [Float](repeating: 0, count: 15), anchor: .topLeft, x: 0, y: 0) }
                        .hasPrefix("show_overlay: 16 numbers a curve"))
        XCTAssertTrue(message { try cross.moveTo(x: .nan, y: 0) }.contains("finite"), message { try cross.moveTo(x: .nan, y: 0) })
        XCTAssertTrue(message { _ = try ov.showOverlayImage(yellow, width: 3, height: 2, anchor: .topLeft, x: 0, y: 0) }
                        .hasPrefix("show_overlay_image: 3 x 2 pixels need 24 bytes"))
    }

    /// A profile is a sketch: with no style it is stroked -- in its own colour, else white -- and
    /// not filled; a fill draws only where given; fill only is a fill and stroke "none"; neither
    /// is refused.
    func testAnOverlayProfileDrawsAsItsOutlineByDefault() throws {
        let ov = try offscreen(120, 80)
        defer { try? ov.close() }
        try ov.setBackground("black")
        let square = try Profile.rect(40, 40)   // x 40..80, y 20..60 at the window's centre
        func px(_ img: ViewImage, _ x: Int) -> [Int] {
            let i = (40 * Int(img.width) + x) * 4
            return [Int(img.rgba[i]), Int(img.rgba[i + 1]), Int(img.rgba[i + 2])]
        }
        // Any pixel of row 40 from x0 to x1 passing ok: a 1 px stroke on the right edge (x 80)
        // may fall across two columns.
        func edge(_ img: ViewImage, _ x0: Int, _ x1: Int, _ ok: ([Int]) -> Bool) -> Bool { (x0...x1).contains { ok(px(img, $0)) } }
        let white: ([Int]) -> Bool = { $0.allSatisfy { $0 > 100 } }
        let red: ([Int]) -> Bool = { $0[0] > 100 && $0[1] < 60 && $0[2] < 60 }
        let dark: ([Int]) -> Bool = { $0.allSatisfy { $0 < 40 } }
        // (a) No style: a white edge, an unfilled inside.
        var o = try ov.showOverlay(square, anchor: .centre, x: 0, y: 0)
        var img = try ov.image()
        XCTAssertTrue(edge(img, 78, 82, white), "no style: the edge is stroked white: \(px(img, 79)) \(px(img, 80))")
        XCTAssertTrue(dark(px(img, 60)), "no style: the inside is not filled: \(px(img, 60))")
        try o.remove()
        // (b) A coloured profile: stroked in its colour, still not filled.
        o = try ov.showOverlay(try square.coloured("red"), anchor: .centre, x: 0, y: 0)
        img = try ov.image()
        XCTAssertTrue(edge(img, 78, 82, red) && !edge(img, 78, 82, white), "a coloured profile strokes in its colour: \(px(img, 79)) \(px(img, 80))")
        XCTAssertTrue(dark(px(img, 60)), "a coloured profile is not filled: \(px(img, 60))")
        try o.remove()
        // (c) Fill only: a fill and stroke "none".
        o = try ov.showOverlay(square, anchor: .centre, x: 0, y: 0, style: OverlayStyle(fill: "lime", stroke: "none"))
        img = try ov.image()
        let inside = px(img, 60)
        XCTAssertTrue(inside[1] > 200 && inside[0] < 60 && inside[2] < 60, "fill only: the inside is lime: \(inside)")
        XCTAssertFalse(edge(img, 76, 84) { $0[0] > 60 || $0[2] > 60 }, "fill only: no stroke on the edge")
        try o.remove()
        // Raw Beziers have no colour of their own: white.
        o = try ov.showOverlay(curves: try square.beziers().map { Float($0) }, anchor: .centre, x: 0, y: 0)
        img = try ov.image()
        XCTAssertTrue(edge(img, 78, 82, white) && dark(px(img, 60)), "raw Beziers: stroked white, not filled")
        try o.remove()
        // (d) Neither a fill nor a stroke: refused.
        XCTAssertEqual(message { _ = try ov.showOverlay(square, anchor: .centre, x: 0, y: 0, style: OverlayStyle(fill: "none", stroke: "none")) },
                       "show_overlay: neither a fill nor a stroke")
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
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        if text { try view.setBackground("#ff0") } else { try view.setBackground(SIMD3<Float>(1, 1, 0)) }
        let square: [Float] = [-4, -1, 0, -2, -1, 0, -2, 1, 0, -4, 1, 0]
        let triangles: [UInt32] = [0, 1, 2, 0, 2, 3]
        _ = try view.showMesh(positions: square, indices: triangles, rgb: pick("Red", SIMD3<Float>(1, 0, 0)))
        var lifted = square
        for i in stride(from: 1, to: lifted.count, by: 3) { lifted[i] += 2.5 }
        try view.showMesh(positions: lifted, indices: triangles).setColour(pick("#00f", SIMD3<Float>(0, 0, 1)))
        let cube = try Solid.cuboid(2, 2, 2)
        let solid = try view.showSolid(cube, rgb: pick("LIME", SIMD3<Float>(0, 1, 0)))
        if text {
            try solid.setFaceColours([0, 1], ["00ff80", "black"])
        } else {
            try solid.setFaceColours([0, 1], [SIMD4<Float>(0, 1, 128 / 255, 1), SIMD4<Float>(0, 0, 0, 1)])
        }
        _ = try view.showLines([3, 0, 0, 5, 2, 2], rgb: pick("#ffffff", SIMD3<Float>(1, 1, 1)))
        _ = try view.showCurves([3, -2, 0, 1, 4, -1, 0, 1, 5, -2, 1, 1, 6, -1, 0, 1],
                                rgb: pick("purple", SIMD3<Float>(128 / 255, 0, 128 / 255)))
        if let scene {
            let whole = try view.showScene(scene)
            try whole.setNodeColour(0, pick("white", SIMD4<Float>(1, 1, 1, 1)))
            try whole.setNodeHighlight(0, pick("#f00", SIMD4<Float>(1, 0, 0, 1)))
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
            XCTAssertEqual(message { try square.setColour(bad) },
                           "cadaclysm_view_parse_colour: colour: \"#rgb\", \"#rrggbb\" or a CSS colour name, not '\(bad)'")
        }
        let cube = try Solid.cuboid(1, 1, 1)
        let refusals: [(String, () throws -> Void)] = [
            ("background", { try view.setBackground("nope") }),
            ("showLines", { _ = try view.showLines([0, 0, 0, 1, 1, 1], rgb: "nope") }),
            ("showCurves", { _ = try view.showCurves([Float](repeating: 0, count: 16), rgb: "nope") }),
            ("showMesh", { _ = try view.showMesh(positions: [Float](repeating: 0, count: 9), indices: [0, 1, 2], rgb: "nope") }),
            ("showSolid", { _ = try view.showSolid(cube, rgb: "nope") }),
            ("faceColours", { try square.setFaceColours([0], ["nope"]) }),
            ("nodeColour", { try square.setNodeColour(0, "nope") }),
            ("nodeHighlight", { try square.setNodeHighlight(0, "nope") }),
        ]
        for (what, call) in refusals {
            XCTAssertTrue(message(call).hasSuffix("not 'nope'"), "\(what): \(message(call))")
        }
        // Not a colour the module reads: refused in its own words.
        XCTAssertEqual(message { try square.setColour([Float](repeating: 0, count: 2)) }, "colour: 3 or 4 numbers, not 2")
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
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
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
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_TEXT), false)
        XCTAssertEqual(changed(try view.image(), blank), 0, "the text layer off still draws text")
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_TEXT), true)
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
            try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
            try view.setBackground("black")
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

    /// 1.28's drafting styles on wgpu offscreen: a dashed line on top, hollow diamond points
    /// with states, the state colours, a viewport's border and its label, which picks as
    /// viewport 0 with item 0; the refusals.
    func testDraftingStyles() throws {
        let v = try offscreen(64, 48)
        defer { try? v.close() }
        let line = try v.showLines([-1, 0, 0, 1, 0, 0])
        try line.setLineStyle(dash: 6, gap: 4)
        XCTAssertThrowsError(try line.setLineStyle(dash: 6, gap: 0))
        try line.setOnTop()
        let pts = try v.showPoints([0, 0, 0, 1, 0, 0], sizePx: 9)
        try pts.setPointStyle(.diamond, hollow: true)
        try pts.setPointStates([.first, .hover])
        XCTAssertThrowsError(try pts.setPointStates([.hover]))
        try v.setPointStateColours(hover: SIMD3<Float>(1, 0, 0), selected: "red", first: "#378add")
        try v.setViewportBorder(0, colour: SIMD3<Float>(1, 0, 0))
        try v.setViewportLabel(0, text: "FRONT", colour: "red")
        var found = false
        for (x, y) in [(8, 8), (10, 10), (12, 8), (9, 12), (14, 10), (7, 6)] as [(UInt32, UInt32)] where !found {
            if let p = try v.pick(x: x, y: y), p.viewportLabel == 0, p.item == 0 { found = true }
        }
        XCTAssertTrue(found, "the label picks as viewport 0")
        // The enums' raw values against the header's own constants.
        XCTAssertEqual(PointShape.allCases.map(\.rawValue), [CADACLYSM_VIEW_POINT_DISC, CADACLYSM_VIEW_POINT_RING, CADACLYSM_VIEW_POINT_SQUARE, CADACLYSM_VIEW_POINT_DIAMOND].map { UInt32($0) })
        XCTAssertEqual(PointState.allCases.map(\.rawValue), [CADACLYSM_VIEW_POINT_STATE_NORMAL, CADACLYSM_VIEW_POINT_STATE_HOVER, CADACLYSM_VIEW_POINT_STATE_SELECTED, CADACLYSM_VIEW_POINT_STATE_FIRST].map { UInt8($0) })
        XCTAssertThrowsError(try v.setViewportBorder(3, colour: SIMD3<Float>(1, 0, 0)))
        // Text colours are taken (the library's own parser), and a name it does not know refused.
        try v.setViewportBorder(0, colour: "red")
        XCTAssertThrowsError(try v.setViewportLabel(0, text: "FRONT", colour: "notacolour"))
        // Cleared again: nil text and nil colour are taken.
        try v.setViewportLabel(0, text: nil)
        try v.setViewportBorder(0, colour: nil)
        try v.setPointStateColours()
        try line.setOnTop(false)
        try line.setLineStyle()
        // A colour of the wrong length is refused before the library reads past it.
        XCTAssertEqual(message { try v.setViewportBorder(0, colour: [Float]([1, 0])) }, "colour: 3 or 4 numbers, not 2")
    }

    /// 1.29's live geometry on wgpu offscreen: each setter replaces its item's data under the
    /// same id; the count refusals read the library's words; glyphs pick as their node (on a
    /// small view of their own, so no shape at the origin hides them); the kinds' raw values
    /// are the header's CADACLYSM_VIEW_GLYPH_* numbers.
    func testLiveGeometryAndGlyphs() throws {
        XCTAssertEqual(GlyphKind.allCases.map(\.rawValue),
                       [CADACLYSM_VIEW_GLYPH_ARROW, CADACLYSM_VIEW_GLYPH_TICK, CADACLYSM_VIEW_GLYPH_CROSS,
                        CADACLYSM_VIEW_GLYPH_SQUARE, CADACLYSM_VIEW_GLYPH_TRIANGLE, CADACLYSM_VIEW_GLYPH_PARALLEL,
                        CADACLYSM_VIEW_GLYPH_PERPENDICULAR, CADACLYSM_VIEW_GLYPH_COINCIDENT, CADACLYSM_VIEW_GLYPH_TANGENT,
                        CADACLYSM_VIEW_GLYPH_FIXED, CADACLYSM_VIEW_GLYPH_HORIZONTAL, CADACLYSM_VIEW_GLYPH_VERTICAL].map { UInt32($0) })
        XCTAssertEqual(GlyphKind.cross.rawValue, UInt32(CADACLYSM_VIEW_GLYPH_CROSS))
        let v = try offscreen(64, 48)
        defer { try? v.close() }
        let line = try v.showLines([-1, 0, 0, 1, 0, 0])
        try line.setLines([-1, 1, 0, 1, 1, 0, -1, -1, 0, 1, -1, 0])
        try line.setLines([])
        let curve = try v.showCurves([0, 0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 1, 3, 0, 0, 1])
        try curve.setCurves([0, 1, 0, 1, 1, 1, 0, 1, 2, 1, 0, 1, 3, 1, 0, 1])
        XCTAssertTrue(message { try line.setCurves([0, 0, 0, 1, 1, 0, 0, 1, 2, 0, 0, 1, 3, 0, 0, 1]) }.contains("is not a curves item"))
        let pts = try v.showPoints([0, 0, 0, 1, 0, 0], sizePx: 9)
        try pts.setPoints([0, 1, 0, 1, 1, 0])
        let mesh = try v.showMesh(positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0], indices: [0, 1, 2])
        try mesh.setMeshPositions([-1, -1, 1, 1, -1, 1, 0, 1, 1])
        try mesh.setMeshPositions([-1, -1, 0, 1, -1, 0, 0, 1, 0], normals: [0, 0, 1, 0, 0, 1, 0, 0, 1])
        // The count refusals, in the library's words and the wrapper's.
        XCTAssertTrue(message { try mesh.setMeshPositions([0, 0, 0, 1, 0, 0]) }.contains("positions has 2 vertices; item"))
        XCTAssertTrue(message { try mesh.setMeshPositions([-1, -1, 0, 1, -1, 0, 0, 1, 0], normals: [0, 0, 1]) }.contains("normal numbers"))
        XCTAssertThrowsError(try line.setLines([0, 0, 0, 1]))
        try pts.setPointStates([.selected, .normal])
        try pts.setPoints([0, 0, 0])  // a new count keeps the states by index
        try pts.setPointStates([.selected])
        XCTAssertThrowsError(try v.showGlyphs([0, 0, 0], kind: .tick, sizePt: 500))
        XCTAssertThrowsError(try v.showGlyphs([0, 0, 0, 1, 0, 0], kind: .arrow, dir: [1, 0, 0]))
        // Glyphs pick as their node, on a small view of their own.
        let g = try offscreen(96, 96)
        defer { try? g.close() }
        _ = try g.showGlyphs([0, 0, 0], kind: .square, sizePt: 24, colour: SIMD3<Float>(1, 0, 0))
        let glyphs = try g.showGlyphs([-1, 0, 0, 1, 0, 0], kind: .cross, sizePt: 16, colour: "red", dir: [1, 0, 0, 0, 1, 0])
        try g.frame()
        var left: ViewPick?, right: ViewPick?
        for x in stride(from: UInt32(0), to: 96, by: 2) {
            for y in stride(from: UInt32(40), to: 56, by: 2) {
                guard let p = try g.pick(x: x, y: y), p.item == glyphs.id else { continue }
                if x < 48 { left = left ?? p } else { right = right ?? p }
            }
        }
        XCTAssertEqual(left?.node, 0, "the left glyph picks as node 0")
        XCTAssertEqual(right?.node, 1, "the right glyph picks as node 1")
        // Each kind draws its own picture: no two of the twelve are the same image.
        var pictures: [GlyphKind: [UInt8]] = [:]
        for kind in GlyphKind.allCases {
            let k = try offscreen(96, 96)
            defer { try? k.close() }
            _ = try k.showGlyphs([-1, 0, 0, 1, 0, 0], kind: kind, sizePt: 24, colour: "red", dir: [1, 0, 0, 1, 0, 0])
            try k.frame()
            try k.draw()
            pictures[kind] = try k.image().rgba
        }
        for a in GlyphKind.allCases {
            for b in GlyphKind.allCases where a.rawValue < b.rawValue {
                XCTAssertNotEqual(pictures[a]!, pictures[b]!, "\(a) and \(b) draw the same picture")
            }
        }
    }

    /// The point enums' raw values are the header's CADACLYSM_VIEW_POINT_* numbers (no GPU).
    func testThePointEnumsAreTheHeaders() {
        XCTAssertEqual(PointShape.allCases.map(\.rawValue),
                       [CADACLYSM_VIEW_POINT_DISC, CADACLYSM_VIEW_POINT_RING, CADACLYSM_VIEW_POINT_SQUARE,
                        CADACLYSM_VIEW_POINT_DIAMOND].map { UInt32($0) })
        XCTAssertEqual(PointState.allCases.map(\.rawValue),
                       [CADACLYSM_VIEW_POINT_STATE_NORMAL, CADACLYSM_VIEW_POINT_STATE_HOVER,
                        CADACLYSM_VIEW_POINT_STATE_SELECTED, CADACLYSM_VIEW_POINT_STATE_FIRST].map { UInt8($0) })
    }

    /// 1.28's viewport_label, rigged: every pick buffer handed to the library holds -1 on the
    /// way in; a label hit (item 0) answers viewportLabel from pick, lastPick, run and a pick
    /// event's pick_viewport_label; -1 answers nil (a miss with no label is no pick). A label
    /// with a NUL is refused before the library is called.
    func testTheViewportLabelRidesEveryPickRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer {
            t.pointee = saved; spySaid = nil; spyPicked = noPick(); spyLanded = true; spyLabelsIn = []; spyEvents = []
            spyCalls = []
        }
        rig17(t)
        spyLabelsIn = []
        spyLanded = true
        spyPicked = noPick()
        spyPicked.viewport_label = 2
        spyPicked.clicks = 1
        let hit = try XCTUnwrap(try view.pick(x: 1, y: 1), "a label hit is a pick")
        XCTAssertEqual(hit.item, 0)
        XCTAssertEqual(hit.viewportLabel, 2, "pick")
        XCTAssertEqual(try view.lastPick().pick?.viewportLabel, 2, "lastPick")
        let own = try View.offscreen(width: 32, height: 32)
        let cam = try own.run()
        try own.close()
        XCTAssertEqual(cam.pick?.viewportLabel, 2, "run")
        XCTAssertFalse(spyLabelsIn.isEmpty)
        XCTAssertEqual(Set(spyLabelsIn), [-1], "every pick buffer handed over holds viewport_label -1")
        spyPicked = noPick()
        XCTAssertNil(try view.pick(x: 1, y: 1), "-1 and item 0: nothing")
        let miss = try view.lastPick()
        XCTAssertTrue(miss.landed)
        XCTAssertNil(miss.pick, "-1 and item 0: nothing landed on")
        spyPicked.item = 4
        XCTAssertNil(try XCTUnwrap(try view.pick(x: 1, y: 1)).viewportLabel, "an item hit: no label")

        rigEvents(t)
        spyEvents = [
            rawEvent(8) { $0.pick_viewport_label = 1; $0.pick.clicks = 1 },
            rawEvent(8),
            rawEvent(8) { $0.pick.item = 3 },
        ]
        let got = try view.events()
        XCTAssertEqual(got.count, 3)
        guard got.count == 3 else { return }
        guard case .pick(let labelled) = got[0].kind else { return XCTFail("pick: \(got[0].kind)") }
        XCTAssertEqual(labelled?.item, 0)
        XCTAssertEqual(labelled?.viewportLabel, 1, "the event's own pick_viewport_label")
        guard case .pick(let nothing) = got[1].kind else { return XCTFail("pick: \(got[1].kind)") }
        XCTAssertNil(nothing, "-1: no pick")
        guard case .pick(let item) = got[2].kind else { return XCTFail("pick: \(got[2].kind)") }
        XCTAssertEqual(item?.item, 3)
        XCTAssertNil(item?.viewportLabel, "an item hit: no label")

        t.pointee.set_viewport_label = { _, _, _, _ in spyCalls.append("label"); return true }
        spyCalls = []
        XCTAssertEqual(message { try view.setViewportLabel(0, text: "A\0B") },
                       "text 'A\\x00B': a NUL character cannot be shown (the C string ends there)")
        XCTAssertEqual(spyCalls, [], "refused before the library is called")
        try view.setViewportLabel(0, text: "AB")
        XCTAssertEqual(spyCalls, ["label"])
    }

    /// A pick and run's pick carry clicks, and the point only where the library set one;
    /// setDoubleClickFrames, focus and navigation reach the library with their arguments.
    func testThePicksClicksAndPointAndThe17CallsRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyPicked = noPick(); spyNavigation = 0; spyLanded = true }
        rig17(t)

        spyPicked = noPick()
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

    // ---- view ABI 1.22: snapping

    /// Through the table rigged: setSnap hands over the kinds' bits, the aperture and the
    /// marker; snap and lastSnap read the answer whole (no edge for a face snap, nil for
    /// nothing); clearSnap and the work plane reach the library as given.
    func testSnapSettingsAndAnswersRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spySnap = CadaclysmViewSnap(); spySnapLanded = true; spySnapCalls = [] }
        rigSnap(t)

        try view.setSnap()
        XCTAssertEqual([spySnapSettings.size, spySnapSettings.kinds, spySnapSettings.marker], [16, UInt32(CADACLYSM_VIEW_SNAP_DEFAULT), 1],
                       "the default kinds")
        try view.setSnap(Set(SnapKind.allCases))
        XCTAssertEqual(spySnapSettings.kinds, UInt32(CADACLYSM_VIEW_SNAP_ALL), "every kind")
        XCTAssertEqual(spySnapSettings.aperture_px, 0)
        try view.setSnap([.vertex, .edge], aperturePx: 6, marker: false)
        XCTAssertEqual([spySnapSettings.kinds, spySnapSettings.marker], [0b1_0001, 0])
        XCTAssertEqual(spySnapSettings.aperture_px, 6)
        try view.setSnap([.face])
        XCTAssertEqual(spySnapSettings.kinds, 32, "one kind alone")
        try view.setSnap(nil)
        XCTAssertEqual(spySnapSettings.kinds, 0, "nil switches snapping off")

        spySnap = CadaclysmViewSnap()
        spySnap.kind = UInt32(CADACLYSM_VIEW_SNAP_VERTEX)
        spySnap.point = (-1, 1, 0)
        spySnap.item = 3
        spySnap.node = 4
        spySnap.face = 5
        spySnap.edge = 2
        spySnap.tangent = (1, 0, 0)
        spySnap.distance_px = 2.5
        let vertex = try view.snap(x: 10, y: 20, viewport: 1)
        XCTAssertEqual(vertex, ViewSnap(kind: .vertex, point: SIMD3(-1, 1, 0), item: 3, node: 4, face: 5, edge: 2,
                                        tangent: SIMD3(1, 0, 0), axis: SIMD3(0, 0, 0), radius: 0, distancePx: 2.5, clicks: 0,
                                        label: "", lockedAngle: nil, guides: []))
        XCTAssertEqual(spySnapCalls, ["snap 1 10 20"])
        spySnap = CadaclysmViewSnap()
        spySnap.kind = UInt32(CADACLYSM_VIEW_SNAP_CENTRE)
        spySnap.axis = (0, 0, 1)
        spySnap.radius = 2.5
        let centre = try XCTUnwrap(try view.snap(x: 1, y: 1))
        XCTAssertEqual(centre.kind, .centre)
        XCTAssertEqual(centre.axis, SIMD3(0, 0, 1))
        XCTAssertEqual(centre.radius, 2.5)
        spySnap = CadaclysmViewSnap()
        spySnap.kind = UInt32(CADACLYSM_VIEW_SNAP_FACE)
        spySnap.edge = UInt32.max
        XCTAssertNil(try XCTUnwrap(try view.snap(x: 1, y: 1)).edge, "a face snap has no edge")
        spySnap = CadaclysmViewSnap()
        XCTAssertNil(try view.snap(x: 1, y: 1), "kind 0 is nothing snapped")

        spySnap.kind = UInt32(CADACLYSM_VIEW_SNAP_EDGE)
        spySnap.clicks = 1
        let landed = try view.lastSnap()
        XCTAssertTrue(landed.landed)
        XCTAssertEqual(landed.snap?.kind, .edge)
        XCTAssertEqual(landed.snap?.clicks, 1)
        spySnapLanded = false
        spySaid = cstr("cadaclysm_view_snap_result: no snap result")
        XCTAssertFalse(try view.lastSnap().landed, "nothing landed yet")
        spySaid = cstr("boom from snap_result")
        XCTAssertEqual(message { _ = try view.lastSnap() }, "boom from snap_result", "the library's refusal")
        spySaid = nil
        spySnapLanded = true

        try view.clearSnap()
        try view.setWorkPlane(origin: SIMD3(1, 2, 3), step: 0.5)
        try view.setWorkPlane(origin: nil)
        XCTAssertEqual(Array(spySnapCalls.suffix(3)),
                       ["clear snap", "work plane 1.0 2.0 3.0, 1.0 0.0 0.0, 0.0 0.0 1.0, 0.5", "ground plane"])
    }

    /// Python's test_a_snap_on_the_real_library_finds_the_squares_corner and
    /// test_snapping_is_off_until_set_snap: the red square with its four sides, from the top, on
    /// a 64 x 48 view. Snapping is off until setSnap; then a snap 3 pixels inside the topmost
    /// (then leftmost) pixel that is not the background answers that corner, (-1, 1, 0), as a
    /// vertex of the square's item; a face snap lands on the face; nil switches it off again.
    func testASnapFindsTheSquaresCorner() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        let square: [Float] = [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0]
        // The square's four sides as segments, written out: Swift 6.1 gives up type-checking
        // the nested flatMap this was ("unable to type-check this expression in reasonable time").
        var outline: [Float] = []
        for i in 0..<4 {
            let a = 3 * i
            let b = 3 * ((i + 1) % 4)
            outline.append(contentsOf: square[a..<a + 3])
            outline.append(contentsOf: square[b..<b + 3])
        }
        let item = try view.showMesh(positions: square, indices: [0, 1, 2, 0, 2, 3], edges: outline, rgb: SIMD3<Float>(1, 0, 0))
        try view.standard("top")
        try view.frame()
        let image = try view.image()
        XCTAssertNil(try view.snap(x: 32, y: 24), "a view starts with snapping off")
        try view.setSnap()
        let width = Int(image.width)
        let background = Array(image.rgba[0..<3])
        let first = try XCTUnwrap((0..<Int(image.height) * width).first { Array(image.rgba[4 * $0 ..< 4 * $0 + 3]) != background },
                                  "the square drew nothing")
        let s = try XCTUnwrap(try view.snap(x: UInt32(first % width) + 3, y: UInt32(first / width) + 3), "nothing snapped near the corner")
        XCTAssertEqual(s.kind, .vertex)
        XCTAssertEqual(s.item, item.id)
        XCTAssertLessThan(max(abs(s.point.x + 1), abs(s.point.y - 1), abs(s.point.z)), 1e-6, "the corner is (-1, 1, 0), not \(s.point)")
        XCTAssertNotNil(s.edge, "a vertex snap lies on an edge")
        XCTAssertEqual(s.clicks, 0, "asked by the host")
        try view.clearSnap()
        try view.setSnap([.face])
        let face = try XCTUnwrap(try view.snap(x: 32, y: 24), "the face snap")
        XCTAssertEqual(face.kind, .face)
        XCTAssertEqual(face.item, item.id)
        XCTAssertNil(face.edge)
        try view.setSnap(nil)
        XCTAssertNil(try view.snap(x: 32, y: 24), "snapping off answers nothing")
    }

    /// A red square seen from the top, zoomed out so a framing visibly changes the picture.
    private func framedSquare() throws -> (View, UInt32) {
        let view = try offscreen(64, 48)
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
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

    // ---- machining and the timeline (view ABI 1.7) ------------------------------------------

    private func plate() throws -> PlateJob {
        guard let dir = plateFixture() else {
            if !(ProcessInfo.processInfo.environment["CADACLYSM_SAMPLES_OPTIONAL"] ?? "").isEmpty {
                throw XCTSkip("web/test/fixtures/machining-plate is missing")
            }
            XCTFail("web/test/fixtures/machining-plate is missing above \(#filePath)")
            throw XCTSkip("no plate")
        }
        func read(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
        return PlateJob(directory: dir, programs: [
            MachiningProgram(tool: MachiningTool(number: 1, shape: "flat", diameter: 6, fluteLength: 20), gcode: try read("program-0.gcode")),
            MachiningProgram(tool: MachiningTool(number: 2, shape: "drill", diameter: 6, fluteLength: 30), gcode: try read("program-1.gcode")),
        ], options: MachiningOptions(cell: 0.5, rapidRate: 5000))
    }

    /// A rigged offscreen view (`rigMachining`), its table put back by the caller's defer.
    private func machiningRig() throws -> (View, Machining, CvlTable, UnsafeMutablePointer<CvlTable>) {
        let view = try offscreen(32, 32)
        let t = view.library.table
        let saved = t.pointee
        rigMachining(t)
        resetMachiningSpies()
        let item = try view.showMachining([MachiningProgram(tool: MachiningTool(number: 1, shape: "flat", diameter: 6), gcode: "G1 X1")],
                                          stock: boxStock)
        return (view, item, saved, t)
    }

    /// F1: what show_machining hands the library, field for field, and the item that comes back.
    func testShowMachiningReachesTheContract() throws {
        let (view, first, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        XCTAssertEqual(first.id, 17)
        XCTAssertEqual(spyMachiningSize, UInt32(MemoryLayout<CadaclysmViewMachining>.size))
        XCTAssertEqual(spyPartPositions == nil, true, "no part is NULL positions")
        XCTAssertEqual(spyPartCounts, [0, 0])
        XCTAssertEqual(spyOptions, [0, 0, 0, 0], "no options: the library's defaults")
        XCTAssertEqual(spySkinSet, 0)

        let programs = [
            MachiningProgram(tool: MachiningTool(number: 3, shape: "vbit", diameter: 8, fluteLength: 12, angle: 90), gcode: "G0 X1\nG1 Z-1"),
            MachiningProgram(tool: MachiningTool(number: 4, shape: "bullnose", diameter: 10, cornerRadius: 2), gcode: "G1 X2 \u{e9}"),
            MachiningProgram(tool: MachiningTool(number: 5, shape: "ball", diameter: 4), gcode: ""),
            MachiningProgram(tool: MachiningTool(number: 6, shape: "drill", diameter: 3), gcode: "G81"),
            MachiningProgram(tool: MachiningTool(number: 7, shape: "flat", diameter: 6), gcode: "G1"),
        ]
        let part = MachiningPart(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1, 2, 2, 1, 0])
        let item = try view.showMachining(programs, stock: MachiningStock(min: SIMD3(-1, -2, -3), max: SIMD3(4, 5, 6)), part: part,
                                          options: MachiningOptions(cell: 0.25, tolerance: 0.01, skin: 0, rapidRate: 1234))
        XCTAssertTrue(type(of: item) == Machining.self)
        XCTAssertEqual(spyShows, 2)
        let size = UInt32(MemoryLayout<CadaclysmViewProgram>.size)
        XCTAssertEqual(spyPrograms, [
            SpyProgram(size: size, number: 3, shape: UInt32(CADACLYSM_VIEW_TOOL_VBIT), diameter: 8, flute: 12, angle: 90, corner: 0, gcode: "G0 X1\nG1 Z-1"),
            SpyProgram(size: size, number: 4, shape: UInt32(CADACLYSM_VIEW_TOOL_BULLNOSE), diameter: 10, flute: 0, angle: 0, corner: 2, gcode: "G1 X2 \u{e9}"),
            SpyProgram(size: size, number: 5, shape: UInt32(CADACLYSM_VIEW_TOOL_BALL), diameter: 4, flute: 0, angle: 0, corner: 0, gcode: ""),
            SpyProgram(size: size, number: 6, shape: UInt32(CADACLYSM_VIEW_TOOL_DRILL), diameter: 3, flute: 0, angle: 0, corner: 0, gcode: "G81"),
            SpyProgram(size: size, number: 7, shape: UInt32(CADACLYSM_VIEW_TOOL_FLAT), diameter: 6, flute: 0, angle: 0, corner: 0, gcode: "G1"),
        ])
        XCTAssertEqual(spyStockMin, [-1, -2, -3])
        XCTAssertEqual(spyStockMax, [4, 5, 6])
        XCTAssertEqual(spyPartPositions, part.positions)
        XCTAssertEqual(spyPartIndices, part.indices)
        XCTAssertEqual(spyPartCounts, [3, 6])
        XCTAssertEqual(spyOptions, [0.25, 0.01, 0, 1234])
        XCTAssertEqual(spySkinSet, 1, "a skin of 0 is given")
        // An empty part still reaches the library as arrays that are not NULL.
        _ = try view.showMachining(programs, stock: boxStock, part: MachiningPart(positions: [], indices: []))
        XCTAssertNotNil(spyPartPositions)
        XCTAssertEqual(spyPartCounts, [0, 0])
        _ = try view.showMachining(programs, stock: boxStock, options: MachiningOptions(skin: 0.4))
        XCTAssertEqual(spyOptions, [0, 0, 0.4, 0])
        // A Machining keeps every Item member: it is one.
        let asItem: Item = item
        XCTAssertEqual(asItem.id, 17)
    }

    /// F2: every refusal before the library, in Python's words; a closed view says so for a
    /// job that is fine.
    func testShowMachiningRefusesBeforeTheLibrary() throws {
        let (view, _, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        let tool = MachiningTool(number: 1, shape: "flat", diameter: 6)
        let ok = [MachiningProgram(tool: tool, gcode: "G1")]
        spyShows = 0
        func show(_ programs: [MachiningProgram]? = nil, stock: MachiningStock = boxStock, part: MachiningPart? = nil,
                  options: MachiningOptions = MachiningOptions()) -> String {
            message { _ = try view.showMachining(programs ?? ok, stock: stock, part: part, options: options) }
        }
        var spade = tool
        spade.shape = "spade"
        XCTAssertEqual(show([MachiningProgram(tool: spade, gcode: "")]), "shape 'spade': one of flat, ball, drill, vbit, bullnose")
        var wide = tool
        wide.diameter = .nan
        XCTAssertEqual(show([MachiningProgram(tool: wide, gcode: "")]), "tool: diameter, flute_length, angle and corner_radius are finite numbers")
        var long = tool
        long.angle = .infinity
        XCTAssertEqual(show([MachiningProgram(tool: long, gcode: "")]), "tool: diameter, flute_length, angle and corner_radius are finite numbers")
        XCTAssertEqual(show([MachiningProgram(tool: tool, gcode: "G1\0X1")]), "gcode: a NUL character cannot be sent (the C string ends there)")
        XCTAssertEqual(show(stock: MachiningStock(min: SIMD3(0, .nan, 0), max: SIMD3(1, 1, 1))), "stock: min and max are finite numbers")
        XCTAssertEqual(show(stock: MachiningStock(min: SIMD3(0, 0, 0), max: SIMD3(1, 1, .infinity))), "stock: min and max are finite numbers")
        XCTAssertEqual(show(part: MachiningPart(positions: [0, 0, .nan], indices: [])), "part positions: finite numbers")
        XCTAssertEqual(show(part: MachiningPart(positions: [0, 0, 0, 1], indices: [])),
                       "part positions: 4 numbers is not a whole number of x y z triples")
        XCTAssertEqual(show(part: MachiningPart(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1])),
                       "part indices: 2 is not a whole number of triangles")
        XCTAssertEqual(show(part: MachiningPart(positions: [0, 0, 0, 1, 0, 0, 0, 1, 0], indices: [0, 1, 3])),
                       "part indices: 3 is past the last of 3 vertices")
        XCTAssertEqual(show(options: MachiningOptions(skin: .nan)),
                       "show_machining options: cell, tolerance, skin and rapid_rate are finite numbers")
        XCTAssertEqual(show(options: MachiningOptions(rapidRate: .infinity)),
                       "show_machining options: cell, tolerance, skin and rapid_rate are finite numbers")
        XCTAssertEqual(spyShows, 0, "a refused show_machining reached the library")
        // The library's own refusal (no programs) comes back in its words.
        t.pointee.show_machining = { _, _ in spySaid = cstr("machining: programs: at least one"); return 0 }
        XCTAssertEqual(show([]), "machining: programs: at least one")
        rigMachining(t)
        try view.close()
        XCTAssertEqual(show(), "cadaclysm_view_show_machining: the view is closed")
        XCTAssertEqual(show([MachiningProgram(tool: spade, gcode: "")]), "shape 'spade': one of flat, ball, drill, vbit, bullnose",
                       "the shape is refused before the view is looked at")
    }

    /// F3: the Machining members reach the library as given -- ids, modes, flags, the info
    /// struct's size and fields, the heights' capacity (nx * ny, never NULL) and order.
    func testMachiningMembersReachTheLibrary() throws {
        let (view, item, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        spyMachLog = []
        try item.seekMove(7)
        try item.setColourBy("height")
        try item.setColourBy("tool")
        try item.setColourBy("deviation")
        try item.setOverlays()
        try item.setOverlays(path: false, tool: true)
        try item.setOverlays(path: true, tool: false)
        XCTAssertEqual(spyMachLog, [
            "seek 17 7",
            "colour 17 \(CADACLYSM_VIEW_COLOUR_BY_HEIGHT)", "colour 17 \(CADACLYSM_VIEW_COLOUR_BY_TOOL)",
            "colour 17 \(CADACLYSM_VIEW_COLOUR_BY_DEVIATION)",
            "overlays 17 true true", "overlays 17 false true", "overlays 17 true false",
        ])
        spyInfoAnswer.moves = 638
        spyInfoAnswer.move = 12
        spyInfoAnswer.nx = 3
        spyInfoAnswer.ny = 2
        spyInfoAnswer.cell = 0.5
        spyInfoAnswer.min = (-41.5, -26.5)
        spyInfoAnswer.cycle_time = 893.25
        let info = try item.info()
        XCTAssertEqual(spyInfoSize, UInt32(MemoryLayout<CadaclysmViewMachiningInfo>.size))
        XCTAssertEqual([info.moves, info.move, info.nx, info.ny], [638, 12, 3, 2])
        XCTAssertEqual(info.cell, 0.5)
        XCTAssertEqual([info.min.0, info.min.1], [-41.5, -26.5])
        XCTAssertEqual(info.cycleTime, 893.25)
        spyHeightsAnswer = [1, 2, 3, 4, 5, 6, 7, 8]
        XCTAssertEqual(try item.heights(), [1, 2, 3, 4, 5, 6], "nx * ny floats, row y then x")
        XCTAssertEqual(spyHeightsCapacity, 6)
        spyInfoAnswer.nx = 0
        XCTAssertEqual(try item.heights(), [])
        XCTAssertEqual(spyHeightsCapacity, 0)
        XCTAssertFalse(spyHeightsNull, "an empty grid still hands the library a buffer")
    }

    /// F4: a mode that is none of the three is refused before the library; the library's
    /// refusals come back in its words; a closed view says so.
    func testMachiningModesAndLibraryRefusals() throws {
        let (view, item, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        spyMachLog = []
        XCTAssertEqual(message { try item.setColourBy("rainbow") }, "mode 'rainbow': one of height, tool, deviation")
        XCTAssertEqual(spyMachLog, [], "a refused mode reached the library")
        spyColourRefused = true
        XCTAssertEqual(message { try item.setColourBy("deviation") }, "cadaclysm_view_machining_colour_by: deviation needs a part")
        try view.close()
        XCTAssertEqual(message { try item.seekMove(1) }, "cadaclysm_view_machining_seek: the view is closed")
        XCTAssertEqual(message { try item.setColourBy("tool") }, "cadaclysm_view_machining_colour_by: the view is closed")
        XCTAssertEqual(message { try item.setOverlays() }, "cadaclysm_view_machining_overlays: the view is closed")
        XCTAssertEqual(message { _ = try item.info() }, "cadaclysm_view_machining_info: the view is closed")
        XCTAssertEqual(message { _ = try item.heights() }, "cadaclysm_view_machining_info: the view is closed")
        XCTAssertEqual(message { try item.remove() }, "cadaclysm_view_remove: the view is closed")
        XCTAssertEqual(message { try item.setColourBy("rainbow") }, "mode 'rainbow': one of height, tool, deviation")
    }

    /// F5: the transport reaches the library with its arguments and answers its numbers; a
    /// speed or time that is not finite is refused first; a closed view says so.
    func testTheTimelineTransport() throws {
        let (view, _, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        spyMachLog = []
        try view.play()
        try view.play(speed: 2.5)
        try view.pause()
        try view.seek(10.25)
        try view.setLoop()
        try view.setLoop(false)
        XCTAssertEqual(spyMachLog, ["play 1.0", "play 2.5", "pause", "seekTime 10.25", "loop true", "loop false"])
        spyTime = 3.5
        spyDuration = 893.25
        spyPlaying = true
        XCTAssertEqual(try view.time, 3.5)
        XCTAssertEqual(try view.duration, 893.25)
        XCTAssertTrue(try view.playing)
        spyPlaying = false
        XCTAssertFalse(try view.playing)
        spyMachLog = []
        XCTAssertEqual(message { try view.play(speed: .nan) }, "play speed: a finite number")
        XCTAssertEqual(message { try view.play(speed: .infinity) }, "play speed: a finite number")
        XCTAssertEqual(message { try view.seek(.nan) }, "seek seconds: a finite number")
        XCTAssertEqual(spyMachLog, [], "a refused play or seek reached the library")
        try view.close()
        XCTAssertEqual(message { try view.play() }, "cadaclysm_view_timeline_play: the view is closed")
        XCTAssertEqual(message { try view.pause() }, "cadaclysm_view_timeline_pause: the view is closed")
        XCTAssertEqual(message { try view.seek(1) }, "cadaclysm_view_timeline_seek: the view is closed")
        XCTAssertEqual(message { try view.setLoop() }, "cadaclysm_view_timeline_set_loop: the view is closed")
        XCTAssertEqual(message { _ = try view.time }, "cadaclysm_view_timeline_time: the view is closed")
        XCTAssertEqual(message { _ = try view.duration }, "cadaclysm_view_timeline_duration: the view is closed")
        XCTAssertEqual(message { _ = try view.playing }, "cadaclysm_view_timeline_playing: the view is closed")
        XCTAssertEqual(message { _ = try view.status() }, "cadaclysm_view_timeline_status: the view is closed")
    }

    /// F6: status asks the length with (NULL, 0), then fills a buffer of n + 1; asks again when
    /// the line grew between the calls; splits at newlines; none is an empty list.
    func testTheTimelineStatusMeasuresFillsAndRetries() throws {
        let (view, _, saved, t) = try machiningRig()
        defer { t.pointee = saved; resetMachiningSpies(); try? view.close() }
        spyStatusAnswers = [""]
        spyStatusCalls = 0
        XCTAssertEqual(try view.status(), [])
        XCTAssertEqual(spyStatusCalls, 1, "nothing on the timeline: one call")
        let two = "move 3 of 9 - T1 flat 6 mm\nmove 1 of 2 - T2 drill 3 mm"
        spyStatusAnswers = [two]
        spyStatusCalls = 0
        XCTAssertEqual(try view.status(), ["move 3 of 9 - T1 flat 6 mm", "move 1 of 2 - T2 drill 3 mm"])
        XCTAssertEqual(spyStatusCalls, 2, "measure, then fill")
        spyStatusAnswers = ["a", "a longer line than measured", "a longer line than measured"]
        spyStatusCalls = 0
        XCTAssertEqual(try view.status(), ["a longer line than measured"])
        XCTAssertEqual(spyStatusCalls, 3, "the line grew: asked again")
        spyStatusAnswers = ["a", ""]
        spyStatusCalls = 0
        XCTAssertEqual(try view.status(), [], "a second answer of 0 bytes is no line")
        XCTAssertEqual(spyStatusCalls, 2)
        spyStatusAnswers = ["caf\u{e9} \u{2014} T1"]
        spyStatusCalls = 0
        XCTAssertEqual(try view.status(), ["caf\u{e9} \u{2014} T1"], "UTF-8 survives")
    }

    /// F7: the plate, seeked to its end, is the fixture's heights on the real library -- by the
    /// wall rule -- and the status line says so.
    func testMachiningPlatePlaysToTheFixturesHeightsOffscreen() throws {
        let job = try plate()
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let item = try view.showMachining(job.programs, stock: boxStock, options: job.options)
        XCTAssertEqual(try view.duration, 893.247024, accuracy: 1e-3)
        let info = try item.info()
        XCTAssertGreaterThan(info.moves, 0)
        try item.seekMove(info.moves)
        let gpu = try item.heights()
        let raw = try Data(contentsOf: job.directory.appendingPathComponent("heights.bin"))
        let word = { (at: Int) -> UInt32 in raw.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }
        let nx = Int(word(8)), ny = Int(word(12))
        XCTAssertEqual([Int(info.nx), Int(info.ny), gpu.count], [nx, ny, nx * ny], "the grid")
        let oracle = (0..<nx * ny).map { Float(bitPattern: word(28 + 4 * $0)) }
        let (failed, excused, walls) = compareAtWalls(gpu, oracle, nx: nx, ny: ny)
        print("machining plate vs heights.bin: failed \(failed), excused \(excused), walls \(walls) of \(nx * ny) cells")
        XCTAssertEqual(failed, 0, "heights against heights.bin: failed \(failed), excused \(excused), walls \(walls)")
        XCTAssertLessThanOrEqual(excused, max(4, walls / 100), "excused \(excused) of walls \(walls)")
        try view.draw()
        let lines = try view.status()
        XCTAssertTrue(lines.first?.hasPrefix("move \(info.moves) of \(info.moves)") ?? false, "status \(lines)")
        try item.remove()
    }

    /// F7b: every one of the fourteen calls on the real library, not only the plate's own.
    func testMachiningAndTimelineCallsOnTheRealLibrary() throws {
        let job = try plate()
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let item = try view.showMachining(job.programs, stock: boxStock, options: job.options)
        let duration = try view.duration
        XCTAssertFalse(try view.playing, "a fresh machining is paused")
        try view.play(speed: 2)
        XCTAssertTrue(try view.playing, "play(2) did not play")
        try view.pause()
        XCTAssertFalse(try view.playing, "pause did not pause")
        try view.seek(10)
        try view.draw()
        XCTAssertEqual(try view.time, 10, accuracy: 1e-6, "time after seek(10)")
        try view.seek(duration + 100)
        try view.draw()
        XCTAssertEqual(try view.time, duration, accuracy: 1e-6, "seek past the end clamps")
        try view.setLoop(true)
        try view.setLoop(false)
        XCTAssertFalse(try view.status().isEmpty, "a status line")
        try item.setColourBy("tool")
        try item.setColourBy("height")
        let refused = message { try item.setColourBy("deviation") }
        XCTAssertTrue(refused.contains("cadaclysm_view_machining_colour_by"), "deviation with no part: \(refused)")
        try item.setOverlays(path: false, tool: false)
        try item.setOverlays()
        try view.draw()
        try item.seekMove(0)
        XCTAssertEqual(try item.info().moves > 0, true)
        try item.remove()
        // With a part, colouring by deviation works.
        let part = MachiningPart(positions: [-42, -27, 14, 42, -27, 14, 0, 27, 14], indices: [0, 1, 2])
        let withPart = try view.showMachining(job.programs, stock: boxStock, part: part, options: job.options)
        try withPart.setColourBy("deviation")
        try view.draw()
        try withPart.remove()
    }

    // ---- view ABI 1.26: input events

    /// CadaclysmViewInputEvent is the header's 424 bytes (1.30) with no implicit padding, its
    /// snap the frozen 88-byte one so `camera` stays at 224; the kinds, modifier bits and pointer
    /// kinds are the header's numbers, written out here.
    func testTheInputEventIsTheHeaders126Layout() {
        typealias E = CadaclysmViewInputEvent
        XCTAssertEqual(MemoryLayout<E>.size, 424)
        let tail: [Int?] = [
            MemoryLayout<E>.offset(of: \E.pick_segment), MemoryLayout<E>.offset(of: \E.pick_distance_px),
            MemoryLayout<E>.offset(of: \E.snap_label), MemoryLayout<E>.offset(of: \E.snap_locked),
            MemoryLayout<E>.offset(of: \E.snap_locked_angle), MemoryLayout<E>.offset(of: \E.snap_guide_count),
            MemoryLayout<E>.offset(of: \E.pad1), MemoryLayout<E>.offset(of: \E.snap_guides),
        ]
        XCTAssertEqual(tail, [272, 276, 280, 312, 316, 320, 324, 328])
        let offsets: [Int?] = [
            MemoryLayout<E>.offset(of: \E.size), MemoryLayout<E>.offset(of: \E.kind), MemoryLayout<E>.offset(of: \E.time_ms),
            MemoryLayout<E>.offset(of: \E.x), MemoryLayout<E>.offset(of: \E.y), MemoryLayout<E>.offset(of: \E.wheel_y),
            MemoryLayout<E>.offset(of: \E.button), MemoryLayout<E>.offset(of: \E.modifiers), MemoryLayout<E>.offset(of: \E.pointer),
            MemoryLayout<E>.offset(of: \E.pointer_id), MemoryLayout<E>.offset(of: \E.width), MemoryLayout<E>.offset(of: \E.height),
            MemoryLayout<E>.offset(of: \E.`repeat`), MemoryLayout<E>.offset(of: \E.dropped), MemoryLayout<E>.offset(of: \E.pad0),
            MemoryLayout<E>.offset(of: \E.key), MemoryLayout<E>.offset(of: \E.pick), MemoryLayout<E>.offset(of: \E.snap),
            MemoryLayout<E>.offset(of: \E.camera), MemoryLayout<E>.offset(of: \E.pick_viewport_label),
        ]
        XCTAssertEqual(offsets, [0, 4, 8, 16, 20, 24, 28, 32, 36, 40, 44, 48, 52, 56, 60, 64, 96, 136, 224, 268])
        XCTAssertEqual(MemoryLayout<CadaclysmViewEventPick>.size, 40)
        let kinds = [CADACLYSM_VIEW_INPUT_EVENT_POINTER_DOWN, CADACLYSM_VIEW_INPUT_EVENT_POINTER_MOVE,
                     CADACLYSM_VIEW_INPUT_EVENT_POINTER_UP, CADACLYSM_VIEW_INPUT_EVENT_WHEEL,
                     CADACLYSM_VIEW_INPUT_EVENT_KEY_DOWN, CADACLYSM_VIEW_INPUT_EVENT_KEY_UP,
                     CADACLYSM_VIEW_INPUT_EVENT_RESIZE, CADACLYSM_VIEW_INPUT_EVENT_PICK,
                     CADACLYSM_VIEW_INPUT_EVENT_SNAP, CADACLYSM_VIEW_INPUT_EVENT_CLOSE].map { UInt32($0) }
        XCTAssertEqual(kinds, Array(1...10))
        XCTAssertEqual([Modifiers.shift, .ctrl, .alt, .meta].map { $0.rawValue }, [1, 2, 4, 8])
        XCTAssertEqual(PointerKind.allCases.map { $0.rawValue }, [0, 1, 2])
    }

    /// nextEvent through the table rigged: each kind read by the header's numbers, the
    /// modifier bits by the header's, nil once none is left, any other failure the library's.
    func testNextEventReadsEachKindRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyEvents = []; spyEventSizes = [] }
        rigEvents(t)

        spyEvents = [
            rawEvent(1) { $0.x = 10; $0.y = 20; $0.button = 2; $0.modifiers = 1 | 4; $0.time_ms = 5 },
            rawEvent(2) { $0.x = 11; $0.y = 21; $0.pointer = 1; $0.pointer_id = 3 },
            rawEvent(4) { $0.x = 1; $0.y = 2; $0.wheel_y = -100; $0.modifiers = 2 },
            rawEvent(5) { setKey(&$0, "KeyR"); $0.`repeat` = 1; $0.modifiers = 8; $0.dropped = 4 },
            rawEvent(6) { setKey(&$0, "KeyR") },
            rawEvent(7) { $0.width = 640; $0.height = 480 },
            rawEvent(8) { $0.pick.item = 3; $0.pick.node = 1; $0.pick.face = 2; $0.pick.clicks = 2; $0.pick.has_point = 1; $0.pick.point = (1, 2, 3) },
            rawEvent(8),
            rawEvent(9) { $0.snap.kind = 1; $0.snap.item = 3; $0.snap.edge = 4; $0.snap.clicks = 1 },
            rawEvent(3) { $0.pointer = 2 },
            rawEvent(10) { $0.camera.eye = (0, -5, 0); $0.camera.up = (0, 0, 1) },
            rawEvent(99),
        ]
        let got = try view.events()
        XCTAssertEqual(got.count, 12)
        guard got.count == 12 else { return }
        guard case .pointerDown(let down) = got[0].kind else { return XCTFail("pointer down: \(got[0].kind)") }
        XCTAssertEqual(down, PointerInput(x: 10, y: 20, button: 2, pointer: .mouse, pointerID: 0, modifiers: [.shift, .alt]),
                       "SHIFT 1, ALT 4")
        XCTAssertEqual(got[0].timeMs, 5)
        guard case .pointerMove(let move) = got[1].kind else { return XCTFail("pointer move: \(got[1].kind)") }
        XCTAssertEqual([move.pointer], [.touch])
        XCTAssertEqual(move.pointerID, 3)
        guard case .wheel(let wheel) = got[2].kind else { return XCTFail("wheel: \(got[2].kind)") }
        XCTAssertEqual(wheel, WheelInput(x: 1, y: 2, wheelY: -100, modifiers: .ctrl), "CTRL 2")
        guard case .keyDown(let key) = got[3].kind else { return XCTFail("key down: \(got[3].kind)") }
        XCTAssertEqual(key, KeyInput(key: "KeyR", isRepeat: true, modifiers: .meta), "META 8")
        XCTAssertEqual(got[3].dropped, 4)
        guard case .keyUp(let up) = got[4].kind else { return XCTFail("key up: \(got[4].kind)") }
        XCTAssertEqual(up, KeyInput(key: "KeyR", isRepeat: false, modifiers: []))
        guard case .resize(let width, let height) = got[5].kind else { return XCTFail("resize: \(got[5].kind)") }
        XCTAssertEqual([width, height], [640, 480])
        guard case .pick(let hit) = got[6].kind else { return XCTFail("pick: \(got[6].kind)") }
        XCTAssertEqual(hit, ViewPick(item: 3, node: 1, face: 2, clicks: 2, point: SIMD3(1, 2, 3), overlay: false,
                                     viewportLabel: nil, segment: nil, distancePx: 0))
        guard case .pick(let miss) = got[7].kind else { return XCTFail("pick: \(got[7].kind)") }
        XCTAssertNil(miss, "a click on nothing")
        guard case .snap(let snap) = got[8].kind else { return XCTFail("snap: \(got[8].kind)") }
        XCTAssertEqual(snap?.kind, .vertex)
        XCTAssertEqual(snap?.edge, 4)
        guard case .pointerUp(let pen) = got[9].kind else { return XCTFail("pointer up: \(got[9].kind)") }
        XCTAssertEqual(pen.pointer, .pen)
        guard case .close(let cam) = got[10].kind else { return XCTFail("close: \(got[10].kind)") }
        XCTAssertEqual(cam.eye, SIMD3<Float>(0, -5, 0))
        XCTAssertEqual(cam.azimuth, -90, accuracy: 1e-9)
        XCTAssertNil(cam.pick)
        guard case .other(let unknown) = got[11].kind else { return XCTFail("other: \(got[11].kind)") }
        XCTAssertEqual(unknown, 99, "a later kind is kept, not dropped")
        XCTAssertNil(try view.nextEvent())
        XCTAssertTrue(spyEventSizes.allSatisfy { $0 == 424 }, "the 1.30 struct's size: \(spyEventSizes)")

        t.pointee.next_event = { _, _ in
            spySaid = cstr("cadaclysm_view_next_event: CadaclysmViewInputEvent.size is 8; this library needs at least 272")
            return false
        }
        XCTAssertEqual(message { _ = try view.nextEvent() },
                       "cadaclysm_view_next_event: CadaclysmViewInputEvent.size is 8; this library needs at least 272")
        try view.close()
        XCTAssertEqual(message { _ = try view.nextEvent() }, "cadaclysm_view_next_event: the view is closed")
    }

    /// closeWindow, rigged: the library's close, then closed as when pump answers CLOSED; a
    /// closed window is not closed again; its close event is still read.
    func testCloseWindowRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyEvents = []; spyClosedWindows = 0 }
        rigEvents(t)
        spyClosedWindows = 0
        try view.closeWindow()
        XCTAssertTrue(view.isClosed)
        try view.closeWindow()
        XCTAssertEqual(spyClosedWindows, 1, "a closed window is not closed again")
        let e = try XCTUnwrap(try view.nextEvent(), "the close event, read on a closed window")
        guard case .close(let cam) = e.kind else { return XCTFail("close: \(e.kind)") }
        XCTAssertEqual(cam.eye, SIMD3<Float>(1, 2, 3))
    }

    /// run(onEvent), rigged: every event handed over until the callback answers false, which
    /// closes the window; the key up after it is not handed over; the camera is the close
    /// event's, the pick the last pick event's (none being left for pick_result).
    func testRunWithACallbackStopsOnFalseRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer {
            t.pointee = saved; spySaid = nil; spyEvents = []; spyClosedWindows = 0; spyPumpMs = []; spyPumpAnswers = []
            spyLanded = true; spyPicked = noPick()
        }
        rigEvents(t)
        spyClosedWindows = 0
        spyPumpMs = []
        spyPumpAnswers = []
        spyLanded = false
        spyEvents = [
            rawEvent(5) { setKey(&$0, "KeyR") },
            rawEvent(8) { $0.pick.item = 3; $0.pick.node = 1; $0.pick.face = 2; $0.pick.clicks = 1 },
            rawEvent(5) { setKey(&$0, "KeyQ") },
            rawEvent(6) { setKey(&$0, "KeyQ") },
        ]
        var seen: [String] = []
        let cam = try view.run { e in
            switch e.kind {
            case .keyDown(let k):
                seen.append("keyDown:\(k.key)")
                if k.key == "KeyR" { try view.draw() }  // the callback may call the view
                return k.key != "KeyQ"
            case .keyUp(let k): seen.append("keyUp:\(k.key)")
            case .pick: seen.append("pick")
            case .close: seen.append("close")
            default: seen.append("other")
            }
            return true
        }
        XCTAssertEqual(seen, ["keyDown:KeyR", "pick", "keyDown:KeyQ"], "false stops: neither the key up nor the close is handed over")
        XCTAssertEqual(spyClosedWindows, 1)
        XCTAssertTrue(view.isClosed)
        XCTAssertEqual(cam.eye, SIMD3<Float>(1, 2, 3), "the camera the close event carried")
        XCTAssertEqual(cam.pick?.item, 3, "the last pick event's, none being left for pick_result")
        XCTAssertEqual(spyPumpMs.first, 16, "pumped 16 ms at a time")
    }

    /// run(onEvent), rigged: the window closing by itself ends it, the close event handed over
    /// last; the pick is what pick_result answers then, as run() takes it.
    func testRunWithACallbackEndsOnTheWindowsOwnCloseRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer {
            t.pointee = saved; spySaid = nil; spyEvents = []; spyClosedWindows = 0; spyPumpMs = []; spyPumpAnswers = []
            spyEye = (10, 0, 0); spyPicked = noPick()
        }
        rigEvents(t)
        spyClosedWindows = 0
        spyPumpMs = []
        spyPumpAnswers = [UInt32(CADACLYSM_VIEW_OPEN), UInt32(CADACLYSM_VIEW_CLOSED)]
        spyEye = (0, -5, 0)
        spyLanded = true
        spyPicked = noPick()
        spyPicked.item = 7
        spyPicked.clicks = 1
        spyEvents = [rawEvent(7) { $0.width = 5; $0.height = 6 }]
        var seen: [String] = []
        let cam = try view.run { e in
            if case .resize = e.kind { seen.append("resize") }
            if case .close = e.kind { seen.append("close") }
            return true
        }
        XCTAssertEqual(seen, ["resize", "close"])
        XCTAssertEqual(cam.eye, SIMD3<Float>(0, -5, 0))
        XCTAssertEqual(cam.azimuth, -90, accuracy: 1e-9)
        XCTAssertEqual(cam.pick?.item, 7, "pick_result's answer, taken as run() takes it")
        XCTAssertTrue(view.isClosed)
        XCTAssertEqual(spyClosedWindows, 0, "closed by itself: never closed by the wrapper")
        XCTAssertEqual(spyPumpMs, [16, 16])
    }

    /// On the real library an offscreen view queues nothing and has no window to close.
    func testAnOffscreenViewQueuesNoEventAndHasNoWindowToClose() throws {
        let view = try offscreen(32, 24)
        defer { try? view.close() }
        XCTAssertNil(try view.nextEvent())
        XCTAssertEqual(message { try view.closeWindow() }, "cadaclysm_view_close: only a view with a window of its own is closed")
    }

    /// CADACLYSM_VIEW_TEST_QUEUE_INPUT=1 when the view is made: an offscreen view queues what
    /// input() hands it, as an own window queues its own input -- read back by nextEvent with
    /// the real library's kinds, names and modifier bits; a click's pick lands with the draw.
    func testTheTestingHookQueuesAnOffscreenViewsInput() throws {
        cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", "1")
        let made: View
        do {
            defer { cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", nil) }
            made = try offscreen(64, 48)
        }
        let view = made
        defer { try? view.close() }
        let item = try view.showMesh(positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], indices: [0, 1, 2, 0, 2, 3],
                                     rgb: SIMD3<Float>(1, 0, 0))
        try view.standard("top")
        try view.frame()
        try view.draw()
        let down = UInt32(CADACLYSM_VIEW_EVENT_DOWN), up = UInt32(CADACLYSM_VIEW_EVENT_UP)
        _ = try view.input(kind: UInt32(CADACLYSM_VIEW_EVENT_KEY), key: "KeyZ", keyDown: true)
        _ = try view.input(kind: down, x: 32, y: 24, button: 2, shift: true, timeMS: 1000)
        _ = try view.input(kind: up, x: 32, y: 24, button: 2, timeMS: 1010)
        _ = try view.input(kind: down, x: 32, y: 24, timeMS: 2000)
        _ = try view.input(kind: up, x: 32, y: 24, timeMS: 2010)
        try view.draw()
        _ = try view.input(kind: UInt32(CADACLYSM_VIEW_EVENT_WHEEL), x: 3, y: 4, wheelY: -100)
        let got = try view.events()
        let names = got.map { e -> String in
            switch e.kind {
            case .keyDown: return "keyDown"
            case .pointerDown: return "pointerDown"
            case .pointerUp: return "pointerUp"
            case .pick: return "pick"
            case .wheel: return "wheel"
            default: return "\(e.kind)"
            }
        }
        XCTAssertEqual(names, ["keyDown", "pointerDown", "pointerUp", "pointerDown", "pointerUp", "pick", "wheel"])
        guard names.count == 7 else { return }
        if case .keyDown(let k) = got[0].kind { XCTAssertEqual(k, KeyInput(key: "KeyZ", isRepeat: false, modifiers: [])) }
        if case .pointerDown(let p) = got[1].kind {
            XCTAssertEqual(p.button, 2)
            XCTAssertEqual(p.modifiers, .shift, "a shifted right press")
            XCTAssertEqual(p.pointer, .mouse)
        }
        if case .pointerDown(let p) = got[3].kind { XCTAssertEqual([p.button, p.modifiers.rawValue], [0, 0]) }
        if case .wheel(let w) = got[6].kind { XCTAssertEqual(w, WheelInput(x: 3, y: 4, wheelY: -100, modifiers: [])) }
        guard case .pick(let hit) = got[5].kind, let hit else { return XCTFail("the click's pick: \(got[5].kind)") }
        XCTAssertEqual([hit.item, hit.clicks], [item.id, 1], "the click's pick: the square")
        let last = try view.lastPick()
        XCTAssertTrue(last.landed)
        XCTAssertEqual(last.pick?.item, hit.item, "lastPick still has it")
        XCTAssertNil(try view.nextEvent(), "all read")
    }

    // ---- view ABI 1.27: kernel animations ----

    /// A 4 x 2 x 1 kernel box shown and framed from the top, as the C ABI's turntable test does.
    private func shownBox(_ view: View) throws -> Item {
        let item = try view.showSolid(try Solid.cuboid(4, 2, 1))
        try view.standard("top")
        try item.frame()
        return item
    }

    private func frameDrawn(_ view: View) throws -> ViewImage {
        try view.draw()
        return try view.image()
    }

    private func turntable(_ target: String = "spin", degrees: Double = 30) throws -> Animation {
        let anim = try Animation()
        try anim.rotate(target, [(time: 0, value: 0), (time: 1, value: degrees)])
        return anim
    }

    /// The header's numbers: the event kind, the all-nodes value and the binding's size.
    func testTheAnimationBindingIsTheHeaders127Layout() {
        XCTAssertEqual(UInt32(CADACLYSM_VIEW_INPUT_EVENT_TIMELINE), 11)
        XCTAssertEqual(UInt32(CADACLYSM_VIEW_ALL_NODES), 0xFFFF_FFFF)
        typealias B = CadaclysmViewAnimationBinding
        let wide = MemoryLayout<UnsafeRawPointer>.size == 8
        XCTAssertEqual(MemoryLayout<B>.size, wide ? 16 : 12)
        XCTAssertEqual([MemoryLayout<B>.offset(of: \B.item), MemoryLayout<B>.offset(of: \B.node)], wide ? [8, 12] : [4, 8])
    }

    /// The table rigged: each binding's target, item and node reach the library as given (nil
    /// node: CADACLYSM_VIEW_ALL_NODES), no binding is a NULL array with count 0, a refusal
    /// comes before the library, the ghosts' NULL and empty arrays differ.
    func testAnimationCallsReachTheLibraryRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spyAnimation = []; spySaid = nil }
        spyAnimation = []
        t.pointee.last_error = { spySaid }
        t.pointee.play_animation = { _, animation, bindings, count in
            var line = "play \(Int(bitPattern: animation)) count \(count) \(bindings == nil ? "NULL" : "array")"
            for k in 0..<Int(count) {
                let b = bindings![k]
                line += " (\(String(cString: b.target)),\(b.item),\(b.node))"
            }
            spyAnimation.append(line)
            spySaid = nil
            return UInt32(spyAnimation.count)
        }
        t.pointee.timeline_remove = { _, track in
            spyAnimation.append("remove \(track)")
            if track == 2 { spySaid = cstr("timeline_remove: no track 2"); return false }
            spySaid = nil
            return true
        }
        t.pointee.set_item_visible = { _, item, on in spyAnimation.append("visible \(item) \(on)"); spySaid = nil; return true }
        t.pointee.set_node_ghosts = { _, item, nodes, count in
            spyAnimation.append("ghosts \(item) \(nodes == nil ? "NULL" : "array") \(count) \((0..<Int(count)).map { nodes![$0] })")
            spySaid = nil
            return true
        }
        let all = UInt32.max
        let item = Item(view: view, id: 41)
        let other = Item(view: view, id: 42)
        let h = OpaquePointer(bitPattern: 77)
        XCTAssertEqual(try view.playAnimationHandle(h, [AnimationBinding(target: "lid", item: item, node: 3),
                                                        AnimationBinding(target: "spin", item: other.id),
                                                        AnimationBinding(target: "arm", item: item, node: 5)]), 1)
        XCTAssertEqual(spyAnimation.last, "play 77 count 3 array (lid,41,3) (spin,42,\(all)) (arm,41,5)",
                       "node nil is CADACLYSM_VIEW_ALL_NODES")
        XCTAssertEqual(try view.playAnimationHandle(h, []), 2)
        XCTAssertEqual(spyAnimation.last, "play 77 count 0 NULL", "no bindings: a NULL array, count 0")
        XCTAssertEqual(message { _ = try view.playAnimationHandle(h, [AnimationBinding(target: "a\u{0}b", item: 1)]) },
                       "binding 0: target 'a\\x00b' holds a NUL character")
        XCTAssertEqual(spyAnimation.count, 2, "the refusal came before the library")
        try view.removeTrack(1)
        XCTAssertEqual(spyAnimation.last, "remove 1")
        XCTAssertEqual(message { try view.removeTrack(2) }, "timeline_remove: no track 2")
        try item.setVisible(false)
        try other.setVisible(true)
        XCTAssertEqual(Array(spyAnimation.suffix(2)), ["visible 41 false", "visible 42 true"])
        try item.setNodeGhosts([2, 0])
        XCTAssertEqual(spyAnimation.last, "ghosts 41 array 2 [2, 0]")
        try item.setNodeGhosts(nil)
        XCTAssertEqual(spyAnimation.last, "ghosts 41 NULL 0 []", "nil clears: a NULL array")
        try item.setNodeGhosts([])
        XCTAssertTrue(spyAnimation.last?.hasPrefix("ghosts 41 array 0") ?? false, "[]: a non-NULL empty array")
        try view.close()
        XCTAssertEqual(message { try view.removeTrack(1) }, "cadaclysm_view_timeline_remove: the view is closed")
    }

    /// Kind 11 is "timeline", and the stamp is all it carries (the other fields are not read).
    func testATimelineEventIsItsStampAloneRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyEvents = []; spyEventSizes = [] }
        rigEvents(t)
        spyEvents = [rawEvent(11) { $0.time_ms = 9.5; $0.x = 3; $0.width = 7; $0.dropped = 2 }]
        let got = try view.events()
        XCTAssertEqual(got.count, 1)
        guard got.count == 1, case .timeline = got[0].kind else { return XCTFail("timeline: \(got.map { $0.kind })") }
        XCTAssertEqual(got[0].timeMs, 9.5)
        XCTAssertEqual(got[0].dropped, 2)
    }

    func testATurntablePlaysOnTheRealLibraryAndRemovingItRestoresTheRest() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let item = try shownBox(view)
        let rest = try frameDrawn(view)
        let anim = try turntable()
        let track = try view.playAnimation(anim, [AnimationBinding(target: "spin", item: item)])
        XCTAssertEqual(track, 1, "the first track")
        anim.close()   // the view plays its own copy
        try view.seek(1)
        XCTAssertGreaterThan(changed(try frameDrawn(view), rest), 0, "turned 30 degrees, the box draws elsewhere")
        try view.removeTrack(track)
        XCTAssertEqual(changed(try frameDrawn(view), rest), 0, "removed: the rest pose again, pixel for pixel")
        XCTAssertEqual(message { try view.removeTrack(track) }, "timeline_remove: no track 1")
    }

    func testABindingToAnUnknownItemOrNodeIsRefusedWithTheLibrarysText() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let item = try shownBox(view)
        let anim = try turntable()
        XCTAssertEqual(message { _ = try view.playAnimation(anim, [AnimationBinding(target: "spin", item: 9999)]) },
                       "play_animation: no item 9999")
        XCTAssertEqual(message { _ = try view.playAnimation(anim, [AnimationBinding(target: "spin", item: item, node: 1)]) },
                       "play_animation: item \(item.id) has no node 1 (it has 1)", "a solid is one node")
        XCTAssertEqual(message { _ = try view.playAnimation(anim, [AnimationBinding(target: "spin", item: item),
                                                                    AnimationBinding(target: "spin", item: item)]) },
                       "play_animation: target \"spin\" is bound twice to item \(item.id)")
        XCTAssertEqual(message { _ = try view.playAnimationHandle(nil, [AnimationBinding(target: "spin", item: item)]) },
                       "play_animation: the animation is null")
    }

    func testSetVisibleHidesTheItemAndShowsItAgainOnTheRealLibrary() throws {
        let view = try offscreen(64, 48)
        defer { try? view.close() }
        let item = try shownBox(view)
        let rest = try frameDrawn(view)
        try item.setVisible(false)
        XCTAssertGreaterThan(changed(try frameDrawn(view), rest), 0, "hidden: the box is gone")
        try item.setVisible(true)
        XCTAssertEqual(changed(try frameDrawn(view), rest), 0, "shown again")
        XCTAssertEqual(message { try Item(view: view, id: 9999).setVisible(false) }, "set_item_visible: no item 9999")
    }

    func testSetNodeGhostsSetsThenClearsOnTheRealLibrary() throws {
        do { try ViewLibrary.useWgpu() } catch { try skipOrFail(error) }
        // Triangles: the exact surfaces draw an x-ray item as they draw it opaque, alone in the picture.
        let view: View
        do { view = try View.offscreen(width: 64, height: 48, triangles: true) } catch { try skipOrFail(error) }
        defer { try? view.close() }
        let item = try shownBox(view)
        let rest = try frameDrawn(view)
        try item.setXray(true)
        let xray = try frameDrawn(view)
        try item.setXray(false)
        try item.setNodeGhosts([0])
        let ghosted = try frameDrawn(view)
        XCTAssertGreaterThan(changed(ghosted, rest), 0, "node 0 drawn x-ray")
        XCTAssertEqual(changed(ghosted, xray), 0, "a solid's one node ghosted is the item x-ray")
        try item.setNodeGhosts(nil)
        XCTAssertEqual(changed(try frameDrawn(view), rest), 0, "cleared")
        XCTAssertEqual(message { try item.setNodeGhosts([1]) }, "set_node_ghosts: item \(item.id) has no node 1 (it has 1)")
        XCTAssertEqual(message { try Item(view: view, id: 9999).setNodeGhosts(nil) }, "set_node_ghosts: no item 9999")
    }

    /// CADACLYSM_VIEW_TEST_QUEUE_INPUT=1: an offscreen view queues as an own window does -- one
    /// timeline event for a draw after a seek moved the clock, none for a draw after that.
    func testASeekAndADrawQueueOneTimelineEventUnderTheTestingHook() throws {
        cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", "1")
        let made: View
        do {
            defer { cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", nil) }
            made = try offscreen(64, 48)
        }
        let view = made
        defer { try? view.close() }
        let item = try shownBox(view)
        let anim = try turntable()
        try view.playAnimation(anim, [AnimationBinding(target: "spin", item: item)])
        anim.close()
        try view.draw()
        _ = try view.events()
        try view.seek(0.5)
        try view.draw()
        let got = try view.events().filter { if case .timeline = $0.kind { return true } else { return false } }
        XCTAssertEqual(got.count, 1, "\(got)")
        try view.draw()
        XCTAssertTrue(try view.events().allSatisfy { if case .timeline = $0.kind { return false } else { return true } },
                      "the clock still: none")
    }

    // ---- view ABI 1.30: picking and snapping

    /// Through the table rigged: the new kinds' bits and the hit kinds are the header's
    /// numbers on the wire; pickRect asks with 64, then again with the total; "none" crosses as
    /// its C value (a NULL base, a NULL label, NULL points); a NUL label and a short base are
    /// refused, as ViewErrors, before the call; a guide count past 2 reads 2 guides; the event's
    /// tail carries the pick's segment and the snap's label, lock and guides.
    func testPickingAndSnappingRigged() throws {
        let view = try offscreen(32, 32)
        defer { try? view.close() }
        let t = view.library.table
        let saved = t.pointee
        defer { t.pointee = saved; spySaid = nil; spyP3 = []; spyRectHits = []; spyEvents = []; spyEventSizes = []; spySegmentsIn = [] }
        rigSnap(t)
        rigEvents(t)
        rigP3(t)

        // The snap kinds and the hit kinds, against the header's constants.
        XCTAssertEqual([SnapKind.end, .intersection, .point, .alignment].map(\.rawValue),
                       [CADACLYSM_VIEW_SNAP_END, CADACLYSM_VIEW_SNAP_INTERSECTION, CADACLYSM_VIEW_SNAP_POINT,
                        CADACLYSM_VIEW_SNAP_ALIGNMENT].map { UInt32($0) })
        XCTAssertEqual(HitKind.face.rawValue, UInt32(CADACLYSM_VIEW_HIT_FACE))
        XCTAssertEqual(HitKind.node.rawValue, UInt32(CADACLYSM_VIEW_HIT_NODE))
        XCTAssertEqual(HitKind.segment.rawValue, UInt32(CADACLYSM_VIEW_HIT_SEGMENT))
        XCTAssertEqual(HitKind.edge.rawValue, UInt32(CADACLYSM_VIEW_HIT_EDGE))
        XCTAssertEqual(HitKind.point.rawValue, UInt32(CADACLYSM_VIEW_HIT_POINT))
        XCTAssertEqual(MemoryLayout<CadaclysmViewRectHit>.size, 12)
        try view.setSnap([.end, .alignment])
        XCTAssertEqual(spySnapSettings.kinds, UInt32(CADACLYSM_VIEW_SNAP_END) | UInt32(CADACLYSM_VIEW_SNAP_ALIGNMENT))
        try view.setSnap(SnapKind.defaultKinds)
        XCTAssertEqual(spySnapSettings.kinds, UInt32(CADACLYSM_VIEW_SNAP_DEFAULT))

        // The count rule, and each header kind decoded.
        let kinds = [CADACLYSM_VIEW_HIT_FACE, CADACLYSM_VIEW_HIT_NODE, CADACLYSM_VIEW_HIT_SEGMENT, CADACLYSM_VIEW_HIT_EDGE,
                     CADACLYSM_VIEW_HIT_POINT].map { UInt32($0) }
        spyRectHits = (0..<70).map { i in CadaclysmViewRectHit(item: 2, kind: kinds[i % 5], index: UInt32(i)) }
        let hits = try view.pickRect(x: 1, y: 2, w: -3, h: 4)
        XCTAssertEqual(hits.count, 70, "never a cut list")
        XCTAssertEqual(hits.prefix(5).map(\.kind), [.face, .node, .segment, .edge, .point])
        XCTAssertEqual(hits[69], RectHit(item: 2, kind: .point, index: 69))
        XCTAssertEqual(spyP3, ["rect 0 1.0 2.0 -3.0 4.0 true cap=64", "rect 0 1.0 2.0 -3.0 4.0 true cap=70"])
        spyP3 = []
        spyRectHits = [CadaclysmViewRectHit(item: 5, kind: kinds[0], index: 2)]
        XCTAssertEqual(try view.pickRect(x: 0, y: 0, w: 1, h: 1, crossing: false, viewport: 2), [RectHit(item: 5, kind: .face, index: 2)])
        XCTAssertEqual(spyP3, ["rect 2 0.0 0.0 1.0 1.0 false cap=64"], "one call when the first buffer holds them")
        spyRectHits = []
        XCTAssertEqual(try view.pickRect(x: 0, y: 0, w: 1, h: 1), [], "0 with no error: nothing there")
        spySaid = cstr("cadaclysm_view_pick_rect: the rectangle is not finite")
        XCTAssertTrue(refused { _ = try view.pickRect(x: .nan, y: 0, w: 1, h: 1) }.hasSuffix("the rectangle is not finite"))
        spySaid = nil

        // None crosses as its C value; refusals come before the call, as ViewErrors.
        let line = try view.showLines([0, 0, 0, 1, 0, 0])
        spyP3 = []
        try view.setSnapBase(nil)
        try view.setSnapBase([1, 2, 3], stepDeg: 45)
        try line.setSnapPoints([2, 0, 0])
        try line.setSnapPoints([0.5, 0.5, 0.01], label: "hole")
        try line.setSnapPoints([])
        try view.setPickAperture(6.5)
        XCTAssertEqual(spyP3, ["base nil 15.0", "base 1.0 2.0 3.0 45.0", "points 1 [2.0, 0.0, 0.0] nil", "points 1 [0.5, 0.5, 0.01] hole",
                               "points 0 nil nil", "aperture 6.5"])
        spyP3 = []
        XCTAssertTrue(refused { try line.setSnapPoints([0, 0, 0], label: "a\0b") }.contains("a NUL character cannot be shown"))
        XCTAssertTrue(refused { try view.setSnapBase([1, 2]) }.contains("3 numbers"))
        XCTAssertTrue(refused { try line.setSnapPoints([0, 0]) }.contains("three numbers a point"))
        XCTAssertEqual(spyP3, [], "refused before the library is called")

        // A pick's segment: UINT32_MAX is none; a buffer starts there.
        rig17(t)
        spyPicked = noPick()
        spyPicked.item = 3
        XCTAssertNil(try XCTUnwrap(try view.pick(x: 1, y: 1)).segment, "UINT32_MAX: no segment")
        spyPicked.segment = 2
        spyPicked.distance_px = 1.5
        let wire = try XCTUnwrap(try view.pick(x: 1, y: 1))
        XCTAssertEqual(wire, ViewPick(item: 3, node: 0, face: 0, clicks: 0, point: nil, overlay: false, viewportLabel: nil,
                                      segment: 2, distancePx: 1.5))
        XCTAssertEqual(try view.lastPick().pick?.segment, 2, "lastPick")
        spyPicked = noPick()
        rigEvents(t)

        // The guide cap, from a hand-filled answer.
        var raw = CadaclysmViewSnap()
        raw.kind = UInt32(CADACLYSM_VIEW_SNAP_PLANE)
        withUnsafeMutableBytes(of: &raw.label) { b in for (i, c) in "plane".utf8.enumerated() { b[i] = c } }
        raw.locked = 1
        raw.locked_angle = 45
        raw.guide_count = 3
        raw.guides = (0, 0, 0, 1, 1, 0, 5, 0, 0, 1, 1, 0)
        let capped = try XCTUnwrap(snapOf(raw))
        XCTAssertEqual(capped.label, "plane")
        XCTAssertEqual(capped.lockedAngle, 45)
        XCTAssertEqual(capped.guides.count, 2, "a guide count of 3 reads 2 guides")
        XCTAssertEqual(capped.guides.map(\.from), [[0, 0, 0], [5, 0, 0]])
        XCTAssertEqual(capped.guides.map(\.to), [[1, 1, 0], [1, 1, 0]])
        raw.locked = 0
        XCTAssertNil(try XCTUnwrap(snapOf(raw)).lockedAngle, "locked 0: no angle")

        // == is synthesized and sees every 1.30 field: a snap differing only in its label, its
        // angle or one guide's end is another snap.
        raw.locked = 1
        let same = try XCTUnwrap(snapOf(raw))
        XCTAssertEqual(same, capped)
        let base = capped
        func with(label: String? = nil, angle: Float?? = nil, guides: [SnapGuide]? = nil) -> ViewSnap {
            ViewSnap(kind: base.kind, point: base.point, item: base.item, node: base.node, face: base.face, edge: base.edge,
                     tangent: base.tangent, axis: base.axis, radius: base.radius, distancePx: base.distancePx, clicks: base.clicks,
                     label: label ?? base.label, lockedAngle: angle ?? base.lockedAngle, guides: guides ?? base.guides)
        }
        XCTAssertEqual(with(), base)
        XCTAssertNotEqual(with(label: "hole"), base, "the label takes part")
        XCTAssertNotEqual(with(angle: .some(nil)), base, "the angle takes part")
        XCTAssertNotEqual(with(guides: [base.guides[0], SnapGuide(from: [5, 0, 0], to: [1, 1, 9])]), base, "a guide's end takes part")
        XCTAssertNotEqual(with(guides: [base.guides[0]]), base, "the guide count takes part")

        // A library that leaves the pick's 1.30 tail as the caller filled it (as a 1.29 one
        // does): every pick buffer starts at segment UINT32_MAX, so it reads as none.
        t.pointee.pick_result = { _, out in
            spySegmentsIn.append(out!.pointee.segment)
            out!.pointee.item = 3
            out!.pointee.clicks = 1
            return true
        }
        spySegmentsIn = []
        XCTAssertNil(try XCTUnwrap(try view.pick(x: 1, y: 1)).segment, "pick: an untouched tail is no segment")
        let untouched = try view.lastPick()
        XCTAssertTrue(untouched.landed)
        XCTAssertNil(try XCTUnwrap(untouched.pick).segment, "lastPick: an untouched tail is no segment")
        XCTAssertEqual(spySegmentsIn, [UInt32.max, UInt32.max], "each buffer handed over held UINT32_MAX")

        // The event's tail.
        spyEvents = [
            rawEvent(8) { $0.pick.item = 7; $0.pick_segment = 0; $0.pick_distance_px = 2.5 },
            rawEvent(8) { $0.pick.item = 7 },
            rawEvent(9) {
                $0.snap.kind = UInt32(CADACLYSM_VIEW_SNAP_POINT)
                withUnsafeMutableBytes(of: &$0.snap_label) { b in for (i, c) in "hole".utf8.enumerated() { b[i] = c } }
                $0.snap_locked = 1
                $0.snap_locked_angle = 90
                $0.snap_guide_count = 3
            },
        ]
        let got = try view.events()
        XCTAssertEqual(got.count, 3)
        guard got.count == 3 else { return }
        guard case .pick(let a) = got[0].kind, case .pick(let b) = got[1].kind, case .snap(let s) = got[2].kind else {
            return XCTFail("\(got.map(\.kind))")
        }
        XCTAssertEqual(a?.segment, 0)
        XCTAssertEqual(a?.distancePx, 2.5)
        XCTAssertNil(b?.segment, "an untouched tail: no segment")
        XCTAssertEqual(s?.label, "hole")
        XCTAssertEqual(s?.lockedAngle, 90)
        XCTAssertEqual(s?.guides.count, 2)
        spyEvents = []
        _ = try view.nextEvent()
        XCTAssertEqual(spyEventSizes.last, 424)
        XCTAssertEqual(spyEventSegmentsIn.last, UInt32.max, "nextEvent's buffer starts with no segment")
    }

    /// The P3 scene on the real library, by the house pixel recipe: a 96 x 96 view of its own,
    /// the square as a mesh, a line along y = 0 a little above it with a snap point on it, the
    /// top view framed, then sweeps -- never a fixed pixel.
    func testPickingAndSnapping() throws {
        XCTAssertEqual(MemoryLayout<CadaclysmViewPick>.size, 52)
        XCTAssertEqual(MemoryLayout<CadaclysmViewSnap>.size, 232)
        XCTAssertEqual(MemoryLayout<CadaclysmViewEventSnap>.size, 88)
        XCTAssertEqual(MemoryLayout<CadaclysmViewInputEvent>.size, 424)
        XCTAssertEqual(MemoryLayout<CadaclysmViewInputEvent>.offset(of: \CadaclysmViewInputEvent.camera), 224)
        XCTAssertEqual(MemoryLayout<CadaclysmViewRectHit>.size, 12)
        XCTAssertEqual(SnapKind.end.rawValue, UInt32(CADACLYSM_VIEW_SNAP_END))
        XCTAssertEqual(SnapKind.intersection.rawValue, UInt32(CADACLYSM_VIEW_SNAP_INTERSECTION))
        XCTAssertEqual(SnapKind.point.rawValue, UInt32(CADACLYSM_VIEW_SNAP_POINT))
        XCTAssertEqual(SnapKind.alignment.rawValue, UInt32(CADACLYSM_VIEW_SNAP_ALIGNMENT))
        XCTAssertEqual(HitKind.edge.rawValue, UInt32(CADACLYSM_VIEW_HIT_EDGE))
        XCTAssertEqual(HitKind.segment.rawValue, UInt32(CADACLYSM_VIEW_HIT_SEGMENT))

        cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", "1")
        let made: View
        do {
            defer { cvl_setenv("CADACLYSM_VIEW_TEST_QUEUE_INPUT", nil) }
            made = try offscreen(96, 96)
        }
        let view = made
        defer { try? view.close() }
        try view.setLayer(UInt32(CADACLYSM_VIEW_LAYER_GRID), false)
        let square = try view.showMesh(positions: [-1, -1, 0, 1, -1, 0, 1, 1, 0, -1, 1, 0], indices: [0, 1, 2, 0, 2, 3],
                                       rgb: SIMD3<Float>(1, 0, 0))
        let line = try view.showLines([-0.8, 0, 0.01, 0.8, 0, 0.01], rgb: SIMD3<Float>(1, 1, 1))
        try line.setSnapPoints([0.5, 0.5, 0.01], label: "hole")
        try view.standard("top")
        try view.frame()
        try view.setPickAperture(0)
        XCTAssertTrue(refused { try view.setPickAperture(-1) }.contains("is not a finite size of 0 or more points"))

        // The pick sweep: column 48, rows 36..59.
        var picks: [(UInt32, ViewPick?)] = []
        for y in UInt32(36)..<60 { picks.append((y, try view.pick(x: 48, y: y))) }
        XCTAssertTrue(picks.contains { $0.1?.item == line.id && $0.1?.segment == 0 && ($0.1?.distancePx ?? 99) <= 4 },
                      "a wire pick's segment: \(picks)")
        XCTAssertTrue(picks.contains { $0.1?.item == square.id && $0.1?.segment == nil && $0.1?.distancePx == 0 },
                      "a face pick has no segment: \(picks)")
        let yLine = try XCTUnwrap(picks.first { $0.1?.item == line.id }).0

        // The event path: a click on the line queues a pick event with its segment; lastPick has the same answer.
        _ = try view.events()
        let down = UInt32(CADACLYSM_VIEW_EVENT_DOWN), up = UInt32(CADACLYSM_VIEW_EVENT_UP)
        _ = try view.input(kind: down, x: 48, y: Float(yLine), timeMS: 30000)
        _ = try view.input(kind: up, x: 48, y: Float(yLine), timeMS: 30010)
        var clicked: ViewPick?
        for _ in 0..<200 where clicked == nil {
            try view.draw()
            for e in try view.events() { if case .pick(let p) = e.kind, let p { clicked = p } }
        }
        XCTAssertEqual(clicked?.item, line.id)
        XCTAssertEqual(clicked?.segment, 0, "a pick event's segment")
        let landed = try view.lastPick().pick
        XCTAssertEqual(landed?.item, line.id)
        XCTAssertEqual(landed?.segment, 0, "lastPick's segment")

        // pickRect over the whole view, with 80 short lines: more hits than its first buffer.
        var many: [Float] = []
        for i in 0..<80 {
            let x = -0.9 + 1.8 * Float(i) / 79
            many.append(contentsOf: [x, -0.6, 0.01, x, -0.5, 0.01])
        }
        let lines80 = try view.showLines(many, rgb: SIMD3<Float>(0, 1, 0))
        let hits = try view.pickRect(x: 0, y: 0, w: 96, h: 96)
        XCTAssertTrue(hits.contains(RectHit(item: line.id, kind: .segment, index: 0)), "pickRect finds the line: \(hits)")
        XCTAssertTrue(hits.contains(RectHit(item: square.id, kind: .node, index: 0)), "pickRect finds the square as a node: \(hits)")
        XCTAssertEqual(hits.filter { $0.item == lines80.id }.count, 80, "pickRect past the first buffer")
        XCTAssertTrue(refused { _ = try view.pickRect(x: 0, y: 0, w: .nan, h: 10) }.contains("cadaclysm_view_pick_rect"))
        XCTAssertLessThanOrEqual(try view.pickRect(x: 0, y: 0, w: 96, h: 96, crossing: false).count, hits.count)
        try lines80.remove()

        // A labelled snap point, by the default kinds: rows 0..47, columns 48..95, step 2.
        try view.setSnap()
        var found: (ViewSnap, UInt32, UInt32)?
        search: for y in stride(from: UInt32(0), to: 48, by: 2) {
            for x in stride(from: UInt32(48), to: 96, by: 2) {
                if let s = try view.snap(x: x, y: y), s.kind == .point {
                    found = (s, x, y)
                    break search
                }
            }
        }
        let (point, px, py) = try XCTUnwrap(found, "a snap in the top right quarter lands on the snap point")
        XCTAssertEqual(point.label, "hole")
        XCTAssertNil(point.lockedAngle)
        XCTAssertEqual(point.guides.count, 0)

        // The event path: a hover over the point queues a snap event with its label; lastSnap has the same answer.
        _ = try view.events()
        _ = try view.lastSnap()
        _ = try view.input(kind: UInt32(CADACLYSM_VIEW_EVENT_MOVE), x: Float(px), y: Float(py), timeMS: 40000)
        var hovered: ViewSnap?
        for _ in 0..<200 where hovered == nil {
            try view.draw()
            for e in try view.events() { if case .snap(let s) = e.kind, let s, s.kind == .point { hovered = s } }
        }
        XCTAssertEqual(hovered?.label, "hole", "a snap event's label")
        XCTAssertEqual(try view.lastSnap().snap?.label, "hole", "lastSnap's label")
        try line.setSnapPoints([])
        XCTAssertNotEqual(try view.snap(x: px, y: py)?.kind, .point, "the cleared points no longer snap")
        XCTAssertTrue(refused { try line.setSnapPoints([0, 0, 0], label: String(repeating: "x", count: 32)) }.contains("at most 31"))

        // The lock: face snaps turn onto 45-degree steps about the origin, the lock's ray their guide.
        try view.setSnapBase([0, 0, 0], stepDeg: 45)
        try view.setSnap([.face, .plane])
        func sweep() throws -> [ViewSnap] {
            var out: [ViewSnap] = []
            for y in stride(from: UInt32(8), to: 40, by: 8) {
                for x in stride(from: UInt32(56), to: 88, by: 8) { if let s = try view.snap(x: x, y: y) { out.append(s) } }
            }
            return out
        }
        let locked = try sweep()
        XCTAssertFalse(locked.isEmpty)
        XCTAssertTrue(locked.allSatisfy { $0.kind == .plane && $0.lockedAngle.map { $0.truncatingRemainder(dividingBy: 45) == 0 } == true && $0.guides.count == 1 },
                      "the lock turns face snaps onto 45-degree steps: \(locked.map { ($0.kind, $0.lockedAngle) })")
        // Clearing passes a NULL point: the same sweep is no longer locked (a zeroed point would lock about the origin).
        try view.setSnapBase(nil)
        let unlocked = try sweep()
        XCTAssertFalse(unlocked.isEmpty, "the cleared sweep snaps")
        XCTAssertEqual(unlocked.filter { $0.lockedAngle != nil || !$0.guides.isEmpty }.count, 0, "the cleared lock turns nothing")
        try view.setSnap(nil)
    }
}
