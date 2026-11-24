// NACA airfoils over the release library: Python's naca tests trimmed to what proves the
// marshalling -- the five numbers both ways, the two-call points and spline, the profile's
// error, the refusals' prefixes. The kernel's own correctness is the kernel's tests' job.
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

final class BlacksmithNacaTests: XCTestCase {
    func testNacaCodes() throws {
        XCTAssertEqual(try Naca.parse("2412"), Naca.four(camber: 0.02, position: 0.4, thickness: 0.12))
        XCTAssertEqual(try Naca.parse("23112"), Naca.five(lift: 0.3, position: 0.15, thickness: 0.12, reflex: true))
        XCTAssertEqual(try Naca.parse("23012").series, 5)
    }

    /// A1 (0012's open-edge ordinate at x = 0.5) and A5 (seven points, the leading edge in the
    /// middle, the upper surface first).
    func testNacaFigures() throws {
        let pts = try Naca.parse("0012").points(chord: 1, count: 201, closedTrailingEdge: false)
        XCTAssertEqual(pts.count, 201)
        XCTAssertEqual(pts[100], SIMD2(0, 0))
        XCTAssertEqual(pts[50].x, 0.5, accuracy: 1e-15)
        XCTAssertEqual(pts[50].y, 0.052940252, accuracy: 1e-9)
        let seven = try Naca.parse("2412").points(chord: 1, count: 7)
        XCTAssertEqual(seven.count, 7)
        XCTAssertEqual(seven[3], SIMD2(0, 0))
        XCTAssertTrue(seven[1].y > 0 && seven[5].y < 0, "\(seven)")
        XCTAssertEqual(seven[0], SIMD2(1, 0))
        XCTAssertEqual(seven[6], seven[0])
    }

    func testNacaSplineAndProfile() throws {
        let n = try Naca.parse("4412")
        let s = try n.spline(chord: 50)
        XCTAssertEqual(s.controls.count, 32)
        XCTAssertEqual(s.controls.first, SIMD2(50, 0))
        XCTAssertEqual(s.controls.last, SIMD2(50, 0))
        XCTAssertTrue(s.error > 0 && s.error < 5e-3, "\(s.error)")
        let p = try n.profile(chord: 50, closedTrailingEdge: false)
        XCTAssertTrue(p.error > 0 && p.error <= 5e-4, "\(p.error)")
        XCTAssertGreaterThan(try p.profile.length().length, 100)
    }

    /// The refusals carry C's prefixed message.
    func testNacaRefusals() throws {
        let short = try XCTUnwrap(refusal { _ = try Naca.parse("12") })
        XCTAssertTrue(short.hasPrefix("naca_parse: "), short)
        XCTAssertEqual(refusal { _ = try Naca.parse("26012") }, "naca_parse: 5-digit positions are 1 to 5")
        let n = Naca.four(camber: 0.02, position: 0.4, thickness: 0.12)
        let chord = try XCTUnwrap(refusal { _ = try n.points(chord: 0) })
        XCTAssertTrue(chord.hasPrefix("naca_points: "), chord)
        let even = try XCTUnwrap(refusal { _ = try n.points(chord: 1, count: 8) })
        XCTAssertTrue(even.hasPrefix("naca_points: "), even)
        let negative = try XCTUnwrap(refusal { _ = try n.points(chord: 1, count: -1) })
        XCTAssertTrue(negative.hasPrefix("naca_points: "), negative)
        let few = try XCTUnwrap(refusal { _ = try n.spline(chord: 1, controls: 7) })
        XCTAssertTrue(few.hasPrefix("naca_spline: "), few)
        let tol = try XCTUnwrap(refusal { _ = try n.profile(chord: 1, tolerance: -1) })
        XCTAssertTrue(tol.hasPrefix("profile_naca: "), tol)
    }
}
