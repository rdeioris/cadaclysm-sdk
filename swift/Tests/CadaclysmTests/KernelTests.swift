// The kernel module over the release library: Python's test_cadaclysm_blacksmith.py, the
// parts that are not the reader's, plus the lifetimes and views only a native wrapper has.
//
// @testable, not plain `import Blacksmith`: `Assembly.place(_:raw:name:)` (the raw,
// unchecked twelve-number frame `testAssemblyFactsHoldAsPythonChecksThem` needs for fact
// 7) is internal on purpose -- a mirrored frame is not something the public API should
// invite -- so only a test target built with testability enabled can see it.
@testable import Blacksmith
import Cadaclysm
import Foundation
import XCTest

// `Selector` is qualified throughout: on Apple platforms Foundation has its own.
private typealias Pick = Blacksmith.Selector

private func plateOutline() throws -> Profile {
    try Profile.rect(80, 40).withHole(try Profile.circle(4)).withHole(try Profile.slot([25, 0], 24, 5))
}

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

/// The volume the mesh encloses, from its signed tetrahedra.
private func volume(_ solid: Solid) throws -> Double {
    let mesh = try solid.mesh()
    let p = mesh.positions.copy(), i = mesh.indices.copy()
    func v(_ k: UInt32) -> SIMD3<Double> {
        let o = Int(k) * 3
        return SIMD3(Double(p[o]), Double(p[o + 1]), Double(p[o + 2]))
    }
    var total = 0.0
    for t in stride(from: 0, to: i.count, by: 3) {
        let a = v(i[t]), b = v(i[t + 1]), c = v(i[t + 2])
        total += (a * SIMD3(b.y * c.z - b.z * c.y, b.z * c.x - b.x * c.z, b.x * c.y - b.y * c.x)).sum()
    }
    return total / 6
}

private func kinds(_ solid: Solid) throws -> [String] {
    try (0..<solid.faces).map { try solid.faceKind($0) }
}

private func assertClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tolerance: Double = 1e-6,
                         file: StaticString = #filePath, line: UInt = #line) {
    let d = a - b
    XCTAssertLessThanOrEqual(Swift.max(abs(d.x), abs(d.y), abs(d.z)), tolerance, "\(a) vs \(b)", file: file, line: line)
}

final class KernelTests: XCTestCase {
    func testTheLibraryReportsItself() throws {
        XCTAssertFalse(Blacksmith.version().isEmpty)
        XCTAssertFalse(Blacksmith.buildDate().isEmpty)
        XCTAssertFalse(Blacksmith.brepLayoutId().isEmpty)
        let line = Blacksmith.licenseInfo()
        XCTAssertFalse(line.isEmpty)
        XCTAssertNotNil(refusal {
            try Blacksmith.license("-----BEGIN LICENSE FILE-----\nnot a certificate\n-----END LICENSE FILE-----\n")
        })
        XCTAssertEqual(Blacksmith.licenseInfo(), line, "a refused license leaves the one in use")
        XCTAssertGreaterThanOrEqual(Blacksmith.licenseNoticeCount(), 0)
        XCTAssertTrue(try Blacksmith.defaultSchema().hasSuffix("ap203.exp"))
    }

    func testPrimitivesAndBounds() throws {
        let cube = try Solid.cuboid(20, 20, 20)
        XCTAssertEqual(try cube.faces, 6)
        let (lo, hi) = try cube.bounds
        assertClose(lo, [-10, -10, -10])
        assertClose(hi, [10, 10, 10])
        XCTAssertEqual(try cube.manifold, try Solid.cuboid(2, 2, 2).manifold)
        let m = try cube.manifold
        XCTAssertEqual([m.faces, m.edges, m.vertices], [6, 12, 8])
        XCTAssertTrue(m.isManifold && m.isClosed)
        XCTAssertTrue(m.description.contains("is_closed=true"))
        XCTAssertEqual(try cube.unpairedEdges(), 0)
        for solid in [try Solid.sphere(3), try Solid.cylinder(2, 5), try Solid.cone(2, 5),
                      try Solid.torus(5, 1), try Solid.wedge(4, 4, 4, 2),
                      try Solid.pyramid(4, 2, 4)] {
            XCTAssertTrue(try solid.isWatertight())
        }
        let (clo, chi) = try Solid.cylinder(2, 5).boundsAt(0.01)
        XCTAssertEqual(clo.z, 0, accuracy: 1e-9)
        XCTAssertEqual(chi.z, 5, accuracy: 1e-9)
        let sheet = try Solid.extrudeOpen(try Profile.rect(4, 4), try Frame.xy(), 2)
        XCTAssertFalse(try sheet.isWatertight())
        XCTAssertEqual(try sheet.manifold.boundaryEdges, 8)
        XCTAssertEqual(refusal { _ = try cube.leakedEdges(tolerance: -1) },
                       "leaked_edges: tolerance must be positive and finite")
    }

    func testThePlateWithAPinIsFilletedIntoAClosedPart() throws {
        let plate = try Workplane.xy().extrude(try plateOutline(), 6).solid()
        XCTAssertEqual(try plate.faces, 12)
        let pin = try Workplane.fromSolid(plate).faces(.max(.z)).workplane().cylinder(5, 10).solid()
        XCTAssertEqual(try pin.bounds.min.z, 6, accuracy: 1e-9, "built on the top face")
        XCTAssertEqual(try pin.faces, 3, "a build call replaces the solid; it does not join")
        let part = try plate.join(pin)
        XCTAssertGreaterThan(try part.faces, try plate.faces)
        let corners = try part.edges.filter { e in
            guard let d = e.direction, abs(d.z) > 0.99 else { return false }
            return try e.faces.allSatisfy { try part.faceKind($0) == "plane" }
        }
        XCTAssertEqual(corners.count, 4)
        let rounded = try part.fillet(corners, 1.0)
        XCTAssertEqual(try rounded.faces, try part.faces + 4, "each corner trades an edge for a face")
        XCTAssertTrue(try rounded.isWatertight())
        let m = try rounded.manifold
        XCTAssertTrue(m.isManifold && m.isClosed, "\(m)")
        let text = try rounded.stepText()
        XCTAssertTrue(text.hasPrefix("ISO-10303-21;"))
        XCTAssertTrue(text.contains("CYLINDRICAL_SURFACE") && text.contains("CLOSED_SHELL"))
        // The same by index, and the smoke's count: the plate alone, its four corners rounded.
        let plain = try Solid.extrude(try Profile.rect(80, 40).withHole(try Profile.circle(4)), try Frame.xy(), 6)
        let joined = try plain.join(try Workplane.fromSolid(plain).faces(.max(.z)).workplane().cylinder(5, 10).solid())
        let four = try joined.edges.filter { e in
            guard let d = e.direction, abs(d.z) > 0.99 else { return false }
            return try e.faces.allSatisfy { try joined.faceKind($0) == "plane" }
        }.map { $0.index }
        let smoke = try joined.fillet(four, 1.0)
        XCTAssertEqual(try smoke.faces, 15)
        XCTAssertTrue(try smoke.isWatertight() && smoke.manifold.isClosed)
        // A pin the hole's own radius touches the plate along an edge: refused.
        let flush = try Workplane.fromSolid(plain).faces(.max(.z)).workplane().cylinder(4, 10).solid()
        XCTAssertTrue(refusal { _ = try plain.join(flush) }?.contains("non-manifold") ?? false)
    }

    func testTheChainMirrorsTheRustWorkplane() throws {
        let plate = try Workplane.xy().extrude(try plateOutline(), 6).solid()
        XCTAssertEqual(refusal { try Workplane.fromSolid(plate).faces(Pick.index(999)) }?
            .hasPrefix("select_face: no face matches"), true)
        XCTAssertEqual(refusal { try Workplane.xy().faces(.max(.z)) },
                       "faces: the workplane holds no solid (BuildError::Empty)")
        XCTAssertEqual(refusal { _ = try Workplane.xy().solid() }, "solid: nothing was built (BuildError::Empty)")
        XCTAssertEqual(try Workplane.fromSolid(plate).workplane().frame, Workplane.xy().frame, "nothing picked: a no-op")
        let ring = try Profile.rect(2, 2).translate(5, 0)
        XCTAssertEqual(try Workplane.xy().revolve(ring, 2 * .pi).solid().faces, 4)
        let top = try plate.selectFace(.max(.z))
        XCTAssertEqual(try plate.faceFrame(top)[2], 6, accuracy: 1e-9)
        XCTAssertEqual(try plate.selectFace(.normal([0, 0, 1])), top)
        // translate keeps the selection, so workplane() adopts the moved face.
        let cube = try Workplane.xy().cuboid(10, 10, 10).solid()
        let moved = try Workplane.fromSolid(cube).faces(.max(.z)).translate(0, 0, 5).workplane()
        XCTAssertEqual(moved.frame[2], 10, accuracy: 1e-9)
        let onTop = try Workplane.xy().cuboid(10, 10, 10).faces(.max(.z)).workplane()
            .face(try Profile.circle(2)).solid()
        XCTAssertEqual(try onTop.faces, 1)
        XCTAssertEqual(try onTop.bounds.min.z, 5, accuracy: 1e-9)
        let wall = try Workplane.on(try Frame.xz([0, 3, 0])).extrude(try Profile.rect(10, 4), 1).solid()
        XCTAssertEqual(try wall.bounds.min.y, 2, accuracy: 1e-6)
        XCTAssertEqual(try wall.bounds.max.y, 3, accuracy: 1e-6)
        let bad = Workplane.xy()
        bad.frame = Array(bad.frame.prefix(11))
        XCTAssertEqual(refusal { try bad.extrude(try Profile.rect(1, 1), 1) }, "frame: expected 12 numbers, got 11")
    }

    func testFrameRules() throws {
        XCTAssertEqual(try Frame.xy().values, Workplane.xy().frame)
        XCTAssertEqual(try Frame.xz().values, Workplane.xz().frame)
        XCTAssertEqual(try Frame.yz().values, Workplane.yz().frame)
        // With no x, a normal along +Z, -Y or +X is exactly the matching world plane.
        XCTAssertEqual(try Frame.at([1, 2, 3], [0, 0, 7]), try Frame.xy([1, 2, 3]))
        XCTAssertEqual(try Frame.at([0, 0, 0], [0, -1, 0]), try Frame.xz())
        XCTAssertEqual(try Frame.at([0, 0, 0], [2, 0, 0]), try Frame.yz())
        // An x hint is laid onto the plane; y completes a right-handed frame.
        let f = try Frame.at(.zero, [0, 0, -1], x: [1, 1, 5])
        let r = 0.5.squareRoot()
        assertClose(f.x, [r, r, 0], 1e-12)
        assertClose(f.y, [r, -r, 0], 1e-12)
        XCTAssertEqual(f.z, [0, 0, -1])
        let t = try Frame.at(.zero, [1, 1, 1])
        XCTAssertEqual((t.x * t.z).sum(), 0, accuracy: 1e-12)
        assertClose(t.x, SIMD3(2, -1, -1) / 6.0.squareRoot(), 1e-12)
        // World X laid on the plane up to |n.x| = 0.9, world Y past it.
        assertClose(try Frame.at(.zero, [0.8, 0.6, 0]).x, [0.6, -0.8, 0], 1e-12)
        assertClose(try Frame.at(.zero, [0.95, 0.3, 0]).x, SIMD3(-0.3, 0.95, 0) / (0.95 * 0.95 + 0.09).squareRoot(), 1e-12)
        // ... which is the frame the library gives a face facing that way.
        let turned = try Solid.cuboid(10, 10, 10).rotate((.zero, [0, 0, 1]), .pi / 6)
        let side = try turned.selectFace(.normal([cos(.pi / 6), sin(.pi / 6), 0]))
        let sideFrame = try Frame.of(try turned.faceFrame(side))
        let expected = try Frame.at(sideFrame.origin, sideFrame.z)
        assertClose(sideFrame.x, expected.x, 1e-9)
        assertClose(sideFrame.y, expected.y, 1e-9)
        XCTAssertEqual(try Frame(t.origin, t.x, t.y, t.z), t)
        // No -0.0 anywhere, however the axes were computed.
        for frame in [try Frame.xz(), try Frame.at(.zero, [0, -1, 0]), try Frame.at(.zero, [0, 0, -1]),
                      try Frame.at(.zero, [-1, 0, 0]), try Frame.xz().offset(0)] {
            XCTAssertTrue(frame.values.allSatisfy { $0.sign == .plus || $0 != 0 }, "\(frame)")
        }
        // Moving it.
        XCTAssertEqual(try Frame.xy().offset(5), try Frame.xy([0, 0, 5]))
        assertClose(try Frame.xz().offset(2).origin, [0, -2, 0], 1e-12)
        XCTAssertEqual(try Frame.xy().translate(1, 2, 3).origin, [1, 2, 3])
        // The constructor normalises and refuses a frame that is not one.
        XCTAssertEqual(try Frame(.zero, [3, 0, 0], [0, 2, 0], [0, 0, 9]), try Frame.xy())
        XCTAssertEqual(refusal { _ = try Frame(.zero, [1, 0, 0], [1, 1, 0], [0, 0, 1]) },
                       "Frame: the axes are not square to each other")
        XCTAssertEqual(refusal { _ = try Frame(.zero, [1, 0, 0], [0, 1, 0], [0, 0, -1]) },
                       "Frame: the axes are left-handed (z must be x × y)")
        XCTAssertEqual(refusal { _ = try Frame.at(.zero, .zero) }, "Frame.at: normal has no direction")
        XCTAssertEqual(refusal { _ = try Frame.at(.zero, [0, 0, 1], x: [0, 0, -2]) },
                       "Frame.at: x lies along the normal")
        XCTAssertEqual(refusal { _ = try Frame.xy([.infinity, 0, 0]) }, "Frame: origin must be three finite numbers")
        XCTAssertEqual(refusal { _ = try Frame.of([0, 0, 0]) }, "frame: expected 12 numbers, got 3")
        // It goes wherever a frame goes, and reads a face's frame back.
        let lid = try Solid.extrude(try Profile.rect(10, 4), try Frame.xy([0, 0, 5]), 2)
        assertClose(try lid.bounds.min, [-5, -2, 5])
        assertClose(try lid.bounds.max, [5, 2, 7])
        let top = try Frame.of(try lid.faceFrame(try lid.selectFace(.max(.z))))
        XCTAssertEqual(top.origin.z, 7, accuracy: 1e-9)
        zip(top.values, try Frame.xy([0, 0, 7]).values).forEach { XCTAssertEqual($0, $1, accuracy: 1e-9) }
        let front = try lid.faceFrame(try lid.selectFace(.min(.y)))
        zip(front, try Frame.xz([0, -2, 6]).values).forEach { XCTAssertEqual($0, $1, accuracy: 1e-9) }
    }

    func testTwoCirclesHitTwiceAndATangentTouches() throws {
        let five: Double = 5
        let crossing = try Profile.circle(five).hits(try Profile.circle(five).translate(6, 0))
        XCTAssertEqual(crossing.count, 2)
        let ys = crossing.map { $0.start.y }.sorted()
        XCTAssertEqual(ys[0], -4, accuracy: 1e-12)
        XCTAssertEqual(ys[1], 4, accuracy: 1e-12)
        for h in crossing {
            XCTAssertFalse(h.run || h.touch)
            XCTAssertEqual(h.start, h.end)
            XCTAssertEqual(h.start.x, 3, accuracy: 1e-12)
            XCTAssertEqual(h.aStart.loopIndex, 0)
            XCTAssertEqual(h.aStart.face, UInt32.max)
            // (3, 4) is t 0.2952 on the first circle's upper arc, 0.7048 on the moved one's
            let (ta, tb) = h.start.y > 0 ? (0.2952, 0.7048) : (0.7048, 0.2952)
            XCTAssertEqual(h.aStart.t, ta, accuracy: 1e-3)
            XCTAssertEqual(h.bStart.t, tb, accuracy: 1e-3)
        }
        let tangent = try Profile.path([-10, 5]).lineTo(10, 5).endOpen()
        let touched = try Profile.circle(five).hits(tangent)
        XCTAssertEqual(touched.count, 1)
        XCTAssertTrue(touched[0].touch && !touched[0].run)
        let runs = try Profile.rect(10, 10).hits(try Profile.rect(10, 10).translate(5, 0)).filter { $0.run }
        XCTAssertEqual(runs.count, 2)
        XCTAssertTrue(refusal { _ = try Profile.circle(1).hits(try Profile.circle(2), tolerance: -1) }?
            .contains("profile_hits: tolerance must be positive and finite") ?? false)
        XCTAssertTrue(try Profile.circle(1).hits(try Profile.circle(2).translate(10, 0)).isEmpty)
    }

    func testALineThroughACuboidHitsTwiceAndCutsThreePieces() throws {
        let box = try Solid.cuboid(10, 20, 30)
        let line = try Profile.path([-20, 0]).lineTo(20, 0).endOpen()
        let found = try box.hits(line, try Frame.xy())
        XCTAssertEqual(found.description, "SolidHits(hits=2, pieces=3)")
        XCTAssertEqual(found.hits.count, 2)
        for (h, x) in zip(found.hits, [-5.0, 5.0]) {
            XCTAssertFalse(h.run || h.touch)
            XCTAssertEqual(h.start.x, x, accuracy: 0.05)
            XCTAssertEqual(h.aStart.segment, 0)
            XCTAssertEqual(h.aStart.face, UInt32.max)
            XCTAssertNotEqual(h.bStart.face, UInt32.max)
            XCTAssertTrue(h.bStart.u.isFinite && h.bStart.v.isFinite)
        }
        XCTAssertEqual(found.pieces.map { $0.inside }, [false, true, false])
        let (first, middle, last) = (found.pieces[0], found.pieces[1], found.pieces[2])
        XCTAssertEqual([first.start.t, last.end.t], [0, 1])
        XCTAssertEqual([first.end.t, middle.end.t], [middle.start.t, last.start.t], "the pieces run head to tail")
        let (lo, hi) = try Solid.extrudeOpen(middle.profile, try Frame.xy(), 1).bounds
        XCTAssertEqual(lo.x, -5, accuracy: 0.05, "the middle piece starts on the box")
        XCTAssertEqual(hi.x, 5, accuracy: 0.05, "the middle piece ends on the box")
        _ = try SweepPath.along(middle.profile, try Frame.xy(), open: true)
        // A loop no hit cuts is one piece, outside here; an open sheet has no pieces.
        let far = try box.hits(try Profile.circle(1), try Frame.xy([100, 0, 0]))
        XCTAssertTrue(far.hits.isEmpty)
        XCTAssertEqual(far.pieces.map { $0.inside }, [false])
        let sheet = try Solid.face(try Profile.rect(20, 20), try Frame.xy())
        let across = try sheet.hits(try Profile.path([0, -20]).lineTo(0, 20).endOpen(), try Frame.xz())
        XCTAssertFalse(across.hits.isEmpty)
        XCTAssertTrue(across.pieces.isEmpty)
        XCTAssertEqual(refusal { _ = try box.hits(line, try Frame.xy(), tolerance: -1) },
                       "solid_profile_hits: tolerance must be positive and finite")
    }

    func testTwoCirclesShareOneLensOfArcs() throws {
        let a = try Profile.circle(5)
        let b = try Profile.circle(5).translate(6, 0)
        let lenses = try a.common(b)
        XCTAssertEqual(lenses.count, 1)
        // Four arcs (each circle's own seam stays a join) between two caps.
        XCTAssertEqual(try Solid.extrude(lenses[0], try Frame.xy(), 1).faces, 6)
        XCTAssertTrue(try a.common(try b.translate(100, 0)).isEmpty)
        XCTAssertTrue(refusal { _ = try a.common(b, tolerance: -1) }?
            .contains("profile_common: tolerance must be positive and finite") ?? false)
    }

