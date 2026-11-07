// Wall thickness over the release library: Python's test_thickness_* and test_mesh_thickness_*,
// trimmed to what proves the marshalling -- every field read, the none mappings, every refusal's
// prefix, the copies. The kernel's own correctness is the kernel's tests' job.
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

private typealias P3 = SIMD3<Double>

private let lowerTriangle: (positions: [P3], triangles: [SIMD3<UInt32>]) =
    ([P3(0, 0, 0), P3(0, 1, 0), P3(1, 0, 0)], [SIMD3(0, 1, 2)])
private let upperTriangle: (positions: [P3], triangles: [SIMD3<UInt32>]) =
    ([P3(0, 0, 1), P3(1, 0, 1), P3(0, 1, 1)], [SIMD3(0, 1, 2)])

/// The face of body `body` whose reading at `p` lies at `p`.
private func faceHolding(_ gauge: ThicknessGauge, _ solid: Solid, _ body: Int, _ p: P3) throws -> Int {
    for f in 0..<(try solid.faces) {
        if let r = try gauge.thicknessAt(body: body, face: f, point: p, maximum: 100, sharpAngle: 0.5),
           abs(r.point.x - p.x) < 1e-9, abs(r.point.y - p.y) < 1e-9, abs(r.point.z - p.z) < 1e-9 {
            return f
        }
    }
    XCTFail("no face holds \(p)")
    return 0
}

private func tube() throws -> Solid {
    let ring = try Profile.circle(5).withHole(try Profile.circle(4))
    return try Solid.extrude(ring, try Frame.xy(), 10)
}

final class BlacksmithThicknessTests: XCTestCase {
    func testAPlateReadsTwoAtEveryCapVertex() throws {
        let plate = try Solid.cuboid(10, 10, 2)
        let g = try ThicknessGauge([plate])
        defer { g.close() }
        XCTAssertEqual(try g.count, 1)
        XCTAssertEqual(try g.tolerance, 0.01)
        let rows = try g.thickness(maximum: 10, sharpAngle: 0.5)
        let mesh = try g.mesh(body: 0)
        let caps = rows.filter { abs(abs($0.point.z) - 1) < 1e-9 && abs($0.opposite.z + $0.point.z) < 1e-9 }
        XCTAssertGreaterThanOrEqual(caps.count, 8)
        for r in caps {
            XCTAssertEqual(r.thickness, 2, accuracy: 1e-9)
            XCTAssertEqual(r.exactThickness, 2, accuracy: 1e-9)
            XCTAssertEqual(r.exactOpposite.z, -r.point.z, accuracy: 1e-9)
            XCTAssertFalse(r.knife)
            XCTAssertEqual(r.oppositeBody, 0)
        }
        for r in rows {
            XCTAssertEqual(r.body, 0)
            let v = try XCTUnwrap(r.vertex)
            XCTAssertEqual(mesh.positions[Int(v)], r.point)
        }
        // below the wall nothing reads; the sharp angle defaults to 0
        let second = try ThicknessGauge([plate], tolerance: 0.01)
        defer { second.close() }
        XCTAssertTrue(try second.thickness(maximum: 1).isEmpty)
        XCTAssertEqual(try second.thickness(maximum: 10).count, rows.count)
        XCTAssertTrue(rows[0].description.hasPrefix("Thickness(body=0, vertex="))
        XCTAssertEqual(g.description, "ThicknessGauge(bodies=1, tolerance=0.01)")
    }

    func testTheGaugeMeshIsACopyThatMatchesTheReadings() throws {
        let plate = try Solid.cuboid(10, 10, 2)
        let g = try ThicknessGauge([plate])
        let m = try g.mesh(body: 0)
        XCTAssertEqual(m.faces.count, m.triangles.count)
        XCTAssertGreaterThanOrEqual(m.triangles.count, 12)
        XCTAssertEqual(m.normals.count, m.positions.count)
        XCTAssertGreaterThan(m.positions.count, 0)
        for f in m.faces { XCTAssertLessThan(Int(f), try plate.faces) }
        for t in m.triangles { for k in [t.x, t.y, t.z] { XCTAssertLessThan(Int(k), m.positions.count) } }
        for n in m.normals { XCTAssertEqual((n * n).sum().squareRoot(), 1, accuracy: 1e-9) }
        let rows = try g.thickness(maximum: 100, sharpAngle: 0.5)
        XCTAssertEqual(rows.count, m.positions.count)
        for r in rows {
            let v = try XCTUnwrap(r.vertex)
            let t = try XCTUnwrap(m.triangles.firstIndex { $0.x == v || $0.y == v || $0.z == v })
            XCTAssertEqual(m.faces[t], r.face)
        }
        XCTAssertEqual(refusal { _ = try g.mesh(body: 1) }, "thickness_gauge_mesh: no body 1 -- there are 1")
        g.close()
        // copied out: the mesh outlives the gauge, which refuses once closed
        XCTAssertEqual(m.positions.count, rows.count)
        XCTAssertEqual(refusal { _ = try g.mesh(body: 0) }, "thickness_gauge: closed")
        XCTAssertEqual(m.description, "ThicknessMesh(vertices=\(m.positions.count), triangles=\(m.triangles.count))")
    }

