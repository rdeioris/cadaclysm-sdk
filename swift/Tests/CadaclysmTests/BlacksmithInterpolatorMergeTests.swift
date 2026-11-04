// The interpolator, the circumscribed polygon and the merge over the release library: Python's
// test_interpolator_*, test_circumscribed_polygon_touches_its_circle, test_merge_* and
// test_a_merged_body_is_refused_*, trimmed to what proves the marshalling -- every field read,
// every refusal's prefix, the lists' length and order, the handle's lifetime. The kernel's own
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

private func check(_ prefix: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    let message = refusal(body) ?? "no error, wanted \(prefix)"
    XCTAssertTrue(message.hasPrefix(prefix), message, file: file, line: line)
}

/// The plain-data mass's volume (`Solid` has two `mass` overloads).
private func volume(_ solid: Solid) throws -> Double {
    let mass: Mass = try solid.mass()
    return mass.volume
}

private let squares: [Double] = [0, 1, 4, 9, 16]
private let modes: [InterpolatorMode] = [.nearest, .linear, .cosine, .cubic, .catmullRom]
private let mergeTolerance = 1e-6

private func near(_ a: [Double], _ b: [Double], _ eps: Double = 1e-12) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= eps }
}

private func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ eps: Double) -> Bool {
    abs(a.x - b.x) <= eps && abs(a.y - b.y) <= eps && abs(a.z - b.z) <= eps
}

