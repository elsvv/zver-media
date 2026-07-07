import Foundation

/// Чистая логика перехвата скачиваний из webview-источника (Bandcamp): решает, по
/// какому ответу навигации форсить скачивание, и приводит имя файла назначения к
/// безопасному виду. Без WebKit — только `Bool`/`String`, чтобы покрыть тестами;
/// адаптер (`WebDownloadCenter`/`BandcampWebView` в приложении) лишь прокидывает
/// сюда `WKNavigationResponse.canShowMIMEType`, `response.mimeType` и
/// `suggestedFilename`.
public enum WebDownloadPolicy {

    /// Перехватывать ли ответ навигации как скачивание.
    ///
    /// Качаем, если:
    /// - WebKit не умеет показать MIME (`!canShowMIMEType`) — zip/октет-стрим/прочие
    ///   файлы, которые иначе просто сорвали бы навигацию;
    /// - либо это наш целевой тип — `application/zip` или любое `audio/*` — даже если
    ///   WebKit взялся бы отрисовать/проиграть его inline: нам нужен файл в
    ///   библиотеку, а не превью в браузере.
    ///
    /// MIME сравниваем без учёта регистра и отбрасываем параметры после `;`
    /// (`audio/flac; charset=binary`).
    public static func shouldDownload(canShowMIMEType: Bool, mimeType: String?) -> Bool {
        if !canShowMIMEType { return true }
        guard let base = normalizedMIME(mimeType) else { return false }
        if base == "application/zip" { return true }
        if base.hasPrefix("audio/") { return true }
        return false
    }

    /// Безопасное имя файла назначения из `suggestedFilename` скачивания.
    ///
    /// `suggestedFilename` контролирует сервер, поэтому берём только последний
    /// компонент пути (режет `../` и подпапки), триммим пробелы и заменяем пустое /
    /// `.` / `..` на `fallback`. Оставшиеся разделители заменяем на `_`.
    public static func sanitizedFilename(_ suggested: String, fallback: String = "download") -> String {
        let last = (suggested as NSString).lastPathComponent
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "." || trimmed == ".." { return fallback }
        return trimmed.replacingOccurrences(of: "/", with: "_")
    }

    /// MIME без параметров, в нижнем регистре; nil/пустой → nil.
    private static func normalizedMIME(_ mimeType: String?) -> String? {
        guard let mime = mimeType?.lowercased() else { return nil }
        let base = mime.split(separator: ";", maxSplits: 1).first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? mime
        return base.isEmpty ? nil : base
    }
}
