// The rectangle, the triangle and the ray over the release library (value geometry plan B4):
// Python's TestPlanarValues, with the same figures and tolerances. The known answers are closed
// forms; the Rhino records are crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt, found from
// this file's own path. In the source checkout a missing file fails; in an SDK, which ships these
// tests without it, the Rhino-record test skips.
import Blacksmith
import Foundation
import XCTest

private typealias P3 = SIMD3<Double>

private let exact = 1e-12
private let xyValues: [Double] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
private let shear: [Double] = [1, 0.5, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func xy() throws -> Frame { try Frame.of(xyValues) }

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

private func assertRefused(_ message: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    XCTAssertEqual(refusal(body), message, file: file, line: line)
}

private func xyz(_ p: P3) -> [Double] { [p.x, p.y, p.z] }

private func assertClose(_ got: [Double], _ want: [Double], _ tolerance: Double, _ label: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(got.count, want.count, "\(label): \(got) vs \(want)", file: file, line: line)
    for (g, w) in zip(got, want) where !(abs(g - w) <= tolerance) {
        XCTFail("\(label): \(got) vs \(want)", file: file, line: line)
        return
    }
}

/// The repository root: this file is crates/cadaclysm-capi/examples/swift/Tests/CadaclysmTests/
/// below it, so seven components come off its path.
private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}()

private struct RecordError: Error, CustomStringConvertible {
    let description: String
}

/// The Rhino records, keyed `case what`; a missing file throws in the checkout and skips in an SDK.
private func records() throws -> [String: [String]] {
    let inCheckout = FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("crates/cadaclysm/Cargo.toml").path)
    guard inCheckout else { throw XCTSkip("value vectors are only in the source checkout") }
    let file = repoRoot.appendingPathComponent("crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        throw RecordError(description: "the value vectors are missing: \(file.path)")
    }
    var out: [String: [String]] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.contains("ERROR") { throw RecordError(description: "an ERROR record: \(line)") }
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let key = "\(parts[0]) \(parts[1])"
        if out[key] != nil { throw RecordError(description: "a repeated record: \(key)") }
        out[key] = Array(parts.dropFirst(2))
    }
    return out
}

private func nums(_ r: [String: [String]], _ name: String, _ what: String) throws -> [Double] {
    guard let words = r["\(name) \(what)"] else { throw RecordError(description: "no record \(name) \(what)") }
    return try words.map {
        guard let v = Double($0) else { throw RecordError(description: "\(name) \(what): '\($0)'") }
        return v
    }
}

private func p3(_ v: [Double], _ at: Int = 0) -> P3 { P3(v[at], v[at + 1], v[at + 2]) }

private func queries(_ r: [String: [String]], _ shape: String) throws -> [(String, P3)] {
    try (0..<12).map { i in
        let name = String(format: "%@_%02d", shape, i)
        return (name, p3(try nums(r, name, "query")))
    }
}

final class BlacksmithPlanarValueTests: XCTestCase {
    func testARectangleIsACurveWithCallsOfItsOwn() throws {
        let r = try Rectangle(try xy(), (1, 4), try Interval(0, 4))
        XCTAssertEqual(r.x, try Interval(1, 4))
        XCTAssertEqual(r.y, try Interval(0, 4))
        XCTAssertEqual(r.frame, try xy())
        XCTAssertEqual(try r.pointAt(2.25), P3(3.25, 4, 0))
        XCTAssertEqual(try r.pointAt(9), P3(1, 0, 0), "clamped to 4")
        XCTAssertEqual(try r.tangentAt(1.5), P3(0, 1, 0))
        XCTAssertEqual(try r.length(), 14)
        XCTAssertEqual(try r.closestPoint(P3(2, -1, 7)), CurveFoot(1.0 / 3, P3(2, 0, 0), true))
        XCTAssertFalse(try Rectangle(try xy(), (0, 2), (0, 2)).closestPoint(P3(1, 1, 0)).unique, "the centre is a pick")
        XCTAssertEqual(try r.corners(), [P3(1, 0, 0), P3(4, 0, 0), P3(4, 4, 0), P3(1, 4, 0)])
        XCTAssertEqual(try r.area(), 12)
        XCTAssertEqual(try r.closestPointIn(P3(2, 1, 5)), P3(2, 1, 0))
        XCTAssertEqual(try r.closestPointIn(P3(2, 1, 5), includeInterior: false), P3(1, 1, 0))
        let b = try r.bounds()
        XCTAssertEqual(b.min, P3(1, 0, 0))
        XCTAssertEqual(b.max, P3(4, 4, 0))
        assertRefused("value_check: the x range must increase") { _ = try Rectangle(try xy(), (1, 1), (0, 4)) }
        assertRefused("value_check: a rectangle is 16 numbers, got 15") { _ = try Rectangle(values: xyValues + [1, 4, 0]) }
        assertRefused("value_transform: a rectangle takes only a map that keeps its sides square (no shear in its plane)") {
            _ = try r.transform(try Transform(shear))
        }
        XCTAssertEqual(try r.transform(try Transform.scaleXyz(try xy(), 2, 3, 1)), try Rectangle(try xy(), (2, 8), (0, 12)))
        let sheet = try r.toSheet()
        XCTAssertEqual(try sheet.faces, 1)
        let rmass: Mass = try sheet.mass(1e-9)
        XCTAssertLessThanOrEqual(abs(rmass.area - 12), 1e-9 * 12)
        let ring = try r.toNurbs()
        XCTAssertTrue(ring.degree == 1 && ring.isClosed && !ring.isRational)
        let (rlo, rhi) = try ring.domain
        XCTAssertTrue(rlo == 0 && rhi == 4)
        let rp = try ring.point(2.25)
        XCTAssertLessThanOrEqual(abs(rp.x - 3.25) + abs(rp.y - 4) + abs(rp.z), 1e-12)
    }

