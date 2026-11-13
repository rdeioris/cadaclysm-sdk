// Closest points against a triangle mesh over the release library: a unit square's face, shared
// edge, outer edge and corner, and a line through a tetrahedron, pinned to their closed forms
// (literals, not read back through the wrapper) at the origin and shifted far out; maxDistance on
// both sides, a solid's own mesh, the nearest object naming a mesh item, and the refusals' words.
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

private func near3(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double, _ what: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.x, b.x, accuracy: tol, what, file: file, line: line)
    XCTAssertEqual(a.y, b.y, accuracy: tol, what, file: file, line: line)
    XCTAssertEqual(a.z, b.z, accuracy: tol, what, file: file, line: line)
}

private func segment(_ a: SIMD3<Double>, _ b: SIMD3<Double>) throws -> NurbsCurve {
    try NurbsCurve([a, b], degree: 1)
}

private let shifts: [SIMD3<Double>] = [[0, 0, 0], [1e4, -1e4, 5e3], [1e6, -1e6, 5e5]]

/// 1e-12 relative to the shift's largest coordinate, as the other wrappers' tests take it.
private func scaled(_ s: SIMD3<Double>, _ base: Double) -> Double {
    let far: Double = max(abs(s.x), max(abs(s.y), abs(s.z)))
    return base * (1 + far)
}

private let square: [SIMD3<Double>] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]]
private let squareTriangles: [(UInt32, UInt32, UInt32)] = [(0, 1, 2), (0, 2, 3)]   // sharing the diagonal 0-2
private let tetra: [SIMD3<Double>] = [[0, 0, 0], [1, 0, 0], [0, 1, 0], [0, 0, 1]]
private let tetraTriangles: [(UInt32, UInt32, UInt32)] = [(0, 2, 1), (0, 1, 3), (0, 3, 2), (1, 2, 3)]   // 0 the z = 0 floor

private func meshOf(_ points: [SIMD3<Double>], _ triangles: [(UInt32, UInt32, UInt32)], _ s: SIMD3<Double>) throws -> TriangleMesh {
    try TriangleMesh(points.map { $0 + s }, triangles)
}

final class BlacksmithMeshClosestTests: XCTestCase {
    func testATriangleMeshNamesItsFaceEdgeAndVertexFeet() throws {
        for s in shifts {
            let tol = scaled(s, 1e-12)
            let mesh = try meshOf(square, squareTriangles, s)
            XCTAssertEqual(try mesh.vertexCount, 4)
            XCTAssertEqual(try mesh.triangleCount, 2)
            let box = try mesh.bounds
            XCTAssertEqual(box.min, s)
            XCTAssertEqual(box.max, s + [1, 1, 0])

            let face = try XCTUnwrap(try mesh.closestPoint(s + [0.75, 0.25, 2]))
            XCTAssertEqual(face.triangle, 0)
            XCTAssertEqual(face.kind, "face")
            XCTAssertEqual(face.vertices, [])
            near3(face.point, s + [0.75, 0.25, 0], tol, "the face point at shift \(s)")
            XCTAssertEqual(face.distance, 2, accuracy: 1e-9)
            near3(face.barycentric, [0.25, 0.5, 0.25], 1e-9, "the face's barycentric")

            let diagonal = try XCTUnwrap(try mesh.closestPoint(s + [0.5, 0.5, 1]))
            XCTAssertEqual(diagonal.triangle, 0, "the lower triangle answers the shared edge")
            XCTAssertEqual(diagonal.kind, "edge")
            XCTAssertEqual(diagonal.vertices, [0, 2])
            XCTAssertEqual(diagonal.distance, 1, accuracy: 1e-9)
            near3(diagonal.barycentric, [0.5, 0, 0.5], 1e-9, "the shared edge's barycentric")

            let outer = try XCTUnwrap(try mesh.closestPoint(s + [0.5, -1, 0]))
            XCTAssertEqual(outer.triangle, 0)
            XCTAssertEqual(outer.kind, "edge")
            XCTAssertEqual(outer.vertices, [0, 1])
            near3(outer.barycentric, [0.5, 0.5, 0], 1e-9, "the outer edge's barycentric")

            let corner = try XCTUnwrap(try mesh.closestPoint(s + [2, 2, 0]))
            XCTAssertEqual(corner.triangle, 0)
            XCTAssertEqual(corner.kind, "vertex")
            XCTAssertEqual(corner.vertices, [2])
            near3(corner.point, s + [1, 1, 0], tol, "the corner at shift \(s)")
            XCTAssertEqual(corner.distance, 2.0.squareRoot(), accuracy: 1e-9)
            near3(corner.barycentric, [0, 0, 1], 1e-9, "the corner's barycentric")
        }
    }

