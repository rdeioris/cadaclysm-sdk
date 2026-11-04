// The 2D constraint sketcher over the release library: Python's test_cadaclysm_blacksmith.py,
// "Sketch: the 2D constraint sketcher", facts S1-S8 and S10-S12 ported value for value.
@testable import Blacksmith
import CCadaclysmBlacksmith
import Foundation
import XCTest

/// The refusal `body` raised: its message and ids, or nil when it did not throw a BuildError.
private func refusal(_ body: () throws -> Void) -> (message: String, ids: [UInt32])? {
    do {
        try body()
    } catch let error as BuildError {
        return (error.message, error.ids)
    } catch {
        return ("not a BuildError: \(error)", [])
    }
    return nil
}

private func near(_ p: SIMD2<Double>, _ x: Double, _ y: Double, _ tol: Double = 1e-9,
                  file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(p.x, x, accuracy: tol, file: file, line: line)
    XCTAssertEqual(p.y, y, accuracy: tol, file: file, line: line)
}

final class BlacksmithSketchTests: XCTestCase {
    private let origin = SIMD2<Double>(0, 0)

    // S1
    func testASketchDimensionsAPlateAndExtrudesIt() throws {
        let s = try Sketch()
        let (corners, sides) = try s.addRect(origin, SIMD2(40, 30))
        XCTAssertEqual(corners.count, 4)
        XCTAssertEqual(sides.count, 4)
        try s.fix(corners[0])
        let width = try s.length(sides[0], 60)
        try s.length(sides[1], 30)
        let hole = try s.addCircle(try s.addPoint(30, 15), 5)
        try s.radiusOf(hole, 5)
        let report = try s.solve()
        XCTAssertTrue(report.converged)
        XCTAssertEqual(report.status, "converged")
        XCTAssertEqual(report.ids, [])
        near(try s.point(corners[1]), 60, 0)
        XCTAssertEqual(try s.constraintKind(width), "length")
        XCTAssertEqual(try s.constraintValue(width), 60)
        let dof = try s.diagnose()
        XCTAssertEqual(dof.free, 2)
        XCTAssertEqual(dof.state, "under")
        let profiles = try s.profiles(tolerance: 1e-9)
        XCTAssertEqual(profiles.count, 1)
        let solid = try Solid.extrude(profiles[0], try Frame.xy(), 10)
        let mass: Mass = try solid.mass()
        XCTAssertGreaterThan(mass.volume, 0)
    }

    // S2
    func testAConflictIsRefusedWithIds() throws {
        let s = try Sketch()
        let (corners, sides) = try s.addRect(origin, SIMD2(40, 30))
        try s.fix(corners[0])
        try s.length(sides[0], 40)
        try s.length(sides[1], 30)
        let conflict = try XCTUnwrap(refusal { try s.distance(corners[0], corners[2], 10) })
        XCTAssertNotNil(conflict)
        XCTAssertTrue(conflict.message.hasPrefix("sketch_constrain: over-constrained"), conflict.message)
        XCTAssertEqual(conflict.ids, [0, 1, 5, 6])
        XCTAssertEqual(try s.constraints().count, 7)

        let removal = try XCTUnwrap(refusal { try s.removeEntity(corners[0]) })
        XCTAssertNotNil(removal)
        XCTAssertTrue(removal.message.hasPrefix("sketch_remove_entity: point"), removal.message)
        XCTAssertEqual(removal.ids.sorted(), [sides[0], sides[3]].sorted())

        let unknown = try XCTUnwrap(refusal { _ = try s.kind(9999) })
        XCTAssertNotNil(unknown)
        XCTAssertTrue(unknown.message.contains("sketch_kind"), unknown.message)
        XCTAssertEqual(unknown.ids, [])

        s.close()
        XCTAssertTrue(s.isClosed)
        XCTAssertEqual(refusal { _ = try s.solve() }?.message, "sketch: closed")
        s.close()
    }

    // S3
    func testDragMovesThePointItHolds() throws {
        let s = try Sketch()
        let (corners, _) = try s.addRect(origin, SIMD2(40, 30))
        let report = try s.drag([corners[0]: SIMD2(5, 5)])
        XCTAssertTrue(report.converged)
        XCTAssertEqual(report.ids, [])
        near(try s.point(corners[0]), 5, 5)
        XCTAssertEqual(try s.point(corners[1]).y, 5, accuracy: 1e-9)
    }

