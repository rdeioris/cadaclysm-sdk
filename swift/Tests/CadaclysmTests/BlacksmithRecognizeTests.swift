// The kernel's canonical recognition over the release library: Python's test_recognize_* figures
// and the distinct-rows decoder test. @testable for the decoder.
@testable import Blacksmith
import Foundation
import XCTest

final class BlacksmithRecognizeTests: XCTestCase {
    /// Python's test_the_recognize_decoder_reads_every_column_of_distinct_rows, row for row: every
    /// figure different, so a swapped column cannot read back.
    func testRecognizeDecoderReadsEveryColumnOfDistinctRows() {
        let r = RecognizeReport(counts: [1, 2, 3, 4, 5, 6, 7, 8, 9, 11], sizes: [0.5, 0.25, 0.125],
                                faceItems: [10, 4, 12, 0], faceSizes: [1.5, 2.5],
                                refusedItems: [20, 0, 21, 3], refusedSizes: [7.5, .nan],
                                edgeItems: [30, 2, 31, 1, 32, 0], edgeSizes: [0.75, 0.0625, 0.03125])
        XCTAssertEqual(r.tolerance, 0.5)
        XCTAssertEqual(r.worstFace, 0.25)
        XCTAssertEqual(r.worstEdge, 0.125)
        XCTAssertEqual(r.edgesLeft, 11)
        XCTAssertEqual(r.faces, [RecognizedFace(face: 10, kind: "torus", deviation: 1.5),
                                 RecognizedFace(face: 12, kind: "plane", deviation: 2.5)])
        XCTAssertEqual(r.refused, [RecognizeRefusal(face: 20, why: "no_kind", closest: 7.5),
                                   RecognizeRefusal(face: 21, why: "too_few_samples", closest: nil)])
        XCTAssertEqual(r.edges, [RecognizedEdge(edge: 30, kind: "ellipse", deviation: 0.75),
                                 RecognizedEdge(edge: 31, kind: "circle", deviation: 0.0625),
                                 RecognizedEdge(edge: 32, kind: "line", deviation: 0.03125)])
    }

    /// Python's test_recognize_takes_a_nurbs_cylinder_back_to_planes_and_a_cylinder: a cylinder
    /// converted to NURBS comes back as two planes and a cylinder, its volume kept.
    func testRecognizeTakesANurbsCylinderBackToPlanesAndACylinder() throws {
        let made = try Solid.cylinder(2, 5)
        let nurbs = try made.convertToNurbs("all")
        let (back, report) = try nurbs.recognize()
        XCTAssertTrue(back !== nurbs)
        XCTAssertEqual(report.faces.map(\.kind).sorted(), ["cylinder", "plane", "plane"])
        XCTAssertEqual(report.faces.map(\.face).sorted(), [0, 1, 2])
        XCTAssertTrue(report.refused.isEmpty, "\(report.refused)")
        XCTAssertEqual(report.edgesLeft, 0)
        XCTAssertGreaterThanOrEqual(report.edges.filter { $0.kind == "circle" }.count, 2)
        XCTAssertTrue(report.edges.allSatisfy { $0.kind == "line" || $0.kind == "circle" }, "\(report.edges)")
        XCTAssertGreaterThan(report.tolerance, 0)
        XCTAssertLessThanOrEqual(report.worstFace, report.tolerance)
        XCTAssertLessThanOrEqual(report.worstEdge, report.tolerance)
        let madeMass: Mass = try made.mass()
        let backMass: Mass = try back.mass()
        let want = madeMass.volume, got = backMass.volume
        XCTAssertLessThanOrEqual(abs(got - want), 1e-6 * abs(want), "volume \(got), the cylinder's \(want)")
        XCTAssertEqual(try nurbs.recognize(tolerance: 0.5).1.tolerance, 0.5)
    }

    /// A cylinder as made has nothing to take.
    func testRecognizeTakesNothingFromAnAnalyticBody() throws {
        let (_, plain) = try Solid.cylinder(2, 5).recognize()
        XCTAssertTrue(plain.faces.isEmpty, "\(plain.faces)")
        XCTAssertTrue(plain.refused.isEmpty, "\(plain.refused)")
    }
}
