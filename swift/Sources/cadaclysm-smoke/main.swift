// Open one file through the reader and check what comes back, then build a part through
// the kernel, write it as STEP and read it back through the reader. The exit code is the
// verdict: the release pipeline runs this against every library it ships.
//
//   swift run cadaclysm-smoke [model] [license]
//
// The Go smoke (go/cmd/smoke) is the twin this follows, check for check.
import Blacksmith
import Cadaclysm
import Foundation

func fail(_ why: String) -> Never {
    FileHandle.standardError.write(Data((why + "\n").utf8))
    exit(1)
}

func check(_ ok: Bool, _ why: @autoclosure () -> String) {
    if !ok { fail(why()) }
}

/// The value of a throwing expression, or the smoke's failure with the library's words.
func must<T>(_ what: String, _ body: () throws -> T) -> T {
    do { return try body() } catch { fail("\(what): \(error)") }
}

/// samples/cube.scad in the nearest directory above this file that has one: the SDK
/// keeps it three levels up, this repository six.
func defaultSample() -> String {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    while true {
        let candidate = dir.appendingPathComponent("samples/cube.scad")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate.path }
        let parent = dir.deletingLastPathComponent().standardized
        if parent.path == dir.path { break }   // the root, on any platform's URL rules
        dir = parent
    }
    return "samples/cube.scad"
}

let arguments = CommandLine.arguments
let path = arguments.count > 1 ? arguments[1] : defaultSample()
let license = arguments.count > 2 ? arguments[2] : nil
let temp = FileManager.default.temporaryDirectory

// ---- the reader ------------------------------------------------------------------------

if let license { must("license") { try Cadaclysm.license(license) } }
print("cadaclysm \(Cadaclysm.version()) built \(Cadaclysm.buildDate())")
print("license: \(Cadaclysm.licenseInfo())")

let scene = must("open") { try Cadaclysm.open(path) }
let bounds = scene.bounds
print("bounds min=\(bounds.min) max=\(bounds.max)")

var triangles = 0
for node in scene.walk() where node.canMesh {
    triangles += node.mesh.triangleCount
}
print("triangles=\(triangles)")
// All six bounds values: a bug that only flips one axis still passes a check of three.
if URL(fileURLWithPath: path).lastPathComponent == "cube.scad" {
    check(bounds.min == SIMD3(0, 0, 0) && bounds.max == SIMD3(20, 20, 20) && triangles == 12,
          "the cube did not come back as a 20-unit cube of 12 triangles")
}

// The reader's own extras: a query, the diagnostics, an in-memory open of the same bytes.
// The OpenSCAD reader's own kind for cube.scad's solid is "solid", not "mesh".
let matched = must("query") { try scene.query("class == solid") }
print("query: \(matched.count) node(s)")
print("diagnostics: \(scene.diagnostics.count)")

let data = must("read \(path)") { try Data(contentsOf: URL(fileURLWithPath: path)) }
let name = URL(fileURLWithPath: path).lastPathComponent
let again = must("open_memory") { try Cadaclysm.openMemory(data, format: URL(fileURLWithPath: path).pathExtension, name: name) }
check(again.bounds == bounds, "open_memory disagrees with open")
check(again.path == name, "open_memory's path is \(again.path)")
again.close()
// A closed scene refuses: a throwing member throws the scene's own error.
do {
    _ = try again.query("class == solid")
    fail("a closed scene answered a query")
} catch is CadaclysmError {
} catch {
    fail("a closed scene's refusal is not a CadaclysmError: \(error)")
}

let stl = temp.appendingPathComponent("cadaclysm-smoke-swift.stl").path
guard let first = scene.roots.first else { fail("the scene has no root nodes to save a mesh from") }
must("save_mesh") { try first.saveMesh(stl, format: "stl") }
let size = (try? FileManager.default.attributesOfItem(atPath: stl)[.size] as? Int) ?? 0
check(size >= 84, "save_mesh wrote no triangles")

