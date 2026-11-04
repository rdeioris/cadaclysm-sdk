// Swept clash over the release library: Python's test_swept_clash_*, trimmed to what proves the
// marshalling -- every field read, interval order, `first` a working `Clash` after the collider
// is closed, every refusal's prefix. A 2-cube moving along x from -5 to 5 through a 2-cube at the
// origin meets it at t = 0.3 and leaves at 0.7, at a relative speed of 10 a segment.
@testable import Blacksmith
import Foundation
import XCTest

/// The library's message for what `body` refused, or nil when it did not throw a BuildError.
private func refusal(_ body: () throws -> Void) -> String? {
    do {
        try body()
    } catch let error as BuildError {
        return error.message
    } catch {
        return "not a BuildError: \(error)"
    }
    return nil
}

/// The frame at (x, y, z) on the world axes.
private func at(_ x: Double, _ y: Double = 0, _ z: Double = 0) throws -> Frame {
    try Frame(values: [x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1])
}

private let tol = 1e-3, res = 1e-3

/// The 2-cube carried through the one standing at the origin.
private func through() throws -> [[Frame]] {
    [[try at(-5), try at(0)], [try at(5), try at(0)]]
}

private func startsNear(_ got: Double, _ want: Double, _ line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(got - want), tol / 10 + 1e-9, "start \(got), not \(want)", line: line)
}

private func endsNear(_ got: Double, _ want: Double, _ line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(got - want), res + tol / 10, "end \(got), not \(want)", line: line)
}

