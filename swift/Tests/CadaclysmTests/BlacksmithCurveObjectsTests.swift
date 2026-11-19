// Curves as objects over the release library: Python's test_cadaclysm_blacksmith.py curves-as-objects
// tests -- a helix and its fit error, a line's lengths by fraction and over a sub-range,
// equidistant and as-contour division, its length mass, a box face's trimmed isocurve read back as
// isoparametric, a box's section and contour curves, and the refusals' prefixes. The kernel's own
// correctness is the kernel's tests' job.
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

private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double) -> Bool {
    abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol && abs(a.z - b.z) <= tol
}

private func wholeLength(_ c: NurbsCurve) throws -> Double {
    let d = try c.domain
    return try c.lengthBetween(d.lo, d.hi, 1e-12).length
}

private let zAxis = (origin: SIMD3<Double>(0, 0, 0), direction: SIMD3<Double>(0, 0, 1))

private func line() throws -> NurbsCurve {
    try NurbsCurve([SIMD3<Double>(0, 0, 0), SIMD3<Double>(10, 0, 0)], degree: 1)
}

final class BlacksmithCurveObjectsTests: XCTestCase {
    func testAHelixClimbsItsPitchAndReportsItsFitError() throws {
        let h = try NurbsCurve.spiral(zAxis, SIMD3(2, 0, 0), pitch: 1, turns: 2)
        let e = try XCTUnwrap(h.fitError)
        XCTAssertTrue(e > 0 && e <= 1e-6, "\(e)")
        let d = try h.domain
        XCTAssertTrue(near(try h.point(d.lo), SIMD3(2, 0, 0), 1e-12))
        let end = try h.point(d.hi)
        XCTAssertTrue(near(end, SIMD3(2, 0, 2), 1e-12), "\(end)")
        let out = try NurbsCurve.spiral(zAxis, SIMD3(2, 0, 0), pitch: 0, turns: 1, endRadius: 4)
        XCTAssertTrue(near(try out.point(try out.domain.hi), SIMD3(4, 0, 0), 1e-12))
    }

    func testALinesLengthsFractionsAndDivisionsAreItsClosedForms() throws {
        let c = try line()
        let l = try c.lengthBetween(0.2, 0.5)
        XCTAssertEqual(l.length, 3, accuracy: 1e-12)
        XCTAssertTrue(l.accuracyMet)
        let quarter = try c.pointAtNormalizedLength(0.25)
        XCTAssertEqual(quarter.point.x, 2.5, accuracy: 1e-12)
        XCTAssertEqual(quarter.parameter, 0.25, accuracy: 1e-12)
        let xs = try c.pointsAtNormalizedLengths([1, 0, 0.5]).map { $0.point.x }
        XCTAssertEqual(Array(xs[0..<2]), [10, 0])
        XCTAssertEqual(xs[2], 5, accuracy: 1e-12)
        XCTAssertTrue(try c.pointsAtNormalizedLengths([]).isEmpty)
        let every3 = try c.divideEquidistant(3)
        XCTAssertEqual(every3.count, 4)
        for (k, a) in every3.enumerated() { XCTAssertEqual(a.point.x, 3 * Double(k), accuracy: 1e-9) }
        let planes = try c.divideAsContour(SIMD3(0, 0, 0), SIMD3(10, 0, 0), 2.5)
        XCTAssertEqual(planes.count, 5)
        for (k, a) in planes.enumerated() { XCTAssertEqual(a.point.x, 2.5 * Double(k), accuracy: 1e-12) }
        XCTAssertEqual(planes.last?.point.x ?? -1, 10, accuracy: 1e-12)
    }

    func testASegmentsLengthMassIsLCubedOverTwelve() throws {
        let m = try line().mass()
        let i = 1000.0 / 12.0
        XCTAssertEqual(m.length, 10, accuracy: 1e-12)
        XCTAssertTrue(m.accuracyMet && !m.fromPolyline)
        XCTAssertTrue(near(m.centroid, SIMD3(5, 0, 0), 1e-12), "\(m)")
        XCTAssertTrue(near(m.principalMoments, SIMD3(0, i, i), 1e-9), "\(m)")
        XCTAssertEqual(m.inertia[2].z, i, accuracy: 1e-9)
        XCTAssertEqual(abs(m.principalAxes[0].x), 1, accuracy: 1e-12)
        XCTAssertEqual(m.radii.z, (i / 10).squareRoot(), accuracy: 1e-9)
    }

