// Clash detection over the release library: Python's test_clash_*, trimmed to what proves the
// marshalling -- every field read, every refusal's prefix, the rows keeping their handle -- plus
// an edge row, the one answer whose two sides are both edges. The kernel's own correctness is
// the kernel's tests' job.
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

/// The frame at (x, y, z) on the world axes.
private func at(_ x: Double, _ y: Double = 0, _ z: Double = 0) throws -> Frame {
    try Frame(values: [x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1])
}

final class BlacksmithClashTests: XCTestCase {
    func testClashBallsWithinTheClearanceAreTooClose() throws {
        let collider = try Collider([try Solid.sphere(1), try Solid.sphere(1)], tolerance: 1e-3)
        defer { collider.close() }
        let rows = try collider.clash([try at(0), try at(2.5)], clearance: 1)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.a, 0)
        XCTAssertEqual(r.b, 1)
        XCTAssertEqual(r.kind, "too_close")
        XCTAssertEqual(r.distance, 0.5, accuracy: 1e-3)
        XCTAssertEqual(r.kindA, "face")
        XCTAssertEqual(r.kindB, "face")
        XCTAssertNotNil(r.indexA)
        XCTAssertNotNil(r.indexB)
        XCTAssertNil(r.edgeA)
        XCTAssertNil(r.edgeB)
        XCTAssertEqual(r.onA.x, 1, accuracy: 2e-3)
        XCTAssertEqual(r.onB.x, 1.5, accuracy: 2e-3)
        XCTAssertEqual(r.text, "")
        XCTAssertEqual(r.depth, 0)
        _ = r.refined as Bool
        XCTAssertEqual(r.description, "Clash(a=0, b=1, kind=too_close, distance=\(r.distance))")
        XCTAssertTrue(try collider.clash([try at(0), try at(2.5)], clearance: 0.25).isEmpty)
    }

    func testClashBoxesFaceToFaceTouchAndIntersectOnTheSharedFace() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: 1e-3)
        let rows = try collider.clash([try at(0), try at(2)])
        collider.close()
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.kind, "touching")
        XCTAssertLessThanOrEqual(r.distance, 1e-3)
        XCTAssertTrue(refusal { _ = try r.solid() }?.hasPrefix("clashes_solid: pair (0, 1) is not penetrating") ?? false)
        let x = try r.intersect()
        XCTAssertEqual(x.overlaps.count, 1)
        let ring = try XCTUnwrap(x.overlaps.first?.loops.first)
        XCTAssertFalse(ring.isEmpty)
        for p in ring { XCTAssertEqual(p.x, 1, accuracy: 1e-3) }
        var twice = 0.0
        for i in ring.indices {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            twice += p.y * q.z - q.y * p.z
        }
        XCTAssertEqual(abs(twice) / 2, 4, accuracy: 1e-6)
    }

    func testClashBoxesInterpenetratingReportDepthAndOutliveTheCollider() throws {
        let collider = try Collider([try Solid.cuboid(2, 2, 2), try Solid.cuboid(2, 2, 2)], tolerance: 1e-3)
        var rows: [Clash]? = try collider.clash([try at(0), try at(1.75)])
        collider.close()
        XCTAssertEqual(rows?.count, 1)
        // One row kept, the list (and with it every other reference) dropped: the row alone
        // holds the clashes handle now.
        let r = try XCTUnwrap(rows?.first)
        rows = nil
        XCTAssertEqual(r.kind, "penetrating")
        XCTAssertEqual(r.depth, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.distance, 0)
        XCTAssertEqual(r.kindA, "none")
        XCTAssertEqual(r.kindB, "none")
        XCTAssertNil(r.indexA)
        XCTAssertNil(r.edgeA)
        XCTAssertNil(r.indexB)
        XCTAssertNil(r.edgeB)
        let mass: Mass = try r.solid().mass()
        XCTAssertEqual(mass.volume, 1, accuracy: 1e-6)
        _ = try r.intersect()
    }

    func testClashOneShotIndexesTheSecondSetAndHonoursAllowed() throws {
        let a0 = try Solid.sphere(1)
        let a1 = try Solid.sphere(1).translate(2.05, 0, 0)
        let b0 = try Solid.sphere(1).translate(0, 2.5, 0)
        let b1 = try Solid.sphere(1).translate(10, 0, 0)
        let two = try clash([a0, a1], [b0, b1], clearance: 1, tolerance: 1e-3)
        XCTAssertEqual(two.map { "\($0.a) \($0.b) \($0.kind)" }, ["0 0 too_close"])
        XCTAssertEqual(two[0].distance, 0.5, accuracy: 1e-3)
        let one = try clash([a0, a1], clearance: 1, tolerance: 1e-3)
        XCTAssertEqual(one.map { "\($0.a) \($0.b)" }, ["0 1"])
        XCTAssertTrue(try clash([a0, a1], clearance: 1, tolerance: 1e-3, allowed: [0, 1]).isEmpty)
    }

    func testClashRefusalsCarryTheCallsPrefix() throws {
        let a = try Solid.cuboid(2, 2, 2), b = try Solid.cuboid(2, 2, 2)
        let collider = try Collider([a, b])
        defer { collider.close() }
        func refused(_ prefix: String, _ body: () throws -> Void) {
            let message = refusal(body)
            XCTAssertTrue(message?.hasPrefix(prefix) ?? false, "expected '\(prefix)...', got \(message ?? "no refusal")")
        }
        refused("collider_clash: clearance -1") { _ = try collider.clash([try at(0), try at(1.75)], clearance: -1) }
        refused("collider_clash: 1 frames for 2 groups") { _ = try collider.clash([try at(0)]) }
        refused("collider_clash: share (2, 2)") { _ = try collider.clash([try at(0), try at(1.75)], share: (2, 2)) }
        refused("clash: clearance -1") { _ = try clash([a, b], clearance: -1) }
        refused("clash: allowed pair (5, 0) names a part out of range") { _ = try clash([a, b], allowed: [5, 0]) }
        refused("clash: allowed is 3 numbers, not pairs") { _ = try clash([a, b], allowed: [0, 1, 0]) }
        refused("clash: an empty set") { _ = try clash([a, b], []) }
    }

    func testClashAnEdgeComesWithinTheClearanceOfAnEdge() throws {
        // b turned so that its edge from (1, 1, -1)..(1, 1, 1) in its own axes runs crosswise
        // over a's edge x = 1, y = 1, 0.1 off it: both closest points lie on edges.
        let a = try Solid.cuboid(2, 2, 2), b = try Solid.cuboid(2, 2, 2)
        let collider = try Collider([a, b], tolerance: 1e-3)
        defer { collider.close() }
        let c = (0.5).squareRoot(), s = 0.1 * c
        let turned = try Frame(values: [2 + s, 2 + s, 0, c, -c, 0, 0.5, 0.5, c, -0.5, -0.5, c])
        let rows = try collider.clash([try at(0), turned], clearance: 0.5)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.kind, "too_close")
        XCTAssertEqual(r.distance, 0.1, accuracy: 1e-3)
        XCTAssertEqual(r.onA.x, 1, accuracy: 2e-3)
        XCTAssertEqual(r.onA.y, 1, accuracy: 2e-3)
        XCTAssertEqual(r.onA.z, 0, accuracy: 2e-3)
        XCTAssertEqual(r.kindA, "edge")
        XCTAssertEqual(r.kindB, "edge")
        let edgesA = try a.edges, edgesB = try b.edges
        let edgeA = Int(try XCTUnwrap(r.edgeA))
        XCTAssertLessThan(edgeA, edgesA.count)
        for segment in edgesA[edgeA].segments {
            for p in [segment.start, segment.end] {
                XCTAssertEqual(p.x, 1, accuracy: 2e-3)
                XCTAssertEqual(p.y, 1, accuracy: 2e-3)
            }
        }
        XCTAssertLessThan(Int(try XCTUnwrap(r.edgeB)), edgesB.count)
    }

    func testClashAnEdgeFacingAFaceKeepsEachSidesKind() throws {
        // Side a a box's edge, side b a ball's face: the one row where a swap of the two sides'
        // features shows. The ball sits 0.2 off a's edge x = 1, y = 1, as Solid.closest agrees.
        let a = try Solid.cuboid(2, 2, 2), ball = try Solid.sphere(1)
        let centre = 1 + 1.2 * (0.5).squareRoot()  // the ball's centre 1.2 off the edge
        let collider = try Collider([a, ball], tolerance: 1e-3)
        defer { collider.close() }
        let rows = try collider.clash([try at(0), try at(centre, centre)], clearance: 0.5)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        let closest = try a.closest(try ball.translate(centre, centre, 0), tolerance: 1e-3)
        XCTAssertEqual(closest.kindA, "edge")
        XCTAssertEqual(closest.kindB, "face")
        XCTAssertEqual(r.kind, "too_close")
        XCTAssertEqual(r.distance, 0.2, accuracy: 1e-3)
        XCTAssertEqual(r.distance, closest.distance, accuracy: 1e-3)
        XCTAssertEqual(r.kindA, "edge")
        XCTAssertEqual(r.kindB, "face")
        XCTAssertEqual(r.edgeA, closest.edgeA)
        XCTAssertNotNil(r.edgeA)
        XCTAssertNil(r.edgeB)
        XCTAssertEqual(r.indexA, closest.indexA)
        XCTAssertEqual(r.indexB, closest.indexB)
    }
}
