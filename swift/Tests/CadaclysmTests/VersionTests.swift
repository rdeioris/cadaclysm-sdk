import Blacksmith
import Cadaclysm
import XCTest

final class VersionTests: XCTestCase {
    func testBothLibrariesAnswer() {
        XCTAssertFalse(Cadaclysm.version().isEmpty)
        XCTAssertFalse(Blacksmith.version().isEmpty)
    }
}
