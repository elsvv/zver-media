import Testing
import Foundation
@testable import ZverTransport

@Suite struct DiscoveredServiceRegistryTests {
    @Test func emptyRegistryHasNoServices() {
        let registry = DiscoveredServiceRegistry()
        #expect(registry.services.isEmpty)
    }

    @Test func addInsertsService() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "MacBook", host: "1.2.3.4", port: 8080))
        #expect(registry.services.count == 1)
        #expect(registry.services.first?.name == "MacBook")
    }

    // Дедуп по имени: повторный add того же имени обновляет запись, не дублирует.
    @Test func addSameNameUpdatesInPlaceWithoutDuplicating() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "MacBook", host: nil, port: nil))
        registry.add(DiscoveredService(name: "MacBook", host: "10.0.0.5", port: 9000))
        #expect(registry.services.count == 1)
        let svc = registry.services.first
        #expect(svc?.host == "10.0.0.5")
        #expect(svc?.port == 9000)
    }

    @Test func removeByNameDeletesService() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "MacBook", host: "1.1.1.1", port: 80))
        registry.add(DiscoveredService(name: "iMac", host: "2.2.2.2", port: 81))
        registry.remove(name: "MacBook")
        #expect(registry.services.count == 1)
        #expect(registry.services.first?.name == "iMac")
    }

    @Test func removeUnknownNameIsNoOp() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "MacBook", host: nil, port: nil))
        registry.remove(name: "Ghost")
        #expect(registry.services.count == 1)
    }

    // Список всегда отсортирован по имени независимо от порядка добавления.
    // Сортировка — стандартный лексикографический `<` для строк (детерминированно,
    // без локали): прописные буквы идут перед строчными по Unicode-скаляру.
    @Test func servicesAreSortedByName() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "Charlie", host: nil, port: nil))
        registry.add(DiscoveredService(name: "Apple", host: nil, port: nil))
        registry.add(DiscoveredService(name: "Bravo", host: nil, port: nil))
        #expect(registry.services.map(\.name) == ["Apple", "Bravo", "Charlie"])
    }

    // Сортировка лексикографическая (как в стандартном `<` для строк).
    @Test func sortingStaysStableAfterUpdate() {
        let registry = DiscoveredServiceRegistry()
        registry.add(DiscoveredService(name: "Beta", host: nil, port: nil))
        registry.add(DiscoveredService(name: "Alpha", host: nil, port: nil))
        registry.add(DiscoveredService(name: "Beta", host: "x", port: 1)) // обновление
        #expect(registry.services.map(\.name) == ["Alpha", "Beta"])
        #expect(registry.services.last?.host == "x")
    }

    @Test func discoveredServiceIsEquatable() {
        let a = DiscoveredService(name: "Mac", host: "1.2.3.4", port: 8080)
        let b = DiscoveredService(name: "Mac", host: "1.2.3.4", port: 8080)
        let c = DiscoveredService(name: "Mac", host: "1.2.3.4", port: 8081)
        #expect(a == b)
        #expect(a != c)
    }
}
