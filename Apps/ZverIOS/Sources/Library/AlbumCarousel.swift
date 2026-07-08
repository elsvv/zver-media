import SwiftUI
import ZverCore

/// Горизонтальная карусель альбомов с заголовком: плитки `AlbumTile`
/// фиксированной ширины, тап — экран альбома. Используется в «Недавно
/// прослушанном»/«Добавленных» (Главная, Библиотека) и discovery-секциях
/// («Ещё от артиста», «Из того же года») внизу экрана альбома. Пустой список —
/// карусель не рисуется.
///
/// Живёт только в НЕ-`List` контейнерах (`ScrollView` Главной/Библиотеки/экрана
/// альбома), поэтому closure-`NavigationLink` здесь работает корректно. Баг «тап
/// открывает не тот альбом» возникает лишь у `NavigationLink` внутри `LazyVGrid`,
/// вложенного в `List`-строку (см. `FavoritesView` — там value-based навигация).
struct AlbumCarousel: View {
    let title: String
    let albums: [AlbumGroup]
    /// Если задан — в шапке справа появляется «Показать все» → грид всех альбомов
    /// (`AlbumsGridView`). nil (по умолчанию) — только заголовок, без кнопки.
    var allAlbums: [AlbumGroup]? = nil
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    /// Ширина плитки: ~2.4 плитки в кадре iPhone — намёк, что можно скроллить.
    private static let tileWidth: CGFloat = 150

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                header
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(albums) { group in
                            NavigationLink {
                                AlbumDetailView(group: group, store: store, engine: engine)
                            } label: {
                                AlbumTile(group: group, loader: engine.artworkLoader)
                                    .frame(width: Self.tileWidth)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    /// Шапка карусели: заголовок и, если задан `allAlbums`, ссылка «Показать все»
    /// на грид всех альбомов (как в Apple Music «See All»).
    @ViewBuilder
    private var header: some View {
        if let allAlbums {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Spacer()
                NavigationLink {
                    AlbumsGridView(title: title, albums: allAlbums,
                                   store: store, engine: engine)
                } label: {
                    Text("Показать все")
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, 16)
        } else {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
        }
    }
}
