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

    func testMirrorJoinSquaresAHalfRoofToItsMirror() throws {
        // Half a roof domed both ways, lofted out from the centre plane y = 0, leaning as it
        // leaves the plane: mirrored as it is, the seam is a crease; squared first, it is smooth.
        func section(_ y: Double) throws -> NurbsCurve {
            try NurbsCurve.through((0...8).map { i -> SIMD3<Double> in
                let x = 10.0 * Double(i)
                return P(x, y, 20 * sin(Double.pi * x / 80) - 0.01 * y * y + 0.05 * y + 0.002 * x * y)
            })
        }
        let half = try Solid.loftCurves([0.0, 10, 20, 30].map(section))
        let plane = try Frame(P(0, 0, 0), P(1, 0, 0), P(0, 0, -1), P(0, 1, 0))
        let (creased, r) = try half.mirrorJoin(plane, tolerance: 0.01)
        XCTAssertTrue(try creased.faces == 2 && r.seams == 1 && r.squared == 0 && r.moved == 0, "\(r)")
        XCTAssertTrue(r.gap < 1e-9 && r.angle > 5 * Double.pi / 180 && r.curvature > 1e-4, "\(r)")
        let (smooth, s) = try half.mirrorJoin(plane, snap: 0.5, tolerance: 0.01)
        XCTAssertTrue(try smooth.faces == 2 && s.seams == 1 && s.squared == 1 && s.naked == 6, "\(s)")
        XCTAssertTrue(s.moved > 0 && s.gap < 1e-9 && s.angle < 1e-9 && s.curvature < 1e-9, "\(s)")
        // Only the first two rows moved: the body is near twice the half.
        let body: Mass = try smooth.mass(), one: Mass = try half.mass()
        XCTAssertLessThan(abs(body.area - 2 * one.area), 0.01 * one.area)
        XCTAssertEqual(refusal { _ = try smooth.mirrorJoin(plane) }?.hasPrefix("mirror_join: the half lies on both sides of the plane"), true)
    }

    func testARingOnASquareOffsetsSplitsAndPartsWithAPanelGap() throws {
        let sq = try rectSheet(P(0, 0, 0), P(1, 0, 0), P(0, 1, 0), 40, 40)
        let pts = (0..<48).map { i -> P in let a = 2 * Double.pi * Double(i) / 48; return P(8 * cos(a), 8 * sin(a), 0) }
        let ring = try NurbsCurve.through(pts, degree: 3, closed: true)
        let inner = try ring.offsetOnSheet(sq, distance: 2, tolerance: 1e-3)
        let p0 = try inner.point(inner.domain.lo)
        XCTAssertLessThanOrEqual(inner.fitError ?? 1, 1e-3)
        XCTAssertEqual((p0.x * p0.x + p0.y * p0.y).squareRoot(), 6, accuracy: 1e-3)
        XCTAssertEqual(try sq.splitAlongCurve(ring, tolerance: 1e-3).faces, 2)
        let (island, rest) = try sq.panelGap(ring, gap: 4, flange: -10, tolerance: 1e-3)
        XCTAssertEqual(try island.faces, 3)
        XCTAssertEqual(try rest.faces, 3)
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

    func testFilletLawWithStationsAtTheEndsIsTheVaryingFillet() throws {
        let shell = try fenderAndDoor()
        let crease = try shell.edges.filter { $0.faces.count == 2 }
        let varying = try shell.fillet(crease, 8.0, tolerance: 1e-3, radiusEnd: 20.0)
        let lawed = try shell.filletLaw(crease, [(0.0, 8.0), (1.0, 20.0)], tolerance: 1e-3)
        XCTAssertEqual(try lawed.faces, 3)
        XCTAssertLessThan(abs(try area(lawed, 1e-6) - area(varying, 1e-6)), 1e-3)
        // A swell in the middle takes more than 8 all along and less than 20 all along.
        let swell = try area(shell.filletLaw(crease.map { $0.index }, [(0.0, 8.0), (0.5, 20.0), (1.0, 8.0)], tolerance: 1e-3), 1e-6)
        XCTAssertLessThan(swell, try area(shell.fillet(crease, 8.0, tolerance: 1e-3), 1e-6))
        XCTAssertGreaterThan(swell, try area(shell.fillet(crease, 20.0, tolerance: 1e-3), 1e-6))
        let none = try XCTUnwrap(refusal { _ = try shell.filletLaw(crease, [], tolerance: 1e-3) })
        XCTAssertTrue(none.contains("at least one station"), none)
        let message = try XCTUnwrap(refusal { _ = try Solid.cuboid(10, 10, 10).filletLaw([0], [(0.0, 1.0), (1.0, 2.0)]) })
        XCTAssertTrue(message.contains("a radius law rounds only spline edges"), message)
    }

    func testAWobblyLoftFairedTurnsNoCurvatureOver() throws {
        // Eleven lines across a shallow arch, each lifted or dropped by 0.4 in turn: a loft
        // through them ripples between every pair.
        let lines = try (0..<11).map { k -> NurbsCurve in
            let x = 10.0 * Double(k)
            let z = -0.01 * (x - 50) * (x - 50) + (k % 2 == 0 ? 0.4 : -0.4)
            return try line(P(x, 0, z), P(x, 40, z))
        }
        let loft = try Solid.loftCurves(lines, degree: 3)
        let t = try loft.curvatureTurns(samples: 32)
        XCTAssertEqual(t.samples, 32, "\(t)")
        XCTAssertTrue(t.meanTurns.count > 0 && t.meanPositive + t.meanNegative > 1, "\(t)")
        for a in t.meanTurns {
            XCTAssertLessThan(abs((a.tangent * a.tangent).sum().squareRoot() - 1), 1e-9, "\(a)")
            XCTAssertTrue(a.point.x >= 0 && a.point.x <= 100 && a.point.z > -26 && a.point.z < 1, "\(a)")
        }
        // The lines run along u, the loft's v across them: the end lines kept, held along v.
        let faired = try loft.faired(tolerance: 1.0, keep: [nil, nil, 0, 0], noInflection: "v")
        let e = try XCTUnwrap(faired.sheetError)
        XCTAssertTrue(e >= 0 && e <= 1.05, "\(e)")
        let f = try faired.curvatureTurns(samples: 32)
        XCTAssertTrue(f.meanTurns.isEmpty && f.meanPositive + f.meanNegative == 1, "\(f)")
        let coarse = try loft.faired(tolerance: 1.0, controls: (6, 8), keep: [nil, nil, 0, 0], noInflection: "v")
        XCTAssertLessThanOrEqual(try XCTUnwrap(coarse.sheetError), 1.05)
        XCTAssertTrue(try coarse.curvatureTurns().meanTurns.isEmpty)
        let low = try XCTUnwrap(refusal { _ = try loft.faired(tolerance: 1.0, degree: 2) })
        XCTAssertTrue(low.hasPrefix("surface_faired: ") && low.contains("degree 2"), low)
        let tight = try XCTUnwrap(refusal { _ = try loft.faired(tolerance: 0.01, keep: [nil, nil, 0, 0], noInflection: "v") })
        XCTAssertTrue(tight.hasPrefix("surface_faired: ") && tight.contains("no fair free of inflections"), tight)
        XCTAssertEqual(refusal { _ = try loft.faired(keep: [0, 0]) }, "keep takes 4 levels (u0, u1, v0, v1), not 2")
        XCTAssertEqual(refusal { _ = try loft.faired(noInflection: "w") }, "no_inflection is 'u', 'v', 'uv' or nil, not 'w'")
        let bad = try XCTUnwrap(refusal { _ = try loft.curvatureTurns(face: 7) })
        XCTAssertTrue(bad.hasPrefix("curvature_turns: "), bad)
    }

    func testHighlightKinkRunsStraightAcrossPlanesAndKinksAtAFilletSeam() throws {
        let block = try Solid.cuboid(2, 2, 2)
        let k = try block.highlightKink(0, samples: 16)
        XCTAssertLessThan(k.angle, 1e-9, "\(k)")
        XCTAssertEqual(k.samples, 17)
        let rounded = try block.fillet([0], 0.5)
        var worst = 0.0
        for e in try rounded.edges {
            guard let kink = try? rounded.highlightKink(e) else { continue }   // an edge of one face
            worst = max(worst, kink.angle)
        }
        // Where the fillet's curvature meets a flat face's, the highlight lines break.
        XCTAssertGreaterThan(worst, Double.pi / 4)
        let bad = try XCTUnwrap(refusal { _ = try block.highlightKink(999) })
        XCTAssertTrue(bad.hasPrefix("highlight_kink: "), bad)
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

    func testHolesRibsWebsAndPatternsAgainstTheirClosedForms() throws {
        let pi = Double.pi
        // A through hole down the top of a 40 x 30 x 20 block with its corner at the origin.
        let blk = try Solid.cuboid(40, 30, 20).translate(20, 15, 10)
        let (drilled, hr) = try blk.hole(P(10, 15, 20), 4)
        let drilledVolume: Double = 24000 - 80 * pi
        XCTAssertEqual(try massOf(drilled).volume, drilledVolume, accuracy: 1e-6 * drilledVolume)
        XCTAssertEqual(try drilled.faces, 7)
        XCTAssertEqual(hr.holes, 1)
        XCTAssertEqual(hr.facesAdded, 1)
        XCTAssertEqual(hr.bottoms.count, 1)
        XCTAssertEqual(hr.bottoms[0], 20, accuracy: 1e-9)
        let holeTool = try blk.holeTool(P(10, 15, 20), 4)
        XCTAssertGreaterThan(try massOf(holeTool).volume, 80 * pi)

        // A 4 x 3 grid of pins cut from a plate: twelve copies, one boolean.
        let plate = try Solid.cuboid(100, 60, 10).translate(50, 30, 5)
        let pin = try Solid.cylinder(3, 30).translate(10, 10, -10)
        let grid = try Pattern.rectangular(P(1, 0, 0), 4, 20, P(0, 1, 0), 3, 20)
        XCTAssertEqual(grid.count, 12)
        let (pierced, pr) = try plate.patternFeature(pin, .cut, grid)
        let piercedVolume: Double = 60000 - 1080 * pi
        XCTAssertEqual(try massOf(pierced).volume, piercedVolume, accuracy: 1e-6 * piercedVolume)
        XCTAssertEqual(pr.instances, 12)
        XCTAssertEqual(pr.booleans, 1)
        XCTAssertEqual(pr.missed, 0)

        // Placements: instance 0 the identity, the next one 10 along x, row-major.
        let row = try Pattern.rectangular(P(1, 0, 0), 3, 10)
        XCTAssertEqual(row.count, 3)
        XCTAssertEqual(row[0].rows, [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        XCTAssertEqual(row[1].rows, [1, 0, 0, 10, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
        // Two blocks 8 apart overlap: one join.
        let (two, tr) = try blk.pattern(Array(try Pattern.rectangular(P(1, 0, 0), 2, 8).prefix(2)))
        XCTAssertEqual(tr.instances, 2)
        XCTAssertEqual(tr.booleans, 1)
        let twoVolume: Double = 28800
        XCTAssertEqual(try massOf(two).volume, twoVolume, accuracy: 1e-6 * twoVolume)
        let turn = try Pattern.circular(P(0, 0, 0), P(0, 0, 1), 6)
        XCTAssertEqual(turn.count, 6)
        XCTAssertEqual(turn[1].rows[0], 0.5, accuracy: 1e-12)
        let along = try Pattern.along(line(P(0, 0, 0), P(30, 0, 0)), 4)
        XCTAssertEqual(along.count, 4)
        XCTAssertEqual(along[3].rows[3], 30, accuracy: 1e-9)

        // A rib across the inside corner of an L, in the L's middle plane y = 15.
        let foot = try Solid.cuboid(40, 30, 5).translate(20, 15, 2.5)
        let upright = try Solid.cuboid(5, 30, 40).translate(2.5, 15, 20)
        let l = try foot.join(upright, tolerance: nil)
        let lVolume: Double = 11250
        XCTAssertEqual(try massOf(l).volume, lVolume, accuracy: 1e-6 * lVolume)
        let diag = try line(P(30, 15, 5), P(5, 15, 30))
        let plane = try Frame(P(0, 15, 0), P(1, 0, 0), P(0, 0, 1), P(0, -1, 0))
        let ribbedVolume: Double = 11250 + 1250
        XCTAssertEqual(try massOf(l.rib(diag, plane, 4)).volume, ribbedVolume, accuracy: 1e-6 * ribbedVolume)
        let slabVolume: Double = 1250
        XCTAssertEqual(try massOf(l.ribTool(diag, plane, 4, side: .front)).volume, slabVolume, accuracy: 1e-6 * slabVolume)

        // A web across a tray, run down from the rim to the floor.
        let tray = try Solid.cuboid(60, 40, 20).translate(30, 20, 10).cut(Solid.cuboid(56, 36, 18).translate(30, 20, 11))
        let down = try Frame(P(0, 0, 10), P(1, 0, 0), P(0, -1, 0), P(0, 0, -1))
        let alongX = try line(P(10, 20, 10), P(50, 20, 10))
        let webVolume: Double = 1344   // 56 x 3 x 8
        let added = try massOf(tray.web([alongX], down, 3)).volume - massOf(tray).volume
        XCTAssertEqual(added, webVolume, accuracy: 1e-6 * webVolume)
        XCTAssertGreaterThan(try massOf(tray.webTool(alongX, down, 3, depth: 6)).volume, 0)

        XCTAssertEqual(refusal { _ = try blk.hole(P(10, 15, 20), 0) }?.hasPrefix("hole: diameter 0 is not positive and finite"), true)
        XCTAssertEqual(refusal { _ = try Pattern.rectangular(P(1, 0, 0), 0, 10) }?.hasPrefix("pattern_rectangular: count1 is 0"), true)
    }
}
