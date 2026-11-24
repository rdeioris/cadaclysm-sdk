// Gear profiles over the release library: Python's gear tests trimmed to what proves the
// marshalling -- every report field read, the nil base radius of cycloidal gearing, the NaN
// defaults, the refusals' prefixes. The kernel's own correctness is the kernel's tests' job.
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

final class BlacksmithGearsTests: XCTestCase {
    /// I1: an involute gear of module 1, 20 teeth, every default.
    func testInvoluteGearReport() throws {
        let g = try Profile.gearInvolute(1, teeth: 20)
        XCTAssertEqual(g.pitchRadius, 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.baseRadius), 9.396926208, accuracy: 1e-9)
        XCTAssertEqual(g.tipRadius, 11, accuracy: 1e-9)
        XCTAssertEqual(g.rootRadius, 8.75, accuracy: 1e-9)
        XCTAssertEqual(g.thickness, 1.570796327, accuracy: 1e-6)
        XCTAssertFalse(g.undercut)
        XCTAssertGreaterThan(try g.profile.length().length, 0)
    }

    /// I5: centre distances, plain and shifted.
    func testInvoluteCentreDistance() throws {
        XCTAssertEqual(try gearCentreDistanceInvolute(1, teethFirst: 20, teethSecond: 40), 30, accuracy: 1e-9)
        let a = try gearCentreDistanceInvolute(1, teethFirst: 20, teethSecond: 40, shiftFirst: 0.25, shiftSecond: 0.25)
        XCTAssertTrue(a > 30.4 && a < 30.5, "\(a)")
        let said = try XCTUnwrap(refusal { _ = try gearCentreDistanceInvolute(0, teethFirst: 20, teethSecond: 40) })
        XCTAssertTrue(said.hasPrefix("gear_centre_distance_involute: "), said)
    }

    /// C2: a cycloidal pinion of 8 leaves driven by a 60-tooth wheel, and that wheel.
    func testCycloidalPinionAndWheel() throws {
        let pinion = try Profile.gearPinionCycloidal(1, leaves: 8, wheelTeeth: 60)
        XCTAssertEqual(pinion.thickness, 1.05, accuracy: 1e-9)
        XCTAssertNil(pinion.baseRadius)
        let ogive = try Profile.gearPinionCycloidal(1, leaves: 8, wheelTeeth: 60, tip: .ogive)
        XCTAssertGreaterThan(ogive.tipRadius, 0)
        let wheel = try Profile.gearWheelCycloidal(1, teeth: 60, pinionLeaves: 8)
        XCTAssertNil(wheel.baseRadius)
        XCTAssertEqual(wheel.pitchRadius, 30, accuracy: 1e-9)
    }

    /// The refusals carry C's prefixed message.
    func testGearRefusalsNameTheCall() throws {
        let said = try XCTUnwrap(refusal { _ = try Profile.gearInvolute(1, teeth: 3) })
        XCTAssertTrue(said.hasPrefix("profile_gear_involute: "), said)
        let negative = try XCTUnwrap(refusal { _ = try Profile.gearInvolute(1, teeth: -1) })
        XCTAssertTrue(negative.hasPrefix("profile_gear_involute: "), negative)
    }
}