final class BlacksmithSweptClashTests: XCTestCase {
    func testSweptClashCubeThroughCubeReadsEveryFieldAndFirstOutlivesTheCollider() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: tol)
        var rows: [SweptClash]? = try collider.sweptClash(try through())
        collider.close()
        XCTAssertEqual(rows?.count, 1)
        let r = try XCTUnwrap(rows?.first)
        rows = nil
        XCTAssertEqual(r.a, 0)
        XCTAssertEqual(r.b, 1)
        startsNear(r.firstTime, 0.3)
        XCTAssertEqual(r.intervals.count, 1)
        let span = try XCTUnwrap(r.intervals.first)
        XCTAssertEqual(span.start, r.firstTime)
        endsNear(span.end, 0.7)
        XCTAssertEqual(r.first.a, 0)
        XCTAssertEqual(r.first.b, 1)
        XCTAssertEqual(r.first.kind, "touching")
        XCTAssertTrue(refusal { _ = try r.first.solid() }?.hasPrefix("clashes_solid: pair (0, 1) is not penetrating") ?? false)
        let x = try r.first.intersect()
        XCTAssertEqual(x.overlaps.count, 1)
        let loops = try XCTUnwrap(x.overlaps.first?.loops)
        XCTAssertFalse(loops.isEmpty)
        for ring in loops {
            XCTAssertFalse(ring.isEmpty)
            for p in ring { XCTAssertLessThanOrEqual(abs(p.x + 1), 2 * tol) }
        }
        XCTAssertTrue(r.description.hasPrefix("SweptClash(a=0, b=1, first_time="))
    }

    func testSweptClashThereAndBackGivesTwoIntervalsInOrder() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: tol)
        defer { collider.close() }
        let rows = try collider.sweptClash(try through() + [[try at(-5), try at(0)]])
        XCTAssertEqual(rows.count, 1)
        let spans = try XCTUnwrap(rows.first).intervals
        XCTAssertEqual(spans.count, 2)
        guard spans.count == 2 else { return }
        startsNear(spans[0].start, 0.3)
        endsNear(spans[0].end, 0.7)
        startsNear(spans[1].start, 1.3)
        endsNear(spans[1].end, 1.7)
    }

    func testSweptClashAMissIsSeenOnlyWithinTheClearance() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: tol)
        defer { collider.close() }
        let passing = [[try at(-5, 2.5), try at(0)], [try at(5, 2.5), try at(0)]]
        XCTAssertTrue(try collider.sweptClash(passing, clearance: 0.4).isEmpty)
        let rows = try collider.sweptClash(passing, clearance: 0.6)
        XCTAssertEqual(rows.count, 1)
        let first = try XCTUnwrap(rows.first).first
        XCTAssertEqual(first.kind, "too_close")
        XCTAssertGreaterThanOrEqual(first.distance, 0.5 - tol)
        XCTAssertLessThanOrEqual(first.distance, 0.6)
    }

    func testSweptClashStartingInsideRebuildsTheOverlapAtTimeZero() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: tol)
        defer { collider.close() }
        let rows = try collider.sweptClash([[try at(1.75), try at(0)], [try at(5), try at(0)]])
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.firstTime, 0)
        XCTAssertEqual(r.first.kind, "penetrating")
        let mass: Mass = try r.first.solid().mass()
        XCTAssertEqual(mass.volume, 1, accuracy: 1e-6)
    }

    func testSweptClashOneShotIndexesTheSecondSetAndHonoursAllowed() throws {
        let a0 = try Solid.cuboid(2, 2, 2), a1 = try Solid.cuboid(2, 2, 2).translate(0, 20, 0)
        let b0 = try Solid.cuboid(2, 2, 2), b1 = try Solid.cuboid(2, 2, 2)
        let still = [[try at(0), try at(0)], [try at(0), try at(0)]]
        let moving = [[try at(-5), try at(-5, 20)], [try at(5), try at(5, 20)]]
        let two = try sweptClash([a0, a1], still, others: [b0, b1], otherPoses: moving, tolerance: tol)
        XCTAssertEqual(two.map { "\($0.a) \($0.b)" }, ["0 0", "1 1"])
        XCTAssertEqual(two.map { "\($0.first.a) \($0.first.b)" }, ["0 0", "1 1"])
        let across = [[try at(0), try at(-5)], [try at(0), try at(5)]]
        let one = try sweptClash([a0, b0], across, tolerance: tol)
        XCTAssertEqual(one.map { "\($0.a) \($0.b)" }, ["0 1"])
        XCTAssertTrue(try sweptClash([a0, b0], across, tolerance: tol, allowed: [0, 1]).isEmpty)
    }

    func testSweptClashRefusalsCarryTheCallsPrefix() throws {
        let a = try Solid.cuboid(2, 2, 2), b = try Solid.cuboid(2, 2, 2)
        let collider = try Collider([a, b], tolerance: tol)
        defer { collider.close() }
        func refused(_ prefix: String, _ line: UInt = #line, _ body: () throws -> Void) {
            let message = refusal(body)
            XCTAssertTrue(message?.hasPrefix(prefix) ?? false, "expected '\(prefix)...', got \(message ?? "no refusal")", line: line)
        }
        let path = try through()
        refused("collider_swept_clash: 1 poses, at least 2 are needed") { _ = try collider.sweptClash(Array(path.prefix(1))) }
        refused("collider_swept_clash: 1 frames for 2 groups") { _ = try collider.sweptClash([[try at(0)], [try at(0)]]) }
        refused("collider_swept_clash: 1 frames for 2 groups") { _ = try collider.sweptClash([[try at(0), try at(0)], [try at(0)]]) }
        refused("collider_swept_clash: resolution 0") { _ = try collider.sweptClash(path, resolution: 0) }
        refused("collider_swept_clash: max_steps must be at least 1") { _ = try collider.sweptClash(path, maxSteps: 0) }
        refused("collider_swept_clash: clearance -1") { _ = try collider.sweptClash(path, clearance: -1) }
        refused("collider_swept_clash: share (2, 2)") { _ = try collider.sweptClash(path, share: (2, 2)) }

        let still = [[try at(0)], [try at(0)]]
        refused("swept_clash: others and other_poses go together") { _ = try sweptClash([a], still, others: [b]) }
        refused("swept_clash: others and other_poses go together") { _ = try sweptClash([a], still, otherPoses: still) }
        refused("swept_clash: 2 poses for set a, 1 for set b") {
            _ = try sweptClash([a], still, others: [b], otherPoses: Array(still.prefix(1)))
        }
        refused("swept_clash: pose 1 of set b has 2 frames for 1 parts") {
            _ = try sweptClash([a], still, others: [b], otherPoses: [[try at(0)], [try at(0), try at(0)]])
        }
        refused("swept_clash: an empty set") { _ = try sweptClash([a], still, others: [], otherPoses: [[], []]) }
        refused("swept_clash: allowed pair (5, 0) names a part out of range") { _ = try sweptClash([a, b], path, allowed: [5, 0]) }
        refused("swept_clash: allowed is 3 numbers, not pairs") { _ = try sweptClash([a, b], path, allowed: [0, 1, 0]) }
        refused("swept_clash: max_steps must be at least 1") { _ = try sweptClash([a, b], path, maxSteps: 0) }
        refused("swept_clash: 1 poses, at least 2 are needed") { _ = try sweptClash([a, b], Array(path.prefix(1))) }
    }
}

