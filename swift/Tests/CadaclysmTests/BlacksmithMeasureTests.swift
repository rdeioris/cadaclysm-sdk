// The oriented box, lengths, containment and closest points over the release library: Python's
// test_cadaclysm_blacksmith.py, "oriented box, lengths, containment, closest", trimmed to what
// proves the marshalling -- every field read, every error path's prefix and the classifier's
// lifetime. The kernel's own correctness is the kernel's tests' and refcheck's job.
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

private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

final class BlacksmithMeasureTests: XCTestCase {
    // MARK: - 1, 2: the oriented box

    func testOrientedBoxOfATurnedCuboid() throws {
        let turned = try Solid.cuboid(2, 3, 4).rotate((.zero, [0, 0, 1]), Double.pi / 6)
        let box = try turned.orientedBox(1e-9)
        let expected = [1.0, 1.5, 2.0]
        let half = [box.half.x, box.half.y, box.half.z].sorted()
        for (h, w) in zip(half, expected) {
            XCTAssertGreaterThanOrEqual(h, w - 1e-9)
            XCTAssertLessThanOrEqual(h, w + 1e-3)
        }
        XCTAssertEqual(box.centre.x, 0, accuracy: 1e-3)
        XCTAssertEqual(box.centre.y, 0, accuracy: 1e-3)
        XCTAssertEqual(box.centre.z, 0, accuracy: 1e-3)
        XCTAssertEqual(box.axes.count, 3)
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(dot(box.axes[i], box.axes[j]), i == j ? 1 : 0, accuracy: 1e-9)
            }
        }
    }

    func testOrientedBoxDefaultsAndErrors() throws {
        let cylinder = try Solid.cylinder(1, 2)
        let standard = try cylinder.orientedBox(1e-5)
        let grown = 1 + 3.125e-5 * 12.0.squareRoot()
        for accuracy in [0.0, -1.0] {
            let box = try cylinder.orientedBox(accuracy)
            XCTAssertEqual(box, standard)
            for h in [box.half.x, box.half.y, box.half.z].prefix(2) {
                XCTAssertEqual(h, grown, accuracy: 1e-12)
            }
        }
        let defaulted = try cylinder.orientedBox()
        XCTAssertEqual(defaulted, standard)
        let nan = refusal { _ = try cylinder.orientedBox(.nan) }
        XCTAssertNotNil(nan)
        XCTAssertTrue(nan?.hasPrefix("oriented_box: ") ?? false, nan ?? "")
        XCTAssertTrue(nan?.contains("is not an accuracy") ?? false, nan ?? "")
        let sheet = try Solid.cuboid(1, 2, 3).faceSheet(0)
        let open = refusal { _ = try sheet.orientedBox() }
        XCTAssertTrue(open?.hasPrefix("oriented_box: ") ?? false, open ?? "no error")
    }

    // MARK: - 3, 4: lengths

    func testEdgeLengthOfACylinderRim() throws {
        let cylinder = try Solid.cylinder(2.5, 4)
        var circles = 0
        for edge in try cylinder.edges where edge.kind == "circle" {
            let length = try cylinder.edgeLength(edge.index, 1e-9)
            XCTAssertEqual(length.length, 5 * Double.pi, accuracy: max(length.error, 1e-9))
            XCTAssertTrue(length.error >= 0 && length.error <= 1e-6 * length.length, "error \(length.error)")
            XCTAssertTrue(length.accuracyMet)
            XCTAssertFalse(length.fromPolyline)
            circles += 1
        }
        XCTAssertGreaterThan(circles, 0)
        let cube = try Solid.cuboid(1, 1, 1)
        let count = try cube.edges.count
        let past = refusal { _ = try cube.edgeLength(count) }
        XCTAssertTrue(past?.hasPrefix("edge_length: ") ?? false, past ?? "no error")
    }

    func testProfileLengthOfASlot() throws {
        let slot = try Profile.slot([0, 0], 8, 1)
        let length = try slot.length(1e-9)
        XCTAssertEqual(length.length, 12 + 2 * Double.pi, accuracy: max(length.error, 1e-9))
        XCTAssertTrue(length.error >= 0 && length.error <= 1e-6 * length.length, "error \(length.error)")
        XCTAssertTrue(length.accuracyMet)
        let nan = refusal { _ = try slot.length(.nan) }
        XCTAssertTrue(nan?.hasPrefix("profile_length: ") ?? false, nan ?? "no error")
    }

    // MARK: - 5, 6, 7: containment

    func testContainsOneShotAndClassifierAgree() throws {
        let box = try Solid.cuboid(2, 3, 4)
        XCTAssertEqual(try box.contains([0, 0, 0]), "inside")
        XCTAssertEqual(try box.contains([5, 0, 0]), "outside")
        XCTAssertEqual(try box.contains([0, 0, 2]), "on")
        let classifier = try box.classifier()
        let points: [SIMD3<Double>] = [[0, 0, 0], [0.99, 0, 0], [1, 0, 0], [1.2, 0, 0], [0, 1.6, 0], [0, 0, -2]]
        for p in points {
            XCTAssertEqual(try classifier.contains(p), try box.contains(p), "\(p)")
        }
        let sphere = try Solid.sphere(1.5)
        let fine = try sphere.classifier(tolerance: 1e-3)
        let line: [(Double, String)] = [(-2, "outside"), (-1.4, "inside"), (-0.5, "inside"), (0, "inside"),
                                        (0.5, "inside"), (1.4, "inside"), (2, "outside")]
        for (x, want) in line {
            XCTAssertEqual(try fine.contains([x, 0, 0]), want, "x = \(x)")
        }
        XCTAssertEqual(try fine.contains([1.5, 0, 0]), "on")
        XCTAssertEqual(try fine.contains([0, 0, -1.5]), "on")
    }

    func testClassifierOutlivesItsSolid() throws {
        let sphere = try Solid.sphere(1.0)
        let classifier = try sphere.classifier(tolerance: 1e-3)
        sphere.close()
        XCTAssertEqual(try classifier.contains([0, 0, 0]), "inside")
        XCTAssertEqual(try classifier.contains([2, 0, 0]), "outside")
        XCTAssertEqual(try classifier.contains([1, 0, 0]), "on")
    }

    func testContainsErrors() throws {
        let box = try Solid.cuboid(2, 3, 4)
        let classifier = try box.classifier()
        let nan1 = refusal { _ = try box.contains([.nan, 0, 0]) }
        XCTAssertTrue(nan1?.hasPrefix("contains: ") ?? false, nan1 ?? "no error")
        XCTAssertTrue(nan1?.contains("not finite") ?? false, nan1 ?? "")
        let nan2 = refusal { _ = try classifier.contains([.nan, 0, 0]) }
        XCTAssertTrue(nan2?.hasPrefix("classifier_contains: ") ?? false, nan2 ?? "no error")
        XCTAssertTrue(nan2?.contains("not finite") ?? false, nan2 ?? "")
        let zero1 = refusal { _ = try box.contains([0, 0, 0], tolerance: 0) }
        XCTAssertTrue(zero1?.hasPrefix("contains: ") ?? false, zero1 ?? "no error")
        XCTAssertTrue(zero1?.contains("positive and finite") ?? false, zero1 ?? "")
        let zero2 = refusal { _ = try box.classifier(tolerance: 0) }
        XCTAssertTrue(zero2?.hasPrefix("classifier_new: ") ?? false, zero2 ?? "no error")
        XCTAssertTrue(zero2?.contains("positive and finite") ?? false, zero2 ?? "")
        XCTAssertFalse(classifier.isClosed)
        classifier.close()
        XCTAssertTrue(classifier.isClosed)
        classifier.close()
        XCTAssertEqual(refusal { _ = try classifier.contains([0, 0, 0]) }, "classifier: closed")
    }

    // MARK: - 8, 9, 10: closest

    func testClosestOfTwoSpheres() throws {
        let a = try Solid.sphere(1)
        let b = try Solid.sphere(1).translate(5, 0, 0)
        let near = try a.closest(b, tolerance: 1e-3)
        XCTAssertEqual(near.distance, 3, accuracy: 6e-9)
        XCTAssertTrue(near.refined)
        XCTAssertEqual(near.kindA, "face")
        XCTAssertEqual(near.kindB, "face")
        XCTAssertNil(near.edgeA)
        XCTAssertNil(near.edgeB)
        for (got, want) in zip([near.onA.x, near.onA.y, near.onA.z], [1.0, 0, 0]) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }
        for (got, want) in zip([near.onB.x, near.onB.y, near.onB.z], [4.0, 0, 0]) {
            XCTAssertEqual(got, want, accuracy: 1e-6)
        }
        let back = try b.closest(a, tolerance: 1e-3)
        XCTAssertEqual(back.distance, near.distance, accuracy: 1e-12)
        for (x, y) in zip([back.onA.x, back.onA.y, back.onA.z], [near.onB.x, near.onB.y, near.onB.z]) {
            XCTAssertEqual(x, y, accuracy: 1e-9)
        }
        for (x, y) in zip([back.onB.x, back.onB.y, back.onB.z], [near.onA.x, near.onA.y, near.onA.z]) {
            XCTAssertEqual(x, y, accuracy: 1e-9)
        }
    }

    func testClosestNamesAFilletableEdge() throws {
        let box = try Solid.cuboid(2, 3, 4)
        let ball = try Solid.sphere(1).translate(3, 0, 4)
        let found = try box.closest(ball, tolerance: 1e-3)
        XCTAssertEqual(found.distance, 2 * 2.0.squareRoot() - 1, accuracy: 2e-3)
        XCTAssertEqual(found.kindA, "edge")
        let edge = try XCTUnwrap(found.edgeA)
        XCTAssertEqual(found.kindB, "face")
        XCTAssertNil(found.edgeB)
        let rounded = try box.fillet([Int(edge)], 0.2)
        XCTAssertEqual(try rounded.faces, try box.faces + 1)
    }

    func testClosestRefusesAZeroTolerance() throws {
        let a = try Solid.sphere(1)
        let b = try Solid.sphere(1).translate(5, 0, 0)
        let message = refusal { _ = try a.closest(b, tolerance: 0) }
        XCTAssertTrue(message?.hasPrefix("closest: ") ?? false, message ?? "no error")
    }
}
