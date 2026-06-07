import SwiftUI
import ZverCore

/// Раздел «Артисты»: алфавитный список по тегу artist всех треков,
/// треки без артиста — под «Неизвестный артист» в конце.
/// Тап — экран артиста: его альбомы тем же grid-компонентом.
struct ArtistsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    static let unknownArtistName = "Неизвестный артист"

    var body: some View {
        List(artists, id: \.self) { artist in
            NavigationLink {
                AlbumsGridView(
                    title: artist ?? Self.unknownArtistName,
                    albums: albums(of: artist),
                    store: store,
                    engine: engine
                )
            } label: {
                Text(artist ?? Self.unknownArtistName)
            }
        }
        .navigationTitle("Артисты")
    }

    /// Уникальные артисты по алфавиту (как в Finder, без учёта регистра),
    /// nil (нет тега) — последним.
    private var artists: [String?] {
        let names = Set(store.albums.flatMap(\.tracks).map { Self.normalizedArtist($0.artist) })
        var result: [String?] = names
            .compactMap { $0 }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if names.contains(nil) {
            result.append(nil)
        }
        return result
    }

    /// Альбомы, в которых у артиста есть хотя бы один трек
    /// (nil — альбомы с треками без артиста).
    private func albums(of artist: String?) -> [AlbumGroup] {
        store.albums.filter { group in
            group.tracks.contains { Self.normalizedArtist($0.artist) == artist }
        }
    }

    /// Пустой или пробельный тег артиста — отсутствие артиста
    /// (та же нормализация, что у альбомов в AlbumGroup).
    private static func normalizedArtist(_ artist: String?) -> String? {
        guard let artist,
              !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return artist
    }
}
