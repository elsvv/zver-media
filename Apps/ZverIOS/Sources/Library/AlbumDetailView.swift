import SwiftUI
import ZverCore
import ZverMetadata

/// Экран альбома в духе Apple Music: крупная центрированная обложка, название/
/// артист/строка качества цифрами, минималистичный транспорт (перемешать · играть ·
/// скачать), опциональное описание и список треков с бейджами и меню действий.
/// Тап по треку — воспроизведение альбома с него (remote-трек тапом качается).
struct AlbumDetailView: View {
    let group: AlbumGroup
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    /// Описание альбома из sidecar (`album.zvermeta.json`). Грузится в `.task`
    /// по появлению — отсутствие файла/поля это норма (тогда блок скрыт).
    @State private var albumDescription: String?
    @State private var isDescriptionExpanded = false

    @Environment(\.dismiss) private var dismiss
    @State private var pending: PendingKind?
    @State private var isRenaming = false
    @State private var renameText = ""

    private enum PendingKind: Identifiable {
        case device, cloud, everywhere, local
        var id: Int { hashValue }
    }

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            }
            if group.hasMultipleDiscs {
                // Много-дисковый альбом: каждый диск — своя секция с серым
                // заголовком «Диск N» (как в Apple Music). Индекс запуска —
                // глобальный (в group.tracks), номер в ряду — тег диска (1..N
                // на каждом диске).
                ForEach(discRowGroups) { section in
                    Section {
                        ForEach(Array(section.tracks.enumerated()), id: \.element.id) { local, track in
                            trackRow(globalIndex: section.startIndex + local,
                                     track: track,
                                     fallback: local + 1)
                        }
                    } header: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                    }
                }
            } else {
                Section {
                    ForEach(Array(group.tracks.enumerated()), id: \.element.id) { index, track in
                        trackRow(globalIndex: index, track: track, fallback: index + 1)
                    }
                }
            }

            // Освобождаем последний трек из-под мини-плеера. Он висит через
            // ContentView `.safeAreaInset(edge:.bottom)`, но в `.plain`-списке
            // на протолкнутом экране нижний inset до последнего ряда доходит
            // не всегда — явный прозрачный ряд гарантирует, что последний трек
            // доскролливается выше панели. Ряд есть только когда панель видна.
            if engine.queue.current != nil {
                Section {
                    Color.clear
                        .frame(height: MiniPlayerMetrics.approximateHeight)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(group.album)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { albumMenu }
        .task { await loadDescription() }
        .confirmationDialog("«\(group.album)»", isPresented: pendingPresented,
                            titleVisibility: .visible, presenting: pending) { kind in
            confirmButton(for: kind)
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать альбом", isPresented: $isRenaming) {
            TextField("Название", text: $renameText)
            Button("Сохранить") { Task { await store.renameAlbum(group, to: renameText) } }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Список треков

    /// Один диск для рендера: номер, глобальный индекс первого трека в
    /// `group.tracks` (для запуска альбома с правильной позиции) и треки диска.
    private struct DiscRowGroup: Identifiable {
        let number: Int
        let title: String       // «CD1»/«Side A» из папки/плейлиста, иначе «Диск N»
        let startIndex: Int
        let tracks: [Track]
        var id: Int { number }
    }

    /// Дисковые секции с проставленным глобальным стартовым индексом. Диски —
    /// непрерывные отрезки уже отсортированного `group.tracks`, поэтому смещение
    /// накапливаем по длине предыдущих.
    private var discRowGroups: [DiscRowGroup] {
        var result: [DiscRowGroup] = []
        var offset = 0
        for section in group.discSections {
            result.append(DiscRowGroup(number: section.number,
                                       title: section.title,
                                       startIndex: offset,
                                       tracks: section.tracks))
            offset += section.tracks.count
        }
        return result
    }

    private func trackRow(globalIndex: Int, track: Track, fallback: Int) -> some View {
        AlbumTrackRow(
            track: track,
            fallbackNumber: fallback,
            store: store,
            onPlay: { play(at: globalIndex, track: track) }
        )
    }

    // MARK: - Шапка

    private var header: some View {
        VStack(spacing: 16) {
            AlbumArtworkView(track: group.tracks.first,
                             loader: engine.artworkLoader,
                             cornerRadius: 14)
                // ~64% ширины контейнера-скролла: квадрат по aspectRatio обложки.
                .containerRelativeFrame(.horizontal) { length, _ in length * 0.64 }
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            VStack(spacing: 4) {
                Text(group.album)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(group.artist ?? ArtistsView.unknownArtistName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let metadataLine {
                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
            }

            transportRow
            descriptionBlock
        }
        .frame(maxWidth: .infinity)
    }

    /// Транспорт: круглая «перемешать», широкая «Играть», круглая «скачать».
    /// Каждая кнопка — `.plain` с собственной фигурой И `contentShape`, иначе в
    /// ряду списка тап по любому месту срабатывал бы на всех кнопках сразу.
    private var transportRow: some View {
        HStack(spacing: 16) {
            Button {
                // Перемешивание — простой shuffle массива перед запуском.
                engine.play(tracks: group.tracks.shuffled(), startAt: 0)
            } label: {
                Image(systemName: "shuffle")
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Перемешать")

            Button {
                engine.play(tracks: group.tracks, startAt: 0)
            } label: {
                Label("Играть", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 200)
                    .frame(height: 52)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            Button {
                downloadRemoteTracks()
            } label: {
                Image(systemName: hasRemoteTracks ? "icloud.and.arrow.down" : "arrow.down")
                    .font(.title3)
                    .foregroundStyle(hasRemoteTracks ? .primary : .secondary)
                    .frame(width: 52, height: 52)
                    .background(Color(uiColor: .secondarySystemFill), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!hasRemoteTracks)
            .accessibilityLabel("Скачать альбом")
        }
    }

    @ViewBuilder
    private var descriptionBlock: some View {
        if let text = albumDescription, !text.isEmpty {
            // «ещё» показываем только у явно длинного описания — иначе toggle над
            // одной строкой выглядел бы лишним (точное определение обрезки в SwiftUI
            // дорого; эвристики по длине достаточно). Короткое описание не режем.
            let canExpand = text.count > 90
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(canExpand && !isDescriptionExpanded ? 2 : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if canExpand {
                    Button(isDescriptionExpanded ? "свернуть" : "ещё") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isDescriptionExpanded.toggle()
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        }
    }

    /// Меню альбома в навбаре: переименование, облачные действия, удаление.
    /// Опасные пункты — под confirm (см. confirmationDialog). После полного
    /// удаления экран закрывается (альбома больше нет).
    @ToolbarContentBuilder
    private var albumMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    renameText = group.album
                    isRenaming = true
                } label: {
                    Label("Переименовать", systemImage: "pencil")
                }
                if hasRemoteTracks {
                    Button { downloadRemoteTracks() } label: {
                        Label("Скачать", systemImage: "icloud.and.arrow.down")
                    }
                }
                Button { Task { await store.backupAll() } } label: {
                    Label("Бэкап в облако", systemImage: "icloud.and.arrow.up")
                }
                if hasBackedUpTracks {
                    Button { pending = .device } label: {
                        Label("Убрать с устройства", systemImage: "iphone.slash")
                    }
                }
                Divider()
                if hasCloudTracks {
                    Button(role: .destructive) { pending = .cloud } label: {
                        Label("Удалить из облака", systemImage: "icloud.slash")
                    }
                    Button(role: .destructive) { pending = .everywhere } label: {
                        Label("Удалить везде", systemImage: "trash")
                    }
                } else {
                    Button(role: .destructive) { pending = .local } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    @ViewBuilder
    private func confirmButton(for kind: PendingKind) -> some View {
        switch kind {
        case .device:
            Button("Убрать с устройства", role: .destructive) { runDeletion(.device) }
        case .cloud:
            Button("Удалить из облака", role: .destructive) { runDeletion(.cloud) }
        case .everywhere:
            Button("Удалить везде", role: .destructive) { runDeletion(.everywhere) }
        case .local:
            Button("Удалить", role: .destructive) { runDeletion(.local) }
        }
    }

    private var pendingPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }

    /// Выполняет действие; закрывает экран, если альбом после него исчезает
    /// (полное удаление или удаление из облака у remote-only).
    private func runDeletion(_ kind: PendingKind) {
        let dismisses = kind == .local || kind == .everywhere
            || (kind == .cloud && isRemoteOnly)
        Task {
            switch kind {
            case .device: await store.removeFromDevice([group])
            case .cloud: await store.deleteFromCloud([group])
            case .everywhere: await store.deleteEverywhere([group])
            case .local: await store.deleteLocally([group])
            }
            if dismisses { dismiss() }
        }
    }

    private var isRemoteOnly: Bool {
        !group.tracks.isEmpty && group.tracks.allSatisfy { $0.fileState == .remote }
    }
    private var hasBackedUpTracks: Bool { group.tracks.contains { $0.fileState == .backedUp } }
    private var hasCloudTracks: Bool {
        group.tracks.contains { $0.fileState == .backedUp || $0.fileState == .remote }
    }

    // MARK: - Действия и данные

    private func play(at index: Int, track: Track) {
        // remote-трек (файла нет) тапом качается, а не играет.
        if track.fileState == .remote {
            Task { await store.download(track: track) }
        } else {
            engine.play(tracks: group.tracks, startAt: index)
        }
    }

    /// Есть ли что качать: хотя бы один трек только в облаке.
    private var hasRemoteTracks: Bool {
        group.tracks.contains { $0.fileState == .remote }
    }

    /// Скачивает все облачные (remote) треки альбома. Делегирует
    /// ``LibraryStore/downloadAlbums(_:)``, который дедупит по контейнеру: cue-альбом
    /// (N логических треков в одном `.flac`) качается один раз, а не N.
    private func downloadRemoteTracks() {
        Task { await store.downloadAlbums([group]) }
    }

    /// «2003 • 24 бит • 96 кГц • FLAC» — год (если есть) + числовое качество и
    /// кодек первого трека (метаданные альбома консистентны по трекам).
    private var metadataLine: String? {
        guard let first = group.tracks.first else { return nil }
        var parts: [String] = []
        if let year = group.tracks.compactMap(\.year).first {
            parts.append(String(year))
        }
        parts.append(TrackQuality.detailed(for: first))
        return parts.joined(separator: " • ")
    }

    /// Читает описание альбома из sidecar в папке альбома (вне главного потока).
    /// Отсутствие файла/поля — норма (блок описания просто не показывается).
    private func loadDescription() async {
        guard let folder = group.tracks.first?.url.deletingLastPathComponent() else { return }
        let sidecarURL = folder.appendingPathComponent(AlbumSidecar.fileName)
        let loaded: String? = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: sidecarURL),
                  let sidecar = try? JSONDecoder().decode(AlbumSidecar.self, from: data)
            else { return nil }
            return sidecar.description
        }.value
        if let loaded, !loaded.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            albumDescription = loaded
        }
    }
}

/// Ряд трека на экране альбома: номер, название, облачный бейдж и меню «…».
/// Тап по ряду играет/качает трек; меню «…» — те же действия, что раньше жили в
/// контекст-меню/свайпе (в плейлист + облако), но видимой кнопкой. Свайп-действия
/// облака оставлены как дополнительный жест.
private struct AlbumTrackRow: View {
    let track: Track
    let fallbackNumber: Int
    @ObservedObject var store: LibraryStore
    let onPlay: () -> Void

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistTitle = ""

    var body: some View {
        HStack(spacing: 12) {
            // Основная зона (номер + название + бейдж) — свой tap-таргет на play,
            // отдельно от меню «…», чтобы тапы не пересекались (как транспорт).
            HStack(spacing: 12) {
                Text(String(track.trackNumber ?? fallbackNumber))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
                Text(track.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                TrackCloudBadge(track: track)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onPlay)

            rowMenu
        }
        .cloudActions(for: track, store: store)
        .alert("Новый плейлист", isPresented: $isCreatingPlaylist) {
            TextField("Название", text: $newPlaylistTitle)
            Button("Создать") {
                Task {
                    if let playlist = await store.createPlaylist(title: newPlaylistTitle) {
                        await store.addToPlaylist(track: track, playlistId: playlist.id)
                    }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var rowMenu: some View {
        Menu {
            cloudMenuItems
            playlistMenu
        } label: {
            Image(systemName: "ellipsis")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Облачные пункты меню по состоянию трека (зеркало swipe-действий).
    @ViewBuilder
    private var cloudMenuItems: some View {
        switch track.fileState {
        case .backedUp:
            Button {
                Task { await store.offload(track: track) }
            } label: {
                Label("Выгрузить из устройства", systemImage: "icloud.and.arrow.up")
            }
        case .remote:
            Button {
                Task { await store.download(track: track) }
            } label: {
                Label("Скачать", systemImage: "icloud.and.arrow.down")
            }
        case .local, .uploading, .downloading:
            EmptyView()
        }
    }

    /// Подменю «В плейлист…»: список плейлистов + создание нового (алерт).
    private var playlistMenu: some View {
        Menu {
            ForEach(store.playlists) { playlist in
                Button(playlist.title) {
                    Task { await store.addToPlaylist(track: track, playlistId: playlist.id) }
                }
            }
            if !store.playlists.isEmpty { Divider() }
            Button {
                newPlaylistTitle = ""
                isCreatingPlaylist = true
            } label: {
                Label("Новый плейлист…", systemImage: "plus")
            }
        } label: {
            Label("В плейлист…", systemImage: "text.badge.plus")
        }
    }
}
