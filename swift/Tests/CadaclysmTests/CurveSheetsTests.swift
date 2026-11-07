// The sheets made from curves over the release library: Python's test_cadaclysm_blacksmith.py,
// "surfaces from curves are sheets", "a curve trims a hole and an island and they join back", "an
// open curve keeps its left or right", "six sheets join into a box ...", "join sheets sews a T
// junction", "trim by curve and join refuse by name", "continuity match and blend", "n sided patch
// fills a pentagon of strips", "fillet surfaces rolls a ball between two sheets" and "fillet rounds a
// spline edge at a constant and a varying radius", "a flange turns a hole under and carries it inward",
// "a liner runs a hole down to a tilted floor" and "flange and extrude to refuse by name", every
// assert, plus the wrapper's own refusals, the `sheetError` / `patchReport` precedent and the
// rails outliving the sheets. The kernel's own correctness is the kernel's tests' and refcheck's
// job.
@testable import Blacksmith
import Foundation
import XCTest

private typealias P = SIMD3<Double>

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

private func line(_ a: P, _ b: P) throws -> NurbsCurve { try NurbsCurve([a, b], degree: 1) }

/// A `w` by `h` rectangle centred at `origin` in the plane of `x`, `y`, facing `x cross y`.
private func rectSheet(_ origin: P, _ x: P, _ y: P, _ w: Double, _ h: Double) throws -> Solid {
    let z = P(x.y * y.z - x.z * y.y, x.z * y.x - x.x * y.z, x.x * y.y - x.y * y.x)
    return try Solid.face(Profile.rect(w, h), Frame(origin, x, y, z))
}

/// The circle of radius `r` about `centre` in its z plane: nine rational quadratic points.
private func exactCircle(_ centre: P, _ r: Double) throws -> NurbsCurve {
    let s = 0.5.squareRoot()
    let offsets: [(Double, Double)] = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0)]
    let pts = offsets.map { P(centre.x + r * $0.0, centre.y + r * $0.1, centre.z) }
    return try NurbsCurve(pts, degree: 2, weights: [1, s, 1, s, 1, s, 1, s, 1],
                          knots: [0, 0, 0, 0.25, 0.25, 0.5, 0.5, 0.75, 0.75, 1, 1, 1])
}

private func massOf(_ s: Solid, _ accuracy: Double = 0) throws -> Mass { try s.mass(accuracy) }

private func area(_ s: Solid, _ accuracy: Double = 0) throws -> Double { try massOf(s, accuracy).area }

private func dist(_ a: P, _ b: P) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

/// The 20 x 20 square in z = 0 facing +z with a round hole of radius 5 about (1, -2), and the
/// hole's rim edges.
private func holedSheet() throws -> (Solid, [Edge]) {
    let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
    let holed = try sheet.trimByCurve(exactCircle(P(1, -2, 0), 5), keep: "outside", direction: P(0, 0, -1), tolerance: 0.01)
    let rim = try holed.edges.filter { e in
        e.faces.count == 1 && e.segments.allSatisfy { abs(hypot($0.start.x - 1, $0.start.y + 2) - 5) < 1e-6 }
    }
    XCTAssertFalse(rim.isEmpty)
    return (holed, rim)
}

/// Two bicubic patches -- a fender's top and a door's side -- sharing the crease row, joined.
private func fenderAndDoor() throws -> Solid {
    let length = 400.0
    var aRows: [NurbsCurve] = [], bRows: [NurbsCurve] = []
    for y in [0.0, length / 3, 2 * length / 3, length] {
        let s = sin(Double.pi * y / length)
        let c = P(150.0 + 8.0 * s, y, 6.0 * s)
        aRows.append(try NurbsCurve([P(0, y, 10), P(50, y, 14), P(100, y, 12), c], degree: 3))
        bRows.append(try NurbsCurve([c, P(c.x + 14, y, c.z - 60), P(c.x + 10, y, c.z - 130), P(c.x - 4, y, c.z - 200)], degree: 3))
    }
    let a = try Solid.loftCurves(aRows, degree: 3, loose: true)
    let b = try Solid.loftCurves(bRows, degree: 3, loose: true)
    let (shell, report) = try Solid.joinSheets([a, b], tolerance: 1e-6)
    XCTAssertEqual(report.sewn, 1)
    return shell
}

