import Testing
import Foundation
@testable import ZverMetadata

@Suite struct LibraryScannerTests {
    @Test func findsAudioRecursivelyIgnoringJunk() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Альбом A")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))
        try fm.copyItem(at: fixture("alac.m4a"), to: tmp.appendingPathComponent("solo.m4a"))
        try Data("мусор".utf8).write(to: sub.appendingPathComponent("readme.txt"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 2)
        #expect(infos.allSatisfy { ["flac", "m4a"].contains($0.url.pathExtension) })
        #expect(infos.map(\.url.path) == infos.map(\.url.path).sorted())
    }
    @Test func emptyDirGivesEmptyResult() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let result = try await LibraryScanner.scan(directory: tmp)
        #expect(result.isEmpty)
    }
    @Test func skipsBrokenAudioFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let fm = FileManager.default
        try fm.copyItem(at: fixture("notags.flac"), to: tmp.appendingPathComponent("ok.flac"))
        try Data("не аудио, просто мусор".utf8).write(to: tmp.appendingPathComponent("broken.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.url.lastPathComponent == "ok.flac")
    }
    @Test func untaggedFileInSubfolderGetsAlbumFromFolderName() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Мой альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: sub.appendingPathComponent("notags.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == "Мой альбом")
    }
    @Test func untaggedFileInScanRootKeepsNilAlbum() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: tmp.appendingPathComponent("notags.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == nil)
    }
    @Test func taggedAlbumWinsOverFolderName() async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let sub = tmp.appendingPathComponent("Не альбом")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("tagged_16_44.flac"), to: sub.appendingPathComponent("01.flac"))

        let infos = try await LibraryScanner.scan(directory: tmp)
        #expect(infos.count == 1)
        #expect(infos.first?.album == "Фикстуры")
    }
}