    func testEveryEdgeCarriesItsExactCurve() throws {
        func norm(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
        // A cylinder's rims are circles of its radius about a cap centre, in a unit frame, a whole turn each.
        let cyl = try Solid.cylinder(5, 3)
        let rims = try cyl.edges.filter { $0.kind == "circle" }.map { $0.curve }
        XCTAssertGreaterThanOrEqual(rims.count, 2)
        for case let c? in rims {
            XCTAssertEqual(c.kind, "circle")
            XCTAssertEqual(c.radius, 5, accuracy: 1e-9)
            XCTAssertEqual(c.radius2, 5, accuracy: 1e-9)
            XCTAssertEqual(c.origin.x, 0, accuracy: 1e-9)
            XCTAssertEqual(c.origin.y, 0, accuracy: 1e-9)
            XCTAssertLessThan(min(abs(c.origin.z), abs(c.origin.z - 3)), 1e-9)
            XCTAssertEqual(norm(c.x), 1, accuracy: 1e-9)
            XCTAssertEqual(norm(c.y), 1, accuracy: 1e-9)
            XCTAssertEqual((c.x * c.y).sum(), 0, accuracy: 1e-9)
            XCTAssertEqual(abs(c.t1 - c.t0), 2 * Double.pi, accuracy: 1e-9, "a whole rim is one edge: a full turn")
            XCTAssertEqual(c.degree, 0)
            XCTAssertTrue(c.knots.isEmpty && c.poles.isEmpty && c.weights == nil)
            XCTAssertTrue(c.description.hasPrefix("Curve('circle', origin=("))
        }
        XCTAssertFalse(rims.contains { $0 == nil })
        // A cuboid's edges are lines: `origin + x` is the far end, both ends its own vertices.
        for e in try Solid.cuboid(2, 4, 6).edges {
            let c = try XCTUnwrap(e.curve)
            XCTAssertEqual(c.kind, "line")
            XCTAssertEqual([c.t0, c.t1], [0, 1])
            let far = c.origin + c.x
            let ends = e.segments.flatMap { [$0.start, $0.end] }
            XCTAssertTrue(ends.contains { norm($0 - c.origin) < 1e-9 })
            XCTAssertTrue(ends.contains { norm($0 - far) < 1e-9 })
            XCTAssertEqual(c.y, SIMD3(0, 0, 0))
            XCTAssertEqual(c.z, SIMD3(0, 0, 0))
            XCTAssertEqual(c.radius, 0)
        }
        // A closed spline extruded: its wall's seam edge is the NURBS itself.
        let square: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        let loop = try Solid.extrude(try Profile.spline(square, degree: 3, closed: true), try Frame.xy(), 2)
        let splines = try loop.edges.filter { $0.kind == "nurbs" }.compactMap { $0.curve }
        XCTAssertFalse(splines.isEmpty, "the extruded spline keeps a nurbs edge")
        for c in splines {
            XCTAssertEqual(c.kind, "nurbs")
            XCTAssertEqual(c.degree, 3)
            XCTAssertEqual(c.knots.count, c.poles.count + c.degree + 1)
            XCTAssertNil(c.weights)
            XCTAssertTrue(c.knots[c.degree] <= c.t0 && c.t0 < c.t1 && c.t1 <= c.knots[c.poles.count])
        }
        // A kernel shape's edges all have an exact curve.
        for solid in [cyl, loop, try Solid.sphere(2)] {
            XCTAssertTrue(try solid.edges.allSatisfy { $0.curve != nil })
        }
    }

    func testTwoCrossedPipesIntersectOnEllipseChainsAndCoaxialPipesOverlap() throws {
        let tol = 1e-3
        func offA(_ p: SIMD3<Double>) -> Double { abs((p.x * p.x + p.y * p.y).squareRoot() - 1) }
        func offB(_ p: SIMD3<Double>) -> Double { abs((p.x * p.x + (p.z - 3) * (p.z - 3)).squareRoot() - 1) }
        // Two equal pipes crossing at right angles: `a` up z, `b` along y through a's middle.
        let a = try Solid.cylinder(1, 6)
        let b = try Solid.cylinder(1, 6).rotate((origin: SIMD3(0, 0, 3), direction: SIMD3(1, 0, 0)), Double.pi / 2)
        let (facesA, facesB) = (try a.faces, try b.faces)
        let found = try a.intersect(b, tolerance: tol)
        XCTAssertGreaterThanOrEqual(found.chains.count, 2, "the saddle splits into chains")
        XCTAssertTrue(found.overlaps.isEmpty, "a transversal crossing has no coincident face pair")
        var kinds: [String] = []
        for c in found.chains {
            XCTAssertTrue(c.faceA >= 0 && c.faceA < facesA && c.faceB >= 0 && c.faceB < facesB)
            XCTAssertGreaterThanOrEqual(c.points.count, 2)
            for p in c.points { XCTAssertTrue(offA(p) < 50 * tol && offB(p) < 50 * tol, "off a surface: \(p)") }
            guard let curve = c.curve else { continue }
            XCTAssertTrue(["ellipse", "nurbs"].contains(curve.kind), curve.description)
            kinds.append(curve.kind)
            if curve.kind == "ellipse" {
                let t = (curve.t0 + curve.t1) / 2   // the curve's own point, mid-chain
                let along: SIMD3<Double> = curve.x * (curve.radius * cos(t))
                let across: SIMD3<Double> = curve.y * (curve.radius2 * sin(t))
                let q: SIMD3<Double> = curve.origin + along + across
                XCTAssertTrue(offA(q) < 50 * tol && offB(q) < 50 * tol, "the ellipse leaves the pipes: \(q)")
            }
            XCTAssertTrue(c.description.hasPrefix("Chain(points="))
        }
        XCTAssertTrue(kinds.contains("ellipse"), "two equal pipes cross on ellipses")
        // Apart: nothing, and not an error. A bad tolerance is refused in the kernel's words.
        let apart = try a.intersect(try b.translate(10, 0, 0))
        XCTAssertTrue(apart.chains.isEmpty && apart.overlaps.isEmpty, apart.description)
        XCTAssertTrue(refusal { _ = try a.intersect(b, tolerance: -1) }?.hasPrefix("intersect: tolerance must be positive and finite") ?? false)
        // Two coaxial pipes overlapping in height share a wall band: rings on that wall.
        let lower = try Solid.cylinder(1, 4)
        let upper = try Solid.cylinder(1, 4).translate(0, 0, 2)
        let (facesLower, facesUpper) = (try lower.faces, try upper.faces)
        let shared = try lower.intersect(upper, tolerance: tol)
        XCTAssertGreaterThanOrEqual(shared.overlaps.count, 1, "the overlapping wall band is an overlap")
        let o = try XCTUnwrap(shared.overlaps.first)
        XCTAssertTrue(o.faceA >= 0 && o.faceA < facesLower && o.faceB >= 0 && o.faceB < facesUpper)
        XCTAssertGreaterThanOrEqual(o.loops.count, 1, "a coaxial wall band closes into rings")
        for ring in o.loops {
            XCTAssertGreaterThanOrEqual(ring.count, 3, "a ring is at least a triangle")
            for p in ring { XCTAssertTrue(offA(p) < 50 * tol && p.z >= 2 - 50 * tol && p.z <= 4 + 50 * tol, "off the shared band: \(p)") }
        }
        XCTAssertEqual(o.description, "Overlap(faces=(\(o.faceA), \(o.faceB)), loops=\(o.loops.count))")
    }

    func testTheColliderFindsOverlappingPartsAndRebuildsTheOverlap() throws {
        // Two cuboids overlapping by 2 along x, plus one far away -> one hit (0, 1), depth 2.
        let xy0 = try Frame.xy()
        let a = try Solid.cuboid(4, 4, 4)
        let b = try Solid.cuboid(4, 4, 4).translate(2, 0, 0)
        let c = try Solid.cuboid(4, 4, 4).translate(100, 0, 0)
        XCTAssertTrue(try a.boundsBox.overlaps(try b.boundsBox), "the two overlapping cuboids' bounds boxes do not overlap")
        let collider = try Collider([a, b, c])
        XCTAssertEqual(try collider.groupCount, 3)
        let stats0 = try collider.stats
        XCTAssertEqual(stats0.considered, 0, "no check yet")
        let hits = try collider.check([xy0, xy0, xy0])
        XCTAssertEqual(hits.count, 1)
        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit.a, 0)
        XCTAssertEqual(hit.b, 1)
        XCTAssertTrue(hit.overlap && hit.kind == "overlap" && hit.text.isEmpty)
        XCTAssertEqual(hit.depth, 2.0, accuracy: 1e-9)
        let overlap = try hit.solid()
        XCTAssertGreaterThan(try overlap.faces, 0)
        let stats1 = try collider.stats
        XCTAssertEqual(stats1.considered, 3, "considered is every candidate pair among the three parts, box filtering aside")
        XCTAssertGreaterThanOrEqual(stats1.confirmed + stats1.closedForm + stats1.meshed, 1)
        let movedFar = try Frame(values: [100, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        let far = try collider.check([xy0, movedFar, movedFar])
        XCTAssertTrue(far.isEmpty)
        collider.close()
        XCTAssertTrue(refusal { _ = try collider.check([xy0, xy0, xy0]) }?.hasPrefix("collider: closed") ?? false)
    }

    func testTheColliderRefusesAShortGroupsList() throws {
        let a = try Solid.cuboid(2, 2, 2)
        let b = try Solid.cuboid(2, 2, 2).translate(1, 0, 0)
        XCTAssertTrue(refusal { _ = try Collider([a, b], groups: [0]) }?
            .contains("groups must have one entry per solid (2 solids, 1 groups)") ?? false)
    }

    func testACollisionHitsSolidSurvivesTheColliderClosing() throws {
        // solid() keeps the collisions handle (not the collider) alive: closing the collider
        // itself must not take the hit's own rebuild with it.
        let xy0 = try Frame.xy()
        let a = try Solid.cuboid(2, 2, 2)
        let b = try Solid.cuboid(2, 2, 2).translate(1, 0, 0)
        let collider = try Collider([a, b])
        let hits = try collider.check([xy0, xy0])
        collider.close()
        XCTAssertEqual(hits.count, 1)
        let overlap = try hits[0].solid()
        XCTAssertGreaterThan(try overlap.faces, 0)
    }

    func testTheColliderRefusesAPartThatIsNotAClosedSolid() throws {
        let sheet = try Solid.cuboid(2, 2, 2).faceSheet(0)
        XCTAssertTrue(refusal { _ = try Collider([sheet]) }?.contains("collider_new: part 0 is not a closed solid") ?? false)
    }

    func testProfilesAndPaths() throws {
        XCTAssertTrue(refusal { _ = try Profile.rect(0, 1) }?.hasPrefix("profile_rect: width and height must be positive") ?? false)
        let xy = try Frame.xy()
        let rounded = try Profile.path([0, 0]).lineTo(10, 0).lineTo(10, 8).arcTo(8, 10, [8, 8], ccw: true)
            .lineTo(0, 10).lineTo(0, 0).end()
        XCTAssertEqual(try kinds(try Solid.extrude(rounded, xy, 2)).filter { $0 == "cylinder" }.count, 1)
        XCTAssertTrue(refusal { _ = try Profile.path([0, 0]).lineTo(10, 0).end() }?
            .hasPrefix("path_end: the path ends at") ?? false)
        // An open chain, ended open: its walls alone, or closed by a straight side.
        let chain = try Profile.path([0, 0]).lineTo(10, 0).lineTo(10, 8).lineTo(0, 10).endOpen()
        XCTAssertEqual(try Solid.extrudeOpen(chain, xy, 5).faces, 3)
        XCTAssertEqual(try Solid.extrude(chain, xy, 5).faces, 6)
        // A Bezier, ended open, is one wall; a line then a Bezier back to the start, a solid.
        let wave = try Profile.path([0, 0]).bezierTo([20, 0], [20, 20], [40, 10]).endOpen()
        XCTAssertEqual(try Solid.extrudeOpen(wave, xy, 2).faces, 1)
        let arch = try Profile.path([0, 0]).lineTo(40, 0).bezierTo([40, 20], [0, 20], [0, 0]).end()
        XCTAssertTrue(try Solid.extrude(arch, xy, 2).isWatertight())
        let ell = try Profile.path([0, 0]).lineTo(10, 0).lineTo(10, 5).endOpen()
        XCTAssertEqual(try Solid.extrude(try ell.closeLoop(), xy, 2).faces, 5)
        // A NURBS segment: a quadratic arc-ish bump back to the start.
        let bump = try Profile.path([0, 0]).lineTo(10, 0).nurbsTo([[5, 8], [0, 0]], [0, 0, 0, 1, 1, 1], 2).end()
        XCTAssertTrue(try Solid.extrude(bump, xy, 1).isWatertight())
        // The builder is consumed by end() and endOpen().
        let consumed = try Profile.path([0, 0]).lineTo(1, 0).lineTo(0, 0)
        _ = try consumed.end()
        XCTAssertEqual(refusal { try consumed.lineTo(2, 2) }, "path: already ended")
        XCTAssertEqual(refusal { _ = try consumed.endOpen() }, "path: already ended")
        // Polygons, splines, loops, chains, rounds.
        let hexagon = try Solid.extrude(try Profile.regularPolygon([0, 0], 10, 6), xy, 2)
        XCTAssertEqual(try hexagon.faces, 8)
        let square: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        XCTAssertEqual(try Solid.extrude(try Profile.spline(square, degree: 3, closed: true), xy, 2).faces, 3)
        XCTAssertEqual(try Solid.extrudeOpen(try Profile.spline(square, weights: [1, 2, 2, 1]), xy, 2).faces, 1)
        XCTAssertEqual(refusal { _ = try Profile.regularPolygon([0, 0], 10, 2) },
                       "profile_regular_polygon: a polygon has at least 3 sides, not 2")
        // A five-pointed star: ten walls and two caps.
        let star = try Solid.extrude(try Profile.star([0, 0], 10, 4, 5), xy, 2)
        XCTAssertEqual(try star.faces, 12)
        XCTAssertTrue(try star.isWatertight())
        XCTAssertEqual(refusal { _ = try Profile.star([0, 0], 10, 10, 5) },
                       "profile_star: the inner radius must be under the outer")
        // A count a UInt32 cannot hold is refused before the call, never clamped.
        for n in [-1, (1 << 32) + 6] {
            XCTAssertEqual(refusal { _ = try Profile.regularPolygon([0, 0], 10, n) },
                           "profile_regular_polygon: sides is out of range: \(n)")
            XCTAssertEqual(refusal { _ = try Profile.star([0, 0], 10, 4, n) },
                           "profile_star: points is out of range: \(n)")
        }
        // Text: an `i` is two shapes and an `o` one; the `o` extrudes to a watertight ring
        // with spline edges; an unknown family sets in the bundled face; bad bytes are refused.
        let word = try Profile.text("io", size: 10)
        XCTAssertEqual(word.count, 3)
        let textRing = try Solid.extrude(word[2], xy, 2)
        XCTAssertTrue(try textRing.isWatertight())
        XCTAssertTrue(try textRing.edges.contains { $0.kind == "nurbs" })
        XCTAssertEqual(try Profile.text("g", size: 10, font: "No Such Family Anywhere").count, 1)
        XCTAssertEqual(try Profile.text("", size: 10).count, 0)
        XCTAssertEqual(refusal { _ = try Profile.text("x", size: 0) }, "profile_text: the size must be positive and finite")
        XCTAssertEqual(refusal { _ = try Profile.text("x", size: 10, fontBytes: [1, 2, 3]) }, "profile_text: the font bytes are not a font")
        XCTAssertEqual(refusal { _ = try Profile.spline(Array(square.prefix(2)), closed: true) },
                       "spline: a closed spline needs at least three points")
        XCTAssertEqual(try Solid.extrude(try Profile.fromLoops([try Profile.circle(4), try Profile.rect(30, 30)]), xy, 2)
            .faces, 8)
        XCTAssertEqual(refusal { _ = try Profile.fromLoops([try Profile.rect(30, 30), try Profile.circle(4).translate(100, 0)]) },
                       "from_loops: loop 1 lies outside loop 0")
        let top = try Profile.path([-10, 5]).lineTo(10, 5).endOpen()
        let right = try Profile.path([10, -5]).arcTo(10, 5, [10, 0]).endOpen()
        let bottom = try Profile.path([10, -5]).lineTo(-10, -5).endOpen()
        let left = try Profile.path([-10, -5]).arcTo(-10, 5, [-10, 0], ccw: false).endOpen()
        let slot = try Solid.extrude(try Profile.chain([top, bottom, left, right]), xy, 2)
        XCTAssertEqual(try slot.faces, 6)
        XCTAssertEqual(try kinds(slot).filter { $0 == "cylinder" }.count, 2)
        XCTAssertEqual(refusal { _ = try Profile.chain([]) }, "chain: no pieces")
        let near = [try Profile.path([0, 0]).lineTo(5, 0).endOpen(), try Profile.path([5.0005, 0]).lineTo(5, 5).endOpen()]
        XCTAssertEqual(try Solid.extrudeOpen(try Profile.chain(near, tolerance: 1e-3), xy, 1).faces, 2)
        let plate = try Solid.extrude(try Profile.rect(20, 10).round(2), xy, 1)
        XCTAssertEqual(try kinds(plate).filter { $0 == "cylinder" }.count, 4)
        let one = try Solid.extrude(try Profile.rect(20, 10).round(2, corners: [1]), xy, 1)
        XCTAssertEqual(try kinds(one).filter { $0 == "cylinder" }.count, 1)
        let elbow = try Profile.path([0, 0]).lineTo(10, 0).lineTo(10, 10).endOpen()
        XCTAssertEqual(try Solid.extrudeOpen(try elbow.round(3, open: true), xy, 1).faces, 3)
        XCTAssertEqual(refusal { _ = try Profile.rect(20, 10).round(30) }, "round: the radius 30 does not fit corner 0")
        let bow = try Profile.polygon([[-30, -20], [30, 20], [30, -20], [-30, 20]])
        XCTAssertEqual(refusal { _ = try Solid.extrude(bow, xy, 10) }, "extrude: the profile crosses itself")
    }

    func testChamferTaperAndLoft() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let vertical = try cube.edges.filter { $0.isLine && abs($0.direction?.z ?? 0) > 0.99 }
        XCTAssertEqual(vertical.count, 4)
        XCTAssertTrue(try cube.edges.allSatisfy { $0.faces.count == 2 && !$0.segments.isEmpty })
        let bevelled = try cube.chamfer(vertical, 1.0)
        XCTAssertEqual(try bevelled.faces, 10)
        XCTAssertTrue(try kinds(bevelled).allSatisfy { $0 == "plane" }, "a chamfer is flat")
        XCTAssertEqual(try cube.chamfer(vertical.map { $0.index }, 1.0).faces, 10)
        XCTAssertTrue(refusal { _ = try cube.chamfer(vertical, 0) }?.hasPrefix("chamfer: ") ?? false)
        XCTAssertEqual(try cube.fillet(vertical, 1.0).faces, 10)
        XCTAssertTrue(refusal { _ = try cube.fillet(vertical, 0) }?.hasPrefix("fillet: ") ?? false)
        XCTAssertTrue(try Solid.cylinder(1, 2).edges.filter { !$0.isLine }.allSatisfy { $0.direction == nil })

        let xy = try Frame.xy()
        let rect = try Profile.rect(20, 10)
        let drafted = try Solid.extrudeTapered(rect, xy, 8, 10 * .pi / 180)
        XCTAssertEqual(try drafted.faces, 6)
        XCTAssertEqual(try drafted.bounds.max.x, 10 + 8 * tan(10 * .pi / 180), accuracy: 1e-6)
        XCTAssertEqual(try Solid.extrudeOpenTapered(rect, xy, 8, 10 * .pi / 180).faces, 4)
        let lifted = try Frame.xy([0, 0, 15])
        let frustum = try Solid.loft(try Profile.rect(20, 20), xy, try Profile.rect(10, 10), lifted)
        XCTAssertEqual(try frustum.faces, 6)
        XCTAssertEqual(try Solid.loftOpen(try Profile.rect(20, 20), xy, try Profile.rect(10, 10), lifted).faces, 4)
        XCTAssertTrue(refusal { _ = try Solid.loft(try Profile.rect(20, 20), xy, try Profile.circle(5), lifted) }?
            .hasPrefix("loft: ") ?? false)
    }

    func testShell() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let box = try cube.shell(1.0, open: [try cube.selectFace(.max(.z))])
        XCTAssertGreaterThan(try box.faces, 6)
        XCTAssertTrue(refusal { _ = try cube.shell(0) }?.hasPrefix("shell: ") ?? false)
        let block = try Solid.cuboid(40, 40, 20)
        let tray = try block.shell(3.0, open: [try block.selectFace(.min(.z))])
        XCTAssertEqual(try tray.faces, 11, "five walls in and out, and the rim")
        XCTAssertTrue(try tray.stepText().contains("CLOSED_SHELL"))
        let hollowed: Double = 32_000 - 19_652   // 40 x 40 x 20 less the 34 x 34 x 17 inside
        XCTAssertEqual(try volume(tray), hollowed, accuracy: 1)
    }

