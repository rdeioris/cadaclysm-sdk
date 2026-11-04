// The kernel's health report and healing over the release library: Python's test_health_* and
// test_healed_* figures, and the two distinct-rows decoder tests. @testable for the decoders.
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

private func close(_ a: Double, _ b: Double, rel: Double) -> Bool {
    abs(a - b) <= rel * max(abs(a), abs(b))
}

final class BlacksmithHealTests: XCTestCase {
    func testHealthOfAClosedCuboidHasNothingFreeAndCracksOnlyOnRequest() throws {
        let box = try Solid.cuboid(10, 10, 10)
        let report = try box.health()
        XCTAssertTrue(report.freeEdges.isEmpty)
        XCTAssertTrue(report.wires.isEmpty)
        XCTAssertTrue(report.small.isEmpty)
        XCTAssertNil(report.cracks)
        XCTAssertTrue(close(report.extent, 10 * 3.0.squareRoot(), rel: 1e-12), "\(report.extent)")
        XCTAssertTrue(close(report.rounding, 1e-7 * report.extent, rel: 1e-12))
        XCTAssertTrue(close(report.tolerance, 1e-4 * report.extent, rel: 1e-12))
        XCTAssertEqual([report.looseEdges, report.sewPairs, report.sewRefused], [0, 0, 0])
        XCTAssertEqual([report.worstLoose, report.sewWorstGap], [0, 0])
        let cracks = try XCTUnwrap(try box.health(mesh: true).cracks)
        XCTAssertEqual(cracks, Cracks(watertight: true, open: 0, folded: 0, crossings: 0, edges: []))
        XCTAssertEqual(try box.health(tolerance: 0.5).tolerance, 0.5)
        XCTAssertEqual(try box.health(tolerance: -1).tolerance, report.tolerance)
    }

    func testHealthOfACuboidWithoutAFaceIsOneOpenRimOfFourEdges() throws {
        let hole = try Solid.cuboid(10, 10, 10).dropFaces([0])
        let report = try hole.health()
        XCTAssertEqual(report.freeEdges.count, 4)
        XCTAssertEqual(report.wires.count, 1)
        let wire = report.wires[0]
        XCTAssertEqual(wire.first, 0)
        XCTAssertEqual(wire.count, 4)
        XCTAssertTrue(wire.closed)
        XCTAssertEqual(wire.length, 40, accuracy: 1e-9)
        XCTAssertEqual(report.wireEdges(0), report.freeEdges)
        XCTAssertEqual(report.freeEdges.map { [$0.trim, $0.edge ?? -1, $0.face, $0.partner ?? -1] },
                       [[4, 3, 1, 2], [16, 2, 4, 3], [11, 1, 2, 0], [15, 0, 3, 1]])
        for edge in report.freeEdges {
            XCTAssertEqual(edge.wire, 0)
            XCTAssertEqual(edge.sharedEnds, 0)
            XCTAssertEqual(edge.length, 10, accuracy: 1e-9)
            XCTAssertEqual(edge.gap, 10, accuracy: 1e-9)
        }
        XCTAssertEqual(report.worstGap, 10, accuracy: 1e-9)
        XCTAssertEqual([report.sewPairs, report.sewRefused, report.looseEdges], [0, 0, 0])
        let cracks = try XCTUnwrap(try hole.health(mesh: true).cracks)
        XCTAssertEqual(cracks, Cracks(watertight: false, open: 0, folded: 0, crossings: 0, edges: []))
    }

    func testHealthListsAThinPlatesSmallFeaturesByKindIndexAndSize() throws {
        let plate = try Solid.cuboid(10, 10, 0.001)
        let report = try plate.health(tolerance: 0.01)
        XCTAssertEqual(report.small.map { "\($0.kind) \($0.index)" },
                       [8, 9, 10, 11].map { "short_edge \($0)" } + [2, 3, 4, 5].map { "sliver_face \($0)" })
        for s in report.small.prefix(4) { XCTAssertTrue(close(s.size, 0.001, rel: 1e-6), "\(s.size)") }
        for s in report.small.dropFirst(4) { XCTAssertTrue(close(s.size, 0.0009999, rel: 1e-3), "\(s.size)") }
    }

