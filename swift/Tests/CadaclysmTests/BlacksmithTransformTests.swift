// Transforms over the release library: Python's test_a_transform_is_sixteen_numbers_row_major_and_
// composes_right_to_left .. test_a_profile_turns_scales_mirrors_and_maps (transforms plan A4), plus
// the product checks the Java and C# tasks found Python's figures miss. @testable for the raw
// 12-number mirror: `Frame` refuses the skew frame before the library sees it.
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

private func assertRefused(_ prefix: String, file: StaticString = #filePath, line: UInt = #line,
                           _ body: () throws -> Void) {
    let message = refusal(body)
    XCTAssertTrue(message?.hasPrefix(prefix) ?? false, "refused with \(message ?? "nothing"), not \(prefix)",
                  file: file, line: line)
}

private func assertAt(_ p: SIMD3<Double>, _ x: Double, _ y: Double, _ z: Double, _ tolerance: Double = 1e-12,
                      file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(p.x, x, accuracy: tolerance, "\(p)", file: file, line: line)
    XCTAssertEqual(p.y, y, accuracy: tolerance, "\(p)", file: file, line: line)
    XCTAssertEqual(p.z, z, accuracy: tolerance, "\(p)", file: file, line: line)
}

private func assertQuaternion(_ q: Quaternion, _ w: Double, _ x: Double, _ y: Double, _ z: Double,
                              _ tolerance: Double = 1e-12, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(q.w, w, accuracy: tolerance, "\(q)", file: file, line: line)
    XCTAssertEqual(q.x, x, accuracy: tolerance, "\(q)", file: file, line: line)
    XCTAssertEqual(q.y, y, accuracy: tolerance, "\(q)", file: file, line: line)
    XCTAssertEqual(q.z, z, accuracy: tolerance, "\(q)", file: file, line: line)
}

/// The world XY frame through (x, y, z).
private func f(_ x: Double, _ y: Double, _ z: Double) throws -> Frame { try Frame.xy(SIMD3(x, y, z)) }

/// The determinant of the linear part.
private func det(_ t: Transform) -> Double {
    let r = t.rows
    return r[0] * (r[5] * r[10] - r[6] * r[9]) - r[1] * (r[4] * r[10] - r[6] * r[8]) + r[2] * (r[4] * r[9] - r[5] * r[8])
}

/// `p` extruded by 1 and read back through `Solid.bounds`: spans and centre, as the CAM tests
/// measure a profile's footprint (a profile has no public polylines here).
private func footprint(_ p: Profile) throws -> (w: Double, h: Double, cx: Double, cy: Double) {
    let b = try Solid.extrude(p, try Frame.xy(), 1.0).bounds
    return (b.max.x - b.min.x, b.max.y - b.min.y, (b.min.x + b.max.x) / 2, (b.min.y + b.max.y) / 2)
}

final class BlacksmithTransformTests: XCTestCase {
    func testATransformIsSixteenNumbersRowMajorAndComposesRightToLeft() throws {
        let t = try Transform.translation(SIMD3(1, 2, 3))
        XCTAssertEqual(t.rows, [1, 0, 0, 1, 0, 1, 0, 2, 0, 0, 1, 3, 0, 0, 0, 1])
        let s = try Transform.scale(.zero, 2)
        assertAt(try (t * s).point(SIMD3(1, 1, 1)), 3, 4, 5)
        assertAt(try t.compose(s).point(SIMD3(1, 1, 1)), 3, 4, 5)
        assertAt(try (s * t).point(SIMD3(1, 1, 1)), 4, 6, 8)
        assertAt(try s.compose(t).point(SIMD3(1, 1, 1)), 4, 6, 8)
        let ts = try t * s
        assertAt(try (ts.inverse() * ts).point(SIMD3(3, -4, 5)), 3, -4, 5)
        XCTAssertEqual(try Transform.fromRows(t.rows), t)
        XCTAssertEqual(try Transform(t.rows), t)
        let nested = (0..<4).map { i in Array(t.rows[(i * 4)..<(i * 4 + 4)]) }
        XCTAssertEqual(try Transform.fromRows(nested), t)
        XCTAssertEqual(Transform(), Transform.identity)

        assertRefused("Transform: the bottom row must be 0 0 0 1 (a projective map is not affine)") {
            _ = try Transform([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1])
        }
        assertRefused("Transform: a matrix is 16 numbers, got 15") { _ = try Transform([Double](repeating: 0, count: 15)) }
        var nan = Transform.identity.rows
        nan[0] = .nan
        assertRefused("Transform: not finite") { _ = try Transform(nan) }
        assertRefused("transform_inverse: the map is singular") {
            _ = try Transform.scaleXyz(try Frame.xy(), 1, 1, 0).inverse()
        }
    }

