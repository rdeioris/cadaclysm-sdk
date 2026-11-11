// NurbsCurve and Curvature over the release library: Python's test_cadaclysm_blacksmith.py,
// "a nurbs curve reads back what it was built from" to "nurbs curve refusals name the call", and
// "a curve maps by its control points", trimmed to what proves the marshalling -- every field
// read, every refusal's prefix, the lists' lengths and order. The kernel's own correctness is the
// kernel's tests' and refcheck's job.
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

private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

private typealias P = SIMD3<Double>

/// A quarter of the circle of radius `r` in the xy plane, exact (rational quadratic).
private func quarterCircle(_ r: Double = 2) throws -> NurbsCurve {
    try NurbsCurve([P(r, 0, 0), P(r, r, 0), P(0, r, 0)], degree: 2, weights: [1, 0.5.squareRoot(), 1])
}

/// The whole circle of radius `r` about the z axis at height `z`, exact (nine-point rational
/// quadratic).
private func circle(_ r: Double, z: Double = 0) throws -> NurbsCurve {
    let h = 0.5.squareRoot()
    let pts = [P(r, 0, z), P(r, r, z), P(0, r, z), P(-r, r, z), P(-r, 0, z), P(-r, -r, z), P(0, -r, z), P(r, -r, z), P(r, 0, z)]
    return try NurbsCurve(pts, degree: 2, weights: [1, h, 1, h, 1, h, 1, h, 1],
                          knots: [0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1])
}

private func ends(_ c: NurbsCurve) throws -> (P, P) {
    let d = try c.domain
    return (try c.point(d.lo), try c.point(d.hi))
}

/// Each tween's ends are `a`'s and `b`'s blended at `(i + 1) / (count + 1)`.
private func assertEndsBlended(_ a: NurbsCurve, _ b: NurbsCurve, _ tweens: [NurbsCurve], _ tol: Double,
                               file: StaticString = #filePath, line: UInt = #line) throws {
    let (a0, a1) = try ends(a)
    let (b0, b1) = try ends(b)
    for (i, t) in tweens.enumerated() {
        let f = Double(i + 1) / Double(tweens.count + 1)
        let (t0, t1) = try ends(t)
        XCTAssertLessThan(distance(t0, a0 + f * (b0 - a0)), tol, "tween \(i) start", file: file, line: line)
        XCTAssertLessThan(distance(t1, a1 + f * (b1 - a1)), tol, "tween \(i) end", file: file, line: line)
    }
}

final class NurbsCurveTests: XCTestCase {
    func testACurveReadsBackWhatItWasBuiltFrom() throws {
        let c = try quarterCircle()
        XCTAssertEqual(c.degree, 2)
        XCTAssertTrue(c.isRational)
        XCTAssertFalse(c.isClosed)
        XCTAssertEqual(try c.controlPoints, [P(2, 0, 0), P(2, 2, 0), P(0, 2, 0)])
        XCTAssertEqual(try c.weights, [1, 0.5.squareRoot(), 1])
        XCTAssertEqual(try c.knots, [0, 0, 0, 1, 1, 1])
        let domain = try c.domain
        XCTAssertEqual(domain.lo, 0)
        XCTAssertEqual(domain.hi, 1)
        XCTAssertNil(c.fitError)
        XCTAssertEqual(distance(try c.point(0.37), P(0, 0, 0)), 2, accuracy: 1e-12)
        let k = try c.curvature(0.5)
        XCTAssertEqual(k.kappa, 0.5, accuracy: 1e-12)
        XCTAssertLessThan(distance(try XCTUnwrap(k.centre), P(0, 0, 0)), 1e-12)
        XCTAssertEqual(try c.length().length, Double.pi, accuracy: 1e-9)
        let at = try c.pointAtLength(Double.pi / 2)
        XCTAssertLessThan(distance(at.point, P(2.0.squareRoot(), 2.0.squareRoot(), 0)), 1e-9)
        XCTAssertNil(at.segment)
        XCTAssertEqual(try c.divideByCount(4).count, 5)
        XCTAssertEqual(try c.divideByLength(1.0).count, 4)
        let d = try c.derivatives(0, 2)
        XCTAssertEqual(d.count, 3)
        XCTAssertEqual(d[0], P(2, 0, 0))
        XCTAssertLessThan(abs(d[1].x), 1e-12)
        XCTAssertGreaterThan(d[1].y, 0)

        let line = try NurbsCurve([P(0, 0, 0), P(1, 0, 0)], degree: 1)
        let straight = try line.curvature(0.5)
        XCTAssertNil(straight.centre)
        XCTAssertEqual(straight.kappa, 0)
    }

