import Foundation

/// Известный провайдер «из коробки»: имя + тип API + базовый URL. Пресет
/// задаёт ОБА поля разом (тип и адрес — повторяющаяся пара, которую иначе
/// пришлось бы перепечатывать при каждом новом профиле).
public struct BrainProviderPreset: Sendable, Equatable, Identifiable {
    public let name: String
    public let kind: BrainAPIKind
    public let baseURL: URL

    public var id: String { name }

    public init(name: String, kind: BrainAPIKind, baseURL: URL) {
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
    }

    /// Стабильные, версиононезависимые адреса — не устаревают в отличие от
    /// списка моделей, поэтому статика (в отличие от ``ModelCatalogFetcher``,
    /// который тянет актуальный список моделей живьём).
    public static let all: [BrainProviderPreset] = [
        .init(name: "OpenRouter", kind: .chatCompletions,
              baseURL: URL(string: "https://openrouter.ai/api/v1")!),
        .init(name: "OpenAI · Chat Completions", kind: .chatCompletions,
              baseURL: URL(string: "https://api.openai.com/v1")!),
        .init(name: "OpenAI · Responses", kind: .openaiResponses,
              baseURL: URL(string: "https://api.openai.com/v1")!),
        .init(name: "Anthropic", kind: .anthropicMessages,
              baseURL: URL(string: "https://api.anthropic.com/v1")!),
        .init(name: "Google Gemini (OpenAI-совместимый)", kind: .chatCompletions,
              baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!),
    ]
}
