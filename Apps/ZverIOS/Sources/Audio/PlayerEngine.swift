import AVFAudio
import Combine
import ZverCore

@MainActor
final class PlayerEngine: ObservableObject {
    enum State: Equatable { case idle, playing, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var currentTime: Double = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var startFrame: AVAudioFramePosition = 0
    private var timeObserver: Timer?
    private let session: AudioSessionControlling

    /// Completion-handler scheduleFile/scheduleSegment вызывается и при ручном
    /// player.stop(). Поколение инкрементируется перед каждым stop/новой
    /// загрузкой — устаревший completion игнорируется, next() срабатывает
    /// только когда трек действительно дослушан.
    private var generation = 0

    init(session: AudioSessionControlling = SystemAudioSession()) {
        self.session = session
        engine.attach(player)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    func play(tracks: [Track], startAt index: Int) {
        queue.start(tracks: tracks, at: index)
        if let track = queue.current {
            loadAndPlay(track)
        } else {
            stopPlayback()
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            player.pause()
            state = .paused
        case .paused:
            if !engine.isRunning {
                try? engine.start()
            }
            player.play()
            state = .playing
        case .idle:
            break
        }
    }

    func next() {
        if let track = queue.advance() {
            loadAndPlay(track)
        } else {
            stopPlayback()
        }
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else if let track = queue.goBack() {
            loadAndPlay(track)
        }
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition((seconds * sampleRate).rounded())
        let clampedFrame = min(max(targetFrame, 0), max(file.length - 1, 0))
        let remainingFrames = AVAudioFrameCount(file.length - clampedFrame)
        guard remainingFrames > 0 else { return }

        generation &+= 1
        let gen = generation
        let wasPlaying = state == .playing

        player.stop()
        startFrame = clampedFrame
        currentTime = Double(clampedFrame) / sampleRate

        player.scheduleSegment(file, startingFrame: clampedFrame,
                               frameCount: remainingFrames, at: nil) { [weak self] in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }
        if wasPlaying {
            if !engine.isRunning {
                try? engine.start()
            }
            player.play()
        }
    }

    private func loadAndPlay(_ track: Track) {
        generation &+= 1
        let gen = generation

        // 1. Открыть файл; ошибка → пропустить трек.
        let loadedFile: AVAudioFile
        do {
            loadedFile = try AVAudioFile(forReading: track.url)
        } catch {
            next()
            return
        }
        file = loadedFile
        startFrame = 0
        currentTime = 0

        // 2. Согласовать частоту сессии с файлом (bit-perfect, если ЦАП умеет).
        player.stop()
        engine.stop()
        _ = SampleRateCoordinator.prepare(session: session,
                                          fileRate: loadedFile.fileFormat.sampleRate)
        try? AVAudioSession.sharedInstance().setActive(true)

        // 3. Пересбор графа под формат файла.
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: loadedFile.processingFormat)

        // 4. Запланировать файл; completion → следующий трек.
        player.scheduleFile(loadedFile, at: nil) { [weak self] in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }

        // 5. Старт.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopPlayback()
            return
        }
        player.play()
        state = .playing

        // 6. Таймер позиции.
        startTimeObserver()
    }

    private func handleTrackFinished(generation gen: Int) {
        guard gen == generation else { return }
        next()
    }

    private func stopPlayback() {
        generation &+= 1
        player.stop()
        engine.stop()
        file = nil
        startFrame = 0
        timeObserver?.invalidate()
        timeObserver = nil
        currentTime = 0
        state = .idle
    }

    private func startTimeObserver() {
        timeObserver?.invalidate()
        timeObserver = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCurrentTime() }
        }
    }

    private func updateCurrentTime() {
        guard state == .playing,
              let file,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return }
        let frames = max(playerTime.sampleTime, 0) + startFrame
        currentTime = Double(frames) / file.processingFormat.sampleRate
    }
}
