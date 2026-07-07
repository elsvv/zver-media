import SwiftUI
import ZverBrain
import ZverCore

/// Таб «Главная»: лента в духе Apple Music. Сверху — локальное «Недавно
/// прослушанное» (без сети и AI), ниже — секции AI-ленты из кэша: альбомные
/// подборки (ведущая шейдерная карточка + карусель) и внешние рекомендации
/// «что скачать». Обновление ленты — только вручную (⋯ → конфирм).
struct HomeView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine
    @ObservedObject var feedService: HomeFeedService
    @ObservedObject var profiles: BrainProfilesStore

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
            ExternalSuggestionSheet(suggestion: suggestion, feedService: feedService)
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
            case .loading, .validating:
                VStack(spacing: 10) {
                    ProgressView()
                    Text(progressLabel)
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
                if profiles.isConfigured {
                    ContentUnavailableView {
                        Label("Лента ещё не собрана", systemImage: "sparkles")
                    } description: {
                        Text("Нажми ⋯ → «Обновить рекомендации» — модель соберёт" +
                             " подборки по твоей библиотеке и истории.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("ИИ не настроен", systemImage: "sparkles")
                    } description: {
                        Text("Создай профиль провайдера (ключ, модель, тип API)" +
                             " в Настройках → ИИ, и здесь появятся умные подборки.")
                    }
                }
            }
        }
    }

    /// Текст фазы генерации: сборка у модели или валидация кандидатов
    /// через iTunes с прогрессом N/M.
    private var progressLabel: String {
        if case .validating(let done, let total) = feedService.state {
            return "Проверяю рекомендации… \(done)/\(total)"
        }
        return "Модель собирает ленту…"
    }

    /// Инлайн-статус над живой лентой: спиннер во время генерации/валидации,
    /// ошибка — баннером (старая лента остаётся рабочей).
    @ViewBuilder
    private var statusBanner: some View {
        switch feedService.state {
        case .loading, .validating:
            HStack(spacing: 10) {
                ProgressView()
                Text(progressLabel)
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
                            ExternalSuggestionCard(suggestion: suggestion,
                                                   liked: feedService.isLiked(suggestion))
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
                .disabled(feedService.state.isBusy)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

/// Карточка внешней рекомендации: обложка из iTunes (пока грузится/не нашлась —
/// шейдерная заглушка с артистом), название + артист под ней. Поверх обложки —
/// бейдж жанра (из валидации) и ♥, если рекомендация понравилась.
struct ExternalSuggestionCard: View {
    let suggestion: ExternalSuggestion
    let liked: Bool

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
            .overlay(alignment: .topLeading) {
                if liked {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                        .padding(4)
                        .background(.black.opacity(0.35), in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let genre = suggestion.genre {
                    Text(genre)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.35), in: Capsule())
                        .padding(6)
                }
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
            artwork = await ITunesCatalog.shared.artwork(for: suggestion)
        }
    }
}

extension ITunesCatalog {
    /// Обложка рекомендации: по готовому `artworkURL` из валидации (быстро,
    /// без второго похода в поиск); старый кэш ленты без него — через резолв.
    func artwork(for suggestion: ExternalSuggestion) async -> UIImage? {
        if let urlString = suggestion.artworkURL {
            return await artwork(urlString: urlString)
        }
        return await artwork(artist: suggestion.artist, album: suggestion.album)
    }
}

/// Шит внешней рекомендации v2: крупная обложка, метадата (жанр/год), reason
/// «почему тебе зайдёт», кнопки «Открыть в…» (Apple Music — прямой ссылкой из
/// валидации, остальные — мгновенным поиском) и фидбек ♥ / ✕ / «уже есть».
struct ExternalSuggestionSheet: View {
    let suggestion: ExternalSuggestion
    @ObservedObject var feedService: HomeFeedService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var artwork: UIImage?
    /// Точные ссылки Odesli (этап 2): подъезжают асинхронно после открытия
    /// (кэш — мгновенно, сеть — один запрос с таймаутом); пока их нет,
    /// кнопки работают поисковыми URL — шит никогда не ждёт сеть.
    @State private var songLinks: SongLinks?

    private var liked: Bool { feedService.isLiked(suggestion) }

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
                    Text(suggestion.artist)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                    if let meta = metaLine {
                        Text(meta)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Text(suggestion.reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)

                feedbackRow
                openInSection

                Label("Найди и закинь через Mac-синк — появится в библиотеке",
                      systemImage: "laptopcomputer.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .presentationDetents([.medium, .large])
        .task(id: suggestion.id) {
            async let art = ITunesCatalog.shared.artwork(for: suggestion)
            async let links = feedService.songLinks(for: suggestion)
            artwork = await art
            songLinks = await links
        }
    }

    /// «Жанр • Год» из валидации; чего нет — не показываем.
    private var metaLine: String? {
        let parts = [suggestion.genre, suggestion.year.map(String.init)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    // MARK: - Фидбек

    /// ♥ «Нравится» (повторный тап снимает), ✕ «Не моё» (карточка уходит из
    /// ленты, анти-сигнал в промпт), «У меня уже есть» (страховка дедупа).
    private var feedbackRow: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task {
                        await feedService.applyFeedback(
                            suggestion, status: liked ? .shown : .liked)
                    }
                } label: {
                    Label("Нравится", systemImage: liked ? "heart.fill" : "heart")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(liked ? .pink : .accentColor)

                Button {
                    Task {
                        await feedService.applyFeedback(suggestion, status: .hidden)
                        dismiss()
                    }
                } label: {
                    Label("Не моё", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task {
                    await feedService.applyFeedback(suggestion, status: .owned)
                    dismiss()
                }
            } label: {
                Label("У меня уже есть", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - «Открыть в…»

    /// Apple Music — прямой `collectionViewUrl` (есть только у прошедших
    /// валидацию); Яндекс.Музыка / Bandcamp — точные ссылки Odesli, когда
    /// подъехали (иконка меняется на link), иначе поисковые URL
    /// (`ExternalLinks`, без сети и ключей); YouTube — всегда поиск.
    /// Tidal/Deezer — бонусные кнопки, только с точной ссылкой.
    // TODO: мост к импорту — кнопка «Найти на Bandcamp», открывающая
    // Bandcamp-экран вкладки «Импорт» с поисковым URL. Зависит от параллельной
    // ветки feat/external-import — см. docs/plans/2026-07-07-discovery-v2-design.md
    // («Этап 2 — мост к импорту»).
    private var openInSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Открыть в…")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 8) {
                if let appleMusic = suggestion.appleMusicURL
                    .flatMap(URL.init(string:)) {
                    openButton("Apple Music", systemImage: "applelogo",
                               url: appleMusic)
                }
                linkedButton("Яндекс.Музыка", exact: songLinks?.yandex,
                             search: ExternalLinks.yandexMusic(artist: suggestion.artist,
                                                               album: suggestion.album))
                linkedButton("Bandcamp", exact: songLinks?.bandcamp,
                             search: ExternalLinks.bandcamp(artist: suggestion.artist,
                                                            album: suggestion.album))
                openButton("YouTube", systemImage: "magnifyingglass",
                           url: ExternalLinks.youtube(artist: suggestion.artist,
                                                      album: suggestion.album))
                if let tidal = songLinks?.tidal.flatMap(URL.init(string:)) {
                    openButton("Tidal", systemImage: "link", url: tidal)
                }
                if let deezer = songLinks?.deezer.flatMap(URL.init(string:)) {
                    openButton("Deezer", systemImage: "link", url: deezer)
                }
            }
        }
    }

    /// Кнопка площадки с апгрейдом: точная ссылка Odesli (иконка link),
    /// пока её нет — поисковый URL (иконка лупы). Кривая точная ссылка
    /// (не URL) — тот же поисковый фоллбэк.
    private func linkedButton(_ title: String, exact: String?,
                              search: URL) -> some View {
        let exactURL = exact.flatMap(URL.init(string:))
        return openButton(title,
                          systemImage: exactURL == nil ? "magnifyingglass" : "link",
                          url: exactURL ?? search)
    }

    private func openButton(_ title: String, systemImage: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
    }
}
