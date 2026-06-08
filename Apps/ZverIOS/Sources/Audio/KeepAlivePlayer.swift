import AVFAudio

/// Silent keep-alive для режима паузы «всегда на связи» (этап 5).
///
/// Отдельный `AVAudioPlayerNode`, привязанный к тому же `AVAudioEngine`, что и
/// основной плеер, но к **отдельной** ноде — чтобы не вмешиваться в gapless-
/// бухгалтерию основного `player` (`sampleTimeBase`/`prescheduleNext`) и расчёт
/// `currentTime`. Нода крутит зацикленный буфер нулевых сэмплов: пока движок
/// работает, аудиосессия остаётся активной и iOS не суспендит приложение на
/// паузе — WebSocket-сервер пульта продолжает обслуживать команды.
///
/// Жизненный цикл подчинён `PlayerEngine`: `start()` на переходе в паузу в
/// режиме «всегда на связи»; `stop()` на `resume`/смене трека/`seek`/остановке.
/// Граф основного плеера пересобирается (`rebuildGraph`/route change) с
/// `engine.disconnectNodeOutput(player)` — keep-alive-нода отдельная и не
/// затрагивается, но её формат привязан к выходу, поэтому при пересборе графа
/// её надо переаттачить (`reattach(format:)`).
///
/// Concurrency: создаётся и используется из `PlayerEngine` (`@MainActor`).
/// Колбэков в системные API не регистрирует (буфер зациклен через `.loops`),
/// поэтому проблем с наследованием `@MainActor`-изоляции в замыканиях нет.
@MainActor
final class KeepAlivePlayer {
    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()

    /// Длительность одного буфера тишины. Достаточно крупный, чтобы не
    /// перепланировать часто, но мелкий относительно памяти.
    private let bufferSeconds: Double = 0.5

    /// Формат, под который сейчас собрана связка нода→микшер. Нужен, чтобы при
    /// пересборе графа основного плеера переаттачить keep-alive под новый формат.
    private var currentFormat: AVAudioFormat?

    /// Играет ли keep-alive сейчас (защита от двойного `start`/`stop`).
    private(set) var isRunning = false

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(node)
    }

    /// Запускает зацикленную тишину под указанным форматом. Идемпотентно.
    /// `format` — `processingFormat` текущего файла (совпадает с форматом, под
    /// который собран основной граф), чтобы микшер не ресэмплил впустую.
    func start(format: AVAudioFormat) {
        guard !isRunning else { return }
        connect(to: format)
        scheduleSilenceLoop(format: format)
        if !engine.isRunning {
            try? engine.start()
        }
        guard engine.isRunning else { return }
        node.play()
        isRunning = true
    }

    /// Останавливает keep-alive-ноду и отсоединяет её от микшера. Основной
    /// движок/плеер не трогаем — их жизненным циклом заведует `PlayerEngine`.
    func stop() {
        guard isRunning else { return }
        node.stop()
        engine.disconnectNodeOutput(node)
        currentFormat = nil
        isRunning = false
    }

    /// Переаттач после пересбора основного графа под новый формат (`rebuildGraph`
    /// /route change). Безопасно вызывать и когда keep-alive не запущен — тогда
    /// просто ничего не делает.
    func reattach(format: AVAudioFormat) {
        guard isRunning else { return }
        node.stop()
        engine.disconnectNodeOutput(node)
        connect(to: format)
        scheduleSilenceLoop(format: format)
        guard engine.isRunning else { return }
        node.play()
    }

    // MARK: - Приватное

    private func connect(to format: AVAudioFormat) {
        engine.connect(node, to: engine.mainMixerNode, format: format)
        currentFormat = format
    }

    /// Планирует буфер нулевых сэмплов в цикл (`.loops`). Буфер создаётся
    /// заполненным нулями (`frameLength = frameCapacity`); `AVAudioPCMBuffer`
    /// инициализирует данные нулями — тишина.
    private func scheduleSilenceLoop(format: AVAudioFormat) {
        let frames = AVAudioFrameCount(format.sampleRate * bufferSeconds)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return
        }
        buffer.frameLength = frames
        zeroFill(buffer)
        node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
    }

    /// Явно зануляет содержимое буфера на случай, если аллокатор отдал
    /// неинициализированную память (float и int16 каналы).
    private func zeroFill(_ buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        if let floatData = buffer.floatChannelData {
            for ch in 0..<channels {
                floatData[ch].update(repeating: 0, count: frameLength)
            }
        } else if let int16Data = buffer.int16ChannelData {
            for ch in 0..<channels {
                int16Data[ch].update(repeating: 0, count: frameLength)
            }
        } else if let int32Data = buffer.int32ChannelData {
            for ch in 0..<channels {
                int32Data[ch].update(repeating: 0, count: frameLength)
            }
        }
    }
}
