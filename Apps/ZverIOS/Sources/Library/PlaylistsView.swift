import SwiftUI
import ZverCore

/// Раздел «Плейлисты»: список плейлистов с навигацией на их экраны.
/// Создание — кнопка «+» (alert с полем имени), удаление — swipe,
/// переименование — контекст-меню (alert).
struct PlaylistsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    @State private var isCreating = false
    @State private var newTitle = ""

    @State private var isRenaming = false
    @State private var renamingPlaylist: Playlist?
    @State private var renameTitle = ""

    var body: some View {
        Group {
            if store.playlists.isEmpty {
                ContentUnavailableView(
                    "Нет плейлистов",
                    systemImage: "music.note.list",
                    description: Text("Создайте плейлист кнопкой «+».")
                )
            } else {
                playlistList
            }
        }
        .navigationTitle("Плейлисты")
        .toolbar {
            Button {
                newTitle = ""
                isCreating = true
            } label: {
                Label("Новый плейлист", systemImage: "plus")
            }
        }
        .alert("Новый плейлист", isPresented: $isCreating) {
            TextField("Название", text: $newTitle)
            Button("Создать") {
                Task { await store.createPlaylist(title: newTitle) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать плейлист", isPresented: $isRenaming,
               presenting: renamingPlaylist) { playlist in
            TextField("Название", text: $renameTitle)
            Button("Сохранить") {
                Task { await store.renamePlaylist(id: playlist.id, title: renameTitle) }
            }
            Button("Отмена", role: .cancel) {}
        }
        // Раздел может открываться до первого refresh библиотеки
        // (или после ошибки) — подгружаем плейлисты сами.
        .task { await store.refreshPlaylists() }
    }

    private var playlistList: some View {
        List {
            ForEach(store.playlists) { playlist in
                NavigationLink {
                    PlaylistDetailView(playlist: playlist, store: store, engine: engine)
                } label: {
                    Label(playlist.title, systemImage: "music.note.list")
                }
                .contextMenu {
                    Button {
                        renameTitle = playlist.title
                        renamingPlaylist = playlist
                        isRenaming = true
                    } label: {
                        Label("Переименовать", systemImage: "pencil")
                    }
                }
            }
            .onDelete { offsets in
                let ids = offsets.map { store.playlists[$0].id }
                Task {
                    for id in ids {
                        await store.deletePlaylist(id: id)
                    }
                }
            }
        }
    }
}

// MARK: - Контекст-меню «В плейлист…»

/// Контекст-меню ряда трека: подменю со списком плейлистов
/// и пунктом «Новый плейлист…» (alert с именем — создаёт плейлист
/// и сразу кладёт в него трек). Общий для всех списков треков.
private struct AddToPlaylistMenuModifier: ViewModifier {
    let track: Track
    @ObservedObject var store: LibraryStore

    @State private var isCreating = false
    @State private var newTitle = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Menu {
                    ForEach(store.playlists) { playlist in
                        Button(playlist.title) {
                            Task {
                                await store.addToPlaylist(track: track,
                                                          playlistId: playlist.id)
                            }
                        }
                    }
                    if !store.playlists.isEmpty {
                        Divider()
                    }
                    Button {
                        newTitle = ""
                        isCreating = true
                    } label: {
                        Label("Новый плейлист…", systemImage: "plus")
                    }
                } label: {
                    Label("В плейлист…", systemImage: "text.badge.plus")
                }
            }
            .alert("Новый плейлист", isPresented: $isCreating) {
                TextField("Название", text: $newTitle)
                Button("Создать") {
                    Task {
                        if let playlist = await store.createPlaylist(title: newTitle) {
                            await store.addToPlaylist(track: track,
                                                      playlistId: playlist.id)
                        }
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
    }
}

extension View {
    /// Вешает на ряд трека контекст-меню «В плейлист…».
    func addToPlaylistMenu(for track: Track, store: LibraryStore) -> some View {
        modifier(AddToPlaylistMenuModifier(track: track, store: store))
    }
}
