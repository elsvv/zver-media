import SwiftUI
import ZverBrain

/// Шит выбора модели: поиск сверху = одновременно ввод и фильтр по живому
/// каталогу провайдера (`GET {baseURL}/models`) — реальные id, не устаревший
/// хардкод. Нет каталога (ошибка/нет ключа/провайдер не отдаёт список) —
/// поиск всё равно работает как обычный ввод, строка «Использовать «…»»
/// подтверждает произвольное значение.
struct ModelPickerSheet: View {
    let baseURL: URL
    let kind: BrainAPIKind
    /// Ключ для запроса каталога — актуальный ввод в редакторе (для нового
    /// профиля) или значение из Keychain (для существующего). Эфемерный,
    /// нигде кроме этого запроса не используется.
    let apiKey: String?
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var models: [BrainModelSummary] = []
    @State private var isLoading = true
    @State private var loadFailed = false

    init(baseURL: URL, kind: BrainAPIKind, apiKey: String?,
         initialQuery: String, onSelect: @escaping (String) -> Void) {
        self.baseURL = baseURL
        self.kind = kind
        self.apiKey = apiKey
        self.onSelect = onSelect
        _query = State(initialValue: initialQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !filtered.contains(where: { $0.id == query }) {
                    Button {
                        onSelect(query)
                        dismiss()
                    } label: {
                        Label("Использовать «\(query)»", systemImage: "pencil")
                    }
                }
                ForEach(filtered) { model in
                    Button {
                        onSelect(model.id)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.displayName).foregroundStyle(.primary)
                            if model.displayName != model.id {
                                Text(model.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else if loadFailed || models.isEmpty {
                    Text(emptyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                       prompt: "Название модели")
            .navigationTitle("Модель")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private var filtered: [BrainModelSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var emptyHint: String {
        kind == .anthropicMessages && (apiKey?.isEmpty != false)
            ? "Список моделей Anthropic требует ключ — впиши название вручную."
            : "Не удалось получить список моделей — впиши название вручную."
    }

    private func load() async {
        models = await ModelCatalogFetcher.fetchModels(baseURL: baseURL, kind: kind, apiKey: apiKey)
        loadFailed = models.isEmpty
        isLoading = false
    }
}