    // S4
    func testAReferenceFollowsItsSource() throws {
        let plate = try Sketch()
        let (corners, sides) = try plate.addRect(origin, SIMD2(40, 30))
        try plate.fix(corners[0])
        let width = try plate.length(sides[0], 40)
        try plate.length(sides[1], 30)

        let boss = try Sketch()
        let edge = try boss.reference(plate, sides[1])
        XCTAssertTrue(boss.isReference(edge))
        XCTAssertTrue(boss.isConstruction(edge))
        let o = try boss.addPoint(130, 15)
        let hole = try boss.addCircle(o, 12)
        try boss.radiusOf(hole, 12)
        try boss.pointLineDistance(o, edge, 100)
        XCTAssertEqual(try boss.point(o).x, 140, accuracy: 1e-9)
        XCTAssertEqual(try boss.profiles(tolerance: 1e-9).count, 1)

        XCTAssertTrue(try plate.setValue(width, 60).converged)
        let update = try boss.updateReference(edge, plate)
        XCTAssertTrue(update.converged)
        XCTAssertEqual(update.ids, [])
        XCTAssertEqual(try boss.point(o).x, 160, accuracy: 1e-9)

        let notRef = try XCTUnwrap(refusal { try boss.updateReference(o, plate) })
        XCTAssertTrue(notRef.message.hasPrefix("sketch_update_reference: entity"), notRef.message)
        XCTAssertEqual(notRef.ids, [])
        let selfRef = try XCTUnwrap(refusal { try boss.reference(boss, o) })
        XCTAssertTrue(selfRef.message.contains("cannot reference itself"), selfRef.message)
    }

    // S5
    func testASketchComesFromAProfileAndKeepsItsTangents() throws {
        let slot = try Profile.slot(origin, 60, 8)
        let s = try Sketch.fromProfile(slot, tolerance: 1e-9)
        let tangents = try s.constraints().filter { try s.constraintKind($0) == "tangent" }
        XCTAssertEqual(tangents.count, 4)
        for t in tangents { XCTAssertTrue(s.isJointTangent(t)) }
        XCTAssertEqual(try s.diagnose().free, 4)
    }

    // S6
    func testASketchReadsBackWhatItHolds() throws {
        let s = try Sketch()
        let a = try s.addPoint(0, 0)
        let b = try s.addPoint(10, 0)
        let line = try s.addLine(a, b)
        XCTAssertEqual(try s.kind(a), "point")
        XCTAssertEqual(try s.kind(line), "line")
        XCTAssertEqual(try s.entities(), [a, b, line].sorted())
        XCTAssertEqual(try s.ends(line), [a, b])

        let c = try s.addCircle(try s.addPoint(0, 5), 3)
        XCTAssertEqual(try s.radius(c), 3)
        try s.setRadius(c, 4)
        XCTAssertEqual(try s.radius(c), 4)
        try s.setPoint(b, 12, 0)
        near(try s.point(b), 12, 0)
        try s.setConstruction(c)
        XCTAssertTrue(s.isConstruction(c))
        XCTAssertFalse(s.isReference(c))

        let h = try s.horizontal(a, b)
        XCTAssertEqual(try s.constraintKind(h), "horizontal")
        XCTAssertEqual(try s.constraintRefs(h), [a, b])
        XCTAssertNil(try s.constraintValue(h))
        XCTAssertFalse(try s.constraintDriving(h))
        XCTAssertEqual(try s.constraintSense(h), "auto")

        let d = try s.distance(a, b, 15, driving: false)
        XCTAssertEqual(try s.constraintValue(d), 15)
        XCTAssertFalse(try s.constraintDriving(d))
        XCTAssertEqual(try s.measure(d), 12, accuracy: 1e-12)
        XCTAssertTrue(try s.setDriving(d, true).converged)
        XCTAssertTrue(try s.constraintDriving(d))
        XCTAssertEqual(try s.constraintValue(d)!, 12, accuracy: 1e-9)
        XCTAssertTrue(try s.setValue(d, 20).converged)
        XCTAssertEqual(try s.measure(d), 20, accuracy: 1e-9)

        let dragged = try s.drag([b: SIMD2(25, 5)])
        XCTAssertTrue(["converged", "conflicting", "diverged"].contains(dragged.status))

        XCTAssertEqual(try s.constraints(), [h, d].sorted())
        try s.remove(h)
        XCTAssertEqual(try s.constraints(), [d])
        XCTAssertEqual(try s.removeEntity(line), [d])
        XCTAssertFalse(try s.entities().contains(a), "its ends went with it")
        XCTAssertEqual(try s.constraints(), [])

        let bez = try s.addBezier(try s.addPoint(0, 0), SIMD2(1, 1), SIMD2(2, 1), SIMD2(3, 0))
        XCTAssertEqual(try s.kind(bez), "free_curve")
        XCTAssertEqual(try s.ends(bez).count, 4)
        XCTAssertEqual(try s.openChains(tolerance: 1e-9).count, 1)

        XCTAssertNotNil(refusal { _ = try s.kind(9999) })
        let sideways = try XCTUnwrap(refusal { try s.tangent(bez, c, sense: "sideways") })
        XCTAssertTrue(sideways.message.contains("sense"), sideways.message)
        for word in ["auto", "positive", "negative", "sideways"] {
            XCTAssertTrue(sideways.message.contains(word), sideways.message)
        }
    }

