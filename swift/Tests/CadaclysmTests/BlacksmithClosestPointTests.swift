// Closest point from a point over the release library: the cube's face, edge and vertex feet and the
// sphere's pinned to their closed forms (literals, not read back through the wrapper), maxDistance on
// both sides, the projector equal to the one-shot (uv included) after its solid is closed, and the
// refusals' words.
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

private let sqrtHalf: Double = 0.7071067811865476
private let invSqrt3: Double = 0.5773502691896258

private func near3(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: 1e-9, what, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: 1e-9, what, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: 1e-9, what, file: file, line: line)
}

final class BlacksmithClosestPointTests: XCTestCase {
    func testACubeNamesFaceEdgeAndVertex() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let face = try XCTUnwrap(try cube.closestPoint([20, 0, 0]))
        XCTAssertEqual(face.distance, 15, accuracy: 1e-9)
        near3(face.point, [5, 0, 0], "face point")
        near3(face.normal, [1, 0, 0], "face normal")
        XCTAssertEqual(face.kind, "face")
        XCTAssertNil(face.edge)
        XCTAssertTrue(face.refined)
        let uv = try XCTUnwrap(face.uv)
        XCTAssertEqual(uv.x, 5, accuracy: 1e-9)
        XCTAssertEqual(uv.y, 5, accuracy: 1e-9)

        let edge = try XCTUnwrap(try cube.closestPoint([8, 8, 0]))
        XCTAssertEqual(edge.distance, 4.242640687119285, accuracy: 1e-9)
        near3(edge.point, [5, 5, 0], "edge point")
        near3(edge.normal, [sqrtHalf, sqrtHalf, 0], "edge normal")
        XCTAssertEqual(edge.kind, "edge")
        XCTAssertNotNil(edge.edge)
        XCTAssertNil(edge.uv)

        let corner = try XCTUnwrap(try cube.closestPoint([8, 8, 8]))
        XCTAssertEqual(corner.distance, 5.196152422706632, accuracy: 1e-9)
        near3(corner.point, [5, 5, 5], "corner point")
        near3(corner.normal, [invSqrt3, invSqrt3, invSqrt3], "corner normal")
        XCTAssertEqual(corner.kind, "vertex")
        XCTAssertNil(corner.edge)
        XCTAssertNil(corner.uv)

