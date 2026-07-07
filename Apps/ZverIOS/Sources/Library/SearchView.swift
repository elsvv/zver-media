import SwiftUI
import ZverCore

/// Экран «Поиск»: запрос через .searchable, результаты из каталога
/// (подстрока в title/artist/album) секциями Артисты / Альбомы / Песни.
/// Тап по песне — воспроизведение с очередью из найденных песен,
/// по артисту/альбому — навигация на их экраны.
struct SearchView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    @State private var query = ""
    @State private var results: [Track] = []

    var body: some View {
        content
            .navigationTitle("Поиск")
            .searchable(text: $query, prompt: "Артисты, альбомы, песни")
            // Локальная БД — debounce не нужен: задача перезапускается
            // на каждое изменение запроса, предыдущая отменяется.
            .task(id: query) {
                let found = await store.search(query: query)
                // Чтение БД не отменяется вместе с задачей: устаревший
                // запрос не должен перетирать результат более нового.
                if !Task.isCancelled { results = found }
            }
            // Поиск может оказаться первым открытым экраном: секции
            // «Артисты»/«Альбомы» строятся из store.albums — нужен
            // опубликованный каталог (guard от параллельных refresh внутри).
            .task { await store.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search
        } else if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            resultsList
        }
    }

    private var resultsList: some View {
        List {
            if !artists.isEmpty {
                Section("Артисты") {
                    ForEach(artists, id: \.self) { artist in
                        NavigationLink {
                            AlbumsGridView(title: artist,
                                           albums: albums(of: artist),
                                           store: store,
                                           engine: engine)
                        } label: {
                            Label(artist, systemImage: "music.mic")
                        }
                    }
                }
            }
            if !albums.isEmpty {
                Section("Альбомы") {
                    ForEach(albums) { group in
                        NavigationLink {
                            AlbumDetailView(group: group, store: store, engine: engine)
                        } label: {
                            albumRow(group)
                        }
                    }
                }
            }
            Section("Песни") {
                ForEach(Array(results.enumerated()), id: \.element.id) { index, track in
                    Button {
                        engine.play(tracks: results, startAt: index)
                    } label: {
                        trackRow(track)
                    }
                    .addToPlaylistMenu(for: track, store: store)
                }
            }
        }
    }

    /// Уникальные артисты найденных треков по алфавиту. Написания одного
    /// артиста в разном регистре схлопываются в один пункт (ключ
    /// `ArtistName.key`, показывается каноничное написание) — как в разделе
    /// «Артисты». Треки без тега в секцию не попадают.
    private var artists: [String] {
        var variants: [String: [String]] = [:]
        for track in results {
            guard let key = ArtistName.key(track.artist) else { continue }
            variants[key, default: []].append(track.artist ?? "")
        }
        return variants.values
            .map { ArtistName.canonical($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Полные группы альбомов библиотеки, чьи имена встречаются среди
    /// найденных треков: навигация ведёт на альбом целиком, а не на его
    /// совпавшую часть. store.albums уже отсортирован по алфавиту.
    private var albums: [AlbumGroup] {
        let names = Set(results.compactMap(\.album).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        return store.albums.filter { names.contains($0.album) }
    }

    /// Экран артиста: его альбомы из всей библиотеки — по нормализованному
    /// ключу, а не точному совпадению (та же логика, что в ArtistsView).
    private func albums(of artist: String) -> [AlbumGroup] {
        let key = ArtistName.key(artist)
        return store.albums.filter { group in
            group.tracks.contains { ArtistName.key($0.artist) == key }
        }
    }

    private func albumRow(_ group: AlbumGroup) -> some View {
        HStack(spacing: 12) {
            AlbumArtworkView(track: group.tracks.first,
                             loader: engine.artworkLoader,
                             cornerRadius: 6)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.album)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(group.artist ?? ArtistsView.unknownArtistName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func trackRow(_ track: Track) -> some View {
        let isCurrent = engine.isCurrent(track)
        return HStack {
            if isCurrent {
                NowPlayingIndicator(isPlaying: engine.state == .playing)
            }
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