    func testThroughPointsAndItsEdits() throws {
        let ring = (0..<10).map { i -> P in
            let a = 2 * Double.pi * Double(i) / 10
            return P(cos(a), sin(a), 0.2 * sin(3 * a))
        }
        let closed = try NurbsCurve.through(ring, closed: true)
        XCTAssertTrue(closed.isClosed)
        XCTAssertEqual(try closed.divideByCount(6).count, 6)

        let pts = [P(0, 0, 0), P(1, 2, 0.5), P(3, 1, -0.5), P(4, 3, 1), P(6, 2, 0)]
        let c = try NurbsCurve.through(pts, startTangent: P(0, 0, 5))
        let (lo, hi) = try c.domain
        let d = try c.derivatives(lo, 1)[1]
        XCTAssertLessThan(abs(d.x), 1e-9)
        XCTAssertLessThan(abs(d.y), 1e-9)
        XCTAssertGreaterThan(d.z, 0)

        let fit = try NurbsCurve.fit((0..<200).map { P(Double($0) / 50, sin(Double($0) / 50), 0) }, tolerance: 1e-4)
        let error = try XCTUnwrap(fit.fitError)
        XCTAssertTrue(error >= 0 && error <= 1e-4, "fit error \(error)")

        XCTAssertLessThan(distance(try c.reversed().point(lo), try c.point(hi)), 1e-12)
        let mid = 0.5 * (lo + hi)
        let trimmed = try c.trimmed(lo, mid).domain
        XCTAssertEqual(trimmed.lo, lo)
        XCTAssertEqual(trimmed.hi, mid)
        let longer = try c.extended(0.5)
        XCTAssertGreaterThan(try longer.domain.hi, hi)
        XCTAssertLessThan(distance(try longer.point(hi), try c.point(hi)), 1e-9)
        let before = try c.extended(0.5, atStart: true)
        XCTAssertLessThan(try before.domain.lo, lo)
        XCTAssertEqual(try c.elevated(2).degree, 5)
    }

    func testCurvesJoinEndToEnd() throws {
        let lead = try NurbsCurve([P(2, -3, 0), P(2, 0, 0)], degree: 1)
        let arc = try quarterCircle()
        let tail = try NurbsCurve([P(0, 2, 0), P(-1, 2.5, 0), P(-2, 2, 1), P(-3, 3, 0), P(-4, 2, 0), P(-5, 2, 2)], degree: 5)
        let j = try NurbsCurve.joined([lead, try arc.reversed(), tail])
        XCTAssertEqual(j.degree, 5)
        let domain = try j.domain
        XCTAssertEqual(domain.lo, 0)
        XCTAssertEqual(domain.hi, 3)
        for (t, want) in [(0.0, P(2, -3, 0)), (1, P(2, 0, 0)), (2, P(0, 2, 0)), (3, P(-5, 2, 2))] {
            XCTAssertLessThan(distance(try j.point(t), want), 1e-12, "t=\(t)")
        }
        for i in 0...20 {
            let s = Double(i) / 20
            XCTAssertEqual(distance(try j.point(1 + s), P(0, 0, 0)), 2, accuracy: 1e-12)
            XCTAssertLessThan(distance(try j.point(2 + s), try tail.point(s)), 1e-12)
        }
        XCTAssertEqual(try NurbsCurve.joined([arc]).controlPoints, try arc.controlPoints)
        let gap = try XCTUnwrap(refusal { _ = try NurbsCurve.joined([lead, tail]) })
        XCTAssertTrue(gap.hasPrefix("nurbs_curve_joined: curve 1 ") && gap.contains("curve 0"), gap)
        let none = try XCTUnwrap(refusal { _ = try NurbsCurve.joined([]) })
        XCTAssertTrue(none.hasPrefix("nurbs_curve_joined: "), none)
    }

