import Testing
@testable import ZverCore

final class MockSession: AudioSessionControlling {
    var currentSampleRate: Double
    var supported: Set<Double>          // что «умеет» ЦАП
    var setCalls: [Double] = []
    var readbackLies = false            // имитация бага iOS 18.0

    init(rate: Double, supported: Set<Double>) {
        self.currentSampleRate = rate
        self.supported = supported
    }
    func setPreferredSampleRate(_ rate: Double) throws {
        setCalls.append(rate)
        if supported.contains(rate) && !readbackLies { currentSampleRate = rate }
    }
}

@Suite struct SampleRateCoordinatorTests {
    @Test func switchesToFileRateWhenSupported() {
        let s = MockSession(rate: 44100, supported: [44100, 48000, 96000, 192000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 96000)
        #expect(plan.effective == 96000)
        #expect(plan.switched)
    }
    @Test func fallsBackToReadbackWhenUnsupported() {
        let s = MockSession(rate: 48000, supported: [44100, 48000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 192000)
        #expect(plan.effective == 48000)   // граф соберём на фактической
        #expect(!plan.switched)
    }
    @Test func noSetCallWhenAlreadyAtFileRate() {
        let s = MockSession(rate: 96000, supported: [96000])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 96000)
        #expect(s.setCalls.isEmpty)        // не дёргаем сессию зря
        #expect(plan.effective == 96000)
    }
    @Test func toleratesTinyRateDifference() {
        let s = MockSession(rate: 44099.9999, supported: [])
        let plan = SampleRateCoordinator.prepare(session: s, fileRate: 44100)
        #expect(plan.switched)             // |дельта| < 1 Гц — считаем совпадением
    }
}
