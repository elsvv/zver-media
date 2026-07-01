import SwiftUI
import ZverCore

/// Сетка альбомов в 2 колонки: обложка, название, артист.
/// Общая для раздела «Альбомы» и экрана артиста; тап — AlbumDetailView.
struct AlbumsGridView: View {
    let title: String
    let albums: [AlbumGroup]
    @ObservedObject var store: LibraryStore
    @ObservedObject var engine: PlayerEngine

    private static let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: Self.columns, spacing: 20) {
                ForEach(albums) { group in
                    NavigationLink {
                        AlbumDetailView(group: group, store: store, engine: engine)
                    } label: {
                        cell(for: group)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            // Хвостовой отступ: последний ряд плиток не должен упираться в
            // мини-плеер (он висит через .safeAreaInset у стека навигации).
            .padding(.bottom, 12)
        }
        .navigationTitle(title)
    }

    /// Названия альбомов, встречающиеся более одного раза в этом списке: у таких
    /// плиток показываем подсказку-качество, чтобы различать версии (оцифровки).
    private var duplicatedTitles: Set<String> {
        var seen: Set<String> = []
        var dupes: Set<String> = []
        for group in albums {
            if !seen.insert(group.album).inserted { dupes.insert(group.album) }
        }
        return dupes
    }

    private func cell(for group: AlbumGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AlbumArtworkView(track: group.tracks.first, loader: engine.artworkLoader)
            Text(group.album)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(group.artist ?? ArtistsView.unknownArtistName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            // Дубль названия = разные версии одного альбома: подсказка «24/96»
            // (качество первого трека) позволяет отличить их в сетке.
            if duplicatedTitles.contains(group.album), let first = group.tracks.first {
                Text(TrackQuality.compact(for: first))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
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
