// Closest points against an untrimmed NURBS surface over the release library: a flat 2 x 2 sheet's
// interior, beyond-an-edge and beyond-a-corner feet, a line through it and a line beside its edge,
// pinned to their closed forms (literals, not read back through the wrapper) at the origin and
// shifted far out; maxDistance on both sides, a weighted net's read-backs, a solid's face surfaces,
// a surface's sheet, the nearest object naming a surface item, and the refusals' words.
@testable import Blacksmith
import CCadaclysmBlacksmith
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

/// `base` relative to the shift's largest coordinate, as the other wrappers' tests take it.
private func scaled(_ s: SIMD3<Double>, _ base: Double) -> Double {
    let far: Double = max(abs(s.x), max(abs(s.y), abs(s.z)))
    return base * (1 + far)
}

/// 2 x 2 points of degree 1: S(u, v) = (u, v, 0) over [0, 1]^2, its normal +z.
private let sheetNet: [SIMD3<Double>] = [[0, 0, 0], [0, 1, 0], [1, 0, 0], [1, 1, 0]]

private func sheetOf(_ s: SIMD3<Double>) throws -> NurbsSurface {
    try NurbsSurface(sheetNet.map { $0 + s }, counts: (2, 2), degreeU: 1, degreeV: 1)
}

private let root2: Double = 2.0.squareRoot()

final class BlacksmithSurfaceClosestTests: XCTestCase {
    func testANurbsSurfaceHoldsItsNetAndReadsBack() throws {
        for s in shifts {
            let sheet = try sheetOf(s)
            XCTAssertEqual(try sheet.degreeU, 1)
            XCTAssertEqual(try sheet.degreeV, 1)
            let counts = try sheet.counts
            XCTAssertEqual(counts.nU, 2)
            XCTAssertEqual(counts.nV, 2)
            let domain = try sheet.domain
            XCTAssertEqual(domain.u, try Interval(0, 1))
            XCTAssertEqual(domain.v, try Interval(0, 1))
            near3(try sheet.pointAt(0.25, 0.75), s + [0.25, 0.75, 0], scaled(s, 1e-12), "pointAt at shift \(s)")
            near3(try sheet.normalAt(0.25, 0.75), [0, 0, 1], 1e-12, "normalAt")
        }
        // weights and knots reach the surface: a 3 x 2 net over u in [2, 6], v in [-1, 1]
        let net: [SIMD3<Double>] = [[0, 0, 0], [0, 1, 0], [1, 0, 1], [1, 1, 1], [2, 0, 0], [2, 1, 0]]
        let w = try NurbsSurface(net, counts: (3, 2), degreeU: 2, degreeV: 1, weights: [1, 1, 2, 2, 1, 1],
                                 knotsU: [2, 2, 2, 6, 6, 6], knotsV: [-1, -1, 1, 1])
        XCTAssertEqual(try w.counts.nU, 3)
        XCTAssertEqual(try w.counts.nV, 2)
        XCTAssertEqual(try w.degreeU, 2)
        XCTAssertEqual(try w.domain.u, try Interval(2, 6))
        XCTAssertEqual(try w.domain.v, try Interval(-1, 1))
        let twoThirds: Double = 2.0 / 3.0
        near3(try w.pointAt(4, -1), [1, 0, twoThirds], 1e-12, "the weights reach the surface")
        XCTAssertTrue(refusal { _ = try w.pointAt(1, 0) }?.hasPrefix("nurbs_surface_point_at: ") ?? false)
        // the refusals, exactly: a bad grid count (the wrapper's), a degree out of range (the library's)
        XCTAssertEqual(refusal { _ = try NurbsSurface(sheetNet, counts: (2, 3), degreeU: 1, degreeV: 1) },
                       "nurbs_surface_new: 2 x 3 points take 18 numbers, got 12")
        XCTAssertEqual(refusal { _ = try NurbsSurface(sheetNet, counts: (2, 2), degreeU: 0, degreeV: 1) },
                       "nurbs_surface_new: u degree 0 is not 1 to 7")
        XCTAssertEqual(refusal { _ = try NurbsSurface(sheetNet, counts: (2, 2), degreeU: 1, degreeV: 1, weights: [1, 1]) },
                       "nurbs_surface_new: 2 weights for 4 points")
        XCTAssertEqual("\(try sheetOf([0, 0, 0]))", "NurbsSurface(degrees 1 x 1, 2 x 2 points)")
    }

