import SwiftUI
import WebKit
import ZverImport

/// Источник «Bandcamp»: встроенный браузер с персистентным логином и перехватом
/// скачиваний. Пользователь сам проходит «buy → $0 → download» (ToS/AUP запрещают
/// автоматизацию), а приложение перехватывает отдаваемый файл (zip альбома / трек) и
/// раскладывает его в библиотеку через `AlbumImporter`.
///
/// `WebDownloadCenter` приходит сверху (из `ImportHomeView`, `@StateObject` уровня
/// стека «Импорта») — плашка прогресса видна и в селекторе источников, и здесь, и
/// переживает уход с экрана назад.
struct BandcampImportView: View {
    @ObservedObject var center: WebDownloadCenter
    /// Мост «Найти на Bandcamp»: отсюда забираем поисковый URL рекомендации.
    /// Экран — единственный потребитель: загрузил и обнулил.
    @ObservedObject var router: ImportRouter
    @StateObject private var navigator = WebNavigator()

    var body: some View {
        BandcampWebView(navigator: navigator, center: center)
            .ignoresSafeArea(.container, edges: .bottom)
            // Поисковый URL моста: и при пуше экрана (у @Published подписка
            // отдаёт текущее значение), и когда экран уже открыт. Обнуляем
            // отложенно — onReceive может сработать в момент установки
            // подписки, прямо во время рендера.
            .onReceive(router.$pendingBandcampSearch) { url in
                guard let url else { return }
                navigator.load(url)
                Task { @MainActor in router.pendingBandcampSearch = nil }
            }
            .navigationTitle("Bandcamp")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { navigator.goBack() } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .disabled(!navigator.canGoBack)

                    Button { navigator.goForward() } label: {
                        Image(systemName: "chevron.forward")
                    }
                    .disabled(!navigator.canGoForward)

                    Button { navigator.goHome() } label: {
                        Image(systemName: "house")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                WebDownloadsPlate(center: center)
            }
    }
}

/// Навигация webview для SwiftUI-тулбара: публикует доступность назад/вперёд и
/// проксирует команды в `WKWebView` (слабая ссылка — вьюху держит representable).
@MainActor
final class WebNavigator: ObservableObject {
    /// Стартовая и «домашняя» страница.
    let home = URL(string: "https://bandcamp.com")!

    @Published var canGoBack = false
    @Published var canGoForward = false

    weak var webView: WKWebView?

    /// URL, отложенный до создания вьюхи (мост «Найти на Bandcamp» пушит экран
    /// раньше, чем `makeUIView` создаст webview). Забирается в `initialURL`.
    private var pendingURL: URL?

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func goHome() { webView?.load(URLRequest(url: home)) }

    /// Загружает URL; вьюхи ещё нет — откладывает его до `makeUIView`.
    func load(_ url: URL) {
        if let webView {
            webView.load(URLRequest(url: url))
        } else {
            pendingURL = url
        }
    }

    /// Стартовый URL для `makeUIView`: отложенный поисковый (мост) или домашняя.
    func initialURL() -> URL {
        defer { pendingURL = nil }
        return pendingURL ?? home
    }

    /// Синхронизирует доступность кнопок с состоянием вьюхи (после каждого перехода).
    func sync() {
        canGoBack = webView?.canGoBack ?? false
        canGoForward = webView?.canGoForward ?? false
    }
}

/// `WKWebView` в SwiftUI. `websiteDataStore = .default()` — куки персистентны, логин
/// Bandcamp переживает перезапуск. Навигационный делегат перехватывает ответы под
/// скачивание (`WebDownloadPolicy`) и передаёт `WKDownload` в `WebDownloadCenter`.
struct BandcampWebView: UIViewRepresentable {
    let navigator: WebNavigator
    let center: WebDownloadCenter

    func makeCoordinator() -> Coordinator {
        Coordinator(navigator: navigator, center: center)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Персистентное хранилище: куки/логин Bandcamp сохраняются между сеансами.
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        navigator.webView = webView
        webView.load(URLRequest(url: navigator.initialURL()))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let navigator: WebNavigator
        private let center: WebDownloadCenter

        init(navigator: WebNavigator, center: WebDownloadCenter) {
            self.navigator = navigator
            self.center = center
        }

        /// Решение по ответу навигации: наш целевой файл (zip/audio) или то, что WebKit
        /// не покажет, — в скачивание; остальное — обычная навигация.
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if WebDownloadPolicy.shouldDownload(
                canShowMIMEType: navigationResponse.canShowMIMEType,
                mimeType: navigationResponse.response.mimeType
            ) {
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        /// Ответ стал скачиванием (перехвачен выше) — отдаём его центру.
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            center.register(download)
        }

        /// Скачивание из действия (ссылка с `Content-Disposition: attachment`).
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            center.register(download)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { navigator.sync() }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { navigator.sync() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            navigator.sync()
        }
    }
}

/// Плашка прогресса скачиваний webview: строки с долей/статусом + предупреждение,
/// что при уходе из приложения загрузка прервётся. Пустая (скрыта), пока скачиваний
/// нет. Общая для экрана Bandcamp и селектора источников (`ImportHomeView`).
struct WebDownloadsPlate: View {
    @ObservedObject var center: WebDownloadCenter

    var body: some View {
        if !center.items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(center.items) { item in
                    row(item)
                }
                if center.hasActive {
                    Label("Не закрывайте приложение — загрузка прервётся.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.regularMaterial,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func row(_ item: WebDownloadCenter.Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                icon(for: item.state)
                Text(item.filename)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(statusText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            switch item.state {
            case .downloading:
                ProgressView(value: item.fraction)
            case .importing:
                ProgressView().progressViewStyle(.linear)
            case .done, .failed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private func icon(for state: WebDownloadCenter.Item.State) -> some View {
        switch state {
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
        case .importing:   Image(systemName: "tray.and.arrow.down").foregroundStyle(.tint)
        case .done:        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:      Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    private func statusText(_ item: WebDownloadCenter.Item) -> String {
        switch item.state {
        case .downloading: return "\(Int(item.fraction * 100))%"
        case .importing:   return "Импорт…"
        case .done:        return "Готово"
        case let .failed(message): return message
        }
    }
}
