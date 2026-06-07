import Foundation
import CryptoKit

/// SHA-256 хелпер протокола синка.
///
/// Хеш контента используется как идентичность файла: обе стороны (Mac и iPhone)
/// сверяют `sha256` чанков/файлов, чтобы не перезаливать уже синхронизированное.
/// Для hi-res файлов (сотни МБ) хеширование с диска идёт потоково через
/// `FileHandle`, без загрузки всего файла в память.
public enum Sha256 {
    /// Размер чанка для потокового чтения файла — 1 МБ.
    private static let chunkSize = 1 * 1024 * 1024

    /// SHA-256 от данных в памяти. Возвращает hex в нижнем регистре (64 символа).
    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).hexString
    }

    /// SHA-256 файла, прочитанного потоково чанками по 1 МБ.
    ///
    /// Не загружает файл целиком в память — пригоден для сотен МБ. Файл
    /// гарантированно закрывается (в т.ч. при ошибке чтения). Бросает, если файл
    /// недоступен/не существует.
    public static func hash(fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }
}

private extension SHA256Digest {
    /// Hex-представление дайджеста в нижнем регистре.
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
