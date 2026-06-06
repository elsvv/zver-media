import AVFAudio
import ZverCore

/// Реальный AVAudioSession за протоколом из ZverCore.
struct SystemAudioSession: AudioSessionControlling {
    var currentSampleRate: Double { AVAudioSession.sharedInstance().sampleRate }
    func setPreferredSampleRate(_ rate: Double) throws {
        try AVAudioSession.sharedInstance().setPreferredSampleRate(rate)
    }
}
