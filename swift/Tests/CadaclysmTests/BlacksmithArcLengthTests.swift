// Point at length, divide by count and divide by length over the release library: Python's
// test_cadaclysm_blacksmith.py, "a cylinder rim a quarter of the way round" to "a read circle edge
// divides on its circle", trimmed to what proves the marshalling -- every field read, every
// refusal's prefix, the list's length and order. The kernel's own correctness is the kernel's
// tests' and refcheck's job.
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

private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
    let d = a - b
    return (d * d).sum().squareRoot()
}

private func norm(_ a: SIMD3<Double>) -> Double { (a * a).sum().squareRoot() }

final class BlacksmithArcLengthTests: XCTestCase {
    func testACylinderRimAQuarterOfTheWayRound() throws {
        let cylinder = try Solid.cylinder(2.5, 4)
        var circles = 0
        for edge in try cylinder.edges where edge.kind == "circle" {
            let curve = try XCTUnwrap(edge.curve)
            let start = try cylinder.edgePointAtLength(edge.index, 0)
            XCTAssertEqual(start.parameter, curve.t0, accuracy: 1e-12)
            let quarter = try cylinder.edgePointAtLength(edge.index, 2.5 * Double.pi / 2)
            XCTAssertEqual(quarter.parameter, curve.t0 + Double.pi / 2, accuracy: 1e-9)
            XCTAssertEqual(distance(quarter.point, curve.origin), 2.5, accuracy: 1e-9)
            XCTAssertEqual(norm(quarter.tangent), 1, accuracy: 1e-12)
            XCTAssertNil(quarter.segment)
            XCTAssertFalse(quarter.fromPolyline)
            XCTAssertTrue(quarter.error.isFinite && quarter.error >= 0, "error \(quarter.error)")

            let four = try cylinder.edgeDivideByCount(edge.index, 4)
            XCTAssertEqual(four.count, 4)
            for k in 0..<4 {
                XCTAssertEqual(distance(four[k].point, four[(k + 1) % 4].point), 2.5 * 2.0.squareRoot(), accuracy: 1e-9)
            }
            XCTAssertEqual(four[0].point, start.point)
            XCTAssertEqual(try cylinder.edgeDivideByLength(edge.index, 2.5 * Double.pi / 2).count, 4)
            circles += 1
        }
        XCTAssertGreaterThanOrEqual(circles, 2)
    }

    func testAnOpenEdgeDividesEndToEnd() throws {
        let cuboid = try Solid.cuboid(2, 3, 4)
        var checked = false
        for edge in try cuboid.edges where edge.kind == "line" {
            guard abs(try cuboid.edgeLength(edge.index).length - 4) < 1e-9 else { continue }
            let curve = try XCTUnwrap(edge.curve)
            let five = try cuboid.edgeDivideByCount(edge.index, 4)
            XCTAssertEqual(five.count, 5)
            for (k, sample) in five.enumerated() {
                XCTAssertEqual(distance(sample.point, five[0].point), Double(k), accuracy: 1e-9)
            }
            XCTAssertEqual(five[0].parameter, curve.t0, accuracy: 1e-12)
            XCTAssertEqual(five[4].parameter, curve.t1, accuracy: 1e-12)
            let stepped = try cuboid.edgeDivideByLength(edge.index, 1.5)
            XCTAssertEqual(stepped.count, 3)
            for (sample, want) in zip(stepped, [0.0, 1.5, 3.0]) {
                XCTAssertEqual(distance(sample.point, stepped[0].point), want, accuracy: 1e-9)
            }
            checked = true
            break
        }
        XCTAssertTrue(checked, "no 4 long line edge")
    }

    func testASlotDividesOnItsOutline() throws {
        let slot = try Profile.slot([0, 0], 8, 1)
        let there = try slot.pointAtLength(6 + Double.pi / 2)
        for (got, want) in zip([there.point.x, there.point.y, there.point.z], [4.0, 0, 0]) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
        XCTAssertEqual(there.segment, 1)

        let eight = try slot.divideByCount(8)
        XCTAssertEqual(eight.count, 8)
        for sample in eight {
            let side = try XCTUnwrap(sample.segment)
            XCTAssertLessThanOrEqual(side, 4)
        }

        let stepped = try slot.divideByLength(3)
        XCTAssertEqual(stepped.count, Int(((12 + 2 * Double.pi) / 3).rounded(.down)) + 1)
        XCTAssertEqual(stepped.count, 7)
        for (k, sample) in stepped.enumerated() {
            let at = try slot.pointAtLength(3 * Double(k))
            XCTAssertLessThan(distance(sample.point, at.point), 1e-12)
            XCTAssertEqual(sample.segment, at.segment)
        }
        XCTAssertGreaterThan(distance(stepped[6].point, stepped[0].point), 0.1)
    }

    func testRefusalsNameTheirCall() throws {
        let cylinder = try Solid.cylinder(2.5, 4)
        let rim = try XCTUnwrap(try cylinder.edges.first { $0.kind == "circle" }).index
        func check(_ call: String, _ contains: String? = nil, _ body: () throws -> Void) {
            let message = refusal(body)
            XCTAssertTrue(message?.hasPrefix("\(call): ") ?? false, message ?? "\(call): no error")
            if let contains {
                XCTAssertTrue(message?.contains(contains) ?? false, message ?? "")
            }
        }
        check("edge_point_at_length") { _ = try cylinder.edgePointAtLength(rim, -1) }
        check("edge_point_at_length") { _ = try cylinder.edgePointAtLength(rim, 100) }
        let count = try cylinder.edges.count
        check("edge_point_at_length") { _ = try cylinder.edgePointAtLength(count, 1) }
        check("edge_divide_by_count", "not at least 1") { _ = try cylinder.edgeDivideByCount(rim, 0) }
        check("edge_divide_by_count", "not at most 1000000") { _ = try cylinder.edgeDivideByCount(rim, 1_000_001) }
        check("edge_divide_by_length") { _ = try cylinder.edgeDivideByLength(rim, 0) }
        check("edge_point_at_length", "is not an accuracy") { _ = try cylinder.edgePointAtLength(rim, 1, .nan) }

        let slot = try Profile.slot([0, 0], 8, 1)
        check("profile_point_at_length") { _ = try slot.pointAtLength(-1) }
        check("profile_divide_by_count") { _ = try slot.divideByCount(0) }
        check("profile_divide_by_length") { _ = try slot.divideByLength(-1) }
        check("profile_point_at_length", "is not an accuracy") { _ = try slot.pointAtLength(1, .infinity) }
    }

    func testTheDefaultAccuracyIsTheLibrarys() throws {
        let slot = try Profile.slot([0, 0], 8, 1)
        let standard = try slot.pointAtLength(5)
        XCTAssertEqual(try slot.pointAtLength(5, 0), standard)
        XCTAssertEqual(try slot.pointAtLength(5, -1), standard)
        let cylinder = try Solid.cylinder(2.5, 4)
        let rim = try XCTUnwrap(try cylinder.edges.first { $0.kind == "circle" }).index
        XCTAssertEqual(try cylinder.edgePointAtLength(rim, 3, 0), try cylinder.edgePointAtLength(rim, 3))
        XCTAssertEqual(try cylinder.edgeDivideByCount(rim, 4, -1), try cylinder.edgeDivideByCount(rim, 4))
    }
}