    func testATubeSweptThroughItselfReportsItsCrossingAndACubeNothing() throws {
        let tol = 1e-3
        // A thin rectangle swept open along a path that comes back across its own start: a line
        // to (10, 0, 0), a 270-degree turn about (10, 3, 0), a line down to (7, -5, 0) -- through
        // the first leg at (7, 0). The profile's x along world y, its y along world z.
        let back = try SweepPath.at(.zero).lineTo([10, 0, 0]).arc([10, 3, 0], [0, 0, 1], 1.5 * .pi).lineTo([7, -5, 0])
        let square = try Frame(SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        let tube = try Solid.sweepOpen(try Profile.rect(0.2, 5), square, back)
        let faces = try tube.faces
        let crossed = try tube.selfIntersections(tolerance: tol)
        XCTAssertFalse(crossed.chains.isEmpty, "the tube passes through itself at (7, 0)")
        for c in crossed.chains {
            XCTAssertTrue(c.faceA != c.faceB && c.faceA < faces && c.faceB < faces, "two walls, not a fold: \(c)")
            XCTAssertEqual(c.curve?.kind, "line", "two planar walls cross in a line")
            for p in c.points {
                XCTAssertTrue(abs(p.x - 7) <= 0.1 + tol && abs(p.y) <= 0.1 + tol && abs(p.z) <= 2.5 + tol, "off the crossing: \(p)")
            }
        }
        let clean = try Solid.cuboid(4, 6, 8).selfIntersections(tolerance: tol)
        XCTAssertTrue(clean.chains.isEmpty && clean.overlaps.isEmpty, clean.description)
        XCTAssertTrue(refusal { _ = try tube.selfIntersections(tolerance: -1) }?.hasPrefix("self_intersect: tolerance must be positive and finite") ?? false)
    }

    func testCheckFindsATubeThroughItselfItsFreeEdgesForACutAndNothingWrongWithTwoCubes() throws {
        let tol = 1e-3
        // The tube of the test above: an open sheet passing through itself at (7, 0).
        let back = try SweepPath.at(.zero).lineTo([10, 0, 0]).arc([10, 3, 0], [0, 0, 1], 1.5 * .pi).lineTo([7, -5, 0])
        let square = try Frame(SIMD3(0, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        let tube = try Solid.sweepOpen(try Profile.rect(0.2, 5), square, back)
        let cube = try Solid.cuboid(1, 1, 1)
        XCTAssertEqual(try cube.check(), [])
        XCTAssertEqual(try cube.check(try Solid.sphere(2), "join", tolerance: tol), [])
        let alone = try tube.check(tolerance: tol)
        XCTAssertFalse(alone.isEmpty, "the tube passes through itself")
        for f in alone {
            XCTAssertEqual(f.kind, "self_intersection", "an open sheet is no fault alone: \(f)")
            XCTAssertEqual(f.argument, 0)
            XCTAssertTrue(f.index != nil && f.other != nil && f.index != f.other && f.size > 0.1, f.description)
        }
        let asCut = try tube.check(cube, "cut", tolerance: tol)
        let open = asCut.filter { $0.kind == "open" }
        XCTAssertFalse(open.isEmpty, "the tube is open")
        XCTAssertTrue(open.allSatisfy { $0.argument == 0 && $0.other != nil && $0.size > 0 }, open.description)
        XCTAssertTrue(asCut.allSatisfy { $0.argument == 0 }, "the cube is fine")
        XCTAssertTrue(try cube.check(tube, "trim", tolerance: tol).contains { $0.kind == "open" && $0.argument == 1 }, "a trim's tool must be closed")
        let small = try Solid.cuboid(4, 4, 0.01).check(tolerance: 0.05)
        XCTAssertTrue(small.contains { $0.kind == "short_edge" && $0.index != nil && $0.other == nil && $0.size < 0.05 }, small.description)
        XCTAssertEqual(refusal { _ = try cube.check(cube, "union") },
                       "check: unknown operation \"union\" (join, cut, common, split_sheet, trim, merge or intersect)")
        XCTAssertEqual(refusal { _ = try cube.check(tolerance: -1) }, "check: tolerance must be positive and finite")
    }

    func testAProfileIsSweptAlongAPathOfLinesAndArcs() throws {
        let xy = try Frame.xy()
        let rect = try Profile.rect(10, 10)
        let lPath = try SweepPath.at(.zero).lineTo([0, 0, 40]).lineTo([30, 0, 40])
        let bent = try Solid.sweep(rect, xy, lPath)
        XCTAssertEqual(try Solid.sweep(rect, xy, lPath).faces, try bent.faces, "the path is only borrowed")
        let circle = try Profile.circle(2)
        let arcPath = try SweepPath.at(.zero).arc([10, 0, 0], [0, 1, 0], .pi / 2)
        let quarter = try Solid.sweep(circle, xy, arcPath)
        XCTAssertTrue(try kinds(quarter).contains("revolution"))
        XCTAssertTrue(try quarter.isWatertight())
        XCTAssertLessThan(try Solid.sweepOpen(circle, xy, arcPath).faces, try quarter.faces)
        XCTAssertTrue(refusal { _ = try Solid.sweep(rect, xy, try SweepPath.at(.zero)) }?
            .contains("the path has no pieces") ?? false)
        XCTAssertTrue(refusal { _ = try Solid.sweep(rect, xy, try SweepPath([0, 0, 1]).lineTo([0, 0, 5])) }?
            .contains("must start on the profile's plane") ?? false)
        // A pipe along a line and an arc: a rod and a tube.
        let path = try SweepPath([0, 0, 0]).lineTo([0, 0, 10]).arc([10, 0, 10], [0, 1, 0], .pi / 2)
        let length = 10 + 2 * Double.pi * 10 / 4
        let rod = try Solid.pipe(path, 2)
        XCTAssertTrue(try rod.isWatertight())
        XCTAssertEqual(try volume(rod), .pi * 4 * length, accuracy: .pi * 4 * length * 0.02)
        XCTAssertTrue(try Solid.pipe(path, 2, thickness: 0.5).isWatertight())
        XCTAssertTrue(refusal { _ = try Solid.pipe(path, 2, thickness: 2) }?.hasPrefix("pipe: the thickness must be") ?? false)
        // A free curve, fitted with biarcs.
        let wave = try Profile.path([0, 0]).bezierTo([20, 0], [20, 20], [40, 10]).endOpen()
        let along = try SweepPath.along(wave, xy, tolerance: 0.01)
        let start = try Frame(.zero, [0, 1, 0], [0, 0, 1], [1, 0, 0])
        XCTAssertTrue(try Solid.sweep(circle, start, along).isWatertight())
        let loop = try SweepPath.along(try Profile.rect(40, 20).round(5), xy, open: false)
        XCTAssertTrue(try Solid.sweep(try Profile.circle(1), try Frame(.init(-15, -10, 0), [0, 1, 0], [0, 0, 1], [1, 0, 0]), loop)
            .isWatertight())
        XCTAssertEqual(refusal { _ = try SweepPath.along(wave, xy, tolerance: -1) },
                       "along: the tolerance must be positive and finite")
        path.close()
        path.close()
        XCTAssertEqual(refusal { _ = try Solid.pipe(path, 2) }, "sweep_path: closed")
        // A coil: a round wire as a spring.
        let spring = try Solid.coil(try Profile.circle(2).translate(20, 0), (.zero, [0, 0, 1]), 8, 2.5)
        XCTAssertTrue(try spring.isWatertight())
        XCTAssertTrue(refusal { _ = try Solid.coil(try Profile.circle(2).translate(20, 0), (.zero, [0, 0, 1]), 3, 2) }?
            .hasPrefix("coil: the pitch must be taller than the section") ?? false)
    }

    func testRevolvesAndExtrudeBetween() throws {
        let xy = try Frame.xy()
        let ring = try Profile.rect(2, 2).translate(5, 0)
        XCTAssertEqual(try Solid.revolve(ring, (.zero, [0, 1, 0]), 2 * .pi).faces, 4)
        let line = try Profile.path([5, 0]).lineTo(5, 10).endOpen()
        XCTAssertEqual(try Solid.revolveOpen(line, (.zero, [0, 1, 0]), .pi).faces, 1)
        let plate = try Profile.polygon([[-8, 0], [-5, 0], [-5, 10], [-8, 10]])
        let quarter = try Solid.revolveInPlane(plate, xy, [0, 0], [0, 1], .pi / 2)
        let (lo, hi) = try quarter.bounds
        XCTAssertEqual(lo.x, -8, accuracy: 1e-6)
        XCTAssertEqual(hi.z, 8, accuracy: 1e-6)
        XCTAssertEqual(refusal { _ = try Solid.revolveInPlane(plate, xy, [-6, 0], [-6, 1], 1) },
                       "revolve_in_plane: the profile crosses the axis")
        XCTAssertEqual(try Solid.revolveOpenInPlane(line, xy, [0, 0], [0, 1], .pi).faces, 1)

        let rect = try Profile.rect(80, 40)
        let between = try Solid.extrudeBetween(rect, xy, 0, Slant.flat(6))
        let plain = try Solid.extrude(rect, xy, 6)
        XCTAssertEqual(try between.faces, try plain.faces)
        XCTAssertEqual(try between.bounds.max, try plain.bounds.max)
        let flat = try Slant.ofPlane(xy, [0, 0, 6], [0, 0, 1])
        XCTAssertEqual(flat.at, 6, accuracy: 1e-9)
        XCTAssertEqual(Swift.max(abs(flat.grad.x), abs(flat.grad.y)), 0, accuracy: 1e-9)
        XCTAssertEqual(refusal { _ = try Slant.ofPlane(xy, [0, 0, 6], [1, 0, 0]) },
                       "slant_of_plane: the plane holds the sweep direction")
        let shifted = try rect.translate(40, 0)
        let sloped = try Solid.extrudeBetween(shifted, xy, .flat(0), Slant(6, grad: [0.25, 0]))
        XCTAssertEqual(try sloped.bounds.max.z, 26, accuracy: 1e-6)
        XCTAssertTrue(refusal { _ = try Solid.extrudeBetween(rect, xy, 0, Slant(6, grad: [0.25, 0])) }?
            .hasPrefix("extrude_between: ") ?? false)
        XCTAssertGreaterThan(try Solid.extrudeOpenBetween(shifted, xy, 0, Slant(6, grad: [0.25, 0])).leakedEdges(), 0)
    }

    func testSolidsCombineMoveAndSplit() throws {
        let a = try Solid.cuboid(2, 2, 2)
        let b = try a.translate(1, 1, 1)
        XCTAssertGreaterThan(try a.join(b).faces, 6)
        assertClose(try a.common(b).bounds.min, .zero)
        XCTAssertGreaterThan(try a.cut(b).faces, 6)
        XCTAssertTrue(refusal { _ = try a.join(b, tolerance: -1) }?.hasPrefix("join: ") ?? false)
        _ = try a.rotate((.zero, [0, 0, 1]), .pi / 2)
        _ = try a.mirror(try Frame.xy())
        XCTAssertEqual(try Solid.cylinder(1, 3).place(try Frame.xy([0, 0, 5])).bounds.min.z, 5, accuracy: 1e-6)
        let holed = try Solid.cuboid(4, 4, 4).cut(try Solid.cylinder(1, 6).translate(0, 0, -1))
        XCTAssertTrue(try holed.manifold.isClosed)
        // merge_flush and push_pull.
        let box = try Solid.cuboid(40, 20, 10)
        let top = try box.selectFace(.max(.z))
        let joined = try box.join(try box.faceSheet(top).extrudeFaces(6))
        XCTAssertEqual(try joined.faces, 10)
        XCTAssertEqual(try joined.mergeFlush().faces, 6)
        XCTAssertEqual(try box.join(try box.faceSheet(top).extrudeFaces(6), merge: true).faces, 6)
        let taller = try box.pushPull(top, 6)
        XCTAssertEqual(try taller.faces, 6)
        XCTAssertEqual(try taller.bounds.max.z, 11, accuracy: 1e-6)
        // A revolved profile's faces lie on revolutions, which do not push; a ball's face
        // moves out, the ball a step bigger (as Python's test has it since 0.4.2).
        let turned = try Solid.revolve(Profile.circle(2).translate(10, 0), (.zero, [0, 1, 0]), 2 * .pi)
        let curved = try (0..<turned.faces).first { try turned.faceKind($0) != "plane" }!
        XCTAssertEqual(refusal { _ = try turned.pushPull(curved, 2) }, "push_pull: no planar face to raise")
        let ball = try Solid.sphere(5).pushPull(0, 1)
        XCTAssertTrue(try ball.isWatertight())
        XCTAssertEqual(try ball.faces, 1)
        XCTAssertEqual(try volume(ball), try volume(Solid.sphere(6)), accuracy: try volume(Solid.sphere(6)) * 1e-3)
        // Faces pushed together: the box's top and +x side, 5 taller and 5 longer, each face
        // found again after the other's push; a can's top and wall, taller and fatter.
        let grown = try box.pushPull([top, try box.selectFace(.max(.x))], 5)
        XCTAssertTrue(try grown.isWatertight())
        XCTAssertEqual(try grown.faces, 6)
        let grownVolume: Double = 45 * 20 * 15
        XCTAssertEqual(try volume(grown), grownVolume, accuracy: grownVolume * 1e-9)
        let can = try Solid.cylinder(5, 10)
        let wall = try (0..<can.faces).first { try can.faceKind($0) == "cylinder" }!
        let both = try can.pushPull([try can.selectFace(.max(.z)), wall], 2)
        XCTAssertTrue(try both.isWatertight())
        XCTAssertEqual(try both.faces, 3)
        let fatter = try volume(Solid.cylinder(7, 12))
        XCTAssertEqual(try volume(both), fatter, accuracy: fatter * 1e-4)
        XCTAssertEqual(refusal { _ = try box.pushPull([Int](), 2) }, "push_pull: no faces to push")
        // A round made again and taken back: the box's edge rounded 2, made again at 3 as the
        // fillet at 3 makes it, and taken off, the box again.
        let slab = try Solid.cuboid(30, 20, 12)
        let edge = try slab.edges.first { $0.isLine && abs($0.direction!.x) > 0.99 }!
        let rounded = try slab.fillet([edge], 2)
        let band = try (0..<rounded.faces).first { try rounded.faceKind($0) == "cylinder" }!
        let again = try rounded.refillet(band, 3)
        XCTAssertTrue(try again.isWatertight())
        XCTAssertEqual(try again.faces, 7)
        XCTAssertEqual(try volume(again), try volume(slab.fillet([edge], 3)), accuracy: try volume(again) * 1e-6)
        let sharp = try rounded.unfillet(band)
        XCTAssertTrue(try sharp.isWatertight())
        XCTAssertEqual(try sharp.faces, 6)
        XCTAssertEqual(try volume(sharp), try volume(slab), accuracy: try volume(slab) * 1e-9)
        XCTAssertTrue(refusal { _ = try slab.unfillet(0) }?.hasPrefix("unfillet: the face is not a round") ?? false)
        // A chamfer the same: cut 2, cut again at 3 as the chamfer at 3 cuts it, taken off.
        let bevelled = try slab.chamfer([edge], 2)
        let bevel = try (0..<bevelled.faces).first {
            try bevelled.faceKind($0) == "plane" && ![0.0, 1.0, -1.0].contains(try bevelled.faceFrame($0)[11])
        }!
        let recut = try bevelled.rechamfer(bevel, 3)
        XCTAssertTrue(try recut.isWatertight())
        XCTAssertEqual(try recut.faces, 7)
        XCTAssertEqual(try volume(recut), try volume(slab.chamfer([edge], 3)), accuracy: try volume(recut) * 1e-6)
        XCTAssertEqual(try bevelled.unchamfer(bevel).faces, 6)
        XCTAssertTrue(refusal { _ = try slab.unchamfer(0) }?.hasPrefix("unchamfer: the face is not a chamfer") ?? false)
        // Split by a plane, by a solid; lumps.
        let block = try Solid.cuboid(20, 10, 6).coloured("#ff0000")
        let halves = try block.splitByPlane(try Frame(.init(4, 0, 0), [0, 1, 0], [0, 0, 1], [1, 0, 0]))
        XCTAssertEqual(halves.count, 2)
        XCTAssertEqual(try volume(halves[0]), 6 * 10 * 6, accuracy: 1e-3)
        XCTAssertEqual(try halves[0].colour, [1, 0, 0])
        let cube = try Solid.cuboid(20, 20, 20)
        let parts = try cube.split(try Solid.cylinder(4, 40).translate(0, 0, -20))
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(try volume(parts[1]), .pi * 16 * 20, accuracy: .pi * 16 * 20 * 0.02)
        XCTAssertEqual(try cube.lumps().count, 1)
        XCTAssertTrue(refusal { _ = try cube.splitByPlane(try Frame.xy([0, 0, 50])) }?
            .hasPrefix("split_by_plane: the plane does not cross the solid") ?? false)
    }

    /// A rectangle drawn on a plane above a sphere cores it: the ball with a square hole first,
    /// then the core, their volumes adding up to the ball's.
    func testASolidIsSplitByAProfilePushedThroughIt() throws {
        let ball = try Solid.sphere(10)
        let pieces = try ball.splitByProfile(try Profile.rect(6, 6), try Frame.xy([0, 0, 40]))
        XCTAssertEqual(pieces.count, 2)
        let (outside, inside) = (try volume(pieces[0]), try volume(pieces[1]))
        XCTAssertTrue(inside > 0 && inside < outside)
        XCTAssertEqual(outside + inside, try volume(ball), accuracy: 0.01 * (try volume(ball)))
        XCTAssertTrue(refusal { _ = try ball.splitByProfile(try Profile.circle(4), try Frame.xy([30, 0, 0])) }?
            .hasPrefix("split_by_profile: ") ?? false)
    }

    /// A rectangle's open box thickened out is the box a thickness bigger all round less the
    /// box, thickened in the box less the box a thickness smaller; a tube thickens to a pipe
    /// that writes. Python's test_a_sheet_is_thickened_either_side.
    func testASheetIsThickenedEitherSide() throws {
        let walls = try Solid.extrudeOpen(Profile.rect(20, 10), Frame.xy(), 8)
        let volumes = try [1.0, -1.0].map { try volume(walls.thicken($0)) }.sorted()
        // Spelled as typed constants: older compilers time out type-checking the literals inline.
        let inward: Double = 8 * (200 - 18 * 8), outward: Double = 8 * (22 * 12 - 200)
        XCTAssertEqual(volumes[0], inward, accuracy: inward * 1e-6)
        XCTAssertEqual(volumes[1], outward, accuracy: outward * 1e-6)
        XCTAssertTrue(try walls.thicken(1.0).isWatertight())
        let pipe = try Solid.extrudeOpen(Profile.circle(10), Frame.xy(), 15).thicken(1.5)
        XCTAssertTrue(try pipe.isWatertight())
        XCTAssertTrue(try pipe.stepText().contains("CLOSED_SHELL"))
        XCTAssertTrue(refusal { _ = try walls.thicken(0) }?.hasPrefix("thicken: ") ?? false)
    }

    func testSheetsFacesAndTrim() throws {
        let xy = try Frame.xy()
        let sheet = try Solid.face(try plateOutline(), xy)
        XCTAssertEqual(try sheet.faces, 1)
        XCTAssertEqual(Array(try sheet.faceFrame(0)[9...]), [0, 0, 1])
        XCTAssertGreaterThan(try sheet.leakedEdges(), 0)
        let raised = try sheet.extrudeFaces(6)
        XCTAssertTrue(try raised.isWatertight())
        XCTAssertEqual(try raised.faces, try Solid.extrude(try plateOutline(), xy, 6).faces)
        let plate = try Solid.extrude(try Profile.rect(80, 40).withHole(try Profile.circle(10)), xy, 6)
        let top = try plate.selectFace(.max(.z))
        XCTAssertEqual(try plate.faceSheet(top).faces, 1)
        XCTAssertEqual(try plate.dropFaces([top, 0, 0]).faces, try plate.faces - 2)
        XCTAssertEqual(refusal { _ = try plate.faceSheet(8) }, "face_sheet: no face 8 -- the solid has 8 (0 to 7)")
        XCTAssertEqual(refusal { _ = try plate.dropFaces(Array(0..<8)) }, "drop_faces: dropping every face leaves nothing")
        let square = try Solid.face(try Profile.rect(20, 20), try Frame.xy([0, 0, 5]))
        let peg = try Solid.extrude(try Profile.circle(4), xy, 12)
        let holed = try square.trim(peg)
        let disc = try square.trim(peg, keep: "inside")
        XCTAssertEqual(try holed.faces + disc.faces, try square.splitSheet(peg).faces)
        XCTAssertEqual(refusal { _ = try square.trim(peg, keep: "both") },
                       "trim: keep must be 'outside' or 'inside', not 'both'")
        XCTAssertEqual(refusal { _ = try square.trim(try peg.translate(100, 0, 0), keep: "inside") },
                       "trim: nothing of the sheet lies inside the tool")
    }

    func testColoursAreSetReadBackAndInherited() throws {
        let block = try Solid.cuboid(10, 10, 10)
        XCTAssertNil(try block.colour)
        XCTAssertNil(try block.faceColour(0))
        let top = try block.selectFace(.max(.z))
        let gold = try block.coloured("#cc9966")
        XCTAssertNil(try block.colour, "a new solid; the original is untouched")
        XCTAssertEqual(try gold.colour, [0.8, 0.6, 0.4])
        let painted = try gold.coloured([0.2, 0.4, 1.0], face: top)
        XCTAssertEqual(try painted.faceColour(top), [0.2, 0.4, 1.0])
        XCTAssertEqual(try painted.faceColour((top + 1) % 6), [0.8, 0.6, 0.4])
        XCTAssertEqual(try Solid.cuboid(1, 1, 1).coloured("#f00").colour, [1, 0, 0])
        XCTAssertEqual(try painted.translate(5, 0, 0).faceColour(top), [0.2, 0.4, 1.0])
        XCTAssertTrue(refusal { _ = try block.coloured([1.5, 0, 0]) }?.hasPrefix("coloured: r, g and b must be in 0..1") ?? false)
        XCTAssertEqual(refusal { _ = try block.coloured("#fff", face: 6) }, "coloured: face 6 is not one of the solid's 6")
        XCTAssertEqual(refusal { _ = try block.coloured("#fff", face: -1) }, "coloured: face -1 is not one of the solid's 6")
        XCTAssertEqual(refusal { _ = try block.faceColour(6) }, "colour: face 6 is not one of the solid's 6")
        // Fullwidth digits are hex digits to Character but not to Int(radix:): refused, not a trap.
        XCTAssertNotNil(refusal { _ = try block.coloured("#ＦＦＦ") })
    }

    func testColouredTakesCssNames() throws {
        let box = try Solid.cuboid(1, 1, 1)
        XCTAssertEqual(try box.coloured("red").colour, SIMD3<Double>(1, 0, 0))
        XCTAssertEqual(try box.coloured("#0f0").colour, SIMD3<Double>(0, 1, 0))
        XCTAssertThrowsError(try box.coloured("notacolour")) { e in
            XCTAssertTrue("\(e)".contains("a CSS colour name"))
        }
        XCTAssertEqual(try packed("navy"), 0x000080)
        XCTAssertThrowsError(try packed("bogus")) { e in
            let text = "\(e)"
            XCTAssertTrue(text.contains("not 'bogus'"))
            XCTAssertFalse(text.contains("0..1"))
        }
    }

    func testProfileAndEdgeColours() throws {
        let rect = try Profile.rect(10, 4)
        XCTAssertNil(try rect.colour)
        let gold = try rect.coloured("#cc9966")
        XCTAssertEqual(try gold.colour, [0.8, 0.6, 0.4])
        XCTAssertNil(try rect.colour, "the original is untouched")
        XCTAssertEqual(try gold.translate(1, 1).colour, [0.8, 0.6, 0.4], "carried by a move")
        XCTAssertThrowsError(try rect.coloured([2, 0, 0])) { error in
            XCTAssertTrue((error as? BuildError)?.message.hasPrefix("profile_coloured: r, g and b must be in 0..1") ?? false)
        }
        let xy = try Frame.xy()
        XCTAssertNil(try Solid.extrude(gold, xy, 3).colour, "a profile's colour stays 2D")

        let cube = try Solid.cuboid(10, 10, 10)
        XCTAssertNil(try cube.edgeColour(0))
        XCTAssertEqual(try cube.edgePolylineColours(), [], "no edge paint: nothing to colour")
        let allGold = try cube.edgesColoured("#cc9966")
        let two = try allGold.edgesColoured([0.2, 0.4, 1.0], edges: [try cube.edges[0].index, 5])
        XCTAssertEqual(try two.edgeColour(5), [0.2, 0.4, 1.0], "the edge's own")
        XCTAssertEqual(try two.edgeColour(1), [0.8, 0.6, 0.4], "the all-edges colour")
        XCTAssertEqual(try two.translate(1, 0, 0).edgeColour(5), [0.2, 0.4, 1.0])
        XCTAssertEqual(try allGold.edgesColoured([1, 0, 0], edges: []).edgeColour(0), [0.8, 0.6, 0.4],
                       "an empty list colours nothing")
        XCTAssertEqual(refusal { _ = try cube.edgesColoured("#f00", edges: [12]) },
                       "edges_coloured: edge 12 is not one of the solid's 12")
        XCTAssertEqual(refusal { _ = try cube.edgeColour(12) }, "edge_colour: edge 12 is not one of the solid's 12")
        // Negative goes through Swift's own guard (UInt32(edge) would trap), not the library's.
        XCTAssertEqual(refusal { _ = try cube.edgeColour(-1) }, "edge_colour: edge -1 is not one of the solid's 12")
        let colours = try two.edgePolylineColours()
        XCTAssertEqual(colours.count, try two.edgePolylines().count)
        for c in colours { XCTAssertTrue(c == SIMD3(0.8, 0.6, 0.4) || c == SIMD3(0.2, 0.4, 1.0), "\(String(describing: c))") }
        XCTAssertTrue(colours.contains(SIMD3(0.2, 0.4, 1.0)))
        XCTAssertEqual(refusal { _ = try two.edgePolylineColours(tolerance: -1) },
                       "edge_polyline_colours: tolerance must be positive and finite")
    }

    /// The library reads a fixed number of weights whatever the array holds, so a wrong count
    /// is refused here rather than read past.
    func testWeightsOfTheWrongCountAreRefused() throws {
        let square: [SIMD2<Double>] = [[0, 0], [10, 0], [10, 10], [0, 10]]
        XCTAssertNoThrow(try Profile.spline(square, weights: [1, 2, 1, 1], closed: true))
        XCTAssertEqual(refusal { _ = try Profile.spline(square, weights: [1, 1], closed: true) },
                       "spline: 2 weights for 4 points; give one per point")
        XCTAssertNotNil(refusal { _ = try Profile.spline(square, weights: [], closed: true) })
        XCTAssertNoThrow(try Path([0, 0]).nurbsTo([[5, 5], [10, 0]], [0, 0, 0, 1, 1, 1], 2, weights: [1, 0.5, 1]).endOpen())
        XCTAssertEqual(refusal { _ = try Path([0, 0]).nurbsTo([[5, 5], [10, 0]], [0, 0, 0, 1, 1, 1], 2, weights: [1, 1]) },
                       "nurbs_to: 2 weights for 3 control points (the current point and 2 given); give one per point")
    }

    func testAReflectorIsDrawnAndRevolvedFromAParabola() throws {
        let xy = try Frame.xy()
        // A dish 100 wide, focal length 20, opening up: from rim to rim on the parabola,
        // closed by the rim line, revolved about the axis -- one NURBS wall, watertight.
        let dish = try Profile.parabola(vertex: [0, 0], axis: [0, 1], focal: 20, from: 0, to: 50).lineTo(0, 31.25).lineTo(0, 0).end()
        let bowl = try Solid.revolveInPlane(dish, xy, [0, 0], [0, 1], 2 * Double.pi)
        XCTAssertTrue(try bowl.isWatertight())
        XCTAssertTrue(try (0..<bowl.faces).contains { try bowl.faceKind($0) == "revolution" })
        // The dish's own arc by vertex, closed by a second parabola through the same rim
        // points with a focus beyond the chord -- the arch over the top, not the dish again
        // (a focus at (0, 20) would rebuild the identical arc and retrace it, per
        // `parabolaByFocus`'s own doc comment on this reflector).
        let arch = try Profile.path([-50, 31.25]).parabolaByVertex(50, 31.25, vertex: [0, 0]).parabolaByFocus(-50, 31.25, focus: [0, 40]).end()
        XCTAssertTrue(try Solid.extrude(arch, xy, 2).isWatertight())
        // A conic with a quarter circle's weight; a parabola by its end tangents.
        let quarter = try Profile.path([10, 0]).conicTo(0, 10, control: [10, 10], weight: cos(Double.pi / 4)).lineTo(0, 0).lineTo(10, 0).end()
        XCTAssertEqual(try Solid.extrude(quarter, xy, 2).faces, 5)
        let bump = try Profile.path([0, 0]).parabolaTo(10, 0, control: [5, 5]).lineTo(0, 0).end()
        XCTAssertEqual(try Solid.extrude(bump, xy, 2).faces, 4)
        XCTAssertNoThrow(try Profile.path([0, 0]).hyperbolaTo(10, 0, control: [5, 5], weight: 2).lineTo(0, 0).end())
        XCTAssertEqual(refusal { _ = try Profile.path([0, 0]).conicTo(2, 0, control: [1, 0], weight: 1) },
                       "path_conic_to: the control point lies on the chord")
        XCTAssertEqual(refusal { _ = try Profile.path([0, 0]).hyperbolaTo(2, 0, control: [1, 1], weight: 1) },
                       "hyperbola_to: the weight must be over 1 (1 is a parabola, under 1 an ellipse)")
        XCTAssertEqual(refusal { _ = try Profile.parabola(vertex: [0, 0], axis: [0, 0], focal: 1, from: -1, to: 1) },
                       "path_parabola: the axis direction is zero")
    }

    func testStepTextAndFiles() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let text = try plate.stepText()
        XCTAssertTrue(text.hasPrefix("ISO-10303-21;"))
        XCTAssertTrue(text.contains("CONFIG_CONTROL_DESIGN"), "the built-in AP203")
        XCTAssertTrue(try plate.stepText(schema: "AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF")
            .contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"))
        XCTAssertTrue(try plate.stepText(schema: try Blacksmith.defaultSchema()).hasPrefix("ISO-10303-21;"),
                      "a schema file's path")
        XCTAssertTrue(refusal { _ = try plate.stepText(schema: "NO_SUCH_SCHEMA") }?
            .contains("no built-in schema named NO_SUCH_SCHEMA") ?? false)
        XCTAssertEqual(refusal { _ = try plate.stepText(unit: "ft") }, "unit must be one of ['in', 'm', 'mm']")
        let both = try Blacksmith.writeStepText([plate, try Solid.cuboid(1, 1, 1)], unit: "in")
        XCTAssertEqual(both.components(separatedBy: "CLOSED_SHELL(").count - 1, 2)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-tests-\(UUID()).stp").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try plate.step(path)
        // The same file, but for the header's time stamp.
        let written = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(written.components(separatedBy: "DATA;").last, text.components(separatedBy: "DATA;").last)
        try Blacksmith.writeStep(path, [plate])
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("ISO-10303-21;"))
    }

    func testSvg() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)

        let text = try plate.svgText()
        XCTAssertTrue(text.hasPrefix("<svg"))
        XCTAssertTrue(text.contains("<path"))

        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-tests-svg-\(UUID()).svg").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try plate.svg(path)
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).hasPrefix("<svg"))

        let both = try Blacksmith.writeSvgText([plate, try Solid.cuboid(1, 1, 1)])
        // Two bodies' line groups, plus the plate's silhouette group: silhouettes are on by
        // default since fc978acfc, and a cuboid has no silhouette curves to draw.
        XCTAssertEqual(both.components(separatedBy: "<g ").count - 1, 3)

        // No convention over the kernel: `up` left nil falls back to Z, not a scene's, so a
        // Y-up ask still reads differently from the default.
        let zUp = try plate.svgText(SvgOptions(up: .z))
        let yUp = try plate.svgText(SvgOptions(up: .y))
        XCTAssertNotEqual(zUp, yUp)

        XCTAssertTrue(refusal { _ = try plate.svgText(SvgOptions(fov: 200)) }?.contains("fov") ?? false)
        XCTAssertNotNil(refusal { _ = try plate.svg(path, options: SvgOptions(margin: -1)) })

        // stroke and background take colour text, read by the kernel's own parser.
        let named = try plate.svgText(SvgOptions(stroke: "Lime", background: "Navy"))
        XCTAssertTrue(named.contains("#000080"), named.prefix(300).description)
        XCTAssertTrue(named.lowercased().contains("#00ff00"), named.prefix(300).description)
        XCTAssertTrue(refusal { _ = try plate.svgText(SvgOptions(background: "bogus")) }?.hasPrefix("svg: background:") ?? false)

        // A profile draws its own plane, top by default -- a sketch lies in z = 0, so its own
        // plane already is the page, unlike a solid's default (`.iso`), which has no plane of
        // its own to prefer. Pinned against an explicit iso view, not just checked non-empty:
        // a top default silently left at iso would make the two calls equal.
        let outline = try plateOutline()
        let profileText = try outline.svgText()
        XCTAssertTrue(profileText.hasPrefix("<svg"))
        XCTAssertTrue(profileText.contains("<path"))
        XCTAssertNotEqual(profileText, try outline.svgText(SvgOptions(view: .iso)))
        let profilePath = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-tests-svg-profile-\(UUID()).svg").path
        defer { try? FileManager.default.removeItem(atPath: profilePath) }
        try outline.svg(profilePath)
        XCTAssertTrue(try String(contentsOfFile: profilePath, encoding: .utf8).hasPrefix("<svg"))

        // The module writer draws a solid and a profile together, one <g> per drawable.
        let mixed = try Blacksmith.writeSvgText([plate], [outline])
        XCTAssertTrue(mixed.contains("id=\"solid-0\""))
        XCTAssertTrue(mixed.contains("id=\"profile-0\""))
        let mixedPath = FileManager.default.temporaryDirectory.appendingPathComponent("kernel-tests-svg-mixed-\(UUID()).svg").path
        defer { try? FileManager.default.removeItem(atPath: mixedPath) }
        try Blacksmith.writeSvg(mixedPath, [plate], [outline])
        XCTAssertTrue(try String(contentsOfFile: mixedPath, encoding: .utf8).hasPrefix("<svg"))
    }

    func testMeshViewsAndTheirCopies() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let mesh = try plate.mesh(tolerance: 0.05)
        XCTAssertEqual(mesh.positions.count, mesh.vertexCount * 3)
        XCTAssertEqual(mesh.normals.count, mesh.positions.count)
        XCTAssertEqual(mesh.indexCount % 3, 0)
        XCTAssertGreaterThan(mesh.triangleCount, 0)
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        let lines = try plate.edgePolylines(tolerance: 0.05)
        XCTAssertGreaterThanOrEqual(lines.count, 12)
        XCTAssertTrue(lines.allSatisfy { $0.count % 3 == 0 && $0.count >= 6 })
        XCTAssertEqual(lines.reduce(0) { $0 + $1.count }, lines.pointCount * 3)
        let meshCopy = mesh.copy()
        let linesCopy = lines.copy()
        let firstRun = Array(lines[0])
        let firstPosition = Array(mesh.positions)

        // A view holds its own tessellation, not the solid: it does not need the solid to stay
        // reachable, so the last reference to a solid going may free it right away even with a
        // live view outstanding.
        weak var alive: Solid?
        var liveView: Blacksmith.Mesh?
        do {
            let temporary = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
            liveView = try temporary.mesh(tolerance: 0.05)
            alive = temporary
        }
        XCTAssertNil(alive, "a view does not keep its solid alive")
        XCTAssertGreaterThan(liveView?.triangleCount ?? 0, 0)

        // Closed, the views still read exactly what they read before -- they own their own
        // tessellation, not the solid's cache.
        plate.close()
        XCTAssertFalse(mesh.isStale)
        XCTAssertFalse(lines.isStale)
        XCTAssertEqual(Array(mesh.positions), firstPosition)
        XCTAssertTrue(mesh.indices.allSatisfy { Int($0) < mesh.vertexCount })
        XCTAssertEqual(Array(lines[0]), firstRun)
        XCTAssertFalse(meshCopy.isStale)
        XCTAssertEqual(meshCopy.positions.count, mesh.positions.count)
        XCTAssertTrue(meshCopy.indices.allSatisfy { Int($0) < meshCopy.vertexCount })
        XCTAssertEqual(Array(linesCopy[0]), firstRun)
        XCTAssertEqual(linesCopy.count, lines.count)
        XCTAssertEqual(refusal { _ = try plate.faces }, "solid: closed")
        XCTAssertEqual(refusal { _ = try plate.mesh() }, "solid: closed")
    }

    /// **Catches:** a view built over the legacy `cadaclysm_blacksmith_mesh`/`_edge_polylines`
    /// calls against the solid's own cache, with an owner that never invalidates -- exactly the
    /// break check in the task brief. A held tessellation must survive re-meshing the solid at
    /// any number of other tolerances, and the span read from it before must still compare
    /// equal after.
    func testAViewOutlivesAReMeshAtAnotherTolerance() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let fine = try plate.mesh(tolerance: 0.05)
        XCTAssertFalse(fine.isStale)
        let span = Array(fine.positions)
        _ = try plate.mesh(tolerance: 0.5)
        XCTAssertFalse(fine.isStale, "a held tessellation is not staled by meshing the solid again")
        XCTAssertEqual(Array(fine.positions), span)
        _ = try plate.boundsAt(0.2)
        XCTAssertFalse(fine.isStale, "a held tessellation is not staled by bounds at another tolerance")
        _ = try plate.mesh(tolerance: 0.01)
        XCTAssertFalse(fine.isStale, "not even back at a tolerance the cache once held (0.05, 0.5, 0.2, 0.01)")
        XCTAssertEqual(Array(fine.positions), span)
    }

    func testMesh64AndBounds64AgreeWithF32OnSmallCoordinates() throws {
        // Catches mesh64's normals wired to the wrong pointer (e.g. raw.positions reused for
        // normals too): the far test below never inspects normals, only positions and bounds.
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let mesh = try plate.mesh(tolerance: 0.05)
        let mesh64 = try plate.mesh64(tolerance: 0.05)
        XCTAssertEqual(mesh64.vertexCount, mesh.vertexCount)
        XCTAssertEqual(mesh64.indexCount, mesh.indexCount)
        XCTAssertEqual(Array(mesh64.indices), Array(mesh.indices), "one tessellation, one index buffer")
        XCTAssertEqual(Float(mesh64.positions[0]), mesh.positions[0], "the f32 mesh is the f64 one narrowed")
        XCTAssertEqual(Float(mesh64.normals[0]), mesh.normals[0])

        let (lo, hi) = try plate.bounds
        let (lo64, hi64) = try plate.bounds64
        assertClose(lo64, lo)
        assertClose(hi64, hi)
        let (loAt, hiAt) = try plate.boundsAt(0.05)
        let (loAt64, hiAt64) = try plate.boundsAt64(0.05)
        assertClose(loAt64, loAt)
        assertClose(hiAt64, hiAt)
    }

    func testMesh64AndBounds64KeepACoordinateFarFromTheOrigin() throws {
        // A small cuboid at the origin cannot tell mesh64 from mesh widened, both narrowing
        // losslessly there; moved far away only mesh64/bounds64 can keep -2600001.987654321.
        let far = try Solid.cuboid(2, 2, 2).translate(1000000.123456789, -2600000.987654321, 450.5)
        let m32 = try far.mesh(tolerance: 0.05)
        let m64 = try far.mesh64(tolerance: 0.05)
        XCTAssertEqual(Array(m64.indices), Array(m32.indices), "one tessellation, one index buffer")
        XCTAssertEqual(m64.vertexCount, m32.vertexCount)
        let ys = (0..<m64.vertexCount).map { m64.positions[$0 * 3 + 1] }
        XCTAssertTrue(ys.contains { abs($0 - -2_600_001.987654321) < 1e-6 }, "\(ys)")
        XCTAssertTrue(ys.contains { abs(Double(Float($0)) - $0) > 1e-3 },
                     "mesh64 carries no coordinate float cannot hold, so this test cannot tell mesh64 from mesh widened")

        let (lo64, _) = try far.boundsAt64(0.05)
        XCTAssertEqual(lo64.y, -2_600_001.987654321, accuracy: 1e-6)
    }

    func testScaledMultipliesEveryLength() throws {
        let big = try Solid.cuboid(1, 2, 3).scaled(2)
        let (lo, hi) = try big.bounds
        XCTAssertEqual(hi.x - lo.x, 2, accuracy: 1e-9)
        XCTAssertEqual(hi.z - lo.z, 6, accuracy: 1e-9)
        XCTAssertThrowsError(try big.scaled(0))
    }

    // ---- the FEM surface mesh ----------------------------------------------------------

    /// A solid's FEM mesh: the kernel has no mesh-only path, so every solid goes through the
    /// options and `fromMesh` is always false.
    ///
    /// Catches the five arrays lent at the wrong counts, `nodeKind`/`nodeEntity` read from each
    /// other's pointers, and a summary figure taken off the wrong member of the view.
    func testFemMeshOfASolid() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let mesh = try plate.femMesh(tolerance: 0.05)
        defer { mesh.free() }
        XCTAssertFalse(mesh.fromMesh, "a solid reported from_mesh -- the kernel has no mesh path")
        XCTAssertEqual(mesh.faceCount, UInt32(try plate.faces))
        XCTAssertEqual(mesh.nodes.count % 3, 0)
        XCTAssertEqual(mesh.triangles.count % 3, 0)
        XCTAssertEqual(mesh.triangleFace.count, mesh.triangles.count / 3)
        XCTAssertEqual(mesh.nodeKind.count, mesh.nodes.count / 3)
        XCTAssertEqual(mesh.nodeEntity.count, mesh.nodes.count / 3)
        XCTAssertTrue(mesh.triangles.allSatisfy { Int($0) < mesh.nodes.count / 3 })
        XCTAssertTrue(mesh.triangleFace.allSatisfy { $0 < mesh.faceCount })
        let edges = try mesh.edges
        let vertices = try mesh.vertices
        XCTAssertFalse(edges.isEmpty)
        XCTAssertFalse(vertices.isEmpty)
        // The kind is asked about before it is used as an index, so `nodeKind` read off the
        // `nodeEntity` pointer fails by name here rather than as an out-of-range crash.
        for (i, kind) in mesh.nodeKind.enumerated() {
            guard kind < 3 else {
                XCTFail("node \(i) has kind \(kind), which is neither vertex, edge nor face")
                break
            }
            let bound = [vertices.count, edges.count, Int(mesh.faceCount)][Int(kind)]
            XCTAssertLessThan(Int(mesh.nodeEntity[i]), bound, "node \(i) of kind \(kind)")
        }
        // A closed part: watertight with both censuses empty, and no crossings.
        XCTAssertTrue(mesh.watertight)
        XCTAssertEqual(try mesh.openEdges.count, 0)
        XCTAssertEqual(try mesh.foldedEdges.count, 0)
        XCTAssertEqual(try mesh.crossings.count, 0)
        XCTAssertGreaterThan(mesh.minAngle, 0)
        XCTAssertLessThanOrEqual(mesh.minAngle, 60)
        XCTAssertLessThan(Int(mesh.worstTriangle), mesh.triangles.count / 3)
        XCTAssertGreaterThan(mesh.longestEdge, 0)
        XCTAssertTrue(mesh.description.contains("watertight=true"), mesh.description)
    }

    /// **Re-meshing the solid does not stale a FEM mesh either.** A FEM mesh is its own handle
    /// and is not in the solid's tessellation cache at all -- and closing the solid is not the
    /// end of it either, because the handle owns every array it lends. A `Solid.mesh` view now
    /// shares that much with it (it holds a `Tessellation` of its own too), so this test also
    /// pins that a re-mesh does not stale `view` below.
    ///
    /// Catches reusing `Tessellation` as the FEM mesh's `NativeMemoryOwner`, which is the
    /// obvious move here and would give a caller a refusal the library never made.
    func testAFemMeshSurvivesReMeshingAndClosingItsSolid() throws {
        var plate: Solid? = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let mesh = try plate!.femMesh(tolerance: 0.05)
        let nodes = mesh.nodes
        let first = nodes[0]
        // Meshed, meshed again at another tolerance, and meshed again: what would have staled
        // every `Solid.mesh` view before this task.
        let view = try plate!.mesh(tolerance: 0.05)
        _ = try plate!.mesh(tolerance: 0.5)
        _ = try plate!.mesh(tolerance: 0.05)
        XCTAssertFalse(view.isStale, "a tessellation view owns its mesh")
        XCTAssertTrue(nodes.isValid, "re-meshing the solid staled the FEM mesh")
        XCTAssertEqual(nodes[0], first)
        // And the solid itself can go: the FEM handle owns everything it lends.
        plate!.close()
        plate = nil
        XCTAssertTrue(nodes.isValid, "closing the solid staled the FEM mesh")
        XCTAssertEqual(mesh.triangles.count % 3, 0)
        XCTAssertGreaterThan(try mesh.edges.count, 0)
        mesh.free()
        XCTAssertFalse(nodes.isValid)
        XCTAssertEqual(nodes.owner.nativeMemoryInvalidReason, "the FEM mesh is freed")
    }

    /// An open sheet -- one face with a hole, so its rim is both loops. `watertight` false with
    /// **both censuses empty** is the "not asked" trio, and every rim edge bounds one real face
    /// and carries the sentinel for its second.
    ///
    /// Catches a wrapper that normalised `face_b` to `0` where the ABI said the sentinel: `0`
    /// is a real face, so that break reads as a rim edge bounded twice by face 0.
    func testFemMeshOfAnOpenSheetReportsItsRimRatherThanACrack() throws {
        let square = try Profile.rect(20, 20).withHole(try Profile.circle(4))
        let sheet = try Solid.face(square, try Frame.xy())
        let mesh = try sheet.femMesh(tolerance: 0.05)
        defer { mesh.free() }
        XCTAssertFalse(mesh.watertight)
        XCTAssertEqual(try mesh.openEdges.count, 0, "the 'not asked' trio is all three")
        XCTAssertEqual(try mesh.foldedEdges.count, 0, "the 'not asked' trio is all three")
        let edges = try mesh.edges
        XCTAssertFalse(edges.isEmpty)
        for (i, edge) in edges.enumerated() {
            XCTAssertEqual(edge.faces.0, 0, "the sheet's rim edge \(i)")
            XCTAssertEqual(edge.faces.1, UInt32.max, "the sheet's rim edge \(i) bounds a second face")
        }
    }

    /// `maxSize` adds nodes and shortens the longest edge -- but it **bounds the boundary and
    /// only targets the interior**, so the check is loose on purpose: a tighter pin would assert
    /// what the ABI does not promise (measured at 1.03x on an unevenly parameterised face).
    /// `longestEdge` is the figure a solver caller checks.
    func testMaxSizeShortensTheLongestEdgeWithoutPromisingIt() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let coarse = try plate.femMesh(tolerance: 0.05)
        defer { coarse.free() }
        let finer = try plate.femMesh(tolerance: 0.05, maxSize: 3)
        defer { finer.free() }
        XCTAssertGreaterThan(finer.nodes.count, coarse.nodes.count)
        XCTAssertLessThan(finer.longestEdge, coarse.longestEdge)
        XCTAssertLessThanOrEqual(finer.longestEdge, 3 * 1.05,
                                 "maxSize 3 left a \(finer.longestEdge) edge, past even the 1.03x measured")
    }

    /// **The kernel's `.msh` text is owned**, released by this wrapper with
    /// `cadaclysm_blacksmith_string_free`, where the reader's is borrowed from a slot on its
    /// handle. Two asks are two independent texts. A wrapper porting one side's convention onto
    /// the other leaks or double-frees -- and a double free here takes the process down, so
    /// asking twice is the proof.
    func testFemMeshMshTextIsOwnedOnThisSide() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let mesh = try plate.femMesh(tolerance: 0.05)
        defer { mesh.free() }
        let text = try mesh.mshText()
        XCTAssertEqual(try mesh.mshText(), text)
        XCTAssertTrue(text.hasPrefix("$MeshFormat\n4.1 0 8\n"), String(text.prefix(40)))
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("cadaclysm-kernel-fem.msh").path
        try mesh.saveMsh(path)
        let written = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
        XCTAssertGreaterThanOrEqual(written, text.utf8.count / 2)
    }

    /// The placement: **twelve** numbers as a `Frame`, where the reader takes sixteen
    /// column-major. The same transform as `turnedMatrix`, so `turned` is the one expected map
    /// for both sides -- which makes that asymmetry something these tests prove. A cuboid,
    /// because all eight of its corners are B-rep vertices and so certainly nodes.
    ///
    /// **The cuboid is moved off the rotation's axis, and the test is worthless without that.**
    /// `Solid.cuboid` is centred where it is built, and transposing the frame's 3x3 axes block
    /// composes this transform with a 180-degree turn about z through the frame's own origin --
    /// a symmetry of an axis-centred box's corner set, which would leave the eight corners and
    /// the span unchanged. **The condition is on x and y alone**: Task 4 measured an offset of
    /// (0, 0, 5) leaving the transpose passing, and (30, 7, 5) catching it. At this offset the
    /// right answer spans x 88..98, y 20..40 and the transposed one x 102..112, y -40..-20 --
    /// disjoint in x, which is what earns the catch. The corner loop is defence in depth.
    ///
    /// Also catches the placement dropped (the nodes stay where the body is), applied twice, or
    /// composed the other way round (the origin at (0, 100, 0), not (100, 0, 0)).
    func testFemMeshFrameTurnsAndMovesEveryCorner() throws {
        let (x, y, z) = (20.0, 10.0, 4.0)
        let off = SIMD3<Double>(30, 7, 5)
        let lo = off - SIMD3(x, y, z) / 2, hi = off + SIMD3(x, y, z) / 2
        let cuboid = try Solid.cuboid(x, y, z).translate(off.x, off.y, off.z)
        let frame = try Frame(SIMD3(100, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0), SIMD3(0, 0, 1))
        let placed = try cuboid.femMesh(tolerance: 0.05, placement: frame)
        defer { placed.free() }
        let there = points(placed.nodes)
        for corner in corners(lo, hi) {
            let want = turned(corner)
            XCTAssertTrue(there.contains { close($0, want, 1e-6) },
                          "the frame did not send \(corner) to \(want) -- the nodes span \(span(placed.nodes))")
        }
        let (low, high) = span(placed.nodes)
        XCTAssertTrue(close(low, SIMD3(88, 20, 3), 1e-6) && close(high, SIMD3(98, 40, 7), 1e-6), "\(low)..\(high)")
        // The identity: a solid meshed in its own coordinates is the common case, and this is
        // the one frame argument in this library that may be left out.
        let own = try cuboid.femMesh(tolerance: 0.05)
        defer { own.free() }
        let (ownLow, ownHigh) = span(own.nodes)
        XCTAssertTrue(close(ownLow, lo, 1e-6) && close(ownHigh, hi, 1e-6), "\(ownLow)..\(ownHigh)")
    }

    /// **`femMesh`'s defaults are `FemOptions::default()`'s** -- `tolerance: 0.01` and
    /// `max_size: 0`, from `impl Default for FemOptions` in `crates/cadaclysm-brep/src/fem.rs`, the
    /// same figures `cadaclysm_blacksmith_fem_options_init` writes. **Not `Solid.mesh`'s `0.05`**,
    /// which is the *render* mesher's default and is the method directly above this one in the
    /// wrapper: copying that neighbour gives a Swift caller a five-times coarser solver mesh than
    /// the same call in every other language, and until this test nothing pinned it.
    ///
    /// Pinned against the figure rather than against the reader's default, so the slip is caught in
    /// either module independently: the no-argument call must agree with an explicit `0.01`, must
    /// come to the node count 0.01 is known to give, and must **disagree** with an explicit `0.05`
    /// -- which is what says the first assertion has teeth. Measured on this plate through
    /// `cadaclysm_blacksmith.py` on the same library: 1208 nodes at 0.01 against 504 at 0.05 (1952 and 864
    /// until 2026-09-26, d2f866b6 (filler interior at six rows, 15-degree turn bound)). A flat
    /// body cannot tell the two apart at all (the reader's cube meshes to 8 nodes either way), which
    /// is why the plate -- with its cylindrical hole and its slot -- is the body here.
    func testFemMeshDefaultsAreTheLibrarysOwn() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        let byDefault = try plate.femMesh()
        defer { byDefault.free() }
        let stated = try plate.femMesh(tolerance: 0.01, maxSize: 0.0)
        defer { stated.free() }
        let renderDefault = try plate.femMesh(tolerance: 0.05)
        defer { renderDefault.free() }
        XCTAssertEqual(byDefault.nodes.count, stated.nodes.count, "the default tolerance is not 0.01")
        XCTAssertEqual(byDefault.nodes.count, 1208 * 3, "0.01 no longer meshes this plate to 1208 nodes")
        XCTAssertNotEqual(byDefault.nodes.count, renderDefault.nodes.count,
                          "0.01 and 0.05 mesh this body alike, so this test cannot tell them apart")
    }

    /// The kernel refuses a bad tolerance in the library's own words: it has no mesh-only path,
    /// so unlike the reader every solid goes through the options. **This wrapper checks neither
    /// `tolerance` nor `maxSize` itself** -- whose words the message is in proves that.
    func testFemMeshRefusesABadToleranceInTheLibrarysWords() throws {
        let plate = try Solid.extrude(try plateOutline(), try Frame.xy(), 6)
        XCTAssertEqual(refusal { _ = try plate.femMesh(tolerance: 0) },
                       "fem_mesh: bad FEM mesh input: tolerance must be finite and > 0, got 0")
        XCTAssertNotNil(refusal { _ = try plate.femMesh(tolerance: 0.05, maxSize: -1) })
        plate.close()
        XCTAssertEqual(refusal { _ = try plate.femMesh() }, "solid: closed")
    }

    // MARK: - Assemblies

    /// The spec §5 assembly facts, over `_shared_assembly()`'s shape, at parity with the
    /// Python reference's tests and Node's `blacksmith.test.js`: placement names ordered
    /// and numbered past a taken one (fact 1), STEP entity counts (fact 2), the STEP text
    /// naming every placement (fact 3), a late placement showing up wherever its
    /// assembly is placed (fact 4), a cycle refused naming it (fact 5), a duplicate
    /// explicit name refused (fact 6), a mirrored raw frame refused in the library's own
    /// words (fact 7), an empty assembly refused at `stepText()` (fact 8), an assembly
    /// placing an empty sub-assembly refused naming it (fact 9), `Solid.named`/`Solid.name`
    /// (fact 10), and a read-back through the reader (fact 11).
    func testAssemblyFactsHoldAsPythonChecksThem() throws {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate").coloured([1, 0.5, 0])

        let bracket = try Assembly("bracket")
        let platePlacement = try bracket.place(plate, try Frame.xy())
        let bolt1Placement = try bracket.place(bolt, try Frame.xy([5, 5, 2]))
        let bolt2Placement = try bracket.place(bolt, try Frame.xy([15, 5, 2]))
        XCTAssertEqual(platePlacement, "plate")
        XCTAssertEqual(bolt1Placement, "bolt")
        XCTAssertEqual(bolt2Placement, "bolt 2")   // fact 1

        let frame = try Assembly("frame")
        let right = try Frame([100, 0, 0], [0, 1, 0], [-1, 0, 0], [0, 0, 1])
        let leftPlacement = try frame.place(bracket, try Frame.xy(), name: "left")
        let rightPlacement = try frame.place(bracket, right, name: "right")
        let rootBoltPlacement = try frame.place(bolt, try Frame.xy([50, 50, 0]))
        XCTAssertEqual(leftPlacement, "left")
        XCTAssertEqual(rightPlacement, "right")
        XCTAssertEqual(rootBoltPlacement, "bolt")   // fact 1

        let frameStepText = try frame.stepText()
        XCTAssertEqual(countOf(frameStepText, "=MANIFOLD_SOLID_BREP("), 2)
        XCTAssertEqual(countOf(frameStepText, "=PRODUCT("), 4)
        XCTAssertEqual(countOf(frameStepText, "=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 6)   // fact 2
        XCTAssertTrue(frameStepText.contains("'left'") && frameStepText.contains("'right'")
                       && frameStepText.contains("'bolt 2'"))   // fact 3

        // Fact 11: read-back through the reader -- structure only. One root "frame" with
        // three children: two "bracket" containers each holding plate/bolt/bolt, and one
        // root-level "bolt". The world origins are Python's to check.
        let scene = try Cadaclysm.openMemory(Data(frameStepText.utf8), format: "stp")
        let roots = scene.roots
        XCTAssertEqual(roots.count, 1)
        if let root = roots.first {
            XCTAssertEqual(root.name, "frame")
            let rootChildren = root.children
            XCTAssertEqual(rootChildren.count, 3)   // fact 11
            let containers = rootChildren.filter { $0.name == "bracket" }
            let rootBolts = rootChildren.filter { $0.name == "bolt" }
            XCTAssertEqual(containers.count, 2)
            XCTAssertEqual(rootBolts.count, 1)
            for container in containers {
                XCTAssertEqual(container.children.map(\.name).sorted(), ["bolt", "bolt", "plate"])
            }
        }
        scene.close()

        // Fact 4: a late placement into bracket shows up wherever bracket is placed.
        _ = try bracket.place(bolt, try Frame.xy([10, 8, 2]))
        XCTAssertEqual(countOf(try frame.stepText(), "=NEXT_ASSEMBLY_USAGE_OCCURRENCE("), 7)

        // Fact 5: a cycle is refused, naming it.
        XCTAssertEqual(refusal { _ = try bracket.place(frame, try Frame.xy()) }?.contains("bracket → frame → bracket"), true)

        // Fact 6: an explicit name already taken is refused.
        XCTAssertNotNil(refusal { _ = try frame.place(bracket, try Frame.xy(), name: "left") })

        // Fact 7: a mirrored raw frame is refused in the library's own words, not
        // `Frame.init`'s -- `place(_:raw:name:)` is the narrow unchecked route added for
        // this, following `Solid.place(raw:)`'s own precedent for the same fact.
        let mirrored = [0.0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, -1]
        let refusedMessage = refusal { _ = try frame.place(bolt, raw: mirrored) }
        XCTAssertEqual(refusedMessage?.contains("right-handed and orthonormal"), true, refusedMessage ?? "")

        // Fact 8: an assembly placing nothing is refused at stepText().
        let x = try Assembly("x")
        XCTAssertNotNil(refusal { _ = try x.stepText() })
        x.close()

        // Fact 9: an assembly placing an empty sub-assembly is refused, naming it.
        let outer = try Assembly("outer")
        let hollow = try Assembly("hollow")
        _ = try outer.place(hollow, try Frame.xy())
        let hollowRefusal = refusal { _ = try outer.stepText() }
        XCTAssertEqual(hollowRefusal?.contains("hollow"), true, hollowRefusal ?? "")
        outer.close()
        hollow.close()

        // Fact 10: `Solid.named`/`Solid.name` -- the name rides through a one-source
        // operation (place, coloured) and is dropped by a two-source one (join) or a
        // fresh primitive.
        XCTAssertEqual(try bolt.name, "bolt")
        let placedBolt = try bolt.place(try Frame.xy([1, 2, 3]))
        XCTAssertEqual(try placedBolt.name, "bolt")
        let colouredBolt = try bolt.coloured([1, 0, 0])
        XCTAssertEqual(try colouredBolt.name, "bolt")
        let cube = try Solid.cuboid(1, 1, 1)
        let joinedBolt = try bolt.join(cube)
        XCTAssertNil(try joinedBolt.name)
        XCTAssertNil(try Solid.cuboid(1, 1, 1).name)   // fact 10
        XCTAssertNotNil(refusal { _ = try bolt.named("") })

        // The material and the outside style: read back, kept by a cut, written to STEP.
        XCTAssertNil(try cube.material)
        let steel = try cube.withMaterial("Steel").styled(location: "materials/steel.mtlx", identification: "BrushedSteel")
        XCTAssertEqual(try steel.material, "Steel")
        XCTAssertEqual(try steel.styleLocation, "materials/steel.mtlx")
        XCTAssertEqual(try steel.styleIdentification, "BrushedSteel")
        XCTAssertEqual(try steel.cut(try cube.withMaterial("Oak").translate(0.5, 0.5, 0.5)).material, "Steel")
        XCTAssertNil(try cube.styled(identification: "BrushedSteel").styleLocation)
        let steelText = try steel.stepText()
        XCTAssertTrue(steelText.contains("MATERIAL_DESIGNATION('Steel'"))
        XCTAssertTrue(steelText.contains("EXTERNALLY_DEFINED_STYLE(IDENTIFIER('BrushedSteel')"))
        XCTAssertNotNil(refusal { _ = try cube.withMaterial(" ") })
        XCTAssertNotNil(refusal { _ = try cube.styled() })

        frame.close()
        bracket.close()
    }

    /// `Assembly.link`/`Assembly.joint`, at parity with the Python reference's
    /// `_mechanism()` and its two mechanism tests in `test_cadaclysm_blacksmith.py` --
    /// see Node's `test/blacksmith.test.js` and Rust's `mod tests` for the same facts
    /// worked out.
    func testMechanismFactsHoldAsTheSharedSpecChecksThem() throws {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate")

        let bracket = try Assembly("bracket")
        _ = try bracket.place(plate, try Frame.xy())
        _ = try bracket.place(bolt, try Frame.xy([5, 5, 2]))
        _ = try bracket.place(bolt, try Frame.xy([15, 5, 2]))
        try bracket.link("fixed", ["plate"])
        try bracket.link("bolts", ["bolt", "bolt 2"])
        try bracket.joint("screw", "fixed", "bolts")

        let arm = try Assembly("arm")
        _ = try arm.place(plate, try Frame.xy(), name: "base")
        _ = try arm.place(bracket, try Frame.xy([0, 0, 10]), name: "upper")
        _ = try arm.place(bolt, try Frame.xy([5, 5, 2]), name: "pin")
        try arm.link("ground", ["base"])
        try arm.link("upper arm", ["upper", "pin"])
        try arm.joint("shoulder", "ground", "upper arm")

        // Fact 1: the default schema (no explicit schema) carries the kinematic entities.
        let step = try arm.stepText()
        XCTAssertTrue(step.contains("AP242_MANAGED_MODEL_BASED_3D_ENGINEERING_MIM_LF"))
        XCTAssertEqual(countOf(step, "=KINEMATIC_LINK("), 4)
        XCTAssertEqual(countOf(step, "=RIGID_LINK_REPRESENTATION("), 6)
        XCTAssertEqual(countOf(step, "=CONTEXT_DEPENDENT_KINEMATIC_LINK_REPRESENTATION("), 6)
        XCTAssertEqual(countOf(step, "=KINEMATIC_JOINT("), 2)
        XCTAssertEqual(countOf(step, "=KINEMATIC_TOPOLOGY_STRUCTURE("), 2)

        // Fact 2: an explicit schema without kinematic entities is refused.
        let schemaRefusal = refusal { _ = try arm.stepText(schema: "config_control_design") }
        XCTAssertEqual(schemaRefusal?.contains("no kinematic entities"), true, schemaRefusal ?? "")

        // Fact 3: each of the eleven refusals raises with exactly its message, and
        // afterwards the STEP text (with `FILE_NAME(` lines stripped) is unchanged.
        let before = noStamp(try arm.stepText())
        let refusals: [(() throws -> Void, String)] = [
            ({ try arm.link("", ["base"]) }, "link: a name cannot be empty"),
            ({ try arm.link("ground", ["base"]) }, "link: assembly 'arm' already has a link named 'ground'"),
            ({ try arm.link("free", []) }, "link: link 'free' names no placements"),
            ({ try arm.link("free", ["base", "base"]) }, "link: link 'free' names placement 'base' twice"),
            ({ try arm.link("free", ["bolt"]) }, "link: assembly 'arm' has no placement named 'bolt'"),
            ({ try arm.link("free", ["pin"]) }, "link: placement 'pin' of assembly 'arm' is already in link 'upper arm'"),
            ({ try arm.joint("", "ground", "upper arm") }, "joint: a name cannot be empty"),
            ({ try arm.joint("shoulder", "upper arm", "ground") }, "joint: assembly 'arm' already has a joint named 'shoulder'"),
            ({ try arm.joint("wrist", "ground", "hand") }, "joint: assembly 'arm' has no link named 'hand'"),
            ({ try arm.joint("wrist", "ground", "ground") }, "joint: joint 'wrist' joins link 'ground' to itself"),
            ({ try arm.joint("wrist", "ground", "upper arm") }, "joint: assembly 'arm' already joins 'ground' to 'upper arm'"),
        ]
        for (call, message) in refusals {
            let message2 = refusal(call)
            XCTAssertEqual(message2, message)
        }
        XCTAssertEqual(noStamp(try arm.stepText()), before)

        // Fact 5: read-back through `toScene`. Checked ahead of fact 4's reverse "back"
        // joint, so the joint list below is exactly the two joints the fixture built.
        let scene = try arm.toScene()
        XCTAssertEqual(scene.links.map { $0.name }, ["fixed", "bolts", "ground", "upper arm"])
        XCTAssertEqual(scene.links.map { $0.nodes.count }, [1, 2, 1, 2])
        let jointFacts = scene.joints.map { ($0.name, $0.start.index, $0.end.index) }
        let expectedJoints = [("screw", 0, 1), ("shoulder", 2, 3)]
        XCTAssertTrue(jointFacts.elementsEqual(expectedJoints, by: { $0 == $1 }))
        XCTAssertFalse(scene.diagnostics.contains { $0.hasPrefix("kinematics:") })
        scene.close()

        // Fact 4: the reverse pair is a new joint.
        try arm.joint("back", "upper arm", "ground")
    }

    /// `Assembly.pair`/`state`/`base` and `Assembly.pairFreedomCount`, at parity with the
    /// Python reference's `_paired()` and its tests in `test_cadaclysm_blacksmith.py`
    /// (spec 2026-09-28). See Node's `test/blacksmith.test.js` and Rust's `mod tests` for
    /// the same facts worked out.
    func testPairedMechanismFactsHoldAsTheSharedSpecChecksThem() throws {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate")

        let bracket = try Assembly("bracket")
        _ = try bracket.place(plate, try Frame.xy())
        _ = try bracket.place(bolt, try Frame.xy([5, 5, 2]))
        _ = try bracket.place(bolt, try Frame.xy([15, 5, 2]))
        try bracket.link("fixed", ["plate"])
        try bracket.link("bolts", ["bolt", "bolt 2"])
        try bracket.joint("screw", "fixed", "bolts")

        let arm = try Assembly("arm")
        _ = try arm.place(plate, try Frame.xy(), name: "base")
        _ = try arm.place(bracket, try Frame.xy([0, 0, 10]), name: "upper")
        _ = try arm.place(bolt, try Frame.xy([5, 5, 2]), name: "pin")
        try arm.link("ground", ["base"])
        try arm.link("upper arm", ["upper", "pin"])
        try arm.joint("shoulder", "ground", "upper arm")

        try bracket.pair("screw", "prismatic", try Frame.xy([1, 2, 3]), endFrame: try Frame.xy([4, 2, 3]))
        try arm.pair("shoulder", "revolute", try Frame.xy([0, 0, 10]), ranges: [(-1.5, 1.5)])
        try arm.state("reach", [("shoulder", [0.5])])
        try arm.base("ground")

        // Fact 1: the written STEP text carries the pairs and the state.
        let step = try arm.stepText()
        XCTAssertEqual(countOf(step, "=MECHANISM_REPRESENTATION("), 2)
        XCTAssertEqual(countOf(step, "=PAIR_REPRESENTATION_RELATIONSHIP("), 2)
        XCTAssertEqual(countOf(step, "REVOLUTE_PAIR_WITH_RANGE"), 1)
        XCTAssertEqual(countOf(step, "PRISMATIC_PAIR"), 1)
        XCTAssertEqual(countOf(step, "=KINEMATIC_PROPERTY_MECHANISM_REPRESENTATION("), 1)
        XCTAssertEqual(countOf(step, "=MECHANISM_STATE_REPRESENTATION("), 1)

        // Facts 2-6, 9: read back through `toScene`.
        let scene = try arm.toScene()
        let shoulder = try XCTUnwrap(scene.joints.first { $0.name == "shoulder" })
        let shoulderPair = try XCTUnwrap(shoulder.pair)
        XCTAssertEqual(shoulderPair.kind, .revolute)
        for frame in [shoulderPair.frameStart, shoulderPair.frameEnd] {
            XCTAssertEqual(frame[0][3], 0.0, accuracy: 1e-9)
            XCTAssertEqual(frame[1][3], 0.0, accuracy: 1e-9)
            XCTAssertEqual(frame[2][3], 10.0, accuracy: 1e-9)
            XCTAssertEqual(frame[0][2], 0.0, accuracy: 1e-9)
            XCTAssertEqual(frame[1][2], 0.0, accuracy: 1e-9)
            XCTAssertEqual(frame[2][2], 1.0, accuracy: 1e-9)
        }
        let shoulderFreedoms = shoulderPair.freedoms()
        XCTAssertEqual(shoulderFreedoms.count, 1)
        XCTAssertEqual(shoulderFreedoms[0].motion, .rotation)
        XCTAssertEqual(shoulderFreedoms[0].axis, .z)
        XCTAssertEqual(shoulderFreedoms[0].lower ?? .nan, -1.5, accuracy: 1e-9)
        XCTAssertEqual(shoulderFreedoms[0].upper ?? .nan, 1.5, accuracy: 1e-9)

        let screw = try XCTUnwrap(scene.joints.first { $0.name == "screw" })
        let screwPair = try XCTUnwrap(screw.pair)
        XCTAssertEqual(screwPair.kind, .prismatic)
        XCTAssertTrue(screwPair.freedoms().allSatisfy { $0.lower == nil && $0.upper == nil })
        XCTAssertEqual(screwPair.frameStart[0][3], 1.0, accuracy: 1e-9)
        XCTAssertEqual(screwPair.frameStart[1][3], 2.0, accuracy: 1e-9)
        XCTAssertEqual(screwPair.frameStart[2][3], 13.0, accuracy: 1e-9)
        XCTAssertEqual(screwPair.frameEnd[0][3], 4.0, accuracy: 1e-9)
        XCTAssertEqual(screwPair.frameEnd[1][3], 2.0, accuracy: 1e-9)
        XCTAssertEqual(screwPair.frameEnd[2][3], 13.0, accuracy: 1e-9)

        XCTAssertEqual(scene.base?.name, "ground")
        XCTAssertEqual(scene.states.map { $0.name }, ["reach"])
        let reach = scene.states[0]
        XCTAssertEqual(reach.values.count, 1)
        XCTAssertEqual(reach.values[0].joint?.name, "shoulder")
        XCTAssertEqual(reach.values[0].values.count, 1)
        XCTAssertEqual(reach.values[0].values[0], 0.5, accuracy: 1e-9)

        // Fact 5: `poseState(reach)` carries the pin node at (5, 5, 2) to
        // (5cos0.5 - 5sin0.5, 5sin0.5 + 5cos0.5, 2).
        let pose = try scene.poseState(reach)
        let upperArm = try XCTUnwrap(scene.links.first { $0.name == "upper arm" })
        let pinNode = try XCTUnwrap(upperArm.nodes.first {
            let t = $0.transform
            return abs(t[0][3] - 5.0) < 1e-9 && abs(t[1][3] - 5.0) < 1e-9 && abs(t[2][3] - 2.0) < 1e-9
        })
        let posed = pose.transform(pinNode)
        XCTAssertEqual(posed[0][3], 5 * cos(0.5) - 5 * sin(0.5), accuracy: 1e-9)
        XCTAssertEqual(posed[1][3], 5 * sin(0.5) + 5 * cos(0.5), accuracy: 1e-9)
        XCTAssertEqual(posed[2][3], 2.0, accuracy: 1e-9)

        // Fact 6: `pose([(screw, [3.0])])` leaves every 'bolts' node at rest; `[5.0]` moves
        // each by (2, 0, 0).
        let pose3 = try scene.pose([StateValue(joint: screw, values: [3.0])])
        let pose5 = try scene.pose([StateValue(joint: screw, values: [5.0])])
        let bolts = try XCTUnwrap(scene.links.first { $0.name == "bolts" })
        for node in bolts.nodes {
            let rest = node.transform
            let at3 = pose3.transform(node)
            let at5 = pose5.transform(node)
            for row in 0..<3 {
                XCTAssertEqual(at3[row][3], rest[row][3], accuracy: 1e-9)
            }
            XCTAssertEqual(at5[0][3], rest[0][3] + 2.0, accuracy: 1e-9)
            XCTAssertEqual(at5[1][3], rest[1][3], accuracy: 1e-9)
            XCTAssertEqual(at5[2][3], rest[2][3], accuracy: 1e-9)
        }

        // Fact 9: no diagnostic names kinematics.
        XCTAssertFalse(scene.diagnostics.contains { $0.hasPrefix("kinematics:") })
        scene.close()

        // Fact 7: the eight refusals, each with exactly its message, and the unpaired
        // 'back' trick -- step_text()'s refusal text is identical before and after.
        try arm.joint("back", "upper arm", "ground")
        func unpairedMessage() -> String? { refusal { _ = try arm.stepText() } }
        let before = unpairedMessage()
        let refusals: [(() throws -> Void, String)] = [
            ({ try arm.pair("shoulder", "revolute", try Frame.xy([0, 0, 10])) },
             "pair: joint 'shoulder' already has a pair"),
            ({ try arm.pair("back", "orbital", try Frame.xy()) },
             "pair: 'orbital' is not a pair kind (revolute, prismatic, cylindrical, screw, gear, rack_and_pinion, spherical, "
             + "spherical_with_pin, planar, universal, homokinetic, fully_constrained, unconstrained)"),
            ({ try arm.pair("back", "screw", try Frame.xy()) }, "pair: a screw needs a non-zero pitch"),
            ({ try arm.pair("back", "revolute", try Frame.xy(), ranges: [(-1, 1), (-1, 1)]) },
             "pair: 'revolute' has 1 freedoms, but 2 ranges were given"),
            ({ try arm.pair("back", "revolute", try Frame.xy(), ranges: []) },
             "pair: 'revolute' has 1 freedoms, but 0 ranges were given"),
            ({ try arm.pair("back", "revolute", try Frame.xy(), ranges: [(1, -1)]) },
             "pair: range 0 of joint 'back' has lower >= upper"),
            ({ try arm.pair("back", "prismatic", try Frame.at(SIMD3(0, 0, 0), SIMD3(0, 0, 1), x: SIMD3(0, 1, 0)),
                            endFrame: try Frame.xy()) },
             "pair: joint 'back' is prismatic, but its end frame is turned 90\u{00B0} about -z, "
             + "which prismatic (does not turn) cannot make"),
            ({ try arm.state("overreach", [("shoulder", [5.0])]) },
             "state: value 0 of joint 'shoulder' is outside its range"),
            ({ try arm.base("upper arm") }, "base: assembly 'arm' already has base 'ground'"),
        ]
        for (call, message) in refusals {
            XCTAssertEqual(refusal(call), message)
        }
        XCTAssertEqual(unpairedMessage(), before)

        // Fact 8: a joint with no pair is refused at write time.
        XCTAssertEqual(
            refusal { _ = try arm.stepText() },
            "assembly_step: assembly 'arm': joint 'back' has no pair; "
            + "a mechanism with pairs needs one on every joint (AP242)"
        )

        // Fact 9: `pairFreedomCount`.
        XCTAssertEqual(Assembly.pairFreedomCount("spherical"), 3)
        XCTAssertEqual(Assembly.pairFreedomCount("revolute"), 1)
        XCTAssertEqual(Assembly.pairFreedomCount("fully_constrained"), 0)
        XCTAssertEqual(Assembly.pairFreedomCount("not_a_kind"), 0)
    }

    /// Drives plan 4's `_geared()` in Python: a pinion turning on `drive` meshes, by the gear
    /// pair `mesh` (radii 10 and 20, ratio -0.5, bevel 0.25, helical 0.125), with a wheel
    /// turning on `driven` about (30, 0).
    private func geared(mesh: Bool = true) throws -> Assembly {
        let plate = try Solid.cuboid(40, 10, 2).named("plate")
        let pin = try Solid.cylinder(1, 6).named("pin")
        let hub = try Solid.cylinder(2, 4).named("hub")
        let gears = try Assembly("gears")
        _ = try gears.place(plate, try Frame.xy(), name: "frame")
        _ = try gears.place(pin, try Frame.xy([0, 0, 2]), name: "pinion")
        _ = try gears.place(hub, try Frame.xy([35, 0, 2]), name: "wheel")
        try gears.link("base", ["frame"])
        try gears.link("driver", ["pinion"])
        try gears.link("follower", ["wheel"])
        try gears.joint("drive", "base", "driver")
        try gears.joint("driven", "base", "follower")
        try gears.joint("mesh", "driver", "follower")
        try gears.pair("drive", "revolute", try Frame.xy([0, 0, 2]))
        try gears.pair("driven", "revolute", try Frame.xy([30, 0, 2]))
        if mesh {
            try gears.pairWith("mesh", "gear", try Frame.xy([0, 0, 2]), params: [10, 20, -0.5, 0.25, 0.125])
        }
        return gears
    }

    func testAGearPairRoundTripsAndPosesFromItsDriver() throws {
        let scene = try geared().toScene()
        let joints = Dictionary(uniqueKeysWithValues: scene.joints.map { ($0.name, $0) })
        let mesh = try XCTUnwrap(joints["mesh"]?.pair)
        XCTAssertEqual(mesh.kind, .other)
        XCTAssertEqual(mesh.kindName, "gear")
        let want = [10.0, 20, -0.5, 0.25, 0.125]
        XCTAssertEqual(mesh.parameters.count, want.count)
        for (got, expected) in zip(mesh.parameters, want) { XCTAssertEqual(got, expected, accuracy: 1e-9) }
        let drivePair = try XCTUnwrap(joints["drive"]?.pair)
        XCTAssertEqual(drivePair.kindName, "revolute")
        XCTAssertEqual(drivePair.parameters, [])

        // the driver alone turns the wheel by ratio x 0.4 about (30, 0): nothing to report
        let drive = try XCTUnwrap(joints["drive"])
        let driven = try XCTUnwrap(joints["driven"])
        var pose = try scene.pose([StateValue(joint: drive, values: [0.4])])
        XCTAssertEqual(pose.diagnostics, [])
        XCTAssertTrue(pose.unsolved.isEmpty)
        let wheel = try XCTUnwrap(scene.links[2].nodes.first)
        let origin = pose.transform(wheel)
        let expected = [30 + 5 * cos(-0.2), 5 * sin(-0.2), 2.0]
        for axis in 0..<3 { XCTAssertEqual(origin[axis][3], expected[axis], accuracy: 1e-9) }

        // both sides given, against the law: one diagnostic, in the kernel's words
        pose = try scene.pose([StateValue(joint: drive, values: [0.4]), StateValue(joint: driven, values: [0.4])])
        XCTAssertEqual(pose.diagnostics.count, 1)
        XCTAssertTrue(
            pose.diagnostics.first?.hasPrefix("coupling 'mesh': both 'drive' and 'driven' are given and disagree by") ?? false,
            "\(pose.diagnostics)"
        )
    }

    private func armForPosing() throws -> Assembly {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate")
        let arm = try Assembly("arm")
        _ = try arm.place(plate, try Frame.xy(), name: "base")
        _ = try arm.place(bolt, try Frame.xy([5, 5, 2]), name: "pin")
        try arm.link("ground", ["base"])
        try arm.link("upper arm", ["pin"])
        try arm.joint("shoulder", "ground", "upper arm")
        try arm.pair("shoulder", "revolute", try Frame.xy([0, 0, 10]), ranges: [(-1.5, 1.5)])
        try arm.state("reach", [("shoulder", [0.5])])
        try arm.base("ground")
        return arm
    }

    func testPosedMovesTheShoulder() throws {
        let arm = try armForPosing()
        let before = noStamp(try arm.stepText())
        let moved = try arm.posed([("shoulder", [0.5])])
        XCTAssertEqual(try moved.name, "arm")
        XCTAssertNotEqual(noStamp(try moved.stepText()), before)
        XCTAssertEqual(noStamp(try arm.stepText()), before)
    }

    func testPosedRefusesAnAmbiguousNameAndTakesAPathWithASlash() throws {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate")
        let bracket = try Assembly("bracket")
        _ = try bracket.place(plate, try Frame.xy(), name: "base")
        _ = try bracket.place(bolt, try Frame.xy([5, 5, 2]), name: "pin")
        try bracket.link("ground", ["base"])
        try bracket.link("arm", ["pin"])
        try bracket.joint("turn", "ground", "arm")
        try bracket.pair("turn", "revolute", try Frame.xy([0, 0, 10]))
        try bracket.base("ground")
        let frame = try Assembly("frame")
        _ = try frame.place(bracket, try Frame.xy(), name: "left")
        _ = try frame.place(bracket, try Frame.xy([50, 0, 0]), name: "right/rear")
        let before = noStamp(try frame.stepText())

        XCTAssertEqual(
            refusal { _ = try frame.posed([("turn", [0.3])]) },
            "posed: 'turn' names 2 joints: left/turn, right\\/rear/turn; give one by its path"
        )
        let turned = try frame.posed([("right\\/rear/turn", [0.3])])
        XCTAssertEqual(try turned.name, "frame")
        XCTAssertNotEqual(noStamp(try turned.stepText()), before)
        let rest = try frame.posed([("right\\/rear/turn", [0.0])])
        XCTAssertEqual(noStamp(try rest.stepText()), before)
        XCTAssertEqual(noStamp(try frame.stepText()), before)
    }

    func testPosedTakesAStateAndAGroundAndRefusesWithTheKernelsWords() throws {
        let arm = try armForPosing()
        let before = noStamp(try arm.stepText())
        let viaState = noStamp(try arm.posed(state: "reach").stepText())
        let viaRow = noStamp(try arm.posed([("shoulder", [0.5])]).stepText())
        XCTAssertEqual(viaState, viaRow)
        XCTAssertNotEqual(viaState, before)
        let grounded = noStamp(try arm.posed([("shoulder", [0.5])], ground: "upper arm").stepText())
        XCTAssertNotEqual(grounded, viaRow)
        XCTAssertEqual(
            refusal { _ = try arm.posed([("shoulder", [2.0])]) },
            "posed: value 0 of joint 'shoulder' is 2, outside its range"
        )
        XCTAssertEqual(
            refusal { _ = try arm.posed(state: "fold") },
            "posed: assembly 'arm' has no state named 'fold'"
        )
        XCTAssertEqual(noStamp(try arm.stepText()), before)
    }

    func testPosedRefusesAGearCouplingThatDisagrees() throws {
        let gears = try geared()
        let before = noStamp(try gears.stepText())
        let one = try gears.posed([("drive", [0.4])])
        XCTAssertEqual(try one.name, "gears")
        let message = try XCTUnwrap(refusal { _ = try gears.posed([("drive", [0.4]), ("driven", [0.4])]) })
        XCTAssertTrue(
            message.hasPrefix("posed: assembly 'gears': coupling 'mesh': both 'drive' and 'driven' are given and disagree by"),
            message
        )
        XCTAssertEqual(noStamp(try gears.stepText()), before)
    }

    func testPairWithRefusesAWrongParameterCount() throws {
        let gears = try geared(mesh: false)
        XCTAssertEqual(
            refusal { try gears.pairWith("mesh", "gear", try Frame.xy(), params: [10, 20]) },
            "pair: a gear takes 3 or 5 parameters, not 2"
        )
        try gears.pairWith("mesh", "gear", try Frame.xy(), params: [10, 20, -0.5])  // unchanged: it takes one now
    }

    /// `Assembly.sequence`, read back through `toScene`: the paired arm, a state `rest`, and a
    /// two-segment `swing`; one refusal checked exactly.
    func testASequenceSurvivesTheRoundTrip() throws {
        let bolt = try Solid.cylinder(1, 6).named("bolt")
        let plate = try Solid.cuboid(20, 10, 2).named("plate")
        let arm = try Assembly("arm")
        _ = try arm.place(plate, try Frame.xy(), name: "base")
        _ = try arm.place(bolt, try Frame.xy([5, 5, 2]), name: "pin")
        try arm.link("ground", ["base"])
        try arm.link("upper arm", ["pin"])
        try arm.joint("shoulder", "ground", "upper arm")
        try arm.pair("shoulder", "revolute", try Frame.xy([0, 0, 10]), ranges: [(-1.5, 1.5)])
        try arm.state("reach", [("shoulder", [0.5])])
        try arm.state("rest", [("shoulder", [0.0])])
        try arm.base("ground")
        try arm.sequence("swing", [("rest", 0.0, "linear"), ("reach", 1.0, "linear")], seconds: true)

        let scene = try arm.toScene()
        defer { scene.close() }
        let sequences = scene.sequences
        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].name, "swing")
        XCTAssertTrue(sequences[0].closed)
        XCTAssertEqual(sequences[0].secondsPerUnit, 1.0)
        XCTAssertEqual(sequences[0].segments.map { $0.state.name }, ["rest", "reach"])
        XCTAssertEqual(sequences[0].segments.map { $0.t }, [0.0, 1.0])
        XCTAssertEqual(sequences[0].segments.map { $0.interpolation }, ["linear", "linear"])

        let before = noStamp(try arm.stepText())
        XCTAssertEqual(
            refusal { try arm.sequence("bad", [("rest", 0.0, "linear"), ("nowhere", 1.0, "linear")]) },
            "sequence: assembly 'arm' has no state named 'nowhere'"
        )
        XCTAssertEqual(noStamp(try arm.stepText()), before)
    }

    /// Controller ruling: fact 10 -- a one-sided range survives the round trip. Without
    /// this, an implementation sending `has_lower`/`has_upper` as always-true would pass
    /// every other fact.
    func testPairOneSidedRangeSurvivesTheRoundTrip() throws {
        let plate = try Solid.cuboid(20, 10, 2).named("plate")
        let bolt = try Solid.cylinder(1, 6).named("bolt")

        let hinge = try Assembly("hinge")
        _ = try hinge.place(plate, try Frame.xy(), name: "base")
        _ = try hinge.place(bolt, try Frame.xy([0, 0, 2]), name: "arm")
        try hinge.link("base", ["base"])
        try hinge.link("arm", ["arm"])
        try hinge.joint("j", "base", "arm")
        try hinge.pair("j", "revolute", try Frame.xy(), ranges: [(nil, 1.0)])

        let scene = try hinge.toScene()
        let j = try XCTUnwrap(scene.joints.first { $0.name == "j" })
        let freedoms = try XCTUnwrap(j.pair).freedoms()
        XCTAssertEqual(freedoms.count, 1)
        XCTAssertNil(freedoms[0].lower)
        XCTAssertEqual(freedoms[0].upper, 1.0)
        scene.close()
    }

    // ---- Solid.silhouetteBeziers ------------------------------------------------------------
    // The curves where a body's surfaces turn away from the eye. The assertions are on values that pin
    // the layout, not only on lengths: a stride-16 unpack that reads a weight as a coordinate, or points
    // shifted by one slice, still gives arrays of the right length.

    func testASpheresRimHasItsEndPointsOnItTo1e9AndItsEndWeightsExactlyOne() throws {
        let rim = try Solid.sphere(2).silhouetteBeziers()
        XCTAssertGreaterThan(rim.count, 0, "a sphere gave no rim")
        XCTAssertEqual(rim.points.count, rim.count * 4 * 3)
        XCTAssertEqual(rim.weights.count, rim.count * 4)
        let points = Array(rim.points), weights = Array(rim.weights)
        func radius(_ curve: Int, _ k: Int) -> Double {
            let o = curve * 12 + k * 3
            return (points[o] * points[o] + points[o + 1] * points[o + 1] + points[o + 2] * points[o + 2]).squareRoot()
        }
        for c in 0..<rim.count {
            // Control points 0 and 3 are the arc's ends: on the sphere to 1e-9, with the end
            // weights exactly 1. The interior control points are not checked at all, and the interior
            // weights only to lie in (0, 1): both move with how the rim is subdivided.
            XCTAssertLessThanOrEqual(abs(radius(c, 0) - 2), 1e-9, "arc \(c): first control point at radius \(radius(c, 0))")
            XCTAssertLessThanOrEqual(abs(radius(c, 3) - 2), 1e-9, "arc \(c): last control point at radius \(radius(c, 3))")
            let w = Array(weights[c * 4 ..< c * 4 + 4])
            XCTAssertTrue(w[0] == 1 && w[3] == 1 && w[1] > 0 && w[1] < 1 && w[2] > 0 && w[2] < 1,
                          "arc \(c): weights \(w), not 1, then two weights in (0, 1), then 1")
        }
    }

    func testACylindersRulingsArePolynomialAndSpanItsHeight() throws {
        let radius = 1.0, height = 3.0
        let rulings = try Solid.cylinder(radius, height).silhouetteBeziers(SvgOptions(view: .front))
        XCTAssertGreaterThan(rulings.count, 0, "a cylinder gave no rulings")
        XCTAssertEqual(rulings.points.count, rulings.count * 4 * 3)
        XCTAssertEqual(rulings.weights.count, rulings.count * 4)
        XCTAssertTrue(rulings.weights.allSatisfy { $0 == 1 }, "a ruling carries a weight other than 1")
        let points = Array(rulings.points)
        for k in 0..<rulings.count * 4 {
            let off = (points[k * 3] * points[k * 3] + points[k * 3 + 1] * points[k * 3 + 1]).squareRoot() - radius
            XCTAssertLessThanOrEqual(abs(off), 1e-6, "control point \(k) is off the cylinder's wall")
            // `hypot(x, y)` is symmetric in x and y, so it cannot tell them apart. The front view looks
            // along y and the silhouette of the cylinder sits on the x axis, at y = 0: that is what pins
            // x against y. Only |x| and |y| are asserted, not the sign of x and not how many rulings
            // there are.
            XCTAssertLessThanOrEqual(abs(abs(points[k * 3]) - radius), 1e-6, "control point \(k) is not at |x| = \(radius)")
            XCTAssertLessThanOrEqual(abs(points[k * 3 + 1]), 1e-6, "control point \(k) is not at y = 0")
        }
        // The rulings run cap to cap, so their z extent is the height: that pins z against x and y.
        let zs: [Double] = (0..<rulings.count * 4).map { (i: Int) -> Double in points[i * 3 + 2] }
        let low = try XCTUnwrap(zs.min()), high = try XCTUnwrap(zs.max())
        XCTAssertLessThanOrEqual(abs(high - low - height), 1e-6, "the rulings span z \(low)...\(high), not a height of \(height)")
    }

    func testAnInfiniteToleranceIsRefusedAndAnAllPlanarBodyIsTheEmptyAnswerAfterIt() throws {
        let sphere = try Solid.sphere(2)
        // Built BEFORE the refusal, not between it and the ask: every call that builds, reads or
        // writes geometry in the library runs under its `guard`, whose first act is `clear_error`
        // (blacksmith-capi lib.rs:117), so building the cuboid in between would wipe the refusal's
        // message. The order is build, refuse, ask. Nothing this wrapper does between the refusal
        // and the native call clears the slot, though: it packs the stroke as a number
        // (`SvgOptions.stroke` is a packed UInt32), so there is no
        // `cadaclysm_blacksmith_parse_colour` call (a `guard`, lib.rs:200) to wipe it as there is
        // in a wrapper that parses the text "#000000", and `buildSvgOptions` calls only
        // `cadaclysm_blacksmith_svg_options_init`, a bare struct fill (output.rs:699) that does not
        // clear. So the refusal's message is still in the slot when
        // `cadaclysm_blacksmith_silhouette_beziers` begins, and this test pins two things. First,
        // that the wrapper must not read the slot anywhere before the native call: a read before
        // packing and a read after packing both fail it. Second, that the library's own entry
        // clears the slot (the entry is a `guard`, output.rs:908): that one is read from the
        // source, not mutation-witnessed, since proving it would take a rebuilt library. The
        // reader's entry point has its own library-side pin,
        // `an_empty_answer_after_a_refusal_carries_no_stale_error`
        // (crates/cadaclysm-capi/tests/silhouette_abi.rs:401); there is no kernel-side equivalent.
        // Only calls under `guard` clear: `cadaclysm_blacksmith_solid_free` and
        // `cadaclysm_blacksmith_silhouette_beziers_free` just drop a box and the error getter does
        // not clear either, so a `deinit` running between the refusal and the ask cannot wipe the
        // slot.
        let cuboid = try Solid.cuboid(10, 10, 10)
        var infinite = SvgOptions()
        infinite.tolerance = .infinity
        let message = refusal { _ = try sphere.silhouetteBeziers(infinite) }
        XCTAssertTrue(message?.contains("silhouette: ") == true, "\(String(describing: message))")
        let none = try cuboid.silhouetteBeziers()
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(none.points.count, 0)
        XCTAssertEqual(none.weights.count, 0)
    }

    /// The block the kernel hands over is owned and freed inside the call, and the answer is copied
    /// into memory of its own, so a second ask for another eye leaves the first as it was.
    func testASilhouetteOutlivesTheNextOneAsked() throws {
        let sphere = try Solid.sphere(2)
        let first = try sphere.silhouetteBeziers(SvgOptions(view: .front))
        let keptPoints = Array(first.points), keptWeights = Array(first.weights)
        let second = try sphere.silhouetteBeziers(SvgOptions(view: .iso))
        XCTAssertGreaterThan(second.count, 0)
        XCTAssertNotEqual(Array(second.points), keptPoints, "the two views gave the same silhouette, so this cannot tell much")
        XCTAssertEqual(Array(first.points), keptPoints)
        XCTAssertEqual(Array(first.weights), keptWeights)
        XCTAssertEqual(Array(try sphere.silhouetteBeziers(SvgOptions(view: .front)).points), keptPoints,
                       "asking again for the same eye gives the same curves")
    }
}

