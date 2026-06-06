import Combine
import Foundation
import ZverCore
import ZverMetadata

/// Источник данных библиотеки: скан Documents → [Track] → группы по альбомам.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums: [AlbumGroup] = []

    /// Пересканирует папку Documents и перегруппировывает альбомы.
    /// Вызывается при старте и по pull-to-refresh.
    func refresh() async {
        let infos = (try? await LibraryScanner.scan(directory: URL.documentsDirectory)) ?? []
        albums = AlbumGroup.group(infos.map(Self.makeTrack))
    }

    private static func makeTrack(_ info: AudioFileInfo) -> Track {
        Track(url: info.url,
              title: info.title,
              artist: info.artist,
              album: info.album,
              trackNumber: info.trackNumber,
              year: info.year,
              duration: info.duration,
              sampleRate: info.sampleRate,
              bitDepth: info.bitDepth)
    }
}
