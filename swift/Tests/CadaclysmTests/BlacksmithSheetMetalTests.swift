// Sheet metal and unroll over the release library: Python's test_cadaclysm_blacksmith.py
// "sheet metal: a tray reads, unfolds and folds back", "unroll a cylinder with points" and
// "sheet metal refusals are named" -- a 60 x 40 plate 1 thick flanged 15 up on all four sides, its
// flat pattern's volume a closed form written out here. The kernel's own correctness is the
// kernel's tests' and refcheck's job.
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

/// The face of `solid` whose outward normal is `n` and whose frame origin has z `z`.
private func face(_ solid: Solid, facing n: SIMD3<Double>, atZ z: Double) throws -> Int {
    for f in 0..<(try solid.faces) {
        let fr = try solid.faceFrame(f)
        if abs(fr[9] - n.x) < 1e-9 && abs(fr[10] - n.y) < 1e-9 && abs(fr[11] - n.z) < 1e-9 && abs(fr[2] - z) < 1e-9 { return f }
    }
    throw BuildError("no face facing \(n) at z \(z)")
}

private func volume(_ solid: Solid) throws -> Double {
    let mass: Mass = try solid.mass()
    return mass.volume
}

final class BlacksmithSheetMetalTests: XCTestCase {
    func testATrayReadsUnfoldsAndFoldsBack() throws {
        let rule = SheetRule(1.0)
        let full = try SheetRule.libraryDefault(1.0)
        XCTAssertEqual(full, SheetRule(1.0, bendRadius: 1, reliefWidth: 1, reliefDepth: 0.5, cornerSize: 2, miterGap: 0.1))
        let plate = try Solid.sheetBase(try Profile.rect(60, 40), rule)
        XCTAssertEqual(try volume(plate), 2400, accuracy: 1e-12 * 2400)
        let top = try face(plate, facing: [0, 0, 1], atZ: 0)
        let edges = try plate.edges.filter { $0.faces.contains(top) }
        XCTAssertEqual(edges.count, 4)
        let tray = try plate.sheetFlange(edges, Double.pi / 2, 15, rule)

        XCTAssertTrue(try tray.isSheetMetal())
        XCTAssertFalse(try Solid.cuboid(10, 10, 10).isSheetMetal())
        let info = try tray.sheetInfo()
        XCTAssertEqual(info.thickness, 1, accuracy: 1e-12)
        XCTAssertEqual(info.bends.count, 4)
        for b in info.bends {
            XCTAssertEqual(b.radius, 1, accuracy: 1e-9, "\(b)")
            XCTAssertEqual(abs(b.angle), Double.pi / 2, accuracy: 1e-9, "\(b)")
        }
        XCTAssertEqual(try tray.sheetBendFaces().count, 8)

        let flat = try tray.flatPattern(try face(tray, facing: [0, 0, 1], atZ: 0), rule)
        let allowance = Double.pi / 2 * (1 + 0.44)
        XCTAssertEqual(flat.bends.count, 4)
        for b in flat.bends {
            XCTAssertTrue(b.up, "\(b)")
            XCTAssertEqual(b.allowance, allowance, accuracy: 1e-9, "\(b)")
        }
        let want = 2400 - Double.pi + 2 * (58 + 38) * (15 - 2 + allowance)
        XCTAssertEqual(try volume(try flat.body), want, accuracy: 1e-6 * want)

        let text = try flat.dxf(units: "mm", extents: true, table: true, labels: true)
        for layer in ["OUTLINE", "BEND_UP", "BEND_EXTENT", "BEND_TABLE", "B4 UP 90"] {
            XCTAssertTrue(text.contains(layer), layer)
        }
        XCTAssertFalse(try flat.dxf(table: false).contains("BEND_TABLE"))

        let page = try Page(units: "mm")
        try page.addFlatPattern(flat, extents: false, labels: false)
        let plain = try page.entityCount
        XCTAssertGreaterThan(plain, 0)
        try page.addFlatPattern(flat, at: [200, 0], extents: true, labels: false)
        XCTAssertEqual(try page.entityCount - plain, plain + 8, "two zone edges a bend")

        // The drawing view: a note a bend, a ruled table (6 + 8 rules, 35 cells), two dimensions of six.
        for (notes, table, dims, more) in [(true, false, false, 4), (false, true, false, 6 + 8 + 35), (false, false, true, 12)] {
            let before = try page.entityCount
            try page.addFlatPattern(flat, at: [400, 0], extents: false, table: table, labels: false, notes: notes, dimensions: dims)
            XCTAssertEqual(try page.entityCount - before, plain + more, "the drawing view")
        }
        let drawn = try flat.dxf(notes: true, dimensions: true, folded: true)
        for layer in ["BEND_NOTE", "DIMENSION", "FOLDED", "K-FACTOR", "DEDUCTION"] {
            XCTAssertTrue(drawn.contains(layer), layer)
        }

        let again = try Solid.foldFlat(try flat.profile, flat.foldBends, rule, frame: flat.frame)
        let trayVolume = try volume(tray)
        XCTAssertEqual(try volume(again), trayVolume, accuracy: 1e-6 * trayVolume)

        flat.close()
        XCTAssertTrue(flat.isClosed)
        XCTAssertEqual(refusal { _ = try flat.body }, "flat_pattern: closed")
    }

