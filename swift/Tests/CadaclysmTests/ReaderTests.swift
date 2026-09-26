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
private let mechanism = "samples/mechanism.stp"
private let openSheet = "samples/open-sheet.scad"
private let blocks = "crates/cadaclysm-acis/tests/fixtures/rhino/block-instances.3dm"
private let attributed = "crates/cadaclysm-acis/tests/fixtures/fusion/attributed.stp"
private let assembly = "android/app/src/debug/assets/as1-ac-214.stp"
private let fusionAssembly = "crates/cadaclysm-acis/tests/fixtures/fusion/assembly.stp"
private let extrusions = "crates/cadaclysm-acis/tests/fixtures/rhino/extrusion-objects.3dm"

private let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func scratch(_ name: String) -> String {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cadaclysm-swift-tests-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name).path
}

private func size(_ path: String) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
}

// ---- the FEM placement, shared with KernelTests ---------------------------------------------
//
// One transform, written both ways, so the reader's sixteen and the kernel's twelve are checked
// against the same expected map -- which makes that asymmetry something these tests prove
// rather than something they only say. A quarter turn about z, then 100 along x:
//
//     [ 0 -1  0 100 ]
//     [ 1  0  0   0 ]      so (x, y, z) -> (100 - y, x, z)
//     [ 0  0  1   0 ]
//     [ 0  0  0   1 ]
//
// **A rotation is only informative about a body that is not symmetric under it.** Transposing
// the 3x3 block composes this with a 180-degree turn about z through the placement's own origin,
// so a body whose centre lands on that axis maps onto itself. The condition is on x and y alone:
// Task 4 measured an offset of (0, 0, 5) -- off the origin, purely along the axis -- leaving the
// transposed placement passing at exit 0, and (30, 7, 5) catching it. Every user of these
// helpers puts its body off the axis in x or y for that reason.

/// The reader's sixteen, column-major: column 0 is where x goes, column 3 the translation.
let turnedMatrix: [Double] = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1]

/// Where `turnedMatrix` (and the kernel's `Frame(origin: (100,0,0), x: (0,1,0), y: (-1,0,0),
/// z: (0,0,1))`) puts a point.
func turned(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(100 - p.y, p.x, p.z) }

func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-9) -> Bool {
    Swift.max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) <= tolerance
}

/// A FEM mesh's flat `nodes` as points.
func points(_ nodes: NativeArray<Double>) -> [SIMD3<Double>] {
    stride(from: 0, to: nodes.count, by: 3).map { SIMD3(nodes[$0], nodes[$0 + 1], nodes[$0 + 2]) }
}

/// The box the nodes span.
func span(_ nodes: NativeArray<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
    var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
    for p in points(nodes) {
        lo = SIMD3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
        hi = SIMD3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
    }
    return (lo, hi)
}

