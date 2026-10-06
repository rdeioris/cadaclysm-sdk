// CAM over the release library: Python's test_cadaclysm_blacksmith.py, "machining: to_arcs,
// offset, section, and a CAM job", and the job tests after it, plus Go's and Rust's own "the
// four verbs by hand" fixture (commit 74b9553ec, ported to Rust in 0ac0df203) -- machine()
// is one separate C entry point that never calls Job.face/contour/pocket/drill, so nothing
// below proves those four wrapper methods' own FFI call shapes without it.
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

/// `p` extruded by 1 and read back through `Solid.bounds`: (xMin, xMax, yMin, yMax), as Go's
/// and Rust's own smoke/test fixtures measure a profile's footprint.
private func footprint(_ p: Profile) throws -> (xMin: Double, xMax: Double, yMin: Double, yMax: Double) {
    let solid = try Solid.extrude(p, try Frame.xy(), 1.0)
    let bounds = try solid.bounds
    return (bounds.min.x, bounds.max.x, bounds.min.y, bounds.max.y)
}

private func assertFootprint(_ p: Profile, _ expected: (xMin: Double, xMax: Double, yMin: Double, yMax: Double),
                             tolerance: Double = 1e-3, file: StaticString = #filePath, line: UInt = #line) throws {
    let got = try footprint(p)
    XCTAssertEqual(got.xMin, expected.xMin, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(got.xMax, expected.xMax, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(got.yMin, expected.yMin, accuracy: tolerance, file: file, line: line)
    XCTAssertEqual(got.yMax, expected.yMax, accuracy: tolerance, file: file, line: line)
}

/// A 40x30x10 block on z=0 with a 20x10 pocket 8 deep: four corners a 6 mm end mill misses.
private func pocketedBlock() throws -> Solid {
    let block = try Solid.cuboid(40, 30, 10).translate(0, 0, 5)
    let pocket = try Solid.cuboid(20, 10, 8).translate(0, 0, 6)
    return try block.cut(pocket)
}

final class BlacksmithCAMTests: XCTestCase {
    // MARK: - The three geometry verbs

    func testProfileOffsetGrowsAndShrinksARectangle() throws {
        let rect = try Profile.rect(20, 10)
        let grown = try rect.offset(2, tolerance: 0.01)
        XCTAssertEqual(grown.count, 1)
        try assertFootprint(grown[0], (-12, 12, -7, 7))
        let shrunk = try rect.offset(-2, tolerance: 0.01)
        XCTAssertEqual(shrunk.count, 1)
        try assertFootprint(shrunk[0], (-8, 8, -3, 3))
        let eaten = try rect.offset(-6, tolerance: 0.01)
        XCTAssertTrue(eaten.isEmpty)
        XCTAssertEqual(refusal { _ = try rect.offset(.nan, tolerance: 0.01) },
                       "profile_offset: distance must be finite")
    }

    func testProfileToArcsFitsASplineWithinTolerance() throws {
        let spline = try Profile.spline([SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10)],
                                        degree: 3, weights: nil, closed: true)
        let fitted = try spline.toArcs(0.01)
        try assertFootprint(fitted, try footprint(spline), tolerance: 0.011)
        XCTAssertEqual(refusal { _ = try spline.toArcs(0) },
                       "profile_to_arcs: tolerance must be positive and finite")
    }

    func testSolidSectionCutsACuboid() throws {
        let cuboid = try Solid.cuboid(20, 10, 5)
        let middle = try cuboid.section(0, tolerance: 0.05)
        XCTAssertEqual(middle.count, 1)
        try assertFootprint(middle[0], (-10, 10, -5, 5))
        let miss = try cuboid.section(50, tolerance: 0.05)
        XCTAssertTrue(miss.isEmpty)
        XCTAssertEqual(refusal { _ = try cuboid.section(2.5, tolerance: 0.05) },
                       "solid_section: a face lies in the plane -- section a little above or below it")
    }

    // MARK: - The pocketed block: machine(), the report and operations()

    func testAPocketedBlockReportsFourCornersASixMmEndMillMisses() throws {
        let block = try pocketedBlock()
        let endMill = try Tool.flat(1, diameter: 6, fluteLength: 20, feed: 800, plunge: 200, rpm: 12000)
        let stock = try Stock.around(block, margin: 2)
        let job = try Job(stock, safeZ: 30)
        let report = try job.machine(block, endMill: endMill, skin: 0.3)
        XCTAssertEqual(report.items.count, 4)
        XCTAssertEqual(report.text.split(separator: "\n").count, 4)
        XCTAssertEqual(report.description, report.text)
        for item in report.items {
            XCTAssertEqual(item.kind, "corner")
            XCTAssertGreaterThan(item.size, 0)
            XCTAssertFalse(item.region.isEmpty)
            XCTAssertFalse(item.reason.isEmpty)
        }
        let ops = try job.operations()
        XCTAssertFalse(ops.isEmpty)
        for op in ops {
            XCTAssertFalse(op.kind.isEmpty)
            XCTAssertEqual(op.tool, 1)
            XCTAssertFalse(op.params.isEmpty)
        }

        // A drill as the end mill is refused, and leaves the job as it was.
        let drill = try Tool.drill(2, diameter: 5, fluteLength: 30, feed: 150, rpm: 3000)
        let freshStock = try Stock.around(block, margin: 2)
        let fresh = try Job(freshStock, safeZ: 30)
        let message = refusal { _ = try fresh.machine(block, endMill: drill, skin: 0.3) }
        XCTAssertNotNil(message)
        XCTAssertTrue(message?.contains("end mill must not be a drill") ?? false, message ?? "")
        XCTAssertTrue(try fresh.operations().isEmpty)
    }

    // MARK: - The plate: an empty report, operations, gcode and write_camotics

    func testThePlateIsMachinedCleanlyByOneEndMillAndOneDrill() throws {
        let plateOutline = try Profile.rect(80, 50).round(6)
        var part = try Solid.extrude(plateOutline, try Frame.xy(), 12)
        let pocketOutline = try Profile.rect(40, 24).round(4).withHole(try Profile.circle(5))
        let pocketSolid = try Solid.extrude(pocketOutline, try Frame.xy(SIMD3(0, 0, 7)), 5)
        part = try part.cut(pocketSolid)
        for (x, y) in [(-32.0, -17.0), (-32.0, 17.0), (32.0, -17.0), (32.0, 17.0)] {
            let bore = try Solid.cylinder(3, 12).translate(x, y, 0)
            part = try part.cut(bore)
        }

        let endMill = try Tool.flat(1, diameter: 6, fluteLength: 20, feed: 800, plunge: 200, rpm: 12000)
        let drill = try Tool.drill(2, diameter: 6, fluteLength: 30, feed: 150, rpm: 3000)
        let stock = try Stock.around(part, margin: 3)
        let job = try Job(stock, safeZ: 25, clearance: 1.0, tolerance: 0.01, name: "plate")
        let report = try job.machine(part, endMill: endMill, drills: [drill], skin: 0.3)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.text, "nothing left uncut")

        let ops = try job.operations()
        XCTAssertFalse(ops.isEmpty)
        XCTAssertEqual(ops[0].kind, "face")
        XCTAssertTrue(ops.contains { $0.kind == "pocket" })
        let last = ops.last!
        XCTAssertEqual(last.kind, "drill")
        XCTAssertEqual(last.params["points"] ?? nil, 4.0)
        XCTAssertTrue(last.params.keys.contains("peck"))
        XCTAssertNil(last.params["peck"]!)

        let programs = try job.gcode()
        XCTAssertEqual(programs.count, 2)
        for p in programs {
            XCTAssertGreaterThanOrEqual(p.tool, 1)
            XCTAssertFalse(p.name.isEmpty)
            XCTAssertFalse(p.text.isEmpty)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadaclysm-smoke-cam-swift-\(ProcessInfo.processInfo.processIdentifier)")
        let written = try job.writeCamotics(dir.appendingPathComponent("plate.camotics").path)
        XCTAssertFalse(written.isEmpty)
        XCTAssertTrue(written.last!.hasSuffix("plate.camotics"))
        for w in written {
            XCTAssertTrue(FileManager.default.fileExists(atPath: w), "\(w) was not written")
        }
        try? FileManager.default.removeItem(at: dir)

        // A stem that is all extension (".camotics") stays whole, as Python's Path.stem keeps it.
        let dotDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadaclysm-smoke-dot-swift-\(ProcessInfo.processInfo.processIdentifier)")
        let dotWritten = try job.writeCamotics(dotDir.appendingPathComponent(".camotics").path)
        XCTAssertGreaterThanOrEqual(dotWritten.count, 2)
        XCTAssertTrue(URL(fileURLWithPath: dotWritten[0]).lastPathComponent.hasPrefix(".camotics-T1"), "\(dotWritten)")
        try? FileManager.default.removeItem(at: dotDir)

        // A NUL in a CAMotics stem, or in a name, is refused in the kernel's words before the
        // library is asked, and the stem's refusal makes no folder.
        let nulName = "job: a name must be non-empty and without brackets, slashes, quotes, control characters, or : * ? < > |"
        XCTAssertEqual(refusal { _ = try job.writeCamotics(dir.path + "/a\0b.camotics") }, nulName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertEqual(refusal { _ = try Job(stock, safeZ: 25, name: "a\0b") }, nulName)
    }

    // MARK: - The four verbs driven by hand: face, contour, pocket and drill on their own

    /// Ports Go's "four verbs by hand" fixture (commit `74b9553ec`, also ported to Rust in
    /// `0ac0df203`): `machine()` never calls `Job.face`/`contour`/`pocket`/`drill`, so this is
    /// the only test that drives their own argument order, `side`'s outside/inside/on mapping
    /// and `drill`'s point count over the real C ABI.
    func testTheFourVerbsByHandGiveTwoProgramsWithTheSpecsOwnNumbers() throws {
        let outline = try Profile.rect(60, 40).round(5)
        let part = try Solid.extrude(outline, try Frame.xy(), 20)
        let end = try Tool.flat(1, diameter: 6, fluteLength: 20, feed: 800, plunge: 200, rpm: 12000)
        let drill = try Tool.drill(2, diameter: 5, fluteLength: 30, feed: 150, rpm: 3000)
        let stock = try Stock.around(part, margin: 2)
        let job = try Job(stock, safeZ: 30)

        try job.face(end, z: 20, stepover: 3, stepdown: 1)
        try job.contour(end, profile: outline, top: 20, bottom: 0, side: "outside", stepdown: 2, climb: true, open: false)
        let levels = try part.section(15, tolerance: 0.05)
        XCTAssertFalse(levels.isEmpty, "job: section(15) is empty")
        try job.pocket(end, profile: levels[0], top: 20, bottom: 10, stepover: 2.4, stepdown: 2)
        try job.drill(drill, points: [SIMD2(10, 10), SIMD2(40, 10)], top: 20, bottom: -1, peck: 3)

        let programs = try job.gcode()
        XCTAssertEqual(programs.count, 2)
        XCTAssertEqual(programs[0].tool, 1)
        XCTAssertEqual(programs[0].name, "job-T1")
        XCTAssertTrue(programs[0].text.hasPrefix("(cadaclysm: job-T1, T1 flat D6)\n"), programs[0].text)
        XCTAssertEqual(programs[1].tool, 2)
        XCTAssertEqual(programs[1].name, "job-T2")
        XCTAssertTrue(programs[1].text.hasPrefix("(cadaclysm: job-T2, T2 drill D5)\n"), programs[1].text)

        let ops = try job.operations()
        XCTAssertEqual(ops.map(\.kind), ["face", "contour", "pocket", "drill"])
        // `jobSide`'s mapping: "outside" is the library's own 0.
        XCTAssertEqual(ops[1].params["side"] ?? nil, 0.0)
        let drillOp = ops[3]
        XCTAssertEqual(drillOp.params["peck"] ?? nil, 3.0)
        XCTAssertEqual(drillOp.params["points"] ?? nil, 2.0)

        // A bad `side` is refused before the library is asked, and leaves the job unchanged.
        let before = try job.operations().count
        let message = refusal {
            try job.contour(end, profile: outline, top: 20, bottom: 0, side: "left", stepdown: 2, climb: true, open: false)
        }
        XCTAssertEqual(message, "side must be 'outside', 'inside' or 'on'")
        XCTAssertEqual(try job.operations().count, before)

        // A `nil` peck reads back as no peck at all through `Job.drill` directly, not only
        // through `Job.machine` (the plate fixture above covers that path).
        let noPeckJob = try Job(stock, safeZ: 30)
        try noPeckJob.drill(drill, points: [SIMD2(0, 0)], top: 20, bottom: -1, peck: nil)
        let noPeckOps = try noPeckJob.operations()
        XCTAssertTrue(noPeckOps[0].params.keys.contains("peck"))
        XCTAssertNil(noPeckOps[0].params["peck"]!)
    }

    // MARK: - A closed job refuses every call

    func testAClosedJobRefusesALaterCall() throws {
        let stock = try Stock.box(min: SIMD3(-10, -10, -10), max: SIMD3(10, 10, 10))
        let job = try Job(stock, safeZ: 20)
        job.close()
        XCTAssertTrue(job.isClosed)
        let tool = try Tool.flat(1, diameter: 6, fluteLength: 20, feed: 800, plunge: 200, rpm: 12000)
        XCTAssertEqual(refusal { try job.face(tool, z: 0, stepover: 3, stepdown: 1) }, "job: closed")
        // Idempotent: closing again does not throw or crash.
        job.close()
        XCTAssertTrue(job.isClosed)
    }
}
