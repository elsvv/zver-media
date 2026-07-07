import SwiftUI

/// Корневое окно приложения: `NavigationSplitView` с сайдбаром
/// Синк / Библиотека / Пульт и детальной областью по выбору.
///
/// Одно окно вместо прежних двух независимых сцен (Синк + Пульт). Browse пульта
/// (`RemoteClientCoordinator.startDiscovery`) стартует на появлении окна — и
/// библиотека, и пульт живут поверх одного подключения к iPhone.
struct RootView: View {
    @ObservedObject var queue: OutgoingQueue
    @ObservedObject var dropController: DropController
    @ObservedObject var server: ServerCoordinator
    @ObservedObject var remote: RemoteClientCoordinator

    @State private var section: AppSection? = .sync

    var body: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .navigationTitle("Zver Media")
        } detail: {
            switch section ?? .sync {
            case .sync:
                SyncTabView(queue: queue, dropController: dropController,
                            server: server, coordinator: remote)
            case .library:
                LibraryGridView(coordinator: remote)
            case .remote:
                RemoteControlView(coordinator: remote)
            }
        }
        .onAppear { remote.startDiscovery() }
    }
}

/// Разделы сайдбара. `rawValue` стабилен (не для UI — заголовки в `title`).
enum AppSection: String, CaseIterable, Identifiable {
    case sync
    case library
    case remote

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sync: return "Синк"
        case .library: return "Библиотека"
        case .remote: return "Пульт"
        }
    }

    var icon: String {
        switch self {
        case .sync: return "arrow.up.arrow.down.circle"
        case .library: return "square.grid.2x2"
        case .remote: return "play.circle"
        }
    }
}
