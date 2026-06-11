import XCTest
@testable import Fuse

final class ModuleCatalogTests: XCTestCase {
    /// Every feature tab must have a card on General → Fused apps (and no
    /// card may exist without a tab) — adding a module reminds you of both.
    func testEveryFeatureTabHasACard() {
        let cardModules = Set(FuseModule.all.map {
            $0.key.replacingOccurrences(of: ".enabled", with: "")
        })
        let featureTabs = Set(SettingsTab.allCases.filter { $0 != .general }.map(\.rawValue))
        XCTAssertEqual(cardModules, featureTabs)
    }

    func testKeysAreUniqueWellFormedEnabledKeys() {
        let keys = FuseModule.all.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count, "duplicate module keys")
        for key in keys {
            XCTAssertTrue(key.hasSuffix(".enabled"), "\(key) is not an .enabled key")
        }
    }
}
