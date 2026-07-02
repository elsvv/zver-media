import AVFAudio
import Combine
import UIKit
import ZverCore

@MainActor
final class PlayerEngine: ObservableObject {
    enum State: Equatable { case idle, playing, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var queue = PlaybackQueue()
    /// Позиция воспроизведения ВНУТРИ текущего трека (секунды от его начала).
    /// Для обычного трека совпадает с позицией в файле; для cue-трека — за вычетом
    /// стартового кадра диапазона. Вся UI/локскрин/пульт работают в координатах
    /// трека (`track.duration` тоже по треку), поэтому конверсия абсолют↔трек
    /// живёт только здесь, в кадровой математике движка.
    @Published private(set) var currentTime: Double = 0

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?

    /// Режим паузы (этап 5): «всегда на связи» держит приложение живым на паузе
    /// тишиной keep-alive (пульт принимает команды), «экономный» — поведение
    /// этапов 1–4. Персистится в `UserDefaults`. Смена режима применяется со
    /// следующей паузы (не трогает текущее воспроизведение).
    @Published var pauseMode: PauseMode {
        didSet {
            guard pauseMode != oldValue else { return }
            pauseModeStore.save(pauseMode)
            // Режим переключили, пока стоим на паузе: привести keep-alive в
            // соответствие новому режиму немедленно.
            if state == .paused {
                applyKeepAliveForCurrentPause()
            }
        }
    }
    private let pauseModeStore: PauseModeStore

    /// Silent keep-alive для режима «всегда на связи»: отдельная нода тишины на
    /// том же движке, не вмешивается в gapless-бухгалтерию основного player.
    private lazy var keepAlive = KeepAlivePlayer(engine: engine)

    /// Абсолютный кадр в файле, с которого начинается СЕЙЧАС запланированный на
    /// ноду сегмент. При свежей загрузке трека == `segStartFrame`; после seek
    /// смещается к позиции seek. Служит для перевода `sampleTime` ноды в
    /// абсолютный кадр файла (см. `updateCurrentTime`).
    private var startFrame: AVAudioFramePosition = 0

    /// Абсолютный кадр начала диапазона ТЕКУЩЕГО трека в контейнере. Для обычного
    /// трека == 0 (весь файл = один трек); для cue-трека == `track.startFrame`.
    /// От него отсчитывается позиция внутри трека (`currentTime` — по треку).
    private var segStartFrame: AVAudioFramePosition = 0

    /// Длина диапазона текущего трека в кадрах, склампленная по реальной длине
    /// файла: `min(track.frameCount, file.length - segStartFrame)`. Для обычного
    /// трека == `file.length`. Конец сегмента = `segStartFrame + segFrameCount`.
    private var segFrameCount: AVAudioFrameCount = 0

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

    init(session: AudioSessionControlling = SystemAudioSession(),
         pauseModeStore: PauseModeStore = PauseModeStore()) {
        self.session = session
        self.pauseModeStore = pauseModeStore
        self.pauseMode = pauseModeStore.load()
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
        applyKeepAliveForCurrentPause()
        updateNowPlaying()
    }

    /// Приводит keep-alive в соответствие текущему режиму на паузе. В режиме
    /// «всегда на связи» — запускает зацикленную тишину под форматом текущего
    /// файла (движок не усыпляется, пульт жив); в «экономном» — гасит её.
    /// Вне паузы keep-alive всегда выключен (его глушат resume/loadAndPlay/seek).
    private func applyKeepAliveForCurrentPause() {
        guard state == .paused else {
            keepAlive.stop()
            return
        }
        if pauseMode.needsKeepAliveOnPause, let format = file?.processingFormat {
            keepAlive.start(format: format)
        } else {
            keepAlive.stop()
        }
    }