// An assembly's swept clash: Python's test_assembly_* swept tests, trimmed to the marshalling.
// The rig: a `base` plate on link `ground`; an `arm`, cuboid(3, 0.2, 0.2) from the hinge out
// along x, on link `arm`, turning on `hinge` (revolute about z through the origin); a
// `carriage` far out on `slide` (cylindrical, two values); and two cubes in no link, held
// fixed: `chord` below the hinge, which the chord between the arm's end poses crosses and its
// arc never does, and `circle` on the arm's circle at 90 degrees.
private func makeRig(_ hand: Assembly? = nil) throws -> Assembly {
    let rig = try Assembly("rig")
    try rig.place(try Solid.cuboid(1, 1, 0.4), try at(0, 0, -1), name: "base")
    if let hand {
        try rig.place(hand, try at(1.5), name: "hand")
    } else {
        try rig.place(try Solid.cuboid(3, 0.2, 0.2), try at(1.5), name: "arm")
    }
    try rig.place(try Solid.cuboid(0.4, 0.4, 0.4), try at(0, -1.2), name: "chord")
    try rig.place(try Solid.cuboid(0.4, 0.4, 0.4), try at(0, 1.5), name: "circle")
    try rig.place(try Solid.cuboid(0.4, 0.4, 0.4), try at(20), name: "carriage")
    try rig.link("ground", ["base"])
    try rig.link("arm", [hand == nil ? "arm" : "hand"])
    try rig.link("carriage", ["carriage"])
    for (joint, end, kind) in [("hinge", "arm", "revolute"), ("slide", "carriage", "cylindrical")] {
        try rig.joint(joint, "ground", end)
        try rig.pair(joint, kind, try at(0))
    }
    try rig.base("ground")
    return rig
}

/// A `tip` cube on link `body`, and a `nub` well above it on `nubs`, turning on `turn`.
private func makeHand() throws -> Assembly {
    let hand = try Assembly("hand")
    try hand.place(try Solid.cuboid(0.4, 0.4, 0.4), try at(0), name: "tip")
    try hand.place(try Solid.cuboid(0.2, 0.2, 0.2), try at(0, 0, 2), name: "nub")
    try hand.link("body", ["tip"])
    try hand.link("nubs", ["nub"])
    try hand.joint("turn", "body", "nubs")
    try hand.pair("turn", "revolute", try at(0))
    return hand
}

/// The hinge at 0, 90 and 180 degrees, the carriage sliding 0, 0.5, 1 unturned.
private let swing: [[(String, [Double])]] = [
    [("hinge", [0]), ("slide", [0, 0])],
    [("hinge", [Double.pi / 2]), ("slide", [0.5, 0])],
    [("hinge", [Double.pi]), ("slide", [1, 0])],
]

