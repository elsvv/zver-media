import SwiftUI

/// Экран Настроек: вход в облако (Яндекс.Диск) ручным OAuth-токеном.
///
/// MVP-вход (см. план этапа 4): владелец вставляет ~годовой OAuth-токен (scope
/// `cloud_api:disk.app_folder`), он ложится в Keychain (`CloudAccount`). Поле ввода
/// маскированное (`SecureField`), статус показывает залогинен/нет и маскированный
/// хвост токена. Полноценный браузерный вход — отложен (см. `CloudAccount`).
///
/// Переключатели автобэкапа/каталога — ЗАГЛУШКИ на этом этапе: реальная связка с
/// очередью и каталогом приедет в S4-10/S4-11. Здесь они лишь намечают будущий UI и
/// не дёргают сеть.
struct SettingsView: View {
    @ObservedObject var account: CloudAccount

    @State private var tokenInput: String = ""
    @State private var errorMessage: String?

    // Заглушки настроек бэкапа — провод в S4-10/S4-11.
    @State private var autoBackupNewAlbums: Bool = true

    var body: some View {
        Form {
            accountSection
            if account.isAuthorized {
                backupSection
            }
            aboutSection
        }
        .navigationTitle("Настройки")
    }

    // MARK: - Аккаунт облака

    @ViewBuilder
    private var accountSection: some View {
        Section {
            if account.isAuthorized {
                LabeledContent("Яндекс.Диск") {
                    Label("Подключён", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                if let masked = account.maskedToken {
                    LabeledContent("Токен", value: masked)
                        .foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    account.logout()
                    tokenInput = ""
                    errorMessage = nil
                } label: {
                    Text("Выйти")
                }
            } else {
                SecureField("OAuth-токен Яндекс.Диска", text: $tokenInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.password)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Button {
                    login()
                } label: {
                    Text("Войти")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Text("Облако")
        } footer: {
            if !account.isAuthorized {
                Text("Вставьте OAuth-токен Яндекс.Диска (scope cloud_api:disk.app_folder). "
                     + "Токен хранится в Keychain устройства и не покидает его.")
            }
        }
    }

    // MARK: - Бэкап (заглушки до S4-10/S4-11)

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Toggle("Автобэкап новых альбомов", isOn: $autoBackupNewAlbums)
                .disabled(true)
        } header: {
            Text("Бэкап")
        } footer: {
            Text("Автоматическая выгрузка и восстановление появятся в следующих обновлениях.")
        }
    }

    // MARK: - О приложении

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            LabeledContent("Версия", value: appVersion)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (v, b) {
        case let (v?, b?): return "\(v) (\(b))"
        case let (v?, nil): return v
        default: return "—"
        }
    }

    private func login() {
        do {
            try account.login(token: tokenInput)
            tokenInput = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
