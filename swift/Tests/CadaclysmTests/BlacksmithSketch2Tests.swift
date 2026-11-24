// Sketch part 2: smooth, translated, rotated, polygon, chamfer, patterns, auto-constrain.
// Python's test_sketch_smooth_translated_rotated / _polygon_and_chamfer / _patterns / _auto_constrain.
@testable import Blacksmith
import CCadaclysmBlacksmith
import Foundation
import XCTest

private func near(_ p: SIMD2<Double>, _ x: Double, _ y: Double, _ tol: Double = 1e-9,
                  file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(p.x, x, accuracy: tol, file: file, line: line)
    XCTAssertEqual(p.y, y, accuracy: tol, file: file, line: line)
}

final class BlacksmithSketch2Tests: XCTestCase {
    private let origin = SIMD2<Double>(0, 0)

    func testSmoothTranslatedRotated() throws {
        let s = try Sketch()
        let c = try s.addPoint(0, 0), a0 = try s.addPoint(5, 0), a1 = try s.addPoint(0, 5)
        let arc = try s.addArc(c, a0, a1)
        let bezier = try s.addBezier(a1, SIMD2(-2, 5.3), SIMD2(-4, 4), SIMD2(-6, 1))
        try s.fix(arc)
        let id = try s.smooth(arc, bezier)
        XCTAssertEqual(try s.constraintKind(id), "smooth")

        let t = try Sketch()
        let p = try t.addPoint(1, 1), q = try t.addPoint(0, 0), f = try t.addPoint(0, 0), to = try t.addPoint(3, 4)
        for e in [p, f, to] { try t.fix(e) }
        try t.translated(p, q, f, to)
        near(try t.point(q), 4, 5)

        let r = try Sketch()
        let rc = try r.addPoint(0, 0), rf = try r.addPoint(2, 0), rt = try r.addPoint(0, 7)
        let rp = try r.addPoint(3, 1), rq = try r.addPoint(0, 0.5)
        for e in [rc, rf, rt, rp] { try r.fix(e) }
        try r.rotated(rp, rq, rc, rf, rt)
        near(try r.point(rq), -1, 3)
    }

    func testPolygonAndChamfer() throws {
        let s = try Sketch()
        let hex = try s.addPolygon(origin, SIMD2(5, 0), 6)
        XCTAssertEqual(hex.corners.count, 6)
        XCTAssertEqual(hex.sides.count, 6)
        for i in 0..<6 {
            let a = try s.point(hex.corners[i]), b = try s.point(hex.corners[(i + 1) % 6])
            XCTAssertEqual(((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot(), 5, accuracy: 1e-9)
        }
        XCTAssertEqual(try s.diagnose().free, 4)

        let c = try Sketch()
        let rect = try c.addRect(origin, SIMD2(10, 10))
        let cut = try c.chamfer(rect.sides[0], rect.sides[1], 2, 3)
        near(try c.point(cut.points.0), 8, 0)
        near(try c.point(cut.points.1), 10, 3)
        XCTAssertEqual(cut.corner, rect.corners[1])
        let profiles = try c.profiles(tolerance: 1e-9)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(try profiles[0].areaProperties().area, 97, accuracy: 1e-9)

        let d = try Sketch()
        let r2 = try d.addRect(origin, SIMD2(10, 10))
        _ = try d.chamferAngle(r2.sides[0], r2.sides[1], 2, Double.pi / 4)

        let e = try Sketch()
        let r3 = try e.addRect(origin, SIMD2(10, 10))
        do {
            _ = try e.chamfer(r3.sides[0], r3.sides[1], 20, 3)
            XCTFail("expected a refusal")
        } catch let error as BuildError {
            XCTAssertTrue(error.message.hasPrefix("sketch_chamfer: "), error.message)
        }
    }

    func testPatterns() throws {
        let s = try Sketch()
        let circle = try s.addCircle(try s.addPoint(10, 0), 1)
        let centre = try s.addPoint(0, 0)
        let ring = try s.patternCircular([circle], centre, 6, Double.pi / 3)
        XCTAssertEqual(ring.copies.count, 5)
        XCTAssertEqual(ring.steps.count, 2)
        XCTAssertEqual(ring.dimensions.count, 1)
        near(try s.point(try s.centre(ring.copies[0][0])), 5, 8.660254037844386)

        let g = try Sketch()
        let pt = try g.addPoint(0, 0)
        let row = try g.patternRectangular([pt], SIMD2(2, 0), 3, SIMD2(0, 0), 1)
        XCTAssertEqual(row.copies.count, 2)
        near(try g.point(row.copies[0][0]), 2, 0)
        near(try g.point(row.copies[1][0]), 4, 0)
        XCTAssertEqual(row.dimensions.count, 2)
    }

    /// A triangle with side a-b on the vertical construction line x = 0: (the free point c,
    /// side b-c, side c-a), the line.
    private func triangleOnALine(_ s: Sketch) throws -> ([UInt32], UInt32) {
        let line = try s.addLine(try s.addPoint(0, 0), try s.addPoint(0, 10))
        try s.setConstruction(line)
        let a = try s.addPoint(0, 2), b = try s.addPoint(0, 8), c = try s.addPoint(5, 5)
        _ = try s.addLine(a, b)
        return ([c, try s.addLine(b, c), try s.addLine(c, a)], line)
    }

    func testMirror() throws {
        let s = try Sketch()
        let (ents, axis) = try triangleOnALine(s)
        let m = try s.mirror(ents, axis)
        XCTAssertEqual(m.copies.count, 3)
        XCTAssertEqual(try m.copies.map { try s.kind($0) }, ["point", "line", "line"])
        near(try s.point(m.copies[0]), -5, 5)
        XCTAssertFalse(m.constraints.isEmpty)
        for c in m.constraints {
            XCTAssertTrue(["symmetric", "equal_radius", "point_on_line"].contains(try s.constraintKind(c)))
        }

        let r = try Sketch()
        let (ents2, axis2) = try triangleOnALine(r)
        let before = try r.entities().count
        do {
            _ = try r.mirror(ents2 + [axis2], axis2)
            XCTFail("expected a refusal")
        } catch let error as BuildError {
            XCTAssertTrue(error.message.contains("mirror line must not be among"), error.message)
        }
        XCTAssertEqual(try r.entities().count, before)
    }

    func testAutoConstrain() throws {
        let s = try Sketch.fromProfile(try Profile.rect(10, 6), infer: false)
        let ids = try s.autoConstrain(tolerance: 0, dimensions: true)
        XCTAssertFalse(ids.isEmpty)
        XCTAssertEqual(try s.diagnose().free, 0)
    }
}