// The scene's and a node's wireframe as SVG: the library's own camera, no viewer.
let svgText = must("svg_text") { try scene.svgText() }
check(svgText.hasPrefix("<svg") && svgText.contains("<path"), "scene SVG text did not look like an SVG wireframe")
let svgPath = temp.appendingPathComponent("cadaclysm-smoke-swift.svg").path
must("svg") { try scene.svg(svgPath) }
let svgSize = (try? FileManager.default.attributesOfItem(atPath: svgPath)[.size] as? Int) ?? 0
check(svgSize > 0, "scene.svg wrote an empty file")
let nodeSvgText = must("node svg_text") { try first.svgText() }
check(nodeSvgText.hasPrefix("<svg") && nodeSvgText.contains("<path"), "node SVG text did not look like an SVG wireframe")
do {
    _ = try scene.svgText(SvgOptions(fov: 200))
    fail("scene svg: fov=200 was accepted")
} catch is CadaclysmError {
} catch {
    fail("scene svg: fov=200's refusal is not a CadaclysmError: \(error)")
}
print("svg: scene and node text, file written, fov=200 refused")

// ---- the kernel ------------------------------------------------------------------------

if let license { must("blacksmith license") { try Blacksmith.license(license) } }
print("blacksmith \(Blacksmith.version()) built \(Blacksmith.buildDate())")
print("blacksmith license: \(Blacksmith.licenseInfo())")

// The plate with a hole and a pin, as every wrapper's smoke builds it.
let xy = must("frame") { try Frame.xy() }
let outline = must("outline") { try Profile.rect(80, 40).withHole(Profile.circle(4)) }
let plate = must("plate") { try Workplane.xy().extrude(outline, 6).solid() }
let pin = must("pin") { try Workplane.fromSolid(plate).faces(.max(.z)).workplane().cylinder(5, 10).solid() }
let part = must("join") { try plate.join(pin) }

// The plate's own corners: vertical lines between planes.
let corners = must("edges") {
    try part.edges.filter { edge in
        guard let d = edge.direction, abs(d.z) > 0.99 else { return false }
        return try edge.faces.allSatisfy { try part.faceKind($0) == "plane" }
    }
}
let rounded = must("fillet") { try part.fillet(corners, 1.0) }
let faces = must("faces") { try rounded.faces }
let watertight = must("is_watertight") { try rounded.isWatertight() }
print("faces=\(faces) watertight=\(watertight)")
check(watertight, "the filleted part is not watertight")
let shape = must("manifold") { try rounded.manifold }
print("manifold: \(shape)")
check(shape.isClosed && shape.faces == faces, "the filleted part is not a closed manifold: \(shape)")
// A plate has 6 faces, the hole adds 1 cylinder, the pin 2 (its wall and its top), and
// each of the four corners rounded trades one edge for one face.
check(faces == 15, "the filleted part has \(faces) faces, not 15")

// The solid's own wireframe as SVG, over the kernel ABI rather than the reader's.
let solidSvgText = must("solid svg_text") { try rounded.svgText() }
check(solidSvgText.hasPrefix("<svg") && solidSvgText.contains("<path"), "solid SVG text did not look like an SVG wireframe")
let solidSvgPath = temp.appendingPathComponent("cadaclysm-smoke-swift-solid.svg").path
must("solid svg") { try rounded.svg(solidSvgPath) }
let solidSvgSize = (try? FileManager.default.attributesOfItem(atPath: solidSvgPath)[.size] as? Int) ?? 0
check(solidSvgSize > 0, "Solid.svg wrote an empty file")
do {
    _ = try rounded.svgText(SvgOptions(fov: 200))
    fail("blacksmith svg: fov=200 was accepted")
} catch is BuildError {
} catch {
    fail("blacksmith svg: fov=200's refusal is not a BuildError: \(error)")
}
print("blacksmith svg: solid text, file written, fov=200 refused")

frames()
sheetVerbs(plate)

