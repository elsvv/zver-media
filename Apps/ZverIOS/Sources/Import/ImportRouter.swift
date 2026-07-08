import Foundation

/// Мост «Главная → Импорт»: шит рекомендации кладёт сюда поисковый URL Bandcamp
/// («Найти на Bandcamp»), `ContentView` переключает таб на «Импорт»,
/// `ImportHomeView` пушит Bandcamp-экран, а `BandcampImportView` загружает URL
/// и обнуляет поле (петля: рекомендация → $0/покупка → FLAC в библиотеке →
/// сигнал owned). Владелец — `ContentView` (`@StateObject` на весь сеанс).
@MainActor
final class ImportRouter: ObservableObject {
    /// Поисковый URL Bandcamp, ожидающий открытия во вкладке «Импорт».
    /// nil — моста нет; потребитель (`BandcampImportView`) обнуляет после загрузки.
    @Published var pendingBandcampSearch: URL?
}
