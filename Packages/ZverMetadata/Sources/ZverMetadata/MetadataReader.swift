import AVFoundation
import Foundation

public struct AudioFileInfo: Sendable {
    public var title: String
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var duration: Double
    public var sampleRate: Double
    public var bitDepth: Int?
    public var artworkData: Data?
    /// Обложка из файла в папке трека (cover/folder/front/albumart).
    /// Заполняется LibraryScanner только когда нет встроенной (artworkData == nil).
    public var artworkFileURL: URL?
    public var url: URL
}

public enum MetadataReader {
    public static func read(url: URL) async throws -> AudioFileInfo {
        let probed = try FormatProbe.probe(url: url)
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
            year: tags["DATE"].flatMap { Int($0.prefix(4)) },
            duration: probed.duration,
            sampleRate: probed.sampleRate,
            bitDepth: probed.bitDepth,
            artworkData: artwork,
            artworkFileURL: nil,
            url: url
        )
    }
}
