import Foundation
import ZverBrain
import ZverTransport

/// Профиль AI-провайдера: тип API + endpoint + модель + инструменты.
/// Ключ API в профиле НЕ хранится (он в Keychain, по записи на профиль).
struct BrainProfile: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var name: String
    var kind: BrainAPIKind
    var baseURL: String
    var model: String
    var webSearch: Bool
    var reasoning: BrainReasoning

    /// Свежий профиль под выбранный тип API (base URL — дефолт типа).
    static func draft(kind: BrainAPIKind = .chatCompletions) -> BrainProfile {
        BrainProfile(id: UUID(), name: "", kind: kind,
                     baseURL: kind.defaultBaseURL.absoluteString,
                     model: "", webSearch: false, reasoning: .off)
    }
}

/// Хранилище AI-профилей (раздел «ИИ» в Настройках): список профилей и
/// активный — в `UserDefaults` (не секреты), ключи — в Keychain по записи
/// на профиль (`service = brain.llm.{uuid}`, общий account `zver-brain-key`).
///
/// **Миграция со старых настроек** (один набор `brain.baseURL`/`brain.model` +
/// ключ в `brain.llm`): при первом запуске превращаются в активный профиль
/// «OpenRouter» типа chatCompletions, легаси-ключ переезжает в про-профильную
/// запись. Легаси-ключи затем чистятся — миграция одноразовая.
@MainActor
final class BrainProfilesStore: ObservableObject {
    static let profilesKey = "brain.profiles"
    static let activeKey = "brain.activeProfileId"
    static let customInstructionsKey = "brain.customInstructions"
    /// Легаси-ключи (до профилей, PR #14) — только для миграции.
    static let legacyBaseURLKey = "brain.baseURL"
    static let legacyModelKey = "brain.model"
    static let legacyService = "brain.llm"
    static let keychainAccount = "zver-brain-key"

    @Published private(set) var profiles: [BrainProfile] = []
    @Published private(set) var activeProfileId: UUID?
    /// Профили с сохранённым ключом — для статуса в списке/редакторе.
    @Published private(set) var keyedProfileIds: Set<UUID> = []

    private let keyStore: any KeyStore
    private let defaults: UserDefaults

    init(keyStore: any KeyStore = KeychainKeyStore(account: BrainProfilesStore.keychainAccount),
         defaults: UserDefaults = .standard) {
        self.keyStore = keyStore
        self.defaults = defaults
        load()
        migrateLegacyIfNeeded()
        refreshKeyedProfiles()
    }

    // MARK: - Доступ

    var activeProfile: BrainProfile? {
        activeProfileId.flatMap { id in profiles.first { $0.id == id } }
    }

    /// Активный профиль настроен: есть ключ и валидный конфиг.
    var isConfigured: Bool {
        guard let profile = activeProfile else { return false }
        return keyedProfileIds.contains(profile.id) && config != nil
    }

    /// Конфиг клиента из активного профиля. Кривой URL/пустая модель → nil.
    var config: BrainConfig? {
        guard let profile = activeProfile else { return nil }
        let raw = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), url.scheme?.hasPrefix("http") == true,
              !model.isEmpty
        else { return nil }
        return BrainConfig(baseURL: url, model: model, kind: profile.kind,
                           webSearch: profile.webSearch, reasoning: profile.reasoning)
    }

    /// Поставщик ключа АКТИВНОГО профиля: Keychain читается поздно, в момент
    /// запроса. Профиль зафиксирован на момент создания поставщика —
    /// HomeFeedService берёт его прямо перед запросом.
    var tokenProvider: any BrainTokenProviding {
        LateKeychainProvider(keyStore: keyStore,
                             service: activeProfileId.map(Self.service(for:)) ?? "")
    }

    /// Кастомные инструкции пользователя к запросу ленты (пусто → nil).
    var customInstructions: String? {
        let text = defaults.string(forKey: Self.customInstructionsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    // MARK: - CRUD профилей

    func upsert(_ profile: BrainProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
            // Первый профиль сразу активен — меньше шагов до рабочей ленты.
            if activeProfileId == nil { activeProfileId = profile.id }
        }
        persist()
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        try? keyStore.delete(forService: Self.service(for: id))
        keyedProfileIds.remove(id)
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }
        persist()
    }

    func activate(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
        persist()
    }

    // MARK: - Ключи

    func saveKey(_ key: String, for id: UUID) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AccountError.emptyToken }
        try keyStore.save(token: trimmed, forService: Self.service(for: id))
        keyedProfileIds.insert(id)
    }

    func clearKey(for id: UUID) {
        try? keyStore.delete(forService: Self.service(for: id))
        keyedProfileIds.remove(id)
    }

    func hasKey(_ id: UUID) -> Bool { keyedProfileIds.contains(id) }

    func maskedKey(for id: UUID) -> String? {
        guard let token = keyStore.token(forService: Self.service(for: id)),
              !token.isEmpty else { return nil }
        return "…\(token.suffix(4))"
    }

    enum AccountError: Error { case emptyToken }

    // MARK: - Персист и миграция

    private static func service(for id: UUID) -> String { "brain.llm.\(id.uuidString)" }

    private func load() {
        if let data = defaults.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([BrainProfile].self, from: data) {
            profiles = decoded
        }
        if let raw = defaults.string(forKey: Self.activeKey), let id = UUID(uuidString: raw),
           profiles.contains(where: { $0.id == id }) {
            activeProfileId = id
        } else {
            activeProfileId = profiles.first?.id
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
        defaults.set(activeProfileId?.uuidString, forKey: Self.activeKey)
    }

    /// Одноразовая миграция настроек до-профильной эпохи. Выполняется только
    /// когда профилей ещё нет И есть хоть что-то легаси (URL/модель/ключ).
    private func migrateLegacyIfNeeded() {
        guard profiles.isEmpty else { return }
        let legacyURL = defaults.string(forKey: Self.legacyBaseURLKey)
        let legacyModel = defaults.string(forKey: Self.legacyModelKey)
        let legacyKey = keyStore.token(forService: Self.legacyService)
        guard legacyURL != nil || (legacyModel?.isEmpty == false)
                || (legacyKey?.isEmpty == false) else { return }

        var profile = BrainProfile.draft(kind: .chatCompletions)
        profile.name = "OpenRouter"
        if let legacyURL, !legacyURL.isEmpty { profile.baseURL = legacyURL }
        profile.model = legacyModel ?? ""
        profiles = [profile]
        activeProfileId = profile.id
        if let legacyKey, !legacyKey.isEmpty {
            try? keyStore.save(token: legacyKey, forService: Self.service(for: profile.id))
            try? keyStore.delete(forService: Self.legacyService)
        }
        defaults.removeObject(forKey: Self.legacyBaseURLKey)
        defaults.removeObject(forKey: Self.legacyModelKey)
        persist()
    }

    private func refreshKeyedProfiles() {
        keyedProfileIds = Set(profiles.map(\.id).filter {
            keyStore.token(forService: Self.service(for: $0))?.isEmpty == false
        })
    }

    private struct LateKeychainProvider: BrainTokenProviding {
        let keyStore: any KeyStore
        let service: String
        func token() async -> String? {
            guard !service.isEmpty else { return nil }
            let value = keyStore.token(forService: service)
            return (value?.isEmpty == false) ? value : nil
        }
    }
}
