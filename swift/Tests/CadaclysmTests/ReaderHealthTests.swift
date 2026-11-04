// The reader's health report and healing over the release library: Python's
// test_brep_health_* / test_brep_healed_* figures on st203-bapl.stp (skipped where the checkout
// does not have it), and the two distinct-rows decoder tests. @testable for the decoders.
@testable import Cadaclysm
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

/// st203-bapl.stp: SAMPLE_DIR when set, else the checkout root; skipped when missing.
private func st203() throws -> String {
    let env = ProcessInfo.processInfo.environment["SAMPLE_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    guard let dir = env.map({ URL(fileURLWithPath: $0) }) ?? root else { throw XCTSkip("no samples/cube.scad above \(#filePath)") }
    let path = dir.appendingPathComponent("st203-bapl.stp").path
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("\(path) not to hand") }
    return path
}

private func close(_ a: Double, _ b: Double, rel: Double) -> Bool {
    abs(a - b) <= rel * max(abs(a), abs(b))
}

/// The scene's breps, in node order; the scene closes (the breps outlive it).
private func st203Breps() throws -> [Brep] {
    let scene = try Cadaclysm.open(try st203())
    defer { scene.close() }
    return scene.nodes.compactMap { $0.brep }
}

final class ReaderHealthTests: XCTestCase {
    func testBrepHealthReportsTheFreeEdgesOfSt203Bapl() throws {
        let breps = try st203Breps()
        defer { breps.forEach { $0.release() } }
        let body = breps[1]   // the 188-free-edge body; body 0 takes minutes to diagnose
        XCTAssertEqual(try body.manifold.boundaryEdges, 188)
        let report = try body.health()
        XCTAssertEqual(report.freeEdges.count, 188)
        XCTAssertEqual(report.wires.count, 45)
        XCTAssertEqual(report.wires.map(\.count).reduce(0, +), 188)
        XCTAssertEqual(report.wireEdges(0), Array(report.freeEdges[0..<report.wires[0].count]))
        XCTAssertTrue(report.wireEdges(0).allSatisfy { $0.wire == 0 })
        XCTAssertNil(report.cracks)
        XCTAssertEqual(try body.health(tolerance: .nan).tolerance, report.tolerance)
        let trims = Set(report.freeEdges.map(\.trim))
        XCTAssertTrue(report.freeEdges.allSatisfy { $0.partner.map { trims.contains($0) } ?? false })
        let first = report.freeEdges[0]
        XCTAssertEqual(first.trim, 0)
        XCTAssertEqual(first.edge, 41363)
        XCTAssertEqual(first.face, 0)
        XCTAssertEqual(first.wire, 0)
        XCTAssertEqual(first.partner, 67)
        XCTAssertEqual(first.sharedEnds, 0)
        XCTAssertTrue(close(first.gap, 95.01496054, rel: 1e-6), "\(first.gap)")
        XCTAssertTrue(close(report.extent, 253.66439715552204, rel: 1e-12), "\(report.extent)")
        XCTAssertTrue(close(report.rounding, 1e-7 * report.extent, rel: 1e-12))
        XCTAssertTrue(close(report.tolerance, 1e-4 * report.extent, rel: 1e-12))
        XCTAssertEqual(report.looseEdges, 0)
        XCTAssertEqual(report.worstLoose, 0)
        let (sewn, sew) = try body.sewed()
        defer { sewn.release() }
        XCTAssertEqual(report.sewPairs, Int(sew.pairs))
        XCTAssertEqual(report.sewRefused, 4)
        XCTAssertEqual(report.sewRefused, Int(sew.refused))
        XCTAssertTrue(close(report.sewWorstGap, sew.worstGap, rel: 1e-12))
        XCTAssertGreaterThan(report.sewWorstGap, 0)
        let c = try XCTUnwrap(try body.health(mesh: true).cracks)
        XCTAssertEqual(c, Cracks(watertight: false, open: 0, folded: 0, crossings: 166, edges: []))
        let wide = try body.health(tolerance: 5)
        XCTAssertEqual(wide.small.count, 96)
        XCTAssertEqual(Set(wide.small.map(\.kind)), ["short_edge", "sliver_face", "tiny_face"])
        let edge = try XCTUnwrap(wide.small.first { $0.kind == "short_edge" })
        XCTAssertEqual(edge.index, 41550)
        XCTAssertTrue(close(edge.size, 3.1622776616321775, rel: 1e-9), "\(edge.size)")
    }

    func testBrepHealedHealsSt203BaplAndLeavesTheOriginal() throws {
        let breps = try st203Breps()
        defer { breps.forEach { $0.release() } }
        let body = breps[1]
        let (healed, report) = try body.healed(tolerance: 5)
        defer { healed.release() }
        XCTAssertNotEqual(healed.pointer, body.pointer)
        XCTAssertEqual(report.tolerance, 5)
        XCTAssertEqual(report.smallBefore, 96)
        XCTAssertEqual(report.fixes.count, 28)
        XCTAssertEqual(report.smallAfter, 8)
        XCTAssertEqual(report.freeBefore, 188)
        XCTAssertEqual(report.freeAfter, 88)
        XCTAssertEqual(report.refused.map { "\($0.kind)/\($0.why)" }, Array(repeating: "sliver_face/uneven", count: 8))
        XCTAssertFalse(report.closedBefore)
        XCTAssertFalse(report.closedAfter)
        XCTAssertEqual(report.nonmanifoldBefore, 0)
        XCTAssertEqual(report.nonmanifoldAfter, 0)
        XCTAssertTrue(close(report.moved, 1.581138831332503, rel: 1e-9), "\(report.moved)")
        XCTAssertTrue(close(report.fixes.map(\.moved).max() ?? 0, 1.8248105306211464, rel: 1e-9))
        XCTAssertEqual(try body.health(tolerance: 5).small.count, 96, "the input is left as it was")
        XCTAssertEqual(try body.edgeTolerance(41550), 0)
        XCTAssertNil(try healed.edgeTolerance(41550))
        XCTAssertEqual(try healed.edgeTolerance(41363), 0)
        XCTAssertNil(try body.edgeTolerance(0xFFFF_FFF0))
        // every kind switched off: nothing healed, every small feature refused as toggled
        let (offBody, off) = try body.healed(tolerance: 5, edges: false, faces: false, holes: false)
        offBody.release()
        XCTAssertTrue(off.fixes.isEmpty)
        XCTAssertEqual(off.refused.count, 96)
        XCTAssertEqual(off.freeAfter, off.freeBefore)
        XCTAssertTrue(off.refused.allSatisfy { $0.why == "toggled" && $0.figure == 0 })
        XCTAssertEqual(["short_edge", "sliver_face", "tiny_face"].map { k in off.refused.filter { $0.kind == k }.count },
                       [64, 26, 6])
        // a released brep raises as the other released calls do
        body.release()
        let calls: [() throws -> Void] = [{ _ = try body.healed() }, { _ = try body.health() }, { _ = try body.edgeTolerance(0) }]
        for call in calls {
            XCTAssertThrowsError(try call()) { error in
                XCTAssertEqual((error as? CadaclysmError)?.message, "brep: released")
            }
        }
    }

    func testTheHealthDecoderReadsEveryColumnOfDistinctRows() {
        let none: UInt32 = 0xFFFF_FFFF
        let r = HealthReport(
            counts: [2, 1, 1, 2, 1, 0, 0, 1, 0, 3, 4, 5, 1, 0, 11, 12, 13, 2],
            sizes: [0.5, 0.25, 9.0, 7.5, 6.5, 5.5, 4.5, 3.5],
            freeIds: [10, 20, 30, 40, 1, 2, 11, none, 31, 41, none, 0], freeSizes: [1.5, 2.5, 3.5, .infinity],
            wireRuns: [0, 2, 1], wireSizes: [8.5, 2.5], smallItems: [1, 77, 4, 99], smallSizes: [0.125, 0.0625],
            crackEdges: [5, 6])
        XCTAssertEqual([r.tolerance, r.rounding, r.extent, r.worstGap], [0.5, 0.25, 9.0, 7.5])
        XCTAssertEqual([r.looseEdges, r.sewPairs, r.sewRefused], [3, 4, 5])
        XCTAssertEqual([r.worstLoose, r.sewWorstGap], [6.5, 5.5])
        XCTAssertEqual(r.freeEdges, [
            FreeEdge(trim: 10, edge: 20, face: 30, wire: 40, partner: 1, sharedEnds: 2, length: 1.5, gap: 2.5),
            FreeEdge(trim: 11, edge: nil, face: 31, wire: 41, partner: nil, sharedEnds: 0, length: 3.5, gap: .infinity),
        ])
        XCTAssertEqual(r.wires, [FreeWire(first: 0, count: 2, closed: true, length: 8.5, widestGap: 2.5)])
        XCTAssertEqual(r.small, [SmallFeature(kind: "collapsed_edge", index: 77, size: 0.125),
                                 SmallFeature(kind: "tiny_body", index: 99, size: 0.0625)])
        XCTAssertEqual(r.cracks, Cracks(watertight: false, open: 11, folded: 12, crossings: 13, edges: [5, 6]))
        // counts[12] 0: not meshed, no cracks whatever the other counts say
        var counts: [UInt32] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 11, 12, 13, 0]
        XCTAssertNil(HealthReport(counts: counts, sizes: Array(repeating: 0, count: 8), freeIds: [], freeSizes: [],
                                  wireRuns: [], wireSizes: [], smallItems: [], smallSizes: [], crackEdges: []).cracks)
        counts[12] = 1
        XCTAssertEqual(HealthReport(counts: counts, sizes: Array(repeating: 0, count: 8), freeIds: [], freeSizes: [],
                                    wireRuns: [], wireSizes: [], smallItems: [], smallSizes: [], crackEdges: []).cracks,
                       Cracks(watertight: true, open: 11, folded: 12, crossings: 13, edges: []))
    }

    func testTheHealDecoderReadsEveryColumnOfDistinctRows() {
        let r = HealReport(counts: [2, 3, 1, 9, 8, 7, 6, 1, 0, 5, 4], sizes: [0.5, 0.25],
                           fixItems: [5, 11, 0, 12], fixSizes: [1.5, 0.125, 2.5, 0.0625],
                           refusedItems: [3, 21, 9, 4, 22, 3, 2, 23, 10], refusedSizes: [0.0, 7.5, 0.0])
        XCTAssertEqual(r.tolerance, 0.5)
        XCTAssertEqual(r.moved, 0.25)
        XCTAssertTrue(r.guarded)
        XCTAssertEqual([r.smallBefore, r.smallAfter, r.freeBefore, r.freeAfter], [9, 8, 7, 6])
        XCTAssertTrue(r.closedBefore)
        XCTAssertFalse(r.closedAfter)
        XCTAssertEqual([r.nonmanifoldBefore, r.nonmanifoldAfter], [5, 4])
        XCTAssertEqual(r.fixes, [HealFix(kind: "small_hole", index: 11, size: 1.5, moved: 0.125),
                                 HealFix(kind: "short_edge", index: 12, size: 2.5, moved: 0.0625)])
        XCTAssertEqual(r.refused, [HealRefusal(kind: "tiny_face", index: 21, why: "toggled", figure: 0),
                                   HealRefusal(kind: "tiny_body", index: 22, why: "chain", figure: 7.5),
                                   HealRefusal(kind: "sliver_face", index: 23, why: "unsupported", figure: 0)])
        XCTAssertEqual(healthKinds[5], "small_hole")
        XCTAssertEqual(healWhys.count, 11)
        XCTAssertEqual(healWhys[0], "would_empty_loop")
    }

    func testHealFlagsAreOneBitAKind() {
        XCTAssertEqual(healFlags(edges: true, faces: true, holes: true), 7)
        XCTAssertEqual(healFlags(edges: true, faces: false, holes: false), 1)
        XCTAssertEqual(healFlags(edges: false, faces: true, holes: false), 2)
        XCTAssertEqual(healFlags(edges: false, faces: false, holes: true), 4)
        XCTAssertEqual(healFlags(edges: false, faces: false, holes: false), 0)
    }
}