    func testRectangleContainsTakesNilAsItsEffectiveToleranceAndZeroAsExact() throws {
        let r = try Rectangle(try xy(), (1, 4), (0, 4))   // diagonal 5: effective 5e-4
        XCTAssertEqual(try r.contains(P3(2, 2, 9), tolerance: 0), "inside")
        XCTAssertEqual(try r.contains(P3(0, 2, 0), tolerance: 0), "outside")
        XCTAssertEqual(try r.contains(P3(1, 2, 0), tolerance: 0), "on")
        let near = P3(1 - 4e-4, 2, 0)
        XCTAssertEqual(try r.contains(near, tolerance: 0), "outside")
        XCTAssertEqual(try r.contains(near, tolerance: 1e-3), "on")
        XCTAssertEqual(try r.contains(near), "on")
        XCTAssertEqual(try r.contains(near, tolerance: .nan), "on")
        XCTAssertEqual(try r.contains(P3(1 - 6e-4, 2, 0)), "outside")
        assertRefused("rectangle_contains: the tolerance must be finite and not negative") { _ = try r.contains(P3(0, 0, 0), tolerance: -1) }
        let eff = 1e-4 * 4 * 3.0.squareRoot()
        let ball = try Sphere(try xy(), 2)
        XCTAssertTrue(try ball.contains(P3(2 + 0.9 * eff, 0, 0), tolerance: .nan))
        XCTAssertFalse(try ball.contains(P3(2 + 0.9 * eff, 0, 0)))
        XCTAssertFalse(try ball.contains(P3(2 + 1.1 * eff, 0, 0), tolerance: .nan))
    }

    func testATriangleAnswersItsClosedForms() throws {
        let t = try Triangle(P3(0, 0, 0), P3(4, 0, 0), P3(0, 3, 0))
        XCTAssertEqual([t.a, t.b, t.c], [P3(0, 0, 0), P3(4, 0, 0), P3(0, 3, 0)])
        XCTAssertEqual(try t.area(), 6)
        XCTAssertEqual(try t.perimeter(), 12)
        assertClose(xyz(try t.centroid()), [4.0 / 3, 1, 0], 1e-15, "centroid")
        let cc = try t.circumcircle()
        assertClose(xyz(cc.frame.origin) + [cc.radius], [2, 1.5, 0, 2.5], 1e-15, "circumcircle")
        XCTAssertEqual(try t.pointAt(0.5, 0.25, 0.25), P3(1, 0.75, 0))
        assertClose(xyz(try t.barycentric(P3(1, 0.75, 5))), [0.5, 0.25, 0.25], 1e-15, "barycentric")
        XCTAssertEqual(try t.closestPoint(P3(2, -1, 0)), P3(2, 0, 0))
        XCTAssertEqual(try t.closestPoint(P3(1, 1, 3)), P3(1, 1, 0))
        XCTAssertEqual(try t.distanceTo(P3(1, 1, 3)), 3)
        XCTAssertEqual(try t.edge(1), try Line(P3(4, 0, 0), P3(0, 3, 0)))
        assertRefused("triangle_edge: edge 3 is not 0, 1 or 2") { _ = try t.edge(3) }
        assertRefused("value_check: the triangle is degenerate (its points are collinear or coincident)") {
            _ = try Triangle(P3(0, 0, 0), P3(1, 1, 1), P3(2, 2, 2))
        }
        assertRefused("value_check: a triangle is 9 numbers, got 8") { _ = try Triangle(values: [0, 0, 0, 4, 0, 0, 0, 3]) }
        XCTAssertEqual(try t.transform(try Transform(shear)), try Triangle(P3(0, 0, 0), P3(4, 0, 0), P3(1.5, 3, 0)), "any affine map")
        let tmass: Mass = try t.toSheet().mass(1e-9)
        XCTAssertLessThanOrEqual(abs(tmass.area - 6), 1e-9 * 6)
        XCTAssertNotEqual(t, try Triangle(P3(0, 0, 0), P3(0, 3, 0), P3(4, 0, 0)))
        XCTAssertEqual(t.hashValue, try Triangle(t.a, t.b, t.c).hashValue)
    }

