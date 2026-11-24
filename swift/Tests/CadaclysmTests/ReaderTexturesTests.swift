// glTF materials and images: samples/textured-quad.glb (samples/textured-quad.py) and a part
// read from no glTF.
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
    guard FileManager.default.fileExists(atPath: path) else {
        XCTFail("\(relative) is not in this checkout (a worktree: scripts/link-samples.py)")
        throw CadaclysmError("missing \(relative)")
    }
    return path
}

final class ReaderTexturesTests: XCTestCase {
    func testTexturedQuadMaterialsAndImage() throws {
        let scene = try Cadaclysm.open(try sample("samples/textured-quad.glb"))
        var materials: [String: Material] = [:]
        for node in scene.nodes {
            if let m = node.material { materials[m.name] = m }
        }
        XCTAssertEqual(Set(materials.keys), ["Checker", "Plain"])
        let checker = try XCTUnwrap(materials["Checker"])
        XCTAssertEqual(checker.baseColor, SIMD4(1, 0.5, 0.25, 1))
        XCTAssertEqual(checker.metallic, 0)
        XCTAssertEqual(checker.roughness, 0.5)
        XCTAssertEqual(checker.alphaMode, "mask")
        XCTAssertEqual(checker.alphaCutoff, 0.25)
        XCTAssertTrue(checker.doubleSided)
        XCTAssertEqual(checker.baseColorImage, 0)
        XCTAssertEqual(checker.baseColorUvSet, 0)
        XCTAssertEqual(checker.uvOffset, SIMD2(0.5, 0))
        XCTAssertEqual(checker.uvRotation, 0)
        XCTAssertEqual(checker.uvScale, SIMD2(2, 2))
        XCTAssertEqual(checker.wrapU, "clamp_to_edge")
        XCTAssertEqual(checker.wrapV, "mirrored_repeat")
        XCTAssertEqual(checker.magFilter, "linear")
        XCTAssertEqual(checker.minFilter, "linear")
        let plain = try XCTUnwrap(materials["Plain"])
        XCTAssertNil(plain.baseColorImage)
        XCTAssertEqual(plain.alphaMode, "opaque")

        XCTAssertEqual(scene.imageCount, 1)
        let image = try scene.image(0)
        XCTAssertEqual(image.mime, "image/png")
        XCTAssertEqual(image.name, "checker")
        XCTAssertEqual(image.data.count, 75)
        XCTAssertEqual(Array(image.data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertThrowsError(try scene.image(1), "past the last")
    }

    func testCubeHasNoMaterialsOrImages() throws {
        let scene = try Cadaclysm.open(try sample("samples/cube.scad"))
        XCTAssertEqual(scene.imageCount, 0)
        for node in scene.nodes { XCTAssertNil(node.material, "node \(node.index)") }
        XCTAssertThrowsError(try scene.image(0), "no images")
    }
}