        let inside = try XCTUnwrap(try cube.closestPoint([1, 0, 0]))
        XCTAssertEqual(inside.distance, 4, accuracy: 1e-9)
        near3(inside.point, [5, 0, 0], "inside point")
        let on = try XCTUnwrap(try cube.closestPoint([5, 1, 2]))
        XCTAssertEqual(on.distance, 0, accuracy: 1e-9)
        near3(on.normal, [1, 0, 0], "on normal")
    }

    func testTheEdgeIsThePublicEdgeNumber() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let p: SIMD3<Double> = [8, 8, 1]
        let edge = try XCTUnwrap(try XCTUnwrap(try cube.closestPoint(p)).edge)
        let foot = try cube.edgeClosestPoint(Int(edge), p)
        near3(foot.point, [5, 5, 1], "edgeClosestPoint point")
        XCTAssertEqual(foot.distance, 4.242640687119285, accuracy: 1e-9)
        // A straight edge: the arc length to the foot is the chord from the edge's start.
        let start = try cube.edgePointAtLength(Int(edge), 0).point
        let s = ((start - foot.point) * (start - foot.point)).sum().squareRoot()
        let at = try cube.edgePointAtLength(Int(edge), s)
        near3(at.point, foot.point, "the point at that arc length")
        XCTAssertEqual(at.parameter, foot.t, accuracy: 1e-9)
        XCTAssertEqual(refusal { _ = try cube.edgeClosestPoint(99, p) }, "edge_closest_point: edge 99 of 12")
    }

    func testASphereInClosedForm() throws {
        let sphere = try Solid.sphere(2)
        let foot = try XCTUnwrap(try sphere.closestPoint([0, 3, 4]))
        XCTAssertEqual(foot.distance, 3, accuracy: 1e-9)
        near3(foot.point, [0, 1.2, 1.6], "sphere point")
        near3(foot.normal, [0, 0.6, 0.8], "sphere normal")
        XCTAssertEqual(foot.kind, "face")
        let inside = try XCTUnwrap(try sphere.closestPoint([0, 0, 0.5]))
        XCTAssertEqual(inside.distance, 1.5, accuracy: 1e-9)
        near3(inside.point, [0, 0, 2], "inside the sphere")
    }

    func testMaxDistanceOnBothSides() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let far: SIMD3<Double> = [20, 0, 0]
        XCTAssertNil(try cube.closestPoint(far, maxDistance: 14.9))
        XCTAssertEqual(try XCTUnwrap(try cube.closestPoint(far, maxDistance: 15.1)).distance, 15, accuracy: 1e-9)
        XCTAssertNotNil(try cube.closestPoint(far, maxDistance: .infinity))
        XCTAssertNotNil(try cube.closestPoint(far, maxDistance: .nan))
        XCTAssertNotNil(try cube.closestPoint([5, 1, 2], maxDistance: 0), "0 keeps a point on the body")
        XCTAssertNil(try cube.closestPoint([5.5, 1, 2], maxDistance: 0))
        XCTAssertEqual(refusal { _ = try cube.closestPoint(.zero, maxDistance: -1) },
                       "closest_point: the max distance must not be negative")
        for tolerance in [-1.0, Double.infinity] {
            let why = refusal { _ = try cube.closestPoint(.zero, tolerance: tolerance) }
            XCTAssertTrue(why?.hasPrefix("closest_point: ") ?? false, why ?? "no error")
        }
        let nan = refusal { _ = try cube.closestPoint([.nan, 0, 0]) }
        XCTAssertTrue(nan?.hasPrefix("closest_point: ") ?? false, nan ?? "no error")
    }

    func testAProjectorAnswersAsTheOneShotAndOutlivesItsSolid() throws {
        let points: [SIMD3<Double>] = [[20, 0, 0], [8, 8, 0], [8, 8, 8], [1, 0, 0], [0, -7, 2]]
        var cube: Solid? = try Solid.cuboid(10, 10, 10)
        let expected = try points.map { try cube!.closestPoint($0) }
        let projector = try cube!.projector()
        cube = nil
        let got = try points.map { try projector.closestPoint($0) }
        XCTAssertEqual(got, expected)
        let uv = try XCTUnwrap(try XCTUnwrap(got[0]).uv)
        XCTAssertEqual(uv.x, 5, accuracy: 1e-9)
        XCTAssertEqual(uv.y, 5, accuracy: 1e-9)
        XCTAssertNil(try projector.closestPoint(points[0], maxDistance: 14.9))
        XCTAssertEqual(try projector.closestPoint(points[0], maxDistance: 15.1), expected[0])
        XCTAssertEqual(refusal { _ = try projector.closestPoint(.zero, maxDistance: -1) },
                       "projector_closest_point: the max distance must not be negative")
        let bad = refusal { _ = try Solid.sphere(1).projector(tolerance: -1) }
        XCTAssertTrue(bad?.hasPrefix("projector_new: ") ?? false, bad ?? "no error")
        XCTAssertFalse(projector.isClosed)
        projector.close()
        XCTAssertTrue(projector.isClosed)
        projector.close()
        XCTAssertEqual(refusal { _ = try projector.closestPoint(.zero) }, "projector: closed")
    }

    func testFaceClosestPointStaysOnItsFace() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let top = try XCTUnwrap(try (0..<cube.faces).first { try cube.faceRef($0)[6] > 0.5 })
        let foot = try cube.faceClosestPoint(top, [20, 0, 0])
        near3(foot.point, [5, 0, 5], "past the face's edge")
        XCTAssertEqual(foot.distance, 15.811388300841896, accuracy: 1e-9)
        XCTAssertEqual(foot.kind, "edge")
        XCTAssertTrue(foot.refined)
        let inner = try cube.faceClosestPoint(top, [1, 2, 9])
        near3(inner.point, [1, 2, 5], "above the face")
        near3(inner.normal, [0, 0, 1], "above the face, normal")
        XCTAssertEqual(inner.kind, "face")
        XCTAssertEqual(Int(inner.index), top)
        XCTAssertNil(inner.edge)
        XCTAssertNotNil(inner.uv)
        XCTAssertEqual(refusal { _ = try cube.faceClosestPoint(99, .zero) }, "face_closest_point: face 99 of 6")
    }

    func testANurbsCurveClosestPointAndItsAxis() throws {
        let circle = try Circle(try Frame.xy(), 2).toNurbs()
        let foot = try circle.closestPoint([0, 5, 0])
        near3(foot.point, [0, 2, 0], "the circle's foot")
        XCTAssertTrue(foot.unique)
        near3(try circle.point(foot.t), foot.point, "the foot's parameter")
        let axis = try circle.closestPoint([0, 0, 3])
        XCTAssertFalse(axis.unique)
        XCTAssertEqual((axis.point * axis.point).sum().squareRoot(), 2, accuracy: 1e-9)
        let bad = refusal { _ = try circle.closestPoint([.infinity, 0, 0]) }
        XCTAssertTrue(bad?.hasPrefix("nurbs_curve_closest_point: ") ?? false, bad ?? "no error")
    }
}
