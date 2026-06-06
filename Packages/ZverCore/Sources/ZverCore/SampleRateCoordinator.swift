public protocol AudioSessionControlling {
    var currentSampleRate: Double { get }
    func setPreferredSampleRate(_ rate: Double) throws
}

public struct SampleRatePlan: Equatable, Sendable {
    public let requested: Double
    public let effective: Double   // на этой частоте собирать аудиограф
    public let switched: Bool

    public init(requested: Double, effective: Double, switched: Bool) {
        self.requested = requested
        self.effective = effective
        self.switched = switched
    }
}

public enum SampleRateCoordinator {
    /// Переключает сессию на частоту файла. Всегда доверяем readback:
    /// если ЦАП не умеет частоту (или iOS наврала) — граф собираем на
    /// фактической частоте, ресемплинг сделает системный микшер.
    public static func prepare(session: AudioSessionControlling,
                               fileRate: Double) -> SampleRatePlan {
        if abs(session.currentSampleRate - fileRate) < 1.0 {
            return SampleRatePlan(requested: fileRate, effective: fileRate, switched: true)
        }
        try? session.setPreferredSampleRate(fileRate)
        let readback = session.currentSampleRate
        let ok = abs(readback - fileRate) < 1.0
        return SampleRatePlan(requested: fileRate,
                              effective: ok ? fileRate : readback,
                              switched: ok)
    }
}
