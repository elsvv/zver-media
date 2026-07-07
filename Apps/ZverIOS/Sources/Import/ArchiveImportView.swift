import SwiftUI

/// Источник «Internet Archive» (Live Music Archive) — заглушка до задачи 6.
/// Полноценный экран (нативный поиск концертов и загрузка FLAC с докачкой →
/// `AlbumImporter`) появится в следующем этапе; пока — плейсхолдер «в разработке».
struct ArchiveImportView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Internet Archive", systemImage: "waveform")
        } description: {
            Text("Поиск концертов Live Music Archive и загрузка FLAC появятся в следующем обновлении.")
        }
        .navigationTitle("Internet Archive")
        .navigationBarTitleDisplayMode(.inline)
    }
}
