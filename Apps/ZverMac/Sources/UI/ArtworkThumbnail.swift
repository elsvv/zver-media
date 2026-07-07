import SwiftUI
import ZverTransport

/// Обложка альбома с ленивой подгрузкой из ``AlbumArtworkStore``.
///
/// Квадратная плитка: показывает `NSImage` из кэша либо заглушку-ноту, и на
/// появлении зовёт `artwork.request(for:)` (память → диск → сеть). Перерисовка —
/// по `@Published revision` кэша (вью наблюдает `artwork`). Общий для грида
/// библиотеки и now-playing пульта — ключ обложки один и тот же (`albumId`).
struct ArtworkThumbnail: View {
    let albumId: String
    @ObservedObject var artwork: AlbumArtworkStore
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            if let image = artwork.image(for: albumId) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onAppear { artwork.request(for: albumId) }
    }
}

/// Бейдж облачного состояния альбома (`RemoteAlbum.cloudState`) для угла плитки.
///
/// `local`/nil → ничего; `backedUp` → облако с галкой; `remote` → облако;
/// `mixed` → облако полупрозрачное. Приглушение всей плитки для `remote`/`mixed`
/// делает вызывающий (грид), здесь только значок.
struct CloudBadge: View {
    let cloudState: String?

    var body: some View {
        switch cloudState {
        case "backedUp":
            badge("checkmark.icloud.fill")
        case "remote":
            badge("icloud.fill")
        case "mixed":
            badge("icloud.fill").opacity(0.5)
        default:
            EmptyView()   // local / nil — без бейджа
        }
    }

    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(.white, .blue)
            .padding(4)
            .background(.black.opacity(0.35), in: Circle())
    }
}