/// `text` with every `FILE_NAME(` line removed -- what fact 3 compares before and after
/// the eleven refusals, since only the timestamp line should ever move.
private func noStamp(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("FILE_NAME(") }
        .joined(separator: "\n")
}

/// How many non-overlapping occurrences of `needle` appear in `haystack`.
private func countOf(_ haystack: String, _ needle: String) -> Int {
    var count = 0, from = haystack.startIndex
    while let range = haystack.range(of: needle, range: from..<haystack.endIndex) {
        count += 1
        from = range.upperBound
    }
    return count
}

// MARK: - The Kiln: the SubD cage (Python's test_subd_*)

private let subdQuarterTurn: [Double] = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]

private func subdDistance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

extension KernelTests {
    func testSubdRoundTripsThroughParts() throws {
        let cube = try Subd.cuboid()
        defer { cube.close() }
        var positions = try cube.positions
        XCTAssertEqual(positions.count, 8)
        XCTAssertEqual(try cube.faces.map { $0.count }, [4, 4, 4, 4, 4, 4])
        XCTAssertEqual(try cube.creases, [])
        XCTAssertEqual(try cube.pins, [])
        XCTAssertNil(try cube.symmetry)
        XCTAssertNil(try cube.selection)
        let was = positions[0].x
        positions[0].x = 99.0   // a copy: writing to it changes nothing
        XCTAssertEqual(try cube.positions[0].x, was)
        let again = try Subd.fromParts(try cube.positions, try cube.faces)
        defer { again.close() }
        XCTAssertEqual(try again.positions, try cube.positions)
        XCTAssertEqual(try again.faces, try cube.faces)
    }

