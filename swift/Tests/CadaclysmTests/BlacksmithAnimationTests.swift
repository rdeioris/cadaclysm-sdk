// The animation tracks over the release library: Python's test_animation_*, trimmed to what
// proves the marshalling -- the turntable placement, every field of a track read back, the
// shapes `valuesAt` answers, the nearest hold, every refusal's text, the handle's lifetime.
// The kernel's own correctness is the kernel's tests' job.
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

private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func near(_ a: [Double], _ b: [Double], _ eps: Double = 1e-12) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= eps }
}

/// `m` (column-major, 16 numbers) applied to the point `p`.
/// Spelled out: Swift 6.1 gives up type-checking the one-expression map/reduce form.
private func moved(_ m: [Double], _ p: [Double]) -> [Double] {
    var out = [Double](repeating: 0, count: 3)
    for r in 0..<3 {
        var sum: Double = m[12 + r]
        for c in 0..<3 {
            sum += m[c * 4 + r] * p[c]
        }
        out[r] = sum
    }
    return out
}

final class BlacksmithAnimationTests: XCTestCase {
    func testTurntableThroughRotate() throws {
        let a = try Animation()
        XCTAssertEqual(try a.count, 0)
        XCTAssertEqual(try a.duration, 0)
        XCTAssertEqual(try a.targets, [])
        XCTAssertEqual(try a.valuesAt(1), [])
        let k = try a.rotate("nut", [(time: 0, value: 0), (time: 4, value: 360)], pivot: SIMD3(1, 2, 0))
        XCTAssertEqual(k, 0)
        XCTAssertEqual(try a.count, 1)
        XCTAssertEqual(try a.targets, ["nut"])
        XCTAssertEqual(try a.duration, 4)
        let m = try a.placementAt("nut", 1)
        XCTAssertEqual(m.count, 16)
        XCTAssertTrue(near(moved(m, [2, 2, 0]), [1, 3, 0]), "\(m)")
        XCTAssertEqual(try a.placementAt(0, 1), m, "by name or by index")
        XCTAssertTrue(near(try a.placementAt("nut", 4), identity), "a full turn")
        XCTAssertEqual(try a.valueAt(0, 1)[0], 90, accuracy: 1e-12)
        let tr = try a.track(0)
        XCTAssertEqual(tr.channel, .rotate)
        XCTAssertEqual(tr.mode, .linear)
        XCTAssertEqual(tr.pivot, SIMD3(1, 2, 0))
        XCTAssertEqual(tr.axis, SIMD3(0, 0, 1))
        // A target with no placement track answers the identity.
        try a.colour("lamp", [(time: 0, value: SIMD3(1, 0, 0))])
        XCTAssertEqual(try a.placementAt("lamp", 2), identity)
        XCTAssertEqual(refusal { _ = try a.placementAt("nobody", 0) }, "animation: no target nobody")
        // Translate and scale, composed T * R * S.
        try a.translate("box", [(time: 0, value: SIMD3(0, 0, 0)), (time: 2, value: SIMD3(10, 0, 0))])
        try a.scale("box", [(time: 0, value: SIMD3(2, 2, 2))], pivot: SIMD3(1, 0, 0))
        XCTAssertTrue(near(moved(try a.placementAt("box", 1), [2, 0, 0]), [8, 0, 0]))
        XCTAssertEqual(AnimationChannel.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5, 6])
    }

    func testTrackReadsBackEveryField() throws {
        let a = try Animation()
        let dial = try a.value("dial", [(time: 0, value: [1, 2]), (time: 1, value: [3, 5]), (time: 3, value: [8, 13])],
                               mode: .cubic)
        XCTAssertEqual(dial, 0)
        XCTAssertEqual(try a.colour("lamp", [(time: 0.5, value: SIMD3(1, 0, 0)), (time: 2, value: SIMD3(0, 0.5, 1))]), 1)
        let tr = try a.track(0)
        XCTAssertEqual(tr.target, "dial")
        XCTAssertEqual(tr.channel, .value)
        XCTAssertEqual(tr.mode, .cubic)
        XCTAssertEqual(tr.dimension, 2)
        XCTAssertEqual(tr.times, [0, 1, 3])
        XCTAssertEqual(tr.values, [[1, 2], [3, 5], [8, 13]])
        XCTAssertEqual(tr.pivot, SIMD3(0, 0, 0))
        XCTAssertEqual(tr.axis, SIMD3(0, 0, 1))
        XCTAssertEqual(try a.track(0), tr, "equal by value")
        let lamp = try a.track(1)
        XCTAssertEqual([lamp.target, "\(lamp.channel)"], ["lamp", "colour"])
        XCTAssertEqual(lamp.dimension, 3)
        XCTAssertEqual(lamp.values, [[1, 0, 0], [0, 0.5, 1]])
        XCTAssertNotEqual(lamp, tr)
        try a.visible("lamp", [(time: 0, value: 1), (time: 2, value: 0)])
        let vis = try a.track(2)
        XCTAssertEqual(vis.dimension, 1)
        XCTAssertEqual(vis.values, [[1], [0]])
        XCTAssertEqual(vis.mode, .nearest)
        XCTAssertEqual(try a.targets, ["dial", "lamp"])
        XCTAssertEqual(try a.duration, 3)
        XCTAssertEqual(refusal { _ = try a.track(9) }, "animation_track_target: track 9 is not below 3")
    }

    func testValuesAtShapes() throws {
        let a = try Animation()
        try a.value("speed", [(time: 0, value: 0.0), (time: 2, value: 4.0)])
        try a.translate("box", [(time: 0, value: SIMD3(0, 0, 0)), (time: 2, value: SIMD3(2, 4, 6))])
        try a.ghost("box", [(time: 0, value: 0), (time: 1, value: 1)])
        let v = try a.valuesAt(1)
        XCTAssertEqual(v.count, 3)
        XCTAssertTrue(near(v[0], [2]) && near(v[1], [1, 2, 3]) && v[2] == [1], "\(v)")
        XCTAssertEqual(v, try (0..<3).map { try a.valueAt($0, 1) })
    }

    func testNearestHoldsAndModesDifferOnUnevenKeys() throws {
        let a = try Animation()
        try a.value("step", [(time: 0, value: 0.0), (time: 2, value: 10.0), (time: 3, value: 20.0)], mode: .nearest)
        let held = try [-1.0, 0, 1.99, 2, 2.5, 3, 9].map { try a.valueAt(0, $0)[0] }
        XCTAssertEqual(held, [0, 0, 0, 10, 10, 20, 20])
        // visible and ghost hold whatever mode was asked, and read the mode back as given.
        try a.addTrack("flag", .visible, [(time: 0, value: 0.0), (time: 1, value: 1.0)], mode: .linear)
        XCTAssertEqual(try a.valueAt(1, 0.9), [0])
        XCTAssertEqual(try a.track(1).mode, .linear)
        let keys: [(time: Double, value: Double)] = [(time: 0, value: 0), (time: 1, value: 1), (time: 3, value: 0)]
        let cubic = try a.value("c", keys, mode: .cubic)
        let catmull = try a.value("r", keys, mode: .catmullRom)
        let cosine = try a.value("o", [(time: 0, value: 0.0), (time: 2, value: 10.0)], mode: .cosine)
        XCTAssertEqual(try a.valueAt(cubic, 2)[0], 0.625, accuracy: 1e-12)
        XCTAssertEqual(try a.valueAt(catmull, 2)[0], 0.5625, accuracy: 1e-12)
        XCTAssertEqual(try a.valueAt(cosine, 0.5)[0], 10 * (1 - cos(Double.pi / 4)) / 2, accuracy: 1e-12)
        XCTAssertEqual(try [cubic, catmull, cosine].map { try a.track($0).mode }, [.cubic, .catmullRom, .cosine])
    }

    func testRefusals() throws {
        let a = try Animation()
        XCTAssertEqual(refusal { _ = try a.value("x", [(time: 0, value: [1, 2]), (time: 1, value: [1, 2, 3])]) },
                       "animation: key values differ in length")
        let kernel = refusal { _ = try a.value("x", [(time: 0, value: 0.0), (time: 1.5, value: 1.0), (time: 1, value: 2.0)]) }
        XCTAssertTrue(kernel?.hasPrefix("animation_add_track: times must increase: key 2 at 1 after 1.5") == true, "\(kernel ?? "nil")")
        let wrong = refusal { _ = try a.addTrack("x", .translate, [(time: 0, value: 1.0)]) }
        XCTAssertTrue(wrong?.hasPrefix("animation_add_track: ") == true, "\(wrong ?? "nil")")
        XCTAssertEqual(refusal { _ = try a.rotate("x", [(time: 0, value: 0)], axis: SIMD3(0, 0, 0)) },
                       "animation_set_pivot: the axis is too short")
        XCTAssertEqual(refusal { _ = try a.scale("x", [(time: 0, value: SIMD3(1, 1, 1))], pivot: SIMD3(.nan, 0, 0)) },
                       "animation_set_pivot: the pivot and axis must be finite")
        XCTAssertEqual(try a.count, 0, "every refusal leaves the animation as it was")
        let k = try a.value("x", [(time: 0, value: 0.0)])
        XCTAssertTrue(refusal { try a.setPivot(k, SIMD3(0, 0, 0)) }?
            .hasPrefix("animation_set_pivot: track 0 is value: only rotate and scale have a pivot") == true)
        XCTAssertEqual(refusal { _ = try a.valueAt(k, .nan) }, "animation_track_value_at: t NaN is not finite")
        try a.value("y", [(time: 0, value: 1.0)])
        XCTAssertEqual(refusal { _ = try a.valueAt(9, 0) }, "animation_track_value_at: track 9 is not below 2")
        XCTAssertEqual(refusal { _ = try a.track(2) }, "animation_track_target: track 2 is not below 2")
        XCTAssertEqual(refusal { _ = try a.track(-1) }, "animation_track_target: index -1 is out of range")
        XCTAssertEqual(refusal { _ = try a.valuesAt(.infinity) }?.hasPrefix("animation_values_at: t "), true)
        XCTAssertEqual(refusal { _ = try a.placementAt(5, 0) }?.hasPrefix("animation_placement_at: "), true)
        XCTAssertEqual(try a.count, 2)
        XCTAssertEqual(try a.targets, ["x", "y"])
    }

    func testCloneIsIndependentAndCloseTwiceIsANoOp() throws {
        let a = try Animation()
        try a.translate("box", [(time: 0, value: SIMD3(0, 0, 0)), (time: 1, value: SIMD3(1, 0, 0))])
        let b = try a.clone()
        try b.value("dial", [(time: 0, value: 5.0), (time: 7, value: 6.0)])
        XCTAssertEqual([try a.count, try b.count], [1, 2])
        XCTAssertEqual([try a.duration, try b.duration], [1, 7])
        XCTAssertEqual(try a.targets, ["box"])
        XCTAssertEqual(try b.targets, ["box", "dial"])
        a.close()
        XCTAssertTrue(a.isClosed)
        XCTAssertEqual(try b.track(0).target, "box", "the clone outlives its source")
        a.close()
        XCTAssertEqual(refusal { _ = try a.count }, "animation: closed")
        XCTAssertEqual(refusal { _ = try a.valuesAt(0) }, "animation: closed")
        XCTAssertEqual(refusal { _ = try a.clone() }, "animation: closed")
        XCTAssertEqual(refusal { try a.value("z", [(time: 0, value: 1.0)]) }, "animation: closed")
        b.close()
    }
}
