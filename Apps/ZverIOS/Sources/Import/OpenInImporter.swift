import Foundation
import ZverImport

/// Тонкий адаптер системного «Открыть в Zver Media»: берёт URL из `.onOpenURL`
/// (Safari/Files/AirDrop/почта), делает security-scoped копию в staging (tmp) и
/// отдаёт её ядру `AlbumImporter`. Вся чистая логика раскладки — в пакете
/// `ZverImport`; здесь только мост «внешний файл → библиотека».
///
/// `nonisolated` (async статик enum): вызывается с MainActor через `await`, но
/// тяжёлая работа (копирование, распаковка, чтение тегов, перенос файлов) идёт
/// вне главного потока — Swift не наследует актор вызывающего для nonisolated
/// async-функции.
enum OpenInImporter {
    /// Импортирует открытый файл. `zip` → альбом(ы) архива, иначе — как россыпь из
    /// одного файла (одиночный flac/audio). Возвращает список разложенных альбомов
    /// (пустой — если импортировать было нечего). Бросает на ошибке доступа/копии/
    /// распаковки; staging при этом подчищается.
    static func importOpened(_ url: URL, libraryRoot: URL) async throws -> [ImportResult] {
        // In-place файлы (Files/iCloud) приходят security-scoped; из Inbox/tmp —
        // scope не нужен (наша песочница), вызов просто вернёт false.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("open-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        // Копия: исходник в Files/iCloud НЕ трогаем — импортер удаляет ИМЕННО
        // staging-копию по успеху (у архива — распакованное; у россыпи — сам файл).
        let staged = staging.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: url, to: staged)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        let importer = AlbumImporter(libraryRoot: libraryRoot)
        let results: [ImportResult]
        do {
            if url.pathExtension.lowercased() == "zip" {
                results = try await importer.importArchive(staged)
            } else {
                results = try await importer.importFiles([staged])
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        // Staging (пустой после переезда) и, если файл пришёл в системный Inbox, —
        // исходник тоже (иначе Inbox копит уже импортированное сырьё).
        try? FileManager.default.removeItem(at: staging)
        removeIfInInbox(url)
        return results
    }

    /// Удаляет исходник, только если он лежит в `Documents/Inbox` (системная копия
    /// «Скопировать в Zver» / AirDrop, которую скан библиотеки и так пропускает).
    /// In-place файлы из Files/iCloud НЕ трогаем — они не наши.
    private static func removeIfInInbox(_ url: URL) {
        let inbox = URL.documentsDirectory
            .appendingPathComponent("Inbox", isDirectory: true)
            .standardizedFileURL.path
        if url.standardizedFileURL.path.hasPrefix(inbox + "/") {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