    // S7
    func testTangentAtEndReadsItsEnd() throws {
        let s = try Sketch()
        let start = try s.addPoint(0, 0)
        let bez = try s.addBezier(start, SIMD2(1, 1), SIMD2(2, 1), SIMD2(3, 0))
        let p = try s.addPoint(8, 0)
        let q = try s.addPoint(8, 4)
        let line = try s.addLine(p, q)
        let atEnd = try s.tangentAtEnd(bez, line, end: "end")
        XCTAssertEqual(try s.constraintEnd(atEnd), "end")
        let line2 = try s.addLine(try s.addPoint(20, 0), try s.addPoint(20, 4))
        let atStart = try s.tangentAtEnd(bez, line2)
        XCTAssertEqual(try s.constraintEnd(atStart), "start")
        XCTAssertEqual(try s.constraintEnd(try s.length(line, 4)), "start")
        XCTAssertEqual(refusal { _ = try s.constraintEnd(999) }?.message, "sketch_constraint_end: no constraint 999")
    }

    // S8
    func testNurbsAndFinite() throws {
        let s = try Sketch()
        let start = try s.addPoint(0, 0)
        let pts: [SIMD2<Double>] = [SIMD2(1, 2), SIMD2(3, 2), SIMD2(4, 0)]
        let knots: [Double] = [0, 0, 0, 0.5, 1, 1, 1]
        let bad = try XCTUnwrap(refusal { try s.addNurbs(start, points: pts, knots: knots, degree: 2, weights: [1, 1, 1]) })
        XCTAssertTrue(bad.message.contains("sketch_add_nurbs"), bad.message)
        let curve = try s.addNurbs(start, points: pts, knots: knots, degree: 2, weights: [1, 0.5, 0.5, 1])
        XCTAssertEqual(try s.kind(curve), "free_curve")
        XCTAssertEqual(try s.ends(curve).count, 4)
        XCTAssertEqual(try s.ends(curve).first, start)

        let t = try Sketch()
        let nan = try XCTUnwrap(refusal { try t.addPoint(.nan, 0) })
        XCTAssertEqual(nan.message, "sketch_add_point: the coordinates must be finite")
        XCTAssertEqual(try t.entities(), [])
    }

