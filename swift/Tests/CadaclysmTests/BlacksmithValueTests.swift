// Value geometry over the release library (plan B3): Python's TestInterval, TestFrameVerbs,
// TestCurveValues, TestSurfaceValues and TestCuboidValue, with the same figures and tolerances.
// Known answers are B1's; the Rhino records are crates/cadaclysm/tests/fixtures/rhino/
// value_vectors.txt, found from this file's own path. In the source checkout a missing file
// fails; in an SDK, which ships these tests without it, the Rhino-record tests skip.
import Blacksmith
import Foundation
import XCTest

private typealias P3 = SIMD3<Double>

private let exact = 1e-12
private let nurbsFootTolerance = 1e-7
private let xyValues: [Double] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
/// Right-handed and exact: x = world y, y = world z, z = world x, off the origin.
private let yzxValues: [Double] = [1, 2, 3, 0, 1, 0, 0, 0, 1, 1, 0, 0]

private func xy() throws -> Frame { try Frame.of(xyValues) }
private func yzx() throws -> Frame { try Frame.of(yzxValues) }

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

/// `body` refused with exactly `message`.
private func assertRefused(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                           _ body: () throws -> Void) {
    let got = refusal(body)
    XCTAssertEqual(got, message, file: file, line: line)
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

private func assertClose(_ got: P3, _ want: P3, _ tolerance: Double, _ label: String = "",
                         file: StaticString = #filePath, line: UInt = #line) {
    assertClose(xyz(got), xyz(want), tolerance, label, file: file, line: line)
}

private func assertRel(_ got: Double, _ want: Double, _ rel: Double = 1e-6, _ label: String = "",
                       file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(got - want), rel * abs(want), "\(label): \(got) vs \(want)", file: file, line: line)
}

private func dist(_ a: P3, _ b: P3) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

/// Python's `%` on floats: the remainder takes the divisor's sign.
private func pymod(_ a: Double, _ b: Double) -> Double {
    let m = a.truncatingRemainder(dividingBy: b)
    return m != 0 && (m < 0) != (b < 0) ? m + b : m
}

// ---- the Rhino records ------------------------------------------------------------------

private struct VectorsMissing: Error, CustomStringConvertible {
    let description: String
}

/// The repository root: this file is crates/cadaclysm-capi/examples/swift/Tests/CadaclysmTests/
/// below it, so seven components come off its path.
private let repoRoot: URL = {
    var url = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { url.deleteLastPathComponent() }
    return url
}()

private struct Vectors {
    let records: [String: [String]]

    /// The numbers of the record `case what`; a missing record throws.
    func nums(_ name: String, _ what: String) throws -> [Double] {
        guard let words = records["\(name) \(what)"] else { throw VectorsMissing(description: "no record \(name) \(what)") }
        return try words.map {
            guard let v = Double($0) else { throw VectorsMissing(description: "\(name) \(what): '\($0)' is not a number") }
            return v
        }
    }

    func words(_ name: String, _ what: String) -> [String]? { records["\(name) \(what)"] }

    func point(_ name: String, _ what: String) throws -> P3 {
        let n = try nums(name, what)
        guard n.count == 3 else { throw VectorsMissing(description: "\(name) \(what): \(n.count) numbers, not 3") }
        return P3(n[0], n[1], n[2])
    }

    /// The twelve query records `shape_00` .. `shape_11`.
    func queries(_ shape: String) throws -> [(String, P3)] {
        try (0..<12).map { i in
            let name = String(format: "%@_%02d", shape, i)
            return (name, try point(name, "query"))
        }
    }
}

/// The Rhino records, keyed `case what`. In the source checkout (the root holds
/// crates/cadaclysm/Cargo.toml) a missing or broken file throws, failing the test; elsewhere
/// (the SDK's copy of these tests) the test skips.
private func vectors() throws -> Vectors {
    let inCheckout = FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("crates/cadaclysm/Cargo.toml").path)
    guard inCheckout else { throw XCTSkip("value vectors are only in the source checkout") }
    let file = repoRoot.appendingPathComponent("crates/cadaclysm/tests/fixtures/rhino/value_vectors.txt")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else {
        throw VectorsMissing(description: "the value vectors are missing: \(file.path)")
    }
    var records: [String: [String]] = [:]
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.contains("ERROR") { throw VectorsMissing(description: "an ERROR record: \(line)") }
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { throw VectorsMissing(description: "a short record: \(line)") }
        let key = "\(parts[0]) \(parts[1])"
        if records[key] != nil { throw VectorsMissing(description: "a repeated record: \(key)") }
        records[key] = Array(parts.dropFirst(2))
    }
    return Vectors(records: records)
}

