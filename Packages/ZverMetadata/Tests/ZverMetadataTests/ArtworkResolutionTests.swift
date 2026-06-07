import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import ZverMetadata

/// Доработка этапа 3 — умное определение обложки из папки:
/// расширенный список имён + фоллбэк на самую крупную картинку.
@Suite struct ArtworkResolutionTests {
    /// Временная папка с `notags.flac` (без тега и без встроенной обложки),
    /// сканируется напрямую — обложка ищется в этой же папке.
    private func albumRoot() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture("notags.flac"), to: dir.appendingPathComponent("notags.flac"))
        return dir
    }

    /// Пишет настоящий PNG заданного разрешения (для проверки фоллбэка по размеру).
    private func writePNG(_ url: URL, width: Int, height: Int) throws {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, "public.png" as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func jpegBytes() -> Data { Data([0xFF, 0xD8, 0xFF]) }

    @Test func extendedNameRecognizedCaseInsensitively() async throws {
        // «artwork» — новое имя из расширенного списка, регистр не важен.
        let dir = try albumRoot()
        try jpegBytes().write(to: dir.appendingPathComponent("ARTWORK.JPG"))

        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "ARTWORK.JPG")
    }

    @Test func multiWordFrontCoverNameWinsOverBiggerUnnamed() async throws {
        // «front cover» (с пробелом) распознаётся по имени и побеждает более
        // крупную, но безымянную картинку (приоритет имени над размером).
        let dir = try albumRoot()
        try writePNG(dir.appendingPathComponent("zzz_big.png"), width: 500, height: 500)
        try jpegBytes().write(to: dir.appendingPathComponent("front cover.jpg"))

        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "front cover.jpg")
    }

    @Test func webpArtworkRecognizedByName() async throws {
        // .webp — новое расширение.
        let dir = try albumRoot()
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: dir.appendingPathComponent("cover.webp"))

        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "cover.webp")
    }

    @Test func largestImageChosenWhenNoNamedCover() async throws {
        // Узнаваемых имён нет → берём самую крупную по разрешению.
        let dir = try albumRoot()
        try writePNG(dir.appendingPathComponent("page01.png"), width: 64, height: 64)
        try writePNG(dir.appendingPathComponent("page02.png"), width: 300, height: 300)

        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "page02.png")
    }

    @Test func equalSizeImagesTieBreakAlphabetically() async throws {
        // Равное разрешение → детерминированный тай-брейк: алфавитно первая.
        let dir = try albumRoot()
        try writePNG(dir.appendingPathComponent("zzz.png"), width: 128, height: 128)
        try writePNG(dir.appendingPathComponent("aaa.png"), width: 128, height: 128)

        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL?.lastPathComponent == "aaa.png")
    }

    @Test func noImagesYieldsNilArtwork() async throws {
        let dir = try albumRoot()
        let infos = try await LibraryScanner.scan(directory: dir)
        #expect(infos.first?.artworkFileURL == nil)
    }
}