    func testASurfacePointNamesItsBoundaryAndNormalInClosedForm() throws {
        for s in shifts {
            let tol = scaled(s, 1e-9)
            let sheet = try sheetOf(s)
            let inside = try XCTUnwrap(try sheet.closestPoint(s + [0.3, 0.4, 1]))
            XCTAssertFalse(inside.boundary)
            near3(inside.point, s + [0.3, 0.4, 0], tol, "the interior point at shift \(s)")
            XCTAssertEqual(inside.distance, 1, accuracy: tol)
            XCTAssertEqual(inside.u, 0.3, accuracy: 1e-9)
            XCTAssertEqual(inside.v, 0.4, accuracy: 1e-9)
            near3(inside.normal, [0, 0, 1], 1e-9, "the interior normal")

            let edge = try XCTUnwrap(try sheet.closestPoint(s + [2, 0.5, -1]))
            XCTAssertTrue(edge.boundary)
            XCTAssertEqual(edge.u, 1)
            XCTAssertEqual(edge.v, 0.5, accuracy: 1e-9)
            XCTAssertEqual(edge.distance, root2, accuracy: tol)
            near3(edge.point, s + [1, 0.5, 0], tol, "the edge point at shift \(s)")

            let corner = try XCTUnwrap(try sheet.closestPoint(s + [2, 2, 0]))
            XCTAssertTrue(corner.boundary)
            XCTAssertEqual(corner.u, 1)
            XCTAssertEqual(corner.v, 1)
            XCTAssertEqual(corner.distance, root2, accuracy: tol)
            near3(corner.point, s + [1, 1, 0], tol, "the corner at shift \(s)")

            // the limit on both sides; nil, NaN and +inf are none
            let p = s + [0.3, 0.4, 1]
            XCTAssertEqual(try sheet.closestPoint(p, maxDistance: 1.1), inside)
            XCTAssertNil(try sheet.closestPoint(p, maxDistance: 0.9))
            XCTAssertEqual(try sheet.closestPoint(p, maxDistance: nil), inside)
            XCTAssertEqual(try sheet.closestPoint(p, maxDistance: .nan), inside)
            XCTAssertEqual(try sheet.closestPoint(p, maxDistance: .infinity), inside)
        }
        let sheet = try sheetOf([0, 0, 0])
        XCTAssertNotNil(try sheet.closestPoint([0.5, 0.5, 0], maxDistance: 0), "a point on the surface is within 0")
        XCTAssertEqual(refusal { _ = try sheet.closestPoint([0.5, 0.5, 1], maxDistance: -1) },
                       "nurbs_surface_closest_point: the max distance must not be negative")
        XCTAssertEqual(refusal { _ = try sheet.closestPoint([.nan, 0, 0]) }, "nurbs_surface_closest_point: not finite")
    }

    func testALineThroughANurbsSurfaceCrossesItAndALineBesideAnswersTheEdge() throws {
        for s in shifts {
            let tol = scaled(s, 1e-9)
            let sheet = try sheetOf(s)
            let through = try segment(s + [0.25, 0.5, -1], s + [0.25, 0.5, 1])
            let foot = try XCTUnwrap(try sheet.curveClosestPoints(through))
            XCTAssertTrue(foot.crossing)
            XCTAssertEqual(foot.distance, 0)
            XCTAssertFalse(foot.boundary)
            XCTAssertEqual(foot.t, 0.5, accuracy: 1e-9)
            XCTAssertEqual(foot.u, 0.25, accuracy: 1e-9)
            XCTAssertEqual(foot.v, 0.5, accuracy: 1e-9)
            near3(foot.pointOnCurve, s + [0.25, 0.5, 0], tol, "the crossing on the curve at shift \(s)")
            near3(foot.pointOnSurface, foot.pointOnCurve, tol, "the crossing on the surface at shift \(s)")
            near3(foot.normal, [0, 0, 1], 1e-9, "the crossing's normal")

            // a line beside the u = 1 edge: the edge answers, boundary true, 1 away at t 0.5
            let beside = try segment(s + [2, 0.5, -1], s + [2, 0.5, 1])
            let side = try XCTUnwrap(try sheet.curveClosestPoints(beside, maxDistance: 1.1))
            XCTAssertFalse(side.crossing)
            XCTAssertTrue(side.boundary)
            XCTAssertEqual(side.u, 1)
            XCTAssertEqual(side.distance, 1, accuracy: tol)
            XCTAssertEqual(side.t, 0.5, accuracy: 1e-9)
            XCTAssertEqual(side.v, 0.5, accuracy: 1e-9)
            near3(side.pointOnSurface, s + [1, 0.5, 0], tol, "beside, on the surface at shift \(s)")
            near3(side.pointOnCurve, s + [2, 0.5, 0], tol, "beside, on the curve at shift \(s)")
            XCTAssertNil(try sheet.curveClosestPoints(beside, maxDistance: 0.9))
            XCTAssertEqual(try sheet.curveClosestPoints(beside), side)
            XCTAssertEqual(try sheet.curveClosestPoints(beside, maxDistance: .nan), side)
            XCTAssertEqual(try sheet.curveClosestPoints(beside, maxDistance: .infinity), side)
            XCTAssertEqual(refusal { _ = try sheet.curveClosestPoints(beside, maxDistance: -1) },
                           "nurbs_surface_curve_closest_points: the max distance must not be negative")
        }
    }

