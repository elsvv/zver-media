import Testing
import Foundation
@testable import ZverTransport

/// Чистый троттлер/диф состояния: эмитим `state` только при значимом изменении
/// (смена трека/playback/очереди/индекса) ИЛИ при сдвиге позиции ≥ порога.
@Suite struct RemoteStateDiffTests {
    private let threshold = 0.5

    private func track(_ id: String, duration: Double = 100) -> RemoteTrack {
        RemoteTrack(id: id, title: id, duration: duration)
    }

    private func state(playback: RemotePlayback = .playing,
                       current: RemoteTrack?,
                       position: Double,
                       queue: [RemoteTrack],
                       currentIndex: Int?) -> RemotePlayerState {
        RemotePlayerState(playback: playback, current: current, position: position,
                          queue: queue, currentIndex: currentIndex)
    }

    @Test func emitsWhenNoPreviousState() {
        let next = state(current: track("a"), position: 0, queue: [track("a")], currentIndex: 0)
        #expect(RemoteStateDiff.shouldEmit(prev: nil, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnTrackChange() {
        let prev = state(current: track("a"), position: 10, queue: [track("a"), track("b")], currentIndex: 0)
        let next = state(current: track("b"), position: 10, queue: [track("a"), track("b")], currentIndex: 1)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnPlaybackChange() {
        let prev = state(playback: .playing, current: track("a"), position: 10, queue: [track("a")], currentIndex: 0)
        let next = state(playback: .paused, current: track("a"), position: 10, queue: [track("a")], currentIndex: 0)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnQueueChange() {
        let prev = state(current: track("a"), position: 10, queue: [track("a")], currentIndex: 0)
        let next = state(current: track("a"), position: 10, queue: [track("a"), track("b")], currentIndex: 0)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnCurrentIndexChange() {
        let q = [track("a"), track("a")]
        let prev = state(current: track("a"), position: 10, queue: q, currentIndex: 0)
        let next = state(current: track("a"), position: 10, queue: q, currentIndex: 1)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnPositionShiftAtOrAboveThreshold() {
        let prev = state(current: track("a"), position: 10.0, queue: [track("a")], currentIndex: 0)
        let next = state(current: track("a"), position: 10.5, queue: [track("a")], currentIndex: 0)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func emitsOnLargeBackwardPositionShift() {
        let prev = state(current: track("a"), position: 50.0, queue: [track("a")], currentIndex: 0)
        let next = state(current: track("a"), position: 10.0, queue: [track("a")], currentIndex: 0)
        #expect(RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func silentOnMicroPositionShift() {
        // Позицию Mac интерполирует сам — не флудим пушами на каждый тик.
        let prev = state(current: track("a"), position: 10.0, queue: [track("a")], currentIndex: 0)
        let next = state(current: track("a"), position: 10.3, queue: [track("a")], currentIndex: 0)
        #expect(!RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func silentOnIdenticalState() {
        let s = state(current: track("a"), position: 10.0, queue: [track("a")], currentIndex: 0)
        #expect(!RemoteStateDiff.shouldEmit(prev: s, next: s, positionThreshold: threshold))
    }

    @Test func positionShiftJustBelowThresholdIsSilent() {
        let prev = state(current: track("a"), position: 10.0, queue: [track("a")], currentIndex: 0)
        let next = state(current: track("a"), position: 10.0 + threshold - 0.0001,
                         queue: [track("a")], currentIndex: 0)
        #expect(!RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }

    @Test func nilToNilCurrentWithSamePlaybackAndQueueIsSilent() {
        let prev = state(playback: .idle, current: nil, position: 0, queue: [], currentIndex: nil)
        let next = state(playback: .idle, current: nil, position: 0, queue: [], currentIndex: nil)
        #expect(!RemoteStateDiff.shouldEmit(prev: prev, next: next, positionThreshold: threshold))
    }
}
