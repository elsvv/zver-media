import Testing
import Foundation
@testable import ZverMetadata

@Suite struct MetadataReaderTests {
    @Test func readsVorbisTagsFromFlac() async throws {
        let info = try await MetadataReader.read(url: fixture("tagged_16_44.flac"))
        #expect(info.title == "Тестовый трек")
        #expect(info.artist == "Зверь")
        #expect(info.album == "Фикстуры")
        #expect(info.trackNumber == 3)
        #expect(info.year == 2024)
    }
    @Test func extractsArtworkBytes() async throws {
        let info = try await MetadataReader.read(url: fixture("tagged_16_44.flac"))
        let art = try #require(info.artworkData)
        #expect(art.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) // PNG magic
    }
    @Test func untaggedFileFallsBackToFilename() async throws {
        let info = try await MetadataReader.read(url: fixture("notags.flac"))
        #expect(info.title == "notags")
        #expect(info.artist == nil)
        #expect(info.discNumber == nil)
    }
    @Test func readsDiscNumberFromFlacVorbisTag() async throws {
        // Фикстура с DISCNUMBER=2/2 (форма «диск/всего») — берём 2.
        let info = try await MetadataReader.read(url: fixture("multidisc_disc2.flac"))
        #expect(info.discNumber == 2)
        #expect(info.trackNumber == 1)
    }
    @Test func flacWithoutDiscTagHasNilDiscNumber() async throws {
        let info = try await MetadataReader.read(url: fixture("tagged_16_44.flac"))
        #expect(info.discNumber == nil)   // одно-дисковый рип без тега DISCNUMBER
    }
    @Test func readsAlacCommonMetadata() async throws {
        let info = try await MetadataReader.read(url: fixture("alac.m4a"))
        #expect(info.sampleRate == 44100)
    }
}