    func testABoxFacesIsocurveIsOneExactLineAndReadsBackAsIsoparametric() throws {
        let cube = try Solid.cuboid(1, 1, 1)
        let intervals = try cube.faceIsoIntervals(0, alongU: true, at: 0)
        XCTAssertFalse(intervals.isEmpty)
        let pieces = try NurbsCurve.faceIsocurves(cube, 0, alongU: true, at: 0, tolerance: nil)
        XCTAssertEqual(pieces.count, 1)
        let piece = try XCTUnwrap(pieces.first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(piece.fitError), 1e-12)
        XCTAssertEqual(try wholeLength(piece), 1, accuracy: 1e-12)
        guard case let .u(v)? = try piece.isIsoparametric(cube, 0, tolerance: nil) else {
            return XCTFail("expected an isocurve along u")
        }
        XCTAssertEqual(v, 0, accuracy: 1e-9)
        XCTAssertTrue(try NurbsCurve.faceIsocurves(cube, 0, alongU: true, at: 1e6).isEmpty)
    }

    func testABoxsSectionAndContoursAreExactClosedRectanglesByPlane() throws {
        let block = try Solid.cuboid(40, 30, 20)
        let section = try block.sectionCurves(SIMD3(0, 0, 3), SIMD3(0, 0, 1))
        XCTAssertEqual(section.count, 1)
        let s = try XCTUnwrap(section.first)
        XCTAssertTrue(s.closed && s.exact && s.error == 0 && s.plane == 0)
        XCTAssertEqual(try wholeLength(s.curve), 140, accuracy: 1e-9)
        XCTAssertTrue(try block.sectionCurves(SIMD3(0, 0, 50), SIMD3(0, 0, 1)).isEmpty)
        let rings = try block.contourCurves(SIMD3(0, 0, -10), SIMD3(0, 0, 10), 5)
        XCTAssertEqual(rings.count, 5)
        for (k, ring) in rings.enumerated() {
            XCTAssertTrue(ring.plane == UInt32(k) && ring.closed && ring.exact, "\(k)")
            let z0 = try ring.curve.point(try ring.curve.domain.lo).z
            XCTAssertEqual(z0, -10 + 5 * Double(k), accuracy: 1e-12)
        }
    }

    func testTheRefusalsNameTheirCall() throws {
        let c = try line()
        let cube = try Solid.cuboid(1, 1, 1)
        let rows: [(String, () throws -> Void)] = [
            ("nurbs_curve_spiral", { _ = try NurbsCurve.spiral(zAxis, SIMD3(2, 0, 0), pitch: 1, turns: 0) }),
            ("nurbs_curve_length_between", { _ = try c.lengthBetween(0.5, 0.2) }),
            ("nurbs_curve_point_at_normalized_length", { _ = try c.pointAtNormalizedLength(1.5) }),
            ("nurbs_curve_divide_equidistant", { _ = try c.divideEquidistant(0) }),
            ("nurbs_curve_divide_as_contour", { _ = try c.divideAsContour(SIMD3(0, 0, 0), SIMD3(0, 0, 0), 1) }),
            ("nurbs_curve_mass", { _ = try c.mass(.nan) }),
            ("nurbs_curve_face_isocurves", { _ = try NurbsCurve.faceIsocurves(cube, 99, alongU: true, at: 0) }),
            ("face_iso_intervals", { _ = try cube.faceIsoIntervals(99, alongU: true, at: 0) }),
            ("nurbs_curve_is_isoparametric", { _ = try c.isIsoparametric(cube, 99) }),
            ("solid_section_curves", { _ = try cube.sectionCurves(SIMD3(0, 0, 0), SIMD3(0, 0, 0)) }),
            ("solid_contour_curves", { _ = try cube.contourCurves(SIMD3(0, 0, 0), SIMD3(0, 0, 1), 0) }),
        ]
        for (name, body) in rows {
            let message = try XCTUnwrap(refusal(body), "\(name) did not refuse")
            XCTAssertTrue(message.hasPrefix("\(name): "), message)
        }
    }
}
