import SwiftUI
import ZverTransport

/// Секция «Пульт» экрана Настроек (этап 5): управляет «Пультом с Мака» на iPhone.
///
/// Читает/пишет ``RemoteControlService`` (тумблер сервера, число подключённых
/// Маков, хост сопряжения) и ``PlayerEngine`` (режим паузы). Возможности:
/// - тумблер «Пульт с Мака» → `enable()`/`disable()` WS-сервера;
/// - пикер режима паузы («всегда на связи» / «экономный») → `PlayerEngine.pauseMode`;
/// - кнопка «Показать код сопряжения» → открывает окно с 6-значным кодом и
///   индикатором ожидания; код одноразовый, закрывается по `Готово` или после
///   успешного сопряжения;
/// - статус «Mac подключён»/«нет» по `connectedClients`.
///
/// Вьюха сетью не управляет напрямую — только дёргает методы сервиса; всю логику
/// (анонс, авторизация, выпуск токена) держит ``RemoteControlService`` /
/// ``RemotePairingHost``. Встраивается секциями в общий `Form` экрана Настроек
/// (см. `SettingsView`), отдельную вкладку не плодит.
struct RemoteSettingsView: View {
    @ObservedObject var remote: RemoteControlService
    @ObservedObject var player: PlayerEngine
    /// Хост сопряжения сервиса — отдельный `@ObservedObject`, чтобы UI обновлялся
    /// при появлении/смене показываемого кода (`pairingCode`) и факте сопряжения.
    @ObservedObject private var pairing: RemotePairingHost

    /// Показывать ли лист с кодом сопряжения.
    @State private var showingPairingSheet = false

    init(remote: RemoteControlService, player: PlayerEngine) {
        self.remote = remote
        self.player = player
        self.pairing = remote.pairing
    }

    var body: some View {
        Section {
            Toggle("Пульт с Мака", isOn: enabledBinding)

            if remote.isEnabled {
                connectionStatusRow

                Picker("На паузе", selection: pauseModeBinding) {
                    Text("Всегда на связи").tag(PauseMode.alwaysConnected)
                    Text("Экономный").tag(PauseMode.economical)
                }

                Button {
                    pairing.openPairing()
                    showingPairingSheet = true
                } label: {
                    Label("Показать код сопряжения", systemImage: "qrcode")
                }
            }
        } header: {
            Text("Пульт")
        } footer: {
            Text(footerText)
        }
        .sheet(isPresented: $showingPairingSheet, onDismiss: {
            pairing.closePairing()
        }) {
            PairingCodeSheet(pairing: pairing, isPresented: $showingPairingSheet)
        }
        // Закрываем лист автоматически, когда Mac успешно сопрягся.
        .onChange(of: pairing.didPair) { _, didPair in
            if didPair { showingPairingSheet = false }
        }
    }

    // MARK: - Строки

    @ViewBuilder
    private var connectionStatusRow: some View {
        LabeledContent("Состояние") {
            if remote.connectedClients > 0 {
                Label("Mac подключён", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Label("Ожидание", systemImage: "wifi")
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }

    // MARK: - Бинды

    /// Тумблер пульта: включает/выключает WS-сервер сервиса.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { remote.isEnabled },
            set: { on in
                if on { remote.enable() } else { remote.disable() }
            }
        )
    }

    /// Режим паузы: пишет в `PlayerEngine.pauseMode` (он сам персистит в UserDefaults).
    private var pauseModeBinding: Binding<PauseMode> {
        Binding(
            get: { player.pauseMode },
            set: { player.pauseMode = $0 }
        )
    }

    private var footerText: String {
        if remote.isEnabled {
            return "Mac управляет воспроизведением по локальной сети. «Всегда на "
                + "связи» — команды доходят и на паузе (расход батареи выше). "
                + "«Экономный» — на паузе пульт спит, оживает с локскрина."
        }
        return "Включите, чтобы управлять плеером iPhone с Мака по локальной сети. "
            + "iPhone и Mac должны быть в одной Wi-Fi."
    }
}

/// Лист сопряжения: крупный 6-значный код и индикатор ожидания Мака.
///
/// Код берётся из ``RemotePairingHost.pairingCode`` (генерируется при `openPairing`,
/// зануляется после успешной сверки кода Маком → `didPair`). Закрывается кнопкой
/// «Готово» или автоматически родителем при `didPair`.
private struct PairingCodeSheet: View {
    @ObservedObject var pairing: RemotePairingHost
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                VStack(spacing: 8) {
                    Text("Код сопряжения")
                        .font(.title3.weight(.semibold))
                    Text("Введите этот код на Маке в окне «Пульт».")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Text(pairing.pairingCode ?? "——————")
                    .font(.system(size: 48, weight: .bold, design: .monospaced))
                    .tracking(8)
                    .monospacedDigit()

                HStack(spacing: 8) {
                    ProgressView()
                    Text("Ожидание Мака…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Сопряжение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
