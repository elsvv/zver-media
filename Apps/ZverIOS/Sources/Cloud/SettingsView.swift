import SwiftUI
import ZverStorage

/// Экран Настроек: вход в облако (Яндекс.Диск), переключатели бэкапа,
/// ручной бэкап каталога и вход в восстановление.
///
/// MVP-вход (см. план этапа 4): владелец вставляет ~годовой OAuth-токен (scope
/// `cloud_api:disk.app_folder`), он ложится в Keychain (`CloudAccount`). Поле ввода
/// маскированное (`SecureField`), статус показывает залогинен/нет и маскированный
/// хвост токена. Полноценный браузерный вход — отложен (см. `CloudAccount`).
///
/// Раздел «Бэкап» доступен только авторизованным: тумблер автобэкапа новых альбомов
/// (`@AppStorage` — ContentView читает его перед автобэкапом после импорта), кнопка
/// ручного бэкапа каталога и переход в ``RestoreView``. Реальная связка — через
/// ``LibraryStore``/``BackupService``; экран сети напрямую не дёргает.
struct SettingsView: View {
    @ObservedObject var account: CloudAccount
    @ObservedObject var store: LibraryStore
    @ObservedObject var backup: BackupService

    @State private var tokenInput: String = ""
    @State private var errorMessage: String?

    /// Идёт ли ручной бэкап каталога (для индикатора на кнопке).
    @State private var isBackingUpCatalog = false

    /// Автобэкап новых альбомов: персистентный флаг. ContentView читает его (тот же
    /// ключ) после импорта и решает, ставить ли треки в очередь автоматически.
    @AppStorage(SettingsView.autoBackupKey) private var autoBackupNewAlbums = true

    /// Ключ `@AppStorage` тумблера автобэкапа — общий с ContentView.
    static let autoBackupKey = "cloud.autoBackupNewAlbums"

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

    // MARK: - Бэкап

    @ViewBuilder
    private var backupSection: some View {
        Section {
            Toggle("Автобэкап новых альбомов", isOn: $autoBackupNewAlbums)

            Button {
                Task { await backupAll() }
            } label: {
                HStack {
                    Label("Сделать бэкап сейчас", systemImage: "icloud.and.arrow.up")
                    Spacer()
                    if backup.isBackingUp || isBackingUpCatalog {
                        ProgressView()
                    }
                }
            }
            .disabled(backup.isBackingUp || isBackingUpCatalog)

            NavigationLink {
                RestoreView(store: store, account: account)
            } label: {
                Label("Восстановить из облака", systemImage: "arrow.clockwise.icloud")
            }
        } header: {
            Text("Бэкап")
        } footer: {
            Text("Новые альбомы выгружаются автоматически, если включено. «Сделать бэкап "
                 + "сейчас» выгружает все неотправленные треки и каталог. Восстановление "
                 + "возвращает библиотеку после переустановки.")
        }

        if let error = backup.lastError {
            Section {
                Label(message(for: error), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
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

    private func backupAll() async {
        guard !isBackingUpCatalog else { return }
        isBackingUpCatalog = true
        defer { isBackingUpCatalog = false }
        await store.backupAll()
    }

    /// Человеко-читаемое сообщение для ошибки верхнего уровня облака.
    private func message(for error: RemoteError) -> String {
        switch error {
        case .unauthorized:
            return "Токен Яндекс.Диска недействителен — войдите заново."
        case .insufficientStorage:
            return "На Яндекс.Диске закончилось место."
        default:
            return "Ошибка облака. Повторите позже."
        }
    }
}
