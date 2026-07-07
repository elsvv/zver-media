import Foundation

/// Одна модель из живого каталога провайдера: `id` — то, что уходит в
/// `BrainConfig.model`; `name` — человекочитаемое имя, если провайдер его
/// отдаёт (иначе показываем `id`).
public struct BrainModelSummary: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String?

    public init(id: String, name: String? = nil) {
        self.id = id
        self.name = name
    }

    /// Что показывать в списке — имя, если оно осмысленно отличается от id.
    public var displayName: String {
        guard let name, !name.isEmpty, name != id else { return id }
        return name
    }
}

/// Живой список моделей провайдера — вместо хардкода «популярных» (который
/// устаревает и может ссылаться на уже не существующую модель). Хочет
/// узнать РЕАЛЬНЫЙ каталог на момент открытия пикера, а не угадывать.
///
/// Стандартный OpenAI-совместимый эндпоинт `GET {baseURL}/models` — тот же
/// путь работает у `chatCompletions` и `openaiResponses` (общий base у
/// OpenAI); Anthropic — свой `GET {baseURL}/models` с `x-api-key`.
/// Любая ошибка (сеть/парсинг/статус) — тихий откат к `[]`: пикер тогда
/// просто предлагает свободный ввод, ничего не падает.
public enum ModelCatalogFetcher {
    /// Короткий таймаут: это вспомогательная подсказка UI, не должна
    /// подвешивать шит дольше, чем пользователь готов ждать список.
    static let timeout: TimeInterval = 8

    public static func fetchModels(
        baseURL: URL,
        kind: BrainAPIKind,
        apiKey: String?,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) async -> [BrainModelSummary] {
        // Anthropic без ключа ответит 401 — не тратим round-trip впустую.
        if kind == .anthropicMessages, apiKey?.isEmpty != false {
            return []
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        switch kind {
        case .chatCompletions, .openaiResponses:
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        case .anthropicMessages:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let list = try? JSONDecoder().decode(ModelListResponse.self, from: data)
        else { return [] }

        return list.data
            .compactMap(\.entry)
            .map { BrainModelSummary(id: $0.id, name: $0.name ?? $0.displayName) }
            .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// `{"data": [{"id": "...", "name"?: "...", "display_name"?: "..."}]}` —
    /// общая форма ответа у OpenAI/OpenRouter (`name`) и Anthropic (`display_name`).
    private struct ModelListResponse: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey {
                case id, name
                case displayName = "display_name"
            }
        }

        /// Одна запись, которая МОЖЕТ не разобраться (нет/не-строка `id` у
        /// конкретного элемента) — не должна ронять парсинг всего массива.
        /// Само `LossyEntry.init` не бросает НИКОГДА, поэтому стандартный
        /// декодер `[LossyEntry]` корректно проходит по всем элементам
        /// (в отличие от ручного `while !container.isAtEnd { try? … }`,
        /// где try? на упавшем декоде не продвигает курсор и зацикливается).
        struct LossyEntry: Decodable {
            let entry: Entry?
            init(from decoder: any Decoder) throws {
                entry = try? Entry(from: decoder)
            }
        }
        let data: [LossyEntry]
    }
}
