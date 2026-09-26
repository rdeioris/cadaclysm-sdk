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
    check(scene.links.isEmpty && scene.joints.isEmpty, "the cube has links or joints")
}

// The mechanism facts, from mechanism.stp beside the sample this smoke was given.
mechanismChecks(path)

// f64 twins (Task 13): the same document's own mesh/bounds, unnarrowed -- exact on the
// cube's small coordinates, so this alone cannot tell mesh64 from mesh widened; the far test
// in ReaderTests.swift proves that.
let node0 = scene.roots[0]
let mesh32 = node0.mesh
let mesh64 = node0.mesh64
check(mesh64.vertexCount == mesh32.vertexCount && mesh64.indexCount == mesh32.indexCount,
      "mesh64's counts disagree with mesh's: \(mesh64.vertexCount)/\(mesh64.indexCount) vs \(mesh32.vertexCount)/\(mesh32.indexCount)")
check(Float(mesh64.positions[0]) == mesh32.positions[0], "mesh64's first position narrowed disagrees with mesh's")
check(node0.bounds64.max == node0.bounds.max, "node.bounds64 disagrees with node.bounds widened")
check(scene.bounds64.max == scene.bounds.max, "scene.bounds64 disagrees with scene.bounds widened")
print("f64 twins: mesh64 \(mesh64.triangleCount) triangles, bounds64 max=\(node0.bounds64.max)")

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

femReader(scene, URL(fileURLWithPath: path).lastPathComponent == "cube.scad")

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

// A profile draws its own plane, top by default -- unlike a solid, a sketch has no camera-
// facing convention of its own, so its plane (z = 0) is already the page. The default is
// pinned against an explicit iso view, not just checked non-empty: a top default silently
// left at iso would make the two calls identical and this comparison would pass wrongly.
let profileSvgText = must("profile svg_text") { try outline.svgText() }
check(profileSvgText.hasPrefix("<svg") && profileSvgText.contains("<path"), "profile SVG text did not look like an SVG wireframe")
let profileSvgIso = must("profile svg_text iso") { try outline.svgText(SvgOptions(view: .iso)) }
check(profileSvgText != profileSvgIso, "profile svg: top default did not differ from an explicit iso view")
let profileSvgPath = temp.appendingPathComponent("cadaclysm-smoke-swift-profile.svg").path
must("profile svg") { try outline.svg(profileSvgPath) }
let profileSvgSize = (try? FileManager.default.attributesOfItem(atPath: profileSvgPath)[.size] as? Int) ?? 0
check(profileSvgSize > 0, "Profile.svg wrote an empty file")
print("blacksmith svg: profile text, file written, top default confirmed against iso")

// The module writer draws a solid and a profile on one page: one <g> per drawable, an id
// each -- the overload writeSvgText(_:_:options:)/writeSvg(_:_:_:options:) take, widened
// from the solids-only ones.
let mixedSvgText = must("mixed svg_text") { try writeSvgText([rounded], [outline]) }
check(mixedSvgText.contains("<path") && mixedSvgText.contains("id=\"solid-0\"") && mixedSvgText.contains("id=\"profile-0\""),
      "mixed solid+profile SVG did not carry both group ids")
let mixedSvgPath = temp.appendingPathComponent("cadaclysm-smoke-swift-mixed.svg").path
must("mixed svg") { try writeSvg(mixedSvgPath, [rounded], [outline]) }
let mixedSvgSize = (try? FileManager.default.attributesOfItem(atPath: mixedSvgPath)[.size] as? Int) ?? 0
check(mixedSvgSize > 0, "writeSvg (solids and profiles) wrote an empty file")
print("blacksmith svg: solid and profile drawn together, both group ids present")

frames()
sheetVerbs(plate)
femKernel(rounded)

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