// Hits: two radius-5 circles six apart cross at two points, (3, -4) and (3, 4). At (3, 4)
// the first circle's upper arc is at t 0.2952 and the moved one's at 0.7048; at (3, -4) the
// other way round -- which catches the two sides read swapped.
let crossing = must("hits") { try Profile.circle(5).hits(try Profile.circle(5).translate(6, 0)) }
check(crossing.count == 2, "hits: two circles hit \(crossing.count) times, not 2")
let crossingYs = crossing.map { $0.start.y }.sorted()
check(abs(crossingYs[0] + 4) < 1e-9 && abs(crossingYs[1] - 4) < 1e-9, "hits: y \(crossingYs), not -4 and 4")
for h in crossing {
    let (ta, tb) = h.start.y > 0 ? (0.2952, 0.7048) : (0.7048, 0.2952)
    check(!h.run && !h.touch && h.aStart.loopIndex == 0 && abs(h.start.x - 3) < 1e-9
        && abs(h.aStart.t - ta) < 1e-3 && abs(h.bStart.t - tb) < 1e-3,
        "hits: \(h) is not a crossing at (3, +-4) at t \(ta) on a and \(tb) on b")
}
print("hits: \(crossing[0]), \(crossing[1])")

// Edge curves: a cylinder's rims are circles of its radius about a cap centre, a whole turn
// each; a cuboid's edges are lines whose origin + x is the far end.
let rims = must("edges") { try Solid.cylinder(5, 3).edges }.filter { $0.kind == "circle" }.compactMap { $0.curve }
check(rims.count >= 2, "edge_curve: the cylinder's rims have no curve")
for c in rims {
    let unit = abs((c.x * c.x).sum().squareRoot() - 1) < 1e-9 && abs((c.y * c.y).sum().squareRoot() - 1) < 1e-9 && abs((c.x * c.y).sum()) < 1e-9
    let centred = abs(c.origin.x) < 1e-9 && abs(c.origin.y) < 1e-9 && min(abs(c.origin.z), abs(c.origin.z - 3)) < 1e-9
    check(c.kind == "circle" && abs(c.radius - 5) < 1e-9 && unit && centred && abs(abs(c.t1 - c.t0) - 2 * Double.pi) < 1e-9
        && c.degree == 0 && c.knots.isEmpty && c.weights == nil, "edge_curve: a rim reads \(c)")
}
for e in must("edges") { try Solid.cuboid(2, 4, 6).edges } {
    guard let c = e.curve, c.kind == "line", c.t0 == 0, c.t1 == 1 else { fail("edge_curve: a cuboid edge reads \(String(describing: e.curve))") }
    let far = c.origin + c.x
    let ends = e.segments.flatMap { [$0.start, $0.end] }
    check(ends.contains { (($0 - c.origin) * ($0 - c.origin)).sum() < 1e-18 } && ends.contains { (($0 - far) * ($0 - far)).sum() < 1e-18 },
          "edge_curve: a cuboid line's ends are not its own vertices: \(c)")
}
print("edge_curve: \(rims[0])")

// Colour: a gold plate joined with a blue pin -- the part is gold, the pin's top keeps its blue.
let gold = must("coloured") { try plate.coloured(SIMD3(0.8, 0.6, 0.4)) }
let blue = must("coloured") { try pin.coloured(SIMD3(0.2, 0.4, 1.0)) }
let coloured = must("join") { try gold.join(blue) }
let top = must("select_face") { try coloured.selectFace(.max(.z)) }
let partColour = must("colour") { try coloured.colour }
let topColour = must("face_colour") { try coloured.faceColour(top) }
print("colour=\(String(describing: partColour)) pin top=\(String(describing: topColour))")
check(partColour == SIMD3(0.8, 0.6, 0.4) && topColour == SIMD3(0.2, 0.4, 1.0), "the colours did not carry through the join")

// A face: the outline as a sheet, which pushed out is the plate again.
let sheet = must("face") { try Solid.face(outline, xy) }
let pushed = must("extrude_faces") { try sheet.extrudeFaces(6) }
let (sheetFaces, pushedFaces, plateFaces) = must("faces") { (try sheet.faces, try pushed.faces, try plate.faces) }
print("face: \(sheetFaces) face, pushed out \(pushedFaces) faces")
check(sheetFaces == 1 && pushedFaces == plateFaces && must("is_watertight") { try pushed.isWatertight() },
      "the outline's face did not push out to the plate")