/// The time the arm's leading face (y = 0.1 in its own frame) is `gap` from the circle cube's
/// corner (0.2, 1.3), the first point it meets, in the first segment.
private func circleTime(_ gap: Double) -> Double {
    let r = (1.3 * 1.3 + 0.2 * 0.2).squareRoot(), phi = atan2(0.2, 1.3)
    return (acos((0.1 + gap) / r) - phi) / (Double.pi / 2)
}

final class BlacksmithAssemblySweptClashTests: XCTestCase {
    func testAssemblyPartsAreListedDepthFirstAndEscaped() throws {
        let sub = try Assembly("pair")
        try sub.place(try Solid.cuboid(1, 1, 1), try at(0), name: "x")
        try sub.place(try Solid.cuboid(1, 1, 1), try at(2), name: "y")
        let top = try Assembly("top")
        try top.place(try Solid.cuboid(1, 1, 1), try at(0, 5), name: "p")
        try top.place(sub, try at(0), name: "a/b")
        try top.place(try Solid.cuboid(1, 1, 1), try at(0, 9), name: "q")
        XCTAssertEqual(try top.parts(), ["p", "a\\/b/x", "a\\/b/y", "q"])
        XCTAssertEqual(try Assembly("empty").parts(), [])
    }

    func testAssemblySweptClashSweepsTheArcNotTheChord() throws {
        let rig = try makeRig()
        let names = try rig.parts()
        XCTAssertEqual(names, ["base", "arm", "chord", "circle", "carriage"])
        let rows = try rig.sweptClash(swing, tolerance: tol)
        XCTAssertEqual(rows.map { "\(names[$0.a]) \(names[$0.b])" }, ["arm circle"])
        let r = try XCTUnwrap(rows.first)
        let first: Clash = r.first
        XCTAssertEqual(first.a, r.a)
        let within = circleTime(tol), meets = circleTime(0)
        XCTAssertGreaterThanOrEqual(r.firstTime, within - 1e-9)
        XCTAssertLessThanOrEqual(r.firstTime, meets + 1e-9)
    }

    func testAssemblySweptClashFirstIsAtThePosedFrames() throws {
        // the arm starts at 1.5 rad, already through the circle cube: penetrating at time 0, and
        // the overlap rebuilt from the first row lies inside the arm's box turned 1.5 about z
        let rig = try makeRig()
        let rows = try rig.sweptClash([[("hinge", [1.5]), ("slide", [0, 0])], [("hinge", [Double.pi]), ("slide", [0, 0])]],
                                      tolerance: tol)
        XCTAssertEqual(rows.map { "\($0.a) \($0.b) \($0.firstTime)" }, ["1 3 0.0"])
        let got = try XCTUnwrap(rows.first).first.solid().boundsBoxAt(tol)
        let co = cos(1.5), si = sin(1.5)
        let want = try Solid.cuboid(3, 0.2, 0.2).translate(1.5, 0, 0).boundsBoxAt(tol)
            .moved(try Frame(values: [0, 0, 0, co, si, 0, -si, co, 0, 0, 0, 1]))
        for k in 0..<3 {
            XCTAssertGreaterThanOrEqual(got.lo[k], want.lo[k] - 1e-6, "\(got) in \(want)")
            XCTAssertLessThanOrEqual(got.hi[k], want.hi[k] + 1e-6, "\(got) in \(want)")
        }
        XCTAssertGreaterThanOrEqual(got.lo.y, 1.3 - 4 * tol)
        XCTAssertLessThanOrEqual(got.hi.y, 1.7 + 4 * tol)
        XCTAssertGreaterThan(got.hi.x, got.lo.x)
    }