// Intersect: two equal pipes crossing at right angles meet on ellipse chains whose points lie
// on both pipes; apart, nothing; two coaxial pipes overlapping in height share a wall band.
let tol = 1e-3
let offA = { (p: SIMD3<Double>) in abs((p.x * p.x + p.y * p.y).squareRoot() - 1) }
let offB = { (p: SIMD3<Double>) in abs((p.x * p.x + (p.z - 3) * (p.z - 3)).squareRoot() - 1) }
let pipeA = must("cylinder") { try Solid.cylinder(1, 6) }
let pipeB = must("rotate") { try Solid.cylinder(1, 6).rotate((origin: SIMD3(0, 0, 3), direction: SIMD3(1, 0, 0)), Double.pi / 2) }
let found = must("intersect") { try pipeA.intersect(pipeB, tolerance: tol) }
check(found.chains.count >= 2 && found.overlaps.isEmpty, "intersect: the crossed pipes read \(found)")
var ellipses = 0
for c in found.chains {
    check(c.points.count >= 2 && c.points.allSatisfy { offA($0) < 50 * tol && offB($0) < 50 * tol }, "intersect: a chain leaves the pipes: \(c)")
    guard let curve = c.curve else { continue }
    check(curve.kind == "ellipse" || curve.kind == "nurbs", "intersect: a chain's curve reads \(curve)")
    if curve.kind != "ellipse" { continue }
    ellipses += 1
    let t = (curve.t0 + curve.t1) / 2
    let q = curve.origin + curve.x * curve.radius * cos(t) + curve.y * curve.radius2 * sin(t)
    check(offA(q) < 50 * tol && offB(q) < 50 * tol, "intersect: the ellipse leaves the pipes at \(curve)")
}
check(ellipses > 0, "intersect: two equal pipes cross on ellipses")
let apart = must("intersect") { try pipeA.intersect(try pipeB.translate(10, 0, 0)) }
check(apart.chains.isEmpty && apart.overlaps.isEmpty, "intersect: pipes apart read \(apart)")
let shared = must("intersect") { try Solid.cylinder(1, 4).intersect(try Solid.cylinder(1, 4).translate(0, 0, 2), tolerance: tol) }
check(!shared.overlaps.isEmpty && !shared.overlaps[0].loops.isEmpty, "intersect: the coaxial pipes read \(shared)")
for ring in shared.overlaps[0].loops {
    check(ring.count >= 3 && ring.allSatisfy { offA($0) < 50 * tol && $0.z >= 2 - 50 * tol && $0.z <= 4 + 50 * tol },
          "intersect: an overlap ring leaves the shared band: \(shared.overlaps[0])")
}
print("intersect: \(found) (\(ellipses) ellipses); \(shared.overlaps[0])")
// Solid x profile hits: a line through a cuboid pierces two faces and is cut into three
// pieces, outside/inside/outside, the middle one spanning the box.
let cuboid = must("cuboid") { try Solid.cuboid(10, 20, 30) }
let pierced = must("hits") { try cuboid.hits(try Profile.path([-20, 0]).lineTo(20, 0).endOpen(), try Frame.xy()) }
check(pierced.hits.count == 2 && pierced.pieces.map { $0.inside } == [false, true, false], "solid hits: a line through a cuboid reads \(pierced)")
let span = must("bounds") { try Solid.extrudeOpen(pierced.pieces[1].profile, try Frame.xy(), 1).bounds }
check(abs(span.min.x + 5) < 0.05 && abs(span.max.x - 5) < 0.05, "solid hits: the middle piece spans x \(span.min.x) .. \(span.max.x)")
print("solid hits: \(pierced); \(pierced.pieces[1])")

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

// f64 twins (Task 13): mesh64/bounds64 from the very same tessellation, unnarrowed.
let mesh32k = must("mesh") { try rounded.mesh(tolerance: 0.05) }
let mesh64k = must("mesh64") { try rounded.mesh64(tolerance: 0.05) }
check(mesh64k.vertexCount == mesh32k.vertexCount && mesh64k.indexCount == mesh32k.indexCount,
      "mesh64's counts disagree with mesh's: \(mesh64k.vertexCount)/\(mesh64k.indexCount) vs \(mesh32k.vertexCount)/\(mesh32k.indexCount)")
let b32 = must("bounds") { try rounded.boundsAt(0.05) }
let b64 = must("bounds64") { try rounded.boundsAt64(0.05) }
check(abs(b64.min.x - b32.min.x) < 1e-9 && abs(b64.max.z - b32.max.z) < 1e-9, "bounds64 disagrees with bounds: \(b64) vs \(b32)")
print("f64 twins: mesh64 \(mesh64k.triangleCount) triangles, bounds64 max=\(b64.max)")

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

femBrep(back!, faces)

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

// ---- mechanism -------------------------------------------------------------------------

