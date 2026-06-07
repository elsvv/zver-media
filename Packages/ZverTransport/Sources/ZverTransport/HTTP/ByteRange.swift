import Foundation

/// Чистый резолвер HTTP-заголовка `Range` для возобновляемой раздачи файлов.
///
/// Поддерживает одиночные формы (RFC 7233): `bytes=start-end`, `bytes=start-`
/// (открытый конец) и `bytes=-suffix` (последние N байт). Границы клампятся к
/// размеру файла. Битый/пустой заголовок — мягкий фоллбэк к `.full` (отдаём весь
/// файл, 200 OK). Запрос полностью вне границ — `.unsatisfiable` (416). Множественные
/// диапазоны не поддерживаются → `.full`.
public enum ByteRange {
    /// Результат разбора.
    public enum RangeResult: Equatable, Sendable {
        /// Весь файл целиком (200 OK). Также мягкий фоллбэк для невалидного Range.
        case full
        /// Часть файла, включительный диапазон `[start, end]` (206 Partial Content).
        case partial(start: Int, end: Int)
        /// Запрошенный диапазон вне файла — 416 Range Not Satisfiable.
        case unsatisfiable
    }

    /// Разбирает заголовок `Range` относительно размера файла.
    ///
    /// - Parameters:
    ///   - header: значение заголовка `Range` (или nil, если его нет).
    ///   - fileSize: размер файла в байтах.
    /// - Returns: `.full` / `.partial(start,end)` / `.unsatisfiable`.
    public static func parse(header: String?, fileSize: Int) -> RangeResult {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return .full
        }

        // Должно начинаться с "bytes=".
        let lower = raw.lowercased()
        guard lower.hasPrefix("bytes=") else {
            return .full
        }
        let spec = raw.dropFirst("bytes=".count).trimmingCharacters(in: .whitespaces)

        // Множественные диапазоны (через запятую) не поддерживаем → весь файл.
        guard !spec.contains(",") else {
            return .full
        }

        // Ровно один дефис-разделитель: "start-end" / "start-" / "-suffix".
        guard let dashIndex = spec.firstIndex(of: "-") else {
            return .full
        }
        let startStr = spec[spec.startIndex..<dashIndex].trimmingCharacters(in: .whitespaces)
        let endStr = spec[spec.index(after: dashIndex)...].trimmingCharacters(in: .whitespaces)

        // Пустой файл: любой диапазон неудовлетворим.
        if fileSize <= 0 {
            // Но совсем мусорный заголовок мы уже отсеяли выше; здесь spec валиден по форме.
            // bytes=...- на пустом файле → 416.
            // Отличаем форму от мусора: хотя бы одна сторона должна быть числом.
            if startStr.isEmpty && endStr.isEmpty {
                return .full
            }
            // Проверим, что присутствующие части — числа; иначе full.
            if !startStr.isEmpty && Int(startStr) == nil { return .full }
            if !endStr.isEmpty && Int(endStr) == nil { return .full }
            return .unsatisfiable
        }

        let lastIndex = fileSize - 1

        switch (startStr.isEmpty, endStr.isEmpty) {
        case (true, true):
            // "bytes=-" — обе стороны пусты → мусор.
            return .full

        case (true, false):
            // Суффикс: "bytes=-N" — последние N байт.
            guard let suffix = Int(endStr) else { return .full }
            if suffix <= 0 {
                // Ноль/отрицательный суффикс — нечего отдавать.
                return .unsatisfiable
            }
            let clampedSuffix = min(suffix, fileSize)
            let start = fileSize - clampedSuffix
            return .partial(start: start, end: lastIndex)

        case (false, true):
            // Открытый конец: "bytes=N-" — от N до конца файла.
            guard let start = Int(startStr) else { return .full }
            if start < 0 { return .full }
            if start > lastIndex {
                // Первый запрошенный байт за пределами файла → 416.
                return .unsatisfiable
            }
            return .partial(start: start, end: lastIndex)

        case (false, false):
            // Закрытый: "bytes=A-B".
            guard let start = Int(startStr), let endRaw = Int(endStr) else { return .full }
            if start < 0 || endRaw < 0 { return .full }
            if start > endRaw {
                // start > end — невалидный диапазон, мягкий фоллбэк.
                return .full
            }
            if start > lastIndex {
                // Полностью за пределами файла → 416.
                return .unsatisfiable
            }
            let end = min(endRaw, lastIndex)
            return .partial(start: start, end: end)
        }
    }
}