final class CurveSheetsTests: XCTestCase {
    func testSurfacesFromCurvesAreSheets() throws {
        let c: [P] = [P(-1, -1, 1), P(1, -1, -1), P(1, 1, 1), P(-1, 1, -1)]
        let coons = try Solid.edgeSurface([line(c[0], c[1]), line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[0])], tolerance: 1e-9)
        XCTAssertEqual(try coons.faces, 1)
        XCTAssertEqual(coons.sheetError, 0.0)
        let loft = try Solid.loftCurves([line(P(0, 0, 0), P(2, 0, 0)), line(P(0, 1, 1), P(2, 1, -1))])
        XCTAssertEqual(try loft.faces, 1)
        XCTAssertNil(loft.sheetError)
        XCTAssertNil(loft.patchReport)
        let ring = (0..<8).map { i -> P in
            let t = 2 * Double.pi * Double(i) / 8
            return P(cos(t), sin(t), 0)
        }
        let circle = try NurbsCurve.through(ring, closed: true)
        let tube = try Solid.sweepRail(line(P(0, 0, 0), P(0, 0, 4)), [circle], tolerance: 1e-5)
        XCTAssertEqual(try tube.faces, 1)
        XCTAssertTrue(try XCTUnwrap(tube.sheetError) >= 0 && tube.sheetError! <= 1e-5)
        let upright = try Solid.sweepRail(line(P(0, 0, 0), P(0, 0, 4)), [circle], frame: "fixed", up: P(0, 1, 0), tolerance: 1e-5)
        XCTAssertEqual(try upright.faces, 1)
        XCTAssertNotNil(upright.sheetError)
        let band = try Solid.sweepTwoRails(line(P(-1, 0, 0), P(-1, 5, 0)), line(P(1, 0, 0), P(1, 5, 0)),
                                           [line(P(-1, 0, 0), P(1, 0, 0))], tolerance: 1e-6)
        XCTAssertEqual(try band.faces, 1)
        XCTAssertNotNil(band.sheetError)
        let net = try Solid.networkSurface([-1.0, 0.2, 1.0].map { try line(P(-1, $0, -$0), P(1, $0, $0)) },
                                           [-1.0, 0.3, 1.0].map { try line(P($0, -1, -$0), P($0, 1, $0)) }, tolerance: 1e-9)
        XCTAssertEqual(try net.faces, 1)
        XCTAssertLessThanOrEqual(try XCTUnwrap(net.sheetError), 1e-9)
        XCTAssertNil(try Solid.cuboid(1, 1, 1).sheetError)
        XCTAssertNil(try Solid.cuboid(1, 1, 1).patchReport)