    func testSubdEditsReturnNewCagesWithTheirSelection() throws {
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let out = try cube.extrude([1], 1.0)
        defer { out.close() }
        XCTAssertEqual(try out.positions.count, 12)
        XCTAssertEqual(try out.selection, .faces([1]))
        XCTAssertEqual(try cube.positions.count, 8, "the input is untouched")
    }

    func testSubdCreaseAndPinRoundTrip() throws {
        let cube = try Subd.cuboid()
        let creased = try cube.crease([SubdEdge(0, 1)])
        let pinned = try creased.pin([6])
        defer { [cube, creased, pinned].forEach { $0.close() } }
        XCTAssertEqual(try creased.selection, .edges([SubdEdge(0, 1)]))
        XCTAssertEqual(try pinned.creases, [SubdEdge(0, 1)])
        XCTAssertEqual(try pinned.pins, [6])
        XCTAssertEqual(try pinned.selection, .vertices([6]))
        let again = try Subd.fromParts(try pinned.positions, try pinned.faces, creases: try pinned.creases,
                                       pins: try pinned.pins)
        defer { again.close() }
        XCTAssertEqual(try again.creases, [SubdEdge(0, 1)])
        XCTAssertEqual(try again.pins, [6])
        let plain = try pinned.crease([SubdEdge(0, 1)], on: false)
        let free = try pinned.pin([6], on: false)
        defer { plain.close(); free.close() }
        XCTAssertEqual(try plain.creases, [])
        XCTAssertEqual(try free.pins, [])
    }

