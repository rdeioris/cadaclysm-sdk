// The NURBS toolbox over the release library: knots in and out of a quarter arc, the forms
// (reparametrised, compatible, uniform, non-rational), Greville points and a periodic curve,
// directions, the mean and conics, a Hermite surface's knots and derivatives, and a cylinder's
// curvature -- the numbers of crates/cadaclysm-blacksmith-capi/tests/nurbs_toolbox_abi.rs, worked by
// hand, pinned as literals rather than read back through the wrapper.
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

private typealias P = SIMD3<Double>

private func distance(_ a: P, _ b: P) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

private func near3(_ a: P, _ b: P, _ tol: Double, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThan(distance(a, b), tol, "\(what): \(a) vs \(b)", file: file, line: line)
}

private let root2: Double = 2.0.squareRoot()

/// A quarter of the circle of radius `r` in the xy plane, an exact rational quadratic on [0, 1].
private func quarter(_ r: Double = 2) throws -> NurbsCurve {
    try NurbsCurve([P(r, 0, 0), P(r, r, 0), P(0, r, 0)], degree: 2, weights: [1, root2 / 2, 1])
}

/// The largest gap between `a` at `t` and `b` at `map(t)` over 41 even parameters of `a`.
private func gap(_ a: NurbsCurve, _ b: NurbsCurve, _ map: (Double) -> Double = { $0 }) throws -> Double {
    let d = try a.domain
    var worst = 0.0
    for i in 0...40 {
        let t = d.lo + (d.hi - d.lo) * Double(i) / 40
        worst = max(worst, distance(try a.point(t), try b.point(map(t))))
    }
    return worst
}

/// The largest gap between two surfaces over a 21 x 21 grid of `a`'s domain.
private func surfaceGap(_ a: NurbsSurface, _ b: NurbsSurface) throws -> Double {
    let d = try a.domain
    var worst = 0.0
    for i in 0...20 {
        for j in 0...20 {
            let u = d.u.t0 + d.u.length * Double(i) / 20, v = d.v.t0 + d.v.length * Double(j) / 20
            worst = max(worst, distance(try a.pointAt(u, v), try b.pointAt(u, v)))
        }
    }
    return worst
}

/// (u, v, u²v + u v³) and its derivatives Su, Sv, Suv: cubic each way, so its Hermite surface is exact.
private func poly(_ u: Double, _ v: Double) -> [P] {
    [P(u, v, u * u * v + u * v * v * v), P(1, 0, 2 * u * v + v * v * v), P(0, 1, u * u + 3 * u * v * v), P(0, 0, 2 * u + 3 * v * v)]
}

private func hermite() throws -> NurbsSurface {
    let us: [Double] = [0, 0.5, 2], vs: [Double] = [0, 1, 1.5]
    var lists: [[P]] = [[], [], [], []]
    for u in us {
        for v in vs {
            for (k, d) in poly(u, v).enumerated() { lists[k].append(d) }
        }
    }
    return try NurbsSurface.hermite(u: us, v: vs, points: lists[0], du: lists[1], dv: lists[2], twists: lists[3])
}

final class NurbsToolboxTests: XCTestCase {
    func testKnotsGoInAndComeOutLeavingTheArc() throws {
        let q = try quarter()
        // Boehm at 1/2: the point (2, 2√2 - 2, 0) of weight (2 + √2) / 4, and its mirror.
        let k = try q.insertKnot(0.5)
        XCTAssertEqual(try k.knots, [0, 0, 0, 0.5, 1, 1, 1])
        let side = 2 * root2 - 2, wt = (2 + root2) / 4
        let pts = try k.controlPoints, w = try k.weights
        near3(pts[1], P(2, side, 0), 1e-14, "inserted point 1")
        near3(pts[2], P(side, 2, 0), 1e-14, "inserted point 2")
        XCTAssertEqual(w[1], wt, accuracy: 1e-14)
        XCTAssertEqual(w[2], wt, accuracy: 1e-14)
        XCTAssertLessThan(try gap(q, k), 1e-14)

        let (back, removed) = try k.removeKnot(0.5, times: 1, tolerance: 1e-9)
        XCTAssertEqual(removed, 1)
        near3(try back.controlPoints[1], P(2, 2, 0), 1e-12, "the arc's middle point back")
        XCTAssertEqual(try back.weights[1], root2 / 2, accuracy: 1e-12)

        // A corner holds its knot: none go.
        let corner = try NurbsCurve([P(0, 0, 0), P(1, 0, 0), P(1, 1, 0)], degree: 1)
        let kept = try corner.removeKnot(0.5, tolerance: 1e-6)
        XCTAssertEqual(kept.removed, 0)
        XCTAssertEqual(try kept.curve.controlPoints.count, 3)

        let r = try q.refineKnots([0.25, 0.5, 0.75])
        XCTAssertEqual(try r.knots, [0, 0, 0, 0.25, 0.5, 0.75, 1, 1, 1])
        XCTAssertLessThan(try gap(q, r), 1e-14)

        let past = try XCTUnwrap(refusal { _ = try q.insertKnot(0.5, times: 3) })
        XCTAssertTrue(past.hasPrefix("nurbs_curve_knot_inserted: "), past)
        let notAKnot = try XCTUnwrap(refusal { _ = try q.removeKnot(0.3) })
        XCTAssertTrue(notAKnot.hasPrefix("nurbs_curve_knot_removed: "), notAKnot)
        let unsorted = try XCTUnwrap(refusal { _ = try q.refineKnots([0.5, 0.25]) })
        XCTAssertTrue(unsorted.hasPrefix("nurbs_curve_knots_refined: "), unsorted)
    }

