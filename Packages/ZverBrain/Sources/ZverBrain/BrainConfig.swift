import Foundation

/// Тип API провайдера — определяет, какой адаптер собирает и разбирает запрос.
///
/// Один ``ChatClient``-контракт, три реализации за ``BrainClientFactory``.
/// `chatCompletions` — дефолт (OpenRouter/OpenAI-совместимые/Gemini-compat);
/// `openaiResponses` — новые модели OpenAI (`/responses`); `anthropicMessages` —
/// Anthropic (`/messages`, `x-api-key`). rawValue стабилен — по нему хранится
/// профиль в аппе, менять нельзя.
public enum BrainAPIKind: String, Codable, CaseIterable, Sendable {
    case chatCompletions
    case openaiResponses
    case anthropicMessages

    /// Базовый URL «из коробки» для типа — подставляется в редакторе профиля
    /// при выборе типа (пользователь может переопределить).
    public var defaultBaseURL: URL {
        switch self {
        case .chatCompletions:
            return URL(string: "https://openrouter.ai/api/v1")!
        case .openaiResponses:
            return URL(string: "https://api.openai.com/v1")!
        case .anthropicMessages:
            return URL(string: "https://api.anthropic.com/v1")!
        }
    }

    /// Человекочитаемое имя типа для пикера в настройках (по-русски).
    public var displayName: String {
        switch self {
        case .chatCompletions: return "Chat Completions (OpenAI-совместимый)"
        case .openaiResponses: return "Responses (OpenAI)"
        case .anthropicMessages: return "Messages (Anthropic)"
        }
    }
}

/// Уровень «рассуждения» (reasoning/extended thinking).
///
/// У разных типов API маппится по-своему: OpenAI-style — `reasoning_effort`/
/// `effort` строкой (low/medium/high), Anthropic — бюджет токенов thinking.
/// `off` означает «не просить рассуждение» — поле в запрос не уходит.
public enum BrainReasoning: String, Codable, CaseIterable, Sendable {
    case off
    case low
    case medium
    case high
}

extension BrainReasoning {
    /// Строка усилия для OpenAI-style полей (`reasoning_effort`, `effort`):
    /// `nil` при `off` (поле опускаем). rawValue уже совпадает с low/medium/high.
    var effort: String? {
        self == .off ? nil : rawValue
    }

    /// Бюджет токенов extended-thinking у Anthropic: `nil` при `off`.
    /// low 4k / medium 8k / high 16k — по дизайну.
    var anthropicThinkingBudget: Int? {
        switch self {
        case .off: return nil
        case .low: return 4096
        case .medium: return 8192
        case .high: return 16384
        }
    }
}

/// Конфигурация обращения к чат-модели.
///
/// `baseURL` — корень API без хвоста метода (напр. `https://openrouter.ai/api/v1`);
/// адаптер сам добавляет свой путь (`/chat/completions`, `/responses`, `/messages`).
/// `model` — идентификатор модели у провайдера. Ключ намеренно НЕ здесь — он
/// приходит поздно, перед запросом, через ``BrainTokenProviding`` (в аппе — из
/// Keychain), чтобы конфиг можно было хранить в `@AppStorage`, а секрет — нет.
///
/// `kind`/`webSearch`/`reasoning` имеют дефолты (`chatCompletions`/`false`/`off`),
/// чтобы старые вызовы `BrainConfig(baseURL:model:)` не ломались.
public struct BrainConfig: Sendable, Equatable {
    /// Корень API (без хвоста метода).
    public let baseURL: URL
    /// Идентификатор модели у провайдера.
    public let model: String
    /// Тип API — какой адаптер обслуживает конфиг.
    public let kind: BrainAPIKind
    /// Просить веб-поиск (нативный тул или плагин — зависит от типа).
    public let webSearch: Bool
    /// Уровень рассуждения (reasoning/thinking).
    public let reasoning: BrainReasoning

    public init(
        baseURL: URL,
        model: String,
        kind: BrainAPIKind = .chatCompletions,
        webSearch: Bool = false,
        reasoning: BrainReasoning = .off
    ) {
        self.baseURL = baseURL
        self.model = model
        self.kind = kind
        self.webSearch = webSearch
        self.reasoning = reasoning
    }
}

/// Поставщик API-ключа для «мозга».
///
/// Свой протокол, НЕ импорт `ZverStorage.TokenProviding` — пакет автономен.
/// Семантика: `token()` асинхронный и возвращает `nil`, когда ключа нет; клиент
/// в этом случае немедленно бросает ``BrainError/missingToken``, не уходя в сеть.
/// Как ключ попадёт в запрос (Bearer или `x-api-key`) — дело адаптера, не токен-
/// провайдера: тут только «значение ключа».
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
