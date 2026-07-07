import SwiftUI

/// Секция «Интеллект» в Настройках (встраивается в Form, как RemoteSettingsView):
/// OpenAI-совместимый провайдер рекомендаций — base URL, модель, API-ключ.
/// Ключ в Keychain (маскированный статус), base URL/модель — AppStorage.
struct BrainSettingsView: View {
    @ObservedObject var account: BrainAccount

    @AppStorage(BrainAccount.baseURLKey) private var baseURL = BrainAccount.defaultBaseURL
    @AppStorage(BrainAccount.modelKey) private var model = ""
    @State private var keyInput = ""
    @State private var errorMessage: String?

    var body: some View {
        Section {
            TextField("Base URL", text: $baseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("Модель (например, openai/gpt-5.2)", text: $model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if account.isConfigured {
                LabeledContent("Ключ API") {
                    Label(account.maskedKey ?? "сохранён", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
                Button("Удалить ключ", role: .destructive) {
                    account.clear()
                }
            } else {
                SecureField("API-ключ провайдера", text: $keyInput)
                Button("Сохранить ключ") {
                    do {
                        try account.save(key: keyInput)
                        keyInput = ""
                        errorMessage = nil
                    } catch {
                        errorMessage = "Ключ пустой — вставь значение из кабинета провайдера."
                    }
                }
                .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Интеллект")
        } footer: {
            Text("Любой OpenAI-совместимый API: OpenRouter, OpenAI, Gemini и др. " +
                 "Рекомендации на «Главной» обновляются только вручную — " +
                 "ключ используется в момент обновления ленты.")
        }
    }
}