    func testSubdMirrorRoundTrip() throws {
        let whole = try Subd.cuboid(size: SIMD3(2, 2, 2), segments: (2, 1, 1))
        let half = try whole.mirrorOn(.x)
        defer { whole.close(); half.close() }
        let symmetry = try XCTUnwrap(try half.symmetry)
        XCTAssertEqual(symmetry.axis, .x)
        XCTAssertGreaterThan(symmetry.tolerance, 0)
        XCTAssertNil(try half.selection)
        XCTAssertLessThan(try half.positions.count, try whole.positions.count)
        let again = try Subd.fromParts(try half.positions, try half.faces, creases: try half.creases,
                                       pins: try half.pins, symmetry: symmetry)
        defer { again.close() }
        XCTAssertEqual(try again.positions, try half.positions)
        XCTAssertEqual(try again.symmetry, symmetry)
        let full = try half.full()
        let off = try half.mirrorOff()
        defer { full.close(); off.close() }
        XCTAssertEqual(try full.positions.count, try whole.positions.count)
        XCTAssertNil(try off.symmetry)
    }

    func testSubdEdgeLoopListsTheLoop() throws {
        let cube = try Subd.cuboid(size: SIMD3(2, 2, 2), segments: (2, 2, 2))
        defer { cube.close() }
        let face = try cube.faces[0]
        let (a, b) = (face[0], face[1])
        let loop = try cube.edgeLoop(SubdEdge(a, b))
        XCTAssertGreaterThanOrEqual(loop.count, 4)
        XCTAssertEqual(loop.first, SubdEdge(Swift.min(a, b), Swift.max(a, b)), "the picked edge first")
    }

