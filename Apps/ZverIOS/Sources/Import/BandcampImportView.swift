import SwiftUI

/// Источник «Bandcamp» — заглушка до задачи 5. Полноценный экран (webview с
/// персистентным логином и перехватом WKDownload → `AlbumImporter`) появится в
/// следующем этапе; пока — плейсхолдер «в разработке», чтобы селектор источников был
/// целостным.
struct BandcampImportView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Bandcamp", systemImage: "cart")
        } description: {
            Text("Покупка и загрузка релизов во FLAC появятся в следующем обновлении.")
        }
        .navigationTitle("Bandcamp")
        .navigationBarTitleDisplayMode(.inline)
    }
}