/// The mechanism facts, identical in every language: two links `base` and `arm`, each naming
/// one node of the same name; one joint `hinge` from `arm` (index 1) to `base` (index 0).
/// mechanism.stp sits beside whatever sample this smoke was given.
func mechanismChecks(_ samplePath: String) {
    let samples = URL(fileURLWithPath: samplePath).deletingLastPathComponent()
    let mechanism = must("mechanism open") { try Cadaclysm.open(samples.appendingPathComponent("mechanism.stp").path) }
    defer { mechanism.close() }

    let links = mechanism.links
    let names = links.map(\.name)
    check(names == ["base", "arm"], "mechanism: link names are \(names), not [base, arm]")
    for link in links {
        let nodes = link.nodes
        check(nodes.count == 1 && nodes[0].name == link.name, "mechanism: link \(link.name) does not name its one node")
    }

    let joints = mechanism.joints
    check(joints.count == 1, "mechanism: \(joints.count) joints, not 1")
    let hinge = joints[0]
    check(hinge.name == "hinge", "mechanism: joint name is \(hinge.name), not hinge")
    let (start, end) = (hinge.start, hinge.end)
    check(start.name == "arm" && start.index == 1 && end.name == "base" && end.index == 0,
          "mechanism: hinge runs \(start.name)(\(start.index)) -> \(end.name)(\(end.index)), not arm(1) -> base(0)")
    print("mechanism: links \(names), hinge \(start.name)(\(start.index)) -> \(end.name)(\(end.index))")
}

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
    let starPrism = must("star") { try Solid.extrude(Profile.star(SIMD2(0, 0), 10, 4, 5), xy, 2) }
    check(count(starPrism) == 12, "star: \(count(starPrism)) faces, not 12")
    let word = must("text") { try Profile.text("io", size: 10) }
    let textRing = must("text") { try Solid.extrude(word[2], xy, 2) }
    let textSpline = must("text") { try textRing.edges.contains { $0.kind == "nurbs" } }
    check(word.count == 3 && textSpline, "text: \(word.count) shapes, no spline edge")
    let loopSolid = must("spline") {
        try Solid.extrude(Profile.spline([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)], closed: true), xy, 2)
    }
    check(count(hexPrism) == 8 && count(loopSolid) == 3, "shapes: \(count(hexPrism)) and \(count(loopSolid)) faces, not 8 and 3")
    // A reflector: the parabola from rim to rim, closed and revolved -- watertight.
    let dish = must("parabola") { try Profile.parabola(vertex: SIMD2(0, 0), axis: SIMD2(0, 1), focal: 20, from: 0, to: 50).lineTo(0, 31.25).lineTo(0, 0).end() }
    let bowl = must("revolve_in_plane") { try Solid.revolveInPlane(dish, xy, SIMD2(0, 0), SIMD2(0, 1), 2 * Double.pi) }
    check(must("is_watertight") { try bowl.isWatertight() }, "parabola: the bowl leaks")
    print("sheet verbs: face, trim (\(count(holed))+\(count(disc))), face_sheet, drop_faces, round (\(count(slab)) faces), along, chain, push_pull, coil, pipe, split_by_plane, close_loop, from_loops, revolve_in_plane, regular_polygon, star, text, spline, parabola: ok")
}

// ---- the FEM surface mesh ------------------------------------------------------------------
//
// One transform written both ways, so the reader's **sixteen** column-major doubles and the
// kernel's **twelve**-number `Frame` are checked against the same expected map -- which makes
// that asymmetry something this smoke proves rather than something it only says. A quarter turn
// about z, then 100 along x:
//
//     [ 0 -1  0 100 ]
//     [ 1  0  0   0 ]      so (x, y, z) -> (100 - y, x, z)
//     [ 0  0  1   0 ]
//     [ 0  0  0   1 ]
//
// A rotation and not only a translation, because translate-then-rotate and rotate-then-translate
// agree on every pure translation and a transposed 3x3 block leaves one bit-identical.
//
// **And a rotation only says something about a body that is not symmetric under it.** Transposing
// the block composes this transform with a 180-degree turn about z through the placement's own
// origin, so a body whose centre lands on that axis maps onto itself and the check is
// mathematically blind. **The condition is on x and y alone**: Task 4 measured an offset of
// (0, 0, 5) -- off the origin, purely along the axis -- leaving a transposed kernel placement at
// exit 0, and (30, 7, 5) catching it. `cube.scad` needs no such care because it spans 0..20 in x
// and y rather than straddling the axis; the kernel's cuboid is translated for exactly this
// reason, and centring it again would make that half blind however many points were checked.

/// The reader's sixteen, column-major: column 0 is where x goes, column 3 the translation.
///
/// A function rather than a `let`: this is `main.swift`, where a top-level `let` is initialised
/// where it is written rather than on first use, and `femReader` is called from line 124 -- above
/// this. Measured: reading a `let [Double]` declared below its use crashed on `.count` (a null
/// array), and in a build without that read it went through as **null**, so the placement check
/// passed the identity and failed with "the placement did not send (0,0,0) to (100,0,0)". A
/// function has no initialisation order to get wrong.
func turnedMatrix() -> [Double] { [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 100, 0, 0, 1] }

/// Where `turnedMatrix()`, and the kernel `Frame` below, put a point.
func turned(_ p: SIMD3<Double>) -> SIMD3<Double> { SIMD3(100 - p.y, p.x, p.z) }

func near(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-6) -> Bool {
    max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) <= tolerance
}

/// A FEM mesh's flat `nodes` as points.
func femPoints(_ nodes: NativeArray<Double>) -> [SIMD3<Double>] {
    stride(from: 0, to: nodes.count, by: 3).map { SIMD3(nodes[$0], nodes[$0 + 1], nodes[$0 + 2]) }
}

