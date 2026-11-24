// 2D polygon sets over the release library: Python's test_polygon_set_* (the _POLYGON_SET
// tests), figure for figure -- the same exact areas, rings corner for corner, refusals by their
// library message. The kernel's own correctness is the kernel's tests' job; these prove the
// marshalling: every view field read, every verb's handle adopted, every refusal thrown.
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

private func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) throws -> PolygonSet {
    try PolygonSet.fromRings([SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)])
}

private func pts(_ xy: [(Double, Double)]) -> [SIMD2<Double>] { xy.map { SIMD2($0.0, $0.1) } }

/// pytest.approx's default: relative 1e-6, absolute 1e-12.
private func approx(_ a: Double, _ b: Double, abs tol: Double? = nil) -> Bool {
    Swift.abs(a - b) <= (tol ?? max(1e-12, 1e-6 * Swift.abs(b)))
}

final class BlacksmithPolygonSetTests: XCTestCase {
    func testBooleansAndMeasures() throws {
        let a = try box(0, 0, 2, 2), b = try box(1, 1, 3, 3)
        XCTAssertEqual(try a.union(b).area, 7.0)
        XCTAssertEqual(try a.intersection(b).area, 1.0)
        XCTAssertEqual(try a.difference(b).area, 3.0)
        XCTAssertEqual(try a.symmetricDifference(b).area, 6.0)
        XCTAssertEqual(try a.intersectionArea(b), 1.0)
        XCTAssertEqual(try a.differenceArea(b), 3.0)
        var tiles: [PolygonSet] = []
        for i in 0..<4 {
            for j in 0..<3 { tiles.append(try box(Double(i), Double(j), Double(i + 1), Double(j + 1))) }
        }
        let u = try PolygonSet.unionAll(tiles)
        XCTAssertEqual(try u.polygons.count, 1)
        XCTAssertEqual(try u.count, 1)
        XCTAssertEqual(try u.area, 12.0)
        XCTAssertEqual(try u.perimeter, 14.0)
        let bounds = try XCTUnwrap(try u.bounds)
        XCTAssertTrue(bounds == (0.0, 0.0, 4.0, 3.0), "\(bounds)")
        let c = try XCTUnwrap(try u.centroid)
        XCTAssertTrue(approx(c.x, 2.0) && approx(c.y, 1.5), "\(c)")
        let empty = try PolygonSet()
        XCTAssertTrue(try empty.isEmpty)
        XCTAssertNil(try empty.bounds)
        XCTAssertNil(try empty.centroid)
        XCTAssertTrue(try PolygonSet.unionAll([]).isEmpty)
    }

    func testRingsComeBackAsShapelys() throws {
        // Kept as written; a verb's result as shapely (GEOS 3.13) gives it, corner for corner.
        let room = try PolygonSet.fromRings(pts([(0, 0), (4, 0), (4, 3), (0, 3), (0, 0)]))
        XCTAssertEqual(try room.polygons, [PolygonSet.Polygon(pts([(0, 0), (4, 0), (4, 3), (0, 3)]))])
        XCTAssertEqual(try room.cleaned().polygons[0].outer, pts([(0, 0), (0, 3), (4, 3), (4, 0)]))
        let cut = try room.difference(try box(1, -1, 2, 4))
        XCTAssertEqual(try cut.polygons.map { $0.outer },
                       [pts([(0, 0), (0, 3), (1, 3), (1, 0)]), pts([(4, 3), (4, 0), (2, 0), (2, 3)])])
        let holed = try box(0, 0, 10, 10).difference(try box(4, 4, 6, 6))
        let polygons = try holed.polygons
        XCTAssertEqual(polygons.count, 1)
        XCTAssertEqual(Array(polygons[0].outer.prefix(2)), pts([(0, 10), (10, 10)]))
        XCTAssertEqual(polygons[0].holes.count, 1)
        XCTAssertEqual(Array(polygons[0].holes[0].prefix(2)), pts([(6, 4), (6, 6)]))
        XCTAssertEqual(try holed.area, 96.0)
        // A set of two polygons, one holed, back through fromPolygons as it came out.
        let again = try PolygonSet.fromPolygons(polygons + (try cut.polygons))
        XCTAssertEqual(try again.polygons, polygons + (try cut.polygons))
    }

    func testBufferIsShapelys() throws {
        // shapely 2.1 / GEOS 3.13: these areas, to the last few bits.
        let sq = try box(0, 0, 10, 10)
        XCTAssertTrue(approx(try sq.buffer(-2).area, 36.0, abs: 1e-12))
        XCTAssertTrue(try sq.buffer(-6).isEmpty)
        let dumbbell = try PolygonSet.unionAll([try box(0, 0, 4, 4), try box(4, 1.5, 8, 2.5), try box(8, 0, 12, 4)])
        let shrunk = try dumbbell.buffer(-1)
        XCTAssertEqual(try shrunk.polygons.count, 2)
        let shrunkArea = try shrunk.area
        XCTAssertTrue(approx(shrunkArea, 8.088436436788012, abs: 1e-9), "\(shrunkArea)")
        let gap = try PolygonSet.unionAll([try box(0, 0, 1, 1), try box(1.5, 0, 2.5, 1)])
        XCTAssertTrue(approx(try gap.buffer(0.3).buffer(-0.3).area, 2.4057536390037235, abs: 1e-9))
        XCTAssertTrue(approx(try box(0, 0, 4, 3).buffer(1, join: .mitre).area, 30.0))
        let flat = try PolygonSet.bufferPolyline(pts([(0, 0), (4, 0)]), 0.5, cap: .flat)
        let bounds = try XCTUnwrap(try flat.bounds)
        XCTAssertTrue(bounds == (0.0, -0.5, 4.0, 0.5), "\(bounds)")
        // The join is an enum here; the refusal a bad argument still gets is the library's.
        let message = refusal { _ = try sq.buffer(1, quadSegs: 0) }
        XCTAssertTrue(message?.hasPrefix("polygon_set_buffer") ?? false, message ?? "no refusal")
        let line = refusal { _ = try PolygonSet.bufferPolyline(pts([(0, 0), (4, 0)]), -1) }
        XCTAssertTrue(line?.hasPrefix("polygon_set_buffer_polyline") ?? false, line ?? "no refusal")
    }

