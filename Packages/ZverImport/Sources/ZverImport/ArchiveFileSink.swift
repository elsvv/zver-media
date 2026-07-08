import Foundation

/// Приёмник тела HTTP-ответа на диск с поддержкой докачки по `Range`. Выделен из
/// сетевого адаптера приложения (`ArchiveDownloader`) в пакет, чтобы диспозицию по
/// статусу — 206 (дописать хвост к частичному префиксу), 200 (перезаписать файл с
/// нуля), не-2xx (не трогать частичный файл и сообщить об ошибке) — можно было
/// юнит-тестировать на временных файлах без реальной сети.
///
/// Именно раскладка префикса на диске делает Range-докачку рабочей: частичный файл
/// переживает обрыв соединения, а следующая попытка стартует с `partialSize` и просит
/// хвост заголовком `Range`. Тело стримится чанками (`write`) — hi-res FLAC это сотни
/// МБ, целиком в память не тянем.
public final class ArchiveFileSink {
    /// Ошибка загрузки: сервер вернул не-2xx (частичный файл при этом не тронут).
    public enum DownloadError: Error, Equatable {
        case http(Int)
    }

    /// Файл назначения (частичный префикс докачки лежит здесь же между попытками).
    private let destination: URL
    private var handle: FileHandle?
    /// Байт уже на диске: префикс докачки + записанный хвост (для доли прогресса).
    public private(set) var bytesOnDisk: Int64 = 0

    public init(destination: URL) {
        self.destination = destination
    }

    /// Размер уже скачанного частичного файла (0, если файла нет) — позиция докачки
    /// для заголовка `Range`.
    public static func partialSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Открывает приёмник по статусу ответа и позиции докачки:
    /// - не-2xx → бросает `DownloadError.http`, частичный файл на диске не тронут;
    /// - 206 при существующем префиксе (`resumeFrom > 0`) → дописываем хвост в конец;
    /// - 200 / новый файл → перезаписываем файл с нуля (даже если Range был проигнорирован
    ///   сервером — иначе конкатенация с префиксом испортила бы файл).
    public func open(status: Int, resumeFrom: Int64) throws {
        guard (200..<300).contains(status) else { throw DownloadError.http(status) }
        let fm = FileManager.default
        if status == 206, resumeFrom > 0, fm.fileExists(atPath: destination.path) {
            let h = try FileHandle(forWritingTo: destination)
            bytesOnDisk = Int64(try h.seekToEnd())
            handle = h
        } else {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            fm.createFile(atPath: destination.path, contents: nil)
            handle = try FileHandle(forWritingTo: destination)
            bytesOnDisk = 0
        }
    }

    /// Пишет очередную порцию тела на диск (после `open`). Обновляет `bytesOnDisk`.
    public func write(_ data: Data) throws {
        guard let handle else { return }
        try handle.write(contentsOf: data)
        bytesOnDisk += Int64(data.count)
    }

    /// Закрывает файловый хэндл (идемпотентно).
    public func close() {
        try? handle?.close()
        handle = nil
    }
}
