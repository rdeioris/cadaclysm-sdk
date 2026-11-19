// The 2D profile toolkit over the release library: Python's test_cadaclysm_blacksmith.py
// test_profile_union_difference_and_regions_are_exact, test_profile_contains_relationship_and_deviation,
// test_profile_offset_corner_and_end_styles and test_profile_polyline_tools -- every figure hand-computed
// (squares, discs, a ring, a chamfered or parabola-cornered offset square). The kernel's own
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

private func area(_ p: Profile) throws -> Double { try p.areaProperties().area }

/// The sides of a profile of straight lines: one Bezier (sixteen numbers) each.
private func sides(_ p: Profile) throws -> Int { try p.beziers().count / 16 }

final class BlacksmithProfileToolkitTests: XCTestCase {
    func testUnionDifferenceAndRegionsAreExact() throws {
        let a = try Profile.rect(10, 10)
        let b = try a.translate(5, 5)
        let u = try a.union(b)
        XCTAssertEqual(u.count, 1)
        XCTAssertEqual(try area(u[0]), 175, accuracy: 1e-9 * 175)
        let d = try a.difference(b)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(try area(d[0]), 75, accuracy: 1e-9 * 75)
        let ring = try Profile.circle(5).difference(try Profile.circle(2))
        XCTAssertEqual(ring.count, 1)
        XCTAssertEqual(try area(ring[0]), 21 * Double.pi, accuracy: 1e-9 * 21 * Double.pi)
        let regions = try Profile.regions([a, b]).map(area).sorted()
        XCTAssertEqual(regions.count, 3)
        for (got, want) in zip(regions, [25.0, 75, 75]) { XCTAssertEqual(got, want, accuracy: 1e-9 * want) }
    }

    func testContainsAndRelationship() throws {
        let sq = try Profile.rect(10, 10)
        XCTAssertEqual(try sq.contains([0, 0]), .inside)
        XCTAssertEqual(try sq.contains([5, 0]), .on)
        XCTAssertEqual(try sq.contains([6, 0]), .outside)
        XCTAssertEqual(try sq.relationship(try sq.translate(20, 0)), .disjoint)
        XCTAssertEqual(try sq.relationship(try sq.translate(10, 0)), .touching)
        XCTAssertEqual(try sq.relationship(try sq.translate(5, 0)), .overlapping)
        XCTAssertEqual(try Profile.circle(2).relationship(sq), .aInsideB)
        XCTAssertEqual(try sq.relationship(try Profile.circle(2)), .bInsideA)
        XCTAssertEqual(try sq.relationship(try Profile.rect(10, 10)), .equal)
    }

    func testDeviation() throws {
        let rings = try Profile.circle(5).deviation(try Profile.circle(6), tolerance: 1e-6)
        XCTAssertEqual(rings.maxDistance, 1, accuracy: 1e-6)
        XCTAssertEqual(rings.minDistance, 1, accuracy: 1e-6)
        let d = try Profile.rect(10, 10).deviation(try Profile.circle(5), tolerance: 1e-6)
        XCTAssertEqual(d.maxDistance, 5 * 2.0.squareRoot() - 5, accuracy: 1e-6)
        XCTAssertEqual(d.minDistance, 0, accuracy: 1e-6)
        XCTAssertEqual((d.maxA * d.maxA).sum().squareRoot(), 5 * 2.0.squareRoot(), accuracy: 1e-5, "the farthest point is a corner")
    }

    func testOffsetCornerAndEndStyles() throws {
        let sq = try Profile.rect(10, 10)
        XCTAssertEqual(try area(try sq.offset(1, tolerance: 1e-3, corner: .sharp)[0]), 144, accuracy: 1e-6 * 144)
        XCTAssertEqual(try area(try sq.offset(1, tolerance: 1e-3, corner: .chamfer)[0]), 142, accuracy: 1e-6 * 142)
        XCTAssertEqual(try area(try sq.offset(1, tolerance: 1e-3, corner: .smooth)[0]), 144 - 4.0 / 6, accuracy: 1e-6 * 144)
        XCTAssertEqual(try area(try sq.offset(1, tolerance: 1e-3)[0]), 140 + Double.pi, accuracy: 1e-4 * 144)
        let line = try Profile.polyline([[0, 0], [10, 0]])
        let flat = try line.offsetOpen(1, tolerance: 1e-3, corner: .round, end: .flat)
        XCTAssertEqual(flat.count, 1)
        XCTAssertEqual(try area(flat[0]), 20, accuracy: 1e-9 * 20)
    }

    func testPolylineTools() throws {
        let colinear = try Profile.polyline([[0, 0], [2, 0], [4, 0], [4, 4], [0, 4]], closed: true)
        XCTAssertEqual(try sides(colinear.mergeColinear(1e-9)), 4)
        XCTAssertTrue(try colinear.isConvex())
        XCTAssertFalse(try colinear.isConvex(strict: true))
        XCTAssertEqual(try Profile.rect(10, 10).breakAtKinks(0.1).count, 4)
        XCTAssertEqual(try area(try Profile.rect(10, 10).withSeam([0, -5])), 100, accuracy: 1e-9 * 100)
    }

    func testRefusalsAreNamed() throws {
        let sq = try Profile.rect(10, 10)
        let message = refusal { _ = try sq.contains([Double.nan, 0]) }
        XCTAssertTrue(message?.hasPrefix("profile_contains: ") ?? false, "\(String(describing: message))")
    }
}