// A mesh view is tied to one filling of the solid's cache: meshing at another tolerance and
// back again replaces that memory, and the first view must know it rather than read it.
let firstMesh = must("mesh") { try rounded.mesh(tolerance: 0.05) }
check(!firstMesh.isStale && firstMesh.positions.count > 0, "a fresh mesh view is not readable")
_ = must("mesh") { try rounded.mesh(tolerance: 0.5) }
_ = must("mesh") { try rounded.mesh(tolerance: 0.05) }
check(firstMesh.isStale, "a mesh view survived meshing at 0.05, 0.5, 0.05")
print("mesh at 0.05: \(firstMesh.triangleCount) triangles; the first view is stale after 0.05, 0.5, 0.05")

// No schema at all: the kernel writes against its built-in AP203, no ap203.exp needed.
let noSchema = must("step_text") { try rounded.stepText() }
check(noSchema.hasPrefix("ISO-10303-21;"), "stepText() with no schema did not write valid STEP")
print("stepText with no schema: ISO-10303-21; ok")

let step = temp.appendingPathComponent("cadaclysm-smoke-swift.stp").path
must("step") { try rounded.step(step) }
var back: Scene? = must("step read back") { try Cadaclysm.open(step) }
let b = back!.bounds
print("step read back: bounds max=\(b.max)")
// The plate is 80 x 40 x 6, Rect centring it on the origin, and the pin adds 10.
check(abs(b.max.x - 40) <= 0.01 && abs(b.max.y - 20) <= 0.01 && abs(b.max.z - 16) <= 0.01,
      "the STEP did not read back as the plate with its pin")

// The same solid as SAT, written by the library itself, read back the same way.
let sat = temp.appendingPathComponent("cadaclysm-smoke-swift.sat").path
must("sat") { try rounded.sat(sat) }
check(must("sat_text") { try rounded.satText() }.hasPrefix("400 0 1 0"), "the SAT text does not open with the record version")
let satBack: Scene = must("sat read back") { try Cadaclysm.open(sat) }
let satBounds = satBack.bounds
print("sat read back: bounds max=\(satBounds.max)")
check(abs(satBounds.max.x - 40) <= 0.01 && abs(satBounds.max.y - 20) <= 0.01 && abs(satBounds.max.z - 16) <= 0.01,
      "the SAT did not read back as the plate with its pin")
satBack.close()

// And back into the kernel: the read body's brep, shared with the scene rather than copied,
// as a solid that outlives the scene it came from.
var body: Node?
for placement in back!.placements {
    guard let brep = placement.geometry.brep else { continue }
    let read = must("brep manifold") { try brep.manifold }
    brep.release()
    check(read.isClosed && read.faces == 15, "the read body is not the closed manifold written: \(read)")
    check((try? brep.manifold) == nil, "a released brep answered manifold")
    body = placement.geometry
    break
}
guard let body else { fail("no placement of the read-back STEP has a brep") }
let imported = must("from_node") { try Solid.fromNode(back!, body) }
back!.close()
back = nil
let importedFaces = must("faces") { try imported.faces }
check(importedFaces == faces, "from_node gave \(importedFaces) faces, not \(faces)")
let opened = must("open") { try Solid.open(step) }
check(must("faces") { try opened.faces } == faces, "Solid.open gave a different face count")
print("from_node: \(importedFaces) faces after the scene closed; Solid.open: the same")

// toScene is the same round trip in memory: the scene's bounds must match the solid's own,
// and the scene is its own document -- closing the solid leaves it readable.
let own = must("bounds") { try rounded.bounds }
let madeScene = must("to_scene") { try rounded.toScene() }
let sb = madeScene.bounds
for i in 0..<3 {
    check(abs(sb.max[i] - own.max[i]) <= 0.01 && abs(sb.min[i] - own.min[i]) <= 0.01, "to_scene's bounds disagree with the solid's")
}
rounded.close()
check(madeScene.bounds == sb, "closing the solid changed the scene made from it")
print("to_scene: bounds max=\(sb.max), still readable after the solid is closed")
print("OK")