    func resume() {
        guard state == .paused else { return }
        // Выходим из паузы — глушим keep-alive до запуска основного player,
        // чтобы тишина не звучала параллельно музыке.
        keepAlive.stop()
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
        // `seconds` — позиция ВНУТРИ трека; переводим в абсолютный кадр файла и
        // клампим в диапазон трека `[segStartFrame, segEnd)`, а не в весь файл.
        let segEnd = segStartFrame + AVAudioFramePosition(segFrameCount)
        let targetFrame = segStartFrame + AVAudioFramePosition((seconds * sampleRate).rounded())
        let clampedFrame = min(max(targetFrame, segStartFrame), max(segEnd - 1, segStartFrame))
        let remainingFrames = AVAudioFrameCount(max(segEnd - clampedFrame, 0))
        guard remainingFrames > 0 else { return }
        defer { updateNowPlaying() }

        generation &+= 1
        let gen = generation

        // Seek/пересбор графа сбрасывает воспроизведение — keep-alive больше не
        // нужен (если играли — заиграет музыка; если нет — applyKeepAlive ниже
        // перезапустит тишину под новый формат на паузе).
        keepAlive.stop()
        player.stop()
        prescheduledFile = nil
        sampleTimeBase = 0
        startFrame = clampedFrame
        currentTime = Double(clampedFrame - segStartFrame) / sampleRate

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
        // Остались на паузе после seek (или engine не стартовал) — в режиме
        // «всегда на связи» вернуть keep-alive под (возможно новый) формат.
        if state == .paused {
            applyKeepAliveForCurrentPause()
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

    /// Диапазон сэмплов трека внутри уже открытого контейнера. Обычный трек
    /// (`startFrame == nil`) — весь файл `(0, file.length)`; cue-трек —
    /// `(track.startFrame, frameCount)` с клампом длины по реальной длине файла.
    /// У ПОСЛЕДНЕГО cue-трека `frameCount == nil` («до конца файла») — берём весь
    /// остаток реального файла, чтобы побитовый хвост не обрезался оценкой из скана.
    private func segmentRange(for track: Track,
                              in file: AVAudioFile) -> (start: AVAudioFramePosition,
                                                        count: AVAudioFrameCount) {
        guard let start = track.startFrame else {
            return (0, AVAudioFrameCount(max(file.length, 0)))
        }
        let clampedStart = min(max(AVAudioFramePosition(start), 0), max(file.length, 0))
        let maxCount = max(0, file.length - clampedStart)
        // frameCount == nil (последний трек) → до EOF; иначе клампим хранимую длину.
        let count: AVAudioFramePosition
        if let stored = track.frameCount {
            count = max(0, min(AVAudioFramePosition(stored), maxCount))
        } else {
            count = maxCount
        }
        return (clampedStart, AVAudioFrameCount(count))
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
        // Диапазон трека в контейнере (для cue — вырезка; для обычного — весь файл).
        let (segStart, segCount) = segmentRange(for: track, in: loadedFile)
        // Пустой сегмент (битые границы) — не зациклиться на нём, идём дальше.
        guard segCount > 0 else { next(); return }
        segStartFrame = segStart
        segFrameCount = segCount
        startFrame = segStart
        currentTime = 0

        // 2. Согласовать частоту сессии с файлом (bit-perfect, если ЦАП умеет).
        // Новый трек заиграет — keep-alive больше не нужен (граф сейчас
        // пересоберётся под формат файла, отдельную ноду тишины надо снять).
        keepAlive.stop()
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

        // 4. Запланировать сегмент трека; completion (.dataPlayedBack — после
        //    фактического проигрывания хвоста через выход, а не после потребления
        //    данных нодой, иначе stop() в next() обрезает конец трека) → следующий
        //    трек. Обычный трек = весь файл; cue-трек = его диапазон сэмплов.
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }
        if track.isCueTrack {
            player.scheduleSegment(loadedFile, startingFrame: segStart,
                                   frameCount: segCount, at: nil,
                                   completionCallbackType: .dataPlayedBack,
                                   completionHandler: completion)
        } else {
            player.scheduleFile(loadedFile, at: nil,
                                completionCallbackType: .dataPlayedBack,
                                completionHandler: completion)
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
        guard let file, let currentTrack = queue.current else { return }
        let nextIndex = (queue.currentIndex ?? -1) + 1
        guard nextIndex < queue.tracks.count else { return }
        let nextTrack = queue.tracks[nextIndex]

        // Открываем ОТДЕЛЬНЫЙ экземпляр файла под следующий сегмент даже для
        // cue-соседа того же контейнера: два запланированных сегмента не должны
        // делить курсор чтения одного AVAudioFile. Нода не останавливается и
        // формат тот же → gapless всё равно бесшовный (ЦАП лочится один раз).
        guard let nextFile = try? AVAudioFile(forReading: nextTrack.url) else { return }
        let sameContainer = nextTrack.url == currentTrack.url
        if !sameContainer {
            // Разные файлы: gapless только при совпадении формата, иначе
            // completion пойдёт обычным путём next() → loadAndPlay с пересбором
            // графа под новую частоту (микропауза на переключение ЦАПа).
            let current = file.processingFormat
            let next = nextFile.processingFormat
            guard next.sampleRate == current.sampleRate,
                  next.channelCount == current.channelCount else { return }
        }

        let gen = generation
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: gen) }
        }
        if nextTrack.isCueTrack {
            // Cue-трек (сосед или первый трек следующего контейнера) — его диапазон.
            let (nStart, nCount) = segmentRange(for: nextTrack, in: nextFile)
            guard nCount > 0 else { return }
            player.scheduleSegment(nextFile, startingFrame: nStart, frameCount: nCount,
                                   at: nil, completionCallbackType: .dataPlayedBack,
                                   completionHandler: completion)
        } else {
            player.scheduleFile(nextFile, at: nil,
                                completionCallbackType: .dataPlayedBack,
                                completionHandler: completion)
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
        // Gapless: нода уже играет предзапланированный сегмент — ничего не
        // останавливаем, только двигаем бухгалтерию. Дослушанный сегмент дал ноде
        // `segEnd - startFrame` кадров (после seek сегмент начинался позже старта
        // трека; для cue-трека конец сегмента = его граница, не конец файла).
        let finishedSegEnd = segStartFrame + AVAudioFramePosition(segFrameCount)
        sampleTimeBase += finishedSegEnd - startFrame
        prescheduledFile = nil
        queue.advance()
        file = nextFile
        // Новый диапазон трека в (том же или новом) контейнере.
        if let track = queue.current {
            let (segStart, segCount) = segmentRange(for: track, in: nextFile)
            segStartFrame = segStart
            segFrameCount = segCount
            startFrame = segStart
        } else {
            segStartFrame = 0
            segFrameCount = AVAudioFrameCount(max(nextFile.length, 0))
            startFrame = 0
        }
        currentTime = 0
        updateNowPlaying()
        if let track = queue.current {
            refreshArtwork(for: track)
        }
        prescheduleNext()
    }

    private func stopPlayback() {
        generation &+= 1
        keepAlive.stop()
        player.stop()
        engine.stop()
        file = nil
        prescheduledFile = nil
        startFrame = 0
        segStartFrame = 0
        segFrameCount = 0
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
        // Абсолютный кадр в файле → позиция внутри трека (минус старт диапазона),
        // склампленная по длине сегмента трека. На gapless-стыке нода уже рендерит
        // следующий трек, а бухгалтерия (queue.current/segStartFrame) ещё на текущем
        // до handleTrackFinished — без клампа таймер отдал бы позицию > длины трека,
        // и она утекла бы на пульт (в UI маскируется min, на проводе — нет).
        let absoluteFrame = max(playerTime.sampleTime - sampleTimeBase, 0) + startFrame
        let inTrack = min(max(absoluteFrame - segStartFrame, 0),
                          AVAudioFramePosition(segFrameCount))
        currentTime = Double(inTrack) / file.processingFormat.sampleRate
    }
}
