import SwiftUI
import ZverCore

/// Шит «Править альбом»: название, артист альбома (пишется во все треки),
/// год. Правки уходят в sidecar `album.zvermeta.json` через
/// ``LibraryStore/editAlbum(_:title:artist:year:)`` — переживают реинсталл и
/// рескан. Пустое поле означает «не менять» (очистить тег с телефона нельзя —
/// это осознанное упрощение, очистка возможна с Мака).
struct AlbumEditSheet: View {
    let group: AlbumGroup
    @ObservedObject var store: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var yearText: String
    @State private var isSaving = false

    init(group: AlbumGroup, store: LibraryStore) {
        self.group = group
        self.store = store
        _title = State(initialValue: group.album)
        _artist = State(initialValue: group.artist ?? "")
        let year = group.tracks.compactMap(\.year).first
        _yearText = State(initialValue: year.map(String.init) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Название альбома", text: $title)
                }
                Section {
                    TextField("Артист", text: $artist)
                } header: {
                    Text("Артист альбома")
                } footer: {
                    Text("Применится ко всем трекам альбома — например, когда " +
                         "вместо основного исполнителя подхватился feat.-гость.")
                }
                Section("Год") {
                    TextField("Год", text: $yearText)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("Править альбом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(isSaving || !hasChanges)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    /// Что реально изменилось относительно текущих значений: неизменённые поля
    /// в sidecar не пишем (не плодим лишних override'ов).
    private var changedTitle: String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != group.album) ? trimmed : nil
    }
    private var changedArtist: String? {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return (!trimmed.isEmpty && trimmed != (group.artist ?? "")) ? trimmed : nil
    }
    private var changedYear: Int? {
        let trimmed = yearText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let year = Int(trimmed), (1000...3000).contains(year),
              year != group.tracks.compactMap(\.year).first else { return nil }
        return year
    }
    private var hasChanges: Bool {
        changedTitle != nil || changedArtist != nil || changedYear != nil
    }

    private func save() {
        isSaving = true
        Task {
            await store.editAlbum(group, title: changedTitle,
                                  artist: changedArtist, year: changedYear)
            dismiss()
        }
    }
}