// ---- frames and the sheet verbs ----------------------------------------------------------

func frames() {
    let at = must("Frame.at") { try Frame.at(.zero, SIMD3(0, -1, 0)) }
    check(at == must("Frame.xz") { try Frame.xz() }, "Frame.at(-Y) = \(at)")
    check(must("Frame.at") { try Frame.at(SIMD3(1, 2, 3), SIMD3(0, 0, 5)) } == must("Frame.xy") { try Frame.xy(SIMD3(1, 2, 3)) },
          "Frame.at(+Z) is not xy at the same origin")
    check(must("offset") { try Frame.xy().offset(5) } == must("Frame.xy") { try Frame.xy(SIMD3(0, 0, 5)) }
          && must("Frame.yz") { try Frame.yz() }.values == Workplane.yz().frame,
          "Frame.xy / offset / Frame.yz disagree")
    do {
        _ = try Frame(.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1))
        fail("a left-handed frame was accepted")
    } catch {
        check("\(error)".contains("left-handed"), "a left-handed frame: \(error)")
    }
    let rect = must("rect") { try Profile.rect(10, 4) }
    let lid = must("extrude") { try Solid.extrude(rect, Frame.xy(SIMD3(0, 0, 5)), 2) }
    let wall = must("on") { try Workplane.on(Frame.xz(SIMD3(0, 3, 0))).extrude(rect, 1).solid() }
    let lb = must("bounds") { try lid.bounds }
    let wb = must("bounds") { try wall.bounds }
    let top = must("face_frame") { try Frame.of(lid.faceFrame(lid.selectFace(.max(.z)))) }
    check(abs(lb.min.z - 5) <= 1e-6 && abs(lb.max.z - 7) <= 1e-6 && abs(wb.max.y - 3) <= 1e-6
          && abs(top.origin.z - 7) <= 1e-6 && abs(top.z.z - 1) <= 1e-9, "frames: lid \(lb), wall \(wb), top \(top)")
    print("frames: \(must("Frame.at") { try Frame.at(.zero, SIMD3(1, 1, 1)) }): ok")
}

