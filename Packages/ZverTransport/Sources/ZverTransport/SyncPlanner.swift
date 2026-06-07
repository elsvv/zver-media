import Foundation

/// Один файл, который дельта-планировщик решил скачать с Мака.
///
/// `albumId/fileName` — относительный путь раздачи и одновременно ключ локальной
/// карты sha. `kind` различает аудиотрек и обложку альбома: они качаются по
/// одному и тому же эндпоинту `/album/<albumId>/<fileName>`, но раскладываются и
/// сверяются по-разному (трек идёт в библиотеку, обложка — рядом как файл).
public struct PlannedFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case track
        case artwork
    }

    public var albumId: String
    public var fileName: String
    public var sha256: String
    public var fileSize: Int
    public var kind: Kind

    public init(albumId: String, fileName: String, sha256: String, fileSize: Int, kind: Kind) {
        self.albumId = albumId
        self.fileName = fileName
        self.sha256 = sha256
        self.fileSize = fileSize
        self.kind = kind
    }

    /// Относительный путь раздачи `"<albumId>/<fileName>"` — ключ в `localShasByPath`.
    public var relativePath: String {
        SyncPlanner.relativePath(albumId: albumId, fileName: fileName)
    }
}

/// Результат планирования: что докачать и какие альбомы уже целиком на месте.
///
/// `alreadyComplete` (только `albumId`-ы) даёт право немедленно подтвердить
/// альбом Маку (`POST /confirm`) без единой загрузки.
public struct SyncPlan: Equatable, Sendable {
    public var toFetch: [PlannedFile]
    public var alreadyComplete: [String]

    public init(toFetch: [PlannedFile], alreadyComplete: [String]) {
        self.toFetch = toFetch
        self.alreadyComplete = alreadyComplete
    }
}

/// Чистый дельта-планировщик синка: сравнивает манифест Мака с локально лежащими
/// файлами и решает, что докачать. Без сети и диска — вся логика проверяема.
public enum SyncPlanner {
    /// Строит план загрузки.
    ///
    /// - Parameters:
    ///   - manifest: манифест Мака (источник истины о составе альбомов).
    ///   - localShasByPath: sha256 уже лежащих локально файлов по относительному
    ///     пути `"<albumId>/<fileName>"`. Посторонние ключи (например sidecar
    ///     `album.zvermeta.json`) игнорируются — план смотрит только на файлы из
    ///     манифеста.
    /// - Returns: `SyncPlan` с файлами на докачку и списком уже полных альбомов.
    ///
    /// Файл попадает в `toFetch`, если его пути нет локально ИЛИ локальный sha не
    /// совпадает с манифестом (идемпотентность/докачка: совпавшие пропускаются).
    /// Альбом попадает в `alreadyComplete`, когда ВСЕ его треки и обложка (если
    /// задана) уже совпадают.
    public static func plan(manifest: SyncManifest,
                            localShasByPath: [String: String]) -> SyncPlan {
        var toFetch: [PlannedFile] = []
        var alreadyComplete: [String] = []

        for album in manifest.albums {
            var albumComplete = true

            for track in album.tracks {
                let path = relativePath(albumId: album.id, fileName: track.fileName)
                if localShasByPath[path] != track.sha256 {
                    toFetch.append(PlannedFile(
                        albumId: album.id,
                        fileName: track.fileName,
                        sha256: track.sha256,
                        fileSize: track.fileSize,
                        kind: .track
                    ))
                    albumComplete = false
                }
            }

            if let artwork = album.artwork {
                let path = relativePath(albumId: album.id, fileName: artwork.fileName)
                if localShasByPath[path] != artwork.sha256 {
                    toFetch.append(PlannedFile(
                        albumId: album.id,
                        fileName: artwork.fileName,
                        sha256: artwork.sha256,
                        fileSize: artwork.fileSize,
                        kind: .artwork
                    ))
                    albumComplete = false
                }
            }

            if albumComplete {
                alreadyComplete.append(album.id)
            }
        }

        return SyncPlan(toFetch: toFetch, alreadyComplete: alreadyComplete)
    }

    /// Относительный путь раздачи и ключ локальной карты sha.
    static func relativePath(albumId: String, fileName: String) -> String {
        "\(albumId)/\(fileName)"
    }
}
