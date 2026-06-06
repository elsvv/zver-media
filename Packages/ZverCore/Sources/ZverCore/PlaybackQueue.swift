public struct PlaybackQueue: Equatable, Sendable {
    public private(set) var tracks: [Track] = []
    public private(set) var currentIndex: Int? = nil

    public init() {}

    public var current: Track? { currentIndex.map { tracks[$0] } }

    public mutating func start(tracks: [Track], at index: Int) {
        self.tracks = tracks
        self.currentIndex = tracks.isEmpty ? nil : min(max(index, 0), tracks.count - 1)
    }

    @discardableResult
    public mutating func advance() -> Track? {
        guard let i = currentIndex else { return nil }
        guard i + 1 < tracks.count else { currentIndex = nil; return nil }
        currentIndex = i + 1
        return current
    }

    @discardableResult
    public mutating func goBack() -> Track? {
        guard let i = currentIndex else { return nil }
        currentIndex = max(i - 1, 0)
        return current
    }
}