    func testFormsReparametrisedCompatibleUniformNonRational() throws {
        let q = try quarter()
        let re = try q.reparametrize(10, 20)
        let d = try re.domain
        XCTAssertEqual(d.lo, 10)
        XCTAssertEqual(d.hi, 20)
        near3(try re.point(15), try q.point(0.5), 1e-14, "reparametrised")
        let flat = try q.nonRational()
        XCTAssertFalse(flat.isRational)
        near3(try flat.point(0.5), P(1.5, 1.5, 0), 1e-14, "the parabola's middle")

        let line = try NurbsCurve([P(0, 0, 1), P(4, 0, 1)], degree: 1, knots: [3, 3, 5, 5])
        let both = try NurbsCurve.makeCompatible([q, line])
        XCTAssertEqual(both.count, 2)
        for c in both {
            XCTAssertEqual(c.degree, 2)
            let cd = try c.domain
            XCTAssertEqual(cd.lo, 0)
            XCTAssertEqual(cd.hi, 1)
        }
        XCTAssertEqual(try both[0].knots, try both[1].knots)
        XCTAssertLessThan(try gap(q, both[0]), 1e-14)
        XCTAssertLessThan(try gap(line, both[1]) { ($0 - 3) / 2 }, 1e-14)
        let none = try XCTUnwrap(refusal { _ = try NurbsCurve.makeCompatible([]) })
        XCTAssertTrue(none.hasPrefix("nurbs_curve_compatible: "), none)

        let bunched = try NurbsCurve((0..<6).map { P(Double($0), Double($0 % 2), 0) }, degree: 3,
                                     knots: [0, 0, 0, 0, 0.1, 0.9, 1, 1, 1, 1])
        let u = try bunched.makeUniform()
        XCTAssertEqual(try u.knots, [0, 0, 0, 0, 1.0 / 3.0, 2.0 / 3.0, 1, 1, 1, 1])
        XCTAssertEqual(try u.controlPoints, try bunched.controlPoints)
        let bad = try XCTUnwrap(refusal { _ = try q.reparametrize(1, 1) })
        XCTAssertTrue(bad.hasPrefix("nurbs_curve_reparametrized: "), bad)
    }

    func testGrevillePointsAndAPeriodicCurve() throws {
        let c = try NurbsCurve((0..<6).map { P(Double($0), Double($0 * $0), 0) }, degree: 3,
                               knots: [0, 0, 0, 0, 1, 2, 3, 3, 3, 3])
        let g = try c.grevilleParameters()
        let want: [Double] = [0, 1.0 / 3.0, 1, 2, 8.0 / 3.0, 3]
        XCTAssertEqual(g.count, 6)
        for (a, b) in zip(g, want) { XCTAssertEqual(a, b, accuracy: 1e-15, "\(g)") }
        let p = try c.grevillePoints()
        XCTAssertEqual(p.count, 6)
        for i in 0..<6 { near3(p[i], try c.point(want[i]), 1e-14, "greville point \(i)") }

        // The unit square's corners as a cubic, wrapped: 7 points on [0, 4]; at a knot a uniform
        // cubic is (P0 + 4 P1 + P2) / 6 = (5/6, 1/6).
        let square = try NurbsCurve([P(0, 0, 0), P(1, 0, 0), P(1, 1, 0), P(0, 1, 0)], degree: 3)
        let wrapped = try square.periodic(smooth: false)
        XCTAssertEqual(try wrapped.controlPoints.count, 7)
        let d = try wrapped.domain
        XCTAssertEqual(d.lo, 0)
        XCTAssertEqual(d.hi, 4)
        near3(try wrapped.point(0), P(5.0 / 6.0, 1.0 / 6.0, 0), 1e-14, "the wrapped start")
        XCTAssertTrue(wrapped.isClosed)
        let smooth = try square.periodic()
        XCTAssertEqual(try smooth.domain.hi, 1)
        let short = try NurbsCurve([P(0, 0, 0), P(1, 0, 0), P(1, 1, 0), P(0, 0, 0)], degree: 3)
        let few = try XCTUnwrap(refusal { _ = try short.periodic(smooth: false) })
        XCTAssertTrue(few.hasPrefix("nurbs_curve_periodic: "), few)
    }

