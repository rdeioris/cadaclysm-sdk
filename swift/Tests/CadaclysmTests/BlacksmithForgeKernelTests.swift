// The forge's general kernel calls -- Document.revision/nodes/inputs/readers/probe/
// resultBeziers/meta and Profile.fromPieces/piecesJSON/filletCorner/bounds/reversed -- at parity
// with Python's tests (holed_document, test_document_revision_moves_with_the_state_only ..
// test_profile_fillet_corner_cuts_back_to_the_tangent_points), the same numbers. The calls
// answer JSON text, read here with JSONSerialization.
import Blacksmith
import Foundation
import XCTest

private typealias JSONObject = [String: Any]

private func json(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> Any {
    do {
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    } catch {
        XCTFail("not JSON: \(text)", file: file, line: line)
        return NSNull()
    }
}

private func object(_ text: String) -> JSONObject { json(text) as? JSONObject ?? [:] }
private func objects(_ text: String) -> [JSONObject] { (json(text) as? [Any] ?? []).compactMap { $0 as? JSONObject } }
private func strings(_ text: String) -> [String] { json(text) as? [String] ?? ["<not a list of strings: \(text)>"] }
private func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? .nan }

/// The library's message for what `body` refused, or nil when it threw nothing.
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

private func addOp(_ node: String) -> String { "{\"op\": \"add\", \"node\": \(node)}" }

private func setOp(_ id: String, _ fields: String) -> String {
    "{\"op\": \"set\", \"id\": \"\(id)\", \"fields\": \(fields)}"
}

