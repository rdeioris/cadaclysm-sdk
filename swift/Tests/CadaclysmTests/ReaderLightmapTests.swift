// Lightmap UVs: the second texture-coordinate channel, asked for with `lightmapResolution:`.
import Cadaclysm
import Foundation
import XCTest

/// The checkout root: the first directory above this file holding samples/cube.scad.
private let root: URL? = {
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<8 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("samples/cube.scad").path) {
            return dir
        }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}()

private func sample(_ relative: String) throws -> String {
    guard let root = root else { throw XCTSkip("no samples/cube.scad above \(#filePath)") }
    let path = root.appendingPathComponent(relative).path
    guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("\(relative) is not in this checkout") }
    return path
}

final class ReaderLightmapTests: XCTestCase {
    // A faced STEP: samples/mechanism.stp has no faces.
    private let faced = "crates/cadaclysm-acis/tests/fixtures/fusion/rhino-fillet-mixed-radii.stp"

    func testLightmapUvsArriveWhenAskedAndNotOtherwise() throws {
        let plain = try Cadaclysm.open(try sample(faced))
        for node in plain.walk() { XCTAssertNil(node.lightmapUvs, "unasked is off") }
        let lit = try Cadaclysm.open(try sample(faced), lightmapResolution: 256)
        var count = 0
        for node in lit.walk() {
            guard let uvs = node.lightmapUvs else { continue }
            let mesh = node.mesh
            XCTAssertEqual(uvs.count, mesh.vertexCount * 2, "two floats a vertex")
            for i in 0..<uvs.count { XCTAssert((0...1).contains(uvs[i]), "inside the unit square") }
            XCTAssertNil(mesh.uvs, "no material uvs were asked")
            count += 1
        }
        XCTAssertGreaterThan(count, 0, "a faced STEP comes back lit")
    }
}