    func testSubdEdgeLoopOfANonEdgeIsEmpty() throws {
        // The C call hands back a handle selecting no edges (kind 1, count 0), not a refusal.
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let face = try cube.faces[0]
        XCTAssertEqual(try cube.edgeLoop(SubdEdge(face[0], face[2])), [], "a face diagonal is no edge")
        XCTAssertEqual(try cube.edgeLoop(SubdEdge(0, 99)), [], "nor is a pair naming no vertex")
    }

    func testSubdTransformRotates() throws {
        // 90 degrees about Z: (x, y, z) -> (-y, x, z), every corner of the cube.
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let before = try cube.positions
        let everything = SubdSelection.vertices((0..<UInt32(before.count)).map { $0 })
        let turned = try cube.transform(everything, subdQuarterTurn)
        defer { turned.close() }
        for (p, q) in zip(try turned.positions, before) {
            assertClose(p, SIMD3(-q.y, q.x, q.z), 1e-12)
        }
        let one = try cube.transform(.vertices([0]), subdQuarterTurn)
        defer { one.close() }
        let moved = try one.positions
        assertClose(moved[0], SIMD3(-before[0].y, before[0].x, before[0].z), 1e-12)
        XCTAssertEqual(Array(moved[1...]), Array(before[1...]))
    }

