import SwiftUI
import ZverBrain

/// Раздел «ИИ» в Настройках: профили провайдеров (тип API + endpoint + модель
/// + ключ + инструменты) с переключением, и свои инструкции к запросу ленты.
/// Встраивается в Form Настроек (как RemoteSettingsView).
struct BrainSettingsView: View {
    @ObservedObject var store: BrainProfilesStore

    @AppStorage(BrainProfilesStore.customInstructionsKey)
    private var customInstructions = ""
    @State private var editingProfile: BrainProfile?

    var body: some View {
        profilesSection
        instructionsSection
    }

    // MARK: - Профили

    private var profilesSection: some View {
        Section {
            ForEach(store.profiles) { profile in
                profileRow(profile)
            }
            Button {
                editingProfile = .draft()
            } label: {
                Label("Добавить профиль…", systemImage: "plus")
            }
        } header: {
            Text("ИИ")
        } footer: {
            Text("Профиль — это провайдер рекомендаций: тип API, адрес, модель " +
                 "и ключ. Активный профиль используется при обновлении ленты " +
                 "на «Главной». Gemini подключается через его OpenAI-совместимый " +
                 "адрес типом Chat Completions.")
        }
        .sheet(item: $editingProfile) { profile in
            BrainProfileEditor(store: store, profile: profile)
        }
    }