/// The eight corners of the box `lo`..`hi`.
func corners(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> [SIMD3<Double>] {
    [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { z in SIMD3(x, y, z) } } }
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
        // 18 bodies and 10 containers: the root, two L-bracket assemblies, six nut-bolt
        // assemblies and the rod assembly -- one container per placement, not per product.
        XCTAssertEqual(scene.nodes.count, 28)
        XCTAssertEqual(scene.placements.count, 18)
        XCTAssertEqual(scene.schema, "AUTOMOTIVE_DESIGN { 1 2 10303 214 0 1 1 1 }")
        XCTAssertEqual(scene.schemaRead, "AUTOMOTIVE_DESIGN")
        XCTAssertFalse(scene.substituted)
        XCTAssertEqual(try Cadaclysm.declaredSchema(path), scene.schema)
        XCTAssertEqual(scene.metresPerUnit, 0.001)
        XCTAssertEqual(scene.bounds, Bounds(min: SIMD3(-10, 0, -7), max: SIMD3(190, 150, 80)))
        XCTAssertEqual(try scene.query("geometry").prefix(5), [1, 3, 5, 7, 9])

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
        XCTAssertEqual(bracket.children.map(\.index), [3, 6, 10, 14])   // its L-bracket, then three nut-bolt assemblies
        XCTAssertEqual(bracket.walk().map(\.index), [2, 3, 6, 7, 18, 10, 11, 20, 14, 15, 22])   // parents before children
        XCTAssertEqual(scene.nodes[4].name, "L-BRACKET ASSEMBLY")   // the second placement is a node of its own
        XCTAssertEqual(scene.nodes[6].children.map(\.name), ["ABSR3", "ABSR4"])   // one bolt, one nut
        XCTAssertEqual(bracket.children[2].parent, bracket)
        XCTAssertEqual(scene.nodes[4].name, "L-BRACKET ASSEMBLY")   // the second placement is a node of its own
        XCTAssertEqual(scene.nodes[6].children.map(\.name), ["ABSR3", "ABSR4"])   // one bolt, one nut
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
        XCTAssertEqual(Set(scene.nodes + scene.nodes).count, 28)
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

    /// The mechanism facts, identical in every language: two links `base` and `arm`, each
    /// naming one node of the same name; one joint `hinge` from `arm` (index 1) to `base`
    /// (index 0).
    func testMechanismLinksAndJoints() throws {
        let scene = try Cadaclysm.open(try sample(mechanism))
        defer { scene.close() }
        let links = scene.links
        XCTAssertEqual(links.map(\.name), ["base", "arm"])
        for link in links {
            XCTAssertEqual(link.nodes.count, 1)
            XCTAssertEqual(link.nodes[0].name, link.name)
        }
        let joints = scene.joints
        XCTAssertEqual(joints.count, 1)
        let hinge = joints[0]
        XCTAssertEqual(hinge.name, "hinge")
        XCTAssertEqual(hinge.start.name, "arm")
        XCTAssertEqual(hinge.start.index, 1)
        XCTAssertEqual(hinge.end.name, "base")
        XCTAssertEqual(hinge.end.index, 0)
    }

    func testCubeHasNoLinksOrJoints() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        XCTAssertTrue(scene.links.isEmpty)
        XCTAssertTrue(scene.joints.isEmpty)
    }

    /// A Rhino extrusion's edges are its profile's own curves, so the surface path gets them
    /// exactly and for nothing. Both conventions: `.unreal` goes through the decorator that maps
    /// every getter into the caller's space, which must forward this rather than fall back to
    /// the trims.
    func testExtrusionHandsItsExactEdgesToTheSurfacePath() throws {
        let path = try sample(extrusions)
        for convention in [Convention.native, .unreal] {
            let scene = try Cadaclysm.open(path, convention: convention)
            defer { scene.close() }
            let found = scene.walk().filter { $0.canMesh && !$0.surfaceEdges.isEmpty }
            XCTAssertFalse(found.isEmpty, "the fixture is here for its extrusion objects")
            for node in found {
                let exact = node.surfaceEdgeBeziers
                XCTAssertFalse(exact.isEmpty, "\(convention): an extrusion's exact edges are free")
                XCTAssertFalse(node.isMeshed, "\(convention): handing them over built the triangles")
                XCTAssertEqual(exact.count, node.edgeBeziers.count, "the same segments as edgeBeziers")
            }
        }
        // A B-rep's exact edges come out of the mesher, so it offers none and stays unmeshed.
        let scene = try Cadaclysm.open(try sample(fusionAssembly))
        defer { scene.close() }
        XCTAssertTrue(scene.nodes[1].surfaceEdgeBeziers.isEmpty)
        XCTAssertFalse(scene.nodes[1].isMeshed)
    }

    // ---- edge colours -------------------------------------------------------------------

    /// `samples/edge-colours.stp` paints one edge teal (0.1, 0.6, 0.55) on the body --
    /// everything else, edge and surface-edge alike, stays unstyled.
    func testEdgeColoursFollowTheEdges() throws {
        let scene = try Cadaclysm.open(try sample("samples/edge-colours.stp"))
        defer { scene.close() }
        let body = try XCTUnwrap(scene.walk().first { $0.edges.polylineCount > 0 })
        for (count, colours) in [(body.edges.polylineCount, body.edgeColours),
                                  (body.surfaceEdges.polylineCount, body.surfaceEdgeColours)] {
            XCTAssertEqual(colours.count, count)
            let styled = colours.compactMap { $0 }
            XCTAssertEqual(styled.count, 1)
            XCTAssertEqual(colours.filter { $0 == nil }.count, colours.count - 1)
            let c = try XCTUnwrap(styled.first)
            XCTAssertEqual(c.x, 0.1, accuracy: 1e-6)
            XCTAssertEqual(c.y, 0.6, accuracy: 1e-6)
            XCTAssertEqual(c.z, 0.55, accuracy: 1e-6)
            XCTAssertEqual(c.w, 1.0, accuracy: 1e-6)
        }
    }

    /// The unpainted cube has no styled edges at all -- both accessors come back empty, not
    /// one `nil` entry a polyline.
    func testAnUnpaintedFileHasNoEdgeColours() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let first = try XCTUnwrap(scene.nodes.first { $0.canMesh })
        XCTAssertTrue(first.edgeColours.isEmpty)
        XCTAssertTrue(first.surfaceEdgeColours.isEmpty)
    }

    // ---- the FEM surface mesh ----------------------------------------------------------

    /// **Which count feeds which entry point** -- the census *wiring*, which nothing else pins.
    /// Every other FEM test proves a row is extracted correctly; none proves `openEdges` reads
    /// `open_edge_count` rows through `cadaclysm_fem_mesh_open_edge` rather than the folded count
    /// or the folded call.
    ///
    /// `samples/open-sheet.scad` is the only body in this repository where both censuses are
    /// non-empty and of different lengths: the B-rep path computes no census unless the topology
    /// is closed (the documented "not asked" pair) and every closed body has none, while the mesh
    /// path always computes one -- so a `polyhedron` with a flap over one of its own directed
    /// edges is the way in. Six cracks, one fold, and the fold is not the first crack.
    ///
    /// Catches: `openEdges` wired to the folded count (1 row where 6 belong), to the folded call
    /// (row 1 of a one-row table cannot be read at all), or both consistently (the contents then
    /// disagree). Proven by each of those three mutations.
    func testFemCensusWiring() throws {
        let scene = try Cadaclysm.open(try sample(openSheet))
        defer { scene.close() }
        let mesh = try scene.roots[0].femMesh()
        defer { mesh.free() }
        XCTAssertEqual(mesh.nodes.count, 5 * 3)
        XCTAssertEqual(mesh.triangles.count, 3 * 3)
        XCTAssertTrue(mesh.fromMesh)
        XCTAssertFalse(mesh.watertight)
        // The counts are what separate the two lists.
        let cracks = try mesh.openEdges
        let folds = try mesh.foldedEdges
        XCTAssertEqual(cracks.count, 6, "the sheet and its flap leave six boundary edges")
        XCTAssertEqual(folds.count, 1, "the flap shares one directed edge with the sheet")
        // And the contents, which separates a wrapper that swapped both consistently.
        XCTAssertEqual(folds[0].0, 2)
        XCTAssertEqual(folds[0].1, 0)
        XCTAssertEqual(folds[0].2, UInt32.max, "a mesh-only body's rows name no B-rep edge")
        XCTAssertEqual(cracks[0].0, 1)
        XCTAssertEqual(cracks[0].1, 2)
    }

    /// The cube's own mesh through `Node.femMesh`: a `from_mesh` body, so one face, every node
    /// on it, no topology at all -- and a census that really did run, because a bare mesh has
    /// no topology to ask of.
    ///
    /// Catches: the five arrays lent at the wrong counts (`triangleFace` is one per triangle
    /// where `nodeKind` is one per node, so a wrapper lending node counts for both passes
    /// nothing else here), `nodeKind`/`nodeEntity` read from each other's pointers, the view
    /// read per accessor instead of once, and a summary field taken off the wrong member.
    func testFemMeshOfAMeshOnlyBody() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let mesh = try scene.roots[0].femMesh(tolerance: 0.01)
        defer { mesh.free() }
        XCTAssertEqual(mesh.nodes.count, 8 * 3)
        XCTAssertEqual(mesh.triangles.count, 12 * 3)
        XCTAssertEqual(mesh.triangleFace.count, 12)
        XCTAssertEqual(mesh.nodeKind.count, 8)
        XCTAssertEqual(mesh.nodeEntity.count, 8)
        XCTAssertTrue(mesh.triangles.allSatisfy { Int($0) < 8 })
        XCTAssertTrue(mesh.triangleFace.allSatisfy { $0 == 0 })
        // A mesh-only body: one face, every node on it (kind 2), no edges and no vertices.
        XCTAssertTrue(mesh.fromMesh)
        XCTAssertEqual(mesh.faceCount, 1)
        XCTAssertTrue(mesh.nodeKind.allSatisfy { $0 == 2 })
        XCTAssertTrue(mesh.nodeEntity.allSatisfy { $0 == 0 })
        XCTAssertEqual(try mesh.edges.count, 0)
        XCTAssertEqual(try mesh.vertices.count, 0)
        // The census ran: for a bare mesh an empty one really does mean "nothing found".
        XCTAssertTrue(mesh.watertight)
        XCTAssertEqual(try mesh.openEdges.count, 0)
        XCTAssertEqual(try mesh.foldedEdges.count, 0)
        XCTAssertGreaterThan(mesh.minAngle, 0)
        XCTAssertLessThanOrEqual(mesh.minAngle, 60)
        XCTAssertLessThan(mesh.worstTriangle, 12)
        // The cube is 20 a side, so a face diagonal is the longest edge any triangle of it has.
        XCTAssertEqual(mesh.longestEdge, 20 * 2.0.squareRoot(), accuracy: 1e-9)
        XCTAssertFalse(mesh.freed)
        XCTAssertTrue(mesh.description.contains("nodes=8"), mesh.description)
    }

    /// The `.msh` text and the file beside it. **The reader's text is borrowed from the
    /// handle** -- a slot replaced by the next call on it -- and this wrapper copies it out, so
    /// two asks give two `String`s of the caller's own and the second does not free the first.
    /// Catches a wrapper that freed the reader's text, which is the kernel's convention.
    func testFemMeshMshText() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let mesh = try scene.roots[0].femMesh()
        defer { mesh.free() }
        let text = try mesh.mshText()
        let again = try mesh.mshText()
        XCTAssertTrue(text.hasPrefix("$MeshFormat\n4.1 0 8\n"), String(text.prefix(40)))
        XCTAssertEqual(again, text)
        let path = scratch("fem-reader.msh")
        try mesh.saveMsh(path)
        XCTAssertGreaterThanOrEqual(size(path), text.utf8.count / 2)
    }

    /// The owner of a FEM mesh's views is the **mesh**, not the scene: closing the scene
    /// neither frees one nor stales one, and `free()` is what ends them.
    ///
    /// Catches building the views with the scene as their `NativeMemoryOwner` -- which
    /// compiles, passes every count and shape check above, and calls a live mesh stale the
    /// moment the scene closes.
    func testFemMeshOutlivesItsSceneAndItsViewsEndWithItAlone() throws {
        var scene: Scene? = try Cadaclysm.open(try sample(cube))
        let mesh = try scene!.roots[0].femMesh()
        let nodes = mesh.nodes
        let copied = nodes.copy()
        let first = nodes[0]
        scene!.close()
        scene = nil
        // The scene is gone; the mesh is its own handle and answers as it did.
        XCTAssertTrue(nodes.isValid)
        XCTAssertEqual(nodes[0], first)
        XCTAssertEqual(mesh.triangles.count, 12 * 3)
        XCTAssertFalse(mesh.freed)
        mesh.free()
        XCTAssertTrue(mesh.freed)
        XCTAssertFalse(nodes.isValid)
        XCTAssertEqual(nodes.owner.nativeMemoryInvalidReason, "the FEM mesh is freed")
        XCTAssertEqual(mesh.description, "FemMesh(freed)")
        // A copy is Swift's own memory and outlives everything.
        XCTAssertTrue(copied.isValid)
        XCTAssertEqual(copied[0], first)
        // Every throwing member that reads the handle refuses in the library's shape. (Asking for
        // a view after the free traps instead, as reading a closed `Scene`'s property does, so
        // there is nothing here that can assert it without ending the process.)
        XCTAssertThrowsError(try mesh.mshText())
        XCTAssertThrowsError(try mesh.edges)
        mesh.free()   // idempotent
    }

    /// A view held after the last reference to the mesh keeps the mesh alive by itself, so no
    /// collector can free the handle under it: the case the docs say Python's and Swift's view
    /// types are safe from, and the one C#, Java, Go and Node cannot guard.
    func testAFemViewKeepsItsMeshAlive() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        weak var alive: FemMesh?
        var nodes: NativeArray<Double>?
        do {
            let mesh = try scene.roots[0].femMesh()
            alive = mesh
            nodes = mesh.nodes
        }
        // The last strong reference to the mesh is the view's own `owner`.
        XCTAssertNotNil(alive, "a view holds its FEM mesh")
        XCTAssertTrue(try XCTUnwrap(nodes).isValid)
        XCTAssertEqual(try XCTUnwrap(nodes).count, 8 * 3)
        nodes = nil
        XCTAssertNil(alive, "dropping the last view frees the mesh")
    }

    /// The placement reaches the library, and in the right order.
    ///
    /// **A rotation, not only a translation**: translate-then-rotate and rotate-then-translate
    /// agree on every pure translation, and transposing the 3x3 block leaves one
    /// bit-identical, so a translation-only check catches neither. This one maps the origin to
    /// (100, 0, 0) where the other order maps it to (0, 100, 0), and the transpose sends what
    /// should be +y to -y.
    ///
    /// **And the body must sit off the rotation's axis, in the plane the rotation turns in.**
    /// Transposing the block composes this transform with a 180-degree turn about z through the
    /// placement's own origin, so a body whose centre lands on that axis maps onto itself and
    /// the check is mathematically blind -- Task 4 measured an offset of (0, 0, 5), off the
    /// origin yet purely along the axis, leaving a transposed kernel placement at exit 0.
    /// `cube.scad` spans 0..20 in x and y rather than straddling the z axis, which is what
    /// earns the catch; the loop over every node is defence in depth, not the thing that works.
    func testFemMeshPlacementTurnsAndMovesEveryNode() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.roots[0]
        let placed = try node.femMesh(placement: turnedMatrix)
        defer { placed.free() }
        let plain = try node.femMesh()
        defer { plain.free() }
        XCTAssertEqual(placed.nodes.count, plain.nodes.count)
        let there = points(placed.nodes)
        for p in points(plain.nodes) {
            let want = turned(p)
            XCTAssertTrue(there.contains { close($0, want) },
                          "the placement did not send \(p) to \(want) -- the placed nodes span \(span(placed.nodes))")
        }
        let (lo, hi) = span(placed.nodes)
        // The cube spans (0,0,0)..(20,20,20), so the turn takes it to (80,0,0)..(100,20,20).
        XCTAssertTrue(close(lo, SIMD3(80, 0, 0)) && close(hi, SIMD3(100, 20, 20)), "\(lo)..\(hi)")
    }

    /// The one thing this wrapper **must** check, because the ABI is handed a bare pointer and
    /// cannot: a placement that is not sixteen numbers. The kernel's `Solid.femMesh` takes a
    /// `Frame` -- twelve numbers, checked when it is built -- so no such check is possible or
    /// needed there.
    func testFemMeshRefusesAPlacementThatIsNotSixteenNumbers() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.roots[0]
        XCTAssertThrowsError(try node.femMesh(placement: [1, 0, 0])) { error in
            XCTAssertEqual((error as? CadaclysmError)?.message, "femMesh: a placement is 16 numbers, not 3")
        }
        // Twelve is the kernel's count, and the mistake a caller moving between the two makes.
        XCTAssertThrowsError(try node.femMesh(placement: Array(repeating: 0, count: 12)))
        XCTAssertNoThrow(try node.femMesh(placement: identity).free())
    }

    /// **Neither `tolerance` nor `maxSize` is validated by this wrapper**, and the mesh-only
    /// path reads neither: `fem_mesh_of_mesh` takes no options at all. Catches a wrapper that
    /// checked either field itself -- which passes every Python-shaped test and is wrong.
    func testFemMeshValidatesNeitherToleranceNorMaxSizeOnTheMeshOnlyPath() throws {
        let scene = try Cadaclysm.open(try sample(cube))
        defer { scene.close() }
        let node = scene.roots[0]
        for (tolerance, maxSize) in [(0.0, 0.0), (-1.0, 0.0), (Double.nan, 0.0),
                                     (0.01, -1.0), (0.01, Double.nan), (0.01, Double.infinity)] {
            let mesh = try node.femMesh(tolerance: tolerance, maxSize: maxSize)
            XCTAssertEqual(mesh.nodes.count, 8 * 3, "tolerance \(tolerance) maxSize \(maxSize)")
            mesh.free()
        }
    }

    /// A B-rep body: the topology is there, `fromMesh` is false, and `FemEdge.id` is the
    /// **body's own** edge id rather than the index it was read at.
    ///
    /// Catches: `id` filled from the loop counter, `faces` and `ends` read from each other's
    /// fields (both a pair of `UInt32` a swap leaves in range), and `nodes`/`runs` lent from
    /// one pointer.
    func testFemMeshOfABrepBodyCarriesItsTopology() throws {
        let scene = try Cadaclysm.open(try sample(assembly))
        defer { scene.close() }
        // A real STEP body, chosen because its edge ids are the file's own (`#89`, `#98`, ...)
        // rather than 0..n: a body whose ids happen to equal their indices -- which a small
        // Rhino body's do -- cannot tell `id` from the loop counter at all.
        let node = scene.nodes[1]
        XCTAssertNotNil(node.brep)
        let mesh = try node.femMesh(tolerance: 0.05)
        defer { mesh.free() }
        XCTAssertFalse(mesh.fromMesh)
        XCTAssertEqual(mesh.faceCount, 18)
        XCTAssertEqual(try mesh.edges.count, 48)
        XCTAssertEqual(try mesh.vertices.count, 32)
        // A closed body: watertight with both censuses empty.
        XCTAssertTrue(mesh.watertight)
        XCTAssertEqual(try mesh.openEdges.count, 0)
        XCTAssertEqual(try mesh.foldedEdges.count, 0)
        let edges = try mesh.edges
        let vertices = try mesh.vertices
        XCTAssertFalse(edges.isEmpty)
        XCTAssertFalse(vertices.isEmpty)
        XCTAssertEqual(mesh.nodeKind.count, mesh.nodes.count / 3)
        XCTAssertTrue((0..<3).allSatisfy { k in mesh.nodeKind.contains(UInt32(k)) },
                      "the nodes do not cover all three kinds")
        // The ids ascend, and at least one is not its own index.
        XCTAssertEqual(edges.map(\.id), edges.map(\.id).sorted())
        XCTAssertTrue(edges.enumerated().allSatisfy { UInt32($0.offset) != $0.element.id },
                      "an edge id equals its own index -- id is the index, not the body's id")
        XCTAssertGreaterThan(edges[0].id, 48, "edge 0's id is the file's own number, not a small index")
        for (i, edge) in edges.enumerated() {
            XCTAssertEqual(edge.runs.first, 0, "edge \(i)'s first run does not start at 0")
            XCTAssertTrue(edge.runs.allSatisfy { Int($0) < edge.nodes.count }, "edge \(i)'s runs leave its nodes")
            XCTAssertTrue(edge.nodes.allSatisfy { Int($0) < mesh.nodes.count / 3 },
                          "edge \(i) names a node past the mesh")
            XCTAssertLessThan(edge.faces.0, mesh.faceCount, "edge \(i)")
            if edge.seam { XCTAssertEqual(edge.faces.0, edge.faces.1, "edge \(i) is a seam") }
            if edge.closed { XCTAssertEqual(edge.runs.count, 1, "edge \(i) is closed with more than one run") }
            // The ends resolve through `vertices` to the chain's own first or last node --
            // which is what tells `ends` from `faces`.
            for v in [edge.ends.0, edge.ends.1] where v != UInt32.max {
                let at = vertices[Int(v)]
                if at.node != UInt32.max {
                    XCTAssertTrue(at.node == edge.nodes.first || at.node == edge.nodes.last,
                                  "edge \(i)'s end vertex \(v) is node \(at.node), neither end of its chain")
                }
            }
        }
        XCTAssertTrue(vertices.contains { $0.hasPosition })
        XCTAssertTrue(vertices.allSatisfy { $0.hasPosition || $0.point == .zero },
                      "a vertex with no position carries a point that is not zeroed")
    }

    /// **`femMesh`'s defaults are `FemOptions::default()`'s** -- `tolerance: 0.01` and
    /// `max_size: 0`, from `impl Default for FemOptions` in `crates/cadaclysm-brep/src/fem.rs`, the
    /// same figures `cadaclysm_fem_options_init` writes into the struct. **Not `Node.mesh`'s
    /// `0.05`**, which is the *render* mesher's default; the kernel's `Solid.femMesh` shipped with
    /// exactly that slip, because `Solid.mesh` sits directly above it, so the pin exists on both
    /// sides now.
    ///
    /// Pinned against the figure rather than against the kernel's default, so either module can be
    /// wrong on its own and still be caught: the no-argument call must agree with an explicit `0.01`,
    /// must come to the node count `0.01` is known to give, and must **disagree** with an explicit
    /// `0.05` -- which is what says the first assertion has teeth. Measured through `cadaclysm.py`
    /// on the same library: 5636 nodes at 0.01 against 2564 at 0.05.
    ///
    /// **The cube cannot do this job**, and the last two assertions say why: a flat mesh-only body
    /// meshes to 8 nodes at either tolerance, so a defaults test written against it would pass
    /// whatever the default said. That is why the slip survived every other test here.
    func testFemMeshDefaultsAreTheLibrarysOwn() throws {
        let scene = try Cadaclysm.open(try sample(assembly))
        defer { scene.close() }
        let node = scene.nodes[1]
        let byDefault = try node.femMesh()
        defer { byDefault.free() }
        let stated = try node.femMesh(tolerance: 0.01, maxSize: 0.0)
        defer { stated.free() }
        let renderDefault = try node.femMesh(tolerance: 0.05)
        defer { renderDefault.free() }
        XCTAssertEqual(byDefault.nodes.count, stated.nodes.count, "the default tolerance is not 0.01")
        XCTAssertEqual(byDefault.nodes.count, 5636 * 3, "0.01 no longer meshes this body to 5636 nodes")
        XCTAssertNotEqual(byDefault.nodes.count, renderDefault.nodes.count,
                          "0.01 and 0.05 mesh this body alike, so this test cannot tell them apart")

        let cubeScene = try Cadaclysm.open(try sample(cube))
        defer { cubeScene.close() }
        let fine = try cubeScene.roots[0].femMesh(tolerance: 0.01)
        defer { fine.free() }
        let coarse = try cubeScene.roots[0].femMesh(tolerance: 0.05)
        defer { coarse.free() }
        XCTAssertEqual(fine.nodes.count, 8 * 3)
        XCTAssertEqual(coarse.nodes.count, fine.nodes.count,
                       "the cube distinguishes the tolerances after all -- it could carry this pin")
    }

    /// The B-rep path **does** read the options, and refuses a bad tolerance in the library's
    /// own words -- which is what proves the wrapper hands the library's message up rather
    /// than inventing one, and the other half of the pass-through contract above.
    func testFemMeshOfABrepBodyRefusesABadTolerance() throws {
        let scene = try Cadaclysm.open(try sample(assembly))
        defer { scene.close() }
        let node = scene.nodes[1]
        XCTAssertThrowsError(try node.femMesh(tolerance: 0)) { error in
            XCTAssertTrue("\(error)".contains("tolerance must be finite and > 0"), "\(error)")
        }
    }
}