    // S10
    func testSenseSidesAndUnknownConstraintReads() throws {
        for (sense, y) in [("positive", 3.0), ("negative", -3.0)] {
            let s = try Sketch()
            let a = try s.addPoint(0, 0)
            let b = try s.addPoint(10, 0)
            let line = try s.addLine(a, b)
            try s.fix(a)
            try s.fix(b)
            let p = try s.addPoint(4, y > 0 ? 1 : -1)
            try s.pointLineDistance(p, line, 3, sense: sense)
            XCTAssertTrue(try s.solve().converged)
            XCTAssertEqual(try s.point(p).y, y, accuracy: 1e-6, sense)
        }
        let s = try Sketch()
        let vr = refusal { _ = try s.constraintValue(999) }
        XCTAssertTrue(try XCTUnwrap(vr).message.contains("999"))
        let dr = refusal { _ = try s.constraintDriving(999) }
        XCTAssertTrue(try XCTUnwrap(dr).message.contains("999"))
    }

    // S11
    func testDiagnosisListsNameRedundantAndConflicting() throws {
        let s = try Sketch()
        let (corners, sides) = try s.addRect(origin, SIMD2(40, 30))
        try s.fix(corners[0])
        try s.length(sides[0], 40)
        try s.length(sides[1], 30)
        let h = try s.horizontal(corners[3], corners[2])
        XCTAssertEqual(h, 7)
        let dof = try s.diagnose()
        XCTAssertEqual(dof.free, 0)
        XCTAssertEqual(dof.state, "full")
        XCTAssertEqual(dof.redundant, [7])
        XCTAssertEqual(dof.conflicting, [])
        XCTAssertEqual(dof.parts.count, 1)
        let part = dof.parts[0]
        XCTAssertEqual(part.free, 0)
        XCTAssertEqual(part.state, "full")
        XCTAssertEqual(part.redundant, [7])
        XCTAssertEqual(part.conflicting, [])
        XCTAssertEqual(part.constraints, [0, 1, 2, 3, 5, 6, 7])
    }

    // S12
    func testASetValueThatCannotConvergeIsRefusedWithItsIds() throws {
        let s = try Sketch()
        let a = try s.addPoint(0, 0)
        let b = try s.addPoint(1, 0)
        let c = try s.addPoint(0, 1)
        try s.distance(a, b, 1)
        try s.distance(b, c, 1)
        let d3 = try s.distance(a, c, 1)
        let diverged = try XCTUnwrap(refusal { _ = try s.setValue(d3, 10) })
        XCTAssertTrue(diverged.message.hasPrefix("sketch_set_value: the solve did not converge"), diverged.message)
        XCTAssertEqual(diverged.ids, [2, 0, 1])
        XCTAssertTrue(try s.solve().converged)
    }

    // The drag rule: ascending ids, whatever order the dictionary walks its keys in.
    func testDragSendsItsPointIdsAscending() throws {
        var moves: [UInt32: SIMD2<Double>] = [:]
        let ids: [UInt32] = [40, 7, 1000, 3, 21, 512, 0, 99, 64, 8]
        for id in ids { moves[id] = SIMD2(Double(id), 0) }
        XCTAssertEqual(sketchDragIDs(moves), ids.sorted())
        let s = try Sketch()
        let (corners, _) = try s.addRect(origin, SIMD2(40, 30))
        let report = try s.drag([corners[2]: SIMD2(41, 31), corners[0]: SIMD2(-1, -1), corners[1]: SIMD2(41, -1)])
        XCTAssertTrue(report.converged)
    }

    // Counts and codes arrive as doubles: whole, in i32 range, or the call is refused naming itself.
    func testReportNumbersAreConvertedExactly() throws {
        XCTAssertEqual(try sketchWhole(3, "sketch_solve"), 3)
        XCTAssertEqual(try sketchWhole(Double(Int32.max), "sketch_solve"), Int(Int32.max))
        for bad in [Double.nan, .infinity, 2.5, -1, Double(Int32.max) + 1] {
            let refused = refusal { _ = try sketchWhole(bad, "sketch_diagnose") }
            XCTAssertTrue(try XCTUnwrap(refused).message.hasPrefix("sketch_diagnose: the library answered"), "\(bad)")
        }
    }