    func testAPointReadsOneRowWithNoVertex() throws {
        let plate = try Solid.cuboid(10, 10, 2)
        let probe = P3(1, 2, 1)
        let g = try ThicknessGauge([plate])
        defer { g.close() }
        let top = try faceHolding(g, plate, 0, probe)
        let r = try XCTUnwrap(try g.thicknessAt(body: 0, face: top, point: probe, maximum: 100, sharpAngle: 0.5))
        XCTAssertNil(r.vertex)
        XCTAssertEqual(r.body, 0)
        XCTAssertEqual(Int(r.face), top)
        XCTAssertEqual(r.oppositeBody, 0)
        XCTAssertEqual(r.point, probe)
        XCTAssertEqual(r.thickness, 2, accuracy: 1e-9)
        XCTAssertEqual(r.exactThickness, 2, accuracy: 1e-9)
        XCTAssertEqual(r.opposite.z, -1, accuracy: 1e-9)
        XCTAssertEqual(r.exactOpposite.z, -1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(r.sphere), 2, accuracy: 0.02)
        // thicker than the maximum: nil
        XCTAssertNil(try g.thicknessAt(body: 0, face: top, point: probe, maximum: 1, sharpAngle: 0.5))
        let plain = try XCTUnwrap(try g.thicknessAt(body: 0, face: top, point: probe, maximum: 100))
        XCTAssertEqual(plain.thickness, r.thickness)
    }

    func testAtFaceReadsThePlateAndNilWhereNothingIsFound() throws {
        let plate = try Solid.cuboid(10, 10, 2)
        let g = try ThicknessGauge([plate])
        defer { g.close() }
        let top = try faceHolding(g, plate, 0, P3(1, 2, 1))
        let f = try XCTUnwrap(try g.thicknessAtFace(body: 0, face: top, maximum: 100))
        XCTAssertEqual(f.thickness, 2, accuracy: 1e-9)
        XCTAssertTrue(f.uniform)
        XCTAssertEqual(f.min, 2, accuracy: 1e-9)
        XCTAssertEqual(f.max, 2, accuracy: 1e-9)
        let a = try XCTUnwrap(try g.thicknessAtFace(body: 0, face: top, at: P3(1, 2, 5), maximum: 100))
        XCTAssertEqual(a.thickness, 2, accuracy: 1e-9)
        XCTAssertEqual(a.min, a.max)
        XCTAssertTrue(a.uniform)
        // not found: under the maximum, and off the face
        XCTAssertNil(try g.thicknessAtFace(body: 0, face: top, maximum: 1))
        XCTAssertNil(try g.thicknessAtFace(body: 0, face: top, at: P3(50, 2, 5), maximum: 100))
        // the one-body convenience: a gauge of its own
        let s = try XCTUnwrap(try plate.thicknessAtFace(top, maximum: 100))
        XCTAssertEqual(s.thickness, 2, accuracy: 1e-9)
        XCTAssertTrue(s.uniform)
        let sa = try XCTUnwrap(try plate.thicknessAtFace(top, at: P3(1, 2, 5), maximum: 100, tolerance: 0.05))
        XCTAssertEqual(sa.thickness, 2, accuracy: 1e-9)
        XCTAssertNil(try plate.thicknessAtFace(top, maximum: 1))
        XCTAssertTrue(s.description.hasPrefix("FaceThickness(thickness=2"))
    }