    func testDirectionsAMeanAndConics() throws {
        let a = try NurbsCurve([P(0, 0, 0), P(10, 0, 0)], degree: 1)
        let b = try NurbsCurve([P(0, 1, 0), P(10, 1, 0)], degree: 1)
        XCTAssertTrue(try a.directionsMatch(b))
        XCTAssertFalse(try a.directionsMatch(try b.reverse()))
        // b reversed, lined up with a: turned back to start at (0, 1, 0).
        near3(try b.reverse().linedUpWith(a).point(0), P(0, 1, 0), 1e-15, "lined up")
        near3(try b.linedUpWith(a).point(0), P(0, 1, 0), 1e-15, "already lined up")

        // Arcs of radius 2 and 4 about one centre, the second run backwards: the mean is radius 3.
        let m = try quarter(2).mean(try quarter(4).reverse())
        let d = try m.domain
        for i in 0...40 {
            let p = try m.point(d.lo + (d.hi - d.lo) * Double(i) / 40)
            XCTAssertEqual(distance(p, P(0, 0, 0)), 3, accuracy: 1e-12, "\(p)")
        }
        let closed = try NurbsCurve([P(0, 0, 0), P(1, 0, 0), P(1, 1, 0), P(0, 0, 0)], degree: 1)
        let mixed = try XCTUnwrap(refusal { _ = try a.mean(closed) })
        XCTAssertTrue(mixed.hasPrefix("nurbs_curve_mean: "), mixed)

        let q = try quarter()
        let stretched = try NurbsCurve([P(4, 0, 0), P(4, 2, 0), P(0, 2, 0)], degree: 2, weights: [1, root2 / 2, 1])
        let hyper = try NurbsCurve([P(2, 0, 0), P(2, 2, 0), P(0, 2, 0)], degree: 2, weights: [1, 2, 1])
        let cases: [(NurbsCurve, ConicType?, String)] = [
            (q, .circle, "the arc"), (try q.elevate(3), .circle, "the arc elevated"), (stretched, .ellipse, "stretched"),
            (hyper, .hyperbola, "weight 2"), (try q.nonRational(), .parabola, "non-rational"), (a, nil, "a line"),
        ]
        for (c, want, what) in cases { XCTAssertEqual(try c.conicType(tolerance: 1e-6), want, what) }
        let negative = try XCTUnwrap(refusal { _ = try q.conicType(tolerance: -1) })
        XCTAssertTrue(negative.hasPrefix("nurbs_curve_conic_type: "), negative)
    }