    func testEachConstructorMatchesItsClosedForm() throws {
        let xy = try Frame.xy()
        assertAt(try Transform.rotation((origin: SIMD3(1, 0, 0), direction: SIMD3(0, 0, 1)), .pi / 2).point(SIMD3(2, 0, 0)), 1, 1, 0)
        assertAt(try Transform.mirror(try f(0, 0, 5)).point(SIMD3(1, 2, 3)), 1, 2, 7)
        assertAt(try Transform.scaleXyz(xy, 2, 3, 4).point(SIMD3(1, 1, 1)), 2, 3, 4)
        let about = try Transform.scale(SIMD3(1, 2, 3), 2)
        assertAt(about.point(SIMD3(2, 2, 3)), 3, 2, 3)
        assertAt(about.point(SIMD3(1, 2, 3)), 1, 2, 3)
        assertAt(try Transform.shear(xy, SIMD3(5, 0, 0), 0.5).point(SIMD3(0, 0, 2)), 1, 0, 2)
        assertAt(try Transform.planarProjection(xy).point(SIMD3(1, 2, 3)), 1, 2, 0)
        assertAt(try Transform.projectAlong(xy, SIMD3(1, 0, 1)).point(SIMD3(0, 0, 2)), -2, 0, 0)
        assertAt(try Transform.planeToPlane(xy, try f(1, 2, 3)).point(.zero), 1, 2, 3)
        assertAt(try Transform.changeBasis(try f(1, 2, 3), xy).point(.zero), 1, 2, 3)

        assertRefused("transform_shear: the shear direction must lie in the plane") {
            _ = try Transform.shear(xy, SIMD3(0, 0, 1), 0.5)
        }
        // Frame refuses this frame itself ("not square"), so it goes as raw numbers.
        assertRefused("Frame: the axes are not square to each other") {
            _ = try Frame(values: [0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1])
        }
        assertRefused("transform_mirror: the frame is not right-handed and orthonormal") {
            _ = try Transform.mirror(raw: [0, 0, 0, 1, 1e-3, 0, 0, 1, 0, 0, 0, 1])
        }
    }

    func testAMapIsToldRigidOrSimilarAndSplit() throws {
        let xy = try Frame.xy()
        let turn = try Transform.rotation((origin: SIMD3(1, 2, 3), direction: SIMD3(1, 1, 0)), 0.7)
        XCTAssertTrue(try turn.isRigid())
        XCTAssertEqual(try XCTUnwrap(try turn.isSimilarity()), 1, accuracy: 1e-9)
        let big = try Transform.scale(.zero, 2.5) * turn
        XCTAssertFalse(try big.isRigid())
        XCTAssertEqual(try XCTUnwrap(try big.isSimilarity()), 2.5, accuracy: 1e-9)
        let bigSplit = try XCTUnwrap(try big.decomposeSimilarity())
        XCTAssertEqual(bigSplit.k, 2.5, accuracy: 1e-9)
        XCTAssertTrue(try bigSplit.orthogonal.isRigid())

        let scaleSplit = try XCTUnwrap(try Transform.scale(SIMD3(1, 2, 3), 2).decomposeSimilarity())
        assertAt(scaleSplit.translation, -1, -2, -3, 1e-9)
        XCTAssertEqual(scaleSplit.k, 2, accuracy: 1e-9)
        XCTAssertEqual(scaleSplit.orthogonal, Transform.identity)

        let rigid = try XCTUnwrap(try turn.decomposeRigid())
        assertAt(rigid.translation, turn.rows[3], turn.rows[7], turn.rows[11], 1e-9)
        XCTAssertTrue(try rigid.orthogonal.isRigid())

        let stretch = try Transform.scaleXyz(xy, 1, 2, 3)
        XCTAssertNil(try stretch.isSimilarity())
        XCTAssertNil(try stretch.decomposeRigid())
        XCTAssertNil(try stretch.decomposeSimilarity())

        let polar = try XCTUnwrap(try (Transform.mirror(xy) * stretch).decomposeAffine())
        assertAt(polar.stretch, 3, 2, 1, 1e-9)
        XCTAssertEqual(det(polar.rotation), -1, accuracy: 1e-9)
        XCTAssertEqual(det(polar.axes), 1, accuracy: 1e-9)
        XCTAssertTrue(try polar.rotation.isRigid())
        XCTAssertTrue(try polar.axes.isRigid())
        XCTAssertNil(try Transform.planarProjection(xy).decomposeAffine())

        assertRefused("transform_is_rigid: the tolerance must be finite and not negative") { _ = try turn.isRigid(tolerance: -1) }
        assertRefused("transform_is_similarity: the tolerance must be finite and not negative") { _ = try turn.isSimilarity(tolerance: -1) }
    }