    func testARayHoldsToItsHalfLineOnlyInClosestPoint() throws {
        let ray = try Ray(P3(1, 2, 3), P3(0, 0, 2))
        XCTAssertEqual(ray.values, [1, 2, 3, 0, 0, 2])
        XCTAssertEqual(ray.direction, P3(0, 0, 2), "kept as given")
        XCTAssertEqual(ray.position, P3(1, 2, 3))
        XCTAssertEqual(try ray.pointAt(1.5), P3(1, 2, 6))
        XCTAssertEqual(try ray.pointAt(-1), P3(1, 2, 1))
        XCTAssertEqual(try ray.closestPoint(P3(5, 2, 7)), CurveFoot(2, P3(1, 2, 7), true))
        XCTAssertEqual(try ray.closestPoint(P3(5, 2, -7)), CurveFoot(0, P3(1, 2, 3), true), "behind: the start")
        XCTAssertLessThanOrEqual(abs(try ray.distanceTo(P3(5, 2, -7)) - 116.0.squareRoot()), 1e-12)
        assertRefused("value_bounds: a ray has no box (it is unbounded)") { _ = try ray.bounds() }
        assertRefused("value_check: the ray's direction is zero") { _ = try Ray(P3(0, 0, 0), P3(0, 0, 0)) }
        assertRefused("value_check: a ray is 6 numbers, got 7") { _ = try Ray(values: [0, 0, 0, 1, 0, 0, 0]) }
        XCTAssertEqual(try ray.transform(try Transform.scaleXyz(try xy(), 1, 1, 3)), try Ray(P3(1, 2, 9), P3(0, 0, 6)))
    }

    func testRectanglesTrianglesAndRaysMatchRhino() throws {
        let r = try records()
        let rect = try Rectangle(values: try nums(r, "rectangle", "frame") + nums(r, "rectangle", "ranges"))
        let corners = try nums(r, "rectangle", "corners")
        for (k, c) in try rect.corners().enumerated() {
            assertClose(xyz(c), Array(corners[(3 * k)..<(3 * k + 3)]), exact, "corner \(k)")
        }
        assertClose([try rect.area(), try rect.length()], try nums(r, "rectangle", "area") + nums(r, "rectangle", "circumference"), exact, "area")
        for k in 0..<9 {
            let n = try nums(r, "rectangle_at_\(k)", "point")
            assertClose(xyz(try rect.pointAt(n[0])), Array(n[1..<4]), exact, "rectangle_at_\(k)")
        }
        let words = ["Inside": "inside", "Outside": "outside", "Coincident": "on"]
        for (c, q) in try queries(r, "rectangle") + queries(r, "rectangle_in") {
            assertClose(xyz(try rect.closestPoint(q).point), try nums(r, c, "boundary"), exact, c)
            assertClose(xyz(try rect.closestPointIn(q, includeInterior: true)), try nums(r, c, "filled"), exact, c)
            XCTAssertEqual(try rect.contains(q, tolerance: 0), words[r["\(c) contains"]?.first ?? ""], c)
        }
        let p = try nums(r, "triangle", "points")
        let tri = try Triangle(p3(p, 0), p3(p, 3), p3(p, 6))
        assertClose([try tri.area(), try tri.perimeter()], try nums(r, "triangle", "area") + nums(r, "triangle", "perimeter"), exact, "triangle")
        assertClose(xyz(try tri.centroid()), try nums(r, "triangle", "centroid"), exact, "centroid")
        assertClose(try tri.circumcircle().values, try nums(r, "triangle", "circumcircle"), exact, "circumcircle")
        for (c, q) in try queries(r, "triangle") + queries(r, "triangle_in") {
            let w = try tri.barycentric(q)
            assertClose([w.y, w.z], Array(try nums(r, c, "barycentric")[0..<2]), exact, c)
            assertClose(xyz(try tri.pointAt(w.x, w.y, w.z)), try nums(r, c, "projected"), exact, c)
            if w.min() < 0 { assertClose(xyz(try tri.closestPoint(q)), try nums(r, c, "boundary"), exact, c) }
        }
        let rn = try nums(r, "ray", "ray")
        let ray = try Ray(p3(rn, 0), p3(rn, 3))
        for k in 0..<4 {
            let n = try nums(r, "ray_at_\(k)", "point")
            assertClose(xyz(try ray.pointAt(n[0])), Array(n[1..<4]), exact, "ray_at_\(k)")
        }
    }
}