        XCTAssertEqual(refusal { _ = try Solid.loftCurves([circle]) }?.hasPrefix("loft_curves: "), true)
        XCTAssertEqual(refusal { _ = try Solid.edgeSurface([line(P(0, 0, 0), P(1, 0, 0))]) }?.hasPrefix("edge_surface: "), true)
        XCTAssertEqual(refusal { _ = try Solid.networkSurface([line(P(0, 0, 0), P(1, 0, 0))], [line(P(0, 0, 0), P(0, 1, 0))]) }?
            .hasPrefix("network_surface: "), true)
    }

    func testACurveTrimsAHoleAndAnIslandAndTheyJoinBack() throws {
        let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
        let ring = try exactCircle(P(1, -2, 0), 5)
        let holed = try sheet.trimByCurve(ring, keep: "outside", direction: P(0, 0, -1), tolerance: 0.01)
        let island = try sheet.trimByCurve(ring, keep: "inside", tolerance: 0.01)
        XCTAssertLessThan(abs(try area(island) - 25 * Double.pi), 1e-6)
        XCTAssertLessThan(abs(try area(holed) - (400 - 25 * Double.pi)), 1e-6)
        let split = try sheet.splitByCurve(ring, tolerance: 0.01)
        XCTAssertEqual(try split.faces, 2)
        let (back, report) = try Solid.joinSheets([holed, island])
        XCTAssertGreaterThanOrEqual(report.sewn, 1)
        XCTAssertEqual(report.nakedAfter, report.nakedBefore - 2 * report.sewn)
        XCTAssertFalse(report.closed)
        XCTAssertEqual(try back.faces, 2)
        XCTAssertTrue(report.description.hasPrefix("JoinReport(sewn="))
    }

    func testAnOpenCurveKeepsItsLeftOrRight() throws {
        let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
        let open = try NurbsCurve.through([P(-5, 1, 0), P(5, 1, 0)], degree: 1)
        let left = try sheet.trimByCurve(open, keep: "left", direction: P(0, 0, 1), tolerance: 0.01)
        let right = try sheet.trimByCurve(open, keep: "right", direction: P(0, 0, 1), tolerance: 0.01)
        XCTAssertLessThan(abs(try area(left) - 180), 1e-9)
        XCTAssertLessThan(abs(try area(right) - 220), 1e-9)
        XCTAssertLessThan(abs(try area(sheet.trimByCurve(open, keep: "inside", direction: P(0, 0, -1), tolerance: 0.01)) - 220), 1e-9)
    }

    func testSixSheetsJoinIntoABoxTheKernelMeasuresCutsAndWrites() throws {
        let x = P(1, 0, 0), y = P(0, 1, 0), z = P(0, 0, 1)
        let faces = [try rectSheet(P(5, 10, 0), x, y, 10, 20), try rectSheet(P(5, 10, 30), x, y, 10, 20),
                     try rectSheet(P(0, 10, 15), y, z, 20, 30), try rectSheet(P(10, 10, 15), y, z, 20, 30),
                     try rectSheet(P(5, 0, 15), z, x, 30, 10), try rectSheet(P(5, 20, 15), x, z, 10, 30)]
        let (box, report) = try Solid.joinSheets(faces)
        XCTAssertEqual([report.sewn, report.nakedBefore, report.nakedAfter, report.turned], [12, 24, 0, 4])
        XCTAssertTrue(report.closed)
        let m = try massOf(box)
        XCTAssertTrue(m.closed)
        XCTAssertLessThan(abs(m.volume - 6000), 1e-6)
        let bored = try box.cut(Solid.cylinder(2, 50).translate(5, 10, -10), tolerance: 0.01)
        XCTAssertLessThan(abs(try massOf(bored).volume - (6000 - Double.pi * 4 * 30)), 0.05)
        XCTAssertTrue(try box.stepText().contains("CLOSED_SHELL"))
        // Two of the faces, one moved a thousandth away: sewn only at a tolerance that covers it.
        let moved = try faces[3].translate(0, 0, 1e-3)
        let (_, apart) = try Solid.joinSheets([faces[1], moved])
        let (_, loose) = try Solid.joinSheets([faces[1], moved], tolerance: 2e-3)
        XCTAssertEqual(apart.sewn, 0)
        XCTAssertEqual(loose.sewn, 1)
        XCTAssertLessThan(abs(loose.worstGap - 1e-3), 1e-9)
    }

    func testJoinSheetsSewsATJunction() throws {
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) throws -> Solid {
            let c: [P] = [P(x0, y0, 0), P(x1, y0, 0), P(x1, y1, 0), P(x0, y1, 0)]
            return try Solid.edgeSurface([line(c[0], c[1]), line(c[1], c[2]), line(c[2], c[3]), line(c[3], c[0])])
        }
        // Two unit squares on a 2 x 1 rectangle's long edge: it is cut where they meet on it.
        let big = try rect(0, 0, 2, 1), a = try rect(0, 1, 1, 2), b = try rect(1, 1, 2, 2)
        let (_, exact) = try Solid.joinSheets([big, a, b])
        XCTAssertEqual(exact.sewn, 1)
        let (shell, report) = try Solid.joinSheets([big, a, b], tolerance: 1e-3)
        XCTAssertEqual([report.sewn, report.nakedBefore, report.nakedAfter], [3, 13, 7])
        XCTAssertFalse(report.closed)
        XCTAssertEqual(try shell.faces, 3)
    }

    func testRecessSetsASquareWindowIntoAFlatSheet() throws {
        let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
        let square = try NurbsCurve.through([P(-5, -5, 0), P(5, -5, 0), P(5, 5, 0), P(-5, 5, 0), P(-5, -5, 0)], degree: 1)
        let (window, faces) = try sheet.recess(square, depth: 3, draft: 0, fillet: 0, pane: true, tolerance: 0.01)
        XCTAssertTrue(faces == (1, 0, 4, 1), "\(faces)")
        XCTAssertEqual(try window.faces, 6)
    }

    func testTrimByCurveAndJoinRefuseByName() throws {
        let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
        let ring = try exactCircle(P(0, 0, 0), 5)
        XCTAssertEqual(refusal { _ = try sheet.trimByCurve(ring, keep: "middle") },
                       "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'middle'")
        let nothing = try XCTUnwrap(refusal { _ = try sheet.trimByCurve(exactCircle(P(100, 0, 0), 5), keep: "inside") })
        XCTAssertTrue(nothing.hasPrefix("trim_by_curve: ") && nothing.contains("nothing of the sheet lies inside"), nothing)
        let zero = try XCTUnwrap(refusal { _ = try sheet.splitByCurve(ring, direction: P(0, 0, 0)) })
        XCTAssertTrue(zero.hasPrefix("split_by_curve: ") && zero.contains("direction is zero"), zero)
        XCTAssertEqual(refusal { _ = try Solid.joinSheets([]) }?.hasPrefix("join_sheets: no sheets"), true)
        let neg = try XCTUnwrap(refusal { _ = try Solid.joinSheets([sheet], tolerance: -1) })
        XCTAssertTrue(neg.hasPrefix("join_sheets: ") && neg.contains("tolerance"), neg)
    }

    func testAFlangeTurnsAHoleUnderAndCarriesItInward() throws {
        let (holed, rim) = try holedSheet()
        let under = try line(P(0, 0, 0), P(0, -3, 0))
        // Turned under 3 along the face's normal (+z): the hole's own cylinder, 3 deep, below the sheet.
        let wall = try holed.flange(rim, section: under, tolerance: 1e-3, join: false)
        XCTAssertEqual(try wall.faces, rim.count)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wall.sheetError), 1e-3)
        XCTAssertLessThan(abs(try area(wall) - 2 * Double.pi * 5 * 3), 0.05)
        let (lo, hi) = try wall.bounds
        XCTAssertLessThan(abs(lo.z + 3), 1e-3)
        XCTAssertLessThan(abs(hi.z), 1e-3)
        XCTAssertLessThan(abs(lo.x - (1 - 5)), 1e-2)
        XCTAssertLessThan(abs(hi.x - (1 + 5)), 1e-2)
        // Carried on outward from the face 2: into the hole, an annulus from radius 5 in to 3.
        let ring = try holed.flange(rim.map { $0.index }, section: line(P(0, 0, 0), P(2, 0, 0)), join: false)
        XCTAssertLessThan(abs(try area(ring) - Double.pi * (25 - 9)), 0.05)
        // Joined, the sheet's faces come first and the flange is sewn on.
        let joined = try holed.flange(rim, section: under)
        XCTAssertEqual(try joined.faces, try holed.faces + rim.count)
        XCTAssertLessThan(abs(try area(joined) - (try area(holed) + 2 * Double.pi * 5 * 3)), 0.05)
        // The rim is sewn all the way round: every edge on the hole's circle borders the sheet and the flange.
        let onRim = try joined.edges.filter { e in
            e.segments.allSatisfy { abs(hypot($0.start.x - 1, $0.start.y + 2) - 5) < 1e-3 && abs($0.start.z) < 1e-6 }
        }
        XCTAssertFalse(onRim.isEmpty)
        for e in onRim { XCTAssertEqual(e.faces.sorted(), [0, 1], "\(e)") }
    }

    func testALinerRunsAHoleDownToATiltedFloor() throws {
        let (holed, rim) = try holedSheet()
        // The floor z = -7 + 0.1 x, wide enough to catch every point: the wall is 7 - 0.1 x deep,
        // 6.9 on average round a hole centred at x = 1.
        let floor = try Solid.edgeSurface([line(P(-20, -20, -9), P(20, -20, -5)), line(P(20, -20, -5), P(20, 20, -5)),
                                           line(P(20, 20, -5), P(-20, 20, -9)), line(P(-20, 20, -9), P(-20, -20, -9))])
        let wall = try holed.extrudeTo(rim, direction: P(0, 0, -1), target: floor, tolerance: 1e-3, join: false)
        XCTAssertEqual(try wall.faces, rim.count)
        XCTAssertLessThanOrEqual(try XCTUnwrap(wall.sheetError), 1e-3)
        XCTAssertLessThan(abs(try area(wall) - 2 * Double.pi * 5 * 6.9), 0.05)
        let (lo, hi) = try wall.bounds
        let deepest: Double = -7.0 + 0.1 * (1.0 - 5.0)
        XCTAssertLessThan(abs(lo.z - deepest), 1e-2)
        XCTAssertLessThan(abs(hi.z), 1e-6)
        let joined = try holed.extrudeTo(rim, direction: P(0, 0, -1), target: floor)
        XCTAssertEqual(try joined.faces, try holed.faces + rim.count)
        XCTAssertTrue(try joined.stepText().contains("SURFACE_OF_LINEAR_EXTRUSION"))
    }

    func testFlangeAndExtrudeToRefuseByName() throws {
        let (holed, rim) = try holedSheet()
        let under = try line(P(0, 0, 0), P(0, -3, 0))
        func check(_ message: String?, _ prefix: String, _ contains: String = "") {
            XCTAssertTrue(message?.hasPrefix(prefix) == true && (contains.isEmpty || message!.contains(contains)), message ?? "did not throw")
        }
        check(refusal { _ = try holed.flange(rim, section: line(P(1, 0, 0), P(1, -3, 0))) }, "flange: the section starts at")
        check(refusal { _ = try holed.flange([Int](), section: under) }, "flange: no edges given")
        check(refusal { _ = try holed.flange([999], section: under) }, "flange: no edge 999")
        check(refusal { _ = try Solid.cuboid(10, 10, 10).flange([0], section: under) }, "flange: edge 0 borders 2 faces")
        let floor = try rectSheet(P(0, 0, -7), P(1, 0, 0), P(0, 1, 0), 40, 40)
        check(refusal { _ = try holed.extrudeTo(rim, direction: P(0, 0, 1), target: floor) }, "extrude_to: edge ", "misses the target")
        check(refusal { _ = try holed.extrudeTo(rim, direction: P(0, 0, 0), target: floor) }, "extrude_to: the direction has no length")
    }

    func testContinuityMatchAndBlend() throws {
        let a = try Solid.loftCurves([line(P(-1, 0, 0), P(0, 0, 0)), line(P(-1, 1, 0), P(0, 1, 0))], degree: 1)
        let b = try Solid.loftCurves([line(P(0, 0, 0), P(0, 0, 1)), line(P(0, 1, 0), P(0, 1, 1))], degree: 1)
        var r = try a.continuity("u1", b, "u0", samples: 32)
        XCTAssertLessThanOrEqual(r.gap, 1e-12)
        XCTAssertLessThanOrEqual(abs(r.angle - Double.pi / 2), 1e-9)
        XCTAssertGreaterThanOrEqual(r.samples, 33)
        let m = try a.matched("u1", b, "u0", level: 1)
        r = try m.continuity("u1", b, "u0")
        XCTAssertLessThanOrEqual(r.gap, 1e-10)
        XCTAssertLessThanOrEqual(r.angle, 1e-8)
        let blend = try Solid.blendSides(a, "u0", b, "u1", level: 2)
        r = try blend.continuity("v0", a, "u0")
        XCTAssertLessThanOrEqual(r.gap, 1e-10)
        XCTAssertLessThanOrEqual(r.angle, 1e-8)
        XCTAssertLessThanOrEqual(r.curvature, 1e-6)
        XCTAssertEqual(refusal { _ = try a.continuity("w2", b, "u0") }, "a side is 'u0', 'u1', 'v0' or 'v1', not 'w2'")
        XCTAssertEqual(refusal { _ = try a.matched("u1", b, "u0", level: 3) }?.hasPrefix("match_side: "), true)
    }

    /// The positions a continuity reports, apart from each other and from the figures they go with.
    func testContinuityReadsEveryFieldInItsPlace() throws {
        let a = try Solid.loftCurves([line(P(-1, 0, 0), P(0, 0, 0)), line(P(-1, 1, 0), P(0, 1, 0))], degree: 1)
        let b = try Solid.loftCurves([line(P(0, 0, 0), P(0, 0, 1)), line(P(0, 1, 0), P(0, 1, 1))], degree: 1)
        let r = try a.continuity("u1", b, "u0", samples: 32)
        // The sides are the line x = 0, z = 0, y in 0...1: every position is on it.
        for at in [r.gapAt, r.angleAt, r.curvatureAt] {
            XCTAssertLessThan(abs(at.x), 1e-9)
            XCTAssertLessThan(abs(at.z), 1e-9)
            XCTAssertTrue(at.y > -1e-9 && at.y < 1 + 1e-9)
        }
        // The angle was found where the worst normal angle is: a right angle everywhere, so any
        // sample; the gap is zero everywhere. Pin the figures to their own names.
        XCTAssertLessThan(r.gap, 1e-12)
        XCTAssertGreaterThan(r.angle, 1.5)
        XCTAssertTrue(r.description.hasPrefix("Continuity(gap="))
    }

    /// Each figure is read with its own position: a gap that grows along the side, and a normal
    /// angle that tilts, are found at different places.
    func testContinuityPositionsBelongToTheirFigures() throws {
        let a = try Solid.loftCurves([line(P(-1, 0, 0), P(0, 0, 0)), line(P(-1, 1, 0), P(0, 1, 0))], degree: 1)
        let b = try Solid.loftCurves([line(P(0, 0, 0), P(0, 0, 1)), line(P(0, 1, 0.2), P(0, 1, 1.2))], degree: 1)
        let r = try a.continuity("u1", b, "u0", samples: 32)
        // The gap opens to a fifth by the far end; the right angle is first found at the near one.
        XCTAssertTrue(r.gap > 0.19 && r.gap <= 0.2 + 1e-9, "\(r)")
        XCTAssertGreaterThan(r.gapAt.y, 0.99, "\(r)")
        XCTAssertLessThan(r.angleAt.y, 0.01, "\(r)")
        XCTAssertLessThan(abs(r.angle - Double.pi / 2), 1e-9, "\(r)")
        XCTAssertLessThan(r.curvature, 1e-9, "\(r)")
        XCTAssertEqual(r.samples, 33, "\(r)")
    }

    func testNSidedPatchFillsAPentagonOfStrips() throws {
        // Five flat strips round a pentagon in z = 0, each lofted from a side outward: the hole's
        // side is each loft's "v0".
        let corners = (0..<5).map { k -> P in
            let a = 2 * Double.pi * Double(k) / 5 + 0.1 * sin(3 * Double(k))
            return P(cos(a), sin(a), 0)
        }
        func out(_ p: P) -> P { P(1.6 * p.x, 1.6 * p.y, 0) }
        let strips = try (0..<5).map { i in
            try Solid.loftCurves([line(corners[i], corners[(i + 1) % 5]), line(out(corners[i]), out(corners[(i + 1) % 5]))], degree: 1)
        }
        let edge = try line(corners[3], corners[4])
        let boundaries: [PatchBoundary] = [
            .side(strips[0], "v0"), .side(strips[1], "v0", level: 1), .side(strips[2], "v0", from: 1, to: 0),
            .curve(edge), .side(strips[4], "v0", level: 2, face: 0),
        ]
        let fill = try Solid.nSidedPatch(boundaries, tolerance: 1e-6)
        let r = try XCTUnwrap(fill.patchReport)
        XCTAssertEqual(try fill.faces, 5, "\(r)")
        XCTAssertEqual(r.faces, 5, "\(r)")
        XCTAssertLessThanOrEqual(r.boundary.gap, 1e-9, "\(r)")
        XCTAssertLessThanOrEqual(r.boundary.angle, 1e-6, "\(r)")
        XCTAssertLessThanOrEqual(r.internal.angle, 1e-6, "\(r)")
        XCTAssertLessThanOrEqual(r.cornerAngle, 1e-9, "\(r)")
        // Face 0 meets strip 0's second half along its v0 side, face 4 the first half along u1.
        for (face, side) in [(0, "v0"), (4, "u1")] {
            let k = try fill.continuity(side, strips[0], "v0", face: face)
            XCTAssertLessThanOrEqual(k.gap, 1e-9, "face \(face): \(k)")
            XCTAssertLessThanOrEqual(k.angle, 1e-6, "face \(face): \(k)")
        }
        // Into the ring: watertight round the hole but where the curve stood in for strip 3.
        let (_, report) = try Solid.joinSheets(Array(strips[..<3]) + [strips[4], fill], tolerance: 1e-6)
        // Naked: the four strips' outer sides, the two radial sides beside the gap, the curve's two halves.
        XCTAssertEqual(report.refused, 0, "\(report)")
        XCTAssertEqual(report.nakedAfter, 4 + 2 + 2, "\(report)")
        XCTAssertEqual(refusal { _ = try Solid.nSidedPatch(Array(boundaries[..<2])) }?.hasPrefix("n_sided_patch: "), true)
        // Every boundary a sheet's side: the curve's place taken by strip 3, the same five faces.
        let whole = try Solid.nSidedPatch(strips.map { .side($0, "v0") }, tolerance: 1e-6)
        XCTAssertEqual(try whole.faces, 5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(whole.patchReport).boundary.angle, 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(whole.patchReport).boundary.samples, 0)
        // A level of 3 on one side of an otherwise good ring is the level's refusal, not the ring's.
        var ring: [PatchBoundary] = strips.map { .side($0, "v0") }
        ring[1] = .side(strips[1], "v0", level: 3)
        let badLevel = try XCTUnwrap(refusal { _ = try Solid.nSidedPatch(ring, tolerance: 1e-6) })
        XCTAssertTrue(badLevel.hasPrefix("n_sided_patch: "), badLevel)
        XCTAssertEqual(refusal { _ = try Solid.nSidedPatch(Array(repeating: .side(strips[0], "x"), count: 3)) },
                       "a side is 'u0', 'u1', 'v0' or 'v1', not 'x'")
    }

    func testFilletSurfacesRollsABallBetweenTwoSheets() throws {
        let floor = try Solid.loftCurves([line(P(0, 0, 0), P(4, 0, 0)), line(P(0, 3, 0), P(4, 3, 0))], degree: 1)
        let wall = try Solid.loftCurves([line(P(0, 0, 0), P(0, 3, 0)), line(P(0, 0, 4), P(0, 3, 4))], degree: 1)
        var found: (sheet: Solid, railA: NurbsCurve, railB: NurbsCurve)?
        for (fa, fb) in [(false, false), (true, false), (false, true), (true, true)] {
            guard let got = try? Solid.filletSurfaces(floor, wall, 1.0, flipA: fa, flipB: fb, tolerance: 1e-4) else { continue }
            let p = try got.railA.point(got.railA.domain.lo)
            if p.x > 0 && abs(p.z) <= 1e-9 {
                found = got
                break
            }
        }
        let (sheet, ra, rb) = try XCTUnwrap(found)
        XCTAssertEqual(try sheet.faces, 1)
        XCTAssertTrue(try XCTUnwrap(sheet.sheetError) >= 0 && sheet.sheetError! <= 1e-4)
        XCTAssertLessThanOrEqual(abs(try ra.point(ra.domain.lo).x - 1.0), 1e-4)
        XCTAssertLessThanOrEqual(abs(try rb.point(rb.domain.lo).z - 1.0), 1e-4)
        // The rails are the caller's: they outlive the sheets they were made on.
        sheet.close()
        floor.close()
        wall.close()
        XCTAssertLessThanOrEqual(abs(try ra.point(ra.domain.lo).x - 1.0), 1e-4)
        XCTAssertLessThanOrEqual(abs(try rb.point(rb.domain.lo).z - 1.0), 1e-4)
        XCTAssertGreaterThan(try ra.length().length, 1)
        let floor2 = try Solid.loftCurves([line(P(0, 0, 0), P(4, 0, 0)), line(P(0, 3, 0), P(4, 3, 0))], degree: 1)
        let wall2 = try Solid.loftCurves([line(P(0, 0, 0), P(0, 3, 0)), line(P(0, 0, 4), P(0, 3, 4))], degree: 1)
        XCTAssertEqual(refusal { _ = try Solid.filletSurfaces(floor2, wall2, 0.0) }?.hasPrefix("fillet_surfaces: "), true)
    }

    func testFilletRoundsASplineEdgeAtAConstantAndAVaryingRadius() throws {
        let shell = try fenderAndDoor()
        let crease = try shell.edges.filter { $0.faces.count == 2 }
        XCTAssertEqual(crease.count, 1)
        XCTAssertEqual(crease[0].kind, "nurbs")
        let constant = try shell.fillet(crease, 12.0, tolerance: 1e-3)
        let varying = try shell.fillet(crease, 8.0, tolerance: 1e-3, radiusEnd: 20.0)
        XCTAssertEqual(try constant.faces, 3)
        XCTAssertEqual(try varying.faces, 3)
        // The fillet cuts the corner off: less area than the sharp shell, and more taken by the
        // larger ball on average (8 to 20 against 12 all along).
        let areaVarying = try area(varying, 1e-6), areaConstant = try area(constant, 1e-6), areaShell = try area(shell, 1e-6)
        XCTAssertLessThan(areaVarying, areaConstant)
        XCTAssertLessThan(areaConstant, areaShell)
        // radius_end equal to radius is the constant fillet.
        let same = try shell.fillet(crease, 12.0, tolerance: 1e-3, radiusEnd: 12.0)
        XCTAssertEqual(try same.faces, 3)
        XCTAssertLessThan(abs(try area(same, 1e-6) - areaConstant), 1e-6 * areaConstant)
        let message = try XCTUnwrap(refusal { _ = try Solid.cuboid(10, 10, 10).fillet([0], 1.0, radiusEnd: 2.0) })
        XCTAssertTrue(message.contains("a varying radius rounds only spline edges"), message)
    }

    func testTheWrappersOwnRefusalsSpellTheCallsWords() throws {
        let circle = try exactCircle(P(0, 0, 0), 1)
        XCTAssertEqual(refusal { _ = try Solid.sweepRail(line(P(0, 0, 0), P(0, 0, 4)), [circle], frame: "twisty") },
                       "sweep_rail: frame is 'rmf' or 'fixed', not 'twisty'")
        let sheet = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 20, 20)
        XCTAssertEqual(refusal { _ = try sheet.trimByCurve(circle, keep: "x") },
                       "trim_by_curve: keep must be 'outside', 'inside', 'left' or 'right', not 'x'")
        XCTAssertEqual(refusal { _ = try sheet.continuity("x", sheet, "u0") }, "a side is 'u0', 'u1', 'v0' or 'v1', not 'x'")
        XCTAssertEqual(refusal { _ = try sheet.matched("u0", sheet, "y") }, "a side is 'u0', 'u1', 'v0' or 'v1', not 'y'")
        XCTAssertEqual(refusal { _ = try Solid.blendSides(sheet, "z", sheet, "u0") }, "a side is 'u0', 'u1', 'v0' or 'v1', not 'z'")
    }
}
