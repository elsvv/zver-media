import Foundation

/// Чистый, потокобезопасный реестр обнаруженных Bonjour-сервисов — без сети.
///
/// `NWServiceBrowser` (тонкий сетевой адаптер) на каждое изменение зовёт
/// `add`/`remove`, а UI читает `services`. Здесь живёт вся проверяемая логика:
/// дедупликация по `name`, обновление записи на месте и стабильная сортировка по
/// имени. Тип не зависит от `Network` и полностью покрыт тестами.
///
/// Реализован на `final class` с `NSLock` (`@unchecked Sendable` оправдан: всё
/// состояние под замком), чтобы безопасно вызываться из `@Sendable`-колбэков
/// браузера на сетевой очереди и читаться с главного потока.
public final class DiscoveredServiceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    /// Хранилище по имени сервиса — гарантирует дедуп и быстрое обновление/удаление.
    private var storage: [String: DiscoveredService] = [:]

    public init() {}

    /// Добавляет сервис или обновляет существующий с тем же `name` на месте
    /// (без дублирования).
    public func add(_ service: DiscoveredService) {
        lock.lock()
        defer { lock.unlock() }
        storage[service.name] = service
    }

    /// Удаляет сервис по имени. Удаление отсутствующего — не ошибка (no-op).
    public func remove(name: String) {
        lock.lock()
        defer { lock.unlock() }
        storage[name] = nil
    }

    /// Текущий снимок сервисов, отсортированный по имени (лексикографически).
    public var services: [DiscoveredService] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values.sorted { $0.name < $1.name }
    }

    /// Снимок сервисов с заданной ролью (`svc`), отсортированный по имени.
    ///
    /// Роль читается через computed `DiscoveredService.role`: отсутствие `svc`
    /// трактуется как `ServiceTXT.sync`, поэтому `services(role: ServiceTXT.sync)`
    /// включает и синк-сервисы этапа 3 (без TXT `svc`). Пульт-клиент Мака зовёт
    /// `services(role: ServiceTXT.remote)`, чтобы не путать пульт iPhone с
    /// синк-сервисом Мака на общем типе `_zver._tcp`.
    public func services(role: String) -> [DiscoveredService] {
        lock.lock()
        defer { lock.unlock() }
        return storage.values
            .filter { $0.role == role }
            .sorted { $0.name < $1.name }
    }
}