/// A foot Rhino found by iteration on a NURBS form: the distance to 1e-12, never beaten by
/// Rhino's, the point to 1e-7 -- as B1's `nurbs_foot`.
private func assertNurbsFoot(_ label: String, _ q: P3, _ ours: P3, _ rhino: P3,
                             file: StaticString = #filePath, line: UInt = #line) {
    let d = dist(q, ours), dr = dist(q, rhino)
    XCTAssertTrue(d <= dr + exact && abs(d - dr) <= exact, "\(label): \(d) vs \(dr)", file: file, line: line)
    assertClose(ours, rhino, nurbsFootTolerance, label, file: file, line: line)
}

// ---- Interval ---------------------------------------------------------------------------

final class BlacksmithIntervalTests: XCTestCase {
    private func i(_ a: Double, _ b: Double) throws -> Interval { try Interval(a, b) }

    func testMeasuresKeepTheOrientation() throws {
        let up = try i(2, 6), down = try i(6, 2)
        XCTAssertEqual(up.length, 4.0)
        XCTAssertEqual(down.length, -4.0)
        XCTAssertEqual(up.mid, 4.0)
        XCTAssertEqual(down.mid, 4.0)
        XCTAssertEqual([up.min, up.max], [2.0, 6.0])
        XCTAssertEqual([down.min, down.max], [2.0, 6.0])
        XCTAssertTrue(up.isIncreasing)
        XCTAssertFalse(down.isIncreasing)
        XCTAssertFalse(try i(3, 3).isIncreasing)
        XCTAssertTrue(try i(3, 3).isSingleton)
        XCTAssertFalse(up.isSingleton)
        XCTAssertEqual(up.swapped(), down)
        XCTAssertEqual(down.swapped(), up)
        XCTAssertEqual([down.t0, down.t1], [6.0, 2.0])
    }

    func testSetOperationsAnswerIncreasingAndTouchingIsASingleton() throws {
        let up = try i(2, 6), down = try i(6, 2)
        XCTAssertEqual(try up.grown(9), try i(2, 9))
        XCTAssertEqual(try down.grown(-1), try i(-1, 6))
        XCTAssertEqual(try down.grown(3), up)
        XCTAssertEqual(up.union(try i(8, 7)), try i(2, 8))
        XCTAssertEqual(down.union(try i(1, 3)), try i(1, 6))
        XCTAssertEqual(down.intersect(try i(9, 4)), try i(4, 6))
        XCTAssertEqual(up.intersect(try i(3, 5)), try i(3, 5))
        XCTAssertNil(up.intersect(try i(7, 9)))
        XCTAssertNil(down.intersect(try i(1, 1.5)))
        XCTAssertEqual(try i(0, 1).intersect(try i(1, 2)), try i(1, 1))
        XCTAssertEqual(try i(2, 1).intersect(try i(0, 1)), try i(1, 1))
        for x in [up, down] {
            XCTAssertTrue(x.contains(2) && x.contains(6) && x.contains(4.5))
            XCTAssertFalse(x.contains(1.999) || x.contains(6.001))
        }
    }

    func testParametersRoundTrip() throws {
        XCTAssertEqual(try i(2, 6).parameterAt(0.25), 3.0)
        XCTAssertEqual(try i(6, 2).parameterAt(0.25), 5.0)
        for x in [try i(2, 6), try i(6, 2), try i(-1.5, 0.7)] {
            for s in [-0.5, 0.0, 0.3, 1.0, 2.0] {
                let back = try XCTUnwrap(x.normalizedParameterAt(x.parameterAt(s)))
                XCTAssertLessThanOrEqual(abs(back - s), 1e-15, "\(x) at \(s)")
            }
        }
        XCTAssertNil(try i(3, 3).normalizedParameterAt(3))
    }

