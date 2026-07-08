import SwiftUI
import ZverCore

/// Корневой экран «Библиотека» (как в Apple Music): карточка разделов
/// (Плейлисты, Артисты, Альбомы, Песни, Избранное), ниже — горизонтальная
/// карусель «Добавленные» (с «Показать все»). Здесь же — первичная загрузка
/// библиотеки и pull-to-refresh.
///
/// Экран — `ScrollView`, а не `List`: раньше «Недавно добавленные» жили гридом
/// `LazyVGrid` внутри `List`-строки, и `NavigationLink` внутри такого грида
/// открывал НЕ ТОТ альбом и ломал стек навигации (баг ленивого грида в List).
/// В `ScrollView` (как на «Главной») closure-`NavigationLink` работает корректно.
struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    /// Сколько «Добавленных» показываем в карусели (полный список — по «Показать все»).
    private static let recentLimit = 15

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                categoriesCard

                if !recentAlbums.isEmpty {
                    AlbumCarousel(title: "Добавленные",
                                  albums: Array(recentAlbums.prefix(Self.recentLimit)),
                                  allAlbums: recentAlbums,
                                  store: store, engine: engine)
                }
            }
            .padding(.vertical, 12)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("Библиотека")
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
    }

    // MARK: - Карточка разделов

    /// Разделы библиотеки одной сгруппированной карточкой (вид как у
    /// `.insetGrouped`-списка, но в `ScrollView` — без бага навигации).
    private var categoriesCard: some View {
        VStack(spacing: 0) {
            categoryRow("Плейлисты", "music.note.list") {
                PlaylistsView(store: store, engine: engine)
            }
            rowDivider
            categoryRow("Артисты", "music.mic") {
                ArtistsView(store: store, engine: engine)
            }
            rowDivider
            categoryRow("Альбомы", "square.stack") {
                AlbumsGridView(title: "Альбомы", albums: store.albums,
                               store: store, engine: engine)
            }
            rowDivider
            categoryRow("Песни", "music.note") {
                SongsView(store: store, engine: engine)
            }
            rowDivider
            categoryRow("Избранное", "heart") {
                FavoritesView(store: store, engine: engine)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }

    /// Разделитель между строками, отбитый под иконку (как в системном списке).
    private var rowDivider: some View {
        Divider().padding(.leading, 56)
    }

    private func categoryRow<Destination: View>(
        _ title: String, _ icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28, alignment: .center)
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Данные

    /// Альбомы по свежести добавления: recency папки = максимальный `addedAt`
    /// её треков (доимпорт трека «поднимает» альбом). Треки без даты — защитный
    /// фоллбэк в конец (addedAt заполняется каталогом с v1, пусто не бывает).
    private var recentAlbums: [AlbumGroup] {
        store.albums
            .map { (group: $0, added: $0.tracks.compactMap(\.addedAt).max() ?? .distantPast) }
            .sorted { $0.added > $1.added }
            .map(\.group)
    }
}