    func testHealthReportsATinyBodyAndItsTinyFaces() throws {
        let tiny = try Solid.cuboid(0.0005, 0.0005, 0.0005)
        let report = try tiny.health(tolerance: 0.01)
        XCTAssertEqual(report.small.filter { $0.kind == "short_edge" }.count, 12)
        let faces = report.small.filter { $0.kind == "tiny_face" }
        XCTAssertEqual(faces.map(\.index), [0, 1, 2, 3, 4, 5])
        for f in faces { XCTAssertTrue(close(f.size, 2.5e-7, rel: 1e-6), "\(f.size)") }
        let bodies = report.small.filter { $0.kind == "tiny_body" }
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(bodies.first?.index, 0)
        XCTAssertTrue(close(bodies.first?.size ?? 0, 0.0005 * 3.0.squareRoot(), rel: 1e-9))
        XCTAssertEqual(report.small.count, 19)
    }

    func testHealedCuboidHealsToItselfAsANewSolid() throws {
        let box = try Solid.cuboid(10, 10, 10)
        let (healed, report) = try box.healed()
        XCTAssertFalse(healed === box)
        XCTAssertNotEqual(try healed.h(), try box.h())
        XCTAssertTrue(report.fixes.isEmpty)
        XCTAssertTrue(report.refused.isEmpty)
        XCTAssertFalse(report.guarded)
        XCTAssertEqual([report.smallBefore, report.smallAfter, report.freeBefore, report.freeAfter], [0, 0, 0, 0])
        XCTAssertTrue(report.closedBefore)
        XCTAssertTrue(report.closedAfter)
        XCTAssertEqual([report.nonmanifoldBefore, report.nonmanifoldAfter], [0, 0])
        XCTAssertTrue(close(report.tolerance, try box.health().tolerance, rel: 1e-12))
        XCTAssertEqual(report.moved, 0)
        XCTAssertEqual(try healed.faces, 6)
        let mass: Mass = try healed.mass()
        XCTAssertEqual(mass.volume, 1000, accuracy: 1e-6)
        XCTAssertEqual(try box.healed(tolerance: 0.5).1.tolerance, 0.5)
        XCTAssertEqual(try (0..<12).map { try healed.edgeTolerance($0) }, Array(repeating: 0.0, count: 12))
        XCTAssertNil(try healed.edgeTolerance(0xFFFF_FFF0))
    }

    func testHealedWithEveryKindOffRefusesEachSmallFeatureAsToggled() throws {
        let plate = try Solid.cuboid(10, 10, 0.001)
        let (_, report) = try plate.healed(tolerance: 0.01, edges: false, faces: false, holes: false)
        XCTAssertTrue(report.fixes.isEmpty)
        XCTAssertEqual(report.smallBefore, 8)
        XCTAssertEqual(report.smallAfter, 8)
        XCTAssertEqual(report.refused,
                       [8, 9, 10, 11].map { HealRefusal(kind: "short_edge", index: $0, why: "toggled", figure: 0) }
                           + [2, 3, 4, 5].map { HealRefusal(kind: "sliver_face", index: $0, why: "toggled", figure: 0) })
        let (_, on) = try plate.healed(tolerance: 0.01)
        XCTAssertEqual(on.smallBefore, 8)
        XCTAssertTrue(on.refused.allSatisfy { $0.why != "toggled" })
        XCTAssertTrue(!on.guarded || on.refused.allSatisfy { $0.why == "body_guard" })
    }

    func testHealthHealedAndEdgeToleranceOfAClosedSolidRaise() throws {
        let box = try Solid.cuboid(1, 1, 1)
        box.close()
        XCTAssertEqual(refusal { _ = try box.health() }, "solid: closed")
        XCTAssertEqual(refusal { _ = try box.healed() }, "solid: closed")
        XCTAssertEqual(refusal { _ = try box.edgeTolerance(0) }, "solid: closed")
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
    }

    func testHealFlagsAreOneBitAKind() {
        XCTAssertEqual(healFlags(edges: true, faces: true, holes: true), 7)
        XCTAssertEqual(healFlags(edges: true, faces: false, holes: false), 1)
        XCTAssertEqual(healFlags(edges: false, faces: true, holes: false), 2)
        XCTAssertEqual(healFlags(edges: false, faces: false, holes: true), 4)
        XCTAssertEqual(healFlags(edges: false, faces: false, holes: false), 0)
    }
}