    func testIsAHashableValue() throws {
        let a = try i(1, 2)
        XCTAssertEqual(a, try i(1.0, 2.0))
        XCTAssertEqual(a.hashValue, try i(1.0, 2.0).hashValue)
        XCTAssertEqual(Set([a, try i(1, 2)]).count, 1)
        XCTAssertEqual(a.description, "Interval(1.0, 2.0)")
        XCTAssertEqual(try Interval.of([1, 2]), a)
        assertRefused("Interval: not finite") { _ = try Interval(.nan, 1) }
        assertRefused("Interval: not finite") { _ = try a.grown(.infinity) }
        assertRefused("Interval: an interval is 2 numbers, got 3") { _ = try Interval.of([1, 2, 3]) }
    }

    func testMatchesRhino() throws {
        let r = try vectors()
        for name in ["apart", "dec_dec", "inc_dec", "inc_inc", "touch"] {
            let c = "interval_\(name)"
            let args = try r.nums(c, "args")
            let a = try i(args[0], args[1]), b = try i(args[2], args[3])
            let u = a.union(b)
            XCTAssertEqual([u.t0, u.t1], try r.nums(c, "union"), c)
            let got = a.intersect(b)
            if r.words(c, "intersection") == ["none"] {
                XCTAssertNil(got, c)
            } else {
                let g = try XCTUnwrap(got, c)
                XCTAssertEqual([g.t0, g.t1], try r.nums(c, "intersection"), c)
            }
        }
        for name in ["inc_inside", "inc_out", "dec_low", "dec_inside"] {
            let args = try r.nums("grow_\(name)", "args")
            let g = try i(args[0], args[1]).grown(args[2])
            XCTAssertEqual([g.t0, g.t1], try r.nums("grow_\(name)", "grown"), name)
        }
        for name in ["inc", "dec"] {
            for k in 0..<4 {
                let c = "param_\(name)_\(k)"
                let args = try r.nums(c, "args")
                let x = try i(args[0], args[1]), t = args[2]
                assertClose([x.parameterAt(t)], try r.nums(c, "parameter_at"), exact, c)
                assertClose([try XCTUnwrap(x.normalizedParameterAt(2.5 + t))], try r.nums(c, "normalized_at"), exact, c)
            }
        }
    }
}

// ---- Frame verbs ------------------------------------------------------------------------

final class BlacksmithFrameVerbTests: XCTestCase {
    func testPlaneVerbsMatchRhino() throws {
        let r = try vectors()
        let p = try Frame.of(try r.nums("plane", "frame"))
        assertClose(try p.flipped().values, try r.nums("plane", "flip"), exact, "flip")
        assertClose(try p.rotated(0.6, P3(1, -1, 0.5)).values, try r.nums("plane", "rotate"), exact, "rotate")
        for (c, q) in try r.queries("plane") {
            assertClose(p.toLocal(q), try r.point(c, "remap"), exact, c)
            assertClose(p.closestPoint(q), try r.point(c, "closest"), exact, c)
            assertClose([p.distanceTo(q)], try r.nums(c, "distance"), exact, c)
        }
    }

    func testFitMatchesRhinoAndRefusesInTheLibrarysWords() throws {
        let r = try vectors()
        let flat = try r.nums("fit", "points")
        let pts = stride(from: 0, to: flat.count, by: 3).map { P3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }
        let (got, deviation) = try Frame.fit(pts)
        let want = try Frame.of(try r.nums("fit", "frame"))
        let sign: Double = (got.z * want.z).sum() < 0 ? -1 : 1
        assertClose(sign * got.z, want.z, exact, "normal")
        assertClose([want.distanceTo(got.origin), got.distanceTo(want.origin)], [0, 0], exact, "origins")
        assertClose([deviation], try r.nums("fit", "deviation"), exact, "deviation")
        assertRefused("frame_fit: needs three points") { _ = try Frame.fit(Array(pts[0..<2])) }
        assertRefused("frame_fit: the points lie on one line") { _ = try Frame.fit([P3(0, 0, 0), P3(1, 1, 1), P3(2, 2, 2)]) }
    }
}

// ---- curves -----------------------------------------------------------------------------

