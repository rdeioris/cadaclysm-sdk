// The reader against the files this repository tracks: samples/cube.scad everywhere, and the
// fixtures under crates/ where the checkout has them (an SDK checkout does not; those tests
// skip). The expected figures were read through cadaclysm.py on the same library.
import Cadaclysm
import Foundation
import XCTest

/// The checkout root: the first directory above this file holding samples/cube.scad.
private let root: URL? = {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("samples/cube.scad").path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}()

private func sample(_ relative: String) throws -> String {
    guard let root = root else { throw XCTSkip("no samples/cube.scad above \(#filePath)") }
    let path = root.appendingPathComponent(relative).path
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("\(relative) is not in this checkout") }
    return path
}

private let cube = "samples/cube.scad"
private let blocks = "crates/cadaclysm-acis/tests/fixtures/rhino/block-instances.3dm"
private let attributed = "crates/cadaclysm-acis/tests/fixtures/fusion/attributed.stp"
private let assembly = "android/app/src/debug/assets/as1-ac-214.stp"
private let fusionAssembly = "crates/cadaclysm-acis/tests/fixtures/fusion/assembly.stp"

private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func scratch(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cadaclysm-swift-tests-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name).path
}

private func size(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
}

final class ReaderTests: XCTestCase {
    func testCubeTreeBoundsAndMesh() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        XCTAssertEqual(scene.nodes.count, 1)
        XCTAssertEqual(scene.roots.map(\.index), [0])
        XCTAssertEqual(scene.walk().map(\.index), [0])
        XCTAssertEqual(scene.bounds, Bounds(min: .zero, max: SIMD3(20, 20, 20)))
        XCTAssertEqual(scene.bounds.size, SIMD3(20, 20, 20))
        XCTAssertEqual(scene.bounds.centre, SIMD3(10, 10, 10))
        XCTAssertFalse(scene.bounds.isEmpty)
        XCTAssertEqual(scene.schema, "")
        XCTAssertEqual(scene.metresPerUnit, 1)
        XCTAssertNil(scene.sourceName)
        XCTAssertEqual(scene.diagnostics, [])
        XCTAssertEqual(scene.convention, .native)
        XCTAssertNil(scene.schemaPath)
        XCTAssertFalse(scene.substituted)
        XCTAssertEqual(scene.version, Cadaclysm.version())
        XCTAssertEqual(scene.surfaceMatrix.flatMap { $0 }, identity)