    func testTweensBlendFromOneCurveToAnother() throws {
        let a = try NurbsCurve([P(0, 0, 0), P(3, 2, 0), P(6, -1, 0), P(10, 0, 0)], degree: 3)
        let b = try NurbsCurve([P(0, 1, 5), P(4, 4, 5), P(7, -3, 6), P(10, 1, 5)], degree: 3)
        let plain = try a.tween(b, 3, method: "plain")
        XCTAssertEqual(plain.count, 3)
        try assertEndsBlended(a, b, plain, 1e-12)
        XCTAssertLessThan(distance(try plain[1].controlPoints[1], P(3.5, 3, 2.5)), 1e-12)
        let matching = try a.tween(b, 2)
        XCTAssertEqual(matching.count, 2)
        try assertEndsBlended(a, b, matching, 1e-12)
        let sampled = try a.tween(b, 4, method: "sampling", samples: 20)
        XCTAssertEqual(sampled.count, 4)
        XCTAssertTrue(sampled.allSatisfy { $0.degree == 3 })
        try assertEndsBlended(a, b, sampled, 1e-9)
        XCTAssertEqual(try a.tween(b, 1, tolerance: 0).count, 1)

        // A quadratic against the cubic: plain refuses in the library's words; matching makes one.
        let q = try NurbsCurve([P(0, 1, 5), P(5, 4, 5), P(10, 1, 5)], degree: 2)
        let notCompatible = try XCTUnwrap(refusal { _ = try a.tween(q, 2, method: "plain") })
        XCTAssertTrue(notCompatible.hasPrefix("nurbs_curve_tween: ") && notCompatible.contains("compatible"), notCompatible)
        let mixed = try a.tween(q, 2)
        XCTAssertEqual(mixed[0].degree, 3)
        try assertEndsBlended(a, q, mixed, 1e-12)
        let zero = try XCTUnwrap(refusal { _ = try a.tween(b, 0) })
        XCTAssertTrue(zero.hasPrefix("nurbs_curve_tween: "), zero)
    }

    func testTweenSamplesAndMethodAreChecked() throws {
        let a = try NurbsCurve([P(0, 0, 0), P(3, 2, 0), P(6, -1, 0), P(10, 0, 0)], degree: 3)
        let b = try NurbsCurve([P(0, 1, 5), P(4, 4, 5), P(7, -3, 6), P(10, 1, 5)], degree: 3)
        let needs = try XCTUnwrap(refusal { _ = try a.tween(b, 2, method: "sampling") })
        XCTAssertEqual(needs, "nurbs_curve_tween: sampling needs samples")
        let only = try XCTUnwrap(refusal { _ = try a.tween(b, 2, method: "matching", samples: 10) })
        XCTAssertEqual(only, "nurbs_curve_tween: samples is read only by sampling, not matching")
        let method = try XCTUnwrap(refusal { _ = try a.tween(b, 2, method: "loft") })
        XCTAssertEqual(method, "nurbs_curve_tween: method must be one of plain, matching, sampling, not 'loft'")
        let few = try XCTUnwrap(refusal { _ = try a.tween(b, 2, method: "sampling", samples: 1) })
        XCTAssertTrue(few.hasPrefix("nurbs_curve_tween: sampling needs at least"), few)
    }