    func testAssemblySweptClashTestsJoinedLinksOnlyWhenAsked() throws {
        let pinned = try Assembly("pinned")
        try pinned.place(try Solid.cuboid(0.6, 0.6, 0.6), try at(0), name: "bore")
        try pinned.place(try Solid.cuboid(0.2, 0.2, 0.2), try at(0), name: "pin")
        try pinned.link("ground", ["bore"])
        try pinned.link("arm", ["pin"])
        try pinned.joint("hinge", "ground", "arm")
        try pinned.pair("hinge", "revolute", try at(0))
        let keys: [[(String, [Double])]] = [[("hinge", [0])], [("hinge", [1])]]
        XCTAssertTrue(try pinned.sweptClash(keys, tolerance: tol).isEmpty)
        let rows = try pinned.sweptClash(keys, tolerance: tol, joined: true)
        XCTAssertEqual(rows.map { "\($0.a) \($0.b) \($0.firstTime)" }, ["0 1 0.0"])
        XCTAssertTrue(try pinned.sweptClash(keys, tolerance: tol, allowed: [0, 1], joined: true).isEmpty)
    }

    func testAssemblySweptClashASubAssemblyRidesItsPlacementsLink() throws {
        let rig = try makeRig(try makeHand())
        let names = try rig.parts()
        XCTAssertEqual(names, ["base", "hand/tip", "hand/nub", "chord", "circle", "carriage"])
        let rows = try rig.sweptClash(swing, tolerance: tol)
        XCTAssertEqual(rows.map { "\(names[$0.a]) \(names[$0.b])" }, ["hand/tip circle"])
    }

    func testAssemblySweptClashRefusesInTheKernelsWords() throws {
        let rig = try makeRig(try makeHand())
        let two: [[(String, [Double])]] = [[("hinge", [0])], [("hinge", [1])]]
        func refused(_ want: String, _ line: UInt = #line, _ body: () throws -> Void) {
            XCTAssertEqual(refusal(body), want, line: line)
        }
        // keyframes naming different joints, refused before C is called
        refused("swept_clash: joint 'slide' is in keyframe 0 and not in keyframe 2") {
            _ = try rig.sweptClash([[("hinge", [0]), ("slide", [0, 0])], [("hinge", [1]), ("slide", [0, 0])], [("hinge", [2])]])
        }
        refused("swept_clash: joint 'slide' is in keyframe 1 and not in keyframe 0") {
            _ = try rig.sweptClash([[("hinge", [0])], [("hinge", [1]), ("slide", [0, 0])]])
        }
        refused("swept_clash: joint 'hinge' is given twice") {
            _ = try rig.sweptClash([[("hinge", [0])], [("hinge", [1]), ("hinge", [2])]])
        }
        refused("swept_clash: joint 'slide' has 2 values in keyframe 0 and 1 in keyframe 1") {
            _ = try rig.sweptClash([[("slide", [0, 0])], [("slide", [1])]])
        }
        refused("swept_clash: allowed is 3 numbers, not pairs") { _ = try rig.sweptClash(two, allowed: [0, 1, 2]) }
        // and the kernel's own refusals, passed on
        refused("swept_clash: joint 'hand/turn' is in a sub-assembly; a sweep moves this assembly's own joints") {
            _ = try rig.sweptClash([[("hand/turn", [0])], [("hand/turn", [1])]])
        }
        refused("swept_clash: no joint named 'elbow' in assembly 'rig' or under it") {
            _ = try rig.sweptClash([[("elbow", [0])], [("elbow", [1])]])
        }
        refused("swept_clash: joint 'hinge' takes 1 values, but 2 were given") {
            _ = try rig.sweptClash([[("hinge", [0, 0])], [("hinge", [1, 1])]])
        }
        refused("swept_clash: 1 poses, at least 2 are needed") { _ = try rig.sweptClash(Array(two.prefix(1))) }
        XCTAssertTrue(refusal { _ = try rig.sweptClash(two, resolution: 0) }?.hasPrefix("swept_clash: resolution 0") ?? false)
        refused("swept_clash: max_steps must be at least 1") { _ = try rig.sweptClash(two, maxSteps: 0) }
        refused("swept_clash: allowed pair (9, 0) names a part out of range") { _ = try rig.sweptClash(two, allowed: [9, 0]) }
        refused("swept_clash: assembly 'rig' has no link named 'wheel'") { _ = try rig.sweptClash(two, ground: "wheel") }
    }
}
