// The library the build linked says which flavour it is: the one CADACLYSM_FLAVOUR chose
// (Package.swift). The reader's half, so it runs under every flavour.
import Cadaclysm
import XCTest

final class FlavourTests: XCTestCase {
    func testTheReaderSaysWhichFlavourItIs() {
        let features = Set(Cadaclysm.features().split(separator: ",").map(String.init))
#if CADACLYSM_SEPARATE
        XCTAssertEqual(Cadaclysm.flavour(), "reader")
        XCTAssertEqual(Cadaclysm.features(), "")
#elseif CADACLYSM_READER
        XCTAssertEqual(Cadaclysm.flavour(), "reader")
        XCTAssertTrue(features.contains("nodes"), Cadaclysm.features())
        XCTAssertFalse(features.contains("kernel"), Cadaclysm.features())
#else
        XCTAssertEqual(Cadaclysm.flavour(), "full")
        XCTAssertTrue(features.isSuperset(of: ["nodes", "kernel", "write-breps"]), Cadaclysm.features())
#endif
    }
}
