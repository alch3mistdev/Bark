import XCTest
@testable import BarkCore

final class AppModeResolverTests: XCTestCase {
    private let available: Set<String> = ["raw", "clean", "email"]

    func testMappedHit() {
        let id = AppModeResolver.modeID(forBundleID: "com.apple.Terminal",
                                        map: ["com.apple.Terminal": "raw"],
                                        availableModeIDs: available, fallback: "clean")
        XCTAssertEqual(id, "raw")
    }

    func testUnmappedFallsBack() {
        let id = AppModeResolver.modeID(forBundleID: "com.unknown.app",
                                        map: ["com.apple.Terminal": "raw"],
                                        availableModeIDs: available, fallback: "clean")
        XCTAssertEqual(id, "clean")
    }

    func testNilBundleFallsBack() {
        XCTAssertEqual(AppModeResolver.modeID(forBundleID: nil, map: ["x": "raw"],
                                              availableModeIDs: available, fallback: "email"), "email")
    }

    func testDeletedTargetModeFallsBack() {
        // Mapping points at a mode that no longer exists → fallback.
        let id = AppModeResolver.modeID(forBundleID: "com.apple.Mail",
                                        map: ["com.apple.Mail": "legal-custom"],
                                        availableModeIDs: available, fallback: "clean")
        XCTAssertEqual(id, "clean")
    }

    func testEmptyMapFallsBack() {
        XCTAssertEqual(AppModeResolver.modeID(forBundleID: "com.apple.Mail", map: [:],
                                              availableModeIDs: available, fallback: "clean"), "clean")
    }
}