    func testTweensOfTwoCirclesAreClosedCircles() throws {
        let small = try circle(2), big = try circle(4, z: 6)
        let tweens = try small.tween(big, 3, method: "matching")
        XCTAssertEqual(tweens.count, 3)
        for (i, t) in tweens.enumerated() {
            let f = Double(i + 1) / 4
            XCTAssertTrue(t.isClosed, "tween \(i)")
            let (lo, hi) = try t.domain
            for k in 0..<24 {
                let p = try t.point(lo + (hi - lo) * Double(k) / 24)
                XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 2 + 2 * f, accuracy: 1e-12, "tween \(i) point \(k)")
                XCTAssertEqual(p.z, 6 * f, accuracy: 1e-12, "tween \(i) point \(k)")
            }
        }
    }

    func testACurveFromAnEdgeAPlaneAndASphere() throws {
        let cyl = try Solid.cylinder(2.5, 4)
        var rims = 0
        for edge in try cyl.edges where edge.kind == "circle" {
            let rim = try NurbsCurve.fromEdge(cyl, edge)
            let (lo, hi) = try rim.domain
            for t in [lo, 0.5 * (lo + hi), hi] {
                let p = try rim.point(t)
                XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 2.5, accuracy: 1e-12)
            }
            rims += 1
        }
        XCTAssertGreaterThanOrEqual(rims, 2)

        let sphere = try Solid.sphere(3)
        let line = try NurbsCurve([P(-2, 0.5, 10), P(2, -0.5, 10)], degree: 1)
        let on = try line.projectedToFace(sphere, 0, direction: P(0, 0, -1), tolerance: 1e-4)
        XCTAssertLessThanOrEqual(try XCTUnwrap(on.fitError), 1e-4)
        let (lo, hi) = try on.domain
        XCTAssertEqual(distance(try on.point(0.5 * (lo + hi)), P(0, 0, 0)), 3, accuracy: 1e-4)
        let pulled = try line.pulledToFace(sphere, 0, tolerance: 1e-4)
        XCTAssertNotNil(pulled.fitError)
        XCTAssertEqual(distance(try pulled.point(try pulled.domain.lo), P(0, 0, 0)), 3, accuracy: 1e-4)

        let through = try NurbsCurve([P(-5, 1, 1), P(5, 1, 1)], degree: 1)
        let hits = try through.faceHits(sphere, 0, tolerance: 1e-6)
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].point.x, -7.0.squareRoot(), accuracy: 1e-6)
        let crossing = try through.planeHits(P(0, 0, 0), P(1, 0, 0))
        XCTAssertEqual(crossing.count, 1)
        XCTAssertLessThan(distance(crossing[0].point, P(0, 1, 1)), 1e-12)
        let flat = try line.projectedToPlane(P(0, 0, 1), P(0, 0, 1))
        XCTAssertEqual(try flat.point(0), P(-2, 0.5, 1))

        let blend = try NurbsCurve.blend(try quarterCircle(), true, through, false, continuity: 2)
        XCTAssertEqual(blend.degree, 5)
        XCTAssertEqual(try blend.curvature(0).kappa, 0.5, accuracy: 1e-9)
        let teeth = try quarterCircle().comb(8)
        XCTAssertEqual(teeth.count, 9)
        for (p, q) in teeth { XCTAssertEqual(distance(p, q), 0.5, accuracy: 1e-9) }
    }

    func testRefusalsNameTheCall() throws {
        let q = try quarterCircle()
        let cube = try Solid.cuboid(1, 1, 1)
        let rows: [(String, () throws -> Void)] = [
            ("nurbs_curve_new", { _ = try NurbsCurve([P(0, 0, 0), P(1, 0, 0)], degree: 9) }),
            ("nurbs_curve_new", { _ = try NurbsCurve([P(0, 0, 0), P(1, 0, 0)], degree: 1, weights: [1, -1]) }),
            ("nurbs_curve_through", { _ = try NurbsCurve.through([P(0, 0, 0), P(1, 0, 0)], degree: 3) }),
            ("nurbs_curve_fit", { _ = try NurbsCurve.fit([P(0, 0, 0), P(1, 0, 0)], degree: 1, tolerance: -1) }),
            ("nurbs_curve_from_edge", { _ = try NurbsCurve.fromEdge(cube, 999) }),
            ("nurbs_curve_from_face_isocurve", { _ = try NurbsCurve.isocurve(cube, 0, alongU: true, at: 0.5) }),
            ("nurbs_curve_blend", { _ = try NurbsCurve.blend(q, true, q, true, continuity: 3) }),
            ("nurbs_curve_projected_to_plane", { _ = try q.projectedToPlane(P(0, 0, 0), P(0, 0, 1), direction: P(1, 0, 0)) }),
            ("nurbs_curve_trimmed", { _ = try q.trimmed(0.5, 0.2) }),
            ("nurbs_curve_extended", { _ = try q.extended(0) }),
            ("nurbs_curve_point", { _ = try q.point(2) }),
            ("nurbs_curve_derivatives", { _ = try q.derivatives(0.5, 9) }),
            ("nurbs_curve_divide_by_count", { _ = try q.divideByCount(0) }),
            ("nurbs_curve_plane_hits", { _ = try q.planeHits(P(0, 0, 0), P(0, 0, 1)) }),
        ]
        for (name, body) in rows {
            let message = try XCTUnwrap(refusal(body), "\(name) did not refuse")
            XCTAssertTrue(message.hasPrefix("\(name): "), message)
        }
        let weights = try XCTUnwrap(refusal { _ = try NurbsCurve([P(0, 0, 0), P(1, 0, 0)], degree: 1, weights: [1]) })
        XCTAssertEqual(weights, "nurbs_curve_new: 1 weights for 2 points; give one per point")
    }

    func testACurveMapsByItsControlPointsAndValuesBecomeCurves() throws {
        let c = try NurbsCurve([P(0, 0, 0), P(1, 1, 1), P(2, 0, 0)], degree: 2, weights: [1, 0.5, 1])
        let moved = try c.transformed(try Transform.translation(P(1, 2, 3)))
        XCTAssertLessThan(distance(try moved.point(0.5), try c.point(0.5) + P(1, 2, 3)), 1e-12)
        XCTAssertEqual(try moved.weights, try c.weights)
        let again = try c.transformed(try Transform.translation(P(1, 2, 3)).rows)
        XCTAssertEqual(try again.controlPoints, try moved.controlPoints)

        let line = try Line(P(0, 0, 0), P(2, 0, 0)).toNurbs()
        XCTAssertEqual(line.degree, 1)
        let (lo, hi) = try line.domain
        XCTAssertLessThan(distance(try line.point(0.5 * (lo + hi)), P(1, 0, 0)), 1e-12)

        let ring = try Circle(try Frame.xy(), 3).toNurbs()
        XCTAssertTrue(ring.isRational)
        XCTAssertTrue(ring.isClosed)
        let (rlo, rhi) = try ring.domain
        for k in 0..<16 {
            let p = try ring.point(rlo + (rhi - rlo) * Double(k) / 16)
            XCTAssertEqual(distance(p, P(0, 0, 0)), 3, accuracy: 1e-12)
        }
        let viaEnum = try CurveValue.line(try Line(P(0, 0, 0), P(2, 0, 0))).toNurbs()
        XCTAssertEqual(viaEnum.degree, 1)
    }

    func testCurvesOutliveWhatTheyCameFrom() throws {
        var tweens: [NurbsCurve] = []
        do {
            let a = try NurbsCurve([P(0, 0, 0), P(3, 2, 0), P(6, -1, 0), P(10, 0, 0)], degree: 3)
            let b = try NurbsCurve([P(0, 1, 5), P(4, 4, 5), P(7, -3, 6), P(10, 1, 5)], degree: 3)
            tweens = try a.tween(b, 3)
        }
        XCTAssertEqual(tweens.count, 3)
        for t in tweens { XCTAssertEqual(try t.controlPoints.count, 4) }

        var rim: NurbsCurve?
        do {
            let cyl = try Solid.cylinder(2.5, 4)
            let edge = try XCTUnwrap(try cyl.edges.first { $0.kind == "circle" })
            rim = try NurbsCurve.fromEdge(cyl, edge)
            cyl.close()
        }
        let r = try XCTUnwrap(rim)
        let p = try r.point(try r.domain.lo)
        XCTAssertEqual((p.x * p.x + p.y * p.y).squareRoot(), 2.5, accuracy: 1e-12)

        let copy = try r.copy()
        XCTAssertEqual(try copy.controlPoints, try r.controlPoints)
    }

    // The fastback's roof on its centreline, (x, z) in mm, traced off the side view of the
    // reference drawing (2.625 mm a pixel): the windshield's foot, the header (the fifth point),
    // the crown, the backlight, the deck.
    private static let roof: [(Double, Double)] = [
        (1717, 1110), (1848, 1191), (1979, 1262), (2110, 1330), (2242, 1356), (2504, 1367), (2767, 1369), (3029, 1364),
        (3160, 1354), (3423, 1304), (3554, 1251), (3686, 1207), (3817, 1165), (3948, 1123), (4079, 1078),
    ]

    /// The parameter of `curve` nearest `p`, read off 400 even arc-length pieces.
    private func nearest(_ curve: NurbsCurve, _ p: P) throws -> Double {
        let samples = try curve.divideByCount(400)
        return try XCTUnwrap(samples.min { distance($0.point, p) < distance($1.point, p) }).parameter
    }

    func testATracedRoofFairedHasNoInflectionPastTheHeader() throws {
        let pts = Self.roof.map { P($0.0, 0, $0.1) }
        let through = try NurbsCurve.through(pts)
        var tHeader = try nearest(through, pts[4])
        let wobbles = try through.inflections().filter { $0.parameter > tHeader }
        XCTAssertGreaterThanOrEqual(wobbles.count, 3, "\(wobbles)")
        for a in wobbles {
            XCTAssertLessThan(distance(try through.point(a.parameter), a.point), 1e-9)
            XCTAssertEqual(a.error, 0.0)
        }
        let tolerance = 5.25   // two pixels of the drawing
        let roof = try NurbsCurve.fair(pts, tolerance: tolerance, noInflection: .between(4, nil))
        XCTAssertEqual(roof.degree, 5)
        let fitError = try XCTUnwrap(roof.fitError)
        XCTAssertTrue(fitError >= 0 && fitError <= tolerance, "\(fitError)")
        tHeader = try nearest(roof, pts[4])
        XCTAssertEqual(try roof.inflections().filter { $0.parameter > tHeader + 1e-6 }.count, 0)
        let k = try roof.knotContinuity()
        XCTAssertLessThan(k.angle, 1e-6, "\(k)")
        XCTAssertLessThan(k.curvature, 1e-9, "\(k)")
        // Too tight to hold: refused in the library's words, not a curve that turns over.
        let tight = try XCTUnwrap(refusal { _ = try NurbsCurve.fair(pts, tolerance: 0.05, noInflection: .whole) })
        XCTAssertTrue(tight.hasPrefix("nurbs_curve_fair: ") && tight.contains("no curve free of inflections"), tight)
        let low = try XCTUnwrap(refusal { _ = try NurbsCurve.fair(pts, degree: 2, tolerance: tolerance) })
        XCTAssertTrue(low.hasPrefix("nurbs_curve_fair: ") && low.contains("degree 2"), low)
        // Faired from the wobbly curve itself, its own parameters naming the span.
        let d = try through.domain
        let faired = try through.faired(tolerance: 1.5 * tolerance, noInflection: .between(d.lo, d.hi))
        XCTAssertEqual(try faired.inflections().count, 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(faired.fitError), 1.6 * tolerance)
    }

    func testEdgeContinuityReadsACreaseAndAFilletSeam() throws {
        let block = try Solid.cuboid(40, 30, 20)
        let r = try block.edgeContinuity(0, samples: 16)
        XCTAssertLessThan(abs(r.angle - Double.pi / 2), 1e-9, "\(r)")
        XCTAssertLessThan(r.gap, 1e-9, "\(r)")
        XCTAssertLessThan(r.curvature, 1e-9, "\(r)")
        XCTAssertEqual(r.samples, 17)
        let rounded = try block.fillet([0], 4.0)
        var seams: [Continuity] = []
        for e in try rounded.edges {
            guard let k = try? rounded.edgeContinuity(e) else { continue }   // an edge of one face
            if k.angle < 1e-6 { seams.append(k) }
        }
        // The fillet's two tangent seams, its curvature a quarter where the flat faces' is zero.
        XCTAssertEqual(seams.count, 2, "\(seams)")
        for k in seams { XCTAssertEqual(k.curvature, 0.25, accuracy: 1e-4) }
        let bad = try XCTUnwrap(refusal { _ = try block.edgeContinuity(999) })
        XCTAssertTrue(bad.hasPrefix("edge_continuity: "), bad)
    }
}