    func testAndProfileGoAcrossAndBack() throws {
        let washer = try Profile.circle(10).withHole(try Profile.circle(4))
        let s = try PolygonSet.fromProfile(washer, 1e-3)
        let exact = Double.pi * (100 - 16)
        XCTAssertLessThan(Swift.abs(try s.area - exact), exact * 1e-3)
        XCTAssertEqual(try s.polygons[0].holes.count, 1)
        let back = try s.toProfiles()
        XCTAssertEqual(back.count, 1)
        XCTAssertTrue(approx(try PolygonSet.fromProfile(back[0], 1e-3).area, try s.area, abs: 1e-9))
        // A floor plan grown into walls: the room's outline thickened, then extruded.
        let room = try box(0, 0, 4, 3)
        let walls = try room.buffer(0.1, join: .mitre).difference(room)
        let rings = try walls.toProfiles()
        XCTAssertEqual(rings.count, 1)
        let mass: Mass = try Solid.extrude(rings[0], try Frame.xy(), 2.5).mass()
        let volume = mass.volume
        XCTAssertTrue(approx(volume, try walls.area * 2.5), "\(volume)")
        XCTAssertTrue(try PolygonSet().toProfiles().isEmpty)
        let message = refusal { _ = try PolygonSet.fromProfile(washer, -1) }
        XCTAssertTrue(message?.contains("profile_polygon_set: tolerance") ?? false, message ?? "no refusal")
    }

    func testQuestions() throws {
        let room = try box(0, 0, 10, 10).difference(try box(4, 4, 6, 6))
        XCTAssertEqual(try room.locate(pts([(1, 1), (4, 5), (5, 5)])), [1, 0, -1])
        XCTAssertTrue(try room.containsPoint(SIMD2(1, 1)))
        XCTAssertFalse(try room.containsPoint(SIMD2(4, 5)))
        XCTAssertTrue(try room.contains(try box(0, 0, 1, 1)))
        XCTAssertFalse(try room.contains(try box(3, 3, 7, 7)))
        XCTAssertFalse(try room.contains(try box(4, 4, 6, 8)))
        XCTAssertTrue(try room.contains(try box(4, 6, 6, 8)))
        XCTAssertTrue(try room.intersects(try box(10, 0, 12, 1)))
        XCTAssertFalse(try room.intersects(try box(4.5, 4.5, 5.5, 5.5)))
        XCTAssertTrue(try room.containsPolyline(pts([(1, 1), (9, 1)])))
        XCTAssertFalse(try room.containsPolyline(pts([(1, 5), (9, 5)])))
        XCTAssertFalse(try room.containsPolyline(pts([(0, 0), (10, 0)])))
        XCTAssertTrue(try room.intersectsPolyline(pts([(-1, 5), (11, 5)])))
        XCTAssertEqual(try room.distance(try box(12, 0, 13, 1)), 2.0)
        XCTAssertEqual(try room.distanceToPoint(SIMD2(5, 5)), 1.0)
        XCTAssertEqual(try room.boundaryDistance(SIMD2(1, 1)), 1.0)
        XCTAssertEqual(try room.distanceToPolyline(pts([(13, 0), (13, 10)])), 3.0)
        XCTAssertEqual(try room.clipPolyline(pts([(-1, 5), (11, 5)])),
                       [pts([(0, 5), (4, 5)]), pts([(6, 5), (10, 5)])])
        XCTAssertEqual(try room.clipPolyline(pts([(20, 20), (30, 20)])), [])
        let moved = try room.transformed(0, -1, 1, 0, 1, 2)
        XCTAssertEqual(try moved.area, 96.0)
        let bounds = try XCTUnwrap(try moved.bounds)
        XCTAssertTrue(bounds == (-9.0, 2.0, 1.0, 12.0), "\(bounds)")
        let short = refusal { _ = try PolygonSet.fromRings(pts([(0, 0), (1, 0)])) }
        XCTAssertTrue(short?.contains("ring 0 has 2 points") ?? false, short ?? "no refusal")
        let nan = refusal { _ = try room.locate(pts([(0, 0), (.nan, 0)])) }
        XCTAssertTrue(nan?.contains("point 1 is not finite") ?? false, nan ?? "no refusal")
    }

    func testCloseIsIdempotentAndRefusesUse() throws {
        let s = try box(0, 0, 1, 1)
        XCTAssertFalse(s.isClosed)
        s.close()
        s.close()
        XCTAssertTrue(s.isClosed)
        XCTAssertEqual(refusal { _ = try s.area }, "polygon_set: closed")
    }
}