func femSpan(_ nodes: NativeArray<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
    var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
    for p in femPoints(nodes) {
        lo = SIMD3(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
        hi = SIMD3(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
    }
    return (lo, hi)
}

func femCorners(_ lo: SIMD3<Double>, _ hi: SIMD3<Double>) -> [SIMD3<Double>] {
    [lo.x, hi.x].flatMap { x in [lo.y, hi.y].flatMap { y in [lo.z, hi.z].map { z in SIMD3(x, y, z) } } }
}

/// The five flat arrays and the entity tags, whatever built them: the shape both sides share, so
/// the two halves cannot drift. `triangleFace` is one per triangle where `nodeKind` and
/// `nodeEntity` are one per node, which is what catches an array lent at the wrong count.
func femArrays(nodes: NativeArray<Double>, triangles: NativeArray<UInt32>, triangleFace: NativeArray<UInt32>,
               nodeKind: NativeArray<UInt32>, nodeEntity: NativeArray<UInt32>, faceCount: UInt32,
               edges: Int, vertices: Int, _ what: String) {
    check(nodes.count > 0 && triangles.count > 0, "\(what): an empty mesh came back as success")
    check(nodes.count % 3 == 0 && triangles.count % 3 == 0, "\(what): the arrays are not three to a node or triangle")
    check(triangleFace.count == triangles.count / 3 && nodeKind.count == nodes.count / 3 && nodeEntity.count == nodes.count / 3,
          "\(what): the arrays disagree -- \(nodes.count / 3) nodes, \(triangles.count / 3) triangles, "
          + "\(triangleFace.count) triangleFace, \(nodeKind.count) nodeKind, \(nodeEntity.count) nodeEntity")
    check(triangles.allSatisfy { Int($0) < nodes.count / 3 }, "\(what): a triangle index points past the nodes")
    check(triangleFace.allSatisfy { $0 < faceCount }, "\(what): a triangleFace is not one of the body's \(faceCount) faces")
    for (i, kind) in nodeKind.enumerated() {
        let bound: Int
        switch kind {
        case 0: bound = vertices
        case 1: bound = edges
        case 2: bound = Int(faceCount)
        default: fail("\(what): node \(i) has kind \(kind), which is neither vertex, edge nor face")
        }
        check(Int(nodeEntity[i]) < bound, "\(what): node \(i) is on entity \(nodeEntity[i]) of kind \(kind), which has only \(bound)")
    }
}

/// The reader over a node with no brep: the scene's own mesh, in the scene's convention.
func femReader(_ scene: Scene, _ isCube: Bool) {
    guard let node = scene.walk().first(where: { $0.canMesh }) else { fail("fem: no meshable node") }
    let mesh = must("fem_mesh") { try node.femMesh(tolerance: 0.01) }
    let edges = must("fem edges") { try mesh.edges }
    let vertices = must("fem vertices") { try mesh.vertices }
    femArrays(nodes: mesh.nodes, triangles: mesh.triangles, triangleFace: mesh.triangleFace,
              nodeKind: mesh.nodeKind, nodeEntity: mesh.nodeEntity, faceCount: mesh.faceCount,
              edges: edges.count, vertices: vertices.count, "fem reader")
    // A mesh-only body: one face, every node on it, no topology at all -- and the census does
    // run over the welded triangles, so an empty one here means "nothing found".
    check(mesh.fromMesh, "fem: a node with no brep did not report fromMesh")
    check(mesh.faceCount == 1 && edges.isEmpty && vertices.isEmpty && mesh.nodeKind.allSatisfy { $0 == 2 },
          "fem: a fromMesh body has edges, vertices or a node off face 0")
    check(mesh.watertight && must("fem census") { try mesh.openEdges }.isEmpty && must("fem census") { try mesh.foldedEdges }.isEmpty,
          "fem: the cube's own mesh is not watertight with both censuses empty")
    check(mesh.minAngle > 0 && mesh.minAngle <= 60 && Int(mesh.worstTriangle) < mesh.triangles.count / 3 && mesh.longestEdge > 0,
          "fem: the quality figures read \(mesh.minAngle) deg, triangle \(mesh.worstTriangle), longest \(mesh.longestEdge)")
    if isCube {
        check(mesh.nodes.count == 8 * 3 && mesh.triangles.count == 12 * 3,
              "fem: the cube meshed to \(mesh.nodes.count / 3) nodes, \(mesh.triangles.count / 3) triangles")
    }

    // The `.msh` text: on this side of the ABI it is borrowed from the handle, and the wrapper
    // copies it out -- so two asks give two strings of the caller's own and the second does not
    // free the first. The kernel's is owned and released; see `femKernel`.
    let text = must("msh_text") { try mesh.mshText() }
    let again = must("msh_text") { try mesh.mshText() }
    check(text.hasPrefix("$MeshFormat\n4.1 0 8\n"), "fem: the .msh text does not open as Gmsh 4.1 ASCII: \(text.prefix(40))")
    check(again == text, "fem: two asks for the same mesh's .msh text disagree")
    let msh = temp.appendingPathComponent("cadaclysm-smoke-swift-fem.msh").path
    must("save_msh") { try mesh.saveMsh(msh) }
    let written = ((try? FileManager.default.attributesOfItem(atPath: msh)[.size]) as? Int) ?? 0
    check(written >= text.utf8.count / 2, "fem: save_msh wrote \(written) bytes against \(text.utf8.count) of text")
    print("fem reader: \(mesh.nodes.count / 3) nodes, \(mesh.triangles.count / 3) triangles, fromMesh=\(mesh.fromMesh), \(written) bytes of .msh")

    // The owner of every view is the **mesh**, not the scene: a FEM mesh outlives the scene it
    // was built through, and `free()` is the one thing that ends its views.
    let held = mesh.nodes
    let firstNode = held[0]
    check(held.isValid, "fem: a fresh view is not readable")
    mesh.free()
    check(mesh.freed && !held.isValid, "fem: free() left the views readable")
    // Measured, in this release build: reading `held[0]` here traps inside
    // `NativeArray.subscript.getter` rather than reading freed memory -- which is why Swift is
    // one of the two wrappers whose docs may say a stale read is refused, and refused on the
    // *read*. Not asserted, because a trap ends the process; see `FemMesh`'s own doc comment.

    // The placement reaches the library, and in the right order. Catches it dropped (the nodes
    // stay where the body is), applied twice, transposed (+y for -y), or composed the other way
    // round (the origin at (0, 100, 0), not (100, 0, 0)).
    let placed = must("fem_mesh placed") { try node.femMesh(tolerance: 0.01, placement: turnedMatrix()) }
    let plain = must("fem_mesh") { try node.femMesh(tolerance: 0.01) }
    check(placed.nodes.count == plain.nodes.count, "fem: the placement changed the node count")
    check(plain.nodes[0] == firstNode, "fem: the unplaced mesh moved between two asks")
    let there = femPoints(placed.nodes)
    for p in femPoints(plain.nodes) {
        let want = turned(p)
        check(there.contains { near($0, want) },
              "fem: the placement did not send \(p) to \(want) -- the placed nodes span \(femSpan(placed.nodes))")
    }
    let (lo, hi) = femSpan(placed.nodes)
    let (plainLo, plainHi) = femSpan(plain.nodes)
    check(near(lo, turned(SIMD3(plainLo.x, plainHi.y, plainLo.z))) && near(hi, turned(SIMD3(plainHi.x, plainLo.y, plainHi.z))),
          "fem: the placed nodes span \(lo)..\(hi), not the turn of \(plainLo)..\(plainHi)")
    print("fem reader: the placement turns and moves \(plainLo)..\(plainHi) into \(lo)..\(hi)")
    placed.free()
    plain.free()

    // A placement of the wrong length is the one thing this wrapper must check, the ABI seeing
    // only a pointer. Twelve is the kernel's count, and the mistake a caller crossing over makes.
    do {
        _ = try node.femMesh(placement: Array(repeating: 0, count: 12))
        fail("fem: a 12-number placement was accepted where 16 are wanted")
    } catch let error as CadaclysmError {
        check(error.message == "femMesh: a placement is 16 numbers, not 12", "fem: a 12-number placement: \(error.message)")
    } catch {
        fail("fem: a 12-number placement's refusal is not a CadaclysmError: \(error)")
    }

    // **Neither `tolerance` nor `maxSize` is checked by this wrapper**, and the mesh-only path
    // reads neither: `fem_mesh_of_mesh` takes no options at all. Catches a wrapper that
    // validated either field itself -- which passes every Python-shaped test and is wrong. The
    // B-rep half of the contract is in `femBrep`, where each of these *is* refused.
    for (tolerance, maxSize) in [(0.0, 0.0), (-1.0, 0.0), (Double.nan, 0.0), (0.01, -1.0), (0.01, Double.nan), (0.01, Double.infinity)] {
        do {
            let any = try node.femMesh(tolerance: tolerance, maxSize: maxSize)
            check(any.nodes.count > 0, "fem: tolerance \(tolerance) maxSize \(maxSize) came back as an empty mesh")
            any.free()
        } catch {
            fail("fem: tolerance \(tolerance) maxSize \(maxSize) was refused on the mesh-only path: \(error)")
        }
    }
    print("fem reader: tolerance 0/-1/NaN and maxSize -1/NaN/+Inf all mesh on the mesh-only path")
}

/// The reader over a body that has a brep: the topology is there, and it is in the file's own
/// space rather than the scene's.
func femBrep(_ scene: Scene, _ faces: Int) {
    guard let node = scene.placements.map({ $0.geometry }).first(where: { $0.brep != nil }) else {
        fail("fem brep: no placement of the read-back STEP has a brep")
    }
    let mesh = must("fem_mesh") { try node.femMesh(tolerance: 0.05) }
    let edges = must("fem edges") { try mesh.edges }
    let vertices = must("fem vertices") { try mesh.vertices }
    femArrays(nodes: mesh.nodes, triangles: mesh.triangles, triangleFace: mesh.triangleFace,
              nodeKind: mesh.nodeKind, nodeEntity: mesh.nodeEntity, faceCount: mesh.faceCount,
              edges: edges.count, vertices: vertices.count, "fem brep")
    // The other half of the `fromMesh` proof: this body has a brep, and both bodies are
    // watertight, so it is the flag that tells them apart rather than luck.
    check(!mesh.fromMesh, "fem brep: a body with a brep reported fromMesh")
    check(Int(mesh.faceCount) == faces, "fem brep: the filleted part read back as \(mesh.faceCount) faces, not \(faces)")
    check(!edges.isEmpty && !vertices.isEmpty, "fem brep: a brep body has no edges or no vertices")
    check((0..<3).allSatisfy { k in mesh.nodeKind.contains(UInt32(k)) }, "fem brep: the nodes do not cover all three kinds")

    // `id` is the **body's own** edge id, not the index. The ids ascend, and at least one is not
    // its own index -- which is what catches an `id` filled from the loop counter.
    check(edges.map { $0.id } == edges.map { $0.id }.sorted(), "fem brep: the edge ids do not ascend")
    check(edges.enumerated().contains { UInt32($0.offset) != $0.element.id },
          "fem brep: every edge id equals its own index -- id is the index, not the body's id")
    for (i, edge) in edges.enumerated() {
        check(edge.runs.first == 0, "fem brep: edge \(i)'s first run does not start at 0")
        check(edge.runs.allSatisfy { Int($0) < edge.nodes.count }, "fem brep: edge \(i)'s runs leave its \(edge.nodes.count) nodes")
        check(edge.nodes.allSatisfy { Int($0) < mesh.nodes.count / 3 }, "fem brep: edge \(i) names a node past the mesh")
        // A closed body: every edge has two real faces, and neither is the sentinel.
        check(edge.faces.0 < mesh.faceCount && edge.faces.1 < mesh.faceCount,
              "fem brep: edge \(i) bounds faces \(edge.faces) of \(mesh.faceCount)")
        check(!edge.closed || edge.runs.count == 1, "fem brep: edge \(i) is closed with \(edge.runs.count) runs")
        if edge.seam { check(edge.faces.0 == edge.faces.1, "fem brep: edge \(i) is a seam but bounds \(edge.faces)") }
        // The ends resolve through `vertices` to the chain's own first or last node, which is
        // what tells `ends` from `faces` -- both a pair of UInt32 a swap leaves in range.
        for v in [edge.ends.0, edge.ends.1] where v != UInt32.max {
            check(Int(v) < vertices.count, "fem brep: edge \(i) ends at vertex \(v) of \(vertices.count)")
            let at = vertices[Int(v)]
            if at.node != UInt32.max {
                check(at.node == edge.nodes.first || at.node == edge.nodes.last,
                      "fem brep: edge \(i)'s end vertex \(v) is node \(at.node), which is neither end of its chain")
            }
        }
    }
    check(vertices.contains { $0.hasPosition }, "fem brep: no vertex has a position")
    check(vertices.allSatisfy { $0.hasPosition || $0.point == SIMD3(0, 0, 0) },
          "fem brep: a vertex with no position carries a point that is not zeroed")
    check(mesh.watertight && must("fem census") { try mesh.openEdges }.isEmpty && must("fem census") { try mesh.foldedEdges }.isEmpty,
          "fem brep: the closed filleted part is not watertight with both censuses empty")
    print("fem brep: \(mesh.nodes.count / 3) nodes, \(edges.count) edges (edge 0 id=\(edges[0].id)), \(vertices.count) vertices, \(mesh.faceCount) faces")
    mesh.free()

    // The B-rep path **does** read the options, and refuses a bad tolerance in the library's own
    // words -- which is what proves the wrapper hands the library's message up rather than one
    // of its own.
    do {
        _ = try node.femMesh(tolerance: 0)
        fail("fem brep: tolerance 0 was accepted")
    } catch {
        check("\(error)".contains("tolerance must be finite and > 0"), "fem brep: tolerance 0 was refused in other words: \(error)")
    }
}

/// The kernel over a solid: no mesh path, an owned `.msh` text, and a twelve-number `Frame`.
func femKernel(_ rounded: Solid) {
    let mesh = must("kernel fem_mesh") { try rounded.femMesh(tolerance: 0.05) }
    let edges = must("kernel fem edges") { try mesh.edges }
    let vertices = must("kernel fem vertices") { try mesh.vertices }
    femArrays(nodes: mesh.nodes, triangles: mesh.triangles, triangleFace: mesh.triangleFace,
              nodeKind: mesh.nodeKind, nodeEntity: mesh.nodeEntity, faceCount: mesh.faceCount,
              edges: edges.count, vertices: vertices.count, "kernel fem")
    check(!mesh.fromMesh, "kernel fem: a solid reported fromMesh -- the kernel has no mesh path")
    check(Int(mesh.faceCount) == must("faces") { try rounded.faces },
          "kernel fem: the mesh reports \(mesh.faceCount) faces, not the solid's")
    check(mesh.watertight && must("kernel fem census") { try mesh.openEdges }.isEmpty
          && must("kernel fem census") { try mesh.foldedEdges }.isEmpty,
          "kernel fem: the filleted part is not watertight with both censuses empty")
    let nodeCount = mesh.nodes.count / 3
    let longest = mesh.longestEdge

    // **A FEM mesh is not in the solid's tessellation cache**, so re-meshing the solid at
    // another tolerance -- which stales every `Solid.mesh` view -- leaves it alone, and neither
    // does closing the solid: the handle owns every array it lends. Catches reusing
    // `CacheFilling` as this mesh's owner, which would refuse a read the library never did.
    let held = mesh.nodes
    let firstNode = held[0]
    let tessellation = must("mesh") { try rounded.mesh(tolerance: 0.05) }
    _ = must("mesh") { try rounded.mesh(tolerance: 0.5) }
    _ = must("mesh") { try rounded.mesh(tolerance: 0.05) }
    check(tessellation.isStale, "kernel fem: the tessellation view is the one that goes stale")
    check(held.isValid && held[0] == firstNode, "kernel fem: re-meshing the solid staled the FEM mesh")
    mesh.free()
    check(!held.isValid, "kernel fem: free() left the views readable")

    // `maxSize` adds nodes and shortens the longest edge -- but it **bounds the boundary and only
    // targets the interior**, so the check is loose on purpose: a tighter pin would assert what
    // the ABI does not promise (measured at 1.03x on an unevenly parameterised face).
    let finer = must("kernel fem_mesh") { try rounded.femMesh(tolerance: 0.05, maxSize: 3) }
    check(finer.nodes.count / 3 > nodeCount && finer.longestEdge < longest,
          "kernel fem: maxSize 3 gave \(finer.nodes.count / 3) nodes (was \(nodeCount)) and a longest edge of \(finer.longestEdge) (was \(longest))")
    check(finer.longestEdge <= 3 * 1.05, "kernel fem: maxSize 3 left a \(finer.longestEdge) edge, past even the 1.03x the spec measured")
    print("kernel fem: \(nodeCount) nodes at maxSize 0, \(finer.nodes.count / 3) at 3.0 (longest \(longest) -> \(finer.longestEdge))")
    finer.free()

    // The **owned** `.msh` text: the kernel hands over a string this wrapper frees, where the
    // reader's is borrowed from its handle. Two asks are two independent strings; a wrapper
    // porting one side's convention onto the other leaks or double-frees.
    let again = must("kernel fem_mesh") { try rounded.femMesh(tolerance: 0.05) }
    let text = must("kernel msh_text") { try again.mshText() }
    check(must("kernel msh_text") { try again.mshText() } == text, "kernel fem: two asks for the .msh text disagree")
    check(text.hasPrefix("$MeshFormat\n4.1 0 8\n"), "kernel fem: the .msh text does not open as Gmsh 4.1 ASCII")
    let msh = temp.appendingPathComponent("cadaclysm-smoke-swift-kernel-fem.msh").path
    must("kernel save_msh") { try again.saveMsh(msh) }
    let written = ((try? FileManager.default.attributesOfItem(atPath: msh)[.size]) as? Int) ?? 0
    check(written >= text.utf8.count / 2, "kernel fem: save_msh wrote much less than the text")
    again.free()

    // The open sheet -- one face with a hole, so its rim is both loops. `watertight` false with
    // **both censuses empty** is the "not asked" trio, and every rim edge has a real face and
    // the sentinel for its second. Catches a wrapper that filled `face_b` with 0 where the ABI
    // said the sentinel: 0 is a real face.
    let sheet = must("face") { try Solid.face(try Profile.rect(20, 20).withHole(try Profile.circle(4)), try Frame.xy()) }
    let rim = must("kernel fem_mesh") { try sheet.femMesh(tolerance: 0.05) }
    let open = must("census") { try rim.openEdges }
    let folded = must("census") { try rim.foldedEdges }
    check(!rim.watertight && open.isEmpty && folded.isEmpty,
          "kernel fem: the open sheet reads watertight=\(rim.watertight) with \(open.count) open and "
          + "\(folded.count) folded rows -- the 'not asked' trio is all three")
    let rimEdges = must("kernel fem edges") { try rim.edges }
    check(!rimEdges.isEmpty, "kernel fem: the sheet has no edges")
    for (i, edge) in rimEdges.enumerated() {
        check(edge.faces.0 == 0 && edge.faces.1 == UInt32.max,
              "kernel fem: the sheet's rim edge \(i) reads faces \(edge.faces), not (0, NONE)")
    }
    print("kernel fem: the sheet's \(rimEdges.count) rim edges each bound face 0 and nothing else")
    rim.free()

    // The placement: **twelve** numbers as a `Frame`, where the reader takes sixteen
    // column-major. The same transform as `turnedMatrix()`, so `turned` is the one expected map
    // for both sides. A cuboid, because all eight of its corners are B-rep vertices and so
    // certainly nodes -- and **translated off the rotation's axis in x and y**, without which
    // the check is mathematically blind to a transposed 3x3 block (see the note above). With
    // this offset the right answer spans x 88..98, y 20..40 where the transposed one spans
    // x 102..112, y -40..-20: disjoint, which is what earns the catch.
    let (bx, by, bz) = (20.0, 10.0, 4.0)
    let off = SIMD3<Double>(30, 7, 5)
    let boxLo = off - SIMD3(bx, by, bz) / 2, boxHi = off + SIMD3(bx, by, bz) / 2
    let cuboid = must("cuboid") { try Solid.cuboid(bx, by, bz).translate(off.x, off.y, off.z) }
    let frame = must("frame") { try Frame(SIMD3(100, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1)) }
    let placed = must("kernel fem_mesh placed") { try cuboid.femMesh(tolerance: 0.05, placement: frame) }
    let there = femPoints(placed.nodes)
    for corner in femCorners(boxLo, boxHi) {
        let want = turned(corner)
        check(there.contains { near($0, want) },
              "kernel fem: the frame did not send the corner \(corner) to \(want) -- the nodes span \(femSpan(placed.nodes))")
    }
    let (lo, hi) = femSpan(placed.nodes)
    check(near(lo, turned(SIMD3(boxLo.x, boxHi.y, boxLo.z))) && near(hi, turned(SIMD3(boxHi.x, boxLo.y, boxHi.z))),
          "kernel fem: the placed cuboid spans \(lo)..\(hi), not the turn of \(boxLo)..\(boxHi)")
    print("kernel fem: the frame turns and moves the cuboid into \(lo)..\(hi)")
    placed.free()

    // The defaults are `FemOptions::default()`'s -- tolerance 0.01, maxSize 0 -- and **not**
    // `Solid.mesh`'s 0.05, which is the render mesher's default and the method directly above
    // `femMesh` in the wrapper. That slip shipped once and nothing here caught it, so the release
    // pipeline checks it too: the no-argument call must agree with an explicit 0.01 and disagree
    // with an explicit 0.05, the second being what gives the first any force.
    let byDefault = must("kernel fem_mesh") { try rounded.femMesh() }
    let stated = must("kernel fem_mesh") { try rounded.femMesh(tolerance: 0.01, maxSize: 0.0) }
    let renderDefault = must("kernel fem_mesh") { try rounded.femMesh(tolerance: 0.05) }
    check(byDefault.nodes.count == stated.nodes.count,
          "kernel fem: the default tolerance is not 0.01 -- \(byDefault.nodes.count / 3) nodes against \(stated.nodes.count / 3)")
    check(byDefault.nodes.count != renderDefault.nodes.count,
          "kernel fem: 0.01 and 0.05 mesh this body alike, so this check cannot tell them apart")
    print("kernel fem: the default tolerance meshes to \(byDefault.nodes.count / 3) nodes, 0.05 to \(renderDefault.nodes.count / 3)")
    byDefault.free()
    stated.free()
    renderDefault.free()

    // A tolerance the mesher refuses, in its own words -- the kernel has no mesh-only path, so
    // unlike the reader every solid goes through the options.
    do {
        _ = try rounded.femMesh(tolerance: 0)
        fail("kernel fem: tolerance 0 was accepted")
    } catch {
        check("\(error)".contains("tolerance must be finite and > 0"), "kernel fem: tolerance 0 was refused in other words: \(error)")
    }
}
