// Point, edge and face queries over the release library: the Python reference's tests, their closed
// forms as literals -- a 2 x 2 x 2 cube about the origin, the same with a bore of radius 0.5 along z,
// its fillet, a cylinder, a sphere, a 6 x 2 plate with and without a hole -- and the refusals' words.
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

private let halfPi: Double = Double.pi / 2
private let two: Double = 2
private let half: Double = 0.5

/// The face of `solid` whose inner point is highest.
private func topFace(_ solid: Solid) throws -> Int {
    var best = 0
    var z = -Double.infinity
    for f in 0..<(try solid.faces) {
        let h = try solid.faceInnerPoint(f).point.z
        if h > z { best = f; z = h }
    }
    return best
}

/// The 2 x 2 x 2 cube about the origin with a bore of radius 0.5 along z through it.
private func boredCube() throws -> Solid {
    let bar: Double = 4
    let down: Double = -2
    return try Solid.cuboid(two, two, two).cut(try Solid.cylinder(half, bar).translate(0, 0, down), tolerance: nil)
}

/// The first face of `solid` with a finite smallest radius.
private func curvedFace(_ solid: Solid) throws -> Int {
    for f in 0..<(try solid.faces) {
        let r = try solid.faceMinimumRadius(f).radius
        if r < Double.infinity { return f }
    }
    return -1
}

final class BlacksmithInspectTests: XCTestCase {
    func testAPointOnAFaceReadsInsideBoundaryOrOff() throws {
        let cube = try Solid.cuboid(two, two, two)
        let top = try topFace(cube)
        let inner = try cube.faceInnerPoint(top)
        XCTAssertEqual(inner.where, "inside")
        XCTAssertLessThan(inner.distance, 1e-12)
        XCTAssertEqual(try cube.facePoint(top, [0.2, 0.1, 1.0]).where, "inside")
        XCTAssertEqual(try cube.facePoint(top, [1.0, 0.1, 1.0], tolerance: 1e-6).where, "boundary")
        let off = try cube.facePoint(top, [0.2, 0.1, 1.5])
        XCTAssertEqual(off.where, "off")
        XCTAssertEqual(off.distance, 0.5, accuracy: 1e-12)
        XCTAssertEqual(off.point.x, 0.2, accuracy: 1e-12)
        XCTAssertEqual(off.point.y, 0.1, accuracy: 1e-12)
        XCTAssertEqual(off.point.z, 1.0, accuracy: 1e-12)
        // 1e-3 above the face: off at 1e-4, on at 1e-2.
        XCTAssertEqual(try cube.facePoint(top, [0.2, 0.1, 1.001], tolerance: 1e-4).where, "off")
        XCTAssertEqual(try cube.facePoint(top, [0.2, 0.1, 1.001], tolerance: 1e-2).where, "inside")
        let size = try cube.faceSize(top)
        XCTAssertEqual(size.width, 2, accuracy: 1e-9)
        XCTAssertEqual(size.height, 2, accuracy: 1e-9)
        // The bored cube's top face: a point in the hole is on the plane but off the face.
        let bored = try boredCube()
        let btop = try topFace(bored)
        XCTAssertEqual(try bored.facePoint(btop, [0.0, 0.0, 1.0]).where, "off")
        XCTAssertEqual(try bored.facePoint(btop, [0.5, 0.0, 1.0], tolerance: 1e-6).where, "boundary")
        XCTAssertTrue(refusal { _ = try cube.facePoint(99, [0, 0, 0]) }?.hasPrefix("face_point: face 99 of ") ?? false)
        XCTAssertTrue(refusal { _ = try cube.facePoint(0, [0, 0, 0], tolerance: -1) }?
            .hasPrefix("face_point: tolerance must be positive and finite") ?? false)
        XCTAssertTrue(refusal { _ = try cube.faceInnerPoint(6) }?.hasPrefix("face_inner_point: face 6 of 6") ?? false)
        XCTAssertTrue(refusal { _ = try cube.faceSize(6) }?.hasPrefix("face_size: face 6 of 6") ?? false)
    }