    private func profileRow(_ profile: BrainProfile) -> some View {
        Button {
            store.activate(profile.id)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name.isEmpty ? "Без названия" : profile.name)
                        .foregroundStyle(.primary)
                    Text(subtitle(for: profile))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !store.hasKey(profile.id) {
                    Image(systemName: "key.slash")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Ключ не задан")
                }
                if store.activeProfileId == profile.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Активный профиль")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                store.delete(profile.id)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
            Button {
                editingProfile = profile
            } label: {
                Label("Править", systemImage: "pencil")
            }
        }
    }

    private func subtitle(for profile: BrainProfile) -> String {
        var parts = [profile.kind.displayName]
        if !profile.model.isEmpty { parts.append(profile.model) }
        var extras: [String] = []
        if profile.webSearch { extras.append("веб-поиск") }
        if profile.reasoning != .off { extras.append("рассуждение") }
        if !extras.isEmpty { parts.append(extras.joined(separator: " + ")) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Свои инструкции

    private var instructionsSection: some View {
        Section {
            TextEditor(text: $customInstructions)
                .frame(minHeight: 88)
                .font(.callout)
        } header: {
            Text("Свои инструкции")
        } footer: {
            Text("Добавляются к каждому запросу ленты. Например: «больше " +
                 "джаза 70-х», «не предлагай сборники», «пиши subtitle с юмором».")
        }
    }
}

/// Редактор профиля: тип API (смена подставляет дефолтный адрес типа),
/// endpoint, модель, ключ (Keychain), инструменты — веб-поиск и рассуждение
/// с per-тип пояснениями, где это нативный тул, а где плагин OpenRouter.
private struct BrainProfileEditor: View {
    @ObservedObject var store: BrainProfilesStore
    @State var profile: BrainProfile

    @Environment(\.dismiss) private var dismiss
    @State private var keyInput = ""
    @State private var keyError: String?
    /// Отложенные операции с ключом — Keychain трогаем ТОЛЬКО в save():
    /// «Отмена» шита не должна оставлять уже удалённый/заменённый ключ.
    @State private var isReplacingKey = false
    @State private var pendingKeyDeletion = false
    @State private var showsModelPicker = false

    init(store: BrainProfilesStore, profile: BrainProfile) {
        self.store = store
        _profile = State(initialValue: profile)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Например, OpenRouter · Gemini 3 Pro", text: $profile.name)
                }

                Section {
                    Picker("Тип API", selection: $profile.kind) {
                        ForEach(BrainAPIKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .onChange(of: profile.kind) { oldKind, newKind in
                        // Подставляем дефолт НОВОГО типа только если поле было
                        // пустым или равнялось дефолту именно СТАРОГО типа (не
                        // трогали руками). Сравнение с дефолтом старого, а не
                        // "с любым из трёх", — иначе пресет вроде «OpenAI · Chat
                        // Completions» (kind=chatCompletions, но адрес — хост
                        // OpenAI, а не OpenRouter) тут же откатился бы: его адрес
                        // совпадает с дефолтом ДРУГОГО типа (openaiResponses) и
                        // старая проверка приняла бы это за «не трогали».
                        if profile.baseURL.isEmpty
                            || profile.baseURL == oldKind.defaultBaseURL.absoluteString {
                            profile.baseURL = newKind.defaultBaseURL.absoluteString
                        }
                    }
                    HStack {
                        TextField("Base URL", text: $profile.baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        presetsMenu
                    }
                    HStack {
                        TextField("Модель", text: $profile.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showsModelPicker = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .accessibilityLabel("Найти модель")
                    }
                } header: {
                    Text("Провайдер")
                }

                keySection
                toolsSection
            }
            .navigationTitle(isNew ? "Новый профиль" : "Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showsModelPicker) {
                if let url = URL(string: profile.baseURL) {
                    ModelPickerSheet(baseURL: url, kind: profile.kind,
                                     apiKey: effectiveKey, initialQuery: profile.model) { model in
                        profile.model = model
                    }
                }
            }
        }
    }

    /// Ключ для живого запроса каталога моделей: только что введённый (новый
    /// профиль/замена) или уже сохранённый в Keychain (существующий, не тронут).
    private var effectiveKey: String? {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if store.hasKey(profile.id), !pendingKeyDeletion {
            return store.currentKey(for: profile.id)
        }
        return nil
    }

    /// Компактное меню известных провайдеров: выбор ставит СРАЗУ тип API и
    /// адрес (повторяющаяся пара, которую иначе пришлось бы перепечатывать).
    private var presetsMenu: some View {
        Menu {
            ForEach(BrainProviderPreset.all) { preset in
                Button(preset.name) {
                    profile.kind = preset.kind
                    profile.baseURL = preset.baseURL.absoluteString
                }
            }
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Пресеты провайдеров")
    }

    private var isNew: Bool { !store.profiles.contains { $0.id == profile.id } }

    private var canSave: Bool {
        !profile.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: profile.baseURL)?.scheme?.hasPrefix("http") == true
    }

    private var keySection: some View {
        Section {
            if store.hasKey(profile.id), !isReplacingKey, !pendingKeyDeletion {
                LabeledContent("Ключ API") {
                    Label(store.maskedKey(for: profile.id) ?? "сохранён",
                          systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Button("Заменить ключ…") { isReplacingKey = true }
                Button("Удалить ключ", role: .destructive) {
                    pendingKeyDeletion = true
                }
            } else if pendingKeyDeletion {
                Label("Ключ будет удалён при сохранении", systemImage: "key.slash")
                    .foregroundStyle(.orange)
                Button("Оставить ключ") { pendingKeyDeletion = false }
            } else {
                SecureField("API-ключ провайдера", text: $keyInput)
                if isReplacingKey {
                    Button("Оставить прежний ключ") {
                        isReplacingKey = false
                        keyInput = ""
                    }
                }
                if let keyError {
                    Text(keyError).font(.caption).foregroundStyle(.red)
                }
            }
        } header: {
            Text("Ключ")
        } footer: {
            Text("Хранится в Keychain, у каждого профиля свой. Изменения " +
                 "ключа применяются кнопкой «Сохранить».")
        }
    }

    private var toolsSection: some View {
        Section {
            Toggle("Веб-поиск", isOn: $profile.webSearch)
            Picker("Рассуждение", selection: $profile.reasoning) {
                Text("Выкл").tag(BrainReasoning.off)
                Text("Низко").tag(BrainReasoning.low)
                Text("Средне").tag(BrainReasoning.medium)
                Text("Глубоко").tag(BrainReasoning.high)
            }
        } header: {
            Text("Инструменты")
        } footer: {
            Text(toolsFootnote)
        }
    }

    /// Честное пояснение, как инструменты ложатся на выбранный тип API.
    private var toolsFootnote: String {
        switch profile.kind {
        case .chatCompletions:
            return "Веб-поиск здесь — плагин OpenRouter (на других " +
                   "провайдерах может не работать). Рассуждение — " +
                   "reasoning_effort, поддерживается OpenAI/OpenRouter. " +
                   "С рассуждением ответ заметно дольше."
        case .openaiResponses:
            return "Нативные инструменты OpenAI: веб-поиск (web_search) и " +
                   "reasoning для новых моделей. С рассуждением ответ дольше."
        case .anthropicMessages:
            return "Нативные инструменты Anthropic: веб-поиск и extended " +
                   "thinking. С thinking ответ заметно дольше."
        }
    }

    private func save() {
        // Ключ применяется здесь, а не в момент нажатий (см. keySection):
        // удаление — по отложенному флагу; ввод (новый профиль или замена) —
        // перезаписью существующей записи Keychain.
        if pendingKeyDeletion {
            store.clearKey(for: profile.id)
        } else {
            let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                do {
                    try store.saveKey(trimmed, for: profile.id)
                } catch {
                    keyError = "Не получилось сохранить ключ."
                    return
                }
            }
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            profile.name = profile.kind.displayName
        }
        store.upsert(profile)
        dismiss()
    }
}
