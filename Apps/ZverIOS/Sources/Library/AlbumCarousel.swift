import SwiftUI
import ZverCore

/// Горизонтальная карусель альбомов с заголовком: плитки `AlbumTile`
/// фиксированной ширины, тап — экран альбома. Используется в discovery-секциях
/// («Ещё от артиста», «Из того же года») внизу экрана альбома; переиспользуема
/// для лент на будущем табе «Главная». Пустой список — карусель не рисуется.
struct AlbumCarousel: View {
    let title: String
    let albums: [AlbumGroup]
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    /// Ширина плитки: ~2.4 плитки в кадре iPhone — намёк, что можно скроллить.
    private static let tileWidth: CGFloat = 150

    var body: some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal, 16)
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
}