    func testUnrollACylinderWithPoints() throws {
        let can = try Solid.cylinder(5, 10)
        let flat = try can.unroll(points: [[5, 0, 1], [50, 50, 50]])
        XCTAssertEqual(flat.faces.sorted(), [0, 1, 2])
        XCTAssertEqual(flat.notDevelopable, [])
        XCTAssertGreaterThanOrEqual(flat.cuts.count, 1)
        // The wall a 10 pi x 10 rectangle, the two discs beside it: area kept.
        let area = 2 * Double.pi * 5 * 10 + 2 * Double.pi * 25
        let mass: Mass = try flat.sheet.mass()
        XCTAssertEqual(mass.area, area, accuracy: 1e-6 * area)
        XCTAssertTrue(flat.curves.isEmpty)
        XCTAssertEqual(flat.points.count, 2)
        let spot = try XCTUnwrap(flat.points[0])
        XCTAssertEqual(spot.z, 0, accuracy: 1e-9)
        XCTAssertNil(flat.points[1])
        let exploded = try can.unroll(explode: true)
        XCTAssertGreaterThanOrEqual(exploded.cuts.count, flat.cuts.count)

        let rim = try NurbsCurve.fromEdge(can, 0)
        let traced = try can.unroll(curves: [rim])
        XCTAssertEqual(traced.curves.count, 1)
        XCTAssertGreaterThanOrEqual(traced.curves[0].count, 1)
    }

    func testSheetMetalRefusalsAreNamed() throws {
        let rule = SheetRule(1.0)
        let cube = try Solid.cuboid(10, 10, 10)
        XCTAssertTrue(refusal { _ = try cube.sheetInfo() }?.hasPrefix("sheet_info: ") ?? false)
        XCTAssertTrue(refusal { _ = try cube.flatPattern(0, rule) }?.hasPrefix("flat_pattern: ") ?? false)
        XCTAssertTrue(refusal { _ = try Solid.sheetBase(try Profile.rect(10, 10), SheetRule(-1.0)) }?.hasPrefix("sheet_base: ") ?? false)
        XCTAssertTrue(refusal { _ = try Solid.sphere(5).unroll() }?.hasPrefix("unroll: ") ?? false)
    }

    func testRipsJoinsAndCornerBreaks() throws {
        let rule = SheetRule(1.0)
        let plate = try Solid.sheetBase(try Profile.rect(60, 40), rule)
        let top = try face(plate, facing: [0, 0, 1], atZ: 0)
        let bottom = try face(plate, facing: [0, 0, -1], atZ: -1)

        let ripped = try plate.sheetRipPoints(top, [0, -20, 0], [0, 20, 0], gap: 0.5)
        XCTAssertEqual(try volume(ripped), 2400 - 20, accuracy: 1e-6 * 2380)
        XCTAssertTrue(refusal { _ = try Solid.cuboid(10, 10, 10).sheetRipFace(0) }?.hasPrefix("sheet_rip_face: ") ?? false)

        let corners = try plate.edges.filter { !$0.faces.contains(top) && !$0.faces.contains(bottom) }
        XCTAssertEqual(corners.count, 4)
        let rounded = try plate.sheetFillet(corners, 3, rule)
        let roundedWant = 2400 - (4 - Double.pi) * 9
        XCTAssertEqual(try volume(rounded), roundedWant, accuracy: 1e-6 * roundedWant)
        XCTAssertTrue(try rounded.isSheetMetal())
        let chamfered = try plate.sheetChamfer(Array(corners.prefix(2)), 2, rule)
        XCTAssertEqual(try volume(chamfered), 2400 - 4, accuracy: 1e-6 * 2396)

        let e = corners[0]
        XCTAssertTrue(refusal { _ = try plate.sheetJoin(e, e, rule) }?.hasPrefix("sheet_join: ") ?? false)
    }
}