    func testAPointOnAnEdgeAndItsParameter() throws {
        let cube = try Solid.cuboid(two, two, two)
        let edge = try cube.edges[0]
        let mid = try cube.edgeInnerPoint(edge)
        XCTAssertTrue(mid.on)
        XCTAssertEqual(mid.distance, 0)
        XCTAssertTrue(try cube.edgePoint(0, mid.point).on)
        let three: Double = 3
        let far = mid.point * three + SIMD3<Double>(1, 1, 1)
        let e = try cube.edgePoint(edge, far)
        XCTAssertFalse(e.on)
        XCTAssertGreaterThan(e.distance, 0.5)
        let closest = try cube.edgeClosestPoint(0, far)
        XCTAssertEqual(e.t, closest.t)
        XCTAssertEqual(e.point, closest.point)
        XCTAssertEqual(e.distance, closest.distance)
        XCTAssertTrue(refusal { _ = try cube.edgePoint(12, far) }?.hasPrefix("edge_point: edge 12 of 12") ?? false)
        XCTAssertTrue(refusal { _ = try cube.edgeInnerPoint(12) }?.hasPrefix("edge_inner_point: edge 12 of 12") ?? false)
    }

    func testEdgeConvexityOnABoxAndAPocket() throws {
        let cube = try Solid.cuboid(two, two, two)
        XCTAssertEqual(try cube.edgesConvexity(), Array(repeating: "convex", count: 12))
        XCTAssertEqual(try cube.convexEdges(), Array(0..<12))
        XCTAssertEqual(try cube.concaveEdges(), [])
        let c = try cube.edgeConvexity(try cube.edges[3], angularTolerance: 0)
        XCTAssertEqual(c.kind, "convex")
        XCTAssertEqual(c.samples, 16)
        XCTAssertEqual(c.angleMin, halfPi, accuracy: 1e-12)
        XCTAssertEqual(c.angleMax, halfPi, accuracy: 1e-12)
        // A pocket's floor edges and its inside corners are concave: four and four.
        let w: Double = 40, d: Double = 30, h: Double = 10, lift: Double = 5
        let pw: Double = 20, pd: Double = 10, ph: Double = 8, plift: Double = 6
        let block = try Solid.cuboid(w, d, h).translate(0, 0, lift)
        let pocketed = try block.cut(try Solid.cuboid(pw, pd, ph).translate(0, 0, plift))
        XCTAssertEqual(try pocketed.concaveEdges().count, 8)
        XCTAssertTrue(refusal { _ = try cube.edgesConvexity(angularTolerance: -0.1) }?
            .hasPrefix("edges_convexity: the angular tolerance -0.1 is not in [0, pi/2)") ?? false)
        XCTAssertTrue(refusal { _ = try cube.edgeConvexity(12) }?.hasPrefix("edge_convexity: edge 12 of 12") ?? false)
    }

    func testTangentChainsSplitABoxAndJoinAFilletedOne() throws {
        let cube = try Solid.cuboid(two, two, two)
        XCTAssertEqual(try cube.tangentFaceGroups(), (0..<6).map { [$0] })
        XCTAssertEqual(try cube.tangentFaces(2), [2])
        XCTAssertEqual(try cube.tangentEdges(try cube.edges[4]), [4])
        let radius: Double = 0.3
        let rounded = try cube.fillet(Array(0..<12), radius)
        let n = try rounded.faces
        XCTAssertEqual(try rounded.tangentFaceGroups(), [Array(0..<n)])
        XCTAssertEqual(try rounded.tangentFaces(0).sorted(), Array(0..<n))
        XCTAssertTrue(refusal { _ = try cube.tangentFaces(6) }?.hasPrefix("tangent_faces: face 6 of 6") ?? false)
        XCTAssertTrue(refusal { _ = try cube.tangentFaceGroups(angularTolerance: 2) }?
            .hasPrefix("tangent_face_groups: the angular tolerance 2 is not in [0, pi/2)") ?? false)
    }

