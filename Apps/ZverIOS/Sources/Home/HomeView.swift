import SwiftUI
import ZverCore

/// Таб «Главная»: лента в духе Apple Music. Сверху — локальное «Недавно
/// прослушанное» (без сети и AI), ниже — секции AI-ленты из кэша: альбомные
/// подборки (ведущая шейдерная карточка + карусель) и внешние рекомендации
/// «что скачать». Обновление ленты — только вручную (⋯ → конфирм).
struct HomeView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var feedService: HomeFeedService
    @ObservedObject var account: BrainAccount

    @State private var recentlyPlayed: [AlbumGroup] = []
    @State private var confirmsRefresh = false
    @State private var selectedSuggestion: ExternalSuggestion?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !recentlyPlayed.isEmpty {
                    AlbumCarousel(title: "Недавно прослушанное",
                                  albums: recentlyPlayed,
                                  store: store, engine: engine)
                }

                feedBody

                if let updatedAt = feedService.feed?.updatedAt {
                    Text("Лента обновлена \(updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .navigationTitle("Главная")
        .toolbar { menu }
        .task {
            await store.refresh()
            recentlyPlayed = await store.recentlyPlayedAlbums(limit: 12)
        }
        .refreshable {
            // Pull-to-refresh обновляет ЛОКАЛЬНЫЕ данные (библиотека, недавнее),
            // не AI-ленту — токены тратятся только по явной кнопке.
            await store.refresh()
            recentlyPlayed = await store.recentlyPlayedAlbums(limit: 12)
        }
        .confirmationDialog("Обновить рекомендации?", isPresented: $confirmsRefresh,
                            titleVisibility: .visible) {
            Button("Обновить (запрос к модели)") {
                Task { await feedService.refresh() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Статистика прослушивания уйдёт выбранной модели, это потратит токены API.")
        }
        .sheet(item: $selectedSuggestion) { suggestion in
            ExternalSuggestionSheet(suggestion: suggestion)
        }
    }

    // MARK: - AI-лента

    /// Лента живёт поверх статуса: уже собранная (кэш) НЕ пропадает во время
    /// загрузки или после ошибки — статус показывается инлайн-баннером сверху.
    /// Полноэкранные состояния — только когда показывать нечего.
    @ViewBuilder
    private var feedBody: some View {
        if let feed = feedService.feed {
            statusBanner
            ForEach(feed.sections) { section in
                sectionView(section)
            }
        } else {
            switch feedService.state {
            case .loading:
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Модель собирает ленту…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Лента не собралась", systemImage: "sparkles")
                } description: {
                    Text(message)
                } actions: {
                    Button("Попробовать ещё раз") { confirmsRefresh = true }
                }
            case .idle:
                if account.isConfigured {
                    ContentUnavailableView {
                        Label("Лента ещё не собрана", systemImage: "sparkles")
                    } description: {
                        Text("Нажми ⋯ → «Обновить рекомендации» — модель соберёт" +
                             " подборки по твоей библиотеке и истории.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Интеллект не настроен", systemImage: "sparkles")
                    } description: {
                        Text("Укажи API-ключ, base URL и модель в Настройках →" +
                             " Интеллект, и здесь появятся умные подборки.")
                    }
                }
            }
        }
    }

    /// Инлайн-статус над живой лентой: спиннер во время генерации, ошибка —
    /// баннером (старая лента остаётся рабочей).
    @ViewBuilder
    private var statusBanner: some View {
        switch feedService.state {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Модель собирает новую ленту…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func sectionView(_ section: ResolvedHomeSection) -> some View {
        if !section.albumKeys.isEmpty {
            albumSection(section)
        } else if !section.external.isEmpty {
            externalSection(section)
        }
    }

    /// Альбомная AI-подборка: ведущая шейдерная карточка (тап — экран секции
    /// гридом) + карусель самих альбомов.
    private func albumSection(_ section: ResolvedHomeSection) -> some View {
        let albums = section.albumKeys.compactMap { store.album(forKey: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    NavigationLink {
                        AlbumsGridView(title: section.title, albums: albums,
                                       store: store, engine: engine)
                    } label: {
                        AIPlaylistCover(title: section.title,
                                        subtitle: section.subtitle)
                            .frame(width: 220)
                    }
                    .buttonStyle(.plain)

                    ForEach(albums) { group in
                        NavigationLink {
                            AlbumDetailView(group: group, store: store, engine: engine)
                        } label: {
                            AlbumTile(group: group, loader: engine.artworkLoader)
                                .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Внешние рекомендации «что скачать»: карточки с iTunes-обложкой
    /// (фоллбэк — шейдер), тап — шит с объяснением.
    private func externalSection(_ section: ResolvedHomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.title3.weight(.semibold))
                if let subtitle = section.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(section.external) { suggestion in
                        Button {
                            selectedSuggestion = suggestion
                        } label: {
                            ExternalSuggestionCard(suggestion: suggestion)
                                .frame(width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ToolbarContentBuilder
    private var menu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button {
                    confirmsRefresh = true
                } label: {
                    Label("Обновить рекомендации", systemImage: "sparkles")
                }
                .disabled(feedService.state == .loading)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

/// Карточка внешней рекомендации: обложка из iTunes (пока грузится/не нашлась —
/// шейдерная заглушка с артистом), название + артист под ней.
struct ExternalSuggestionCard: View {
    let suggestion: ExternalSuggestion

    @State private var artwork: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .aspectRatio(1, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    AIPlaylistCover(title: suggestion.album, cornerRadius: 8)
                }
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(4)
                    .background(.black.opacity(0.35), in: Circle())
                    .padding(6)
            }
            Text(suggestion.album)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(suggestion.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task(id: suggestion.id) {
            artwork = await ITunesArtworkFetcher.shared.artwork(
                artist: suggestion.artist, album: suggestion.album)
        }
    }
}

/// Шит внешней рекомендации: крупная обложка, метадата и reason —
/// «почему тебе зайдёт» от модели.
struct ExternalSuggestionSheet: View {
    let suggestion: ExternalSuggestion

    @State private var artwork: UIImage?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Group {
                    if let artwork {
                        Image(uiImage: artwork)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    } else {
                        AIPlaylistCover(title: suggestion.album)
                    }
                }
                .frame(maxWidth: 280)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

                VStack(spacing: 4) {
                    Text(suggestion.album)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(suggestion.year.map { "\(suggestion.artist) • \($0)" }
                         ?? suggestion.artist)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Text(suggestion.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                Label("Найди и закинь через Mac-синк — появится в библиотеке",
                      systemImage: "laptopcomputer.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .task(id: suggestion.id) {
            artwork = await ITunesArtworkFetcher.shared.artwork(
                artist: suggestion.artist, album: suggestion.album)
        }
    }
}
