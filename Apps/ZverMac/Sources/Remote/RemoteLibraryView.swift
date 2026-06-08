import SwiftUI
import ZverTransport

/// Браузинг библиотеки iPhone и текущая очередь (S5-8).
///
/// Лёгкий список альбомов (`RemoteLibrary`, без треков) приходит на коннект; по
/// тапу на альбом шлём `requestAlbumTracks(albumId)` → iPhone отвечает
/// `albumTracks` (кэшируются в `store.albumTracks`). Раскрытый альбом показывает
/// треки; тап по треку → `playAlbum(albumId, startIndex)` (iPhone резолвит альбом
/// из своего каталога и запускает плеер — Mac локальных файлов не видит).
///
/// Внизу — текущая очередь воспроизведения из последнего `RemotePlayerState`
/// (что реально стоит в плеере iPhone), с подсветкой играющего трека.
struct RemoteLibraryView: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore

    /// Раскрытый альбом (id) — для него тянем/показываем треки. Один за раз.
    @State private var expandedAlbumId: String?
    /// Переключатель «Библиотека» / «Очередь».
    @State private var tab: Tab = .library

    private enum Tab: String, CaseIterable, Identifiable {
        case library = "Библиотека"
        case queue = "Очередь"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            switch tab {
            case .library: libraryList
            case .queue: queueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Библиотека

    @ViewBuilder
    private var libraryList: some View {
        if let albums = store.library?.albums, !albums.isEmpty {
            List {
                ForEach(albums, id: \.id) { album in
                    albumRow(album)
                }
            }
            .listStyle(.inset)
        } else {
            placeholder(
                icon: "music.note.list",
                title: "Библиотека пуста",
                subtitle: "Альбомы появятся, когда iPhone пришлёт каталог."
            )
        }
    }

    @ViewBuilder
    private func albumRow(_ album: RemoteAlbum) -> some View {
        let isExpanded = expandedAlbumId == album.id
        Button {
            toggle(album)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title)
                        .lineLimit(1)
                    Text(albumSubtitle(album))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if isExpanded {
            albumTracks(for: album)
        }
    }

    @ViewBuilder
    private func albumTracks(for album: RemoteAlbum) -> some View {
        if let tracks = store.albumTracks[album.id] {
            if tracks.isEmpty {
                Text("В альбоме нет треков")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    Button {
                        coordinator.playAlbum(albumId: album.id, startIndex: index)
                    } label: {
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 22, alignment: .trailing)
                            Text(track.title)
                                .lineLimit(1)
                            Spacer()
                            Text(durationLabel(track.duration))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "play.circle")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Запустить альбом с этого трека")
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Загрузка треков…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 34)
        }
    }

    /// Разворачивает/сворачивает альбом; при раскрытии — запрашивает треки, если
    /// их ещё нет в кэше.
    private func toggle(_ album: RemoteAlbum) {
        if expandedAlbumId == album.id {
            expandedAlbumId = nil
        } else {
            expandedAlbumId = album.id
            if store.albumTracks[album.id] == nil {
                coordinator.requestAlbumTracks(albumId: album.id)
            }
        }
    }

    private func albumSubtitle(_ album: RemoteAlbum) -> String {
        var parts: [String] = []
        if let artist = album.artist?.trimmingCharacters(in: .whitespaces), !artist.isEmpty {
            parts.append(artist)
        }
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.trackCount == 1 ? "1 трек" : "\(album.trackCount) треков")
        return parts.joined(separator: " · ")
    }

    // MARK: - Очередь (из текущего состояния плеера)

    @ViewBuilder
    private var queueList: some View {
        let queue = store.playerState?.queue ?? []
        if queue.isEmpty {
            placeholder(
                icon: "list.number",
                title: "Очередь пуста",
                subtitle: "Запустите альбом из библиотеки."
            )
        } else {
            let currentIndex = store.playerState?.currentIndex
            List {
                ForEach(Array(queue.enumerated()), id: \.offset) { index, track in
                    HStack(spacing: 8) {
                        if index == currentIndex {
                            Image(systemName: store.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 18)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                                .frame(width: 18, alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .lineLimit(1)
                            if let artist = track.artist, !artist.isEmpty {
                                Text(artist)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(durationLabel(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .fontWeight(index == currentIndex ? .semibold : .regular)
                }
            }
            .listStyle(.inset)
        }
    }

    // MARK: - Хелперы

    private func placeholder(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