final class BlacksmithCurveValueTests: XCTestCase {
    func testABadValueIsRefusedByValueCheck() throws {
        let f = try xy()
        assertRefused("value_check: the radius must be positive") { _ = try Circle(f, 0) }
        assertRefused("value_check: the line has no length") { _ = try Line(P3(1, 1, 1), P3(1, 1, 1)) }
        assertRefused("value_check: the angle must increase by at most a full turn") { _ = try Arc(f, 1, (0, 7)) }
        assertRefused("value_check: the angle must increase by at most a full turn") { _ = try Arc(f, 1, try Interval(1, 0)) }
        assertRefused("value_check: the second radius must be positive") { _ = try Ellipse(f, 3, -1) }
        assertRefused("value_check: the frame is not right-handed and orthonormal") {
            _ = try Circle(values: [0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1, 1])
        }
        // value_size's count, in the library's sentence.
        assertRefused("value_check: a circle is 13 numbers, got 12") { _ = try Circle(values: xyValues) }
        // 1e-7 off square is squared up, not refused.
        let near = try Circle(values: [0, 0, 0, 1, 1e-7, 0, 0, 1, 0, 0, 0, 1, 1])
        XCTAssertLessThan(abs((near.frame.x * near.frame.y).sum()), 1e-15)
        XCTAssertNotEqual(near.frame.x.y, 0)
    }

    func testEachCallAnswersB1sFigures() throws {
        let unit = try Circle(try xy(), 1)
        assertClose(try unit.pointAt(.pi / 2), P3(0, 1, 0), 1e-15)
        assertClose(try unit.tangentAt(0), P3(0, 1, 0), 1e-15)
        let line = try Line(P3(0, 0, 0), P3(1, 2, 3))
        XCTAssertEqual(try line.pointAt(0.5), P3(0.5, 1.0, 1.5))
        XCTAssertEqual(try line.length(), Double(14).squareRoot())
        XCTAssertEqual(line.start, P3(0, 0, 0))
        XCTAssertEqual(line.end, P3(1, 2, 3))
        assertClose(try line.tangentAt(0), P3(1, 2, 3) / Double(14).squareRoot(), 1e-15)
        let quarter = try Arc(try xy(), 2, (0, .pi / 2))
        XCTAssertEqual(try quarter.length(), .pi)
        XCTAssertEqual(quarter.angle, try Interval(0, .pi / 2))
        assertClose(try quarter.start, P3(2, 0, 0), 1e-15)
        assertClose(try quarter.end, P3(0, 2, 0), 1e-15)
        assertClose(try quarter.mid, P3(Double(2).squareRoot(), Double(2).squareRoot(), 0), 1e-15)
        // On the axis the foot is a pick: t = 0, not unique.
        XCTAssertEqual(try unit.closestPoint(P3(2, 0, 5)), CurveFoot(0, P3(1, 0, 0), true))
        XCTAssertEqual(try unit.closestPoint(P3(0, 0, 5)), CurveFoot(0, P3(1, 0, 0), false))
        assertRel(try unit.distanceTo(P3(2, 0, 5)), Double(26).squareRoot())
        let b = try Line(P3(1, 5, 0), P3(0, 2, 3)).bounds()
        XCTAssertEqual(b.min, P3(0, 2, 0))
        XCTAssertEqual(b.max, P3(1, 5, 3))
        assertRel(try Ellipse(try xy(), 3, 1).length(), 13.364893220555258, 1e-12)
    }

    func testConstructorsAndTransforms() throws {
        let a = P3(1, 0, 0), b = P3(0, 1, 0), c = P3(-1, 0, 0)
        assertClose(try Circle.through(a, b, c).values, xyValues + [1], 1e-15)
        assertClose(try Arc.through(a, b, c).values, xyValues + [1, 0, .pi], 1e-15)
        assertClose(try Arc.fromStartTangentEnd(a, P3(0, 1, 0), c).values, xyValues + [1, 0, .pi], 1e-15)
        assertRefused("circle_through: the points are coincident or collinear") { _ = try Circle.through(a, a, c) }
        assertRefused("arc_from_start_tangent_end: the tangent is zero or the end lies on the tangent line") {
            _ = try Arc.fromStartTangentEnd(a, P3(0, 0, 0), c)
        }
        XCTAssertEqual(try Ellipse.fromCircle(try Circle(try xy(), 2)), try Ellipse(try xy(), 2, 2))
        XCTAssertEqual(try Circle(try xy(), 1).transform(try Transform.scale(.zero, 2)), try Circle(try xy(), 2))
        let stretch = try Transform.scaleXyz(try Frame.xy(), 1, 3, 1)
        assertRefused("value_transform: a circle takes only a similarity (use ellipse_from_circle)") {
            _ = try Circle(try xy(), 1).transform(stretch)
        }
        let e = try Ellipse.fromCircle(try Circle(try xy(), 1)).transform(stretch)
        assertClose([e.r1, e.r2], [3, 1], 1e-15)
        let moved = try Line(P3(0, 0, 0), P3(1, 0, 0)).transform(try Transform.translation(P3(0, 0, 2)))
        XCTAssertEqual(moved, try Line(P3(0, 0, 2), P3(1, 0, 2)))
    }

