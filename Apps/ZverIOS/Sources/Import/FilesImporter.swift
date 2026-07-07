import Foundation
import ZverImport

/// Тонкий адаптер источника «Из файлов» (`fileImporter` вкладки «Импорт»). Берёт
/// выбранные пользователем URL (из «Файлов»/iCloud они приходят security-scoped),
/// делает staging-копии в tmp и отдаёт их ядру `AlbumImporter.importPicked`. Вся
/// логика маршрутизации (zip → архив, остальное → россыпь) и раскладки живёт в пакете
/// `ZverImport`; здесь только мост «выбранные файлы → библиотека».
///
/// `nonisolated` (async статик enum): вызывается с MainActor через `await`, но тяжёлая
/// работа (доступ к файлам, копирование, распаковка, чтение тегов, перенос) идёт вне
/// главного потока — Swift не наследует актор вызывающего для nonisolated async.
enum FilesImporter {
    /// Импортирует выбранные файлы. Возвращает список разложенных альбомов (пустой —
    /// если импортировать было нечего). Бросает на ошибке доступа/копии/распаковки;
    /// staging при этом подчищается.
    static func importPicked(_ urls: [URL], libraryRoot: URL) async throws -> [ImportResult] {
        guard !urls.isEmpty else { return [] }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("files-in-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let staged: [URL]
        do {
            staged = try stage(urls, into: staging)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }

        let importer = AlbumImporter(libraryRoot: libraryRoot)
        do {
            let results = try await importer.importPicked(staged)
            // staging пуст после переезда — убираем каркас подпапок.
            try? FileManager.default.removeItem(at: staging)
            return results
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Копирует каждый выбранный файл в staging. Zip-архивы — каждый в свою подпапку
    /// (чтобы сохранить имя для фоллбэка альбома и развести одинаковые имена разных
    /// архивов); остальное — в общую папку `loose/` (россыпь группируется по тегам
    /// одним пакетом), коллизии имён разводятся индексом. Исходники (в «Файлах»/iCloud)
    /// не трогаем — импортер удаляет ИМЕННО staging-копии по успеху.
    private static func stage(_ urls: [URL], into staging: URL) throws -> [URL] {
        let fm = FileManager.default
        let loose = staging.appendingPathComponent("loose", isDirectory: true)
        var staged: [URL] = []
        var zipIndex = 0
        for url in urls {
            // In-place файлы из «Файлов»/iCloud приходят security-scoped; из нашей
            // песочницы — scope не нужен (вызов просто вернёт false).
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let dest: URL
            if url.pathExtension.lowercased() == "zip" {
                let sub = staging.appendingPathComponent("z\(zipIndex)", isDirectory: true)
                zipIndex += 1
                try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                dest = sub.appendingPathComponent(url.lastPathComponent)
            } else {
                try fm.createDirectory(at: loose, withIntermediateDirectories: true)
                dest = uniqueDestination(for: url.lastPathComponent, in: loose)
            }
            try fm.copyItem(at: url, to: dest)
            staged.append(dest)
        }
        return staged
    }

    /// Свободное имя в папке: при коллизии добавляет индекс-префикс.
    private static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var i = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(i)-\(name)")
            i += 1
        }
        return candidate
    }
}
