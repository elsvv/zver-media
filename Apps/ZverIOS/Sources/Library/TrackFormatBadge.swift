import SwiftUI
import ZverCore

/// Бейдж формата «FLAC 24/96»: расширение верхним регистром,
/// битность (если есть) и частота в kHz. Общий для всех списков треков.
struct TrackFormatBadge: View {
    let track: Track

    var body: some View {
        Text(Self.text(for: track))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
    }

    static func text(for track: Track) -> String {
        let kHz = track.sampleRate / 1000
        let rate = kHz == kHz.rounded() ? String(Int(kHz)) : String(format: "%.1f", kHz)
        let ext = track.fileExtension.uppercased()
        if let bitDepth = track.bitDepth {
            return "\(ext) \(bitDepth)/\(rate)"
        }
        return "\(ext) \(rate)"
    }
}
