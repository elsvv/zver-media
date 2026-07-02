import SwiftUI
import ZverCore

/// Сетка альбомов в 2 колонки: обложка, название, артист.
/// Общая для раздела «Альбомы» и экрана артиста; тап — AlbumDetailView.
///
/// Долгий тап по альбому → нативное контекст-меню (переименовать / облако /
/// выбрать / удалить). «Выбрать» включает режим мультивыбора: у плиток кружок-
/// галочка, снизу — панель пакетных действий. Все удаления — под confirm.
/// Альбомы только-в-облаке (все треки `remote`) показываются приглушёнными.
struct AlbumsGridView: View {
    let title: String
    let albums: [AlbumGroup]
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    @State private var isSelecting = false
    @State private var selection: Set<String> = []
    @State private var pending: PendingDeletion?
    @State private var renaming: AlbumGroup?
    @State private var renameText = ""

    /// Отложенное опасное действие — показывается через confirmationDialog.
    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let kind: Kind
        let groups: [AlbumGroup]
        enum Kind { case device, cloud, everywhere, local, choose }
    }

    private static let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(albums) { group in
                    cellContainer(for: group)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .navigationTitle(isSelecting ? selectionTitle : title)
        .toolbar { toolbar }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented,
                            titleVisibility: .visible, presenting: pending) { pending in
            confirmButtons(for: pending)
            Button("Отмена", role: .cancel) {}
        }
        .alert("Переименовать альбом", isPresented: renamePresented) {
            TextField("Название", text: $renameText)
            Button("Сохранить") {
                if let group = renaming { Task { await store.renameAlbum(group, to: renameText) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    // MARK: - Плитка и контекст-меню

    @ViewBuilder
    private func cellContainer(for group: AlbumGroup) -> some View {
        if isSelecting {
            Button { toggle(group) } label: {
                cell(for: group)
                    .overlay(alignment: .bottomTrailing) { selectionBadge(for: group) }
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: group) }
        } else {
            NavigationLink {
                AlbumDetailView(group: group, store: store, engine: engine)
            } label: {
                cell(for: group)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(for: group) }
        }
    }

    @ViewBuilder
    private func menu(for group: AlbumGroup) -> some View {
        Button { beginRename(group) } label: { Label("Переименовать", systemImage: "pencil") }

        if hasRemote(group) {
            Button { Task { await store.downloadAlbums([group]) } } label: {
                Label("Скачать", systemImage: "icloud.and.arrow.down")
            }
        }
        if hasLocalAwaitingBackup(group) {
            Button { Task { await store.backupAlbums([group]) } } label: {
                Label("Бэкап в облако", systemImage: "icloud.and.arrow.up")
            }
        }
        if hasBackedUp(group) {
            Button { pending = .init(kind: .device, groups: [group]) } label: {
                Label("Убрать с устройства", systemImage: "iphone.slash")
            }
        }
        if hasCloud(group) {
            Button(role: .destructive) { pending = .init(kind: .cloud, groups: [group]) } label: {
                Label("Удалить из облака", systemImage: "icloud.slash")
            }
        }

        Button { beginSelect(group) } label: { Label("Выбрать", systemImage: "checkmark.circle") }
        Divider()

        if hasCloud(group) {
            Button(role: .destructive) { pending = .init(kind: .everywhere, groups: [group]) } label: {
                Label("Удалить везде", systemImage: "trash")
            }
        } else {
            Button(role: .destructive) { pending = .init(kind: .local, groups: [group]) } label: {
                Label("Удалить", systemImage: "trash")
            }
        }
    }

    private func selectionBadge(for group: AlbumGroup) -> some View {
        let selected = selection.contains(group.id)
        return Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, selected ? Color.accentColor : Color.black.opacity(0.35))
            .padding(6)
            .shadow(radius: 2)
    }

    private func cell(for group: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AlbumArtworkView(track: group.tracks.first, loader: engine.artworkLoader)
                .overlay(alignment: .topTrailing) {
                    if isRemoteOnly(group) {
                        Image(systemName: "icloud")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(.black.opacity(0.35), in: Circle())
                            .padding(6)
                    }
                }
                // Только-в-облаке — приглушаем (нет на устройстве; тап-в-альбом → скачать).
                .opacity(isRemoteOnly(group) ? 0.5 : 1)
            Text(group.album)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(group.artist ?? ArtistsView.unknownArtistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if duplicatedTitles.contains(group.album), let first = group.tracks.first {
                Text(TrackQuality.compact(for: first))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Тулбар и подтверждения

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if albums.isEmpty {
                EmptyView()
            } else {
                Button(isSelecting ? "Готово" : "Выбрать") {
                    withAnimation {
                        isSelecting.toggle()
                        if !isSelecting { selection.removeAll() }
                    }
                }
            }
        }
        if isSelecting {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { Task { await store.downloadAlbums(selectedGroups) } } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button { Task { await store.backupAlbums(selectedGroups) } } label: {
                    Image(systemName: "icloud.and.arrow.up")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    pending = .init(kind: .choose, groups: selectedGroups)
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selection.isEmpty)
            }
        }
    }

    @ViewBuilder
    private func confirmButtons(for pending: PendingDeletion) -> some View {
        switch pending.kind {
        case .device:
            Button("Убрать с устройства", role: .destructive) { perform(.device, pending.groups) }
        case .cloud:
            Button("Удалить из облака", role: .destructive) { perform(.cloud, pending.groups) }
        case .everywhere:
            Button("Удалить везде", role: .destructive) { perform(.everywhere, pending.groups) }
        case .local:
            Button("Удалить", role: .destructive) { perform(.local, pending.groups) }
        case .choose:
            Button("Убрать с устройства", role: .destructive) { perform(.device, pending.groups) }
            Button("Удалить из облака", role: .destructive) { perform(.cloud, pending.groups) }
            Button("Удалить везде", role: .destructive) { perform(.everywhere, pending.groups) }
        }
    }

    private func perform(_ kind: PendingDeletion.Kind, _ groups: [AlbumGroup]) {
        Task {
            switch kind {
            case .device: await store.removeFromDevice(groups)
            case .cloud: await store.deleteFromCloud(groups)
            case .everywhere: await store.deleteEverywhere(groups)
            case .local: await store.deleteLocally(groups)
            case .choose: break
            }
            withAnimation { isSelecting = false; selection.removeAll() }
        }
    }

    // MARK: - Состояние выбора и действий

    private var selectedGroups: [AlbumGroup] { albums.filter { selection.contains($0.id) } }
    private var selectionTitle: String { selection.isEmpty ? "Выбор" : "Выбрано: \(selection.count)" }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
    }
    private var renamePresented: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }
    private var confirmTitle: String {
        switch pending?.kind {
        case .choose: return "Действие с \(pending?.groups.count ?? 0) альбомами"
        case .none: return ""
        default:
            return pending?.groups.first.map { "«\($0.album)»" } ?? "Удалить альбом?"
        }
    }

    private func toggle(_ group: AlbumGroup) {
        if selection.contains(group.id) { selection.remove(group.id) }
        else { selection.insert(group.id) }
    }
    private func beginSelect(_ group: AlbumGroup) {
        withAnimation { isSelecting = true; selection = [group.id] }
    }
    private func beginRename(_ group: AlbumGroup) {
        renameText = group.album
        renaming = group
    }

    private func isRemoteOnly(_ group: AlbumGroup) -> Bool {
        !group.tracks.isEmpty && group.tracks.allSatisfy { $0.fileState == .remote }
    }
    private func hasRemote(_ group: AlbumGroup) -> Bool { group.tracks.contains { $0.fileState == .remote } }
    private func hasBackedUp(_ group: AlbumGroup) -> Bool { group.tracks.contains { $0.fileState == .backedUp } }
    private func hasCloud(_ group: AlbumGroup) -> Bool {
        group.tracks.contains { $0.fileState == .backedUp || $0.fileState == .remote }
    }
    private func hasLocalAwaitingBackup(_ group: AlbumGroup) -> Bool {
        group.tracks.contains { $0.fileState == .local }
    }

    /// Названия альбомов, встречающиеся более одного раза: у таких плиток
    /// показываем подсказку-качество, чтобы различать версии (оцифровки).
    private var duplicatedTitles: Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for group in albums {
            if !seen.insert(group.album).inserted { dupes.insert(group.album) }
        }
        return dupes
    }
}

/// Квадратная обложка альбома с плейсхолдером: грузится лениво
/// через ArtworkLoader (общий кэш движка) по первому треку альбома.
struct AlbumArtworkView: View {
    let track: Track?
    let loader: ArtworkLoader
    var cornerRadius: CGFloat = 8

    @State private var artwork: UIImage?

    var body: some View {
        // Картинка лежит в overlay поверх квадрата: overlay не участвует
        // в layout родителя, поэтому scaledToFill у непрямоугольной обложки
        // не раздувает ячейку грида; вылезающую отрисовку режет clipShape.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .task(id: track?.id) {
                artwork = nil
                guard let track else { return }
                let image = await loader.artwork(for: track)
                // Отменённая задача (смена идентичности ячейки) не должна
                // перетирать артворк: continuation выполняется и после await.
                if !Task.isCancelled { artwork = image }
            }
    }
}