    func testAPointMaxDistanceOnBothSides() throws {
        for s in shifts {
            let mesh = try meshOf(square, squareTriangles, s)
            let p = s + [0.75, 0.25, 2]
            let unlimited = try mesh.closestPoint(p)
            XCTAssertNotNil(unlimited)
            XCTAssertEqual(try mesh.closestPoint(p, maxDistance: 2.1), unlimited)
            XCTAssertNil(try mesh.closestPoint(p, maxDistance: 1.9))
            XCTAssertEqual(try mesh.closestPoint(p, maxDistance: nil), unlimited)
            XCTAssertEqual(try mesh.closestPoint(p, maxDistance: .nan), unlimited)
            XCTAssertEqual(try mesh.closestPoint(p, maxDistance: .infinity), unlimited)
        }
        let mesh = try meshOf(square, squareTriangles, [0, 0, 0])
        XCTAssertNotNil(try mesh.closestPoint([0.5, 0.5, 0], maxDistance: 0), "a point on the mesh is within 0")
        XCTAssertEqual(refusal { _ = try mesh.closestPoint([0.5, 0.5, 1], maxDistance: -1) },
                       "triangle_mesh_closest_point: the max distance must not be negative")
        XCTAssertEqual(refusal { _ = try mesh.closestPoint([.nan, 0, 0]) }, "triangle_mesh_closest_point: not finite")
    }

    func testALineThroughATetrahedronCrossesItsFloorFirst() throws {
        for s in shifts {
            let tol = scaled(s, 1e-9)
            let mesh = try meshOf(tetra, tetraTriangles, s)
            let line = try segment(s + [0.2, 0.2, -1], s + [0.2, 0.2, 2])
            let foot = try XCTUnwrap(try mesh.curveClosestPoints(line))
            XCTAssertTrue(foot.crossing)
            XCTAssertEqual(foot.distance, 0)
            XCTAssertEqual(foot.triangle, 0)
            XCTAssertEqual(foot.kind, "face")
            XCTAssertEqual(foot.vertices, [])
            XCTAssertEqual(foot.t, 1.0 / 3.0, accuracy: 1e-9)
            near3(foot.pointOnCurve, s + [0.2, 0.2, 0], tol, "on the curve at shift \(s)")
            near3(foot.pointOnMesh, s + [0.2, 0.2, 0], tol, "on the mesh at shift \(s)")
            near3(foot.barycentric, [0.6, 0.2, 0.2], 1e-9, "the floor's barycentric")

            let beside = try segment(s + [2, 0, 0], s + [3, 0, 0])
            let near = try XCTUnwrap(try mesh.curveClosestPoints(beside, maxDistance: 1.1))
            XCTAssertFalse(near.crossing)
            XCTAssertEqual(near.triangle, 0)
            XCTAssertEqual(near.kind, "vertex")
            XCTAssertEqual(near.vertices, [1])
            XCTAssertEqual(near.distance, 1, accuracy: tol)
            XCTAssertEqual(near.t, 0, accuracy: 1e-9)
            near3(near.pointOnMesh, s + [1, 0, 0], tol, "vertex 1 at shift \(s)")
            XCTAssertNil(try mesh.curveClosestPoints(beside, maxDistance: 0.9))
            XCTAssertEqual(try mesh.curveClosestPoints(beside), near)
            XCTAssertEqual(try mesh.curveClosestPoints(beside, maxDistance: .nan), near)
            XCTAssertEqual(try mesh.curveClosestPoints(beside, maxDistance: .infinity), near)
            XCTAssertEqual(refusal { _ = try mesh.curveClosestPoints(beside, maxDistance: -1) },
                           "triangle_mesh_curve_closest_points: the max distance must not be negative")
        }
    }