/// Python's plate_document: a 10 x 10 rectangle `r1` and its 10 mm extrusion `x1`.
private func plateDocument() throws -> Document {
    let doc = try Document("mm")
    try doc.apply(addOp(#"{"id": "r1", "kind": "profile.rect", "w": 10, "h": 10}"#))
    try doc.apply(addOp(#"{"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10}"#))
    return doc
}

/// Python's holed_document: a 10 mm box and a 2 mm pin cut through it -- the box's six faces
/// and the hole's wall.
private func holedDocument() throws -> Document {
    let doc = try Document("mm")
    try doc.apply(addOp(#"{"id": "box", "kind": "solid.cuboid", "x": 10, "y": 10, "z": 10}"#))
    try doc.apply(addOp(#"{"id": "pin", "kind": "solid.cylinder", "r": 2, "h": 30, "at": [0, 0, -15]}"#))
    try doc.apply(addOp(#"{"id": "cut", "kind": "solid.cut", "target": "box", "tool": "pin"}"#))
    try doc.evaluate()
    return doc
}

private struct Dropped: Error {}

final class BlacksmithForgeKernelTests: XCTestCase {
    func testDocumentRevisionMovesWithTheStateOnly() throws {
        let doc = try plateDocument()
        let r0 = try doc.revision()
        XCTAssertGreaterThanOrEqual(r0, 1)
        try doc.evaluate()
        _ = try doc.save()
        _ = try doc.nodes()
        XCTAssertEqual(try doc.revision(), r0, "an evaluation, a save or a read leaves it")
        XCTAssertTrue(try doc.undo())
        XCTAssertEqual(try doc.revision(), r0 + 1)
        try doc.apply(setOp("r1", #"{"w": 12}"#))
        XCTAssertEqual(try doc.revision(), r0 + 2)
        XCTAssertEqual(try Document.load(try doc.save()).revision(), 1, "a loaded document starts at 1")
    }

    func testDocumentNodesAllOrById() throws {
        let doc = try plateDocument()
        let nodes = objects(try doc.nodes())
        XCTAssertEqual(nodes.map { $0["id"] as? String ?? "?" }, ["r1", "x1"])
        XCTAssertEqual(nodes.first?["kind"] as? String, "profile.rect")
        XCTAssertEqual(number(nodes.first?["w"]), 10)
        XCTAssertEqual(objects(try doc.nodes(["x1", "r1"])).map { $0["id"] as? String ?? "?" }, ["x1", "r1"], "in the order asked")
        XCTAssertTrue(refusal { _ = try doc.nodes(["ghost"]) }?.contains("ghost") ?? false)
    }

    func testDocumentInputsAndReadersDirectAndTransitive() throws {
        let doc = try holedDocument()
        try doc.apply(addOp(#"{"id": "m", "kind": "measure.mass", "solid": "cut"}"#))
        XCTAssertEqual(strings(try doc.inputs("cut")), ["box", "pin"])
        XCTAssertEqual(strings(try doc.inputs("m")), ["cut"])
        XCTAssertEqual(strings(try doc.inputs("m", transitive: true)), ["box", "pin", "cut"])
        XCTAssertEqual(strings(try doc.readers("box")), ["cut"])
        XCTAssertEqual(strings(try doc.readers("box", transitive: true)), ["cut", "m"])
        XCTAssertEqual(strings(try doc.inputs("box")), [])
        XCTAssertEqual(strings(try doc.readers("m")), [])
        XCTAssertTrue(refusal { _ = try doc.inputs("ghost") }?.contains("ghost") ?? false)
    }

    func testDocumentProbeReadsThroughResultsAndLeavesTheDocument() throws {
        let doc = try holedDocument()
        XCTAssertEqual(try doc.resultSolid("cut").faces, 7)
        let saved = try doc.save()
        let revision = try doc.revision()
        try doc.probe(setOp("pin", #"{"at": [50, 0, -15]}"#), ["cut"]) { statuses in
            let cut = objects(statuses).first { $0["id"] as? String == "cut" }
            XCTAssertEqual(cut?["state"] as? String, "ok", statuses)
            XCTAssertEqual(try doc.resultSolid("cut").faces, 6, "the probe's cut: the pin moved clear")
            XCTAssertTrue(refusal { try doc.apply(#"{"op": "remove", "id": "cut"}"#) }?.contains("a probe is open") ?? false)
        }
        XCTAssertEqual(try doc.resultSolid("cut").faces, 7, "the document's cut again")
        XCTAssertEqual(try doc.save(), saved)
        XCTAssertEqual(try doc.revision(), revision)
        // The probe ends on an error too, and the error is passed on.
        XCTAssertThrowsError(try doc.probe(setOp("pin", #"{"r": 1}"#), ["cut"]) { _ in throw Dropped() }) { error in
            XCTAssertTrue(error is Dropped, "\(error)")
        }
        try doc.apply(setOp("pin", #"{"r": 1}"#))   // not refused: no probe is open
        let ghost = refusal { try doc.probe(setOp("pin", #"{"r": 2}"#), ["ghost"]) { _ in } }
        XCTAssertTrue(ghost?.contains("no node `ghost`") ?? false, ghost ?? "nothing")
    }

    func testDocumentResultBeziersOfACurveNode() throws {
        let doc = try Document("mm")
        try doc.apply(addOp(#"{"id": "l", "kind": "curve.line", "x0": 0, "y0": 0, "x1": 10, "y1": 5}"#))
        try doc.apply(addOp(#"{"id": "s", "kind": "solid.cuboid", "x": 1, "y": 1, "z": 1}"#))
        let flat = try doc.resultBeziers("l")
        XCTAssertEqual(flat.count, 16)
        XCTAssertEqual(Array(flat.prefix(4)), [0, 0, 0, 1])
        XCTAssertEqual(Array(flat.suffix(4)), [10, 5, 0, 1])
        let up = try Frame(values: [0, 0, 10, 1, 0, 0, 0, 1, 0, 0, 0, 1])
        let lifted = try doc.resultBeziers("l", frame: up)
        XCTAssertEqual(Array(lifted.prefix(4)), [0, 0, 10, 1])
        XCTAssertEqual(Array(lifted.suffix(4)), [10, 5, 10, 1])
        XCTAssertTrue(refusal { _ = try doc.resultBeziers("s") }?.contains("is a solid") ?? false)
    }

    func testDocumentMetaIsPerAppUndoneAndSaved() throws {
        let doc = try plateDocument()
        XCTAssertNil(try doc.meta("forge"))
        let changed = object(try doc.apply(#"{"op": "meta", "app": "forge", "value": {"grid": 5}}"#))
        XCTAssertEqual(changed["meta"] as? [String], ["forge"])
        let forge = object(try doc.meta("forge") ?? "null")
        XCTAssertEqual(forge.count, 1)
        XCTAssertEqual(number(forge["grid"]), 5)
        XCTAssertNil(try doc.meta("other"))
        XCTAssertEqual(number(object(try Document.load(try doc.save()).meta("forge") ?? "null")["grid"]), 5)
        try doc.undo()
        XCTAssertNil(try doc.meta("forge"))
    }

    func testProfileFromPiecesRoundTripsItsPieces() throws {
        let pieces = #"[{"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0}, {"kind": "arc", "x0": 10, "y0": 0, "xm": 15, "ym": 5, "x1": 10, "y1": 10}, {"kind": "line", "x0": 10, "y0": 10, "x1": 0, "y1": 10}]"#
        let closed = try Profile.fromPieces(pieces, closed: true)
        let back = try closed.piecesJSON()
        XCTAssertEqual(objects(back).map { $0["xm"] != nil }, [false, true, false, false], "three pieces and the closing side")
        XCTAssertEqual(objects(try Profile.fromPieces(back).piecesJSON()).count, 4)
        XCTAssertTrue(refusal { _ = try Profile.fromPieces(#"[{"kind": "nope"}]"#) }?.contains("0") ?? false)
    }

    func testProfileBoundsAreTheCurvesOwnExtremes() throws {
        let c = try Profile.circle(5).bounds()
        XCTAssertEqual(c.minX, -5, accuracy: 1e-12)
        XCTAssertEqual(c.minY, -5, accuracy: 1e-12)
        XCTAssertEqual(c.maxX, 5, accuracy: 1e-12)
        XCTAssertEqual(c.maxY, 5, accuracy: 1e-12)
        let r = try Profile.rect(4, 2).bounds()
        XCTAssertEqual([r.minX, r.minY, r.maxX, r.maxY], [-2, -1, 2, 1])
    }

    func testProfileReversedTwiceIsTheProfile() throws {
        let open = try Profile.fromPieces(#"[{"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0}, {"kind": "line", "x0": 10, "y0": 0, "x1": 10, "y1": 5}]"#)
        let turned = try open.reversed()
        let first = objects(try turned.piecesJSON()).first ?? [:]
        XCTAssertEqual(number(first["x0"]), 10, accuracy: 1e-9)
        XCTAssertEqual(number(first["y0"]), 5, accuracy: 1e-9)
        func ends(_ p: Profile) throws -> [Double] {
            try objects(p.piecesJSON()).flatMap { q in ["x0", "y0", "x1", "y1"].map { (number(q[$0]) * 1e9).rounded() / 1e9 } }
        }
        XCTAssertEqual(try ends(try turned.reversed()), try ends(open))
    }

    func testProfileFilletCornerCutsBackToTheTangentPoints() throws {
        let a = try Profile.fromPieces(#"[{"kind": "line", "x0": 0, "y0": 0, "x1": 10, "y1": 0}]"#)
        let b = try Profile.fromPieces(#"[{"kind": "line", "x0": 10, "y0": 0, "x1": 10, "y1": 10}]"#)
        let got = object(try Profile.filletCorner(a, b, radius: 2))
        XCTAssertEqual(Set(got.keys), ["a", "b", "arc"])
        let cutA = (got["a"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
        let cutB = (got["b"] as? [Any] ?? []).compactMap { $0 as? JSONObject }
        XCTAssertEqual(number(cutA.last?["x1"]), 8, accuracy: 1e-9)
        XCTAssertEqual(number(cutB.first?["y0"]), 2, accuracy: 1e-9)
        let arc = got["arc"] as? JSONObject ?? [:]
        XCTAssertEqual(number(arc["x0"]), 8, accuracy: 1e-9)
        XCTAssertEqual(number(arc["y0"]), 0, accuracy: 1e-9)
        XCTAssertEqual(number(arc["x1"]), 10, accuracy: 1e-9)
        XCTAssertEqual(number(arc["y1"]), 2, accuracy: 1e-9)
        XCTAssertNotNil(refusal { _ = try Profile.filletCorner(a, b, radius: 50) })
    }
}
