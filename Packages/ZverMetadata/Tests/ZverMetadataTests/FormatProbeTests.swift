import Testing
import Foundation
@testable import ZverMetadata

func fixture(_ name: String) -> URL {
    Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
}

@Suite struct FormatProbeTests {
    @Test func probesHiResFlac() throws {
        let info = try FormatProbe.probe(url: fixture("hires_24_96.flac"))
        #expect(info.sampleRate == 96000)
        #expect(info.bitDepth == 24)
        #expect(abs(info.duration - 1.0) < 0.1)
    }
    @Test func probesCdQualityFlac() throws {
        let info = try FormatProbe.probe(url: fixture("tagged_16_44.flac"))
        #expect(info.sampleRate == 44100)
        #expect(info.bitDepth == 16)
    }
    @Test func probesAlac() throws {
        let info = try FormatProbe.probe(url: fixture("alac.m4a"))
        #expect(info.sampleRate == 44100)
    }
    @Test func throwsOnGarbage() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x.flac")
        try? Data("не аудио".utf8).write(to: tmp)
        #expect(throws: (any Error).self) { try FormatProbe.probe(url: tmp) }
    }
}
