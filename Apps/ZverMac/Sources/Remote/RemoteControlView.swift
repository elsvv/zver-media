import SwiftUI
import ZverTransport

/// Окно «Пульт» (S5-8): транспорт + очередь + браузинг библиотеки iPhone с Мака.
///
/// Биндится к `RemoteClientCoordinator` (browse/WS/авторизация) и его агрегатору
/// `RemoteClientStore` (принятое `RemotePlayerState`/`RemoteLibrary`). Кнопки
/// транспорта и слайдер шлют команды (`play`/`pause`/`next`/`previous`/`seek`);
/// состояние (трек/playback/очередь) приходит пушами от iPhone. Позицию между
/// пушами интерполируем локальным таймером, пока `playback == .playing`
/// (`store.displayPosition`), чтобы шкала ехала плавно без флуда пушей.
///
/// Деградация: если iPhone не в сети / соединение упало (`status == .offline`),
/// показываем заглушку с кнопкой переподключения. Пока токена нет — экран ввода
/// 6-значного кода сопряжения (`needsPairingCode`).
struct RemoteControlView: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore

    init(coordinator: RemoteClientCoordinator) {
        self.coordinator = coordinator
        self.store = coordinator.store
    }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            content
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear { coordinator.startDiscovery() }
    }

    // MARK: - Верхняя полоса статуса

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusTitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let name = coordinator.selectedDeviceName {
                Label(name, systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch coordinator.status {
        case .connected: return .green
        case .discovering, .discovered, .pairing: return .orange
        case .offline, .failed: return .red
        case .idle: return .secondary
        }
    }

    private var statusTitle: String {
        switch coordinator.status {
        case .idle: return "Пульт выключен"
        case .discovering: return "Поиск iPhone в сети…"
        case .discovered: return "iPhone найден"
        case .pairing: return "Сопряжение…"
        case .connected: return "Подключено"
        case .offline: return "iPhone не в сети"
        case let .failed(message): return message
        }
    }

    // MARK: - Тело: маршрутизация по статусу

    @ViewBuilder
    private var content: some View {
        switch coordinator.status {
        case .connected:
            connectedBody
        case .pairing where coordinator.needsPairingCode:
            PairingCodeEntry(coordinator: coordinator)
        case .offline, .failed:
            OfflinePlaceholder(coordinator: coordinator)
        case .idle, .discovering, .discovered, .pairing:
            DiscoveryPlaceholder(coordinator: coordinator)
        }
    }

    /// Основной экран пульта: транспорт сверху, библиотека/очередь снизу.
    private var connectedBody: some View {
        VStack(spacing: 0) {
            NowPlayingPanel(coordinator: coordinator, store: store)
                .padding(16)
            Divider()
            RemoteLibraryView(coordinator: coordinator, store: store)
        }
    }
}

// MARK: - Now Playing + транспорт

/// Текущий трек, шкала позиции и кнопки транспорта. Позиция интерполируется
/// локальным таймером (`TimelineView`) по `store.displayPosition`, пока играет.
private struct NowPlayingPanel: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore

    /// Локальная позиция слайдера во время перетаскивания — пока пользователь
    /// тянет, не даём интерполяции/пушам дёргать ползунок; на отпускании — `seek`.
    @State private var scrubPosition: Double?

    var body: some View {
        VStack(spacing: 14) {
            trackInfo
            scrubber
            transport
        }
    }

    @ViewBuilder
    private var trackInfo: some View {
        if let track = store.playerState?.current {
            VStack(spacing: 4) {
                Text(track.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(secondaryLine(for: track))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 4) {
                Image(systemName: "music.note")
                    .font(.system(size: 30))
                    .foregroundStyle(.secondary)
                Text("Ничего не играет")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// «исполнитель — альбом» (опускаем отсутствующие части).
    private func secondaryLine(for track: RemoteTrack) -> String {
        [track.artist, track.album]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    /// Шкала позиции: интерполируется таймером, пока `playback == .playing`.
    /// `TimelineView(.periodic)` тикает раз в 0.5с и перечитывает
    /// `store.displayPosition` (который сам учитывает прошедшее время).
    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let duration = store.playerState?.current?.duration ?? 0
            let live = store.displayPosition
            let shown = scrubPosition ?? live
            VStack(spacing: 2) {
                Slider(
                    value: Binding(
                        get: { duration > 0 ? min(shown, duration) : 0 },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...max(duration, 0.01),
                    onEditingChanged: { editing in
                        if !editing, let target = scrubPosition {
                            coordinator.seek(to: target)
                            scrubPosition = nil
                        }
                    }
                )
                .disabled(duration <= 0)
                HStack {
                    Text(timeLabel(shown))
                    Spacer()
                    Text(timeLabel(duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 28) {
            transportButton("backward.fill", help: "Предыдущий") { coordinator.previous() }
            transportButton(playButtonSymbol, help: "Воспроизведение / пауза", large: true) {
                coordinator.togglePlayPause()
            }
            transportButton("forward.fill", help: "Следующий") { coordinator.next() }
        }
        .padding(.top, 2)
    }

    private var playButtonSymbol: String {
        store.isPlaying ? "pause.fill" : "play.fill"
    }

    private func transportButton(_ symbol: String,
                                 help: String,
                                 large: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 34 : 22, weight: .medium))
                .frame(width: large ? 56 : 40, height: large ? 56 : 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// `мм:сс` для шкалы; отрицательные/NaN → `0:00`.
    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Заглушки статусов

/// Экран ввода 6-значного кода сопряжения (нет сохранённого токена для iPhone).
private struct PairingCodeEntry: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.iphone")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Сопряжение с iPhone")
                .font(.title3.weight(.semibold))
            Text("Включите «Пульт» на iPhone и введите показанный там 6-значный код.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            TextField("Код", text: $code)
                .textFieldStyle(.roundedBorder)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .frame(width: 160)
                .onSubmit(submit)

            Button("Сопрячь", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }

    private func submit() {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 4 else { return }
        coordinator.submitPairingCode(trimmed)
    }
}

/// Деградация «iPhone не в сети» + кнопка переподключения.
private struct OfflinePlaceholder: View {
    @ObservedObject var coordinator: RemoteClientCoordinator

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("iPhone не в сети")
                .font(.title3.weight(.semibold))
            Text("Убедитесь, что iPhone в той же сети Wi-Fi и «Пульт» включён. Пульт переподключится автоматически, когда iPhone вернётся.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Переподключиться") {
                coordinator.reconnect()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

/// Список найденных iPhone (browse идёт), выбор устройства для подключения.
private struct DiscoveryPlaceholder: View {
    @ObservedObject var coordinator: RemoteClientCoordinator

    var body: some View {
        VStack(spacing: 14) {
            if coordinator.devices.isEmpty {
                ProgressView()
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Ищу iPhone в локальной сети…")
                    .foregroundStyle(.secondary)
                Text("Включите «Пульт» на iPhone, чтобы он появился здесь.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Выберите iPhone")
                    .font(.headline)
                List(coordinator.devices, id: \.name) { device in
                    Button {
                        coordinator.select(device)
                    } label: {
                        Label(device.name, systemImage: "iphone")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
                .frame(maxHeight: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