    func testAQuaternionTurnsAsItsTransform() throws {
        let q = try Quaternion.fromAxisAngle(SIMD3(0, 0, 2), .pi / 2)
        assertQuaternion(q, cos(.pi / 4), 0, 0, sin(.pi / 4))
        XCTAssertEqual(q.angle, .pi / 2, accuracy: 1e-12)
        assertAt(try XCTUnwrap(q.axis), 0, 0, 1)
        assertAt(try q.toTransform(SIMD3(1, 0, 0)).point(SIMD3(2, 0, 0)), 1, 1, 0)
        assertAt(try Quaternion(2 * q.w, 2 * q.x, 2 * q.y, 2 * q.z).toTransform().point(SIMD3(1, 0, 0)), 0, 1, 0)
        let back = try Quaternion.fromTransform(try q.toTransform())
        assertQuaternion(back, q.w, q.x, q.y, q.z, 1e-9)
        XCTAssertEqual(try Quaternion.slerp(Quaternion(), q, 0.25).angle, .pi / 8, accuracy: 1e-9)
        assertQuaternion(try q * q.conjugate(), 1, 0, 0, 0, 1e-9)
        XCTAssertEqual(try Quaternion(0, 0, 0, 2).normalized(), try Quaternion(0, 0, 0, 1))
        // No zero components, so every term counts.
        XCTAssertEqual(try Quaternion(1, 2, 3, 4) * Quaternion(5, 6, 7, 8), try Quaternion(-60, 12, 30, 24))
        // Every term's sign: for two generic turns the product turns as the two transforms composed.
        let a = try Quaternion.fromAxisAngle(SIMD3(1, 2, 3), 0.7)
        let b = try Quaternion.fromAxisAngle(SIMD3(-2, 1, 0.5), 1.1)
        let product = try (a * b).toTransform().rows
        let composed = try (a.toTransform() * b.toTransform()).rows
        for (p, c) in zip(product, composed) { XCTAssertEqual(p, c, accuracy: 1e-12, "\(product) vs \(composed)") }
        assertQuaternion(try Quaternion.fromAxisAngle(SIMD3(1, 0, 0), .pi / 2) * Quaternion.fromAxisAngle(SIMD3(0, 1, 0), .pi / 2),
                         0.5, 0.5, 0.5, 0.5)

        assertRefused("quaternion_to_transform: the quaternion is zero") { _ = try Quaternion(0, 0, 0, 0).toTransform() }
        assertRefused("quaternion_from_transform: ") { _ = try Quaternion.fromTransform(try Transform.mirror(try Frame.xy())) }
        assertRefused("Quaternion: not finite") { _ = try Quaternion(.infinity, 0, 0, 0) }
    }

    func testAQuaternionFarFromUnitLengthStillNormalises() throws {
        let half = 0.5.squareRoot()
        for k in [1e200, 1e-170] {
            XCTAssertEqual(try Quaternion(k, 0, 0, 0).normalized(), try Quaternion(1, 0, 0, 0), "\(k)")
            XCTAssertEqual(try Quaternion(0, 0, 0, -k).normalized(), try Quaternion(0, 0, 0, -1), "\(k)")
            let kk = try Quaternion(k, k, 0, 0)
            assertQuaternion(try kk.normalized(), half, half, 0, 0)
            XCTAssertEqual(kk.length, k * 2.0.squareRoot(), accuracy: 1e-15 * k * 2.0.squareRoot(), "\(k)")
            XCTAssertEqual(kk.angle, .pi / 2, accuracy: 1e-12, "\(k)")
            assertAt(try XCTUnwrap(try Quaternion(0, k, k, 0).axis), half, half, 0)
        }
        assertRefused("Quaternion.normalized: the quaternion is zero") { _ = try Quaternion(0, 0, 0, 0).normalized() }
    }