final class BlacksmithInterpolatorMergeTests: XCTestCase {
    func testInterpolatorClosedFormsOnTheSquares() throws {
        let sq = try Interpolator(squares)
        XCTAssertEqual(try sq.count, 5)
        XCTAssertEqual(try sq.dimension, 1)
        XCTAssertFalse(try sq.cyclic)
        XCTAssertEqual(InterpolatorMode.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
        for mode in modes {
            for (k, y) in squares.enumerated() {
                let v = try sq.at(Double(k), mode)
                XCTAssertEqual(v.count, 1, "\(mode)")
                XCTAssertEqual(v[0], y, accuracy: 1e-12, "\(mode) at \(k)")
            }
            XCTAssertEqual(try sq.at(-2, mode)[0], 0, accuracy: 1e-12, "\(mode): clamped to the first sample")
            XCTAssertEqual(try sq.at(7, mode)[0], 16, accuracy: 1e-12, "\(mode): clamped to the last sample")
        }
        XCTAssertEqual(try sq.nearest(1.5), [4])
        XCTAssertEqual(try sq.nearest(1.49), [1])
        XCTAssertEqual(try sq.linear(1.5)[0], 2.5, accuracy: 1e-12)
        XCTAssertEqual(try sq.cosine(1.5)[0], 2.5, accuracy: 1e-12)
        XCTAssertEqual(try sq.cosine(1.25)[0], 1 + 3 * (1 - cos(Double.pi / 4)) / 2, accuracy: 1e-12)
        XCTAssertEqual(try sq.cubic(1.5)[0], 2.0, accuracy: 1e-12)
        XCTAssertEqual(try sq.catmullRom(1.5)[0], 2.25, accuracy: 1e-12)
        XCTAssertEqual(try sq.at(1.5), try sq.linear(1.5), "linear by default")

        let ring = try Interpolator(squares, cyclic: true)
        XCTAssertTrue(try ring.cyclic)
        XCTAssertEqual(try ring.catmullRom(5)[0], try ring.catmullRom(0)[0], accuracy: 1e-12)
        XCTAssertEqual(try ring.linear(-0.5)[0], 8.0, accuracy: 1e-12, "halfway from the last sample back to the first")
    }

    func testPointsAndSampleIsALoopOfAt() throws {
        let helix: [[Double]] = (0..<9).map { k in
            let a = 0.7 * Double(k)
            return [cos(a), sin(a), 0.3 * Double(k)]
        }
        let h = try Interpolator(rows: helix)
        XCTAssertEqual(try h.count, 9)
        XCTAssertEqual(try h.dimension, 3)
        XCTAssertTrue(near(try h.at(2), helix[2]))
        XCTAssertEqual(try h.catmullRom(2.5).count, 3)
        let ts: [Double] = (0..<50).map { (i: Int) -> Double in -1.0 + 10.0 * Double(i) / 49 }
        for mode in modes {
            let sampled = try h.sample(ts, mode)
            XCTAssertEqual(sampled.count, 50, "\(mode)")
            XCTAssertEqual(sampled, try ts.map { try h.at($0, mode) }, "\(mode)")
        }
        XCTAssertEqual(try h.sample([]), [])

        let corners: [[Double]] = [[0, 0], [1, 0], [1, 1], [0, 1]]
        let square = try Interpolator(rows: corners, cyclic: true)
        XCTAssertTrue(near(try square.linear(-0.5), [0, 0.5]))
        let two = try square.sample([0.5, 1.5])
        XCTAssertEqual(two.count, 2)
        XCTAssertTrue(near(two[0], [0.5, 0]) && near(two[1], [1, 0.5]), "\(two)")
    }

    func testInterpolatorRefusals() throws {
        check("interpolator_new: no samples") { _ = try Interpolator([]) }
        check("interpolator_new: no samples") { _ = try Interpolator(rows: []) }
        check("interpolator_new: sample 2 is not finite") { _ = try Interpolator([0, 1, .nan]) }
        check("interpolator: samples differ in length") { _ = try Interpolator(rows: [[0, 1], [2, 3, 4]]) }
        let sq = try Interpolator(squares)
        XCTAssertEqual(refusal { _ = try sq.linear(.nan) }, "interpolator_at: t NaN is not finite")
        XCTAssertEqual(refusal { _ = try sq.sample([0, .infinity]) }, "interpolator_sample: t 1 (inf) is not finite")
        XCTAssertFalse(sq.isClosed)
        sq.close()
        sq.close()
        XCTAssertTrue(sq.isClosed)
        XCTAssertEqual(refusal { _ = try sq.linear(1) }, "interpolator: closed")
        XCTAssertEqual(refusal { _ = try sq.sample([1]) }, "interpolator: closed")
        XCTAssertEqual(refusal { _ = try sq.count }, "interpolator: closed")
    }

    func testCircumscribedPolygonTouchesItsCircle() throws {
        let (centre, r, n) = (SIMD2<Double>(2, -1), 5.0, 6)
        let hex = try Profile.circumscribedPolygon(centre, r, n, angle: 0.3)
        let runs = try hex.outlineRuns(tolerance: 1e-3)
        XCTAssertEqual(runs.count, 1)
        var corners = stride(from: 0, to: runs[0].count, by: 3).map { SIMD2(Double(runs[0][$0]), Double(runs[0][$0 + 1])) }
        if corners.count > 1, corners.first == corners.last { corners.removeLast() }
        XCTAssertEqual(corners.count, n)
        let flat = r / cos(Double.pi / Double(n))
        for k in 0..<corners.count {
            let (a, b) = (corners[k], corners[(k + 1) % corners.count])
            let mid = (a + b) / 2 - centre
            XCTAssertEqual((mid * mid).sum().squareRoot(), r, accuracy: r * 1e-6, "side \(k)'s midpoint")
            let d = a - centre
            XCTAssertEqual((d * d).sum().squareRoot(), flat, accuracy: flat * 1e-6, "corner \(k)")
        }
        let perimeter = 2 * Double(n) * r * tan(Double.pi / Double(n))
        XCTAssertEqual(try hex.length().length, perimeter, accuracy: perimeter * 1e-9)
        check("profile_circumscribed_polygon: a polygon has at least 3 sides, not 2") {
            _ = try Profile.circumscribedPolygon(SIMD2(0, 0), 10, 2)
        }
        XCTAssertEqual(refusal { _ = try Profile.circumscribedPolygon(SIMD2(0, 0), 10, -1) },
                       "profile_circumscribed_polygon: sides is out of range: -1")
        XCTAssertEqual(refusal { _ = try Profile.circumscribedPolygon(SIMD2(0, 0), 10, 1 << 32) },
                       "profile_circumscribed_polygon: sides is out of range: 4294967296")
    }

    func testMergeOfTwoCubesAtACornerIsTheOutsideAndThreeCells() throws {
        let a = try Solid.cuboid(1, 1, 1)
        let m = try a.merge(try a.translate(0.5, 0.5, 0.5), tolerance: mergeTolerance)
        let faces = try m.faces
        XCTAssertEqual(faces, 18)
        let regions = try m.regions()
        XCTAssertEqual(regions.map(\.index), [0, 1, 2, 3])
        XCTAssertFalse(regions[0].finite)
        XCTAssertTrue(regions.dropFirst().allSatisfy(\.finite))
        XCTAssertTrue(regions.allSatisfy { $0.shells == 1 }, "\(regions.map(\.shells))")
        XCTAssertTrue(regions.allSatisfy { $0.sides.allSatisfy { $0.sense == 1 || $0.sense == -1 } })
        XCTAssertEqual(regions.map { $0.sides.count }.reduce(0, +), 2 * faces, "each face's two sides")
        XCTAssertEqual(Set(regions.dropFirst().flatMap { $0.sides.map(\.face) }), Set(0..<faces))
        for region in regions {
            let keys = region.sides.map { [$0.face, $0.sense] }
            XCTAssertEqual(keys, keys.sorted { $0.lexicographicallyPrecedes($1) }, "region \(region.index): sides ascending")
        }
        var volumes: [Int: Double] = [:]
        for region in regions.dropFirst() { volumes[region.index] = try volume(m.regionSolid(region.index)) }
        let sorted = volumes.values.sorted()
        XCTAssertTrue(near(sorted, [0.125, 0.875, 0.875], 1e-6), "\(sorted)")
        let small = try XCTUnwrap(volumes.first { abs($0.value - 0.125) < 1e-6 }?.key)
        let overlap = regions[small]
        XCTAssertEqual(overlap.sides.count, 6)
        XCTAssertTrue(overlap.sides.allSatisfy { $0.sense == -1 }, "inside both, behind its walls")
        XCTAssertTrue(near(overlap.box.lo, SIMD3(0, 0, 0), 1e-6) && near(overlap.box.hi, SIMD3(0.5, 0.5, 0.5), 1e-6),
                      "\(overlap.box)")
        XCTAssertEqual(try m.regions(), regions, "value records, equal by value")
    }

    func testMergeOfABallInABoxIsABoxCellWithAVoid() throws {
        let m = try Solid.cuboid(1, 1, 1).merge(try Solid.sphere(0.3), tolerance: mergeTolerance)
        let regions = try m.regions()
        XCTAssertEqual(regions.count, 3)
        let ball = 4.0 / 3.0 * Double.pi * 0.3 * 0.3 * 0.3
        let volumes = try [1, 2].map { try volume(m.regionSolid($0)) }
        let box = volumes[0] > volumes[1] ? 1 : 2
        XCTAssertEqual(volumes[box - 1], 1 - ball, accuracy: 1e-6)
        XCTAssertEqual(volumes[2 - box], ball, accuracy: 1e-6)
        XCTAssertEqual(regions[box].shells, 2)
        XCTAssertEqual(regions[3 - box].shells, 1)
    }

    func testAMergedBodyIsRefusedByTheManifoldVerbsAndItsCellsAreNot() throws {
        let a = try Solid.cuboid(1, 1, 1)
        let m = try a.merge(try a.translate(0.5, 0.5, 0.5), tolerance: mergeTolerance)
        check("join: the join needs a manifold solid, and this one has edges of three or more faces") {
            _ = try m.join(a, tolerance: mergeTolerance)
        }
        check("mass_properties: the mass needs a manifold solid") { _ = try volume(m) }
        XCTAssertEqual(refusal { _ = try m.regionSolid(0) }, "region_solid: region 0 is the infinite region")
        XCTAssertEqual(refusal { _ = try m.regionSolid(4) }, "region_solid: region 4 is not below 4")
        XCTAssertEqual(refusal { _ = try m.regionSolid(-1) }, "region_solid: region is out of range: -1")
        XCTAssertEqual(refusal { _ = try m.regionSolid(1 << 32) }, "region_solid: region is out of range: 4294967296")
        check("merge: tolerance must be positive and finite") { _ = try a.merge(a, tolerance: 0) }
        // A cell is an ordinary solid again.
        XCTAssertGreaterThan(try m.regionSolid(1).join(a, tolerance: mergeTolerance).faces, 0)
        // An ordinary solid has two regions: outside in front of every face, inside behind.
        let plain = try a.regions()
        XCTAssertEqual(plain.count, 2)
        XCTAssertEqual(plain[0].sides.count, 6)
        XCTAssertTrue(plain[0].sides.allSatisfy { $0.sense == 1 } && plain[1].sides.allSatisfy { $0.sense == -1 })
        XCTAssertEqual(plain[1].sides.map(\.face), [0, 1, 2, 3, 4, 5])
        let closed = try Solid.cuboid(1, 1, 1)
        closed.close()
        XCTAssertEqual(refusal { _ = try closed.regions() }, "solid: closed")
    }
}