    func testASolidsFaceSurfaceAndASurfacesSheet() throws {
        let cube = try Solid.cuboid(2, 2, 2)
        let faces = try (0..<6).map { try cube.faceSurface($0) }
        XCTAssertTrue(refusal { _ = try cube.faceSurface(99) }?.hasPrefix("solid_face_surface: ") ?? false)
        cube.close()
        for (f, face) in faces.enumerated() {
            let foot = try XCTUnwrap(try face.closestPoint([0, 0, 0]))
            XCTAssertEqual(foot.distance, 1, accuracy: 1e-12, "face \(f) after the solid is closed")
        }
        let wide = try NurbsSurface([[0, 0, 0], [0, 2, 0], [3, 0, 0], [3, 2, 0]], counts: (2, 2), degreeU: 1, degreeV: 1,
                                    knotsU: [5, 5, 9, 9], knotsV: [-1, -1, 1, 1])
        XCTAssertEqual(try wide.domain.u, try Interval(5, 9))
        XCTAssertEqual(try wide.domain.v, try Interval(-1, 1))
        let sheet = try wide.toSheet()
        XCTAssertEqual(try sheet.faces, 1)
        let own = try sheet.faceSurface(0).domain
        XCTAssertEqual(own.u, try Interval(0, 1), "the sheet is over [0, 1]^2")
        XCTAssertEqual(own.v, try Interval(0, 1), "the sheet is over [0, 1]^2")
    }

    func testANurbsSurfaceAnswersNoMoreOnceClosed() throws {
        let sheet = try sheetOf([0, 0, 0])
        XCTAssertFalse(sheet.isClosed)
        sheet.close()
        sheet.close()
        XCTAssertTrue(sheet.isClosed)
        XCTAssertEqual(refusal { _ = try sheet.closestPoint([0, 0, 1]) }, "nurbs_surface: closed")
        let line = try segment([0, 0, 1], [1, 0, 1])
        XCTAssertEqual(refusal { _ = try line.closestObject([.surface(sheet)]) }, "nurbs_surface: closed")
    }

    func testTheNearestObjectToACurveTakesANurbsSurface() throws {
        let sheet = try sheetOf([0, 0, 0])
        let beside = try segment([2, 0.5, -1], [2, 0.5, 1])
        let near = try XCTUnwrap(try beside.closestObject([.point([9, 9, 9]), .surface(sheet)]))
        let own = try XCTUnwrap(try sheet.curveClosestPoints(beside))
        XCTAssertEqual(near.which, 1)
        XCTAssertEqual(near.distance, own.distance)
        XCTAssertEqual(near.t, own.t)
        XCTAssertEqual(near.pointOnCurve, own.pointOnCurve)
        XCTAssertEqual(near.pointOnItem, own.pointOnSurface)
        XCTAssertEqual(near.answer, .surface(own))

        let after = try XCTUnwrap(try beside.closestObject([.surface(sheet), .point([2.5, 0.5, 0])]))
        XCTAssertEqual(after.which, 1)
        XCTAssertEqual(after.answer, .point)
        XCTAssertEqual(after.distance, 0.5, accuracy: 1e-9)
        XCTAssertNil(try beside.closestObject([.surface(sheet)], maxDistance: 0.9))
    }

    func testAnUnknownAnswerKindIsAnErrorNeverAPoint() throws {
        var raw = CadaclysmBlacksmithNearestObject()
        raw.answer_kind = 5
        XCTAssertEqual(refusal { _ = try NearestObject(raw) },
                       "nurbs_curve_closest_object: the library answered kind 5, not 0 to 4")
        raw.answer_kind = 2
        XCTAssertEqual(try NearestObject(raw).answer, .point)
    }
}
