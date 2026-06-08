import Foundation
import Network

/// Обнаруженный в локальной сети Bonjour-сервис Zver.
///
/// `host`/`port` опциональны: при первом обнаружении известно только имя, адрес
/// и порт резолвятся позже (или при установке соединения). Тип чистый, не
/// зависит от `Network`, `Sendable` для безопасной передачи через
/// `@Sendable`-колбэки браузера.
///
/// `txt` — TXT-запись сервиса (`name`, `v`, `svc` и т.п.). Дефолт `[:]` —
/// обратная совместимость с вызовами этапа 3, которые TXT не передавали.
/// Роль (`svc`) читается через computed `role` (см. `ServiceRole.swift`).
public struct DiscoveredService: Equatable, Sendable {
    public var name: String
    public var host: String?
    public var port: UInt16?
    public var txt: [String: String]

    public init(name: String, host: String? = nil, port: UInt16? = nil, txt: [String: String] = [:]) {
        self.name = name
        self.host = host
        self.port = port
        self.txt = txt
    }
}

/// Ищет сервисы `_zver._tcp` в локальной сети. Рантайм-сетевой объект спрятан за
/// протоколом; колбэк `onChange` вызывается на сетевой очереди — поэтому
/// `@Sendable` (переход в UI делается на стороне вызывающего через
/// `Task { @MainActor in … }`).
public protocol ServiceBrowser: Sendable {
    /// Начинает браузинг. `onChange` зовётся при каждом изменении набора
    /// обнаруженных сервисов и передаёт актуальный отсортированный список.
    func start(onChange: @Sendable @escaping ([DiscoveredService]) -> Void)
    /// Прекращает браузинг.
    func stop()
}

/// Адаптер `ServiceBrowser` поверх `NWBrowser` для `_zver._tcp`.
///
/// Тонкий и тестами НЕ покрывается (рантайм-сеть за протоколом). Чистую часть —
/// дедуп/сортировку набора — держит `DiscoveredServiceRegistry`, который и
/// покрыт тестами. Адаптер обязан лишь компилироваться под Swift 6 на обеих
/// платформах.
///
/// `@unchecked Sendable` оправдан: мутабельный `browser` живёт на сетевой
/// очереди `queue`, реестр потокобезопасен сам по себе.
public final class NWServiceBrowser: ServiceBrowser, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zver.browser")
    private let registry = DiscoveredServiceRegistry()
    private var browser: NWBrowser?

    public init() {}

    public func start(onChange: @Sendable @escaping ([DiscoveredService]) -> Void) {
        stop()

        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        // `bonjourWithTXTRecord` (а не `bonjour`) — чтобы `result.metadata` нёс
        // TXT-запись сервиса. Без этого роль `svc` (этап 5) не доходила бы до
        // браузера, и Mac не отличил бы пульт iPhone от синк-сервиса Мака.
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: zverServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: parameters)
        let registry = self.registry

        // Замыкание @Sendable: вызывается на сетевой очереди, не наследует
        // @MainActor-изоляцию. Обновляем чистый реестр и отдаём снимок наружу.
        browser.browseResultsChangedHandler = { @Sendable results, _ in
            // Полный пересбор реестра из текущего набора результатов: проще и
            // надёжнее, чем дифф по changes, и снимает риск рассинхрона.
            for name in registry.services.map(\.name) {
                registry.remove(name: name)
            }
            for result in results {
                if case let .service(name, _, _, _) = result.endpoint {
                    registry.add(
                        DiscoveredService(
                            name: name,
                            host: nil,
                            port: nil,
                            txt: Self.txtDictionary(from: result.metadata)
                        )
                    )
                }
            }
            onChange(registry.services)
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Извлекает TXT-запись из метаданных результата браузинга в чистый
    /// `[String:String]`. `.none` (TXT отсутствует) → пустой словарь, что роль
    /// трактует как `sync` (обратная совместимость этапа 3).
    private static func txtDictionary(from metadata: NWBrowser.Result.Metadata) -> [String: String] {
        if case let .bonjour(txtRecord) = metadata {
            return txtRecord.dictionary
        }
        return [:]
    }
}