    func testATriangleMeshRefusesABadIndexAndAnswersNoMoreOnceClosed() throws {
        XCTAssertEqual(refusal { _ = try TriangleMesh(square, [(0, 1, 4)]) },
                       "triangle_mesh_new: triangle 0 names vertex 4, past the vertex count")
        let mesh = try meshOf(square, squareTriangles, [0, 0, 0])
        XCTAssertFalse(mesh.isClosed)
        mesh.close()
        mesh.close()
        XCTAssertTrue(mesh.isClosed)
        XCTAssertEqual(refusal { _ = try mesh.closestPoint([0, 0, 1]) }, "triangle_mesh: closed")
        let line = try segment([0, 0, 1], [1, 0, 1])
        XCTAssertEqual(refusal { _ = try line.closestObject([.mesh(mesh)]) }, "triangle_mesh: closed")
    }

    func testASolidsTriangleMeshIsItsMeasuringTessellation() throws {
        let cube = try Solid.cuboid(2, 2, 2)
        let mesh = try cube.triangleMesh()
        XCTAssertGreaterThanOrEqual(try mesh.triangleCount, 12)
        XCTAssertGreaterThanOrEqual(try mesh.vertexCount, 8)
        let box = try mesh.bounds
        near3(box.min, [-1, -1, -1], 1e-9, "the 2-cube's box, min")
        near3(box.max, [1, 1, 1], 1e-9, "the 2-cube's box, max")
        XCTAssertEqual(try cube.triangleMesh(tolerance: 0).triangleCount, try mesh.triangleCount, "0 is an unset tolerance")
        for bad in [-1.0, Double.infinity] {
            XCTAssertEqual(refusal { _ = try cube.triangleMesh(tolerance: bad) },
                           "solid_triangle_mesh: tolerance must be positive and finite")
        }
        cube.close()
        let foot = try XCTUnwrap(try mesh.closestPoint([5, 0.1, 0.2]))
        XCTAssertEqual(foot.distance, 4, accuracy: 1e-9)
        near3(foot.point, [1, 0.1, 0.2], 1e-9, "after the solid is closed")
    }

    func testTheNearestObjectToACurveTakesATriangleMesh() throws {
        let mesh = try meshOf(tetra, tetraTriangles, [0, 0, 0])
        let line = try segment([0.2, 0.2, -1], [0.2, 0.2, 2])
        let near = try XCTUnwrap(try line.closestObject([.point([9, 9, 9]), .mesh(mesh)]))
        let own = try XCTUnwrap(try mesh.curveClosestPoints(line))
        XCTAssertEqual(near.which, 1)
        XCTAssertEqual(near.distance, own.distance)
        XCTAssertEqual(near.t, own.t)
        XCTAssertEqual(near.pointOnCurve, own.pointOnCurve)
        XCTAssertEqual(near.pointOnItem, own.pointOnMesh)
        XCTAssertEqual(near.answer, .mesh(own))

        let beside = try segment([2, 0, 0], [3, 0, 0])
        let after = try XCTUnwrap(try beside.closestObject([.mesh(mesh), .point([2.5, 0.5, 0])]))
        XCTAssertEqual(after.which, 1)
        XCTAssertEqual(after.answer, .point)
        XCTAssertEqual(after.distance, 0.5, accuracy: 1e-9)

        // 1 from vertex 0 and from the point (0, 0, 0) alike: the earlier item answers.
        let short = try segment([-2, 0, 0], [-1, 0, 0])
        let tie = try XCTUnwrap(try short.closestObject([.mesh(mesh), .point([0, 0, 0])]))
        XCTAssertEqual(tie.which, 0)
        XCTAssertEqual(tie.distance, 1)
        guard case .mesh(let foot) = tie.answer else { return XCTFail("the tie answers \(tie.answer)") }
        XCTAssertEqual(foot.vertices, [0])
        let second = try XCTUnwrap(try short.closestObject([.point([0, 0, 0]), .mesh(mesh)]))
        XCTAssertEqual(second.which, 0)
        XCTAssertEqual(second.answer, .point)
        XCTAssertNil(try beside.closestObject([.mesh(mesh)], maxDistance: 0.9))
    }
}
