// The reader's canonical recognition over the release library: Python's test_brep_recognize_*
// figures on box-union-sphere.3dm (in the repo) and the distinct-rows decoder test. @testable
// for the decoder.
@testable import Cadaclysm
import Foundation
import XCTest

/// crates/cadaclysm-acis/tests/fixtures/rhino/box-union-sphere.3dm, found from this file.
private let boxUnionSphere: String = {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<6 { dir = dir.deletingLastPathComponent() }   // up to crates/
    return dir.appendingPathComponent("cadaclysm-acis/tests/fixtures/rhino/box-union-sphere.3dm").path
}()

final class ReaderRecognizeTests: XCTestCase {
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

    /// Python's test_brep_recognize_takes_a_3dm_ball_back_to_a_sphere_and_leaves_the_original:
    /// box-union-sphere.3dm, a box unioned with a ball, every face stored as NURBS.
    func testBrepRecognizeTakesA3dmBallBackToASphere() throws {
        let scene = try Cadaclysm.open(boxUnionSphere)
        defer { scene.close() }
        let body = try XCTUnwrap(scene.nodes.lazy.compactMap { $0.brep }.first, "box-union-sphere.3dm has no brep")
        defer { body.release() }
        let (back, report) = try body.recognize()
        defer { back.release() }
        XCTAssertTrue(back !== body)
        XCTAssertNotEqual(back.pointer, body.pointer)
        let kinds = report.faces.map(\.kind)
        XCTAssertTrue(kinds.contains("sphere") && kinds.contains("plane"), "\(kinds)")
        XCTAssertEqual(Set(report.faces.map(\.face)).count, report.faces.count, "a face twice")
        for f in report.faces {
            XCTAssertLessThanOrEqual(f.deviation, report.tolerance, "face \(f.face)")
        }
        XCTAssertEqual(report.worstFace, report.faces.map(\.deviation).max() ?? 0.0)
        for e in report.edges {
            XCTAssertLessThanOrEqual(e.deviation, report.tolerance, "edge \(e.edge)")
            XCTAssertNotNil(try back.edgeTolerance(e.edge), "edge \(e.edge) has no edge tolerance on the result")
        }
        let (wide, at) = try body.recognize(tolerance: 0.25)
        wide.release()
        XCTAssertEqual(at.tolerance, 0.25)
    }

    /// Unasked, the ball is still NURBS; with `recognizeTolerance` every body the scene hands out
    /// is already analytic, so recognizing it again finds nothing to take.
    func testRecognizeOnOpen() throws {
        for (tolerance, wantSphere) in [(0.0, true), (1e-6, false)] {
            let scene = try Cadaclysm.open(boxUnionSphere, recognizeTolerance: tolerance)
            defer { scene.close() }
            let body = try XCTUnwrap(scene.nodes.lazy.compactMap { $0.brep }.first, "box-union-sphere.3dm has no brep")
            defer { body.release() }
            let (back, report) = try body.recognize()
            back.release()
            let kinds = report.faces.map(\.kind)
            if wantSphere {
                XCTAssertTrue(kinds.contains("sphere"), "unasked: \(kinds)")
            } else {
                XCTAssertTrue(kinds.isEmpty, "asked: \(kinds)")
            }
        }
        XCTAssertThrowsError(try Cadaclysm.open(boxUnionSphere, recognizeTolerance: -1)) { error in
            XCTAssertTrue("\(error)".contains("recognize_tolerance"), "\(error)")
        }
    }
}
