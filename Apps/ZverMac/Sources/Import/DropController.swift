import Foundation
import ZverMetadata

/// Приём перетащенной папки альбома и превращение её в `AlbumDraft`.
///
/// Drag-drop папки на окно → `LibraryScanner.scan` (тот же сканер, что на
/// телефоне: единый разбор тегов и обложки) → редактируемый черновик. Скан
/// идёт вне главного потока; публикация черновика — на `@MainActor`.
///
/// `@MainActor`: владеет публикуемым состоянием для UI. Ошибки скана не роняют
/// контроллер — отражаются в `lastError`, окно остаётся живым.
@MainActor
final class DropController: ObservableObject {
    /// Текущий импортированный черновик (показывается в превью). nil — пусто.
    @Published private(set) var draft: AlbumDraft?
    /// Идёт скан перетащенной папки.
    @Published private(set) var isScanning = false
    /// Человекочитаемая ошибка последнего импорта (RU), если был сбой.
    @Published private(set) var lastError: String?

    init() {}

    /// Импортирует папку альбома: сканирует её и строит `AlbumDraft`.
    ///
    /// - Папка без аудиофайлов → `lastError`, черновик не меняется.
    /// - Недоступная/нечитаемая папка → `lastError`, не падает.
    func importFolder(_ folder: URL) async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }

        let infos: [AudioFileInfo]
        do {
            infos = try await LibraryScanner.scan(directory: folder)
        } catch {
            lastError = "Не удалось прочитать папку «\(folder.lastPathComponent)»."
            return
        }

        guard !infos.isEmpty else {
            lastError = "В папке «\(folder.lastPathComponent)» нет аудиофайлов."
            return
        }

        draft = AlbumDraft.from(folder: folder, infos: infos)
    }

    /// Сбрасывает текущий черновик (после отправки в очередь или отмены).
    func clear() {
        draft = nil
        lastError = nil
    }

    /// Извлекает URL папки из набора `NSItemProvider` (drag-drop на SwiftUI окно).
    ///
    /// Берёт первый перетащенный элемент, который указывает на директорию. Не-папки
    /// (одиночные файлы) на этапе каркаса игнорируются — импорт по папке альбома.
    static func firstFolderURL(from providers: [NSItemProvider]) async -> URL? {
        for provider in providers {
            guard let url = await loadFileURL(from: provider) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue {
                return url
            }
        }
        return nil
    }

    /// Грузит file URL из одного провайдера. Колбэк системного API — `@Sendable`,
    /// результат возвращается через `withCheckedContinuation` (не наследуем
    /// `@MainActor`-изоляцию в фоновый колбэк).
    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }
}
