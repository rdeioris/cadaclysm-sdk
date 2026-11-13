// The kernel's half of FlavourTests.swift: left out with the kernel, under the reader flavour.
import Blacksmith
import Cadaclysm
import XCTest

final class BlacksmithFlavourTests: XCTestCase {
    func testTheKernelSaysWhichFlavourItIs() {
#if CADACLYSM_SEPARATE
        XCTAssertEqual(Blacksmith.flavour(), "kernel")
        XCTAssertEqual(Blacksmith.features(), "")
#else
        // One library for both modules: the same answer as the reader's.
        XCTAssertEqual(Blacksmith.flavour(), "full")
        XCTAssertEqual(Blacksmith.features(), Cadaclysm.features())
#endif
    }
}
