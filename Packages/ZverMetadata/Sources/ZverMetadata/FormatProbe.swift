import AudioToolbox
import Foundation

public struct ProbedFormat: Equatable, Sendable {
    public let sampleRate: Double
    public let bitDepth: Int?
    public let duration: Double
}

public enum FormatProbeError: Error { case cannotOpen(OSStatus) }

public enum FormatProbe {
    public static func probe(url: URL) throws -> ProbedFormat {
        var fileID: AudioFileID?
        let st = AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID)
        guard st == noErr, let file = fileID else { throw FormatProbeError.cannotOpen(st) }
        defer { AudioFileClose(file) }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)

        var bitDepth: Int32 = 0
        size = UInt32(MemoryLayout.size(ofValue: bitDepth))
        let bdStatus = AudioFileGetProperty(file, kAudioFilePropertySourceBitDepth, &size, &bitDepth)

        var duration: Double = 0
        size = UInt32(MemoryLayout.size(ofValue: duration))
        AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)

        return ProbedFormat(sampleRate: asbd.mSampleRate,
                            bitDepth: bdStatus == noErr && bitDepth > 0 ? Int(bitDepth) : nil,
                            duration: duration)
    }
}
