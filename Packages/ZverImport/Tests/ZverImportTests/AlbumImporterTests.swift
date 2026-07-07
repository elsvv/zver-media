import Testing
import Foundation
import ZIPFoundation
@testable import ZverImport

/// Тесты `AlbumImporter` на настоящих аудио-фикстурах — теги читает `MetadataReader`
/// (AVFoundation), поэтому нужны реальные FLAC/m4a, а не байтовый мусор. Берём их из
/// соседнего пакета `ZverMetadata` (собраны `scripts/make-fixtures.sh`), не тащим
/// бинарники повторно. Zip-архивы под сценарии собираем на лету через ZIPFoundation.
@Suite struct AlbumImporterTests {

    // MARK: - Фикстуры и песочница

    /// Путь к фикстурам `ZverMetadata` от исходника теста (`#filePath` — абсолютный на
    /// момент компиляции). Так «берём из Packages/ZverMetadata/.../Fixtures/» буквально.
    private func fixture(_ name: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()   // ZverImportTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ZverImport
            .deletingLastPathComponent()   // Packages
            .appending(path: "ZverMetadata/Tests/ZverMetadataTests/Fixtures/\(name)")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixture(name))
    }

    /// Уникальная песочница на тест в системном tmp (тот же том, что использует
    /// экстрактор/импортер по умолчанию — move остаётся дешёвым и атомарным).
    private func makeSandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AlbumImporterTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Копирует фикстуру в `dir` под именем `as` и возвращает URL копии (для
    /// `importFiles`: импортер переносит источник, оригинал-фикстуру трогать нельзя).
    @discardableResult
    private func copyFixture(_ name: String, to dir: URL, as newName: String) throws -> URL {
        let dest = dir.appendingPathComponent(newName)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture(name), to: dest)
        return dest
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func exists(_ folder: URL, _ relPath: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(relPath).path)
    }

    private func childCount(_ dir: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }

    private let coverJPEG = Data([0xFF, 0xD8, 0xFF, 0xE0]) // сигнатура JPEG

    // MARK: - importArchive: нормальный альбом

    @Test func importArchivePlacesAlbumFromTagsStrippingWrapper() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let zip = sandbox.appendingPathComponent("album.zip")
        // Обе дорожки — ARTIST=Зверь, ALBUM=Фикстуры; у tagged есть DATE=2024.
        try makeArchive(at: zip, files: [
            ("Зверь - Фикстуры/01 tagged.flac", try fixtureData("tagged_16_44.flac")),
            ("Зверь - Фикстуры/02 hires.flac", try fixtureData("hires_24_96.flac")),
            ("Зверь - Фикстуры/cover.jpg", coverJPEG),
        ])

        let results = try await AlbumImporter(libraryRoot: library).importArchive(zip)

        #expect(results.count == 1)
        let r = try #require(results.first)
        #expect(r.artist == "Зверь")
        #expect(r.album == "Фикстуры")
        #expect(r.trackCount == 2)
        // Имя папки — из AlbumIdentity (год из тега), НЕ имя папки-обёртки архива.
        #expect(r.albumFolder.lastPathComponent == "Зверь - Фикстуры (2024)")

        let folder = library.appendingPathComponent("Зверь - Фикстуры (2024)")
        #expect(exists(folder, "01 tagged.flac"))
        #expect(exists(folder, "02 hires.flac"))
        #expect(exists(folder, "cover.jpg"))
        // Источник удалён после успеха.
        #expect(!exists(zip))
    }

    // MARK: - importArchive: multi-disc, поддиректории сохраняются

    @Test func importArchivePreservesDiscSubfolders() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let zip = sandbox.appendingPathComponent("multidisc.zip")
        try makeArchive(at: zip, files: [
            ("Бокс-сет/CD1/01.flac", try fixtureData("tagged_16_44.flac")),
            ("Бокс-сет/CD2/01.flac", try fixtureData("multidisc_disc2.flac")),
            ("Бокс-сет/cover.jpg", coverJPEG),
        ])

        let results = try await AlbumImporter(libraryRoot: library).importArchive(zip)

        #expect(results.count == 1)
        #expect(results.first?.trackCount == 2)
        let folder = library.appendingPathComponent("Зверь - Фикстуры (2024)")
        // Подпапки-диски сохранены, обложка из корня альбома — рядом.
        #expect(exists(folder, "CD1/01.flac"))
        #expect(exists(folder, "CD2/01.flac"))
        #expect(exists(folder, "cover.jpg"))
    }

    // MARK: - importArchive: фоллбэк имени альбома

    @Test func importArchiveFallsBackToRootFolderNameWhenNoAlbumTag() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let zip = sandbox.appendingPathComponent("noalbum.zip")
        // notags.flac — без тегов ALBUM/ARTIST; обёртка задаёт имя альбома.
        try makeArchive(at: zip, files: [
            ("Артист - Безымянный/song.flac", try fixtureData("notags.flac")),
        ])

        let results = try await AlbumImporter(libraryRoot: library).importArchive(zip)

        #expect(results.count == 1)
        let r = try #require(results.first)
        #expect(r.artist == nil)
        #expect(r.album == "Артист - Безымянный")
        #expect(r.albumFolder.lastPathComponent == "Артист - Безымянный")
        #expect(exists(library.appendingPathComponent("Артист - Безымянный"), "song.flac"))
    }

    @Test func importArchiveFallsBackToZipNameWhenNoWrapperFolder() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        // Имя zip в бэндкэмповском формате «Artist - Album».
        let zip = sandbox.appendingPathComponent("Группа - Демо.zip")
        try makeArchive(at: zip, files: [
            ("song.flac", try fixtureData("notags.flac")),   // файл в корне архива
        ])

        let results = try await AlbumImporter(libraryRoot: library).importArchive(zip)

        #expect(results.count == 1)
        #expect(results.first?.album == "Группа - Демо")
        #expect(exists(library.appendingPathComponent("Группа - Демо"), "song.flac"))
    }

    // MARK: - importArchive: идемпотентный повтор

    @Test func importArchiveRepeatAddsMissingKeepsExisting() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let importer = AlbumImporter(libraryRoot: library)
        let folder = library.appendingPathComponent("Зверь - Фикстуры (2024)")

        // Первый импорт: оба трека на месте.
        let zip1 = sandbox.appendingPathComponent("first.zip")
        try makeArchive(at: zip1, files: [
            ("A/01.flac", try fixtureData("tagged_16_44.flac")),
            ("A/02.flac", try fixtureData("hires_24_96.flac")),
        ])
        _ = try await importer.importArchive(zip1)
        #expect(exists(folder, "01.flac"))
        #expect(exists(folder, "02.flac"))

        // Портим существующий 01 и удаляем 02 — имитируем «докладываем недостающее».
        let sentinel = Data("НЕ ТРОГАЙ".utf8)
        try sentinel.write(to: folder.appendingPathComponent("01.flac"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("02.flac"))

        // Второй импорт того же альбома (zip пересобираем — первый удалён).
        let zip2 = sandbox.appendingPathComponent("second.zip")
        try makeArchive(at: zip2, files: [
            ("A/01.flac", try fixtureData("tagged_16_44.flac")),
            ("A/02.flac", try fixtureData("hires_24_96.flac")),
        ])
        let results = try await importer.importArchive(zip2)

        #expect(results.first?.trackCount == 2)
        // Существующий 01 не перезаписан, недостающий 02 доложен.
        #expect(try Data(contentsOf: folder.appendingPathComponent("01.flac")) == sentinel)
        #expect(exists(folder, "02.flac"))
        #expect(!exists(zip2))
    }

    // MARK: - importArchive: чистка staging и источника

    @Test func importArchiveRemovesStagingAndSource() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let staging = sandbox.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let zip = sandbox.appendingPathComponent("album.zip")
        try makeArchive(at: zip, files: [
            ("Зверь - Фикстуры/01.flac", try fixtureData("tagged_16_44.flac")),
        ])

        _ = try await AlbumImporter(libraryRoot: library, stagingBase: staging)
            .importArchive(zip)

        // Распакованная папка выехала целиком — в staging пусто, zip удалён.
        #expect(childCount(staging) == 0)
        #expect(!exists(zip))
    }

    // MARK: - importArchive: битый архив — не удаляем источник

    @Test func importArchiveThrowsOnUnreadableArchiveKeepingSource() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let garbage = sandbox.appendingPathComponent("broken.zip")
        try Data("это не zip".utf8).write(to: garbage)

        await #expect(throws: (any Error).self) {
            _ = try await AlbumImporter(libraryRoot: library).importArchive(garbage)
        }
        // Провал импорта не трогает источник и не создаёт библиотеку.
        #expect(exists(garbage))
        #expect(!exists(library))
    }

    // MARK: - importFiles: россыпь файлов

    @Test func importFilesPlacesLooseTracksFlatGroupedByTags() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let source = sandbox.appendingPathComponent("drop")
        let t1 = try copyFixture("tagged_16_44.flac", to: source, as: "one.flac")
        let t2 = try copyFixture("hires_24_96.flac", to: source, as: "two.flac")
        let cover = source.appendingPathComponent("cover.jpg")
        try coverJPEG.write(to: cover)

        let results = try await AlbumImporter(libraryRoot: library)
            .importFiles([t1, t2, cover])

        #expect(results.count == 1)
        let r = try #require(results.first)
        #expect(r.artist == "Зверь")
        #expect(r.album == "Фикстуры")
        #expect(r.trackCount == 2)

        let folder = library.appendingPathComponent("Зверь - Фикстуры (2024)")
        #expect(exists(folder, "one.flac"))
        #expect(exists(folder, "two.flac"))
        #expect(exists(folder, "cover.jpg"))
        // Источники перенесены (удалены после успеха).
        #expect(!exists(t1))
        #expect(!exists(t2))
    }

    @Test func importFilesFallsBackToParentFolderNameWhenNoAlbumTag() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let source = sandbox.appendingPathComponent("Мой Альбом")
        let track = try copyFixture("notags.flac", to: source, as: "song.flac")

        let results = try await AlbumImporter(libraryRoot: library).importFiles([track])

        #expect(results.count == 1)
        #expect(results.first?.artist == nil)
        #expect(results.first?.album == "Мой Альбом")
        #expect(exists(library.appendingPathComponent("Мой Альбом"), "song.flac"))
    }

    @Test func importFilesGroupsMultipleAlbumsIntoSeparateFolders() async throws {
        let sandbox = try makeSandbox()
        let library = sandbox.appendingPathComponent("Library")
        let source = sandbox.appendingPathComponent("Микс")
        // Один трек с тегами (свой альбом), один без — фоллбэк на папку «Микс».
        let tagged = try copyFixture("tagged_16_44.flac", to: source, as: "01.flac")
        let untagged = try copyFixture("notags.flac", to: source, as: "02.flac")

        let results = try await AlbumImporter(libraryRoot: library)
            .importFiles([tagged, untagged])

        #expect(results.count == 2)
        let albums = Set(results.map(\.album))
        #expect(albums == ["Фикстуры", "Микс"])
        #expect(exists(library.appendingPathComponent("Зверь - Фикстуры (2024)"), "01.flac"))
        #expect(exists(library.appendingPathComponent("Микс"), "02.flac"))
    }
}