    func testValuesAreHashableAndHoldTheirArray() throws {
        let c = try Circle(try yzx(), 2)
        XCTAssertEqual(c.values, yzxValues + [2])
        XCTAssertEqual(c.radius, 2.0)
        XCTAssertEqual(c.frame, try yzx())
        XCTAssertEqual(c, try Circle(try Frame.of(yzxValues), 2.0))
        XCTAssertEqual(c.hashValue, try Circle(try yzx(), 2).hashValue)
        // The same numbers as another kind are another value.
        let s = try Sphere(try yzx(), 2)
        XCTAssertEqual(s.values, c.values)
        XCTAssertNotEqual(AnyHashable(c), AnyHashable(s))
        XCTAssertEqual(Set([AnyHashable(c), AnyHashable(try Circle(try yzx(), 2)), AnyHashable(s)]).count, 2)
        XCTAssertEqual(CurveValue.circle(c), CurveValue.circle(try Circle(try yzx(), 2)))
        XCTAssertTrue(c.description.hasPrefix("Circle(frame=Frame(origin=(1.0, 2.0, 3.0)"), c.description)
        XCTAssertTrue(c.description.hasSuffix("radius=2.0)"), c.description)
    }

    func testLinesCirclesAndArcsMatchRhino() throws {
        let r = try vectors()
        let ends = try r.nums("line", "ends")
        let line = try Line(P3(ends[0], ends[1], ends[2]), P3(ends[3], ends[4], ends[5]))
        assertClose([try line.length()], try r.nums("line", "length"), exact, "line length")
        assertClose(try line.tangentAt(0.5), try r.point("line", "tangent"), exact, "line tangent")
        for k in 0..<5 {
            let n = try r.nums("line_at_\(k)", "point")
            assertClose(try line.pointAt(n[0]), P3(n[1], n[2], n[3]), exact, "line_at_\(k)")
        }
        for (c, q) in try r.queries("line") {
            assertClose(try line.closestPoint(q).point, try r.point(c, "closest"), exact, c)
        }

        let circle = try Circle(values: try r.nums("circle", "frame") + r.nums("circle", "radius"))
        assertClose([try circle.length()], try r.nums("circle", "length"), exact, "circle length")
        for k in 0..<5 {
            let n = try r.nums("circle_at_\(k)", "point")
            assertClose(try circle.pointAt(n[0]), P3(n[1], n[2], n[3]), exact, "circle_at_\(k)")
            assertClose(try circle.tangentAt(n[0]), P3(n[4], n[5], n[6]), exact, "circle_at_\(k) tangent")
        }
        for (c, q) in try r.queries("circle") {
            let want = try r.nums(c, "closest"), foot = try circle.closestPoint(q)
            XCTAssertTrue(foot.unique, c)
            assertClose([foot.t], [pymod(want[0], 2 * .pi)], exact, c)
            assertClose(foot.point, P3(want[1], want[2], want[3]), exact, c)
        }

        let arc = try Arc(values: try r.nums("arc", "frame") + r.nums("arc", "radius") + r.nums("arc", "angle"))
        assertClose([try arc.length()], try r.nums("arc", "length"), exact, "arc length")
        for k in 0..<4 {
            let n = try r.nums("arc_at_\(k)", "point")
            assertClose(try arc.pointAt(n[0]), P3(n[1], n[2], n[3]), exact, "arc_at_\(k)")
            assertClose(try arc.tangentAt(n[0]), P3(n[4], n[5], n[6]), exact, "arc_at_\(k) tangent")
        }
        for (c, q) in try r.queries("arc") {
            let want = try r.nums(c, "closest"), foot = try arc.closestPoint(q)
            assertClose([foot.t], [want[0]], exact, c)
            assertClose(foot.point, P3(want[1], want[2], want[3]), exact, c)
        }
    }

