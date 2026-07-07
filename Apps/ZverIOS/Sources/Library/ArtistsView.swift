import SwiftUI
import ZverCore

/// Раздел «Артисты»: алфавитный список по тегу artist всех треков,
/// треки без артиста — под «Неизвестный артист» в конце.
/// Тап — экран артиста: его альбомы тем же grid-компонентом.
///
/// Варианты написания одного артиста в разном регистре («King Gizzard & the
/// lizard wizard» / «… The lizard wizard») — ОДИН артист: группировка по
/// нормализованному ключу `ArtistName.key`, отображается написание
/// большинством голосов (`ArtistName.canonical`).
struct ArtistsView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    static let unknownArtistName = "Неизвестный артист"

    /// Артист списка: нормализованный ключ (идентичность) + каноничное
    /// отображаемое написание. nil-ключ — «Неизвестный артист».
    private struct Entry: Identifiable {
        let key: String?
        let name: String
        var id: String { key ?? "" }
    }

    var body: some View {
        List(entries) { entry in
            NavigationLink {
                AlbumsGridView(
                    title: entry.name,
                    albums: albums(ofKey: entry.key),
                    store: store,
                    engine: engine
                )
            } label: {
                Text(entry.name)
            }
        }
        .navigationTitle("Артисты")
    }

    /// Уникальные артисты по алфавиту (как в Finder, без учёта регистра),
    /// «Неизвестный артист» (треки без тега) — последним.
    private var entries: [Entry] {
        var variants: [String: [String]] = [:]   // ключ → все встреченные написания
        var hasUnknown = false
        for track in store.albums.flatMap(\.tracks) {
            if let key = ArtistName.key(track.artist) {
                // Ключ есть ⟹ тег непустой; исходное написание — для canonical.
                variants[key, default: []].append(track.artist ?? "")
            } else {
                hasUnknown = true
            }
        }
        var result = variants
            .map { Entry(key: $0.key, name: ArtistName.canonical($0.value)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if hasUnknown {
            result.append(Entry(key: nil, name: Self.unknownArtistName))
        }
        return result
    }

    /// Альбомы, в которых у артиста (по нормализованному ключу) есть хотя бы
    /// один трек (nil — альбомы с треками без артиста).
    private func albums(ofKey key: String?) -> [AlbumGroup] {
        store.albums.filter { group in
            group.tracks.contains { ArtistName.key($0.artist) == key }
        }
    }
}
