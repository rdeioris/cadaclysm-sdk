// The R-tree over the release library: Python's test_rtree_*,
// test_closest_points_and_k_neighbors_match_brute_force and
// test_k_neighbors_reports_a_bad_point_before_a_bad_k, trimmed to what proves the marshalling --
// every field read, every refusal's prefix, the lists' length and order, the handle's lifetime.
// The kernel's own correctness is the kernel's tests' job.
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

private func cell(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) -> Box {
    Box(SIMD3(x0, y0, z0), SIMD3(x1, y1, z1))
}

/// The 10 x 10 x 10 grid of unit boxes, id 100 i + 10 j + k.
private func grid() -> [(UInt32, Box)] {
    var cells: [(UInt32, Box)] = []
    for i in 0..<10 {
        for j in 0..<10 {
            for k in 0..<10 {
                let (x, y, z) = (Double(i), Double(j), Double(k))
                cells.append((UInt32(100 * i + 10 * j + k), cell(x, y, z, x + 1, y + 1, z + 1)))
            }
        }
    }
    return cells
}

private func ascending(_ pairs: [RTreePair]) -> Bool {
    zip(pairs, pairs.dropFirst()).allSatisfy { ($0.a, $0.b) <= ($1.a, $1.b) }
}

private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

final class BlacksmithRTreeTests: XCTestCase {
    func testAGridPackedOrGrownAnswersAlike() throws {
        let cells = grid()
        let packed = try RTree.fromBoxes(cells)
        let grown = try RTree()
        for (id, box) in cells.reversed() { try grown.insert(id, box) }
        let ids: [UInt32] = cells.map { $0.0 }
        let corner = ids.filter { (id: UInt32) -> Bool in
            let i: UInt32 = id / 100
            let j: UInt32 = id / 10 % 10
            let k: UInt32 = id % 10
            return i <= 2 && j <= 2 && k <= 2
        }
        XCTAssertEqual(corner.count, 27)
        var answers: [[RTreePair]] = []
        for (name, tree) in [("fromBoxes", packed), ("insert", grown)] {
            XCTAssertEqual(try tree.count, 1000, name)
            XCTAssertEqual(try tree.bounds, cell(0, 0, 0, 10, 10, 10), name)
            XCTAssertEqual(try tree.search(cell(0, 0, 0, 2, 2, 2)), corner, name)
            let near = try tree.nearest(SIMD3(-1, -1, -1), 1)
            XCTAssertEqual(near.count, 1, name)
            XCTAssertEqual(near.first?.id, 0, name)
            XCTAssertEqual(near.first?.distance ?? 0, 3.0.squareRoot(), accuracy: 1e-12, name)
            XCTAssertEqual(try tree.within(SIMD3(0, 0, 0), 0), [RTreeHit(id: 0, distance: 0)], name)
            XCTAssertEqual(try tree.within(SIMD3(-1, -1, -1), 2.5).map(\.id), [0, 1, 10, 100], name)
            let pairs = try tree.selfOverlaps()
            XCTAssertEqual(pairs.count, (28 * 28 * 28 - 1000) / 2, name)
            XCTAssertTrue(pairs.allSatisfy { $0.a < $0.b } && ascending(pairs), "\(name): a pair out of order")
            XCTAssertEqual(try tree.selfOverlaps(slack: 0.5), pairs, "\(name): unit gaps paired at slack 0.5")
            answers.append(pairs)
        }
        XCTAssertEqual(answers[0], answers[1], "the packed and the grown trees disagree")
    }

    func testOverlapsTwoTreesAndOneTreeTwice() throws {
        let packed = try RTree.fromBoxes(grid())
        let one = try RTree.fromBoxes([(7, cell(4.5, 4.5, 4.5, 5.5, 5.5, 5.5))])
        let ids: [UInt32] = [444, 445, 454, 455, 544, 545, 554, 555]
        XCTAssertEqual(try packed.overlaps(one), ids.map { RTreePair(a: $0, b: 7) })
        XCTAssertEqual(try one.overlaps(packed, slack: 0), ids.map { RTreePair(a: 7, b: $0) })
        let twice = try packed.overlaps(packed)
        XCTAssertEqual(twice.count, 1000 + 2 * 10476)
        XCTAssertTrue(ascending(twice))
    }

