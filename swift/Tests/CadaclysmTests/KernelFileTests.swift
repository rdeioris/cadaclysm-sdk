// Solids from files: the kernel over the reader -- Solid.fromNode, open, openAll, toScene --
// as Python's test_cadaclysm_blacksmith.py tests them.
import Blacksmith
import CCadaclysmBlacksmith
import Cadaclysm
import Foundation
import XCTest

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../../crates/cadaclysm-acis/tests/fixtures/rhino").standardizedFileURL

private func plate() throws -> Solid {
    let outline = try Profile.rect(80, 40).withHole(try Profile.circle(4)).withHole(try Profile.slot([25, 0], 24, 5))
    return try Solid.extrude(outline, try Frame.xy(), 6)
}

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

private func assertSameBounds(_ a: Solid, _ b: Solid, file: StaticString = #filePath, line: UInt = #line) throws {
    let (alo, ahi) = try a.bounds, (blo, bhi) = try b.bounds
    for (p, q) in [(alo, blo), (ahi, bhi)] {
        let d = p - q
        XCTAssertLessThanOrEqual(Swift.max(abs(d.x), abs(d.y), abs(d.z)), 1e-6, "\(p) vs \(q)", file: file, line: line)
    }
}

final class KernelFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-files-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The plate written as STEP, and where.
    private func writtenPlate() throws -> (Solid, String) {
        let solid = try plate()
        let path = directory.appendingPathComponent("plate.stp").path
        try solid.step(path)
        return (solid, path)
    }

    func testAReadBodyIsASolidSharedWithTheScene() throws {
        let (original, path) = try writtenPlate()
        let scene = try Cadaclysm.open(path)
        let node = try XCTUnwrap(scene.placements.map { $0.geometry }.first { $0.brep != nil })
        let part = try Solid.fromNode(scene, node)
        XCTAssertEqual(try part.faces, try original.faces)
        try assertSameBounds(part, original)
        XCTAssertEqual(try Solid.fromNode(scene, node, placed: false).faces, try original.faces)
        // The same body by index, and the scene can go first: the brep lives on.
        let again = try Solid.fromNode(scene, node.index)
        scene.close()
        XCTAssertEqual(try again.faces, try original.faces)
        try assertSameBounds(again, original)
        XCTAssertTrue(try again.isWatertight() && again.manifold.isClosed)
        // A solid like any other: cut it, and write it back out.
        let cut = try part.cut(try Solid.cylinder(2, 20).translate(-30, 0, -5))
        XCTAssertGreaterThan(try cut.faces, try part.faces)
        XCTAssertTrue(try cut.stepText().hasPrefix("ISO-10303-21;"))
    }

    func testANodeWithNoBrepOrNoSuchIndexIsRefused() throws {
        // OpenSCAD is evaluated to triangles: a mesh, and no brep.
        let scene = try Cadaclysm.openMemory(Array("cube(10);".utf8), format: "scad")
        defer { scene.close() }
        let empty = try XCTUnwrap(scene.nodes.first { $0.brep == nil })
        let message = refusal { _ = try Solid.fromNode(scene, empty) } ?? ""
        XCTAssertTrue(message.hasPrefix("from_node: node \(empty.index) ("), message)
        XCTAssertTrue(message.contains("has no brep"), message)
        XCTAssertEqual(refusal { _ = try Solid.fromNode(scene, 9999) },
                       "from_node: no node 9999 -- the scene has \(scene.nodes.count)")
    }

    func testTheBrepLayoutIsCheckedBeforeTheBrepIsRead() throws {
        let (_, path) = try writtenPlate()
        let scene = try Cadaclysm.open(path)
        defer { scene.close() }
        let node = try XCTUnwrap(scene.placements.map { $0.geometry }.first { $0.brep != nil })
        let brep = try XCTUnwrap(node.brep)
        defer { brep.release() }
        XCTAssertNil(cadaclysm_blacksmith_from_brep(brep.pointer, "cadaclysm-brep 0.0.0 elsewhere"))
        let reason = String(cString: cadaclysm_blacksmith_last_error())
        XCTAssertTrue(reason.hasPrefix("from_brep: ") && reason.contains("same release"), reason)
        // The real handoff checks the reader's id against its own, and they agree.
        XCTAssertEqual(Brep.layoutId(), Blacksmith.brepLayoutId())
        XCTAssertTrue(Blacksmith.brepLayoutId().hasPrefix("cadaclysm-brep "))
    }

    func testOpenReadsAPartFileAsItsSolid() throws {
        let (original, path) = try writtenPlate()
        let part = try Solid.open(path)
        XCTAssertEqual(try part.faces, try original.faces)
        try assertSameBounds(part, original)
        XCTAssertEqual(try Solid.openAll(path).map { try $0.faces }, [try original.faces])
        let missing = directory.appendingPathComponent("missing.stp").path
        XCTAssertTrue(refusal { _ = try Solid.open(missing) }?.hasPrefix("open: ") ?? false)
        let mesh = directory.appendingPathComponent("cube.scad").path
        try "cube(10);".write(toFile: mesh, atomically: true, encoding: .utf8)
        XCTAssertTrue(refusal { _ = try Solid.openAll(mesh) }?.hasPrefix("open: the .scad file draws no B-rep body") ?? false)
    }

    func testAFileOfSeveralBodiesNeedsTheBodyNamed() throws {
        let one = try plate()
        let two = try Solid.cuboid(10, 10, 10).translate(200, 0, 0)
        let path = directory.appendingPathComponent("two.stp").path
        try Blacksmith.writeStep(path, [one, two])
        let solids = try Solid.openAll(path)
        XCTAssertEqual(solids.count, 2)
        XCTAssertEqual(refusal { _ = try Solid.open(path) },
                       "open: two.stp holds 2 bodies: pass body: (0 to 1), or use Solid.openAll")
        XCTAssertEqual(refusal { _ = try Solid.open(path, body: 99) }, "open: two.stp has no body 99: it holds 2")
        let second = try Solid.open(path, body: 1)
        try assertSameBounds(second, two)
        XCTAssertEqual(try second.faces, 6)
        // By index is the same node as by `Node`, body for body.
        let scene = try Cadaclysm.open(path)
        defer { scene.close() }
        let bodies = scene.nodes.filter { $0.brep != nil }
        XCTAssertGreaterThanOrEqual(bodies.count, 2)
        var faces: Set<Int> = []
        for node in bodies {
            let byIndex = try Solid.fromNode(scene, node.index)
            try assertSameBounds(byIndex, try Solid.fromNode(scene, node))
            faces.insert(try byIndex.faces)
        }
        XCTAssertEqual(faces, [try one.faces, 6])
    }

    func testEveryBodyIsWhereTheFileDrawsIt() throws {
        // One block placed four times -- as defined, rotated, scaled, mirrored -- which Rhino's
        // SAT export bakes into four bodies; the .3dm keeps the placements, and the scale is
        // one a brep cannot follow.
        let sat = fixtures.appendingPathComponent("block-instances.sat").path
        let rhino = fixtures.appendingPathComponent("block-instances.3dm").path
        guard FileManager.default.fileExists(atPath: sat), FileManager.default.fileExists(atPath: rhino) else {
            throw XCTSkip("block-instances fixtures are not to hand")
        }
        let solids = try Solid.openAll(sat)
        XCTAssertEqual(solids.count, 4)
        let centres = Set(try solids.map { s -> [Double] in
            let (lo, hi) = try s.bounds
            return [lo.x + hi.x, lo.y + hi.y, lo.z + hi.z].map { ($0 / 2 * 1e6).rounded() / 1e6 }
        })
        XCTAssertEqual(centres.count, 4, "each body where it is drawn")
        XCTAssertEqual(refusal { _ = try Solid.open(sat) }?.hasPrefix("open: block-instances.sat holds 4 bodies"), true)
        try assertSameBounds(try Solid.open(sat, body: 1), solids[1])
        let scaled = refusal { _ = try Solid.openAll(rhino) } ?? ""
        XCTAssertTrue(scaled.hasPrefix("open: ") && scaled.contains("scales or shears"), scaled)
        // Opened in another convention, a moved node's transform is not in the brep's axes.
        let step = fixtures.appendingPathComponent("block-instances.stp").path
        guard FileManager.default.fileExists(atPath: step) else { throw XCTSkip("block-instances.stp is not to hand") }
        let scene = try Cadaclysm.open(step, convention: .yUp)
        defer { scene.close() }
        let moved = try XCTUnwrap(scene.nodes.first { node in
            node.brep != nil && node.transform != (0..<4).map { i in (0..<4).map { j in i == j ? 1.0 : 0.0 } }
        })
        XCTAssertEqual(refusal { _ = try Solid.fromNode(scene, moved) }?.hasPrefix("from_node: placed=True needs"), true)
        XCTAssertGreaterThan(try Solid.fromNode(scene, moved, placed: false).faces, 0)
    }

    func testASolidGoesToTheReaderAsAScene() throws {
        let original = try plate()
        let scene = try original.toScene()
        defer { scene.close() }
        let node = try XCTUnwrap(scene.nodes.first { $0.brep != nil })
        XCTAssertTrue(node.canMesh)
        let back = try Solid.fromNode(scene, node)
        XCTAssertEqual(try back.faces, try original.faces)
        try assertSameBounds(back, original)
        let named = try original.toScene(schema: try Blacksmith.defaultSchema())
        defer { named.close() }
        XCTAssertTrue(named.nodes.contains { $0.canMesh })
    }
}