    func testAnEdgesCurveIsItsValue() throws {
        for rim in try Solid.cylinder(5, 3).edges where rim.kind == "circle" {
            guard case .circle(let v)? = try rim.curve?.value else { return XCTFail("\(rim): not a circle") }
            assertRel(v.radius, 5)
            XCTAssertTrue(abs(v.frame.origin.z) < 1e-9 || abs(v.frame.origin.z - 3) < 1e-9, "\(v)")
        }
        func rounded(_ p: P3) -> [Double] { xyz(p).map { ($0 * 1e9).rounded() / 1e9 + 0.0 } }
        for e in try Solid.cuboid(2, 4, 6).edges {
            guard case .line(let v)? = try e.curve?.value else { return XCTFail("\(e): not a line") }
            let ends = Set(e.segments.flatMap { [rounded($0.start), rounded($0.end)] })
            XCTAssertTrue(ends.contains(rounded(v.start)) && ends.contains(rounded(v.end)), "\(v)")
        }
        let cube = try Solid.cuboid(10, 10, 10)
        let upright = try cube.edges.filter { e in e.direction.map { abs(abs($0.z) - 1) < 1e-9 } ?? false }
        let rounder = try cube.fillet(Array(upright.prefix(1)), 2.0)
        let arcs = try rounder.edges.filter { $0.kind == "circle" }
        XCTAssertEqual(arcs.count, 2)
        for e in arcs {
            guard case .arc(let v)? = try e.curve?.value else { return XCTFail("\(e): not an arc") }
            assertRel(v.radius, 2)
            assertRel(v.angle.length, .pi / 2)
            let vertices = [e.segments[0].start, e.segments[e.segments.count - 1].end]
            let start = try v.start, end = try v.end
            XCTAssertTrue(vertices.contains { dist(start, $0) < 1e-9 }, "\(v)")
            XCTAssertTrue(vertices.contains { dist(end, $0) < 1e-9 }, "\(v)")
        }
        let profile = try Profile.spline([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)], degree: 3, closed: true)
        let spline = try Solid.extrude(profile, try Frame.xy(), 2)
        let nurbs = try spline.edges.filter { $0.kind == "nurbs" }
        XCTAssertFalse(nurbs.isEmpty)
        for e in nurbs {
            XCTAssertNil(try e.curve?.value, "\(e)")
        }
    }
}

// ---- surfaces ---------------------------------------------------------------------------

final class BlacksmithSurfaceValueTests: XCTestCase {
    func testABadValueIsRefusedByValueCheck() throws {
        let f = try xy()
        assertRefused("value_check: the height must increase") { _ = try Cylinder(f, 1, (2, 1)) }
        assertRefused("value_check: the minor radius must be less than the major") { _ = try Torus(f, 1, 1) }
        assertRefused("value_check: the height must be positive") { _ = try Cone(f, 1, 0) }
        assertRefused("value_check: not finite") { _ = try Sphere(f, .nan) }
    }

