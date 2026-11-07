// The blacksmith document over the release library (document plan, 2026-11-06): Python's
// document tests (plate_document .. the bim tests) on the JSON-text shape. The document answers
// JSON text, read here with JSONSerialization -- the binding itself parses none of it.
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
private func array(_ text: String) -> [Any] { json(text) as? [Any] ?? [] }

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

private func assertPrefix(_ prefix: String, file: StaticString = #filePath, line: UInt = #line, _ body: () throws -> Void) {
    let said = refusal(body)
    XCTAssertTrue(said?.hasPrefix(prefix) ?? false, "said \(said ?? "nothing"), not \(prefix)...", file: file, line: line)
}

private func addOp(_ node: String) -> String { "{\"op\": \"add\", \"node\": \(node)}" }

private func setOp(_ id: String, _ fields: String) -> String {
    "{\"op\": \"set\", \"id\": \"\(id)\", \"fields\": \(fields)}"
}

private func added(_ changed: String) -> [String] { object(changed)["added"] as? [String] ?? [] }

/// Python's plate_document: a 10 x 10 rectangle `r1` and its 10 mm extrusion `x1`.
private func plateDocument() throws -> Document {
    let doc = try Document("mm")
    XCTAssertEqual(added(try doc.apply(addOp(#"{"id": "r1", "kind": "profile.rect", "w": 10, "h": 10}"#))), ["r1"])
    XCTAssertEqual(added(try doc.apply(addOp(
        #"{"id": "x1", "kind": "solid.extrude", "profile": "r1", "frame": "xy", "distance": 10}"#))), ["x1"])
    return doc
}

private func states(_ status: String) -> [String] { array(status).map { ($0 as? JSONObject)?["state"] as? String ?? "?" } }

private func volume(_ solid: Solid) throws -> Double {
    let mass: Mass = try solid.mass(1e-7)
    return mass.volume
}

private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1e-6 * max(1, abs(b)) }

private func branchList(_ doc: Document) throws -> JSONObject { object(try doc.branches()) }
private func canUndo(_ doc: Document) throws -> Bool { try branchList(doc)["can_undo"] as? Bool ?? false }
private func canRedo(_ doc: Document) throws -> Bool { try branchList(doc)["can_redo"] as? Bool ?? false }
private func branchNames(_ doc: Document) throws -> Set<String> {
    Set((try branchList(doc)["branches"] as? JSONObject ?? [:]).keys)
}

private func commits(_ text: String) -> [JSONObject] { array(text).compactMap { $0 as? JSONObject } }
private func ids(_ commits: [JSONObject]) -> [String] { commits.map { $0["id"] as? String ?? "?" } }
private func headId(_ doc: Document) throws -> String { ids(commits(try doc.log()))[0] }
private func firstOp(_ commit: JSONObject) -> JSONObject { (commit["ops"] as? [Any])?.first as? JSONObject ?? [:] }
private func names(_ kinds: String) -> Set<String> { Set(array(kinds).compactMap { ($0 as? JSONObject)?["name"] as? String }) }

private func temporaryFile(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("cadaclysm-swift-\(UUID())-\(name)")
}

private struct Cancelled: Error, Equatable { let why: String }

final class DocumentTests: XCTestCase {
    // 1. evaluate and results
    func testEvaluateAndResults() throws {
        let doc = try plateDocument()
        XCTAssertEqual(states(try doc.evaluate()), ["ok", "ok"])
        XCTAssertTrue(array(try doc.errors()).isEmpty)
        let solid = try doc.resultSolid("x1")
        XCTAssertEqual(try solid.faces, 6)
        XCTAssertEqual(try doc.resultKind("r1"), "profile")
        _ = try doc.resultProfile("r1")
        XCTAssertEqual(try doc.resultKind("nope"), "none")
        assertPrefix("document_value: ") { _ = try doc.value("nope") }
        try doc.apply(setOp("x1", #"{"distance": 20}"#))
        XCTAssertEqual(try solid.faces, 6)
        XCTAssertTrue(near(try volume(solid), 1000), "the old result changed with the edit")
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 2000))
    }

    // 2. save, load, open, refusals
    func testSaveLoadOpenAndRefusals() throws {
        let doc = try plateDocument()
        let first = try doc.save()
        let loaded = try Document.load(first)
        XCTAssertEqual(try loaded.save(), first)
        XCTAssertEqual(states(try loaded.evaluate()), ["ok", "ok"])
        XCTAssertEqual(try loaded.resultSolid("x1").faces, 6)
        let file = temporaryFile("plate.json")
        defer { try? FileManager.default.removeItem(at: file) }
        try first.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Document.open(file.path).save(), first)
        assertPrefix("document_load: ") { _ = try Document.load("not a document") }
        assertPrefix("document_new: ") { _ = try Document("furlongs") }
    }

    // 3. undo and redo (Python's test_document_undo_takes_the_node_away_and_redo_puts_it_back)
    func testUndoTakesTheNodeAwayAndRedoPutsItBack() throws {
        let doc = try plateDocument()
        XCTAssertTrue(try canUndo(doc))
        XCTAssertFalse(try canRedo(doc))
        XCTAssertTrue(try doc.undo())
        XCTAssertEqual(try doc.resultKind("x1"), "none")
        XCTAssertNotEqual(try doc.resultKind("r1"), "none")
        XCTAssertTrue(try canRedo(doc))
        XCTAssertTrue(try doc.redo())
        XCTAssertNotEqual(try doc.resultKind("x1"), "none")
        XCTAssertFalse(try doc.redo())
        XCTAssertFalse(try canRedo(doc))
        XCTAssertTrue(try doc.undo())
        XCTAssertTrue(try doc.undo())
        XCTAssertFalse(try canUndo(doc))
        XCTAssertFalse(try doc.undo())
        XCTAssertTrue(array(try doc.evaluate()).isEmpty)
        XCTAssertTrue(try canRedo(doc))
    }

    // 4. a refusal leaves the document unchanged
    func testRefusalLeavesTheDocumentUnchanged() throws {
        let doc = try plateDocument()
        let before = try doc.save()
        let log = try doc.log()
        XCTAssertEqual(refusal { try doc.apply(#"{"op": "remove", "id": "r1"}"#) }, "document_apply: r1 is read by x1")
        XCTAssertEqual(try doc.save(), before)
        XCTAssertEqual(try doc.log(), log)
        assertPrefix("document_apply: ") { try doc.apply(addOp(#"{"kind": "no.such.kind"}"#)) }
        try doc.apply(#"{"op": "remove", "id": "r1", "cascade": true}"#)
        XCTAssertEqual(try doc.resultKind("r1"), "none")
        XCTAssertEqual(try doc.resultKind("x1"), "none")
        XCTAssertEqual(commits(try doc.log()).count, commits(log).count + 1, "the cascade was not one commit")
        assertPrefix("document_apply: ") { try doc.apply("{not json") }
    }

    // 5. values, lists and kinds
    func testValuesListsAndKinds() throws {
        let plate = try plateDocument()
        try plate.apply(addOp(#"{"id": "m", "kind": "measure.mass", "solid": "x1"}"#))
        XCTAssertEqual(object(try plate.value("m"))["volume"] as? Double ?? 0, 1000, accuracy: 1e-6)

        let doc = try Document()
        try doc.apply(addOp(#"{"id": "w", "kind": "value", "value": "=range(10, 40, 10)"}"#))
        try doc.apply(addOp(#"{"id": "c", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1}"#))
        try doc.apply(addOp(#"{"id": "x", "kind": "solid.cuboid", "x": "=w", "y": "=[1, 2]", "z": 1, "lacing": "cross"}"#))
        XCTAssertEqual(json(try doc.value("w")) as? [Double], [10, 20, 30])
        XCTAssertEqual(try doc.resultKind("c"), "list")
        let n = array(try doc.value("c")).count
        XCTAssertEqual(n, 3, "longest: the depths' last item repeats")
        let want: [Double] = [10, 40, 60]
        for i in 0..<n { XCTAssertTrue(near(try volume(try doc.resultSolid("c#\(i)")), want[i]), "c#\(i)") }
        XCTAssertEqual(try doc.resultKind("c#1"), "solid")
        let cross: [Double] = [10, 20, 30, 20, 40, 60]
        let m = array(try doc.value("x")).count
        XCTAssertEqual(m, 6)
        for i in 0..<m { XCTAssertTrue(near(try volume(try doc.resultSolid("x#\(i)")), cross[i]), "x#\(i)") }
        let text = try doc.save()
        XCTAssertEqual(try Document.load(text).save(), text)

        let rows = array(try Document.kinds())
        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertTrue(names(try Document.kinds()).isSuperset(of: ["profile.rect", "solid.extrude", "measure.mass"]))

        let bad = try Document()
        try bad.apply(#"{"op": "param", "name": "k", "value": -5}"#)
        try bad.apply(addOp(#"{"id": "bad", "kind": "profile.rect", "w": "=k", "h": 1}"#))
        let errors = array(try bad.errors())
        XCTAssertEqual(errors.count, 1)
        let e = errors.first as? JSONObject ?? [:]
        XCTAssertEqual(e["id"] as? String, "bad")
        XCTAssertEqual(e["state"] as? String, "error")
        XCTAssertFalse((e["message"] as? String ?? "").isEmpty)
        XCTAssertEqual((array(try bad.evaluate(cheapOnly: true)).first as? JSONObject)?["id"] as? String, "bad")
    }

    // 6. params
    func testParams() throws {
        let doc = try Document()
        XCTAssertTrue(object(try doc.params()).isEmpty)
        try doc.apply(#"{"op": "param", "name": "w", "value": 200}"#)
        let params = object(try doc.params())
        XCTAssertEqual(params.count, 1)
        XCTAssertEqual(params["w"] as? Double, 200)
        try doc.apply(addOp(#"{"id": "rect", "kind": "profile.rect", "w": "=w", "h": 100}"#))
        try doc.apply(addOp(#"{"id": "ext", "kind": "solid.extrude", "profile": "rect", "frame": "xy", "distance": 10}"#))
        XCTAssertTrue(near(try volume(try doc.resultSolid("ext")), 200 * 100 * 10))
        try doc.apply(#"{"op": "param", "name": "w", "value": 300}"#)
        XCTAssertTrue(near(try volume(try doc.resultSolid("ext")), 300 * 100 * 10))
        let op = firstOp(commits(try doc.log())[0])
        XCTAssertEqual(op.count, 3)
        XCTAssertEqual(op["op"] as? String, "param")
        XCTAssertEqual(op["name"] as? String, "w")
        XCTAssertEqual(op["value"] as? Double, 300)
        let before = try doc.save()
        assertPrefix("document_apply: ") { try doc.apply(#"{"op": "param", "name": "w", "value": null}"#) }
        XCTAssertEqual(try doc.save(), before)
        XCTAssertEqual(object(try doc.params())["w"] as? Double, 300)
    }

    // 7. branches and the log (Python's test_document_branches_and_the_log)
    func testBranchesAndTheLog() throws {
        let doc = try plateDocument()
        var list = try branchList(doc)
        XCTAssertEqual(list["branch"] as? String, "main")
        XCTAssertEqual(list["branches"] as? [String: String], ["main": try headId(doc)])
        try doc.branchNew("idea")
        list = try branchList(doc)
        let branches = list["branches"] as? [String: String] ?? [:]
        XCTAssertEqual(list["branch"] as? String, "idea")
        XCTAssertEqual(Set(branches.keys), ["main", "idea"])
        XCTAssertEqual(branches["idea"], branches["main"])
        XCTAssertEqual(ids(commits(try doc.log("main"))), ids(commits(try doc.log())))
        try doc.switchTo("main")
        try doc.branchRename("idea", "plan")
        XCTAssertEqual(try branchNames(doc), ["main", "plan"])
        try doc.branchDelete("plan")
        XCTAssertEqual(try branchNames(doc), ["main"])
        assertPrefix("document_branch_delete: ") { try doc.branchDelete("plan") }
        assertPrefix("document_branch_delete: ") { try doc.branchDelete("main") }
        assertPrefix("document_branch_rename: ") { try doc.branchRename("plan", "x") }
        assertPrefix("document_log: ") { _ = try doc.log("plan") }
        assertPrefix("document_branch_switch: ") { try doc.switchTo("nowhere") }
        XCTAssertTrue(array(try doc.tips()).isEmpty)
        let root = ids(commits(try doc.log())).last!
        try doc.branchNew("early", at: root)
        list = try branchList(doc)
        XCTAssertEqual((list["branches"] as? [String: String])?["early"], root)
        XCTAssertEqual(list["branch"] as? String, "main", "branch_new at a commit switched")
    }

    // test_document_log_order_and_messages
    func testLogOrderAndMessages() throws {
        let doc = try Document()
        try doc.apply(addOp(#"{"id": "r1", "kind": "profile.rect", "w": 1, "h": 1}"#), message: "first")
        try doc.apply(addOp(#"{"id": "r2", "kind": "profile.rect", "w": 2, "h": 2}"#))
        try doc.apply(addOp(#"{"id": "r3", "kind": "profile.rect", "w": 3, "h": 3}"#), message: "third")
        let log = commits(try doc.log())
        XCTAssertEqual(log.map { $0["message"] as? String }, ["third", nil, "first", nil])
        XCTAssertEqual((0..<3).map { (firstOp(log[$0])["node"] as? JSONObject)?["id"] as? String }, ["r3", "r2", "r1"])
        XCTAssertEqual(log[0]["id"] as? String, try headId(doc))
        XCTAssertEqual(log[0]["parents"] as? [String], [log[1]["id"] as? String ?? "?"])
        XCTAssertEqual(log[3]["parents"] as? [String], [])
    }

    // test_document_switch_by_name_and_by_commit_id
    func testSwitchByNameAndByCommitId() throws {
        let doc = try plateDocument()
        let first = ids(commits(try doc.log()))[1]
        try doc.branchNew("side")
        try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#))
        XCTAssertEqual(try branchList(doc)["branch"] as? String, "side")
        XCTAssertNotEqual(try doc.resultKind("c1"), "none")
        try doc.switchTo("main")
        XCTAssertEqual(try branchList(doc)["branch"] as? String, "main")
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        XCTAssertNotEqual(try doc.resultKind("x1"), "none")
        try doc.switchTo("side")
        XCTAssertNotEqual(try doc.resultKind("c1"), "none")
        try doc.switchTo(first)
        let list = try branchList(doc)
        XCTAssertTrue(list["branch"] is NSNull, "a commit id did not detach: \(list)")
        XCTAssertEqual(try headId(doc), first)
        XCTAssertNotEqual(try doc.resultKind("r1"), "none")
        XCTAssertEqual(try doc.resultKind("x1"), "none")
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        XCTAssertNotEqual((list["branches"] as? [String: String])?["main"], first)
        XCTAssertFalse(try canRedo(doc))
        try doc.switchTo("main")
        XCTAssertEqual(try branchList(doc)["branch"] as? String, "main")
        XCTAssertNotEqual(try doc.resultKind("x1"), "none")
    }

    // test_document_tips_after_undo_and_an_edit
    func testTipsAfterUndoAndAnEdit() throws {
        let doc = try plateDocument()
        XCTAssertTrue(array(try doc.tips()).isEmpty)
        let old = commits(try doc.log())[0]
        let oldId = old["id"] as? String ?? "?"
        XCTAssertTrue(try doc.undo())
        try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#), message: "other way")
        let tips = commits(try doc.tips())
        XCTAssertEqual(ids(tips), [oldId])
        XCTAssertEqual((firstOp(tips[0])["node"] as? JSONObject)?["id"] as? String, "x1", "a tip is a whole commit")
        XCTAssertEqual(tips[0]["parents"] as? [String], [ids(commits(try doc.log()))[1]])
        XCTAssertEqual(tips[0]["parents"] as? [String], old["parents"] as? [String])
        let head = commits(try doc.log())[0]
        XCTAssertEqual(head["message"] as? String, "other way")
        XCTAssertFalse(ids(tips).contains(head["id"] as? String ?? "?"))
        try doc.switchTo(oldId)
        XCTAssertNotEqual(try doc.resultKind("x1"), "none")
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        try doc.switchTo("main")
        try doc.branchNew("kept", at: oldId)
        XCTAssertTrue(array(try doc.tips()).isEmpty, "naming the line left it a tip")
    }

    // 8. batch and preview (Python's test_document_batch_is_one_commit,
    // test_document_batch_rolls_back_on_an_exception, test_document_preview_is_applied_and_reverted)
    func testBatchIsOneCommit() throws {
        let doc = try plateDocument()
        let before = commits(try doc.log()).count
        try doc.batch(message: "slot and fillet") {
            try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#))
            try doc.apply(addOp(#"{"id": "c2", "kind": "profile.circle", "r": 3}"#))
            XCTAssertNotEqual(try doc.resultKind("c2"), "none", "the ops are not live inside the batch")
        }
        let log = commits(try doc.log())
        XCTAssertEqual(log.count, before + 1)
        XCTAssertEqual(log[0]["message"] as? String, "slot and fillet")
        XCTAssertEqual((log[0]["ops"] as? [Any])?.count, 2)
        XCTAssertTrue(try doc.undo())
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        XCTAssertEqual(try doc.resultKind("c2"), "none")
        try doc.batch {}
        XCTAssertEqual(commits(try doc.log()).count, before, "an empty batch recorded something")
        XCTAssertEqual(try doc.batch { 42 }, 42, "the body's result")
    }

    func testBatchRollsBackOnAnError() throws {
        let doc = try plateDocument()
        let before = try doc.save()
        let log = try doc.log()
        XCTAssertThrowsError(try doc.batch(message: "never") {
            try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#))
            try doc.apply(setOp("r1", #"{"w": 20}"#))
            throw Cancelled(why: "never")
        }) { XCTAssertEqual($0 as? Cancelled, Cancelled(why: "never")) }
        XCTAssertEqual(try doc.save(), before)
        XCTAssertEqual(try doc.log(), log)
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 1000))
        assertPrefix("document_apply: ") {
            try doc.batch {
                try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#))
                try doc.apply(#"{"op": "remove", "id": "r1"}"#)
            }
        }
        XCTAssertEqual(try doc.save(), before, "the refused batch was not rolled back")
        try doc.batch(message: "again") { try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#)) }
        XCTAssertEqual(commits(try doc.log())[0]["message"] as? String, "again")
        // the clean-up is refused (the document is gone): the body's own error still wins
        XCTAssertThrowsError(try doc.batch {
            doc.close()
            throw Cancelled(why: "body")
        }) { XCTAssertEqual($0 as? Cancelled, Cancelled(why: "body"), "a refused clean-up replaced the body's error") }

        let nested = try plateDocument()
        try nested.batch { assertPrefix("document_batch_begin: ") { try nested.batch {} } }
    }

    func testPreviewIsAppliedAndReverted() throws {
        let doc = try plateDocument()
        let before = try doc.save()
        let log = try doc.log()
        try doc.preview {
            try doc.apply(setOp("r1", #"{"w": 30}"#))
            try doc.apply(addOp(#"{"id": "c1", "kind": "profile.circle", "r": 2}"#))
            XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 30 * 10 * 10))
            XCTAssertNotEqual(try doc.resultKind("c1"), "none")
        }
        XCTAssertEqual(try doc.save(), before)
        XCTAssertEqual(try doc.log(), log)
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 1000), "the preview was not taken back")
        XCTAssertEqual(try doc.resultKind("c1"), "none")
        XCTAssertThrowsError(try doc.preview {
            try doc.apply(setOp("r1", #"{"w": 40}"#))
            throw Cancelled(why: "drag cancelled")
        }) { XCTAssertEqual($0 as? Cancelled, Cancelled(why: "drag cancelled")) }
        XCTAssertEqual(try doc.save(), before)
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 1000))
        XCTAssertTrue(try canUndo(doc))
        XCTAssertThrowsError(try doc.preview {
            doc.close()
            throw Cancelled(why: "gone")
        }) { XCTAssertEqual($0 as? Cancelled, Cancelled(why: "gone"), "a refused clean-up replaced the body's error") }

        let nested = try plateDocument()
        try nested.preview { assertPrefix("document_preview_begin: ") { try nested.preview {} } }
    }

    // the editor's drag: frames replace each other, endPreview takes the drag back
    func testPreviewFramesReplaceEachOther() throws {
        let doc = try plateDocument()
        let before = try doc.save()
        let log = try doc.log()
        try doc.previewFrame(setOp("r1", #"{"w": 30}"#))
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 3000))
        try doc.previewFrame(setOp("r1", #"{"w": 40}"#))
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 4000), "frames stack")
        try doc.endPreview()
        XCTAssertTrue(near(try volume(try doc.resultSolid("x1")), 1000))
        XCTAssertEqual(try doc.save(), before)
        XCTAssertEqual(try doc.log(), log)
    }

    // 9. result types (Python's test_document_result_types)
    func testResultTypes() throws {
        let doc = try Document()
        try doc.apply(addOp(#"{"id": "r", "kind": "profile.rect", "w": 40, "h": 30}"#))
        try doc.apply(addOp(#"{"id": "c", "kind": "profile.circle", "r": 5}"#))
        try doc.apply(addOp(#"{"id": "m", "kind": "profile.translate", "profile": "c", "by": [20, 0]}"#))
        try doc.apply(addOp(#"{"id": "pieces", "kind": "profile.pieces", "profile": "r", "cutters": ["m"]}"#))
        try doc.apply(addOp(#"{"id": "k", "kind": "curve.nurbs", "points": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]}"#))
        try doc.apply(addOp(#"{"id": "cage", "kind": "subd.cuboid", "size": [20, 10, 5], "segments": [2, 1, 1]}"#))
        try doc.apply(addOp(#"{"id": "e", "kind": "solid.extrude", "profile": "r", "frame": "xy", "distance": 2}"#))
        try doc.apply(addOp(#"{"id": "mass", "kind": "measure.mass", "solid": "e"}"#))
        XCTAssertEqual(states(try doc.evaluate()).filter { $0 == "ok" }.count, 8)
        XCTAssertEqual(try doc.resultKind("r"), "profile")
        XCTAssertEqual(try doc.resultKind("pieces"), "profiles")
        XCTAssertGreaterThanOrEqual(try doc.resultProfiles("pieces").count, 2)
        XCTAssertEqual(try doc.resultKind("k"), "nurbs")
        XCTAssertEqual(try doc.resultNurbsCurve("k").degree, 3)
        XCTAssertEqual(try doc.resultKind("cage"), "subd")
        let want = try Subd.cuboid(size: SIMD3(20, 10, 5), segments: (2, 1, 1))
        XCTAssertEqual(try doc.resultSubd("cage").faces.count, try want.faces.count)
        try doc.apply(addOp(#"{"id": "outline", "kind": "curve.polyline", "points": [[0, 0], [10, 0], [10, 5], [3, 9]], "closed": true}"#))
        XCTAssertEqual(try doc.resultKind("outline"), "curve")
        let outline = object(try doc.value("outline"))
        XCTAssertEqual(outline.count, 2)
        XCTAssertEqual(outline["type"] as? String, "curve")
        XCTAssertEqual(outline["closed"] as? Bool, true)
        XCTAssertEqual(try doc.resultKind("mass"), "value")
        XCTAssertTrue(json(try doc.value("mass")) is JSONObject)
        XCTAssertEqual(try doc.resultKind("missing"), "none")
        assertPrefix("document_result_profile_count: ") { _ = try doc.resultProfiles("e") }
        assertPrefix("document_result_nurbs_curve: ") { _ = try doc.resultNurbsCurve("cage") }
        assertPrefix("document_result_subd: ") { _ = try doc.resultSubd("k") }
    }

    // 10. held geometry (Python's test_document_holds_a_solid_and_a_profile_the_caller_already_has)
    func testHoldsASolidAndAProfileTheCallerAlreadyHas() throws {
        let cutter = try Solid.cylinder(5, 60).translate(0, 0, -20)
        let part = try Solid.cuboid(40, 30, 20).cut(cutter)
        let slot = try Profile.slot(SIMD2(0, 0), 30, 5).withHole(try Profile.circle(2))
        let doc = try Document()
        let held = try doc.addSolid(part)
        let outline = try doc.addProfile(slot)
        try doc.apply(addOp("{\"id\": \"x\", \"kind\": \"solid.extrude\", \"profile\": \"\(outline)\", \"distance\": 4}"))
        try doc.apply(addOp("{\"id\": \"c\", \"kind\": \"solid.cut\", \"target\": \"\(held)\", \"tool\": \"x\"}"))
        XCTAssertEqual(try doc.errors().filter { !$0.isWhitespace }, "[]")
        XCTAssertEqual(try doc.resultKind(held), "solid")
        XCTAssertEqual(try doc.resultSolid(held).documentBody(), try part.documentBody())
        XCTAssertEqual(try volume(try doc.resultSolid(held)), try volume(part), "not the part's volume to the bit")
        let path = try slot.documentPath()
        let p = object(path)
        XCTAssertEqual((p["segments"] as? [Any] ?? []).filter { ($0 as? JSONObject)?["type"] as? String == "arc" }.count, 2)
        XCTAssertEqual((p["holes"] as? [Any])?.count, 1)
        XCTAssertEqual(try doc.resultProfile(outline).documentPath(), path)
        let want = try volume(try Solid.extrude(slot, try Frame.xy(), 4))
        XCTAssertEqual(try volume(try doc.resultSolid("x")), want, accuracy: 1e-9 * want)
        XCTAssertLessThan(try volume(try doc.resultSolid("c")), try volume(part))
        let text = try doc.save()
        let back = try Document.load(text)
        XCTAssertEqual(try back.save(), text)
        XCTAssertEqual(try back.resultSolid(held).faces, try part.faces)
        let face = try Solid.face(try Profile.rect(10, 10), try Frame.xy())
        let sheet = try doc.addSolid(face, sheet: true)
        XCTAssertTrue(try doc.save().contains("sheet.body"))
        XCTAssertEqual(try doc.resultKind(sheet), "sheet")
        XCTAssertEqual(try doc.resultSolid(sheet).faces, 1)
        let said = refusal { try doc.apply(addOp(#"{"kind": "solid.body", "body": "not a body"}"#)) }
        XCTAssertTrue(said?.contains("must be a body") ?? false, said ?? "nothing")
    }

    // test_document_keeps_held_colours_through_save_and_load
    func testKeepsHeldColoursThroughSaveAndLoad() throws {
        let red = SIMD3<Double>(1, 0, 0), green = SIMD3<Double>(0, 0.5, 0), blue = SIMD3<Double>(0, 0, 1)
        let yellow = SIMD3<Double>(1, 1, 0), grey = SIMD3<Double>(0.25, 0.5, 0.75)
        let part = try Solid.cuboid(1, 1, 1).coloured(red).coloured(green, face: 2)
            .edgesColoured(blue).edgesColoured(yellow, edges: [3])
        let slot = try Profile.slot(SIMD2(0, 0), 30, 5).coloured(grey)
        let doc = try Document()
        let held = try doc.addSolid(part)
        let outline = try doc.addProfile(slot)
        let plain = try doc.addProfile(try Profile.rect(2, 1))
        let back = try Document.load(try doc.save())
        let got = try back.resultSolid(held)
        XCTAssertEqual(try got.colour, red)
        XCTAssertEqual(try got.faceColour(2), green)
        XCTAssertEqual(try got.faceColour(0), red)
        XCTAssertEqual(try got.edgeColour(3), yellow)
        XCTAssertEqual(try got.edgeColour(0), blue)
        XCTAssertEqual(try got.documentBody(), try part.documentBody())
        XCTAssertEqual(try back.resultProfile(outline).colour, grey)
        XCTAssertNil(try back.resultProfile(plain).colour)
        var bare = object(try part.documentBody())
        for k in ["colour", "face_colours", "edges_colour", "edge_colours"] { bare.removeValue(forKey: k) }
        let bareText = String(decoding: try JSONSerialization.data(withJSONObject: bare), as: UTF8.self)
        let id = added(try back.apply(addOp("{\"kind\": \"solid.body\", \"body\": \(bareText)}")))[0]
        XCTAssertNil(try back.resultSolid(id).colour, "a body written without colours is coloured")
    }

    // 11. building documents (Python's four bim tests)
    private func bimWallDocument() throws -> Document {
        let doc = try Document.newBim("mm")
        try doc.apply("""
            {"op": "batch", "ops": [
            {"op": "add", "node": {"id": "l0", "kind": "bim.level", "name": "Ground"}},
            {"op": "add", "node": {"id": "part", "kind": "bim.wall_type", "name": "Partition",
             "layers": [{"material": "block", "thickness": 100, "function": "structure"}]}},
            {"op": "add", "node": {"id": "w1", "kind": "bim.wall", "level": "l0", "type": "part",
             "a": [0, 0], "b": [4000, 0]}}]}
            """)
        return doc
    }

    private func projectGuid(_ doc: Document) throws -> String {
        let nodes = object(try doc.save())["nodes"] as? [Any] ?? []
        let project = nodes.compactMap { $0 as? JSONObject }.first { $0["kind"] as? String == "bim.project" }
        return project?["guid"] as? String ?? ""
    }

    private func refusalNode(_ said: String) -> Any? {
        let prefix = "bim_document_export_ifc: "
        XCTAssertTrue(said.hasPrefix(prefix), said)
        let refusals = object(String(said.dropFirst(prefix.count)))["refusals"] as? [Any] ?? []
        return (refusals.first as? JSONObject)?["node"]
    }

    func testBimExportsIfcAndRefuses() throws {
        let ifc2x3 = #"{"schema": "IFC2X3", "timestamp": 0}"#
        let doc = try bimWallDocument()
        let text = try doc.exportIfc(ifc2x3)
        XCTAssertTrue(text.contains("IFCWALLSTANDARDCASE("))
        let saved = temporaryFile("wall.json")
        defer { try? FileManager.default.removeItem(at: saved) }
        try doc.save().write(to: saved, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Document.openBim(saved.path).exportIfc(ifc2x3), text)
        XCTAssertEqual(try Document.loadBim(try doc.save()).exportIfc(ifc2x3), text)
        let exact = try doc.exportIfc(#"{"geometry": "exact", "timestamp": 0, "name": "Wall"}"#)
        XCTAssertTrue(exact.contains("IFCPROJECT(") && exact.contains("'Wall'"))
        XCTAssertNotEqual(exact, text)
        try doc.apply(addOp(#"{"id": "d900", "kind": "bim.door_type", "width": 900, "height": 2100}"#))
        try doc.apply(addOp(#"{"id": "o1", "kind": "bim.door", "host": "w1", "type": "d900", "joins": [], "offset": 3900}"#))
        let said = refusal { _ = try doc.exportIfc(#"{"timestamp": 0}"#) } ?? ""
        XCTAssertEqual(refusalNode(said) as? String, "o1", said)
        let ifc5 = refusal { _ = try doc.exportIfc(#"{"schema": "IFC5"}"#) } ?? ""
        XCTAssertTrue(ifc5.contains("IFC4 or IFC2X3"), ifc5)

        let plain = try Document()
        let refused = refusal { _ = try plain.exportIfc() } ?? ""
        XCTAssertTrue(refused.contains("not a BIM document"), refused)
        XCTAssertTrue(refusalNode(refused) is NSNull, refused)
    }

    func testBimKindsAndProjectGuids() throws {
        XCTAssertTrue(names(try Document.bimKinds()).isSuperset(of: ["bim.project", "bim.wall", "solid.extrude"]))
        let a = try projectGuid(try Document.newBim())
        let b = try projectGuid(try Document.newBim())
        XCTAssertEqual(a.count, 36)
        XCTAssertEqual(a.count == 36 ? Array(a)[14] : nil, "4", "not a v4 uuid: \(a)")
        XCTAssertNotEqual(a, b)
    }

    // 12. lifetime
    func testResultsOutliveTheDocumentAndAClosedOneRefuses() throws {
        let doc = try plateDocument()
        try doc.apply(addOp(#"{"id": "k", "kind": "curve.nurbs", "points": [[0, 0, 0], [10, 5, 0], [20, -5, 0], [30, 0, 0]]}"#))
        try doc.apply(addOp(#"{"id": "cage", "kind": "subd.cuboid", "size": [20, 10, 5], "segments": [2, 1, 1]}"#))
        let solid = try doc.resultSolid("x1")
        let profile = try doc.resultProfile("r1")
        let curve = try doc.resultNurbsCurve("k")
        let cage = try doc.resultSubd("cage")
        doc.close()
        XCTAssertTrue(doc.isClosed)
        XCTAssertEqual(doc.description, "Document(closed)")
        XCTAssertEqual(try solid.faces, 6)
        XCTAssertTrue(near(try volume(solid), 1000))
        XCTAssertTrue(try profile.documentPath().contains("segments"))
        XCTAssertEqual(curve.degree, 3)
        XCTAssertGreaterThan(try cage.faces.count, 0)
        XCTAssertEqual(refusal { _ = try doc.save() }, "document: closed")
        XCTAssertEqual(refusal { try doc.apply("{}") }, "document: closed")
        doc.close() // twice is fine
    }
}
