import SwiftUI
import ZverTransport

/// Вкладка «Библиотека»: грид альбомов iPhone с обложками, бейджами облака и
/// поиском. Тап по альбому → лист с треками и кнопками запуска на iPhone.
///
/// Каталог (`RemoteLibrary`, без треков) приходит на коннект в `store.library`.
/// Обложки ленивые: плитка на появлении зовёт `artwork.request` (память → диск →
/// сеть). Пульт должен быть подключён (`coordinator.isConnected`), иначе —
/// подсказка. «Что запустить» живёт здесь; «что играет» — во вкладке «Пульт».
struct LibraryGridView: View {
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore
    @ObservedObject var artwork: AlbumArtworkStore

    @State private var search = ""
    @State private var selection: AlbumSelection?

    init(coordinator: RemoteClientCoordinator) {
        self.coordinator = coordinator
        self.store = coordinator.store
        self.artwork = coordinator.artwork
    }

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 18)]

    var body: some View {
        Group {
            if !coordinator.isConnected {
                LibraryPlaceholder(
                    icon: "iphone.slash",
                    title: "Пульт не подключён",
                    subtitle: "Подключи пульт на вкладке «Пульт», чтобы видеть библиотеку iPhone."
                )
            } else if albums.isEmpty {
                LibraryPlaceholder(
                    icon: "music.note.list",
                    title: "Библиотека пуста",
                    subtitle: "Альбомы появятся, когда iPhone пришлёт каталог."
                )
            } else if filteredAlbums.isEmpty {
                LibraryPlaceholder(
                    icon: "magnifyingglass",
                    title: "Ничего не найдено",
                    subtitle: "Измени запрос — поиск идёт по названию и артисту."
                )
            } else {
                grid
            }
        }
        .navigationTitle("Библиотека")
        .searchable(text: $search, prompt: "Поиск по альбомам и артистам")
        .sheet(item: $selection) { sel in
            AlbumDetailView(album: sel.album, coordinator: coordinator)
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(filteredAlbums, id: \.id) { album in
                    AlbumTile(album: album, artwork: artwork) {
                        selection = AlbumSelection(album: album)
                    }
                }
            }
            .padding(18)
        }
    }

    private var albums: [RemoteAlbum] { store.library?.albums ?? [] }

    private var filteredAlbums: [RemoteAlbum] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return albums }
        return albums.filter { album in
            album.title.lowercased().contains(query)
                || (album.artist?.lowercased().contains(query) ?? false)
        }
    }

    /// Обёртка `RemoteAlbum` в `Identifiable` для `sheet(item:)` (сам DTO
    /// протокола Identifiable не является — id есть, но conformance держим в app).
    struct AlbumSelection: Identifiable {
        let album: RemoteAlbum
        var id: String { album.id }
    }
}

/// Плитка альбома: обложка + бейдж облака + название/артист. `remote` (только в
/// облаке) — приглушаем всю плитку, чтобы «не на телефоне» читалось глазами.
private struct AlbumTile: View {
    let album: RemoteAlbum
    @ObservedObject var artwork: AlbumArtworkStore
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    ArtworkThumbnail(albumId: album.id, artwork: artwork)
                    CloudBadge(cloudState: album.cloudState)
                        .padding(6)
                }
                Text(album.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let artist = album.artist?.trimmingCharacters(in: .whitespaces), !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .opacity(album.cloudState == "remote" ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(album.title)
    }
}

/// Лист альбома: крупная обложка, «Играть на iPhone», список треков с запуском
/// с выбранного трека. Треки тянутся `requestAlbumTracks` на появлении.
private struct AlbumDetailView: View {
    let album: RemoteAlbum
    @ObservedObject var coordinator: RemoteClientCoordinator
    @ObservedObject var store: RemoteClientStore
    @ObservedObject var artwork: AlbumArtworkStore
    @Environment(\.dismiss) private var dismiss

    init(album: RemoteAlbum, coordinator: RemoteClientCoordinator) {
        self.album = album
        self.coordinator = coordinator
        self.store = coordinator.store
        self.artwork = coordinator.artwork
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            trackList
        }
        .frame(width: 480, height: 580)
        .onAppear {
            artwork.request(for: album.id)
            if store.albumTracks[album.id] == nil {
                coordinator.requestAlbumTracks(albumId: album.id)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ArtworkThumbnail(albumId: album.id, artwork: artwork, cornerRadius: 10)
                .frame(width: 140, height: 140)
            VStack(alignment: .leading, spacing: 6) {
                Text(album.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                if let artist = album.artist?.trimmingCharacters(in: .whitespaces), !artist.isEmpty {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    coordinator.playAlbum(albumId: album.id, startIndex: 0)
                    dismiss()
                } label: {
                    Label("Играть на iPhone", systemImage: "play.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.isConnected)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let year = album.year { parts.append(String(year)) }
        parts.append(album.trackCount == 1 ? "1 трек" : "\(album.trackCount) треков")
        if let cloud = cloudLabel { parts.append(cloud) }
        return parts.joined(separator: " · ")
    }

    private var cloudLabel: String? {
        switch album.cloudState {
        case "backedUp": return "в облаке (есть копия)"
        case "remote": return "только в облаке"
        case "mixed": return "частично в облаке"
        default: return nil   // local / nil
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if let tracks = store.albumTracks[album.id] {
            if tracks.isEmpty {
                Spacer()
                Text("В альбоме нет треков")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                        Button {
                            coordinator.playAlbum(albumId: album.id, startIndex: index)
                            dismiss()
                        } label: {
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 24, alignment: .trailing)
                                Text(track.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(durationLabel(track.duration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Image(systemName: "play.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Играть с этого трека")
                    }
                }
                .listStyle(.inset)
            }
        } else {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Загрузка треков…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Общая заглушка вкладки «Библиотека» (не подключён / пусто / ничего не найдено).
private struct LibraryPlaceholder: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.medium))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