    func testEachCallAnswersB1sFigures() throws {
        let f = try xy()
        let sphere = try Sphere(f, 2)
        assertClose(try sphere.pointAt(0, .pi / 2), P3(0, 0, 2), 1e-15)
        let cyl = try Cylinder(f, 1, (-1, 2))
        XCTAssertEqual(cyl.height, try Interval(-1, 2))
        assertClose(try cyl.normalAt(.pi / 2, 0), P3(0, 1, 0), 1e-15)
        assertClose(try Torus(f, 3, 1).pointAt(0, 0), P3(4, 0, 0), 1e-15)
        let foot = try sphere.closestPoint(P3(0, 0, 5))
        XCTAssertTrue(foot.unique)
        assertClose([foot.u, foot.v] + xyz(foot.point), [0, .pi / 2, 0, 0, 2], 1e-15)
        XCTAssertFalse(try sphere.closestPoint(P3(0, 0, 0)).unique, "the centre is a pick")
        assertRel(try sphere.distanceTo(P3(0, 0, 5)), 3)
        let d = try cyl.domain()
        XCTAssertEqual(d.u, try Interval(0, 2 * .pi))
        XCTAssertEqual(d.v, try Interval(-1, 2))
        let dc = try Cone(f, 1, 2).domain()
        XCTAssertEqual(dc.u, try Interval(0, 2 * .pi))
        XCTAssertEqual(dc.v, try Interval(0, 2))
        XCTAssertLessThan(abs(try sphere.volume() - 32 * .pi / 3), 1e-13)
        XCTAssertLessThan(abs(try sphere.area() - 16 * .pi), 1e-13)
        XCTAssertTrue(try Torus(f, 3, 1).contains(P3(3, 0, 0.5)))
        XCTAssertFalse(try sphere.contains(P3(0, 0, 2.5)))
        XCTAssertTrue(try sphere.contains(P3(0, 0, 2.5), tolerance: 0.5))
        assertRefused("solid_value_contains: the tolerance must be finite and not negative") {
            _ = try sphere.contains(P3(0, 0, 0), tolerance: -1)
        }
        let b = try sphere.bounds()
        XCTAssertEqual(b.min, P3(-2, -2, -2))
        XCTAssertEqual(b.max, P3(2, 2, 2))
        assertRefused("value_transform: a sphere takes only a similarity") {
            _ = try sphere.transform(try Transform.scaleXyz(try Frame.xy(), 1, 3, 1))
        }
        XCTAssertEqual(try sphere.transform(try Transform.translation(P3(1, 0, 0))), try Sphere(try Frame.xy(P3(1, 0, 0)), 2))
        let sheet = try cyl.toNurbsSheet()
        XCTAssertEqual(try sheet.faces, 1)
    }

    func testEachShapeBecomesASolidOfItsVolume() throws {
        let f = try xy()
        let sphere = try Sphere(f, 2), cyl = try Cylinder(f, 1, (-1, 2)), cone = try Cone(f, 1, 2)
        let torus = try Torus(f, 3, 1), box = try Cuboid(try yzx(), (0, 1), (0, 2), (0, 3))
        let shapes: [(String, Solid, Double, Double)] = [
            ("sphere", try sphere.toSolid(), try sphere.volume(), 32 * .pi / 3),
            ("cylinder", try cyl.toSolid(), try cyl.volume(), 3 * .pi),
            ("cone", try cone.toSolid(), try cone.volume(), 2 * .pi / 3),
            ("torus", try torus.toSolid(), try torus.volume(), 6 * .pi * .pi),
            ("cuboid", try box.toSolid(), try box.volume(), 6.0),
        ]
        for (name, solid, volume, want) in shapes {
            let mass: Mass = try solid.mass(1e-9)
            assertRel(mass.volume, want, 1e-6, name)
            assertRel(volume, want, 1e-12, name)
        }
    }

    func testSpheresToriCylindersAndConesMatchRhino() throws {
        let r = try vectors()
        let sphere = try Sphere(values: try r.nums("sphere", "frame") + r.nums("sphere", "radius"))
        for (c, q) in try r.queries("sphere") {
            let want = try r.nums(c, "closest"), foot = try sphere.closestPoint(q)
            assertClose([foot.u, foot.v], [pymod(want[0], 2 * .pi), want[1]], exact, c)
            assertClose(foot.point, P3(want[2], want[3], want[4]), exact, c)
        }
        let torus = try Torus(values: try r.nums("torus", "frame") + r.nums("torus", "radii"))
        for (c, q) in try r.queries("torus") {
            let foot = try torus.closestPoint(q)
            XCTAssertTrue(foot.unique, c)
            assertNurbsFoot(c, q, foot.point, try r.point(c, "closest"))
        }
        let cyl = try Cylinder(values: try r.nums("cylinder", "frame") + r.nums("cylinder", "radius") + r.nums("cylinder", "height"))
        for (c, q) in try r.queries("cylinder") {
            assertNurbsFoot(c, q, try cyl.closestPoint(q).point, try r.point(c, "closest"))
        }
        let cone = try Cone(values: try r.nums("cone", "frame") + r.nums("cone", "size"))
        for (c, q) in try r.queries("cone") {
            assertNurbsFoot(c, q, try cone.closestPoint(q).point, try r.point(c, "closest"))
        }
    }
}

