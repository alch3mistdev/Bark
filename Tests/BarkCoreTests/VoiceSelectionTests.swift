import XCTest
@testable import BarkCore

/// Voice-selection policy. Fixtures use REAL identifiers and tiers read off a
/// stock macOS 26 machine (180 voices, zero Enhanced/Premium) — the state that
/// made 017's speech sound robotic.
final class VoiceSelectionTests: XCTestCase {
    private let samanthaCompact = VoiceOption(
        identifier: "com.apple.voice.compact.en-US.Samantha",
        name: "Samantha", language: "en-US", tier: .basic)
    private let badNews = VoiceOption(
        identifier: "com.apple.speech.synthesis.voice.BadNews",
        name: "Bad News", language: "en-US", tier: .basic)
    private let zarvox = VoiceOption(
        identifier: "com.apple.speech.synthesis.voice.Zarvox",
        name: "Zarvox", language: "en-US", tier: .basic)
    private let eddyEloquence = VoiceOption(
        identifier: "com.apple.eloquence.en-US.Eddy",
        name: "Eddy", language: "en-US", tier: .basic)
    private let avaPremium = VoiceOption(
        identifier: "com.apple.voice.premium.en-US.Ava",
        name: "Ava", language: "en-US", tier: .premium)
    private let evanEnhanced = VoiceOption(
        identifier: "com.apple.voice.enhanced.en-US.Evan",
        name: "Evan", language: "en-US", tier: .enhanced)
    private let danielGB = VoiceOption(
        identifier: "com.apple.voice.super-compact.en-GB.Daniel",
        name: "Daniel", language: "en-GB", tier: .basic)
    private let sereneGBEnhanced = VoiceOption(
        identifier: "com.apple.voice.enhanced.en-GB.Serena",
        name: "Serena", language: "en-GB", tier: .enhanced)
    private let annaDE = VoiceOption(
        identifier: "com.apple.voice.compact.de-DE.Anna",
        name: "Anna", language: "de-DE", tier: .basic)

    private var stockMac: [VoiceOption] {
        [samanthaCompact, badNews, zarvox, eddyEloquence, danielGB, annaDE]
    }

    // MARK: - Classification

    func testNoveltyAndFormantVoicesAreClassified() {
        XCTAssertTrue(badNews.isNovelty)
        XCTAssertTrue(zarvox.isNovelty)
        XCTAssertFalse(badNews.isAutoSelectable)

        XCTAssertTrue(eddyEloquence.isLegacyFormant)
        XCTAssertFalse(eddyEloquence.isAutoSelectable)

        XCTAssertFalse(samanthaCompact.isNovelty)
        XCTAssertFalse(samanthaCompact.isLegacyFormant)
        XCTAssertTrue(samanthaCompact.isAutoSelectable)
        XCTAssertTrue(avaPremium.isAutoSelectable)
    }

    func testTierOrdering() {
        XCTAssertTrue(VoiceTier.premium > .enhanced)
        XCTAssertTrue(VoiceTier.enhanced > .basic)
    }

    // MARK: - Auto-selection

    func testStockMacPicksTheRealVoiceNotANoveltyOne() {
        // The bug this policy exists to prevent: "pick any en-US voice" could
        // land on Bad News or Zarvox, which are alphabetically ahead.
        let pick = VoiceSelector.best(from: stockMac, language: "en-US", preferred: nil)
        XCTAssertEqual(pick, samanthaCompact)
    }

    func testPremiumBeatsEnhancedBeatsCompact() {
        let all = stockMac + [evanEnhanced, avaPremium]
        XCTAssertEqual(VoiceSelector.best(from: all, language: "en-US", preferred: nil), avaPremium)

        let withoutPremium = stockMac + [evanEnhanced]
        XCTAssertEqual(VoiceSelector.best(from: withoutPremium, language: "en-US", preferred: nil),
                       evanEnhanced)
    }