    func testAHermiteSurfaceIsItsBicubicAndItsKnotsMove() throws {
        let s = try hermite()
        XCTAssertEqual(try s.counts.nU, 6)
        XCTAssertEqual(try s.counts.nV, 6)
        XCTAssertEqual(try s.knots(.u), [0, 0, 0, 0, 0.5, 0.5, 2, 2, 2, 2])
        XCTAssertEqual(try s.knots(.v), [0, 0, 0, 0, 1, 1, 1.5, 1.5, 1.5, 1.5])
        let net = try s.controlPoints
        XCTAssertEqual(net.count, 36)
        XCTAssertEqual(net[0], P(0, 0, 0))
        XCTAssertEqual(net[1], P(0, 1.0 / 3.0, 0))
        near3(net[6], P(0.5 / 3.0, 0, 0), 1e-15, "the u neighbour of the corner")
        XCTAssertEqual(try s.weights, [Double](repeating: 1, count: 36))

        let (u, v) = (1.3, 0.7)
        near3(try s.pointAt(u, v), poly(u, v)[0], 1e-13, "exact off the grid")
        let d = try s.secondDerivatives(u, v)
        near3(d.s, poly(u, v)[0], 1e-12, "S")
        near3(d.su, poly(u, v)[1], 1e-12, "Su")
        near3(d.sv, poly(u, v)[2], 1e-12, "Sv")
        near3(d.suu, P(0, 0, 2 * v), 1e-12, "Suu")
        near3(d.suv, P(0, 0, 2 * u + 3 * v * v), 1e-12, "Suv")
        near3(d.svv, P(0, 0, 6 * u * v), 1e-12, "Svv")

        let e = try s.elevate(.u)
        XCTAssertEqual(try e.degreeU, 4)
        XCTAssertEqual(try e.degreeV, 3)
        XCTAssertLessThan(try surfaceGap(s, e), 1e-13)
        let k = try s.insertKnot(.u, 1.0)
        XCTAssertEqual(try k.counts.nU, 7)
        XCTAssertEqual(try k.counts.nV, 6)
        XCTAssertEqual(try k.knots(.u), [0, 0, 0, 0, 0.5, 0.5, 1, 2, 2, 2, 2])
        let r = try s.refineKnots(.v, [0.25, 1.25])
        XCTAssertEqual(try r.counts.nU, 6)
        XCTAssertEqual(try r.counts.nV, 8)
        XCTAssertLessThan(try surfaceGap(s, r), 1e-13)
        let (back, removed) = try k.removeKnot(.u, 1.0, times: 1, tolerance: 1e-9)
        XCTAssertEqual(removed, 1)
        XCTAssertEqual(try back.counts.nU, 6)
        XCTAssertEqual(try back.counts.nV, 6)
        XCTAssertLessThan(try surfaceGap(s, back), 1e-12)

        let x = try s.extend(.uEnd, 0.5)
        let dom = try x.domain
        XCTAssertGreaterThan(dom.u.t1, 2)
        XCTAssertEqual(dom.u.t0, 0)
        XCTAssertEqual(dom.v, try Interval(0, 1.5))
        near3(try x.pointAt(u, v), try s.pointAt(u, v), 1e-12, "extended, the old point kept")

        // Refusals: the wrapper's list check, then the library's.
        XCTAssertEqual(refusal { _ = try NurbsSurface.hermite(u: [0, 1], v: [0, 1], points: [P(0, 0, 0)], du: [], dv: [], twists: []) },
                       "nurbs_surface_hermite: 2 x 2 nodes take 4 points, got 1")
        let z = [P](repeating: P(0, 0, 0), count: 4)
        let falling = try XCTUnwrap(refusal { _ = try NurbsSurface.hermite(u: [1, 0], v: [0, 1], points: z, du: z, dv: z, twists: z) })
        XCTAssertTrue(falling.hasPrefix("nurbs_surface_hermite: "), falling)
        let twice = try XCTUnwrap(refusal { _ = try s.insertKnot(.u, 0.5, times: 2) })
        XCTAssertTrue(twice.hasPrefix("nurbs_surface_knot_inserted: "), twice)
        let outside = try XCTUnwrap(refusal { _ = try s.secondDerivatives(3, 0.5) })
        XCTAssertTrue(outside.hasPrefix("nurbs_surface_second_derivatives: "), outside)
        let inward = try XCTUnwrap(refusal { _ = try s.extend(.uStart, -1) })
        XCTAssertTrue(inward.hasPrefix("nurbs_surface_extended: "), inward)
    }

    func testACylinderBendsOneWay() throws {
        // A quarter cylinder of radius 2 along z: the arc in u, a line of length 5 in v.
        let h = root2 / 2
        let s = try NurbsSurface([P(2, 0, 0), P(2, 0, 5), P(2, 2, 0), P(2, 2, 5), P(0, 2, 0), P(0, 2, 5)], counts: (3, 2),
                                 degreeU: 2, degreeV: 1, weights: [1, 1, h, h, 1, 1])
        let c = try s.curvature(0.5, 0.3)
        // Su x Sv points out of the cylinder, which bends away from it: k2 = -1/2 round, k1 = 0 along.
        XCTAssertEqual(c.k1, 0, accuracy: 1e-12, "\(c)")
        XCTAssertEqual(c.k2, -0.5, accuracy: 1e-12, "\(c)")
        XCTAssertEqual(c.gaussian, 0, accuracy: 1e-12, "\(c)")
        XCTAssertEqual(c.mean, -0.25, accuracy: 1e-12, "\(c)")
        near3(c.normal, P(h, h, 0), 1e-12, "the normal")
        XCTAssertLessThan(min(distance(c.dir1, P(0, 0, 1)), distance(c.dir1, P(0, 0, -1))), 1e-12, "\(c)")
        XCTAssertLessThan(min(distance(c.dir2, P(-h, h, 0)), distance(c.dir2, P(h, -h, 0))), 1e-12, "\(c)")
        let outside = try XCTUnwrap(refusal { _ = try s.curvature(2.0, 0.3) })
        XCTAssertTrue(outside.hasPrefix("nurbs_surface_curvature: "), outside)
    }
}