    // Every constraint method on geometry of its own, so none is refused: each reads back its
    // kind and refs (and value), and the wrapper's kind table matches the header's codes.
    func testEveryConstraintMethodAddsItsKind() throws {
        let headerCodes: [(Int32, String)] = [
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COINCIDENT, "coincident"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_LINE, "point_on_line"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_ON_CIRCLE, "point_on_circle"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL, "horizontal"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL, "vertical"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PARALLEL, "parallel"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_PERPENDICULAR, "perpendicular"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_COLLINEAR, "collinear"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT, "tangent"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_TANGENT_AT_END, "tangent_at_end"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CONCENTRIC, "concentric"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_LENGTH, "equal_length"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_EQUAL_RADIUS, "equal_radius"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_MIDPOINT, "midpoint"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_SYMMETRIC, "symmetric"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_FIX, "fix"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DISTANCE, "distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_POINT_LINE_DISTANCE, "point_line_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LINE_DISTANCE, "line_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_LINE_DISTANCE, "circle_line_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_CIRCLE_DISTANCE, "circle_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_HORIZONTAL_DISTANCE, "horizontal_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_VERTICAL_DISTANCE, "vertical_distance"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_LENGTH, "length"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_ANGLE, "angle"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_RADIUS, "radius"),
            (CADACLYSM_BLACKSMITH_SKETCH_CONSTRAINT_DIAMETER, "diameter"),
        ]
        XCTAssertEqual(headerCodes.count, 27)
        for (code, name) in headerCodes {
            XCTAssertEqual(sketchConstraintKinds[Int(code)], name, "the wrapper's table at the header's code for \(name)")
        }

