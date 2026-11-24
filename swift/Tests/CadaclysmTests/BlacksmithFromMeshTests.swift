// A triangle mesh made a B-rep over the release library, as test_cadaclysm_blacksmith.py's from_mesh
// tests drive it: a unit cube's mesh merged and faceted, one triangle short, refused by name, read
// through the reader from a STEP cube's node, and a bored block's bore coming back a cylinder. The
// kernel's own correctness is the kernel's tests' job.
@testable import Blacksmith
import Cadaclysm
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

private let cubePositions: [SIMD3<Double>] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0], [0, 0, 1], [1, 0, 1], [1, 1, 1], [0, 1, 1]]
private let cubeTriangles: [(UInt32, UInt32, UInt32)] = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4), (1, 2, 6),
                                                         (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)]

final class BlacksmithFromMeshTests: XCTestCase {
    func testACubeIsAClosedSolidMergedOrFaceted() throws {
        let (cube, r) = try Solid.fromMesh(cubePositions, cubeTriangles)
        XCTAssertEqual(r, FromMeshReport(closed: true, faces: 6, edges: 12, vertices: 8, holes: 0, boundaryEdges: 0,
                                         nonManifoldEdges: 0, flipped: 0, dropped: 0, planes: 6, cylinders: 0, cones: 0,
                                         spheres: 0, tori: 0), "prismatic by default: no curved faces")
        XCTAssertEqual(try cube.faces, 6)
        XCTAssertEqual(try cube.edges.count, 12)
        let cubeMass: Mass = try cube.mass()
        XCTAssertEqual(cubeMass.volume, 1, accuracy: 1e-9)
        let (_, p) = try Solid.fromMesh(cubePositions, cubeTriangles, mode: .planes)
        XCTAssertTrue(p.closed)
        XCTAssertEqual([p.faces, p.edges, p.vertices, p.planes], [6, 12, 8, 6])
        let (faceted, f) = try Solid.fromMesh(cubePositions, cubeTriangles, angleTolerance: .nan, mode: .faceted)
        XCTAssertTrue(f.closed)
        XCTAssertEqual([f.faces, f.edges, f.vertices, f.planes], [12, 18, 8, 0])
        XCTAssertEqual(try faceted.faces, 12)
        let facetedMass: Mass = try faceted.mass()
        XCTAssertEqual(facetedMass.volume, 1, accuracy: 1e-9)
    }

    func testACubeMissingATriangleIsAnOpenShell() throws {
        let (sheet, r) = try Solid.fromMesh(cubePositions, Array(cubeTriangles.dropFirst()))
        XCTAssertFalse(r.closed)
        XCTAssertEqual([r.holes, r.boundaryEdges, r.nonManifoldEdges], [1, 3, 0])
        XCTAssertEqual(try sheet.faces, 6, "the open bottom is still one plane's face, less a triangle")
    }

    func testBadMeshesAreRefusedByName() throws {
        let none = refusal { _ = try Solid.fromMesh(cubePositions, []) }
        XCTAssertTrue(none?.hasPrefix("from_mesh: no triangles") ?? false, "\(String(describing: none))")
        let past = refusal { _ = try Solid.fromMesh(cubePositions, [(0, 1, 8)]) }
        XCTAssertTrue(past?.hasPrefix("from_mesh: a triangle index is out of range") ?? false, "\(String(describing: past))")
        let negative = refusal { _ = try Solid.fromMesh(cubePositions, cubeTriangles, weldTolerance: -1) }
        XCTAssertTrue(negative?.hasPrefix("from_mesh: a tolerance is negative") ?? false, "\(String(describing: negative))")
    }

    func testFromMeshNodeReadsANodesMeshThroughTheReader() throws {
        // The desktop reader library registers no STL reader: a STEP cube's tessellation, two
        // triangles a side, made back into a box.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("from-mesh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("cube.stp").path
        try Solid.cuboid(1, 1, 1).step(path)
        let scene = try Cadaclysm.open(path)
        let node = try XCTUnwrap(scene.nodes.first { $0.mesh64.indexCount > 0 }, "a node with triangles")
        let (cube, r) = try Solid.fromMeshNode(node)
        XCTAssertEqual([r.faces, r.edges], [6, 12])
        XCTAssertTrue(r.closed)
        let cubeMass: Mass = try cube.mass()
        XCTAssertEqual(cubeMass.volume, 1, accuracy: 1e-6)
        let (_, f) = try Solid.fromMeshNode(node, mode: .faceted)
        XCTAssertTrue(f.closed)
        XCTAssertEqual([f.faces, f.edges], [12, 18])
        let (_, p) = try Solid.fromMeshNode(node, mode: .planes)
        XCTAssertTrue(p.closed)
        XCTAssertEqual([p.faces, p.edges, p.planes], [6, 12, 6])
    }

    /// A 4 x 4 x 2 block less a radius-1 pin through it, meshed at 0.01 and converted in the
    /// default (prismatic) mode: the bore comes back as cylinder faces, the 6 sides as planes.
    func testABoredBlocksBoreComesBackACylinder() throws {
        let pin = try Solid.cylinder(1, 4).translate(0, 0, -2)
        let bored = try Solid.cuboid(4, 4, 2).cut(pin, tolerance: 1e-4)
        let mesh = try bored.mesh64(tolerance: 0.01)
        // Plain loops, each step its own statement: Swift 6.1 on Linux gave up type-checking the
        // same thing written as `map` closures indexing `3 * v + 1` within its time limit.
        let xyz: [Double] = Array(mesh.positions)
        let ids: [UInt32] = Array(mesh.indices)
        var positions: [SIMD3<Double>] = []
        var k: Int = 0
        while k + 2 < xyz.count {
            let x: Double = xyz[k]
            let y: Double = xyz[k + 1]
            let z: Double = xyz[k + 2]
            positions.append(SIMD3<Double>(x, y, z))
            k += 3
        }
        var triangles: [(UInt32, UInt32, UInt32)] = []
        k = 0
        while k + 2 < ids.count {
            let a: UInt32 = ids[k]
            let b: UInt32 = ids[k + 1]
            let c: UInt32 = ids[k + 2]
            triangles.append((a, b, c))
            k += 3
        }
        let (made, r) = try Solid.fromMesh(positions, triangles)
        XCTAssertTrue(r.closed, "\(r)")
        XCTAssertEqual(r.planes, 6, "\(r)")
        XCTAssertGreaterThanOrEqual(r.cylinders, 1, "the bore is a cylinder: \(r)")
        XCTAssertEqual(r.faces, 6 + r.cylinders, "\(r)")
        let mass: Mass = try made.mass()
        let exact: Double = 32.0 - 2.0 * Double.pi
        XCTAssertEqual(mass.volume, exact, accuracy: 0.01)
    }
}
