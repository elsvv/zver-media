import AVFAudio
import Combine
import UIKit
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
    private let nowPlaying = NowPlayingService()

    /// Общий кэш обложек: им же пользуются MiniPlayerBar и PlayerScreen.
    let artworkLoader = ArtworkLoader()
    private var currentArtwork: UIImage?
    private var artworkTask: Task<Void, Never>?

    /// Completion-handler scheduleFile/scheduleSegment (даже с .dataPlayedBack)
    /// вызывается и при ручном player.stop(). Поколение инкрементируется перед
    /// каждым stop/новой загрузкой — устаревший completion игнорируется, переход
    /// к следующему треку срабатывает только когда трек действительно дослушан.
    private var generation = 0

    /// Файл следующего трека, предзапланированный в очередь ноды (gapless).
    /// nil — следующего трека нет или его формат отличается от текущего.
    /// player.stop() чистит очередь ноды — вместе с ним обнуляется и это поле.
    private var prescheduledFile: AVAudioFile?

    /// Кадровая позиция ноды на момент начала текущего файла. При gapless-переходе
    /// нода не останавливается и её sampleTime растёт сквозь треки — база
    /// вычитается при расчёте currentTime. Обнуляется при каждом player.stop()
    /// (sampleTime ноды после него начинается заново с нуля).
    private var sampleTimeBase: AVAudioFramePosition = 0

    /// Играли ли на момент начала прерывания (звонок, Siri) —
    /// чтобы после .ended с .shouldResume продолжить только если играли.
    private var wasPlayingBeforeInterruption = false

    /// После .newDeviceAvailable граф остаётся собранным под частоту старого
    /// устройства — пересобрать при следующем воспроизведении.
    private var needsGraphRebuild = false

    /// Был ли на выходе внешний приёмник (ЦАП/наушники/BT) на момент последней
    /// сборки графа или route change. Порядок configurationChange и
    /// routeChange(.oldDeviceUnavailable) не документирован: если первым придёт
    /// configurationChange, state ещё .playing, и авто-резюм успел бы заиграть
    /// в динамик до pause() из handleRouteChange. Снимок маршрута отличает
    /// «выдернули устройство, звук упал на динамик» (играть нельзя) от смены
    /// конфигурации самого динамика (продолжаем).
    private var wasOnExternalOutput = false

    init(session: AudioSessionControlling = SystemAudioSession()) {
        self.session = session
        engine.attach(player)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        nowPlaying.wire(to: self)
        subscribeToSessionNotifications()
    }

    /// Реакции на системные события: выдернули ЦАП/наушники, звонок,
    /// смена конфигурации движка. PlayerEngine живёт всё время жизни
    /// приложения, блоки держат self слабо — токены подписок не храним.
    private func subscribeToSessionNotifications() {
        let center = NotificationCenter.default
        let audioSession = AVAudioSession.sharedInstance()

        _ = center.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: audioSession, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
            Task { @MainActor in self?.handleRouteChange(reason) }
        }

        _ = center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: audioSession, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            Task { @MainActor in self?.handleInterruption(type, options: options) }
        }

        _ = center.addObserver(forName: .AVAudioEngineConfigurationChange,
                               object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationChange() }
        }
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // Выдернули ЦАП/наушники — не продолжаем играть в динамик.
            pause()
        case .newDeviceAvailable:
            needsGraphRebuild = true
        default:
            break
        }
        wasOnExternalOutput = Self.routeHasExternalOutput()
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType,
                                    options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            wasPlayingBeforeInterruption = state == .playing
            pause()
        case .ended:
            if wasPlayingBeforeInterruption, options.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                resume()
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleConfigurationChange() {
        // Движок останавливает себя при смене частоты/каналов железа —
        // пересобираем граф и продолжаем с текущей позиции, если играли.
        guard file != nil else { return }
        needsGraphRebuild = false
        // Выход упал с внешнего устройства на встроенный динамик — значит,
        // устройство выдернули, а routeChange(.oldDeviceUnavailable) мог ещё
        // не прийти (state ещё .playing). Пересобираем граф в паузе,
        // возобновление за пользователем — никакого всплеска в динамик.
        if wasOnExternalOutput, !Self.routeHasExternalOutput() {
            pause()
        }
        rebuildGraph(resumeFrom: currentTime, andPlay: state == .playing)
    }

    /// Есть ли в текущем маршруте вывод, отличный от встроенного динамика
    /// (ЦАП, наушники, Bluetooth, AirPlay).
    private static func routeHasExternalOutput() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs
            .contains { $0.portType != .builtInSpeaker }
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
        case .playing: pause()
        case .paused: resume()
        case .idle: break
        }
    }

    func pause() {
        guard state == .playing else { return }
        player.pause()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard state == .paused else { return }
        if needsGraphRebuild {
            // Появилось новое устройство вывода — собрать граф под его частоту.
            needsGraphRebuild = false
            rebuildGraph(resumeFrom: currentTime, andPlay: true)
            return
        }
        if !engine.isRunning {
            try? engine.start()
        }
        // player.play() на незапущенном движке кидает NSException —
        // если движок не стартовал (например, прерывание сессии),
        // остаёмся в .paused.
        guard engine.isRunning else { return }
        player.play()
        state = .playing
        updateNowPlaying()
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
        reschedule(from: seconds, andPlay: state == .playing)
    }

    /// Останавливает плеер, заново планирует сегмент текущего файла с позиции
    /// и (опционально) запускает воспроизведение. Общий путь seek и пересбора графа.
    private func reschedule(from seconds: Double, andPlay shouldPlay: Bool) {
        guard let file else { return }
        let sampleRate = file.processingFormat.sampleRate
        let targetFrame = AVAudioFramePosition((seconds * sampleRate).rounded())
        let clampedFrame = min(max(targetFrame, 0), max(file.length - 1, 0))
        let remainingFrames = AVAudioFrameCount(file.length - clampedFrame)
        guard remainingFrames > 0 else { return }
        defer { updateNowPlaying() }

        generation &+= 1
        let gen = generation

        player.stop()
        prescheduledFile = nil
        sampleTimeBase = 0
        startFrame = clampedFrame
        currentTime = Double(clampedFrame) / sampleRate

        player.scheduleSegment(file, startingFrame: clampedFrame,
                               frameCount: remainingFrames, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }
        prescheduleNext()
        if shouldPlay {
            if !engine.isRunning {
                try? engine.start()
            }
            // player.play() на незапущенном движке кидает NSException —
            // при неудачном старте остаёмся на новой позиции в паузе.
            guard engine.isRunning else {
                state = .paused
                return
            }
            player.play()
            state = .playing
        }
    }

    /// Пересобирает аудиограф под текущий маршрут вывода (новый ЦАП, динамик)
    /// и продолжает с указанной позиции.
    private func rebuildGraph(resumeFrom seconds: Double, andPlay shouldPlay: Bool) {
        guard let file else { return }
        generation &+= 1
        player.stop()
        engine.stop()
        _ = SampleRateCoordinator.prepare(session: session,
                                          fileRate: file.fileFormat.sampleRate)
        try? AVAudioSession.sharedInstance().setActive(true)
        wasOnExternalOutput = Self.routeHasExternalOutput()
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        engine.prepare()
        reschedule(from: seconds, andPlay: shouldPlay)
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
        prescheduledFile = nil
        sampleTimeBase = 0
        engine.stop()
        _ = SampleRateCoordinator.prepare(session: session,
                                          fileRate: loadedFile.fileFormat.sampleRate)
        try? AVAudioSession.sharedInstance().setActive(true)
        wasOnExternalOutput = Self.routeHasExternalOutput()

        // 3. Пересбор графа под формат файла.
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: loadedFile.processingFormat)
        needsGraphRebuild = false

        // 4. Запланировать файл; completion (.dataPlayedBack — после фактического
        //    проигрывания хвоста через выход, а не после потребления данных нодой,
        //    иначе stop() в next() обрезает конец трека) → следующий трек.
        player.scheduleFile(loadedFile, at: nil,
                            completionCallbackType: .dataPlayedBack) { [weak self] _ in
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
        updateNowPlaying()
        refreshArtwork(for: track)

        // 6. Таймер позиции.
        startTimeObserver()

        // 7. Gapless: предзапланировать следующий трек той же частоты.
        prescheduleNext()
    }

    /// Gapless: если следующий трек очереди существует и его формат совпадает
    /// с текущим (sampleRate и channelCount), файл сразу ставится в очередь
    /// ноды — она сыграет его встык, без зазора. При другом формате не
    /// предпланируем: completion пойдёт обычным путём next() → loadAndPlay
    /// с пересбором графа под новую частоту (микропауза на переключение ЦАПа).
    private func prescheduleNext() {
        prescheduledFile = nil
        guard let file else { return }
        let nextIndex = (queue.currentIndex ?? -1) + 1
        guard nextIndex < queue.tracks.count,
              let nextFile = try? AVAudioFile(forReading: queue.tracks[nextIndex].url)
        else { return }
        let current = file.processingFormat
        let next = nextFile.processingFormat
        guard next.sampleRate == current.sampleRate,
              next.channelCount == current.channelCount else { return }

        let gen = generation
        player.scheduleFile(nextFile, at: nil,
                            completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }
        prescheduledFile = nextFile
    }

    /// Артворк грузится асинхронно: Now Playing сначала обновляется без него,
    /// после загрузки — повторно с картинкой (если трек не сменился).
    private func refreshArtwork(for track: Track) {
        artworkTask?.cancel()
        currentArtwork = nil
        artworkTask = Task { [weak self] in
            guard let self else { return }
            let image = await self.artworkLoader.artwork(for: track)
            guard !Task.isCancelled, self.queue.current?.id == track.id else { return }
            self.currentArtwork = image
            self.updateNowPlaying()
        }
    }

    private func handleTrackFinished(generation gen: Int) {
        guard gen == generation else { return }
        guard let nextFile = prescheduledFile else {
            next()
            return
        }
        // Gapless: нода уже играет предзапланированный файл — ничего не
        // останавливаем, только двигаем бухгалтерию. Дослушанный файл дал
        // ноде length - startFrame кадров (после seek сегмент короче полного).
        if let finished = file {
            sampleTimeBase += finished.length - startFrame
        }
        prescheduledFile = nil
        queue.advance()
        file = nextFile
        startFrame = 0
        currentTime = 0
        updateNowPlaying()
        if let track = queue.current {
            refreshArtwork(for: track)
        }
        prescheduleNext()
    }

    private func stopPlayback() {
        generation &+= 1
        player.stop()
        engine.stop()
        file = nil
        prescheduledFile = nil
        startFrame = 0
        sampleTimeBase = 0
        timeObserver?.invalidate()
        timeObserver = nil
        currentTime = 0
        state = .idle
        artworkTask?.cancel()
        artworkTask = nil
        currentArtwork = nil
        nowPlaying.clear()
    }

    private func updateNowPlaying() {
        guard let track = queue.current else { return }
        nowPlaying.update(track: track, artwork: currentArtwork,
                          currentTime: currentTime, isPlaying: state == .playing)
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
        let frames = max(playerTime.sampleTime - sampleTimeBase, 0) + startFrame
        currentTime = Double(frames) / file.processingFormat.sampleRate
    }
}