        let node = scene.roots[0]
        XCTAssertEqual(node.name, "cube")
        XCTAssertEqual(node.kind, "solid")
        XCTAssertEqual(node.label, "cube")
        XCTAssertEqual(node.generator, "csg")
        XCTAssertEqual(node.depth, 0)
        XCTAssertTrue(node.canMesh)
        XCTAssertTrue(node.visible)
        XCTAssertTrue(node.visibleNow)
        XCTAssertFalse(node.locked)
        XCTAssertNil(node.parent)
        XCTAssertNil(node.instanceOf)
        XCTAssertEqual(node.selectAs, node)
        XCTAssertEqual(node.children, [])
        XCTAssertNil(node.colour)
        XCTAssertEqual(node.rawTransform, identity)
        XCTAssertEqual(node.transform, [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]])
        XCTAssertEqual(node.bounds.max, SIMD3(20, 20, 20))

        let mesh = node.mesh
        XCTAssertEqual(mesh.vertexCount, 36)
        XCTAssertEqual(mesh.indexCount, 36)
        XCTAssertEqual(mesh.triangleCount, 12)
        XCTAssertFalse(mesh.isEmpty)
        XCTAssertEqual(mesh.positions.count, 36 * 3)
        XCTAssertEqual(mesh.normals?.count, 36 * 3)
        XCTAssertNil(mesh.uvs)
        XCTAssertNil(mesh.colors)
        XCTAssertEqual(mesh.indices.count, 36)
        let positions = Array(mesh.positions)
        XCTAssertEqual(positions.min(), 0)
        XCTAssertEqual(positions.max(), 20)
        XCTAssertEqual(mesh.indices.max(), 35)
        XCTAssertEqual(mesh.positions.withUnsafeBufferPointer { $0.reduce(0, +) }, positions.reduce(0, +))

        let edges = node.edges
        XCTAssertEqual(edges.polylineCount, 12)
        XCTAssertEqual(edges.vertexCount, 24)
        XCTAssertEqual(edges.segmentIndices().count, 24)
        XCTAssertEqual(edges.segments().count, 24 * 3)
        XCTAssertTrue(node.curves.isEmpty)
        XCTAssertEqual(node.isocurves.polylineCount, 12)
        XCTAssertTrue(node.surfaces.isEmpty)
        XCTAssertNil(node.brep)

        XCTAssertEqual(scene.placements.count, 1)
        XCTAssertEqual(scene.placements[0].geometry, node)
        XCTAssertEqual(scene.placements[0].select, node)
        XCTAssertEqual(scene.placements[0].rawTransform, identity)
    }

    func testOpenMemoryAgreesWithOpen() throws {
        let path = try sample(cube)
        let fromFile = try Cadaclysm.open(path)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let fromData = try Cadaclysm.openMemory(data, format: "scad")
        let fromBytes = try Cadaclysm.openMemory([UInt8](data), format: ".scad", name: "cube-bytes.scad")
        for scene in [fromData, fromBytes] {
            XCTAssertEqual(scene.bounds, fromFile.bounds)
            XCTAssertEqual(scene.nodes.count, fromFile.nodes.count)
            XCTAssertEqual(scene.nodes[0].name, fromFile.nodes[0].name)
            XCTAssertEqual(Array(scene.nodes[0].mesh.positions), Array(fromFile.nodes[0].mesh.positions))
            XCTAssertEqual(Array(scene.nodes[0].mesh.indices), Array(fromFile.nodes[0].mesh.indices))
        }
        XCTAssertEqual(fromData.path, "<memory>")
        XCTAssertEqual(fromBytes.path, "cube-bytes.scad")
        XCTAssertThrowsError(try Cadaclysm.openMemory(Data("not a model".utf8), format: "nope", name: "junk")) { error in
            XCTAssertTrue((error as? CadaclysmError)?.message.hasPrefix("junk: ") ?? false, "\(error)")
        }
    }

    func testQuery() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        XCTAssertEqual(try scene.query("geometry"), [0])
        XCTAssertEqual(try scene.query("name == nothing_is_called_this"), [])
        XCTAssertThrowsError(try scene.query("name ==")) { error in
            guard let error = error as? CadaclysmError else { return XCTFail("\(error)") }
            // The parser's own message and byte offset, behind the file's name.
            XCTAssertEqual(error.message, "cube.scad: expected a value (at byte 7)")
            XCTAssertEqual(error.description, error.message)
        }
    }

    func testAttributesAndValueKind() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        let attributes = scene.nodes[0].attributes
        XCTAssertEqual(attributes.map(\.name), ["alpha", "flat", "background"])
        XCTAssertEqual(attributes[0].kind, .real)
        XCTAssertEqual(attributes[0].value, .real(1))
        XCTAssertEqual(attributes[0].text, "1")
        XCTAssertEqual(attributes[1].kind, .boolean)
        XCTAssertEqual(attributes[1].value, .boolean(false))
        XCTAssertEqual(attributes[1].text, "false")

        XCTAssertEqual([ValueKind.none, .text, .integer, .real, .boolean, .list, .reference].map(\.rawValue),
                       Array(0...6))

        // Reals as Rust's Display writes them: shortest digits, never an exponent.
        let reals: [(Double, String)] = [(1e-5, "0.00001"), (1e16, "10000000000000000"), (0.1, "0.1"),
                                         (-0.0, "-0"), (0, "0"), (123.456, "123.456"), (-2.5e-7, "-0.00000025"),
                                         (1.5e20, "150000000000000000000"), (.infinity, "inf"),
                                         (-.infinity, "-inf"), (.nan, "NaN"), (100, "100")]
        for (real, expected) in reals {
            XCTAssertEqual(Attribute(name: "x", kind: .real, value: .real(real)).text, expected, "\(real)")
        }
        XCTAssertEqual(Attribute(name: "n", kind: .integer, value: .integer(-42)).text, "-42")
        XCTAssertEqual(Attribute(name: "n", kind: .none, value: nil).text, "")

        let step = try Cadaclysm.open(try sample(attributed))
        let housing = step.nodes[1]
        XCTAssertEqual(housing.name, "Housing body")
        let name = housing.attributes.first { $0.name == "name" }
        XCTAssertEqual(name?.kind, .text)
        // The file's string spans a line break, which git writes as CRLF in a Windows checkout
        // and LF elsewhere (the fixture is `text: auto`): compare the text, not the line ending.
        XCTAssertEqual(name?.text.replacingOccurrences(of: "\r\n", with: "\n"), "Корпус 部品 \nÜnïcødé")
        XCTAssertEqual(housing.attributes.first { $0.name == "id" }?.value, .text("P-2026-0913"))
    }

    func testPlacementsAndInstances() throws {
        let scene = try Cadaclysm.open(try sample(blocks))
        XCTAssertEqual(scene.nodes.count, 7)
        let placements = scene.placements
        XCTAssertEqual(placements.map(\.index), [0, 1, 2, 3])
        XCTAssertEqual(placements.map(\.geometry.index), [2, 2, 2, 2])
        XCTAssertEqual(placements.map(\.select.index), [3, 4, 5, 6])
        XCTAssertEqual(placements[0].rawTransform, identity)
        XCTAssertEqual(placements[1].rawTransform[12], 20)
        XCTAssertEqual(placements[1].transform[0][3], 20)
        XCTAssertEqual(placements[2].transform[1][3], 20)
        XCTAssertEqual(placements[2].transform[0][0], 1.5)
        XCTAssertEqual(placements[3].transform[0][0], -1)
        XCTAssertEqual(Set(placements).count, 4)

        let layer = scene.nodes[0]
        XCTAssertEqual(layer.name, "Default")
        XCTAssertEqual(layer.kind, "ON_Layer")
        XCTAssertFalse(layer.locked)
        XCTAssertEqual(layer.attributes.first { $0.name == "Visible" }?.value, .boolean(true))
        let instance = scene.nodes[3]
        XCTAssertEqual(instance.kind, "ON_InstanceRef")
        XCTAssertEqual(instance.instanceOf?.index, 1)
        XCTAssertEqual(instance.parent, layer)
        XCTAssertTrue(instance.visibleNow)
        XCTAssertEqual(instance.colour, SIMD4(0.8509804, 0.8509804, 0.8509804, 1))
        XCTAssertEqual(try scene.query("class == ON_Brep"), [2])

        let body = scene.nodes[2]
        XCTAssertEqual(body.mesh.vertexCount, 619)
        XCTAssertEqual(body.mesh.triangleCount, 1014)
        XCTAssertEqual(body.edges.polylineCount, 15)
        XCTAssertEqual(body.edges.segmentIndices().count, 218)
        let surfaces = body.surfaces
        XCTAssertEqual(surfaces.count, 7)
        XCTAssertEqual(surfaces[0].kind, 7)
        XCTAssertEqual(surfaces[0].loops.count, 1)
        XCTAssertEqual(surfaces[0].loops[0].count, 4 * 2)
        XCTAssertEqual(surfaces[0].nurbs.count, 28)
        XCTAssertEqual(surfaces[0].domain, SIMD4(0, 0, 10, 10))
        let brep = try XCTUnwrap(body.brep)
        let manifold = try brep.manifold
        XCTAssertEqual(manifold.faces, 7)
        XCTAssertEqual(manifold.edges, 15)
        XCTAssertEqual(manifold.vertices, 10)
        XCTAssertTrue(manifold.isManifold)
        XCTAssertTrue(manifold.isClosed)
    }

    func testStepPolylinesAndSurfaces() throws {
        let path = try sample(assembly)
        let scene = try Cadaclysm.open(path)
        XCTAssertEqual(scene.nodes.count, 22)
        XCTAssertEqual(scene.placements.count, 18)
        XCTAssertEqual(scene.schema, "AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }")
        XCTAssertEqual(scene.schemaRead, "AUTOMOTIVE_DESIGN")
        XCTAssertFalse(scene.substituted)
        XCTAssertEqual(try Cadaclysm.declaredSchema(path), scene.schema)
        XCTAssertEqual(scene.metresPerUnit, 0.001)
        XCTAssertEqual(scene.bounds, Bounds(min: SIMD3(-10, 0, -7), max: SIMD3(190, 150, 80)))
        XCTAssertEqual(try scene.query("geometry").prefix(5), [1, 3, 4, 6, 7])

        let plate = scene.nodes[1]
        XCTAssertEqual(plate.name, "ABSR1")
        XCTAssertEqual(plate.generator, "brep")
        XCTAssertEqual(plate.depth, 1)
        XCTAssertEqual(plate.colour, SIMD4(1, 0, 0, 1))
        XCTAssertEqual(plate.mesh.vertexCount, 2652)
        XCTAssertEqual(plate.mesh.triangleCount, 4092)
        let edges = plate.edges
        XCTAssertEqual(edges.polylineCount, 48)
        XCTAssertEqual(edges.vertexCount, 648)
        XCTAssertEqual(edges.segmentIndices().count, 1200)
        XCTAssertEqual(Int(edges.counts.reduce(0, +)), edges.vertexCount)
        XCTAssertEqual(plate.isocurves.polylineCount, 102)
        XCTAssertEqual(plate.isocurves.vertexCount, 384)
        XCTAssertTrue(plate.curves.isEmpty)
        let surfaces = plate.surfaces
        XCTAssertEqual(surfaces.faces.count, 18)
        XCTAssertEqual(surfaces[0].kind, 1)
        XCTAssertTrue(surfaces[0].reversed)
        XCTAssertEqual(surfaces[0].loops[0].count, 50 * 2)
        XCTAssertEqual(surfaces[0].nurbs.count, 0)
        XCTAssertEqual(scene.surfaceMatrix.flatMap { $0 }, identity)
        XCTAssertEqual(try XCTUnwrap(plate.brep).manifold.faces, 18)

        let bracket = scene.nodes[2]
        XCTAssertEqual(bracket.name, "L-BRACKET ASSEMBLY")
        XCTAssertEqual(bracket.children.map(\.index), [3, 4, 5])
        XCTAssertEqual(bracket.walk().map(\.index), Array(2...17))   // parents before children
        XCTAssertEqual(bracket.children[2].parent, bracket)
        XCTAssertEqual(scene.walk().count, scene.nodes.count)
    }

    func testSaveMeshAndSceneSave() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        let node = scene.nodes[0]
        let formats = Cadaclysm.meshFormats()
        XCTAssertTrue(formats.contains { $0.name == "stl-ascii" && $0.extension == "stl" }, "\(formats)")

        let stl = scratch("cube.stl")
        try node.saveMesh(stl)
        XCTAssertEqual(size(stl), 84 + 12 * 50)   // binary STL: header, count, 50 bytes a triangle
        let ascii = scratch("cube-ascii.stl")
        try node.saveMesh(ascii, format: "stl-ascii")
        XCTAssertGreaterThan(size(ascii), size(stl))
        XCTAssertThrowsError(try node.saveMesh(scratch("cube.nope"), format: "nope")) { error in
            XCTAssertFalse((error as? CadaclysmError)?.message.isEmpty ?? true)
        }

        let glb = scratch("cube.glb")
        try scene.save(glb)
        XCTAssertGreaterThan(size(glb), 0)
        let obj = scratch("cube.obj")
        try scene.save(obj, format: "obj")
        XCTAssertGreaterThan(size(obj), 0)
        XCTAssertThrowsError(try scene.save(scratch("cube.nope"), format: "nope"))
        XCTAssertTrue(try String(contentsOfFile: obj, encoding: .utf8).contains("\nf "))
    }

    func testSvg() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        let node = scene.nodes[0]

        let text = try scene.svgText()
        XCTAssertTrue(text.hasPrefix("<svg"))
        XCTAssertTrue(text.contains("<path"))

        let path = scratch("cube.svg")
        try scene.svg(path)
        XCTAssertGreaterThan(size(path), 0)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("<svg"))

        let nodeText = try node.svgText()
        XCTAssertTrue(nodeText.hasPrefix("<svg"))
        XCTAssertTrue(nodeText.contains("<path"))
        let nodePath = scratch("cube-node.svg")
        try node.svg(nodePath)
        XCTAssertGreaterThan(size(nodePath), 0)

        // A view, an explicit up and a background all reach the camera and the page: front and
        // top read differently, as do z-up and y-up, and a coloured background paints a rect.
        let front = try scene.svgText(SvgOptions(view: .front))
        let top = try scene.svgText(SvgOptions(view: .top))
        XCTAssertNotEqual(front, top)
        let zUp = try scene.svgText(SvgOptions(up: .z))
        let yUp = try scene.svgText(SvgOptions(up: .y))
        XCTAssertNotEqual(zUp, yUp)
        let painted = try scene.svgText(SvgOptions(background: 0xFF0000))
        XCTAssertTrue(painted.contains("fill=\"#ff0000\""), painted.prefix(300).description)

        // Refusals surface as the library's own words, thrown as a CadaclysmError.
        XCTAssertThrowsError(try scene.svgText(SvgOptions(fov: 200))) { error in
            XCTAssertTrue((error as? CadaclysmError)?.message.contains("fov") ?? false)
        }
        XCTAssertThrowsError(try scene.svgText(SvgOptions(margin: -1)))
        XCTAssertThrowsError(try node.svgText(SvgOptions(fov: 200)))
    }

    func testCopyOutlivesClose() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        let node = scene.nodes[0]
        let mesh = node.mesh
        let copy = mesh.copy()
        let edges = node.edges.positions.copy()
        let expected = Array(mesh.positions)
        let expectedIndices = Array(mesh.indices)
        let expectedEdges = Array(node.edges.positions)
        XCTAssertNil(mesh.positions.owner.nativeMemoryInvalidReason)

        XCTAssertFalse(scene.closed)
        scene.close()
        scene.close()   // idempotent
        XCTAssertTrue(scene.closed)
        XCTAssertEqual(scene.nativeMemoryInvalidReason, "the scene is closed")
        XCTAssertEqual(mesh.positions.owner.nativeMemoryInvalidReason, "the scene is closed")

        XCTAssertEqual(Array(copy.positions), expected)
        XCTAssertEqual(Array(copy.indices), expectedIndices)
        XCTAssertEqual(copy.normals?.count, 36 * 3)
        XCTAssertEqual(copy.triangleCount, 12)
        XCTAssertNil(copy.positions.owner.nativeMemoryInvalidReason)
        XCTAssertEqual(Array(edges), expectedEdges)
        XCTAssertEqual(node.description, "<Node 0 (scene closed)>")
        XCTAssertEqual(scene.description, "<Scene cube.scad (closed)>")

        // What throws anyway reports the closed scene rather than trapping.
        XCTAssertThrowsError(try scene.query("geometry")) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message, "cube.scad: the scene is closed")
        }
        XCTAssertThrowsError(try scene.save(scratch("closed.glb")))
        XCTAssertThrowsError(try node.saveMesh(scratch("closed.stl")))
    }

    func testBrepOutlivesSceneAndReleases() throws {
        let scene = try Cadaclysm.open(try sample(attributed))
        let brep = try XCTUnwrap(scene.nodes[1].brep)
        XCTAssertFalse(Cadaclysm.Brep.layoutId().isEmpty)
        XCTAssertFalse(brep.released)
        _ = brep.pointer
        scene.close()
        XCTAssertEqual(try brep.manifold.faces, 6)   // the brep lives past the scene's close
        brep.release()
        brep.release()
        XCTAssertTrue(brep.released)
        XCTAssertThrowsError(try brep.manifold) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message, "brep: released")
        }
    }

    func testNodeFromSceneAndIndex() throws {
        let scene = try Cadaclysm.open(try sample(assembly))
        for index in try scene.query("geometry") {
            let node = Node(scene, index)
            XCTAssertEqual(node.index, index)
            XCTAssertEqual(node, scene.nodes[index])
            XCTAssertTrue(node.canMesh)
        }
        XCTAssertEqual(Set(scene.nodes + scene.nodes).count, 22)
        let other = try Cadaclysm.open(try sample(assembly))
        XCTAssertNotEqual(Node(scene, 1), Node(other, 1))
        XCTAssertEqual(Node(scene, 1).description, "<Node 1 ABSR1>")
    }

    func testConventionParse() throws {
        XCTAssertEqual(try Convention.parse("unreal"), .unreal)
        XCTAssertEqual(try Convention.parse("  Unreal+File-Units "), .unreal | .fileUnits)
        XCTAssertEqual(try Convention.parse("unreal+file-units").rawValue, 0x101)
        XCTAssertEqual(try Convention.parse("y-up"), .yUp)
        XCTAssertEqual(try Convention.parse("blender+"), .blender)
        XCTAssertEqual((Convention.unity | .fileUnits | .uvWorld).description, "unity+file-units+uv-world")
        for name in ["native", "unreal", "unity", "y-up", "blender", "unreal+file-units"] {
            XCTAssertEqual(try Convention.parse(name).description, name)
        }
        XCTAssertThrowsError(try Convention.parse("zup")) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message,
                           "no convention called 'zup': native, unreal, unity, y-up or blender")
        }
        XCTAssertThrowsError(try Convention.parse("unreal+metres")) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message, "no convention flag called 'metres': file-units")
        }

        // Z up to Y up swaps the cube's axes; a 20-unit cube in 1 m units stays 20 across.
        let scene = try Cadaclysm.open(try sample(cube), convention: .yUp | .uvWorld)
        XCTAssertEqual(scene.convention, .yUp | .uvWorld)
        XCTAssertEqual(scene.bounds.size, SIMD3(20, 20, 20))
        let unreal = try Cadaclysm.open(try sample(cube), convention: .unreal)
        XCTAssertEqual(unreal.bounds.size, SIMD3(2000, 2000, 2000))   // metres to centimetres
    }

    func testOpeningMissingFiles() throws {
        XCTAssertThrowsError(try Cadaclysm.open("definitely/not/here.step")) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message, "definitely/not/here.step: no such file")
        }
        XCTAssertThrowsError(try Cadaclysm.declaredSchema("definitely/not/here.step"))
        let path = try sample(cube)
        XCTAssertEqual(try Cadaclysm.declaredSchema(path), "")
        XCTAssertThrowsError(try Cadaclysm.resolveSchema(path, schema: "definitely/not/here.exp")) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message,
                           "schema definitely/not/here.exp is neither a file nor a directory")
        }
        let none = try Cadaclysm.resolveSchema(path, schema: nil)
        XCTAssertNil(none.chosen)
        XCTAssertEqual(none.fallbacks, [])
        XCTAssertThrowsError(try Cadaclysm.open(path, schema: "definitely/not/here.exp"))
    }

    func testModuleFunctions() {
        XCTAssertFalse(Cadaclysm.version().isEmpty)
        XCTAssertNotNil(Cadaclysm.buildDate().range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression))
        XCTAssertFalse(Cadaclysm.licenseInfo().isEmpty)
        XCTAssertGreaterThanOrEqual(Cadaclysm.licenseNoticeCount(), 0)
        XCTAssertThrowsError(try Cadaclysm.license("not a licence at all")) { error in
            XCTAssertFalse((error as? CadaclysmError)?.message.isEmpty ?? true)
        }
    }

    func testRealizeAll() throws {
        let scene = try Cadaclysm.open(try sample(assembly))
        XCTAssertEqual(scene.realizeTotal, 0)
        XCTAssertGreaterThan(scene.realizeAll(), 0)
        XCTAssertEqual(scene.realized, scene.realizeTotal)
        scene.cancel()
        XCTAssertEqual(scene.realizeAll(), 0)   // one-way for the life of the scene
    }

    func testFormatsAndLabels() {
        let iges = formats().first { $0.name == "IGES" }
        XCTAssertEqual(iges?.extensions, ["iges", "igs"])
        XCTAssertEqual(meshFormats().first { $0.name == "stl" }?.label, "STL (binary)")
        XCTAssertEqual(meshFormats().first { $0.name == "stl-ascii" }?.extension, "stl")
    }

    func testGeometryDiagnosticsAndForgetMeshes() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        XCTAssertEqual(scene.geometryDiagnostics, [])
        XCTAssertEqual(scene.nodes[0].mesh.triangleCount, 12)
        scene.forgetMeshes()
        XCTAssertEqual(scene.nodes[0].mesh.triangleCount, 12)
    }

    func testLodAndBeziers() throws {
        XCTAssertEqual(lodLevels(), 3)
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.nodes[0]
        XCTAssertEqual(node.meshLod(0).triangleCount, node.mesh.triangleCount)
        XCTAssertEqual(node.meshLod(1).triangleCount, 3)
        XCTAssertEqual(node.meshLod(1).vertexCount, node.mesh.vertexCount)
        XCTAssertTrue(node.meshLod(4).isEmpty)
        XCTAssertEqual(node.lodError(0), 0)
        XCTAssertGreaterThan(node.lodError(1), 0)
        XCTAssertEqual(node.edgeBeziers.count, 12)
        XCTAssertEqual(node.edgeBeziers.points.count, 12 * 12)
        XCTAssertEqual(node.edgeBeziers.weights.count, 12 * 4)
        XCTAssertTrue(node.curveBeziers.isEmpty)
        XCTAssertEqual(node.isocurveBeziers.count, 12)
    }

    func testCollision() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.nodes[0]
        let fit = try XCTUnwrap(node.collision())
        XCTAssertEqual(fit.error, 0)
        XCTAssertEqual(fit.frame.count, 16)
        XCTAssertEqual(fit.hullVertexCount, 8)
        XCTAssertTrue(["box", "hull"].contains(fit.shapeName))
        let hull = node.collisionHull()
        XCTAssertEqual(hull.vertexCount, 8)
        XCTAssertEqual(hull.indices.count, 36)
        XCTAssertFalse(hull.isEmpty)
    }

    func testMeshlets() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let mesh = scene.nodes[0].mesh
        let meshlets = try Meshlets.build(positions: Array(mesh.positions), normals: mesh.normals.map(Array.init),
                                          indices: Array(mesh.indices), maxTriangles: 124, maxVertices: 64)
        XCTAssertEqual(meshlets.count, 1)
        let one = meshlets.meshlet(0)
        XCTAssertEqual(one.triangleCount, 12)
        XCTAssertEqual(one.vertexCount, 36)
        XCTAssertEqual(one.positions.count, 36 * 3)
        XCTAssertEqual(one.indices.count, 36)
        XCTAssertEqual(one.level, 0)
        XCTAssertEqual(one.children.count, 0)
        meshlets.free()
        XCTAssertTrue(meshlets.freed)
        meshlets.free()
        XCTAssertThrowsError(try Meshlets.build(positions: Array(mesh.positions), normals: nil, indices: Array(mesh.indices), maxTriangles: 0, maxVertices: 64))
    }

    func testMesh64Bounds64AndBeziers64AgreeWithF32OnSmallCoordinates() throws {
        // Catches curveBeziers64/isocurveBeziers64 wired to the wrong C call (e.g. curveBeziers64
        // calling cadaclysm_node_edge_beziers64): cube.scad's counts differ per kind (12 edge, 0
        // curve, 12 isocurve), and beziers64 is not covered by the far test below at all.
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.nodes[0]

        let mesh = node.mesh
        let mesh64 = node.mesh64
        XCTAssertEqual(mesh64.vertexCount, mesh.vertexCount)
        XCTAssertEqual(mesh64.indexCount, mesh.indexCount)
        XCTAssertEqual(mesh64.triangleCount, 12)
        XCTAssertEqual(Float(mesh64.positions[0]), mesh.positions[0], "the f32 mesh is the f64 one narrowed")
        XCTAssertEqual(Array(mesh64.indices), Array(mesh.indices))
        XCTAssertEqual(mesh64.normals?.count, mesh.normals?.count)
        XCTAssertNil(mesh64.uvs)
        XCTAssertNil(mesh64.colors)
        XCTAssertEqual(node.bounds64.max, node.bounds.max)
        XCTAssertEqual(scene.bounds64.max, scene.bounds.max)
        XCTAssertEqual(try node.boundsPlaced64().max, try node.boundsPlaced().max)

        let bz = node.edgeBeziers, bz64 = node.edgeBeziers64
        XCTAssertEqual(bz64.count, bz.count)
        XCTAssertEqual(Float(bz64.points[0]), bz.points[0])
        XCTAssertEqual(bz64.weights.count, bz.weights.count)
        XCTAssertEqual(node.curveBeziers64.count, node.curveBeziers.count)
        XCTAssertEqual(node.isocurveBeziers64.count, node.isocurveBeziers.count)
    }

    func testMesh64IsRebuiltAfterAForgetUnlikeMesh() throws {
        // mesh64's arrays borrow the document's own f64 mesh directly, which forgetMeshes
        // frees (see Node.mesh64's doc comment); mesh's arrays are a separate copy the
        // library keeps and forgetMeshes does not clear (an existing gap, out of scope).
        // Asking again after a forget must rebuild rather than answer from stale memory.
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.nodes[0]
        XCTAssertEqual(node.mesh64.triangleCount, 12)
        XCTAssertEqual(node.mesh.triangleCount, 12)
        scene.forgetMeshes()
        XCTAssertEqual(node.mesh64.triangleCount, 12, "mesh64 did not rebuild after a forget")
        XCTAssertEqual(node.mesh.triangleCount, 12)
    }

    func testMesh64AndBounds64KeepACoordinateFarFromTheOrigin() throws {
        // A cube at small coordinates cannot tell mesh64 from mesh widened -- both narrow
        // losslessly there. This catches mesh64 handing back mesh's float positions widened
        // (or bounds64 handing back bounds's) instead of the document's own double mesh.
        let scad = "translate([1000000.123456789, -2600000.987654321, 450.5]) cube(1);"
        let scene = try Cadaclysm.openMemory(Data(scad.utf8), format: "scad", name: "far.scad")
        defer { scene.close() }
        let node = scene.nodes[0]

        let mesh64 = node.mesh64
        let ys = (0..<mesh64.vertexCount).map { mesh64.positions[$0 * 3 + 1] }
        XCTAssertTrue(ys.contains { abs($0 - -2_600_000.987654321) < 1e-6 }, "\(ys)")
        XCTAssertTrue(ys.contains { abs(Double(Float($0)) - $0) > 1e-3 },
                     "mesh64 carries no coordinate float cannot hold, so this test cannot tell mesh64 from mesh widened")
        XCTAssertEqual(node.bounds64.min.y, -2_600_000.987654321, accuracy: 1e-6)
        XCTAssertEqual(scene.bounds64.min.y, -2_600_000.987654321, accuracy: 1e-6)
    }

    func testSurfacePathWithoutMeshing() throws {
        let scene = try Cadaclysm.open(try sample(fusionAssembly))
        defer { scene.close() }
        let bracket = scene.nodes[1], pin = scene.nodes[2]
        XCTAssertFalse(bracket.isMeshed)
        XCTAssertEqual(bracket.triangleEstimate, 18)
        XCTAssertEqual(pin.triangleEstimate, 480)
        XCTAssertEqual(bracket.surfaceEdges.polylineCount, 12)
        XCTAssertEqual(bracket.surfaceEdges.vertexCount, 24)
        XCTAssertTrue(bracket.surfaceIsocurves.isEmpty)
        XCTAssertEqual(pin.surfaceIsocurves.polylineCount, 3)
        let proxy = bracket.surfaceProxyMesh(cells: 4)
        XCTAssertEqual(proxy.vertexCount, 150)
        XCTAssertEqual(proxy.indexCount, 576)
        let hit = try XCTUnwrap(bracket.surfacePick(from: SIMD3(2, 1.5, 1002), to: SIMD3(2, 1.5, -998)))
        XCTAssertEqual(hit.x, 2, accuracy: 1e-9); XCTAssertEqual(hit.y, 1.5, accuracy: 1e-9); XCTAssertEqual(hit.z, 2, accuracy: 1e-9)
        XCTAssertNil(bracket.surfacePick(from: SIMD3(1e6, 1.5, 1002), to: SIMD3(1e6, 1.5, -998)))
        XCTAssertFalse(bracket.isMeshed)
        XCTAssertEqual(try bracket.boundsPlaced().max, SIMD3(4, 3, 2))
        XCTAssertEqual(try bracket.boundsPlaced(identity).max, SIMD3(4, 3, 2))
        XCTAssertThrowsError(try bracket.boundsPlaced([1, 0, 0]))
        XCTAssertEqual(scene.realizeMeshes(), 0)
        XCTAssertFalse(bracket.isMeshed)
        XCTAssertEqual(scene.realizeMeshes(skipSurfaced: false), 3)
        XCTAssertTrue(bracket.isMeshed)
    }
}
