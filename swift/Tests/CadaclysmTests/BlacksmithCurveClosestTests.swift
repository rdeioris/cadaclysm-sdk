// Closest points from a curve over the release library: a point within reach of a line, two skew
// lines and a line through or past the 2-cube pinned to their closed forms (literals, not read back
// through the wrapper), maxDistance on both sides, the projector equal to the one-shot, the nearest
// object naming its item with a curve's and a point's answer, and the refusals' words.
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

private func near3(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double, _ what: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: tol, what, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: tol, what, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: tol, what, file: file, line: line)
}

private func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>) throws -> NurbsCurve {
    try NurbsCurve([a, b], degree: 1)
}

private let shifts: [SIMD3<Double>] = [[0, 0, 0], [1e4, -1e4, 5e3], [1e6, -1e6, 5e5]]
private let sqrt2: Double = 1.4142135623730951
private let oneThird: Double = 1.0 / 3.0

/// 1e-12 relative to the shift's largest coordinate, as the other wrappers' tests take it.
private func scaled(_ s: SIMD3<Double>, _ base: Double) -> Double {
    let far: Double = max(abs(s.x), max(abs(s.y), abs(s.z)))
    return base * (1 + far)
}

final class BlacksmithCurveClosestTests: XCTestCase {
    func testAPointWithinReachOfALine() throws {
        for s in shifts {
            let tol = scaled(s, 1e-12)
            let line = try segment(s, s + [10, 0, 0])
            let p: SIMD3<Double> = s + [3, 4, 0]
            let foot = try XCTUnwrap(try line.closestPoint(p, maxDistance: 4.1))
            XCTAssertEqual(foot.t, 0.3, accuracy: 1e-12)
            near3(foot.point, s + [3, 0, 0], tol, "the foot at shift \(s)")
            XCTAssertTrue(foot.unique)
            XCTAssertNil(try line.closestPoint(p, maxDistance: 3.9))
            let unlimited = try line.closestPoint(p)
            XCTAssertEqual(try line.closestPoint(p, maxDistance: nil), unlimited)
            XCTAssertEqual(try line.closestPoint(p, maxDistance: .nan), unlimited)
            XCTAssertEqual(try line.closestPoint(p, maxDistance: .infinity), unlimited)
        }
        let line = try segment([0, 0, 0], [10, 0, 0])
        XCTAssertEqual(refusal { _ = try line.closestPoint([3, 4, 0], maxDistance: -1) },
                       "nurbs_curve_closest_point_within: the max distance must not be negative")
    }

    func testTwoSkewLinesMeetAtTheirClosedForm() throws {
        for s in shifts {
            let tol = scaled(s, 1e-12)
            let a = try segment(s, s + [10, 0, 0])
            let b = try segment(s + [3, -5, 2], s + [3, 5, 2])
            for limit in [2.1, nil, Double.nan, Double.infinity] as [Double?] {
                let pair = try XCTUnwrap(try a.closestPoints(b, maxDistance: limit), "limit \(String(describing: limit))")
                XCTAssertEqual(pair.distance, 2, accuracy: 1e-9)
                XCTAssertEqual(pair.tA, 0.3, accuracy: 1e-12)
                near3(pair.pointA, s + [3, 0, 0], tol, "point a at shift \(s)")
                XCTAssertEqual(pair.tB, 0.5, accuracy: 1e-12)
                near3(pair.pointB, s + [3, 0, 2], tol, "point b at shift \(s)")
            }
            let swapped = try XCTUnwrap(try b.closestPoints(a))
            XCTAssertEqual(swapped.tA, 0.5, accuracy: 1e-12)
            XCTAssertEqual(swapped.tB, 0.3, accuracy: 1e-12)
            near3(swapped.pointA, s + [3, 0, 2], tol, "swapped point a")
            XCTAssertNil(try a.closestPoints(b, maxDistance: 1.9))
            XCTAssertEqual(refusal { _ = try a.closestPoints(b, maxDistance: -1) },
                           "nurbs_curve_closest_points: the max distance must not be negative")
        }
    }

    func testALineThroughTheCubeCrossesItsFirstFace() throws {
        let cube = try Solid.cuboid(2, 2, 2)
        let through = try segment([-3, 0.1, 0.2], [3, 0.1, 0.2])
        let foot = try XCTUnwrap(try cube.curveClosestPoints(through))
        XCTAssertTrue(foot.crossing)
        XCTAssertEqual(foot.distance, 0)
        XCTAssertEqual(foot.t, oneThird, accuracy: 1e-9)
        near3(foot.pointOnCurve, [-1, 0.1, 0.2], 1e-9, "on the curve")
        near3(foot.pointOnBody, [-1, 0.1, 0.2], 1e-9, "on the body")
        XCTAssertEqual(foot.kind, "face")
        XCTAssertNil(foot.edge)
        XCTAssertNotNil(foot.uv)
        near3(foot.normal, [-1, 0, 0], 1e-9, "the -x face's normal")
        let projector = try cube.projector()
        XCTAssertEqual(try projector.curveClosestPoints(through), foot)
        for bad in [-1.0, Double.infinity] {
            XCTAssertEqual(refusal { _ = try cube.curveClosestPoints(through, tolerance: bad) },
                           "curve_closest_points: tolerance must be positive and finite")
        }
        XCTAssertNotNil(try cube.curveClosestPoints(through, tolerance: 0), "0 is an unset tolerance")
        XCTAssertEqual(refusal { _ = try cube.curveClosestPoints(through, maxDistance: -1) },
                       "curve_closest_points: the max distance must not be negative")
        XCTAssertEqual(refusal { _ = try projector.curveClosestPoints(through, maxDistance: -1) },
                       "projector_curve_closest_points: the max distance must not be negative")
        projector.close()
        XCTAssertEqual(refusal { _ = try projector.curveClosestPoints(through) }, "projector: closed")
    }

