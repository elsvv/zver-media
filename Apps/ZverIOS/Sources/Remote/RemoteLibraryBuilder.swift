import Foundation
import ZverCore
import ZverTransport

/// Чистый маппинг каталога iPhone (`[AlbumGroup]`/`[Track]`) в DTO протокола
/// пульта (`RemoteLibrary`/`RemoteAlbum`/`RemoteTrack`) и обратно — резолв
/// `albumId` в локальные `Track` для запуска альбома.
///
/// Без сети, без `@MainActor`, без сторонних эффектов — чистые функции, удобные
/// для повторного использования и (при желании) для TDD. `AlbumGroup` не несёт
/// собственного `id`, поэтому идентификатор альбома выводится детерминированно из
/// пары `artist|album` (стабилен между пушами и запросами, пока каталог тот же).
/// Mac получает только метадату; локальные URL/файлы наружу не уходят.
enum RemoteLibraryBuilder {
    /// Выводит стабильный идентификатор альбома из его группы.
    ///
    /// `AlbumGroup` уникален парой (артист, название) в пределах каталога
    /// (см. `AlbumGroup.group`). Кодируем обе части, разделяя управляющим
    /// `\u{1}`, который в тегах не встречается — так «Artist|Album» и
    /// «Artist|» + «Album» не схлопываются.
    static func albumId(for group: AlbumGroup) -> String {
        albumId(artist: group.artist, album: group.album)
    }

    /// Тот же идентификатор из артиста и названия — для резолва без группы.
    static func albumId(artist: String?, album: String) -> String {
        (artist ?? "") + "\u{1}" + album
    }

    /// Лёгкий список альбомов библиотеки (без треков — те тянутся по
    /// `requestAlbumTracks`, чтобы не слать всю библиотеку зараз).
    static func library(from groups: [AlbumGroup]) -> RemoteLibrary {
        RemoteLibrary(albums: groups.map(remoteAlbum(from:)))
    }

    /// Запись альбома для списка: id/title/artist/year/trackCount. `year` —
    /// из первого трека группы (год альбома в MVP).
    static func remoteAlbum(from group: AlbumGroup) -> RemoteAlbum {
        RemoteAlbum(
            id: albumId(for: group),
            title: group.album,
            artist: group.artist,
            year: group.tracks.first?.year,
            trackCount: group.tracks.count
        )
    }

    /// DTO трека для протокола. `id` — стабильный путь файла (`Track.id`),
    /// который iPhone резолвит обратно при `playAlbum`; Mac его не видит как URL.
    static func remoteTrack(from track: Track) -> RemoteTrack {
        RemoteTrack(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            sampleRate: Int(track.sampleRate.rounded()),
            bitDepth: track.bitDepth
        )
    }

    /// Находит группу альбома по идентификатору (или nil, если каталог изменился
    /// и альбом исчез — пульт получит пустой ответ/ошибку, соединение живёт).
    static func group(withId albumId: String, in groups: [AlbumGroup]) -> AlbumGroup? {
        groups.first { self.albumId(for: $0) == albumId }
    }

    /// Треки альбома в порядке группы (как сгруппировал `AlbumGroup.group`).
    static func tracks(forAlbumId albumId: String, in groups: [AlbumGroup]) -> [RemoteTrack] {
        guard let group = group(withId: albumId, in: groups) else { return [] }
        return group.tracks.map(remoteTrack(from:))
    }

    /// Резолвит `playAlbum(albumId, startIndex)` в локальные `Track` и
    /// нормализованный индекс старта для `PlayerEngine.play(tracks:startAt:)`.
    /// nil — альбома нет в каталоге. `startIndex` клампится в границы списка.
    static func resolvePlayAlbum(albumId: String,
                                 startIndex: Int,
                                 in groups: [AlbumGroup]) -> (tracks: [Track], startIndex: Int)? {
        guard let group = group(withId: albumId, in: groups), !group.tracks.isEmpty else {
            return nil
        }
        let clamped = min(max(startIndex, 0), group.tracks.count - 1)
        return (group.tracks, clamped)
    }
}
