import SwiftUI
import ZverCore

/// Экран плейлиста: треки по позициям, кнопка «Играть», режим
/// правки (перетаскивание и удаление). Тап по треку — воспроизведение
/// плейлиста с него. Мутации идут в LibraryStore, локальный массив
/// правится сразу же — без перечитывания БД на каждый жест.
struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    @State private var tracks: [Track] = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            if !tracks.isEmpty {
                Section {
                    Button {
                        engine.play(tracks: tracks, startAt: 0)
                    } label: {
                        Label("Играть", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .listRowSeparator(.hidden)
                }
            }
            Section {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        engine.play(tracks: tracks, startAt: index)
                    } label: {
                        trackRow(track, position: index + 1)
                    }
                    .addToPlaylistMenu(for: track, store: store)
                }
                .onMove(perform: move)
                .onDelete(perform: delete)
                // Освобождаем последний трек из-под мини-плеера: в `.plain`-списке
                // нижний inset от ContentView `.safeAreaInset` до последнего ряда
                // доходит не всегда (та же причина, что в AlbumDetailView). Ряд вне
                // ForEach — не таскается и не удаляется в режиме правки.
                if !tracks.isEmpty, engine.queue.current != nil {
                    Color.clear
                        .frame(height: MiniPlayerMetrics.approximateHeight)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(playlist.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !tracks.isEmpty {
                // Не EditButton: его подпись системная (Edit без локализации
                // приложения), остальной интерфейс — русский.
                Button(editMode.isEditing ? "Готово" : "Изменить") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView(
                    "Плейлист пуст",
                    systemImage: "music.note.list",
                    description: Text("Добавляйте треки через контекст-меню «В плейлист…».")
                )
            }
        }
        .task { tracks = await store.playlistTracks(id: playlist.id) }
    }

    /// Перестановка в правке: локально — move по offsets, в сторе —
    /// позиция вставки после изъятия трека (семантика PlaylistStore.move
    /// совпадает с ней: destination за вычетом самого трека).
    private func move(from source: IndexSet, to destination: Int) {
        guard let from = source.first, source.count == 1 else { return }
        let track = tracks[from]
        tracks.move(fromOffsets: source, toOffset: destination)
        let position = destination > from ? destination - 1 : destination
        Task {
            await store.moveInPlaylist(track: track, playlistId: playlist.id,
                                       to: position)
        }
    }

    private func delete(at offsets: IndexSet) {
        let removed = offsets.map { tracks[$0] }
        tracks.remove(atOffsets: offsets)
        Task {
            for track in removed {
                await store.removeFromPlaylist(track: track, playlistId: playlist.id)
            }
        }
    }

    private func trackRow(_ track: Track, position: Int) -> some View {
        let isCurrent = engine.isCurrent(track)
        return HStack(spacing: 12) {
            // Колонка позиции: у текущего трека — индикатор вместо номера
            // (та же ширина, ряды не «прыгают» — как на экране альбома).
            Group {
                if isCurrent {
                    NowPlayingIndicator(isPlaying: engine.state == .playing)
                } else {
                    Text(String(position))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 24, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                if let artist = track.artist {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            TrackFormatBadge(track: track)
        }
    }
}
