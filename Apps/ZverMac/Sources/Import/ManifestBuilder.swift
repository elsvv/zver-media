import Foundation
import ZverTransport

/// App-glue: собирает `ManifestAlbum`/`SyncManifest` из `AlbumDraft`.
///
/// Чистая логика идентичности (`AlbumIdentity`) и SHA-256 (`Sha256`) живут в
/// `ZverTransport` и покрыты тестами там; здесь только сбор данных. Хеширование
/// файлов — потоковое с диска (`Sha256.hash(fileURL:)`), пригодно для hi-res.
///
/// Билдер не редактирует и не копирует исходные файлы: только читает их для
/// размера и контент-хеша.
enum ManifestBuilder {
    enum BuildError: Error {
        case fileUnreadable(URL)
    }

    /// Снимок данных черновика, безопасный для передачи на фоновую очередь
    /// (значения скопированы из `@MainActor`-модели до ухода с главного потока).
    struct DraftSnapshot: Sendable {
        var albumId: String
        var title: String
        var artist: String?
        var year: Int?
        var sourceFolder: URL
        var artworkFileName: String?
        var playlistFileName: String?
        var tracks: [TrackSnapshot]

        struct TrackSnapshot: Sendable {
            var fileURL: URL
            var fileName: String
            /// Путь относительно корня альбома — едет в манифест как `fileName`.
            var relativePath: String
            var fileExtension: String
            var title: String
            var artist: String?
            var album: String?
            var trackNumber: Int?
            var discNumber: Int?
            var year: Int?
            var duration: Double
            var sampleRate: Double
            var bitDepth: Int?
        }
    }

    /// Строит `ManifestAlbum` из снимка черновика: считает SHA-256 и размер
    /// каждого аудиофайла и обложки. Бросает `BuildError.fileUnreadable`, если
    /// файл недоступен (целостность важнее частичного манифеста).
    static func buildAlbum(from snapshot: DraftSnapshot) throws -> ManifestAlbum {
        let tracks = try snapshot.tracks.map { track -> ManifestTrack in
            let (sha, size) = try hashAndSize(of: track.fileURL)
            return ManifestTrack(
                // fileName несёт относительный путь внутри альбома (`CD1/01 - x.flac`),
                // чтобы структура папок сохранилась на телефоне.
                fileName: track.relativePath,
                title: track.title,
                artist: track.artist.nilIfBlank,
                album: track.album.nilIfBlank,
                trackNumber: track.trackNumber,
                discNumber: track.discNumber,
                year: track.year,
                duration: track.duration,
                sampleRate: Int(track.sampleRate.rounded()),
                bitDepth: track.bitDepth,
                fileSize: size,
                sha256: sha,
                fileExtension: track.fileExtension
            )
        }

        var artwork: ManifestArtwork?
        if let artworkFileName = snapshot.artworkFileName {
            let artworkURL = snapshot.sourceFolder
                .appendingPathComponent(artworkFileName)
            let (sha, size) = try hashAndSize(of: artworkURL)
            artwork = ManifestArtwork(
                fileName: artworkFileName, sha256: sha, fileSize: size)
        }

        var playlist: ManifestFile?
        if let playlistFileName = snapshot.playlistFileName {
            let playlistURL = snapshot.sourceFolder
                .appendingPathComponent(playlistFileName)
            let (sha, size) = try hashAndSize(of: playlistURL)
            playlist = ManifestFile(
                fileName: playlistFileName, sha256: sha, fileSize: size)
        }

        return ManifestAlbum(
            id: snapshot.albumId,
            title: snapshot.title,
            artist: snapshot.artist.nilIfBlank,
            year: snapshot.year,
            artwork: artwork,
            playlist: playlist,
            tracks: tracks
        )
    }

    /// Собирает полный `SyncManifest` (текущая версия протокола) из нескольких
    /// готовых альбомов.
    static func buildManifest(albums: [ManifestAlbum]) -> SyncManifest {
        SyncManifest(albums: albums)
    }

    /// SHA-256 (потоково) и размер файла за один проход доступа к ФС.
    private static func hashAndSize(of url: URL) throws -> (sha: String, size: Int) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize else {
            throw BuildError.fileUnreadable(url)
        }
        let sha: String
        do {
            sha = try Sha256.hash(fileURL: url)
        } catch {
            throw BuildError.fileUnreadable(url)
        }
        return (sha, size)
    }
}

private extension Optional where Wrapped == String {
    /// nil, если строка пуста или состоит из пробелов; иначе тримленное значение.
    var nilIfBlank: String? {
        guard let self else { return nil }
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension String {
    /// nil, если строка пуста или состоит из пробелов; иначе тримленное значение.
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
