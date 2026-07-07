import AVFoundation
import Foundation

public struct AudioFileInfo: Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    /// Номер диска (1-based) из тега DISCNUMBER/disc. nil — одно-дисковый.
    public var discNumber: Int?
    /// Метка диска (`CD1`/`Side A`) — заполняет `LibraryScanner` из папки/плейлиста,
    /// не из тега файла. nil — метки нет (показываем «Диск N» по номеру).
    public var discLabel: String? = nil
    public var year: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int?
    public var artworkData: Data?
    /// Обложка из файла в папке трека (cover/folder/front/albumart).
    /// Заполняется LibraryScanner только когда нет встроенной (artworkData == nil).
    public var artworkFileURL: URL?
    public var url: URL
    /// 1-based номер трека внутри cue-шита (image+cue). nil у обычных файлов —
    /// `url` тогда сам является треком; у cue-трека `url` = контейнер (`.flac`).
    public var cueIndex: Int? = nil
    /// Смещение начала логического cue-трека в сэмплах внутри контейнера.
    /// nil у обычных файлов. `isCueTrack == (startFrame != nil)`.
    public var startFrame: Int64? = nil
    /// Длина логического cue-трека в сэмплах. Последний трек считается до конца
    /// файла (оценка по duration; плеер клампит по реальной длине). nil у обычных.
    public var frameCount: Int64? = nil
    /// Источник — DSD (`.dsf`): играть на телефоне нельзя, Мак сконвертит его в
    /// FLAC при импорте. `sampleRate` тут — частота DSD (для метки «DSD64»).
    public var isDSD: Bool = false
}

public enum MetadataReader {
    public static func read(url: URL) async throws -> AudioFileInfo {
        let probed = try FormatProbe.probe(url: url)

        // DSD (`.dsf`): AVFoundation его не читает (ни формат, ни теги). Название и
        // номер берём из имени файла («01 - Птица» → №1, «Птица»); альбом/артист
        // пользователь задаёт в превью (album-уровень), обложку сканер найдёт в
        // папке. Сами теги (если есть) перенесёт ffmpeg в итоговый FLAC.
        if probed.isDSD {
            let stem = url.deletingPathExtension().lastPathComponent
            let (number, title) = parseTrackFilename(stem)
            return AudioFileInfo(
                title: title,
                artist: nil,
                album: nil,
                trackNumber: number,
                discNumber: nil,
                year: nil,
                duration: probed.duration,
                sampleRate: probed.sampleRate,
                bitDepth: probed.bitDepth,
                artworkData: nil,
                artworkFileURL: nil,
                url: url,
                isDSD: true
            )
        }

        let asset = AVURLAsset(url: url)

        var tags: [String: String] = [:]
        var artwork: Data?

        let formats = (try? await asset.load(.availableMetadataFormats)) ?? []
        for format in formats {
            let items = (try? await asset.loadMetadata(for: format)) ?? []
            for item in items {
                let key = (item.key as? String) ?? item.commonKey?.rawValue ?? ""
                switch key.uppercased() {
                case "METADATA_BLOCK_PICTURE":
                    // Фактическое поведение (Xcode 26.3 / macOS 15): AVFoundation сам
                    // декодирует base64 и FLAC Picture-блок — dataValue это уже сырые
                    // байты картинки (PNG/JPEG magic в начале), доп. парсинг не нужен.
                    artwork = try? await item.load(.dataValue)
                default:
                    if let v = try? await item.load(.stringValue) {
                        tags[key.uppercased()] = v
                    }
                }
            }
            for item in items where item.commonKey != nil {
                if item.commonKey == .commonKeyArtwork, artwork == nil {
                    artwork = try? await item.load(.dataValue)
                }
            }
        }

        if tags["TITLE"] == nil {
            let common = (try? await asset.load(.commonMetadata)) ?? []
            for item in common {
                guard let ck = item.commonKey else { continue }
                let v = try? await item.load(.stringValue)
                switch ck {
                case .commonKeyTitle:      tags["TITLE"] = v
                case .commonKeyArtist:     tags["ARTIST"] = v
                case .commonKeyAlbumName:  tags["ALBUM"] = v
                default: break
                }
            }
        }

        return AudioFileInfo(
            title: tags["TITLE"] ?? url.deletingPathExtension().lastPathComponent,
            artist: tags["ARTIST"],
            album: tags["ALBUM"],
            trackNumber: tags["TRACKNUMBER"].flatMap { Int($0.prefix(while: \.isNumber)) },
            // Vorbis DISCNUMBER (FLAC/Ogg) или DISC; форма «1/2» и «01» → 1.
            discNumber: (tags["DISCNUMBER"] ?? tags["DISC"])
                .flatMap { Int($0.prefix(while: \.isNumber)) },
            year: tags["DATE"].flatMap { Int($0.prefix(4)) },
            duration: probed.duration,
            sampleRate: probed.sampleRate,
            bitDepth: probed.bitDepth,
            artworkData: artwork,
            artworkFileURL: nil,
            url: url
        )
    }

    /// «01 - Птица» → (1, "Птица"); «12. Foo» → (12, "Foo"); «Птица» → (nil, "Птица").
    /// Ведущие цифры — номер трека, дальше разделитель (` -._–—`) и название.
    /// Используется для DSD-файлов (у которых теги AVFoundation не читает).
    static func parseTrackFilename(_ stem: String) -> (number: Int?, title: String) {
        let trimmed = stem.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix(while: \.isNumber)
        guard !digits.isEmpty, let number = Int(digits) else { return (nil, trimmed) }
        let separators: Set<Character> = [" ", "-", "_", ".", "\u{2013}", "\u{2014}"]
        let rest = trimmed[digits.endIndex...].drop(while: { separators.contains($0) })
        let title = rest.trimmingCharacters(in: .whitespaces)
        return (number, title.isEmpty ? trimmed : title)
    }
}