    func testABallPastTheMaximumIsNil() throws {
        let wedge = try Solid.extrude(try Profile.polygon([SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 10)]),
                                      try Frame.xy(), 20)
        let probe = P3(5, 0, 10)
        let g = try ThicknessGauge([wedge])
        defer { g.close() }
        let f = try faceHolding(g, wedge, 0, probe)
        let wide = try XCTUnwrap(try g.thicknessAt(body: 0, face: f, point: probe, maximum: 100, sharpAngle: 0.5))
        let inscribed: Double = 10 / (1 + 2.0.squareRoot())   // 2 x 5 / (1 + sqrt 2)
        XCTAssertEqual(try XCTUnwrap(wide.sphere), inscribed, accuracy: 0.01)
        let narrow = try XCTUnwrap(try g.thicknessAt(body: 0, face: f, point: probe, maximum: 4, sharpAngle: 0.5))
        XCTAssertEqual(narrow.thickness, 5 / 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertNil(narrow.sphere)
    }

    func testTwoBodiesReadEachOtherAndTheOneShotAgrees() throws {
        let slab = try Solid.extrude(try Profile.polygon([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 3), SIMD2(0, 1)]),
                                     try Frame.xy(), 4)
        let pipe = try tube()
        let g = try ThicknessGauge([slab, pipe])
        defer { g.close() }
        XCTAssertEqual(try g.count, 2)
        let via = try g.thickness(maximum: 100, sharpAngle: 0.5)
        let one = try thickness([slab, pipe], maximum: 100, sharpAngle: 0.5)
        XCTAssertEqual(one.count, via.count)
        for (a, b) in zip(one, via) {
            XCTAssertEqual(a.body, b.body)
            XCTAssertEqual(a.vertex, b.vertex)
            XCTAssertEqual(a.face, b.face)
            XCTAssertEqual(a.thickness, b.thickness)
            XCTAssertEqual(a.oppositeBody, b.oppositeBody)
        }
        XCTAssertTrue(one.contains { $0.body == 0 && $0.oppositeBody == 1 }, "the slab reads the tube somewhere")
        XCTAssertTrue(one.contains { $0.body == 1 && $0.oppositeBody == 0 }, "the tube reads the slab somewhere")
        XCTAssertTrue(try thickness([slab], maximum: 0.001).isEmpty)
        XCTAssertGreaterThan(try thickness([slab], maximum: 100, tolerance: 0.05).count, 0)
        // an empty gauge has no bodies and no readings
        let empty = try ThicknessGauge([])
        defer { empty.close() }
        XCTAssertEqual(try empty.count, 0)
        XCTAssertTrue(try empty.thickness(maximum: 10).isEmpty)
    }

    func testTwoTrianglesOneApartReadOneAcross() throws {
        let meshes = [lowerTriangle, upperTriangle]
        let rows = try meshThickness(meshes, maximum: 10, sharpAngle: 0.5)
        XCTAssertEqual(rows.count, 6)
        for r in rows {
            XCTAssertEqual(r.thickness, 1, accuracy: 1e-12)
            XCTAssertFalse(r.knife)
            XCTAssertEqual(r.oppositeMesh, 1 - r.mesh)
            XCTAssertEqual(r.oppositeTriangle, 0)
            XCTAssertEqual(r.point, meshes[Int(r.mesh)].positions[Int(r.vertex)])
            XCTAssertEqual(r.opposite.z, 1 - r.point.z, accuracy: 1e-12)
            XCTAssertEqual(r.opposite.x, r.point.x)
            XCTAssertEqual(r.opposite.y, r.point.y)
        }
        XCTAssertEqual(rows.map { [$0.mesh, $0.vertex] }, [[0, 0], [0, 1], [0, 2], [1, 0], [1, 1], [1, 2]])
        // under the gap nothing; no meshes at all, nothing
        XCTAssertTrue(try meshThickness(meshes, maximum: 0.5, sharpAngle: 0.5).isEmpty)
        XCTAssertTrue(try meshThickness([], maximum: 1).isEmpty)
        XCTAssertEqual(try meshThickness(meshes, maximum: 10).count, 6)
        XCTAssertTrue(rows[0].description.hasPrefix("MeshThickness(mesh=0, vertex=0"))
    }

    func testRefusalsCarryTheCallsPrefix() throws {
        let plate = try Solid.cuboid(10, 10, 2)
        XCTAssertTrue(refusal { _ = try ThicknessGauge([plate], tolerance: -1) }?
            .hasPrefix("thickness_gauge_new: the tolerance must be positive and finite") ?? false)
        let g = try ThicknessGauge([plate])
        XCTAssertTrue(refusal { _ = try g.thickness(maximum: 0) }?
            .hasPrefix("thickness_gauge_measure: the maximum must be positive and finite") ?? false)
        XCTAssertTrue(refusal { _ = try g.thickness(maximum: 10, sharpAngle: -0.1) }?
            .hasPrefix("thickness_gauge_measure: the sharp angle must be zero or positive and finite") ?? false)
        XCTAssertEqual(refusal { _ = try g.thicknessAt(body: 3, face: 0, point: P3(1, 2, 1), maximum: 10) },
                       "thickness_gauge_at: no body 3 -- there are 1")
        XCTAssertEqual(refusal { _ = try g.thicknessAt(body: 0, face: 99, point: P3(1, 2, 1), maximum: 10) },
                       "thickness_gauge_at: no face 99 -- the solid has 6 (0 to 5)")
        XCTAssertTrue(refusal { _ = try g.thicknessAt(body: 0, face: 0, point: P3(1, .nan, 1), maximum: 10) }?
            .hasPrefix("thickness_gauge_at: the point must be finite") ?? false)
        XCTAssertTrue(refusal { _ = try g.thicknessAt(body: -1, face: 0, point: P3(1, 2, 1), maximum: 10) }?
            .hasPrefix("thickness_gauge_at: ") ?? false)
        XCTAssertEqual(refusal { _ = try g.thicknessAtFace(body: 2, face: 0, maximum: 10) },
                       "thickness_gauge_face: no body 2 -- there are 1")
        XCTAssertEqual(refusal { _ = try g.thicknessAtFace(body: 0, face: 99, maximum: 10) },
                       "thickness_gauge_face: no face 99 -- the solid has 6 (0 to 5)")
        XCTAssertTrue(refusal { _ = try g.thicknessAtFace(body: 0, face: 0, at: P3(.infinity, 0, 1), maximum: 10) }?
            .hasPrefix("thickness_gauge_face: the point must be finite") ?? false)
        XCTAssertTrue(refusal { _ = try g.thicknessAtFace(body: 0, face: 0, maximum: 0) }?
            .hasPrefix("thickness_gauge_face: the maximum must be positive and finite") ?? false)
        XCTAssertFalse(g.isClosed)
        g.close()
        g.close()  // twice is a no-op
        XCTAssertTrue(g.isClosed)
        XCTAssertEqual(g.description, "ThicknessGauge(closed)")
        XCTAssertEqual(refusal { _ = try g.thickness(maximum: 10) }, "thickness_gauge: closed")
        XCTAssertEqual(refusal { _ = try g.count }, "thickness_gauge: closed")
        // the conveniences refuse with the gauge call's own prefix
        XCTAssertTrue(refusal { _ = try thickness([plate], maximum: -1) }?
            .hasPrefix("thickness_gauge_measure: the maximum must be positive and finite") ?? false)
        XCTAssertTrue(refusal { _ = try thickness([plate], maximum: 10, tolerance: .infinity) }?
            .hasPrefix("thickness_gauge_new: the tolerance must be positive and finite") ?? false)
        XCTAssertTrue(refusal { _ = try plate.thicknessAtFace(99, maximum: 10) }?
            .hasPrefix("thickness_gauge_face: no face 99") ?? false)
        // meshThickness: the kernel's refusals
        let meshes = [lowerTriangle, upperTriangle]
        XCTAssertTrue(refusal { _ = try meshThickness(meshes, maximum: 0) }?
            .hasPrefix("mesh_thickness: the maximum must be positive and finite") ?? false)
        XCTAssertTrue(refusal { _ = try meshThickness(meshes, maximum: 10, sharpAngle: -0.5) }?
            .hasPrefix("mesh_thickness: the sharp angle must be zero or positive and finite") ?? false)
        let short: [(positions: [P3], triangles: [SIMD3<UInt32>])] = [([P3(0, 0, 0), P3(1, 0, 0)], [SIMD3(0, 1, 2)])]
        XCTAssertTrue(refusal { _ = try meshThickness(short, maximum: 10) }?
            .hasPrefix("mesh_thickness: a triangle names a position past the mesh") ?? false)
        let nan: [(positions: [P3], triangles: [SIMD3<UInt32>])] =
            [([P3(0, 0, 0), P3(1, .nan, 0), P3(0, 1, 0)], [SIMD3(0, 1, 2)])]
        XCTAssertTrue(refusal { _ = try meshThickness(nan, maximum: 10) }?
            .hasPrefix("mesh_thickness: a mesh position is not finite") ?? false)
    }
}
