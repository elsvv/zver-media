import Foundation
import Network

/// Bonjour-тип сервиса синка Zver. Используют и анонс (`ServiceAdvertiser`), и
/// браузинг (`ServiceBrowser`) — обе стороны протокола должны совпадать.
public let zverServiceType = "_zver._tcp"

/// Публикует сервис в локальной сети по Bonjour. Рантайм-сетевой объект спрятан
/// за протоколом: чистая логика тестируется отдельно, адаптер остаётся тонким.
public protocol ServiceAdvertiser: Sendable {
    /// Начинает анонс на указанном порту с именем сервиса и TXT-записью
    /// (`name=<имя Мака>`, `v=1` и т.п.).
    func start(port: UInt16, name: String, txt: [String: String]) throws
    /// Прекращает анонс и освобождает слушатель.
    func stop()
}

/// Адаптер `ServiceAdvertiser` поверх `NWListener` — публикует `_zver._tcp` с
/// TXT-записью.
///
/// Тонкий и тестами НЕ покрывается (лессон прошлых этапов: рантайм-сетевые
/// объекты прячем за протоколом, юнит-тестим только чистую логику). Обязан лишь
/// корректно компилироваться под Swift 6 на iOS и macOS.
///
/// `@unchecked Sendable` оправдан: мутабельный `listener` синхронизирован
/// внутренней очередью `queue`, на которую завязаны и обновления состояния.
public final class NWServiceAdvertiser: ServiceAdvertiser, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zver.advertiser")
    private var listener: NWListener?

    public init() {}

    public func start(port: UInt16, name: String, txt: [String: String]) throws {
        stop()

        let parameters = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)

        let txtRecord = NWTXTRecord(txt)
        listener.service = NWListener.Service(
            name: name,
            type: zverServiceType,
            txtRecord: txtRecord
        )

        // Соединения здесь не обрабатываем — это задача файлового сервера в
        // ZverMac (S3-9). Анонсу достаточно принять и закрыть, чтобы порт жил.
        // Замыкание @Sendable: вызывается на сетевой очереди, не наследует
        // @MainActor-изоляцию (краш-класс Swift 6 из этапа 1).
        listener.newConnectionHandler = { @Sendable connection in
            connection.cancel()
        }

        self.listener = listener
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
