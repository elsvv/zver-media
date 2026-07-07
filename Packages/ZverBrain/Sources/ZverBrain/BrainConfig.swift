import Foundation

/// Конфигурация обращения к OpenAI-совместимому endpoint.
///
/// `baseURL` — корень API без хвоста метода (напр. `https://openrouter.ai/api/v1`);
/// клиент сам добавляет `/chat/completions`. `model` — идентификатор модели у
/// провайдера. Ключ (Bearer) намеренно НЕ здесь — он приходит поздно, перед
/// запросом, через ``BrainTokenProviding`` (в аппе — из Keychain), чтобы конфиг
/// можно было хранить в `@AppStorage`, а секрет — нет.
public struct BrainConfig: Sendable, Equatable {
    /// Корень OpenAI-совместимого API (без `/chat/completions`).
    public let baseURL: URL
    /// Идентификатор модели у провайдера.
    public let model: String

    public init(baseURL: URL, model: String) {
        self.baseURL = baseURL
        self.model = model
    }
}

/// Поставщик API-ключа (Bearer) для «мозга».
///
/// Свой протокол, НЕ импорт `ZverStorage.TokenProviding` — пакет автономен.
/// Семантика та же: `token()` асинхронный и возвращает `nil`, когда ключа нет;
/// клиент в этом случае немедленно бросает ``BrainError/missingToken``, не уходя
/// в сеть.
public protocol BrainTokenProviding: Sendable {
    /// Возвращает актуальный API-ключ или `nil`, если он не задан.
    func token() async -> String?
}

/// Неизменяемый поставщик одного заранее известного ключа (или его отсутствия).
///
/// Приложение читает ключ из Keychain и оборачивает сюда; при сбросе —
/// `StaticBrainTokenProvider(token: nil)`. Потокобезопасен по построению.
public struct StaticBrainTokenProvider: BrainTokenProviding {
    private let value: String?

    /// - Parameter token: ключ или `nil` (не задан).
    public init(token: String?) {
        self.value = token
    }

    public func token() async -> String? {
        value
    }
}
