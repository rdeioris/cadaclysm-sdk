// Squish over the release library, as the kernel C ABI's squish_abi.rs drives it: a half ball cut
// from a sphere, its two faces squished apart (the disk exactly, the dome with its distortion), the
// dome alone with a point following, and the joined faces refused by name. The kernel's own
// correctness is the kernel's tests' and refcheck's job.
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

/// A sphere r 5 with the half below z = 0 cut away.
private func halfBall() throws -> Solid {
    let below = try Solid.cuboid(20, 20, 10).translate(0, 0, -5)
    return try Solid.sphere(5).cut(below, tolerance: 0)
}

final class BlacksmithSquishTests: XCTestCase {
    func testAHalfBallSquishesWithItsDistortionAndAPoint() throws {
        let half = try halfBall()
        XCTAssertEqual(try half.faces, 2)
        let q = try half.squish(explode: true)
        XCTAssertEqual(q.faces.count, 2)
        XCTAssertEqual(q.distortion.count, 2)
        XCTAssertEqual(q.exact.count, 1, "the disk alone is developable")
        XCTAssertEqual(try q.sheet.faces, 2)
        let disk = try XCTUnwrap(q.faces.firstIndex(of: q.exact[0]))
        let dome = 1 - disk
        XCTAssertEqual(q.distortion[disk].areaMean, 1, accuracy: 1e-6, "the disk's area kept")
        let a = q.distortion[dome]
        XCTAssertGreaterThan(a.areaMin, 0, "\(a)")
        XCTAssertLessThanOrEqual(a.areaMin, a.areaMean)
        XCTAssertLessThanOrEqual(a.areaMean, a.areaMax)
        XCTAssertTrue((0.45...0.7).contains(a.areaMean), "\(a)")

        // The dome alone, compress-only: the pole lands, a point far off does not.
        let alone = try half.squish(faces: [q.faces[dome]], points: [[0, 0, 5], [50, 50, 50]], deformation: .compressOnly,
                                    preserveBoundary: false)
        XCTAssertGreaterThanOrEqual(alone.distortion[0].lengthMin, 1, "compress only: every length at least its 3D one")
        XCTAssertEqual(alone.points.count, 2)
        let pole = try XCTUnwrap(alone.points[0])
        XCTAssertEqual(pole.z, 0, accuracy: 1e-9)
        XCTAssertNil(alone.points[1])
        XCTAssertEqual(alone.curves.count, 0)
    }

    func testBadSquishInputIsRefusedByName() throws {
        let half = try halfBall()
        // Both faces joined close on themselves: nothing to open from.
        let closed = refusal { _ = try half.squish() }
        XCTAssertTrue(closed?.hasPrefix("squish: ") ?? false, "\(String(describing: closed))")
        XCTAssertTrue(closed?.contains("closed") ?? false, "\(String(describing: closed))")
        XCTAssertTrue(refusal { _ = try half.squish(faces: [9], explode: true) }?.hasPrefix("squish: ") ?? false)
        XCTAssertEqual(SquishDeformation.allCases.map(\.rawValue), [0, 1, 2, 3, 4])
    }
}