    func testAnglesBetweenFacesEdgesAndPoints() throws {
        let cube = try Solid.cuboid(two, two, two)
        let angles = try (0..<6).map { try cube.angleTo("face", 0, cube, "face", $0).angle }.sorted()
        let want: [Double] = [0, halfPi, halfPi, halfPi, halfPi, Double.pi]
        for (a, b) in zip(angles, want) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        let a = try cube.angleTo("edge", try cube.edges[0], cube, "face", 0)
        XCTAssertEqual(a.kind, "line_plane")
        // A cylinder's axis to its cap: square.
        let one: Double = 1, three: Double = 3
        let rod = try Solid.cylinder(one, three)
        let side = try curvedFace(rod)
        let cap = side == 0 ? 1 : 0
        let square = try rod.angleTo("face", side, rod, "face", cap)
        XCTAssertEqual(square.kind, "line_plane")
        XCTAssertEqual(square.angle, halfPi, accuracy: 1e-12)
        XCTAssertEqual(try angle([1, 0, 0], [0, 0, 0], [0, 3, 0]), halfPi, accuracy: 1e-15)
        XCTAssertEqual(try angle([1, 0, 0], [0, 0, 0], [-2, 0, 0]), Double.pi, accuracy: 1e-15)
        XCTAssertTrue(refusal { _ = try angle([0, 0, 0], [0, 0, 0], [1, 0, 0]) }?.hasPrefix("angle_points: ") ?? false)
        XCTAssertTrue(refusal { _ = try cube.angleTo("vertex", 0, cube, "face", 0) }?
            .hasPrefix("angle_between: a kind is 'face' or 'edge'") ?? false)
        let ball = try Solid.sphere(one)
        XCTAssertTrue(refusal { _ = try ball.angleTo("face", 0, cube, "face", 0) }?
            .hasPrefix("angle_between: face 0 is neither planar nor has an axis") ?? false)
    }

    func testMinimumRadiusOfABoreAndAPlane() throws {
        let bored = try boredCube()
        let wall = try curvedFace(bored)
        let r = try bored.faceMinimumRadius(wall)
        XCTAssertEqual(r.radius, 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.curvature, -2, accuracy: 1e-9)
        let flat = try Solid.cuboid(two, two, two).faceMinimumRadius(0)
        XCTAssertEqual(flat.radius, Double.infinity)
        XCTAssertEqual(flat.curvature, 0)
        XCTAssertTrue(refusal { _ = try Solid.cuboid(two, two, two).faceMinimumRadius(6) }?
            .hasPrefix("face_minimum_radius: face 6 of 6") ?? false)
    }

    func testAreaPropertiesOfAPlateWithAHole() throws {
        let six: Double = 6
        let rect = try Profile.rect(six, two).areaProperties()
        XCTAssertTrue(rect.accuracyMet)
        XCTAssertEqual(rect.area, 12, accuracy: 1e-12)
        XCTAssertEqual(rect.perimeter, 16, accuracy: 1e-12)
        XCTAssertEqual(rect.secondMoments.x, 4, accuracy: 1e-12)
        XCTAssertEqual(rect.secondMoments.y, 36, accuracy: 1e-12)
        XCTAssertEqual(rect.secondMoments.z, 0, accuracy: 1e-12)
        XCTAssertEqual(rect.principalMoments.x, 4, accuracy: 1e-12)
        XCTAssertEqual(rect.principalMoments.y, 36, accuracy: 1e-12)
        // The first principal axis is x (Ixx the smaller), the second it turned +90 degrees.
        XCTAssertEqual(abs(rect.principalAxes[0].x), 1, accuracy: 1e-12)
        XCTAssertEqual(rect.principalAxes[1].x, -rect.principalAxes[0].y, accuracy: 1e-12)
        XCTAssertEqual(rect.principalAxes[1].y, rect.principalAxes[0].x, accuracy: 1e-12)
        let holed = try Profile.rect(six, two).withHole(try Profile.circle(half)).areaProperties()
        let quarterPi: Double = Double.pi / 4
        let holeIxx: Double = Double.pi * 0.0625 / 4
        XCTAssertEqual(holed.area, 12 - quarterPi, accuracy: 1e-9)
        XCTAssertEqual(holed.perimeter, 16 + Double.pi, accuracy: 1e-9)
        XCTAssertEqual(holed.secondMoments.x, 4 - holeIxx, accuracy: 1e-9)
        XCTAssertEqual(holed.centroid.x, 0, accuracy: 1e-12)
        XCTAssertEqual(holed.centroid.y, 0, accuracy: 1e-12)
        XCTAssertTrue(refusal { _ = try Profile.rect(six, two).areaProperties(accuracy: 2) }?
            .hasPrefix("profile_area_properties: accuracy 2 is not in (0, 1)") ?? false)
    }
}
