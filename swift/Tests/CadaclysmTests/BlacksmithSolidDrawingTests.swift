// A face's round radius and chamfer distance, the edges and isocurves as Beziers, and meshFile,
// at parity with the Python reference's test_a_face_tells_its_round_radius_and_chamfer_distance,
// test_edges_and_isocurves_come_as_beziers and test_mesh_file_writes_several_solids_in_each_format.
import Blacksmith
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

private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

final class BlacksmithSolidDrawingTests: XCTestCase {
    func testAFaceTellsItsRoundRadiusAndChamferDistance() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let vertical = try cube.edges.filter { e in
            guard e.isLine, let d = e.direction else { return false }
            return abs(d.z) > 0.99
        }
        XCTAssertEqual(vertical.count, 4)
        let rounded = try cube.fillet(vertical, 1.5)
        let radii = try (0..<rounded.faces).map { try rounded.faceRoundRadius($0) }
        XCTAssertEqual(Set(radii.map { ($0 * 1e9).rounded() / 1e9 }), [0, 1.5], "\(radii)")
        XCTAssertEqual(radii.filter { $0 != 0 }.count, 4, "one round a vertical edge")
        for f in 0..<(try rounded.faces) { XCTAssertEqual(try rounded.faceChamferDistance(f), 0) }
        let bevelled = try cube.chamfer(vertical, 2.0)
        let distances = try (0..<bevelled.faces).map { try bevelled.faceChamferDistance($0) }
        XCTAssertEqual(distances.filter { abs($0 - 2.0) < 1e-9 }.count, 4, "\(distances)")
        for f in 0..<(try bevelled.faces) { XCTAssertEqual(try bevelled.faceRoundRadius(f), 0) }
        XCTAssertTrue(refusal { _ = try cube.faceRoundRadius(6) }?.hasPrefix("face_round_radius: face 6 of 6") ?? false)
        XCTAssertTrue(refusal { _ = try cube.faceChamferDistance(6) }?.hasPrefix("face_chamfer_distance: face 6 of 6") ?? false)
    }

    func testEdgesAndIsocurvesComeAsBeziers() throws {
        let cube = try Solid.cuboid(2, 2, 2)
        let edges = try cube.edgeBeziers()
        XCTAssertEqual(edges.count, 12 * 16, "one straight Bezier an edge")
        XCTAssertTrue(stride(from: 3, to: edges.count, by: 4).allSatisfy { edges[$0] == 1.0 }, "a line's weights are one")
        XCTAssertEqual(try cube.isocurveBeziers(density: 4), [], "a flat face draws no isocurve")
        let cylinder = try Solid.cylinder(1, 3)
        let rings = try cylinder.isocurveBeziers(density: 3)
        XCTAssertTrue(rings.count > 0 && rings.count % 16 == 0)
        XCTAssertGreaterThan(try cylinder.isocurveBeziers(density: 6).count, rings.count, "a denser grid draws more lines")
        // A circle's Beziers are exact conics: some weight below one.
        let circles = try cylinder.edgeBeziers()
        XCTAssertTrue(stride(from: 3, to: circles.count, by: 4).contains { circles[$0] < 0.99 })
        let refused = refusal { _ = try cube.edgeBeziers(tolerance: -1) }
        XCTAssertTrue(refused?.contains("tolerance must be positive and finite") ?? false, refused ?? "no refusal")
    }

    func testMeshFileWritesSeveralSolidsInEachFormat() throws {
        let a = try Solid.cuboid(2, 2, 2)
        let b = try Solid.cuboid(1, 1, 1).translate(5, 0, 0)
        let stl = try meshFile([a, b], format: "stl")
        XCTAssertEqual(stl[80..<84].reversed().reduce(0) { $0 << 8 | Int($1) }, 24, "two boxes, twelve triangles each")
        XCTAssertEqual(stl.count, 84 + 50 * 24)
        let ascii = text(try meshFile([a, b], format: "stl-ascii", names: ["plate", "pin"]))
        XCTAssertTrue(ascii.hasPrefix("solid plate"))
        XCTAssertEqual(ascii.components(separatedBy: "facet normal").count - 1, 24)
        let obj = text(try meshFile([a, b], format: "obj", names: ["plate", "pin"]))
        XCTAssertTrue(obj.contains("o plate") && obj.contains("o pin"))
        let glb = try meshFile([a, b], format: "glb", looks: [[1, 0, 0, 1, 0, 0.5], [0, 0, 1, 0.5, 1, 0.2]])
        XCTAssertEqual(Array(glb.prefix(4)), Array("glTF".utf8))
        let gltf = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try meshFile([a, b], format: "gltf"))) as? [String: Any])
        let nodes = try XCTUnwrap(gltf["nodes"] as? [[String: Any]])
        XCTAssertEqual(nodes.compactMap { $0["name"] as? String }, ["Solid 1", "Solid 2"])
        XCTAssertTrue(refusal { _ = try meshFile([a], format: "step") }?.hasPrefix("mesh_file: format \"step\" is not one of") ?? false)
        XCTAssertTrue(refusal { _ = try meshFile([], format: "stl") }?.hasPrefix("mesh_file: no solids") ?? false)
        XCTAssertTrue(refusal { _ = try meshFile([a], format: "obj", names: ["a", "b"]) }?.contains("2 names for 1 solids") ?? false)
    }
}