    func testALinePastAnEdgeAndAProjectorAnsweringAsTheOneShot() throws {
        for s in shifts {
            let tol = scaled(s, 1e-9)
            let cube = try Solid.cuboid(2, 2, 2).translate(s.x, s.y, s.z)
            let line = try segment(s + [2, -0.5, 2], s + [2.5, 0.5, 2.5])
            let projector = try cube.projector()
            let foot = try XCTUnwrap(try cube.curveClosestPoints(line, maxDistance: 1.5))
            XCTAssertFalse(foot.crossing)
            XCTAssertEqual(foot.kind, "edge")
            XCTAssertNil(foot.uv)
            XCTAssertEqual(foot.distance, sqrt2, accuracy: tol)
            XCTAssertEqual(foot.t, 0, accuracy: 1e-9)
            near3(foot.pointOnCurve, s + [2, -0.5, 2], tol, "on the curve at shift \(s)")
            near3(foot.pointOnBody, s + [1, -0.5, 1], tol, "on the edge at shift \(s)")
            let edge = try XCTUnwrap(foot.edge)
            let at = try cube.edgeClosestPoint(Int(edge), foot.pointOnCurve)
            near3(at.point, foot.pointOnBody, tol, "the public edge's foot")
            XCTAssertEqual(at.distance, foot.distance, accuracy: tol)
            XCTAssertNil(try cube.curveClosestPoints(line, maxDistance: 1.4))
            XCTAssertNil(try projector.curveClosestPoints(line, maxDistance: 1.4))
            XCTAssertEqual(try projector.curveClosestPoints(line, maxDistance: 1.5), foot)
            XCTAssertEqual(try projector.curveClosestPoints(line), try cube.curveClosestPoints(line))
            XCTAssertEqual(try cube.curveClosestPoints(line, maxDistance: .nan),
                           try cube.curveClosestPoints(line, maxDistance: .infinity))
        }
    }

    func testTheNearestObjectNamesItsItem() throws {
        let cube = try Solid.cuboid(2, 2, 2)
        let line = try segment([2, -0.5, 2], [2.5, 0.5, 2.5])
        let other = try segment([2, -0.5, 2.3], [2, 5, 2.3])   // sqrt(0.045) off `line`, at t 0.3
        let projector = try cube.projector()
        let gap: Double = 0.045.squareRoot()

        // A curve wins: answer kind 1, its pair.
        let near = try XCTUnwrap(try line.closestObject([.point([0, 0, 10]), .solid(cube), .curve(other), .projector(projector),
                                                         .point([9, 9, 9])]))
        let pair = try XCTUnwrap(try line.closestPoints(other))
        XCTAssertEqual(near.which, 2)
        XCTAssertEqual(near.answer, .curve(pair))
        XCTAssertEqual(near.distance, gap, accuracy: 1e-9)
        XCTAssertEqual(near.t, 0.3, accuracy: 1e-9)
        XCTAssertEqual(near.distance, pair.distance)
        XCTAssertEqual(near.t, pair.tA)
        XCTAssertEqual(near.pointOnCurve, pair.pointA)
        XCTAssertEqual(near.pointOnItem, pair.pointB)

        // A point wins: answer kind 2, no answer of its own.
        let point = try XCTUnwrap(try line.closestObject([.solid(cube), .point([2.5, 0.6, 2.5])]))
        XCTAssertEqual(point.which, 1)
        XCTAssertEqual(point.answer, .point)
        XCTAssertEqual(point.distance, 0.1, accuracy: 1e-9)
        XCTAssertEqual(point.t, 1, accuracy: 1e-9)
        XCTAssertEqual(point.pointOnItem, [2.5, 0.6, 2.5])
        near3(point.pointOnCurve, [2.5, 0.5, 2.5], 1e-9, "the point's foot on the curve")

        // A solid or a projector alone: the body's answer.
        let solid = try XCTUnwrap(try line.closestObject([.solid(cube)]))
        XCTAssertEqual(solid.which, 0)
        XCTAssertEqual(solid.answer, .body(try XCTUnwrap(try cube.curveClosestPoints(line))))
        let prepared = try XCTUnwrap(try line.closestObject([.projector(projector)], maxDistance: nil, tolerance: nil))
        XCTAssertEqual(prepared.answer, .body(try XCTUnwrap(try projector.curveClosestPoints(line))))

        XCTAssertNil(try line.closestObject([.solid(cube), .curve(other)], maxDistance: 0.2))
        XCTAssertEqual(try line.closestObject([.solid(cube), .curve(other)], maxDistance: 0.25)?.which, 1)
        XCTAssertNil(try line.closestObject([]))
        XCTAssertEqual(refusal { _ = try line.closestObject([.solid(cube)], maxDistance: -1) },
                       "nurbs_curve_closest_object: the max distance must not be negative")
        let nan = refusal { _ = try line.closestObject([.point([.nan, 0, 0])]) }
        XCTAssertTrue(nan?.hasPrefix("nurbs_curve_closest_object: ") ?? false, nan ?? "no error")
    }
}
