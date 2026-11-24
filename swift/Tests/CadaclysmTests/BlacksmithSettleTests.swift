// Contact settle over the release library: the hand-computed check figures of clockwork plan 3
// (Python's test_contact_settle_figures) trimmed to what proves the marshalling -- the pivots'
// order, every result field, the absent contact, the nil defaults, the refusal's prefix.
@testable import Blacksmith
import Foundation
import XCTest

final class BlacksmithSettleTests: XCTestCase {
    /// The driver a unit disc at local (3, 0) about (5, 0), turned to pi (world (2, 0)); the
    /// follower a unit disc at local (2, 0) about the origin.
    private func discs() throws -> (Profile, Profile) {
        (try Profile.circle(1).translate(3, 0), try Profile.circle(1).translate(2, 0))
    }

    /// S1: clockwise from pi to pi/3, touching at (1.5, sqrt 3 / 2).
    func testS1ClockwiseToFirstContact() throws {
        let (d, f) = try discs()
        let h = 3.0.squareRoot() / 2
        let s = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                  previous: .pi, direction: -1, tolerance: 1e-11)
        XCTAssertEqual(s.value, .pi / 3, accuracy: 1e-9)
        XCTAssertFalse(s.recoiled)
        XCTAssertGreaterThan(s.steps, 0)
        let c = try XCTUnwrap(s.contact)
        XCTAssertEqual(c.point.x, 1.5, accuracy: 1e-9)
        XCTAssertEqual(c.point.y, h, accuracy: 1e-9)
        XCTAssertEqual(c.normal.x, -0.5, accuracy: 1e-9)
        XCTAssertEqual(c.normal.y, h, accuracy: 1e-9)
        XCTAssertEqual(c.driver.loop, 0)
        XCTAssertEqual(c.follower.loop, 0)
    }

    /// S5: S1 counter-clockwise reaches the limit 3 pi / 2 without contact.
    func testS5StopsAtTheLimit() throws {
        let (d, f) = try discs()
        let s = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                  previous: .pi, direction: 1, limit: 1.5 * .pi, tolerance: 1e-11)
        XCTAssertEqual(s.value, 1.5 * .pi)
        XCTAssertNil(s.contact)
        XCTAssertFalse(s.recoiled)
    }

    /// S6: S1 from pi/6 (overlapping) recoils to pi/3.
    func testS6RecoilsOutOfPenetration() throws {
        let (d, f) = try discs()
        let s = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                  previous: .pi / 6, direction: -1, tolerance: 1e-11)
        XCTAssertEqual(s.value, .pi / 3, accuracy: 1e-9)
        XCTAssertNotNil(s.contact)
        XCTAssertTrue(s.recoiled)
    }

    /// A nil tolerance is the default: 1e-9 of either placed disc's diagonal, 2 sqrt 2.
    func testDefaultTolerance() throws {
        let (d, f) = try discs()
        let plain = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                      previous: .pi, direction: -1)
        let given = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                      previous: .pi, direction: -1, tolerance: 2e-9 * 2.0.squareRoot())
        XCTAssertEqual(plain.value, given.value)
        XCTAssertEqual(plain.steps, given.steps)
        XCTAssertEqual(plain.contact?.point, given.contact?.point)
    }

    /// A direction of 0 is refused with C's prefixed message.
    func testRefusalNamesTheCall() throws {
        let (d, f) = try discs()
        do {
            _ = try contactSettle(d, driverPivot: SIMD2(5, 0), driverAngle: .pi, f, followerPivot: SIMD2(0, 0),
                                  previous: .pi, direction: 0)
            XCTFail("direction 0 was not refused")
        } catch let error as BuildError {
            XCTAssertTrue(error.message.hasPrefix("contact_settle: "), error.message)
        }
    }
}
