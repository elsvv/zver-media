import Foundation
import ZverCore

/// Форматирование числового качества трека (битность/частота/кодек) для UI.
/// Единая точка правды, чтобы шапка альбома, плитки-версии и бейдж формата
/// одинаково округляли кГц (напр. 44100→«44.1», 96000→«96»).
enum TrackQuality {
    /// Частота в кГц без хвостовых нулей: 44100→«44.1», 96000→«96».
    static func kHzString(_ sampleRate: Double) -> String {
        let kHz = sampleRate / 1000
        return kHz == kHz.rounded() ? String(Int(kHz)) : String(format: "%.1f", kHz)
    }

    /// Компактно «24/96» (бит/кГц) — для подсказки-версии под плиткой альбома.
    /// Без битности (нет тега) — только частота «96».
    static func compact(for track: Track) -> String {
        let rate = kHzString(track.sampleRate)
        guard let bit = track.bitDepth else { return rate }
        return "\(bit)/\(rate)"
    }

    /// Качество словами для шапки альбома: «24 бит • 96 кГц • FLAC».
    /// Без битности — «96 кГц • FLAC».
    static func detailed(for track: Track) -> String {
        var parts: [String] = []
        if let bit = track.bitDepth { parts.append("\(bit) бит") }
        parts.append("\(kHzString(track.sampleRate)) кГц")
        parts.append(track.fileExtension.uppercased())
        return parts.joined(separator: " • ")
    }
}
