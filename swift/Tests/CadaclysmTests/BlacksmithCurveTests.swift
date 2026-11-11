// Sketch curves as profiles: Python's test_sketch_curves_are_profiles_that_draw_as_beziers and
// test_open_sketch_curves_close_into_loops, the same numbers.
@testable import Blacksmith
import CCadaclysmBlacksmith
import Foundation
import XCTest

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

final class BlacksmithCurveTests: XCTestCase {
    private func volume(_ p: Profile) throws -> Double {
        let solid = try Solid.extrude(p, try Frame.xy(), 1)
        let mass: Mass = try solid.mass()
        return mass.volume
    }

    func testSketchCurvesAreProfilesThatDrawAsBeziers() throws {
        let line = try Profile.polyline([SIMD2(1, 2), SIMD2(4, 6)])
        let third: Double = 10.0 / 3.0
        let fourteenThirds: Double = 14.0 / 3.0
        let want: [Double] = [1, 2, 0, 1, 2, third, 0, 1, 3, fourteenThirds, 0, 1, 4, 6, 0, 1]
        let got = try line.beziers()
        XCTAssertEqual(got.count, 16)
        for (g, w) in zip(got, want) { XCTAssertEqual(g, w, accuracy: 1e-9) }
        XCTAssertEqual(try Profile.polyline([SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 3)], closed: true).beziers().count, 3 * 16)
        let circle = try Profile.arc(SIMD2(1, 2), 3, 0, 0)
        let flat = try circle.beziers()
        XCTAssertEqual(flat.count, 4 * 16)
        let conic: Double = (0.5 as Double).squareRoot() * 2.0 / 3.0 + 1.0 / 3.0
        for k in stride(from: 0, to: flat.count, by: 16) {
            XCTAssertEqual(hypot(flat[k] - 1, flat[k + 1] - 2), 3, accuracy: 1e-9)
            XCTAssertEqual(flat[k + 3], 1, accuracy: 1e-9)
            XCTAssertEqual(flat[k + 7], conic, accuracy: 1e-9)
        }
        let reference = try volume(try Profile.circle(3))
        XCTAssertEqual(try volume(circle), reference, accuracy: 1e-6 * reference)
        let quarter = try Profile.arc(SIMD2(0, 0), 2, 0, Double.pi / 2).beziers()
        XCTAssertEqual(quarter[12], 0, accuracy: 1e-12)
        XCTAssertEqual(quarter[13], 2, accuracy: 1e-12)
        let ellipse = try Profile.ellipse(SIMD2(0, 0), 3, 1)
        XCTAssertEqual(try ellipse.beziers().count, 4 * 16)
        XCTAssertEqual(try volume(ellipse), Double.pi * 3, accuracy: 1e-2 * Double.pi * 3)
        // Through a middle point: the arc that passes it, whichever side it is on.
        let up = try Profile.arcThrough(SIMD2(0, 0), SIMD2(2, 2), SIMD2(4, 0)).beziers()
        let down = try Profile.arcThrough(SIMD2(0, 0), SIMD2(2, -2), SIMD2(4, 0)).beziers()
        XCTAssertEqual(stride(from: 1, to: up.count, by: 4).map { up[$0] }.max() ?? 0, 2, accuracy: 1e-9)
        XCTAssertEqual(stride(from: 1, to: down.count, by: 4).map { down[$0] }.min() ?? 0, -2, accuracy: 1e-9)
        // Carried onto a plane: the Front plane five along -y.
        let front = try Frame(SIMD3(0, -5, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0))
        let onFront = try line.beziers(frame: front)
        XCTAssertEqual(onFront[0], 1, accuracy: 1e-9)
        XCTAssertEqual(onFront[1], -5, accuracy: 1e-9)
        XCTAssertEqual(onFront[2], 2, accuracy: 1e-9)
        XCTAssertEqual(onFront[12], 4, accuracy: 1e-9)
        XCTAssertEqual(onFront[13], -5, accuracy: 1e-9)
        XCTAssertEqual(onFront[14], 6, accuracy: 1e-9)
        // And back: kept exact, they round-trip; recognised, a circle is arcs again.
        let again = try Profile.fromBeziers(flat, recognise: false).beziers()
        XCTAssertEqual(again.count, flat.count)
        for (g, w) in zip(again, flat) { XCTAssertEqual(g, w, accuracy: 1e-9) }
        let cylinder = try Solid.extrude(try Profile.fromBeziers(flat), try Frame.xy(), 1)
        for i in 0..<(try cylinder.faces) {
            let kind = try cylinder.faceKind(i)
            XCTAssertTrue(kind == "cylinder" || kind == "plane", kind)
        }
        XCTAssertEqual(refusal { _ = try Profile.arcThrough(SIMD2(0, 0), SIMD2(1, 1), SIMD2(2, 2)) }?
            .hasPrefix("profile_arc_through: the arc's three points are in a line"), true)
        XCTAssertEqual(refusal { _ = try Profile.polyline([SIMD2(0, 0)]) }?
            .hasPrefix("profile_polyline: a polyline needs at least two points"), true)
        XCTAssertEqual(refusal { _ = try Profile.fromBeziers([]) }?.hasPrefix("profile_from_beziers: "), true)
    }

    func testOpenSketchCurvesCloseIntoLoops() throws {
        let dLine = try Profile.polyline([SIMD2(0, 0), SIMD2(4, 0)])
        let dArc = try Profile.arcThrough(SIMD2(4, 0), SIMD2(2, 2), SIMD2(0, 0))
        let stray = try Profile.polyline([SIMD2(9, 9), SIMD2(10, 9)])
        let ring = try Profile.arc(SIMD2(20, 0), 1, 0, 0)
        XCTAssertEqual(try Profile.loops([stray, dLine, ring, dArc]), [[1, 3], [2]])
        // A corner where three ends meet is ambiguous: no loop through it.
        let spur = try Profile.polyline([SIMD2(0, 0), SIMD2(-3, 0)])
        XCTAssertEqual(try Profile.loops([dLine, dArc, spur]), [])
        // The chain's order: the arc first here, then the line -- neither turned round.
        let order = try Profile.chainOrder([dArc, dLine])
        XCTAssertEqual(order.map { $0.index }, [0, 1])
        XCTAssertEqual(order.map { $0.turned }, [false, false])
        let turned = try Profile.chainOrder([dLine, try Profile.polyline([SIMD2(7, 0), SIMD2(4, 0)])])
        XCTAssertEqual(turned.map { $0.index }, [0, 1])
        XCTAssertEqual(turned.map { $0.turned }, [false, true])
        XCTAssertEqual(refusal { _ = try Profile.chainOrder([dLine, stray]) }?
            .hasPrefix("chain: piece 1 does not meet the others"), true)
        let holed = try Profile.rect(9, 9).withHole(try Profile.circle(1))
        XCTAssertEqual(refusal { _ = try Profile.loops([holed]) }?
            .hasPrefix("profile_loops: piece 0 has holes"), true)
    }
}
