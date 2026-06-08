import SwiftUI
import ZverCore

/// Восстановление библиотеки из облака (экран в Настройках).
///
/// Сценарий (план этапа 4): после переустановки приложения локальных файлов нет.
/// Владелец входит в облако (токен) и жмёт «Восстановить из облака»: качается
/// `catalog.sqlite.backup`, его записи импортируются в живой каталог как `remote`
/// (несут `cloudSha`), библиотека publish'ится — вся библиотека показывается ☁️,
/// дальше пользователь качает нужные треки. Существующие локальные строки НЕ
/// деградируют (см. `CatalogStore.importRemoteCatalog`).
///
/// Сама загрузка/импорт — в ``BackupService/restore()`` (через ``LibraryStore``):
/// сеть и чтение БД на детаче, republish после. Экран лишь оркестрирует состояние
/// (идёт ли восстановление, результат) и не дёргает сеть напрямую.
struct RestoreView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var account: CloudAccount

    @State private var isRestoring = false
    @State private var result: RestoreResult?

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await restore() }
                } label: {
                    HStack {
                        Label("Восстановить из облака", systemImage: "arrow.clockwise.icloud")
                        Spacer()
                        if isRestoring {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRestoring || !account.isAuthorized)
            } footer: {
                footer
            }

            if let result {
                Section {
                    switch result {
                    case let .success(count):
                        Label("Импортировано треков: \(count)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure:
                        Label("Не удалось восстановить. Проверьте подключение и токен.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .navigationTitle("Восстановление")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var footer: some View {
        if account.isAuthorized {
            Text("Скачивает каталог из облака и добавляет всю библиотеку как «в облаке». "
                 + "Локальные треки остаются на месте. После — качайте нужное по тапу ☁️.")
        } else {
            Text("Сначала войдите в Яндекс.Диск выше.")
        }
    }

    private func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        result = nil
        defer { isRestoring = false }

        if let count = await store.restore() {
            result = .success(count)
        } else {
            result = .failure
        }
    }

    /// Итог восстановления для индикации в UI.
    enum RestoreResult: Equatable {
        case success(Int)
        case failure
    }
}