    func testExplicitChoiceWinsIncludingNovelty() {
        let all = stockMac + [avaPremium]
        // A user who deliberately picks Zarvox gets Zarvox.
        XCTAssertEqual(VoiceSelector.best(from: all, language: "en-US",
                                          preferred: zarvox.identifier), zarvox)
        // Empty string means auto, not "no voice".
        XCTAssertEqual(VoiceSelector.best(from: all, language: "en-US", preferred: ""), avaPremium)
    }

    func testUninstalledPreferredVoiceFallsBackToAuto() {
        // The voice was uninstalled since it was chosen — degrade, don't break.
        let pick = VoiceSelector.best(from: stockMac, language: "en-US",
                                      preferred: "com.apple.voice.premium.en-US.Ava")
        XCTAssertEqual(pick, samanthaCompact)
    }

    func testFallsBackToSameBaseLanguageWhenRegionMissing() {
        // en-US requested, only en-GB installed → use the GB voice rather than
        // silently speaking German.
        let all = [danielGB, sereneGBEnhanced, annaDE]
        XCTAssertEqual(VoiceSelector.best(from: all, language: "en-US", preferred: nil),
                       sereneGBEnhanced)
    }

    func testExactRegionPreferredOverOtherRegionEvenAtLowerTier() {
        // A user set to en-US should hear en-US, not a better-tier en-GB voice.
        let all = [samanthaCompact, sereneGBEnhanced]
        XCTAssertEqual(VoiceSelector.best(from: all, language: "en-US", preferred: nil),
                       samanthaCompact)
    }

    func testNoVoicesYieldsNil() {
        XCTAssertNil(VoiceSelector.best(from: [], language: "en-US", preferred: nil))
        // Only novelty voices installed is still "nothing auto-selectable".
        XCTAssertNil(VoiceSelector.best(from: [badNews, zarvox], language: "en-US", preferred: nil))
    }

    // MARK: - Picker ordering

    func testOptionsPutRealVoicesFirstAndOddballsLast() {
        let all = stockMac + [avaPremium, evanEnhanced]
        let ordered = VoiceSelector.options(from: all, language: "en-US")
        XCTAssertEqual(ordered.map(\.name), ["Ava", "Evan", "Samantha", "Bad News", "Eddy", "Zarvox"])
        // Every auto-selectable voice precedes every oddball.
        let firstOddball = ordered.firstIndex { !$0.isAutoSelectable } ?? ordered.count
        XCTAssertTrue(ordered.prefix(firstOddball).allSatisfy(\.isAutoSelectable))
        XCTAssertTrue(ordered.dropFirst(firstOddball).allSatisfy { !$0.isAutoSelectable })
        // Other languages are not offered.
        XCTAssertFalse(ordered.contains(annaDE))
    }

    // MARK: - Download hint

    func testDownloadHintFiresOnAStockMacOnly() {
        // Zero Enhanced/Premium installed → suggest a download.
        XCTAssertFalse(VoiceSelector.hasBetterTierAvailable(than: .basic, from: stockMac,
                                                            language: "en-US"))
        // One installed → no hint.
        XCTAssertTrue(VoiceSelector.hasBetterTierAvailable(than: .basic,
                                                           from: stockMac + [evanEnhanced],
                                                           language: "en-US"))
        // An Enhanced voice doesn't count as "better than Enhanced".
        XCTAssertFalse(VoiceSelector.hasBetterTierAvailable(than: .enhanced,
                                                            from: stockMac + [evanEnhanced],
                                                            language: "en-US"))
        XCTAssertTrue(VoiceSelector.hasBetterTierAvailable(than: .enhanced,
                                                           from: stockMac + [avaPremium],
                                                           language: "en-US"))
        // A novelty voice at a high tier (hypothetical) must not satisfy it.
        let noveltyPremium = VoiceOption(identifier: "com.apple.speech.synthesis.voice.Fake",
                                         name: "Fake", language: "en-US", tier: .premium)
        XCTAssertFalse(VoiceSelector.hasBetterTierAvailable(than: .basic,
                                                            from: [samanthaCompact, noveltyPremium],
                                                            language: "en-US"))
    }
}