    func testASolidTakesAnyAffineMap() throws {
        let xy = try Frame.xy()
        let box = try Solid.cuboid(1, 2, 3)
        XCTAssertEqual(box.inexactTrims, 0)
        let stretched = try box.transform(try Transform.scaleXyz(xy, 2, 3, 0.5))
        let b = try stretched.bounds
        XCTAssertEqual(b.max.x - b.min.x, 2, accuracy: 1e-9)
        XCTAssertEqual(b.max.y - b.min.y, 6, accuracy: 1e-9)
        XCTAssertEqual(b.max.z - b.min.z, 1.5, accuracy: 1e-9)
        XCTAssertEqual(stretched.inexactTrims, 0)
        let moved = try box.transform(try Transform.translation(SIMD3(1, 0, 0)).rows)
        XCTAssertEqual(moved.inexactTrims, 0)
        XCTAssertEqual(try moved.bounds.min.x, 0.5, accuracy: 1e-9)
        assertRefused("solid_transform: expected 16 numbers, got 12") { _ = try box.transform(xy.values) }

        let sheared = try Solid.cylinder(1, 2).transform(try Transform.shear(xy, SIMD3(1, 0, 0), 0.5))
        let mass: Mass = try sheared.mass(1e-7)
        let volume = mass.volume
        XCTAssertEqual(volume, 2 * .pi, accuracy: 1e-6 * 2 * .pi)
        XCTAssertTrue(try (0..<sheared.faces).contains { try sheared.faceKind($0) == "nurbs" })

        assertRefused("solid_transform: a singular map flattens the solid") {
            _ = try box.transform(try Transform.scaleXyz(xy, 1, 1, 0))
        }
    }

    func testAMappedSolidKeepsItsColoursAndName() throws {
        let named = try Solid.cylinder(1, 2).coloured("#808080").named("can")
        let side = try XCTUnwrap(try (0..<named.faces).first { try named.faceKind($0) == "cylinder" })
        let can = try named.coloured(SIMD3(0.2, 0.4, 1.0), face: side)
        let solidColour = try XCTUnwrap(try can.colour)
        let outs = [("transform", try can.transform(try Transform.shear(try Frame.xy(), SIMD3(1, 0, 0), 0.5))),
                    ("convert_to_nurbs", try can.convertToNurbs())]
        for (label, out) in outs {
            XCTAssertEqual(try out.faces, try can.faces, label)
            XCTAssertEqual(try out.faceColour(side), SIMD3(0.2, 0.4, 1.0), label)
            for i in 0..<(try out.faces) where i != side {
                XCTAssertEqual(try out.faceColour(i), solidColour, "\(label): face \(i)")
            }
            XCTAssertEqual(try out.name, "can", label)
        }
    }

    func testConvertToNurbsTakesThreeLevels() throws {
        let can = try Solid.cylinder(1, 2)
        let every = try can.convertToNurbs()
        XCTAssertTrue(try (0..<every.faces).allSatisfy { try every.faceKind($0) == "nurbs" })
        XCTAssertEqual(every.inexactTrims, 0)
        let analytic = try can.convertToNurbs("analytic")
        let kinds = Set(try (0..<analytic.faces).map { try analytic.faceKind($0) })
        XCTAssertTrue(kinds.contains("plane"), "\(kinds)")
        XCTAssertTrue(kinds.contains("nurbs"), "\(kinds)")
        assertRefused("convert_to_nurbs: level 'some' is not \"procedural\", \"analytic\" or \"all\"") {
            _ = try can.convertToNurbs("some")
        }
    }

    func testAProfileTurnsScalesMirrorsAndMaps() throws {
        let rect = try Profile.rect(80, 40)
        let r = try footprint(rect)
        let (rx, ry) = (r.cx, r.cy)
        var p = try footprint(try rect.rotate(SIMD2(0, 0), .pi / 2))
        XCTAssertEqual(p.w, 40, accuracy: 1e-3)
        XCTAssertEqual(p.h, 80, accuracy: 1e-3)
        p = try footprint(try rect.scale(SIMD2(0, 0), 0.5, 2))
        XCTAssertEqual(p.w, 40, accuracy: 1e-3)
        XCTAssertEqual(p.h, 80, accuracy: 1e-3)
        p = try footprint(try rect.rotate(SIMD2(10, 20), .pi / 2))
        XCTAssertEqual(p.cx, 10 - (ry - 20), accuracy: 1e-3)
        XCTAssertEqual(p.cy, 20 + (rx - 10), accuracy: 1e-3)
        p = try footprint(try rect.scale(SIMD2(10, 0), 0.5, 2))
        XCTAssertEqual(p.cx, 10 + 0.5 * (rx - 10), accuracy: 1e-3)
        XCTAssertEqual(p.cy, 2 * ry, accuracy: 1e-3)
        p = try footprint(try rect.mirror(SIMD2(100, 0), SIMD2(0, 1)))
        XCTAssertEqual(p.cx, 200, accuracy: 1e-3)
        p = try footprint(try rect.transform2d([1, 0.5, 0, 0, 1, 0]))
        XCTAssertEqual(p.w, 100, accuracy: 1e-3)
        assertRefused("profile_transform2d: the 2D map is singular") { _ = try rect.transform2d([1, 2, 0, 2, 4, 0]) }
        assertRefused("profile_transform2d: expected 6 numbers, got 4") { _ = try rect.transform2d([1, 0, 0, 1]) }
    }
}
