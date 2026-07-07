import Foundation
import Testing
@testable import ZverCore

@Suite struct ArtistNameTests {

    // MARK: - key

    @Test func keyLowercasesAndTrims() {
        #expect(ArtistName.key("  Аня  ") == "аня")
        #expect(ArtistName.key("KANYE") == "kanye")
    }

    @Test func keyNilForMissingOrEmptyArtist() {
        #expect(ArtistName.key(nil) == nil)
        #expect(ArtistName.key("") == nil)
        #expect(ArtistName.key("   ") == nil)
    }

    @Test func keyMergesCaseVariantsOfKingGizzard() {
        // Требование: два написания "The"/"the" — один артист (один ключ).
        let a = ArtistName.key("King Gizzard & The lizard wizard")
        let b = ArtistName.key("King Gizzard & the lizard wizard")
        #expect(a == b)
        #expect(a == "king gizzard & the lizard wizard")
    }

    // MARK: - canonical

    @Test func canonicalPicksMajoritySpelling() {
        let variants = ["King Gizzard & The lizard wizard",
                        "King Gizzard & The lizard wizard",
                        "King Gizzard & the lizard wizard"]

        #expect(ArtistName.canonical(variants) == "King Gizzard & The lizard wizard")
    }

    @Test func canonicalBreaksTiesByFirstAppearance() {
        // По одному разу каждое написание — при равенстве побеждает первое.
        let variants = ["the lizard wizard", "The Lizard Wizard"]

        #expect(ArtistName.canonical(variants) == "the lizard wizard")
    }

    @Test func canonicalTrimsAndIgnoresBlanks() {
        let variants = ["  Аня  ", "", "   ", "Аня"]

        #expect(ArtistName.canonical(variants) == "Аня")
    }

    @Test func canonicalEmptyForNoVariants() {
        #expect(ArtistName.canonical([String]()) == "")
        #expect(ArtistName.canonical(["", "  "]) == "")
    }

    @Test func canonicalSingleVariant() {
        #expect(ArtistName.canonical(["Massive Attack"]) == "Massive Attack")
    }
}