    func testSubdTransformInsetAndInsertLoop() throws {
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let translate: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 3, 0, 0, 1]
        let moved = try cube.transform(.edges([SubdEdge(0, 1)]), translate)
        defer { moved.close() }
        XCTAssertEqual(try moved.positions[0].x, try cube.positions[0].x + 3.0)
        XCTAssertEqual(try moved.selection, .edges([SubdEdge(0, 1)]))
        let inset = try cube.inset([1], 0.25)
        defer { inset.close() }
        XCTAssertEqual(try inset.faces.count, 6 + 4)
        let looped = try cube.insertLoop(SubdEdge(0, 1))
        defer { looped.close() }
        XCTAssertEqual(try looped.positions.count, 8 + 4)
        XCTAssertEqual(try looped.selection?.kind, .edges)
        let bad = refusal { _ = try cube.insertLoop(SubdEdge(0, 1), at: 1.5) }
        XCTAssertTrue(bad?.hasPrefix("bad selection: ") ?? false, "\(String(describing: bad))")
        let short = refusal { _ = try cube.transform(.vertices([0]), [1, 2, 3]) }
        XCTAssertTrue(short?.contains("matrix") ?? false, "\(String(describing: short))")
    }

    func testSubdSubdivide() throws {
        let kiln = try Subd.cuboid(size: SIMD3(2, 2, 2), segments: (2, 2, 2))
        defer { kiln.close() }
        let whole = try kiln.subdivide()
        defer { whole.close() }
        XCTAssertEqual(try whole.faces.count, 96)
        let one = try kiln.subdivide([1])
        defer { one.close() }
        XCTAssertEqual(try one.faces.count, 27)
        XCTAssertEqual(try one.selection?.kind, .faces)
        if case .faces(let picked)? = try one.selection { XCTAssertEqual(picked.count, 4) } else { XCTFail("no face selection") }
        let bad = refusal { _ = try kiln.subdivide([999]) }
        XCTAssertTrue(bad?.contains("subdivide: face 999 is not in the cage") ?? false, "\(String(describing: bad))")
    }

    func testSubdSmoothMeshIsConsistentAndKept() throws {
        let cube = try Subd.cuboid()
        let mesh = try cube.smoothMesh(2)
        let n = mesh.positions.count
        XCTAssertGreaterThan(n, 8)
        XCTAssertEqual(mesh.normals.count, n)
        XCTAssertEqual(mesh.indices.count % 3, 0)
        XCTAssertLessThan(try XCTUnwrap(mesh.indices.max()), UInt32(n))
        XCTAssertEqual(mesh.triangleFace.count, mesh.indices.count / 3)
        XCTAssertLessThan(try XCTUnwrap(mesh.triangleFace.max()), 6)
        for normal in mesh.normals {
            XCTAssertEqual((normal * normal).sum().squareRoot(), 1.0, accuracy: 1e-9)
        }
        XCTAssertLessThan(try cube.smoothMesh(1).positions.count, n)
        XCTAssertEqual(try cube.smoothMesh(2).positions, mesh.positions)
        let bad = refusal { _ = try cube.smoothMesh(7) }
        XCTAssertTrue(bad?.contains("levels") ?? false, "\(String(describing: bad))")
        let positions = mesh.positions, normals = mesh.normals, indices = mesh.indices, faces = mesh.triangleFace
        cube.close()
        // A mesh is a copy: it outlives its cage, and the freed views are not read.
        XCTAssertEqual(mesh.positions.count, n)
        XCTAssertEqual(mesh.positions, positions)
        XCTAssertEqual(mesh.normals, normals)
        XCTAssertEqual(mesh.indices, indices)
        XCTAssertEqual(mesh.triangleFace, faces)
    }

    func testSubdPickFindsTheElementOrNil() throws {
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let corner = try cube.positions[6]
        let mesh = try cube.smoothMesh(3)
        let point = try XCTUnwrap(mesh.positions.min { subdDistance($0, corner) < subdDistance($1, corner) })
        XCTAssertEqual(try cube.pick(point, .vertices), .vertices([6]))
        guard case .edges(let edges)? = try cube.pick(point, .edges) else { return XCTFail("an edge is expected") }
        XCTAssertEqual(edges.count, 1)
        XCTAssertTrue(edges[0].a == 6 || edges[0].b == 6)
        guard case .faces(let faces)? = try cube.pick(point, .faces) else { return XCTFail("a face is expected") }
        XCTAssertEqual(faces.count, 1)
        // The refusal comes first: a stale last_error would make the far point look refused.
        XCTAssertEqual(refusal { _ = try cube.pick(SIMD3(Double.nan, 0, 0), .faces) },
                       "bad selection: pick: point is not finite")
        XCTAssertNil(try cube.pick(SIMD3(100, 100, 100), .vertices), "nothing near is nil, not an error")
    }

    func testSubdToSolidConvertsACube() throws {
        let cube = try Subd.cuboid()
        defer { cube.close() }
        let (solid, report) = try cube.toSolid()
        defer { solid.close() }
        XCTAssertEqual(report.regular, 0)
        XCTAssertEqual(report.refined, 24)
        XCTAssertGreaterThanOrEqual(report.levels, 2)
        XCTAssertGreaterThanOrEqual(report.steps, 1)
        XCTAssertLessThanOrEqual(report.deviation, 1e-4)
        XCTAssertLessThanOrEqual(report.g1AngleDeg, 0.1)
        XCTAssertTrue(report.deviationAt.x.isFinite && report.deviationAt.y.isFinite && report.deviationAt.z.isFinite)
        XCTAssertTrue(report.g1At.x.isFinite && report.g1At.y.isFinite && report.g1At.z.isFinite)
        XCTAssertTrue(try solid.manifold.isClosed)
        let mass: Mass = try solid.mass()   // Solid has two `mass` overloads: ask for the plain-data one
        XCTAssertGreaterThan(mass.volume, 0.0)
        let (again, _) = try cube.toSolid(tolerance: 1e-4, g1Angle: 0.1, maxLevels: 6)
        again.close()
    }

    func testSubdToSolidRefusesWithFigures() throws {
        let cylinder = try Subd.cylinder(radius: 1.0, height: 2.0, sides: 8, rings: 1, creasedRims: false)
        defer { cylinder.close() }
        let message = try XCTUnwrap(refusal { _ = try cylinder.toSolid() }, "an uncreased cylinder must be refused")
        XCTAssertNotNil(message.range(of: "subd:.*tangent break", options: .regularExpression), message)
    }

    func testSubdDefaultCylinderConverts() throws {
        let cylinder = try Subd.cylinder()
        defer { cylinder.close() }
        let (solid, report) = try cylinder.toSolid()
        defer { solid.close() }
        XCTAssertLessThanOrEqual(report.deviation, 1e-4)
        XCTAssertLessThanOrEqual(report.g1AngleDeg, 0.1)
        XCTAssertTrue(try solid.manifold.isClosed)
        let mass: Mass = try solid.mass()   // Solid has two `mass` overloads: ask for the plain-data one
        XCTAssertGreaterThan(mass.volume, 0.0)
    }

    func testSubdOtherPrimitivesBuildAndBadOnesAreRefused() throws {
        for cage in [try Subd.cylinder(radius: 1.0, height: 2.0, sides: 8, rings: 2, creasedRims: true),
                     try Subd.sphere(radius: 1.0, segments: 2),
                     try Subd.torus(major: 3.0, minor: 1.0, around: 12, tube: 8)] {
            XCTAssertGreaterThan(try cage.faces.count, 0)
            cage.close()
        }
        XCTAssertEqual(refusal { _ = try Subd.cuboid(size: SIMD3(2, 2, 2), segments: (0, 1, 1)) },
                       "bad selection: cuboid: segments >= 1")
        let big = refusal { _ = try Subd.sphere(radius: 1.0, segments: 2000) }
        XCTAssertTrue(big?.contains("1024") ?? false, "\(String(describing: big))")
    }

    func testSubdBadPartsAreRefused() throws {
        let cube = try Subd.cuboid()
        let positions = try cube.positions, faces = try cube.faces
        cube.close()
        let crease = refusal { _ = try Subd.fromParts(positions, faces, creases: [SubdEdge(0, 6)]) }
        XCTAssertTrue(crease?.hasPrefix("bad selection: ") ?? false, "\(String(describing: crease))")
        let empty = refusal { _ = try Subd.fromParts([], faces) }
        XCTAssertTrue(empty?.contains("vertex_count") ?? false, "\(String(describing: empty))")
    }

    func testSubdPipelineWritesStep() throws {
        let cube = try Subd.cuboid()
        let raised = try cube.extrude([1], 0.5)
        let inset = try raised.inset([1], 0.25)
        defer { [cube, raised, inset].forEach { $0.close() } }
        let (solid, report) = try inset.toSolid()
        defer { solid.close() }
        XCTAssertTrue(try solid.manifold.isClosed)
        XCTAssertLessThanOrEqual(report.deviation, 1e-4)
        let text = try solid.stepText()
        XCTAssertTrue(text.hasPrefix("ISO-10303-21;"))
        XCTAssertTrue(text.contains("ADVANCED_FACE"))
        let scene = try Cadaclysm.openMemory(Array(text.utf8), format: "stp")
        defer { scene.close() }
        XCTAssertEqual(scene.nodes.filter { $0.canMesh }.count, 1, "the STEP the SubD cage wrote is one body")
    }

    func testSubdHandlesClose() throws {
        let cube = try Subd.cuboid()
        cube.close()
        cube.close()   // closing twice is fine
        XCTAssertTrue(cube.isClosed)
        let calls: [() throws -> Void] = [
            { _ = try cube.positions }, { _ = try cube.extrude([1], 1.0) }, { _ = try cube.smoothMesh(1) },
            { _ = try cube.pick(SIMD3(0, 0, 0), .faces) }, { _ = try cube.toSolid() },
        ]
        for call in calls { XCTAssertEqual(refusal(call), "subd: closed") }
        let other = try Subd.cuboid()
        other.close()
        XCTAssertEqual(refusal { _ = try other.faces }, "subd: closed")
    }

    // MARK: Mechanical drawings: hidden lines, the projected outline, pages, DXF profiles

    func testACubeOnItsDiagonalShowsNineLinesAndHidesThree() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let diagonal = SIMD3<Double>(-1, -1, -1)
        let view = try hlr([cube], HlrOptions(direction: diagonal))
        XCTAssertEqual(view.visible().count, 9)
        XCTAssertEqual(view.hidden().count, 3)
        for line in view.lines {
            XCTAssertEqual(line.kind, .sharp, line.description)
            XCTAssertEqual(line.solid, 0)
            if case .edge = line.source {} else { XCTFail("an edge source: \(line)") }
            XCTAssertTrue(line.beziers2d.count >= 1 && line.beziers2d.count == line.beziers3d.count, line.description)
            for k in 0..<line.beziers2d.count * 4 { XCTAssertEqual(line.beziers2d.points[k * 3 + 2], 0.0) }
        }
        let seen: Double = view.visible().reduce(0.0) { $0 + $1.length3d }
        let unseen: Double = view.hidden().reduce(0.0) { $0 + $1.length3d }
        XCTAssertEqual(seen, 90.0, accuracy: 1e-6)
        XCTAssertEqual(unseen, 30.0, accuracy: 1e-6)
        // The three hidden edges meet at the far corner.
        for line in view.hidden() {
            let p = line.beziers3d.points
            let n = line.beziers3d.count * 12
            let ends = [SIMD3(p[0], p[1], p[2]), SIMD3(p[n - 3], p[n - 2], p[n - 1])]
            let corner = SIMD3<Double>(-5, -5, -5)
            XCTAssertTrue(ends.contains { (($0 - corner) * ($0 - corner)).sum() < 1e-18 }, line.description)
        }
        XCTAssertEqual(view.report.unsettled, 0)
        XCTAssertEqual(view.tolerance, try effectiveTolerance(cube), accuracy: 1e-12)
        view.close()
        XCTAssertTrue(view.isClosed)
    }

    func testACubeInPerspectiveAndAsAMeshShowsNineAndHidesThree() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let eye = SIMD3<Double>(30, 25, 20)
        let seen = try hlr([cube], HlrOptions(eye: eye, target: SIMD3<Double>(0, 0, 0)))
        XCTAssertEqual(seen.visible().count, 9)
        XCTAssertEqual(seen.hidden().count, 3)
        let positions: [SIMD3<Double>] = [[-5, -5, -5], [5, -5, -5], [5, 5, -5], [-5, 5, -5],
                                          [-5, -5, 5], [5, -5, 5], [5, 5, 5], [-5, 5, 5]]
        let triangles: [(UInt32, UInt32, UInt32)] = [(0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
                                                     (3, 7, 6), (3, 6, 2), (0, 4, 7), (0, 7, 3), (1, 2, 6), (1, 6, 5)]
        let mesh = try TriangleMesh(positions, triangles)
        let view = try hlrMesh([mesh], HlrOptions(direction: SIMD3<Double>(-1, -1, -1)))
        XCTAssertEqual(view.visible().count, 9)
        XCTAssertEqual(view.hidden().count, 3)
        for line in view.lines {
            if case .meshEdge(let a, let b) = line.source {
                XCTAssertTrue(a < 8 && b < 8 && a != b, line.description)
            } else {
                XCTFail("a mesh edge source: \(line)")
            }
        }
    }

    func testHiddenLineWordsAreRefusedNamingTheCall() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        XCTAssertTrue(refusal { _ = try hlr([cube], HlrOptions(direction: SIMD3<Double>(0, 0, -1))) }?.hasPrefix("hlr: up is along the view") ?? false)
        XCTAssertEqual(refusal { _ = try hlr([]) }, "hlr: no solids")
        XCTAssertTrue(refusal { _ = try hlr([cube], HlrOptions(tolerance: -1)) }?.hasPrefix("hlr: tolerance must be 0 or more") ?? false)
        XCTAssertEqual(refusal { _ = try hlr([cube], HlrOptions(direction: SIMD3<Double>(1, 0, 0), eye: SIMD3<Double>(5, 5, 5))) },
                       "hlr: give direction (parallel) or eye (perspective), not both")
        XCTAssertTrue(refusal { _ = try Page(units: "furlongs") }?.hasPrefix("page_new: units") ?? false)
    }

    func testAPlateOutlinesAsOneProfileWithItsHole() throws {
        let hole = try Solid.cylinder(5, 20).translate(0, 0, -10)
        let plate = try Solid.cuboid(40, 30, 5).cut(hole, tolerance: nil)
        let profiles = try projectedOutline([plate], HlrOptions(direction: SIMD3<Double>(0, 0, -1), up: SIMD3<Double>(0, 1, 0)))
        XCTAssertEqual(profiles.count, 1)
        let flat = try profiles[0].beziers()
        var widest = 0.0
        for k in stride(from: 0, to: flat.count, by: 4) { widest = max(widest, abs(flat[k])) }
        XCTAssertEqual(widest, 20.0, accuracy: 1e-6)
        XCTAssertTrue(flat.count / 16 > 4, "the rectangle's four sides, then the hole's pieces")
        // The hole is a hole: the outline extruded is the plate's area less the hole's.
        let slab = try Solid.extrude(profiles[0], try Frame.xy(), 1)
        let mass: Mass = try slab.mass()
        let expected: Double = 40.0 * 30.0 - Double.pi * 25.0
        XCTAssertEqual(mass.volume, expected, accuracy: 0.5)
    }

    func testSvgDrawsHiddenLinesRemovedOrDashed() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let el: Double = atan(1.0 / 2.0.squareRoot()) * 180.0 / Double.pi
        let options = SvgOptions(azimuth: 45, elevation: el)
        let removed = try writeSvgText([cube], options: options, hidden: .removed)
        XCTAssertTrue(removed.contains("<g id=\"solid-0\""))
        XCTAssertFalse(removed.contains("solid-0-hidden"))
        let dashed = try writeSvgText([cube], options: options, hidden: .dashed)
        guard let start = dashed.range(of: "<g id=\"solid-0-hidden\"") else { return XCTFail("no hidden group") }
        let rest = dashed[start.lowerBound...]
        guard let end = rest.range(of: "</g>") else { return XCTFail("an unclosed hidden group") }
        let group = rest[..<end.lowerBound]
        XCTAssertTrue(group.contains("stroke-dasharray"))
        XCTAssertEqual(group.filter { $0 == "M" }.count, 3)
        let drawn = try writeSvgText([cube], options: options, hidden: .drawn)
        XCTAssertFalse(drawn.contains("solid-0-hidden"))
        // Removed leaves the three hidden edges out of the solid's own group: it differs from
        // the group that draws every line, and draws fewer paths.
        func solidGroup(_ svg: String) -> Substring {
            guard let start = svg.range(of: "<g id=\"solid-0\"") else { return "" }
            let rest = svg[start.lowerBound...]
            guard let end = rest.range(of: "</g>") else { return "" }
            return rest[..<end.lowerBound]
        }
        XCTAssertNotEqual(solidGroup(removed), solidGroup(drawn))
        XCTAssertLessThan(solidGroup(removed).filter { $0 == "M" }.count, solidGroup(drawn).filter { $0 == "M" }.count)
    }

    func testAPageWritesR2000DxfThatReadsBackAsItsProfiles() throws {
        let cube = try Solid.cuboid(10, 10, 10)
        let plate = try Profile.rect(40, 20)
        let page = try Page(units: "mm")
        try page.addView(try hlr([cube], HlrOptions(direction: SIMD3<Double>(-1, -1, -1))), at: SIMD2<Double>(50, 50), scale: 2)
        XCTAssertEqual(try page.entityCount, 12)
        let at = SIMD2<Double>(150, 50)
        try page.addProfile(plate, at: at, layer: "parts")
            .addHatch(plate, pattern: "ANSI31", at: at)
            .addText("PLATE", at: SIMD2<Double>(150, 30), height: 3.5, halign: "center")
        XCTAssertEqual(try page.entityCount, 15)
        let dxf = try page.dxf()
        XCTAssertTrue(dxf.hasPrefix("  0\nSECTION\n  2\nHEADER\n  9\n$ACADVER\n  1\nAC1015\n"), String(dxf.prefix(80)))
        XCTAssertEqual(dxf, try page.dxf())
        for layer in ["visible", "hidden", "parts", "hatch", "text"] {
            XCTAssertTrue(dxf.contains("\n  8\n\(layer)\n"), layer)
        }
        let svg = try page.svg()
        XCTAssertTrue(svg.contains("<svg") && svg.contains("PLATE"))

        // The rectangle alone round-trips: one profile, where it was put.
        let alone = try Page(units: "mm").addProfile(plate, at: at)
        let back = try dxfProfiles(try alone.dxf())
        XCTAssertEqual(back.count, 1)
        let flat = try back[0].beziers()
        var lo = SIMD2<Double>(.infinity, .infinity), hi = SIMD2<Double>(-.infinity, -.infinity)
        for k in stride(from: 0, to: flat.count, by: 4) {
            lo = SIMD2(min(lo.x, flat[k]), min(lo.y, flat[k + 1]))
            hi = SIMD2(max(hi.x, flat[k]), max(hi.y, flat[k + 1]))
        }
        XCTAssertEqual(lo.x, 130.0, accuracy: 1e-6)
        XCTAssertEqual(lo.y, 40.0, accuracy: 1e-6)
        XCTAssertEqual(hi.x, 170.0, accuracy: 1e-6)
        XCTAssertEqual(hi.y, 60.0, accuracy: 1e-6)
        XCTAssertTrue(refusal { _ = try dxfProfiles("not a DXF file") }?.hasPrefix("dxf_profiles: line ") ?? false)
        XCTAssertTrue(refusal { try page.addHatch(plate, pattern: "BRICK") }?.hasPrefix("page_add_hatch: pattern") ?? false)
        page.close()
        XCTAssertTrue(page.isClosed)
    }
}
