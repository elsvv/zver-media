import Foundation

/// Детерминированный вывод `albumId` / имени папки альбома.
///
/// Часть протокола синка: обе стороны (Mac и iPhone) должны вывести один и тот
/// же `albumId` из одних метаданных, чтобы перезаливка обновляла альбом на месте
/// (`Documents/Library/<albumId>/...`), а не плодила дубли. Чистая, без
/// сторонних эффектов.
public enum AlbumIdentity {
    /// Символы, небезопасные для имени файла/папки на iOS/macOS:
    /// `/` (разделитель пути), `:` (исторический разделитель HFS, до сих пор
    /// перекодируется Finder'ом в `/`). Управляющие символы вырезаются отдельно.
    private static let unsafeCharacters = CharacterSet(charactersIn: "/:")

    /// Строит детерминированное имя папки/`albumId` вида
    /// `"<artist> - <title> (<year>)"`.
    ///
    /// - `artist` nil или пустой (после тримминга) → префикс `"<artist> - "`
    ///   опускается.
    /// - `year` nil → `" (<year>)"` опускается.
    /// - Небезопасные для ФС символы и управляющие символы заменяются/вырезаются,
    ///   повторные пробелы схлопываются, края обрезаются.
    /// - Гарантированно непустой результат (фоллбэк `"Unknown Album"`), чтобы
    ///   путь альбома всегда был валиден.
    public static func folderName(artist: String?, title: String, year: Int?) -> String {
        let cleanTitle = sanitize(title)
        let cleanArtist = artist.map(sanitize).flatMap { $0.isEmpty ? nil : $0 }

        var result = ""
        if let artist = cleanArtist {
            result = "\(artist) - "
        }
        result += cleanTitle
        if let year {
            result += " (\(year))"
        }

        let trimmed = result.trimmingCharacters(in: .whitespaces)
        // "." и ".." — валидные имена ФС, но как сегмент пути их режет HTTPRouter
        // (traversal), и файлы такого альбома 404-ят навсегда. Откатываемся к фоллбэку.
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
            return "Unknown Album"
        }
        return trimmed
    }

    /// Вырезает управляющие символы, заменяет небезопасные для ФС символы на
    /// пробел, схлопывает повторные пробелы и обрезает края.
    private static func sanitize(_ raw: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar) {
                // Управляющие/переводы строк — вырезаем полностью.
                continue
            }
            if unsafeCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let replaced = String(scalars)
        let collapsed = replaced
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
