import Foundation

/// Общие для трёх адаптеров «мозга» помощники разбора HTTP-ответа.
///
/// Статусы, диагностический срез тела, транспортное описание и выбор таймаута
/// вынесены сюда, чтобы chat/completions, responses и messages трактовали ошибки
/// ОДИНАКОВО (401/403 → unauthorized, 429 → rateLimited, прочее не-2xx →
/// badResponse), а не расходились по мелочам. Только тела методов ссылаются на
/// `BrainHTTP` — в публичных сигнатурах его нет.
enum BrainHTTP {
    /// Максимум символов тела/причины в ``BrainError/badResponse(_:)`` —
    /// чтобы ошибка оставалась читаемой, а не тащила килобайты HTML.
    static let snippetLimit = 500

    /// Обычный таймаут одного запроса. Генерация ленты у медленных моделей —
    /// десятки секунд; берём с запасом, но конечный.
    static let requestTimeout: TimeInterval = 120

    /// Удлинённый таймаут: reasoning/thinking ощутимо замедляют ответ.
    static let reasoningTimeout: TimeInterval = 300

    /// Таймаут под конфиг: reasoning ≠ off → длинный.
    static func timeout(for reasoning: BrainReasoning) -> TimeInterval {
        reasoning == .off ? requestTimeout : reasoningTimeout
    }

    /// Единая трактовка статуса. 2xx → ок (return); 401/403 → unauthorized;
    /// 429 → rateLimited; прочее → badResponse с обрезанным телом.
    static func checkStatus(_ http: HTTPURLResponse, data: Data) throws {
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw BrainError.unauthorized
        case 429:
            throw BrainError.rateLimited
        default:
            throw BrainError.badResponse("HTTP \(http.statusCode): \(snippet(from: data))")
        }
    }

    /// Короткий человекочитаемый фрагмент тела ответа для ошибки.
    static func snippet(from data: Data) -> String {
        guard !data.isEmpty else { return "(пустое тело)" }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count <= snippetLimit { return text }
        return String(text.prefix(snippetLimit)) + "…"
    }

    /// Описание транспортной ошибки без утечки внутренних типов в API.
    static func describe(_ error: any Error) -> String {
        if let urlError = error as? URLError {
            return "URLError(\(urlError.code.rawValue))"
        }
        return String(describing: error)
    }
}
