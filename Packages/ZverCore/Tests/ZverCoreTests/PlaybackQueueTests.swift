import Foundation
import Testing
@testable import ZverCore

private func makeTrack(_ n: Int) -> Track {
    Track(url: URL(fileURLWithPath: "/t/\(n).flac"), title: "T\(n)",
          duration: 60, sampleRate: 44100)
}

@Suite struct PlaybackQueueTests {
    @Test func startSetsCurrent() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 0)
        #expect(q.current?.title == "T1")
    }
    @Test func advanceMovesForwardAndStopsAtEnd() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 0)
        #expect(q.advance()?.title == "T2")
        #expect(q.advance() == nil)          // конец очереди
        #expect(q.current == nil)
    }
    @Test func goBackMovesBackAndClampsAtStart() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1), makeTrack(2)], at: 1)
        #expect(q.goBack()?.title == "T1")
        #expect(q.goBack()?.title == "T1")   // не уходит ниже 0
    }
    @Test func startAtIndexOutOfBoundsClamps() {
        var q = PlaybackQueue()
        q.start(tracks: [makeTrack(1)], at: 5)
        #expect(q.current?.title == "T1")
    }
}