    func testPointsInsertAndRemove() throws {
        let points = try RTree.fromPoints([SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 3, 0)])
        XCTAssertEqual(try points.count, 4)
        XCTAssertEqual(try points.search(cell(0.9, -0.1, -0.1, 1.1, 0.1, 0.1)), [2], "ids are the indices")
        XCTAssertEqual(try points.search(cell(-0.1, -0.1, -0.1, 1.1, 0.1, 0.1)), [0, 2])
        XCTAssertEqual(try points.nearest(SIMD3(4, 0, 0), 2), [RTreeHit(id: 1, distance: 1), RTreeHit(id: 2, distance: 3)])

        let tree = try RTree()
        let unit = cell(3, 3, 3, 4, 4, 4)
        try tree.insert(7, unit)
        try tree.insert(7, unit)
        XCTAssertEqual(try tree.search(unit), [7, 7], "one (id, box) twice is two entries")
        XCTAssertEqual([try tree.remove(7, unit), try tree.remove(7, unit), try tree.remove(7, unit)], [true, true, false])
        try tree.insert(7, unit)
        XCTAssertFalse(try tree.remove(8, unit), "another id took the entry out")
        XCTAssertFalse(try tree.remove(7, cell(3, 3, 3, 4, 4, 4.5)), "another box took the entry out")
        let point = SIMD3<Double>(1, 2, 3)
        try tree.insert(9, point)
        XCTAssertEqual(try tree.count, 2)
        XCTAssertEqual(try tree.bounds, Box(point, SIMD3(4, 4, 4)))
        XCTAssertTrue(try tree.remove(9, point), "the point stayed")
        XCTAssertTrue(try tree.remove(7, unit), "the box stayed")
        XCTAssertEqual(try tree.count, 0, "emptied")
        XCTAssertNil(try tree.bounds, "emptied")
        try tree.insert(UInt32.max, point)
        XCTAssertEqual(try tree.search(cell(0, 0, 0, 5, 5, 5)), [UInt32.max], "the largest id came back whole")
        XCTAssertTrue(try tree.remove(UInt32.max, point))
    }

    func testClosestPointsAndKNeighborsMatchBruteForce() throws {
        var state: UInt64 = 5
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        let hay: [SIMD3<Double>] = (0..<30).map { _ in SIMD3(10 * next(), 10 * next(), 10 * next()) }
        let needles: [SIMD3<Double>] = (0..<5).map { _ in SIMD3(10 * next(), 10 * next(), 10 * next()) }
        func byDistance(_ q: SIMD3<Double>) -> [Int] {
            hay.indices.sorted { x, y in
                let (dx, dy) = (distance(hay[x], q), distance(hay[y], q))
                return dx != dy ? dx < dy : x < y
            }
        }
        let close = try closestPoints(hay, needles, 3)
        let knn = try kNeighbors(hay, needles, 4)
        XCTAssertEqual(close.count, 5)
        XCTAssertEqual(knn.count, 5)
        var some = false
        var all = true
        for (n, q) in needles.enumerated() {
            let order = byDistance(q)
            let inLimit = order.filter { distance(hay[$0], q) <= 3 }
            XCTAssertEqual(close[n], inLimit, "closest points, needle \(n)")
            XCTAssertEqual(knn[n], Array(order[..<4]), "k neighbors, needle \(n)")
            some = some || !inLimit.isEmpty
            all = all && inLimit.count == hay.count
        }
        XCTAssertTrue(some && !all, "the limit chose nothing or everything")
        let every = try kNeighbors(hay, Array(needles[..<2]), 500)
        XCTAssertEqual(every.count, 2)
        XCTAssertEqual(every[1], byDistance(needles[1]), "k over the hay count is every point")
        XCTAssertEqual(try kNeighbors([], Array(needles[..<2]), 3), [[], []], "an empty hay")
    }

    func testRefusalsNameTheirCall() throws {
        let (nan, inf) = (Double.nan, Double.infinity)
        let tree = try RTree()
        func check(_ prefix: String, _ suffix: String = "", _ body: () throws -> Void) {
            let message = refusal(body) ?? "no error, wanted \(prefix)"
            XCTAssertTrue(message.hasPrefix(prefix) && message.hasSuffix(suffix), message)
        }
        for bad in [cell(0, 0, 0, nan, 1, 1), cell(1, 0, 0, 0, 1, 1)] {
            check("rtree_insert: ", "is not a box") { try tree.insert(1, bad) }
        }
        check("rtree_insert_point: ", "is not finite") { try tree.insert(1, SIMD3(inf, 0, 0)) }
        XCTAssertEqual(try tree.count, 0, "a refused insert changed the tree")
        check("rtree_remove: ") { _ = try tree.remove(1, cell(1, 0, 0, 0, 1, 1)) }
        XCTAssertFalse(try tree.remove(1, cell(0, 0, 0, 1, 1, 1)), "absent right after a refusal")
        check("rtree_search: ") { _ = try tree.search(cell(0, 0, 0, nan, 1, 1)) }
        check("rtree_within: ", "is not finite") { _ = try tree.within(SIMD3(nan, 0, 0), 1) }
        check("rtree_nearest: ", "is not finite") { _ = try tree.nearest(SIMD3(nan, 0, 0), 1) }
        XCTAssertEqual(refusal { _ = try tree.within(SIMD3(0, 0, 0), -1) }, "rtree_within: radius -1 is not a distance")
        XCTAssertEqual(refusal { _ = try tree.selfOverlaps(slack: nan) }, "rtree_self_overlaps: slack NaN is not a distance")
        check("rtree_overlaps: ") { _ = try tree.overlaps(tree, slack: -0.5) }
        XCTAssertEqual(refusal { _ = try tree.nearest(SIMD3(0, 0, 0), 1_000_001) }, "rtree_nearest: k 1000001 is not at most 1000000")
        check("rtree_from_boxes: entry 1") { _ = try RTree.fromBoxes([(1, cell(0, 0, 0, 1, 1, 1)), (2, cell(2, 0, 0, 1, 1, 1))]) }
        XCTAssertEqual(refusal { _ = try RTree.fromPoints([SIMD3(0, 0, 0), SIMD3(0, nan, 0)]) }, "rtree_from_points: point 1 is not finite")

        let origin: [SIMD3<Double>] = [SIMD3(0, 0, 0)]
        XCTAssertEqual(refusal { _ = try closestPoints(origin, origin, -1) }, "closest_points: limit -1 is not a distance")
        XCTAssertEqual(refusal { _ = try closestPoints([SIMD3(0, 0, 0), SIMD3(nan, 0, 0)], [SIMD3(inf, 0, 0)], -1) },
                       "closest_points: limit -1 is not a distance", "the limit first")
        XCTAssertEqual(refusal { _ = try closestPoints(origin, [SIMD3(nan, 0, 0)], 1) }, "closest_points: needle point 0 is not finite")
        XCTAssertEqual(refusal { _ = try closestPoints([SIMD3(0, 0, 0), SIMD3(0, 0, nan)], [SIMD3(nan, 0, 0)], 1) },
                       "closest_points: hay point 1 is not finite", "the hay before the needles")
        XCTAssertEqual(refusal { _ = try kNeighbors([SIMD3(0, 0, 0), SIMD3(inf, 0, 0)], origin, 1_000_001) },
                       "k_neighbors: hay point 1 is not finite", "the points before k")
        XCTAssertEqual(refusal { _ = try kNeighbors(origin, origin, 1_000_001) }, "k_neighbors: k 1000001 is not at most 1000000")
    }

    /// A number in a message prints as Rust's `{}` prints an f64: the shortest round-trip
    /// digits, never an exponent.
    func testNumbersInMessagesPrintAsRustPrintsThem() {
        let cases: [(Double, String)] = [
            (1e20, "100000000000000000000"), (-1e-7, "-0.0000001"), (1.5, "1.5"), (-1, "-1"),
            (0.1 + 0.2, "0.30000000000000004"), (-0.0, "-0"), (.nan, "NaN"), (.infinity, "inf"),
            (-.infinity, "-inf"), (5e-324, "0." + String(repeating: "0", count: 323) + "5"),
            (1e-323, "0." + String(repeating: "0", count: 322) + "1"), (1e16, "10000000000000000"),
            (-1.2345678901234568e17, "-123456789012345680"), (1e21, "1000000000000000000000"),
            (0.000123, "0.000123"), (-2.5e-5, "-0.000025"),
        ]
        for (x, shown) in cases {
            XCTAssertEqual(rustNumber(x), shown, "\(x)")
        }
        let origin: [SIMD3<Double>] = [SIMD3(0, 0, 0)]
        XCTAssertEqual(refusal { _ = try closestPoints(origin, origin, -1e-7) }, "closest_points: limit -0.0000001 is not a distance")
        XCTAssertEqual(refusal { _ = try closestPoints(origin, origin, -1e20) },
                       "closest_points: limit -100000000000000000000 is not a distance")
    }

    func testAnEmptyTreeAnswersNothingAndAClosedOneRefuses() throws {
        let other = try RTree.fromBoxes(grid())
        let empty = try RTree()
        XCTAssertEqual(try empty.count, 0)
        XCTAssertNil(try empty.bounds)
        XCTAssertEqual(try empty.search(cell(0, 0, 0, 1, 1, 1)), [])
        XCTAssertEqual(try empty.within(SIMD3(0, 0, 0), 10), [])
        XCTAssertEqual(try empty.nearest(SIMD3(0, 0, 0), 3), [])
        XCTAssertEqual(try empty.selfOverlaps(), [])
        XCTAssertEqual(try empty.overlaps(other), [])
        XCTAssertEqual(try other.overlaps(empty), [])
        XCTAssertEqual(try RTree.fromBoxes([]).count, 0)
        XCTAssertEqual(try RTree.fromPoints([]).count, 0)

        XCTAssertFalse(empty.isClosed)
        empty.close()
        empty.close()
        XCTAssertTrue(empty.isClosed)
        XCTAssertEqual(refusal { _ = try empty.count }, "rtree: closed")
        XCTAssertEqual(refusal { _ = try empty.bounds }, "rtree: closed")
        XCTAssertEqual(refusal { try empty.insert(1, SIMD3(0, 0, 0)) }, "rtree: closed")
        XCTAssertEqual(refusal { _ = try empty.search(cell(0, 0, 0, 1, 1, 1)) }, "rtree: closed")
        XCTAssertEqual(refusal { _ = try other.overlaps(empty) }, "rtree: closed")
        XCTAssertEqual(try other.count, 1000, "the other tree is untouched")
    }

    // Rays, triangle trees and a solid's face tree (rtree plan 6): Python's test_rtree_ray_*,
    // test_rtree_from_triangles_* and test_solid_face_tree_*, trimmed.

    private func hits(_ rows: [(UInt32, Double)]) -> [RTreeHit] {
        rows.map { RTreeHit(id: $0.0, distance: $0.1) }
    }

    func testARayThroughARow() throws {
        let row = try RTree.fromBoxes((0..<10).map { (UInt32($0), cell(Double($0), 0, 0, Double($0) + 1, 1, 1)) })
        let (x, start) = (SIMD3<Double>(1, 0, 0), SIMD3<Double>(-1, 0.5, 0.5))
        let along: [(UInt32, Double)] = (0..<10).map { (i: Int) -> (UInt32, Double) in (UInt32(i), Double(i) + 1) }
        XCTAssertEqual(try row.ray(start, x), hits(along))
        XCTAssertEqual(try row.ray(start, SIMD3(2, 0, 0), maxT: 1), hits([(0, 0.5), (1, 1)]), "t in units of the direction")
        XCTAssertEqual(try row.ray(start, x, maxT: 3), hits([(0, 1), (1, 2), (2, 3)]), "max_t cuts the row")
        XCTAssertEqual(try row.ray(SIMD3(2.5, 0.5, 0.5), x, maxT: 1), hits([(2, 0), (3, 0.5)]), "from inside: 0")
        XCTAssertEqual(try row.ray(SIMD3(11, 0.5, 0.5), SIMD3(-1, 0, 0), maxT: 2), hits([(9, 1), (8, 2)]))
        XCTAssertEqual(try row.ray(SIMD3(-1, 1, 0.5), x).count, 10, "grazing the top face counts")
        XCTAssertEqual(try row.ray(SIMD3(-1, 1 + 1e-12, 0.5), x), [])
        XCTAssertEqual(try RTree().ray(start, x), [], "an empty tree")

        let (nan, inf) = (Double.nan, Double.infinity)
        XCTAssertEqual(refusal { _ = try row.ray(SIMD3(0, 0, 0), SIMD3(0, 0, 0)) }, "rtree_ray: direction (0, 0, 0) is not a direction")
        XCTAssertEqual(refusal { _ = try row.ray(SIMD3(0, 0, 0), x, maxT: -1) }, "rtree_ray: max_t -1 is not a distance")
        XCTAssertEqual(refusal { _ = try row.ray(SIMD3(0, 0, 0), x, maxT: nan) }, "rtree_ray: max_t NaN is not a distance")
        XCTAssertEqual(refusal { _ = try row.ray(SIMD3(nan, 0, 0), x) }, "rtree_ray: origin (NaN, 0, 0) is not finite")
        XCTAssertEqual(refusal { _ = try row.ray(SIMD3(0, 0, 0), SIMD3(inf, 0, 0)) }, "rtree_ray: direction (inf, 0, 0) is not finite")
        row.close()
        XCTAssertEqual(refusal { _ = try row.ray(start, x) }, "rtree: closed")
    }

    func testFromTrianglesBoxesEachTriangle() throws {
        let positions: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(0, 3, 0), SIMD3(.nan, 0, 0), SIMD3(5, 1, 4)]
        let tree = try RTree.fromTriangles(positions, [(0, 1, 2), (1, 4, 1)])
        XCTAssertEqual(try tree.count, 2)
        XCTAssertEqual(try tree.bounds, cell(0, 0, 0, 5, 3, 4), "point 3 is used by no triangle")
        XCTAssertEqual(try tree.search(cell(1, 1, 0, 1, 1, 0)), [0], "ids are the triangle indices")
        XCTAssertEqual(try tree.search(cell(4, 0.5, 2, 4, 0.5, 2)), [1])
        XCTAssertEqual(try tree.ray(SIMD3(-1, 0.5, 0), SIMD3(1, 0, 0)), hits([(0, 1), (1, 3)]))
        XCTAssertEqual(try RTree.fromTriangles([], []).count, 0)
        XCTAssertEqual(refusal { _ = try RTree.fromTriangles(Array(repeating: SIMD3(0, 0, 0), count: 4), [(0, 1, 2), (0, 4, 1)]) },
                       "rtree_from_triangles: triangle 1 names point 4 of 4")
        XCTAssertEqual(refusal { _ = try RTree.fromTriangles([SIMD3(0, 0, 0), SIMD3(0, .infinity, 0)], [(0, 1, 0)]) },
                       "rtree_from_triangles: triangle 0 point 1 is not finite")
    }

    func testACuboidsFaceTree() throws {
        let cuboid = try Solid.cuboid(3, 4, 5)
        let faces = try cuboid.faceTree()
        XCTAssertEqual(try faces.count, 6)
        let grow = 5 * 1e-3
        let b = try XCTUnwrap(try faces.bounds)
        let want: [SIMD3<Double>] = [SIMD3(-1.5 - grow, -2 - grow, -2.5 - grow), SIMD3(1.5 + grow, 2 + grow, 2.5 + grow)]
        for (got, wanted) in zip([b.lo, b.hi], want) {
            for axis in 0..<3 {
                XCTAssertEqual(got[axis], wanted[axis], accuracy: 1e-9, "\(b)")
            }
        }
        XCTAssertEqual(try faces.search(cell(1.4, 1.9, 2.4, 1.6, 2.1, 2.6)).count, 3, "three faces at a corner")
        let shot = try faces.ray(SIMD3(10, 0, 0), SIMD3(-1, 0, 0))
        XCTAssertEqual(shot.count, 2, "\(shot)")
        XCTAssertEqual(shot.first?.distance ?? 0, 8.5 - grow, accuracy: 1e-9)
        XCTAssertEqual(shot.last?.distance ?? 0, 11.5 - grow, accuracy: 1e-9)
        // The +x face is the one the ray met first: a face call by that index agrees.
        let frame = try cuboid.faceFrame(Int(shot.first?.id ?? 99))
        XCTAssertEqual(Array(frame[9..<12]), [1, 0, 0])
        // The tree is its own: it outlives the solid.
        cuboid.close()
        XCTAssertEqual(try faces.count, 6)
        XCTAssertEqual(refusal { _ = try cuboid.faceTree() }, "solid: closed")
    }
}
