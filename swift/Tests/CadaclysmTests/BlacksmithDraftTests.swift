// Draft over the release library: Python's test_cadaclysm_blacksmith.py "draft a box side to the
// closed form", "draft analysis reads a box's six kinds" and "draft refusals are named" -- a 2 x 3 x
// 4 box's +x side drafted 5 degrees about its bottom loses a wedge of h^2 w tan(5)/2, every figure a
// closed form written out here. The kernel's own correctness is the kernel's tests' and refcheck's
// job.
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

/// The face of `solid` whose outward normal is `n`.
private func facing(_ solid: Solid, _ n: SIMD3<Double>) throws -> Int {
    for f in 0..<(try solid.faces) {
        let z = try solid.faceFrame(f)
        if abs(z[9] - n.x) < 1e-9 && abs(z[10] - n.y) < 1e-9 && abs(z[11] - n.z) < 1e-9 { return f }
    }
    throw BuildError("no face facing \(n)")
}

private let fiveDegrees = 5 * Double.pi / 180

final class BlacksmithDraftTests: XCTestCase {
    func testDraftABoxSideToTheClosedForm() throws {
        let block = try Solid.cuboid(2, 3, 4)
        let side = try facing(block, [1, 0, 0])
        let out = try block.draft([side], try Frame.xy([0, 0, -2]), fiveDegrees)
        XCTAssertEqual(try out.faces, 6)
        let want = 24 - 16 * 3 * tan(fiveDegrees) / 2
        let mass: Mass = try out.mass()
        XCTAssertEqual(mass.volume, want, accuracy: 1e-9 * want)
        let at = try out.draftAngleAt(side, [5, 0, 0], pull: [0, 0, 2])
        XCTAssertEqual(at.angle, fiveDegrees, accuracy: 1e-12)
        XCTAssertNotNil(at.uv)
        XCTAssertEqual(at.normal.x, cos(fiveDegrees), accuracy: 1e-12)
        XCTAssertEqual(at.normal.z, sin(fiveDegrees), accuracy: 1e-12)
        // Two-sided about the middle: two half-height wedges off.
        let both = try block.draftTwoSided([side], try Frame.xy(), above: fiveDegrees, below: fiveDegrees, tolerance: 0)
        let wantBoth = 24 - 2 * (4 * 3 * tan(fiveDegrees) / 2)
        let bothMass: Mass = try both.mass()
        XCTAssertEqual(bothMass.volume, wantBoth, accuracy: 1e-9 * wantBoth)
    }

    func testDraftAnalysisReadsABoxsSixKinds() throws {
        let block = try Solid.cuboid(2, 3, 4)
        let top = try facing(block, [0, 0, 1]), bottom = try facing(block, [0, 0, -1]), side = try facing(block, [1, 0, 0])
        let rows = try block.draftAnalysis(pull: [0, 0, 1])
        XCTAssertEqual(rows.map(\.face), Array(0..<6))
        for r in rows {
            XCTAssertEqual(r.kind, r.face == top ? "positive" : r.face == bottom ? "negative" : "vertical", "\(r)")
            XCTAssertEqual(r.undercut, 0)
            XCTAssertGreaterThan(r.area, 0)
        }
        XCTAssertEqual(rows[top].min, Double.pi / 2, accuracy: 1e-9)
        XCTAssertEqual(rows[top].area, 6, accuracy: 1e-9)
        XCTAssertEqual(rows[top].positive, rows[top].area)
        let drafted = try block.draft([side], try Frame.xy([0, 0, -2]), fiveDegrees)
        let after = try drafted.draftAnalysis(pull: [0, 0, 1], threshold: Double.pi / 180, tolerance: nil)
        XCTAssertEqual(after[side].kind, "positive")
        XCTAssertEqual(after[side].min, fiveDegrees, accuracy: 1e-9)
    }

    func testDraftRefusalsAreNamed() throws {
        let block = try Solid.cuboid(2, 3, 4)
        let top = try facing(block, [0, 0, 1])
        let plane = try Frame.xy()
        XCTAssertTrue(refusal { _ = try block.draft([top], plane, 0.1) }?.hasPrefix("draft: ") ?? false)
        XCTAssertTrue(refusal { _ = try block.draft([], plane, 0.1) }?.hasPrefix("draft: ") ?? false)
        XCTAssertTrue(refusal { _ = try block.draftTwoSided([0, 0], plane, above: 0.1, below: 0.1) }?.hasPrefix("draft: ") ?? false)
        XCTAssertTrue(refusal { _ = try block.draftAngleAt(9, [0, 0, 0], pull: [0, 0, 1]) }?.hasPrefix("draft_angle_at: face 9 of 6") ?? false)
        XCTAssertTrue(refusal { _ = try block.draftAngleAt(0, [0, 0, 0], pull: [0, 0, 0]) }?.hasPrefix("draft_angle_at: ") ?? false)
        XCTAssertTrue(refusal { _ = try block.draftAnalysis(pull: [0, 0, 1], threshold: 2) }?.hasPrefix("draft_analysis: ") ?? false)
    }
}