// ---- Cuboid -----------------------------------------------------------------------------

final class BlacksmithCuboidValueTests: XCTestCase {
    func testConstructionBoundsAndAround() throws {
        let box = try Cuboid(try yzx(), try Interval(0, 1), try Interval(0, 2), try Interval(0, 3))
        XCTAssertEqual([box.x, box.y, box.z], [try Interval(0, 1), try Interval(0, 2), try Interval(0, 3)])
        // x along world y (0..1), y along world z (0..2), z along world x (0..3), from (1, 2, 3).
        let b = try box.bounds()
        XCTAssertEqual(b.min, P3(1, 2, 3))
        XCTAssertEqual(b.max, P3(4, 3, 5))
        XCTAssertEqual(try Cuboid.fromBounds(P3(0, 0, 0), P3(1, 2, 3)), try Cuboid(try xy(), (0, 1), (0, 2), (0, 3)))
        assertRefused("cuboid_from_bounds: the bounds must increase along every axis") {
            _ = try Cuboid.fromBounds(P3(0, 0, 0), P3(1, 0, 3))
        }
        assertRefused("value_check: the y range must increase") { _ = try Cuboid(try xy(), (0, 1), (2, 2), (0, 1)) }
        let pts = [P3(0, 0, 0), P3(1, 2, 3), P3(0.5, -1, 0.25)]
        XCTAssertEqual(try Cuboid.around(try Frame.xy(), pts), try Cuboid(try xy(), (0, 1), (-1, 2), (0, 3)))
        assertRefused("cuboid_around: the points are flat along an axis of the frame") {
            _ = try Cuboid.around(try xy(), [P3(0, 0, 0), P3(1, 1, 0)])
        }
        assertRefused("cuboid_around: no points") { _ = try Cuboid.around(try xy(), []) }
    }

    func testEachCallAnswersB1sFigures() throws {
        let box = try Cuboid(try xy(), (0, 1), (0, 2), (0, 3))
        XCTAssertEqual(try box.area(), 22.0)
        XCTAssertEqual(try box.volume(), 6.0)
        XCTAssertTrue(try box.contains(P3(0.5, 0.5, 0.5)))
        XCTAssertFalse(try box.contains(P3(1.5, 0.5, 0.5), tolerance: 0.4))
        XCTAssertTrue(try box.contains(P3(1.5, 0.5, 0.5), tolerance: 0.5))
        let tilted = try Cuboid(try yzx(), (0, 1), (0, 2), (0, 3))
        XCTAssertEqual(try tilted.closestPoint(P3(9, 9, 9)), P3(4, 3, 5))
        assertClose(try tilted.pointAt(0.5, 0.5, 0.5), P3(2.5, 2.5, 4), 1e-15)
        let corners = try box.corners()
        XCTAssertEqual(corners.count, 8)
        XCTAssertEqual(corners[0], P3(0, 0, 0))
        XCTAssertEqual(corners[2], P3(1, 2, 0))
        XCTAssertEqual(corners[6], P3(1, 2, 3))
        let moved = try box.transform(try Transform.translation(P3(0, 0, 1)))
        let mb = try moved.bounds()
        XCTAssertEqual(mb.min, P3(0, 0, 1))
        XCTAssertEqual(mb.max, P3(1, 2, 4))
    }

    func testBoxesMatchRhino() throws {
        let r = try vectors()
        let box = try Cuboid(values: try r.nums("box", "frame") + r.nums("box", "ranges"))
        let corners = try r.nums("box", "corners")
        let got = try box.corners()
        XCTAssertEqual(got.count, 8)
        for (k, c) in got.enumerated() {
            assertClose(xyz(c), Array(corners[(3 * k)..<(3 * k + 3)]), exact, "corner \(k)")
        }
        for k in 0..<4 {
            let n = try r.nums("box_at_\(k)", "point")
            assertClose(try box.pointAt(n[0], n[1], n[2]), P3(n[3], n[4], n[5]), exact, "box_at_\(k)")
        }
        for (c, q) in try r.queries("box") {
            assertClose(try box.closestPoint(q), try r.point(c, "closest"), exact, c)
        }
    }
}
