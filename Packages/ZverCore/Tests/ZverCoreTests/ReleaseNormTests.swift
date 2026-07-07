import Testing
@testable import ZverCore

@Suite struct ReleaseNormTests {

    // MARK: - Регистр, пробелы

    @Test func lowercasesAndTrims() {
        #expect(ReleaseNorm.key(artist: "  Radiohead ", album: " OK Computer ")
                == "radiohead|ok computer")
    }

    @Test func collapsesInnerWhitespace() {
        #expect(ReleaseNorm.key(artist: "The  Cure", album: "Wish   Tour")
                == "the cure|wish tour")
    }

    @Test func lowercasesCyrillic() {
        #expect(ReleaseNorm.key(artist: "Аня", album: "Аврора") == "аня|аврора")
    }

    // MARK: - Диакритика

    @Test func stripsDiacritics() {
        #expect(ReleaseNorm.key(artist: "Björk", album: "Homogénic") == "bjork|homogenic")
        #expect(ReleaseNorm.key(artist: "Motörhead", album: "Ace of Spades")
                == ReleaseNorm.key(artist: "Motorhead", album: "Ace of Spades"))
        #expect(ReleaseNorm.key(artist: "Sigur Rós", album: "Takk")
                == ReleaseNorm.key(artist: "Sigur Ros", album: "Takk"))
    }

    // MARK: - Пунктуация

    @Test func removesPunctuationWithoutTrace() {
        // Точки внутри аббревиатур схлопываются в слитное слово — так
        // «R.E.M.» и «REM» дают один ключ.
        #expect(ReleaseNorm.key(artist: "R.E.M.", album: "Up")
                == ReleaseNorm.key(artist: "REM", album: "Up"))
        #expect(ReleaseNorm.key(artist: "AC/DC", album: "Back in Black")
                == ReleaseNorm.key(artist: "ACDC", album: "Back in Black"))
        #expect(ReleaseNorm.key(artist: "The Beatles",
                                album: "Sgt. Pepper's Lonely Hearts Club Band")
                == "the beatles|sgt peppers lonely hearts club band")
    }

    @Test func punctuationBetweenWordsKeepsWordBoundary() {
        // Скобки/дефисы, окружённые пробелами, не склеивают соседние слова.
        #expect(ReleaseNorm.key(artist: "Nine Inch Nails", album: "The Downward - Spiral")
                == "nine inch nails|the downward spiral")
    }

    // MARK: - Издательские хвосты

    @Test func stripsDeluxeEditionTail() {
        #expect(ReleaseNorm.key(artist: "Radiohead", album: "OK Computer (Deluxe Edition)")
                == ReleaseNorm.key(artist: "Radiohead", album: "OK Computer"))
    }

    @Test func stripsRemasterVariants() {
        #expect(ReleaseNorm.key(artist: "Radiohead", album: "In Rainbows [Remastered]")
                == "radiohead|in rainbows")
        #expect(ReleaseNorm.key(artist: "Radiohead", album: "In Rainbows (Remaster)")
                == "radiohead|in rainbows")
    }

    @Test func stripsStackedTailWords() {
        #expect(ReleaseNorm.key(artist: "X", album: "Album Anniversary Expanded Edition")
                == "x|album")
        #expect(ReleaseNorm.key(artist: "X", album: "Album (Bonus Reissue)") == "x|album")
    }

    @Test func keepsAlbumThatIsOnlyATailWord() {
        // Альбом, целиком состоящий из «хвостового» слова, — легитимное название.
        #expect(ReleaseNorm.key(artist: "Brockhampton", album: "Deluxe")
                == "brockhampton|deluxe")
    }

    @Test func keepsTailWordInsideTitle() {
        // Хвост срезается только с конца — в середине названия слово живёт.
        #expect(ReleaseNorm.key(artist: "X", album: "Bonus Round Time")
                == "x|bonus round time")
    }

    @Test func doesNotStripTailsFromArtist() {
        #expect(ReleaseNorm.key(artist: "Edition", album: "Songs") == "edition|songs")
    }

    // MARK: - Граница артист/альбом

    @Test func artistAlbumBoundaryIsUnambiguous() {
        #expect(ReleaseNorm.key(artist: "ab", album: "c")
                != ReleaseNorm.key(artist: "a", album: "bc"))
    }
}
