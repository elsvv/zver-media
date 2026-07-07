import Testing
import Foundation
import ZIPFoundation
@testable import ZverImport

/// Фикстуры-зипы собираем прямо здесь через ZIPFoundation — свой набор записей
/// под каждый сценарий (нормальный альбом, zip-slip, чужие расширения, лимит),
/// чтобы не тащить бинарные фикстуры в репо.
@Suite struct ZipExtractorTests {

    // MARK: - Хелперы

    /// Уникальная временная папка-песочница на каждый тест (том tmp — тот же, что
    /// использует экстрактор по умолчанию). Пустая после успешной очистки — на этом
    /// строятся проверки «источник не оставил мусора».
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZipExtractorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Собирает zip с перечисленными записями-файлами (путь → содержимое).
    private func makeArchive(at url: URL, files: [(path: String, data: Data)]) throws {
        let archive = try Archive(url: url, accessMode: .create)
        for file in files {
            try archive.addEntry(
                with: file.path, type: .file,
                uncompressedSize: Int64(file.data.count)
            ) { position, size in
                let start = Int(position)
                let end = min(file.data.count, start + size)
                return file.data.subdata(in: start..<end)
            }
        }
    }

    private func contents(_ folder: URL, _ relPath: String) -> Data? {
        try? Data(contentsOf: folder.appendingPathComponent(relPath))
    }

    private func exists(_ folder: URL, _ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relPath).path)
    }

    private func isEmptyDir(_ url: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return items.isEmpty
    }

    // MARK: - Нормальный альбом

    @Test func extractsNormalAlbumPreservingLayout() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("album.zip")
        let flac1 = Data("FLAC-один".utf8)
        let flac2 = Data("FLAC-два".utf8)
        let cover = Data([0xFF, 0xD8, 0xFF, 0xE0])   // сигнатура JPEG
        try makeArchive(at: zip, files: [
            ("Артист - Альбом/01 Трек.flac", flac1),
            ("Артист - Альбом/02 Трек.flac", flac2),
            ("Артист - Альбом/cover.jpg", cover),
        ])

        let out = try ZipExtractor.extract(zip, into: sandbox)

        // Папка вложения сохранена, содержимое побайтово совпадает.
        #expect(contents(out, "Артист - Альбом/01 Трек.flac") == flac1)
        #expect(contents(out, "Артист - Альбом/02 Трек.flac") == flac2)
        #expect(contents(out, "Артист - Альбом/cover.jpg") == cover)
        // Результат лежит внутри переданной песочницы.
        #expect(out.standardizedFileURL.path.hasPrefix(sandbox.standardizedFileURL.path + "/"))
    }

    // MARK: - zip-slip

    @Test func rejectsParentTraversalEntry() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("evil.zip")
        try makeArchive(at: zip, files: [
            ("Альбом/ok.flac", Data("ok".utf8)),
            ("../evil.txt", Data("pwned".utf8)),   // расширение .txt в списке — отклонить должен ПУТЬ
        ])

        #expect(throws: ZipExtractError.self) {
            _ = try ZipExtractor.extract(zip, into: sandbox)
        }
        // Ничего не выехало наружу и распакованная папка вычищена (в песочнице — только сам zip).
        #expect(!exists(sandbox, "evil.txt"))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) == ["evil.zip"])
    }

    @Test func rejectsAbsolutePathEntry() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("abs.zip")
        try makeArchive(at: zip, files: [
            ("/tmp/zver-evil.txt", Data("pwned".utf8)),
        ])

        #expect(throws: ZipExtractError.self) {
            _ = try ZipExtractor.extract(zip, into: sandbox)
        }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) == ["abs.zip"])
    }

    // MARK: - Белый список расширений

    @Test func skipsForeignExtensions() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("mixed.zip")
        try makeArchive(at: zip, files: [
            ("Альбом/track.flac", Data("audio".utf8)),
            ("Альбом/malware.exe", Data("MZ".utf8)),
            ("Альбом/booklet.nfo", Data("nfo".utf8)),
            ("Альбом/.DS_Store", Data("junk".utf8)),   // dot-файл без расширения
        ])

        let out = try ZipExtractor.extract(zip, into: sandbox)

        #expect(exists(out, "Альбом/track.flac"))
        #expect(!exists(out, "Альбом/malware.exe"))
        #expect(!exists(out, "Альбом/booklet.nfo"))
        #expect(!exists(out, "Альбом/.DS_Store"))
    }

    @Test func keepsWhitelistedSidecarFiles() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("sidecars.zip")
        // По одному из каждого разрешённого «сопутствующего» типа.
        let sidecars = ["cover.jpg", "back.jpeg", "art.png", "image.cue",
                        "list.m3u", "list.m3u8", "rip.log", "notes.txt"]
        try makeArchive(at: zip, files:
            [("Альбом/song.flac", Data("a".utf8))]
            + sidecars.map { ("Альбом/\($0)", Data($0.utf8)) }
        )

        let out = try ZipExtractor.extract(zip, into: sandbox)

        #expect(exists(out, "Альбом/song.flac"))
        for name in sidecars {
            #expect(exists(out, "Альбом/\(name)"))
        }
    }

    // MARK: - Лимит распакованного размера

    @Test func enforcesSizeLimitCumulatively() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("big.zip")
        // Две записи по 600 байт: первая проходит (600 ≤ 1000), вторая переваливает (1200 > 1000).
        try makeArchive(at: zip, files: [
            ("Альбом/a.flac", Data(count: 600)),
            ("Альбом/b.flac", Data(count: 600)),
        ])

        #expect(throws: ZipExtractError.sizeLimitExceeded(limit: 1000)) {
            _ = try ZipExtractor.extract(zip, into: sandbox, sizeLimit: 1000)
        }
        // Частичная распаковка вычищена.
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) == ["big.zip"])
    }

    @Test func allowsArchiveWithinSizeLimit() throws {
        let sandbox = try makeSandbox()
        let zip = sandbox.appendingPathComponent("ok.zip")
        try makeArchive(at: zip, files: [
            ("Альбом/a.flac", Data(count: 400)),
            ("Альбом/b.flac", Data(count: 400)),
        ])

        let out = try ZipExtractor.extract(zip, into: sandbox, sizeLimit: 1000)
        #expect(exists(out, "Альбом/a.flac"))
        #expect(exists(out, "Альбом/b.flac"))
    }

    // MARK: - Нечитаемый архив

    @Test func throwsOnUnreadableArchive() throws {
        let sandbox = try makeSandbox()
        let notZip = sandbox.appendingPathComponent("garbage.zip")
        try Data("это не zip, а просто мусор".utf8).write(to: notZip)

        #expect(throws: ZipExtractError.unreadableArchive) {
            _ = try ZipExtractor.extract(notZip, into: sandbox)
        }
    }
}