        let s = try Sketch()
        var ox: Double = 0
        func place() { ox += 100 }
        func pt(_ x: Double, _ y: Double) throws -> UInt32 { try s.addPoint(ox + x, y) }
        func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) throws -> UInt32 {
            try s.addLine(try pt(x0, y0), try pt(x1, y1))
        }
        func circle(_ x: Double, _ y: Double, _ r: Double) throws -> UInt32 { try s.addCircle(try pt(x, y), r) }
        func readBack(_ kind: String, _ refs: [UInt32], _ id: UInt32, value: Double? = nil, sense: String? = nil) throws {
            XCTAssertEqual(try s.constraintKind(id), kind)
            XCTAssertEqual(try s.constraintRefs(id), refs, kind)
            XCTAssertEqual(try s.constraintValue(id), value, kind)
            if let sense { XCTAssertEqual(try s.constraintSense(id), sense, kind) }
            XCTAssertTrue(try s.solve().converged, kind)
        }

        place()
        var r: [UInt32] = [try pt(0, 0), try pt(1, 1)]
        try readBack("coincident", r, try s.coincident(r[0], r[1]))
        place()
        r = [try pt(3, 2), try line(0, 0, 10, 0)]
        try readBack("point_on_line", r, try s.pointOnLine(r[0], r[1]))
        place()
        r = [try pt(6, 1), try circle(0, 0, 5)]
        try readBack("point_on_circle", r, try s.pointOnCircle(r[0], r[1]))
        place()
        r = [try pt(0, 0), try pt(5, 1)]
        try readBack("horizontal", r, try s.horizontal(r[0], r[1]))
        XCTAssertEqual(try s.point(r[0]).y, try s.point(r[1]).y, accuracy: 1e-9)
        place()
        r = [try pt(0, 0), try pt(1, 5)]
        try readBack("vertical", r, try s.vertical(r[0], r[1]))
        XCTAssertEqual(try s.point(r[0]).x, try s.point(r[1]).x, accuracy: 1e-9)
        place()
        r = [try line(0, 0, 10, 0), try line(0, 5, 10, 7)]
        try readBack("parallel", r, try s.parallel(r[0], r[1]))
        place()
        r = [try line(0, 0, 10, 0), try line(3, 5, 4, 15)]
        try readBack("perpendicular", r, try s.perpendicular(r[0], r[1]))
        place()
        r = [try line(0, 0, 10, 0), try line(12, 1, 20, 2)]
        try readBack("collinear", r, try s.collinear(r[0], r[1]))
        place()
        r = [try circle(0, 5, 3), try line(-10, 0, 10, 0)]
        try readBack("tangent", r, try s.tangent(r[0], r[1]))
        place()
        r = [try circle(0, 0, 3), try circle(7, 0, 3)]
        try readBack("tangent", r, try s.tangent(r[0], r[1], sense: "positive"), sense: "positive")
        place()
        let ln = try line(0, 0, 4, 0)
        let bez = try s.addBezier(try s.ends(ln)[1], SIMD2(ox + 5, 0), SIMD2(ox + 6, 1), SIMD2(ox + 7, 1))
        let atEnd = try s.tangentAtEnd(bez, ln, end: "end")
        try readBack("tangent_at_end", [bez, ln], atEnd)
        XCTAssertEqual(try s.constraintEnd(atEnd), "end")
        place()
        r = [try circle(0, 0, 3), try circle(1, 1, 5)]
        try readBack("concentric", r, try s.concentric(r[0], r[1]))
        place()
        r = [try line(0, 0, 10, 0), try line(0, 5, 7, 5)]
        try readBack("equal_length", r, try s.equalLength(r[0], r[1]))
        place()
        r = [try circle(0, 0, 3), try circle(9, 0, 5)]
        try readBack("equal_radius", r, try s.equalRadius(r[0], r[1]))
        place()
        r = [try pt(4, 1), try line(0, 0, 10, 0)]
        try readBack("midpoint", r, try s.midpoint(r[0], r[1]))
        place()
        r = [try pt(-3, 2), try pt(4, 3), try line(0, 0, 0, 10)]
        try readBack("symmetric", r, try s.symmetric(r[0], r[1], r[2]))
        place()
        r = [try pt(2, 2)]
        try readBack("fix", r, try s.fix(r[0]))
        place()
        r = [try pt(0, 0), try pt(5, 1)]
        try readBack("distance", r, try s.distance(r[0], r[1], 7), value: 7)
        place()
        r = [try pt(3, 2), try line(0, 0, 10, 0)]
        try readBack("point_line_distance", r, try s.pointLineDistance(r[0], r[1], 3), value: 3)
        place()
        r = [try line(0, 0, 10, 0), try line(0, 5, 10, 5)]
        try readBack("line_distance", r, try s.lineDistance(r[0], r[1], 4), value: 4)
        place()
        r = [try circle(0, 10, 2), try line(-10, 0, 10, 0)]
        try readBack("circle_line_distance", r, try s.circleLineDistance(r[0], r[1], 3), value: 3)
        place()
        r = [try circle(0, 0, 2), try circle(10, 0, 3)]
        try readBack("circle_distance", r, try s.circleDistance(r[0], r[1], 3), value: 3)
        place()
        r = [try pt(0, 0), try pt(5, 1)]
        try readBack("horizontal_distance", r, try s.horizontalDistance(r[0], r[1], 6), value: 6)
        XCTAssertEqual(try s.point(r[1]).x - s.point(r[0]).x, 6, accuracy: 1e-9)
        place()
        r = [try pt(0, 0), try pt(5, 1)]
        try readBack("vertical_distance", r, try s.verticalDistance(r[0], r[1], 6), value: 6)
        XCTAssertEqual(try s.point(r[1]).y - s.point(r[0]).y, 6, accuracy: 1e-9)
        place()
        r = [try line(0, 0, 10, 0)]
        try readBack("length", r, try s.length(r[0], 12), value: 12)
        place()
        r = [try line(0, 0, 10, 0), try line(0, 5, 10, 7)]
        try readBack("angle", r, try s.angle(r[0], r[1], 0.5), value: 0.5)
        place()
        r = [try circle(0, 0, 3)]
        try readBack("radius", r, try s.radiusOf(r[0], 4), value: 4)
        XCTAssertEqual(try s.radius(r[0]), 4, accuracy: 1e-9)
        place()
        r = [try circle(0, 0, 3)]
        try readBack("diameter", r, try s.diameter(r[0], 9), value: 9)
        XCTAssertEqual(try s.radius(r[0]), 4.5, accuracy: 1e-9)
        XCTAssertEqual(try s.constraints().count, 28)

        let arc = try s.addArc(try s.addPoint(0, -30), try s.addPoint(5, -30), try s.addPoint(0, -25))
        let conic = try s.addConic(try s.addPoint(0, -60), SIMD2(1, -58), SIMD2(3, -60), weight: 0.7)
        XCTAssertEqual(try s.kind(arc), "arc")
        XCTAssertEqual(try s.kind(conic), "free_curve")
    }
}
