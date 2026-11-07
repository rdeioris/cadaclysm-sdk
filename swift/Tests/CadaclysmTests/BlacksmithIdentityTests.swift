// Identity and attributes over the release library: Python's TestIdentity, trimmed to what
// proves the marshalling -- ids as `UInt64?` with nil for none, origins as `Origin`, a history
// read whole into its four lists, attributes in key order, the edge and vertex references'
// layouts, the `merge` step reading origins back through the boolean, every refusal's prefix.
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

/// A 10-cube centred on the origin and a pin through it (radius 2, along z, z -10..10), both
/// tracked -- the kernel's oracle 2 cut.
private func blockAndPin() throws -> (Solid, Solid) {
    (try Solid.cuboid(10, 10, 10).tracked(), try Solid.cylinder(2, 20).translate(0, 0, -10).tracked())
}

/// Face `f`'s outward normal's z, off its reference.
private func nz(_ solid: Solid, _ f: Int) throws -> Double { try solid.faceRef(f)[6] }

final class BlacksmithIdentityTests: XCTestCase {
    func testTrackingNumbersFacesAndEdgesAndAnUntrackedSolidHasNoIds() throws {
        let plain = try Solid.cuboid(1, 2, 3)
        XCTAssertFalse(try plain.isTracked)
        XCTAssertNil(try plain.faceId(0))
        XCTAssertNil(try plain.edgeId(0))
        XCTAssertEqual(try plain.faceOrigins(0), [])
        let t = try plain.tracked()
        XCTAssertTrue(try t.isTracked)
        XCTAssertEqual(try t.tracked().faceId(5), 6)
        XCTAssertEqual(try (0..<6).map { try t.faceId($0) }, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(try (0..<12).map { try t.edgeId($0) }, (1...12).map { UInt64($0) })
        XCTAssertEqual(try t.faceWithId(4), 3)
        XCTAssertNil(try t.faceWithId(7))
        XCTAssertNil(try t.faceWithId(0))
        XCTAssertEqual(try t.edgeWithId(12), 11)
        XCTAssertNil(try t.edgeWithId(13))
        XCTAssertEqual(try t.faceOrigins(2), [Origin(0, 3)])
        XCTAssertEqual(try t.edgeOrigins(11), [Origin(0, 12)])
        XCTAssertEqual(refusal { _ = try t.faceId(6) }, "face_id: face 6 of 6")
        XCTAssertEqual(refusal { _ = try t.faceOrigins(6) }, "face_origin_count: face 6 of 6")
        XCTAssertEqual(refusal { _ = try t.edgeId(12) }, "edge_id: edge 12 of 12")
    }

    func testACutsOriginsAndHistory() throws {
        let (block, pin) = try blockAndPin()
        let wall = try (0..<pin.faces).first { try pin.faceKind($0) == "cylinder" }!
        let wallId = try XCTUnwrap(try pin.faceId(wall))
        let caps = try (0..<pin.faces).filter { $0 != wall }.map { Origin(1, try XCTUnwrap(try pin.faceId($0))) }
        let cut = try block.cut(pin)
        let bore = try (0..<cut.faces).first { try cut.faceKind($0) == "cylinder" }!
        XCTAssertEqual(try cut.faceOrigins(bore), [Origin(1, wallId)], "the bore came from the pin's wall")
        XCTAssertEqual(try cut.faceId(bore), 7, "renumbered: the wall's id is the box's")
        for f in 0..<(try cut.faces) where f != bore {
            XCTAssertEqual(try cut.faceOrigins(f), [Origin(0, try XCTUnwrap(try cut.faceId(f)))], "the box's own")
        }
        let h = try cut.history(block, pin)
        XCTAssertEqual(h.kept, (1...6).map { History.Kept(Origin(0, UInt64($0)), UInt64($0)) }, "the box's six kept")
        XCTAssertEqual(h.modified, [History.Modified(Origin(1, wallId), [7])], "the bore modified")
        XCTAssertEqual(h.generated, [])
        XCTAssertEqual(h.deleted, caps, "the pin's two caps deleted")
        XCTAssertEqual(h.description, "History(kept=6, modified=1, generated=0, deleted=2)")
        XCTAssertEqual(h, try cut.history(block, pin), "a history compares by value")
        let e = try cut.edgeHistory(block, pin)
        XCTAssertEqual(e.kept.count, 12)
        XCTAssertEqual(e.deleted, [Origin(1, 1), Origin(1, 2), Origin(1, 3)])
        XCTAssertEqual(e.generated.count, 3)
        XCTAssertEqual(e.modified, [])
        XCTAssertEqual(refusal { _ = try cut.history(block, try Solid.cuboid(1, 1, 1)) }, "history: input 1 is not tracked")
        let one = refusal { _ = try cut.history(block) } ?? ""
        XCTAssertTrue(one.hasPrefix("history: face ") && one.contains(" names operand 1"), one)
        XCTAssertEqual(refusal { _ = try Solid.cuboid(1, 1, 1).edgeHistory(block) }, "edge_history: the result is not tracked")
    }

    func testAUnionRenumbersTheSecondOperandsClashingIds() throws {
        let a = try Solid.cuboid(10, 10, 10).tracked()
        let b = try Solid.cuboid(10, 10, 10).translate(5, 5, 5).tracked()
        let joined = try a.join(b)
        XCTAssertEqual(try joined.faces, 12)
        var firsts = Set<UInt64>(), seconds: [(UInt64, UInt64)] = []
        for f in 0..<(try joined.faces) {
            let o = try joined.faceOrigins(f)[0]
            let id = try XCTUnwrap(try joined.faceId(f))
            if o.operand == 0 {
                XCTAssertEqual(id, o.id)
                firsts.insert(o.id)
            } else {
                seconds.append((id, o.id))
            }
        }
        XCTAssertEqual(firsts, Set(1...6))
        XCTAssertEqual(seconds.map { $0.0 }, Array(7...12), "renumbered in face order")
        XCTAssertEqual(Set(seconds.map { $0.1 }), Set(1...6), "their origins name operand 1's own ids")
    }

    func testASplitHalvesTheSidesAndItsBodiesKeepTheSplitsOrigins() throws {
        let block = try Solid.cuboid(2, 4, 6).tracked()
        let pieces = try block.splitByPlane(try Frame.xy())
        XCTAssertEqual(pieces.count, 2)
        let sides = Set(try (0..<6).filter { abs(try nz(block, $0)) < 0.5 }.map { try XCTUnwrap(try block.faceId($0)) })
        XCTAssertEqual(sides.count, 4)
        var halves: [UInt64: [UInt64]] = [:]
        var cutFaces = 0, caps = 0
        for piece in pieces {
            for f in 0..<(try piece.faces) {
                let o = try piece.faceOrigins(f), id = try XCTUnwrap(try piece.faceId(f))
                if o.isEmpty {
                    XCTAssertGreaterThan(id, 6, "a cut face is generated, with a fresh id")
                    cutFaces += 1
                } else if sides.contains(o[0].id) {
                    XCTAssertEqual(o, [Origin(0, o[0].id)])
                    halves[o[0].id, default: []].append(id)
                } else {
                    XCTAssertEqual(o, [Origin(0, id)], "a cap is kept")
                    caps += 1
                }
            }
        }
        XCTAssertEqual(cutFaces, 2)
        XCTAssertEqual(caps, 2)
        XCTAssertEqual(Set(halves.keys), sides)
        for (s, ids) in halves {
            XCTAssertEqual(ids.count, 2, "side \(s): \(ids)")
            XCTAssertEqual(ids.filter { $0 == s }.count, 1, "side \(s), one half keeping its id: \(ids)")
        }
        for piece in pieces {
            let h = try piece.history(block)
            XCTAssertEqual(h.generated.count, 1)
            XCTAssertEqual(h.deleted.count, 1)
        }
    }

    func testAFilletsRoundIsGenerated() throws {
        let block = try Solid.cuboid(10, 10, 10).tracked()
        let rounded = try block.fillet([0], 1.0)
        XCTAssertEqual(try rounded.faces, 7)
        let round = try (0..<rounded.faces).first { try rounded.faceKind($0) != "plane" }!
        XCTAssertEqual(try rounded.faceOrigins(round), [])
        XCTAssertEqual(try rounded.faceId(round), 7)
        let h = try rounded.history(block)
        XCTAssertEqual(h.generated, [7])
        XCTAssertEqual(h.kept.count, 6)
        XCTAssertNil(try rounded.edgeWithId(1), "the rounded edge is gone")
    }

    func testAFlushJoinMergedNamesOneOriginPerInput() throws {
        let a = try Solid.cuboid(10, 10, 10).tracked()
        let b = try Solid.cuboid(4, 10, 10).translate(7, 0, 0).tracked()
        let merged = try a.join(b, merge: true)
        XCTAssertEqual(try merged.faces, 6)
        var two = 0
        for f in 0..<(try merged.faces) {
            let o = try merged.faceOrigins(f)
            if abs(try merged.faceRef(f)[4]) < 0.5 {
                XCTAssertEqual(o.map { $0.operand }, [0, 1], "face \(f): \(o)")
                if o.count == 2 {
                    XCTAssertNotNil(try a.faceWithId(o[0].id))
                    XCTAssertNotNil(try b.faceWithId(o[1].id))
                }
                two += 1
            } else {
                XCTAssertEqual(o.count, 1, "face \(f): \(o)")
            }
        }
        XCTAssertEqual(two, 4)
        let h = try merged.history(a, b)
        XCTAssertEqual(h.generated, [])
        XCTAssertEqual(h.deleted.count, 2, "the two flush faces")
        XCTAssertEqual(h.modified.filter { $0.outputs.count == 1 && $0.input.operand == 1 }.count, 4)
    }

    func testTheSameChainTwiceNumbersTheSame() throws {
        func run() throws -> ([UInt64?], [UInt64?]) {
            let (block, pin) = try blockAndPin()
            let cut = try block.cut(pin)
            let line = try cut.edges.first { $0.isLine }!.index
            let r = try cut.fillet([line], 1.0)
            return (try (0..<r.faces).map { try r.faceId($0) }, try (0..<r.edges.count).map { try r.edgeId($0) })
        }
        let (f1, e1) = try run(), (f2, e2) = try run()
        XCTAssertEqual(f1, f2)
        XCTAssertEqual(e1, e2)
        XCTAssertFalse(f1.contains(nil))
    }

    func testAttributesAreSetReadListedAndRefused() throws {
        let s = try Solid.cuboid(1, 2, 3).withAttribute("material", "steel")
        XCTAssertTrue(try s.isTracked, "an attribute rides with the ids")
        XCTAssertEqual(try s.attribute("material"), "steel")
        XCTAssertNil(try s.attribute("absent"))
        XCTAssertEqual(try s.attributes.map { "\($0.key)=\($0.value)" }, ["material=steel"])
        let both = try s.withAttributes(["zeta": "1", "alpha": "2"])
        XCTAssertEqual(try both.attributes.map { $0.key }, ["alpha", "material", "zeta"])
        XCTAssertEqual(try both.attributes.map { $0.value }, ["2", "steel", "1"])
        let text = "acciaio inossidabile è ☃ \u{1F527}"
        XCTAssertEqual(try s.withAttribute("m", text).attribute("m"), text)
        XCTAssertEqual(try s.withAttribute("empty", "").attribute("empty"), "")
        XCTAssertEqual(refusal { _ = try s.withAttribute("", "x") }, "with_attribute: the key is empty")
        XCTAssertEqual(try s.withoutAttribute("absent").attributes.map { $0.key }, ["material"])
        XCTAssertTrue(try s.withoutAttribute("material").attributes.isEmpty)
        XCTAssertTrue(try Solid.cuboid(1, 1, 1).attributes.isEmpty)
    }

    func testFaceAttributesSurviveATranslateAndASplit() throws {
        let block = try Solid.cuboid(10, 10, 10)
        let side = try (0..<6).first { abs(try nz(block, $0)) < 0.5 }!
        let s = try block.withFaceAttribute(side, "finish", "ground")
        XCTAssertEqual(try s.faceAttribute(side, "finish"), "ground")
        let other = (side + 1) % 6
        XCTAssertNil(try s.faceAttribute(other, "finish"))
        XCTAssertTrue(try s.faceAttributes(other).isEmpty)
        XCTAssertEqual(try s.faceAttributes(side).map { "\($0.key)=\($0.value)" }, ["finish=ground"])
        let two = try s.withFaceAttributes(side, ["b": "1", "a": "2"])
        XCTAssertEqual(try two.faceAttributes(side).map { $0.key }, ["a", "b", "finish"])
        XCTAssertTrue(try s.withoutFaceAttribute(side, "finish").faceAttributes(side).isEmpty)
        XCTAssertEqual(try s.translate(5, 0, 0).faceAttribute(side, "finish"), "ground")
        XCTAssertEqual(refusal { _ = try s.faceAttribute(6, "finish") }, "face_attribute: face 6 is not one of the solid's 6")
        XCTAssertEqual(refusal { _ = try s.withFaceAttribute(side, "", "x") }, "with_face_attribute: the key is empty")
        // A split face's pieces keep their parent's attributes.
        let sideId = try XCTUnwrap(try s.faceId(side))
        var found: [String?] = []
        for p in try s.splitByPlane(try Frame.xy()) {
            for f in 0..<(try p.faces) where try p.faceOrigins(f).contains(Origin(0, sideId)) {
                found.append(try p.faceAttribute(f, "finish"))
            }
        }
        XCTAssertEqual(found, ["ground", "ground"])
    }

    func testASolidsAttributesReachStep() throws {
        let text = try Solid.cuboid(1, 2, 3).withAttribute("material", "steel").stepText()
        XCTAssertEqual(text.components(separatedBy: "PROPERTY_DEFINITION('material','user defined attribute',").count - 1, 1)
        XCTAssertTrue(text.contains("DESCRIPTIVE_REPRESENTATION_ITEM('material','steel')"))
        XCTAssertTrue(text.components(separatedBy: "ENDSEC;")[0].contains("AP242"), "the header names the AP242 schema")
    }

    func testEdgesAreFoundAgainAfterAStretchAndVerticesAfterAMove() throws {
        let box = try Solid.cuboid(10, 10, 10), long = try Solid.cuboid(11, 10, 10)
        let n = try box.edges.count
        XCTAssertEqual(n, 12)
        let refs = try (0..<n).map { try box.edgeRef($0) }
        XCTAssertTrue(refs.allSatisfy { $0.count == 15 })
        let found = try refs.map { try XCTUnwrap(try long.findEdge($0)) }
        XCTAssertEqual(found.sorted(), Array(0..<n), "\(found)")
        for (r, g) in zip(refs, found) {
            let tangent = try long.edgeRef(g)[4..<7]
            XCTAssertGreaterThan(abs(zip(r[4..<7], tangent).map { $0 * $1 }.reduce(0, +)), 0.99)
        }
        var bad = refs[0]
        bad[1] = .nan
        XCTAssertEqual(refusal { _ = try box.findEdge(bad) }, "find_edge: an edge reference is fifteen finite numbers")
        XCTAssertEqual(refusal { _ = try box.findEdge(Array(refs[0].prefix(14))) },
                       "find_edge: an edge reference is fifteen finite numbers")
        XCTAssertEqual(refusal { _ = try box.edgeRef(12) }, "edge_ref: edge 12 of 12")
        XCTAssertEqual(try box.vertexCount, 8)
        let moved = try box.translate(1e-4, 0, 0)
        for v in 0..<8 {
            let p = try box.vertexRef(v)
            XCTAssertEqual(p.count, 3)
            XCTAssertEqual(try moved.findVertex(p), v)
        }
        XCTAssertNil(try box.findVertex([100, 0, 0]))
        let nan = refusal { _ = try box.findVertex([0, 0, .nan]) } ?? ""
        XCTAssertTrue(nan.hasPrefix("find_vertex: "), nan)
    }
}