func sheetVerbs(_ plate: Solid) {
    let xy = must("frame") { try Frame.xy() }
    let square = must("rect") { try Profile.rect(20, 20) }
    let circle = must("circle") { try Profile.circle(4) }
    let sheet = must("face") { try Solid.face(square, xy) }
    let peg = must("extrude") { try Solid.extrude(circle, Frame.xy(SIMD3(0, 0, -6)), 12) }
    let holed = must("trim") { try sheet.trim(peg, keep: "outside") }
    let disc = must("trim") { try sheet.trim(peg, keep: "inside") }
    let lid = must("face_sheet") { try plate.faceSheet(plate.selectFace(.max(.z))) }
    let walls = must("drop_faces") { try plate.dropFaces([0, 1]) }
    let slab = must("round") { try Solid.extrude(square.round(2), xy, 1) }
    let wave = must("path") { try Path(SIMD2(0, 0)).bezierTo(SIMD2(20, 0), SIMD2(20, 20), SIMD2(40, 10)).endOpen() }
    let along = must("along") { try SweepPath.along(wave, xy, tolerance: 0.01) }
    let tube = must("sweep") { try Solid.sweep(Profile.circle(1), Frame(.zero, SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)), along) }
    let onPlane = must("workplane face") { try Workplane.xy().face(square).solid() }
    func count(_ s: Solid) -> Int { must("faces") { try s.faces } }
    check(count(sheet) == 1 && count(holed) >= 1 && count(disc) >= 1 && count(lid) == 1 && count(walls) == count(plate) - 2
          && count(slab) == 10 && must("is_watertight") { try tube.isWatertight() } && count(onPlane) == 1,
          "sheet verbs: sheet=\(count(sheet)) holed=\(count(holed)) disc=\(count(disc)) lid=\(count(lid)) walls=\(count(walls)) slab=\(count(slab))")
    let away = must("translate") { try peg.translate(100, 0, 0) }
    do {
        _ = try sheet.trim(away, keep: "inside")
        fail("a trim with nothing inside the tool succeeded")
    } catch {
        check("\(error)".contains("trim: nothing of the sheet lies inside the tool"), "a trim with nothing inside the tool: \(error)")
    }
    // Chain: an L's two sides, the second drawn back to front, joined -- open, two walls.
    let ell = must("chain") {
        try Profile.chain([Path(SIMD2(0, 0)).lineTo(10, 0).endOpen(), Path(SIMD2(10, 8)).lineTo(10, 0).endOpen()])
    }
    check(count(must("extrude_open") { try Solid.extrudeOpen(ell, xy, 2) }) == 2, "chain: an L extruded open is not two walls")
    // Close: the open L's first side and a line back -- closed, a triangle's three walls.
    let closedL = must("close_loop") { try Path(SIMD2(0, 0)).lineTo(10, 0).lineTo(10, 8).endOpen().closeLoop() }
    check(count(must("extrude_open") { try Solid.extrudeOpen(closedL, xy, 2) }) == 3, "close_loop: a closed L is not three walls")
    // Push-pull: a cube's top raised is one taller box, six faces, not a box and a prism.
    let cube = must("cuboid") { try Solid.cuboid(10, 10, 10) }
    check(count(must("push_pull") { try cube.pushPull(cube.selectFace(.max(.z)), 5) }) == 6, "push_pull: the raised cube is not six faces")
    // Quick solids: a coiled wire and a pipe close; a cube split by a plane is two bodies.
    let spring = must("coil") { try Solid.coil(Profile.circle(1).translate(10, 0), (origin: .zero, direction: SIMD3(0, 0, 1)), 4, 2) }
    check(must("is_watertight") { try spring.isWatertight() }, "coil: the spring leaks")
    let pipe = must("pipe") { try Solid.pipe(SweepPath(.zero).lineTo(SIMD3(0, 0, 10)), 2, thickness: 0.5) }
    check(count(pipe) == 6, "pipe: the tube has \(count(pipe)) faces, not 6")
    let halves = must("split_by_plane") { try cube.splitByPlane(Frame(SIMD3(2, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))) }
    check(halves.count == 2 && count(halves[0]) == 6, "split_by_plane: \(halves.count) bodies, not 2")
    // From loops: a circle given before the square it lies in -- the square is the boundary.
    let holedSquare = must("from_loops") { try Solid.extrude(Profile.fromLoops([Profile.circle(4), Profile.rect(30, 30)]), xy, 2) }
    check(count(holedSquare) == 8, "from_loops: the holed square has \(count(holedSquare)) faces, not 8")
    // Revolve in plane: a plate drawn beside the y axis turns into a tube of four walls.
    let beside = must("polygon") { try Profile.polygon([SIMD2(5, 0), SIMD2(8, 0), SIMD2(8, 10), SIMD2(5, 10)]) }
    let turned = must("revolve_in_plane") { try Solid.revolveInPlane(beside, xy, SIMD2(0, 0), SIMD2(0, 1), 2 * Double.pi) }
    let turnedWalls = must("revolve_open_in_plane") { try Solid.revolveOpenInPlane(beside, xy, SIMD2(0, 0), SIMD2(0, 1), Double.pi) }
    check(count(turned) == 4 && count(turnedWalls) == 4, "revolve_in_plane: \(count(turned)) and \(count(turnedWalls)) faces, not 4")
    // A hexagon: six walls and two caps. A closed spline through a square's corners: one wall.
    let hexPrism = must("regular_polygon") { try Solid.extrude(Profile.regularPolygon(SIMD2(0, 0), 10, 6), xy, 2) }
    let loopSolid = must("spline") {
        try Solid.extrude(Profile.spline([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)], closed: true), xy, 2)
    }
    check(count(hexPrism) == 8 && count(loopSolid) == 3, "shapes: \(count(hexPrism)) and \(count(loopSolid)) faces, not 8 and 3")
    print("sheet verbs: face, trim (\(count(holed))+\(count(disc))), face_sheet, drop_faces, round (\(count(slab)) faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, spline: ok")
}
